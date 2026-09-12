#!/usr/bin/env bash
#
# build-deb.sh — build the egresslock .deb (ARC-22-D1/D2).
#
# The .deb is a thin, OPTIONAL convenience; clone + install-kit.sh stays
# the primary deploy. This script stages an FHS tree and calls
# dpkg-deb --build directly (no debhelper, no debian/ project):
#
#   /usr/bin/egresslock              wrapper -> /usr/lib/egresslock/egresslock
#   /usr/sbin/egresslock-setup       wrapper -> /usr/lib/egresslock/egresslock-setup
#   /usr/lib/egresslock/             engine, egresslock-start, egresslock-verify,
#                                    egresslock-setup, gateway/, VERSION
#   /usr/share/egresslock/examples/  starter conf + allowlist + recipes
#   /usr/share/egresslock/doc/       docs/ tree (EGL-28 structure,
#                                    structure-preserving) + README.md
#   /usr/share/egresslock/apparmor/  ARC-27 pasta snippet + README (shipped,
#                                    NOT applied — activation is
#                                    egresslock-setup --apparmor-add, ARC-22-D3)
#   /usr/lib/systemd/system/         egresslock-verify@.{service,timer}
#                                    (ExecStart rewritten to libdir)
#
# Maintainer scripts (ARC-22-D2): postinst retires the pre-ARC-16 global
# unit names, daemon-reloads and prints the next step — no timer enable,
# no AppArmor apply, no account touch. postrm daemon-reloads only; it
# never tears down Podman state, never deletes ~/.config/egresslock (not
# even on purge — ARC-7-D5), never removes the pasta local snippet.
#
# Every input comes from the kit root next to this script (the repo
# root since the EGL-1 flatten), so the packaging works unchanged if
# the kit moves to its own repo. The
# unit templates are in-tree kit assets since ARC-74-D5 — resolved as:
#   1. $EGRESSLOCK_UNIT_SRC (override)
#   2. <kit>/systemd            (the in-tree templates)
#
# Environment:
#   EGRESSLOCK_DEB_OUT=<path>     output .deb path (default:
#                            packaging/egresslock_<version>_all.deb
#                            next to this script; build artifacts are
#                            NOT committed)
#   EGRESSLOCK_DEB_KEEP_STAGE=<dir>  copy the staged tree here (tests:
#                            file-set asserts without building)
#   EGRESSLOCK_UNIT_SRC=<dir>     unit-template dir override (see above)
#
# Exit codes: 0 ok, 1 build failure, 2 usage/environment error.
set -euo pipefail

pkg_dir="$(cd "$(dirname "$0")" && pwd)"
kit="$(cd "$pkg_dir/.." && pwd)"
# Git checkout root holding the kit: the kit root IS the repo root since
# the EGL-1 flatten; a kit nested inside a checkout still resolves to
# that checkout's toplevel. No git at all -> the version fallback below
# reports 'unknown'.
repo="$(git -C "$kit" rev-parse --show-toplevel 2>/dev/null || echo "$kit")"

keep_stage="${EGRESSLOCK_DEB_KEEP_STAGE:-}"

# Runs as ANY user — nothing here writes outside the mktemp staging dir
# and the output path. dpkg-deb --root-owner-group records root
# ownership in the archive without fakeroot (R-022-2 follow-up: the
# install-kit-style root gate was over-conservative for a pure build).

# Version (ARC-22-D2, EGL-27-D1, EGL-72-D1/D2): <VERSION_BASE>+git<YYYYMMDDHHMMSS>.<short12>
# (VERSION_BASE is the one release base at the repo root — bump it once
# per release, never hard-code it here). All characters are legal in a
# Debian Version (alnum . + - ~).
# EGL-27: the UTC second-resolution timestamp is the dpkg ORDERING key
# (the old date-only prefix collided within a day, and hex commit hashes
# do not sort monotonically — a later rebuild could compare as a
# DOWNGRADE); the 12-char sha is identification only.
# EGL-72-D1: fail closed if VERSION_BASE is missing or empty.
[[ -s "$kit/VERSION_BASE" ]] || {
    echo "build-deb: FAIL - VERSION_BASE missing or empty at $kit/VERSION_BASE (EGL-72-D1)" >&2
    exit 2
}
base="$(tr -d ' \t\n' < "$kit/VERSION_BASE")"
[[ -n "$base" ]] || {
    echo "build-deb: FAIL - VERSION_BASE is empty (EGL-72-D1)" >&2
    exit 2
}
commit="$(git -C "$repo" rev-parse --short=12 HEAD 2>/dev/null || true)"
if [[ -z "$commit" ]]; then
    echo "build-deb: WARNING - not a git checkout; version falls back to 'unknown'" >&2
    commit=unknown
fi
if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
    commit="$commit-dirty"
fi
version="${base}+git$(date -u '+%Y%m%d%H%M%S').$commit"

# EGL-27-D2: operator signal when rebuilding on a host that already has
# an installed egresslock whose dpkg version is not older than this
# build (dpkg would keep the installed files). Warn only — builds must
# succeed without dpkg-query (tarball hosts / non-Debian containers).
echo "build-deb: version $version"
if installed="$(dpkg-query -W -f='${Version}' egresslock 2>/dev/null)" && [[ -n "$installed" ]]; then
    if dpkg --compare-versions "$installed" ge "$version" 2>/dev/null; then
        echo "build-deb: WARNING - installed egresslock $installed is not older than $version; dpkg would treat this build as a downgrade" >&2
    fi
fi

# Default artifact name carries the version (matches packaging/README.md
# and the maintainer's apt install sketch: apt install ./<name>.deb).
out="${EGRESSLOCK_DEB_OUT:-$pkg_dir/egresslock_${version}_all.deb}"

# Unit templates: in-tree (see header); no out-of-tree fallback.
unit_src="${EGRESSLOCK_UNIT_SRC:-$kit/systemd}"
for f in egresslock-verify@.service egresslock-verify@.timer; do
    [[ -f "$unit_src/$f" ]] || {
        echo "build-deb: unit template missing: $unit_src/$f" >&2
        exit 2
    }
done

for f in egresslock egresslock-start egresslock-verify egresslock-setup; do
    [[ -f "$kit/$f" ]] || { echo "build-deb: kit file missing: $kit/$f" >&2; exit 2; }
done
[[ -f "$kit/gateway/Containerfile" ]] || { echo "build-deb: gateway context missing: $kit/gateway" >&2; exit 2; }
[[ -f "$kit/examples/main.conf" && -f "$kit/examples/main-allowlist" ]] || {
    echo "build-deb: examples missing under $kit/examples" >&2
    exit 2
}
[[ -f "$kit/apparmor/usr.bin.pasta.local" ]] || { echo "build-deb: apparmor snippet missing" >&2; exit 2; }

stage="$(mktemp -d /tmp/egresslock-deb.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
root="$stage/egresslock"
libdir="$root/usr/lib/egresslock"
share="$root/usr/share/egresslock"

install -d -m 0755 "$root/DEBIAN" \
    "$root/usr/bin" "$root/usr/sbin" "$libdir" \
    "$root/usr/lib/systemd/system" \
    "$share/examples" "$share/doc" "$share/apparmor"

# Wrappers (staged tree ONLY — /opt/egresslock/egresslock stays a real
# script; the wrapper exists so $0/VERSION/gateway resolve next to the
# real scripts via BASH_SOURCE in libdir, ARC-22-D1).
cat > "$root/usr/bin/egresslock" <<'EOF'
#!/bin/sh
exec /usr/lib/egresslock/egresslock "$@"
EOF
cat > "$root/usr/sbin/egresslock-setup" <<'EOF'
#!/bin/sh
exec /usr/lib/egresslock/egresslock-setup "$@"
EOF
chmod 0755 "$root/usr/bin/egresslock" "$root/usr/sbin/egresslock-setup"

# Libdir kit.
install -m 0755 "$kit/egresslock"        "$libdir/egresslock"
install -m 0755 "$kit/egresslock-start"  "$libdir/egresslock-start"
install -m 0755 "$kit/egresslock-verify" "$libdir/egresslock-verify"
install -m 0755 "$kit/egresslock-setup"  "$libdir/egresslock-setup"
cp -R "$kit/gateway" "$libdir/gateway"
chmod -R go-w "$libdir/gateway"

# VERSION stamp (same shape install-kit.sh writes; libdir copy so the
# deployed binary and dpkg metadata agree, ARC-22-D2). EGL-72-D3: the
# stamp gains the full version string first.
{
    printf 'version: %s\n' "$version"
    printf 'commit: %s\n' "$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf 'deployed: '
    date -u '+%Y-%m-%dT%H:%M:%SZ'
} > "$libdir/VERSION"
chmod 0644 "$libdir/VERSION"

# Share data.
install -m 0644 "$kit/examples/main.conf"       "$share/examples/main.conf"
install -m 0644 "$kit/examples/main-allowlist"  "$share/examples/main-allowlist"
install -d -m 0755 "$share/examples/recipes"
for f in "$kit"/examples/recipes/*; do
    [[ -f "$f" ]] || continue
    # Site-name screen (see the doc loop below/above): a recipe that
    # carries fleet facts stays repo-only.
    if grep -q 'home\.arpa' "$f" 2>/dev/null; then
        echo "build-deb: skipping recipe with site names: $(basename "$f")" >&2
        continue
    fi
    install -m 0644 "$f" "$share/examples/recipes/$(basename "$f")"
done
chmod -R go-w "$share/examples/recipes"
# EGL-28: the docs/ tree ships structure-preserving (quickstart/setup/
# reference/troubleshooting tiers + the index); process files (tickets/,
# BOARD.md) and site-named docs never ship. README.md sits beside the
# tree at doc/README.md.
while IFS= read -r f; do
    # BOARD.md is generated ticket-process navigation (EGL-1 flatten:
    # the manuals share docs/ with docs/tickets/ + BOARD.md) — process
    # files never ship in the package.
    [[ "$(basename "$f")" == "BOARD.md" ]] && continue
    # ARC-22 verification: no site names in the package. A doc that
    # carries fleet facts is skipped (named on stderr) rather than
    # redacted here; the prefix deploy keeps shipping everything.
    if grep -q 'home\.arpa' "$f" 2>/dev/null; then
        echo "build-deb: skipping doc with site names: ${f#"$kit"/}" >&2
        continue
    fi
    rel="${f#"$kit"/}"
    mkdir -p "$share/doc/$(dirname "$rel")"
    install -m 0644 "$f" "$share/doc/$rel"
done < <(find "$kit/docs" -name '*.md' ! -path "$kit/docs/tickets/*" | sort)
install -m 0644 "$kit/README.md" "$share/doc/README.md"
install -m 0644 "$kit/apparmor/usr.bin.pasta.local" "$share/apparmor/usr.bin.pasta.local"
install -m 0644 "$kit/apparmor/README.md" "$share/apparmor/README.md"

# Unit templates with the LIBDIR ExecStart (ARC-22-D1): the .deb has no
# configurable prefix, so the placeholder is substituted at build time.
sed "s|__EGRESSLOCK_PREFIX__|/usr/lib/egresslock|g" \
    "$unit_src/egresslock-verify@.service" \
    > "$root/usr/lib/systemd/system/egresslock-verify@.service"
chmod 0644 "$root/usr/lib/systemd/system/egresslock-verify@.service"
install -m 0644 "$unit_src/egresslock-verify@.timer" \
    "$root/usr/lib/systemd/system/egresslock-verify@.timer"

# Package control + maintainer scripts (ARC-22-D2).
cat > "$root/DEBIAN/control" <<EOF
Package: egresslock
Version: $version
Section: net
Priority: optional
Architecture: all
Depends: bash, podman, netavark, nftables
Recommends: apparmor
Maintainer: egresslock maintainers <onyxcoyote@users.noreply.github.com>
Description: restricted egress for agent accounts (rootless podman + nftables + squid)
 Per-profile bridge networks with a fail-closed nftables policy in the
 shared rootless netns, a squid gateway, and a periodic drift-check
 timer. Thin packaging convenience; the checkout + install-kit.sh
 prefix deploy remains the primary path.
EOF

cat > "$root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
# ARC-22-D2: reload, retire the pre-ARC-16 global unit names (same as
# install-kit.sh, so an apt upgrade retires them too), print the next
# step. NO timer enable, NO AppArmor apply, NO account touch.
set -e
if [ -e /opt/egresslock/egresslock ]; then
    # ARC-22-D1: never run both installs at once on a host.
    echo "WARNING: a prefix kit also exists at /opt/egresslock — do not" >&2
    echo "  run both installs at once; remove one first (docs: /usr/share/egresslock/doc/upgrade.md)." >&2
fi
systemctl disable --now egresslock-verify.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/egresslock-verify.service \
      /etc/systemd/system/egresslock-verify.timer
systemctl disable --now 'agent-network-verify@*.timer' >/dev/null 2>&1 || true
rm -f /etc/systemd/system/agent-network-verify@.service \
      /etc/systemd/system/agent-network-verify@.timer \
      /etc/systemd/system/agent-network-verify.service \
      /etc/systemd/system/agent-network-verify.timer
systemctl daemon-reload || true
echo "egresslock installed. next step:"
echo "  sudo egresslock-setup --account <acct> --init-conf --enable"
echo "  sudo egresslock-setup --apparmor-check  # confirm pasta AppArmor compatibility on this host"
exit 0
EOF

cat > "$root/DEBIAN/postrm" <<'EOF'
#!/bin/sh
# ARC-22-D2: dpkg removes the package files; we only reload systemd.
# Deliberately NOT done here (ARC-7-D5): teardown, podman rm, deleting
# ~/.config/egresslock (not even on purge), removing the pasta local
# snippet (host policy; see /usr/share/egresslock/apparmor/README.md).
set -e
systemctl daemon-reload || true
exit 0
EOF
chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

# Guard: no site names in the package (ARC-22 verification).
if grep -RIl 'home\.arpa' "$root/usr" "$root/DEBIAN" >/dev/null 2>&1; then
    echo "build-deb: FAIL - site names leaked into the staged tree:" >&2
    grep -RIl 'home\.arpa' "$root/usr" "$root/DEBIAN" >&2 || true
    exit 1
fi

# Guard (EGL-47-D3): the maintainer-internal internal_docs/ (repo
# root) must never reach the package. The docs loop below/above is
# deliberately scoped to `find "$kit/docs"` — do NOT widen it to
# `$kit`; this tripwire catches a widened copy if one ever appears.
if find "$root" -name 'internal_docs' | grep -q .; then
    echo "build-deb: FAIL - internal_docs leaked into the staged tree:" >&2
    find "$root" -name 'internal_docs' >&2 || true
    exit 1
fi

if [[ -n "$keep_stage" ]]; then
    rm -rf "$keep_stage"
    mkdir -p "$(dirname "$keep_stage")"
    cp -R "$root" "$keep_stage"
    echo "build-deb: staged tree copied to $keep_stage (not built)"
    exit 0
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "build-deb: dpkg-deb not found; staged tree at $stage (kept)" >&2
    trap - EXIT
    exit 2
fi

mkdir -p "$(dirname "$out")"
# --root-owner-group: correct root ownership without a real fakeroot.
dpkg-deb --root-owner-group --build "$root" "$out" >/dev/null
# EGL-49-D1: dpkg-deb writes with the build host's umask; a
# non-other-readable .deb makes `apt install ./file.deb` fall back to
# "Download is performed unsandboxed as root" (the _apt sandbox user
# cannot read it) — noisy on every install. The deb is a distributable
# artifact with no secrets (ARC-22 site-name screen guards content), so
# a+r is safe. a+r keeps owner bits (not 644) and is idempotent under
# umask 022.
chmod a+r "$out"
echo "build-deb: built $out (version $version)"
