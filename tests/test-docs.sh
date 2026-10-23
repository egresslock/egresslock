#!/usr/bin/env bash
#
# tests/test-docs.sh — public docs ship-gate (EGL-163): every relative
# link in the shipped markdown set must resolve to an existing file.
# Broken links are a ship gate, so this runs in the default battery
# (`test-*.sh` glob) and via `tests/run.sh --harness docs`.
#
# Scope (EGL-163-D2, first cut): exactly the markdown the public snapshot
# stages — README.md, SECURITY.md, CHANGELOG.md, packaging/README.md,
# apparmor/README.md, docs/** and examples/**; docs/tickets/ and
# docs/BOARD.md are excluded (the snapshot's process-file cut), and
# docs/lp-*.txt / docs/debian-*.txt are not markdown (do not widen).
# A link is an inline `](target)` or reference definition `]: target`
# whose target is RELATIVE — no scheme, leading `/`, or bare `#anchor`;
# `.md` and non-md targets both. Validation is file existence with
# `#fragment` stripped (no heading parsing); a lexically normalized
# target outside `$TREE_ROOT` FAILs. Fenced or 4-space/tab-indented text
# is literal and never swept.
# The self-test runs the extractor on a synthetic tree, including the
# EGL-160 trailing-`)` defect (`sed 's/](//'` made every check fail); the
# `[^)]*` capture cannot stick a `)` to a target.
# Sourcing tests/lib.sh reuses the shared counters/check/skip/tree-tag
# boilerplate (EGL-163-D3); its mock env is inert here. Run:
#   bash tests/test-docs.sh   (or tests/run.sh --harness docs)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

docs_root="$TREE_ROOT"   # scan root: the repo root (cwd-independent)

# Link regexes live in variables: unquoted in [[ =~ ]] is a syntax error;
# quoted would match literally.
docs_re_inline='\]\(([^)]*)\)'
docs_re_refdef='^[[:space:]]*\[[^]]+\]:[[:space:]]*([^[:space:]]+)'
docs_re_scheme='^[A-Za-z][A-Za-z0-9+.-]*:'

# --- link validation ----------------------------------------------------
docs_norm=""
# docs_normalize <absolute-path>: lexical collapse of `.` and `seg/..`
# (an above-`/` pop cannot leave the `out=("")` sentinel; docs_norm stays
# empty). Containment is the caller's prefix test against docs_root — no
# realpath, no symlink following; existence is checked afterwards.
docs_normalize() {
    local seg
    local -a segs=() out=("")
    local IFS='/'
    read -ra segs <<< "$1"
    for seg in "${segs[@]}"; do
        case "$seg" in
            ""|".") ;;
            "..")
                if (( ${#out[@]} > 1 )); then
                    out=("${out[@]:0:${#out[@]}-1}")
                fi
                ;;
            *) out+=("$seg") ;;
        esac
    done
    docs_norm="$(IFS=/; echo "${out[*]}")"
}

docs_pass=0
docs_fail=0

# docs_check_target <source-file> <raw-target> — validate one occurrence.
# A broken target prints one FAIL naming the source and original target;
# the sweep continues. Out-of-cut shapes (empty, bare anchor, absolute
# `/…`, scheme'd) skip, not FAIL (D2).
docs_check_target() {
    local f="$1" t="$2" t2 dir base
    t="${t#"${t%%[![:space:]]*}"}"    # ltrim (an inline capture may hold spaces)
    t="${t%"${t##*[![:space:]]}"}"    # rtrim
    if [[ "$t" == \<* && "$t" == *\> ]]; then t="${t#<}"; t="${t%>}"; fi
    if [[ -z "$t" || "$t" == \#* || "$t" == /* ]]; then return; fi
    if [[ "$t" =~ $docs_re_scheme ]]; then return; fi
    t2="${t%%#*}"                     # fragment stripped; file existence only
    [[ -z "$t2" ]] && return
    dir="${f%/*}"; [[ "$dir" == "$f" ]] && dir="."
    docs_normalize "$docs_root/$dir/$t2"
    # Containment bar: inside-or-equal the scan root only (`"$docs_root"/*`,
    # never a bare prefix); empty docs_norm is outside. The D2 FAIL wording
    # covers both escape shapes.
    if [[ -z "$docs_norm" || ( "$docs_norm" != "$docs_root" && "$docs_norm" != "$docs_root"/* ) ]]; then
        docs_fail=$(( docs_fail + 1 ))
        echo "FAIL: $f: relative link '$t' resolves outside the repository root"
    elif [[ ! -e "$docs_norm" ]]; then
        docs_fail=$(( docs_fail + 1 ))
        echo "FAIL: $f: relative link '$t' does not resolve (want $docs_norm)"
    else
        docs_pass=$(( docs_pass + 1 ))
    fi
}

# docs_sweep <file>... — paths relative to docs_root. Resolved
# occurrences increment docs_pass; broken ones print FAIL and increment
# docs_fail. Call directly (counters live); under command substitution the
# counters are lost, so the self-test asserts on captured output.
docs_sweep() {
    local f line rest t occ
    local infence
    for f in "$@"; do
        [[ -f "$docs_root/$f" ]] || continue
        infence=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                '```'*|'~~~'*|'    '*|'	'*)
                    # fence boundary or literal (code-block) line: never a link
                    case "$line" in '```'*|'~~~'*) infence=$(( 1 - infence ));; esac
                    continue
                    ;;
            esac
            (( infence )) && continue
            rest="$line"
            while [[ "$rest" =~ $docs_re_inline ]]; do
                occ="${BASH_REMATCH[0]}"
                t="${BASH_REMATCH[1]}"
                rest="${rest#*"$occ"}"
                docs_check_target "$f" "$t"
            done
            if [[ "$line" =~ $docs_re_refdef ]]; then
                docs_check_target "$f" "${BASH_REMATCH[1]}"
            fi
        done < "$docs_root/$f"
    done
}

# docs_require_nonempty — fail closed when the shipped-file list is empty
# (EGL-194 item 3): a failed `find` used to yield a vacuous green sweep.
# The FAIL line + increment is the signal; the final docs_fail check is rc 1.
docs_require_nonempty() {
    if (( ${#docs_files[@]} == 0 )); then
        docs_fail=$(( docs_fail + 1 ))
        echo "FAIL: docs ship-gate file list is empty (docs_root=$docs_root)"
        return 1
    fi
    return 0
}

# --- self-test (EGL-163-D2): synthetic tree; proves the EGL-160 defect
# class and out-of-cut skips before the real sweep. Asserts read captured
# output (the sweep runs in a command substitution; shared counters unused).
sd="$TESTROOT/docs-selftest"
mkdir -p "$sd/sub"
printf 'see [ok](real.md). trailing prose stays outside the target\n' > "$sd/page.md"
: > "$sd/real.md"
printf 'broken: [b](missing.md)\n' > "$sd/broken.md"
printf 'fenced:\n```sh\n[f](fence-only.md)\n```\n' > "$sd/fenced.md"
printf 'skips: [a](#anchor) [s](https://example.test/x.md) [u](/etc/hosts)\n' > "$sd/skips.md"
printf '[refdef]: missing-ref.md\nusage [refdef] only\n' > "$sd/ref.md"
printf 'escape: [e](../../../../../outside.md)\n' > "$sd/escape.md"
: > "$TESTROOT/outside.md"
printf 'climb: [c](../outside.md)\n' > "$sd/climb.md"

a_docs() { if [[ "$1" == pass ]]; then docs_pass=$((docs_pass+1)); else docs_fail=$((docs_fail+1)); echo "FAIL: $2"; fi; }

docs_root_saved="$docs_root"
docs_root="$sd"

st_out="$(docs_sweep page.md)"
if [[ -z "$st_out" ]]; then
    a_docs pass "self-test: [ok](real.md) resolves with trailing prose — no EGL-160 trailing-) defect"
else
    a_docs fail "self-test: [ok](real.md) did not resolve: $st_out"
fi
st_broken="$(docs_sweep broken.md)"
if printf '%s\n' "$st_broken" | grep -qF "FAIL: broken.md: relative link 'missing.md' does not resolve"; then
    a_docs pass "self-test: broken target flagged naming source + original target"
else
    a_docs fail "self-test: broken.md link not flagged: $st_broken"
fi
st_fence="$(docs_sweep fenced.md)"
if [[ -z "$st_fence" ]]; then
    a_docs pass "self-test: link-shaped text inside a code fence is not swept"
else
    a_docs fail "self-test: fence content swept as links: $st_fence"
fi
st_skips="$(docs_sweep skips.md)"
if [[ -z "$st_skips" ]]; then
    a_docs pass "self-test: bare anchor, scheme'd URL and absolute /… targets skipped"
else
    a_docs fail "self-test: out-of-cut targets not skipped: $st_skips"
fi
st_ref="$(docs_sweep ref.md)"
if printf '%s\n' "$st_ref" | grep -qF "FAIL: ref.md: relative link 'missing-ref.md' does not resolve"; then
    a_docs pass "self-test: reference definition target validated"
else
    a_docs fail "self-test: reference definition not validated: $st_ref"
fi
st_esc="$(docs_sweep escape.md)"
if printf '%s\n' "$st_esc" | grep -qF "FAIL: escape.md: relative link '../../../../../outside.md' resolves outside the repository root"; then
    a_docs pass "self-test: target escaping the repository root is a FAIL"
else
    a_docs fail "self-test: outside-root escape not flagged: $st_esc"
fi
st_climb="$(docs_sweep climb.md)"
if printf '%s\n' "$st_climb" | grep -qF "FAIL: climb.md: relative link '../outside.md' resolves outside the repository root"; then
    a_docs pass "self-test: target climbing out of TREE_ROOT to an existing file is a FAIL"
else
    a_docs fail "self-test: climb-out-of-TREE_ROOT escape not flagged: $st_climb"
fi

# EGL-194 item 3 self-test: an empty shipped-file list fails closed. Do
# not wrap the helper in $() — the subshell would drop the docs_fail
# increment; counters are restored after the observation either way.
docs_fail_saved=$docs_fail
docs_files=()
docs_require_nonempty >"$sd/empty.out" || true
if [[ "$docs_fail" -eq $((docs_fail_saved + 1)) ]] \
   && grep -qF "FAIL: docs ship-gate file list is empty" "$sd/empty.out"; then
    docs_fail=$docs_fail_saved
    a_docs pass "self-test: empty shipped-file list is fail-closed"
else
    docs_fail=$docs_fail_saved
    a_docs fail "self-test: empty shipped-file list did not fail-closed: $(cat "$sd/empty.out")"
fi
docs_root="$docs_root_saved"

# --- the shipped set (EGL-163-D2 roots; sorted for stable FAIL order) ---
docs_files=()
while IFS= read -r f; do
    docs_files+=( "$f" )
done < <(
    cd "$docs_root" || exit 1
    find docs examples -name '*.md' \
        -not -path 'docs/tickets/*' -not -path 'docs/BOARD.md' 2>/dev/null | sort
    for f in README.md SECURITY.md CHANGELOG.md packaging/README.md apparmor/README.md; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
)
docs_sweep ${docs_files[@]+"${docs_files[@]}"}
docs_require_nonempty || true

echo "RESULTS (docs link resolution): $docs_pass passed, $docs_fail failed"
echo "RESULTS TOTAL: $docs_pass passed, $docs_fail failed$(skip_summary) ($(tree_shape_tag))"
[[ "$docs_fail" -eq 0 ]]
