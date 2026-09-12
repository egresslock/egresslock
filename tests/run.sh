#!/usr/bin/env bash
#
# tests/run.sh — THE product-tree test entry point (ARC-74-D2).
# Runs every test-*.sh beside this script and fails closed if any harness
# is missing or not executable, so reviewers (and the standalone egresslock
# repo after ARC-75) cannot skip a battery by accident.
#
# Run:  bash tests/run.sh
#
# Exit codes: 0 all harnesses green; 1 one or more harnesses failed
# (failing harnesses' rc 0 with FAIL lines are caught through the
# harnesses' final test); 2 usage error (no harnesses found).

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

shopt -s nullglob
harnesses=( "$tests_dir"/test-*.sh )
shopt -u nullglob
if [[ ${#harnesses[@]} -eq 0 ]]; then
    echo "run.sh: no egresslock test harnesses found under $tests_dir" >&2
    exit 2
fi

rc=0
for h in "${harnesses[@]}"; do
    if [[ ! -x "$h" ]]; then
        echo "run.sh: FAIL harness not executable: $h" >&2
        rc=1
        continue
    fi
    echo "== egresslock tests: $h =="
    bash "$h" || { rc=$?; echo "run.sh: FAIL $h (rc=$rc)" >&2; }
done

echo "run.sh: egresslock tests done (rc=$rc)"
exit "$rc"