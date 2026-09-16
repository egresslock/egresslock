#!/usr/bin/env bash
#
# tests/run.sh — THE product-tree test entry point (ARC-74-D2).
# Runs the product test-*.sh harnesses beside this script and fails closed
# if a selected harness is missing or not executable, so reviewers (and
# the standalone egresslock repo after ARC-75) cannot skip a battery by
# accident.
#
# EGL-78-D2/D3/D6: every harness runs inside `timeout 300` so a single
# hanging check (wedged probe, stuck pty, unexpected real binary on PATH)
# is a NAMED FAILURE, never a wedged battery. A timeout is a FAIL — never
# a skip. When `stdbuf` is present, each harness runs as
# `stdbuf -oL -eL bash "$h"` inside the timeout so PASS lines flush before
# a later hang; without stdbuf the harness runs unmodified (not a failure).
#
# EGL-79-D2: `--help/-h` prints usage and exits 0 (no battery);
# `--harness engine|kit|all` selects a subset (default `all` = today's
# `test-*.sh` glob). Unknown options / bad values exit 2.
#
# Run:  bash tests/run.sh [--help] [--harness engine|kit|all]
#                                      [--no-foreground]
#
# Exit codes: 0 all harnesses green; 1 one or more harnesses failed
# (failing harnesses' rc 0 with FAIL lines are caught through the
# harnesses' final test; a harness timeout is also rc 1); 2 usage error
# (bad flags, no harnesses found, or timeout(1) missing).

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: bash tests/run.sh [options]

  --help, -h              Show this help and exit 0
  --harness engine|kit|all
                          Which test-*.sh to run (default: all)
  --no-foreground         Classic timeout isolation: on expiry the whole
                          harness process group is TERMed instead of the
                          direct child only. Default is foreground mode
                          (--foreground -k 15) so Ctrl+C cancels the
                          whole battery and a wedged harness is
                          SIGKILLed 15s after the TERM.

Layers (taxonomy; not selectable flags in this ticket):
  1 public unit/integration  — test-engine.sh + test-kit.sh
  2 public security regs.    — mixed into those harnesses
  3 private/adversarial      — not in this tree (must not ship)

Exit: 0 all green; 1 a harness failed; 2 usage / no harnesses
EOF
}

# --- EGL-79-D2: flag parsing (before any timeout/harness work) ----------
harness_sel="all"
# EGL-80 signal/timeout policy: default is `timeout --foreground -k 15`.
#   --foreground  keeps the harness in the caller's foreground process
#                 group so Ctrl+C cancels the whole battery. Without it,
#                 timeout self-groups the harness and ignores tty
#                 SIGINT/SIGQUIT while non-interactive bash defers its
#                 own SIGINT behind the wrapper — Ctrl+C would appear to
#                 do nothing (observed on a deployed host, 2026-09-16).
#   -k 15         restores a hard bound: SIGKILL 15s after the TERM.
#                 SIGKILL cannot be deferred the way the F1 wedge
#                 deferred TERM, so a wedged harness cannot outlive the
#                 bound.
#   Tradeoff: on expiry only the direct child is signalled, so short-
#   lived grandchildren may orphan (harmless here: mocks, stdin already
#   /dev/null). Pass --no-foreground to prefer the classic group-kill
#   isolation instead (mainly for long-lived headless environments that
#   would rather reap a whole process group on expiry). EGL-80-1-F2
#   note: the opt-out keeps the same kill-after — a group whose
#   harness inherited an ignored SIGTERM would otherwise outlive the
#   bound; group-scoped KILL at +15s reaps it. The only mode difference
#   left is the signal scope (group vs direct child) and tty behavior.
tf_args=( --foreground --kill-after=15 )
while (( $# )); do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --no-foreground)
            # EGL-80-2-F3: the opt-out keeps the kill-after — a group
            # whose harness inherited an ignored SIGTERM would
            # otherwise outlive the bound; group-scoped KILL at +15s
            # reaps it. Only the signal scope (group vs direct child)
            # and tty behavior differ from the default.
            tf_args=( --kill-after=15 )
            ;;
        --harness=*)
            harness_sel="${1#*=}"
            ;;
        --harness)
            if (( $# < 2 )); then
                echo "run.sh: --harness requires a value (engine|kit|all)" >&2
                exit 2
            fi
            harness_sel="$2"
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

shopt -s nullglob
case "$harness_sel" in
    engine)
        harnesses=( "$tests_dir/test-engine.sh" )
        ;;
    kit)
        harnesses=( "$tests_dir/test-kit.sh" )
        ;;
    all)
        harnesses=( "$tests_dir"/test-*.sh )
        ;;
    *)
        echo "run.sh: bad --harness value: '$harness_sel' (expected engine|kit|all)" >&2
        exit 2
        ;;
esac
shopt -u nullglob

# EGL-78-D6: timeout(1) is required — fail closed rather than run unbounded.
if ! command -v timeout >/dev/null 2>&1; then
    echo "run.sh: FAIL timeout(1) is required (coreutils)" >&2
    exit 2
fi

if [[ "$harness_sel" == "all" && ${#harnesses[@]} -eq 0 ]]; then
    echo "run.sh: no egresslock test harnesses found under $tests_dir" >&2
    exit 2
fi

HARNESS_TIMEOUT=300

rc=0
for h in "${harnesses[@]}"; do
    if [[ ! -x "$h" ]]; then
        echo "run.sh: FAIL harness not executable: $h" >&2
        rc=1
        continue
    fi
    echo "== egresslock tests: $h =="
    hrc=0
    # EGL-78-1-F1: each harness's stdin is /dev/null — a harness must not
    # inherit the caller's interactive terminal (a script(1) inside the
    # harness can otherwise wedge on the never-EOF stdin relay even after
    # its child exits, which also defeats the timeout bound because bash
    # defers SIGTERM while waiting on a foreground child).
    if command -v stdbuf >/dev/null 2>&1; then
        timeout "${tf_args[@]}" "$HARNESS_TIMEOUT" stdbuf -oL -eL bash "$h" </dev/null || hrc=$?
    else
        timeout "${tf_args[@]}" "$HARNESS_TIMEOUT" bash "$h" </dev/null || hrc=$?
    fi
    if (( hrc == 124 )); then
        # EGL-78-D3: a timeout is a FAIL, never a skip; name it for the
        # next investigator and keep the battery rc clean (no leaking 124).
        echo "run.sh: FAIL $h timeout after ${HARNESS_TIMEOUT}s" >&2
        rc=1
    elif (( hrc == 137 )); then
        # EGL-80-1-F2: with --kill-after, a harness that defied (or
        # deferred past) the TERM is SIGKILLed at bound+kill-after and
        # timeout reports 137. Same classification as 124 — a named
        # timeout FAIL, battery rc 1; rc 137 must never leak as the
        # battery rc (documented exit contract 0/1/2).
        echo "run.sh: FAIL $h timeout after ${HARNESS_TIMEOUT}s (TERM defied; kill-after SIGKILL fired)" >&2
        rc=1
    elif (( hrc != 0 )); then
        rc=$hrc; echo "run.sh: FAIL $h (rc=$rc)" >&2
    fi
done

echo "run.sh: egresslock tests done (rc=$rc)"
exit "$rc"
