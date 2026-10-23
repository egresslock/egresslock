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
# opts in at `.forgejo/workflows/ci.yml`; the full battery stays the
# handoff/pre-release gate.
#
# EGL-86-D1/D2: the battery is non-root — refused, not skipped, under uid
# 0 (exit 2 after flag parsing, before harness selection). `--help` wins
# over the root gate.
#
# EGL-86-D3: each harness's output is teed to a temp log; at suite end
# `^SKIP:` lines are counted, bucketed by reason, and summarized as one
# `run.sh: skips` line plus a fixed coverage note. Skips never change rc.
#
# Run:  bash tests/run.sh [--help] [--harness engine|kit|docs|all]
#                                      [--track fast|full] [--no-foreground]
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
  --track fast|full       Run track (default: full). On --track fast the
                          registered slow sections (tests/lib.sh
                          _slow_sections; round 1: egl203r — egl223
                          stays per-push, security-classed, EGL-270)
                          are skipped with a named cause in each
                          harness's RESULTS TOTAL.
                          Default stays the full battery (EGL-79-D2);
                          `--track fast` is CI's per-push battery and
                          the local iteration shortcut.
  --no-foreground         Classic timeout isolation: on expiry the whole
                          harness process group is TERMed instead of the
                          direct child only. Default is foreground mode
                          (--foreground -k 15) so Ctrl+C cancels the
                          whole battery and a wedged harness is
                          SIGKILLed 15s after the TERM.

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
track_sel="full"   # EGL-270 (D1-B): default = full battery; unset/empty = full for harnesses too
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
            ;;
        --harness)
            if (( $# < 2 )); then
                echo "run.sh: --harness requires a value (engine|kit|docs|all)" >&2
                exit 2
            fi
            harness_sel="$2"
            shift
            ;;
        --track=*)
            track_sel="${1#*=}"
            ;;
        --track)
            if (( $# < 2 )); then
                echo "run.sh: --track requires a value (fast|full)" >&2
                exit 2
            fi
            track_sel="$2"
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

# EGL-86-D1/D2: root preflight — refuse, never skip. Under uid 0 the
# mocked root-guard and non-root-hook cases fail structurally; a skip
# would falsely report "all applicable tests passed" and could mask a
# real regression. Same exit class as usage (0/1/2); --help exited above.
if [[ "$(id -u)" == "0" ]]; then
    echo "run.sh: FAIL run tests as an unprivileged account — the battery's mocked root-guard and non-root-hook cases are structurally invalid under uid 0, so root execution is refused, not skipped (EGL-86-D2)" >&2
    echo "run.sh: in a root-only container, run mapped: setpriv --reuid=nobody --regid=nogroup --clear-groups env HOME=/tmp bash tests/run.sh" >&2
    exit 2
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

# EGL-270: validate the track and export the channel (direct runs stay full).
case "$track_sel" in
    fast|full) export EGRESSLOCK_TEST_TRACK="$track_sel" ;;
    *)
        echo "run.sh: bad --track value: '$track_sel' (expected fast|full)" >&2
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

HARNESS_TIMEOUT=600

# EGL-86-D3: per-harness tee logs for the end-of-suite skip summary.
skip_logs=()
rc=0
for h in "${harnesses[@]}"; do
    if [[ ! -x "$h" ]]; then
        echo "run.sh: FAIL harness not executable: $h" >&2
        rc=1
        continue
    fi
    echo "== egresslock tests: $h =="
    hrc=0
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
        echo "run.sh: FAIL $h timeout after ${HARNESS_TIMEOUT}s" >&2
        rc=1
    elif (( hrc == 137 )); then
        # EGL-80-1-F2: a harness that defied the TERM is SIGKILLed at
        # bound+kill-after (timeout rc 137); same classification as 124.
        # rc 137 must never leak as the battery rc (contract 0/1/2).
        echo "run.sh: FAIL $h timeout after ${HARNESS_TIMEOUT}s (TERM defied; kill-after SIGKILL fired)" >&2
        rc=1
    elif (( hrc != 0 )); then
        rc=$hrc; echo "run.sh: FAIL $h (rc=$rc)" >&2
    fi
    # EGL-270 (P1): per-harness runtime line — bookkeeping, not RESULTS (EGL-99).
    echo "run.sh: harness $(basename "$h") $(( $(date +%s) - h_t0 ))s"
done

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
if [[ "$track_sel" == "fast" ]]; then
    # EGL-270 (G5): the full trailer would over-claim on a fast run.
    echo "run.sh: --track fast — registered slow sections were skipped (named above); run bash tests/run.sh for the full battery; remaining skips are the private-fixture / host-shape checks"
else
    echo "run.sh: public-tree coverage still includes .deb staging asserts, tarball staging, and prefix guards; skipped items above are the private-fixture / host-shape checks that need a tree with those fixtures present"
fi

echo "run.sh: egresslock tests done (rc=$rc)"
exit "$rc"
