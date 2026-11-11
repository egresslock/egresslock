#!/usr/bin/env bash
#
# tests/test-docs.sh — public docs ship-gate (EGL-163): every relative
# link in the shipped markdown set must resolve to an existing file.
# Broken links are a ship gate, so this runs in the default battery
# (`test-*.sh` glob) and via `tests/run.sh --harness docs`.
#
# Scope (EGL-163-D2, first cut): exactly the markdown the public snapshot
# stages — README.md, SECURITY.md, CHANGELOG.md, packaging/README.md,
# apparmor/README.md, docs/** and examples/**. The ticket flow and board
# live outside the shipped set (not staged, not link-checked), and
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
    find docs examples -name '*.md' 2>/dev/null | sort
    for f in README.md SECURITY.md CHANGELOG.md packaging/README.md apparmor/README.md; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
)
docs_sweep ${docs_files[@]+"${docs_files[@]}"}
docs_require_nonempty || true

# EGL-433-D9: the public refused-run claim must stay scoped to the
# implemented guarantees. A stale broad claim, or an unconditional
# "deny-all" description of the allowlist a failed --init-conf retains,
# is a ship-gate FAIL. The changelog is shipped; the operator map is not
# present in an extracted kit, so it is checked only when it exists.
d9_files=( "$docs_root/CHANGELOG.md" )
# The operator map is private maintainer material, absent from an extracted
# kit; locate it by basename so the check runs when the map exists and stays
# inert otherwise (no private path is named here).
while IFS= read -r d9f; do
    d9_files+=( "$d9f" )
done < <(find "$docs_root" -type f -name 'OPERATOR_STATE_MAP.md' \
    -not -path '*/.git/*' 2>/dev/null | sort)
d9_bad=0
for d9f in "${d9_files[@]}"; do
    [[ -f "$d9f" ]] || continue
    if grep -qF 'a refused run changes nothing' "$d9f"; then
        echo "FAIL: ${d9f#"$docs_root"/}: stale broad claim 'a refused run changes nothing'"
        d9_bad=$(( d9_bad + 1 ))
    fi
    if grep -qF 'leaves the deny-all allowlist in place' "$d9f" \
       || grep -qF 'it is the deny-all allowlist, reused on re-run' "$d9f"; then
        echo "FAIL: ${d9f#"$docs_root"/}: retained allowlist unconditionally called deny-all"
        d9_bad=$(( d9_bad + 1 ))
    fi
done
if (( d9_bad )); then
    docs_fail=$(( docs_fail + d9_bad ))
else
    docs_pass=$(( docs_pass + 1 ))
fi
# The shipped one-sentence D9 claim (line wrapping collapsed).
if [[ -f "$docs_root/CHANGELOG.md" ]]; then
    d9_flat="$(tr '\n' ' ' < "$docs_root/CHANGELOG.md" | tr -s ' ')"
    if [[ "$d9_flat" == *'Normal use is unchanged. A refused run never deletes or overwrites your files — except that a refused build can leave an empty keep-stage directory absent, and a failed `--init-conf` leaves the allowlist in place; inspect it before reuse.'* ]]; then
        docs_pass=$(( docs_pass + 1 ))
    else
        docs_fail=$(( docs_fail + 1 ))
        echo "FAIL: CHANGELOG.md: scoped D9 refused-run claim is missing"
    fi
fi

echo "RESULTS (docs link resolution): $docs_pass passed, $docs_fail failed"
echo "RESULTS TOTAL: $docs_pass passed, $docs_fail failed$(skip_summary) ($(tree_shape_tag))"
[[ "$docs_fail" -eq 0 ]]
