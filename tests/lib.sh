# tests/lib.sh — shared mock environment for the engine and consumer test
# harnesses (ARC-15). Mocks podman, nft and getent to emulate rootless-
# netns state transitions (netns/policy destroyed when the last container
# stops, nft listings with counters). No root, Podman or nftables needed.
#
# Callers may set beforehand: EGRESSLOCK_PROFILES (engine binary; default
# <tree-root>/egresslock), AGENT_RUN (consumer wrapper; default unset),
# ARCMOCK_DNS_BASE (base DNS mapping "host=ip,host=ip"; the engine harness
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

TESTROOT="$(mktemp -d /tmp/egresslock-test.XXXXXX)"
# EGL-246 launcher note: deliberately NO battery-wide `egresslock` PATH
# launcher. Both harnesses put the tree root on PATH at their top
# (`export PATH="$TESTROOT/bin:$TREE_ROOT:$PATH"`); the egl246 section
# owns a SECTION-LOCAL absolute launcher for its PATH-shimmed legs.
trap 'rm -rf "$TESTROOT"' EXIT
STATE="$TESTROOT/state"
export ARCMOCK_STATE="$STATE"
mkdir -p "$STATE/nft" "$STATE/networks" "$STATE/running" "$STATE/containers" "$STATE/runargs"

TREE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_RUN="${AGENT_RUN:-}"
EGRESSLOCK_PROFILES="${EGRESSLOCK_PROFILES:-$TREE_ROOT/egresslock}"

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
populated() { grep -q 'counter' "$1"; }

case "$cmd" in
    -c) shift 1; exec "$0" -f "$@" ;;  # -c -f file
    -f)
        file="$1"
        cp "$file" "$D/last-transaction.nft"
        table="$(grep -oE 'table [a-z]+ [a-z_]+' "$file" | awk '{print $3}' | head -1)"
        [[ -n "$table" ]] || { echo "mock nft: no table in $file" >&2; exit 1; }
        # Inline 'flush chain' directives apply in order first: rules of
        # the named chain are removed (the chain itself stays).
        while read -r _ _ fam tbl ch; do
            f="$D/$tbl.$ch"
            if [[ -f "$f" ]]; then
                grep -v 'counter' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
            else
                echo "Error: No such file or directory" >&2
                exit 1
            fi
        done < <(grep '^flush chain ' "$file" || true)
        # exclude 'flush chain' directive lines from chain-block parsing
        chains="$(grep -v '^flush chain ' "$file" | grep -oE 'chain [A-Za-z0-9_]+' | awk '{print $2}')"
        [[ -n "$chains" ]] || { echo "mock nft: no chain in $file" >&2; exit 1; }
        # EGL-91: cross-tool ordering probe — one summary line per -f
        # transaction into callorder.log (chains touched, flush
        # directives, rule-line count) so tests can assert policy-vs-
        # gateway-start ordering and that a first-create transaction
        # already carries rules. Existing callorder consumers are
        # grep-based and unaffected by the extra line type.
        echo "nft -f chains=$(echo "$chains" | paste -sd, -) flush=$(grep -c '^flush chain ' "$file" || true) rules=$(grep -c 'counter' "$file" || true)" \
            >> "$ARCMOCK_STATE/callorder.log"
        # Store or append each chain's own section (additive semantics).
        for ch in $chains; do
            sect="$(awk -v ch="$ch" '
                $0 ~ "^[[:space:]]*chain " ch "[[:space:]]*\\{" { inchain=1 }
                inchain { print }
                inchain && /^[[:space:]]*\}[[:space:]]*$/ { inchain=0 }
            ' "$file")"
            if [[ -f "$D/$table.$ch" ]]; then
                # Append only rule lines to the existing chain.
                # EGL-141: rule lines may also start with `iifname` (the
                # anti-spoof drop is a first-class rule line now).
                grep -E '^[[:space:]]*(ip |meta |iifname )' <<<"$sect" \
                    | sed -E 's/^[[:space:]]+//' >> "$D/$table.$ch"
            else
                printf '%s\n' "$sect" > "$D/$table.$ch"
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
        # delete table <family> <table> (ARC-54): drops every chain of
        # the table; fails when the table does not exist, or when the
        # state marker delete-table-fail is present (fail-closed drill).
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
            [[ "$found" == 1 ]] || { echo "Error: No such file or directory" >&2; exit 1; }
            exit 0
        fi
        [[ "$1" == chain && "$2" == inet ]] || { echo "mock nft: delete chain needs family" >&2; exit 2; }
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
        [[ "$1" == chain && "$2" == inet ]] || { echo "mock nft: unsupported flush $*" >&2; exit 2; }
        f="$D/$3.$4"
        if [[ ! -f "$f" ]]; then
            echo "Error: No such file or directory" >&2
            exit 1
        fi
        # Keep non-rule lines (chain/type/hook), drop rule lines.
        grep -v 'counter' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
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
                if [[ -f "$D/f-done" ]] \
                   && grep -q '^conntrack -D ' "${ARCMOCK_STATE:?}/conntrack.log" 2>/dev/null; then
                    if [[ -f "$D/fail-list-chain-after-flush" ]]; then
                        rm -f "$D/fail-list-chain-after-flush"
                        echo "Error: mock nft: netlink read of chain '$3' failed once (fail-list-chain-after-flush)" >&2
                        exit 1
                    fi
                    if [[ -f "$D/partial-list-chain-after-flush" ]]; then
                        rm -f "$D/partial-list-chain-after-flush"
                        sed -E 's/counter (drop|accept)$/counter packets 0 bytes 0 \1/; s/priority -150/priority mangle/' "$f" \
                            | awk '/\{|\}/ { print; next } { print "        " $0 }'
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
                body="$(sed -E 's/counter (drop|accept)$/counter packets 0 bytes 0 \1/; s/priority -150/priority mangle/' "$f" \
                    | awk '/\{|\}/ { print; next } { print "        " $0 }')"
                if [[ -f "$D/fail-list-chain-output-rc1" ]]; then
                    rm -f "$D/fail-list-chain-output-rc1"
                    printf '%s\n' "$body"
                    exit 1
                fi
                if [[ -f "$D/fail-list-chain-partial-rc1" ]]; then
                    rm -f "$D/fail-list-chain-partial-rc1"
                    printf '%s\n' "$body" | head -1
                    exit 1
                fi
                printf '%s\n' "$body"
                ;;
            table)
                # Keyed on the TABLE name ($2), not the family: a table
                # exists iff it has chain state files.
                found=0
                for f in "$D/$2".*; do
                    [[ -f "$f" ]] || continue
                    found=1; cat "$f"
                done
                [[ "$found" == 1 ]] || { echo "Error: No such file or directory" >&2; exit 1; }
                ;;
            ruleset)
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
                    echo "}"
                done
                ;;
        esac
        ;;
    *) echo "mock nft: unsupported op $cmd" >&2; exit 2 ;;
esac
EOF

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
        echo "testuser:x:$(id -u):0:test:$ARCMOCK_PASSWD_HOME:/bin/bash"
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
D="${ARCMOCK_STATE:?}"
[[ -d "$D/nft" && -d "$D/networks" && -d "$D/running" && -d "$D/containers" ]] \
    || mkdir -p "$D/nft" "$D/networks" "$D/running" "$D/containers"
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
                # EGL-141-D1: the bridge device token. interface= line
                # when present; hand-seeded state files (mocknet) are
                # deterministic as podman1 (the lowest slot, exactly
                # what a fresh one-network account gets). Churn tests
                # hand-edit interface= to pin re-resolution.
                mock_iface_of(){ local v; v="$(grep '^interface=' "$f" | cut -d= -f2-)"; echo "${v:-podman1}"; }
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
                echo "     \"driver\": \"$(grep '^driver=' "$f" | cut -d= -f2-)\","
                echo "     \"subnets\": ["
                # gateway= lines (in order) override the computed value so
                # gateway-mismatch scenarios are reproducible.
                mapfile -t gws < <(grep '^gateway=' "$f" | cut -d= -f2-)
                first=1
                i=0
                while IFS= read -r line; do
                    sub="${line#subnet=}"
                    [[ "$sub" == "$line" ]] && continue
                    gw="${gws[$i]:-${sub%0/24}1}"
                    [[ $first -eq 0 ]] && echo ","
                    first=0
                    echo "          {"
                    echo "               \"subnet\": \"$sub\","
                    echo "               \"gateway\": \"$gw\""
                    printf '          }'
                    i=$((i+1))
                done < <(grep '^subnet=' "$f")
                echo
                echo "     ],"
                echo "     \"ipv6_enabled\": $(grep '^ipv6_enabled=' "$f" | cut -d= -f2-)"
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
        # --format '{{.Names}}' (ARC-60 teardown --runtime sweep) also
        # lists stopped-but-registered ones (the *.net state files, which
        # is what survives a stopped/exited container in the real store).
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
        case "$fmt" in
            '{{.State.Health.Status}}')
                # Gateway health: healthy unless the test marks it sick.
                if [[ -f "$D/gateway-unhealthy" ]]; then echo "unhealthy"; else echo "healthy"; fi
                ;;
            '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')
                cat "$D/containers/$name.net" 2>/dev/null | head -1; echo ;;
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
        echo "exec $name $*" >> "$D/execlog"
        # EGL-283: model podman's own exec failure (container stopped or
        # mid-restart — e.g. a concurrent ensure) while the container
        # still lists as running, so the engine's earlier liveness check
        # passed. Podman rc 125 + the real container-state error.
        if [[ -f "$D/exec-fails-$name" || -f "$D/exec-fails" ]]; then
            echo "Error: can only create exec sessions on running containers: container state improper" >&2
            exit 125
        fi
        case "$1" in
            squid)
                # ARC-32-D1: `squid -k rotate` reopens the stdio logs;
                # model that by recreating fresh (empty) log files. The
                # rotate-fails marker exercises the engine's restore
                # path (fail open for the log, never for policy).
                if [[ "$*" == *"-k rotate"* ]]; then
                    if [[ -f "$D/rotate-fails" ]]; then
                        echo "mock squid: rotate failed" >&2
                        exit 1
                    fi
                    : > "$D/containers-$name.access.log" 2>/dev/null || true
                    : > "$D/containers-$name.cache.log" 2>/dev/null || true
                    exit 0
                fi
                # Reject if the candidate config is marked bad.
                if [[ -f "$D/allowlist-invalid" ]]; then
                    echo "mock squid: config invalid" >&2
                    exit 1
                fi
                exit 0
                ;;
            stat)
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
                echo "mock podman: unsupported stat $*" >&2
                exit 2
                ;;
            tail)
                # EGL-252: cmd_denied tail-reads the newest log bytes
                # when access.log exceeds the read cap (tail -c <N>).
                if [[ "${2:-}" == "-c" && "${4:-}" == /var/log/squid/access.log ]]; then
                    f="$D/containers-$name.access.log"
                    if [[ -f "$f" ]]; then tail -c "$3" "$f"; exit 0; fi
                    echo "tail: cannot open '$4' for reading: No such file or directory" >&2
                    exit 1
                fi
                echo "mock podman: unsupported tail $*" >&2
                exit 2
                ;;
            mv)
                # ARC-32-D1: simulate mv inside the gateway's log dir so
                # the rotated .1 generation is observable in the mock
                # state. mv outside /var/log/squid (e.g. the staged
                # squid.conf swap) stays a no-op success.
                if [[ "${2:-}" == /var/log/squid/* && "${3:-}" == /var/log/squid/* ]]; then
                    s="$D/containers-$name.${2##*/}"; d="$D/containers-$name.${3##*/}"
                    if [[ -f "$s" ]]; then
                        mv "$s" "$d"
                        exit 0
                    fi
                    echo "mv: cannot stat '$2': No such file or directory" >&2
                    exit 1
                fi
                exit 0
                ;;
            rm)
                # ARC-32-D1: simulate rm of the rotated .1 generation;
                # other paths (e.g. the staged check.conf cleanup) are
                # no-op successes.
                if [[ "${2:-}" == -f && "${3:-}" == /var/log/squid/* ]]; then
                    rm -f "$D/containers-$name.${3##*/}"
                fi
                exit 0
                ;;
            cat)
                # EGL-206-D2b: the live-hardening oracle reads PID 1's
                # /proc/1/status inside the container. Default fixture is
                # healthy (CapEff all-zero, NoNewPrivs 1 — exactly what
                # --cap-drop=all --security-opt=no-new-privileges
                # produces). Named knobs, per-container marker first then
                # the global one: caps-bad (non-zero CapEff), caps-nnp
                # (NoNewPrivs 0), caps-unreadable (exec fails — the
                # fail-closed path). Per-container form: caps-<knob>-<name>.
                if [[ "${2:-}" == /proc/1/status ]]; then
                    knob_bad=""; knob_nnp=""; knob_unreadable=""
                    [[ -f "$D/caps-bad-$name" || -f "$D/caps-bad" ]] && knob_bad=1
                    [[ -f "$D/caps-nnp-$name" || -f "$D/caps-nnp" ]] && knob_nnp=1
                    [[ -f "$D/caps-unreadable-$name" || -f "$D/caps-unreadable" ]] && knob_unreadable=1
                    if [[ -n "$knob_unreadable" ]]; then
                        echo "cat: /proc/1/status: No such file or directory" >&2
                        exit 1
                    fi
                    capseff="0000000000000000"; nnp="1"
                    [[ -n "$knob_bad" ]] && capseff="00000000000001f7"
                    [[ -n "$knob_nnp" ]] && nnp="0"
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
                # skip).
                if [[ "${2:-}" == /etc/squid/agent/* ]]; then
                    deployed="${2##*/}"
                    # The candidate is stored by its STAGING name
                    # (squid-gw.conf — podman cp records the src
                    # basename) but deployed as squid.conf (the mv
                    # swap); serve the payload under either name.
                    f="$D/containers-$name.$deployed"
                    if [[ "$deployed" == squid.conf && -f "$D/containers-$name.squid-gw.conf" ]]; then
                        f="$D/containers-$name.squid-gw.conf"
                    fi
                    if [[ -f "$f" ]]; then
                        cat "$f"
                        exit 0
                    fi
                    echo "cat: ${2}: No such file or directory" >&2
                    exit 1
                fi
                exit 0
                ;;
            bash)
                # gw_probe /dev/tcp check. EGL-217: the probe-fails knob
                # ($D/probe-fails[-<name>]) models a proxy that never
                # answers — scoped to containers STARTED or RESTARTED
                # while armed (the run/restart arms write
                # $D/probe-fails-active-<name>): the crash begins at
                # start or at config activation, never on a pre-existing
                # healthy gateway mid-ensure.
                if [[ -f "$D/probe-fails-active-$name" ]]; then
                    exit 1
                fi
                exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
    cp)
        # cp <src> <dst>: record the allowlist payload; allow tests to
        # flag invalid content.
        src="$1"; dst="$2"
        name="${dst%%:*}"; path="${dst#*:}"
        [[ -f "$D/containers/$name.net" || -f "$D/running/$name" ]] || { echo "no such container" >&2; exit 1; }
        cp "$src" "$D/allowlist-staged"
        cp "$src" "$D/containers-$name.${src##*/}"
        cp "$src" "$D/containers-$name.allowlist.last"
        exit 0
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
            echo "Error: unable to remove container $name: device or resource busy" >&2
            exit 1
        fi
        rm -f "$D/running/$name" "$D/containers/$name" \
              "$D/containers/$name.net" "$D/containers/$name.ip" \
              "$D/containers/$name.mac" "$D/probe-fails-active-$name"
        # EGL-114: a removed container's filesystem is gone — clear the
        # modeled per-container files (staged squid/allowlist payloads,
        # log fixtures) so a REPLACED gateway starts from a fresh
        # bootstrap FS, exactly like the real image (empty
        # /etc/squid/agent). The literal '.' keeps the glob prefix-safe
        # (s50 cannot match s50n's files).
        rm -f "$D/containers-$name."* 2>/dev/null || true
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
        [[ -f "$D/running/$name" ]] || { echo "no such container" >&2; exit 1; }
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
                [[ -f "$D/images/$(echo "$img" | tr '/:' '__')" ]] \
                    || { echo "Error: no such image $img" >&2; exit 1; }
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
echo "conntrack $*" >> "$LOG"
op="$1"; shift
case "$op" in
    -C)
        [[ -f "$D/conntrack-probe-fails" ]] && { echo "mock conntrack: ctnetlink unavailable" >&2; exit 1; }
        n=0
        [[ -f "$TABLE" ]] && n="$(grep -c . "$TABLE" || true)"
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
            n="$(awk -v a="$dip" -v b="$dport" -v s="$sip" -v p="$sport" '{
                    delete seen; od = ""; dport_o = ""; os = ""; sport_o = ""
                    for (i = 1; i <= NF; i++) {
                        split($i, kv, "=")
                        if (kv[1] == "src" || kv[1] == "dst" || kv[1] == "sport" || kv[1] == "dport") {
                            if (seen[kv[1]]++ == 0) {
                                if (kv[1] == "dst") od = kv[2]
                                if (kv[1] == "dport") dport_o = kv[2]
                                if (kv[1] == "src") os = kv[2]
                                if (kv[1] == "sport") sport_o = kv[2]
                            }
                        }
                    }
                    ok = 1
                    if (a != "") { if (od != a) ok = 0 }
                    if (b != "") { if (dport_o != b) ok = 0 }
                    if (s != "") { if (os != s) ok = 0 }
                    if (p != "") { if (sport_o != p) ok = 0 }
                    if (a == "" && b == "" && s == "" && p == "") ok = 0
                    if (ok) { c++ }
                } END { print c+0 }' "$TABLE")"
            awk -v a="$dip" -v b="$dport" -v s="$sip" -v p="$sport" '{
                    delete seen; od = ""; dport_o = ""; os = ""; sport_o = ""
                    for (i = 1; i <= NF; i++) {
                        split($i, kv, "=")
                        if (kv[1] == "src" || kv[1] == "dst" || kv[1] == "sport" || kv[1] == "dport") {
                            if (seen[kv[1]]++ == 0) {
                                if (kv[1] == "dst") od = kv[2]
                                if (kv[1] == "dport") dport_o = kv[2]
                                if (kv[1] == "src") os = kv[2]
                                if (kv[1] == "sport") sport_o = kv[2]
                            }
                        }
                    }
                    ok = 1
                    if (a != "") { if (od != a) ok = 0 }
                    if (b != "") { if (dport_o != b) ok = 0 }
                    if (s != "") { if (os != s) ok = 0 }
                    if (p != "") { if (sport_o != p) ok = 0 }
                    if (a == "" && b == "" && s == "" && p == "") ok = 0
                    if (ok) { next }
                    { print }
                }' "$TABLE" > "$TABLE.t" && mv "$TABLE.t" "$TABLE"
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
                orig="$(awk -v a="$dip" -v b="$dport" -v s="$sip" -v p="$sport" '{
                        delete seen; od = ""; dport_o = ""; os = ""; sport_o = ""
                        for (i = 1; i <= NF; i++) {
                            split($i, kv, "=")
                            if (kv[1] == "src" || kv[1] == "dst" || kv[1] == "sport" || kv[1] == "dport") {
                                if (seen[kv[1]]++ == 0) {
                                    if (kv[1] == "dst") od = kv[2]
                                    if (kv[1] == "dport") dport_o = kv[2]
                                    if (kv[1] == "src") os = kv[2]
                                    if (kv[1] == "sport") sport_o = kv[2]
                                }
                            }
                        }
                        ok = 1
                        if (a != "") { if (od != a) ok = 0 }
                        if (b != "") { if (dport_o != b) ok = 0 }
                        if (s != "") { if (os != s) ok = 0 }
                        if (p != "") { if (sport_o != p) ok = 0 }
                        if (a == "" && b == "" && s == "" && p == "") ok = 0
                        if (ok) { print "y"; exit }
                    }' <<<"$row")"
                if [[ "$orig" == "y" ]]; then
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

# EGL-270 (P1): per-section runtime stamps. section_end emits one
# `TIMING: <name> <n.n>s`; a slow-skipped section emits none. RESULTS text
# stays byte-identical (EGL-99).
declare -A _sect_snap=()   # name -> "mode|label|pass|fail" (ended only)
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
    echo "RESULTS TOTAL: $total_pass passed, $total_fail failed$(skip_summary) ($(tree_shape_tag))"
}