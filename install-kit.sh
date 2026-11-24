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
#      --apparmor-add), docs/ (the installed copy of the shipped pages
#      the engine/verify messages point at), and a VERSION stamp
#      (version string + deployed commit SHA + UTC date). This is the
#      ONLY thing accounts share.
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
# confdir is validated — never as a vacuous enable at install time.
# Account-owned data (conf, allowlist, gateway image) is NOT installed
# here either: accounts execute, root distributes.
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
#     egl-base/), apparmor/ (pasta snippet), docs/ (regular .md pages;
#     no tickets/ or BOARD.md), VERSION (all root-owned)
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
unset prefix_resolved q_prefix q_resolved

# EGL-555-D1: capture the probed prefix's no-follow identity. The -L probe
# above is name-based and the copies/deletes below run later; a writer that
# can create entries in the prefix's parent could otherwise swap the prefix
# for a symlink in between. Capture `dev:ino` now (or record that the prefix
# is absent) and make every prefix-scoped write/delete resolve through a
# held directory whose identity is checked against this capture. stat
# without -L is intentional: it is the directory itself, never a referent.
prefix_id=""
if [[ -e "$prefix_probe" || -L "$prefix_probe" ]]; then
    prefix_id="$(stat -c '%d:%i' -- "$prefix_probe" 2>/dev/null)" || prefix_id=""
    if [[ -z "$prefix_id" ]]; then
        printf -v q_prefix '%q' "$prefix"
        echo "install-kit: refusing: cannot read the --prefix directory identity: $q_prefix" >&2
        echo "  check that the path is a readable directory, then re-run; nothing was written or removed." >&2
        exit 1
    fi
fi
# EGL-555-D1: one cause line for a prefix that no longer matches the probe
# (swapped for a link, replaced, or appeared after an absent probe).
_kit_prefix_refuse_changed() { # <check|appeared>
    printf -v q_prefix '%q' "$prefix"
    echo "install-kit: refusing: --prefix changed while the kit checked it: $q_prefix" >&2
    if [[ "${1:-}" == appeared ]]; then
        echo "  it appeared after the check, so this run cannot claim it; nothing was written or removed. Re-run when no other install is running." >&2
    else
        echo "  nothing was written or removed; name the real kit prefix and re-run." >&2
    fi
    exit 1
}

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
# EGL-549-D5: ONE manifest drives this gate and the copy below. Rows are
# `file <mode> <rel-path>`, `dir <mode> <rel-path>` and
# `tree <mode> <rel-root>`; a `tree` root is installed by staging a temp
# copy of the root and swapping it in. The modes are the DEPLOYED modes
# (0644 everywhere except the four entry points and build-egl-base, and
# all directories at 0755), so `install -m` makes them real even under a
# nonstandard umask. systemd/ stays outside: its source is
# EGRESSLOCK_UNIT_SRC when the test hook is on and it installs to the
# unit dir, not the prefix.
_kit_manifest() {
    cat <<'EOF'
file 0755 egresslock
file 0755 egresslock-start
file 0755 egresslock-verify
file 0755 egresslock-setup
dir 0755 examples
file 0644 examples/main.conf
file 0644 examples/main-allowlist
tree 0755 gateway
file 0644 gateway/Containerfile
file 0644 gateway/entrypoint.sh
file 0644 gateway/security-floor
file 0644 gateway/squid.conf
tree 0755 apparmor
file 0644 apparmor/README.md
file 0644 apparmor/usr.bin.pasta.local
tree 0755 examples/recipes
dir 0755 examples/recipes/agent-container-example
file 0644 examples/recipes/agent-container-example/Containerfile
file 0644 examples/recipes/agentic-tool-opencode.md
file 0644 examples/recipes/ci-runner.md
file 0644 examples/recipes/fleet-deploy.md
file 0644 examples/recipes/github.md
file 0644 examples/recipes/hermes-curl-install.md
file 0644 examples/recipes/local-llm.md
file 0644 examples/recipes/malware-analysis.md
file 0644 examples/recipes/opencode-npm-install.md
file 0644 examples/recipes/supply-chain-safe-build.md
tree 0755 examples/egl-base
file 0644 examples/egl-base/Containerfile
file 0644 examples/egl-base/README.md
file 0755 examples/egl-base/build-egl-base
file 0644 examples/egl-base/security-floor
tree 0755 docs
EOF
    # EGL-556-D2: the docs tree ships into the prefix so the engine and
    # verify messages point at a copy that survives the checkout/tarball
    # being removed. Only regular `.md` pages: `tickets/` and the
    # generated `BOARD.md` are process material, and `find -type f`
    # keeps symlinked leaves out of the stage (the EGL-399 class). The
    # rows replay into the `docs.tmp` swap below like the other trees.
    if [[ -d "$src/docs" && ! -L "$src/docs" ]]; then
        local _doc_abs _doc_rel _doc_dir
        while IFS= read -r _doc_abs; do
            _doc_rel="docs/${_doc_abs#"$src/docs/"}"
            _doc_dir="${_doc_rel%/*}"
            [[ "$_doc_dir" == docs ]] || printf 'dir 0755 %s\n' "$_doc_dir"
        done < <(find "$src/docs" -type f -name '*.md' \
                      ! -path "$src/docs/tickets/*" \
                      ! -path "$src/docs/BOARD.md")
        while IFS= read -r _doc_abs; do
            _doc_rel="docs/${_doc_abs#"$src/docs/"}"
            printf 'file 0644 %s\n' "$_doc_rel"
        done < <(find "$src/docs" -type f -name '*.md' \
                      ! -path "$src/docs/tickets/*" \
                      ! -path "$src/docs/BOARD.md")
    fi
}
_kit_rows="$(_kit_manifest)"
_kit_missing=""
# EGL-102-D6-F3: cover the WHOLE deployed set (binaries, gateway/,
# apparmor/, examples incl. every recipes/ and egl-base/ leaf). The rows
# and the copy below are the same table, so the gate guards exactly what
# is installed.
while IFS=' ' read -r _kind _mode _rel; do
    [[ -n "$_kind" ]] || continue
    case "$_kind" in
        tree|dir) [[ -d "$src/$_rel" ]] || _kit_missing+="$_rel " ;;
        file) [[ -f "$src/$_rel" ]] || _kit_missing+="$_rel " ;;
    esac
done <<<"$_kit_rows"
# EGL-556-D2: docs must be a real directory, not a link — `-d` accepts a
# symlinked tree, but the manifest only enumerated regular `.md` leaves
# under a real one, so a link would ship an empty docs/ and the messages
# would silently fall back to titles. Refuse before any write.
if [[ -L "$src/docs" && -d "$src/docs" ]]; then
    _kit_missing+="docs "
fi
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
unset _kit_missing _ut

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
            "falls back to '${base}+gitTS.unknown'" >&2
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
# EGL-555-D1: create/anchor the prefix without following a final link
# (`install -d -m` follows a swapped link and chmods the referent;
# `mkdir -p` returns 0 through a symlink-to-directory). A prefix absent at
# the probe is created here, then its own identity becomes the reference;
# a path that appeared in between refuses. Everything from the marker fence
# through the last prefix write runs in a subshell whose cwd is the held
# directory and whose `stat .` must still equal the reference: a swap
# before this point refuses with nothing written or removed, and a swap
# after it cannot redirect a relative operation.
if [[ -z "$prefix_id" ]]; then
    if [[ -e "$prefix_probe" || -L "$prefix_probe" ]]; then
        _kit_prefix_refuse_changed appeared
    fi
    mkdir -p -- "$(dirname -- "$prefix_probe")" || {
        printf -v q_prefix '%q' "$prefix"
        echo "install-kit: FAIL - could not create the parent directory for $q_prefix" >&2
        echo "  nothing was installed; check the path's permissions and re-run." >&2
        exit 1
    }
    mkdir -- "$prefix_probe" || {
        if [[ -e "$prefix_probe" || -L "$prefix_probe" ]]; then
            _kit_prefix_refuse_changed appeared
        fi
        printf -v q_prefix '%q' "$prefix"
        echo "install-kit: FAIL - could not create the kit prefix: $q_prefix" >&2
        echo "  nothing was installed; check the parent directory's permissions and re-run." >&2
        exit 1
    }
    prefix_id="$(stat -c '%d:%i' -- "$prefix_probe" 2>/dev/null)" || {
        printf -v q_prefix '%q' "$prefix"
        echo "install-kit: refusing: cannot read the --prefix directory identity: $q_prefix" >&2
        echo "  check that the path is a readable directory, then re-run; nothing was installed." >&2
        exit 1
    }
elif [[ ! -d "$prefix_probe" ]]; then
    printf -v q_prefix '%q' "$prefix"
    echo "install-kit: refusing: --prefix is not a directory: $q_prefix" >&2
    echo "  pass a directory path here; nothing was written or removed." >&2
    exit 1
fi
(
cd -- "$prefix_probe" || _kit_prefix_refuse_changed check
_kit_id_now="$(stat -c '%d:%i' . 2>/dev/null)" || _kit_prefix_refuse_changed check
[[ "$_kit_id_now" == "$prefix_id" ]] || _kit_prefix_refuse_changed check
# EGL-68-D1 / EGL-90-D3: never rm -rf through a mistyped --prefix. The
# install replaces gateway/, apparmor/, examples/recipes/,
# examples/egl-base/ and docs/. Deleting one is allowed only when it is
# absent (first install), $prefix carries a kit marker (VERSION or the
# egresslock executable), or the path is kit-shaped
# (gateway/Containerfile). Otherwise fail closed before any copy, naming
# the path. EGL-265 item 4: keep this list in lockstep with the loop.
# EGL-556-D2: docs/ joins the replacement set and this fence.
# EGL-555-D1: read through the held directory, relative names only.
for _dest in gateway apparmor examples/recipes examples/egl-base docs; do
    if [[ ! -e "$_dest" ]]; then
        continue                                   # first install
    fi
    if [[ -f VERSION || -x egresslock || -f gateway/Containerfile ]]; then
        continue              # reinstall over this kit's deploy / kit-shaped
    fi
    echo "install-kit: FAIL - refusing to delete $prefix/$_dest" >&2
    echo "  $prefix has no kit marker (VERSION, egresslock executable) and" >&2
    echo "  the dest path is not kit-shaped (no gateway/Containerfile): a mistyped" >&2
    echo "  --prefix would destroy a foreign tree. Remove it or name the real kit prefix." >&2
    exit 1
done
unset _dest
# EGL-555-D1: the mode is set through the held directory, never at the name.
chmod 0755 . || {
    printf -v q_prefix '%q' "$prefix"
    echo "install-kit: FAIL - could not set the kit prefix mode: $q_prefix" >&2
    echo "  nothing was installed; check the directory's ownership and permissions, then re-run." >&2
    exit 1
}
# EGL-549-D5: the manifest drives the copy too. Direct rows install in
# order (the `examples` dir before its two files); each `tree` row is
# staged as `<root>.tmp`, replayed from its own dir/file rows into the
# temp, mode-normalized, and swapped in. The four atomic-replace sites
# (gateway, apparmor, examples/recipes, examples/egl-base) are the same
# temp+rm+mv shape as before (EGL-531-D1; EGL-555 keeps them
# addressable), and a failure before the swap leaves the old tree.
_kit_in_tree() { # <rel> — 0 when a tree root owns this row
    local _t
    for _t in "${_kit_tree_roots[@]}"; do
        [[ "$1" == "$_t"/* ]] && return 0
    done
    return 1
}
_kit_tree_roots=()
while IFS=' ' read -r _kind _mode _rel; do
    [[ "$_kind" == tree ]] || continue
    _kit_tree_roots+=("$_rel")
done <<<"$_kit_rows"
while IFS=' ' read -r _kind _mode _rel; do
    [[ -n "$_kind" ]] || continue
    case "$_kind" in
        file)
            if _kit_in_tree "$_rel"; then continue; fi
            install -m "$_mode" "$src/$_rel" "$_rel"
            ;;
        dir)
            if _kit_in_tree "$_rel"; then continue; fi
            install -d -m "$_mode" "$_rel"
            ;;
    esac
done <<<"$_kit_rows"
# ARC-19-D3: starter conf + empty allowlist for egresslock-setup
# --init-conf. Root-owned, never installed into account homes.
# Recipes and egl-base ship too so accounts can build from the PREFIX
# without a checkout (same rationale as the gateway context, ARC-16-D6).
# EGL-69-D2: the pasta AppArmor snippet ships with the prefix
# (root-owned, like gateway/) so `sudo $prefix/egresslock-setup
# --apparmor-add` works on prefix installs. Shipping is distribution;
# applying stays explicit --apparmor-add only (ARC-22-D3).
# EGL-232: the shared example base image (egl-base) ships too so the
# quickstarts can build it without a checkout.
while IFS=' ' read -r _kind _mode _rel; do
    [[ "$_kind" == tree ]] || continue
    _tmp="$_rel.tmp"
    # EGL-531-D1: pre-clean only the `.tmp` path; the live root stays in
    # place until the copy succeeds. EGL-555-D1: relative to the held
    # prefix directory, so a swapped prefix name cannot redirect it.
    rm -rf "$_tmp"
    install -d -m "$_mode" "$_tmp"
    while IFS=' ' read -r _kind2 _mode2 _rel2; do
        [[ "$_rel2" == "$_rel"/* ]] || continue
        case "$_kind2" in
            dir)  install -d -m "$_mode2" "$_tmp/${_rel2#"$_rel"/}" ;;
            file) install -m "$_mode2" "$src/$_rel2" "$_tmp/${_rel2#"$_rel"/}" ;;
        esac
    done <<<"$_kit_rows"
    chmod -R go-w "$_tmp"
    rm -rf "$_rel"
    mv "$_tmp" "$_rel"
done <<<"$_kit_rows"
unset _kit_rows _kit_tree_roots _kind _mode _rel _kind2 _mode2 _rel2 _tmp
unset -f _kit_in_tree

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
} > VERSION
chmod 0644 VERSION
)
unset prefix_id _kit_id_now

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
echo "  sudo $prefix/egresslock-setup init ACCT --init-conf --enable"
echo "  (or --from CONF to import a pair; import never overwrites a"
echo "  differing/torn dest — use import --force deliberately; the starter"
echo "  ships from examples/ only when the dest conf is missing)"
echo
echo "or try the engine directly:  $prefix/egresslock --help"
