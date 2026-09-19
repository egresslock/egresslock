# tests/lib.sh — shared mock environment for the engine and
# consumer test harnesses (ARC-15).
#
# Mocks the podman, nft and getent to emulate the rootless-netns state
# transitions observed on-host (netns/policy destroyed when the last
# container stops, nft chain listings with counter expansion, etc.).
# No root, no Podman, no nftables needed.
#
# Callers source this file and may set beforehand:
#   EGRESSLOCK_PROFILES  engine binary under test (default:
#                        <tree-root>/egresslock)
#   AGENT_RUN            consumer wrapper under test (default: unset)
#   ARCMOCK_DNS_BASE  base DNS mapping "host=ip,host=ip" for the getent
#                     mock (the engine harness uses neutral example.test
#                     hosts as site data)
#
# Default paths are relative to the egresslock tree (the parent of
# tests/), so this file keeps working when the tree relocates to the
# standalone egresslock repository (ARC-74-D4).
#   EGRESSLOCK_MOCK_DNS    per-call DNS overrides (drift knob, ARC-12)
#   ARCMOCK_PASSWD_HOME  when set, the getent mock answers
#                     `getent passwd <uid>` with this home so the
#                     default-config probe's HOME fallback
#                     (confdir_default) is hermetic (ARC-24)
#   ARCMOCK_LINGER_ANSWER  loginctl mock's `show-user … Linger
#                     --value` answer (default `yes`); set `no` to
#                     exercise egresslock-setup's fail-closed linger
#                     branch (ARC-28)

set -u

TESTROOT="$(mktemp -d /tmp/egresslock-test.XXXXXX)"
trap 'rm -rf "$TESTROOT"' EXIT
STATE="$TESTROOT/state"
export ARCMOCK_STATE="$STATE"
mkdir -p "$STATE/nft" "$STATE/networks" "$STATE/running" "$STATE/containers" "$STATE/runargs"

TREE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_RUN="${AGENT_RUN:-}"
EGRESSLOCK_PROFILES="${EGRESSLOCK_PROFILES:-$TREE_ROOT/egresslock}"

# --- mocks ------------------------------------------------------------
mkdir -p "$TESTROOT/bin"
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
                grep -E '^[[:space:]]*(ip |meta )' <<<"$sect" \
                    | sed -E 's/^[[:space:]]+//' >> "$D/$table.$ch"
            else
                printf '%s\n' "$sect" > "$D/$table.$ch"
            fi
        done
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
                # Mimic real nft output: expanded counters, mangle priority
                # alias, and INDENTED body lines inside the chain.
                sed -E 's/counter (drop|accept)$/counter packets 0 bytes 0 \1/; s/priority -150/priority mangle/' "$f" \
                    | awk '/\{|\}/ { print; next } { print "        " $0 }'
                ;;
            table)
                # Keyed on the TABLE name ($2), not the family: a table
                # exists iff it has chain state files (ARC-54 uses rc +
                # output scoping to detect the legacy table precisely).
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
                    rbase="$(basename "$f")"
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
# ARC-24 HOME-fallback knob: answer `getent passwd <uid>` with the
# configured home so the default-config probe's getent fallback is
# hermetic when a test unsets HOME.
if [[ "$1" == passwd && -n "${ARCMOCK_PASSWD_HOME:-}" ]]; then
    echo "testuser:x:$(id -u):0:test:$ARCMOCK_PASSWD_HOME:/bin/bash"
    exit 0
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
# resolves". Unlisted hosts keep the base mapping.
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
ip="${BASE[$2]-}"
if [[ -n "$ip" ]]; then
    echo "$ip STREAM $2"
    exit 0
fi
exit 2
EOF

cat > "$TESTROOT/bin/podman" <<'EOF'
#!/usr/bin/env bash
# Mock podman: persistent-enough state for the egresslock flow.
set -u
D="${ARCMOCK_STATE:?}"
mkdir -p "$D/nft" "$D/networks" "$D/running" "$D/containers"
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
        exec "$@"
        ;;
    network)
        case "$1" in
            inspect)
                local_args=("$@"); name="${local_args[-1]}"
                f="$D/networks/$name"
                [[ -f "$f" ]] || { echo "Error: unable to find network" >&2; exit 1; }
                # Mimic real podman network inspect JSON (fields the
                # profile tool depends on). All subnet= lines become
                # subnet entries (real podman lists each).
                echo '['
                echo "     \"name\": \"$name\","
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
                    for f in "$D/networks"/*; do [[ -f "$f" ]] && basename "$f"; done
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
        name=""; net=""; ip=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --name) name="$2"; shift 2 ;;
                --network) net="$2"; shift 2 ;;
                --network=*) net="${1#--network=}"; shift ;;
                --ip) ip="$2"; shift 2 ;;
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
        : > "$D/running/$name"
        echo "$net" > "$D/containers/$name.net"
        [[ -n "$ip" ]] && { echo "$ip" > "$D/containers/$name.ip"; echo "$name" > "$D/ips/$ip"; }
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
            ps_seen[$(basename "$f")]=1
            basename "$f"
        done
        if [[ "${1:-}" == "-a" ]]; then
            for f in "$D/containers"/*.net; do
                [[ -f "$f" ]] || continue
                n="$(basename "$f" .net)"
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
                # ARC-7: cmd_denied reads the gateway's access log.
                [[ "${2:-}" == /var/log/squid/access.log ]] \
                    && cat "$D/containers-$name.access.log" 2>/dev/null || true
                exit 0
                ;;
            bash) exit 0 ;;   # gw_probe /dev/tcp check
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
        cp "$src" "$D/containers-$name.$(basename "$src")"
        cp "$src" "$D/containers-$name.allowlist.last"
        exit 0
        ;;
    rm)
        # rm [-f] [-t N] <name>: remove container state, releasing any
        # IPAM allocation it holds. ARC-69: $D/rm-container-fails makes
        # the rm fail like a real stuck removal would.
        name=""
        while [[ $# -gt 0 ]]; do
            case "$1" in -*) ;; *) name="$1"; break ;; esac
            shift
        done
        if [[ -f "$D/rm-container-fails" ]]; then
            echo "Error: unable to remove container $name: device or resource busy" >&2
            exit 1
        fi
        rm -f "$D/running/$name" "$D/containers/$name" \
              "$D/containers/$name.net" "$D/containers/$name.ip"
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
        name=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -t) shift 2 ;;
                -*) shift ;;
                *) name="$1"; break ;;
            esac
        done
        [[ -f "$D/running/$name" ]] || { echo "no such container" >&2; exit 1; }
        exit 0
        ;;
    image)
        # image exists <name>: gateway image must exist once built.
        [[ "$1" == exists ]] || exit 1
        [[ -f "$D/images/$(echo "$2" | tr '/:' '__')" ]] && exit 0
        exit 1
        ;;
    build)
        # build [-t tag] ... <context>: record the build; a -t tag makes
        # the image exist (ARC-16-D6 gateway self-provision). EGL-51:
        # mirrored into callorder.log for cross-tool ordering asserts.
        echo "build $*" >> "$D/buildlog"
        echo "podman build $*" >> "$D/callorder.log"
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
    *) echo "mock podman: unsupported op $cmd" >&2; exit 2 ;;
esac
EOF
# EGL-80-L1: hermetic dpkg-query — the host dpkg database must not leak
# into the harness. On a host where the egresslock .deb is installed,
# install-kit's real dpkg-query call answered "install ok installed" and
# its ARC-22-D1 refusal failed ~30 prefix-install tests. Mock emulates
# dpkg-query for an UNKNOWN package: rc 1, no stdout (exactly what the
# real tool prints for a package it does not know), so install-kit's
# `deb_status` is empty and it proceeds. Tests that need an
# installed-deb answer (the p43 refusal case) stub their own dpkg-query
# earlier on PATH and still win.
cat > "$TESTROOT/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
# EGL-80-L1 mock: egresslock is never installed in the harness world.
exit 1
EOF

chmod +x "$TESTROOT/bin/nft" "$TESTROOT/bin/getent" "$TESTROOT/bin/podman" \
         "$TESTROOT/bin/dpkg-query" "$EGRESSLOCK_PROFILES"

# Mock systemctl for kit-install tests (ARC-16): records every call.
# EGL-51: every call is also mirrored into callorder.log so tests can
# assert cross-tool ordering (loginctl enable-linger → systemctl start
# user@ → podman build). The marker file systemctl-usermgr-fails makes
# the user-manager liveness probe (`is-active --quiet user@…`) exit 3
# the way an inactive user@<uid>.service would.
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
if [[ -f "$D/systemctl-timer-off" && "$*" == "is-enabled --quiet egresslock-verify@"* ]]; then
    exit 1
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
if [[ "$1" == "list-units" ]]; then
    [[ -f "$D/systemctl-list-units" ]] && cat "$D/systemctl-list-units"
    exit 0
fi
exit 0
EOF
chmod +x "$TESTROOT/bin/systemctl"

# Mock loginctl (ARC-28): records every call; show-user Linger -> yes so
# the --enable linger check passes in the harness (override with
# ARCMOCK_LINGER_ANSWER=no to exercise the fail-closed branch). EGL-51:
# calls are mirrored into callorder.log (see systemctl mock above).
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
export USER="testuser"
export EGRESSLOCK_ANCHOR_IMAGE="docker.io/library/alpine:latest"
export AGENTS_ROOT="$TESTROOT/agents"
# EGL-80-L2: the kit's deb-shape guard must not see the host's real
# /usr/bin/egresslock (present on deployed hosts; the .deb's engine is
# not a kit PATH wrapper, so install-kit would refuse). Default to an
# absent path; tests that exercise the refusal point the hook at a
# fixture file.
export EGRESSLOCK_UB_BIN="$TESTROOT/ub/egresslock"
# EGL-80-1-F1 note: EGRESSLOCK_PATH_BINDIR/SBINDIR are deliberately NOT
# defaulted here. The battery installs many distinct prefixes; a single
# shared wrapper dir would trip install-kit's ARC-22-D1 foreign-marker
# refusal ("two prefix installs must not fight over PATH"). Instead,
# every install-kit/uninstall-kit test invocation sets explicit
# per-prefix wrapper hooks (grep EGRESSLOCK_PATH_BINDIR in
# tests/test-kit.sh).
# Gateway image exists in the mock (created below); keep the real default
# name so the ensure flow exercises the image-exists check.
mkdir -p "$STATE/images"
: > "$STATE/images/localhost_egresslock-gateway_latest"

pass=0; fail=0
check() { # check <desc> <rc-expected> <cmd...>
    local desc="$1" want="$2"; shift 2
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    if [[ "$got" == "$want" ]]; then
        pass=$((pass+1)); echo "PASS: $desc"
    else
        fail=$((fail+1)); echo "FAIL: $desc (want rc=$want, got rc=$got)"
    fi
}
check_out() { # check_out <desc> <expected-substring> <cmd...>
    local desc="$1" want="$2"; shift 2
    if "$@" 2>/dev/null | grep -qF "$want"; then
        pass=$((pass+1)); echo "PASS: $desc"
    else
        fail=$((fail+1)); echo "FAIL: $desc (output missing '$want')"
    fi
}