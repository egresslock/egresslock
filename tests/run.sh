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
# EGL-86-D1/D2: the battery is a non-root battery — refused, not
# skipped, under uid 0 (exit 2 after flag parsing, before harness
# selection). `--help` still wins over the root gate (parsed first).
#
# EGL-86-D3: each harness's output is teed to a temp log; at suite end
# the `^SKIP:` lines are counted, bucketed by free-text reason, and
# summarized as one `run.sh: skips` line plus a fixed note of what the
# public tree still covers. Skips never change the exit code.
#
# Run:  bash tests/run.sh [--help] [--harness engine|kit|all]
#                                      [--no-foreground]
#
# Exit codes: 0 all harnesses green; 1 one or more harnesses failed
# (failing harnesses' rc 0 with FAIL lines are caught through the
# harnesses' final test; a harness timeout is also rc 1); 2 usage error
# (bad flags, no harnesses found, timeout(1) missing, or root uid —
# run the battery as an unprivileged account).

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
  1 public unit/integration  — test-engine.sh + test-kit.sh
  2 public security regs.    — mixed into those harnesses
  3 private/adversarial      — not in this tree (must not ship)

Exit: 0 all green; 1 a harness failed; 2 usage / no harnesses / root
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

# EGL-86-D1/D2: root preflight — refuse, do not skip. Running the
# battery under uid 0 turns the mocked root-guard cases and the
# non-root-hook kit asserts into a cascade of structural failures that
# look like product bugs; per-section skip classification would leave a
# thin residue falsely reporting "all applicable tests passed" and
# could mask a real root-guard regression. Same exit class as a usage
# error (documented 0/1/2 contract). `--help` already exited above, so
# the root gate never hides the usage text.
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
    h_log="$(mktemp /tmp/egl86-run-log.XXXXXX)"
    skip_logs+=( "$h_log" )
    # EGL-78-1-F1: each harness's stdin is /dev/null — a harness must not
    # inherit the caller's interactive terminal (a script(1) inside the
    # harness can otherwise wedge on the never-EOF stdin relay even after
    # its child exits, which also defeats the timeout bound because bash
    # defers SIGTERM while waiting on a foreground child).
    # EGL-86-D3: stdout+stderr are merged through tee so the visible run
    # keeps every byte while the `^SKIP:` lines land in the log for the
    # suite-end summary; PIPESTATUS[0] preserves the harness/timeout rc
    # (tee must not mask a failure).
    if command -v stdbuf >/dev/null 2>&1; then
        timeout "${tf_args[@]}" "$HARNESS_TIMEOUT" stdbuf -oL -eL bash "$h" </dev/null 2>&1 | tee "$h_log"
        hrc=${PIPESTATUS[0]}
    else
        timeout "${tf_args[@]}" "$HARNESS_TIMEOUT" bash "$h" </dev/null 2>&1 | tee "$h_log"
        hrc=${PIPESTATUS[0]}
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

# EGL-86-D3: skip summary — "N passed, 0 failed" must be distinguishable
# from "all applicable tests ran". Count `^SKIP:` lines across the teed
# logs, bucket them by (truncated) free-text reason, and state what the
# public tree still covers. Skips never change the exit code: this is a
# words-level distinction, not a new rc.
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
echo "run.sh: public-tree coverage still includes .deb staging asserts, tarball staging, and prefix guards; skipped items above are the private-fixture / host-shape checks that need a tree with those fixtures present"

echo "run.sh: egresslock tests done (rc=$rc)"
exit "$rc"
