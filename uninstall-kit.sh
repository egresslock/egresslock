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
#   1. Stops/disables egresslock-verify@ACCOUNT.timer for each
#      --account.
#   2. Removes the instanced unit templates and the installed kit from
#      --prefix (egresslock, egresslock-start, egresslock-verify,
#      egresslock-setup, gateway/, apparmor/, examples/, docs/, VERSION)
#      and this prefix's PATH wrappers, then daemon-reloads.
#
# What it deliberately does NOT touch (account-owned):
#   - ~/.config/egresslock/ (conf, allowlist) — operator
#     runtime state. Pass --purge-account-data to remove it.
#   - Podman state: anchor/gateway containers, networks, images. The
#     uninstaller never runs podman. Teardown is the
#     account's job, run while the engine still exists:
#       egresslock teardown all --yes
#       egresslock teardown --orphans
#     (as the account; `all` tears down every configured profile, then
#     `--orphans` sweeps kit objects whose conf is already gone — no
#     conf needed. If the engine is already gone, reinstall the kit and
#     run these to recover leftovers.)
#
# Options:
#   --prefix <path>         kit prefix to remove (default:
#                           /opt/egresslock)
#   --account <name>        account whose verify timer to stop/disable;
#                           repeatable; every enabled instance of the
#                           timer is also swept regardless of --account
#   --purge-account-data    also delete each account's
#                           ~/.config/egresslock (policy configs);
#                           Podman state is NEVER touched
#   -h, --help              print this help
#
# Environment (test hooks; the mock harness runs non-root):
#   EGRESSLOCK_KIT_ALLOW_NON_ROOT=1   allow non-root runs (tests only);
#                                test mode is off by default — only
#                                exactly 1 turns it on, and any other
#                                value (e.g. true) warns and leaves
#                                test mode off
#   EGRESSLOCK_UNIT_DIR=<dir>         remove unit templates here in test mode
#                                (default: /etc/systemd/system; requires
#                                EGRESSLOCK_KIT_ALLOW_NON_ROOT=1)
#   EGRESSLOCK_ACCOUNT_HOME=<dir>     account home override in test mode
#                                (requires EGRESSLOCK_KIT_ALLOW_NON_ROOT=1;
#                                honored as root in test mode too)
#   EGRESSLOCK_PATH_BINDIR=<dir>     PATH wrapper dir for the engine in test mode
#                                (default: /usr/local/bin; removes only
#                                THIS prefix's wrappers; requires
#                                EGRESSLOCK_KIT_ALLOW_NON_ROOT=1)
#   EGRESSLOCK_PATH_SBINDIR=<dir>    PATH wrapper dir for
#                                egresslock-setup in test mode (default:
#                                /usr/local/sbin; requires
#                                EGRESSLOCK_KIT_ALLOW_NON_ROOT=1)
#
# Defaults that are not parameter-changeable:
#   - a --prefix that is not an absolute, charset-clean kit path (no //,
#     no /./ or /../ segments, not /, ., or ..) exits 2 before anything
#     is removed
#   - a kit prefix is rm -rf'd ONLY when it is such a path AND carries
#     the REAL kit markers — egresslock (executable), egresslock-verify,
#     VERSION, and gateway/Containerfile — anything else is warned and
#     kept (a lone VERSION or egresslock file is not a kit)
#   - account data (conf, allowlist) is preserved by default;
#     only --purge-account-data removes it
#   - Podman state (anchors/gateways/networks/images) is never touched;
#     run `egresslock teardown all --yes` and then `egresslock teardown
#     --orphans` as the account, while the engine still exists
#
# Exit codes: 0 ok, 1 preflight failure (non-root, unknown account),
#   2 usage/environment error.

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
    echo "uninstall-kit: WARNING - $_name is set but ignored: it is a test-harness override and requires EGRESSLOCK_KIT_ALLOW_NON_ROOT=1; the production default applies." >&2
}
# EGL-491-D4: the test flag's gate is the exact `== 1` predicate. Any other
# set value (including empty) leaves test mode off, so the hooks set
# alongside it are inert — warn once, presence-based, never echo the value.
if [[ -n "${EGRESSLOCK_KIT_ALLOW_NON_ROOT+x}" \
      && "${EGRESSLOCK_KIT_ALLOW_NON_ROOT-}" != 1 ]]; then
    echo "uninstall-kit: WARNING - EGRESSLOCK_KIT_ALLOW_NON_ROOT is set but is not the exact value 1, so test mode is off; test-harness overrides are ignored." >&2
fi

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
[[ "$(id -u)" == 0 ]] || kit_test_mode || {
    echo "uninstall-kit: must run as root (sudo)" >&2
    exit 1
}
for acct in "${accounts[@]:-}"; do
    [[ -n "$acct" ]] || continue
    id "$acct" >/dev/null 2>&1 || { echo "uninstall-kit: no such account: $acct" >&2; exit 1; }
done

# EGL-89-D1: validate prefix path shapes BEFORE anything is removed.
# A kit path must be absolute and charset-clean: ^/[A-Za-z0-9._/-]+$,
# no //, no /./ or /../ segment (incl. a trailing /. or /..), never
# /, ., or .. — GNU rm's "." / ".." refusal is not a security boundary.
_check_kit_path_shape() {
    local p="$1" what="$2" bad=0
    if [[ "$p" == "/" || "$p" == "." || "$p" == ".." ]]; then
        bad=1
    elif [[ "$p" != /* ]]; then
        bad=1
    elif [[ "$p" == *$'\n'* ]]; then
        # a newline would smuggle a second operand past the line-anchored
        # charset grep below — reject before it can match
        bad=1
    elif ! LC_ALL=C grep -qE '^/[A-Za-z0-9._/-]+$' <<<"$p"; then
        bad=1
    elif [[ "$p" == *"//"* || "$p" == *"/./"* || "$p" == *"/../"* \
            || "$p" == *"/." || "$p" == *"/.." ]]; then
        bad=1
    fi
    if (( bad )); then
        echo "uninstall-kit: $what must be an absolute kit path (no relative/./.. or illegal characters; got: $p)" >&2
        exit 2
    fi
}
_check_kit_path_shape "$prefix" "--prefix"

# EGL-433-D3/D7: never operate through a symlinked --prefix. `rm -rf "<link>/"`
# follows the trailing slash into the referent, and the marker read, timer
# stop, and template removal would all run against the referent. Probe both
# spellings (the argument as passed and its one-trailing-slash form, whose
# -L is false) BEFORE the marker read, any stop, or any delete. Do not
# rewrite --prefix: the PATH-wrapper marker embeds the argument as passed.
_kit_prefix_shape_ok() { # <path> — the parser's rule, without exiting
    local p="$1"
    [[ "$p" == /* && "$p" != "/" ]] || return 1
    [[ "$p" != *$'\n'* ]] || return 1
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
    echo "uninstall-kit: refusing: --prefix is a symbolic link: $q_prefix" >&2
    prefix_resolved=""
    if [[ -d "$prefix_probe" ]]; then
        _kit_resolved prefix_resolved "$prefix_probe" || prefix_resolved=""
    fi
    if [[ -z "$prefix_resolved" ]]; then
        echo "  the link does not resolve to a directory; pass the real kit prefix. nothing was stopped, removed, or disabled." >&2
    elif _kit_prefix_shape_ok "$prefix_resolved"; then
        printf -v q_resolved '%q' "$prefix_resolved"
        echo "  pass the real directory the link points to (only that directory is removed); nothing was stopped, removed, or disabled:" >&2
        echo "    sudo ./uninstall-kit.sh --prefix $q_resolved" >&2
    else
        # D7: a retry command is offered only when its argument would pass
        # this tool's own --prefix rule; name the target, offer no command.
        printf -v q_resolved '%q' "$prefix_resolved"
        echo "  the link points to $q_resolved, which --prefix cannot name (only letters, digits, '.', '_', '-', and '/' are allowed); nothing was stopped, removed, or disabled." >&2
    fi
    exit 2
fi
unset prefix_resolved q_prefix q_resolved

# EGL-555-D2: capture the probed prefix's no-follow identity (or record that
# it is absent) so the marker fence and the removal below can run relative to
# the directory that was checked, not to its name. stat without -L is the
# directory itself, never a referent.
prefix_id=""
if [[ -e "$prefix_probe" || -L "$prefix_probe" ]]; then
    prefix_id="$(stat -c '%d:%i' -- "$prefix_probe" 2>/dev/null)" || prefix_id=""
    if [[ -z "$prefix_id" ]]; then
        printf -v q_prefix '%q' "$prefix"
        echo "uninstall-kit: refusing: cannot read the --prefix directory identity: $q_prefix" >&2
        echo "  check that the path is a readable directory, then re-run; nothing was stopped, removed, or disabled." >&2
        exit 1
    fi
fi
# EGL-555-D2: one cause line for a prefix that no longer matches the probe.
_kit_prefix_refuse_changed() {
    printf -v q_prefix '%q' "$prefix"
    echo "uninstall-kit: refusing: --prefix changed while the kit checked it: $q_prefix" >&2
    echo "  no kit files were removed from it; the instanced timer templates are already removed. Name the real kit prefix and re-run." >&2
    exit 1
}

# 1. Stop/disable the per-account timers (D2: conservative, explicit).
# EGL-463-D1: the attempt's exit status is the only locale/version-stable
# signal. Record it instead of discarding it; a nonzero disable or an
# unreadable list leaves the stop unconfirmed (and the closing summary
# honest, D2).
timer_stop_confirmed=1
_stop_failed_units=()
_stop_attempted_units=()
_stop_fail_add() {
    local _unit="$1" _seen
    for _seen in "${_stop_failed_units[@]:-}"; do
        [[ "$_seen" == "$_unit" ]] && return 0
    done
    _stop_failed_units+=("$_unit")
}
_stop_disable() {
    local _unit="$1"
    if systemctl disable --now "$_unit" 2>/dev/null; then
        return 0
    fi
    timer_stop_confirmed=0
    _stop_fail_add "$_unit"
    return 0
}
for acct in "${accounts[@]:-}"; do
    [[ -n "$acct" ]] || continue
    _stop_unit="egresslock-verify@$acct.timer"
    _stop_attempted_units+=("$_stop_unit")
    _stop_disable "$_stop_unit"
done
# R-017-1 F4: an installed-but-unnamed account would otherwise keep a
# stale wants-symlink pointing at the removed template — disable every
# enabled instance of the timer, not just the named ones.
# EGL-434-D1/D3: the unit dir is a test-only hook. Without the flag an
# inherited value is ignored and the production default is used, exactly
# as if the variable were unset. Resolved here, above the sweep
# (EGL-535-D2): the sweep's path sources read the same resolved dir.
unit_dest="/etc/systemd/system"
if kit_test_mode; then
    if [[ -n "${EGRESSLOCK_UNIT_DIR:-}" ]]; then unit_dest="$EGRESSLOCK_UNIT_DIR"; fi
else
    egl491_warn_ignored_hook EGRESSLOCK_UNIT_DIR "${EGRESSLOCK_UNIT_DIR:-}"
fi
# EGL-535-D1: every name any source yields passes this one attempt path —
# shape filter, bare-template skip, attempted-set de-dup, then the
# existing `_stop_disable`. The filters are load-bearing: a mock (or an
# over-broad listing) must not widen the sweep to `.service` units or
# foreign names, and a pattern-shaped test must never admit its own
# unmatched glob literal (`*`, `?`, `[`) or a path.
_stop_try_unit() {
    local _unit="$1" _seen=0 _attempted
    case "$_unit" in
        egresslock-verify@*.timer) ;;
        *) return 0 ;;
    esac
    case "$_unit" in
        *'*'*|*'?'*|*'['*|*/*) return 0 ;;
    esac
    [[ "$_unit" == "egresslock-verify@.timer" ]] && return 0
    for _attempted in "${_stop_attempted_units[@]}"; do
        [[ "$_attempted" == "$_unit" ]] && { _seen=1; break; }
    done
    (( _seen == 0 )) || return 0
    _stop_attempted_units+=("$_unit")
    _stop_disable "$_unit"
}
# EGL-463-D1: capture each list in this shell (no pipeline/xargs, whose
# status hid per-unit failures); the queries' own rc is part of the
# outcome, and the bare template is not an instance to disable.
# EGL-535-D1: one source can succeed while returning an incomplete list
# (systemd 257 renders only the template row for the file query), so the
# union below is the source of record — never any single query.
# EGL-535-D3: any failing query leaves the stop unconfirmed; a succeeding
# source never certifies a failing one.
_stop_list_rc=0
_stop_list="$(systemctl list-unit-files 'egresslock-verify@*.timer' --no-legend 2>/dev/null)" \
    || _stop_list_rc=$?
_stop_units="$(systemctl list-units --all --type=timer --plain --no-legend 'egresslock-verify@*.timer' 2>/dev/null)" \
    || _stop_list_rc=$?
if (( _stop_list_rc != 0 )); then
    timer_stop_confirmed=0
fi
if [[ -n "$_stop_list" ]]; then
    while IFS= read -r _stop_line; do
        _stop_try_unit "${_stop_line%%[[:space:]]*}"
    done <<< "$_stop_list"
fi
if [[ -n "$_stop_units" ]]; then
    while IFS= read -r _stop_line; do
        _stop_try_unit "${_stop_line%%[[:space:]]*}"
    done <<< "$_stop_units"
fi
# EGL-535-D1 amendment / D4: the path sources admit existing entries only.
# An unmatched glob yields its own literal, and a dangling wants link is
# section 2's job (attempting it would fake a failed stop on a state that
# section already cleans up).
for _stop_path in "$unit_dest"/egresslock-verify@*.timer; do
    [[ -e "$_stop_path" ]] || continue
    _stop_try_unit "${_stop_path##*/}"
done
for _stop_path in "$unit_dest"/timers.target.wants/egresslock-verify@*.timer; do
    [[ -L "$_stop_path" && -e "$_stop_path" ]] || continue
    _stop_try_unit "${_stop_path##*/}"
done
if (( timer_stop_confirmed == 0 )); then
    echo "uninstall-kit: WARNING - could not confirm the verify timers stopped." >&2
    if (( ${#_stop_failed_units[@]} > 0 )); then
        printf '  systemd did not disable:' >&2
        printf ' %s' "${_stop_failed_units[@]}" >&2
        printf '\n' >&2
    fi
    if (( _stop_list_rc != 0 )); then
        echo "  The enabled verify timers could not be listed." >&2
    fi
    echo "  When systemd is available, check: systemctl list-timers 'egresslock-verify@*.timer'" >&2
    echo "  If a verify timer is still active, stop it: systemctl disable --now egresslock-verify@ACCOUNT.timer" >&2
fi
unset _stop_line _stop_units _stop_path _stop_list

# 2. Remove the instanced templates and the deployed kit.
rm -f "$unit_dest/egresslock-verify@.service" \
      "$unit_dest/egresslock-verify@.timer"
# EGL-102-D6-R2: a timers.target.wants symlink whose template is gone
# cannot be cleared by disable and would leave a not-found timer after
# this uninstall. Sweep only the kit's own dangling enablement symlinks;
# anything else in wants/ is not ours.
for _want in "$unit_dest"/timers.target.wants/egresslock-verify@*.timer; do
    [[ -L "$_want" && ! -e "$_want" ]] || continue
    rm -f "$_want"
    echo "uninstall-kit: removed dangling timer enablement: $_want"
done
unset _want
# R-017-1 F5 / EGL-89-D1: only remove a directory that IS a kit prefix —
# an absolute, charset-clean path (checked above) carrying all four
# regular-file markers. A checkout (egresslock, no VERSION) or a scratch
# dir with one marker is not a kit; warn and keep it.
# EGL-555-D2: the path fence above decides only the branch; the removal
# itself runs in a subshell whose cwd is the probed directory and whose
# `stat .` must still equal the captured identity. The marker fence is
# re-read there (authoritative), the contents are emptied from inside
# (relative names, never `rm -rf "$prefix"`, never a trailing `/`), and
# the emptied name is then rmdir'd from the parent: a substituted link
# fails ENOTDIR and a repopulated directory ENOTEMPTY, both fail closed.
prefix_removed=0
if [[ -d "$prefix_probe" \
      && -f "$prefix_probe/egresslock" && -x "$prefix_probe/egresslock" \
      && -f "$prefix_probe/egresslock-verify" \
      && -f "$prefix_probe/VERSION" \
      && -f "$prefix_probe/gateway/Containerfile" ]]; then
    (
        cd -- "$prefix_probe" || _kit_prefix_refuse_changed
        _kit_id_now="$(stat -c '%d:%i' . 2>/dev/null)" || _kit_prefix_refuse_changed
        [[ "$_kit_id_now" == "$prefix_id" ]] || _kit_prefix_refuse_changed
        [[ -f egresslock && -x egresslock \
              && -f egresslock-verify && -f VERSION \
              && -f gateway/Containerfile ]] || _kit_prefix_refuse_changed
        find . -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || {
            printf -v q_prefix '%q' "$prefix"
            echo "uninstall-kit: FAIL - could not empty the kit prefix: $q_prefix" >&2
            echo "  some kit files were removed; inspect the directory and remove it yourself once it is empty." >&2
            exit 1
        }
    )
    rmdir -- "$prefix_probe" || {
        printf -v q_prefix '%q' "$prefix"
        echo "uninstall-kit: FAIL - could not remove the emptied kit prefix: $q_prefix" >&2
        echo "  the kit files were removed from it, then the name was repopulated or replaced; inspect it and remove it yourself." >&2
        exit 1
    }
    prefix_removed=1
elif [[ -e "$prefix" ]]; then
    echo "uninstall-kit: WARNING - $prefix exists but is not a real kit prefix (missing real-kit markers: egresslock, egresslock-verify, VERSION, gateway/Containerfile); not removing" >&2
fi
unset prefix_id _kit_id_now

# EGL-43-D4: remove THIS prefix's PATH wrappers only — the marker
# comment on line 2 carries the prefix, so another prefix's wrappers and
# a deb-owned /usr/bin/egresslock are left behind. Same dirs as
# install-kit.sh; EGRESSLOCK_PATH_BINDIR / EGRESSLOCK_PATH_SBINDIR are
# test-only overrides (EGL-434-D1/D3): without the test hook
# they are ignored and the production dirs are used.
path_bindir="/usr/local/bin"
path_sbindir="/usr/local/sbin"
if kit_test_mode; then
    if [[ -n "${EGRESSLOCK_PATH_BINDIR:-}" ]]; then path_bindir="$EGRESSLOCK_PATH_BINDIR"; fi
    if [[ -n "${EGRESSLOCK_PATH_SBINDIR:-}" ]]; then path_sbindir="$EGRESSLOCK_PATH_SBINDIR"; fi
else
    egl491_warn_ignored_hook EGRESSLOCK_PATH_BINDIR "${EGRESSLOCK_PATH_BINDIR:-}"
    egl491_warn_ignored_hook EGRESSLOCK_PATH_SBINDIR "${EGRESSLOCK_PATH_SBINDIR:-}"
fi
for _wdest in "$path_bindir/egresslock" "$path_sbindir/egresslock-setup"; do
    [[ -e "$_wdest" ]] || continue
    _wmarker="$(sed -n '2p' "$_wdest" 2>/dev/null || true)"
    if [[ "$_wmarker" == "# egresslock-path-wrapper prefix=$prefix" ]]; then
        rm -f "$_wdest"
        echo "uninstall-kit: removed PATH wrapper $_wdest"
    fi
done
# EGL-121: the templates are already removed; on a host without systemd a
# bare reload failed *after* the removal and `set -e` skipped the
# account-data/summary lines. Warn and continue (rc 0); the attempt is the
# check (a `systemctl` binary may exist with no reachable systemd).
# Confirmed only on rc 0 with no captured output (a chroot/offline systemd
# ignores `daemon-reload` after logging it and still exits 0). Together
# with the stop outcome above it drives the closing timer clause (D5,
# EGL-463-D2): `timers stopped` requires every stop attempt and this
# reload to be confirmed. The captured text is not echoed.
_reload_rc=0
_reload_out="$(systemctl daemon-reload 2>&1)" || _reload_rc=$?
_reload_confirmed=0
if (( _reload_rc == 0 )) && [[ -z "$_reload_out" ]]; then
    _reload_confirmed=1
else
    echo "uninstall-kit: WARNING - systemd did not confirm the unit-file reload; the verify timer templates were removed, but a running systemd may still have them loaded." >&2
    echo "  An enabled verify timer may still be active; when systemd is available, run: systemctl daemon-reload" >&2
    echo "  If a verify timer is still active, stop it: systemctl disable --now egresslock-verify@ACCT.timer" >&2
fi

# 3. Account data: preserved unless explicitly purged.
for acct in "${accounts[@]:-}"; do
    [[ -n "$acct" ]] || continue
    # EGRESSLOCK_ACCOUNT_HOME overrides the passwd lookup in test mode
    # only; guard against a bogus resolution ever purging the wrong tree.
    home="$(getent passwd "$acct" | cut -d: -f6)"
    if kit_test_mode && [[ -n "${EGRESSLOCK_ACCOUNT_HOME:-}" ]]; then
        home="$EGRESSLOCK_ACCOUNT_HOME"
    else
        egl491_warn_ignored_hook EGRESSLOCK_ACCOUNT_HOME "${EGRESSLOCK_ACCOUNT_HOME:-}"
    fi
    if [[ -z "$home" || "$home" == "/" || ! -d "$home" ]]; then
        echo "uninstall-kit: refusing account-data handling for '$acct' (unresolved home '$home')" >&2
        continue
    fi
    if (( purge_account_data )); then
        if [[ -L "$home/.config/egresslock" ]]; then
            # EGL-433-D2: a symlink is only the link, never "account data";
            # removing it leaves the target (the real policy tree) intact.
            rm -f -- "$home/.config/egresslock"
            echo "uninstall-kit: removed $home/.config/egresslock (symbolic link; its target was not touched)"
        elif [[ -e "$home/.config/egresslock" ]]; then
            rm -rf "$home/.config/egresslock"
            echo "uninstall-kit: purged $home/.config/egresslock (account data)"
        fi
    else
        # EGL-102-D6-R4 honesty: by this point the engine is already
        # removed, so the reminder must say so instead of prescribing an
        # unrunnable command.
        [[ -e "$home/.config/egresslock" ]] && \
            echo "uninstall-kit: kept $home/.config/egresslock (account-owned policy data; Podman state untouched — run 'egresslock teardown all --yes' then 'egresslock teardown --orphans' as the account to remove kit containers/networks; they need the engine, so reinstall the kit first if it is already gone)"
    fi
done

if (( timer_stop_confirmed && _reload_confirmed )); then
    _timer_clause="timers stopped"
else
    _timer_clause="timer stop not confirmed"
fi
if (( prefix_removed )); then
    echo "uninstall-kit: kit removed from $prefix; instanced templates removed; $_timer_clause"
elif [[ -e "$prefix" ]]; then
    echo "uninstall-kit: done — $prefix left in place (see warning above); instanced templates removed; $_timer_clause"
else
    echo "uninstall-kit: done — no kit at $prefix; instanced templates removed; $_timer_clause"
fi
