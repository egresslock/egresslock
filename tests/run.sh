#!/usr/bin/env bash
#
# tests/run.sh — THE product-tree test entry point (ARC-74-D2).
# Runs the product test-*.sh harnesses beside this script and fails closed
# if a selected harness is missing or not executable, so reviewers (and
# the standalone egresslock repo after ARC-75) cannot skip a battery.
#
# EGL-78-D2/D3/D6: every harness runs inside `timeout` so a hang is a
# NAMED FAILURE, never a wedged battery. A timeout is a FAIL, never a
# skip. With `stdbuf`, each harness runs as `stdbuf -oL -eL bash "$h"`
# inside the timeout so PASS lines flush before a later hang; without it
# the harness runs unmodified.
#
# EGL-225: the bound is 600s (was 300s). The engine harness is a
# process-spawn storm (hundreds of invocations, ~80+ mock helpers each,
# plus deliberate latency budgets) and measured 297-345s vs 300s (runs
# 486/505/509/510 on the shared CI runner: all PASS, then the bound
# fired). 600s leaves headroom while a real wedge is named in ~10 min.
#
# EGL-353: the 600s default is overridable per run with
# EGRESSLOCK_HARNESS_TIMEOUT=<seconds> (positive integer; unset/empty
# keeps 600) so a slow or loaded host can finish the engine battery.
# Anything else — including 0, which `timeout 0` would turn into no
# bound — is refused with rc 2 before any harness starts; CI sets it
# to 2000 on its two battery jobs (EGL-432), while local and handoff
# runs keep the 600s default.
#
# EGL-79-D2: `--help/-h` prints usage and exits 0; `--harness
# engine|kit|docs|all` selects a subset (default `all` = the `test-*.sh`
# glob). Unknown options / bad values exit 2.
#
# EGL-270 (D1-B): `bash tests/run.sh` keeps its meaning (full battery).
# `--track fast|full` (default `full`) skips registered slow sections
# (tests/lib.sh `_slow_sections`; round 1 `egl203r`; `egl223` stays
# per-push, security-classed, R-EGL-270-5) through skip() with a named
# cause; RESULTS TOTAL still reports exact counts. run.sh exports
# EGRESSLOCK_TEST_TRACK for the harness loop (unset/empty = full). CI
# opts in through its workflow configuration; the full battery stays the
# handoff/pre-release gate.
#
# EGL-451: the engine harness shards by default. `bash tests/run.sh`
# splits the engine windows into M weight-balanced processes (M =
# min(3, detected CPUs); cgroup v2 cpu.max quota, else nproc) using the
# shipped tests/shard-weights.tsv, runs them concurrently, replays their
# logs in shard order, and prints one parent-rendered RESULTS TOTAL.
# `--serial` restores the one-process path; `--shard M` picks the count;
# `--shard N/M` runs one shard for debugging. kit/docs stay serial. The
# weights table and `test-engine.sh --list-sections` must agree exactly
# or run.sh exits 2 before any shard starts.
#
# EGL-86-D1/D2: the battery is non-root — refused, not skipped, under uid
# 0 (exit 2 after flag parsing, before harness selection). `--help` wins
# over the root gate.
#
# EGL-464: `--section <name>[,<name>…]` is the documented, engine-only
# subset run. It is a thin wrapper over EGL-451's shard selection
# (`EGRESSLOCK_TEST_SHARDED=1` + `EGRESSLOCK_TEST_SECTIONS`), not a new
# selector: one process, only the named windows, and the harness's own
# partial RESULTS TOTAL. Names come from `test-engine.sh --list-sections`;
# an empty, duplicate, or unknown name is refused (rc 2) before any test.
# It refuses `--track fast` (a chosen slow section would be skipped),
# `--shard`/`--serial` (not a shard pack), and `--harness kit|docs|all`.
#
# EGL-497: `--track lite` is the per-push CI track. It runs an explicit
# core engine set (`LITE_SECTIONS` below: egl365 egl395 egl305 egl318
# egl223) plus the kit and docs harnesses, still sharded; every other
# engine section is deferred to the full battery (handoff, nightly,
# release). Lite always takes the shard path — the serial path unsets the
# section env and would run the full engine — so `--track lite` refuses
# `--serial` and `--section` (exit 2), and `--shard 1` / a single-CPU
# host still packs one bin. The full section list is validated exactly as
# before (harness `--list-sections`, duplicate names, weights exact-set,
# one window gate per section) and only then filtered, so a lite run
# still proves the EGL-451 sharder contract over all sections; an
# unknown or duplicate lite name exits 2. The parent-rendered merged
# TOTAL names the deferral (`lite-deferred engine sections: N`, count =
# full list - lite list) beside the shards' real skips, so a lite green
# is never read as the full battery. `--track fast` keeps its EGL-270
# meaning (only registered slow sections skip).
#
# EGL-86-D3: each harness's output is teed to a temp log; at suite end
# `^SKIP:` lines are counted, bucketed by reason, and summarized as one
# `run.sh: skips` line plus a fixed coverage note. Skips never change rc.
#
# Run:  bash tests/run.sh [--help] [--harness engine|kit|docs|all]
#                                      [--track fast|full|lite] [--no-foreground]
#                                      [--section <name>[,<name>…]]
#                                      [--serial | --shard M | --shard N/M]
#
# Exit codes: 0 all green; 1 one or more harnesses failed (also a harness
# timeout); 2 usage error (bad flags, no harnesses, timeout(1) missing, or
# root uid — run as an unprivileged account).

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: bash tests/run.sh [options]

  --help, -h              Show this help and exit 0
  --harness engine|kit|docs|all
                          Which test-*.sh to run (default: all)
  --track fast|full|lite  Run track (default: full). On --track fast the
                          registered slow sections (tests/lib.sh
                          _slow_sections; round 1: egl203r — egl223
                          stays per-push, security-classed, EGL-270)
                          are skipped with a named cause in each
                          harness's RESULTS TOTAL. --track lite is the
                          per-push CI track: only the core engine
                          sections (egl365 egl395 egl305 egl318 egl223)
                          plus kit and docs, always sharded; the merged
                          engine TOTAL names the deferred sections
                          (EGL-497). Default stays the full battery
                          (EGL-79-D2); `--track fast` is the local
                          iteration shortcut and `--track lite` is CI's
                          per-push battery.
  --serial                Run the engine harness in one process (the
                          pre-EGL-451 path). Default is sharded.
  --shard M               Run the engine in M concurrent shards (M >= 1;
                          M=1 is the serial path). An explicit M is
                          honored even above the detected CPU count.
  --shard N/M             Run only shard N of M (debugging); that shard
                          prints its own partial RESULTS TOTAL.
  --section <name>[,<name>...]
                          Engine-only subset run: execute only the named
                          sections (names from
                          `bash tests/test-engine.sh --list-sections`).
                          Empty, duplicate, or unknown names exit 2 before
                          any test; the RESULTS TOTAL is a partial total
                          over the selected sections, not the battery
                          total. Refused with --track fast|lite, --shard,
                          --serial, or --harness kit|docs|all (EGL-464,
                          EGL-497).
  --no-foreground         Classic timeout isolation: on expiry the whole
                          harness process group is TERMed instead of the
                          direct child only. Default is foreground mode
                          (--foreground -k 15) so Ctrl+C cancels the
                          whole battery and a wedged harness is
                          SIGKILLed 15s after the TERM.

Environment:
  EGRESSLOCK_HARNESS_TIMEOUT=<seconds>
                          Per-harness timeout bound: a positive integer
                          of seconds (default: 600; unset or empty keeps
                          600). Raise it on a slow or loaded host so the
                          engine battery can finish (EGL-353).

The battery must run as an unprivileged account (its mocked root-guard
and non-root-hook cases are structurally invalid under uid 0 and root
execution is refused, not skipped). In a root-only container, run it
mapped, e.g.:

  setpriv --reuid=nobody --regid=nogroup --clear-groups env HOME=/tmp bash tests/run.sh

(the repo must be world-readable; the harness tempdirs already live in
/tmp). Intentional security-test skips (private fixtures absent on the
public tree, host-shape gaps) are summarized as a `run.sh: skips` line
at suite end; they never change the exit code.

Layers (taxonomy; not selectable flags in this ticket):
  1 public unit/integration  — test-engine.sh + test-kit.sh +
                               test-docs.sh (docs link resolution)
  2 public security regs.    — mixed into those harnesses
  3 private/adversarial      — not in this tree (must not ship)

Exit: 0 all green; 1 a harness failed; 2 usage / no harnesses / root
EOF
}

# --- EGL-79-D2: flag parsing (before any timeout/harness work) ----------
harness_sel="all"
harness_given=0
track_sel="full"   # EGL-270 (D1-B): default = full battery; unset/empty = full for harnesses too
shard_sel=""       # EGL-451: empty = default policy; M or N/M otherwise
serial_sel=0       # EGL-451: --serial forces the one-process engine path
section_sel=""     # EGL-464: comma-separated engine section names
section_mode=0     # EGL-464: --section selects the one-process subset path
# EGL-80 signal/timeout policy: default is `timeout --foreground -k 15`.
#   --foreground keeps the harness in the caller's group so Ctrl+C cancels
#                the battery; without it timeout ignores tty SIGINT and
#                bash defers its own, so Ctrl+C appears dead (observed on a
#                deployed host, 2026-09-16).
#   -k 15        SIGKILL 15s after TERM, so a wedge cannot outlive the bound.
#   Tradeoff: only the direct child is signalled; short-lived grandchildren
#   may orphan (harmless: mocks, stdin /dev/null). `--no-foreground` prefers
#   classic group-kill isolation; it keeps the same group-scoped KILL at
#   +15s (EGL-80-1-F2), differing only in signal scope and tty behavior.
tf_args=( --foreground --kill-after=15 )
while (( $# )); do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --no-foreground)
            # EGL-80-2-F3: same kill-after; only scope/tty differ.
            tf_args=( --kill-after=15 )
            ;;
        --harness=*)
            harness_sel="${1#*=}"
            harness_given=1
            ;;
        --harness)
            if (( $# < 2 )); then
                echo "run.sh: --harness requires a value (engine|kit|docs|all)" >&2
                exit 2
            fi
            harness_sel="$2"
            harness_given=1
            shift
            ;;
        --section=*)
            section_sel="${1#*=}"
            section_mode=1
            ;;
        --section)
            if (( $# < 2 )); then
                echo "run.sh: --section requires a comma-separated list of engine section names" >&2
                exit 2
            fi
            section_sel="$2"
            section_mode=1
            shift
            ;;
        --track=*)
            track_sel="${1#*=}"
            ;;
        --track)
            if (( $# < 2 )); then
                echo "run.sh: --track requires a value (fast|full|lite)" >&2
                exit 2
            fi
            track_sel="$2"
            shift
            ;;
        --serial)
            serial_sel=1
            ;;
        --shard=*)
            shard_sel="${1#*=}"
            ;;
        --shard)
            if (( $# < 2 )); then
                echo "run.sh: --shard requires a value (M or N/M)" >&2
                exit 2
            fi
            shard_sel="$2"
            shift
            ;;
        *)
            echo "run.sh: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

# EGL-464: --section shape conflicts are usage errors before any test runs.
if (( section_mode )); then
    if [[ -n "$shard_sel" ]]; then
        echo "run.sh: --section and --shard are mutually exclusive (--section runs one process over a subset)" >&2
        exit 2
    fi
    if (( serial_sel )); then
        echo "run.sh: --section and --serial are mutually exclusive (--section is already the one-process subset path)" >&2
        exit 2
    fi
    if [[ "$track_sel" == "fast" ]]; then
        echo "run.sh: --section refuses --track fast (a chosen slow section would otherwise be skipped)" >&2
        exit 2
    fi
    if (( harness_given )) && [[ "$harness_sel" != "engine" ]]; then
        echo "run.sh: --section applies to the engine harness only (got --harness $harness_sel)" >&2
        exit 2
    fi
    if [[ "$track_sel" == "lite" ]]; then
        echo "run.sh: --section refuses --track lite (the lite core set is already a subset; use --section <name>[,<name>...] for a custom subset)" >&2
        exit 2
    fi
fi

# EGL-497 D3: the lite track always runs the engine shard path. --serial
# would unset the section env and silently execute the full engine, so it
# is a usage error before any harness (the same reason --section is
# refused above).
if [[ "$track_sel" == "lite" ]] && (( serial_sel )); then
    echo "run.sh: --track lite refuses --serial (the lite selection needs the engine shard path; a serial run would execute the full engine)" >&2
    exit 2
fi

# EGL-86-D1/D2: root preflight — refuse, never skip. Under uid 0 the
# mocked root-guard and non-root-hook cases fail structurally; a skip
# would falsely report "all applicable tests passed" and could mask a
# real regression. Same exit class as usage (0/1/2); --help exited above.
#
# EGL-434 (R-EGL-434-6, R-EGL-434-8): the effective UID is read from the
# kernel's /proc/self/status `Uid:` line. Neither `id -u` nor bash's EUID
# is caller-safe: PATH lets an `id` shim hide a uid-0 run (R-EGL-434-6),
# and bash imports a pre-set EUID from the environment at startup, so
# `env EUID=<nonzero>` hides one too (R-EGL-434-8). /proc/self/status is
# generated by the kernel for this process and cannot be forged. Fail
# closed if it is unreadable or the effective UID is not numeric instead
# of running with unknown privilege.
egl434_euid=""
if [[ -r /proc/self/status ]]; then
    while IFS=$' \t' read -r egl434_key egl434_real egl434_eff egl434_saved egl434_fs; do
        if [[ "$egl434_key" == "Uid:" ]]; then
            egl434_euid="$egl434_eff"
            break
        fi
    done < /proc/self/status
fi
if [[ ! "${egl434_euid:-}" =~ ^[0-9]+$ ]]; then
    echo "run.sh: FAIL cannot determine the effective UID (kernel Uid='${egl434_euid:-}') — refusing to run the battery with unknown privilege, because its mocked root-guard and non-root-hook cases are structurally invalid under uid 0 (EGL-434 F1)" >&2
    exit 2
fi
if (( egl434_euid == 0 )); then
    echo "run.sh: FAIL run tests as an unprivileged account — the battery's mocked root-guard and non-root-hook cases are structurally invalid under uid 0, so root execution is refused, not skipped (EGL-86-D2)" >&2
    echo "run.sh: in a root-only container, run mapped: setpriv --reuid=nobody --regid=nogroup --clear-groups env HOME=/tmp bash tests/run.sh" >&2
    exit 2
fi

# EGL-434 F1 probe seam: the root-guard pin runs this file with
# EGL434_ROOT_GUARD_PROBE=1 and a throwaway HOME, then checks which side
# of the guard the child reached. Exit here — before harness selection or
# any harness side effect — so a non-refused probe is bounded. Normal
# runs never set it.
if [[ -n "${EGL434_ROOT_GUARD_PROBE:-}" ]]; then
    printf 'run.sh guard-pass euid=%s\n' "$egl434_euid"
    exit 0
fi

shopt -s nullglob
case "$harness_sel" in
    engine)
        harnesses=( "$tests_dir/test-engine.sh" )
        ;;
    kit)
        harnesses=( "$tests_dir/test-kit.sh" )
        ;;
    docs)
        harnesses=( "$tests_dir/test-docs.sh" )
        ;;
    all)
        harnesses=( "$tests_dir"/test-*.sh )
        ;;
    *)
        echo "run.sh: bad --harness value: '$harness_sel' (expected engine|kit|docs|all)" >&2
        exit 2
        ;;
esac
shopt -u nullglob

# EGL-464: --section is engine-only; omitted --harness already means engine.
if (( section_mode )); then
    harnesses=( "$tests_dir/test-engine.sh" )
fi

# EGL-270: validate the track and export the channel (direct runs stay full).
# EGL-497: the lite track's explicit core engine set — the one greppable
# home for per-push engine membership. Every other engine section is
# deferred to the full battery; names are validated against
# `test-engine.sh --list-sections` in the shard-planning block (unknown
# or duplicate exits 2 there, after the full-set checks).
LITE_SECTIONS=( egl365 egl395 egl305 egl318 egl223 )
lite_deferred=0        # full engine section list - lite list (D6)
lite_total_printed=0   # the parent merge added the synthetic count
case "$track_sel" in
    fast|full|lite) export EGRESSLOCK_TEST_TRACK="$track_sel" ;;
    *)
        echo "run.sh: bad --track value: '$track_sel' (expected fast|full|lite)" >&2
        exit 2
        ;;
esac

# EGL-78-D6: timeout(1) is required — fail closed rather than run unbounded.
if ! command -v timeout >/dev/null 2>&1; then
    echo "run.sh: FAIL timeout(1) is required (coreutils)" >&2
    exit 2
fi

if [[ "$harness_sel" == "all" && ${#harnesses[@]} -eq 0 ]]; then
    echo "run.sh: no egresslock test harnesses found under $tests_dir" >&2
    exit 2
fi

# EGL-353-D1/D2: one env seam for the per-harness bound. Unset/empty
# keeps 600; anything else must be a positive integer of seconds and is
# refused here, before any harness starts. `timeout 0` would disable the
# bound (the EGL-78-D6 wedge class) and timeout(1) exits 125 on values it
# cannot parse, so neither may reach it.
HARNESS_TIMEOUT=600
if [[ -n "${EGRESSLOCK_HARNESS_TIMEOUT:-}" ]]; then
    _bound_raw="$EGRESSLOCK_HARNESS_TIMEOUT"
    if [[ ! "$_bound_raw" =~ ^[0-9]+$ ]]; then
        echo "run.sh: bad EGRESSLOCK_HARNESS_TIMEOUT value: '$_bound_raw' (expected a positive integer of seconds; default 600)" >&2
        exit 2
    fi
    # Strip leading zeros without arithmetic (a bare `0NN` is octal in
    # `$(( ))`); an all-zero value is `timeout 0`, i.e. unbounded.
    _bound="${_bound_raw#"${_bound_raw%%[!0]*}"}"
    if [[ -z "$_bound" ]]; then
        echo "run.sh: bad EGRESSLOCK_HARNESS_TIMEOUT value: '$_bound_raw' (0 means no timeout; expected a positive integer of seconds; default 600)" >&2
        exit 2
    fi
    HARNESS_TIMEOUT="$_bound"
    # EGL-353-D3: confirm a set override; the default path stays quiet.
    echo "run.sh: harness bound ${HARNESS_TIMEOUT}s (EGRESSLOCK_HARNESS_TIMEOUT)"
fi

# --- EGL-464: --section selection (fail closed before any test) ----------
# Names are the `test-engine.sh --list-sections` output. Parse the
# comma-separated list (trim each item), refuse an empty selection, a
# duplicate, or an unknown name here — before any harness starts. The
# selection is handed to the harness through EGL-451's existing
# EGRESSLOCK_TEST_SHARDED/EGRESSLOCK_TEST_SECTIONS seam, whose own
# fail-closed checks (a selected section never began / emitted no
# RESULTS line) then apply inside the run.
engine_harness="$tests_dir/test-engine.sh"
section_names=""   # space-delimited, the harness seam's shape
if (( section_mode )); then
    declare -A section_known=() section_picked=()
    declare -a section_listed=()
    if [[ ! -f "$engine_harness" ]]; then
        echo "run.sh: FAIL engine harness not found: $engine_harness (--section; EGL-464)" >&2
        exit 2
    fi
    mapfile -t section_listed < <(bash "$engine_harness" --list-sections)
    if (( ${#section_listed[@]} == 0 )); then
        echo "run.sh: FAIL engine harness printed no sections (--list-sections; EGL-464)" >&2
        exit 2
    fi
    for s in "${section_listed[@]}"; do
        section_known[$s]=1
    done
    _section_rest="$section_sel"
    while :; do
        if [[ "$_section_rest" == *,* ]]; then
            s="${_section_rest%%,*}"
            _section_rest="${_section_rest#*,}"
            _section_more=1
        else
            s="$_section_rest"
            _section_more=0
        fi
        # Trim leading/trailing whitespace without external tools.
        s="${s#"${s%%[![:space:]]*}"}"
        s="${s%"${s##*[![:space:]]}"}"
        if [[ -z "$s" ]]; then
            echo "run.sh: --section has an empty name (expected name[,name...]; EGL-464)" >&2
            exit 2
        fi
        if [[ -z "${section_known[$s]:-}" ]]; then
            echo "run.sh: --section unknown section '$s' (see: bash tests/test-engine.sh --list-sections; EGL-464)" >&2
            exit 2
        fi
        if [[ -n "${section_picked[$s]:-}" ]]; then
            echo "run.sh: --section duplicate section '$s' (EGL-464)" >&2
            exit 2
        fi
        section_picked[$s]=1
        section_names+="${section_names:+ }$s"
        (( _section_more )) || break
    done
    if [[ -z "$section_names" ]]; then
        echo "run.sh: --section requires at least one section name (EGL-464)" >&2
        exit 2
    fi
fi

# --- EGL-451: shard planning ---------------------------------------------
# Detected CPUs: ceil(cgroup v2 quota/period) when the quota is numeric,
# else nproc. The local container reports nproc=8 but cpu.max=300000/100000
# = 3; CI's job container is --cpus=2.
detect_cpus() {
    local quota period cpus=""
    if [[ -r /sys/fs/cgroup/cpu.max ]]; then
        read -r quota period < /sys/fs/cgroup/cpu.max || true
        if [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ ]] && (( period > 0 )); then
            cpus=$(( (quota + period - 1) / period ))
        fi
    fi
    if [[ -z "$cpus" ]]; then
        cpus="$(nproc 2>/dev/null || true)"
    fi
    if [[ ! "$cpus" =~ ^[0-9]+$ ]] || (( cpus < 1 )); then
        cpus=1
    fi
    printf '%s\n' "$cpus"
}

if (( serial_sel )) && [[ -n "$shard_sel" ]]; then
    echo "run.sh: --serial and --shard are mutually exclusive" >&2
    exit 2
fi
if [[ -n "$shard_sel" && "$harness_sel" != "engine" && "$harness_sel" != "all" ]]; then
    echo "run.sh: --shard applies to the engine harness only (got --harness $harness_sel)" >&2
    exit 2
fi

engine_harness="$tests_dir/test-engine.sh"
shard_mode="serial"   # serial | all | single
shard_total=0
shard_index=0
if [[ -n "$shard_sel" ]]; then
    if [[ "$shard_sel" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        shard_index=$((10#${BASH_REMATCH[1]}))
        shard_total=$((10#${BASH_REMATCH[2]}))
        if (( shard_index < 1 || shard_total < 1 || shard_index > shard_total )); then
            echo "run.sh: bad --shard value: '$shard_sel' (expected N/M with 1 <= N <= M)" >&2
            exit 2
        fi
        if (( shard_total == 1 )); then
            shard_mode="serial"
        else
            shard_mode="single"
        fi
    elif [[ "$shard_sel" =~ ^[0-9]+$ ]]; then
        shard_total=$((10#$shard_sel))
        if (( shard_total < 1 )); then
            echo "run.sh: bad --shard value: '$shard_sel' (expected a positive integer)" >&2
            exit 2
        fi
        if (( shard_total == 1 )); then
            shard_mode="serial"
        else
            shard_mode="all"
        fi
    else
        echo "run.sh: bad --shard value: '$shard_sel' (expected M or N/M)" >&2
        exit 2
    fi
elif (( serial_sel )); then
    shard_mode="serial"
elif (( ! section_mode )) && [[ "$harness_sel" == "engine" || "$harness_sel" == "all" ]]; then
    _cpus="$(detect_cpus)"
    shard_total=$(( _cpus < 3 ? _cpus : 3 ))
    (( shard_total < 1 )) && shard_total=1
    if (( shard_total > 1 )); then
        shard_mode="all"
    fi
fi

# EGL-497 D3: lite always takes the shard path — even when `--shard 1` or
# a single-CPU host selected the serial path — because the serial path
# unsets EGRESSLOCK_TEST_SECTIONS and would run the full engine. A
# one-bin pack (shard_mode=all, shard_total=1) is allowed; `--shard N/M`
# stays a single debug window with its own partial TOTAL. No engine
# harness selected -> nothing to force.
if [[ "$track_sel" == "lite" && "$shard_mode" == "serial" \
      && ( "$harness_sel" == "engine" || "$harness_sel" == "all" ) ]]; then
    shard_mode="all"
    (( shard_total < 1 )) && shard_total=1
fi

declare -a sections=()
declare -a bin_names=()
declare -a bin_load=()
if [[ "$shard_mode" != "serial" ]]; then
    if [[ ! -f "$engine_harness" ]]; then
        echo "run.sh: FAIL engine harness not found: $engine_harness" >&2
        exit 2
    fi
    mapfile -t sections < <(bash "$engine_harness" --list-sections)
    if (( ${#sections[@]} == 0 )); then
        echo "run.sh: FAIL engine harness printed no sections (--list-sections; EGL-451)" >&2
        exit 2
    fi
    declare -A section_seen=()
    for s in "${sections[@]}"; do
        if [[ -n "${section_seen[$s]:-}" ]]; then
            echo "run.sh: FAIL duplicate section '$s' in the harness --list-sections (EGL-451 fail-closed)" >&2
            exit 2
        fi
        section_seen[$s]=1
    done
    weights_file="$tests_dir/shard-weights.tsv"
    if [[ ! -f "$weights_file" ]]; then
        echo "run.sh: FAIL shard weights not found: $weights_file (EGL-451)" >&2
        exit 2
    fi
    declare -A weight=()
    declare -A weight_seen=()
    while IFS=$'\t' read -r wname wms wextra; do
        [[ "$wname" =~ ^[[:space:]]*$ ]] && continue
        [[ "$wname" =~ ^[[:space:]]*# ]] && continue
        if [[ -n "$wextra" || ! "$wms" =~ ^[0-9]+$ ]]; then
            echo "run.sh: bad shard weight row: '$wname' (expected name<TAB>positive-milliseconds)" >&2
            exit 2
        fi
        wms=$((10#$wms))
        if (( wms < 1 )); then
            echo "run.sh: bad shard weight for '$wname': '$wms' (expected a positive integer of milliseconds)" >&2
            exit 2
        fi
        if [[ -n "${weight_seen[$wname]:-}" ]]; then
            echo "run.sh: duplicate shard weight for '$wname' (EGL-451 fail-closed)" >&2
            exit 2
        fi
        weight_seen[$wname]=1
        weight[$wname]=$wms
    done < "$weights_file"

    declare -A in_list=()
    declare -a missing=() extra=()
    for s in "${sections[@]}"; do
        in_list[$s]=1
        [[ -n "${weight[$s]:-}" ]] || missing+=( "$s" )
    done
    for w in "${!weight[@]}"; do
        [[ -n "${in_list[$w]:-}" ]] || extra+=( "$w" )
    done
    if (( ${#missing[@]} > 0 || ${#extra[@]} > 0 )); then
        echo "run.sh: FAIL shard weights disagree with the harness section list (EGL-451 fail-closed)" >&2
        (( ${#missing[@]} > 0 )) && echo "run.sh: missing weight(s): ${missing[*]}" >&2
        (( ${#extra[@]} > 0 )) && echo "run.sh: unknown section(s): ${extra[*]}" >&2
        exit 2
    fi

    # EGL-451-F5: `--list-sections` proves a section exists; it does not
    # prove the sharder can select it. A removed (or duplicated) window
    # guard would run that body in every shard or in none while the pinned
    # TOTAL/section evidence stayed green. Verify each listed section has
    # exactly one `if shard_section_run <name>; then` window gate in the
    # harness source (a slow-section wrapper may sit between the gate and
    # `section_begin`); a gate for an unknown name is also refused. The two
    # tail alias gates (arc14 on arc12, egl140 on egl139) wrap manual
    # RESULTS echoes, not windows, and do not count here.
    declare -A gate_windows=()
    declare -A alias_labels=()
    declare -A alias_counts=()
    while IFS=$'\t' read -r _kind _gname _gmode _gline _glabel; do
        [[ "$_kind" == "GATE" ]] || continue
        if [[ -z "${section_seen[$_gname]:-}" ]]; then
            echo "run.sh: FAIL shard gate for unknown section '$_gname' at $engine_harness:$_gline (EGL-451 fail-closed)" >&2
            exit 2
        fi
        if [[ "$_gmode" == "invalid" ]]; then
            echo "run.sh: FAIL shard gate for '$_gname' at $engine_harness:$_gline does not wrap a section window or a manual RESULTS alias (EGL-451 fail-closed)" >&2
            exit 2
        fi
        if [[ "$_gmode" == "window" ]]; then
            gate_windows[$_gname]=$(( ${gate_windows[$_gname]:-0} + 1 ))
        elif [[ "$_gmode" == "alias" ]]; then
            alias_counts[$_gname]=$(( ${alias_counts[$_gname]:-0} + 1 ))
            alias_labels[$_gname]+="${alias_labels[$_gname]:+, }$_glabel"
        fi
    done < <(awk '
        /^if shard_section_run [A-Za-z0-9_]+; then$/ {
            name = $3
            sub(/;$/, "", name)
            start = NR
            mode = "invalid"
            label = ""
            while ((getline line) > 0) {
                if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*#/) continue
                if (line == "if slow_section_run " name "; then") continue
                if (line ~ ("^section_begin[[:space:]]+" name "([[:space:]]|$)")) mode = "window"
                else if (line ~ /^[[:space:]]*echo "RESULTS \(/) {
                    mode = "alias"
                    label = line
                    sub(/^.*RESULTS \(/, "", label)
                    sub(/[[:space:])].*$/, "", label)
                    label = tolower(label)
                    gsub(/[^a-z0-9]/, "", label)
                }
                break
            }
            print "GATE\t" name "\t" mode "\t" start "\t" label
        }
    ' "$engine_harness")
    # EGL-532-D7: an alias gate must name the expected ticket. A bare
    # `RESULTS (<label>)` under any known gate name would otherwise pass as
    # a 0/0 alias (the tail witnesses are manual counters). Require exactly
    # one alias gate per expected pairing; any other, missing, or duplicate
    # pairing exits 2 before a shard starts. Count each gate separately
    # (EGL-532 F1): a label that normalizes to empty must not vanish into
    # the aggregate, so the order of a duplicate cannot hide it.
    declare -A alias_expect=([arc12]=arc14 [egl139]=egl140)
    for _an in "${!alias_expect[@]}"; do
        if (( ${alias_counts[$_an]:-0} != 1 )) \
           || [[ "${alias_labels[$_an]:-}" != "${alias_expect[$_an]}" ]]; then
            echo "run.sh: FAIL alias gate '$_an' must pair exactly once with '${alias_expect[$_an]}' (found ${alias_counts[$_an]:-0} gate(s): '${alias_labels[$_an]:-<none>}') at $engine_harness (EGL-532 fail-closed)" >&2
            exit 2
        fi
    done
    for _an in "${!alias_labels[@]}"; do
        if [[ -z "${alias_expect[$_an]:-}" ]]; then
            echo "run.sh: FAIL unexpected RESULTS alias gate '$_an' (labels: '${alias_labels[$_an]}') at $engine_harness (EGL-532 fail-closed)" >&2
            exit 2
        fi
    done
    declare -a gate_missing=()
    for s in "${sections[@]}"; do
        if (( ${gate_windows[$s]:-0} != 1 )); then
            gate_missing+=( "$s (${gate_windows[$s]:-0} window gate(s))" )
        fi
    done
    if (( ${#gate_missing[@]} > 0 )); then
        echo "run.sh: FAIL shard window gates do not match the harness section list — expected exactly one \`if shard_section_run <name>; then\` per section (EGL-451 fail-closed)" >&2
        echo "run.sh: section(s): ${gate_missing[*]}" >&2
        exit 2
    fi

    # EGL-497 D2: apply the lite selection AFTER the full-set checks above
    # (harness list, duplicate names, weights exact-set, one window gate
    # per section), so a lite run still proves the EGL-451 sharder
    # contract over every section, and BEFORE the LPT packing, so the
    # shard children receive only the validated core list. An unknown or
    # duplicate lite name fails closed here; the deferred count feeds the
    # parent-rendered TOTAL (D6).
    if [[ "$track_sel" == "lite" ]]; then
        if (( ${#LITE_SECTIONS[@]} == 0 )); then
            echo "run.sh: FAIL LITE_SECTIONS is empty — no engine sections would run on --track lite (EGL-497 fail-closed)" >&2
            exit 2
        fi
        declare -A _lite_seen=()
        for s in "${LITE_SECTIONS[@]}"; do
            if [[ -n "${_lite_seen[$s]:-}" ]]; then
                echo "run.sh: FAIL duplicate lite section '$s' in LITE_SECTIONS (EGL-497 fail-closed)" >&2
                exit 2
            fi
            _lite_seen[$s]=1
            if [[ -z "${section_seen[$s]:-}" ]]; then
                echo "run.sh: FAIL lite section '$s' is not in the harness --list-sections (EGL-497 fail-closed)" >&2
                exit 2
            fi
        done
        lite_deferred=$(( ${#sections[@]} - ${#LITE_SECTIONS[@]} ))
        (( lite_deferred < 0 )) && lite_deferred=0
        sections=( "${LITE_SECTIONS[@]}" )
    fi

    # Longest-processing-time packing: weight descending, source order as
    # the tie-break; each section goes to the least-loaded bin (lowest bin
    # index on a tie). M <= sections is enforced by the empty-bin check.
    for ((i=0; i<shard_total; i++)); do
        bin_names[i]=""
        bin_load[i]=0
    done
    while IFS=$'\t' read -r _idx _w _name; do
        _best=0
        for ((b=1; b<shard_total; b++)); do
            if (( bin_load[b] < bin_load[_best] )); then _best=$b; fi
        done
        bin_names[_best]+="${bin_names[_best]:+ }$_name"
        bin_load[_best]=$(( bin_load[_best] + _w ))
    done < <(
        for ((i=0; i<${#sections[@]}; i++)); do
            s="${sections[i]}"
            printf '%d\t%d\t%s\n' "$i" "${weight[$s]}" "$s"
        done | sort -t $'\t' -k2,2nr -k1,1n
    )
    for ((i=0; i<shard_total; i++)); do
        if [[ -z "${bin_names[i]}" ]]; then
            echo "run.sh: FAIL shard $((i+1))/$shard_total has no sections (EGL-451; M exceeds the section count)" >&2
            exit 2
        fi
    done
fi

# EGL-558: whole-set closing block state (D2). The battery aggregate prints
# only when every harness the `all` selection runs did run: not under
# --section (engine-only subset) and not under a single debug --shard N/M.
# --track fast and --serial still print it. The records are transient and
# live beside the shard work dirs until the closing block consumes them.
#
# The record path is run.sh-internal: drop any inherited copy first, the
# same stale-env hygiene run_harness applies to EGL-451's shard variables,
# so a nested run.sh cannot write into an outer run's record.
unset EGRESSLOCK_TEST_BATTERY_RESULT
battery_on=0
battery_dir=""
battery_current_result=""
if [[ "$harness_sel" == "all" ]] && (( ! section_mode )) && [[ "$shard_sel" != */* ]]; then
    battery_on=1
    battery_dir="$(mktemp -d /tmp/egl558-battery.XXXXXX)" || {
        echo "run.sh: FAIL cannot create the battery result directory (EGL-558)" >&2
        exit 2
    }
fi

# EGL-86-D3: per-harness tee logs for the end-of-suite skip summary.
skip_logs=()
rc=0

run_harness() { # run_harness <path> [keep-section-env] — the pre-EGL-451 single-process path
    local h="$1" keep_section="${2:-}"
    if [[ ! -x "$h" ]]; then
        echo "run.sh: FAIL harness not executable: $h" >&2
        rc=1
        return
    fi
    # EGL-451-F1: the shard variables are run.sh-internal. A stale exported
    # copy in the caller's environment must never turn this one-process path
    # into a filtered partial run (a non-empty non-matching section list
    # would skip every engine window and still print a green 0/0/0 TOTAL).
    # EGL-464: `--section` deliberately sets the same seam for its subset
    # run, so only that caller keeps it.
    if [[ "$keep_section" != "keep-section-env" ]]; then
        unset EGRESSLOCK_TEST_SHARDED EGRESSLOCK_TEST_SECTIONS \
            EGRESSLOCK_TEST_SHARD_PROGRESS EGRESSLOCK_TEST_SHARD_RESULT
    fi
    echo "== egresslock tests: $h =="
    local hrc=0 h_t0 h_log
    h_t0="$(date +%s)"   # EGL-270 (P1): per-harness runtime stamp
    h_log="$(mktemp /tmp/egl86-run-log.XXXXXX)"
    skip_logs+=( "$h_log" )
    # EGL-78-1-F1: stdin is /dev/null — a script(1) inside the harness can
    # otherwise wedge on the never-EOF relay, defeating the timeout (bash
    # defers SIGTERM while waiting on a foreground child).
    # EGL-86-D3: stdout+stderr merge through tee for the visible run and
    # SKIP collection; PIPESTATUS[0] preserves the harness rc.
    if command -v stdbuf >/dev/null 2>&1; then
        timeout "${tf_args[@]}" "$HARNESS_TIMEOUT" stdbuf -oL -eL bash "$h" </dev/null 2>&1 | tee "$h_log"
        hrc=${PIPESTATUS[0]}
    else
        timeout "${tf_args[@]}" "$HARNESS_TIMEOUT" bash "$h" </dev/null 2>&1 | tee "$h_log"
        hrc=${PIPESTATUS[0]}
    fi
    if (( hrc == 124 )); then
        # EGL-78-D3: a timeout is a FAIL, never a skip; keep rc clean (no 124).
        echo "run.sh: FAIL $h timeout after ${HARNESS_TIMEOUT}s (set EGRESSLOCK_HARNESS_TIMEOUT=<seconds> to change the bound)" >&2
        rc=1
    elif (( hrc == 137 )); then
        # EGL-80-1-F2: a harness that defied the TERM is SIGKILLed at
        # bound+kill-after (timeout rc 137); same classification as 124.
        # rc 137 must never leak as the battery rc (contract 0/1/2).
        echo "run.sh: FAIL $h timeout after ${HARNESS_TIMEOUT}s (TERM defied; kill-after SIGKILL fired; set EGRESSLOCK_HARNESS_TIMEOUT=<seconds> to change the bound)" >&2
        rc=1
    elif (( hrc != 0 )); then
        rc=$hrc; echo "run.sh: FAIL $h (rc=$rc)" >&2
    fi
    # EGL-270 (P1): per-harness runtime line — bookkeeping, not RESULTS (EGL-99).
    echo "run.sh: harness $(basename "$h") $(( $(date +%s) - h_t0 ))s"
}

shard_work=""
declare -a shard_pids=()
shards_running=0
_cleanup_done=0
# EGL-451-F6: each shard command runs in its own session (setsid) so
# cancellation can signal the whole process group, including descendants
# that a shard's direct parent no longer owns. Without setsid, fall back
# to a recursive (ppid) tree walk.
_shard_setsid=0
if command -v setsid >/dev/null 2>&1; then
    _shard_setsid=1
fi
_own_pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' || true)"
_shard_group_signal() { # <pgid> <TERM|KILL> — signal a shard's own session group
    local pg="$1" sig="$2"
    [[ "$pg" =~ ^[0-9]+$ ]] || return 0
    (( pg > 1 )) || return 0
    [[ "$pg" != "$$" ]] || return 0
    # Never signal our own process group if setsid did not detach.
    [[ -n "$_own_pgid" && "$pg" == "$_own_pgid" ]] && return 0
    kill -"$sig" -- "-$pg" 2>/dev/null || true
}
_shard_group_alive() { # <pgid> — true while any process remains in the group
    local pg="$1"
    [[ "$pg" =~ ^[0-9]+$ ]] || return 1
    (( pg > 1 )) || return 1
    [[ "$pg" != "$$" ]] || return 1
    [[ -n "$_own_pgid" && "$pg" == "$_own_pgid" ]] && return 1
    kill -0 -- "-$pg" 2>/dev/null
}
_shard_kill_tree() { # <pid> [TERM|KILL] — signal this pid's descendants leaf-first, then it
    local p="$1" sig="${2:-TERM}" c
    [[ -n "$p" ]] || return 0
    while read -r c; do
        [[ -n "$c" ]] && _shard_kill_tree "$c" "$sig"
    done < <(ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$p" '$2 == parent { print $1 }')
    kill -"$sig" "$p" 2>/dev/null || true
}
cleanup_shards() {
    # EGL-451-F6: a cancelled battery must not orphan the shard processes.
    # Each shard command was started in its own session; signal that whole
    # process group TERM (covers children that were already reparented,
    # e.g. a mock's background rotation) and walk the remaining ppid tree
    # leaf-first. Bash defers its own TERM while waiting on a foreground
    # child, so descendants must be signalled before their parents. After a
    # bounded grace, KILL the groups and any survivors: a SIGSTOPped or
    # TERM-ignoring descendant must not keep mutating mock state (or block
    # `wait`) after the parent exits. Idempotent (the EXIT trap runs again
    # after a signal trap).
    (( _cleanup_done )) && return 0
    _cleanup_done=1
    local p c pg
    local -a groups=()
    if (( shards_running )); then
        if (( _shard_setsid )) && [[ -n "$shard_work" ]]; then
            for c in "$shard_work"/shard-*.cmdpid; do
                [[ -f "$c" ]] || continue
                read -r p < "$c" || p=""
                [[ "$p" =~ ^[0-9]+$ ]] && groups+=( "$p" )
            done
        fi
        for pg in "${groups[@]:-}"; do
            _shard_group_signal "$pg" TERM
        done
        for p in "${shard_pids[@]:-}"; do
            _shard_kill_tree "$p" TERM
        done
        # Bounded grace for normal TERM handling; poll at 100 ms.
        local i any
        for i in {1..50}; do
            any=0
            for pg in "${groups[@]:-}"; do
                if _shard_group_alive "$pg"; then any=1; break; fi
            done
            if (( any == 0 )); then
                for p in "${shard_pids[@]:-}"; do
                    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then any=1; break; fi
                done
            fi
            (( any )) || break
            sleep 0.1
        done
        # A stopped or TERM-defying descendant must not survive the parent.
        for pg in "${groups[@]:-}"; do
            _shard_group_signal "$pg" KILL
        done
        for p in "${shard_pids[@]:-}"; do
            _shard_kill_tree "$p" KILL
        done
        for p in "${shard_pids[@]:-}"; do
            [[ -n "$p" ]] && wait "$p" 2>/dev/null || true
        done
    fi
    [[ -n "$shard_work" ]] && rm -rf "$shard_work"
    # EGL-558: the battery records are transient like the shard work dir.
    [[ -n "${battery_dir:-}" ]] && rm -rf "$battery_dir"
    return 0
}
trap cleanup_shards EXIT
trap 'cleanup_shards; exit 143' TERM
trap 'cleanup_shards; exit 130' INT

run_shard_bg() { # <i> <M> <sections> <log> <result> <progress> <rcfile> <timefile> <cmdpidfile>
    local i="$1" m="$2" secs="$3" log="$4" result="$5" progress="$6" rcfile="$7" timefile="$8" cmdpidfile="$9"
    local t0 jrc=0 cpid
    t0="$(date +%s)"
    : > "$progress"
    # EGL-558: the battery record path is per harness. A shard child must
    # never inherit the parent's path — its results_total would overwrite
    # the merged engine record with one shard's partial counts.
    unset EGRESSLOCK_TEST_BATTERY_RESULT
    export EGRESSLOCK_TEST_SHARDED=1
    export EGRESSLOCK_TEST_SECTIONS="$secs"
    export EGRESSLOCK_TEST_SHARD_PROGRESS="$progress"
    if [[ -n "$result" ]]; then
        export EGRESSLOCK_TEST_SHARD_RESULT="$result"
    else
        unset EGRESSLOCK_TEST_SHARD_RESULT
    fi
    # EGL-451-F6: run the bounded command as a background child and record
    # its pid so the parent's signal trap can terminate it directly (and
    # through it the harness). `wait` below still captures the exact rc.
    # The command gets its own session/process group (setsid) so cleanup
    # can signal every descendant, including already-reparented helpers,
    # and KILL a stopped survivor after the TERM grace. The child writes
    # its own pid (the session leader/pgid) before exec.
    local -a shard_cmd=()
    if command -v stdbuf >/dev/null 2>&1; then
        shard_cmd=( timeout "${tf_args[@]}" "$HARNESS_TIMEOUT" stdbuf -oL -eL bash "$engine_harness" )
    else
        shard_cmd=( timeout "${tf_args[@]}" "$HARNESS_TIMEOUT" bash "$engine_harness" )
    fi
    if (( _shard_setsid )); then
        setsid -w bash -c 'printf "%s\n" "$$" > "$1" || exit 1; shift; exec "$@"' \
            _ "$cmdpidfile" "${shard_cmd[@]}" </dev/null >"$log" 2>&1 &
    else
        "${shard_cmd[@]}" </dev/null >"$log" 2>&1 &
        cpid=$!
        printf '%s\n' "$cpid" > "$cmdpidfile" 2>/dev/null || true
    fi
    cpid=$!
    # Do not race cleanup: make sure the pid file exists before waiting.
    local i
    for i in {1..100}; do
        [[ -s "$cmdpidfile" ]] && break
        sleep 0.01
    done
    wait "$cpid"
    jrc=$?
    printf '%s\n' "$jrc" > "$rcfile"
    printf '%s\n' "$(( $(date +%s) - t0 ))" > "$timefile"
}

report_shard() { # <i> <M> <log> <rcfile> <timefile> <progress>
    local i="$1" m="$2" log="$3" rcfile="$4" timefile="$5" progress="$6"
    local jrc sect
    jrc="$(cat "$rcfile" 2>/dev/null || echo 99)"
    # Not the `== egresslock tests: <path> ==` evidence boundary shape:
    # a shard log is not a complete harness, and ci-status.sh requires
    # exactly one boundary + one RESULTS TOTAL per harness. The parent
    # prints the canonical engine boundary before the merged TOTAL.
    echo "== egresslock tests [shard $i/$m]: $engine_harness =="
    cat "$log"
    skip_logs+=( "$log" )
    if (( jrc == 124 || jrc == 137 )); then
        sect=""
        [[ -s "$progress" ]] && sect="$(head -1 "$progress")"
        echo "run.sh: FAIL shard $i/$m timed out on ${sect:-(no section begun)} after ${HARNESS_TIMEOUT}s (set EGRESSLOCK_HARNESS_TIMEOUT=<seconds> to change the bound)" >&2
        rc=1
    elif (( jrc != 0 )); then
        echo "run.sh: FAIL shard $i/$m (rc=$jrc)" >&2
        rc=1
    fi
    echo "run.sh: harness $(basename "$engine_harness") shard $i/$m $(cat "$timefile" 2>/dev/null || echo '?')s"
}

# EGL-558: write one battery record in EGL-451's tab schema. Same
# write-then-rename publication as the harness-side writer
# (tests/lib.sh battery_result_publish); run.sh cannot source lib.sh
# (it seeds a mock battery), so the two writers are kept byte-compatible
# by the scratch probes in tests/test-kit.sh. <file> <pass> <fail>
# <ext_pass> <ext_fail> <skips> <tree> [cause count]...
battery_result_write() {
    local b_rf="$1" b_pass="$2" b_fail="$3" b_ep="$4" b_ef="$5" b_sk="$6" b_tree="$7"
    shift 7
    local b_tmp="$b_rf.tmp.$$"
    if ! {
        printf 'pass\t%s\n' "$b_pass"
        printf 'fail\t%s\n' "$b_fail"
        printf 'ext_pass\t%s\n' "$b_ep"
        printf 'ext_fail\t%s\n' "$b_ef"
        printf 'skips\t%s\n' "$b_sk"
        while (( $# >= 2 )); do
            printf 'skip_cause\t%s\t%s\n' "$1" "$2"
            shift 2
        done
        printf 'tree\t%s\n' "$b_tree"
    } > "$b_tmp"; then
        echo "run.sh: FAIL cannot write battery result '$b_tmp' (EGL-558 fail-closed)" >&2
        rm -f -- "$b_tmp"
        return 1
    fi
    if ! mv -f -- "$b_tmp" "$b_rf"; then
        echo "run.sh: FAIL cannot publish battery result '$b_rf' (EGL-558 fail-closed)" >&2
        rm -f -- "$b_tmp"
        return 1
    fi
    return 0
}

# EGL-558: read one per-harness battery record, print its subtotal row and
# add it to the battery counters (battery_pass/fail/skips/tree). A
# missing, malformed, or tree-disagreeing record is a named refusal: the
# caller prints no BATTERY TOTAL and forces a nonzero rc (D5). Records are
# written by the harnesses (tests/lib.sh) or by merge_shard_results for the
# sharded engine; no human text is re-parsed.
battery_record_read() { # <harness> <file> — 0 = usable, 1 = refuse
    local h="$1" rf="$2"
    local key val extra
    local p=0 f=0 ep=0 ef=0 sk=0 tree=""
    local have_p=0 have_f=0 have_ep=0 have_ef=0 have_sk=0 have_tree=0
    local unavailable="run.sh: FAIL battery TOTAL unavailable — $h (EGL-558)"
    if [[ ! -f "$rf" ]]; then
        echo "$unavailable" >&2
        return 1
    fi
    while IFS=$'\t' read -r key val extra; do
        case "$key" in
            pass|fail|ext_pass|ext_fail|skips)
                if [[ ! "$val" =~ ^[0-9]+$ || -n "$extra" ]]; then
                    echo "$unavailable" >&2
                    return 1
                fi
                case "$key" in
                    pass) if (( have_p )); then echo "$unavailable" >&2; return 1; fi
                          p=$(( 10#$val )); have_p=1 ;;
                    fail) if (( have_f )); then echo "$unavailable" >&2; return 1; fi
                          f=$(( 10#$val )); have_f=1 ;;
                    ext_pass) if (( have_ep )); then echo "$unavailable" >&2; return 1; fi
                          ep=$(( 10#$val )); have_ep=1 ;;
                    ext_fail) if (( have_ef )); then echo "$unavailable" >&2; return 1; fi
                          ef=$(( 10#$val )); have_ef=1 ;;
                    skips) if (( have_sk )); then echo "$unavailable" >&2; return 1; fi
                          sk=$(( 10#$val )); have_sk=1 ;;
                esac
                ;;
            skip_cause)
                if [[ -z "$val" || ! "$extra" =~ ^[0-9]+$ ]]; then
                    echo "$unavailable" >&2
                    return 1
                fi
                ;;
            tree)
                if (( have_tree )) || [[ -n "$extra" ]]; then
                    echo "$unavailable" >&2
                    return 1
                fi
                tree="$val"; have_tree=1
                ;;
            *)
                echo "$unavailable" >&2
                return 1
                ;;
        esac
    done < "$rf"
    if (( !have_p || !have_f || !have_ep || !have_ef || !have_sk || !have_tree )); then
        echo "$unavailable" >&2
        return 1
    fi
    battery_pass=$(( battery_pass + p + ep ))
    battery_fail=$(( battery_fail + f + ef ))
    battery_skips=$(( battery_skips + sk ))
    echo "run.sh: subtotal — $h: $(( p + ep )) passed, $(( f + ef )) failed, $sk skipped"
    if [[ -n "$battery_tree" && "$tree" != "$battery_tree" ]]; then
        echo "$unavailable" >&2
        return 1
    fi
    battery_tree="$tree"
    return 0
}

merge_shard_results() { # <M> <result-prefix> — one parent-rendered TOTAL
    local m="$1" prefix="$2" i key val extra
    local pass=0 fail=0 ext_pass=0 ext_fail=0 skips=0
    local tree="" tree_prev="" tree_seen=0
    declare -A causes=()
    for ((i=1; i<=m; i++)); do
        local rf="$prefix$i.result"
        if [[ ! -f "$rf" ]]; then
            echo "run.sh: FAIL shard $i/$m produced no result file — no merged RESULTS TOTAL (incomplete; EGL-451)" >&2
            return 1
        fi
        local have_pass=0 have_fail=0 have_ep=0 have_ef=0 have_sk=0 have_tree=0
        while IFS=$'\t' read -r key val extra; do
            case "$key" in
                pass|fail|ext_pass|ext_fail|skips)
                    if [[ ! "$val" =~ ^[0-9]+$ ]]; then
                        echo "run.sh: FAIL shard $i/$m result: '$key' is not numeric ('$val'; EGL-451)" >&2
                        return 1
                    fi
                    case "$key" in
                        pass) pass=$(( pass + 10#$val )); have_pass=1 ;;
                        fail) fail=$(( fail + 10#$val )); have_fail=1 ;;
                        ext_pass) ext_pass=$(( ext_pass + 10#$val )); have_ep=1 ;;
                        ext_fail) ext_fail=$(( ext_fail + 10#$val )); have_ef=1 ;;
                        skips) skips=$(( skips + 10#$val )); have_sk=1 ;;
                    esac
                    ;;
                skip_cause)
                    if [[ -z "$val" || ! "$extra" =~ ^[0-9]+$ ]]; then
                        echo "run.sh: FAIL shard $i/$m result: malformed skip_cause row (EGL-451)" >&2
                        return 1
                    fi
                    causes["$val"]=$(( ${causes["$val"]:-0} + 10#$extra ))
                    ;;
                tree)
                    tree="$val"; have_tree=1
                    ;;
                *)
                    echo "run.sh: FAIL shard $i/$m result: unknown key '$key' (EGL-451)" >&2
                    return 1
                    ;;
            esac
        done < "$rf"
        if (( !have_pass || !have_fail || !have_ep || !have_ef || !have_sk || !have_tree )); then
            echo "run.sh: FAIL shard $i/$m result is incomplete — no merged RESULTS TOTAL (EGL-451)" >&2
            return 1
        fi
        if (( tree_seen )) && [[ "$tree" != "$tree_prev" ]]; then
            echo "run.sh: FAIL shard tree tags disagree ('$tree_prev' vs '$tree') — no merged RESULTS TOTAL (EGL-451)" >&2
            return 2
        fi
        tree_prev="$tree"; tree_seen=1
    done
    # EGL-497 D6: name the lite deferral in the parent-rendered TOTAL. It
    # is a synthetic engine-section count (never a harness SKIP line),
    # added beside the shards' real skip counts; only this parent merge
    # adds it, so --section and direct harness runs can never claim it.
    # The count is the full engine list minus the lite core list, so a
    # reader sees egl139 and the other deferred sections, not a silently
    # smaller green battery.
    if [[ "$track_sel" == "lite" ]] && (( lite_deferred > 0 )); then
        skips=$(( skips + lite_deferred ))
        causes["lite-deferred engine sections"]=$(( ${causes["lite-deferred engine sections"]:-0} + lite_deferred ))
        lite_total_printed=1
    fi
    local total_pass=$(( pass + ext_pass )) total_fail=$(( fail + ext_fail ))
    local detail="" cause
    for cause in "${!causes[@]}"; do
        if (( causes["$cause"] == 1 )); then
            detail+="${detail:+, }$cause"
        else
            detail+="${detail:+, }$cause: ${causes["$cause"]}"
        fi
    done
    if (( skips == 0 )); then
        echo "RESULTS TOTAL: $total_pass passed, $total_fail failed, 0 skipped ($tree)"
    else
        echo "RESULTS TOTAL: $total_pass passed, $total_fail failed, $skips skipped ($detail) ($tree)"
    fi
    # EGL-558: publish the merged engine record (the same numbers as the
    # line above) for the runner's battery aggregate. The parent writes it;
    # shard children never see the battery path (run_shard_bg unsets it).
    if [[ -n "${battery_current_result:-}" ]]; then
        local -a battery_cause_args=()
        for cause in "${!causes[@]}"; do
            battery_cause_args+=( "$cause" "${causes["$cause"]}" )
        done
        if ! battery_result_write "$battery_current_result" \
                "$pass" "$fail" "$ext_pass" "$ext_fail" "$skips" "$tree" \
                "${battery_cause_args[@]}"; then
            rc=1
        fi
    fi
    return 0
}

run_engine_shards() {
    local i
    shard_work="$(mktemp -d /tmp/egl451-shard.XXXXXX)" || {
        echo "run.sh: FAIL cannot create the shard work directory (EGL-451)" >&2
        exit 2
    }
    if [[ "$shard_mode" == "single" ]]; then
        local idx=$(( shard_index - 1 ))
        echo "run.sh: shard $shard_index/$shard_total (${bin_load[$idx]}ms, $(wc -w <<<"${bin_names[$idx]}") sections)"
        shards_running=1
        run_shard_bg "$shard_index" "$shard_total" "${bin_names[$idx]}" \
            "$shard_work/shard-$shard_index.log" "" \
            "$shard_work/shard-$shard_index.progress" \
            "$shard_work/shard-$shard_index.rc" "$shard_work/shard-$shard_index.time" \
            "$shard_work/shard-$shard_index.cmdpid" &
        shard_pids+=($!)
        wait "${shard_pids[-1]}"
        shards_running=0
        report_shard "$shard_index" "$shard_total" \
            "$shard_work/shard-$shard_index.log" "$shard_work/shard-$shard_index.rc" \
            "$shard_work/shard-$shard_index.time" "$shard_work/shard-$shard_index.progress"
        return
    fi
    echo "run.sh: sharding engine: $shard_total shards, ${#sections[@]} sections (weights tests/shard-weights.tsv)"
    if [[ "$track_sel" == "lite" ]]; then
        echo "run.sh: --track lite: ${#LITE_SECTIONS[@]} core engine sections (${lite_deferred} deferred to the full battery)"
    fi
    # The one canonical harness boundary for tier-0 evidence tooling; it
    # opens the section that the parent-rendered merged TOTAL closes.
    echo "== egresslock tests: $engine_harness =="
    local -a pids=()
    shards_running=1
    for ((i=1; i<=shard_total; i++)); do
        local idx=$(( i - 1 ))
        run_shard_bg "$i" "$shard_total" "${bin_names[$idx]}" \
            "$shard_work/shard-$i.log" "$shard_work/shard-$i.result" \
            "$shard_work/shard-$i.progress" "$shard_work/shard-$i.rc" \
            "$shard_work/shard-$i.time" "$shard_work/shard-$i.cmdpid" &
        pids[i]=$!
        shard_pids+=("$!")
    done
    for ((i=1; i<=shard_total; i++)); do
        wait "${pids[i]}" || true
    done
    shards_running=0
    for ((i=1; i<=shard_total; i++)); do
        report_shard "$i" "$shard_total" "$shard_work/shard-$i.log" \
            "$shard_work/shard-$i.rc" "$shard_work/shard-$i.time" \
            "$shard_work/shard-$i.progress"
    done
    merge_shard_results "$shard_total" "$shard_work/shard-"
    local mrc=$?
    if (( mrc == 2 )); then
        rc=2
    elif (( mrc != 0 )); then
        rc=1
    fi
}

# EGL-464: hand the validated subset to the engine harness through
# EGL-451's existing fail-closed seam (one process, named windows only).
if (( section_mode )); then
    export EGRESSLOCK_TEST_SHARDED=1
    export EGRESSLOCK_TEST_SECTIONS="$section_names"
fi

for h in "${harnesses[@]}"; do
    # EGL-558: one record path per harness for the closing battery block.
    battery_current_result=""
    if (( battery_on )); then
        battery_current_result="$battery_dir/$(basename "$h").result"
    fi
    if [[ "$h" == "$engine_harness" && "$shard_mode" != "serial" ]]; then
        run_engine_shards
        continue
    fi
    if (( section_mode )); then
        run_harness "$h" keep-section-env
    else
        if (( battery_on )); then
            export EGRESSLOCK_TEST_BATTERY_RESULT="$battery_current_result"
        fi
        run_harness "$h"
        unset EGRESSLOCK_TEST_BATTERY_RESULT
    fi
done
if (( section_mode )); then
    # The harness's RESULTS TOTAL covers only these windows; never let it
    # read as the battery total.
    echo "run.sh: --section partial TOTAL over: $section_names (not the battery total; EGL-464)"
fi
# EGL-86-D3: "N passed, 0 failed" must be distinguishable from "all
# applicable tests ran". Count `^SKIP:` lines across the teed logs, bucket
# by reason, and state the public tree's remaining coverage. Skips never
# change the exit code.
skip_total=0
declare -A skip_counts=()
for h_log in "${skip_logs[@]}"; do
    while IFS= read -r skip_line; do
        skip_total=$(( skip_total + 1 ))
        reason="${skip_line#SKIP: }"
        (( ${#reason} > 72 )) && reason="${reason:0:69}..."
        skip_counts["$reason"]=$(( ${skip_counts["$reason"]:-0} + 1 ))
    done < <(grep '^SKIP:' "$h_log" || true)
done
rm -f "${skip_logs[@]}"
skip_detail=""
for reason in "${!skip_counts[@]}"; do
    skip_detail+="${skip_detail:+; }${reason}: ${skip_counts["$reason"]}"
done
if (( skip_total > 0 )); then
    echo "run.sh: skips — ${skip_total} (${skip_detail})"
else
    echo "run.sh: skips — 0"
fi
if [[ "$track_sel" == "lite" && "$lite_total_printed" == 1 ]]; then
    # EGL-497 (D6): the merged TOTAL's synthetic count is engine sections,
    # not assertions, and the `run.sh: skips` line above counts only
    # harness `SKIP:` lines — a lite green must not read as the battery.
    # EGL-558: the battery line sums the merged harness totals, so it
    # carries the same synthetic count; say so beside the caveat.
    lite_agg=""
    if (( battery_on )); then
        lite_agg=" the BATTERY TOTAL below sums the harness totals, so its skipped count includes that deferred count;"
    fi
    echo "run.sh: --track lite — ${#LITE_SECTIONS[@]} core engine sections ran; the merged engine TOTAL's 'lite-deferred engine sections' count (${lite_deferred}) is deferred engine sections, not assertions, and the run.sh: skips line above counts only harness SKIP: lines;${lite_agg} run bash tests/run.sh for the full battery (handoff, nightly, release)"
elif [[ "$track_sel" == "fast" ]]; then
    # EGL-270 (G5): the full trailer would over-claim on a fast run.
    echo "run.sh: --track fast — registered slow sections were skipped (named above); run bash tests/run.sh for the full battery; remaining skips are the private-fixture / host-shape checks"
elif (( section_mode )); then
    # EGL-464: a subset run must not read as a full-battery coverage claim.
    echo "run.sh: --section subset — the rest of the battery was not run; use bash tests/run.sh for the full battery"
else
    echo "run.sh: public-tree coverage still includes .deb staging asserts, tarball staging, and prefix guards; skipped items above are the private-fixture / host-shape checks that need a tree with those fixtures present"
fi

# EGL-558: closing block (D3/D5/D6) — one `run.sh: subtotal —` row per
# harness with a usable record, then the battery-wide TOTAL as the last
# numeric line. Fail-closed: a missing/malformed record or disagreeing
# tree tags refuses the aggregate with a named failure and a nonzero rc; a
# partial sum never renders as BATTERY TOTAL (EGL-451 precedent).
if (( battery_on )); then
    battery_pass=0
    battery_fail=0
    battery_skips=0
    battery_tree=""
    battery_bad=0
    for h in "${harnesses[@]}"; do
        h_name="$(basename "$h")"
        if ! battery_record_read "$h_name" "$battery_dir/$h_name.result"; then
            battery_bad=1
        fi
    done
    if (( battery_bad )); then
        (( rc == 0 )) && rc=1
    else
        echo "BATTERY TOTAL: $battery_pass passed, $battery_fail failed, $battery_skips skipped ($battery_tree)"
    fi
    rm -rf -- "$battery_dir"
    battery_dir=""
fi

echo "run.sh: egresslock tests done (rc=$rc)"
exit "$rc"
