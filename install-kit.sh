#!/usr/bin/env bash
#
# install-kit.sh — deploy the shared network-profile kit and the
# instanced verify unit templates (kit layer).
#
# Run as ROOT, from a checkout of this repository:
#   sudo ./install-kit.sh
#   sudo ./install-kit.sh --prefix /opt/egresslock
#
# What it does:
#   1. Deploys the shared, ROOT-OWNED kit to --prefix (default
#      /opt/egresslock): egresslock (engine), egresslock-start
#      (wrapper), egresslock-verify (timer entry), egresslock-setup
#      (per-account bootstrap), gateway/ (image build context),
#      examples/ (starter conf + empty allowlist for egresslock-setup
#      --init-conf, recipes/, egl-base/), apparmor/ (pasta snippet for
#      --apparmor-add), and a VERSION stamp (version string + deployed
#      commit SHA + UTC date). This is the ONLY thing accounts share.
#   1b. Installs PATH wrappers: /usr/local/bin/egresslock and
#      /usr/local/sbin/egresslock-setup exec the deployed prefix copies,
#      so the bare command works on prefix installs the way the .deb
#      does. Marker-guarded; refused (rc 1) when the .deb is installed
#      or the dest is a foreign file. An unwritable PATH dir warns and
#      skips.
#   2. Installs the instanced unit templates egresslock-verify@.service
#      and egresslock-verify@.timer into /etc/systemd/system/.
#
# It does NOT touch accounts: per-account timers are enabled by
# `egresslock-setup init --enable` at account setup, AFTER the account's
# unit.env exists — never as a vacuous enable at install time.
# Account-owned data (conf, allowlist, unit.env, gateway image) is NOT
# installed here either: accounts execute, root distributes.
#
# Options:
#   --prefix <path>   deploy the kit here (default: /opt/egresslock)
#   -h, --help        print this help
#
# Environment (test hooks; the mock harness runs non-root):
#   EGRESSLOCK_KIT_ALLOW_NON_ROOT=1   allow non-root runs (tests only)
#   EGRESSLOCK_APPARMOR_PROFILES=<f>  kernel profiles listing to probe
#                                for the podman AppArmor label advisory
#                                (default:
#                                /sys/kernel/security/apparmor/profiles;
#                                same hook/ERE as egresslock-setup)
#   EGRESSLOCK_UNIT_DIR=<dir>         install unit templates here
#                                (default: /etc/systemd/system)
#   EGRESSLOCK_PATH_BINDIR=<dir>     PATH wrapper dir for the engine
#                                (default: /usr/local/bin)
#   EGRESSLOCK_PATH_SBINDIR=<dir>    PATH wrapper dir for
#                                egresslock-setup (default:
#                                /usr/local/sbin)
#
# Defaults that are not parameter-changeable:
#   - deployed kit file set: egresslock, egresslock-start,
#     egresslock-verify, egresslock-setup, gateway/, examples/ (starter
#     conf + allowlist + recipes/ incl. the container example +
#     egl-base/), apparmor/ (pasta snippet), VERSION (all root-owned)
#   - unit template names: egresslock-verify@.{service,timer}
#   - the installed unit template's ExecStart is rewritten with the
#     deployed prefix at install time
#
# Exit codes: 0 ok, 1 preflight failure, 2 usage error.

set -euo pipefail

prefix="/opt/egresslock"
src="$(cd "$(dirname "$0")" && pwd)"
# Kit root = the script's own directory: the kit files always live
# beside it (repo root or extracted tarball). Git facts (the VERSION
# stamp) resolve from the checkout toplevel when the kit is a git checkout.
repo="$(git -C "$src" rev-parse --show-toplevel 2>/dev/null || echo "$src")"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)  [[ $# -ge 2 ]] || { echo "install-kit: missing value for --prefix" >&2; exit 2; }
                   prefix="$2"; shift 2 ;;
        -h|--help) awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        *) echo "install-kit: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# EGL-90-D1 (audit I-02/I-03): validate the --prefix path shape at parse.
# It must be absolute and charset-clean (^/[A-Za-z0-9._/-]+$ under
# LC_ALL=C, no //, /./ or /../ segment, never /, ., or ..), with no
# whitespace: systemd splits the substituted ExecStart on whitespace, and
# the PATH wrapper embeds the prefix into an sh file, so metacharacters
# are either a broken install or code-exec in the wrapper. Fail closed
# rc 2 rather than half-install. Same rule as uninstall-kit.sh
# (EGL-89-D1); duplicated by design, not a shared library.
_check_kit_path_shape() {
    local p="$1" bad=0
    if [[ "$p" == "/" || "$p" == "." || "$p" == ".." ]]; then
        bad=1
    elif [[ "$p" != /* ]]; then
        bad=1
    elif [[ "$p" == *[[:space:]]* ]]; then
        # ARC-49-D3 (subsumed by the charset, kept explicit): a newline
        # would also smuggle a second operand past the line-anchored
        # charset grep below, and systemd ExecStart splits on whitespace
        bad=1
    elif ! LC_ALL=C grep -qE '^/[A-Za-z0-9._/-]+$' <<<"$p"; then
        bad=1
    elif [[ "$p" == *"//"* || "$p" == *"/./"* || "$p" == *"/../"* \
            || "$p" == *"/." || "$p" == *"/.." ]]; then
        bad=1
    fi
    if (( bad )); then
        echo "install-kit: --prefix must be an absolute kit path (no relative/./.., whitespace, or metacharacters; got: $p)" >&2
        exit 2
    fi
}
_check_kit_path_shape "$prefix"

# Testability hook: the mock harness runs as non-root. Fail closed
# outside tests.
[[ "$(id -u)" == 0 || "${EGRESSLOCK_KIT_ALLOW_NON_ROOT:-0}" == 1 ]] || {
    echo "install-kit: must run as root (sudo)" >&2
    exit 1
}

# EGL-68-D1 / EGL-90-D3: never rm -rf through a mistyped --prefix. The
# install replaces gateway/, apparmor/, examples/recipes/ and
# examples/egl-base/. Deleting one is allowed only when it is absent
# (first install), $prefix carries a kit marker (VERSION or the
# egresslock executable), or the path is kit-shaped
# (gateway/Containerfile). Otherwise fail closed before any copy, naming
# the path. EGL-265 item 4: keep this list in lockstep with the loop.
for _dest in "$prefix/gateway" "$prefix/apparmor" \
             "$prefix/examples/recipes" "$prefix/examples/egl-base"; do
    if [[ ! -e "$_dest" ]]; then
        continue                                   # first install
    fi
    if [[ -f "$prefix/VERSION" || -x "$prefix/egresslock" \
          || -f "$prefix/gateway/Containerfile" ]]; then
        continue              # reinstall over this kit's deploy / kit-shaped
    fi
    echo "install-kit: FAIL - refusing to delete $_dest" >&2
    echo "  $prefix has no kit marker (VERSION, egresslock executable) and" >&2
    echo "  the dest path is not kit-shaped (no gateway/Containerfile): a mistyped" >&2
    echo "  --prefix would destroy a foreign tree. Remove it or name the real kit prefix." >&2
    exit 1
done
unset _dest

# EGL-72-D1: the release base lives in one VERSION_BASE at the kit root
# (repo root or extracted tarball). Fail closed BEFORE any copy if it
# is missing or empty — a versionless deploy is not deployable.
[[ -s "$src/VERSION_BASE" ]] || {
    echo "install-kit: FAIL - VERSION_BASE missing or empty at $src/VERSION_BASE (a versionless deploy is not deployable)" >&2
    exit 1
}
base="$(tr -d ' \t\n' < "$src/VERSION_BASE")"
[[ -n "$base" ]] || {
    echo "install-kit: FAIL - VERSION_BASE is empty (a versionless deploy is not deployable)" >&2
    exit 1
}

# EGL-102-D6-R2: the whole source set must exist BEFORE any copy. A
# mid-deploy `install: cannot stat` used to leave a partial prefix
# (binaries or templates missing, no next action); this gate fails
# closed naming the missing files, before anything is written.
_kit_missing=""
# EGL-102-D6-F3: cover the WHOLE unconditional copy list (binaries,
# gateway/, apparmor/, examples incl. recipes/, unit templates). Keep
# this list in lockstep with the copy list: the EGL-47-D3 tripwire
# below guards the shipped set, this guards the copied set.
for _src in egresslock egresslock-start egresslock-verify egresslock-setup \
            gateway/Containerfile gateway/entrypoint.sh gateway/squid.conf \
            apparmor/usr.bin.pasta.local apparmor/README.md \
            examples/main.conf examples/main-allowlist examples/recipes \
            examples/egl-base/Containerfile examples/egl-base/build-egl-base; do
    [[ -e "$src/$_src" ]] || _kit_missing+="$_src "
done
if [[ -n "${EGRESSLOCK_UNIT_SRC:-}" ]]; then
    _unit_src_chk="$EGRESSLOCK_UNIT_SRC"
else
    _unit_src_chk="$src/systemd"
fi
for _ut in egresslock-verify@.service egresslock-verify@.timer; do
    [[ -f "$_unit_src_chk/$_ut" ]] || _kit_missing+="systemd/$_ut "
done
if [[ -n "$_kit_missing" ]]; then
    echo "install-kit: FAIL - incomplete kit tree at $src (missing: ${_kit_missing% })" >&2
    echo "  restore the full checkout or re-extract the release tarball, then re-run; nothing was written." >&2
    exit 1
fi
unset _kit_missing _src _unit_src_chk _ut

# EGL-72-D3: the version line. A tarball install carries KIT_VERSION
# (written by build-tarball.sh) so the deployed stamp is the BUILD
# version; a checkout install synthesizes it from VERSION_BASE + git.
# The install-time timestamp is expected there.
kit_version=""
if [[ -f "$src/KIT_VERSION" ]]; then
    kit_version="$(tr -d ' \t\n' < "$src/KIT_VERSION")"
fi
if [[ -z "$kit_version" ]]; then
    vcommit="$(git -C "$repo" rev-parse --short=12 HEAD 2>/dev/null || true)"
    if [[ -z "$vcommit" ]]; then
        echo "install-kit: WARNING - cannot determine a git commit for the version;" \
            "falls back to '${base}+git<ts>.unknown'" >&2
        vcommit=unknown
    fi
    if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
        vcommit="$vcommit-dirty"
    fi
    kit_version="${base}+git$(date -u '+%Y%m%d%H%M%S').$vcommit"
fi

# 1. Shared kit — root:root, the only shared copy (ARC-16-D6: gateway
#    build context ships with the kit so accounts build from the PREFIX,
#    not a checkout).
install -d -m 0755 "$prefix"
install -m 0755 "$src/egresslock"      "$prefix/egresslock"
install -m 0755 "$src/egresslock-start" "$prefix/egresslock-start"
install -m 0755 "$src/egresslock-verify"      "$prefix/egresslock-verify"
install -m 0755 "$src/egresslock-setup"    "$prefix/egresslock-setup"
cp -R "$src/gateway" "$prefix/gateway.tmp"
rm -rf "$prefix/gateway"
mv "$prefix/gateway.tmp" "$prefix/gateway"
chmod -R go-w "$prefix/gateway"
# EGL-69-D2: the pasta AppArmor snippet ships with the prefix
# (root-owned, like gateway/) so `sudo $prefix/egresslock-setup
# --apparmor-add` works on prefix installs. Shipping is distribution;
# applying stays explicit --apparmor-add only (ARC-22-D3).
cp -R "$src/apparmor" "$prefix/apparmor.tmp"
rm -rf "$prefix/apparmor"
mv "$prefix/apparmor.tmp" "$prefix/apparmor"
chmod -R go-w "$prefix/apparmor"
# ARC-19-D3: starter conf + empty allowlist for egresslock-setup
# --init-conf. Root-owned, never installed into account homes.
# Recipes and egl-base ship too so accounts can build from the PREFIX
# without a checkout (same rationale as the gateway context, ARC-16-D6).
install -d -m 0755 "$prefix/examples"
install -m 0644 "$src/examples/main.conf"       "$prefix/examples/main.conf"
install -m 0644 "$src/examples/main-allowlist" "$prefix/examples/main-allowlist"
cp -R "$src/examples/recipes" "$prefix/examples/recipes.tmp"
rm -rf "$prefix/examples/recipes"
mv "$prefix/examples/recipes.tmp" "$prefix/examples/recipes"
chmod -R go-w "$prefix/examples/recipes"
# EGL-232: the shared example base image (egl-base) ships too so the
# quickstarts can build it without a checkout (same rationale as the
# recipes and the gateway context above).
cp -R "$src/examples/egl-base" "$prefix/examples/egl-base.tmp"
rm -rf "$prefix/examples/egl-base"
mv "$prefix/examples/egl-base.tmp" "$prefix/examples/egl-base"
chmod -R go-w "$prefix/examples/egl-base"

# EGL-47-D3: the deployed file set is the explicit copy list above —
# repo-internal material (internal_docs/, maintainer notes) is NOT in
# it and must never be added. Tripwire: fail closed if a widened copy
# rule ever sweeps it in.
if [[ -e "$prefix/internal_docs" ]]; then
    echo "install-kit: FAIL - internal_docs leaked into the prefix" >&2
    exit 1
fi
commit="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
if [[ -z "$commit" ]]; then
    echo "install-kit: WARNING - cannot determine deployed commit" \
        "(checkout at $repo is not a git repo?); VERSION says 'unknown'" >&2
    commit=unknown
fi
# R-016-1 F4: a dirty checkout would deploy modified content under an
# unmodified stamp; mark it so the stamp is honest.
if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
    commit="$commit-dirty"
fi
{
    printf 'version: %s\n' "$kit_version"
    printf 'commit: %s\n' "$commit"
    printf 'deployed: '
    date -u '+%Y-%m-%dT%H:%M:%SZ'
} > "$prefix/VERSION"
chmod 0644 "$prefix/VERSION"

# 1b. PATH wrappers (EGL-43): the .deb ships /usr/bin wrappers, but a
#     prefix deploy had none, so bare `egresslock` (the root-guard
#     guidance, EGL-31) failed command-not-found. D1: an sh wrapper with
#     an absolute exec (never a symlink); line 2 is the marker comment so
#     upgrade (D3) and uninstall (D4) touch only this prefix's wrappers.
#     Two names only: engine + egresslock-setup; start/verify are invoked
#     by the installed units' rewritten ExecStart. D3: refuse co-install
#     with the .deb (ARC-22-D1) and never clobber a foreign dest.
#     EGL-80-L2: the deb-shape guard honours EGRESSLOCK_UB_BIN (default
#     /usr/bin/egresslock), so it is testable on hosts with the .deb.
path_bindir="${EGRESSLOCK_PATH_BINDIR:-/usr/local/bin}"
path_sbindir="${EGRESSLOCK_PATH_SBINDIR:-/usr/local/sbin}"
ub_bin="${EGRESSLOCK_UB_BIN:-/usr/bin/egresslock}"
deb_status="$(dpkg-query -W -f='${Status}' egresslock 2>/dev/null || true)"
if [[ "$deb_status" == *'installed'* ]]; then
    echo "install-kit: the egresslock .deb is installed on this host ($deb_status);" >&2
    echo "  never run both installs at once — 'apt remove egresslock' first." >&2
    exit 1
fi
# EGL-83-D2: dpkg-query can be missing or wrong (non-dpkg cleanup,
# foreign host) while the deb's libdir kit is still present. Refuse on
# the deb libdir's VERSION marker too (hookable for tests); never
# auto-remove the deb (same never-co-install policy as above).
deb_libdir="${EGRESSLOCK_DEB_LIBDIR:-/usr/lib/egresslock}"
if [[ -e "$deb_libdir/VERSION" ]]; then
    echo "install-kit: FAIL - an egresslock .deb kit exists at $deb_libdir" >&2
    echo "  (dpkg-query did not report an installed egresslock, but the libdir kit" >&2
    echo "  is present); never run both install channels. If dpkg still lists the" >&2
    echo "  package, remove it: 'apt remove egresslock'; otherwise remove the" >&2
    echo "  leftover kit dir: sudo rm -r $deb_libdir." >&2
    exit 1
fi
if [[ -e "$ub_bin" ]]; then
    _ub_marker="$(sed -n '2p' "$ub_bin" 2>/dev/null || true)"
    if [[ "$_ub_marker" != '# egresslock-path-wrapper prefix='* ]]; then
        echo "install-kit: $ub_bin exists and is not an egresslock kit PATH" >&2
        echo "  wrapper (deb shape?); remove it first — install-kit will not clobber it." >&2
        exit 1
    fi
fi
for _wl in "$path_bindir/egresslock:$prefix/egresslock" \
           "$path_sbindir/egresslock-setup:$prefix/egresslock-setup"; do
    _wdest="${_wl%%:*}"
    _wtarget="${_wl#*:}"
    _wdir="$(dirname "$_wdest")"
    if [[ -e "$_wdest" ]]; then
        _wmarker="$(sed -n '2p' "$_wdest" 2>/dev/null || true)"
        if [[ "$_wmarker" == "# egresslock-path-wrapper prefix=$prefix" ]]; then
            : # this prefix's own wrapper — upgrade, overwrite below
        elif [[ "$_wmarker" == '# egresslock-path-wrapper prefix='* ]]; then
            echo "install-kit: $_wdest wraps a DIFFERENT prefix; two prefix installs" >&2
            echo "  must not fight over PATH. Remove one first." >&2
            exit 1
        else
            echo "install-kit: $_wdest exists and is not an egresslock PATH wrapper;" >&2
            echo "  not clobbering it — remove it first if it is stale." >&2
            exit 1
        fi
    fi
    # EGL-90-D1.2 (audit I-03): the exec target is double-quoted so a
    # prefix can never become wrapper code even if a future regression
    # reintroduces a permissive charset. The line-2 marker stays unquoted
    # (`prefix=$prefix`) — EGL-43 uninstall matching and EGL-90's charset
    # make that safe.
    if printf '#!/bin/sh\n# egresslock-path-wrapper prefix=%s\nexec "%s" "$@"\n' \
            "$prefix" "$_wtarget" > "$_wdest" 2>/dev/null \
            && chmod 0755 "$_wdest" 2>/dev/null; then
        echo "PATH wrapper installed: $_wdest -> $_wtarget"
    else
        # Unwritable PATH dir (read-only /usr, unusual setups): warn and
        # continue — the wrappers are a convenience, the prefix kit is
        # the deploy. The kit itself is already fully installed above.
        echo "install-kit: WARNING - cannot install PATH wrapper at $_wdest" >&2
        echo "  (unwritable dir?); the bare command stays available as $_wtarget" >&2
    fi
done

# 2. Instanced unit templates (instance = account, ARC-16-D1/D8).
#    Destination overridable for the mock harness (non-root tests).
#    R-017-1 F1: the ExecStart prefix placeholder is substituted HERE so
#    a non-default --prefix yields a working timer; the repo template
#    keeps the __EGRESSLOCK_PREFIX__ placeholder.
unit_dest="${EGRESSLOCK_UNIT_DIR:-/etc/systemd/system}"
# ARC-22, tightened for the repo split (ARC-74-D5): the unit templates
# are kit assets inside the egresslock tree, so a self-contained kit tree
# deploys with no shared-repo layout. Only EGRESSLOCK_UNIT_SRC (override)
# or $src/systemd are consulted; there is no fallback outside the tree.
if [[ -n "${EGRESSLOCK_UNIT_SRC:-}" ]]; then
    unit_src="${EGRESSLOCK_UNIT_SRC}"
else
    unit_src="$src/systemd"
fi
[[ -f "$unit_src/egresslock-verify@.service" && -f "$unit_src/egresslock-verify@.timer" ]] || {
    echo "install-kit: unit templates missing under $unit_src" >&2
    exit 1
}
mkdir -p "$unit_dest"
sed "s|__EGRESSLOCK_PREFIX__|$prefix|g" "$unit_src/egresslock-verify@.service" \
    > "$unit_dest/egresslock-verify@.service"
chmod 0644 "$unit_dest/egresslock-verify@.service"
install -m 0644 "$unit_src/egresslock-verify@.timer" "$unit_dest/"

systemctl daemon-reload

echo
echo "successfully installed! kit is at: $prefix"
echo "  $(tr '\n' ' ' < "$prefix/VERSION")"
echo
# EGL-39 / D39-2 surface 2: one-line AppArmor conditionality advisory
# (read-only; recommend, never auto-apply — ARC-22-D3). The ERE is
# shared with egresslock-setup podman_labeled() (D39-3): ANY mode in the
# kernel listing counts as labeled, including `(unconfined)` — the
# label, not the mode, is the discriminator (EGL-33); anchored so hat
# lines (`podman//…`) never match. Silence on UNKNOWN (missing or
# unreadable listing, grep rc 2): never claim "not needed" from an
# unknown state (EGL-22-D2).
_aa_profiles="${EGRESSLOCK_APPARMOR_PROFILES:-/sys/kernel/security/apparmor/profiles}"
if [[ -r "$_aa_profiles" ]]; then
    # grep rc: 0 = match (labeled), 1 = no match (unlabeled), 2 = read
    # error (UNKNOWN — silence). `|| grc=$?` keeps grep's real rc under
    # `set -e` (a `!`-negated if would leave the negation's status).
    _podman_grc=0
    grep -qE '^(podman|/usr/bin/podman) \([^)]*\)$' "$_aa_profiles" 2>/dev/null || _podman_grc=$?
    if (( _podman_grc == 0 )); then
        echo "AppArmor: podman labeled; confirm pasta compatibility: sudo $prefix/egresslock-setup apparmor check"
    elif (( _podman_grc == 1 )); then
        echo "AppArmor: this host's podman is not confined by AppArmor, so no extra AppArmor rule is needed — no action needed."
    fi
fi
echo
echo "next step — per-account setup (from the installed kit):"
echo "  sudo $prefix/egresslock-setup init --account <acct> --init-conf --enable"
echo "  (or --from <conf> to import a pair; import never overwrites a"
echo "  differing/torn dest — use import --force deliberately; the starter"
echo "  ships from examples/ only when the dest conf is missing)"
echo
echo "or try the engine directly:  $prefix/egresslock --help"
