#!/usr/bin/env bash
#
# build-tarball.sh — build the manual-install tar.gz (ARC-22-D4).
#
# The tarball is the egresslock/ tree itself (engine, helpers, gateway,
# examples, docs (quickstart/setup/reference/troubleshooting tiers),
# apparmor, install-kit.sh, uninstall-kit.sh, README) plus the systemd/
# unit templates, so the extracted tree is
# SELF-CONTAINED: install-kit.sh prefers the in-kit systemd/ templates
# (ARC-22 implementation decision — see docs/tickets/ARC-22.md), which
# also means the kit can move to its own repository without layout
# changes.
#
#   tar -xzf egresslock_<version>.tar.gz
#   sudo ./egresslock/install-kit.sh --prefix /opt/egresslock
#   ... and on-box uninstall:
#   sudo ./egresslock/uninstall-kit.sh --prefix /opt/egresslock
#
# Environment:
#   EGRESSLOCK_TARBALL_OUT=<path>  output tar.gz path (default:
#                            packaging/egresslock_<version>.tar.gz next
#                            to this script; artifacts are NOT committed)
#   EGRESSLOCK_UNIT_SRC=<dir>      unit-template dir override (default:
#                            <kit>/systemd — the templates are in-tree
#                            kit assets since ARC-74-D5; there is no
#                            out-of-tree fallback)
#
# Exit codes: 0 ok, 1 build failure, 2 usage/environment error.
set -euo pipefail

pkg_dir="$(cd "$(dirname "$0")" && pwd)"
kit="$(cd "$pkg_dir/.." && pwd)"
# Git checkout root holding the kit (same resolution as build-deb.sh:
# the kit root IS the repo root since the EGL-1 flatten).
repo="$(git -C "$kit" rev-parse --show-toplevel 2>/dev/null || echo "$kit")"

# Runs as ANY user — staging and the output tarball live in mktemp /
# the output path; nothing system-owned is touched (R-022-2 follow-up:
# the install-kit-style root gate was over-conservative for a pure
# build).

# Version scheme (EGL-27-D1, EGL-72-D1/D2): same as build-deb.sh —
# <VERSION_BASE>+git<YYYYMMDDHHMMSS>.<short12>; the UTC
# second-resolution timestamp is the ordering key; the 12-char sha is
# identification only. EGL-72-D1: fail closed if VERSION_BASE is
# missing or empty.
[[ -s "$kit/VERSION_BASE" ]] || {
    echo "build-tarball: FAIL - VERSION_BASE missing or empty at $kit/VERSION_BASE (EGL-72-D1)" >&2
    exit 2
}
base="$(tr -d ' \t\n' < "$kit/VERSION_BASE")"
[[ -n "$base" ]] || {
    echo "build-tarball: FAIL - VERSION_BASE is empty (EGL-72-D1)" >&2
    exit 2
}
commit="$(git -C "$repo" rev-parse --short=12 HEAD 2>/dev/null || true)"
if [[ -z "$commit" ]]; then
    echo "build-tarball: WARNING - not a git checkout; version falls back to 'unknown'" >&2
    commit=unknown
fi
if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
    commit="$commit-dirty"
fi
version="${base}+git$(date -u '+%Y%m%d%H%M%S').$commit"

# Default artifact name carries the version (matches packaging/README.md).
out="${EGRESSLOCK_TARBALL_OUT:-$pkg_dir/egresslock_${version}.tar.gz}"

unit_src="${EGRESSLOCK_UNIT_SRC:-$kit/systemd}"
[[ -f "$unit_src/egresslock-verify@.service" && -f "$unit_src/egresslock-verify@.timer" ]] || {
    echo "build-tarball: unit templates missing under $unit_src" >&2
    exit 2
}

stage="$(mktemp -d /tmp/egresslock-tarball.XXXXXX)"
trap 'rm -rf "$stage"' EXIT

# Stage the kit tree (same file set the repo carries) + the templates.
mkdir -p "$stage/egresslock/systemd"
(
    cd "$kit"
    # Copy everything at the kit root (the repo root since the EGL-1
    # flatten) except the packaging build outputs and the repo-only
    # process files (git dir, AGENTS.md, .gitignore, docs/tickets/,
    # docs/BOARD.md) and the maintainer-internal internal_docs/
    # (EGL-47-D2) — the shipped tarball carries kit payload only,
    # exactly the file set the pre-flatten egresslock/ tree carried.
    tar -cf - --exclude=./packaging --exclude=./.git \
        --exclude=./AGENTS.md --exclude=./.gitignore \
        --exclude=./internal_docs \
        --exclude=./docs/tickets --exclude=./docs/BOARD.md \
        --exclude=./docs/lp-*.txt --exclude=./docs/debian-*.txt . | tar -xf - -C "$stage/egresslock"
)
# EGL-47-D2: tripwire — the maintainer-internal internal_docs/ must
# never reach the tarball; a widened copy rule would leak it.
if [[ -e "$stage/egresslock/internal_docs" ]]; then
    echo "build-tarball: FAIL - internal_docs leaked into the tarball stage" >&2
    exit 1
fi
# EGL-65-D1: tripwire — the internal bug-report drafts (docs/lp-*.txt,
# docs/debian-*.txt) stay repo-only, same as in the snapshot excludes.
if find "$stage/egresslock/docs" -maxdepth 1 \
        \( -name 'lp-*.txt' -o -name 'debian-*.txt' \) | grep -q .; then
    echo "build-tarball: FAIL - internal bug-report draft leaked into the tarball stage" >&2
    find "$stage/egresslock/docs" -maxdepth 1 \( -name 'lp-*.txt' -o -name 'debian-*.txt' \) >&2
    exit 1
fi
install -m 0644 "$unit_src/egresslock-verify@.service" "$stage/egresslock/systemd/"
install -m 0644 "$unit_src/egresslock-verify@.timer"   "$stage/egresslock/systemd/"

# EGL-72-D3: KIT_VERSION carries the BUILD version string (same string
# as the artifact name) so a tarball install stamps the deployed
# VERSION with the build version instead of re-synthesizing
# <base>+git<install-ts>.unknown. Stage-only: never committed.
printf '%s\n' "$version" > "$stage/egresslock/KIT_VERSION"
chmod 0644 "$stage/egresslock/KIT_VERSION"

# Top-level README fragment (ARC-22-D4).
cat > "$stage/README.txt" <<EOF
egresslock $version — manual install tarball

Quick install (prefix deploy, root):
  tar -xzf $(basename "$out") && cd egresslock
  sudo ./install-kit.sh --prefix /opt/egresslock
  sudo ./egresslock-setup --account <acct> --init-conf --enable
  sudo ./egresslock-setup --apparmor-check  # confirm pasta AppArmor compatibility on this host

On-box uninstall (root):
  sudo ./uninstall-kit.sh --prefix /opt/egresslock
  (account teardown first, while the engine exists:
   egresslock teardown --runtime — as the account)

See egresslock/README.md for the full guide.
EOF

mkdir -p "$(dirname "$out")"
tar -czf "$out" -C "$stage" README.txt egresslock
echo "build-tarball: built $out (version $version)"
