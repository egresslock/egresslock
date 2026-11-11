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
#   EGRESSLOCK_KIT_ALLOW_NON_ROOT=1   allow non-root runs (tests only);
#                                test mode is off by default — only
#                                exactly 1 turns it on, and any other
#                                value (e.g. true) warns and leaves
#                                test mode off
#   EGRESSLOCK_APPARMOR_PROFILES=<f>  kernel profiles listing to probe
#                                for the podman AppArmor label advisory
#                                (default:
#                                /sys/kernel/security/apparmor/profiles;
#                                requires EGRESSLOCK_KIT_ALLOW_NON_ROOT=1;
#                                same hook/ERE as egresslock-setup)
#   EGRESSLOCK_UNIT_DIR=<dir>         install unit templates here in test mode
#                                (default: /etc/systemd/system; requires
#                                EGRESSLOCK_KIT_ALLOW_NON_ROOT=1)
#   EGRESSLOCK_UNIT_SRC=<dir>         unit template source in test mode
#                                (default: the kit's systemd/; requires
#                                EGRESSLOCK_KIT_ALLOW_NON_ROOT=1)
#   EGRESSLOCK_UB_BIN=<path>          deb-shape guard probe in test mode
#                                (default: /usr/bin/egresslock; requires
#                                EGRESSLOCK_KIT_ALLOW_NON_ROOT=1)
#   EGRESSLOCK_DEB_LIBDIR=<dir>       deb-libdir guard probe in test mode
#                                (default: /usr/lib/egresslock; requires
#                                EGRESSLOCK_KIT_ALLOW_NON_ROOT=1)
#   EGRESSLOCK_PATH_BINDIR=<dir>     PATH wrapper dir for the engine in test mode
#                                (default: /usr/local/bin; requires
#                                EGRESSLOCK_KIT_ALLOW_NON_ROOT=1)
#   EGRESSLOCK_PATH_SBINDIR=<dir>    PATH wrapper dir for
#                                egresslock-setup in test mode (default:
#                                /usr/local/sbin; requires
#                                EGRESSLOCK_KIT_ALLOW_NON_ROOT=1)
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

# Testability hook: the mock harness runs non-root. This flag gates the
# harness hook reads that follow; without it each gated site uses its
# production default.
kit_test_mode() { [[ "${EGRESSLOCK_KIT_ALLOW_NON_ROOT:-0}" == 1 ]]; }

# EGL-491-D1/D2: a test-harness hook that is set without the test flag is
# discarded; say so once per name per invocation, on stderr only. The value
# is never echoed and rc/stdout stay unchanged.
egl491_warned_hooks=""
egl491_warn_ignored_hook() { # egl491_warn_ignored_hook <name> [value]
    local _name="$1" _value="${2:-}"
    if [[ -z "$_value" ]] || kit_test_mode; then
        return 0
    fi
    case " $egl491_warned_hooks " in
        *" $_name "*) return 0 ;;
    esac
    egl491_warned_hooks+=" $_name"
    echo "install-kit: WARNING - $_name is set but ignored: it is a test-harness override and requires EGRESSLOCK_KIT_ALLOW_NON_ROOT=1; the production default applies." >&2
}
# EGL-491-D4: the test flag's gate is the exact `== 1` predicate. Any other
# set value (including empty) leaves test mode off, so the hooks set
# alongside it are inert — warn once, presence-based, never echo the value.
if [[ -n "${EGRESSLOCK_KIT_ALLOW_NON_ROOT+x}" \
      && "${EGRESSLOCK_KIT_ALLOW_NON_ROOT-}" != 1 ]]; then
    echo "install-kit: WARNING - EGRESSLOCK_KIT_ALLOW_NON_ROOT is set but is not the exact value 1, so test mode is off; test-harness overrides are ignored." >&2
fi

prefix="/opt/egresslock"
src="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
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

# EGL-433-D3/D7: never operate through a symlinked --prefix. The guard below
# (and every copy after it) would otherwise read, delete, and deploy inside
# the referent; a stray `<link>/VERSION` would even pass the marker fence.
# Probe both spellings (the argument as passed and its one-trailing-slash
# form, whose -L is false) before the marker read and any copy. Do not
# rewrite --prefix: the PATH-wrapper marker embeds the argument as passed.
_kit_prefix_shape_ok() { # <path> — the parser's rule, without exiting
    local p="$1"
    [[ "$p" == /* && "$p" != "/" ]] || return 1
    [[ "$p" != *[[:space:]]* ]] || return 1
    LC_ALL=C grep -qE '^/[A-Za-z0-9._/-]+$' <<<"$p" || return 1
    [[ "$p" != *"//"* && "$p" != *"/./"* && "$p" != *"/../"* \
       && "$p" != *"/." && "$p" != *"/.." ]] || return 1
    return 0
}
# EGL-433-D8/F1: capture `readlink -z -f` without losing pathname bytes and
# without trusting a failed producer. Command substitution strips a trailing
# newline (naming a sibling); `<(…)` exposes only the read's status, not the
# producer's. Run the producer to a private file, keep its real exit status,
# and accept only rc 0 plus exactly one complete NUL record. Remove the file
# on every path; anything else is unresolvable (no retry is offered).
_kit_resolved() { # <var> <path> — returns 1 when unresolvable
    local _out="$1" _src="$2" _tmp _rc=0 _val="" _n _sz
    _tmp="$(mktemp "${TMPDIR:-/tmp}/egl433-readlink.XXXXXX")" || return 1
    readlink -z -f -- "$_src" >"$_tmp" 2>/dev/null || _rc=$?
    if (( _rc == 0 )) && IFS= read -r -d '' _val <"$_tmp"; then
        _n="$(printf '%s' "$_val" | wc -c)"
        _sz="$(wc -c <"$_tmp")"
        rm -f -- "$_tmp"
        if (( _sz == _n + 1 )); then
            printf -v "$_out" '%s' "$_val"
            return 0
        fi
        return 1
    fi
    rm -f -- "$_tmp"
    return 1
}
prefix_probe="$prefix"
[[ "$prefix_probe" == */ ]] && prefix_probe="${prefix_probe%/}"
if [[ -L "$prefix_probe" ]]; then
    printf -v q_prefix '%q' "$prefix"
    echo "install-kit: refusing: --prefix is a symbolic link: $q_prefix" >&2
    prefix_resolved=""
    if [[ -d "$prefix_probe" ]]; then
        _kit_resolved prefix_resolved "$prefix_probe" || prefix_resolved=""
    fi
    if [[ -z "$prefix_resolved" ]]; then
        echo "  the link does not resolve to a directory; pass the real kit prefix. nothing was written or removed." >&2
    elif _kit_prefix_shape_ok "$prefix_resolved"; then
        printf -v q_resolved '%q' "$prefix_resolved"
        echo "  pass the real directory the link points to (the installer does not follow the link); nothing was written or removed:" >&2
        echo "    sudo ./install-kit.sh --prefix $q_resolved" >&2
    else
        # D7: a retry command is offered only when its argument would pass
        # this tool's own --prefix rule; name the target, offer no command.
        printf -v q_resolved '%q' "$prefix_resolved"
        echo "  the link points to $q_resolved, which --prefix cannot name (only letters, digits, '.', '_', '-', and '/' are allowed); nothing was written or removed." >&2
    fi
    exit 2
fi
unset prefix_probe prefix_resolved q_prefix q_resolved

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
# this list in lockstep with the copy list below: this gate guards the
# copied set.
for _src in egresslock egresslock-start egresslock-verify egresslock-setup \
            gateway/Containerfile gateway/entrypoint.sh gateway/squid.conf \
            gateway/security-floor \
            apparmor/usr.bin.pasta.local apparmor/README.md \
            examples/main.conf examples/main-allowlist examples/recipes \
            examples/egl-base/Containerfile examples/egl-base/README.md \
            examples/egl-base/build-egl-base examples/egl-base/security-floor; do
    [[ -e "$src/$_src" ]] || _kit_missing+="$_src "
done
# EGL-456-D4: EGRESSLOCK_UNIT_SRC is a test-only hook. Resolve it once
# here (gated) and use the same value for the completeness check and the
# deploy; without the flag the kit's own systemd/ applies.
unit_src="$src/systemd"
if kit_test_mode && [[ -n "${EGRESSLOCK_UNIT_SRC:-}" ]]; then
    unit_src="$EGRESSLOCK_UNIT_SRC"
else
    egl491_warn_ignored_hook EGRESSLOCK_UNIT_SRC "${EGRESSLOCK_UNIT_SRC:-}"
fi
for _ut in egresslock-verify@.service egresslock-verify@.timer; do
    [[ -f "$unit_src/$_ut" ]] || _kit_missing+="systemd/$_ut "
done
if [[ -n "$_kit_missing" ]]; then
    echo "install-kit: FAIL - incomplete kit tree at $src (missing: ${_kit_missing% })" >&2
    echo "  restore the full checkout or re-extract the release tarball, then re-run; nothing was written." >&2
    exit 1
fi
unset _kit_missing _src _ut

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
# EGL-434-D1/D3: the PATH dirs are test-only hooks. Without the flag an
# inherited value is ignored and the production default is used, exactly
# as if the variable were unset.
path_bindir="/usr/local/bin"
path_sbindir="/usr/local/sbin"
if kit_test_mode; then
    if [[ -n "${EGRESSLOCK_PATH_BINDIR:-}" ]]; then path_bindir="$EGRESSLOCK_PATH_BINDIR"; fi
    if [[ -n "${EGRESSLOCK_PATH_SBINDIR:-}" ]]; then path_sbindir="$EGRESSLOCK_PATH_SBINDIR"; fi
else
    egl491_warn_ignored_hook EGRESSLOCK_PATH_BINDIR "${EGRESSLOCK_PATH_BINDIR:-}"
    egl491_warn_ignored_hook EGRESSLOCK_PATH_SBINDIR "${EGRESSLOCK_PATH_SBINDIR:-}"
fi
ub_bin="/usr/bin/egresslock"
# EGL-456-D4: the host-leftover guard fixtures are test-only hooks. Without
# the flag an inherited value is ignored and the production probe applies.
if kit_test_mode; then
    if [[ -n "${EGRESSLOCK_UB_BIN:-}" ]]; then ub_bin="$EGRESSLOCK_UB_BIN"; fi
else
    egl491_warn_ignored_hook EGRESSLOCK_UB_BIN "${EGRESSLOCK_UB_BIN:-}"
fi
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
deb_libdir="/usr/lib/egresslock"
if kit_test_mode; then
    if [[ -n "${EGRESSLOCK_DEB_LIBDIR:-}" ]]; then deb_libdir="$EGRESSLOCK_DEB_LIBDIR"; fi
else
    egl491_warn_ignored_hook EGRESSLOCK_DEB_LIBDIR "${EGRESSLOCK_DEB_LIBDIR:-}"
fi
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
        echo "PATH wrapper installed: $_wdest to $_wtarget"
    else
        # Unwritable PATH dir (read-only /usr, unusual setups): warn and
        # continue — the wrappers are a convenience, the prefix kit is
        # the deploy. The kit itself is already fully installed above.
        echo "install-kit: WARNING - cannot install PATH wrapper at $_wdest" >&2
        echo "  (unwritable dir?); the bare command stays available as $_wtarget" >&2
    fi
done

# 2. Instanced unit templates (instance = account, ARC-16-D1/D8).
#    Destination overridable for the mock harness (non-root tests) only;
#    EGL-434-D1/D3 gates the hook so a root run always uses /etc.
#    R-017-1 F1: the ExecStart prefix placeholder is substituted HERE so
#    a non-default --prefix yields a working timer; the repo template
#    keeps the __EGRESSLOCK_PREFIX__ placeholder.
unit_dest="/etc/systemd/system"
if kit_test_mode && [[ -n "${EGRESSLOCK_UNIT_DIR:-}" ]]; then
    unit_dest="$EGRESSLOCK_UNIT_DIR"
else
    egl491_warn_ignored_hook EGRESSLOCK_UNIT_DIR "${EGRESSLOCK_UNIT_DIR:-}"
fi
# ARC-22, tightened for the repo split (ARC-74-D5): the unit templates
# are kit assets inside the egresslock tree, so a self-contained kit tree
# deploys with no shared-repo layout. EGL-456-D4: unit_src was resolved
# once, gated, before the completeness check; this deploy uses that same
# value (no second raw hook read).
[[ -f "$unit_src/egresslock-verify@.service" && -f "$unit_src/egresslock-verify@.timer" ]] || {
    echo "install-kit: unit templates missing under $unit_src" >&2
    exit 1
}
mkdir -p "$unit_dest"
sed "s|__EGRESSLOCK_PREFIX__|$prefix|g" "$unit_src/egresslock-verify@.service" \
    > "$unit_dest/egresslock-verify@.service"
chmod 0644 "$unit_dest/egresslock-verify@.service"
install -m 0644 "$unit_src/egresslock-verify@.timer" "$unit_dest/"

# EGL-121: the reload only loads the verify timer templates; the kit is
# already deployed. On a host without systemd (no systemctl, or a binary
# with no reachable PID 1) a bare reload failed *after* the install and
# `set -e` skipped the success/advisory lines. Warn and continue (rc 0),
# same policy as packaging/build-deb.sh; the attempt itself is the check
# (a PATH pre-check would pass on a container/chroot/WSL host).
# Confirmed only on rc 0 with no captured output: systemd v257 logs
# `Running in chroot, ignoring command 'daemon-reload'` and exits 0 in a
# real chroot (or with SYSTEMD_OFFLINE=1), so an rc-only guard would hide
# that no-op; a noisy rc-0 reload is unconfirmed too. The captured text is
# not echoed — the named warning is the operator contract.
_reload_rc=0
_reload_out="$(systemctl daemon-reload 2>&1)" || _reload_rc=$?
if (( _reload_rc != 0 )) || [[ -n "$_reload_out" ]]; then
    echo "install-kit: WARNING - systemd did not confirm the unit-file reload; the verify timer templates are installed but may not be loaded." >&2
    echo "  An already-enabled verify timer may still run the previous unit definition; when systemd is available, run: systemctl daemon-reload" >&2
fi

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
# EGL-390-D2: the profiles override is a test-mode hook here. This
# advisory read is reached as root (production) or with the test flag;
# without the flag read the kernel listing, silently (EGL-382-D3 family).
_aa_profiles="/sys/kernel/security/apparmor/profiles"
if [[ "${EGRESSLOCK_KIT_ALLOW_NON_ROOT:-0}" == 1 ]]; then
    _aa_profiles="${EGRESSLOCK_APPARMOR_PROFILES:-$_aa_profiles}"
else
    egl491_warn_ignored_hook EGRESSLOCK_APPARMOR_PROFILES "${EGRESSLOCK_APPARMOR_PROFILES:-}"
fi
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
