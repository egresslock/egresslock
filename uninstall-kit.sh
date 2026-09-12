#!/usr/bin/env bash
#
# uninstall-kit.sh — remove the shared network-profile kit and its
# instanced verify units (inverse of install-kit.sh).
#
# Run as ROOT, from a checkout of this repository:
#   sudo ./uninstall-kit.sh --prefix /opt/egresslock \
#        --account runner
#
# What it does:
#   1. Stops/disables egresslock-verify@<account>.timer for each
#      --account.
#   2. Removes the instanced unit templates and the installed kit from
#      --prefix (egresslock, egresslock-start, egresslock-verify,
#      egresslock-setup, gateway/, examples/, VERSION), then daemon-reloads.
#      The PRE-RENAME unit names are swept the same way
#      install-kit.sh does (agent-network-verify@.* templates + enabled
#      instances + the legacy globals), and a leftover pre-rename
#      prefix (/opt/agent-network, marker-guarded) is removed too.
#
# What it deliberately does NOT touch (account-owned):
#   - ~/.config/egresslock/ and the pre-rename ~/.config/agent-network/
#     (conf, allowlist, unit.env) — operator runtime state. Pass
#     --purge-account-data to remove both.
#   - Podman state: anchor/gateway containers, networks, images. The
#     uninstaller never runs podman. Teardown is the
#     account's job, run while the engine still exists:
#       egresslock teardown --runtime
#     (as the account; no conf needed — it sweeps kit containers and
#     networks of BOTH name generations. If the engine is
#     already gone, reinstall the kit and run `teardown --runtime` to
#     recover the leftovers.)
#
# Options:
#   --prefix <path>         kit prefix to remove (default:
#                           /opt/egresslock)
#   --account <name>        account whose verify timer to stop/disable;
#                           repeatable; every enabled instance of the
#                           timer is also swept regardless of --account
#   --purge-account-data    also delete each account's
#                           ~/.config/egresslock AND the pre-rename
#                           ~/.config/agent-network (policy configs);
#                           Podman state is NEVER touched
#   -h, --help              print this help
#
# Environment (test hooks; the mock harness runs non-root):
#   EGRESSLOCK_KIT_ALLOW_NON_ROOT=1   allow non-root runs (tests only)
#   EGRESSLOCK_UNIT_DIR=<dir>         remove unit templates here
#                                (default: /etc/systemd/system)
#   EGRESSLOCK_ACCOUNT_HOME=<dir>     account home in non-root test mode
#   EGRESSLOCK_LEGACY_PREFIX=<dir>    pre-rename kit prefix to sweep
#                                (default: /opt/agent-network)
#   EGRESSLOCK_PATH_BINDIR=<dir>     PATH wrapper dir for the engine
#                                (default: /usr/local/bin; removes only
#                                THIS prefix's wrappers)
#   EGRESSLOCK_PATH_SBINDIR=<dir>    PATH wrapper dir for
#                                egresslock-setup (default:
#                                /usr/local/sbin)
#
# Defaults that are not parameter-changeable:
#   - a kit prefix (new or pre-rename) is rm -rf'd ONLY when it carries
#     kit markers (egresslock/agent-profiles or VERSION) — a marker-less
#     dir is warned and kept
#   - account data (conf, allowlist, unit.env) is preserved by default;
#     only --purge-account-data removes it (both confdirs)
#   - Podman state (anchors/gateways/networks/images) is never touched;
#     run `egresslock teardown --runtime` as the account, while the
#     engine still exists
#
# Exit codes: 0 ok, 1 preflight failure (non-root, unknown account),
#   2 usage/environment error.

set -euo pipefail

prefix="/opt/egresslock"
accounts=()
purge_account_data=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)  [[ $# -ge 2 ]] || { echo "uninstall-kit: missing value for --prefix" >&2; exit 2; }
                   prefix="$2"; shift 2 ;;
        --account) [[ $# -ge 2 ]] || { echo "uninstall-kit: missing value for --account" >&2; exit 2; }
                   accounts+=("$2"); shift 2 ;;
        --purge-account-data) purge_account_data=1; shift ;;
        -h|--help) awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        *) echo "uninstall-kit: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Testability hook (mirror of install-kit.sh): fail closed outside tests.
[[ "$(id -u)" == 0 || "${EGRESSLOCK_KIT_ALLOW_NON_ROOT:-0}" == 1 ]] || {
    echo "uninstall-kit: must run as root (sudo)" >&2
    exit 1
}
for acct in "${accounts[@]:-}"; do
    [[ -n "$acct" ]] || continue
    id "$acct" >/dev/null 2>&1 || { echo "uninstall-kit: no such account: $acct" >&2; exit 1; }
done

# 1. Stop/disable the per-account timers (D2: conservative, explicit).
for acct in "${accounts[@]:-}"; do
    [[ -n "$acct" ]] || continue
    systemctl disable --now "egresslock-verify@$acct.timer" 2>/dev/null || true
done
# R-017-1 F4: an installed-but-unnamed account would otherwise keep a
# stale wants-symlink pointing at the removed template — disable every
# enabled instance of the timer, not just the named ones.
systemctl list-unit-files 'egresslock-verify@*.timer' --no-legend 2>/dev/null \
    | awk '{ print $1 }' \
    | xargs -r systemctl disable --now 2>/dev/null || true

# 2. Remove the instanced templates and the deployed kit.
unit_dest="${EGRESSLOCK_UNIT_DIR:-/etc/systemd/system}"
rm -f "$unit_dest/egresslock-verify@.service" \
      "$unit_dest/egresslock-verify@.timer"
# ARC-60-D3: sweep the PRE-RENAME unit names too, exactly like
# install-kit.sh does (agent-network-verify@.* templates + enabled
# instances, plus the pre-ARC-16 globals), so no old timer can survive
# an uninstall. Never fatal if they were never installed.
systemctl disable --now 'agent-network-verify@*.timer' 2>/dev/null || true
rm -f "$unit_dest/agent-network-verify@.service" \
      "$unit_dest/agent-network-verify@.timer"
rm -f "$unit_dest/agent-network-verify.service" \
      "$unit_dest/agent-network-verify.timer"
systemctl disable --now egresslock-verify.timer 2>/dev/null || true
rm -f "$unit_dest/egresslock-verify.service" \
      "$unit_dest/egresslock-verify.timer"
# R-017-1 F5: only rm -rf a directory that actually IS a kit prefix
# (marker files), never a bare/mis-resolved path.
if [[ -d "$prefix" && ( -f "$prefix/egresslock" || -f "$prefix/VERSION" ) ]]; then
    rm -rf "$prefix"
elif [[ -e "$prefix" ]]; then
    echo "uninstall-kit: WARNING - $prefix exists but has no kit markers; not removing" >&2
fi

# EGL-43-D4: remove THIS prefix's PATH wrappers only — the marker
# comment on line 2 carries the prefix, so another prefix's wrappers and
# a deb-owned /usr/bin/egresslock are left alone. Same dir hooks as
# install-kit.sh (EGRESSLOCK_PATH_BINDIR / EGRESSLOCK_PATH_SBINDIR).
path_bindir="${EGRESSLOCK_PATH_BINDIR:-/usr/local/bin}"
path_sbindir="${EGRESSLOCK_PATH_SBINDIR:-/usr/local/sbin}"
for _wdest in "$path_bindir/egresslock" "$path_sbindir/egresslock-setup"; do
    [[ -e "$_wdest" ]] || continue
    _wmarker="$(sed -n '2p' "$_wdest" 2>/dev/null || true)"
    if [[ "$_wmarker" == "# egresslock-path-wrapper prefix=$prefix" ]]; then
        rm -f "$_wdest"
        echo "uninstall-kit: removed PATH wrapper $_wdest"
    fi
done
# ARC-60-D3: the pre-rename prefix, same marker guard as above (old kit
# markers: agent-profiles or VERSION). A marker-less dir is warned and
# kept, never silently destroyed (ARC-47-D3).
legacy_prefix="${EGRESSLOCK_LEGACY_PREFIX:-/opt/agent-network}"
if [[ "$legacy_prefix" != "$prefix" ]]; then
    if [[ -d "$legacy_prefix" \
          && ( -f "$legacy_prefix/agent-profiles" || -f "$legacy_prefix/VERSION" ) ]]; then
        rm -rf "$legacy_prefix"
        echo "uninstall-kit: removed leftover pre-rename kit at $legacy_prefix"
    elif [[ -e "$legacy_prefix" ]]; then
        echo "uninstall-kit: WARNING - $legacy_prefix exists but has no pre-rename kit markers; not removing" >&2
    fi
fi
systemctl daemon-reload

# 3. Account data: preserved unless explicitly purged.
for acct in "${accounts[@]:-}"; do
    [[ -n "$acct" ]] || continue
    # EGRESSLOCK_ACCOUNT_HOME overrides the passwd lookup (mock harness);
    # guard against a bogus resolution ever purging the wrong tree.
    home="$(getent passwd "$acct" | cut -d: -f6)"
    [[ -n "${EGRESSLOCK_ACCOUNT_HOME:-}" ]] && home="$EGRESSLOCK_ACCOUNT_HOME"
    if [[ -z "$home" || "$home" == "/" || ! -d "$home" ]]; then
        echo "uninstall-kit: refusing account-data handling for '$acct' (unresolved home '$home')" >&2
        continue
    fi
    if (( purge_account_data )); then
        # ARC-60-D3: purge BOTH confdirs — the pre-rename tree must not
        # outlive the kit either.
        for cdir in "$home/.config/egresslock" "$home/.config/agent-network"; do
            [[ -e "$cdir" ]] || continue
            rm -rf "$cdir"
            echo "uninstall-kit: purged $cdir (account data)"
        done
    else
        # ARC-60-D3: the reminder names `teardown --runtime` (no conf,
        # both generations), run as the account while the engine still
        # exists — `teardown all` is conf-scoped and the conf may be gone.
        [[ -e "$home/.config/egresslock" ]] && \
            echo "uninstall-kit: kept $home/.config/egresslock (account-owned policy data; Podman state untouched — run 'egresslock teardown --runtime' as the account, while the engine still exists, to remove kit containers/networks)"
        [[ -e "$home/.config/agent-network" ]] && \
            echo "uninstall-kit: kept $home/.config/agent-network (pre-rename account data; mv it to $home/.config/egresslock or purge with --purge-account-data)"
    fi
done

echo "uninstall-kit: kit removed from $prefix; instanced templates removed; timers stopped"
