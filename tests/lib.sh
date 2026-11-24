# tests/lib.sh — shared mock environment for the engine and consumer test
# harnesses (ARC-15). Mocks podman, nft and getent to emulate rootless-
# netns state transitions (netns/policy destroyed when the last container
# stops, nft listings with counters). No root, Podman or nftables needed.
#
# Callers may set beforehand: EGRESSLOCK_PROFILES (engine binary; default
# <tree-root>/egresslock), ARCMOCK_DNS_BASE (base DNS mapping
# "host=ip,host=ip"; the engine harness
# uses neutral example.test).
#
# Defaults are relative to the egresslock tree (parent of tests/), so the
# file keeps working when the tree relocates (ARC-74-D4).
#   EGRESSLOCK_MOCK_DNS   per-call DNS overrides (drift knob, ARC-12)
#   ARCMOCK_PASSWD_HOME   getent passwd <uid> home; keeps the default-config
#                         HOME fallback hermetic (ARC-24)
#   ARCMOCK_LINGER_ANSWER loginctl Linger answer (`yes` default; `no`
#                         exercises setup's fail-closed branch, ARC-28)

set -u

# EGL-451: sharded-window selection. run.sh exports
# EGRESSLOCK_TEST_SHARDED=1 plus a space-delimited EGRESSLOCK_TEST_SECTIONS
# list; each engine window is wrapped in shard_section_run. A sharded run
# with an empty list is refused here, before any window can execute: empty
# must never mean "run every section" (that would duplicate every section
# across shards if the planner ever produced an empty bin).
if [[ -n "${EGRESSLOCK_TEST_SHARDED:-}" && -z "${EGRESSLOCK_TEST_SECTIONS:-}" ]]; then
    echo "FAIL: EGRESSLOCK_TEST_SHARDED is set but EGRESSLOCK_TEST_SECTIONS is empty — refusing to run every section (EGL-451 fail-closed)" >&2
    exit 2
fi

TESTROOT="$(mktemp -d /tmp/egresslock-test.XXXXXX)"
# EGL-246 launcher note: deliberately NO battery-wide `egresslock` PATH
# launcher. Both harnesses put the tree root on PATH at their top
# (`export PATH="$TESTROOT/bin:$TREE_ROOT:$PATH"`); the egl246 section
# owns a SECTION-LOCAL absolute launcher for its PATH-shimmed legs.
trap 'rm -rf "$TESTROOT"' EXIT
STATE="$TESTROOT/state"
export ARCMOCK_STATE="$STATE"
mkdir -p "$STATE/nft" "$STATE/networks" "$STATE/running" "$STATE/containers" \
    "$STATE/runargs" "$STATE/ips"

TREE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EGRESSLOCK_PROFILES="${EGRESSLOCK_PROFILES:-$TREE_ROOT/egresslock}"
# EGL-395: the mock container filesystem seeds the image bootstrap config
# and the live (loaded) bytes from the shipped gateway tree.
export ARCMOCK_TREE_ROOT="$TREE_ROOT"

# EGL-325: fixed-confdir helper. The engine no longer accepts --config or
# EGRESSLOCK_CONF; a profile's conf is always
# <passwd-home>/.config/egresslock/<profile>.conf. conf_home builds a
# synthetic home whose confdir symlinks the fixture directory (not
# per-file copies), so conf RMW and .pins records land in the fixture.
#
# The home path is DETERMINISTIC per fixture directory (not mktemp): the
# engine embeds the path in generated configs and tests call this in
# `$(...)` subshells, so a cache would not survive. Stability lets a
# second ensure converge (EGL-114 byte-identity).
__conf_home_key() { # <path> -> stable short digest
    printf '%s' "$1" | sha256sum | cut -c1-16
}
conf_home() { # conf_home <conf-file-or-dir> -> synthetic home for the passwd mock
    local src="$1" dir home key
    if [[ -d "$src" ]]; then
        dir="$(cd "$src" && pwd)" || return 1
    else
        dir="$(cd "$(dirname "$src")" && pwd)" || return 1
    fi
    key="$(__conf_home_key "$dir")" || return 1
    home="$TESTROOT/confhome.$key"
    if [[ ! -L "$home/.config/egresslock" ]]; then
        mkdir -p "$home/.config" || return 1
        ln -sfn "$dir" "$home/.config/egresslock" || return 1
    fi
    printf '%s\n' "$home"
}

# EGL-325: read-only fixture isolation. Reads that used `--config` need a
# confdir holding only the named profile (the fixed-confdir rule).
# conf_home_ro copies the fixture per call (picks up source edits) and
# links non-conf siblings. Never use for mutating commands — rewrites
# would land on the copy.
conf_home_ro() { # conf_home_ro <conf-file> -> synthetic home, isolated confdir
    local src="$1" prof home key
    src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" || return 1
    key="$(__conf_home_key "$src")" || return 1
    home="$TESTROOT/confhome-ro.$key"
    mkdir -p "$home/.config/egresslock" || return 1
    prof="$(sed -n 's/^[[:space:]]*profile[[:space:]][[:space:]]*\([^[:space:]]*\).*/\1/p' "$src" 2>/dev/null | head -n1)"
    [[ -n "$prof" ]] || prof="$(basename "$src" .conf)"
    rm -f -- "$home/.config/egresslock/"*.conf
    cp -- "$src" "$home/.config/egresslock/$prof.conf" || return 1
    local f
    for f in "$(dirname "$src")"/*; do
        [[ -f "$f" && "$f" != *.conf ]] || continue
        ln -sfn -- "$f" "$home/.config/egresslock/$(basename "$f")"
    done
    printf '%s\n' "$home"
}

# --- mocks ------------------------------------------------------------
mkdir -p "$TESTROOT/bin"
cat > "$TESTROOT/bin/ip" <<'EOF'
#!/usr/bin/env bash
# Mock iproute2 `ip` — EGL-141-D1: the engine's profile_bridge_if
# cross-checks the network's bridge device against the rootless netns
# link list (`podman unshare --rootless-netns ip -br link`). Answer the
# -br link form with a deterministic slot list podman0..podman9 (plus
# lo), all UP: (a) every mock-resolved interface is always confirmed
# (the cross-check then pins the INSPECT half — churn scenarios flip
# interface= in the state file); (b) a real mismatch drill needs only
# a hand-edit of the networks/<name> state file (drop/rename its
# interface= line so it names a slot outside this list) — no mock-ip
# flag surface. Any other subcommand is unsupported (fail loud, like
# the other mocks).
if [[ "${1:-}" == "-br" && "${2:-}" == "link" ]]; then
    echo "lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>"
    local_n=0
    while (( local_n <= 9 )); do
        printf 'podman%d          UP             02:00:00:00:00:%02x <BROADCAST,MULTICAST,UP,LOWER_UP>\n' "$local_n" "$local_n"
        local_n=$(( local_n + 1 ))
    done
    exit 0
fi
echo "mock ip: unsupported invocation: $*" >&2
exit 2
EOF

cat > "$TESTROOT/bin/nft" <<'EOF'
#!/usr/bin/env bash
# Mock nft: state dir files named <table>.<chain>. Models the real
# nftables semantics established on-host (ARC-3 R-003-7 era):
#   - 'nft -f' is ONE atomic transaction, but chains are ADDITIVE: rules
#     in a block for an EXISTING chain are APPENDED (they do not fail —
#     the R-003-2 "File exists" theory was disproven on-host by the
#     duplicated-rule evidence).
#   - 'flush chain <fam> <tbl> <chain>' directives INSIDE a -f file are
#     applied in order (this is how install_policy atomically replaces
#     a populated chain without an empty-chain window).
#   - 'delete chain' on a populated chain fails; only empty chains can
#     be deleted.
#   - 'add table' over an existing table is a no-op (additive semantics).
set -u
D="${ARCMOCK_STATE:?}/nft"
cmd="$1"; shift
# Rule lines = anything containing 'counter' (mock simplification: every
# generated rule carries a counter statement).
populated() {
    local _pline=""
    while IFS= read -r _pline || [[ -n "$_pline" ]]; do
        [[ "$_pline" == *counter* ]] && return 0
    done < "$1"
    return 1
}
# EGL-362 P2: render `nft list chain` output (expanded counters, mangle
# priority alias, indented body) with bash builtins. RENDERED is the
# line array the caller prints, byte-identical to the old sed|awk body.
RENDERED=()
render_chain() { # render_chain <state-file>
    local _rfile="$1" _rline=""
    RENDERED=()
    while IFS= read -r _rline || [[ -n "$_rline" ]]; do
        if [[ "$_rline" =~ counter\ (drop|accept)$ ]]; then
            _rline="${_rline%"counter ${BASH_REMATCH[1]}"}counter packets 0 bytes 0 ${BASH_REMATCH[1]}"
        elif [[ "$_rline" =~ counter$ ]]; then
            # EGL-376-D-MOCK: a bare trailing `counter` (the non-verdict
            # record rule) expands exactly like real nft; without this
            # the live and mock listings would drift and verify would
            # compare an unexpanded mock line.
            _rline="${_rline%counter}counter packets 0 bytes 0"
        fi
        _rline="${_rline/priority -150/priority mangle}"
        if [[ "$_rline" == *"{"* || "$_rline" == *"}"* ]]; then
            RENDERED+=("$_rline")
        else
            RENDERED+=("        $_rline")
        fi
    done < "$_rfile"
}

# EGL-376-D-MOCK: per-profile drop-record sets. State lives under
# $D/sets/<table>/ — a SUBDIRECTORY, so the `$D/<table>.<chain>` chain
# model and every existing list/tables/ruleset walk cannot mistake a set
# for a chain. Definition and elements are separate files so a re-declare
# (`nft -f`) updates the definition and KEEPS elements (VM P4).
set_state_dir() { echo "$D/sets/$1"; }
set_referenced() { # set_referenced <table> <set> -> 0 while any chain rule names @set
    local _srt="$1" _srs="$2" _srf _srl _srre
    _srre="@${_srs}([^A-Za-z0-9_]|$)"
    for _srf in "$D/$_srt".*; do
        [[ -f "$_srf" ]] || continue
        while IFS= read -r _srl || [[ -n "$_srl" ]]; do
            [[ "$_srl" =~ $_srre ]] && return 0
        done < "$_srf"
    done
    return 1
}
render_set() { # render_set <table> <set> -> listing block (no table wrapper)
    local _rst="$1" _rss="$2" _rsdir _rsdef _rsel _rsline _rsi
    local -a _rstoks=()
    _rsdir="$D/sets/$_rst"
    _rsdef="$_rsdir/$_rss.def"
    _rsel="$_rsdir/$_rss.elements"
    [[ -f "$_rsdef" || -f "$_rsel" ]] || return 1
    echo "set $_rss {"
    if [[ -f "$_rsdef" ]]; then
        while IFS= read -r _rsline || [[ -n "$_rsline" ]]; do
            [[ -n "$_rsline" ]] && echo "    $_rsline"
        done < "$_rsdef"
    else
        echo "    type ipv4_addr . inet_service"
        echo "    flags dynamic,timeout"
    fi
    if [[ -f "$_rsel" ]]; then
        while IFS= read -r _rsline || [[ -n "$_rsline" ]]; do
            local _rsip _rsport
            [[ -n "$_rsline" ]] || continue
            read -r _rsip _rsport _ <<<"$_rsline"
            [[ -n "$_rsip" && -n "$_rsport" ]] || continue
            if [[ -f "$_rsdir/$_rss.timeout" ]]; then
                _rstoks+=("$_rsip . $_rsport timeout 1h expires 59m57s")
            else
                _rstoks+=("$_rsip . $_rsport expires 59m57s")
            fi
        done < "$_rsel"
    fi
    if (( ${#_rstoks[@]} == 1 )); then
        echo "    elements = { ${_rstoks[0]} }"
    elif (( ${#_rstoks[@]} > 1 )); then
        for _rsi in "${!_rstoks[@]}"; do
            if (( _rsi == 0 )); then
                echo "        elements = { ${_rstoks[$_rsi]},"
            elif (( _rsi == ${#_rstoks[@]} - 1 )); then
                echo "                      ${_rstoks[$_rsi]} }"
            else
                echo "                      ${_rstoks[$_rsi]},"
            fi
        done
    fi
    echo "}"
}

case "$cmd" in
    -c) shift 1; exec "$0" -f "$@" ;;  # -c -f file
    -f)
        file="$1"
        cp "$file" "$D/last-transaction.nft"
        table=""
        while IFS= read -r _fline || [[ -n "$_fline" ]]; do
            if [[ "$_fline" =~ table\ ([a-z]+)\ ([a-z_]+) ]]; then
                table="${BASH_REMATCH[2]}"
                break
            fi
        done < "$file"
        [[ -n "$table" ]] || { echo "mock nft: no table in $file" >&2; exit 1; }
        # Inline 'flush chain' directives apply in order first: rules of
        # the named chain are removed (the chain itself stays).
        while IFS= read -r _fline || [[ -n "$_fline" ]]; do
            [[ "$_fline" == "flush chain "* ]] || continue
            read -r _ _ fam tbl ch <<<"$_fline"
            f="$D/$tbl.$ch"
            if [[ -f "$f" ]]; then
                # R-EGL-362-3: grep -v leaves the file (and an empty
                # .tmp) untouched when every line is a rule; only a
                # transaction that kept a non-rule line renames.
                _kept=0
                : > "$f.tmp"
                while IFS= read -r _fbody || [[ -n "$_fbody" ]]; do
                    [[ "$_fbody" == *counter* ]] && continue
                    printf '%s\n' "$_fbody" >> "$f.tmp"
                    _kept=1
                done < "$f"
                (( _kept )) && mv "$f.tmp" "$f"
            else
                echo "Error: No such file or directory" >&2
                exit 1
            fi
        done < "$file"
        # exclude 'flush chain' directive lines from chain-block parsing
        # (grep -oE semantics: every `chain NAME` match on every other
        # line, in file order).
        chains=""
        while IFS= read -r _fline || [[ -n "$_fline" ]]; do
            [[ "$_fline" == "flush chain "* ]] && continue
            _frest="$_fline"
            while [[ "$_frest" =~ chain\ ([A-Za-z0-9_]+) ]]; do
                chains+="${chains:+$'\n'}${BASH_REMATCH[1]}"
                _frest="${_frest#*"${BASH_REMATCH[0]}"}"
            done
        done < "$file"
        [[ -n "$chains" ]] || { echo "mock nft: no chain in $file" >&2; exit 1; }
        # EGL-91: cross-tool ordering probe — one summary line per -f
        # transaction into callorder.log (chains touched, flush
        # directives, rule-line count) so tests can assert policy-vs-
        # gateway-start ordering and that a first-create transaction
        # already carries rules. Existing callorder consumers are
        # grep-based and unaffected by the extra line type.
        _chain_csv=""
        while IFS= read -r _fc; do
            _chain_csv+="${_chain_csv:+,}$_fc"
        done <<<"$chains"
        _flush_n=0; _rule_n=0
        while IFS= read -r _fline || [[ -n "$_fline" ]]; do
            [[ "$_fline" == "flush chain "* ]] && _flush_n=$((_flush_n + 1))
            [[ "$_fline" == *counter* ]] && _rule_n=$((_rule_n + 1))
        done < "$file"
        echo "nft -f chains=$_chain_csv flush=$_flush_n rules=$_rule_n" \
            >> "$ARCMOCK_STATE/callorder.log"
        # EGL-376-D-MOCK: set declarations create the per-table set state;
        # re-declaring updates the definition but keeps the existing
        # elements (VM P4). Elements live in their own file so this write
        # cannot erase them.
        while IFS= read -r _fline || [[ -n "$_fline" ]]; do
            [[ "$_fline" =~ ^[[:space:]]*set\ ([A-Za-z0-9_]+)[[:space:]]*\{ ]] || continue
            _sn="${BASH_REMATCH[1]}"
            _sdir="$D/sets/$table"
            mkdir -p "$_sdir"
            _sdef=()
            _inset=0
            while IFS= read -r _fline2 || [[ -n "$_fline2" ]]; do
                if [[ "$_fline2" =~ ^[[:space:]]*set\ ${_sn}[[:space:]]*\{ ]]; then
                    _inset=1
                    continue
                fi
                if (( _inset )); then
                    [[ "$_fline2" =~ ^[[:space:]]*\}[[:space:]]*$ ]] && { _inset=0; break; }
                    _sline="${_fline2#"${_fline2%%[![:space:]]*}"}"
                    _sdef+=("$_sline")
                fi
            done < "$file"
            printf '%s\n' "${_sdef[@]}" > "$_sdir/$_sn.def"
            [[ -f "$_sdir/$_sn.elements" ]] || : > "$_sdir/$_sn.elements"
        done < "$file"
        # Store or append each chain's own section (additive semantics).
        for ch in $chains; do
            _sect=()
            _inchain=0
            while IFS= read -r _fline || [[ -n "$_fline" ]]; do
                # Base awk matched exactly one space after `chain`
                # (R-EGL-362-3); keep that byte-for-byte contract.
                if [[ "$_fline" =~ ^[[:space:]]*chain\ ${ch}[[:space:]]*\{ ]]; then
                    _inchain=1
                fi
                if (( _inchain )); then
                    _sect+=("$_fline")
                fi
                if (( _inchain )) && [[ "$_fline" =~ ^[[:space:]]*\}[[:space:]]*$ ]]; then
                    _inchain=0
                fi
            done < "$file"
            if [[ -f "$D/$table.$ch" ]]; then
                # Append only rule lines to the existing chain.
                # EGL-141: rule lines may also start with `iifname` (the
                # anti-spoof drop is a first-class rule line now).
                for _fline in "${_sect[@]}"; do
                    [[ "$_fline" =~ ^[[:space:]]*(ip\ |meta\ |iifname\ ) ]] || continue
                    _fstrip="$_fline"
                    _fstrip="${_fstrip#"${_fstrip%%[![:space:]]*}"}"
                    printf '%s\n' "$_fstrip"
                done >> "$D/$table.$ch"
            else
                printf '%s\n' "${_sect[@]}" > "$D/$table.$ch"
            fi
        done
        # EGL-305 test seam: transaction-applied marker (gates the
        # post-swap list-chain fault injection to a failure AFTER the
        # successful atomic -f request reached the mock).
        : > "$D/f-done"
        # EGL-307 test seam: the ordinal list-chain read counter resets
        # on every -f transaction, so fail-list-chain-read-n always
        # counts POST-swap reads only.
        : > "$D/f-list-reads"
        exit 0
        ;;
    delete)
        # delete chain <family> <table> <chain> — family is REQUIRED
        # (real nft syntax); the R-003 on-host incident showed a missing
        # family silently broke list/flush/delete.
        # EGL-376-D-MOCK: delete set <family> <table> <set> — fails while
        # a chain rule still references the set (`Device or resource
        # busy`, VM P5/P7); after flush/delete chain it succeeds.
        # delete table <family> <table> (ARC-54): drops every chain and
        # every set of the table; fails when the table does not exist, or
        # when the state marker delete-table-fail is present.
        if [[ "$1" == set ]]; then
            [[ "$2" == inet ]] || { echo "mock nft: delete set needs a family" >&2; exit 2; }
            _sdir="$D/sets/$3"
            if [[ ! -f "$_sdir/$4.def" && ! -f "$_sdir/$4.elements" ]]; then
                echo "Error: No such file or directory" >&2
                exit 1
            fi
            if set_referenced "$3" "$4"; then
                echo "Error: Could not process rule: Device or resource busy" >&2
                exit 1
            fi
            if [[ -f "$D/delete-set-fail" ]]; then
                echo "Error: mock nft: delete-set-fail marker present" >&2
                exit 1
            fi
            rm -f "$_sdir/$4.def" "$_sdir/$4.elements" \
                  "$_sdir/$4.timeout" "$_sdir/$4.wrap"
            exit 0
        fi
        if [[ "$1" == table ]]; then
            [[ "$2" == inet ]] || { echo "mock nft: delete table needs a family" >&2; exit 2; }
            if [[ -f "$D/delete-table-fail" ]]; then
                echo "Error: mock nft: delete-table-fail marker present" >&2
                exit 1
            fi
            found=0
            for f in "$D/$3".*; do
                [[ -f "$f" ]] || continue
                found=1; rm -f "$f"
            done
            if [[ -d "$D/sets/$3" ]]; then
                found=1
                rm -rf "$D/sets/$3"
            fi
            [[ "$found" == 1 ]] || { echo "Error: No such file or directory" >&2; exit 1; }
            exit 0
        fi
        [[ "$1" == chain && "$2" == inet ]] || { echo "mock nft: delete chain needs family" >&2; exit 2; }
        # EGL-518 test seam: the chain delete fails (after a successful
        # flush) — the D5 failed-chain-delete disclosure.
        if [[ -f "$D/delete-chain-fail" ]]; then
            echo "Error: mock nft: delete-chain-fail marker present" >&2
            exit 1
        fi
        f="$D/$3.$4"
        if [[ ! -f "$f" ]]; then
            echo "Error: No such file or directory" >&2
            exit 1
        fi
        if populated "$f"; then
            echo "Error: Could not process rule: Device or resource busy" >&2
            exit 1
        fi
        rm -f "$f"
        exit 0
        ;;
    flush)
        # flush chain <family> <table> <chain>
        # EGL-376-D-MOCK: flush set empties the elements but keeps the
        # set (and its definition), like real nft.
        if [[ "$1" == set ]]; then
            [[ "$2" == inet ]] || { echo "mock nft: flush set needs a family" >&2; exit 2; }
            _sdir="$D/sets/$3"
            if [[ ! -f "$_sdir/$4.def" && ! -f "$_sdir/$4.elements" ]]; then
                echo "Error: No such file or directory" >&2
                exit 1
            fi
            : > "$_sdir/$4.elements"
            exit 0
        fi
        [[ "$1" == chain && "$2" == inet ]] || { echo "mock nft: unsupported flush $*" >&2; exit 2; }
        f="$D/$3.$4"
        if [[ ! -f "$f" ]]; then
            echo "Error: No such file or directory" >&2
            exit 1
        fi
        # Keep non-rule lines (chain/type/hook), drop rule lines. Match
        # grep -v: an all-rule file is left byte-identical and its empty
        # .tmp stays behind (R-EGL-362-3).
        _kept=0
        : > "$f.tmp"
        while IFS= read -r _fline || [[ -n "$_fline" ]]; do
            [[ "$_fline" == *counter* ]] && continue
            printf '%s\n' "$_fline" >> "$f.tmp"
            _kept=1
        done < "$f"
        (( _kept )) && mv "$f.tmp" "$f"
        exit 0
        ;;
    list)
        # list chain <family> <table> <chain> | list table <table>
        sub="$1"; shift
        case "$sub" in
            chain)
                [[ "$1" == inet ]] || { echo "mock nft: list chain needs a family" >&2; exit 2; }
                f="$D/$2.$3"
                [[ -f "$f" ]] || { echo "Error: No such file or directory" >&2; exit 1; }
                # EGL-389 test seam: make the conf dir unwritable on the
                # FIRST chain read (the proxy disallow's ensure reaches
                # ensure_snapshot_pins after cmd_disallow's rewrite), so
                # the trap's source restore (same-dir rename) fails — the
                # S-P2/S-P2n/S-P2r/S-P2s injection. Consumed once.
                if [[ -f "$D/proxy-source-restore-fails" ]]; then
                    _cdir="$(cat "$D/proxy-source-restore-fails")"
                    rm -f "$D/proxy-source-restore-fails"
                    chmod 0555 "$_cdir" 2>/dev/null || true
                fi
                # EGL-305 test seam (EGL-314 re-point): after the conf
                # delete, make the conf dir unwritable (content = the
                # conf dir path) so the trap-context restore's mktemp
                # fails — the state-(i) restore-failure injection. In a
                # disallow-host run the first `list chain` is
                # live_pin_daddr's pre-delete capture; the seam must
                # fire on the NEXT read (ensure_snapshot_pins' probe,
                # post-delete, pre-die), so the delete itself is
                # unaffected. Consumed once (marker + one-shot seen
                # flag).
                if [[ -f "$D/confdir-unwritable" ]]; then
                    if [[ -f "$D/confdir-unwritable-seen" ]]; then
                        _cdir="$(cat "$D/confdir-unwritable")"
                        rm -f "$D/confdir-unwritable" "$D/confdir-unwritable-seen"
                        chmod 0555 "$_cdir" 2>/dev/null || true
                    else
                        : > "$D/confdir-unwritable-seen"
                    fi
                fi
                # EGL-397 F5 test seam: witness the actual post-delete,
                # pre-restore conf. Marker = two lines (<conf> then
                # <witness>); same one-shot second-read timing as
                # confdir-unwritable. A test that never observes this
                # state cannot prove the delete/restore window ran.
                if [[ -f "$D/conf-witness-after-delete" ]]; then
                    if [[ -f "$D/conf-witness-after-delete-seen" ]]; then
                        _cwconf=""; _cwdest=""
                        { IFS= read -r _cwconf; IFS= read -r _cwdest; } < "$D/conf-witness-after-delete"
                        if [[ -n "$_cwconf" && -n "$_cwdest" ]]; then
                            cp -- "$_cwconf" "$_cwdest" 2>/dev/null || true
                        fi
                        rm -f "$D/conf-witness-after-delete" "$D/conf-witness-after-delete-seen"
                    else
                        : > "$D/conf-witness-after-delete-seen"
                    fi
                fi
                # EGL-307 test seam: the Nth POST-(-f) chain read fails
                # once with a netlink-style error. The counter
                # ($D/f-list-reads, reset on every -f) increments per
                # read while the swap marker ($D/f-done) is present;
                # fail-list-chain-read-n names N. The marker is consumed
                # when it fires, so later reads pass (e307-c: the guard's
                # read fails, the reconcile's own read succeeds).
                if [[ -f "$D/f-done" ]]; then
                    _n307=0
                    [[ -s "$D/f-list-reads" ]] && read -r _n307 < "$D/f-list-reads"
                    _n307=$((_n307 + 1))
                    echo "$_n307" > "$D/f-list-reads"
                    if [[ -f "$D/fail-list-chain-read-n" ]] \
                       && [[ "$_n307" == "$(cat "$D/fail-list-chain-read-n")" ]]; then
                        rm -f "$D/fail-list-chain-read-n"
                        echo "Error: mock nft: netlink read of chain '$3' failed once (fail-list-chain-read-n)" >&2
                        exit 1
                    fi
                fi
                # EGL-305 test seam: fail the FIRST post-swap chain read
                # once, with a netlink-style error, when both markers
                # are present (f-done gates it to AFTER the -f swap;
                # the engine's 2>/dev/null swallows the message so the
                # mock just exits 1). Consumes both markers.
                if [[ -f "$D/fail-list-chain-after-f" && -f "$D/f-done" ]]; then
                    rm -f "$D/fail-list-chain-after-f" "$D/f-done"
                    echo "Error: mock nft: netlink read of chain '$3' failed once (fail-list-chain-after-f)" >&2
                    exit 1
                fi
                # EGL-311 test seams: the post-swap read AFTER the member
                # flush (the conntrack log already carries a -D). Each
                # marker is consumed once.
                _ctd=0
                if [[ -f "$D/f-done" && -f "${ARCMOCK_STATE:?}/conntrack.log" ]]; then
                    # grep -q also matches an unterminated final line
                    # (R-EGL-362-3), so keep the short-line branch.
                    while IFS= read -r _ctline || [[ -n "$_ctline" ]]; do
                        [[ "$_ctline" == "conntrack -D "* ]] && { _ctd=1; break; }
                    done < "${ARCMOCK_STATE:?}/conntrack.log"
                fi
                if [[ -f "$D/f-done" ]] && (( _ctd )); then
                    if [[ -f "$D/fail-list-chain-after-flush" ]]; then
                        rm -f "$D/fail-list-chain-after-flush"
                        echo "Error: mock nft: netlink read of chain '$3' failed once (fail-list-chain-after-flush)" >&2
                        exit 1
                    fi
                    if [[ -f "$D/partial-list-chain-after-flush" ]]; then
                        rm -f "$D/partial-list-chain-after-flush"
                        render_chain "$f"
                        # The base sed|awk pipeline wrote nothing for an
                        # empty chain; printf with no elements would add
                        # a blank line (R-EGL-362-3).
                        (( ${#RENDERED[@]} )) && printf '%s\n' "${RENDERED[@]}"
                        echo "Error: mock nft: netlink read of chain '$3' failed after data (partial-list-chain-after-flush)" >&2
                        exit 1
                    fi
                    if [[ -f "$D/empty-list-chain-after-flush" ]]; then
                        rm -f "$D/empty-list-chain-after-flush"
                        exit 0
                    fi
                    if [[ -f "$D/header-list-chain-after-flush" ]]; then
                        rm -f "$D/header-list-chain-after-flush"
                        printf 'chain %s {\n        type filter hook forward priority -150; policy accept;\n}\n' "$3"
                        exit 0
                    fi
                    if [[ -f "$D/garbage-list-chain-after-flush" ]]; then
                        rm -f "$D/garbage-list-chain-after-flush"
                        printf 'not a firewall chain\n'
                        exit 0
                    fi
                fi
                # Mimic real nft output: expanded counters, mangle priority
                # alias, and INDENTED body lines inside the chain.
                # EGL-296 F1 (ER-EGL-296-5) test seams: a failed read
                # whose stdout still looks usable. Consumed once each,
                # like fail-list-chain-after-f.
                render_chain "$f"
                if [[ -f "$D/fail-list-chain-output-rc1" ]]; then
                    rm -f "$D/fail-list-chain-output-rc1"
                    printf '%s\n' "${RENDERED[@]}"
                    exit 1
                fi
                if [[ -f "$D/fail-list-chain-partial-rc1" ]]; then
                    rm -f "$D/fail-list-chain-partial-rc1"
                    printf '%s\n' "${RENDERED[0]:-}"
                    exit 1
                fi
                printf '%s\n' "${RENDERED[@]}"
                ;;
            set)
                # EGL-376-D-MOCK: list set <family> <table> <set>.
                # Seams: fail-list-set (one-shot, any) and
                # fail-list-set-<set> (one-shot) model a netlink read
                # fault while the set still exists in `list table`.
                [[ "$1" == inet ]] || { echo "mock nft: list set needs a family" >&2; exit 2; }
                if [[ -f "$D/fail-list-set-$3" ]]; then
                    rm -f "$D/fail-list-set-$3"
                    echo "Error: mock nft: netlink read of set '$3' failed once" >&2
                    exit 1
                fi
                if [[ -f "$D/fail-list-set" ]]; then
                    rm -f "$D/fail-list-set"
                    echo "Error: mock nft: netlink read of set '$3' failed once" >&2
                    exit 1
                fi
                if [[ ! -f "$D/sets/$2/$3.def" && ! -f "$D/sets/$2/$3.elements" ]]; then
                    echo "Error: No such file or directory" >&2
                    exit 1
                fi
                echo "table inet $2 {"
                render_set "$2" "$3" | sed 's/^/    /'
                echo "}"
                exit 0
                ;;
            table)
                # EGL-481 test seam: the chain-set read fails once
                # (one-shot), modelling an nft/netns read fault after the
                # content compares already passed. Must surface as the
                # named not-drift read-failure line, never as drift.
                if [[ -f "$D/fail-list-table" ]]; then
                    rm -f "$D/fail-list-table"
                    echo "Error: mock nft: netlink read of table '$2' failed once (fail-list-table)" >&2
                    exit 1
                fi
                # EGL-527: the two-shot variant — fail the next N table
                # reads (the counter file holds how many are left). The
                # one-shot seam above keeps its D5(f) semantics.
                if [[ -f "$D/fail-list-table-n" ]]; then
                    _flt_n="$(cat "$D/fail-list-table-n" 2>/dev/null || true)"
                    if [[ "$_flt_n" =~ ^[0-9]+$ ]] && (( _flt_n > 0 )); then
                        printf '%s\n' "$(( _flt_n - 1 ))" > "$D/fail-list-table-n"
                        echo "Error: mock nft: netlink read of table '$2' failed (fail-list-table-n, $_flt_n left)" >&2
                        exit 1
                    fi
                fi
                # Keyed on the TABLE name ($2), not the family: a table
                # exists iff it has chain state files or a sets dir.
                found=0
                for f in "$D/$2".*; do
                    [[ -f "$f" ]] || continue
                    found=1; cat "$f"
                done
                if [[ -d "$D/sets/$2" ]]; then
                    for _sf in "$D/sets/$2"/*.def; do
                        [[ -f "$_sf" ]] || continue
                        found=1
                        _sn="${_sf##*/}"; _sn="${_sn%.def}"
                        render_set "$2" "$_sn"
                    done
                fi
                [[ "$found" == 1 ]] || { echo "Error: No such file or directory" >&2; exit 1; }
                ;;
            tables)
                # EGL-438-D5: bare `nft list tables` — one brace-less
                # declaration line per fixture table (the <table>.<chain>
                # state files), like real nft's table-only listing. This
                # is the teardown oracle: rule/set/comment bytes never
                # appear, so foreign content cannot fake a declaration.
                declare -A tseen_t=()
                for f in "$D"/*; do
                    [[ -f "$f" ]] || continue
                    tbase="${f##*/}"
                    [[ "$tbase" == last-transaction.nft ]] && continue
                    [[ "$tbase" == *.* ]] || continue
                    ttable="${tbase%%.*}"
                    [[ -z "${tseen_t[$ttable]:-}" ]] || continue
                    tseen_t[$ttable]=1
                    echo "table inet $ttable"
                done
                # EGL-376: a table with only sets (its chains already
                # removed) still exists in real nft.
                for f in "$D/sets"/*; do
                    [[ -d "$f" ]] || continue
                    ttable="${f##*/}"
                    [[ -z "${tseen_t[$ttable]:-}" ]] || continue
                    tseen_t[$ttable]=1
                    echo "table inet $ttable"
                done
                # EGL-438-D5 test seam: extra declaration lines (wrong
                # family, lookalike, or a duplicate exact line) come from
                # this file, so a foreign shape needs no fixture chain.
                [[ -f "$D/list-tables-extra" ]] && cat "$D/list-tables-extra"
                exit 0
                ;;
            ruleset)
                # EGL-438-D5 test seam: the boundedness leg models the
                # ER's constrained-resource full-ruleset read failing
                # while `list tables` and deletes still work.
                if [[ -f "$D/list-ruleset-fails" ]]; then
                    echo "Error: Memory allocation failure" >&2
                    exit 1
                fi
                # ARC-52: every table's chains grouped under a table
                # header, like real `nft list ruleset` (family inet is
                # assumed in this mock). Scratch files are skipped:
                # last-transaction.nft (mock -f bookkeeping) and any
                # dot-less marker file.
                declare -A rseen_t=()
                for f in "$D"/*; do
                    [[ -f "$f" ]] || continue
                    rbase="${f##*/}"
                    [[ "$rbase" == last-transaction.nft ]] && continue
                    [[ "$rbase" == *.* ]] || continue
                    rtable="${rbase%%.*}"
                    [[ -z "${rseen_t[$rtable]:-}" ]] || continue
                    rseen_t[$rtable]=1
                    echo "table inet $rtable {"
                    for g in "$D/$rtable".*; do [[ -f "$g" ]] && cat "$g"; done
                    if [[ -d "$D/sets/$rtable" ]]; then
                        for _sf in "$D/sets/$rtable"/*.def; do
                            [[ -f "$_sf" ]] || continue
                            _sn="${_sf##*/}"; _sn="${_sn%.def}"
                            render_set "$rtable" "$_sn"
                        done
                    fi
                    echo "}"
                done
                # EGL-376: set-only tables (chains already removed).
                for f in "$D/sets"/*; do
                    [[ -d "$f" ]] || continue
                    rtable="${f##*/}"
                    [[ -z "${rseen_t[$rtable]:-}" ]] || continue
                    rseen_t[$rtable]=1
                    echo "table inet $rtable {"
                    for _sf in "$D/sets/$rtable"/*.def; do
                        [[ -f "$_sf" ]] || continue
                        _sn="${_sf##*/}"; _sn="${_sn%.def}"
                        render_set "$rtable" "$_sn"
                    done
                    echo "}"
                done
                ;;
        esac
        ;;
    *) echo "mock nft: unsupported op $cmd" >&2; exit 2 ;;
esac
EOF

# EGL-376 test helpers: seed the mock's per-profile drop-record set.
# The state layout mirrors the mock nft model ($ARCMOCK_STATE/nft/sets/
# <table>/<set>.def|.elements) so a test can preload a pre-feature policy
# or a specific listing shape without going through `nft -f`.
mock_nft_set_add() { # <table> <set> <ip> <port>
    local dir="${ARCMOCK_STATE:?}/nft/sets/$1"
    mkdir -p "$dir" || return 1
    if [[ ! -f "$dir/$2.def" ]]; then
        printf 'type ipv4_addr . inet_service\nflags dynamic,timeout\nsize 16384\ntimeout 24h\n' \
            > "$dir/$2.def" || return 1
    fi
    : >> "$dir/$2.elements" || return 1
    printf '%s %s\n' "$3" "$4" >> "$dir/$2.elements"
}
mock_nft_set_per_element_timeout() { # <table> <set>
    : > "${ARCMOCK_STATE:?}/nft/sets/$1/$2.timeout"
}

cat > "$TESTROOT/bin/getent" <<'EOF'
#!/usr/bin/env bash
# ARC-24 HOME-fallback knob, EGL-227 F1 rework: the mock answers NUMERIC
# `getent passwd <uid>` queries with the configured home (the engine's
# confdir_default HOME fallback and engine_lock_path are both numeric);
# name lookups still reach the real database.
if [[ "$1" == passwd && "$2" =~ ^[0-9]+$ ]]; then
    if [[ -n "${ARCMOCK_PASSWD_MISSING:-}" ]]; then
        exit 2
    fi
    if [[ -n "${ARCMOCK_PASSWD_HOME:-}" ]]; then
        echo "testuser:x:$EUID:0:test:$ARCMOCK_PASSWD_HOME:/bin/bash"
        exit 0
    fi
fi
[[ "$1" == ahostsv4 ]] || exec /usr/bin/getent "$@"
# Numeric IPv4 queries: real getent answers a dotted quad from the
# literal itself (ahostsv4 of an IP never consults DNS) — the engine
# relies on that for allow-host IPv4 pins (ARC-51-D2: resolve_ip
# "already returns the address"; EGL-18 harness pins literals end to
# end). The engine validates octets before resolving, so the mock can
# echo any dotted quad it is asked for.
if [[ "$2" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "$2 STREAM $2"
    exit 0
fi
# ARC-12 drift knob: EGRESSLOCK_MOCK_DNS="host=newip,host2=" overrides the
# pinned base mapping per call; host= (empty value) means "no longer
# resolves". Unlisted hosts keep the base mapping. EGL-219: a value may
# carry '+'-separated ADDRESSES (multi-A; both ARCMOCK_DNS_BASE and the
# override accept the same grammar); ',' is never an address separator.
declare -A BASE=()
if [[ -n "${ARCMOCK_DNS_BASE:-}" ]]; then
    IFS=, read -ra basepairs <<<"$ARCMOCK_DNS_BASE"
    for bp in "${basepairs[@]}"; do
        BASE["${bp%%=*}"]="${bp#*=}"
    done
fi
if [[ -n "${EGRESSLOCK_MOCK_DNS:-}" ]]; then
    IFS=, read -ra overrides <<<"$EGRESSLOCK_MOCK_DNS"
    for ov in "${overrides[@]}"; do
        h="${ov%%=*}"; v="${ov#*=}"
        BASE[$h]="$v"
    done
fi
# EGL-219-D14: stateful-resolver seam for the single-query regression.
# $ARCMOCK_STATE/dns-seq-<host>, when present and non-empty, serves (and
# pops) its first line — same '+'-grammar as the base mapping — so
# consecutive lookups of one host can differ. When
# $ARCMOCK_STATE/dns-queries.log exists, every served answer is appended
# as '<host>=<value>' (base path included), making the lookup count
# observable; with neither file the mock is byte-identical to before.
if [[ -n "${ARCMOCK_STATE:-}" && -s "$ARCMOCK_STATE/dns-seq-$2" ]]; then
    seq_ip="$(head -n 1 "$ARCMOCK_STATE/dns-seq-$2")"
    sed -i '1d' "$ARCMOCK_STATE/dns-seq-$2"
    if [[ -f "$ARCMOCK_STATE/dns-queries.log" ]]; then
        printf '%s=%s\n' "$2" "$seq_ip" >> "$ARCMOCK_STATE/dns-queries.log"
    fi
    if [[ -n "$seq_ip" ]]; then
        IFS='+' read -ra seq_addrs <<<"$seq_ip"
        for seq_addr in "${seq_addrs[@]}"; do
            echo "$seq_addr STREAM $2"
        done
        exit 0
    fi
    exit 2
fi
ip="${BASE[$2]-}"
if [[ -n "$ip" ]]; then
    # EGL-219: a '+'-separated value is several A records for the
    # host — one emitted line per address, in the GIVEN order (a
    # resolver's order is not canonical; the engine sorts). ',' stays
    # the pair separator (never an address separator).
    IFS='+' read -ra mock_addrs <<<"$ip"
    for mock_addr in "${mock_addrs[@]}"; do
        echo "$mock_addr STREAM $2"
    done
    if [[ -n "${ARCMOCK_STATE:-}" && -f "$ARCMOCK_STATE/dns-queries.log" ]]; then
        printf '%s=%s\n' "$2" "$ip" >> "$ARCMOCK_STATE/dns-queries.log"
    fi
    exit 0
fi
exit 2
EOF

cat > "$TESTROOT/bin/podman" <<'EOF'
#!/usr/bin/env bash
# Mock podman: persistent-enough state for the egresslock flow.
set -u
# EGL-378: real rootless podman re-enters the inherited CWD at startup
# as the account; a directory the account cannot traverse kills the call
# with `cannot chdir to <dir>: Permission denied` before any work. Model
# that here so a missing CWD guard is a behavioral failure, not a silent
# pass. ARCMOCK_PODMAN_CWD_LOG (optional) records each call's start CWD.
[[ -n "${ARCMOCK_PODMAN_CWD_LOG:-}" ]] && printf '%s\n' "$PWD" >> "$ARCMOCK_PODMAN_CWD_LOG"
if ! ( cd . ) 2>/dev/null; then
    echo "Error: cannot chdir to $PWD: Permission denied" >&2
    exit 125
fi
# EGL-378 R-EGL-378-8: podman reads path-valued environment settings at
# startup, resolving a relative value against the inherited CWD. Model
# that on request: ARCMOCK_PODMAN_CONFIG_VARS names the settings to read
# (space/comma separated); each non-empty value must exist as seen from
# this process's startup CWD, and each resolved path is logged as
# VAR=<path> in ARCMOCK_PODMAN_CONFIG_LOG. A missing path is podman's own
# startup failure (rc 125). Inert unless the knob is set.
if [[ -n "${ARCMOCK_PODMAN_CONFIG_VARS:-}" ]]; then
    read -ra _pvs <<<"${ARCMOCK_PODMAN_CONFIG_VARS//,/ }"
    for _pv in "${_pvs[@]}"; do
        _pp="${!_pv:-}"
        [[ -n "$_pp" ]] || continue
        if [[ ! -e "$_pp" ]]; then
            echo "Error: reading configuration file \"$_pp\": no such file or directory" >&2
            exit 125
        fi
        [[ -n "${ARCMOCK_PODMAN_CONFIG_LOG:-}" ]] \
            && printf '%s=%s\n' "$_pv" "$_pp" >> "$ARCMOCK_PODMAN_CONFIG_LOG"
    done
fi
D="${ARCMOCK_STATE:?}"
[[ -d "$D/nft" && -d "$D/networks" && -d "$D/running" && -d "$D/containers" ]] \
    || mkdir -p "$D/nft" "$D/networks" "$D/running" "$D/containers"
# EGL-369-D7: per-container gateway image layout. The current shipped image
# carries the real /etc/squid/egresslock dir plus /etc/squid/agent as a
# relative symlink (both answer `test -d`); an un-replaced old image carries
# /etc/squid/agent only. Default = current image; the marker
# $D/gw-layout-agent[-<name>] selects the old layout. Knob
# $D/gw-probe-egresslock[-<name>] forces the new dir to answer on an
# old-layout container to exercise the engine's fail-closed mismatch path.
# $D/gw-probe-fails[-<name>] makes the probe a runtime/exec error (rc 125);
# $D/gw-probe-old-once[-<name>] answers the old dir on the first probe only;
# $D/gw-probe-fail-after-old-once[-<name>] then errors on every later probe
# (R-EGL-369-13 F3: proves the apply layout is bound through verify/cleanup).
mock_layout() { # <name> -> egresslock|agent
    if [[ -f "$D/gw-layout-agent-$1" || -f "$D/gw-layout-agent" ]]; then
        echo agent
    else
        echo egresslock
    fi
}
mock_layout_has() { # <layout> <abs-dir> -> 0 when that layout has the dir
    local layout="$1" dir="$2"
    case "$dir" in
        /etc/squid/egresslock) [[ "$layout" == egresslock ]] ;;
        /etc/squid/agent) return 0 ;; # old image's real dir, or new image's symlink
        *) return 1 ;;
    esac
}
mock_layout_probe() { # <name> -> layout the `test -d` probe answers
    local layout
    layout="$(mock_layout "$1")"
    [[ -f "$D/gw-probe-egresslock-$1" || -f "$D/gw-probe-egresslock" ]] \
        && layout=egresslock
    echo "$layout"
}
# EGL-395: separate staged/deployed models. The deployed config dir is
# $D/containers-<name>.cfg/ (files by their final basename); per-run
# private stages are real subdirectories ($D/...cfg/.egresslock-stage.*)
# so a staged candidate is never aliased onto the deployed squid.conf.
# Both layouts map onto the same deployed tree (the old image carries
# only the agent path; the new image answers both).
mock_cfg_local() { # <name> <in-container-abs-path> -> host path, rc 1 outside cfgdir
    local name="$1" abs="$2" layout rel
    layout="$(mock_layout "$name")"
    case "$abs" in
        /etc/squid/egresslock)
            [[ "$layout" == egresslock ]] || return 1
            rel="" ;;
        /etc/squid/egresslock/*)
            [[ "$layout" == egresslock ]] || return 1
            rel="${abs#/etc/squid/egresslock/}" ;;
        /etc/squid/agent)
            rel="" ;;
        /etc/squid/agent/*)
            rel="${abs#/etc/squid/agent/}" ;;
        *) return 1 ;;
    esac
    [[ "$rel" != *..* && "$rel" != /* ]] || return 1
    echo "$D/containers-$name.cfg/$rel"
}
mock_cfg_abs() { # <name> -> the in-container cfgdir prefix for this layout
    if [[ "$(mock_layout "$1")" == egresslock ]]; then
        echo /etc/squid/egresslock
    else
        echo /etc/squid/agent
    fi
}
mock_cfg_init() { # <name> — first boot / replace: bootstrap cfgdir + identity
    local name="$1"
    rm -rf "$D/containers-$name.cfg" "$D/containers-$name.candidate" \
           "$D/containers-$name.pending-mv" "$D/containers-$name.started" \
           "$D/containers-$name.id" "$D/containers-$name.live" \
           "$D/containers-$name.live-token"
    mkdir -p "$D/containers-$name.cfg"
    # EGL-394: a booted Squid has its cache.log open from the start.
    : > "$D/containers-$name.cache.log"
    : > "$D/containers-$name.cfg/allowlist.conf"
    # A replacement container gets a NEW ID (the .gen counter survives the
    # rm); restarts keep it. EGL-395's witness binds that instance ID.
    local gen=0
    [[ -f "$D/containers-$name.gen" ]] && read -r gen < "$D/containers-$name.gen"
    [[ "$gen" =~ ^[0-9]+$ ]] || gen=0
    gen=$((gen + 1))
    printf '%s\n' "$gen" > "$D/containers-$name.gen"
    printf 'mockid%s%sg%s\n' "$(printf '%s' "$name" | sha256sum | cut -c1-56)" "$gen" "$gen" \
        > "$D/containers-$name.id"
    printf '2026-01-01T00:00:00.000000000Z#1\n' > "$D/containers-$name.started"
    # EGL-394: a fresh container boots the entrypoint's bootstrap config.
    printf '/etc/squid/squid.conf\n' > "$D/containers-$name.argv"
    if [[ -f "${ARCMOCK_TREE_ROOT:-}/gateway/squid.conf" ]]; then
        cp "${ARCMOCK_TREE_ROOT}/gateway/squid.conf" "$D/containers-$name.live"
    else
        : > "$D/containers-$name.live"
    fi
}
mock_cfg_argv_set() { # <name> — the argv the running Squid was started with
    local name="$1"
    if [[ -f "$D/containers-$name.cfg/squid.conf" ]]; then
        printf '%s\n' "$(mock_cfg_abs "$name")/squid.conf" > "$D/containers-$name.argv"
    else
        printf '/etc/squid/squid.conf\n' > "$D/containers-$name.argv"
    fi
}
mock_cfg_load_live() { # <name> — a start/restart loads the deployed config (or bootstrap)
    local name="$1" src token
    [[ -f "$D/containers-$name.cache.log" ]] || : > "$D/containers-$name.cache.log"
    mock_cfg_argv_set "$name"
    if [[ -f "$D/containers-$name.cfg/squid.conf" ]]; then
        src="$D/containers-$name.cfg/squid.conf"
    elif [[ -f "${ARCMOCK_TREE_ROOT:-}/gateway/squid.conf" ]]; then
        src="${ARCMOCK_TREE_ROOT}/gateway/squid.conf"
    else
        : > "$D/containers-$name.live"
        rm -f "$D/containers-$name.live-token"
        return 0
    fi
    cp "$src" "$D/containers-$name.live"
    # EGL-393-D5: the live token is the one embedded in the config that
    # was LOADED (the deny_info URL), exactly what Squid would answer
    # with — never a recompute from the current group files. Bootstrap /
    # no block -> no token (the probe then has no redirect to return).
    token="$(sed -n "s|^deny_info 302:http://egresslock-probe\\.invalid/live/\\([0-9a-f]\\{64\\}\\) egl393_probe_dst\$|\\1|p" "$src" | head -n1)"
    if [[ -n "$token" ]]; then
        printf '%s\n' "$token" > "$D/containers-$name.live-token"
    else
        rm -f "$D/containers-$name.live-token"
    fi
}
mock_bump_started() { # <name> — a restart changes StartedAt; Id stays
    local name="$1" n
    n="$(sed -n 's/.*#\([0-9][0-9]*\)$/\1/p' "$D/containers-$name.started" 2>/dev/null | head -1)"
    [[ -n "$n" ]] || n=0
    printf '2026-01-01T00:00:00.000000000Z#%s\n' "$((n + 1))" > "$D/containers-$name.started"
}
# EGL-394 F1: model a deployed config swapped out after the running
# instance loaded it and restored to the SAME bytes. A byte-identical
# copy has the same generation but a new device/inode and ctime, so only
# the stat-identity chain can tell the load did not come from the file
# being claimed.
mock_cfg_restored_after_load() { # <name> — identical deployed squid.conf, new inode/ctime
    local name="$1" f
    f="$D/containers-$name.cfg/squid.conf"
    [[ -f "$f" ]] || return 0
    cp -p "$f" "$f.egl394-restore" || return 0
    mv -f "$f.egl394-restore" "$f"
    return 0
}
# EGL-515: batched read-only probes (`bash -c <script> egl515-batch ...`).
# Each record models one in-container probe; the knobs keep the
# fail-closed seams reachable per key and per batch.
mock_batch_test() { # <name> <op> <path> -> rc
    local name="$1" topt="$2" tpath="$3" lpath="" tstate=1
    case "$topt" in
        -e|-f|-L) ;;
        *) return 2 ;;
    esac
    if [[ "$topt" == "-e" && ( -f "$D/batch-test-e-fails-$name" || -f "$D/batch-test-e-fails" ) ]] \
        || [[ "$topt" == "-L" && ( -f "$D/batch-test-L-fails-$name" || -f "$D/batch-test-L-fails" ) ]] \
        || [[ "$topt" == "-f" && ( -f "$D/batch-test-f-fails-$name" || -f "$D/batch-test-f-fails" ) ]]; then
        return 2
    fi
    if [[ "$topt" == "-e" && ( -f "$D/exec-test-e-fails-$name" || -f "$D/exec-test-e-fails" ) ]]; then
        return 2
    fi
    if [[ "$topt" == "-L" && ( -f "$D/exec-test-L-fails-$name" || -f "$D/exec-test-L-fails" ) ]]; then
        return 2
    fi
    if [[ "$topt" == "-L" && -f "$D/exec-test-L-fails-deployed" && "$tpath" == */squid.conf && "$tpath" != */.egresslock-stage.* ]]; then
        return 2
    fi
    if [[ "$topt" == "-e" && -f "$D/exec-test-e-fails-stage" && "$tpath" == */.egresslock-stage.* ]]; then
        return 2
    fi
    case "$tpath" in
        /var/log/squid/access.log) lpath="$D/containers-$name.access.log" ;;
        /var/log/squid/cache.log) lpath="$D/containers-$name.cache.log" ;;
        *) lpath="$(mock_cfg_local "$name" "$tpath" 2>/dev/null)" || lpath="" ;;
    esac
    [[ -n "$lpath" ]] || return 1
    case "$topt" in
        -e) [[ -e "$lpath" ]] && tstate=0 ;;
        -f) [[ -f "$lpath" && ! -L "$lpath" ]] && tstate=0 ;;
        -L) [[ -L "$lpath" ]] && tstate=0 ;;
    esac
    return "$tstate"
}

mock_batch_hash() { # <name> <path> -> payload; rc
    local name="$1" tpath="$2" lpath=""
    # EGL-395 publication-resolution seam: a lost rename result leaves
    # the deployed-config read failing (never "absent").
    if [[ -f "$D/read-fails-$name" && "$tpath" == */squid.conf \
        && "$tpath" != *"/.egresslock-stage."* ]]; then
        return 1
    fi
    case "$tpath" in
        /var/log/squid/access.log) lpath="$D/containers-$name.access.log" ;;
        /var/log/squid/cache.log) lpath="$D/containers-$name.cache.log" ;;
        *) lpath="$(mock_cfg_local "$name" "$tpath" 2>/dev/null)" || lpath="" ;;
    esac
    [[ -n "$lpath" && -f "$lpath" ]] || return 1
    sha256sum "$lpath" | sed "s|  $lpath\$|  $tpath|"
}

mock_batch_stat_ident() { # <name> <path> -> payload; rc
    local name="$1" tpath="$2" lpath=""
    # EGL-394: a failed identity read after a confirmed publication dies
    # committed+owned (the running gateway was not activated).
    if [[ -f "$D/conf-ident-fails-$name" || -f "$D/conf-ident-fails" ]]; then
        return 1
    fi
    case "$tpath" in
        # EGL-540: the cap's batch also stats the `.1` generations; the
        # same basename mapping the log mv/rm handlers use answers them.
        /var/log/squid/*.log*) lpath="$D/containers-$name.${tpath##*/}" ;;
        *) lpath="$(mock_cfg_local "$name" "$tpath" 2>/dev/null)" || lpath="" ;;
    esac
    [[ -n "$lpath" && -f "$lpath" ]] || return 1
    stat -c '%d:%i %s %z' "$lpath"
}

mock_batch_stat_stream() { # <name> <path> -> payload; rc
    local name="$1" tpath="$2" lpath=""
    case "$tpath" in
        # EGL-540: `.1` keys ride the same read window as the live logs.
        /var/log/squid/*.log*) lpath="$D/containers-$name.${tpath##*/}" ;;
        *) lpath="$(mock_cfg_local "$name" "$tpath" 2>/dev/null)" || lpath="" ;;
    esac
    [[ -n "$lpath" && -f "$lpath" ]] || return 1
    printf '%s %s\n' "$(stat -c %d:%i "$lpath")" "$(wc -c < "$lpath")"
}

mock_batch_mtime() { # <name> <path> -> payload; rc
    local name="$1" tpath="$2" lpath=""
    lpath="$(mock_cfg_local "$name" "$tpath" 2>/dev/null)" || lpath=""
    [[ -n "$lpath" && -e "$lpath" ]] || return 1
    stat -c %Y "$lpath"
}

mock_batch_prefix() { # <name> <path> -> "dev:inode size prefix-hash"; rc
    local name="$1" tpath="$2" lpath="" st size plen h
    # EGL-515: the warm reload gate's pre-signal baseline (once the
    # reload pre-read moved into the batch). Same failure knobs the old
    # pre mode honored.
    if [[ -f "$D/reload-stat-fails-$name" || -f "$D/reload-stat-fails" ]]; then
        return 1
    fi
    case "$tpath" in
        /var/log/squid/access.log) lpath="$D/containers-$name.access.log" ;;
        /var/log/squid/cache.log) lpath="$D/containers-$name.cache.log" ;;
        *) lpath="$(mock_cfg_local "$name" "$tpath" 2>/dev/null)" || lpath="" ;;
    esac
    [[ -n "$lpath" && -f "$lpath" ]] || return 1
    st="$(stat -c '%d:%i %s' "$lpath")"
    size="${st##* }"
    if (( size < 4096 )); then plen=$size; else plen=4096; fi
    if (( plen > 0 )); then
        if [[ -f "$D/reload-prefix-fails-$name" || -f "$D/reload-prefix-fails" ]] \
            || [[ -f "$D/reload-prefix-head-fails-$name" || -f "$D/reload-prefix-head-fails" ]]; then
            return 1
        fi
        h="$(head -c "$plen" "$lpath" | sha256sum)"
        printf '%s %s\n' "$st" "${h%%[[:space:]]*}"
    else
        printf '%s \n' "$st"
    fi
}

mock_caps_pair() { # <name> -> "CapEff NoNewPrivs"; rc 1 unreadable, 2 missing
    local name="$1" knob_bad="" knob_nnp="" knob_unreadable="" knob_shell=""
    local knob_badtext="" knob_nnpbadtext=""
    # EGL-206-D2b: healthy default (CapEff all-zero, NoNewPrivs 1), with
    # the same per-container-then-global knobs the exec oracle models.
    [[ -f "$D/caps-bad-$name" || -f "$D/caps-bad" ]] && knob_bad=1
    [[ -f "$D/caps-nnp-$name" || -f "$D/caps-nnp" ]] && knob_nnp=1
    [[ -f "$D/caps-unreadable-$name" || -f "$D/caps-unreadable" ]] && knob_unreadable=1
    # EGL-415: the install-shell five-cap add-back (SETUID, SETGID,
    # CHOWN, DAC_OVERRIDE, FOWNER = 0xcb) is the one allowed non-zero
    # workload mask.
    [[ -f "$D/caps-shell-$name" || -f "$D/caps-shell" ]] && knob_shell=1
    # EGL-415 rework: malformed text in either field must render the row
    # UNKNOWN, never echo the raw value.
    [[ -f "$D/caps-badtext-$name" || -f "$D/caps-badtext" ]] && knob_badtext=1
    [[ -f "$D/caps-nnpbadtext-$name" || -f "$D/caps-nnpbadtext" ]] && knob_nnpbadtext=1
    if [[ -n "$knob_unreadable" ]]; then
        return 1
    fi
    if [[ -n "$knob_badtext" ]]; then
        printf 'zzzz-not-hex 1\n'
        return 0
    fi
    if [[ -n "$knob_nnpbadtext" ]]; then
        printf '0000000000000000 zz\n'
        return 0
    fi
    local capseff="0000000000000000" nnp="1"
    [[ -n "$knob_bad" ]] && capseff="00000000000001f7"
    [[ -n "$knob_shell" ]] && capseff="00000000000000cb"
    [[ -n "$knob_nnp" ]] && nnp="0"
    printf '%s %s\n' "$capseff" "$nnp"
}

mock_batch_argv() { # <name> <cfgdir> -> rc 0 when PID 1 is squid -N -f <cfgdir>/squid.conf
    local name="$1" cfgdir="$2" want
    if [[ -f "$D/argv-bad-$name" || -f "$D/argv-bad" ]]; then
        return 1
    fi
    if [[ -f "$D/containers-$name.argv" ]]; then
        want="$(cat "$D/containers-$name.argv")"
    elif [[ -f "$D/containers-$name.cfg/squid.conf" ]]; then
        want="$(mock_cfg_abs "$name")/squid.conf"
    else
        want="/etc/squid/squid.conf"
    fi
    [[ "$want" == "$cfgdir/squid.conf" ]]
}

# EGL-515: model the one-shot deployed-vs-live HTTP GET (EGL-393) once,
# shared by the single-exec shape and the batch `G` op. Prints the raw
# response; returns 1 when the listener never answers (probe-fails).
# EGL-515: model the container-side `mv -T <src> <dst>` rename used by
# the publish script (extracted from the exec mv branch so both the
# single-call shape and the batch-era script share one model).
mock_mv_T() { # <name> <src> <dst>
    local name="$1" msrc="$2" mdst="$3" lsrc="" ldst=""
    lsrc="$(mock_cfg_local "$name" "$msrc" 2>/dev/null)" || lsrc=""
    ldst="$(mock_cfg_local "$name" "$mdst" 2>/dev/null)" || ldst=""
    if [[ -f "$D/mv-rc0-old" || -f "$D/mv-rc0-absent" || -f "$D/mv-rc0-other" ]]; then
        # EGL-395: a zero rc reports a completed rename; a later
        # read-back that is not the candidate is Unknown. Model an
        # outside writer / lying primitive: report success without
        # publishing.
        if [[ -f "$D/mv-rc0-absent" ]]; then
            [[ -n "$ldst" ]] && rm -f "$ldst"
        elif [[ -f "$D/mv-rc0-other" && -n "$ldst" ]]; then
            printf 'tampered\n' > "$ldst"
        fi
        return 0
    fi
    if [[ -f "$D/mv-check-fails" ]]; then
        echo "mv: cannot move '$msrc': simulated swap failure" >&2
        return 1
    fi
    if [[ -f "$D/mv-arm-read-fails" ]]; then
        # EGL-395: the rename client result is lost and the container
        # read path then fails. The resolution must classify the read
        # error as Unknown, never as a proven pre-publication state.
        : > "$D/read-fails-$name"
        echo "Error: error moving file: simulated lost rename result" >&2
        return 1
    fi
    if [[ -f "$D/mv-arm-probe-fails" ]]; then
        # EGL-395 R-EGL-395-4 F1(a): the rename reports a failure and the
        # deployed read-back then fails on both the hash and the -L
        # probe. With a bootstrap (old generation absent) tree this must
        # stay Unknown/S-P4: a failed probe is never `absent`, so it
        # cannot prove pre-publication.
        : > "$D/read-fails-$name"
        : > "$D/exec-test-L-fails-deployed"
        echo "Error: error moving file: simulated lost rename result" >&2
        return 1
    fi
    if [[ -f "$D/mv-lost-result-landed" || -f "$D/mv-lost-result-not-landed" \
        || -f "$D/mv-delayed-lands" || -f "$D/mv-unknown" ]]; then
        if [[ -f "$D/mv-lost-result-landed" ]]; then
            [[ -n "$lsrc" && -f "$lsrc" && -n "$ldst" ]] && mv -f "$lsrc" "$ldst"
        elif [[ -f "$D/mv-delayed-lands" ]]; then
            printf '%s\n%s\n' "$msrc" "$mdst" > "$D/containers-$name.pending-mv"
        fi
        echo "Error: error moving file: simulated lost rename result" >&2
        return 1
    fi
    if [[ -z "$lsrc" || ! -f "$lsrc" ]]; then
        echo "mv: cannot stat '$msrc': No such file or directory" >&2
        return 1
    fi
    if [[ -z "$ldst" ]]; then
        echo "mv: cannot move '$msrc' to '$mdst': No such file or directory" >&2
        return 1
    fi
    if [[ -d "$ldst" && ! -L "$ldst" ]]; then
        echo "mv: cannot overwrite directory '$mdst'" >&2
        return 1
    fi
    mv -f "$lsrc" "$ldst"
}

# EGL-515: model the purpose-built publish script (`EGL-515 publish v1`):
# witness removal, `mv -T`, and a success-only stage sweep in one exec.
# The stage sweep is best-effort in the script, so its failure stays
# silent and leaves the stage for the host's quiescence path.
mock_publish() { # <name> <witness> <src> <dst> <stage>
    local name="$1" witness="$2" src="$3" dst="$4" stage="$5" wl="" sdir="" rc=0
    wl="$(mock_cfg_local "$name" "$witness" 2>/dev/null)" || wl=""
    if [[ -n "$wl" ]]; then rm -f "$wl" 2>/dev/null || true; fi
    mock_mv_T "$name" "$src" "$dst" || rc=$?
    if (( rc == 0 )); then
        sdir="$(mock_cfg_local "$name" "$stage" 2>/dev/null)" || sdir=""
        if [[ -n "$sdir" && ! -f "$D/rm-stage-fails" ]]; then
            rm -rf "$sdir"
        fi
    fi
    return "$rc"
}

# EGL-515: model cleanup's one-exec window (`EGL-515 cleanup-read v2`):
# witness removal, deployed-config read and the single type/mtime/name
# listing. Two space-delimited base64 records (`cfg`, `find`) so one exec
# still carries exact bytes; the script itself always exits 0.
mock_cleanup() { # <name> <witness> <conf> <dir>
    local name="$1" witness="$2" conf="$3" dir="$4" wl="" cl="" ldir="" f typ
    local frc=0 fdata="" listing=""
    local -a _found=() _lines=()
    wl="$(mock_cfg_local "$name" "$witness" 2>/dev/null)" || wl=""
    if [[ -n "$wl" ]]; then rm -f "$wl" 2>/dev/null || true; fi
    cl="$(mock_cfg_local "$name" "$conf" 2>/dev/null)" || cl=""
    if [[ -n "$cl" && -f "$cl" ]]; then
        printf 'cfg 0 %s\n' "$(base64 -w0 < "$cl")"
    else
        printf 'cfg 1 \n'
    fi
    if [[ -f "$D/find-fails-$name" || -f "$D/find-fails" ]]; then
        echo "find: ${dir:-}: Input/output error" >&2
        frc=1
    else
        ldir="$(mock_cfg_local "$name" "${dir%/}" 2>/dev/null)" || ldir=""
        if [[ -z "$ldir" ]]; then
            echo "find: '${dir}': No such file or directory" >&2
            frc=1
        else
            shopt -s dotglob nullglob
            _found=("$ldir"/*)
            shopt -u dotglob nullglob
            for f in "${_found[@]}"; do
                typ=o
                [[ -L "$f" ]] && typ=l
                [[ -f "$f" && ! -L "$f" ]] && typ=f
                [[ -d "$f" && ! -L "$f" ]] && typ=d
                _lines+=("$(printf '%s %s %s' "$typ" "$(stat -c %Y "$f")" "${f##*/}")")
            done
            if (( ${#_lines[@]} > 0 )); then
                listing="$(printf '%s\n' "${_lines[@]}")"
            fi
            fdata="$(printf '%s' "$listing" | base64 -w0)"
        fi
    fi
    printf 'find %s %s\n' "$frc" "$fdata"
    return 0
}

mock_live_http() { # <name> -> raw HTTP; rc 1 no listener
    local name="$1" _ltok=""
    if [[ -f "$D/probe-fails-active-$name" || -f "$D/reload-probe-fails-active-$name" ]]; then
        return 1
    fi
    _ltok="$(cat "$D/containers-$name.live-token" 2>/dev/null || true)"
    if [[ -f "$D/live-probe-no-response-$name" || -f "$D/live-probe-no-response" ]]; then
        return 0
    fi
    if [[ -f "$D/live-probe-403-$name" || -f "$D/live-probe-403" ]]; then
        printf 'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'
        return 0
    fi
    if [[ -f "$D/live-probe-malformed-location-$name" || -f "$D/live-probe-malformed-location" ]]; then
        printf 'HTTP/1.1 302 Found\r\nLocation: http://egresslock-probe.invalid/live/not-a-token\r\nContent-Length: 0\r\n\r\n'
        return 0
    fi
    if [[ -f "$D/live-probe-wrong-token-$name" || -f "$D/live-probe-wrong-token" ]]; then
        printf 'HTTP/1.1 302 Found\r\nLocation: http://egresslock-probe.invalid/live/%064d\r\nContent-Length: 0\r\n\r\n' 0
        return 0
    fi
    if [[ -f "$D/live-probe-no-location-$name" || -f "$D/live-probe-no-location" || -z "$_ltok" ]]; then
        printf 'HTTP/1.1 302 Found\r\nContent-Length: 0\r\n\r\n'
        return 0
    fi
    printf 'HTTP/1.1 302 Found\r\nLocation: http://egresslock-probe.invalid/live/%s\r\nContent-Length: 0\r\n\r\n' "$_ltok"
}

mock_batch() { # <name> <key op path>...
    local name="$1"; shift
    local key op path out rc i=0 gport grest gurl ghost ghttp
    if [[ -f "$D/batch-exec-fails" ]]; then
        echo "Error: can only create exec sessions on running containers: container state improper" >&2
        exit 125
    fi
    while (( $# )); do
        key="$1"; op="$2"; path="$3"; shift 3
        i=$((i + 1))
        out=""; rc=0
        case "$op" in
            e) mock_batch_test "$name" -e "$path" || rc=$? ;;
            L) mock_batch_test "$name" -L "$path" || rc=$? ;;
            f) mock_batch_test "$name" -f "$path" || rc=$? ;;
            h) out="$(mock_batch_hash "$name" "$path" 2>/dev/null)" || rc=$?
               out="${out%%[[:space:]]*}" ;;
            i) out="$(mock_batch_stat_ident "$name" "$path" 2>/dev/null)" || rc=$? ;;
            s) out="$(mock_batch_stat_stream "$name" "$path" 2>/dev/null)" || rc=$? ;;
            m) out="$(mock_batch_mtime "$name" "$path" 2>/dev/null)" || rc=$? ;;
            B) out="$(mock_batch_prefix "$name" "$path" 2>/dev/null)" || rc=$? ;;
            P) # A stopped container cannot run the probe exec at all (real
               # podman exec fails); the mock's generic exec gate accepts a
               # registered container, so the liveness op owns the running
               # oracle here — the batch must not bless a stopped instance.
               if [[ ! -f "$D/running/$name" ]] \
                   || [[ -f "$D/probe-fails-active-$name" || -f "$D/reload-probe-fails-active-$name" ]]; then
                   rc=1
               else
                   rc=0
               fi ;;
            C) out="$(mock_caps_pair "$name" 2>/dev/null)" || rc=$? ;;
            A) mock_batch_argv "$name" "$path" || rc=$? ;;
            G) gport="${path%%|*}"; grest="${path#*|}"
               gurl="${grest%%|*}"; ghost="${grest#*|}"
               if [[ "$gport" =~ ^[0-9]+$ && -n "$gurl" && -n "$ghost" ]]; then
                   if ghttp="$(mock_live_http "$name")"; then
                       out="$(printf '%s' "$ghttp" | base64 -w0)" || rc=$?
                   else
                       rc=2
                   fi
               else
                   rc=2
               fi ;;
            *) rc=2 ;;
        esac
        case "$rc" in 0|1) ;; *) rc=2 ;; esac
        [[ -f "$D/batch-drop-key-$key" ]] && continue
        if [[ -f "$D/batch-blank-$key" ]]; then
            # F4: an internal blank line is a malformed record (D1); the
            # parser must invalidate the whole batch, not skip it.
            printf '\n%s\t%s\t%s\n' "$key" "$rc" "$out"
        elif [[ -f "$D/batch-malformed-$key" ]]; then
            printf 'malformed record\n'
        elif [[ -f "$D/batch-dup-$key" ]]; then
            printf '%s\t%s\t%s\n%s\t%s\t%s\n' "$key" "$rc" "$out" "$key" "$rc" "$out"
        elif [[ -f "$D/batch-rc9-$key" ]]; then
            printf '%s\t9\t%s\n' "$key" "$out"
        else
            printf '%s\t%s\t%s\n' "$key" "$rc" "$out"
        fi
        if [[ -f "$D/batch-partial-dies" && "$i" -ge 1 ]]; then
            exit 1
        fi
    done
}

# EGL-515: model the purpose-built reload read script (`EGL-515
# reload-read v1`). Emits the same TAB records the container-side script
# would. Probe failures are rc 2; a tail that does not carry the witness
# is rc 1 (the host maps that to its existing named error). Only the
# post-signal mode is reachable — the pre-signal baseline is batch op `B`
# (`mock_batch_prefix`), so there is no `pre` model here (F1).
mock_reload_read() { # <name> <post> [<prev-ident> <before> <plen> <phash> <cfgdir>]
    local name="$1"
    shift 2
    local f="$D/containers-$name.cache.log" st h new
    local prev_ident="$1" before="$2" plen_arg="$3" cfgdir="$5"
    _rl_post_stat() {
        if [[ -f "$D/reload-stat-fails-$name" || -f "$D/reload-stat-fails" ]] \
            || [[ ! -f "$f" ]]; then
            return 1
        fi
        # EGL-394 F2: a later post-signal observation of the
        # shrink-then-regrow seam sees the stream regrown past the
        # original offset with a matching witness. The fixed engine
        # treats the first shrink as terminal and never accepts it.
        if [[ -f "$D/reload-log-shrink-regrow-pending-$name" ]]; then
            local _n=0
            [[ -f "$D/reload-log-shrink-regrow-pending-$name.n" ]] \
                && read -r _n < "$D/reload-log-shrink-regrow-pending-$name.n"
            _n=$((_n + 1))
            printf '%s\n' "$_n" > "$D/reload-log-shrink-regrow-pending-$name.n"
            if (( _n >= 2 )); then
                rm -f "$D/reload-log-shrink-regrow-pending-$name" \
                      "$D/reload-log-shrink-regrow-pending-$name.n"
                : > "$f"
                printf '%05000d' 0 >> "$f"
                {
                    printf 'Reconfiguring Squid Cache (version 6.13)...\n'
                    printf 'Processing Configuration File: %s/squid.conf (depth 0)\n' "$(mock_cfg_abs "$name")"
                } >> "$f"
                mock_cfg_load_live "$name"
            fi
        fi
        stat -c '%d:%i %s' "$f"
    }
    if ! st="$(_rl_post_stat)"; then
        printf 's1\t2\t\np\t2\t\nt\t2\t\nw1\t2\t\nw2\t2\t\ns2\t2\t\n'
        return 0
    fi
    printf 's1\t0\t%s\n' "$st"
    if (( plen_arg > 0 )); then
        if [[ -f "$D/reload-prefix-fails-$name" || -f "$D/reload-prefix-fails" ]] \
            || [[ -f "$D/reload-prefix-head-fails-$name" || -f "$D/reload-prefix-head-fails" ]]; then
            printf 'p\t2\t\n'
        else
            h="$(head -c "$plen_arg" "$f" | sha256sum)"
            printf 'p\t0\t%s\n' "${h%%[[:space:]]*}"
        fi
    else
        printf 'p\t1\t\n'
    fi
    new=""
    if new="$(tail -c "+$((before + 1))" "$f" 2>/dev/null)"; then
        printf 't\t0\t\n'
        if [[ "$new" == *"Reconfiguring Squid Cache"* ]]; then
            printf 'w1\t0\t\n'
        else
            printf 'w1\t1\t\n'
        fi
        if [[ "$new" == *"Processing Configuration File: $cfgdir/squid.conf (depth 0)"* ]]; then
            printf 'w2\t0\t\n'
        else
            printf 'w2\t1\t\n'
        fi
        # EGL-394 H2: swap the stream AFTER the witness bytes are read;
        # the re-stat inside the same script must see the new inode.
        if [[ -f "$D/reload-log-replaced-at-tail-once-$name" ]]; then
            rm -f "$D/reload-log-replaced-at-tail-once-$name"
            cp "$f" "$f.at-tail"
            mv -f "$f.at-tail" "$f"
        fi
    else
        printf 't\t2\t\nw1\t2\t\nw2\t2\t\n'
    fi
    if st="$(_rl_post_stat)"; then
        printf 's2\t0\t%s\n' "$st"
    else
        printf 's2\t2\t\n'
    fi
    return 0
}

mock_perform_pending_mv() { # <name> <in-container stage dir> — delayed rename lands before sweep
    local name="$1" stage="$2" src dst
    [[ -f "$D/containers-$name.pending-mv" ]] || return 0
    src="$(sed -n '1p' "$D/containers-$name.pending-mv")"
    dst="$(sed -n '2p' "$D/containers-$name.pending-mv")"
    if [[ "$src" == "$stage"/* ]]; then
        local lsrc ldst
        lsrc="$(mock_cfg_local "$name" "$src")" || return 0
        ldst="$(mock_cfg_local "$name" "$dst")" || return 0
        mkdir -p "${ldst%/*}" 2>/dev/null || true
        mv -f "$lsrc" "$ldst" 2>/dev/null || true
        rm -f "$D/containers-$name.pending-mv"
    fi
}
cmd="$1"; shift
case "$cmd" in
    unshare)
        [[ "$1" == "--rootless-netns" ]] || { echo "mock: bad unshare" >&2; exit 2; }
        shift
        # ARC-71: dedicated wedge case — $D/netns-broken makes the probe
        # command fail the way the pasta EPERM does, while direct podman
        # container/network ops (not routed through unshare) still work.
        if [[ -f "$D/netns-broken" && "${1:-}" == "true" ]]; then
            echo "kill network process: permission denied" >&2
            exit 1
        fi
        # EGL-98: hard nft failure model — the netns answers the probe
        # (`true`) but nft list calls fail with a netlink error, the
        # "netns not answering" shape the stale-unpolicied predicate
        # must never fold into its skip path (R9). "No such file or
        # directory" is deliberately NOT used: that phrase is the
        # missing-chain answer the engine reads as "stale". The engine
        # passes the RESOLVED binary path (nft_bin), so match the
        # basename.
        if [[ -f "$D/netns-nft-fails" && "${1##*/}" == nft ]]; then
            echo "Error: Netlink error: Socket not connected" >&2
            exit 1
        fi
        exec "$@"
        ;;
    network)
        case "$1" in
            inspect)
                local_args=("$@"); name="${local_args[-1]}"
                f="$D/networks/$name"
                [[ -f "$f" ]] || { echo "Error: unable to find network" >&2; exit 1; }
                # EGL-362 P2: parse the state file once with bash builtins.
                # grep|cut emits every matching line's value (newline-
                # joined), so multi-line fields stay byte-identical.
                m_iface=""; m_driver=""; m_ipv6=""
                m_line=""
                m_gws=(); m_subs=()
                while IFS= read -r m_line || [[ -n "$m_line" ]]; do
                    case "$m_line" in
                        interface=*) m_iface+="${m_line#interface=}"$'\n' ;;
                        driver=*) m_driver+="${m_line#driver=}"$'\n' ;;
                        gateway=*) m_gws+=("${m_line#gateway=}") ;;
                        subnet=*) m_subs+=("${m_line#subnet=}") ;;
                        ipv6_enabled=*) m_ipv6+="${m_line#ipv6_enabled=}"$'\n' ;;
                    esac
                done < "$f"
                # command substitution strips ALL trailing newlines; an
                # empty last match (e.g. `interface=`) must not leave one.
                m_iface="${m_iface%"${m_iface##*[!$'\n']}"}"
                m_driver="${m_driver%"${m_driver##*[!$'\n']}"}"
                m_ipv6="${m_ipv6%"${m_ipv6##*[!$'\n']}"}"
                # EGL-141-D1: the bridge device token. interface= line
                # when present; hand-seeded state files (mocknet) are
                # deterministic as podman1 (the lowest slot, exactly
                # what a fresh one-network account gets). Churn tests
                # hand-edit interface= to pin re-resolution.
                mock_iface_of(){ echo "${m_iface:-podman1}"; }
                # local_args[0] is the `inspect` verb itself (the case
                # consumed `network`); the template pair follows it.
                if [[ "${local_args[1]:-}" == "--format" && "${local_args[2]:-}" == "{{.NetworkInterface}}" ]]; then
                    mock_iface_of
                    exit 0
                fi
                # Mimic real podman network inspect JSON (fields the
                # profile tool depends on). All subnet= lines become
                # subnet entries (real podman lists each).
                echo '['
                echo "     \"name\": \"$name\","
                echo "     \"network_interface\": \"$(mock_iface_of)\","
                echo "     \"driver\": \"$m_driver\","
                echo "     \"subnets\": ["
                # gateway= lines (in order) override the computed value so
                # gateway-mismatch scenarios are reproducible.
                first=1
                i=0
                for sub in "${m_subs[@]}"; do
                    gw="${m_gws[$i]:-${sub%0/24}1}"
                    [[ $first -eq 0 ]] && echo ","
                    first=0
                    echo "          {"
                    echo "               \"subnet\": \"$sub\","
                    echo "               \"gateway\": \"$gw\""
                    printf '          }'
                    i=$((i+1))
                done
                echo
                echo "     ],"
                echo "     \"ipv6_enabled\": $m_ipv6"
                echo "]"
                ;;
            create)
                local_args=("$@")
                name="${local_args[-1]}"
                [[ -f "$D/networks/$name" ]] && { echo "network exists" >&2; exit 1; }
                subnet="unknown"
                gateway=""
                prev=""
                for a in "${local_args[@]}"; do
                    [[ "$prev" == "--subnet" ]] && subnet="$a"
                    [[ "$prev" == "--gateway" ]] && gateway="$a"
                    prev="$a"
                done
                {
                    echo "driver=bridge"
                    echo "subnet=$subnet"
                    echo "gateway=${gateway:-${subnet%0/24}1}"
                    echo "ipv6_enabled=false"
                    # EGL-141-D1: lowest-free-slot default — the mock
                    # netns link list (lib.sh's mock `ip`) lists
                    # podman0..podman9, so a fresh account's first
                    # network lands on podman1 deterministically.
                    echo "interface=podman1"
                } > "$D/networks/$name"
                echo "$name"
                ;;
            ls)
                # network ls --format '{{.Name}}' (ARC-67-D2: real
                # podman's network ls field is .Name SINGULAR —
                # {{.Names}} is the podman ps container field and the
                # real binary errors on it; the mock must reject it
                # too, or a wrong template passes green while vacuous
                # on real hosts, which is exactly the ARC-67 bug).
                if [[ "${2:-}" == "--format" && "${3:-}" == "{{.Name}}" ]]; then
                    for f in "$D/networks"/*; do [[ -f "$f" ]] && echo "${f##*/}"; done
                    exit 0
                fi
                echo "mock podman: unsupported network ls" >&2
                exit 2
                ;;
            rm) [[ -f "$D/networks/$2" ]] || { echo "not found" >&2; exit 1; }
                # ARC-69: $D/network-rm-fails models a network with
                # attached containers (real podman refuses the rm).
                if [[ -f "$D/network-rm-fails" ]]; then
                    echo "Error: unable to remove network $2: network is being used" >&2
                    exit 1
                fi
                rm -f "$D/networks/$2"; echo "$2" ;;
        esac
        ;;
    run)
        echo "run $*" >> "$D/runlog"
        # EGL-91: mirror container starts into callorder.log so tests
        # can assert policy-vs-gateway ordering (grep-based consumers
        # of the other markers are unaffected by the extra line type).
        echo "podman run $*" >> "$D/callorder.log"
        # EGL-114: opslog mirror (rm/restart/run argv for the
        # converged-ensure pins; opslog has no other consumers).
        echo "podman run $*" >> "$D/opslog"
        # EGL-227 D10: a container-starting child (run/restart) must
        # never inherit fd 9 (the account lock) — rt_run/rt_restart
        # close it in the child. Record any leak; the egl227 section
        # asserts the marker absent.
        if [[ -e /proc/self/fd/9 ]]; then
            echo "container child inherited fd 9: $*" >> "$D/egl227-fd9-leak"
        fi
        name=""; net=""; ip=""; mac=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --name) name="$2"; shift 2 ;;
                --network) net="$2"; shift 2 ;;
                --network=*) net="${1#--network=}"; shift ;;
                --ip) ip="$2"; shift 2 ;;
                # EGL-123-D3: the gateway run carries the kit-derived
                # pinned MAC; store it in container state so inspect
                # can answer the MacAddress template (without this,
                # the MAC value would be left as the image name).
                --mac-address) mac="$2"; shift 2 ;;
                -*) shift ;;
                *) break ;;
            esac
        done
        # Model real IPAM: a static IP already held by another container
        # fails AFTER the name is registered (partial storage left
        # behind), which is what the on-host ARC-5 incident showed.
        if [[ -n "$ip" && -f "$D/ips/$ip" ]] \
           && [[ "$(cat "$D/ips/$ip")" != "$name" ]]; then
            : > "$D/containers/$name.net"
            echo "Error: IPAM error: requested ip address $ip is already allocated to another container" >&2
            exit 1
        fi
        # EGL-217: probe-fails arming — a container STARTED while the
        # probe-fails knob ($D/probe-fails[-<name>]) is armed gets the
        # live $D/probe-fails-active-<name> marker: the proxy never
        # answers from birth. Pre-existing containers keep answering
        # until the config-apply restart (the restart arm re-arms), which
        # is what lets a converged gateway short-circuit and still die in
        # gw_apply_allowlist's post-restart health wait.
        if [[ -f "$D/probe-fails-$name" || -f "$D/probe-fails" ]]; then
            : > "$D/probe-fails-active-$name"
        fi
        # EGL-217: run-registers-but-not-running knob ($D/run-sick[-<name>]):
        # model a container the runtime registered but that never reports
        # running (wedged start, ARC-5 partial storage) — the .net/ip/mac
        # state files are written (so `ps -a` still lists it and cleanup's
        # existence oracle sees it) but the `running/` marker is skipped,
        # so the engine's wait loops never see it running.
        # EGL-395: a new container gets a fresh bootstrap config dir and
        # its own instance identity; the shipped image config is what
        # PID 1 starts on until the first apply publishes squid.conf.
        # EGL-394 F1: real podman refuses a duplicate container name. A
        # failed removal of a still-running pre-existing gateway leaves
        # the name registered, so its replacement start fails here.
        if [[ -f "$D/name-in-use-$name" ]]; then
            echo "Error: creating container storage: the container name \"$name\" is already in use by another container" >&2
            exit 125
        fi
        mock_cfg_init "$name"
        if [[ -f "$D/run-sick-$name" || -f "$D/run-sick" ]]; then
            echo "$net" > "$D/containers/$name.net"
            [[ -n "$ip" ]] && { echo "$ip" > "$D/containers/$name.ip"; echo "$name" > "$D/ips/$ip"; }
            [[ -n "$mac" ]] && echo "$mac" > "$D/containers/$name.mac"
            echo "$name"
            exit 0
        fi
        : > "$D/running/$name"
        echo "$net" > "$D/containers/$name.net"
        [[ -n "$ip" ]] && { echo "$ip" > "$D/containers/$name.ip"; echo "$name" > "$D/ips/$ip"; }
        [[ -n "$mac" ]] && echo "$mac" > "$D/containers/$name.mac"
        echo "$name"
        ;;
    ps)
        # ps --format '{{.Names}}' lists RUNNING containers; ps -a
        # --format '{{.Names}}' (ARC-60 teardown --orphans sweep) also
        # lists stopped-but-registered ones (the *.net state files, which
        # is what survives a stopped/exited container in the real store).
        # EGL-389-D7: a failed container list (wedged runtime).
        # $D/ps-fails fails every call; $D/ps-fails-late arms
        # $D/ps-fails-active at the first host -> container staging copy,
        # so the ensure path before the apply is unaffected and only the
        # disclosure's observation and the cleanup probe fail.
        if [[ -f "$D/ps-fails-active" || -f "$D/ps-fails" ]]; then
            echo "Error: unable to connect to Podman: cannot invoke Podman API" >&2
            exit 125
        fi
        # EGL-602: opt-in call log, mirroring inspectlog-on. The bare
        # doctor leg asserts it stays empty, so "reads no container
        # list" is observed rather than inferred. The first argv token
        # is recorded so a default listing and `ps -a` stay
        # distinguishable.
        [[ -f "$D/pslog-on" ]] && echo "ps ${1:-}" >> "$D/pslog"
        declare -A ps_seen=()
        for f in "$D/running"/*; do
            [[ -f "$f" ]] || continue
            _ps_name="${f##*/}"
            ps_seen[$_ps_name]=1
            echo "$_ps_name"
        done
        if [[ "${1:-}" == "-a" ]]; then
            for f in "$D/containers"/*.net; do
                [[ -f "$f" ]] || continue
                n="${f##*/}"; n="${n%.net}"
                [[ -n "${ps_seen[$n]:-}" ]] && continue
                echo "$n"
            done
        fi
        ;;
    container)
        [[ "$1" == exists ]] && { [[ -f "$D/running/$2" || -f "$D/containers/$2" ]]; } ;;
    inspect)
        # inspect <name> [--format <tpl>]: support the container name and
        # the health/IP format strings egresslock uses.
        name="$1"; shift
        fmt=""
        if [[ "${1:-}" == "--format" ]]; then fmt="$2"; fi
        [[ -f "$D/containers/$name.net" || -f "$D/running/$name" ]] || { echo "Error: no such object" >&2; exit 1; }
        # EGL-415 rework: opt-in call-count oracle — the doctor must read
        # one inspect per running container, not three per-field calls.
        [[ -f "$D/inspectlog-on" ]] && echo "inspect $name" >> "$D/inspectlog"
        case "$fmt" in
            '{{.State.Health.Status}}')
                # Gateway health: healthy unless the test marks it sick.
                if [[ -f "$D/gateway-unhealthy" ]]; then echo "unhealthy"; else echo "healthy"; fi
                ;;
            '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')
                cat "$D/containers/$name.net" 2>/dev/null | head -1; echo ;;
            '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{println}}{{end}}')
                # EGL-415: one attachment name per line (multi-network
                # workloads need the whole set for the dual-homed row).
                cat "$D/containers/$name.net" 2>/dev/null || true ;;
            '{{.HostConfig.NetworkMode}}{{println}}{{range $k,$v := .NetworkSettings.Networks}}net|{{$k}}{{println}}{{end}}{{range .Mounts}}mount|{{.Type}}|{{.Source}}{{println}}{{end}}')
                # EGL-415: one combined read for the doctor's workload
                # row — network mode, attachment names, mount rows.
                # R-EGL-415-3 F2: a raw-bytes fixture expresses a record
                # the line-oriented .netmode/.net/.mounts files cannot —
                # e.g. a newline inside a mount source (the template
                # emits it unescaped, which is exactly the split the
                # parser must detect).
                if [[ -f "$D/containers/$name.inspect-raw" ]]; then
                    cat "$D/containers/$name.inspect-raw"
                    exit 0
                fi
                printf '%s\n' "$(cat "$D/containers/$name.netmode" 2>/dev/null || true)"
                if [[ -f "$D/containers/$name.net" ]]; then
                    while IFS= read -r n; do
                        [[ -n "$n" ]] && printf 'net|%s\n' "$n"
                    done < "$D/containers/$name.net"
                fi
                if [[ -f "$D/containers/$name.mounts" ]]; then
                    while IFS= read -r m; do
                        [[ -n "$m" ]] && printf 'mount|%s\n' "$m"
                    done < "$D/containers/$name.mounts"
                fi
                ;;
            '{{.HostConfig.NetworkMode}}')
                # EGL-415: host / container:<id> / a network name. The
                # .netmode fixture is optional (hand-seeded containers).
                cat "$D/containers/$name.netmode" 2>/dev/null || true ;;
            '{{range .Mounts}}{{.Type}}|{{.Source}}{{println}}{{end}}')
                # EGL-415: bind-mount sources for the policy-exposure
                # check; the fixture is one type|source per line.
                cat "$D/containers/$name.mounts" 2>/dev/null || true ;;
            '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}|{{$v.IPAddress}}|{{$v.MacAddress}}{{println}}{{end}}')
                # EGL-515 D3: verify_gateway's combined attachment/IP/MAC
                # read. One row for the container's class network.
                printf '%s|%s|%s\n' \
                    "$(head -1 "$D/containers/$name.net" 2>/dev/null)" \
                    "$(cat "$D/containers/$name.ip" 2>/dev/null || true)" \
                    "$(cat "$D/containers/$name.mac" 2>/dev/null || true)" ;;
            *'IPAddress}}'*)
                # Static-ip containers report their stored IP.
                if [[ -f "$D/containers/$name.ip" ]]; then
                    cat "$D/containers/$name.ip"
                else
                    echo ""
                fi
                ;;
            *'MacAddress}}'*)
                # EGL-123-D3: mirror the IPAddress template — a
                # --mac-address run stores the pinned MAC; containers
                # without one report empty (like the real per-network
                # field for an unset MAC).
                if [[ -f "$D/containers/$name.mac" ]]; then
                    cat "$D/containers/$name.mac"
                else
                    echo ""
                fi
                ;;
            '{{.Id}}')
                # EGL-395: instance identity for the activation witness.
                # A hand-seeded container (tests that only write the
                # running/net markers) still answers an identity.
                cat "$D/containers-$name.id" 2>/dev/null \
                    || printf 'mockid%s\n' "$(printf '%s' "$name" | sha256sum | cut -c1-56)"
                ;;
            '{{.Image}}')
                # EGL-547: the running container's image ID for the
                # doctor's tagged-vs-running comparison. No fixture means
                # an empty read (the doctor reports UNKNOWN, never clean).
                cat "$D/containers-$name.image" 2>/dev/null || true
                ;;
            '{{.State.StartedAt}}')
                # EGL-395: a real container always has an identity even
                # when a test hand-seeded only the running/net markers.
                # EGL-394 F2: a failed pre-signal StartedAt read must
                # disclose the unexpected warm-path restart.
                if [[ -f "$D/inspect-started-fails-$name" || -f "$D/inspect-started-fails" ]]; then
                    echo "Error: simulated inspect failure for $name" >&2
                    exit 1
                fi
                cat "$D/containers-$name.started" 2>/dev/null \
                    || echo '2026-01-01T00:00:00.000000000Z#1'
                ;;
            *)
                :
                ;;
        esac
        ;;
    exec)
        # exec <name> <cmd...>: used for squid config validation/reload.
        name="$1"; shift
        [[ -f "$D/containers/$name.net" || -f "$D/running/$name" ]] || { echo "no such container" >&2; exit 1; }
        # ARC-32-D1: record exec argv — separate file, because runlog
        # line counts are how existing tests assert "no new podman run".
        # EGL-515: the batched-probe script is multi-line; log a compact
        # one-line argv so execlog stays a per-exec log and the count
        # oracle stays exact.
        batch=0
        reload=0
        publish=0
        cleanup=0
        if [[ "${1:-}" == "bash" && "${2:-}" == "-c" && "${3:-}" == *"EGL-515 batch v1"* ]]; then
            batch=1
            echo "exec $name bash -c egl515-batch ${*:5}" >> "$D/execlog"
        elif [[ "${1:-}" == "bash" && "${2:-}" == "-c" && "${3:-}" == *"EGL-515 reload-read v1"* ]]; then
            reload=1
            echo "exec $name bash -c egl515-reload ${*:5}" >> "$D/execlog"
        elif [[ "${1:-}" == "bash" && "${2:-}" == "-c" && "${3:-}" == *"EGL-515 publish v1"* ]]; then
            publish=1
            echo "exec $name bash -c egl515-publish ${*:5}" >> "$D/execlog"
        elif [[ "${1:-}" == "bash" && "${2:-}" == "-c" && "${3:-}" == *"EGL-515 cleanup-read v2"* ]]; then
            cleanup=1
            echo "exec $name bash -c egl515-cleanup ${*:5}" >> "$D/execlog"
        else
            echo "exec $name $*" >> "$D/execlog"
        fi
        # EGL-283: model podman's own exec failure (container stopped or
        # mid-restart — e.g. a concurrent ensure) while the container
        # still lists as running, so the engine's earlier liveness check
        # passed. Podman rc 125 + the real container-state error.
        if [[ -f "$D/exec-fails-$name" || -f "$D/exec-fails" ]]; then
            echo "Error: can only create exec sessions on running containers: container state improper" >&2
            exit 125
        fi
        if (( reload == 1 )); then
            shift 4
            mock_reload_read "$name" "$@"
            exit $?
        fi
        if (( batch == 1 )); then
            shift 4
            mock_batch "$name" "$@"
            exit $?
        fi
        if (( publish == 1 )); then
            shift 4
            mock_publish "$name" "$@"
            exit $?
        fi
        if (( cleanup == 1 )); then
            shift 4
            mock_cleanup "$name" "$@"
            exit $?
        fi
        case "$1" in
            test)
                # EGL-369-D3/D7: gw_config_dir's layout probe. The current
                # image has both the new dir and the old-path symlink; an
                # old image has only /etc/squid/agent (the forced-probe
                # knob can make it answer the new dir to test fail-closed).
                # R-EGL-369-10 F1: the probe-fails knob models a runtime/
                # exec error (rc 125) — distinct from an absent dir (rc 1).
                if [[ "${2:-}" == -d ]]; then
                    if [[ -f "$D/gw-probe-fails-$name" || -f "$D/gw-probe-fails" ]]; then
                        echo "Error: can only create exec sessions on running containers: container state improper" >&2
                        exit 125
                    fi
                    # R-EGL-369-10 F1: one-shot "absent new dir" answer,
                    # consumed by the first probe of /etc/squid/egresslock.
                    # Models a transient probe disagreement between apply
                    # and a later independent re-probe.
                    if [[ "${3:-}" == /etc/squid/egresslock \
                          && -f "$D/gw-probe-old-once-$name" ]]; then
                        rm -f "$D/gw-probe-old-once-$name"
                        exit 1
                    fi
                    # R-EGL-369-13 F3: after the one-shot old answer is
                    # consumed, every later probe is a runtime error. With
                    # the apply layout bound through verify/cleanup there
                    # is no later probe; a re-probe fails closed, so the
                    # binding mutants cannot pass silently.
                    if [[ "${3:-}" == /etc/squid/egresslock \
                          && -f "$D/gw-probe-fail-after-old-once-$name" ]]; then
                        echo "Error: can only create exec sessions on running containers: container state improper" >&2
                        exit 125
                    fi
                    layout="$(mock_layout_probe "$name")"
                    mock_layout_has "$layout" "${3:-}" && exit 0
                    exit 1
                fi
                # EGL-395: `test [-e|-f|-L] [!] <path>` against the
                # modeled deployed tree (files and stage dirs).
                tneg=0; topt="${2:-}"; tpath="${3:-}"
                if [[ "$topt" == "!" ]]; then tneg=1; topt="${3:-}"; tpath="${4:-}"; fi
                if [[ "$topt" == "-e" && -f "$D/exec-test-e-fails-$name" ]] \
                    || [[ "$topt" == "-e" && -f "$D/exec-test-e-fails" ]] \
                    || [[ "$topt" == "-e" && -f "$D/exec-test-e-fails-witness" && "$tpath" == */.egresslock-activated ]] \
                    || [[ "$topt" == "-e" && -f "$D/exec-test-e-fails-stage" && "$tpath" == */.egresslock-stage.* ]] \
                    || [[ "$topt" == "-L" && -f "$D/exec-test-L-fails-$name" ]] \
                    || [[ "$topt" == "-L" && -f "$D/exec-test-L-fails-witness" && "$tpath" == */.egresslock-activated ]] \
                    || [[ "$topt" == "-L" && -f "$D/exec-test-L-fails-deployed" && "$tpath" == */squid.conf && "$tpath" != */.egresslock-stage.* ]]; then
                    echo "Error: can only create exec sessions on running containers: container state improper" >&2
                    exit 125
                fi
                # EGL-394: log-path existence (the cap's reopen proof).
                if [[ "${2:-}" =~ ^-(e|f)$ && ( "${3:-}" == /var/log/squid/access.log || "${3:-}" == /var/log/squid/cache.log ) ]]; then
                    case "${3:-}" in
                        /var/log/squid/access.log) f="$D/containers-$name.access.log" ;;
                        /var/log/squid/cache.log)  f="$D/containers-$name.cache.log" ;;
                    esac
                    if [[ "${2:-}" == "-e" ]]; then
                        [[ -e "$f" ]] && exit 0
                        exit 1
                    fi
                    [[ -f "$f" && ! -L "$f" ]] && exit 0
                    exit 1
                fi
                tstate=1
                case "$topt" in
                    -e|-f|-L)
                        lpath="$(mock_cfg_local "$name" "$tpath" 2>/dev/null)" || lpath=""
                        if [[ -n "$lpath" ]]; then
                            case "$topt" in
                                -e) [[ -e "$lpath" ]] && tstate=0 ;;
                                -f) [[ -f "$lpath" && ! -L "$lpath" ]] && tstate=0 ;;
                                -L) [[ -L "$lpath" ]] && tstate=0 ;;
                            esac
                        fi
                        ;;
                esac
                (( tneg == 1 )) && tstate=$(( tstate == 0 ? 1 : 0 ))
                exit "$tstate"
                ;;
            squid)
                # EGL-394: the engine signals the daemon by pid
                # (`bash -c 'kill -HUP 1'`), not `squid -k` — see the
                # bash case below. A `squid -k` client would need the
                # daemon's pidfile, which the shipped entrypoint's
                # daemonizing `squid -z` can delete after `-N` wrote it
                # (live finding R-EGL-394-2 F2).
                # Reject if the candidate config is marked bad.
                if [[ -f "$D/allowlist-invalid" ]]; then
                    echo "mock squid: config invalid" >&2
                    exit 1
                fi
                # EGL-389: a parse failure only for the DEPLOYED config
                # (verify_gateway), not the staged candidate — lets the
                # ensure's apply succeed and its final verify fail.
                if [[ -f "$D/deployed-config-invalid" && "$*" == *"/squid.conf"* \
                    && "$*" != *"/.egresslock-stage."* ]]; then
                    # EGL-389-D7 leg 9b: model the gateway stopping between
                    # the converged skip and the disclosure (the verify
                    # parse is the first exec after the skip).
                    if [[ -f "$D/gateway-stops-at-verify" ]]; then
                        rm -f "$D/gateway-stops-at-verify"
                        rm -f "$D/running/$name"
                    fi
                    # EGL-389-D7 leg 8b: the same late point models a
                    # container list that fails only at disclosure time.
                    if [[ -f "$D/ps-fails-at-verify" ]]; then
                        : > "$D/ps-fails-active"
                    fi
                    echo "mock squid: deployed config invalid" >&2
                    exit 1
                fi
                # EGL-394 F3: a same-name replacement or a deployed-config
                # drift at the final verification. Both leave the deployed
                # file parseable; only argv/hash binding catches them.
                if [[ "$*" == *"/squid.conf"* && "$*" != *"/.egresslock-stage."* ]]; then
                    if [[ -f "$D/deployed-replaced-at-verify-$name" ]]; then
                        rm -f "$D/deployed-replaced-at-verify-$name"
                        mock_bump_started "$name"
                        printf '/etc/squid/squid.conf\n' > "$D/containers-$name.argv"
                        printf 'bootstrap-old-acl\n' > "$D/containers-$name.live"
                    fi
                    if [[ -f "$D/deployed-config-drifts-at-verify-$name" ]]; then
                        rm -f "$D/deployed-config-drifts-at-verify-$name"
                        _df="$(mock_cfg_local "$name" "${!#}" 2>/dev/null)" || _df=""
                        [[ -n "$_df" && -f "$_df" ]] && printf '\n# concurrent drift\n' >> "$_df"
                    fi
                    # EGL-394 F1: the deployed config is swapped for an
                    # identical copy after the apply loaded it but before
                    # the final verification. The generation (bytes) is
                    # unchanged; only the stat identity shows the swap.
                    if [[ -f "$D/deployed-conf-restored-at-verify-$name" ]]; then
                        rm -f "$D/deployed-conf-restored-at-verify-$name"
                        mock_cfg_restored_after_load "$name"
                    fi
                fi
                exit 0
                ;;
            stat)
                # EGL-395: cleanup age reads (mtime epoch).
                if [[ "${2:-}" == "-c" && "${3:-}" == "%Y" ]]; then
                    lpath="$(mock_cfg_local "$name" "${4:-}" 2>/dev/null)" || lpath=""
                    if [[ -n "$lpath" && -e "$lpath" ]]; then
                        stat -c %Y "$lpath"
                        exit 0
                    fi
                    echo "stat: cannot stat '${4:-}': No such file or directory" >&2
                    exit 1
                fi
                # EGL-394 F1: the deployed config's stat identity
                # (device/inode, size, ctime). The mock's mounted tree is
                # a host directory, so the host file's identity models
                # the container view exactly.
                if [[ "${2:-}" == "-c" && "${3:-}" == "%d:%i %s %z" ]]; then
                    # EGL-394: a failed identity read after a confirmed
                    # publication dies committed+owned (the running
                    # gateway was not activated).
                    if [[ -f "$D/conf-ident-fails-$name" || -f "$D/conf-ident-fails" ]]; then
                        echo "stat: cannot stat '${4:-}': simulated failure" >&2
                        exit 1
                    fi
                    lpath="$(mock_cfg_local "$name" "${4:-}" 2>/dev/null)" || lpath=""
                    if [[ -n "$lpath" && -f "$lpath" ]]; then
                        stat -c '%d:%i %s %z' "$lpath"
                        exit 0
                    fi
                    echo "stat: cannot stat '${4:-}': No such file or directory" >&2
                    exit 1
                fi
                # ARC-32-D1: gw_log_cap sizes the overlay logs. Report
                # the byte size of the mocked log fixture file. ($1 is
                # the command word 'stat' after the name shift.)
                if [[ "${2:-}" == "-c" && "${3:-}" == "%s" ]]; then
                    case "$4" in
                        /var/log/squid/access.log) f="$D/containers-$name.access.log" ;;
                        /var/log/squid/cache.log)  f="$D/containers-$name.cache.log" ;;
                        *) f="" ;;
                    esac
                    if [[ -n "$f" && -f "$f" ]]; then
                        wc -c < "$f"
                        exit 0
                    fi
                    echo "stat: cannot stat '${4:-}': No such file or directory" >&2
                    exit 1
                fi
                # EGL-394: reload proof binds the cache log stream to its
                # device:inode and size; log cap binds the reopen to a
                # changed inode.
                case "$4" in
                    /var/log/squid/access.log) f="$D/containers-$name.access.log" ;;
                    /var/log/squid/cache.log)  f="$D/containers-$name.cache.log" ;;
                    *) f="" ;;
                esac
                if [[ "${2:-}" == "-c" && "${3:-}" == "%d:%i" && -n "$f" && -f "$f" ]]; then
                    stat -c %d:%i "$f"
                    exit 0
                fi
                if [[ "${2:-}" == "-c" && "${3:-}" == "%d:%i %s" && -n "$f" && -f "$f" ]]; then
                    # EGL-394 F2: a failed pre-signal cache-log stat must
                    # disclose the unexpected warm-path restart.
                    if [[ -f "$D/reload-stat-fails-$name" || -f "$D/reload-stat-fails" ]]; then
                        echo "stat: cannot stat '$4': simulated failure" >&2
                        exit 1
                    fi
                    # EGL-394 F2: second post-signal observation of the
                    # shrink-then-regrow seam: the stream regrows past the
                    # original offset with a matching witness.
                    if [[ "$f" == "$D/containers-$name.cache.log" \
                          && -f "$D/reload-log-shrink-regrow-pending-$name" ]]; then
                        _sr_n=0
                        [[ -f "$D/reload-log-shrink-regrow-pending-$name.n" ]] \
                            && read -r _sr_n < "$D/reload-log-shrink-regrow-pending-$name.n"
                        _sr_n=$(( _sr_n + 1 ))
                        printf '%s\n' "$_sr_n" > "$D/reload-log-shrink-regrow-pending-$name.n"
                        if (( _sr_n >= 2 )); then
                            rm -f "$D/reload-log-shrink-regrow-pending-$name" \
                                  "$D/reload-log-shrink-regrow-pending-$name.n"
                            : > "$f"
                            printf '%05000d' 0 >> "$f"
                            {
                                printf 'Reconfiguring Squid Cache (version 6.13)...\n'
                                printf 'Processing Configuration File: %s/squid.conf (depth 0)\n' "$(mock_cfg_abs "$name")"
                            } >> "$f"
                            mock_cfg_load_live "$name"
                        fi
                    fi
                    printf '%s %s\n' "$(stat -c %d:%i "$f")" "$(wc -c < "$f")"
                    exit 0
                fi
                echo "mock podman: unsupported stat $*" >&2
                exit 2
                ;;
            tail)
                # EGL-252: cmd_denied tail-reads the newest log bytes
                # when access.log exceeds the read cap (tail -c <N>).
                # EGL-394: the reload witness scan reads cache.log from
                # a recorded offset (tail -c +<N>).
                if [[ "${2:-}" == "-c" && "${4:-}" == /var/log/squid/access.log ]]; then
                    f="$D/containers-$name.access.log"
                    if [[ -f "$f" ]]; then tail -c "$3" "$f"; exit 0; fi
                    echo "tail: cannot open '$4' for reading: No such file or directory" >&2
                    exit 1
                fi
                if [[ "${2:-}" == "-c" && "${4:-}" == /var/log/squid/cache.log \
                      && "${3:-}" == +* ]]; then
                    f="$D/containers-$name.cache.log"
                    if [[ -f "$f" ]]; then
                        tail -c "$3" "$f"
                        # EGL-394 H2: swap the stream AFTER the witness
                        # bytes are read. The post-tail stat must see the
                        # new inode and reject the poll; without that
                        # re-assertion the witness would be accepted.
                        if [[ -f "$D/reload-log-replaced-at-tail-once-$name" ]]; then
                            rm -f "$D/reload-log-replaced-at-tail-once-$name"
                            _tp="$f.at-tail"
                            cp "$f" "$_tp"
                            mv -f "$_tp" "$f"
                        fi
                        exit 0
                    fi
                    echo "tail: cannot open '$4' for reading: No such file or directory" >&2
                    exit 1
                fi
                echo "mock podman: unsupported tail $*" >&2
                exit 2
                ;;
            mv)
                # ARC-32-D1: simulate mv inside the gateway's log dir so
                # the rotated .1 generation is observable in the mock
                # state. EGL-389: model the config-dir swap/moves too
                # (check.conf -> squid.conf and the rollback's file
                # moves); $D/mv-check-fails exercises the swap die.
                if [[ "${2:-}" == /var/log/squid/* && "${3:-}" == /var/log/squid/* ]]; then
                    s="$D/containers-$name.${2##*/}"; d="$D/containers-$name.${3##*/}"
                    # EGL-540: model a failed cache move after access
                    # already moved aside — the engine's restore-then-
                    # disclose site (`:7229`). The source stays in place.
                    if [[ "${2##*/}" == cache.log && -f "$D/rotate-move-cache-fails-$name" ]]; then
                        echo "mv: cannot move '$2' to '$3': Device or resource busy" >&2
                        exit 1
                    fi
                    # R-EGL-394-16 F1 mutation control: the pre-fix
                    # restore was a clobbering `mv`. Model the same
                    # reopen-at-restore race here so a reintroduced
                    # check-then-mv loses the fresh record, not just the
                    # primitive-shape assertion in the fixed legs.
                    case "${3##*/}" in
                        access.log)
                            if [[ -f "$D/rotate-reopen-before-restore-access-$name" ]]; then
                                rm -f "$D/rotate-reopen-before-restore-access-$name"
                                printf 'fresh-access-record\n' > "$d"
                            fi
                            ;;
                        cache.log)
                            if [[ -f "$D/rotate-reopen-before-restore-cache-$name" ]]; then
                                rm -f "$D/rotate-reopen-before-restore-cache-$name"
                                printf 'fresh-cache-record\n' > "$d"
                            fi
                            ;;
                    esac
                    if [[ -f "$s" ]]; then
                        # EGL-540: propagate the real rc. A same-inode
                        # refusal (the bug's precondition: live and `.1`
                        # are hard links to one inode) must reach the
                        # engine's skip branch instead of reading as a
                        # successful move.
                        mv "$s" "$d"
                        exit $?
                    fi
                    echo "mv: cannot stat '$2': No such file or directory" >&2
                    exit 1
                fi
                if [[ "${2:-}" == "-T" && "${3:-}" == /etc/squid/* && "${4:-}" == /etc/squid/* ]]; then
                    mock_mv_T "$name" "${3:-}" "${4:-}"
                    exit $?
                fi
                exit 0
                ;;
            rm)
                # ARC-32-D1: simulate rm of the rotated .1 generation;
                # EGL-389/EGL-395: config-path rm (rollback removal,
                # cleanup, stage sweep) removes the modeled path.
                if [[ "${2:-}" == -f && "${3:-}" == /var/log/squid/* ]]; then
                    # EGL-540: model a failed unlink after the restore's
                    # no-clobber link succeeded (live and `.1` then share
                    # one inode). This is the log-path rm the restore and
                    # the repair run; the cap's generation cleanup is the
                    # separate `bash -c` case above.
                    if [[ -f "$D/restore-rm-fails-$name" || -f "$D/restore-rm-fails" ]]; then
                        echo "rm: cannot remove '${3:-}': Operation not permitted" >&2
                        exit 1
                    fi
                    rm -f "$D/containers-$name.${3##*/}"
                fi
                if [[ "${2:-}" == -f || "${2:-}" == -rf ]]; then
                    shift 2
                    [[ "${1:-}" == "--" ]] && shift
                    for rpath in "$@"; do
                        if [[ "$rpath" == /etc/squid/agent/* || "$rpath" == /etc/squid/egresslock/* ]]; then
                            if [[ "$rpath" == *"/.egresslock-stage."* ]]; then
                                if [[ -f "$D/rm-stage-fails" ]]; then
                                    echo "Error: simulated stage sweep failure" >&2
                                    exit 1
                                fi
                                mock_perform_pending_mv "$name" "$rpath"
                            elif [[ -f "$D/rm-config-fails-${rpath##*/}" ]]; then
                                echo "rm: cannot remove '$rpath': simulated config removal failure" >&2
                                exit 1
                            elif [[ -f "$D/cleanup-rm-enospc" ]]; then
                                echo "rm: cannot remove '$rpath': No space left on device" >&2
                                exit 1
                            elif [[ -f "$D/cleanup-rm-fails" ]]; then
                                echo "rm: cannot remove '$rpath': simulated cleanup failure" >&2
                                exit 1
                            fi
                            lpath="$(mock_cfg_local "$name" "$rpath" 2>/dev/null)" || lpath=""
                            if [[ -n "$lpath" ]]; then
                                if [[ -d "$lpath" && ! -L "$lpath" ]]; then
                                    rm -rf "$lpath"
                                else
                                    rm -f "$lpath"
                                fi
                            fi
                        fi
                    done
                fi
                exit 0
                ;;
            cat)
                # EGL-395: PID 1's argv as NUL-separated tokens. The
                # default is the shipped entrypoint shape for the
                # container's current deployed config (bootstrap before
                # the first publication). Knob $D/argv-bad[-<name>]
                # models an unconfirmed/wrong process argv.
                if [[ "${2:-}" == /proc/1/cmdline ]]; then
                    if [[ -f "$D/argv-bad-$name" || -f "$D/argv-bad" ]]; then
                        printf 'squid\0-N\0-f\0/etc/squid/squid.conf\0-d\00\0'
                    elif [[ -f "$D/containers-$name.argv" ]]; then
                        printf 'squid\0-N\0-f\0%s\0-d\00\0' "$(cat "$D/containers-$name.argv")"
                    elif [[ -f "$D/containers-$name.cfg/squid.conf" ]]; then
                        printf 'squid\0-N\0-f\0%s/squid.conf\0-d\00\0' "$(mock_cfg_abs "$name")"
                    else
                        printf 'squid\0-N\0-f\0/etc/squid/squid.conf\0-d\00\0'
                    fi
                    exit 0
                fi
                # EGL-206-D2b: the live-hardening oracle reads PID 1's
                # /proc/1/status inside the container. Default fixture is
                # healthy (CapEff all-zero, NoNewPrivs 1 — exactly what
                # --cap-drop=all --security-opt=no-new-privileges
                # produces). Named knobs, per-container marker first then
                # the global one: caps-bad (non-zero CapEff), caps-nnp
                # (NoNewPrivs 0), caps-unreadable (exec fails — the
                # fail-closed path). Per-container form: caps-<knob>-<name>.
                if [[ "${2:-}" == /proc/1/status ]]; then
                    if ! pair="$(mock_caps_pair "$name")"; then
                        echo "cat: /proc/1/status: No such file or directory" >&2
                        exit 1
                    fi
                    read -r capseff nnp <<<"$pair" || true
                    printf 'CapEff:\t%s\n' "$capseff"
                    printf 'NoNewPrivs:\t%s\n' "$nnp"
                    exit 0
                fi
                # ARC-7: cmd_denied reads the gateway's access log.
                if [[ "${2:-}" == /var/log/squid/access.log ]]; then
                    cat "$D/containers-$name.access.log" 2>/dev/null || true
                    exit 0
                fi
                # EGL-114: the converged-ensure compare reads DEPLOYED
                # files back from the gateway. The mock models the
                # container FS with the files podman cp staged (stored
                # by src basename); a missing file fails like a real
                # missing path (a missing live file is a DIFFER, never a
                # skip). EGL-369-D7: both layouts are modeled — the old
                # path resolves through the symlink on a new image, while
                # an old image has no new path.
                if [[ "${2:-}" == /etc/squid/agent/* || "${2:-}" == /etc/squid/egresslock/* ]]; then
                    # EGL-515: cleanup reads the deployed config once and
                    # hashes it on the host; this seam makes that read
                    # fail (the old cleanup-sha-fails seam).
                    if [[ -f "$D/cleanup-sha-fails" && "${2:-}" == */squid.conf \
                        && "${2:-}" != *"/.egresslock-stage."* ]]; then
                        echo "cat: ${2}: Input/output error" >&2
                        exit 1
                    fi
                    f="$(mock_cfg_local "$name" "$2" 2>/dev/null)" || f=""
                    if [[ -n "$f" && -f "$f" ]]; then
                        cat "$f"
                        exit 0
                    fi
                    echo "cat: ${2}: No such file or directory" >&2
                    exit 1
                fi
                exit 0
                ;;
            mktemp)
                # EGL-395: private in-container stage. Only the engine's
                # .egresslock-stage template is supported; the returned
                # path is inside the detected cfgdir.
                if [[ "${2:-}" == -d && "${3:-}" == /etc/squid/agent/.egresslock-stage.XXXXXX \
                    || "${2:-}" == -d && "${3:-}" == /etc/squid/egresslock/.egresslock-stage.XXXXXX ]]; then
                    absdir="${3%/*}"
                    ldir="$(mock_cfg_local "$name" "$absdir/.x" 2>/dev/null)" || ldir=""
                    if [[ -z "$ldir" ]]; then
                        echo "mktemp: failed to create directory via template '${3}': No such file or directory" >&2
                        exit 1
                    fi
                    ldir="${ldir%/.x}"
                    stageme=".egresslock-stage.$$$RANDOM"
                    mkdir -p "$ldir/$stageme"
                    printf '%s/%s\n' "$absdir" "$stageme"
                    exit 0
                fi
                echo "mock podman: unsupported mktemp $*" >&2
                exit 2
                ;;
            ln)
                # EGL-395: no-clobber hard-link publication. `ln -T` is
                # required (a plain ln into an existing directory is a
                # false success); an existing destination (including a
                # dangling symlink) fails with EEXIST.
                if [[ "${2:-}" != -T || -z "${3:-}" || -z "${4:-}" ]]; then
                    echo "mock podman: unsupported ln $*" >&2
                    exit 2
                fi
                # R-EGL-394-16 F1: the cap restores a moved stdio log
                # with an atomic no-clobber link. Model Squid's async
                # rotation reopening the live path at the instant of the
                # link: the seam creates that path (with a fresh record)
                # immediately before the link attempt, so a clobbering
                # restore would lose the record while `ln -T` fails EEXIST
                # and leaves the moved generation.
                if [[ "${3:-}" == /var/log/squid/* && "${4:-}" == /var/log/squid/* ]]; then
                    lsrc="$D/containers-$name.${3##*/}"
                    ldst="$D/containers-$name.${4##*/}"
                    case "${4##*/}" in
                        access.log)
                            if [[ -f "$D/rotate-reopen-before-restore-access-$name" ]]; then
                                rm -f "$D/rotate-reopen-before-restore-access-$name"
                                printf 'fresh-access-record\n' > "$ldst"
                            fi
                            ;;
                        cache.log)
                            if [[ -f "$D/rotate-reopen-before-restore-cache-$name" ]]; then
                                rm -f "$D/rotate-reopen-before-restore-cache-$name"
                                printf 'fresh-cache-record\n' > "$ldst"
                            fi
                            ;;
                    esac
                    if [[ -e "$ldst" || -L "$ldst" ]]; then
                        echo "ln: failed to create hard link '${4}': File exists" >&2
                        exit 1
                    fi
                    [[ -f "$lsrc" ]] || { echo "ln: failed to access '${3}': No such file or directory" >&2; exit 1; }
                    ln -T -- "$lsrc" "$ldst" || { echo "ln: failed to create hard link '${4}'" >&2; exit 1; }
                    exit 0
                fi
                lsrc="$(mock_cfg_local "$name" "$3" 2>/dev/null)" || lsrc=""
                ldst="$(mock_cfg_local "$name" "$4" 2>/dev/null)" || ldst=""
                [[ -n "$ldst" ]] || { echo "ln: failed to create hard link '${4}': No such file or directory" >&2; exit 1; }
                if [[ -e "$ldst" || -L "$ldst" ]]; then
                    echo "ln: failed to create hard link '${4}': File exists" >&2
                    exit 1
                fi
                [[ -n "$lsrc" && -f "$lsrc" ]] || { echo "ln: failed to access '${3}': No such file or directory" >&2; exit 1; }
                ln -T -- "$lsrc" "$ldst" || { echo "ln: failed to create hard link '${4}'" >&2; exit 1; }
                exit 0
                ;;
            sha256sum)
                # EGL-395 cleanup seam: fail the deployed-config hash read
                # only (never a staged candidate), so cleanup sees an
                # unreadable reference set.
                if [[ -f "$D/cleanup-sha-fails" && "${2:-}" == */squid.conf \
                    && "${2:-}" != *"/.egresslock-stage."* ]]; then
                    echo "sha256sum: ${2:-}: Input/output error" >&2
                    exit 1
                fi
                # EGL-395 publication-resolution seam: a lost rename
                # result leaves the deployed read failing. Only the
                # deployed squid.conf is affected.
                if [[ -f "$D/read-fails-$name" && "${2:-}" == */squid.conf \
                    && "${2:-}" != *"/.egresslock-stage."* ]]; then
                    echo "sha256sum: ${2:-}: Input/output error" >&2
                    exit 1
                fi
                lpath="$(mock_cfg_local "$name" "${2:-}" 2>/dev/null)" || lpath=""
                if [[ -n "$lpath" && -f "$lpath" ]]; then
                    sha256sum "$lpath" | sed "s|  $lpath$|  ${2}|"
                    exit 0
                fi
                echo "sha256sum: ${2:-}: No such file or directory" >&2
                exit 1
                ;;
            find)
                # EGL-395 cleanup enumeration: find <cfgdir> -maxdepth 1
                # -mindepth 1 -type f|d|l -printf '%f\n'.
                # EGL-394: find-fails models an unreadable config
                # directory during cleanup (the apply itself never runs
                # find, so this only exercises the cleanup skip).
                if [[ -f "$D/find-fails-$name" || -f "$D/find-fails" ]]; then
                    echo "find: ${2:-}: Input/output error" >&2
                    exit 1
                fi
                if [[ "${2:-}" == /etc/squid/agent* || "${2:-}" == /etc/squid/egresslock* ]] \
                    && [[ "$*" == *"-maxdepth 1"* && "$*" == *"-mindepth 1"* ]] \
                    && [[ "$*" == *"-printf %f\\n"* || "$*" == *"-printf %y %T@ %f\\n"* ]]; then
                    ldir="$(mock_cfg_local "$name" "${2%/}" 2>/dev/null)" || ldir=""
                    if [[ -z "$ldir" ]]; then
                        echo "find: '${2}': No such file or directory" >&2
                        exit 1
                    fi
                    # Real find includes dotfiles; the stage dirs and
                    # the witness are dot-named, so glob with explicit
                    # dot patterns instead of relying on * alone.
                    shopt -s dotglob nullglob
                    _found=("$ldir"/*)
                    shopt -u dotglob nullglob
                    # EGL-515: one listing for type + mtime + name.
                    if [[ "$*" == *"-printf %y %T@ %f\\n"* ]]; then
                        for f in "${_found[@]}"; do
                            _typ=o
                            [[ -L "$f" ]] && _typ=l
                            [[ -f "$f" && ! -L "$f" ]] && _typ=f
                            [[ -d "$f" && ! -L "$f" ]] && _typ=d
                            printf '%s %s %s\n' "$_typ" "$(stat -c %Y "$f")" "${f##*/}"
                        done
                        exit 0
                    fi
                    if [[ "$*" == *"-type f"* ]]; then
                        for f in "${_found[@]}"; do [[ -f "$f" && ! -L "$f" ]] && echo "${f##*/}"; done
                        exit 0
                    elif [[ "$*" == *"-type d"* ]]; then
                        for f in "${_found[@]}"; do [[ -d "$f" && ! -L "$f" ]] && echo "${f##*/}"; done
                        exit 0
                    elif [[ "$*" == *"-type l"* ]]; then
                        for f in "${_found[@]}"; do [[ -L "$f" ]] && echo "${f##*/}"; done
                        exit 0
                    fi
                fi
                echo "mock podman: unsupported find $*" >&2
                exit 2
                ;;
            bash)
                # EGL-395: argv proof — `bash -c 'exec tr "\0" "\n" <
                # /proc/1/cmdline'` returns the NUL-separated tokens as
                # one token per line.
                if [[ "${2:-}" == "-c" && "${3:-}" == *"/proc/1/cmdline"* ]]; then
                    if [[ -f "$D/argv-bad-$name" || -f "$D/argv-bad" ]]; then
                        printf 'squid\n-N\n-f\n/etc/squid/squid.conf\n-d\n0\n'
                    elif [[ -f "$D/containers-$name.argv" ]]; then
                        printf 'squid\n-N\n-f\n%s\n-d\n0\n' "$(cat "$D/containers-$name.argv")"
                    elif [[ -f "$D/containers-$name.cfg/squid.conf" ]]; then
                        printf 'squid\n-N\n-f\n%s/squid.conf\n-d\n0\n' "$(mock_cfg_abs "$name")"
                    else
                        printf 'squid\n-N\n-f\n/etc/squid/squid.conf\n-d\n0\n'
                    fi
                    exit 0
                fi
                # EGL-394: the reload proof hashes a fixed prefix of the
                # cache log to bind later polls to the same stream.
                # R-EGL-394-13 F1: the engine runs the pipeline under
                # `set -o pipefail`, so a failing `head` fails the exec
                # even though `sha256sum` still writes a digest of its
                # (empty/partial) input. The mock models that result: the
                # `reload-prefix-head-fails` seam emits the empty-input
                # digest and exits 1 when pipefail is present; without
                # pipefail (pre-fix engine) the same pipeline exits 0,
                # which is exactly the false proof the pin must catch.
                if [[ "${2:-}" == "-c" && "${3:-}" =~ ^(set\ -o\ pipefail\;\ )?head\ -c\ \'([0-9]+)\'\ \'/var/log/squid/cache\.log\'\ \|\ sha256sum$ ]]; then
                    f="$D/containers-$name.cache.log"
                    if [[ -f "$f" ]]; then
                        # EGL-394 F2: a failed pre-signal prefix read must
                        # disclose the unexpected warm-path restart.
                        if [[ -f "$D/reload-prefix-fails-$name" || -f "$D/reload-prefix-fails" ]]; then
                            echo "head: cannot open /var/log/squid/cache.log (simulated failure)" >&2
                            exit 1
                        fi
                        # R-EGL-394-13 F1: only `head` fails; sha256sum
                        # still writes the empty-input digest.
                        if [[ -f "$D/reload-prefix-head-fails-$name" || -f "$D/reload-prefix-head-fails" ]]; then
                            printf '%s  -\n' "$(printf '' | sha256sum | cut -d' ' -f1)"
                            if [[ "${3:-}" == *"set -o pipefail"* ]]; then
                                exit 1
                            fi
                            exit 0
                        fi
                        head -c "${BASH_REMATCH[2]}" "$f" | sha256sum
                        exit 0
                    fi
                    echo "head: cannot open /var/log/squid/cache.log" >&2
                    exit 1
                fi
                # EGL-394: gw_log_cap drops every numbered generation
                # after a confirmed reopen (both stdio logs).
                if [[ "${2:-}" == "-c" && "${3:-}" == 'rm -f /var/log/squid/access.log.[0-9]* /var/log/squid/cache.log.[0-9]*' ]]; then
                    rm -f "$D/containers-$name.access.log".[0-9]* \
                          "$D/containers-$name.cache.log".[0-9]* 2>/dev/null || true
                    exit 0
                fi
                # EGL-394: the engine's activation signal. The gateway
                # daemon is PID 1, so the engine runs
                # `bash -c 'kill -HUP 1'` (reload) / `kill -USR1 1`
                # (rotate). A real SIGHUP re-reads the daemon's startup
                # ConfigFile and writes its witness to cache.log.
                # Knobs: reload-signal-fails (rc 1), reload-silent
                # (rc 0, no witness), reload-fatal (the container exits,
                # as a fatal parse does), reload-probe-fails (the
                # listener never reopens until a restart), rotate-fails.
                if [[ "${2:-}" == "-c" && "${3:-}" == "kill -USR1 1" ]]; then
                    # ARC-32-D1: a rotate reopens the stdio logs. EGL-394
                    # models Squid 6.13 `logfile_rotate 10` and the real
                    # rename order: shift `.0`..`.9` up by one, move the
                    # live file to `.0`, then create a fresh live file —
                    # for BOTH access.log and cache.log. The rotate-fails
                    # marker exercises the engine's restore path (fail
                    # open for the log, never for policy).
                    if [[ -f "$D/rotate-fails" ]]; then
                        echo "mock squid: rotate failed" >&2
                        exit 1
                    fi
                    # EGL-394 F3: the signal fails after one stdio log
                    # already reopened. The engine's restore must be
                    # gated on the live path being absent, or it would
                    # move the retained `.1` generation over the
                    # daemon's new fd.
                    if [[ -f "$D/rotate-fails-after-reopen-$name" ]]; then
                        rm -f "$D/rotate-fails-after-reopen-$name"
                        : > "$D/containers-$name.access.log"
                        echo "mock squid: rotate failed after reopening access.log" >&2
                        exit 1
                    fi
                    # R-EGL-394-13 F2: the signal is delivered but the
                    # daemon reopens only access.log (the sibling rename
                    # sequence stalls). The timeout branch must restore
                    # only the path that is PROVEN absent.
                    if [[ -f "$D/rotate-partial-reopen-$name" ]]; then
                        rm -f "$D/rotate-partial-reopen-$name"
                        : > "$D/containers-$name.access.log"
                        exit 0
                    fi
                    # R-EGL-394-13 F2: signal delivered, no stdio log
                    # reopened at all (the daemon is wedged in rotation).
                    if [[ -f "$D/rotate-no-reopen-$name" ]]; then
                        rm -f "$D/rotate-no-reopen-$name"
                        exit 0
                    fi
                    _rot() {
                        local _b="$D/containers-$name.$1.log" _i
                        for ((_i = 9; _i >= 0; _i--)); do
                            [[ -e "$_b.$_i" ]] && mv -f "$_b.$_i" "$_b.$((_i + 1))"
                        done
                        [[ -e "$_b" ]] && mv -f "$_b" "$_b.0"
                        : > "$_b"
                    }
                    if [[ -f "$D/rotate-stagger" ]]; then
                        # Squid may rotate one stdio log after the other;
                        # the exec returns after access.log and cache.log
                        # follows asynchronously. The cap must wait for
                        # both reopens before deleting generations (F4).
                        _rot access
                        ( sleep 0.4; _rot cache ) &
                        exit 0
                    fi
                    for _l in access cache; do
                        _rot "$_l"
                    done
                    exit 0
                fi
                if [[ "${2:-}" == "-c" && "${3:-}" == "kill -HUP 1" ]]; then
                    if [[ -f "$D/reload-signal-fails-$name" || -f "$D/reload-signal-fails" ]]; then
                        echo "mock squid: reconfigure signal failed" >&2
                        exit 1
                    fi
                    if [[ -f "$D/reload-fatal-$name" || -f "$D/reload-fatal" ]]; then
                        rm -f "$D/running/$name"
                        echo "mock squid: fatal parse error" >&2
                        exit 1
                    fi
                    if [[ -f "$D/reload-silent-$name" || -f "$D/reload-silent" ]]; then
                        exit 0
                    fi
                    # EGL-394 F2: a log that shrinks during the reload is
                    # terminal for the attempt (never a later regrown
                    # stream). `shrink` leaves the live path short;
                    # `regrow` truncates and rewrites it in place so the
                    # original offset is valid again but the stream is
                    # different; `replaced` swaps in a new inode whose
                    # bytes contain a matching witness (the old size-only
                    # proof would bless it).
                    if [[ -f "$D/reload-log-shrink-once-$name" ]]; then
                        rm -f "$D/reload-log-shrink-once-$name"
                        : > "$D/containers-$name.cache.log"
                        printf 'x' >> "$D/containers-$name.cache.log"
                        mock_cfg_load_live "$name"
                        exit 0
                    fi
                    # EGL-394 F2 mutation seam: the first post-signal stat
                    # sees the shrink; a LATER poll sees the stream regrown
                    # past the original offset with a matching witness. The
                    # shrink must be terminal, so the later stream is never
                    # accepted as this apply's reload.
                    if [[ -f "$D/reload-log-shrink-regrow-once-$name" ]]; then
                        rm -f "$D/reload-log-shrink-regrow-once-$name"
                        : > "$D/containers-$name.cache.log"
                        printf 'x' >> "$D/containers-$name.cache.log"
                        rm -f "$D/reload-log-shrink-regrow-pending-$name".n
                        : > "$D/reload-log-shrink-regrow-pending-$name"
                        mock_cfg_load_live "$name"
                        exit 0
                    fi
                    if [[ -f "$D/reload-log-regrow-once-$name" ]]; then
                        rm -f "$D/reload-log-regrow-once-$name"
                        : > "$D/containers-$name.cache.log"
                        printf '%05000d' 0 >> "$D/containers-$name.cache.log"
                        {
                            printf 'Reconfiguring Squid Cache (version 6.13)...\n'
                            printf 'Processing Configuration File: %s/squid.conf (depth 0)\n' "$(mock_cfg_abs "$name")"
                        } >> "$D/containers-$name.cache.log"
                        mock_cfg_load_live "$name"
                        exit 0
                    fi
                    if [[ -f "$D/reload-log-replaced-once-$name" ]]; then
                        rm -f "$D/reload-log-replaced-once-$name"
                        # Allocate the replacement BEFORE unlinking the
                        # old file, so the new stream cannot reuse the
                        # old inode (the identity binding must be real).
                        _rp="$D/containers-$name.cache.log.new"
                        printf '%05000d' 0 > "$_rp"
                        {
                            printf 'Reconfiguring Squid Cache (version 6.13)...\n'
                            printf 'Processing Configuration File: %s/squid.conf (depth 0)\n' "$(mock_cfg_abs "$name")"
                        } >> "$_rp"
                        mv -f "$_rp" "$D/containers-$name.cache.log"
                        mock_cfg_load_live "$name"
                        exit 0
                    fi
                    # EGL-394 F3: the same-name instance is replaced at
                    # the signal boundary by a healthy bootstrap-argv
                    # gateway; the deployed candidate stays parseable.
                    # The engine must not call that activation.
                    if [[ -f "$D/reload-replaced-during-$name" ]]; then
                        rm -f "$D/reload-replaced-during-$name"
                        mock_bump_started "$name"
                        printf '/etc/squid/squid.conf\n' > "$D/containers-$name.argv"
                        printf 'bootstrap-old-acl\n' > "$D/containers-$name.live"
                        exit 0
                    fi
                    cfgabs="$(mock_cfg_abs "$name")"
                    {
                        printf 'Reconfiguring Squid Cache (version 6.13)...\n'
                        printf 'Processing Configuration File: %s/squid.conf (depth 0)\n' "$cfgabs"
                    } >> "$D/containers-$name.cache.log"
                    mock_cfg_load_live "$name"
                    # EGL-394 F1: the deployed config is swapped for an
                    # identical copy after Squid loaded it. The reload
                    # witness is real; only the stat-identity chain can
                    # refuse the claim that these bytes came from the
                    # published file.
                    if [[ -f "$D/conf-restored-after-reload-$name" ]]; then
                        rm -f "$D/conf-restored-after-reload-$name"
                        mock_cfg_restored_after_load "$name"
                    fi
                    if [[ -f "$D/reload-probe-fails-$name" || -f "$D/reload-probe-fails" ]]; then
                        : > "$D/reload-probe-fails-active-$name"
                    fi
                    exit 0
                fi
                # EGL-393: the deployed-vs-live HTTP check. The engine
                # sends one GET for the reserved probe name over bash
                # /dev/tcp; the mock answers with raw HTTP built from the
                # token embedded in the config that was loaded. This stays
                # distinct from gw_probe's TCP-connect success (which
                # falls through to exit 0 with no body).
                if [[ "${2:-}" == "-c" && "${3:-}" == *"GET http://egresslock-probe.invalid/"* ]]; then
                    mock_live_http "$name" || exit 1
                    exit 0
                fi
                # gw_probe /dev/tcp check. EGL-217: the probe-fails knob
                # ($D/probe-fails[-<name>]) models a proxy that never
                # answers — scoped to containers STARTED or RESTARTED
                # while armed (the run/restart arms write
                # $D/probe-fails-active-<name>): the crash begins at
                # start or at config activation, never on a pre-existing
                # healthy gateway mid-ensure.
                if [[ -f "$D/probe-fails-active-$name" || -f "$D/reload-probe-fails-active-$name" ]]; then
                    exit 1
                fi
                exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
    cp)
        # cp <src> <dst>: host -> container (private stage copy /
        # EGL-389 rollback restore) or container -> host (pre-staging
        # snapshot). Podman 5.4 accepts exactly one source and one
        # destination (a third path is a CLI error), so the mock rejects
        # a multi-source call with podman's rc 125 instead of silently
        # modeling more than the runtime supports.
        # EGL-395: the deployed tree is a real directory model; a stage
        # path is a real subdirectory, so a staged candidate is never
        # aliased onto the deployed squid.conf. EGL-369-D7: the
        # destination parent must exist in the container's modeled
        # layout — copying the new path into an old-layout gateway fails
        # as podman cp would.
        ndst=$#
        if (( ndst > 2 )); then
            echo "Error: accepts 2 arg(s), received $ndst" >&2
            exit 125
        fi
        dst="${!#}"
        if [[ "$dst" == *:* ]]; then
            name="${dst%%:*}"; path="${dst#*:}"
            [[ -f "$D/containers/$name.net" || -f "$D/running/$name" ]] || { echo "no such container" >&2; exit 1; }
            layout="$(mock_layout "$name")"
            lpath="$(mock_cfg_local "$name" "$path" 2>/dev/null)" || lpath=""
            if [[ -z "$lpath" ]]; then
                echo "Error: copying to '$path': no such directory in container $name (layout $layout)" >&2
                exit 1
            fi
            # A trailing slash or an existing modeled directory means
            # each source lands under its own basename.
            isdir=0
            [[ "$path" == */ || -d "$lpath" ]] && isdir=1
            # EGL-395 R-EGL-395-4 F1(b): the container stops after the
            # apply has begun. The registration and its config remain, so
            # the failure disclosure must select the proven not-running
            # body rather than a running/indeterminate or removed one.
            if [[ -f "$D/gateway-stops-late-$name" ]]; then
                rm -f "$D/gateway-stops-late-$name"
                rm -f "$D/running/$name"
            fi
            # EGL-389 D7/late seams, armed at the FIRST host -> container
            # staging copy so the ensure up to the apply is unaffected:
            #   $D/ps-fails-late        -> $D/ps-fails-active (failed ps)
            #   $D/replace-src-with-dir -> replace the host source leaf
            #     (content = path) with a directory, modelling an
            #     out-of-band replacement just before the trap restore.
            if [[ -f "$D/ps-fails-late" ]]; then
                : > "$D/ps-fails-active"
            fi
            if [[ -f "$D/replace-src-with-dir" ]]; then
                _rpath="$(cat "$D/replace-src-with-dir")"
                rm -f "$D/replace-src-with-dir"
                rm -f "$_rpath"
                mkdir -p "$_rpath"
            fi
            # EGL-389 late seam: make the conf dir unwritable at the
            # FIRST host -> container staging copy, so the gateway has
            # already been started/replaced (owned) before the trap's
            # source restore fails — S-P2r/S-P2s. Consumed once.
            if [[ -f "$D/proxy-source-restore-fails-cp" ]]; then
                _cdir="$(cat "$D/proxy-source-restore-fails-cp")"
                rm -f "$D/proxy-source-restore-fails-cp"
                chmod 0555 "$_cdir" 2>/dev/null || true
            fi
            # EGL-515: a directory source copies its contents
            # (`podman cp <dir>/. <container>:<dir>/`); the group set is
            # staged this way. Apply the per-file failure knobs to every
            # member, as the old one-source-per-group copies did.
            if (( ndst == 2 )) && [[ "${1:-}" == */. ]]; then
                srcdir="${1%/.}"
                [[ -d "$srcdir" ]] || {
                    echo "Error: copying to '$path': no such directory: $srcdir" >&2
                    exit 1
                }
                for srcf in "$srcdir"/*; do
                    [[ -e "$srcf" || -L "$srcf" ]] || continue
                    base="${srcf##*/}"
                    if [[ "$srcf" == */prev/* ]]; then
                        if [[ -f "$D/cp-restore-fails-$base" ]]; then
                            echo "Error: simulated restore copy failure for $base" >&2
                            exit 1
                        fi
                    elif [[ -f "$D/cp-stage-fails-$base" ]]; then
                        echo "Error: simulated staging copy failure for $base" >&2
                        exit 1
                    fi
                    if [[ ! -d "${lpath%/*}" ]]; then
                        echo "Error: copying to '$path': no such directory in container $name (layout $layout)" >&2
                        exit 1
                    fi
                    cp "$srcf" "$lpath/"
                    cp "$srcf" "$D/allowlist-staged"
                    # Test observation only: the exact candidate bytes copied
                    # into a private stage (the deployed squid.conf changes
                    # only at the publication rename).
                    if [[ "$base" == squid.conf && "$path" == *"/.egresslock-stage."* ]]; then
                        cp "$srcf" "$D/containers-$name.candidate"
                    fi
                done
                exit 0
            fi
            for ((ci = 1; ci < ndst; ci++)); do
                src="${!ci}"
                base="${path##*/}"
                [[ -z "$base" || "$isdir" == 1 ]] && base="${src##*/}"
                if [[ "$src" == */prev/* ]]; then
                    if [[ -f "$D/cp-restore-fails-$base" ]]; then
                        echo "Error: simulated restore copy failure for $base" >&2
                        exit 1
                    fi
                elif [[ -f "$D/cp-stage-fails-$base" ]]; then
                    echo "Error: simulated staging copy failure for $base" >&2
                    exit 1
                fi
                if [[ ! -d "${lpath%/*}" ]]; then
                    echo "Error: copying to '$path': no such directory in container $name (layout $layout)" >&2
                    exit 1
                fi
                cp "$src" "$lpath"
                cp "$src" "$D/allowlist-staged"
                # Test observation only: the exact candidate bytes copied
                # into a private stage (the deployed squid.conf changes
                # only at the publication rename).
                if [[ "$base" == squid.conf && "$path" == *"/.egresslock-stage."* ]]; then
                    cp "$src" "$D/containers-$name.candidate"
                fi
            done
            exit 0
        fi
        if [[ "$ndst" -ge 2 && "${1:-}" == *:* ]]; then
            # EGL-515: a directory source copies its contents to the host
            # (`podman cp <container>:<dir>/. <host-dir>/`); the deployed
            # config tree is snapshotted this way.
            if [[ "${1:-}" == */. ]]; then
                src="${1%/.}"
                name="${src%%:*}"; path="${src#*:}"
                [[ -f "$D/containers/$name.net" || -f "$D/running/$name" ]] || { echo "no such container" >&2; exit 1; }
                fdir="$(mock_cfg_local "$name" "$path" 2>/dev/null)" || fdir=""
                [[ -n "$fdir" && -d "$fdir" ]] \
                    || { echo "Error: no such file in container $name: $path" >&2; exit 1; }
                for f in "$fdir"/*; do
                    [[ -e "$f" || -L "$f" ]] || continue
                    base="${f##*/}"
                    if [[ -f "$D/cp-snapshot-fails-$base" ]]; then
                        echo "Error: simulated snapshot copy failure for $base" >&2
                        exit 1
                    fi
                    cp -a "$f" "$dst/"
                done
                exit 0
            fi
            for ((ci = 1; ci < ndst; ci++)); do
                src="${!ci}"
                name="${src%%:*}"; path="${src#*:}"
                [[ -f "$D/containers/$name.net" || -f "$D/running/$name" ]] || { echo "no such container" >&2; exit 1; }
                base="${path##*/}"
                if [[ -f "$D/cp-snapshot-fails-$base" ]]; then
                    echo "Error: simulated snapshot copy failure for $base" >&2
                    exit 1
                fi
                f="$(mock_cfg_local "$name" "$path" 2>/dev/null)" || f=""
                [[ -n "$f" && ( -f "$f" || -d "$f" ) ]] \
                    || { echo "Error: no such file in container $name: $path" >&2; exit 1; }
                if [[ -d "$f" && ! -L "$f" ]]; then
                    cp -a "$f" "$dst"
                else
                    cp "$f" "$dst"
                fi
            done
            exit 0
        fi
        echo "mock podman: unsupported cp (neither side names a container)" >&2
        exit 2
        ;;
    rm)
        # rm [-f] [-t N] <name>: remove container state, releasing any
        # IPAM allocation it holds. ARC-69: $D/rm-container-fails makes
        # the rm fail like a real stuck removal would.
        # EGL-114: argv recorded (the converged-ensure pins assert no
        # `rm -f` of the gateway/anchor on a converged profile).
        echo "podman rm $*" >> "$D/opslog"
        name=""
        while [[ $# -gt 0 ]]; do
            case "$1" in -*) ;; *) name="$1"; break ;; esac
            shift
        done
        # EGL-97: rm-wedged[-<name>] — the FIRST rm of that name fails like
        # a conmon-wedged removal (rc 125, real libpod error shape; state
        # untouched); the fired marker makes later calls take the normal path.
        if [[ ! -f "$D/rm-wedged-fired-$name" ]] \
            && { [[ -f "$D/rm-wedged" ]] || [[ -f "$D/rm-wedged-$name" ]]; }; then
            echo "Error: cannot remove container $name as it could not be stopped: container $name conmon exited prematurely: internal libpod error" >&2
            : > "$D/rm-wedged-fired-$name"
            exit 125
        fi
        if [[ -f "$D/rm-container-fails" ]]; then
            # EGL-394 F1 seam: the failed removal and the trap's source
            # restore are one failure window — the conf dir becomes
            # unwritable at the failed gateway removal (after the pin
            # record was written), so a still-running pre-existing
            # gateway is left owned and the restore also fails.
            if [[ -f "$D/proxy-source-restore-fails-rmf-$name" ]]; then
                _cdir="$(cat "$D/proxy-source-restore-fails-rmf-$name")"
                rm -f "$D/proxy-source-restore-fails-rmf-$name"
                chmod 0555 "$_cdir" 2>/dev/null || true
            fi
            echo "Error: unable to remove container $name: device or resource busy" >&2
            exit 1
        fi
        rm -f "$D/running/$name" "$D/containers/$name" \
              "$D/containers/$name.net" "$D/containers/$name.ip" \
              "$D/containers/$name.mac" "$D/probe-fails-active-$name"
        # EGL-114: a removed container's filesystem is gone — clear the
        # modeled per-container files (deployed/staged configs, log
        # fixtures) so a REPLACED gateway starts from a fresh bootstrap
        # FS, exactly like the real image. The literal '.' keeps the glob
        # prefix-safe (s50 cannot match s50n's files).
        rm -rf "$D/containers-$name.cfg" "$D/containers-$name.candidate" \
               "$D/containers-$name.pending-mv" "$D/containers-$name.started" \
               "$D/containers-$name.id" "$D/containers-$name.live" 2>/dev/null || true
        # EGL-395: the replacement counter is mock bookkeeping, not
        # container state — it survives the removal so a replaced
        # container gets a genuinely new instance ID.
        for f in "$D/containers-$name."*; do
            [[ -f "$f" ]] || continue
            [[ "$f" == "$D/containers-$name.gen" ]] && continue
            rm -f "$f"
        done
        if [[ -d "$D/ips" ]]; then
            for ipf in "$D/ips"/*; do
                [[ -f "$ipf" ]] || continue
                [[ "$(cat "$ipf")" == "$name" ]] && rm -f "$ipf"
            done
        fi
        echo "$name"
        ;;
    restart)
        # restart [-t N] <name>
        # EGL-114: argv recorded so the converged-ensure pins can assert
        # NO restart of a healthy gateway (and existing pins can keep
        # counting restarts where they already do).
        echo "podman restart $*" >> "$D/opslog"
        # EGL-227 D10: same fd-9 leak witness as the run arm (a restart
        # is a stop+start — its fresh monitor must not inherit the
        # account-lock fd); the egl227 section asserts the marker absent.
        if [[ -e /proc/self/fd/9 ]]; then
            echo "container child inherited fd 9: $*" >> "$D/egl227-fd9-leak"
        fi
        name=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -t) shift 2 ;;
                -*) shift ;;
                *) name="$1"; break ;;
            esac
        done
        # EGL-395: a restart that fails at the stop phase leaves the old
        # instance running (the mock keeps the running marker and the
        # old live config, so the live ACL is untouched).
        if [[ -f "$D/restart-stop-fails-$name" || -f "$D/restart-stop-fails" ]]; then
            echo "Error: failed to stop container $name: simulated stop failure" >&2
            exit 1
        fi
        # EGL-389: model a container that vanished between the config
        # swap and the restart (its name is gone from BOTH ps views), so
        # the EGL-217 cleanup skips it — the S-P3n branch.
        if [[ -f "$D/restart-vanishes-$name" ]]; then
            rm -f "$D/running/$name" "$D/containers/$name.net" \
                  "$D/containers/$name.ip" "$D/containers/$name.mac"
            echo "Error: no such container $name" >&2
            exit 1
        fi
        [[ -f "$D/running/$name" ]] || { echo "no such container" >&2; exit 1; }
        # EGL-394: a restart is a new container start. A one-shot
        # bootstrap-argv seam models the instance being restarted, not
        # every later start, so consume it here (the entrypoint starts
        # Squid on the deployed config whenever it exists — D5).
        rm -f "$D/argv-bad-$name"
        # EGL-395: a restart is a new gateway instance start — StartedAt
        # changes and the current deployed bytes become the live config.
        # EGL-394: a restart also reopens the listener modeled as failed
        # by a reload.
        mock_bump_started "$name"
        mock_cfg_load_live "$name"
        # EGL-394 F1: the deployed config is swapped for an identical
        # copy after the (re)started instance loaded it. The start cannot
        # be claimed as activation of the published file.
        if [[ -f "$D/conf-restored-after-start-$name" ]]; then
            rm -f "$D/conf-restored-after-start-$name"
            mock_cfg_restored_after_load "$name"
        fi
        rm -f "$D/reload-probe-fails-active-$name"
        # EGL-217: a RESTART while the probe-fails knob is armed puts the
        # swapped config live — from here the proxy never answers
        # (crash-loop), so the apply health wait fails.
        if [[ -f "$D/probe-fails-$name" || -f "$D/probe-fails" ]]; then
            : > "$D/probe-fails-active-$name"
        fi
        exit 0
        ;;
    image)
        case "$1" in
            exists)
                [[ -f "$D/images/$(echo "$2" | tr '/:' '__')" ]] && exit 0
                exit 1
                ;;
            inspect)
                # EGL-206-D2a: image inspect --format <tpl> <image> — the
                # annotation oracle for the checkpoint-annotation refusal.
                # Default: no annotation (empty output, rc 0). Fixture:
                # $D/image-annotated-<name-with-/-and-:->__ marks an image
                # as carrying io.podman.annotations.checkpoint.runtime.name.
                # EGL-203: an image-inspect fixture
                # ($D/image-inspect-<name-with-/-and-:->__ — e.g. the
                # doctor's staleness peek) is catted verbatim instead, so
                # a test controls what the inspect reads off the image.
                img="${@: -1}"
                fmt=""
                if [[ "${2:-}" == "--format" ]]; then fmt="${3:-}"; fi
                [[ -f "$D/images/$(echo "$img" | tr '/:' '__')" ]] \
                    || { echo "Error: no such image $img" >&2; exit 1; }
                # EGL-547: the tagged image's ID for the running-gateway
                # comparison. Dispatch on the template BEFORE the verbatim
                # staleness-peek cat below: a `{{.Id}}` probe must never
                # read a label/created fixture as an ID.
                if [[ "$fmt" == '{{.Id}}' ]]; then
                    cat "$D/image-id-$(echo "$img" | tr '/:' '__')" 2>/dev/null || true
                    exit 0
                fi
                if [[ -f "$D/image-inspect-$(echo "$img" | tr '/:' '__')" ]]; then
                    cat "$D/image-inspect-$(echo "$img" | tr '/:' '__')"
                    exit 0
                fi
                [[ -f "$D/image-annotated-$(echo "$img" | tr '/:' '__')" ]] && echo "criu"
                exit 0
                ;;
        esac
        exit 1
        ;;
    build)
        # build [-t tag] ... <context>: record the build; a -t tag makes
        # the image exist (ARC-16-D6 gateway self-provision). EGL-51:
        # mirrored into callorder.log for cross-tool ordering asserts.
        # R-EGL-222-3 F3: the marker $D/build-fails models a failing
        # build (real podman exits 125 on build errors) — recorded, then
        # failed, so "no build" asserts (empty buildlog) stay exact.
        echo "build $*" >> "$D/buildlog"
        echo "podman build $*" >> "$D/callorder.log"
        # EGL-200 P3-C: opt-in noisy build stream for the quiet-build pins.
        if [[ -f "$D/build-noisy" ]]; then
            echo "MOCK-BUILD-OUTPUT"
        fi
        if [[ -f "$D/build-fails" ]]; then
            exit 125
        fi
        local tag=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -t) tag="$2"; shift 2 ;;
                -f) shift 2 ;;
                *) shift ;;
            esac
        done
        [[ -n "$tag" ]] && : > "$D/images/$(echo "$tag" | tr '/:' '__')"
        exit 0
        ;;
    pull)
        # EGL-206 (R-EGL-206-2 #1): pull <image> — modeled fresh-account
        # first-create provision (the real `podman run` pulls a missing
        # ref; the mock run never does, so the preflight's explicit pull
        # is the modeled provision). Mirrored into callorder.log for
        # ordering asserts. Fixture: $D/pull-fails -> rc 1, store
        # untouched (models a blocked/failed registry pull).
        echo "podman pull $*" >> "$D/callorder.log"
        echo "podman pull $*" >> "$D/opslog"
        if [[ -f "$D/pull-fails" ]]; then
            echo "Error: initializing source docker://$1: reading manifest (mock pull-fails fixture)" >&2
            exit 1
        fi
        : > "$D/images/$(echo "$1" | tr '/:' '__')"
        exit 0
        ;;
    *) echo "mock podman: unsupported op $cmd" >&2; exit 2 ;;
esac
EOF

# EGL-395 test helpers for the content-addressed deployed model. The
# deployed gateway config dir is $STATE/containers-<name>.cfg/; group
# basenames carry a SHA-256, so tests resolve them through the deployed
# squid.conf reference for the ACL label instead of hard-coding a name.
mock_cfg_file() { # <container> <basename> -> host path in the deployed cfg dir
    printf '%s\n' "$STATE/containers-$1.cfg/$2"
}
mock_cfg_ref() { # <container> <acl-label> -> in-container ref from squid.conf
    local conf ref
    conf="$(mock_cfg_file "$1" squid.conf)"
    [[ -f "$conf" ]] || return 1
    ref="$(sed -n "s|^acl $2 dstdomain -n \"\\([^\"]*\\)\"[[:space:]]*$|\\1|p" "$conf" | head -n1)"
    [[ -n "$ref" ]] || return 1
    printf '%s\n' "$ref"
}
mock_group_basename() { # <container> <acl-label> -> referenced group basename
    local ref
    ref="$(mock_cfg_ref "$@")" || return 1
    printf '%s\n' "${ref##*/}"
}
mock_group_file() { # <container> <acl-label> -> host path of the deployed group
    local base
    base="$(mock_group_basename "$@")" || return 1
    mock_cfg_file "$1" "$base"
}
mock_group_name() { # <kind> <bytes-with-newlines> -> content-addressed name
    printf 'allowlist.%s.%s\n' "$1" \
        "$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)"
}

# EGL-80-L1: hermetic dpkg-query — the host dpkg database must not leak.
# An installed .deb made install-kit's real query answer "install ok
# installed", failing ~30 prefix-install tests. The mock answers an
# unknown package: rc 1, no stdout, so `deb_status` is empty. The p43
# refusal stubs its own dpkg-query earlier on PATH.
cat > "$TESTROOT/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
# EGL-80-L1 mock: egresslock is never installed in the harness world.
exit 1
EOF

# EGL-139-D2 mock seam: a state-file conntrack mirroring the ctnetlink
# verbs the engine uses. $D/conntrack-table holds nf_conntrack-shaped
# lines; $D/conntrack.log pins argv/order. Markers: conntrack-probe-fails
# (-C), conntrack-delete-fails (-D, table untouched), conntrack-list-fails
# (-L, empty), and conntrack-list-<shape> for other failed-list shapes
# (R-EGL-231-3 finding 1): nonzero-empty, zero-summary-error,
# nonzero-count, partial-rows-fail, and port-fails (EGL-295: only the
# port-only enumerate read fails). RCs match the real tool: -D deletes
# nothing -> rc 1 + banner summary on stderr; -L matches nothing -> rc 0
# + summary on stderr. Both filter ONLY original-direction tuple fields,
# so a reply-side-only match never counts; EGL-312 (R-EGL-306-3 F2)
# reaches that shape through the original fields (src=<peer>
# sport=<port>), so -D/-L also accept -s/--src and --sport and match
# every provided filter (no filter => no match).
cat > "$TESTROOT/bin/conntrack" <<'EOF'
#!/usr/bin/env bash
set -u
D="${ARCMOCK_STATE:?}/nft"
LOG="${ARCMOCK_STATE:?}/conntrack.log"
TABLE="${ARCMOCK_STATE:?}/nft/conntrack-table"
# EGL-362 P2: first-occurrence original-direction field extraction (the
# awk `seen[kv]++ == 0` semantics) in pure bash. ct_orig fills _od
# (dst), _dport_o, _os (src), _sport_o; ct_match applies the active
# filters, requiring every provided one.
ct_orig() { # ct_orig <row>
    local _row="$1" _tok="" _key="" _val=""
    local _ss=0 _sd=0 _ssp=0 _sdp=0
    _od=""; _dport_o=""; _os=""; _sport_o=""
    local -a _toks=()
    read -r -a _toks <<<"$_row"
    for _tok in "${_toks[@]}"; do
        case "$_tok" in
            *=*) _key="${_tok%%=*}"; _val="${_tok#*=}"; _val="${_val%%=*}" ;;
            *) _key="$_tok"; _val="" ;;
        esac
        case "$_key" in
            src) (( _ss == 0 )) && { _os="$_val"; _ss=1; } ;;
            dst) (( _sd == 0 )) && { _od="$_val"; _sd=1; } ;;
            sport) (( _ssp == 0 )) && { _sport_o="$_val"; _ssp=1; } ;;
            dport) (( _sdp == 0 )) && { _dport_o="$_val"; _sdp=1; } ;;
        esac
    done
}
# R-EGL-362-3 F1: awk compared numeric-looking values numerically
# (443 == 0443; +443 and 4.43e2 too), and compared as strings otherwise.
# Recreate that here: both numeric -> compare the doubles (printf is the
# in-process strtod), else exact string equality. Ports with leading
# zeros are accepted engine input, so this is producer-reachable.
ct_num_re='^[[:space:]]*[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?[[:space:]]*$'
ct_eq() { # ct_eq <row-value> <filter-value>
    local _a="$1" _b="$2" _na="" _nb="" _ca="" _cb=""
    [[ "$_a" =~ $ct_num_re ]] && _na=1
    [[ "$_b" =~ $ct_num_re ]] && _nb=1
    if [[ -n "$_na" && -n "$_nb" ]]; then
        _a="${_a#"${_a%%[![:space:]]*}"}"; _a="${_a%"${_a##*[![:space:]]}"}"
        _b="${_b#"${_b%%[![:space:]]*}"}"; _b="${_b%"${_b##*[![:space:]]}"}"
        printf -v _ca '%.17g' "$_a"
        printf -v _cb '%.17g' "$_b"
        [[ "$_ca" == "-0" ]] && _ca="0"
        [[ "$_cb" == "-0" ]] && _cb="0"
        [[ "$_ca" == "$_cb" ]]
    else
        [[ "$_a" == "$_b" ]]
    fi
}
ct_match() { # ct_match <row> — true when every provided filter matches
    local _ok=1
    ct_orig "$1"
    [[ -n "$dip" ]] && ! ct_eq "$_od" "$dip" && _ok=0
    [[ -n "$dport" ]] && ! ct_eq "$_dport_o" "$dport" && _ok=0
    [[ -n "$sip" ]] && ! ct_eq "$_os" "$sip" && _ok=0
    [[ -n "$sport" ]] && ! ct_eq "$_sport_o" "$sport" && _ok=0
    [[ -z "$dip" && -z "$dport" && -z "$sip" && -z "$sport" ]] && _ok=0
    (( _ok ))
}
echo "conntrack $*" >> "$LOG"
op="$1"; shift
case "$op" in
    -C)
        [[ -f "$D/conntrack-probe-fails" ]] && { echo "mock conntrack: ctnetlink unavailable" >&2; exit 1; }
        n=0
        if [[ -f "$TABLE" ]]; then
            while IFS= read -r _ctrow || [[ -n "$_ctrow" ]]; do
                [[ -n "$_ctrow" ]] && n=$((n + 1))
            done < "$TABLE"
        fi
        echo "$n"
        exit 0
        ;;
    -D)
        if [[ -f "$D/conntrack-delete-fails" ]]; then
            echo "conntrack: Operation failed: Connection timed out" >&2
            exit 1
        fi
        # Scoped delete: drop entries whose ORIGINAL-direction fields
        # (the first src/dst/sport/dport set in the row — the fields the
        # real filters select) match EVERY provided filter (EGL-312:
        # -s/--src and --sport admitted for the peer-direction
        # exact-tuple deletes); other pins, DNS, gateway-exemption
        # traffic, and rows matching only on the reply side stay
        # untouched. No filter set ⇒ nothing matches (never delete
        # unscoped).
        dip=""; dport=""; sip=""; sport=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -d) dip="$2"; shift 2 ;;
                --dport) dport="$2"; shift 2 ;;
                -s|--src|--orig-src) sip="$2"; shift 2 ;;
                --sport|--orig-port-src) sport="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        n=0
        if [[ -f "$TABLE" && ( -n "$dip" || -n "$sip" || -n "$dport" || -n "$sport" ) ]]; then
            : > "$TABLE.t"
            while IFS= read -r _ctrow || [[ -n "$_ctrow" ]]; do
                if ct_match "$_ctrow"; then
                    n=$((n + 1))
                else
                    printf '%s\n' "$_ctrow" >> "$TABLE.t"
                fi
            done < "$TABLE"
            mv "$TABLE.t" "$TABLE"
        fi
        # EGL-231-R2: honest rc + the banner summary on stderr like the
        # real tool — a no-op delete is nonzero with the delimited
        # "…: 0 flow entries have been deleted." summary; a real delete
        # is rc 0. (The engine keys the no-warn on the ": 0 …." shape.)
        echo "conntrack v1.4.8 (conntrack-tools): $n flow entries have been deleted." >&2
        [[ "$n" -gt 0 ]] && exit 0
        exit 1
        ;;
    -L)
        if [[ -f "$D/conntrack-list-fails" ]]; then
            # EGL-231: empty-output failure shape (no summary at all) —
            # a failing read must not classify as success.
            echo "mock conntrack: list failed" >&2
            exit 1
        fi
        # R-EGL-231-3 failed-list shapes: rc != 0 in every one; the
        # engine must die at the read (suppress `removed:`) on all.
        if [[ -f "$D/conntrack-list-nonzero-empty" ]]; then
            echo "conntrack v1.4.8 (conntrack-tools): 0 flow entries have been shown." >&2
            exit 1
        fi
        if [[ -f "$D/conntrack-list-zero-summary-error" ]]; then
            echo "conntrack: netlink error: Operation failed" >&2
            echo "conntrack v1.4.8 (conntrack-tools): 0 flow entries have been shown." >&2
            exit 1
        fi
        if [[ -f "$D/conntrack-list-nonzero-count" ]]; then
            echo "conntrack v1.4.8 (conntrack-tools): 10 flow entries have been shown." >&2
            exit 1
        fi
        if [[ -f "$D/conntrack-list-partial-rows-fail" ]]; then
            # Partial dump: rows on stdout, then the failure.
            echo "tcp 6 431998 ESTABLISHED src=10.199.60.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2"
            echo "conntrack: netlink error: Operation failed" >&2
            echo "conntrack v1.4.8 (conntrack-tools): 1 flow entry has been shown." >&2
            exit 1
        fi
        # Scoped list of the remaining entries for the tuple; rows are
        # rendered in the ctnetlink -L shape (no leading `ipv4 2 `, the
        # procfs dump prefix — EGL-231-D1) on stdout, the banner summary
        # on stderr; an empty dump is rc 0 (upstream print_stats
        # exempts the list summary from the zero-count failure —
        # R-EGL-231-3, the D6 correction).
        dip=""; dport=""; sip=""; sport=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -d) dip="$2"; shift 2 ;;
                --dport) dport="$2"; shift 2 ;;
                -s|--src|--orig-src) sip="$2"; shift 2 ;;
                --sport|--orig-port-src) sport="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        # EGL-313 flush-shaped read counter (mirror of the EGL-312 peer
        # counter): counts every -L carrying both `-d` and `--dport`
        # (the flush helper's enumerate/witness shape) so the
        # conntrack-flush-recheck-fails marker can fail ONLY the SECOND
        # such read (the witness) and the witness's rc gate stays
        # observable (gate dropped -> the survivor is declared absent).
        # Leads the fail markers like the peer counter does: it counts
        # every flush-shaped attempt, the marker's own die included.
        if [[ -n "$dip" && -n "$dport" && -z "$sip" && -z "$sport" ]]; then
            fc=0
            [[ -f "$D/conntrack-flush-reads" ]] && fc="$(cat "$D/conntrack-flush-reads")"
            fc=$(( fc + 1 ))
            printf '%s\n' "$fc" > "$D/conntrack-flush-reads"
            if [[ -f "$D/conntrack-flush-recheck-fails" && "$fc" -ge 2 ]]; then
                echo "mock conntrack: flush recheck list failed" >&2
                exit 1
            fi
        fi
        # EGL-317 test seam: the lying scoped read. While the marker
        # exists, EVERY flush-shaped -L (daddr+dport set, no -s/--sport —
        # the helper's enumerate and its own witness share one argv)
        # returns the empty dump with rc 0 while the table keeps its
        # rows. Persistent, NOT consumed-once: consumed-once would fool
        # the enumerate only, and the helper's real witness read would
        # then die the EGL-297 survivor die before the reconcile witness
        # runs (rc 1 but never F3). The reconcile's port-only enumerate
        # is a different read shape and still sees the rows — the leg
        # pins the F3 residue die.
        if [[ -f "$D/conntrack-list-scoped-hides" \
           && -n "$dip" && -n "$dport" && -z "$sip" && -z "$sport" ]]; then
            echo "conntrack v1.4.8 (conntrack-tools): 0 flow entries have been shown." >&2
            exit 0
        fi
        # EGL-312 stage markers (R-EGL-312-1 F3/F4, R-EGL-312-2 F1) —
        # each failing ONLY its own read so the earlier reads succeed
        # first; they sit after argv parse (before the table walk) so
        # they never fire on the unrelated shapes. The per-source
        # counter leads the fail marker: it counts every peer-shaped
        # -L attempt (the marker's own die included), which keeps the
        # pre-delete rc gate mutation observable in the peer-fails leg
        # (counter==2 instead of 1).
        if [[ -n "$sport" && -n "$sip" ]]; then
            pc=0
            [[ -f "$D/conntrack-peer-reads" ]] && pc="$(cat "$D/conntrack-peer-reads")"
            pc=$(( pc + 1 ))
            printf '%s\n' "$pc" > "$D/conntrack-peer-reads"
            if [[ -f "$D/conntrack-list-peer-recheck-fails" && "$pc" -ge 2 ]]; then
                # EGL-312 R-EGL-312-2 F1: the phase-selective witness
                # recheck. The pre-delete peer enumerate and the
                # post-delete witness read share one argv, so
                # conntrack-list-peer-recheck-fails fails only the
                # SECOND peer-shaped -L of the command (the witness),
                # letting the delete run first. The leg removes the
                # counter file before the command.
                echo "mock conntrack: peer recheck list failed" >&2
                exit 1
            fi
        fi
        if [[ -n "$sport" && -n "$sip" && -f "$D/conntrack-list-peer-fails" ]]; then
            echo "mock conntrack: peer list failed" >&2
            exit 1
        fi
        if [[ -n "$sport" && -z "$dip" && -z "$dport" && -z "$sip" && -f "$D/conntrack-list-sport-fails" ]]; then
            echo "mock conntrack: sport list failed" >&2
            exit 1
        fi
        # EGL-317 test seam: the phase-selective port-only recheck —
        # mirror of the EGL-312 peer counter. Counts every port-only
        # enumerate (-L with a --dport and no -d/-s/--sport: the
        # reconcile's step (2) read shape);
        # conntrack-list-port-recheck-fails fails ONLY the SECOND such
        # read (the witness pass's enumerate), so the flush pass's
        # deletes run first. The leg removes the counter file before the
        # command.
        if [[ -z "$dip" && -n "$dport" && -z "$sip" && -z "$sport" ]]; then
            prc=0
            [[ -f "$D/conntrack-port-reads" ]] && prc="$(cat "$D/conntrack-port-reads")"
            prc=$(( prc + 1 ))
            printf '%s\n' "$prc" > "$D/conntrack-port-reads"
            if [[ -f "$D/conntrack-list-port-recheck-fails" && "$prc" -ge 2 ]]; then
                echo "mock conntrack: port recheck list failed" >&2
                exit 1
            fi
        fi
        # EGL-295: the port-only enumerate read (`-L` with a `--dport`
        # but no `-d`) has its own marker — conntrack-list-port-fails
        # fails ONLY that read (the member leg's -d-scoped -L read still
        # runs first and succeeds); -D and the scoped reads are
        # unchanged.
        if [[ -z "$dip" && -n "$dport" && -f "$D/conntrack-list-port-fails" ]]; then
            echo "mock conntrack: port list failed" >&2
            exit 1
        fi
        # EGL-219-D14 (R4): the daddr-selective read-failure seam for the
        # member-loop leg. The marker's content is one daddr: a `-L` whose
        # `-d` matches fails with the netlink-error shape (rc 1, stderr)
        # and consumes the marker, so exactly the first read of that
        # member fails and the leg can observe the enumerate-before-delete
        # ordering. Other reads are unchanged.
        if [[ -n "$dip" && -f "$D/conntrack-list-fail-daddr" ]] \
           && [[ "$dip" == "$(cat "$D/conntrack-list-fail-daddr")" ]]; then
            rm -f "$D/conntrack-list-fail-daddr"
            echo "mock conntrack: netlink error: Operation failed" >&2
            exit 1
        fi
        n=0
        if [[ -f "$TABLE" && ( -n "$dport" || -n "$sport" || -n "$dip" || -n "$sip" ) ]]; then
            while IFS= read -r row; do
                [[ -z "$row" ]] && continue
                # -d sets the scoped member shape (both fields); the
                # port-only enumerate read has no -d, so every row
                # whose ORIGINAL-direction dport matches is returned
                # (a=="" is the reconcile's enumerate shape, EGL-295).
                # EGL-312: every provided filter must match (the peer
                # reads add -s/--sport); no filter set ⇒ no match.
                if ct_match "$row"; then
                    (( n += 1 ))
                    echo "${row#ipv4 2 }"
                fi
            done < "$TABLE"
        fi
        echo "conntrack v1.4.8 (conntrack-tools): $n flow entries have been shown." >&2
        exit 0
        ;;
    --version|-V)
        echo "conntrack v1.4.8 (conntrack-tools mock)"
        exit 0
        ;;
    *)
        echo "mock conntrack: unsupported op $op" >&2
        exit 2
        ;;
esac
EOF

# EGL-139-D2 mock seam: the epilogue reader for /proc/net/nf_conntrack.
# Since EGL-231 disallow-host reads ctnetlink, not proc, but the mock
# `cat` stays so a regressed proc reader fails named:
# conntrack-table-unreadable forces a read failure and
# conntrack-table-absent (EGL-231-D4) is the real netns ENOENT. Everything
# else delegates to the real cat.
cat > "$TESTROOT/bin/cat" <<'EOF'
#!/usr/bin/env bash
# Mock cat: intercept only /proc/net/nf_conntrack (EGL-139-D2 reader).
for a in "$@"; do
    if [[ "$a" == /proc/net/nf_conntrack ]]; then
        # EGL-231-D4: the conntrack-table-absent marker is the reporter's
        # host shape — the proc file simply does not exist in that netns.
        if [[ -f "${ARCMOCK_STATE:?}/nft/conntrack-table-absent" ]]; then
            echo "cat: /proc/net/nf_conntrack: No such file or directory" >&2
            exit 1
        fi
        # EGL-168-D4: the conntrack-table-unreadable marker forces the
        # table read to fail (rc non-zero, named stderr) — the
        # post-swap assert's table-unreadable die path.
        if [[ -f "${ARCMOCK_STATE:?}/nft/conntrack-table-unreadable" ]]; then
            echo "cat: /proc/net/nf_conntrack: read failed (conntrack-table-unreadable marker)" >&2
            exit 1
        fi
        [[ -f "${ARCMOCK_STATE:?}/nft/conntrack-table" ]] && cat "${ARCMOCK_STATE:?}/nft/conntrack-table"
        exit 0
    fi
done
exec /bin/cat "$@"
EOF

chmod +x "$TESTROOT/bin/nft" "$TESTROOT/bin/getent" "$TESTROOT/bin/podman" \
         "$TESTROOT/bin/dpkg-query" "$TESTROOT/bin/ip" "$EGRESSLOCK_PROFILES" \
         "$TESTROOT/bin/conntrack" "$TESTROOT/bin/cat"

# Mock systemctl (ARC-16): records every call, mirrored to callorder.log
# for cross-tool ordering (EGL-51). systemctl-usermgr-fails makes the
# user-manager liveness probe exit 3 like inactive user@<uid>.service.
cat > "$TESTROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
D="${ARCMOCK_STATE:?}"
echo "systemctl $*" >> "$D/systemctl.log"
echo "systemctl $*" >> "$D/callorder.log"
if [[ -f "$D/systemctl-usermgr-fails" && "$*" == "is-active --quiet user@"* ]]; then
    exit 3
fi
# EGL-38: marker models a not-enabled verify timer for the --doctor
# account slice (start/enable calls still log).
# EGL-345: the armed-state probe asks NON-QUIET (`static`/`indirect`
# exit 0, so --quiet cannot distinguish them from `enabled`); the
# legacy marker answers `disabled` for both forms, and a
# systemctl-is-enabled fixture names any other state (`masked`,
# `static`, `not-found`, ...).
if [[ "$1" == "is-enabled" && "$*" == *"egresslock-verify@"* ]]; then
    if [[ -f "$D/systemctl-timer-off" && "$*" == *".timer"* ]]; then
        echo disabled
        exit 1
    fi
    if [[ -f "$D/systemctl-is-enabled" ]]; then
        st="$(cat "$D/systemctl-is-enabled")"
        echo "$st"
        case "$st" in
            enabled|enabled-runtime|static|indirect) exit 0 ;;
            not-found) exit 4 ;;
            *) exit 1 ;;
        esac
    fi
    if [[ "$*" == *"--quiet"* ]]; then
        exit 0
    fi
    echo enabled
    exit 0
fi
# EGL-84: --doctor unit-health probes answer from fixture files.
# Absent fixtures = a HEALTHY host (is-failed says active; show/list-units
# return nothing) so the pre-EGL-84 doctor behavior is unchanged.
# EGL-102-D6: (a) FragmentPath queries for a .timer unit answer from
# systemctl-fragpath-timer when present (the service/shared fixture
# otherwise, so older cases behave exactly as before); (b) a NON-EMPTY
# systemctl-health-failed is a unit-glob list — is-failed fails only for
# matching units (an EMPTY file keeps failing every unit, as before).
if [[ "$1" == "is-failed" ]]; then
    if [[ -f "$D/systemctl-health-failed" ]]; then
        if [[ ! -s "$D/systemctl-health-failed" ]]; then echo failed; exit 0; fi
        u="${!#}"
        while IFS= read -r m; do
            [[ -z "$m" ]] && continue
            # shellcheck disable=SC2254  # deliberate glob match
            case "$u" in $m) echo failed; exit 0 ;; esac
        done < "$D/systemctl-health-failed"
    fi
    echo active
    exit 1
fi
# EGL-345: `show` degrade fixture — a systemctl-show-fail marker makes
# every property lookup fail (rc 1, no output); systemctl-show-fail-
# <Property> fails only that property. Exercises the named-unknown
# paths (a failed probe must never be reported as a real state).
if [[ "$1" == "show" ]]; then
    egl345_failprop="" egl345_fargs=("$@")
    for ((i = 0; i < ${#egl345_fargs[@]}; i++)); do
        if [[ "${egl345_fargs[i]}" == "-p" ]]; then egl345_failprop="${egl345_fargs[i+1]:-}"; break; fi
    done
    if [[ -f "$D/systemctl-show-fail" \
            || ( -n "$egl345_failprop" && -f "$D/systemctl-show-fail-${egl345_failprop}" ) ]]; then
        exit 1
    fi
fi
if [[ "$1" == "show" && "$*" == *"ExecMainStatus"* ]]; then
    [[ -f "$D/systemctl-mainstatus" ]] && cat "$D/systemctl-mainstatus"
    exit 0
fi
if [[ "$1" == "show" && "$*" == *"FragmentPath"* ]]; then
    if [[ "$*" == *".timer" && -f "$D/systemctl-fragpath-timer" ]]; then
        cat "$D/systemctl-fragpath-timer"
    else
        [[ -f "$D/systemctl-fragpath" ]] && cat "$D/systemctl-fragpath"
    fi
    exit 0
fi
if [[ "$1" == "show" ]]; then
    # EGL-345: per-property fixtures for the recency/state probes.
    # `systemctl-show-<Property>.<unit>` is unit-specific and wins when
    # present; `systemctl-show-<Property>` is the shared fallback. An
    # absent fixture is an empty (answered) value, matching real show.
    egl345_prop="" egl345_unit="${!#}"
    egl345_args=("$@")
    for ((i = 0; i < ${#egl345_args[@]}; i++)); do
        if [[ "${egl345_args[i]}" == "-p" ]]; then egl345_prop="${egl345_args[i+1]:-}"; break; fi
    done
    if [[ -n "$egl345_prop" ]]; then
        if [[ -f "$D/systemctl-show-${egl345_prop}.${egl345_unit}" ]]; then
            cat "$D/systemctl-show-${egl345_prop}.${egl345_unit}"
        elif [[ -f "$D/systemctl-show-${egl345_prop}" ]]; then
            cat "$D/systemctl-show-${egl345_prop}"
        elif [[ "$egl345_prop" == "ActiveState" ]]; then
            # R-EGL-345-4: ActiveState has no valid empty value — a real
            # `show` always answers one. Default to a running unit so the
            # normal cases exercise a real state; the empty-answer degrade
            # is written as an explicitly empty fixture file above.
            echo active
        fi
    fi
    exit 0
fi
if [[ "$1" == "list-units" ]]; then
    # EGL-201: a --failed query serves the split fixture when present;
    # everything else (and the fallback) keeps the shared fixture.
    if [[ "$*" == *"--failed"* && -f "$D/systemctl-list-units-failed" ]]; then
        cat "$D/systemctl-list-units-failed"
    elif [[ -f "$D/systemctl-list-units" ]]; then
        cat "$D/systemctl-list-units"
    fi
    exit 0
fi
exit 0
EOF
chmod +x "$TESTROOT/bin/systemctl"

# Mock loginctl (ARC-28): records calls; show-user Linger -> yes (set
# ARCMOCK_LINGER_ANSWER=no for the fail-closed branch). EGL-51 mirrors
# calls to callorder.log.
cat > "$TESTROOT/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
D="${ARCMOCK_STATE:?}"
echo "loginctl $*" >> "$D/loginctl.log"
echo "loginctl $*" >> "$D/callorder.log"
if [[ "$1" == "show-user" && "$*" == *"-p Linger --value"* ]]; then
    echo "${ARCMOCK_LINGER_ANSWER:-yes}"
fi
exit 0
EOF
chmod +x "$TESTROOT/bin/loginctl"

export PATH="$TESTROOT/bin:$PATH"
export HOME="$TESTROOT/home"
# EGL-227 F1: the engine lock is keyed to the account's home from the
# account database — the mock answers uid queries with the harness home
# so the lock stays under $TESTROOT (and matches $HOME).
export ARCMOCK_PASSWD_HOME="$TESTROOT/home"
export USER="testuser"
export EGRESSLOCK_ANCHOR_IMAGE="docker.io/library/alpine:latest"
export AGENTS_ROOT="$TESTROOT/agents"
# EGL-80-L2: the deb-shape guard must not see a host /usr/bin/egresslock
# (install-kit would refuse). Default absent; refusal tests point at a
# fixture.
export EGRESSLOCK_UB_BIN="$TESTROOT/ub/egresslock"
# EGL-107-D2: the deb-libdir guard must not read host state — a bare
# /usr/lib/egresslock leftover made every install-kit test refuse. Default
# an empty harness path (never VERSION); the refusal test overrides it.
# Unset stays production's real /usr/lib/egresslock.
mkdir -p "$TESTROOT/deb-libdir"
export EGRESSLOCK_DEB_LIBDIR="$TESTROOT/deb-libdir"
# EGL-80-1-F1: EGRESSLOCK_PATH_BINDIR/SBINDIR are deliberately NOT
# defaulted — a shared wrapper dir would trip install-kit's ARC-22-D1
# foreign-marker refusal. Each kit test sets per-prefix hooks.
# Gateway image exists in the mock; keep the real default name.
mkdir -p "$STATE/images"
: > "$STATE/images/localhost_egresslock-gateway_latest"
# EGL-206-D2a: the checkpoint preflight inspects the RESOLVED anchor image
# before running. Seed the mock store's alpine marker; localhost/base stays
# ABSENT for the EGL-66-D2 fallback pin.
: > "$STATE/images/docker.io_library_alpine_latest"

# EGL-99 (direction 3): named-skip accounting. Every skip goes through
# skip() so TOTAL reports the exact count and cause; a tree-shape-gated
# assert is visible instead of silently absent. The `SKIP: ` prefix feeds
# run.sh's summary (EGL-86-D3).
skip_count=0
declare -A skip_causes=()
skip() { # skip <cause-tag> <free-text message...>
    local cause="$1"; shift
    skip_count=$(( skip_count + 1 ))
    skip_causes["$cause"]=$(( ${skip_causes["$cause"]:-0} + 1 ))
    echo "SKIP: $*"
}
# skip_summary renders `, 0 skipped` or `, N skipped (cause[, cause: k])`;
# a single-count cause is named bare.
skip_summary() {
    if (( skip_count == 0 )); then
        printf ', 0 skipped'
        return
    fi
    local detail=""
    for cause in "${!skip_causes[@]}"; do
        if (( skip_causes["$cause"] == 1 )); then
            detail+="${detail:+, }$cause"
        else
            detail+="${detail:+, }$cause: ${skip_causes["$cause"]}"
        fi
    done
    printf ', %d skipped (%s)' "$skip_count" "$detail"
}
# EGL-99 (direction 1): record the tree shape beside the counts (`.git`
# dir, worktree file, or none) so a count delta is attributable from the
# TOTAL line.
tree_shape_tag() {
    if [[ -d "$TREE_ROOT/.git" ]]; then
        echo "tree: git-checkout"
    elif [[ -f "$TREE_ROOT/.git" ]]; then
        echo "tree: git-worktree"
    else
        echo "tree: no-git"
    fi
}

pass=0; fail=0
# EGL-184 (F-022 remainder): _sect_bump is the only sanctioned pass/fail
# increment. Inside a section it bumps section + grand; outside, it books
# a stray and results_total refuses a TOTAL (EGL-184-D4).
_sect_open_cur=""
_sect_open_label=""
_sect_open_mode=""
_sect_stray=0
_sect_grand_pass=0; _sect_grand_fail=0    # every sanctioned increment
_sect_booked_pass=0; _sect_booked_fail=0  # Σ all ended snapshots (counted + excluded)
_sect_bump() { # _sect_bump pass|fail
    if [[ -n "$_sect_open_cur" ]]; then
        if [[ "$1" == pass ]]; then
            pass=$((pass+1)); _sect_grand_pass=$((_sect_grand_pass+1))
        else
            fail=$((fail+1)); _sect_grand_fail=$((_sect_grand_fail+1))
        fi
    else
        _sect_stray=$((_sect_stray+1))
    fi
}
check() { # check <desc> <rc-expected> <cmd...>
    local desc="$1" want="$2"; shift 2
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    if [[ "$got" == "$want" ]]; then
        _sect_bump pass; echo "PASS: $desc"
    else
        _sect_bump fail; echo "FAIL: $desc (want rc=$want, got rc=$got)"
    fi
}
check_out() { # check_out <desc> <expected-substring> <cmd...>
    local desc="$1" want="$2"; shift 2
    if "$@" 2>/dev/null | grep -qF "$want"; then
        _sect_bump pass; echo "PASS: $desc"
    else
        _sect_bump fail; echo "FAIL: $desc (output missing '$want')"
    fi
}
assert() { # assert pass|fail [fail-message]
    if [[ "$1" == pass ]]; then
        _sect_bump pass
    else
        _sect_bump fail
        echo "FAIL: $2"
    fi
}

# EGL-184 (F-022 remainder): per-section RESULTS bookkeeping. Replaces the
# hand-maintained reset -> capture -> RESULTS-echo -> hand-sum chain (86
# resets, 84 captures/RESULTS lines, distant sum terms). EGL-99 freeze:
# RESULTS/TOTAL text is byte-pinned, so section_end only snapshots and
# emission stays at the echo sites via results_emit.
#
# Modes (section_begin <name> "<label>" [mode]):
#   counted          — RESULTS line emitted, in TOTAL
#   excluded         — RESULTS line emitted, NOT in TOTAL (engine e98)
#   excluded-silent  — no RESULTS line, not in TOTAL (kit egl102r2)
# Engine arc14 (a14 delegate, EGL-179-D3) and the egl140 witness alias stay
# manual (EGL-184-D2 / EGL-194-D5); arc14 enters TOTAL via results_total's
# extra args and bypasses the grand accumulator by design.
# EGL-270 (P4): the slow-section registry + track gate. run.sh --track fast
# exports EGRESSLOCK_TEST_TRACK=fast; each registered section's whole
# window is skipped (body never runs). Unset/empty (direct harness run) is
# the full track. Membership is whole-section only (EGL-270 D2); security-
# classed sections never register (operator G1=A). R-EGL-270-5 F1: egl223
# stays fast-track (EGL-223-D9 anchor retention, EGL-206 checkpoint
# refusal); the round-1 member is egl203r alone.
declare -A _slow_sections=( [egl203r]=1 )
declare -A _slow_skipped=()
slow_section_run() { # slow_section_run <name> — 0 = run the window, 1 = skip it
    local name="${1:-}"
    if [[ "${EGRESSLOCK_TEST_TRACK:-full}" != "fast" || -z "${_slow_sections[$name]:-}" ]]; then
        return 0
    fi
    # EGL-270/G4: go through skip() so TOTAL names the cause and run.sh
    # counts it (EGL-86-D3).
    _slow_skipped["$name"]=1
    skip "slow-track $name" "slow-track: section '$name' skipped on --track fast (run: bash tests/run.sh --track full)"
    return 1
}

# EGL-451: whole-window shard gate. Unsharded (direct harness run, flag
# unset/empty) runs every window; sharded matches NAME as a whole
# space-delimited word in EGRESSLOCK_TEST_SECTIONS (never a substring).
shard_section_run() { # shard_section_run <name> — 0 = run this window
    local name="${1:-}"
    if [[ -z "${EGRESSLOCK_TEST_SHARDED:-}" ]]; then
        return 0
    fi
    case " ${EGRESSLOCK_TEST_SECTIONS:-} " in
        *" $name "*) return 0 ;;
    esac
    return 1
}

# EGL-465: converged-state snapshot for section resets that would otherwise
# pay a teardown+ensure per leg (the egl389/egl392 state-pristine pattern).
# `state_restore_or_seed <dir> <seed-cmd...>` restores the frozen mock state
# when it exists, else runs the seed command once and freezes the result.
# The cumulative logs ($STATE/opslog, $STATE/callorder.log) are append-only
# evidence: they are excluded from the snapshot and callorder is carried
# across a restore (opslog is truncated as the per-leg reset contract).
# Every failure is named and returned; callers turn it into their section
# assert so a partial copy can never look like a successful reset.
state_snapshot() { # state_snapshot <pristine-dir> — freeze the converged $STATE
    local dest="${1:-}"
    if [[ -z "$dest" ]]; then
        echo "FAIL: state_snapshot: usage: state_snapshot <pristine-dir>" >&2
        return 2
    fi
    if ! rm -rf "$dest" || ! mkdir -p "$dest"; then
        echo "FAIL: state_snapshot: cannot create $dest" >&2
        return 1
    fi
    if ! cp -a "$STATE/." "$dest/"; then
        echo "FAIL: state_snapshot: cannot copy $STATE to $dest" >&2
        return 1
    fi
    if ! rm -f "$dest/opslog" "$dest/callorder.log"; then
        echo "FAIL: state_snapshot: cannot exclude the cumulative logs in $dest" >&2
        return 1
    fi
    return 0
}
state_restore_or_seed() { # state_restore_or_seed <pristine-dir> <seed-cmd...>
    local dest="${1:-}" saved had_callorder=0
    if [[ -z "$dest" ]]; then
        echo "FAIL: state_restore_or_seed: usage: state_restore_or_seed <pristine-dir> <seed-cmd...>" >&2
        return 2
    fi
    shift
    if [[ -d "$dest" ]]; then
        saved="$TESTROOT/.state-restore-callorder.$$"
        if [[ -f "$STATE/callorder.log" ]]; then
            had_callorder=1
            if ! cp -a "$STATE/callorder.log" "$saved"; then
                echo "FAIL: state_restore_or_seed: cannot preserve $STATE/callorder.log" >&2
                rm -f "$saved"; return 1
            fi
        fi
        if ! rm -rf "$STATE" || ! cp -a "$dest" "$STATE"; then
            echo "FAIL: state_restore_or_seed: cannot restore $STATE from $dest" >&2
            rm -f "$saved"; return 1
        fi
        if (( had_callorder )) && ! cp -a "$saved" "$STATE/callorder.log"; then
            echo "FAIL: state_restore_or_seed: cannot restore $STATE/callorder.log" >&2
            rm -f "$saved"; return 1
        fi
        rm -f "$saved"
        if ! : > "$STATE/opslog"; then
            echo "FAIL: state_restore_or_seed: cannot reset $STATE/opslog" >&2
            return 1
        fi
        return 0
    fi
    if (( $# == 0 )); then
        echo "FAIL: state_restore_or_seed: no snapshot at $dest and no seed command" >&2
        return 1
    fi
    if ! "$@"; then
        echo "FAIL: state_restore_or_seed: seed command failed for $dest" >&2
        return 1
    fi
    state_snapshot "$dest"
}

# EGL-270 (P1): per-section runtime stamps. section_end emits one
# `TIMING: <name> <n.n>s`; a slow-skipped section emits none. RESULTS text
# stays byte-identical (EGL-99).
declare -A _sect_snap=()   # name -> "mode|label|pass|fail" (ended only)
declare -A _sect_emitted=()  # name -> 1 when results_emit printed its line (EGL-451-F3)

# EGL-481-D5 (nft) + EGL-518-F2 (networks): per-section mock-runtime
# isolation. Engine windows share the ONE mock netns state ($STATE/nft) and
# the ONE mock Podman network registry ($STATE/networks) inside a harness
# process. A chain a previous section installed used to be visible to this
# section — harmless while verify compared only the two known chains, but
# EGL-481-D2 fails any chain the section's own confdir does not define. A
# network a previous section created is a kit network the EGL-518 table-step
# re-read must (correctly) keep the last table for, so a leaked
# `egresslock-*` file silently changes a teardown leg's expected state in
# whatever shard layout packs the producer before the consumer (seen only
# under CI's 2-shard packing). Reset both registries at every engine window
# entry so each section starts from no chains and no networks (its own
# seeds/ensures rebuild what it needs); never weaken a check itself. Gated
# on the engine harness opt-in so the kit/docs harnesses (same lib.sh) keep
# their state across sections. The cumulative logs live outside
# $STATE/{nft,networks} and are untouched.
_section_reset_runtime_state() {
    [[ -n "${EGRESSLOCK_TEST_NFT_ISOLATION:-}" ]] || return 0
    [[ -n "${STATE:-}" ]] || return 0
    local d
    for d in nft networks; do
        [[ -e "$STATE/$d" ]] || continue
        if ! rm -rf "$STATE/$d" || ! mkdir -p "$STATE/$d"; then
            echo "FAIL: section_begin: cannot reset the mock runtime state in $STATE/$d (EGL-481/EGL-518 isolation, fail-closed)"
            exit 1
        fi
    done
}

section_begin() { # section_begin <name> "<label>" [counted|excluded|excluded-silent]
    local name="${1:-}" label="${2:-}" mode="${3:-counted}"
    if [[ -z "$name" || -z "$label" ]]; then
        echo "FAIL: section_begin: usage: section_begin <name> <label> [counted|excluded|excluded-silent] (EGL-184 fail-closed)"
        exit 1
    fi
    case "$mode" in
        counted|excluded|excluded-silent) ;;
        *) echo "FAIL: section_begin: '$name': unknown mode '$mode' (EGL-184 fail-closed)"; exit 1 ;;
    esac
    if [[ -n "$_sect_open_cur" ]]; then
        echo "FAIL: section_begin: '$_sect_open_cur' is still open (double begin / overlapping window of '$name'; EGL-184 fail-closed)"
        exit 1
    fi
    if [[ -n "${_sect_snap[$name]:-}" ]]; then
        echo "FAIL: section_begin: '$name' already ended (re-begin; EGL-184 fail-closed)"
        exit 1
    fi
    # EGL-451-D6: the parent names the section a timed-out shard wedged in.
    # Subsections (EGL-184 controls in command substitutions) must not
    # overwrite the top-level progress marker.
    if [[ -n "${EGRESSLOCK_TEST_SHARD_PROGRESS:-}" && "${BASH_SUBSHELL:-0}" == "0" ]]; then
        printf '%s\n' "$name" > "$EGRESSLOCK_TEST_SHARD_PROGRESS" 2>/dev/null || true
    fi
    _section_reset_runtime_state
    _sect_open_cur="$name"; _sect_open_label="$label"; _sect_open_mode="$mode"
    pass=0; fail=0
    _sect_t0="${EPOCHREALTIME:-}"
}
section_end() { # section_end <name> — snapshot only; does NOT emit RESULTS (EGL-184-D1)
    local name="${1:-}"
    if [[ -z "$_sect_open_cur" || "$_sect_open_cur" != "$name" ]]; then
        echo "FAIL: section_end: '$name' is not the open section (end without begin, ended twice, or out of order; EGL-184 fail-closed)"
        exit 1
    fi
    _sect_snap["$name"]="$_sect_open_mode|$_sect_open_label|$pass|$fail"
    _sect_booked_pass=$((_sect_booked_pass + pass))
    _sect_booked_fail=$((_sect_booked_fail + fail))
    # EGL-270 (P1): the per-section runtime stamp is bookkeeping, not a
    # verdict — one line, name-identical with the section name.
    if [[ -n "${_sect_t0:-}" && -n "${EPOCHREALTIME:-}" ]]; then
        echo "TIMING: $name $(LC_ALL=C awk -v a="$_sect_t0" -v b="${EPOCHREALTIME:-}" 'BEGIN{printf "%.1f", b-a}')s"
    fi
    _sect_t0=""
    _sect_open_cur=""; _sect_open_label=""; _sect_open_mode=""
}
results_emit() { # results_emit <name> — prints the pinned RESULTS line from the snapshot
    local name="${1:-}"
    # EGL-451-D5: in a shard, a section outside this shard's selection was
    # never begun and must no-op. Restrict the no-op to the top-level shell:
    # the EGL-184 controls call results_emit inside a command substitution
    # and must still refuse a never-begun/never-ended section.
    if [[ -n "${EGRESSLOCK_TEST_SHARDED:-}" && "${BASH_SUBSHELL:-0}" == "0" ]] \
       && ! shard_section_run "$name"; then
        return 0
    fi
    # EGL-270/G4: a section skipped on the fast track has no snapshot and
    # emits no RESULTS line — its named SKIP: line is the record; TOTAL
    # counts it via skip_summary.
    if [[ -n "${_slow_skipped[$name]:-}" ]]; then
        return 0
    fi
    local snap="${_sect_snap[$name]:-}"
    if [[ -z "$snap" ]]; then
        echo "FAIL: results_emit: '$name' has no ended snapshot (emit before end, or never begun; EGL-184 fail-closed)"
        exit 1
    fi
    local rest="${snap#*|}"
    local label="${rest%%|*}" counts="${rest#*|}"
    echo "RESULTS ($label): ${counts%%|*} passed, ${counts#*|} failed"
    _sect_emitted["$name"]=1
}
# EGL-558: additive battery record. A whole-set run.sh sets
# EGRESSLOCK_TEST_BATTERY_RESULT to a private per-harness path; the harness
# publishes the same tab schema EGL-451 uses for shards (pass/fail/ext
# counters, skips, skip_cause rows, tree) and the runner sums the records
# into its closing BATTERY TOTAL block. Record-in-addition-to-print: the
# per-harness `RESULTS TOTAL:` line stays byte-identical in every mode
# (EGL-451's shard branch below replaces the print, hence the separate
# call site). Write-then-rename keeps a killed harness from leaving a
# partial record the runner could mistake for a complete one (EGL-451).
battery_result_publish() { # <pass> <fail> [ext_pass] [ext_fail]
    [[ -n "${EGRESSLOCK_TEST_BATTERY_RESULT:-}" ]] || return 0
    local b_pass="$1" b_fail="$2" b_ep="${3:-0}" b_ef="${4:-0}"
    local b_rf="$EGRESSLOCK_TEST_BATTERY_RESULT"
    local b_tmp="$b_rf.tmp.$$"
    local b_cause
    if ! {
        printf 'pass\t%s\n' "$b_pass"
        printf 'fail\t%s\n' "$b_fail"
        printf 'ext_pass\t%s\n' "$b_ep"
        printf 'ext_fail\t%s\n' "$b_ef"
        printf 'skips\t%s\n' "$skip_count"
        for b_cause in "${!skip_causes[@]}"; do
            printf 'skip_cause\t%s\t%s\n' "$b_cause" "${skip_causes[$b_cause]}"
        done
        printf 'tree\t%s\n' "$(tree_shape_tag)"
    } > "$b_tmp"; then
        echo "FAIL: battery_result_publish: cannot write battery result '$b_tmp' (EGL-558 fail-closed)"
        exit 1
    fi
    if ! mv -f -- "$b_tmp" "$b_rf"; then
        echo "FAIL: battery_result_publish: cannot publish battery result '$b_rf' (EGL-558 fail-closed)"
        exit 1
    fi
}

results_total() { # results_total [ext_pass] [ext_fail] — declared raw-counter externals (engine arc14)
    local ext_pass="${1:-0}" ext_fail="${2:-0}"
    if [[ ! "$ext_pass" =~ ^[0-9]+$ || ! "$ext_fail" =~ ^[0-9]+$ ]]; then
        echo "FAIL: results_total: external counters must be numeric (got '$ext_pass', '$ext_fail'; EGL-184 fail-closed)"
        exit 1
    fi
    if [[ -n "$_sect_open_cur" ]]; then
        echo "FAIL: results_total: section '$_sect_open_cur' still open (begun, never ended; EGL-184 fail-closed) — TOTAL refused"
        exit 1
    fi
    if (( _sect_stray != 0 )); then
        echo "FAIL: results_total: $_sect_stray check/assert increment(s) outside any section (stray; EGL-184 fail-closed) — TOTAL refused"
        exit 1
    fi
    if (( _sect_grand_pass != _sect_booked_pass || _sect_grand_fail != _sect_booked_fail )); then
        echo "FAIL: results_total: grand accumulator ($_sect_grand_pass passed, $_sect_grand_fail failed) disagrees with booked snapshots ($_sect_booked_pass passed, $_sect_booked_fail failed) — an increment ran outside every ended section (EGL-184 fail-closed) — TOTAL refused"
        exit 1
    fi
    # EGL-451-F3: a shard must prove every section in its selection produced
    # its pinned RESULTS line. Without this a misspelled/missing
    # `results_emit <name>` is a silent evidence omission: the section's
    # counters still enter TOTAL from the ended snapshot while no RESULTS
    # line names them. The unsharded path needs no check — its RESULTS set
    # is the whole file. Slow-skipped sections are the one legitimate
    # no-emit case (their named SKIP line is the record).
    if [[ -n "${EGRESSLOCK_TEST_SHARDED:-}" && "${BASH_SUBSHELL:-0}" == "0" ]]; then
        local _want
        for _want in ${EGRESSLOCK_TEST_SECTIONS:-}; do
            [[ -n "${_slow_skipped[$_want]:-}" ]] && continue
            if [[ -z "${_sect_snap[$_want]:-}" ]]; then
                echo "FAIL: results_total: selected section '$_want' never began (EGL-451 fail-closed) — TOTAL refused"
                exit 1
            fi
            if [[ -z "${_sect_emitted[$_want]:-}" ]]; then
                echo "FAIL: results_total: selected section '$_want' produced no RESULTS line (misspelled or missing results_emit; EGL-451 fail-closed) — TOTAL refused"
                exit 1
            fi
        done
    fi
    local counted_pass=0 counted_fail=0 name snap rest mode counts
    for name in "${!_sect_snap[@]}"; do
        snap="${_sect_snap[$name]}"
        mode="${snap%%|*}"; rest="${snap#*|}"; counts="${rest#*|}"
        if [[ "$mode" == counted ]]; then
            counted_pass=$((counted_pass + ${counts%%|*}))
            counted_fail=$((counted_fail + ${counts#*|}))
        fi
    done
    total_pass=$((counted_pass + ext_pass))
    total_fail=$((counted_fail + ext_fail))
    # EGL-558: publish the battery record before the shard branch can
    # return — it is additive to the printed TOTAL below, never a
    # replacement for it.
    battery_result_publish "$counted_pass" "$counted_fail" "$ext_pass" "$ext_fail"
    # EGL-451-D5: in a multi-shard run each harness writes its counters and
    # skip causes to a private file; the parent replays the logs in shard
    # order, sums them, and prints the single pinned TOTAL line. A single
    # debug shard (--shard N/M) leaves this unset and prints its own
    # partial TOTAL. Write-then-rename keeps a killed shard from leaving a
    # half result the parent could mistake for a complete one.
    if [[ -n "${EGRESSLOCK_TEST_SHARD_RESULT:-}" ]]; then
        local _rf="$EGRESSLOCK_TEST_SHARD_RESULT"
        local _rtmp="$EGRESSLOCK_TEST_SHARD_RESULT.tmp.$$"
        local _cause
        if ! {
            printf 'pass\t%s\n' "$counted_pass"
            printf 'fail\t%s\n' "$counted_fail"
            printf 'ext_pass\t%s\n' "$ext_pass"
            printf 'ext_fail\t%s\n' "$ext_fail"
            printf 'skips\t%s\n' "$skip_count"
            for _cause in "${!skip_causes[@]}"; do
                printf 'skip_cause\t%s\t%s\n' "$_cause" "${skip_causes[$_cause]}"
            done
            printf 'tree\t%s\n' "$(tree_shape_tag)"
        } > "$_rtmp"; then
            echo "FAIL: results_total: cannot write shard result '$_rtmp' (EGL-451 fail-closed)"
            exit 1
        fi
        if ! mv -f -- "$_rtmp" "$_rf"; then
            echo "FAIL: results_total: cannot publish shard result '$_rf' (EGL-451 fail-closed)"
            exit 1
        fi
        return 0
    fi
    echo "RESULTS TOTAL: $total_pass passed, $total_fail failed$(skip_summary) ($(tree_shape_tag))"
}

# --- EGL-352: harness stderr tripwire -------------------------------------
# A green harness run must write nothing to its own fd 2. tests/run.sh
# merges stdout+stderr through `tee`, so an escaped engine/mock diagnostic
# is invisible as a failure yet reads as an error in the run output. Each
# harness process opts in after `source tests/lib.sh` and its PATH setup:
# harness_stderr_guard_init saves fd 2 to $TESTROOT/harness-stderr.log and
# extends the EXIT trap, the tail calls harness_stderr_guard_check (engine/
# kit: a fail-only counted `egl352_guard` section, so TOTAL reds without a
# green count) or harness_stderr_guard_assert (docs: its own counter),
# and the trap reports an early exit or growth after the tail check. The
# check is unconditional (never behind shard_section_run): the engine
# shards into up to three test-engine.sh processes, so every process must
# watch its own fd 2. `egl352_guard` is begun only here, from lib.sh —
# a column-0 `section_begin` in a harness would join --list-sections.
# Dump lines go to fd 1 (never fd 2, or the guard captures itself) and
# are prefixed so escaped text cannot read as a SKIP:/RESULTS/boundary
# record. No bypass: a `bash -x` trace also trips the guard by design.
_egl352_guard_armed=""
_egl352_guard_log=""
_egl352_guard_tail_checked=""
_egl352_guard_tail_size=0

harness_stderr_guard_dump() { # <path> — prefixed, capped dump to fd 1
    local path="${1:-}" line n=0 extra=0
    [[ -f "$path" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        if (( n <= 200 )); then
            printf '  harness stderr| %s\n' "$line"
        else
            extra=$((extra + 1))
        fi
    done < "$path"
    if (( extra > 0 )); then
        printf '  harness stderr| ... %d more line(s) not shown (EGL-352 dump cap 200)\n' "$extra"
    fi
}

harness_stderr_guard_init() { # arm fd 2 capture for this harness process
    [[ -z "$_egl352_guard_armed" ]] || return 0
    _egl352_guard_log="$TESTROOT/harness-stderr.log"
    if ! : > "$_egl352_guard_log"; then
        echo "FAIL: harness_stderr_guard_init: cannot create $_egl352_guard_log (EGL-352 fail-closed)"
        exit 1
    fi
    _egl352_guard_armed=1
    exec 2>"$_egl352_guard_log"
    trap 'harness_stderr_guard_exit' EXIT
}

harness_stderr_guard_assert() { # [path] — pure check; no counters
    local path="${1:-${_egl352_guard_log:-$TESTROOT/harness-stderr.log}}"
    local size=0 rc=0
    if [[ ! -f "$path" ]]; then
        printf 'FAIL: harness stderr guard: capture file is missing (%s; EGL-352 fail-closed)\n' "$path"
        rc=1
    else
        size="$(wc -c < "$path" 2>/dev/null)" || size=0
        if (( size == 0 )); then
            printf 'PASS: harness stderr is clean (EGL-352)\n'
        else
            printf 'FAIL: harness stderr is not empty (EGL-352)\n'
            harness_stderr_guard_dump "$path"
            rc=1
        fi
    fi
    # The tail check marks the armed capture; controls pass explicit paths
    # and must not disturb the harness's own late-growth window.
    if [[ -n "$_egl352_guard_armed" && "$path" == "$_egl352_guard_log" ]]; then
        _egl352_guard_tail_checked=1
        _egl352_guard_tail_size="$size"
    fi
    return "$rc"
}

harness_stderr_guard_check() { # engine/kit tail wrapper: book a leak, red TOTAL
    if harness_stderr_guard_assert; then
        return 0
    fi
    section_begin egl352_guard "EGL-352 harness stderr guard"
    assert fail "harness stderr guard: this process wrote to its own fd 2 (EGL-352)"
    section_end egl352_guard
    results_emit egl352_guard
    return 1
}

harness_stderr_guard_exit() { # EXIT trap: early-exit dump, late-growth rc
    local rc=$?
    local log="$_egl352_guard_log" size=0
    if [[ -n "$_egl352_guard_armed" && -f "$log" ]]; then
        size="$(wc -c < "$log" 2>/dev/null)" || size=0
        if [[ -z "$_egl352_guard_tail_checked" ]]; then
            if (( size > 0 )); then
                printf 'FAIL: harness stderr was written before the tail check\n'
                harness_stderr_guard_dump "$log"
                rc=1
            fi
        elif (( size > _egl352_guard_tail_size )); then
            printf 'FAIL: harness stderr grew after the tail check\n'
            harness_stderr_guard_dump "$log"
            rc=1
        fi
    fi
    rm -rf "$TESTROOT" 2>/dev/null || true
    exit "$rc"
}