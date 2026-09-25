#!/usr/bin/env bash
#
# Engine-only tests for egresslock (ARC-15): config validation,
# config-only profiles, subnet hygiene (ARC-11), DNS drift (ARC-12),
# site-default hygiene (ARC-14), and the deep state-semantics battery
# (tamper/re-ensure, v6deny, gateway death/recovery, rule order —
# ARC-74 relocation). All fixtures are synthetic (neutral example.test
# hosts, docs-range IPs) so this tree can relocate to the public
# egresslock repo (ARC-13-D5). Consumer harnesses live with their
# consumers (see the repository AGENTS.md Testing section); this tree
# must not reference them.
#
# Run:  bash tests/run.sh   (or this file directly)


export ARCMOCK_DNS_BASE="git.example.test=192.0.2.10,gitXexample.test=192.0.2.12,cache.example.test=192.0.2.11"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
export PATH="$TESTROOT/bin:$TREE_ROOT:$PATH"

# Run a command with stdout attached to a PTY (script(1)). The probe
# hint used to be TTY-gated (ARC-45); EGL-117-D1 lifted that gate for
# the resolution lines (they print every time now), so the PTY is no
# longer required for disclosure — the helper stays for any future
# TTY-shaped assert and keeps these call sites working unchanged.
# EGL-78-1-F1: script's stdin is cut off from the caller's terminal
# (</dev/null). With a live TTY stdin, script's stdin-relay has no EOF
# and can block forever after the child exits (interactive-run wedge);
# the child still gets a PTY on both fds, so TTY-gated behavior is
# unchanged — only script's own stdin-relay gets immediate EOF.
pty() { script -qec "$1" /dev/null </dev/null; }

pass=0; fail=0

# --- config validation (ARC-8 engine-specific, synthetic fixtures) -------
# --config activates the engine; validation errors exit 2.


mkdir -p "$TESTROOT/validconf"
printf 'profile v 10.50.9.0/24\n' > "$TESTROOT/validconf/ok.conf"
check "--config flag works" 0 env EGRESSLOCK_CONF=/nonexistent \
    egresslock --config "$TESTROOT/validconf/ok.conf" list
check "EGRESSLOCK_CONF env works" 0 env EGRESSLOCK_CONF="$TESTROOT/validconf/ok.conf" \
    egresslock list
check "--config=<file> form works" 0 egresslock --config="$TESTROOT/validconf/ok.conf" list

# Every config-validation failure must exit 2 with a useful message.
bad_config() { # bad_config <name> <content> <expected-message-substring>
    local dir="$TESTROOT/badconf"
    mkdir -p "$dir"
    printf '%s\n' "$2" > "$dir/$1.conf"
    local out rc=0
    out="$(egresslock --config "$dir/$1.conf" list 2>&1)" || rc=$?
    if [[ "$rc" == 2 && "$out" == *"$1.conf:"* && "$out" == *"$3"* ]]; then
        pass=$((pass+1)); echo "PASS: bad config rejected: $1"
    else
        fail=$((fail+1)); echo "FAIL: bad config '$1' (rc=$rc, msg: $out)"
    fi
}

bad_config dup-name \
    $'profile a 10.50.0.0/24\nprofile a 10.50.1.0/24' \
    "duplicate profile name 'a'"
bad_config subnet-overlap \
    $'profile a 10.50.0.0/24\nprofile b 10.50.0.0/24' \
    "overlaps an earlier profile"
bad_config subnet-overlap-nested \
    $'profile a 10.50.0.0/16\nprofile b 10.50.1.0/24' \
    "overlaps an earlier profile"
bad_config subnet-overlap-nested-rev \
    $'profile a 10.50.0.0/24\nprofile b 10.50.0.0/16' \
    "overlaps an earlier profile"
bad_config subnet-octet \
    'profile a 256.50.0.0/24' "expected IPv4 CIDR"
bad_config subnet-prefixlen-30 \
    'profile a 10.50.0.0/30' "prefix length must be between 8 and 29"
bad_config subnet-prefixlen-7 \
    'profile a 10.0.0.0/7' "prefix length must be between 8 and 29"
bad_config subnet-prefixlen-32 \
    'profile a 10.50.0.5/32' "prefix length must be between 8 and 29"
bad_config subnet-host-bits \
    'profile a 10.50.0.1/24' "canonical network address"
bad_config subnet-ipv6 \
    'profile a fd00::/24' "invalid subnet"
# R-011-1 finding 3: leading-zero octets (octal arithmetic hazard).
bad_config subnet-leading-zero \
    'profile a 10.010.0.0/24' "expected IPv4 CIDR"
bad_config subnet-leading-zero-gw \
    $'profile a 10.50.0.0/24\n    rule gateway-only\n    gateway 10.50.0.010 3128 a' \
    "invalid gateway IP '10.50.0.010'"
bad_config creds-leftover \
    $'profile a 10.50.0.0/24\n    creds no' \
    "the 'creds' directive was removed"
bad_config creds-leftover-outside \
    'creds yes' "the 'creds' directive was removed"
# missing creds must now be ACCEPTED (ARC-11-D4) — assert directly:
mkdir -p "$TESTROOT/badconf"
printf 'profile a 10.50.0.0/24\n' > "$TESTROOT/badconf/missing-creds-ok.conf"
check "missing creds directive is now OK" 0 \
    egresslock --config "$TESTROOT/badconf/missing-creds-ok.conf" list
bad_config gw-only-no-gw \
    $'profile a 10.50.0.0/24\n    rule gateway-only' \
    "no 'gateway' directive"
bad_config pub-plus-allowhost \
    $'profile a 10.50.0.0/24\n    rule public-only\n    rule allow-host git.example.test:443' \
    "public-only combined with allow-host"
bad_config pub-plus-gw \
    $'profile a 10.50.0.0/24\n    rule public-only\n    gateway 10.50.0.2 3128 a' \
    "public-only combined with gateway"
bad_config bad-host \
    $'profile a 10.50.0.0/24\n    rule allow-host bad~host:443' \
    "invalid host name"
bad_config bad-port \
    $'profile a 10.50.0.0/24\n    rule allow-host git.example.test:70000' \
    "invalid port '70000'"
bad_config gw-outside-subnet \
    $'profile a 10.50.0.0/24\n    rule gateway-only\n    gateway 10.60.0.2 3128 a' \
    "outside the usable range"
bad_config gw-is-bridge-gateway \
    $'profile a 10.50.0.0/24\n    rule gateway-only\n    gateway 10.50.0.1 3128 a' \
    "outside the usable range"
bad_config gw-is-anchor \
    $'profile a 10.50.0.0/24\n    rule gateway-only\n    gateway 10.50.0.254 3128 a' \
    "outside the usable range"
bad_config gw-is-network \
    $'profile a 10.50.0.0/24\n    rule gateway-only\n    gateway 10.50.0.0 3128 a' \
    "outside the usable range"
bad_config gw-bad-ip \
    $'profile a 10.50.0.0/24\n    rule gateway-only\n    gateway not-an-ip 3128 a' \
    "invalid gateway IP"
bad_config unknown-directive \
    $'profile a 10.50.0.0/24\n    frobnicate yes' \
    "unknown directive"
bad_config unknown-rule-kind \
    $'profile a 10.50.0.0/24\n    rule teleport' \
    "unknown rule kind"
bad_config no-profiles \
    '# nothing here' "config defines no profiles"
bad_config unset-env-no-default \
    $'profile a 10.50.0.0/24\n    rule allow-host ${ARC8_UNSET_VAR}:443' \
    "unset and has no default"

# --- config-only profile (ARC-7 shape, neutralized) ----------------------
# New profile WITHOUT any tool edit: allow-host rules plus a gateway with
# an EMPTY per-profile allowlist — config-only addition.

# New profile WITHOUT any tool edit (ARC-7 shape): allow-host rules plus a
# gateway with an EMPTY per-profile allowlist — config-only addition.
NPDIR="$TESTROOT/newprof"
mkdir -p "$NPDIR"
: > "$NPDIR/ci-allowlist"
cat > "$NPDIR/ci.conf" <<'EOF'
profile ci 10.94.7.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
    rule gateway-only
    gateway 10.94.7.2 3128 ci-allowlist
EOF
npc() { env EGRESSLOCK_CONF="$NPDIR/ci.conf" egresslock "$@"; }
check "config-only profile: list" 0 npc list
check_out "config-only profile listed" "ci" npc list
check "config-only profile: ensure" 0 npc ensure ci
check "config-only profile: verify" 0 npc verify ci
check "config-only gateway running" 0 test -f "$STATE/running/egresslock-gateway-ci"
check_out "config-only gateway at static IP" "10.94.7.2" \
    cat "$STATE/containers/egresslock-gateway-ci.ip"
check_out "config-only allow-host compiled" "daddr 192.0.2.10 tcp dport 443" \
    cat "$STATE/nft/egresslock.p_ci"
check "config-only profile: teardown" 0 npc teardown ci
check "config-only teardown removed gateway" 1 test -f "$STATE/running/egresslock-gateway-ci"

extra_pass=$pass; extra_fail=$fail


# --- ARC-11: subnet hygiene ----------------------------------------------
pass=0; fail=0
A11="$TESTROOT/arc11"
mkdir -p "$A11"
a11() { env EGRESSLOCK_CONF="$A11/$1" egresslock "${@:2}"; }

# 1. Podman overlap pre-check: a colliding network (even a foreign one)
#    fails ensure with remediation, not the raw create error.
: > "$A11/allow"
cat > "$A11/overlap.conf" <<'EOF'
profile ov 10.77.0.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
EOF
mkdir -p "$STATE/networks"
printf 'driver=bridge\nsubnet=10.77.0.0/24\ngateway=10.77.0.1\nipv6_enabled=false\n' > "$STATE/networks/someone-elses-net"
ov_out="$(a11 overlap.conf ensure ov 2>&1)"; ov_rc=$?
if [[ "$ov_rc" == 1 && "$ov_out" == *"overlaps existing Podman network 'someone-elses-net'"* \
      && "$ov_out" == *"podman network rm"* ]]; then
    pass=$((pass+1)); echo "PASS: ensure fails closed on overlapping foreign network (with remediation)"
else
    fail=$((fail+1)); echo "FAIL: overlap pre-check (rc=$ov_rc, out: $ov_out)"
fi
# Own network is not a collision; after removing the foreign net, ensure works.
rm -f "$STATE/networks/someone-elses-net"
check "ensure succeeds once foreign network removed" 0 a11 overlap.conf ensure ov
check "overlap profile: verify" 0 a11 overlap.conf verify ov
# Re-ensure with the profile network existing must NOT self-collide.
check "re-ensure own network is not a collision" 0 a11 overlap.conf ensure ov

# 1b. R-011-1 finding 1: a foreign subnet outside prefixlen 8-29 nested
#     inside the profile's range must still fail the scan (relaxed
#     parse), not be silently skipped.
printf 'driver=bridge\nsubnet=10.77.0.128/30\ngateway=10.77.0.129\nipv6_enabled=false\n' > "$STATE/networks/tiny-foreign"
ov_out="$(a11 overlap.conf ensure ov 2>&1)"; ov_rc=$?
if [[ "$ov_rc" == 1 && "$ov_out" == *"overlaps existing Podman network 'tiny-foreign'"* ]]; then
    pass=$((pass+1)); echo "PASS: foreign /30 nested in profile range fails ensure"
else
    fail=$((fail+1)); echo "FAIL: tiny-prefix foreign subnet slipped the scan (rc=$ov_rc, out: $ov_out)"
fi
rm -f "$STATE/networks/tiny-foreign"

# 2. Nested in-file overlap already covered by bad_config (identical,
#    /16 vs /24, /24 vs /16). Prefix validation cases: /30 /7 /32
#    host-bits ipv6 (bad_config above). Here: a non-/24 profile end to end.
: > "$A11/allow28"
cat > "$A11/sub28.conf" <<'EOF'
profile sub28 10.78.0.16/28
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
    rule gateway-only
    gateway 10.78.0.18 3128 allow28
EOF
check "28-prefix profile: list" 0 a11 sub28.conf list
check_out "28-prefix profile listed with canonical subnet" "10.78.0.16/28" a11 sub28.conf list
check "28-prefix profile: ensure" 0 a11 sub28.conf ensure sub28
check "28-prefix profile: verify" 0 a11 sub28.conf verify sub28
# Bridge gateway = first usable (10.78.0.17); anchor = last usable (10.78.0.30);
# static squid gateway accepted at 10.78.0.18 (strictly between).
check_out "28-prefix: gateway container at .18" "10.78.0.18" \
    cat "$STATE/containers/egresslock-gateway-sub28.ip"
check_out "28-prefix: anchor at last usable .30" "10.78.0.30" \
    cat "$STATE/containers/egresslock-anchor-sub28.ip"
grep -q 'ip saddr 10.78.0.16/28 iifname "podman1" ip daddr 10.78.0.17' "$STATE/nft/egresslock.p_sub28" \
    && { pass=$((pass+1)); echo "PASS: 28-prefix DNS allow targets first usable"; } \
    || { fail=$((fail+1)); echo "FAIL: 28-prefix DNS allow gateway wrong"; }
# Anchor/gateway address exclusion: 10.78.0.17 (bridge gw) as static gw.
bad_config sub28-gw-eq-bridge \
    $'profile a 10.78.0.16/28\n    rule gateway-only\n    gateway 10.78.0.17 3128 allow28' \
    "outside the usable range"
# Teardown for cleanliness.
check "28-prefix profile: teardown" 0 a11 sub28.conf teardown sub28

arc11_pass=$pass; arc11_fail=$fail


# --- ARC-12: stale-DNS drift check ----------------------------------------
pass=0; fail=0
A12="$TESTROOT/arc12"
mkdir -p "$A12"
: > "$A12/allow"
cat > "$A12/drift.conf" <<'EOF'
profile dr 10.79.0.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
    rule allow-host ${FORGEJO_HOST:-git.example.test}:2222
    rule allow-host ${OLLAMA_HOST:-cache.example.test}:11434
EOF
drc() { env EGRESSLOCK_CONF="$A12/drift.conf" egresslock "$@"; }

# Baseline: ensure + verify with the base DNS mapping; verify silent.
check "drift profile: ensure" 0 drc ensure dr
v_out="$(drc verify dr 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" != *"drift:"* ]]; then
    pass=$((pass+1)); echo "PASS: no-drift verify is silent and passes"
else
    fail=$((fail+1)); echo "FAIL: no-drift verify (rc=$v_rc, out: $v_out)"
fi

# Drifted first-A: forgejo now resolves elsewhere. verify must exit 0,
# warn with old and new, and the live chain must KEEP the old pin.
export EGRESSLOCK_MOCK_DNS="git.example.test=192.0.2.99"
v_out="$(drc verify dr 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" == *"drift: host git.example.test resolved to 192.0.2.99 but the policy pins 192.0.2.10"* ]] \
   && [[ "$(grep -c 'drift:' <<<"$v_out")" == 1 ]]; then
    pass=$((pass+1)); echo "PASS: drifted verify warns once (per host) and exits 0"
else
    fail=$((fail+1)); echo "FAIL: drifted verify (rc=$v_rc, out: $v_out)"
fi
grep -q 'daddr 192.0.2.10 tcp dport 443' "$STATE/nft/egresslock.p_dr" \
    && { pass=$((pass+1)); echo "PASS: drift did not mutate the policy"; } \
    || { fail=$((fail+1)); echo "FAIL: drift check changed the pinned policy"; }
# Unresolvable host at verify: distinct warn, exit 0, pin kept.
export EGRESSLOCK_MOCK_DNS="git.example.test="
v_out="$(drc verify dr 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" == *"drift: host git.example.test no longer resolves; policy still pins 192.0.2.10"* ]]; then
    pass=$((pass+1)); echo "PASS: unresolvable host warns, exits 0"
else
    fail=$((fail+1)); echo "FAIL: unresolvable-at-verify (rc=$v_rc, out: $v_out)"
fi
unset EGRESSLOCK_MOCK_DNS

# ensure after a drift: heals and announces; subsequent verify silent.
export EGRESSLOCK_MOCK_DNS="git.example.test=192.0.2.99"
e_out="$(drc ensure dr 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 && "$e_out" == *"refreshed: host git.example.test 192.0.2.10 -> 192.0.2.99"* ]]; then
    pass=$((pass+1)); echo "PASS: ensure announces the refreshed host"
else
    fail=$((fail+1)); echo "FAIL: ensure refresh announce (rc=$e_rc, out: $e_out)"
fi
# R-012-1 F1: exactly ONE announce line per drifted HOST (forgejo has
# two allow-host ports; a naive per-port loop prints two lines).
announced_count="$(grep -c 'refreshed: host git.example.test' <<<"$e_out")"
if [[ "$announced_count" == 1 ]]; then
    pass=$((pass+1)); echo "PASS: one refreshed line per drifted host (not per port)"
else
    fail=$((fail+1)); echo "FAIL: refreshed announce count=$announced_count (want 1)"
fi
v_out="$(drc verify dr 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" != *"drift:"* ]]; then
    pass=$((pass+1)); echo "PASS: verify silent after the heal"
else
    fail=$((fail+1)); echo "FAIL: verify after heal (rc=$v_rc, out: $v_out)"
fi
# Unresolvable at ENSURE still fails closed.
export EGRESSLOCK_MOCK_DNS="git.example.test="
check "unresolvable host at ensure still fails closed" 1 drc ensure dr
unset EGRESSLOCK_MOCK_DNS
check "ensure recovers when DNS is back" 0 drc ensure dr

# No-allow-host profile: verify stays silent.
export EGRESSLOCK_MOCK_DNS="git.example.test=192.0.2.99,cache.example.test=192.0.2.98"
# no-allow-host profile: ensure first, then verify stays silent.
cat > "$A12/plain.conf" <<'EOF'
profile plain 10.79.1.0/24
    rule public-only
EOF
env EGRESSLOCK_CONF="$A12/plain.conf" egresslock ensure plain >/dev/null 2>&1
export EGRESSLOCK_MOCK_DNS="git.example.test=192.0.2.99,cache.example.test=192.0.2.98"
p_out="$(env EGRESSLOCK_CONF="$A12/plain.conf" egresslock verify plain 2>&1)"; p_rc=$?
if [[ "$p_rc" == 0 && "$p_out" != *"drift:"* ]]; then
    pass=$((pass+1)); echo "PASS: no-allow-host profile verify silent"
else
    fail=$((fail+1)); echo "FAIL: no-allow-host profile (rc=$p_rc, out: $p_out)"
fi

# Structural mismatch must STILL fail verify (D1 did not weaken
# fail-closed): remove an allow-host rule from the live chain.
drc ensure dr >/dev/null 2>&1
grep -v 'dport 2222' "$STATE/nft/egresslock.p_dr" > "$STATE/nft/egresslock.p_dr.t" \
    && mv "$STATE/nft/egresslock.p_dr.t" "$STATE/nft/egresslock.p_dr"
check "verify fails on missing allow-host rule (structural)" 1 drc verify dr
drc ensure dr >/dev/null 2>&1
check "verify passes after re-ensure" 0 drc verify dr
unset EGRESSLOCK_MOCK_DNS

arc12_pass=$pass; arc12_fail=$fail



arc14_pass=0; arc14_fail=0
A14="$(mktemp -d /tmp/agent-a14.XXXXXX)"
a14() { if [[ "$1" == pass ]]; then arc14_pass=$((arc14_pass+1)); else arc14_fail=$((arc14_fail+1)); echo "FAIL: $2"; fi; }

cat > "$A14/bare.conf" <<'EOF'
profile bare 10.80.0.0/24
    rule public-only
    rule allow-host ${FORGEJO_HOST}:443
EOF

# Engine mode with the site env vars UNSET: a bare ${FORGEJO_HOST} with
# no fallback must fail closed at conf parse — the binary must NOT
# supply a site default hostname (ARC-14).
b_out="$(env -u FORGEJO_HOST -u OLLAMA_HOST EGRESSLOCK_CONF="$A14/bare.conf" egresslock rules bare 2>&1)"; b_rc=$?
if [[ "$b_rc" != 0 && "$b_out" != *"git.example.test"* ]]; then
    a14 pass
else
    a14 fail "bare \${FORGEJO_HOST} in engine mode (rc=$b_rc, out: $b_out)"
fi

# The --config= CLI form must behave identically (defaults unset in main).
b2_out="$(env -u FORGEJO_HOST -u OLLAMA_HOST egresslock --config="$A14/bare.conf" rules bare 2>&1)"; b2_rc=$?
if [[ "$b2_rc" != 0 && "$b2_out" != *"git.example.test"* ]]; then
    a14 pass
else
    a14 fail "bare \${FORGEJO_HOST} via --config= (rc=$b2_rc, out: $b2_out)"
fi

# Engine mode with fallback data in the conf keeps working when the
# variable is simply unset (no baked default needed), and explicit env
# overrides still win (ARC-8 data semantics, unchanged).
cat > "$A14/fb.conf" <<'EOF'
profile fb 10.80.1.0/24
    rule allow-host ${FORGEJO_HOST:-fb.example.test}:443
EOF
# EGL-141-D1: the compiler now resolves the profile's live bridge token
# (single emit path — rules/verify/install all share it). These
# `rules`-verb asserts therefore need the mock network present (the
# ensure-time topology the verb assumes); without it the emit fails
# closed by design (unresolved bridge). Inline state write — `mocknet`
# is defined later in this harness.
printf 'driver=bridge\nsubnet=10.80.1.0/24\ngateway=10.80.1.1\nipv6_enabled=false\ninterface=podman1\n' \
    > "$STATE/networks/egresslock-fb"
b3_out="$(env -u FORGEJO_HOST EGRESSLOCK_MOCK_DNS="fb.example.test=192.0.2.10,override.example.test=192.0.2.11" EGRESSLOCK_CONF="$A14/fb.conf" egresslock rules fb 2>&1)"; b3_rc=$?
if [[ "$b3_rc" == 0 && "$b3_out" == *"ip daddr 192.0.2.10 tcp dport 443"* ]]; then
    a14 pass
else
    a14 fail "conf fallback data without baked default (rc=$b3_rc, out: $b3_out)"
fi
b4_out="$(env FORGEJO_HOST=override.example.test EGRESSLOCK_MOCK_DNS="fb.example.test=192.0.2.10,override.example.test=192.0.2.11" EGRESSLOCK_CONF="$A14/fb.conf" egresslock rules fb 2>&1)"; b4_rc=$?
if [[ "$b4_rc" == 0 && "$b4_out" == *"ip daddr 192.0.2.11 tcp dport 443"* ]]; then
    a14 pass
else
    a14 fail "explicit env override of conf data (rc=$b4_rc, out: $b4_out)"
fi
rm -rf "$A14"

# R-014-1 F1 / ARC-21-D1: usage output must contain COMPLETE entries for
# the documented env vars and the required-config wording (ARC-20: the
# engine has no compiled-in profiles). FORGEJO_HOST/OLLAMA_HOST are no
# longer environment overrides of the binary (D3) and must NOT appear.
# Single compound assertion with an explicit else: the check ALWAYS
# ticks the ARC-14 counter (one PASS or one FAIL) — a --help reword can
# never silently drop it from the harness count again (R-019-1 F2).
u_out="$(env -u EGRESSLOCK_CONF egresslock --help 2>&1)"; u_rc=$?
u_ok=1
for v in NFT_BIN EGRESSLOCK_ANCHOR_IMAGE EGRESSLOCK_GW_IMAGE EGRESSLOCK_CONF \
         "localhost/egresslock-gateway:latest" "no profile config"; do
    [[ "$u_out" == *"$v"* ]] || u_ok=0
done
[[ "$u_out" == *"FORGEJO_HOST"* || "$u_out" == *"OLLAMA_HOST"* ]] && u_ok=0
if [[ "$u_ok" == 1 && "$u_rc" == 0 ]]; then
    a14 pass
else
    a14 fail "usage completeness (rc=$u_rc; missing a required entry or listing a forbidden name)"
fi

# --- ARC-16: kit surface (engine side) -------------------------------------
pass=0; fail=0
a16() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# D5: --version prints 'dev' when the binary has no VERSION file next
# to it (repo checkout), without touching profile state.
v_out="$(env -u EGRESSLOCK_CONF egresslock --version 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" == "dev" ]]; then
    a16 pass
else
    a16 fail "--version dev (rc=$v_rc, out: $v_out)"
fi
v2_out="$(env -u EGRESSLOCK_CONF egresslock --version extra-arg 2>&1)"; v2_rc=$?
if [[ "$v2_rc" == 0 && "$v2_out" == "dev" ]]; then
    a16 pass
else
    a16 fail "--version ignores extra args (rc=$v2_rc, out: $v2_out)"
fi

# D3: verify --ensured with nothing ensured is silent success. The
# no-config case is now the ARC-20 fail-closed check, so this runs on a
# --config fixture (a profile with no live anchor).
env EGRESSLOCK_CONF="$TESTROOT/validconf/ok.conf" egresslock teardown all >/dev/null 2>&1 || true
e_out="$(env EGRESSLOCK_CONF="$TESTROOT/validconf/ok.conf" egresslock verify --ensured 2>"$TESTROOT/e16.err")"; e_rc=$?
if [[ "$e_rc" == 0 && -z "$e_out" ]] \
   && [[ "$(cat $TESTROOT/e16.err)" == *"scoped: EGRESSLOCK_CONF="* ]]; then
    a16 pass
else
    a16 fail "verify --ensured silent stdout + scoped stderr (rc=$e_rc, out: $e_out, err: $(cat $TESTROOT/e16.err))"
fi

# D3: verify --ensured takes no profile argument.
x_out="$(env EGRESSLOCK_CONF="$TESTROOT/validconf/ok.conf" egresslock verify --ensured local-dev 2>&1)"; x_rc=$?
[[ "$x_rc" == 2 ]] && a16 pass || a16 fail "verify --ensured rejects profile arg (rc=$x_rc)"

arc16_pass=$pass; arc16_fail=$fail

# --- ARC-20: config required (no compiled-in profiles) -------------------
pass=0; fail=0
a20() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# Bare invocation (no --config, no EGRESSLOCK_CONF) fails closed for
# every profile subcommand with the required-config message. The message
# names the checked default path and hints at running as the account;
# it does NOT dump the full usage (the error is a missing config, not a
# usage mistake).
b_out="$(env -u EGRESSLOCK_CONF egresslock list 2>&1)"; b_rc=$?
if [[ "$b_rc" == 2 && "$b_out" == *"no profile config"* && "$b_out" == *"EGRESSLOCK_CONF"* ]]; then
    a20 pass
else
    a20 fail "bare list fails closed (rc=$b_rc, out: $b_out)"
fi
b2_out="$(env -u EGRESSLOCK_CONF egresslock list 2>&1)"; b2_rc=$?
if [[ "$b2_rc" == 2 && "$b2_out" == *"make sure you are running as the dedicated account"* ]]; then
    a20 pass
else
    a20 fail "no-config message hints at account/config (rc=$b2_rc, out: $b2_out)"
fi
b3_out="$(env -u EGRESSLOCK_CONF egresslock list 2>&1)"; b3_rc=$?
if [[ "$b3_rc" == 2 && "$b3_out" != *"Usage:"* ]]; then
    a20 pass
else
    a20 fail "no-config does not dump usage (rc=$b3_rc, out: $b3_out)"
fi
check "bare ensure fails closed" 2 env -u EGRESSLOCK_CONF egresslock ensure v
check "bare verify fails closed" 2 env -u EGRESSLOCK_CONF egresslock verify v
check "bare verify --ensured fails closed" 2 env -u EGRESSLOCK_CONF egresslock verify --ensured
check "bare teardown all fails closed" 2 env -u EGRESSLOCK_CONF egresslock teardown all
check "bare network fails closed" 2 env -u EGRESSLOCK_CONF egresslock network v
check "bare proxy-env fails closed" 2 env -u EGRESSLOCK_CONF egresslock proxy-env v
check "bare rules fails closed" 2 env -u EGRESSLOCK_CONF egresslock rules v
check "bare allowlist fails closed" 2 env -u EGRESSLOCK_CONF egresslock allowlist v
check "bare denied fails closed" 2 env -u EGRESSLOCK_CONF egresslock denied v
check "bare allow fails closed" 2 env -u EGRESSLOCK_CONF egresslock allow v x
# Empty EGRESSLOCK_CONF is the same as unset (D1).
check "empty EGRESSLOCK_CONF fails closed" 2 env EGRESSLOCK_CONF= egresslock list
# --help / --version / no-args usage do NOT require a config.
check "bare --help works without a conf" 0 env -u EGRESSLOCK_CONF egresslock --help
check "bare --version works without a conf" 0 env -u EGRESSLOCK_CONF egresslock --version
check "no-args usage works without a conf" 0 env -u EGRESSLOCK_CONF egresslock
# Unknown subcommand is a usage error (exit 2), not a config requirement.
check "unknown subcommand without a conf exits 2" 2 env -u EGRESSLOCK_CONF egresslock frobnicate
# The removed needs-creds subcommand now hits the unknown-command path.
check "needs-creds is an unknown command now" 2 env -u EGRESSLOCK_CONF egresslock needs-creds v
# no-args shows the SHORT usage (command index), not the full header.
u0_out="$(env -u EGRESSLOCK_CONF egresslock 2>&1)"; u0_rc=$?
if [[ "$u0_rc" == 0 && "$u0_out" == *"usage: egresslock"* && "$u0_out" == *"commands:"* ]]; then
    a20 pass
else
    a20 fail "no-args short usage (rc=$u0_rc, out: $u0_out)"
fi
# Unknown command prints short usage, not the full header.
u1_out="$(env -u EGRESSLOCK_CONF egresslock bogus 2>&1)"; u1_rc=$?
if [[ "$u1_rc" == 2 && "$u1_out" == *"unknown command"* && "$u1_out" == *"commands:"* ]]; then
    a20 pass
else
    a20 fail "unknown command short usage (rc=$u1_rc, out: $u1_out)"
fi
# Missing profile arg gives a command-specific usage line.
u2_out="$(env EGRESSLOCK_CONF="$TESTROOT/validconf/ok.conf" egresslock proxy-env 2>&1)"; u2_rc=$?
if [[ "$u2_rc" == 2 && "$u2_out" == *"proxy-env requires a profile name"* && "$u2_out" == *"usage: egresslock proxy-env <profile>"* ]]; then
    a20 pass
else
    a20 fail "proxy-env missing profile message (rc=$u2_rc, out: $u2_out)"
fi
# Missing allow entry gives a command-specific usage line (gateway profile).
u3_out="$(env EGRESSLOCK_CONF="$NPDIR/ci.conf" egresslock allow ci 2>&1)"; u3_rc=$?
if [[ "$u3_rc" == 2 && "$u3_out" == *"allow requires a destination"* && "$u3_out" == *"usage: egresslock allow <profile> <host[:port]>"* ]]; then
    a20 pass
else
    a20 fail "allow missing entry message (rc=$u3_rc, out: $u3_out)"
fi
# list has column headers.
u4_out="$(env EGRESSLOCK_CONF="$TESTROOT/validconf/ok.conf" egresslock list 2>/dev/null)"; u4_rc=$?
if [[ "$u4_rc" == 0 && "$u4_out" == *"NAME"* && "$u4_out" == *"NETWORK"* && "$u4_out" == *"SUBNET"* ]]; then
    a20 pass
else
    a20 fail "list column headers (rc=$u4_rc, out: $u4_out)"
fi

arc20_pass=$pass; arc20_fail=$fail

# --- ARC-25: fail closed when run as root -------------------------------
pass=0; fail=0
a25() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# Mock `id` to report uid 0 (root). The engine's only `id` use is the
# ARC-25 guard, so a PATH shim in the test bin is a faithful root mock.
mkdir -p "$TESTROOT/bin-root"
cat > "$TESTROOT/bin-root/id" <<'EOF'
#!/usr/bin/env bash
echo 0
EOF
chmod +x "$TESTROOT/bin-root/id"

# Every profile subcommand as root exits non-zero with the guard message.
# init is a writer with no config requirement, so it is exercised here too
# (R-035-1 note 1 follow-up): the guard must fire before it writes.
for cmd in "ensure v" "verify v" "verify --ensured" "teardown all" "teardown --runtime" \
           "network v" "proxy-env v" "rules v" "allowlist v" "denied v" "allow v x" "list" "init x"; do
    # shellcheck disable=SC2086
    r_out="$(PATH="$TESTROOT/bin-root:$PATH" env EGRESSLOCK_CONF="$TESTROOT/validconf/ok.conf" egresslock $cmd 2>&1)"; r_rc=$?
    if [[ "$r_rc" != 0 && "$r_out" == *"must run as the account, not root"* ]]; then
        a25 pass
    else
        a25 fail "root guard '$cmd' (rc=$r_rc, out: $r_out)"
    fi
done

# --help / --version stay root-safe (read-only, config-free).
h_out="$(PATH="$TESTROOT/bin-root:$PATH" env -u EGRESSLOCK_CONF egresslock --help 2>&1)"; h_rc=$?
[[ "$h_rc" == 0 && "$h_out" == *"Usage:"* ]] && a25 pass || a25 fail "--help as root works (rc=$h_rc)"
v_out="$(PATH="$TESTROOT/bin-root:$PATH" env -u EGRESSLOCK_CONF egresslock --version 2>&1)"; v_rc=$?
[[ "$v_rc" == 0 && "$v_out" == "dev" ]] && a25 pass || a25 fail "--version as root works (rc=$v_rc)"

# Escape hatch: EGRESSLOCK_ALLOW_ROOT=1 lets the root path run.
e_out="$(PATH="$TESTROOT/bin-root:$PATH" env EGRESSLOCK_ALLOW_ROOT=1 EGRESSLOCK_CONF="$TESTROOT/validconf/ok.conf" egresslock list 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 && "$e_out" == *"egresslock-v"* ]]; then
    a25 pass
else
    a25 fail "escape hatch allows root list (rc=$e_rc, out: $e_out)"
fi

arc25_pass=$pass; arc25_fail=$fail

# --- ARC-26: netns preflight probe --------------------------------------
pass=0; fail=0
a26() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# Healthy probe: the mock podman's `unshare --rootless-netns <cmd>`
# execs <cmd>, so `true` succeeds. ensure/verify still pass normally.
check "ARC-26 ensure passes with healthy probe" 0 npc ensure ci
check "ARC-26 verify passes with healthy probe" 0 npc verify ci

# A broken shared netns = a podman whose `unshare` fails. Mock it in a
# shim bin; the engine must emit the guidance text and NOT proceed to
# policy work (exit 1).
mkdir -p "$TESTROOT/bin-broken"
cat > "$TESTROOT/bin-broken/podman" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "unshare" && "\$2" == "--rootless-netns" && "\$3" == "true" ]]; then
    echo "Error: rootless netns: kill network process: permission denied" >&2
    exit 126
fi
# Everything else (incl. netns_nft's unshare nft ...): delegate to mock.
exec "$TESTROOT/bin/podman" "\$@"
EOF
chmod +x "$TESTROOT/bin-broken/podman"

for cmd in "ensure ci" "verify ci" "verify --ensured" "teardown all"; do
    # shellcheck disable=SC2086
    p_out="$(PATH="$TESTROOT/bin-broken:$PATH" npc $cmd 2>&1)"; p_rc=$?
    # EGL-35: the preflight guidance leads with the shipped fix
    # (--apparmor-add, or --apparmor-check to inspect); the manual
    # aa-status/parser archaeology moved to docs/troubleshooting.
    if [[ "$p_rc" == 1 && "$p_out" == *"podman rootless-netns is broken"* && "$p_out" == *"--apparmor-add"* && "$p_out" == *"--apparmor-check"* ]]; then
        a26 pass
    else
        a26 fail "broken probe '$cmd' (rc=$p_rc, out: $p_out)"
    fi
done

# Read-only commands do NOT probe (ARC-26-D1): with a broken netns,
# `network`/`list`/`rules`/`proxy-env`/`denied` still work.
n_out="$(PATH="$TESTROOT/bin-broken:$PATH" npc network ci 2>&1)"; n_rc=$?
[[ "$n_rc" == 0 && "$n_out" != *"rootless-netns is broken"* ]] && a26 pass || a26 fail "read-only network skips probe (rc=$n_rc, out: $n_out)"
l_out="$(PATH="$TESTROOT/bin-broken:$PATH" npc list 2>&1)"; l_rc=$?
[[ "$l_rc" == 0 && "$l_out" != *"rootless-netns is broken"* ]] && a26 pass || a26 fail "read-only list skips probe (rc=$l_rc, out: $l_out)"

# EGRESSLOCK_SKIP_NETNS_PROBE=1 bypasses the probe even for ensure/verify.
# Use the broken podman but skip the probe; other podman calls (network
# create/inspect/run) still delegate to the healthy mock, so ensure
# succeeds and the probe message is never emitted.
s_out="$(PATH="$TESTROOT/bin-broken:$PATH" env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_CONF="$NPDIR/ci.conf" egresslock ensure ci 2>&1)"; s_rc=$?
if [[ "$s_rc" == 0 && "$s_out" != *"rootless-netns is broken"* ]]; then
    a26 pass
else
    a26 fail "EGRESSLOCK_SKIP_NETNS_PROBE=1 bypasses probe (rc=$s_rc, out: $s_out)"
fi

# EGL-78-D1/D3 regression: a probe that HANGS (wedged pasta, stuck
# unshare) must be a named failure after the 5s bound, not a wedge of
# every ensure/verify/teardown. Shim podman so
# `unshare --rootless-netns true` sleeps 60s; ensure must return
# non-zero with the timeout-specific message, well under the harness's
# 300s bound. SKIP is deliberately NOT set on this call (D4: the bound,
# not the SKIP env, is the hang-prevention mechanism).
mkdir -p "$TESTROOT/bin-hang"
cat > "$TESTROOT/bin-hang/podman" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "unshare" && "\$2" == "--rootless-netns" && "\$3" == "true" ]]; then
    sleep 60
    exit 0
fi
# Everything else: delegate to the healthy mock.
exec "$TESTROOT/bin/podman" "\$@"
EOF
chmod +x "$TESTROOT/bin-hang/podman"
h_start=$SECONDS
h_out="$(PATH="$TESTROOT/bin-hang:$PATH" npc ensure ci 2>&1)"; h_rc=$?
h_elapsed=$(( SECONDS - h_start ))
if [[ "$h_rc" == 1 && "$h_out" == *"netns probe timed out after 5s"* && "$h_elapsed" -lt 15 ]]; then
    pass=$((pass+1)); echo "PASS: ARC-26 hanging probe is a named timeout failure (rc=1, ${h_elapsed}s)"
else
    fail=$((fail+1)); echo "FAIL: ARC-26 hanging probe not bounded (rc=$h_rc, elapsed=${h_elapsed}s, out: $h_out)"
fi

arc26_pass=$pass; arc26_fail=$fail

# --- ARC-49 R-049-1 F1: no /tmp/agent-policy.* leak on a failed nft -f -
# Regression for F1: the EXIT-trap cleanup (removed in the F1 fix) could
# not fire on implicit set -e exits; the fix uses explicit rm + die
# instead. Assert a mid-install_policy nft failure is fail-closed AND
# leaves no /tmp/agent-policy.* behind.
pass=0; fail=0
a49() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

mkdir -p "$TESTROOT/bin-nftfail"
cat > "$TESTROOT/bin-nftfail/nft" <<EOF
#!/usr/bin/env bash
# ARC-49 F1 regression shim (EGL-106 retarget): delegate everything to
# the harness mock but fail the FIRST '-f' invocation — with EGL-106's
# single-transaction install there is exactly ONE install -f per
# ensure (the combined p_v6deny + profile file), so #1 IS the install,
# leaving its temp file behind if cleanup does not run.
set -u
C="$TESTROOT/nftfail-count"
if [[ "\$1" == "-f" ]]; then
    n=\$((\$(cat "\$C" 2>/dev/null || echo 0) + 1))
    echo "\$n" > "\$C"
    if [[ "\$n" == 1 ]]; then
        echo "shim nft: injected failure on -f #1 (combined install)" >&2
        exit 1
    fi
fi
exec "$TESTROOT/bin/nft" "\$@"
EOF
chmod +x "$TESTROOT/bin-nftfail/nft"
: > "$TESTROOT/nftfail-count"
before="$(find /tmp -maxdepth 1 -name 'agent-policy.*' 2>/dev/null | sort)"
nf_out="$(PATH="$TESTROOT/bin-nftfail:$PATH" env EGRESSLOCK_CONF="$NPDIR/ci.conf" egresslock ensure ci 2>&1)"; nf_rc=$?
after="$(find /tmp -maxdepth 1 -name 'agent-policy.*' 2>/dev/null | sort)"
new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
if [[ "$nf_rc" != 0 && -z "$new" ]]; then
    a49 pass
else
    a49 fail "failed nft -f leaks agent-policy temp (rc=$nf_rc, new=[$new], out: $nf_out)"
fi
# Restore a verified policy (the failed ensure left a partial state; the
# engine's next ensure self-heals, and later sections expect ci verified).
restore_out="$(npc ensure ci >/dev/null 2>&1)"; restore_rc=$?
[[ "$restore_rc" == 0 ]] && a49 pass || a49 fail "ensure ci after F1 probe self-heals (rc=$restore_rc)"
arc49_pass=$pass; arc49_fail=$fail

# --- ARC-24: per-user default config probe ------------------------------
pass=0; fail=0
a24() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# HOME with the well-known default present: bare `list` now AGGREGATES
# CONFDIR/*.conf (ARC-37-D3), prints 'using configs in <dir>' on stderr,
# and stdout stays pure payload. A lone main.conf still lists.
mkdir -p "$TESTROOT/h24/.config/egresslock"
printf 'profile v 10.50.9.0/24\n' > "$TESTROOT/h24/.config/egresslock/main.conf"
d_out="$(pty "env -u EGRESSLOCK_CONF HOME='$TESTROOT/h24' egresslock list 2>$TESTROOT/agent24.err")"; d_rc=$?
if [[ "$d_rc" == 0 && "$d_out" == *"egresslock-v"* && "$(cat $TESTROOT/agent24.err)" == *"using configs in"*"$TESTROOT/h24/.config/egresslock"* ]]; then
    a24 pass
else
    a24 fail "default probe resolves + prints using configs in (rc=$d_rc, out: $d_out, err: $(cat $TESTROOT/agent24.err))"
fi

# ARC-49-D3: HOME containing a space must still resolve the default conf
# dir and aggregate — confdir_default's ${HOME:-...} path is quoted, so a
# space in the account home must not break the probe (or any named path).
mkdir -p "$TESTROOT/home with space/.config/egresslock"
printf 'profile hsp 10.50.11.0/24\n' > "$TESTROOT/home with space/.config/egresslock/main.conf"
sp_out="$(pty "env -u EGRESSLOCK_CONF HOME='$TESTROOT/home with space' egresslock list 2>$TESTROOT/agent24sp.err")"; sp_rc=$?
if [[ "$sp_rc" == 0 && "$sp_out" == *"egresslock-hsp"* && "$(cat $TESTROOT/agent24sp.err)" == *"using configs in"*"$TESTROOT/home with space/.config/egresslock"* ]]; then
    a24 pass
else
    a24 fail "HOME with a space resolves default conf (rc=$sp_rc, out: $sp_out, err: $(cat $TESTROOT/agent24sp.err))"
fi

# EGL-117-D1: the resolution line is TTY-independent — under capture
# (stdout NOT a terminal) stderr still carries it (the old ARC-45
# "stderr stays empty under capture" pin is UPDATED, not kept); rc and
# stdout are unchanged. This is the exact footgun shape: a captured /
# piped bare command must not silently lose its scope disclosure.
q_out="$(env -u EGRESSLOCK_CONF HOME="$TESTROOT/h24" egresslock list 2>$TESTROOT/agent24q.err)"; q_rc=$?
if [[ "$q_rc" == 0 && "$q_out" == *"egresslock-v"* \
      && "$(cat $TESTROOT/agent24q.err)" == *"using configs in"*"$TESTROOT/h24/.config/egresslock"*"(1 profiles)"* ]]; then
    a24 pass
else
    a24 fail "EGL-117: resolution line survives capture (rc=$q_rc, out: $q_out, err: $(cat $TESTROOT/agent24q.err))"
fi

# stderr only: stdout payload (list) unchanged.
d2_out="$(env -u EGRESSLOCK_CONF HOME="$TESTROOT/h24" egresslock network v 2>/dev/null)"; d2_rc=$?
if [[ "$d2_rc" == 0 && "$d2_out" == *"egresslock-v"* ]]; then
    a24 pass
else
    a24 fail "stdout payload unchanged by probe (rc=$d2_rc, out: $d2_out)"
fi

# HOME without the file: bare invocation still fails closed (exit 2).
mkdir -p "$TESTROOT/h24-empty"
m_out="$(env -u EGRESSLOCK_CONF HOME="$TESTROOT/h24-empty" egresslock list 2>&1)"; m_rc=$?
if [[ "$m_rc" == 2 && "$m_out" == *"no profile config"* ]]; then
    a24 pass
else
    a24 fail "probe miss fails closed (rc=$m_rc, out: $m_out)"
fi

# Explicit --config beats the default AND is disclosed (EGL-117): the
# scoped line, never the probe lines.
x_out="$(env -u EGRESSLOCK_CONF HOME="$TESTROOT/h24" egresslock --config "$TESTROOT/validconf/ok.conf" list 2>$TESTROOT/agent24x.err)"; x_rc=$?
if [[ "$x_rc" == 0 \
      && "$(cat $TESTROOT/agent24x.err)" == *"scoped: --config $TESTROOT/validconf/ok.conf"*"uses this config only"* \
      && "$(cat $TESTROOT/agent24x.err)" != *"using config"* ]]; then
    a24 pass
else
    a24 fail "explicit --config disclosed as scoped (rc=$x_rc, err: $(cat $TESTROOT/agent24x.err))"
fi

# Explicit EGRESSLOCK_CONF beats the default and is disclosed (EGL-117),
# with the unset remediation named.
y_out="$(env EGRESSLOCK_CONF="$TESTROOT/validconf/ok.conf" HOME="$TESTROOT/h24" egresslock list 2>$TESTROOT/agent24y.err)"; y_rc=$?
if [[ "$y_rc" == 0 \
      && "$(cat $TESTROOT/agent24y.err)" == *"scoped: EGRESSLOCK_CONF=$TESTROOT/validconf/ok.conf"* \
      && "$(cat $TESTROOT/agent24y.err)" == *"unset EGRESSLOCK_CONF to sweep the confdir"* \
      && "$(cat $TESTROOT/agent24y.err)" != *"using config"* ]]; then
    a24 pass
else
    a24 fail "EGRESSLOCK_CONF disclosed as scoped (rc=$y_rc, err: $(cat $TESTROOT/agent24y.err))"
fi

# HOME unset: the getent passwd fallback resolves the account home and
# the default probe still works (ARC-24 review note 1 follow-up; locks
# confdir_default's ${HOME:-$(getent passwd ...)} path).
mkdir -p "$TESTROOT/h24-nohome/.config/egresslock"
printf 'profile w 10.50.10.0/24\n' > "$TESTROOT/h24-nohome/.config/egresslock/main.conf"
g_out="$(pty "env -u HOME -u EGRESSLOCK_CONF ARCMOCK_PASSWD_HOME='$TESTROOT/h24-nohome' egresslock list 2>$TESTROOT/agent24g.err")"; g_rc=$?
if [[ "$g_rc" == 0 && "$g_out" == *"egresslock-w"* && "$(cat $TESTROOT/agent24g.err)" == *"using configs in"*"$TESTROOT/h24-nohome/.config/egresslock"* ]]; then
    a24 pass
else
    a24 fail "HOME-unset getent fallback resolves default conf (rc=$g_rc, out: $g_out, err: $(cat $TESTROOT/agent24g.err))"
fi

# HOME empty (''): the :- operator treats it as unset, same fallback.
g2_out="$(pty "env -u EGRESSLOCK_CONF HOME= ARCMOCK_PASSWD_HOME='$TESTROOT/h24-nohome' egresslock list 2>$TESTROOT/agent24g2.err")"; g2_rc=$?
if [[ "$g2_rc" == 0 && "$g2_out" == *"egresslock-w"* && "$(cat $TESTROOT/agent24g2.err)" == *"using configs in"*"$TESTROOT/h24-nohome/.config/egresslock"* ]]; then
    a24 pass
else
    a24 fail "HOME-empty getent fallback resolves default conf (rc=$g2_rc, out: $g2_out, err: $(cat $TESTROOT/agent24g2.err))"
fi

# getent home pointing at a nonexistent dir: probe miss stays fail-closed.
g3_out="$(env -u HOME -u EGRESSLOCK_CONF ARCMOCK_PASSWD_HOME="$TESTROOT/h24-nohome-missing" egresslock list 2>&1)"; g3_rc=$?
if [[ "$g3_rc" == 2 && "$g3_out" == *"no profile config"* ]]; then
    a24 pass
else
    a24 fail "getent home miss stays fail-closed (rc=$g3_rc, out: $g3_out)"
fi

arc24_pass=$pass; arc24_fail=$fail

# --- ARC-35: init (write a starter profile pair) ------------------------
pass=0; fail=0
a35() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# init is a writer, not a config-requiring subcommand: works with no
# loadable conf, from $HOME/.config/egresslock.
rm -rf "$TESTROOT/i35"; mkdir -p "$TESTROOT/i35/.config/egresslock"
printf 'profile main 10.199.0.0/24\n    rule gateway-only\n    gateway 10.199.0.2 3128 main-allowlist\n' \
    > "$TESTROOT/i35/.config/egresslock/main.conf"

# Auto-pick skips main's 10.199.0.0/24 -> 10.199.1.0/24.
i_out="$(env -u EGRESSLOCK_CONF HOME="$TESTROOT/i35" egresslock init local 2>&1)"; i_rc=$?
if [[ "$i_rc" == 0 && -f "$TESTROOT/i35/.config/egresslock/local.conf" \
      && -f "$TESTROOT/i35/.config/egresslock/local-allowlist" ]]; then
    i_conf="$(grep '^profile local' "$TESTROOT/i35/.config/egresslock/local.conf")"
    if [[ "$i_conf" == "profile local 10.199.1.0/24" \
          && "$(grep 'gateway 10.199.1.2 3128 local-allowlist' "$TESTROOT/i35/.config/egresslock/local.conf")" != "" ]]; then
        a35 pass
    else
        a35 fail "init auto-pick content (conf: $i_conf)"
    fi
else
    a35 fail "init auto-pick (rc=$i_rc, out: $i_out)"
fi

# Re-run never overwrites (exit 1, files unchanged).
i2_out="$(env -u EGRESSLOCK_CONF HOME="$TESTROOT/i35" egresslock init local 2>&1)"; i2_rc=$?
[[ "$i2_rc" == 1 && "$i2_out" == *"already exists"* ]] \
    && a35 pass || a35 fail "init re-run never overwrites (rc=$i2_rc, out: $i2_out)"

# Explicit --subnet (free) writes it; overlapping fails closed.
i3_out="$(env -u EGRESSLOCK_CONF HOME="$TESTROOT/i35" egresslock init dev --subnet 10.199.5.0/24 2>&1)"; i3_rc=$?
[[ "$i3_rc" == 0 && "$(grep '^profile dev' "$TESTROOT/i35/.config/egresslock/dev.conf")" == "profile dev 10.199.5.0/24" ]] \
    && a35 pass || a35 fail "init explicit subnet (rc=$i3_rc, out: $i3_out)"
i4_out="$(env -u EGRESSLOCK_CONF HOME="$TESTROOT/i35" egresslock init ov --subnet 10.199.1.0/24 2>&1)"; i4_rc=$?
[[ "$i4_rc" == 1 && "$i4_out" == *"overlaps"* ]] \
    && a35 pass || a35 fail "init overlapping subnet fails closed (rc=$i4_rc, out: $i4_out)"

# Bad name / missing name / bad --subnet are usage errors (exit 2).
i5_out="$(env -u EGRESSLOCK_CONF HOME="$TESTROOT/i35" egresslock init "Bad_Name" 2>&1)"; i5_rc=$?
[[ "$i5_rc" == 2 && "$i5_out" == *"invalid profile name"* ]] \
    && a35 pass || a35 fail "init invalid name (rc=$i5_rc, out: $i5_out)"
i6_out="$(env -u EGRESSLOCK_CONF HOME="$TESTROOT/i35" egresslock init 2>&1)"; i6_rc=$?
[[ "$i6_rc" == 2 && "$i6_out" == *"init requires a profile name"* ]] \
    && a35 pass || a35 fail "init missing name (rc=$i6_rc, out: $i6_out)"
i7_out="$(env -u EGRESSLOCK_CONF HOME="$TESTROOT/i35" egresslock init bad --subnet nope 2>&1)"; i7_rc=$?
[[ "$i7_rc" == 2 && "$i7_out" == *"invalid --subnet"* ]] \
    && a35 pass || a35 fail "init bad --subnet (rc=$i7_rc, out: $i7_out)"

# The written pair loads and lists.
i8_out="$(env EGRESSLOCK_CONF="$TESTROOT/i35/.config/egresslock/local.conf" egresslock list 2>&1)"; i8_rc=$?
[[ "$i8_rc" == 0 && "$i8_out" == *"local"* ]] \
    && a35 pass || a35 fail "init pair is loadable (rc=$i8_rc, out: $i8_out)"

# The written pair is end-to-end operable: ensure + verify against the
# generated conf (R-035-1 note 2 follow-up). Use a dedicated profile on
# a collision-free subnet (10.199.40.0/24 is unused by every other
# engine fixture) — the live network this creates must not trip the
# ARC-11 overlap pre-check of a later section (auto-pick's 10.199.1.0/24
# collides with the ARC-37 fixture).
env -u EGRESSLOCK_CONF HOME="$TESTROOT/i35" egresslock init e2e --subnet 10.199.40.0/24 >/dev/null 2>&1
i9_out="$(env EGRESSLOCK_CONF="$TESTROOT/i35/.config/egresslock/e2e.conf" egresslock ensure e2e 2>&1)"; i9_rc=$?
[[ "$i9_rc" == 0 ]] \
    && a35 pass || a35 fail "init pair ensures (rc=$i9_rc, out: $i9_out)"
i10_out="$(env EGRESSLOCK_CONF="$TESTROOT/i35/.config/egresslock/e2e.conf" egresslock verify e2e 2>&1)"; i10_rc=$?
[[ "$i10_rc" == 0 ]] \
    && a35 pass || a35 fail "init pair verifies (rc=$i10_rc, out: $i10_out)"

arc35_pass=$pass; arc35_fail=$fail

# --- ARC-30: disallow (remove an exact allowlist entry) -----------------
pass=0; fail=0
a30() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# ci.conf gateway allowlist (NPDIR/ci-allowlist). Seed two entries, one
# to remove, one to keep, plus a comment and an order check.
d_al="$NPDIR/ci-allowlist"
printf 'github.com\nexample.com:443\n# keep me\napi.local:8080\n' > "$d_al"
d_out="$(env EGRESSLOCK_CONF="$NPDIR/ci.conf" egresslock disallow ci example.com:443 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$d_out" == *"removed: example.com:443"* ]]; then
    if grep -q '^example.com:443$' "$d_al"; then
        a30 fail "disallow left the entry behind"
    elif grep -q '^github.com$' "$d_al" && grep -q '^# keep me$' "$d_al" && grep -q '^api.local:8080$' "$d_al"; then
        a30 pass
    else
        a30 fail "disallow removed too much (out: $d_out)"
    fi
else
    a30 fail "disallow removes exact line (rc=$d_rc, out: $d_out)"
fi

# Absent entry -> exit 1, allowlist unchanged, no ensure side effect.
d2_out="$(env EGRESSLOCK_CONF="$NPDIR/ci.conf" egresslock disallow ci notpresent.example 2>&1)"; d2_rc=$?
[[ "$d2_rc" == 1 && "$d2_out" == *"entry not present"* ]] \
    && a30 pass || a30 fail "disallow absent entry fails closed (rc=$d2_rc, out: $d2_out)"

# Missing destination -> usage error (exit 2).
d3_out="$(env EGRESSLOCK_CONF="$NPDIR/ci.conf" egresslock disallow ci 2>&1)"; d3_rc=$?
[[ "$d3_rc" == 2 && "$d3_out" == *"disallow requires a destination"* ]] \
    && a30 pass || a30 fail "disallow missing entry (rc=$d3_rc, out: $d3_out)"

# Invalid grammar -> exit 2.
d4_out="$(env EGRESSLOCK_CONF="$NPDIR/ci.conf" egresslock disallow ci 'bad entry!' 2>&1)"; d4_rc=$?
[[ "$d4_rc" == 2 && "$d4_out" == *"invalid allowlist entry"* ]] \
    && a30 pass || a30 fail "disallow invalid grammar (rc=$d4_rc, out: $d4_out)"

# Non-gateway profile -> the require_gateway_profile guard.
d5_out="$(env EGRESSLOCK_CONF="$TESTROOT/validconf/ok.conf" egresslock disallow v example.com:443 2>&1)"; d5_rc=$?
[[ "$d5_rc" != 0 ]] && a30 pass || a30 fail "disallow on non-gateway profile (rc=$d5_rc, out: $d5_out)"

# R-030-1 finding 1: mode preservation — a non-600 allowlist must keep
# its mode after disallow (not be tightened to 600).
AD30="$TESTROOT/h30"; rm -rf "$AD30"; mkdir -p "$AD30"
cat > "$AD30/m.conf" <<'EOF'
profile m 10.199.22.0/24
    rule gateway-only
    gateway 10.199.22.2 3128 m-allowlist
EOF
printf 'github.com\nexample.com:443\n' > "$AD30/m-allowlist"
chmod 644 "$AD30/m-allowlist"
env EGRESSLOCK_CONF="$AD30/m.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow m example.com:443 >/dev/null 2>&1
if [[ "$(stat -c %a "$AD30/m-allowlist")" == 644 ]] && ! grep -q 'example.com:443' "$AD30/m-allowlist"; then
    a30 pass
else
    a30 fail "R-030-1f1: disallow preserves allowlist mode (mode=$(stat -c %a "$AD30/m-allowlist" 2>/dev/null))"
fi

arc30_pass=$pass; arc30_fail=$fail

# --- ARC-46: multi-arg allow/disallow + re-ensuring status line ----------
pass=0; fail=0
a46() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

AD46="$TESTROOT/h46"; rm -rf "$AD46"; mkdir -p "$AD46"
cat > "$AD46/m.conf" <<'EOF'
profile mm 10.199.23.0/24
    rule gateway-only
    gateway 10.199.23.2 3128 mm-allowlist
EOF
: > "$AD46/mm-allowlist"
mkdir -p "$STATE/ips" "$STATE/containers"
: > "$STATE/running/egresslock-gateway-mm"
echo "egresslock-mm" > "$STATE/containers/egresslock-gateway-mm.net"
echo "10.199.23.2" > "$STATE/containers/egresslock-gateway-mm.ip"
run46() { env EGRESSLOCK_CONF="$AD46/m.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

# 1. multi-arg allow: all three added, one ensure (stderr has ONE
#    re-ensuring line), stdout has three result lines.
ml_out="$(run46 allow mm a.example:443 b.example c.example:8080 2>$TESTROOT/a46.err)"; ml_rc=$?
ml_added="$(grep -c 'added:' <<<"$ml_out")"
ml_re="$(grep -c 're-ensuring profile' $TESTROOT/a46.err)"
if [[ "$ml_rc" == 0 && "$ml_added" == 3 && "$ml_re" == 1 ]] \
   && grep -q '^a.example:443$' "$AD46/mm-allowlist" \
   && grep -q '^b.example$' "$AD46/mm-allowlist" \
   && grep -q '^c.example:8080$' "$AD46/mm-allowlist"; then
    a46 pass
else
    a46 fail "multi-arg allow: 3 added, 1 re-ensure (rc=$ml_rc, added=$ml_added re=$ml_re, out: $ml_out, err: $(cat $TESTROOT/a46.err))"
fi

# 2. duplicate argv (entry already seeded by test 1): both already
#    present, still ONE re-ensure.
dp_out="$(run46 allow mm a.example:443 a.example:443 2>$TESTROOT/a46b.err)"; dp_rc=$?
dp_added="$(grep -c 'added:' <<<"$dp_out")"
dp_present="$(grep -c 'entry already present:' <<<"$dp_out")"
dp_re="$(grep -c 're-ensuring profile' $TESTROOT/a46b.err)"
if [[ "$dp_rc" == 0 \
      && "$dp_added" == 0 \
      && "$dp_present" == 2 \
      && "$dp_re" == 1 ]]; then
    a46 pass
else
    a46 fail "allow duplicate argv (rc=$dp_rc, added=$dp_added present=$dp_present re=$dp_re, out: $dp_out, err: $(cat $TESTROOT/a46b.err))"
fi

# 3. invalid arg -> exit 2, allowlist unchanged, no ensure, no re-ensuring.
inv_before="$(cat "$AD46/mm-allowlist")"
in_out="$(run46 allow mm new.example 'bad entry!' 2>&1)"; in_rc=$?
if [[ "$in_rc" == 2 && "$in_out" == *"invalid allowlist entry"* \
      && "$(cat "$AD46/mm-allowlist")" == "$inv_before" \
      && "$in_out" != *"re-ensuring"* ]]; then
    a46 pass
else
    a46 fail "allow invalid arg no-op (rc=$in_rc, out: $in_out)"
fi

# 4. single allow still re-ensures even when already present.
pr_out="$(run46 allow mm a.example:443 2>$TESTROOT/a46c.err)"; pr_rc=$?
pr_re="$(grep -c 're-ensuring profile' $TESTROOT/a46c.err)"
[[ "$pr_rc" == 0 && "$pr_out" == *"entry already present"* \
  && "$pr_re" == 1 ]] \
    && a46 pass || a46 fail "single allow already-present re-ensures (rc=$pr_rc, out: $pr_out)"

# 5. multi-arg disallow: all present -> removed, one ensure.
printf 'x.example\ny.example:443\nz.example:8080\n' > "$AD46/mm-allowlist"
dm_out="$(run46 disallow mm x.example z.example:8080 2>$TESTROOT/a46d.err)"; dm_rc=$?
dm_removed="$(grep -c 'removed:' <<<"$dm_out")"
dm_re="$(grep -c 're-ensuring profile' $TESTROOT/a46d.err)"
if [[ "$dm_rc" == 0 && "$dm_removed" == 2 && "$dm_re" == 1 ]] \
   && ! grep -q '^x.example$' "$AD46/mm-allowlist" \
   && ! grep -q '^z.example:8080$' "$AD46/mm-allowlist" \
   && grep -q '^y.example:443$' "$AD46/mm-allowlist"; then
    a46 pass
else
    a46 fail "multi-arg disallow removes all present, one ensure (rc=$dm_rc, removed=$dm_removed re=$dm_re, out: $dm_out, err: $(cat $TESTROOT/a46d.err))"
fi

# 6. disallow with an absent entry -> exit 1, nothing changed.
before_da="$(cat "$AD46/mm-allowlist")"
da_out="$(run46 disallow mm y.example:443 nope.example 2>&1)"; da_rc=$?
[[ "$da_rc" == 1 && "$da_out" == *"entry not present"* \
  && "$(cat "$AD46/mm-allowlist")" == "$before_da" \
  && "$da_out" != *"re-ensuring"* ]] \
    && a46 pass || a46 fail "disallow absent entry no-op (rc=$da_rc, out: $da_out)"

# 7. allow-host: re-ensuring line present; extra arg -> exit 2.
cat > "$AD46/m.conf" <<'EOF'
profile mm 10.199.23.0/24
    rule gateway-only
    gateway 10.199.23.2 3128 mm-allowlist
EOF
ah_out="$(run46 allow-host mm git.example.test:2222 2>$TESTROOT/a46e.err)"; ah_rc=$?
[[ "$ah_rc" == 0 && "$(grep -c 're-ensuring profile' $TESTROOT/a46e.err)" == 1 ]] \
    && a46 pass || a46 fail "allow-host re-ensures (rc=$ah_rc, out: $ah_out, err: $(cat $TESTROOT/a46e.err))"
ahx_out="$(run46 allow-host mm git.example.test:2222 extra 2>&1)"; ahx_rc=$?
[[ "$ahx_rc" == 2 && "$ahx_out" == *"exactly one"* ]] \
    && a46 pass || a46 fail "allow-host extra arg (rc=$ahx_rc, out: $ahx_out)"

arc46_pass=$pass; arc46_fail=$fail

# --- BUG-002: allow appends to a no-trailing-newline allowlist -----------
pass=0; fail=0
b2() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# A starter-like allowlist whose last line is a comment with NO trailing
# newline (the shipped examples/main-allowlist pre-fix shape). A plain
# append would glue the first entry onto that comment and silently drop
# it; the append guard must write a leading newline first.
B2="$TESTROOT/hb2"; rm -rf "$B2"; mkdir -p "$B2"
cat > "$B2/m.conf" <<'EOF'
profile nn 10.199.25.0/24
    rule gateway-only
    gateway 10.199.25.2 3128 nn-allowlist
EOF
printf '# starter comment\n# entries below\n# last line, no newline' > "$B2/nn-allowlist"
# Fixture sanity: the last byte really is a non-newline.
[[ -s "$B2/nn-allowlist" && -n "$(tail -c 1 "$B2/nn-allowlist")" ]] \
    && b2 pass || b2 fail "fixture: allowlist lacks a trailing newline"
mkdir -p "$STATE/ips" "$STATE/containers"
: > "$STATE/running/egresslock-gateway-nn"
echo "egresslock-nn" > "$STATE/containers/egresslock-gateway-nn.net"
echo "10.199.25.2" > "$STATE/containers/egresslock-gateway-nn.ip"
run_b2() { env EGRESSLOCK_CONF="$B2/m.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

# 1. First allow clean-lands on its own standalone line (not glued
#    to the last comment), and is findable by the exact-match parse.
b2a_out="$(run_b2 allow nn demo.example.test 2>&1)"; b2a_rc=$?
if [[ "$b2a_rc" == 0 && "$b2a_out" == *"added: demo.example.test"* ]] \
   && grep -qxF 'demo.example.test' "$B2/nn-allowlist" \
   && ! grep -q '^# last line, no newlinedemo.example.test$' "$B2/nn-allowlist"; then
    b2 pass
else
    b2 fail "first allow clean-lands on no-newline allowlist (rc=$b2a_rc, out: $b2a_out)"
fi

# 2. A second allow still lands on its own line (newline present now).
b2b_out="$(run_b2 allow nn cache.example.test:8080 2>&1)"; b2b_rc=$?
if [[ "$b2b_rc" == 0 ]] && grep -qxF 'cache.example.test:8080' "$B2/nn-allowlist"; then
    b2 pass
else
    b2 fail "second allow clean (rc=$b2b_rc, out: $b2b_out)"
fi

# 3. D1: an entry ALREADY glued onto a comment line is NOT healed — the
#    guard writes a newline but never splits the glued line, so the glued
#    host stays inside the comment; a new allow still lands clean.
printf '# keep old.example:443 glued here no newline' > "$B2/g-allowlist"
cat > "$B2/g.conf" <<'EOF'
profile q3 10.199.26.0/24
    rule gateway-only
    gateway 10.199.26.2 3128 g-allowlist
EOF
mkdir -p "$STATE/ips" "$STATE/containers"
: > "$STATE/running/egresslock-gateway-q3"
echo "egresslock-q3" > "$STATE/containers/egresslock-gateway-q3.net"
echo "10.199.26.2" > "$STATE/containers/egresslock-gateway-q3.ip"
run_b2g() { env EGRESSLOCK_CONF="$B2/g.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
b2g_out="$(run_b2g allow q3 new.example 2>&1)"; b2g_rc=$?
if [[ "$b2g_rc" == 0 ]] \
   && grep -qxF 'new.example' "$B2/g-allowlist" \
   && ! grep -q '^old.example:443$' "$B2/g-allowlist" \
   && grep -q '^# keep old.example:443 glued here no newline$' "$B2/g-allowlist"; then
    b2 pass
else
    b2 fail "glued entry not healed; new allow clean (rc=$b2g_rc, out: $b2g_out)"
fi

arc_b2_pass=$pass; arc_b2_fail=$fail

# --- ARC-54: leftover inet agent_policy table dropped (rename residue) ---
pass=0; fail=0
a54() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# Fixture: plain (non-gateway) profile + the stale table as observed in
# the ARC-48 host lab — empty chains, no v6-drop rule, policy accept.
A54="$TESTROOT/arc54"; rm -rf "$A54"; mkdir -p "$A54"
cat > "$A54/lg.conf" <<'EOF'
profile lg 10.199.30.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
EOF
run_a54() { env EGRESSLOCK_CONF="$A54/lg.conf" egresslock "$@"; }
mkleftover() {
    printf 'chain p_main {\n}\n' > "$STATE/nft/agent_policy.p_main"
    printf 'chain p_dev {\n}\n' > "$STATE/nft/agent_policy.p_dev"
    printf 'chain p_v6deny {\n}\n' > "$STATE/nft/agent_policy.p_v6deny"
}
rmleftover() { rm -f "$STATE/nft/agent_policy.p_main" "$STATE/nft/agent_policy.p_dev" "$STATE/nft/agent_policy.p_v6deny"; }

# 1. ensure with the leftover present: the table is deleted BEFORE the
#    egresslock policy is installed (no dual policy tables, no rule copy).
mkleftover
a54_out="$(run_a54 ensure lg 2>&1)"; a54_rc=$?
if [[ "$a54_rc" == 0 \
      && "$a54_out" == *"removed leftover nft table 'inet agent_policy'"* \
      && ! -e "$STATE/nft/agent_policy.p_main" && ! -e "$STATE/nft/agent_policy.p_v6deny" \
      && -f "$STATE/nft/egresslock.p_lg" ]] \
   && grep -q 'daddr 192.0.2.10 tcp dport 443' "$STATE/nft/egresslock.p_lg"; then
    a54 pass
else
    a54 fail "ensure deletes leftover agent_policy then installs (rc=$a54_rc, out: $a54_out)"
fi

# 2. ensure without any leftover: no residue message, ensure stays green.
rmleftover
a54b_out="$(run_a54 ensure lg 2>&1)"; a54b_rc=$?
if [[ "$a54b_rc" == 0 && "$a54b_out" != *"agent_policy"* ]]; then
    a54 pass
else
    a54 fail "clean ensure has no residue message (rc=$a54b_rc, out: $a54b_out)"
fi

# 3. teardown all deletes the leftover too.
mkleftover
a54c_out="$(run_a54 teardown all 2>&1)"; a54c_rc=$?
if [[ "$a54c_rc" == 0 \
      && "$a54c_out" == *"removed leftover nft table 'inet agent_policy'"* \
      && ! -e "$STATE/nft/agent_policy.p_main" ]]; then
    a54 pass
else
    a54 fail "teardown all deletes leftover (rc=$a54c_rc, out: $a54c_out)"
fi

# 4. fail closed: a failing table delete aborts ensure BEFORE any
#    egresslock policy is installed (die, not warn).
rm -f "$STATE/nft/egresslock.p_lg"
mkleftover
: > "$STATE/nft/delete-table-fail"
a54d_out="$(run_a54 ensure lg 2>&1)"; a54d_rc=$?
rm -f "$STATE/nft/delete-table-fail"
if [[ "$a54d_rc" == 1 \
      && "$a54d_out" == *"could not be deleted (fail closed)"* \
      && ! -f "$STATE/nft/egresslock.p_lg" \
      && -e "$STATE/nft/agent_policy.p_main" ]]; then
    a54 pass
else
    a54 fail "failing delete fails closed before policy install (rc=$a54d_rc, out: $a54d_out)"
fi
rmleftover

arc54_pass=$pass; arc54_fail=$fail

# --- ARC-52: verify fail-closed on foreign early FORWARD hooks -----------
pass=0; fail=0
a52() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

A52="$TESTROOT/arc52"; rm -rf "$A52"; mkdir -p "$A52"
cat > "$A52/a52.conf" <<'EOF'
profile a52 10.199.31.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
EOF
run_a52() { env EGRESSLOCK_CONF="$A52/a52.conf" egresslock "$@"; }

# Baseline: ensured profile verifies green with nothing foreign hooked.
run_a52 ensure a52 >/dev/null 2>&1
a52_out="$(run_a52 verify a52 2>&1)"; a52_rc=$?
if [[ "$a52_rc" == 0 && "$a52_out" != *"agent_policy"* ]]; then
    a52 pass
else
    a52 fail "clean verify stays green (rc=$a52_rc, out: $a52_out)"
fi

# D3 check 3: a later-priority foreign hook (Netavark-like, filter = 0)
# does not fail verify.
printf 'chain p_late {\n    type filter hook forward priority filter; policy accept;\n}\n' \
    > "$STATE/nft/foreign_tbl.p_late"
a52_out="$(run_a52 verify a52 2>&1)"; a52_rc=$?
if [[ "$a52_rc" == 0 ]]; then
    a52 pass
else
    a52 fail "later-priority foreign hook is exempt (rc=$a52_rc, out: $a52_out)"
fi
rm -f "$STATE/nft/foreign_tbl.p_late"

# D3 check 1: leftover legacy table with a -150 hook (the ARC-52 host
# shape) fails verify; message names the table and points at ensure.
printf 'chain p_left {\n    type filter hook forward priority mangle; policy accept;\n    ip saddr 10.199.31.0/24 counter drop\n}\n' \
    > "$STATE/nft/agent_policy.p_left"
a52_out="$(run_a52 verify a52 2>&1)"; a52_rc=$?
if [[ "$a52_rc" == 1 && "$a52_out" == *"'inet agent_policy'"* && "$a52_out" == *"ensure"* ]]; then
    a52 pass
else
    a52 fail "leftover agent_policy fails verify with the table named (rc=$a52_rc, out: $a52_out)"
fi
rm -f "$STATE/nft/agent_policy.p_left"

# D3 check 2: a foreign (non-legacy) table's early forward chain fails
# verify, naming table and chain; verify never deletes it.
printf 'chain p_early {\n    type filter hook forward priority mangle; policy accept;\n}\n' \
    > "$STATE/nft/other_kit.p_early"
a52_out="$(run_a52 verify a52 2>&1)"; a52_rc=$?
if [[ "$a52_rc" == 1 && "$a52_out" == *"other_kit"* && "$a52_out" == *"p_early"* ]] \
   && [[ -f "$STATE/nft/other_kit.p_early" ]]; then
    a52 pass
else
    a52 fail "foreign early hook fails verify, named, not deleted (rc=$a52_rc, out: $a52_out)"
fi
rm -f "$STATE/nft/other_kit.p_early"

# An EMPTY legacy table (no forward hook, the mid-rename shape) still
# fails on existence.
printf 'chain p_orphan {\n}\n' > "$STATE/nft/agent_policy.p_orphan"
a52_out="$(run_a52 verify a52 2>&1)"; a52_rc=$?
if [[ "$a52_rc" == 1 && "$a52_out" == *"agent_policy"* && "$a52_out" == *"ensure"* ]]; then
    a52 pass
else
    a52 fail "legacy table existence alone fails verify (rc=$a52_rc, out: $a52_out)"
fi
rm -f "$STATE/nft/agent_policy.p_orphan"

# verify --ensured inherits the check.
printf 'chain p_left {\n    type filter hook forward priority mangle; policy accept;\n    ip saddr 10.199.31.0/24 counter drop\n}\n' \
    > "$STATE/nft/agent_policy.p_left"
a52_out="$(run_a52 verify --ensured 2>&1)"; a52_rc=$?
rm -f "$STATE/nft/agent_policy.p_left"
if [[ "$a52_rc" == 1 && "$a52_out" == *"agent_policy"* ]]; then
    a52 pass
else
    a52 fail "verify --ensured inherits the foreign-hook check (rc=$a52_rc, out: $a52_out)"
fi

# Back to clean: green again after the leftovers are gone.
a52_out="$(run_a52 verify a52 2>&1)"; a52_rc=$?
if [[ "$a52_rc" == 0 ]]; then
    a52 pass
else
    a52 fail "verify green again after leftovers removed (rc=$a52_rc, out: $a52_out)"
fi

echo "RESULTS (ARC-52 foreign hooks): $pass passed, $fail failed"
arc52_pass=$pass; arc52_fail=$fail

# --- EGL-98: stale-unpolicied detection (post-reboot window) --------------
# The podman network OBJECT survives a reboot (on-disk) while the netns
# nft policy is gone (volatile): a raw `podman run --network
# egresslock-<p>` in that window is unpolicied. D2: the stale predicate
# (network exists + profile chain absent) names the state on BOTH
# verify surfaces — `verify <p>` and the `--ensured` sweep (the
# default-wiring timer's only post-reboot drift signal) — instead of
# the unexplained `anchor ... not running` bail / the silent skip.
# Signal-only: nothing repairs; teardown'd / never-ensured profiles
# keep the silent skip (ARC-16-D3, narrowed).
pass=0; fail=0
e98() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

E98="$TESTROOT/e98"; rm -rf "$E98"; mkdir -p "$E98"
cat > "$E98/e98.conf" <<'EOF'
profile e98 10.199.32.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
EOF
run_e98() { env EGRESSLOCK_CONF="$E98/e98.conf" egresslock "$@"; }

# Stale seed: the network OBJECT present (on-disk half), no chain state
# (volatile half gone), no live anchor — the post-reboot window.
e98_seed_stale() {
    : > "$STATE/networks/egresslock-e98"
}

# 1. Named verify on the stale state fails NAMED (network exists but
# policy does not), not at the unexplained anchor-not-running bail.
e98_seed_stale
e98_out="$(run_e98 verify e98 2>&1)"; e98_rc=$?
if [[ "$e98_rc" == 1 \
      && "$e98_out" == *"network exists but policy does not"* \
      && "$e98_out" == *"egresslock ensure e98"* ]]; then
    e98 pass
else
    e98 fail "stale verify main-line (rc=$e98_rc, out: $e98_out)"
fi
if [[ "$e98_out" != *"anchor egresslock-anchor-e98 not running"* ]]; then
    e98 pass
else
    e98 fail "stale verify must not stop at the unexplained anchor line (out: $e98_out)"
fi
rm -f "$STATE/networks/egresslock-e98"

# 2. Same shape on verify --ensured: named failure, NOT the silent rc 0
# (the default sweep-mode wiring's post-reboot hole).
e98_seed_stale
e98_out="$(run_e98 verify --ensured 2>&1)"; e98_rc=$?
if [[ "$e98_rc" == 1 \
      && "$e98_out" == *"network exists but policy does not"* \
      && "$e98_out" == *"egresslock ensure e98"* ]]; then
    e98 pass
else
    e98 fail "stale verify --ensured named failure (rc=$e98_rc, out: $e98_out)"
fi
rm -f "$STATE/networks/egresslock-e98"

# 3. Regressions: network object missing keeps the existing named line
# (never-ensured / teardown'd shape) — and --ensured stays silent rc 0
# when nothing is stale.
e98_out="$(run_e98 verify e98 2>&1)"; e98_rc=$?
if [[ "$e98_rc" == 1 && "$e98_out" == *"network egresslock-e98 missing — run: egresslock ensure e98"* ]]; then
    e98 pass
else
    e98 fail "network-missing regression (rc=$e98_rc, out: $e98_out)"
fi
e98_out="$(run_e98 verify --ensured 2>/dev/null)"; e98_rc=$?
if [[ "$e98_rc" == 0 && -z "$e98_out" ]]; then
    e98 pass
else
    e98 fail "never-ensured --ensured stays silent rc 0 (rc=$e98_rc, out: $e98_out)"
fi

# 4. Hard probe failure (netns not answering — NOT the no-such-chain
# answer): named failure on both surfaces, never folded into the skip
# path (R9).
e98_seed_stale
: > "$STATE/netns-nft-fails"
e98_out="$(run_e98 verify --ensured 2>&1)"; e98_rc=$?
if [[ "$e98_rc" == 1 && "$e98_out" == *"cannot probe the nft policy"* ]]; then
    e98 pass
else
    e98 fail "hard nft failure on the sweep is a named failure (rc=$e98_rc, out: $e98_out)"
fi
e98_out="$(run_e98 verify e98 2>&1)"; e98_rc=$?
if [[ "$e98_rc" == 1 && "$e98_out" == *"cannot probe the nft policy"* ]]; then
    e98 pass
else
    e98 fail "hard nft failure on named verify is a named failure (rc=$e98_rc, out: $e98_out)"
fi
rm -f "$STATE/netns-nft-fails" "$STATE/networks/egresslock-e98"

# 5. Healthy pin: the ensured profile verifies green — the stale probe
# must not change the converged path.
run_e98 ensure e98 >/dev/null 2>&1
e98_out="$(run_e98 verify e98 2>&1)"; e98_rc=$?
if [[ "$e98_rc" == 0 && "$e98_out" != *"network exists but policy does not"* ]]; then
    e98 pass
else
    e98 fail "ensured profile stays green after the delta (rc=$e98_rc, out: $e98_out)"
fi
run_e98 teardown all >/dev/null 2>&1 || true

echo "RESULTS (EGL-98 stale-unpolicied): $pass passed, $fail failed"
e98_pass=$pass; e98_fail=$fail

# --- ARC-37: per-profile conf probe + list aggregation -------------------
pass=0; fail=0
a37() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

H37="$TESTROOT/h37"
rm -rf "$H37"; mkdir -p "$H37/.config/egresslock"
printf 'profile main 10.199.0.0/24\n    rule gateway-only\n    gateway 10.199.0.2 3128 main-allowlist\n' \
    > "$H37/.config/egresslock/main.conf"
: > "$H37/.config/egresslock/main-allowlist"
printf 'profile a 10.199.1.0/24\n    rule public-only\n' > "$H37/.config/egresslock/a.conf"
printf 'profile b 10.199.2.0/24\n    rule public-only\n' > "$H37/.config/egresslock/b.conf"

# 1. bare list aggregates every *.conf (main + a + b).
l_out="$(pty "env -u EGRESSLOCK_CONF HOME='$H37' egresslock list 2>$TESTROOT/a37.err")"; l_rc=$?
if [[ "$l_rc" == 0 && "$l_out" == *"main"* && "$l_out" == *"a"* && "$l_out" == *"b"* \
      && "$(cat $TESTROOT/a37.err)" == *"using configs in"*"$H37/.config/egresslock"* ]]; then
    a37 pass
else
    a37 fail "bare list aggregates main+a+b (rc=$l_rc, out: $l_out, err: $(cat $TESTROOT/a37.err))"
fi

# 2. named probe: <profile>.conf wins over main.conf.
n_out="$(pty "env -u EGRESSLOCK_CONF HOME='$H37' egresslock network a 2>$TESTROOT/a37n.err")"; n_rc=$?
[[ "$n_rc" == 0 && "$n_out" == *"egresslock-a"* && "$(cat $TESTROOT/a37n.err)" == *"using config"*"a.conf"* ]] \
    && a37 pass || a37 fail "named probe uses <profile>.conf (rc=$n_rc, out: $n_out, err: $(cat $TESTROOT/a37n.err))"

# 3. fallback to main.conf when <profile>.conf is absent; a name missing
#    from main.conf must fail require_profile, not 'no profile config'.
rm -f "$H37/.config/egresslock/b.conf"
n2_out="$(env -u EGRESSLOCK_CONF HOME="$H37" egresslock network b 2>&1)"; n2_rc=$?
[[ "$n2_rc" == 2 && "$n2_out" == *"unknown profile 'b'"* ]] \
    && a37 pass || a37 fail "fallback to main.conf then require_profile (rc=$n2_rc, out: $n2_out)"

# 4. duplicate profile name across two *.conf -> bare list exits 2 naming
#    both files.
printf 'profile b 10.199.2.0/24\n    rule public-only\n' > "$H37/.config/egresslock/b.conf"
printf 'profile a 10.199.3.0/24\n    rule public-only\n' > "$H37/.config/egresslock/c.conf"
d_out="$(env -u EGRESSLOCK_CONF HOME="$H37" egresslock list 2>&1)"; d_rc=$?
if [[ "$d_rc" == 2 && "$d_out" == *"duplicate profile name 'a'"* \
      && "$d_out" == *"a.conf"* && "$d_out" == *"c.conf"* ]]; then
    a37 pass
else
    a37 fail "duplicate across files exits 2 naming both (rc=$d_rc, out: $d_out)"
fi

# 5. bare teardown all uses main.conf only (never scans siblings).
rm -f "$H37/.config/egresslock/c.conf"
env -u EGRESSLOCK_CONF HOME="$H37" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure a >/dev/null 2>&1
env -u EGRESSLOCK_CONF HOME="$H37" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure main >/dev/null 2>&1
env -u EGRESSLOCK_CONF HOME="$H37" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock teardown all >/dev/null 2>&1
[[ -f "$STATE/networks/egresslock-a" ]] && a37 pass || a37 fail "bare teardown all leaves a.conf network alone"
[[ ! -f "$STATE/networks/egresslock-main" ]] && a37 pass || a37 fail "bare teardown all removed main's network"

# 6. bare verify --ensured aggregates every *.conf (a check, not a delete).
env -u EGRESSLOCK_CONF HOME="$H37" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure a >/dev/null 2>&1
env -u EGRESSLOCK_CONF HOME="$H37" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure b >/dev/null 2>&1
v_out="$(env -u EGRESSLOCK_CONF HOME="$H37" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify --ensured 2>&1)"; v_rc=$?
[[ "$v_rc" == 0 && "$v_out" == *"verified (ensured)"* ]] \
    && a37 pass || a37 fail "bare verify --ensured aggregates (rc=$v_rc, out: $v_out)"

# 7. init hint teaches bare ensure (ARC-37-D5).
i37_out="$(env -u EGRESSLOCK_CONF HOME="$H37" egresslock init x 2>&1)"; i37_rc=$?
[[ "$i37_rc" == 0 && "$i37_out" == *"egresslock ensure x"* && "$i37_out" == *"--config"* ]] \
    && a37 pass || a37 fail "init hint teaches bare ensure (rc=$i37_rc, out: $i37_out)"

# 8. explicit --config stays single-file (site multi-block conf); the
#    scoped resolution line is disclosed (EGL-117), never the probe lines.
x37_out="$(env -u EGRESSLOCK_CONF HOME="$H37" egresslock --config "$H37/.config/egresslock/a.conf" list 2>$TESTROOT/a37x.err)"; x37_rc=$?
if [[ "$x37_rc" == 0 && "$x37_out" == *"a"* && "$x37_out" != *"main"* \
      && "$(cat $TESTROOT/a37x.err)" == *"scoped: --config"*"$H37/.config/egresslock/a.conf"* \
      && "$(cat $TESTROOT/a37x.err)" != *"using config"* ]]; then
    a37 pass
else
    a37 fail "explicit --config stays single-file + scoped line (rc=$x37_rc, out: $x37_out, err: $(cat $TESTROOT/a37x.err))"
fi

arc37_pass=$pass; arc37_fail=$fail

# --- EGL-117: resolution disclosure — every time, TTY-independent --------
# D1: exactly one stderr resolution line per conf-resolving invocation,
# exact deterministic wording, never gated on stdout being a terminal.
pass=0; fail=0
a117() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

H117="$TESTROOT/h117"
rm -rf "$H117"; mkdir -p "$H117/.config/egresslock"
printf 'profile main 10.199.0.0/24\n    rule public-only\n' > "$H117/.config/egresslock/main.conf"
printf 'profile p2 10.199.1.0/24\n    rule public-only\n' > "$H117/.config/egresslock/p2.conf"

# 1. Named probe hit: exact line (named command under capture).
o="$(env -u EGRESSLOCK_CONF HOME="$H117" egresslock network p2 2>$TESTROOT/e117a.err)"; rc=$?
[[ "$rc" == 0 && "$(cat $TESTROOT/e117a.err)" == "using config $H117/.config/egresslock/p2.conf" ]] \
    && a117 pass || a117 fail "named probe line exact (rc=$rc, err: $(cat $TESTROOT/e117a.err))"

# 2. Named fallback: no p3.conf -> main.conf named as the fallback, even
#    though the profile lookup then fails closed (require_profile).
o="$(env -u EGRESSLOCK_CONF HOME="$H117" egresslock network p3 2>$TESTROOT/e117b.err)"; rc=$?
if [[ "$rc" == 2 \
      && "$(cat $TESTROOT/e117b.err)" == *"using config $H117/.config/egresslock/main.conf (named fallback: no p3.conf)"* \
      && "$(cat $TESTROOT/e117b.err)" == *"unknown profile 'p3'"* ]]; then
    a117 pass
else
    a117 fail "named fallback line (rc=$rc, err: $(cat $TESTROOT/e117b.err))"
fi

# 2b. profile 'main' hitting main.conf is a NAMED hit (main.conf IS
#     <main>.conf) — never carries the fallback suffix.
o="$(env -u EGRESSLOCK_CONF HOME="$H117" egresslock network main 2>$TESTROOT/e117b2.err)"; rc=$?
[[ "$rc" == 0 && "$(cat $TESTROOT/e117b2.err)" == "using config $H117/.config/egresslock/main.conf" ]] \
    && a117 pass || a117 fail "main-on-main is a named hit (rc=$rc, err: $(cat $TESTROOT/e117b2.err))"

# 3. Aggregate: exact line with the conf count (N = *.conf files loaded).
o="$(env -u EGRESSLOCK_CONF HOME="$H117" egresslock list 2>$TESTROOT/e117c.err)"; rc=$?
[[ "$rc" == 0 && "$(cat $TESTROOT/e117c.err)" == "using configs in $H117/.config/egresslock (2 profiles)" ]] \
    && a117 pass || a117 fail "aggregate line with count (rc=$rc, err: $(cat $TESTROOT/e117c.err))"

# 4. Exactly ONE resolution line per invocation.
lines="$(wc -l < $TESTROOT/e117c.err)"
[[ "$lines" == 1 ]] && a117 pass || a117 fail "exactly one resolution line (got $lines: $(cat $TESTROOT/e117c.err))"

# 5. Env-scoped under a pipe (the live footgun: an exported
#    EGRESSLOCK_CONF narrows every bare command; the scoped line must
#    survive command substitution, not only a TTY).
o="$(env EGRESSLOCK_CONF="$H117/.config/egresslock/p2.conf" HOME="$H117" egresslock list 2>$TESTROOT/e117d.err | cat)"; rc=$?
if [[ "$rc" == 0 \
      && "$(cat $TESTROOT/e117d.err)" == "scoped: EGRESSLOCK_CONF=$H117/.config/egresslock/p2.conf — this command uses this config only; unset EGRESSLOCK_CONF to sweep the confdir" ]]; then
    a117 pass
else
    a117 fail "env-scoped line under pipe (rc=$rc, err: $(cat $TESTROOT/e117d.err))"
fi

egl117_pass=$pass; egl117_fail=$fail

# --- ARC-38: allow-host / disallow-host (conf mutation) ------------------
pass=0; fail=0
a38() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

AH="$TESTROOT/h38"; rm -rf "$AH"; mkdir -p "$AH"
cat > "$AH/multi.conf" <<'EOF'
profile one 10.199.10.0/24
    rule allow-host first.example.test:443
    rule gateway-only
    gateway 10.199.10.2 3128 one-allowlist
profile two 10.199.11.0/24
    rule gateway-only
    gateway 10.199.11.2 3128 two-allowlist
EOF
: > "$AH/one-allowlist"; : > "$AH/two-allowlist"

# 1. allow-host inserts into the NAMED block of a multi-block conf (not EOF
#    / not the last block).
a_out="$(env EGRESSLOCK_CONF="$AH/multi.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host two git.example.test:2222 2>&1)"; a_rc=$?
if [[ "$a_rc" == 0 && "$a_out" == *"added: rule allow-host git.example.test:2222"* ]]; then
    line="$(grep -n 'rule allow-host git.example.test:2222' "$AH/multi.conf" | cut -d: -f1)"
    two_line="$(grep -n '^profile two' "$AH/multi.conf" | cut -d: -f1)"
    one_line="$(grep -n '^profile one' "$AH/multi.conf" | cut -d: -f1)"
    if [[ -n "$line" && "$line" -gt "$two_line" && "$line" -gt "$one_line" ]]; then
        a38 pass
    else
        a38 fail "rule landed in wrong block (rule line $line, one at $one_line, two at $two_line)"
    fi
else
    a38 fail "allow-host inserts rule (rc=$a_rc, out: $a_out)"
fi

# 2. duplicate -> 'entry already present' + still ensures; no double-add.
a2_out="$(env EGRESSLOCK_CONF="$AH/multi.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host two git.example.test:2222 2>&1)"; a2_rc=$?
[[ "$a2_rc" == 0 && "$a2_out" == *"entry already present"* ]] \
    && a38 pass || a38 fail "duplicate allow-host (rc=$a2_rc, out: $a2_out)"
[[ "$(grep -c 'rule allow-host git.example.test:2222' "$AH/multi.conf")" == 1 ]] \
    && a38 pass || a38 fail "duplicate did not double-add"

# 3. disallow-host removes the exact rule.
r_out="$(env EGRESSLOCK_CONF="$AH/multi.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow-host two git.example.test:2222 2>&1)"; r_rc=$?
if [[ "$r_rc" == 0 && "$r_out" == *"removed: rule allow-host git.example.test:2222"* ]] \
   && ! grep -q 'rule allow-host git.example.test:2222' "$AH/multi.conf"; then
    a38 pass
else
    a38 fail "disallow-host removes the rule (rc=$r_rc, out: $r_out)"
fi

# 4. disallow-host of an absent rule -> exit 1, conf unchanged, no ensure.
r2_out="$(env EGRESSLOCK_CONF="$AH/multi.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow-host two git.example.test:2222 2>&1)"; r2_rc=$?
[[ "$r2_rc" == 1 && "$r2_out" == *"rule not present"* ]] \
    && a38 pass || a38 fail "disallow-host absent (rc=$r2_rc, out: $r2_out)"

# 5. malformed host:port -> exit 2, conf unchanged.
m_out="$(env EGRESSLOCK_CONF="$AH/multi.conf" egresslock allow-host two 'bad entry' 2>&1)"; m_rc=$?
[[ "$m_rc" == 2 && "$m_out" == *"invalid allow-host entry"* ]] \
    && a38 pass || a38 fail "allow-host invalid grammar (rc=$m_rc, out: $m_out)"

# 6. public-only profile -> exit 2, nothing written.
printf 'profile pub 10.199.12.0/24\n    rule public-only\n' > "$AH/pub.conf"
p_out="$(env EGRESSLOCK_CONF="$AH/pub.conf" egresslock allow-host pub git.example.test:2222 2>&1)"; p_rc=$?
if [[ "$p_rc" == 2 && "$p_out" == *"public-only"* ]] && ! grep -q 'allow-host' "$AH/pub.conf"; then
    a38 pass
else
    a38 fail "allow-host on public-only fails closed (rc=$p_rc, out: $p_out)"
fi

# 7. non-gateway profile can take allow-host (no gateway guard).
printf 'profile d 10.199.13.0/24\n    rule allow-host git.example.test:443\n' > "$AH/direct.conf"
dg_out="$(env EGRESSLOCK_CONF="$AH/direct.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host d cache.example.test:443 2>&1)"; dg_rc=$?
if [[ "$dg_rc" == 0 ]] && grep -q 'rule allow-host cache.example.test:443' "$AH/direct.conf"; then
    a38 pass
else
    a38 fail "allow-host on non-gateway profile (rc=$dg_rc, out: $dg_out)"
fi

# 8. disallow-host only matches inside the named block (a same-named rule
#    in another profile is untouched).
cat > "$AH/same.conf" <<'EOF'
profile p1 10.199.14.0/24
    rule allow-host git.example.test:2222
profile p2 10.199.15.0/24
    rule allow-host git.example.test:2222
EOF
env EGRESSLOCK_CONF="$AH/same.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow-host p1 git.example.test:2222 >/dev/null 2>&1
p1_count="$(sed -n '/^profile p1/,/^profile p2/p' "$AH/same.conf" | grep -c 'rule allow-host git.example.test:2222')"
p2_count="$(sed -n '/^profile p2/,$p' "$AH/same.conf" | grep -c 'rule allow-host git.example.test:2222')"
[[ "$p1_count" == 0 && "$p2_count" == 1 ]] \
    && a38 pass || a38 fail "disallow-host scoped to named block (p1=$p1_count, p2=$p2_count)"

# R-038-1 finding 1 regression: a profile with PRE-EXISTING engine rules
# (not a clean slate) — allow-host of a second destination must not
# duplicate the existing rule, and a FRESH-PROCESS verify must pass.
cat > "$AH/pre.conf" <<'EOF'
profile pre 10.199.16.0/24
    rule allow-host git.example.test:443
    rule gateway-only
    gateway 10.199.16.2 3128 pre-allowlist
EOF
: > "$AH/pre-allowlist"
env EGRESSLOCK_CONF="$AH/pre.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure pre >/dev/null 2>&1
env EGRESSLOCK_CONF="$AH/pre.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host pre cache.example.test:2222 >/dev/null 2>&1
# the 443 rule must appear exactly ONCE in both the conf and the chain.
pre_conf_443="$(grep -c 'rule allow-host git.example.test:443' "$AH/pre.conf")"
pre_chain_443="$(grep -c 'daddr 192.0.2.10 tcp dport 443' "$STATE/nft/egresslock.p_pre")"
pre_chain_2222="$(grep -c 'daddr 192.0.2.11 tcp dport 2222' "$STATE/nft/egresslock.p_pre")"
if [[ "$pre_conf_443" == 1 && "$pre_chain_443" == 1 && "$pre_chain_2222" == 1 ]]; then
    a38 pass
else
    a38 fail "R-038-1f1: no duplicate registration (conf443=$pre_conf_443 chain443=$pre_chain_443 chain2222=$pre_chain_2222)"
fi
check "R-038-1f1: fresh verify passes after allow-host on pre-existing rules" 0 \
    env EGRESSLOCK_CONF="$AH/pre.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify pre

# R-038-1 finding 1b regression: disallow-host (the revocation path) must
# remove the rule from the enforced chain, not just the conf.
env EGRESSLOCK_CONF="$AH/pre.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow-host pre git.example.test:443 >/dev/null 2>&1
pre_chain_443_after="$(grep -c 'daddr 192.0.2.10 tcp dport 443' "$STATE/nft/egresslock.p_pre")"
pre_conf_443_after="$(grep -c 'rule allow-host git.example.test:443' "$AH/pre.conf")"
if [[ "$pre_chain_443_after" == 0 && "$pre_conf_443_after" == 0 ]]; then
    a38 pass
else
    a38 fail "R-038-1f1b: disallow-host revokes enforced rule (chain443=$pre_chain_443_after conf443=$pre_conf_443_after)"
fi
check "R-038-1f1b: fresh verify passes after disallow-host" 0 \
    env EGRESSLOCK_CONF="$AH/pre.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify pre

# R-038-1 finding 2 regression: regex near-collision host must NOT match.
# Use resolvable mock-DNS hosts so ensure passes after the conf write.
cat > "$AH/near.conf" <<'EOF'
profile near 10.199.17.0/24
    rule allow-host gitXexample.test:443
EOF
near_out="$(env EGRESSLOCK_CONF="$AH/near.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host near git.example.test:443 2>&1)"; near_rc=$?
if [[ "$near_rc" == 0 && "$near_out" == *"added: rule allow-host git.example.test:443"* ]] \
   && grep -qF '    rule allow-host git.example.test:443' "$AH/near.conf" \
   && grep -qF '    rule allow-host gitXexample.test:443' "$AH/near.conf"; then
    a38 pass
else
    a38 fail "R-038-1f2: near-collision host not falsely matched (rc=$near_rc, out: $near_out)"
fi
# disallow of the near host must leave the exact-conflicting host alone.
env EGRESSLOCK_CONF="$AH/near.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow-host near git.example.test:443 >/dev/null 2>&1
if ! grep -qF '    rule allow-host git.example.test:443' "$AH/near.conf" \
    && grep -qF 'rule allow-host gitXexample.test:443' "$AH/near.conf"; then
    a38 pass
else
    a38 fail "R-038-1f2: disallow-host near-collision deletes the right line"
fi

arc38_pass=$pass; arc38_fail=$fail

# --- ARC-31: denied filters allowlisted hosts ----------------------------
pass=0; fail=0
a31() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

AD="$TESTROOT/h31"; rm -rf "$AD"; mkdir -p "$AD"
cat > "$AD/gw.conf" <<'EOF'
profile gw 10.199.20.0/24
    rule gateway-only
    gateway 10.199.20.2 3128 gw-allowlist
EOF
printf 'allowed.example.test\n' > "$AD/gw-allowlist"
: > "$STATE/running/egresslock-gateway-gw"
cat > "$STATE/containers-egresslock-gateway-gw.access.log" <<EOF
$(date +%s).000    120 10.199.20.5 TCP_DENIED/403 0 CONNECT allowed.example.test:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.20.5 TCP_DENIED/403 0 CONNECT blocked.example.test:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.20.5 TCP_DENIED/403 0 CONNECT blocked.example.test:443 - HIER_NONE/- -
EOF

# 1. default filters out the allowlisted host, de-dupes the rest.
den_out="$(env EGRESSLOCK_CONF="$AD/gw.conf" egresslock denied gw 2>&1)"; den_rc=$?
if [[ "$den_rc" == 0 && "$den_out" == *"blocked.example.test"* && "$den_out" != *"allowed.example.test"* \
      && "$(grep -c 'blocked.example.test' <<<"$den_out")" == 1 ]]; then
    a31 pass
else
    a31 fail "denied filters allowlisted host (rc=$den_rc, out: $den_out)"
fi

# 2. --all shows everything (pre-ARC-31 behavior).
all_out="$(env EGRESSLOCK_CONF="$AD/gw.conf" egresslock denied gw --all 2>&1)"; all_rc=$?
[[ "$all_rc" == 0 && "$all_out" == *"allowed.example.test"* && "$all_out" == *"blocked.example.test"* ]] \
    && a31 pass || a31 fail "denied --all shows all (rc=$all_rc, out: $all_out)"

# 3. unknown flag -> exit 2.
b_out="$(env EGRESSLOCK_CONF="$AD/gw.conf" egresslock denied gw --bogus 2>&1)"; b_rc=$?
[[ "$b_rc" == 2 && "$b_out" == *"--all"* ]] \
    && a31 pass || a31 fail "denied bad flag (rc=$b_rc, out: $b_out)"

# R-031-1 finding 1: a leading-dot allowlist entry ('.example.test')
# covers the bare host AND every subdomain per Squid dstdomain — the
# filter must omit a host that falls under it, not just exact matches.
AD2="$TESTROOT/h31b"; rm -rf "$AD2"; mkdir -p "$AD2"
cat > "$AD2/gw.conf" <<'EOF'
profile gw 10.199.21.0/24
    rule gateway-only
    gateway 10.199.21.2 3128 gw-allowlist
EOF
printf '.example.test\n' > "$AD2/gw-allowlist"
: > "$STATE/running/egresslock-gateway-gw"
cat > "$STATE/containers-egresslock-gateway-gw.access.log" <<EOF
$(date +%s).000    120 10.199.21.5 TCP_DENIED/403 0 CONNECT sub.example.test:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.21.5 TCP_DENIED/403 0 CONNECT example.test:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.21.5 TCP_DENIED/403 0 CONNECT other.example.net:443 - HIER_NONE/- -
EOF
ld_out="$(env EGRESSLOCK_CONF="$AD2/gw.conf" egresslock denied gw 2>&1)"; ld_rc=$?
if [[ "$ld_rc" == 0 && "$ld_out" != *"sub.example.test"* && "$ld_out" != *"example.test"* \
      && "$ld_out" == *"other.example.net"* ]]; then
    a31 pass
else
    a31 fail "R-031-1f1: leading-dot allowlist filters subdomains+bare host (rc=$ld_rc, out: $ld_out)"
fi

arc31_pass=$pass; arc31_fail=$fail

# --- ARC-41: denied surfaces plain-HTTP (GET/port-80) denials -----------
pass=0; fail=0
a41() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# 1. GET-only log (empty allowlist): denied and --all both emit host:80 (D1),
#    and a non-denied TCP_MISS row is excluded.
AD3="$TESTROOT/h41"; rm -rf "$AD3"; mkdir -p "$AD3"
cat > "$AD3/gw.conf" <<'EOF'
profile gw 10.199.30.0/24
    rule gateway-only
    gateway 10.199.30.2 3128 gw-allowlist
EOF
: > "$AD3/gw-allowlist"
: > "$STATE/running/egresslock-gateway-gw"
cat > "$STATE/containers-egresslock-gateway-gw.access.log" <<EOF
$(date +%s).000    120 10.199.30.5 TCP_DENIED/403 3454 GET http://deb.debian.org/debian/dists/trixie/InRelease - HIER_NONE/- text/html
$(date +%s).000    120 10.199.30.5 TCP_DENIED/403 3454 GET http://deb.debian.org/debian/dists/trixie-updates/InRelease - HIER_NONE/- text/html
$(date +%s).000    120 10.199.30.5 TCP_MISS/200 3454 GET http://allowed.example.test/x - HIER_NONE/- text/html
EOF
g_out="$(env EGRESSLOCK_CONF="$AD3/gw.conf" egresslock denied gw 2>&1)"; g_rc=$?
if [[ "$g_rc" == 0 && "$g_out" == *"deb.debian.org:80"* \
      && "$(grep -c 'deb.debian.org:80' <<<"$g_out")" == 1 ]]; then
    a41 pass
else
    a41 fail "GET denial emitted as host:80, de-duped (rc=$g_rc, out: $g_out)"
fi
all_out="$(env EGRESSLOCK_CONF="$AD3/gw.conf" egresslock denied gw --all 2>&1)"; all_rc=$?
[[ "$all_rc" == 0 && "$all_out" == *"deb.debian.org:80"* && "$all_out" != *"allowed.example.test"* ]] \
    && a41 pass || a41 fail "--all union excludes non-DENIED rows (rc=$all_rc, out: $all_out)"

# 2. allow deb.debian.org:80 -> filtered denied no longer lists it (D3);
#    --all still does (raw log, pre-ARC-31).
printf 'deb.debian.org:80\n' >> "$AD3/gw-allowlist"
f_out="$(env EGRESSLOCK_CONF="$AD3/gw.conf" egresslock denied gw 2>&1)"; f_rc=$?
[[ "$f_rc" == 0 && "$f_out" != *"deb.debian.org"* ]] \
    && a41 pass || a41 fail "D3: :80 allowlist hides :80 denial (rc=$f_rc, out: $f_out)"
all_out="$(env EGRESSLOCK_CONF="$AD3/gw.conf" egresslock denied gw --all 2>&1)"
[[ "$all_out" == *"deb.debian.org:80"* ]] \
    && a41 pass || a41 fail "--all still lists :80 after allow (out: $all_out)"

# 3. Mixed CONNECT + GET with a bare (443-group) allowlist entry: the bare
#    entry hides only the CONNECT row; the :80 row stays (D2/D3). HEAD and
#    POST http(s) URLs are included; an explicit :8080 port is preserved.
AD4="$TESTROOT/h41b"; rm -rf "$AD4"; mkdir -p "$AD4"
cat > "$AD4/gw.conf" <<'EOF'
profile gw 10.199.31.0/24
    rule gateway-only
    gateway 10.199.31.2 3128 gw-allowlist
EOF
printf 'blocked.example.test\n' > "$AD4/gw-allowlist"
: > "$STATE/running/egresslock-gateway-gw"
cat > "$STATE/containers-egresslock-gateway-gw.access.log" <<EOF
$(date +%s).000    120 10.199.31.5 TCP_DENIED/403 0 CONNECT blocked.example.test:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.31.5 TCP_DENIED/403 3454 GET http://blocked.example.test/ - HIER_NONE/- text/html
$(date +%s).000    120 10.199.31.5 TCP_DENIED/403 3454 HEAD http://blocked.example.test/head - HIER_NONE/- text/html
$(date +%s).000    120 10.199.31.5 TCP_DENIED/403 3454 POST http://api.example.net:8080/submit - HIER_NONE/- text/html
EOF
m_out="$(env EGRESSLOCK_CONF="$AD4/gw.conf" egresslock denied gw 2>&1)"; m_rc=$?
if [[ "$m_rc" == 0 && "$(grep -c '^blocked.example.test$' <<<"$m_out")" == 0 \
      && "$(grep -c 'blocked.example.test:80' <<<"$m_out")" == 1 \
      && "$m_out" == *"api.example.net:8080"* ]]; then
    a41 pass
else
    a41 fail "D2/D3: bare 443 allowlist hides CONNECT row, keeps :80; HEAD/POST included (rc=$m_rc, out: $m_out)"
fi

# 4. Leading-dot 443 allowlist (R-031-1) hides the CONNECT subdomain but
#    NOT its :80 denial (D3 port-awareness).
AD5="$TESTROOT/h41c"; rm -rf "$AD5"; mkdir -p "$AD5"
cat > "$AD5/gw.conf" <<'EOF'
profile gw 10.199.32.0/24
    rule gateway-only
    gateway 10.199.32.2 3128 gw-allowlist
EOF
printf '.example.test\n' > "$AD5/gw-allowlist"
: > "$STATE/running/egresslock-gateway-gw"
cat > "$STATE/containers-egresslock-gateway-gw.access.log" <<EOF
$(date +%s).000    120 10.199.32.5 TCP_DENIED/403 0 CONNECT sub.example.test:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.32.5 TCP_DENIED/403 3454 GET http://sub.example.test/ - HIER_NONE/- text/html
EOF
ld_out="$(env EGRESSLOCK_CONF="$AD5/gw.conf" egresslock denied gw 2>&1)"; ld_rc=$?
if [[ "$ld_rc" == 0 && "$(grep -c '^sub.example.test$' <<<"$ld_out")" == 0 \
      && "$(grep -c 'sub.example.test:80' <<<"$ld_out")" == 1 ]]; then
    a41 pass
else
    a41 fail "leading-dot 443 hides CONNECT, keeps :80 (rc=$ld_rc, out: $ld_out)"
fi

# 5. Non-HTTP schemes, userinfo, IPv6 literals, and unparseable URLs are
#    skipped best-effort; the command stays rc 0 and CONNECT still lists.
AD6="$TESTROOT/h41d"; rm -rf "$AD6"; mkdir -p "$AD6"
cat > "$AD6/gw.conf" <<'EOF'
profile gw 10.199.33.0/24
    rule gateway-only
    gateway 10.199.33.2 3128 gw-allowlist
EOF
: > "$AD6/gw-allowlist"
: > "$STATE/running/egresslock-gateway-gw"
cat > "$STATE/containers-egresslock-gateway-gw.access.log" <<EOF
$(date +%s).000    120 10.199.33.5 TCP_DENIED/403 0 CONNECT ok.example.test:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.33.5 TCP_DENIED/403 3454 GET ftp://bad.example.test/file - HIER_NONE/- text/html
$(date +%s).000    120 10.199.33.5 TCP_DENIED/403 3454 GET http://user:pass@bad.example.test/x - HIER_NONE/- text/html
$(date +%s).000    120 10.199.33.5 TCP_DENIED/403 3454 GET http://[::1]:8080/x - HIER_NONE/- text/html
$(date +%s).000    120 10.199.33.5 TCP_DENIED/403 3454 GET not-a-url - HIER_NONE/- text/html
EOF
u_out="$(env EGRESSLOCK_CONF="$AD6/gw.conf" egresslock denied gw 2>&1)"; u_rc=$?
if [[ "$u_rc" == 0 && "$(grep -c '^ok.example.test$' <<<"$u_out")" == 1 \
      && "$u_out" != *"bad.example.test"* && "$u_out" != *"::1"* ]]; then
    a41 pass
else
    a41 fail "non-HTTP/userinfo/IPv6/malformed skipped; CONNECT still listed (rc=$u_rc, out: $u_out)"
fi

arc41_pass=$pass; arc41_fail=$fail

# --- ARC-42: denied time window (--days N, default 14) ------------------
pass=0; fail=0
a42() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

AD7="$TESTROOT/h42"; rm -rf "$AD7"; mkdir -p "$AD7"
cat > "$AD7/gw.conf" <<'EOF'
profile gw 10.199.40.0/24
    rule gateway-only
    gateway 10.199.40.2 3128 gw-allowlist
EOF
: > "$AD7/gw-allowlist"
: > "$STATE/running/egresslock-gateway-gw"
now_sec="$(date +%s)"
old_sec="$(( now_sec - 15 * 86400 ))"

# 1. recent + 15-day-old denied: default prints only the recent one;
#    --days 0 prints both; --all --days 0 prints both raw.
cat > "$STATE/containers-egresslock-gateway-gw.access.log" <<EOF
$old_sec.000    120 10.199.40.5 TCP_DENIED/403 0 CONNECT old.example.test:443 - HIER_NONE/- -
$now_sec.000    120 10.199.40.5 TCP_DENIED/403 0 CONNECT recent.example.test:443 - HIER_NONE/- -
EOF
w_out="$(env EGRESSLOCK_CONF="$AD7/gw.conf" egresslock denied gw 2>&1)"; w_rc=$?
if [[ "$w_rc" == 0 && "$w_out" == *"recent.example.test"* && "$w_out" != *"old.example.test"* ]]; then
    a42 pass
else
    a42 fail "default 14-day window hides old denial (rc=$w_rc, out: $w_out)"
fi
z_out="$(env EGRESSLOCK_CONF="$AD7/gw.conf" egresslock denied gw --days 0 2>&1)"; z_rc=$?
[[ "$z_rc" == 0 && "$z_out" == *"old.example.test"* && "$z_out" == *"recent.example.test"* ]] \
    && a42 pass || a42 fail "--days 0 shows full log (rc=$z_rc, out: $z_out)"
za_out="$(env EGRESSLOCK_CONF="$AD7/gw.conf" egresslock denied gw --all --days 0 2>&1)"; za_rc=$?
[[ "$za_rc" == 0 && "$za_out" == *"old.example.test"* && "$za_out" == *"recent.example.test"* ]] \
    && a42 pass || a42 fail "--all --days 0 raw union (rc=$za_rc, out: $za_out)"

# 2. old-only log: stdout empty rc 0, stderr carries the D3 note.
cat > "$STATE/containers-egresslock-gateway-gw.access.log" <<EOF
$old_sec.000    120 10.199.40.5 TCP_DENIED/403 0 CONNECT old.example.test:443 - HIER_NONE/- -
EOF
o_out="$(env EGRESSLOCK_CONF="$AD7/gw.conf" egresslock denied gw 2>/dev/null)"; o_rc=$?
o_err="$(env EGRESSLOCK_CONF="$AD7/gw.conf" egresslock denied gw 2>&1 >/dev/null)"
if [[ "$o_rc" == 0 && -z "$o_out" && "$o_err" == *"no denials in the last 14 days"* && "$o_err" == *"--days 0"* ]]; then
    a42 pass
else
    a42 fail "old-only log: empty stdout + D3 stderr note (rc=$o_rc, out=[$o_out], err=[$o_err])"
fi

# 3. empty/missing log: today's stdout message, NO note.
: > "$STATE/containers-egresslock-gateway-gw.access.log"
e_out="$(env EGRESSLOCK_CONF="$AD7/gw.conf" egresslock denied gw 2>&1)"; e_rc=$?
[[ "$e_rc" == 0 && "$e_out" == *"no gateway log"* && "$e_out" != *"no denials in the last"* ]] \
    && a42 pass || a42 fail "empty log: gateway message, no note (rc=$e_rc, out: $e_out)"

# 4. --days validation: missing value / negative / leading zero / unknown flag -> exit 2.
cat > "$STATE/containers-egresslock-gateway-gw.access.log" <<EOF
$now_sec.000    120 10.199.40.5 TCP_DENIED/403 0 CONNECT recent.example.test:443 - HIER_NONE/- -
EOF
for bad in "--days" "--days -1" "--days 014" "--bogus"; do
    # shellcheck disable=SC2086
    b_out="$(env EGRESSLOCK_CONF="$AD7/gw.conf" egresslock denied gw $bad 2>&1)"; b_rc=$?
    [[ "$b_rc" == 2 ]] && a42 pass || a42 fail "denied $bad -> exit 2 (rc=$b_rc, out: $b_out)"
done

# 5. flag order equivalence.
f1="$(env EGRESSLOCK_CONF="$AD7/gw.conf" egresslock denied gw --all --days 1 2>&1)"
f2="$(env EGRESSLOCK_CONF="$AD7/gw.conf" egresslock denied gw --days 1 --all 2>&1)"
[[ "$f1" == "$f2" && "$f1" == *"recent.example.test"* ]] \
    && a42 pass || a42 fail "flag order equivalence (f1=[$f1] f2=[$f2])"

arc42_pass=$pass; arc42_fail=$fail

# --- ARC-43: allowlist — print the allowlist file raw ---------------------
pass=0; fail=0
a43() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

AD8="$TESTROOT/h43"; rm -rf "$AD8"; mkdir -p "$AD8"
cat > "$AD8/gw.conf" <<'EOF'
profile gw 10.199.50.0/24
    rule gateway-only
    gateway 10.199.50.2 3128 gw-allowlist
EOF
printf '# comment line\nexample.test\nother.test:8443\n' > "$AD8/gw-allowlist"
: > "$STATE/running/egresslock-gateway-gw"

# 1. prints the file bytes (comments included); path stays off stdout.
al_out="$(env EGRESSLOCK_CONF="$AD8/gw.conf" egresslock allowlist gw 2>/dev/null)"; al_rc=$?
al_err="$(env EGRESSLOCK_CONF="$AD8/gw.conf" egresslock allowlist gw 2>&1 >/dev/null)"
if [[ "$al_rc" == 0 && "$al_out" == *"# comment line"* && "$al_out" == *"example.test"* \
      && "$al_out" == *"other.test:8443"* && "$al_err" != *"gw-allowlist"* ]]; then
    a43 pass
else
    a43 fail "allowlist prints raw file, path not on stdout (rc=$al_rc, out: $al_out)"
fi

# 2. empty allowlist -> empty stdout (payload contract), rc 0; the
#    resolution line is stderr-only (EGL-117) and must not bleed here.
: > "$AD8/gw-allowlist"
ae_out="$(env EGRESSLOCK_CONF="$AD8/gw.conf" egresslock allowlist gw 2>/dev/null)"; ae_rc=$?
[[ "$ae_rc" == 0 && -z "$ae_out" ]] \
    && a43 pass || a43 fail "allowlist empty allowlist (rc=$ae_rc, out: [$ae_out])"

# 3. comments-only starter -> the comment bytes, no invented entries.
printf '# main-allowlist — starter\n# EMPTY by design\n' > "$AD8/gw-allowlist"
ac_out="$(env EGRESSLOCK_CONF="$AD8/gw.conf" egresslock allowlist gw 2>&1)"; ac_rc=$?
[[ "$ac_rc" == 0 && "$ac_out" == *"# main-allowlist"* && "$ac_out" != *"gateway-only"* ]] \
    && a43 pass || a43 fail "allowlist comments-only (rc=$ac_rc, out: $ac_out)"

# 4. extra arg -> exit 2.
ax_out="$(env EGRESSLOCK_CONF="$AD8/gw.conf" egresslock allowlist gw extra 2>&1)"; ax_rc=$?
[[ "$ax_rc" == 2 && "$ax_out" == *"usage"* ]] \
    && a43 pass || a43 fail "allowlist extra arg (rc=$ax_rc, out: $ax_out)"

# ARC-45: the old `allowed` name is now an unknown command (no alias).
old_out="$(env EGRESSLOCK_CONF="$AD8/gw.conf" egresslock allowed gw 2>&1)"; old_rc=$?
[[ "$old_rc" == 2 && "$old_out" == *"unknown command"* ]] \
    && a43 pass || a43 fail "ARC-45: old 'allowed' is unknown (rc=$old_rc, out: $old_out)"

# 5. non-gateway profile -> fail closed naming gateway.
cat > "$AD8/plain.conf" <<'EOF'
profile plain 10.199.51.0/24
    rule allow-host plain.example.test:443
EOF
an_out="$(env EGRESSLOCK_CONF="$AD8/plain.conf" egresslock allowlist plain 2>&1)"; an_rc=$?
[[ "$an_rc" != 0 && "$an_out" == *"gateway"* ]] \
    && a43 pass || a43 fail "allowlist non-gateway fails closed (rc=$an_rc, out: $an_out)"

# 6. missing allowlist file -> fail closed naming the path.
cat > "$AD8/miss.conf" <<'EOF'
profile gw 10.199.52.0/24
    rule gateway-only
    gateway 10.199.52.2 3128 nope-allowlist
EOF
am_out="$(env EGRESSLOCK_CONF="$AD8/miss.conf" egresslock allowlist gw 2>&1)"; am_rc=$?
[[ "$am_rc" != 0 && "$am_out" == *"nope-allowlist"* ]] \
    && a43 pass || a43 fail "allowlist missing file names path (rc=$am_rc, out: $am_out)"

arc43_pass=$pass; arc43_fail=$fail

# --- ARC-44: proxy-env tokens + network single-token output -------------
pass=0; fail=0
a44() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# 1. proxyip / proxyport / noproxy exact tokens; no `using config` on stdout.
AD9="$TESTROOT/h44"; rm -rf "$AD9"; mkdir -p "$AD9"
cat > "$AD9/gw.conf" <<'EOF'
profile gw 10.199.60.0/24
    rule gateway-only
    gateway 10.199.60.2 3128 gw-allowlist
    no-proxy api.local
EOF
: > "$AD9/gw-allowlist"
: > "$STATE/running/egresslock-gateway-gw"
ip_out="$(env EGRESSLOCK_CONF="$AD9/gw.conf" egresslock proxy-env gw proxyip 2>/dev/null)"; ip_rc=$?
port_out="$(env EGRESSLOCK_CONF="$AD9/gw.conf" egresslock proxy-env gw proxyport 2>/dev/null)"; port_rc=$?
np_out="$(env EGRESSLOCK_CONF="$AD9/gw.conf" egresslock proxy-env gw noproxy 2>/dev/null)"; np_rc=$?
[[ "$ip_rc" == 0 && "$ip_out" == "10.199.60.2" && "$port_rc" == 0 && "$port_out" == "3128" \
  && "$np_rc" == 0 && "$np_out" == "localhost,127.0.0.1,api.local" ]] \
    && a44 pass || a44 fail "proxy-env tokens exact (ip=[$ip_out] port=[$port_out] np=[$np_out])"

# 2. bare proxy-env still prints the six assignment lines (back-compat);
#    the EGL-117 resolution line is stderr-only (captured separately).
full_out="$(env EGRESSLOCK_CONF="$AD9/gw.conf" egresslock proxy-env gw 2>"$TESTROOT/e44.err")"; full_rc=$?
if [[ "$full_rc" == 0 && "$full_out" == *"HTTP_PROXY=http://10.199.60.2:3128"* \
      && "$full_out" == *"NO_PROXY=localhost,127.0.0.1,api.local"* \
      && "$(grep -c '=' <<<"$full_out")" == 6 \
      && "$(cat $TESTROOT/e44.err)" == *"scoped: EGRESSLOCK_CONF="* ]]; then
    a44 pass
else
    a44 fail "bare proxy-env six lines (rc=$full_rc, out: $full_out, err: $(cat $TESTROOT/e44.err))"
fi

# 3. unknown token / extra arg -> exit 2, no assignment lines on stdout.
for bad in "bogus" "proxyip extra"; do
    # shellcheck disable=SC2086
    t_out="$(env EGRESSLOCK_CONF="$AD9/gw.conf" egresslock proxy-env gw $bad 2>/dev/null)"; t_rc=$?
    [[ "$t_rc" == 2 && -z "$t_out" ]] \
        && a44 pass || a44 fail "proxy-env token '$bad' exit 2 empty stdout (rc=$t_rc, out: [$t_out])"
done

# 4. non-gateway + token fails closed; non-gateway bare stays rc 0 empty.
ng_out="$(env EGRESSLOCK_CONF="$AD8/plain.conf" egresslock proxy-env plain proxyip 2>&1)"; ng_rc=$?
[[ "$ng_rc" != 0 && "$ng_out" == *"gateway"* ]] \
    && a44 pass || a44 fail "proxy-env non-gateway token fails closed (rc=$ng_rc, out: $ng_out)"
ngb_out="$(env EGRESSLOCK_CONF="$AD8/plain.conf" egresslock proxy-env plain 2>/dev/null)"; ngb_rc=$?
[[ "$ngb_rc" == 0 && -z "$ngb_out" ]] \
    && a44 pass || a44 fail "proxy-env non-gateway bare rc 0 empty (rc=$ngb_rc, out: [$ngb_out])"

# 5. network is a single safe token; extra arg -> exit 2.
net_out="$(env EGRESSLOCK_CONF="$AD9/gw.conf" egresslock network gw 2>/dev/null)"; net_rc=$?
netx_out="$(env EGRESSLOCK_CONF="$AD9/gw.conf" egresslock network gw extra 2>&1)"; netx_rc=$?
[[ "$net_rc" == 0 && "$net_out" == "egresslock-gw" && "$netx_rc" == 2 ]] \
    && a44 pass || a44 fail "network single token + extra-arg guard (net=[$net_out] rc=$net_rc xrc=$netx_rc)"

arc44_pass=$pass; arc44_fail=$fail

# --- ARC-50: focused kit input→sink security review (D3 probes) ---------
# Probes that pin the review claim for rows the code already enforces.
# Each asserts a fail-closed/validated behavior that MUST stay green.
# (R-050-D3: a section that cannot fail the suite is inert — arc50_fail
# is wired into total_fail below.)
pass=0; fail=0
a50() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S50="$TESTROOT/s50"; rm -rf "$S50"; mkdir -p "$S50"
cat > "$S50/gw.conf" <<'EOF'
profile s50 10.199.70.0/24
    rule gateway-only
    gateway 10.199.70.2 3128 s50-allowlist
EOF
: > "$S50/s50-allowlist"

# D3.1 — allow argv cannot carry shell metachars / newlines.
for bad in 'foo;rm' 'foo$(reboot)' $'foo\nbar'; do
    pre_md5="$(md5sum "$S50/s50-allowlist" | cut -d' ' -f1)"
    pre_runs="$(wc -l < "$STATE/runlog")"
    a50_out="$(egresslock --config "$S50/gw.conf" allow s50 "$bad" 2>&1)"; a50_rc=$?
    post_md5="$(md5sum "$S50/s50-allowlist" | cut -d' ' -f1)"
    post_runs="$(wc -l < "$STATE/runlog")"
    if [[ "$a50_rc" == 2 && "$pre_md5" == "$post_md5" && "$post_runs" == "$pre_runs" ]]; then
        a50 pass
    else
        a50 fail "D3.1 allow argv [$(printf %q "$bad")] (rc=$a50_rc unchanged=$([ "$pre_md5" == "$post_md5" ] && echo yes || echo no) newruns=$((post_runs-pre_runs)))"
    fi
done

# D3.2 — ${VAR} in conf cannot expand into a second directive (newline).
cat > "$S50/nl.conf" <<'EOF'
profile s50n 10.199.71.0/24
    rule allow-host ${H}:443
EOF
a50_out="$(H=$'x.example\n    rule public-only' egresslock --config "$S50/nl.conf" list 2>&1)"; a50_rc=$?
[[ "$a50_rc" == 2 && "$a50_out" == *"invalid host"* ]] && a50 pass || a50 fail "D3.2 conf newline not a second directive (rc=$a50_rc, out: $a50_out)"

# D3.5 — gateway podman run carries --cap-drop=all + no-new-privileges.
egresslock --config "$S50/gw.conf" ensure s50 >/dev/null 2>&1; a50_rc=$?
if [[ "$a50_rc" == 0 ]] \
   && grep -q -- '--cap-drop=all' "$STATE/runlog" \
   && grep -q -- 'no-new-privileges' "$STATE/runlog"; then
    a50 pass
else
    a50 fail "D3.5 gateway run has cap-drop=all + no-new-privileges (ensure rc=$a50_rc)"
fi

# D3.3 — empty allowlist ⇒ terminal deny-all, no allow rule.
: > "$S50/s50-allowlist"
egresslock --config "$S50/gw.conf" ensure s50 >/dev/null 2>&1; a50_rc=$?
sq="$(find "$STATE" -name 'containers-egresslock-gateway-s50.squid-gw.conf' 2>/dev/null | head -1)"
if [[ "$a50_rc" == 0 && -n "$sq" ]] \
   && grep -q 'http_access deny all' "$sq" \
   && ! grep -q 'http_access allow' "$sq"; then
    a50 pass
else
    a50 fail "D3.3 empty allowlist is deny-all (rc=$a50_rc sq=[$sq] $(grep -c 'http_access allow' "$sq" 2>/dev/null))"
fi

# D3.4 — allowlist line that cannot be a host fails closed at generation.
printf 'foo;bar\n' > "$S50/s50-allowlist"
a50_out="$(egresslock --config "$S50/gw.conf" ensure s50 2>&1)"; a50_rc=$?
[[ "$a50_rc" != 0 && "$a50_out" == *"fail closed"* ]] && a50 pass || a50 fail "D3.4 poisoned allowlist line fails closed (rc=$a50_rc, out: $a50_out)"

# D3.6 — no live `eval` on D1 bash files (only comments match).
eval_hits="$(grep -nE '(^|[^[:alpha:]])eval ' \
    "$TREE_ROOT/egresslock" \
    "$TREE_ROOT/egresslock-setup" \
    "$TREE_ROOT/egresslock-start" \
    "$TREE_ROOT/egresslock-verify" \
    "$TREE_ROOT/install-kit.sh" \
    "$TREE_ROOT/uninstall-kit.sh" \
    "$TREE_ROOT/build-gateway" 2>/dev/null \
    | grep -vE ':\s*#|never eval|no eval|not eval|parse-only|never sourced' \
    | grep -E ':[0-9]+:\s*[^#]' || true)"
if [[ -z "$eval_hits" ]]; then
    a50 pass
else
    a50 fail "D3.6 unexpected live eval on D1 files: $eval_hits"
fi

arc50_pass=$pass; arc50_fail=$fail

# --- ARC-56: GW_DNS_NAMESERVERS strict IPv4 list (ARC-50 D7) ------------
# The override is interpolated into squid.conf dns_nameservers; it must
# be an ASCII-space list of cfg_is_ipv4-valid addresses (D1).
pass=0; fail=0
a56() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S56="$TESTROOT/s56"; rm -rf "$S56"; mkdir -p "$S56"
cat > "$S56/gw.conf" <<'EOF'
profile s56 10.199.72.0/24
    rule gateway-only
    gateway 10.199.72.2 3128 s56-allowlist
EOF
: > "$S56/s56-allowlist"

# default unset still works and emits the default nameserver.
egresslock --config "$S56/gw.conf" ensure s56 >/dev/null 2>&1; a56_rc=$?
sq56="$(find "$STATE" -name 'containers-egresslock-gateway-s56.squid-gw.conf' 2>/dev/null | head -1)"
[[ "$a56_rc" == 0 && -n "$sq56" && "$(grep -m1 'dns_nameservers' "$sq56")" == "dns_nameservers 169.254.1.1" ]] \
    && a56 pass || a56 fail "D default unset → 169.254.1.1 (rc=$a56_rc sq=[$sq56] $(grep -m1 dns_nameservers "$sq56" 2>/dev/null))"

# single valid + two valid still work.
for val in "8.8.8.8" "8.8.8.8 1.1.1.1"; do
    egresslock --config "$S56/gw.conf" teardown s56 >/dev/null 2>&1 || true
    a56_out="$(GW_DNS_NAMESERVERS="$val" egresslock --config "$S56/gw.conf" ensure s56 2>&1)"; a56_rc=$?
    sq56="$(find "$STATE" -name 'containers-egresslock-gateway-s56.squid-gw.conf' 2>/dev/null | head -1)"
    [[ "$a56_rc" == 0 && -n "$sq56" && "$(grep -m1 'dns_nameservers' "$sq56")" == "dns_nameservers $val" ]] \
        && a56 pass || a56 fail "D valid '$val' (rc=$a56_rc $(grep -m1 dns_nameservers "$sq56" 2>/dev/null))"
done

# invalid: bad octet, newline, double space.
for val in "999.999" $'8.8.8.8\n1.1.1.1' "8.8.8.8  1.1.1.1" "1.2.3"; do
    egresslock --config "$S56/gw.conf" teardown s56 >/dev/null 2>&1 || true
    a56_out="$(GW_DNS_NAMESERVERS="$val" egresslock --config "$S56/gw.conf" ensure s56 2>&1)"; a56_rc=$?
    [[ "$a56_rc" != 0 && "$a56_out" == *"GW_DNS_NAMESERVERS"* ]] \
        && a56 pass || a56 fail "D invalid [$(printf %q "$val")] not fail-closed (rc=$a56_rc, out: $a56_out)"
done

arc56_pass=$pass; arc56_fail=$fail

# --- ARC-58: relative gateway allowlist path is a confdir basename ------
# No '/' and no '..' segment in relative paths (D1); absolute unchanged.
pass=0; fail=0
a58() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S58="$TESTROOT/s58"; rm -rf "$S58"; mkdir -p "$S58"
for bad in '../other/secret' 'foo/bar' '..'; do
    # EGL-78-D5: the old noisy `cat > "$S58/$bad.conf"` (which always
    # failed with "No such file or directory" for the two bad paths) is
    # gone — the test only reads the sanitized-basename conf written below.
    # sanitize the filename for the .conf suffix
    safe="$(printf %s "$bad" | tr '/.' '__')"
    printf 'profile g 10.199.73.0/24\n    rule gateway-only\n    gateway 10.199.73.2 3128 %s\n' "$bad" > "$S58/$safe.conf"
    a58_out="$(egresslock --config "$S58/$safe.conf" list 2>&1)"; a58_rc=$?
    [[ "$a58_rc" == 2 && "$a58_out" == *"allowlist path"* ]] \
        && a58 pass || a58 fail "D bad relative '$bad' not rejected (rc=$a58_rc, out: $a58_out)"
done

# normal relative basename + absolute path still load.
cat > "$S58/ok.conf" <<'EOF'
profile g 10.199.74.0/24
    rule gateway-only
    gateway 10.199.74.2 3128 g-allowlist
EOF
: > "$S58/g-allowlist"
a58_out="$(egresslock --config "$S58/ok.conf" list 2>&1)"; a58_rc=$?
[[ "$a58_rc" == 0 && "$a58_out" == *"g"* ]] && a58 pass || a58 fail "D normal relative basename loads (rc=$a58_rc, out: $a58_out)"

# EGL-80-L6: absolute allowlist path — but under TESTROOT, not a fixed
# shared /tmp file (no real-environment write, no cross-run collision).
abs58="$TESTROOT/s58-abs-allowlist"
cat > "$S58/abs.conf" <<EOF
profile a2 10.199.75.0/24
    rule gateway-only
    gateway 10.199.75.2 3128 $abs58
EOF
: > "$abs58"
a58_out="$(egresslock --config "$S58/abs.conf" list 2>&1)"; a58_rc=$?
[[ "$a58_rc" == 0 && "$a58_out" == *"a2"* ]] && a58 pass || a58 fail "D absolute path loads (rc=$a58_rc, out: $a58_out)"

arc58_pass=$pass; arc58_fail=$fail

# --- ARC-51: allowlist grammar rejects IPv4 literals (names only) ---------
# D1: `allow` of a literal exits 2 with the allowlist untouched; a literal
# line in the file fails `ensure` closed (not skipped). D2: `allow-host`
# still accepts a literal (conf rule + CLI insert). Hostname cases
# unchanged.
pass=0; fail=0
a51() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S51="$TESTROOT/s51"; rm -rf "$S51"; mkdir -p "$S51"
cat > "$S51/gw.conf" <<'EOF'
profile s51 10.199.76.0/24
    rule gateway-only
    gateway 10.199.76.2 3128 s51-allowlist
EOF
: > "$S51/s51-allowlist"

# D1.1 — allow of a literal and a literal:port -> rc 2, file unchanged, no
# gateway run. Message points the operator at allow-host.
for lit in '203.0.113.7:11434' '10.1.2.3' '.10.1.2.3'; do
    pre_md5="$(md5sum "$S51/s51-allowlist" | cut -d' ' -f1)"
    pre_runs="$(wc -l < "$STATE/runlog")"
    a51_out="$(egresslock --config "$S51/gw.conf" allow s51 "$lit" 2>&1)"; a51_rc=$?
    post_md5="$(md5sum "$S51/s51-allowlist" | cut -d' ' -f1)"
    post_runs="$(wc -l < "$STATE/runlog")"
    if [[ "$a51_rc" == 2 && "$pre_md5" == "$post_md5" && "$post_runs" == "$pre_runs" \
          && "$a51_out" == *"allow-host"* ]]; then
        a51 pass
    else
        a51 fail "D1.1 allow literal [$(printf %q "$lit")] (rc=$a51_rc unchanged=$([ "$pre_md5" == "$post_md5" ] && echo yes || echo no) newruns=$((post_runs-pre_runs)) msg=$a51_out)"
    fi
done

# D1.2 — a literal line in the allowlist file fails `ensure` closed (fail
# closed, not skipped).
printf '10.1.2.3\n' > "$S51/s51-allowlist"
a51_out="$(egresslock --config "$S51/gw.conf" ensure s51 2>&1)"; a51_rc=$?
[[ "$a51_rc" != 0 && "$a51_out" == *"allow-host"* ]] \
    && a51 pass || a51 fail "D1.2 literal allowlist line fails ensure closed (rc=$a51_rc, out: $a51_out)"
printf '203.0.113.7:11434\n' > "$S51/s51-allowlist"
a51_out="$(egresslock --config "$S51/gw.conf" ensure s51 2>&1)"; a51_rc=$?
[[ "$a51_rc" != 0 && "$a51_out" == *"allow-host"* ]] \
    && a51 pass || a51 fail "D1.2b literal:port allowlist line fails ensure closed (rc=$a51_rc, out: $a51_out)"

# D2.1 — a conf `rule allow-host <literal>:<port>` still loads (D2: the
# allow-host path takes hostname or IPv4 literal).
cat > "$S51/ah.conf" <<'EOF'
profile ah 10.199.77.0/24
    rule allow-host 10.1.2.3:443
EOF
a51_out="$(egresslock --config "$S51/ah.conf" list 2>&1)"; a51_rc=$?
[[ "$a51_rc" == 0 ]] && a51 pass || a51 fail "D2.1 conf rule allow-host literal loads (rc=$a51_rc, out: $a51_out)"

# D2.2 — CLI allow-host of a literal inserts the rule and re-ensures (mock
# DNS echoes the literal like real getent ahostsv4, ARC-12 drift knob).
cat > "$S51/gw2.conf" <<'EOF'
profile s51b 10.199.78.0/24
    rule gateway-only
    gateway 10.199.78.2 3128 s51-allowlist
EOF
: > "$S51/s51-allowlist"
a51_out="$(EGRESSLOCK_MOCK_DNS="10.1.2.3=10.1.2.3" egresslock --config "$S51/gw2.conf" allow-host s51b 10.1.2.3:443 2>&1)"; a51_rc=$?
if [[ "$a51_rc" == 0 && "$a51_out" == *"added: rule allow-host 10.1.2.3:443"* ]] \
   && grep -qF 'rule allow-host 10.1.2.3:443' "$S51/gw2.conf"; then
    a51 pass
else
    a51 fail "D2.2 CLI allow-host literal (rc=$a51_rc, out: $a51_out)"
fi

# D0 — normal hostname allow still works.
: > "$S51/s51-allowlist"
a51_out="$(egresslock --config "$S51/gw.conf" allow s51 example.com 2>&1)"; a51_rc=$?
[[ "$a51_rc" == 0 && "$a51_out" == *"added: example.com"* ]] \
    && a51 pass || a51 fail "D0 hostname allow unchanged (rc=$a51_rc, out: $a51_out)"

arc51_pass=$pass; arc51_fail=$fail

# --- ARC-59: leading '-' / flag-shaped tokens rejected (ARC-50 D7) -------
# D1: profile names must start [a-z0-9]; host fields start alnum or '.';
# env overrides (GW_IMAGE / ANCHOR_IMAGE / NFT_BIN) reject a non-empty
# value that starts with '-'. Happy paths unchanged.
pass=0; fail=0
a59() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# D1.1 — `profile -foo` is a config error (rc 2), not a live profile.
S59="$TESTROOT/s59"; rm -rf "$S59"; mkdir -p "$S59"
printf 'profile -foo 10.199.79.0/24\n' > "$S59/bad.conf"
a59_out="$(egresslock --config "$S59/bad.conf" list 2>&1)"; a59_rc=$?
[[ "$a59_rc" == 2 && "$a59_out" == *"invalid profile name"* ]] \
    && a59 pass || a59 fail "D1.1 conf profile -foo rejected (rc=$a59_rc, out: $a59_out)"

# D1.2 — a valid leading-alnum name (with later hyphens) still loads.
printf 'profile dev-llm 10.199.81.0/24\n' > "$S59/ok.conf"
a59_out="$(egresslock --config "$S59/ok.conf" list 2>&1)"; a59_rc=$?
[[ "$a59_rc" == 0 ]] && a59 pass || a59 fail "D1.2 dev-llm profile still loads (rc=$a59_rc, out: $a59_out)"

# D1.3 — init rejects a leading-dash name ('-x' is not a flag token, so it
# reaches the name validator; '--x' is rejected earlier by the option parser,
# also rc 2).
a59_out="$(egresslock init -x 2>&1)"; a59_rc=$?
[[ "$a59_rc" == 2 && "$a59_out" == *"invalid profile name"* ]] \
    && a59 pass || a59 fail "D1.3 init -x rejected (rc=$a59_rc, out: $a59_out)"

# D1.4 — init accepts a normal name (temp dest -> cleaned up).
a59_out="$(env EGRESSLOCK_CONF="$S59/init-dest/x.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock init dev-x --subnet 10.199.82.0/24 2>&1)"; a59_rc=$?
[[ "$a59_rc" == 0 ]] && a59 pass || a59 fail "D1.4 init dev-x works (rc=$a59_rc, out: $a59_out)"

# D1.5 — CLI `allow` of a leading-dash host exits 2, allowlist unchanged.
cat > "$S59/gw.conf" <<'EOF'
profile s59 10.199.83.0/24
    rule gateway-only
    gateway 10.199.83.2 3128 s59-allowlist
EOF
: > "$S59/s59-allowlist"
for bad in '--help' '-x'; do
    pre_md5="$(md5sum "$S59/s59-allowlist" | cut -d' ' -f1)"
    pre_runs="$(wc -l < "$STATE/runlog")"
    a59_out="$(egresslock --config "$S59/gw.conf" allow s59 "$bad" 2>&1)"; a59_rc=$?
    post_md5="$(md5sum "$S59/s59-allowlist" | cut -d' ' -f1)"
    post_runs="$(wc -l < "$STATE/runlog")"
    if [[ "$a59_rc" == 2 && "$pre_md5" == "$post_md5" && "$post_runs" == "$pre_runs" ]]; then
        a59 pass
    else
        a59 fail "D1.5 allow leading-dash [$(printf %q "$bad")] (rc=$a59_rc unchanged=$([ "$pre_md5" == "$post_md5" ] && echo yes || echo no) newruns=$((post_runs-pre_runs)) out=$a59_out)"
    fi
done

# D1.6 — CLI allow-host of a leading-dash host:port → rc 2.
a59_out="$(egresslock --config "$S59/gw.conf" allow-host s59 --help:443 2>&1)"; a59_rc=$?
[[ "$a59_rc" == 2 && "$a59_out" == *"invalid allow-host entry"* ]] \
    && a59 pass || a59 fail "D1.6 allow-host --help:443 rejected (rc=$a59_rc, out: $a59_out)"

# D1.7 — a poisoned allowlist line with a leading dash fails `ensure` closed.
printf -- '-bad\n' > "$S59/s59-allowlist"
a59_out="$(egresslock --config "$S59/gw.conf" ensure s59 2>&1)"; a59_rc=$?
[[ "$a59_rc" != 0 ]] && a59 pass || a59 fail "D1.7 allowlist '-bad' fails closed (rc=$a59_rc)"

# D1.8 — env overrides: `ensure` of a gateway profile with
# EGRESSLOCK_GW_IMAGE='-privileged' dies before a `podman run` could
# interpolate that token. The anchors already started (network first) is
# fine; the assert is that the token never reaches the runlog and the
# message names the variable.
cat > "$S59/gwok.conf" <<'EOF'
profile s59b 10.199.84.0/24
    rule gateway-only
    gateway 10.199.84.2 3128 s59-allowlist
EOF
: > "$S59/s59-allowlist"
: > "$STATE/runlog"
a59_out="$(EGRESSLOCK_GW_IMAGE='-privileged' egresslock --config "$S59/gwok.conf" ensure s59b 2>&1)"; a59_rc=$?
if [[ "$a59_rc" != 0 && "$a59_out" == *"EGRESSLOCK_GW_IMAGE"* ]] && ! grep -q -- '-privileged' "$STATE/runlog"; then
    a59 pass
else
    a59 fail "D1.8 GW_IMAGE '-privileged' dies pre-run (rc=$a59_rc runs=$(wc -l < "$STATE/runlog") token-in-runlog=$(grep -c -- '-privileged' "$STATE/runlog" || true) out=$a59_out)"
fi
# NFT_BIN is only interpolated into `podman unshare` (not a run); the guard
# still fires with rc non-zero and names the var — no runlog assert needed.
: > "$STATE/runlog"
a59_out="$(NFT_BIN='-privileged' egresslock --config "$S59/gwok.conf" ensure s59b 2>&1)"; a59_rc=$?
[[ "$a59_rc" != 0 && "$a59_out" == *"NFT_BIN"* ]] \
    && a59 pass || a59 fail "D1.8b NFT_BIN '-privileged' rejected (rc=$a59_rc out=$a59_out)"

# D1.8c — EGRESSLOCK_ANCHOR_IMAGE: the anchor's `podman run` is the first
# consumer; the die fires at that interpolation, token never in runlog.
# Own profile/network so the anchor container is actually created here.
cat > "$S59/anch.conf" <<'EOF'
profile s59c 10.199.85.0/24
    rule gateway-only
    gateway 10.199.85.2 3128 s59-allowlist
EOF
: > "$STATE/runlog"
a59_out="$(EGRESSLOCK_ANCHOR_IMAGE='-privileged' egresslock --config "$S59/anch.conf" ensure s59c 2>&1)"; a59_rc=$?
if [[ "$a59_rc" != 0 && "$a59_out" == *"EGRESSLOCK_ANCHOR_IMAGE"* ]] && ! grep -q -- '-privileged' "$STATE/runlog"; then
    a59 pass
else
    a59 fail "D1.8c ANCHOR_IMAGE '-privileged' dies pre-run (rc=$a59_rc token-in-runlog=$(grep -c -- '-privileged' "$STATE/runlog" || true) out=$a59_out)"
fi

# D1.9 — valid env overrides still pass; the gateway image override keeps
# the default image-exists path (mock has it).
: > "$STATE/runlog"
a59_out="$(EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:latest \
    egresslock --config "$S59/gwok.conf" ensure s59b 2>&1)"; a59_rc=$?
[[ "$a59_rc" == 0 ]] && a59 pass || a59 fail "D1.9 GW_IMAGE happy path (rc=$a59_rc runs=$(wc -l < "$STATE/runlog") out=$a59_out)"

arc59_pass=$pass; arc59_fail=$fail

# --- ARC-57: denied emit filters strings the allow grammar rejects ------
# D1: a malicious/malformed log line must not make `denied` print a
# string `allow` would reject; skipped silently (rc 0, no invalid-entry
# stderr). ARC-59 leading-dash hosts are also omitted because the shared
# predicate picks them up. EGL-18-D1 AMENDED the ARC-51 IPv4 omission:
# well-formed IPv4 host[:port] candidates are now EMITTED (not allowlist
# entries — the allow-host pointer is the one-time stderr note).
pass=0; fail=0
a57() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S57="$TESTROOT/s57"; rm -rf "$S57"; mkdir -p "$S57"
cat > "$S57/gw.conf" <<'EOF'
profile s57 10.199.86.0/24
    rule gateway-only
    gateway 10.199.86.2 3128 s57-allowlist
EOF
: > "$S57/s57-allowlist"
: > "$STATE/running/egresslock-gateway-s57"
cat > "$STATE/containers-egresslock-gateway-s57.access.log" <<EOF
$(date +%s).000    120 10.199.86.5 TCP_DENIED/403 0 CONNECT foo;rm:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.86.5 TCP_DENIED/403 0 CONNECT evil\`x:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.86.5 TCP_DENIED/403 0 CONNECT -x.example:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.86.5 TCP_DENIED/403 0 CONNECT 10.1.2.3:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.86.5 TCP_DENIED/403 0 CONNECT example.com:443 - HIER_NONE/- -
EOF

# 1. payloads absent, normal host AND the IPv4 literal present (EGL-18-D1),
# rc 0, no invalid-entry stderr.
d57_out="$(env EGRESSLOCK_CONF="$S57/gw.conf" egresslock denied s57 --days 0 2>&1)"; d57_rc=$?
if [[ "$d57_rc" == 0 \
      && "$d57_out" != *"foo;rm"* && "$d57_out" != *"evil\`x"* \
      && "$d57_out" != *"-x.example"* && "$d57_out" == *"10.1.2.3"* \
      && "$d57_out" == *"example.com"* \
      && "$d57_out" != *"invalid allowlist entry"* ]]; then
    a57 pass
else
    a57 fail "D1 denied skips un-allowable payloads, emits IPv4 (rc=$d57_rc, out: $d57_out)"
fi

# 2. --all also filters at emit (the allow grammar gate applies to the
# whole feed, not just the ARC-31 filter path).
all57_out="$(env EGRESSLOCK_CONF="$S57/gw.conf" egresslock denied s57 --days 0 --all 2>&1)"; all57_rc=$?
if [[ "$all57_rc" == 0 \
      && "$all57_out" != *"foo;rm"* && "$all57_out" != *"evil\`x"* \
      && "$all57_out" == *"example.com"* && "$all57_out" == *"10.1.2.3"* ]]; then
    a57 pass
else
    a57 fail "D1b denied --all also filters (rc=$all57_rc, out: $all57_out)"
fi

# 3. a valid host:port denial (HTTP-origin absolute URL, ARC-41 path)
# still passes through as host:port.
: > "$STATE/containers-egresslock-gateway-s57.access.log"
printf '%s.000    120 10.199.86.5 TCP_DENIED/403 0 GET http://cache.example.test:8080/ - HIER_NONE/- -\n' "$(date +%s)" \
    > "$STATE/containers-egresslock-gateway-s57.access.log"
p57_out="$(env EGRESSLOCK_CONF="$S57/gw.conf" egresslock denied s57 --days 0 --all 2>&1)"; p57_rc=$?
[[ "$p57_rc" == 0 && "$p57_out" == *"cache.example.test:8080"* ]] \
    && a57 pass || a57 fail "D1c host:port denial preserved (rc=$p57_rc, out: $p57_out)"

# 4. allow still rejects the same payload string (defense-in-depth intact;
# the shared predicate is the same one denied uses).
a57_out="$(egresslock --config "$S57/gw.conf" allow s57 'foo;rm' 2>&1)"; a57_rc=$?
[[ "$a57_rc" == 2 && "$a57_out" == *"invalid allowlist entry"* ]] \
    && a57 pass || a57 fail "D1d allow rejects the payload string (rc=$a57_rc, out: $a57_out)"

arc57_pass=$pass; arc57_fail=$fail

# --- EGL-18: IP destinations — denied emits IPv4 + note, allow-host ------
# hint, NO_PROXY unions allow-host IPv4 pins (D1/D2/D3; D5: the matrix is
# harness evidence, not a live-lab gate).
pass=0; fail=0
a18() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S18="$TESTROOT/h18"; rm -rf "$S18"; mkdir -p "$S18"
cat > "$S18/gw.conf" <<'EOF'
profile s18 10.199.87.0/24
    rule gateway-only
    gateway 10.199.87.2 3128 s18-allowlist
EOF
: > "$S18/s18-allowlist"
: > "$STATE/running/egresslock-gateway-s18"
D1_NOTE="note: IPv4 destinations are not allowlist hostnames — use allow-host, not allow. Proxied clients 403 unless the IP is in NO_PROXY (proxy-env includes allow-host IPv4 pins; recreate the workload)."
D2_NOTE="note: IPv4 allow-host pins are included in proxy-env NO_PROXY; recreate running workloads to pick up the new env."

# 1. D1: CONNECT IPv4 403 is emitted bare; payloads stay skipped; the
#    D1 note is on STDERR verbatim, exactly once; rc 0.
cat > "$STATE/containers-egresslock-gateway-s18.access.log" <<EOF
$(date +%s).000    120 10.199.87.5 TCP_DENIED/403 0 CONNECT 10.1.2.3:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.87.5 TCP_DENIED/403 0 CONNECT foo;rm:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.87.5 TCP_DENIED/403 0 CONNECT evil\`x:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.87.5 TCP_DENIED/403 0 CONNECT -x.example:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.87.5 TCP_DENIED/403 0 CONNECT example.com:443 - HIER_NONE/- -
EOF
d18_out="$(env EGRESSLOCK_CONF="$S18/gw.conf" egresslock denied s18 --days 0 2>"$S18/d1.err")"; d18_rc=$?
d18_err="$(cat "$S18/d1.err")"
if [[ "$d18_rc" == 0 \
      && "$d18_out" == *"10.1.2.3"* && "$d18_out" == *"example.com"* \
      && "$d18_out" != *"foo;rm"* && "$d18_out" != *"evil\`x"* \
      && "$d18_out" != *"-x.example"* \
      && "$d18_err" == *"$D1_NOTE"* \
      && "$(grep -c '^note: IPv4 destinations' "$S18/d1.err")" == 1 \
      && "$d18_out" != *"note: IPv4 destinations"* ]]; then
    a18 pass
else
    a18 fail "D1 denied emits IPv4 + one stderr note (rc=$d18_rc, out: $d18_out, err: $d18_err)"
fi

# 2. D1: plain-HTTP GET to a literal is emitted as host:port (explicit
#    port preserved), with the note.
printf '%s.000    120 10.199.87.5 TCP_DENIED/403 0 GET http://10.1.2.3:11434/ - HIER_NONE/- -\n' "$(date +%s)" \
    > "$STATE/containers-egresslock-gateway-s18.access.log"
d18b_out="$(env EGRESSLOCK_CONF="$S18/gw.conf" egresslock denied s18 --days 0 2>"$S18/d1b.err")"; d18b_rc=$?
[[ "$d18b_rc" == 0 && "$d18b_out" == *"10.1.2.3:11434"* \
    && "$(cat "$S18/d1b.err")" == *"$D1_NOTE"* ]] \
    && a18 pass || a18 fail "D1 GET literal emitted host:port (rc=$d18b_rc, out: $d18b_out)"

# 3. D1: hostname-only denied log -> NO note on stderr.
printf '%s.000    120 10.199.87.5 TCP_DENIED/403 0 GET http://cache.example.test:8080/ - HIER_NONE/- -\n' "$(date +%s)" \
    > "$STATE/containers-egresslock-gateway-s18.access.log"
d18c_out="$(env EGRESSLOCK_CONF="$S18/gw.conf" egresslock denied s18 --days 0 2>"$S18/d1c.err")"; d18c_rc=$?
if [[ "$d18c_rc" == 0 && "$d18c_out" == *"cache.example.test:8080"* \
      && "$(grep -c '^note: IPv4' "$S18/d1c.err")" == 0 ]]; then
    a18 pass
else
    a18 fail "D1 hostname-only log has no note (rc=$d18c_rc, out: $d18c_out, err: $(cat "$S18/d1c.err"))"
fi

# 4. D2: allow-host of an IPv4 on a GATEWAY profile -> added: line on
#    stdout + the D2 note verbatim on stderr; conf has the rule.
cat > "$S18/hint.conf" <<'EOF'
profile s18h 10.199.89.0/24
    rule gateway-only
    gateway 10.199.89.2 3128 s18h-allowlist
EOF
: > "$S18/s18h-allowlist"
h18_out="$(env EGRESSLOCK_CONF="$S18/hint.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host s18h 10.1.2.3:11434 2>"$S18/h1.err")"; h18_rc=$?
if [[ "$h18_rc" == 0 && "$h18_out" == *"added: rule allow-host 10.1.2.3:11434"* \
      && "$(cat "$S18/h1.err")" == *"$D2_NOTE"* \
      && "$(grep -c 'rule allow-host 10.1.2.3:11434' "$S18/hint.conf")" == 1 ]]; then
    a18 pass
else
    a18 fail "D2 allow-host IPv4 hint (rc=$h18_rc, out: $h18_out, err: $(cat "$S18/h1.err"))"
fi

# 4b. D2: the duplicate (already present) still prints the hint.
h18d_out="$(env EGRESSLOCK_CONF="$S18/hint.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host s18h 10.1.2.3:11434 2>"$S18/h1b.err")"; h18d_rc=$?
[[ "$h18d_rc" == 0 && "$h18d_out" == *"entry already present"* \
    && "$(cat "$S18/h1b.err")" == *"$D2_NOTE"* ]] \
    && a18 pass || a18 fail "D2 duplicate still hints (rc=$h18d_rc, out: $h18d_out)"

# 5. D2: IPv4 allow-host on a NON-gateway profile -> no hint (stderr
#    still carries the re-ensuring banner — assert the NOTE line count).
cat > "$S18/direct.conf" <<'EOF'
profile s18d 10.199.88.0/24
    rule allow-host 10.1.2.3:11434
EOF
h18n_out="$(env EGRESSLOCK_CONF="$S18/direct.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host s18d 10.1.2.3:8080 2>"$S18/h2.err")"; h18n_rc=$?
[[ "$h18n_rc" == 0 && "$(grep -c '^note: IPv4 allow-host' "$S18/h2.err")" == 0 \
    && "$(grep -c 'rule allow-host 10.1.2.3:8080' "$S18/direct.conf")" == 1 ]] \
    && a18 pass || a18 fail "D2 non-gateway no hint (rc=$h18n_rc, err: $(cat "$S18/h2.err"))"

# 6. D2: hostname allow-host on a GATEWAY profile -> no hint (ARC-38-D4
#    rationale: ssh ignores HTTP(S)_PROXY).
h18g_out="$(env EGRESSLOCK_CONF="$S18/hint.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host s18h git.example.test:2222 2>"$S18/h3.err")"; h18g_rc=$?
[[ "$h18g_rc" == 0 && "$(grep -c '^note: IPv4 allow-host' "$S18/h3.err")" == 0 \
    && "$(grep -c 'rule allow-host git.example.test:2222' "$S18/hint.conf")" == 1 ]] \
    && a18 pass || a18 fail "D2 hostname pin no hint (rc=$h18g_rc, err: $(cat "$S18/h3.err"))"

# 7. D3: proxy-env noproxy unions allow-host IPv4 literals — IP once,
#    hostname pin absent.
cat > "$S18/np.conf" <<'EOF'
profile s18n 10.199.90.0/24
    rule allow-host 10.1.2.3:11434
    rule allow-host 10.1.2.3:443
    rule allow-host git.example.test:2222
    rule gateway-only
    gateway 10.199.90.2 3128 s18n-allowlist
EOF
: > "$S18/s18n-allowlist"
np18="$(env EGRESSLOCK_CONF="$S18/np.conf" egresslock proxy-env s18n noproxy 2>/dev/null)"
[[ "$np18" == "localhost,127.0.0.1,10.1.2.3" ]] \
    && a18 pass || a18 fail "D3 noproxy union (got: $np18)"

# 8. D3: conf no-proxy naming the same IP -> still exactly once.
cat > "$S18/np2.conf" <<'EOF'
profile s18n2 10.199.91.0/24
    rule allow-host 10.1.2.3:11434
    no-proxy 10.1.2.3
    rule gateway-only
    gateway 10.199.91.2 3128 s18n2-allowlist
EOF
: > "$S18/s18n2-allowlist"
np18b="$(env EGRESSLOCK_CONF="$S18/np2.conf" egresslock proxy-env s18n2 noproxy 2>/dev/null)"
[[ "$np18b" == "localhost,127.0.0.1,10.1.2.3" ]] \
    && a18 pass || a18 fail "D3 conf+pin dedup (got: $np18b)"

# 9. D3: hostname-only allow-host (no IPv4 pin, no conf no-proxy) ->
#    the ARC-44 default is byte-exact.
cat > "$S18/np3.conf" <<'EOF'
profile s18n3 10.199.92.0/24
    rule allow-host git.example.test:2222
    rule gateway-only
    gateway 10.199.92.2 3128 s18n3-allowlist
EOF
: > "$S18/s18n3-allowlist"
np18c="$(env EGRESSLOCK_CONF="$S18/np3.conf" egresslock proxy-env s18n3 noproxy 2>/dev/null)"
[[ "$np18c" == "localhost,127.0.0.1" ]] \
    && a18 pass || a18 fail "D3 hostname-only stays default (got: $np18c)"

egl18_pass=$pass; egl18_fail=$fail

# --- ARC-60: teardown --runtime + cutover-incomplete probe ----------------
# D1: the no-conf runtime sweep (ARC-68-D1: egresslock-only regexes; the
# agent-* family is NOT swept). D2: the engine probe names the old confdir
# when the new one is empty and the old one exists.
pass=0; fail=0
a60() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# Fixture: the dogfood-host shape — old-generation containers/network
# still up with NO conf anywhere, plus new-generation objects, plus
# non-kit names that must survive.
H60="$TESTROOT/h60"; rm -rf "$H60"; mkdir -p "$H60"
mk_a60_runtime() {
    rm -rf "$STATE/networks" "$STATE/running" "$STATE/containers" "$STATE/ips"
    mkdir -p "$STATE/networks" "$STATE/running" "$STATE/containers" "$STATE/ips"
    # old generation (pre-rename, conf deleted)
    : > "$STATE/running/agent-gateway-dev"; echo "agent-dev" > "$STATE/containers/agent-gateway-dev.net"
    : > "$STATE/running/agent-anchor-dev";  echo "agent-dev" > "$STATE/containers/agent-anchor-dev.net"
    printf 'driver=bridge\nsubnet=192.0.2.0/24\n' > "$STATE/networks/agent-dev"
    # new generation (current names)
    : > "$STATE/running/egresslock-anchor-main"; echo "egresslock-main" > "$STATE/containers/egresslock-anchor-main.net"
    printf 'driver=bridge\nsubnet=10.199.0.0/24\n' > "$STATE/networks/egresslock-main"
    # non-kit: the opencode recipe container + a foreign-prefix network
    : > "$STATE/running/agent-opencode"; echo "podman-default" > "$STATE/containers/agent-opencode.net"
    printf 'driver=bridge\nsubnet=10.88.0.0/24\n' > "$STATE/networks/shackle-old"
}
run_a60() { env -u EGRESSLOCK_CONF HOME="$H60" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

# 1. --runtime sweeps the egresslock-* generation only (ARC-68-D1: the
#    seeded agent-* family SURVIVES); an explicit EGRESSLOCK_CONF is
#    ignored (not loaded, not required).
mk_a60_runtime
a60_out="$(env EGRESSLOCK_CONF="$H60/nope.conf" HOME="$H60" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock teardown --runtime 2>&1)"; a60_rc=$?
if [[ "$a60_rc" == 0 \
      && "$a60_out" == *"removed container egresslock-anchor-main"* \
      && "$a60_out" == *"removed network egresslock-main"* ]] \
   && [[ -f "$STATE/running/agent-gateway-dev" && -f "$STATE/running/agent-anchor-dev" \
      && -f "$STATE/networks/agent-dev" \
      && ! -e "$STATE/running/egresslock-anchor-main" && ! -e "$STATE/networks/egresslock-main" ]] \
   && [[ -f "$STATE/running/agent-opencode" && -f "$STATE/networks/shackle-old" ]] \
   && [[ "$a60_out" != *"removed container agent-"* && "$a60_out" != *"removed network agent-"* \
      && "$a60_out" != *"agent-opencode"* && "$a60_out" != *"shackle"* ]]; then
    a60 pass
else
    a60 fail "D1 --runtime sweeps egresslock-* only, agent-* family survives (rc=$a60_rc, out: $a60_out)"
fi

# 1b. ARC-68-D1: the leftover agent-* generation is untouched by the
#     sweep — a second --runtime still says `no kit runtime` (the agent-*
#     names do not count as kit runtime).
a60d_out="$(run_a60 teardown --runtime 2>&1)"; a60d_rc=$?
[[ "$a60d_rc" == 0 && "$a60d_out" == *"no kit runtime"* \
    && -f "$STATE/running/agent-gateway-dev" && -f "$STATE/networks/agent-dev" ]] \
    && a60 pass || a60 fail "D1 agent-* leftovers are invisible to --runtime (rc=$a60d_rc, out: $a60d_out)"

# 2. Idempotent: nothing matching -> rc 0 and `no kit runtime`.
a60b_out="$(run_a60 teardown --runtime 2>&1)"; a60b_rc=$?
[[ "$a60b_rc" == 0 && "$a60b_out" == *"no kit runtime"* ]] \
    && a60 pass || a60 fail "D1 second --runtime is rc 0 'no kit runtime' (rc=$a60b_rc, out: $a60b_out)"

# 3. Strict arity: --runtime takes no other arguments.
a60c_out="$(run_a60 teardown --runtime extra 2>&1)"; a60c_rc=$?
[[ "$a60c_rc" == 2 && "$a60c_out" == *"takes no other arguments"* ]] \
    && a60 pass || a60 fail "D1 --runtime arity (rc=$a60c_rc, out: $a60c_out)"

# 4. D2: empty NEW confdir + old confdir present -> rc 2 naming the old
#    confdir (`cutover incomplete`), for both probe paths.
mkdir -p "$H60/.config/egresslock" "$H60/.config/agent-network"
printf 'profile dev 10.199.90.0/24\n' > "$H60/.config/agent-network/dev.conf"
o="$(run_a60 ensure main 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"cutover incomplete"* && "$o" == *"$H60/.config/agent-network"* ]] \
    && a60 pass || a60 fail "D2 named probe names the old confdir (rc=$rc, out: $o)"
o="$(run_a60 list 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"cutover incomplete"* && "$o" == *"agent-network"* ]] \
    && a60 pass || a60 fail "D2 aggregate probe names the old confdir (rc=$rc, out: $o)"

# 5. D2: the new confdir having a conf (migration done) suppresses the
#    cutover hint; the generic miss stays.
printf 'profile dev 10.199.90.0/24\n' > "$H60/.config/egresslock/dev.conf"
o="$(run_a60 ensure main 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" != *"cutover incomplete"* ]] \
    && a60 pass || a60 fail "D2 migrated confdir keeps the generic miss (rc=$rc, out: $o)"

# 6. D2: no old confdir -> no cutover hint (plain miss).
rm -rf "$H60/.config/agent-network" "$H60/.config/egresslock"
o="$(run_a60 list 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" != *"cutover incomplete"* && "$o" == *"no profile config"* ]] \
    && a60 pass || a60 fail "D2 no old confdir -> generic miss only (rc=$rc, out: $o)"

arc60_pass=$pass; arc60_fail=$fail
# --- ARC-32: pre-OSS hardening -------------------------------------------
# D1: `denied` streams and byte-caps the log read (EGRESSLOCK_DENIED_
# MAX_BYTES, default 8 MiB) and never rotates; verify/ensure rotate
# overlay logs over EGRESSLOCK_GW_LOG_MAX_BYTES (mv -> squid -k rotate
# -> rm .1). D2: DNS length caps (host <= 253, labels 1..63) in the
# shared predicate + conf/CLI host fields. D3: gateway base digest pin.
# D4: NOPASSWD documented unsupported, no sudoers shipped.
pass=0; fail=0
a32() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

A32="$TESTROOT/s32"; rm -rf "$A32"; mkdir -p "$A32"
cat > "$A32/gw.conf" <<'EOF'
profile s32 10.199.90.0/24
    rule gateway-only
    gateway 10.199.90.2 3128 s32-allowlist
EOF
: > "$A32/s32-allowlist"
GW32=egresslock-gateway-s32
: > "$STATE/running/$GW32"
now32="$(date +%s)"
old32="$(( now32 - 15 * 86400 ))"

mklog32() { # mklog32 <ts-line1> — three CONNECT denials, one per host
    cat > "$STATE/containers-$GW32.access.log" <<EOF
$1.000    120 10.199.90.5 TCP_DENIED/403 0 CONNECT a32-one.example.test:443 - HIER_NONE/- -
$now32.000    120 10.199.90.5 TCP_DENIED/403 0 CONNECT a32-two.example.test:443 - HIER_NONE/- -
$now32.000    120 10.199.90.5 TCP_DENIED/403 0 CONNECT a32-three.example.test:443 - HIER_NONE/- -
EOF
}

# D1.1 — capped read: rc 0, only the prefix within the cap is parsed,
# one stderr line names the truncation. Cap = first line + 5 bytes.
mklog32 "$now32"
cap32="$(head -1 "$STATE/containers-$GW32.access.log" | wc -c)"; cap32=$(( cap32 + 5 ))
d32_out="$(env EGRESSLOCK_CONF="$A32/gw.conf" EGRESSLOCK_DENIED_MAX_BYTES="$cap32" \
    egresslock denied s32 --days 0 2>$TESTROOT/agent32a.err)"; d32_rc=$?
d32_err="$(cat $TESTROOT/agent32a.err)"
if [[ "$d32_rc" == 0 && "$d32_out" == *"a32-one.example.test"* \
      && "$d32_out" != *"a32-two.example.test"* && "$d32_out" != *"a32-three.example.test"* \
      && "$d32_err" == *"EGRESSLOCK_DENIED_MAX_BYTES"* && "$d32_err" == *"stopped at ${cap32} bytes"* ]] \
   && [[ "$(grep -vc '^scoped: ' $TESTROOT/agent32a.err)" == 1 ]]; then
    a32 pass
else
    a32 fail "D1.1 denied byte cap (rc=$d32_rc out=[$d32_out] err=[$d32_err])"
fi

# D1.2 — the --days window still applies to the prefix that was read:
# only the OLD line is within the cap -> empty stdout, truncate note +
# window note (had_denied came from the streamed meta, not a slurp).
mklog32 "$old32"
cap32="$(head -1 "$STATE/containers-$GW32.access.log" | wc -c)"; cap32=$(( cap32 + 5 ))
d32_out="$(env EGRESSLOCK_CONF="$A32/gw.conf" EGRESSLOCK_DENIED_MAX_BYTES="$cap32" \
    egresslock denied s32 2>$TESTROOT/agent32b.err)"; d32_rc=$?
d32_err="$(cat $TESTROOT/agent32b.err)"
if [[ "$d32_rc" == 0 && -z "$d32_out" \
      && "$d32_err" == *"EGRESSLOCK_DENIED_MAX_BYTES"* \
      && "$d32_err" == *"no denials in the last 14 days"* ]]; then
    a32 pass
else
    a32 fail "D1.2 cap + window on the read prefix (rc=$d32_rc out=[$d32_out] err=[$d32_err])"
fi

# D1.3 — cap 0 is uncapped: all three entries, no note.
mklog32 "$now32"
d32_out="$(env EGRESSLOCK_CONF="$A32/gw.conf" EGRESSLOCK_DENIED_MAX_BYTES=0 \
    egresslock denied s32 --days 0 2>$TESTROOT/agent32c.err)"; d32_rc=$?
d32_err="$(cat $TESTROOT/agent32c.err)"
if [[ "$d32_rc" == 0 && "$d32_out" == *"a32-one.example.test"* && "$d32_out" == *"a32-three.example.test"* \
      && "$d32_err" != *"EGRESSLOCK_DENIED_MAX_BYTES"* ]]; then
    a32 pass
else
    a32 fail "D1.3 cap 0 uncapped (rc=$d32_rc out=[$d32_out] err=[$d32_err])"
fi

# D1.4 — invalid cap values die as usage errors (rc 2).
for bad32 in abc -1 1.5; do
    d32_out="$(env EGRESSLOCK_CONF="$A32/gw.conf" EGRESSLOCK_DENIED_MAX_BYTES="$bad32" \
        egresslock denied s32 2>&1)"; d32_rc=$?
    [[ "$d32_rc" == 2 ]] && a32 pass || a32 fail "D1.4 DENIED_MAX='$bad32' -> exit 2 (rc=$d32_rc out=$d32_out)"
done

# D1.5 — `denied` never rotates: no mv/rm of the log, no `squid -k
# rotate`, even on a truncated read.
: > "$STATE/execlog"
mklog32 "$now32"
cap32="$(head -1 "$STATE/containers-$GW32.access.log" | wc -c)"
env EGRESSLOCK_CONF="$A32/gw.conf" EGRESSLOCK_DENIED_MAX_BYTES="$cap32" \
    egresslock denied s32 --days 0 >/dev/null 2>&1
if ! grep -q 'access.log.1' "$STATE/execlog" && ! grep -q -- '-k rotate' "$STATE/execlog"; then
    a32 pass
else
    a32 fail "D1.5 denied must not rotate (execlog: $(grep -e 'access.log.1' -e -- '-k rotate' "$STATE/execlog" | head -3))"
fi

# D1.6 — verify rotates oversize overlay logs: default cap (32 MiB) is
# inert during the setup ensure; a tiny cap on verify must produce the
# exact mv -> `squid -k rotate` -> rm argv, leave NO .1 as the live
# file, and reopen fresh logs (modeled by the mock). One rotate covers
# BOTH stdio logs (real squid reopens every log on rotate — the mock
# does the same), so the cache.log side asserts the reopen, not its own
# mv. The fake running marker from the denied tests must go first —
# ensure must really create the gateway (podman run records the
# network attachment).
rm -f "$STATE/running/$GW32"
d32_out="$(egresslock --config "$A32/gw.conf" ensure s32 2>&1)"; d32_rc=$?
[[ "$d32_rc" == 0 ]] && a32 pass || a32 fail "D1.6 setup ensure (rc=$d32_rc out=$d32_out)"
: > "$STATE/execlog"
printf '%s\n' "$(printf 'c%.0s' $(seq 1 90))" > "$STATE/containers-$GW32.cache.log"
mklog32 "$now32"
v32_out="$(env EGRESSLOCK_CONF="$A32/gw.conf" EGRESSLOCK_GW_LOG_MAX_BYTES=50 \
    egresslock verify s32 2>$TESTROOT/agent32d.err)"; v32_rc=$?
v32_err="$(cat $TESTROOT/agent32d.err)"
if [[ "$v32_rc" == 0 \
      && "$(grep -c "exec $GW32 mv /var/log/squid/access.log /var/log/squid/access.log.1" "$STATE/execlog")" == 1 \
      && "$(grep -c "exec $GW32 squid -k rotate" "$STATE/execlog")" == 1 \
      && "$(grep -c "exec $GW32 rm -f /var/log/squid/access.log.1" "$STATE/execlog")" == 1 \
      && ! -f "$STATE/containers-$GW32.access.log.1" \
      && -f "$STATE/containers-$GW32.access.log" \
      && ! -s "$STATE/containers-$GW32.access.log" \
      && -f "$STATE/containers-$GW32.cache.log" \
      && ! -s "$STATE/containers-$GW32.cache.log" \
      && ! -f "$STATE/containers-$GW32.cache.log.1" \
      && "$v32_err" == *"rotating:"* ]]; then
    a32 pass
else
    a32 fail "D1.6 verify rotates oversize logs (rc=$v32_rc out=[$v32_out] err=[$v32_err] execlog=$(grep "$GW32" "$STATE/execlog" | head -8))"
fi

# D1.7 — rotate failure restores the live file (no rm of .1, no data
# loss beyond the cap decision, fail open for the LOG only).
: > "$STATE/execlog"
mklog32 "$now32"
touch "$STATE/rotate-fails"
v32_out="$(env EGRESSLOCK_CONF="$A32/gw.conf" EGRESSLOCK_GW_LOG_MAX_BYTES=50 \
    egresslock verify s32 2>$TESTROOT/agent32e.err)"; v32_rc=$?
v32_err="$(cat $TESTROOT/agent32e.err)"
rm -f "$STATE/rotate-fails"
if [[ "$v32_rc" == 0 \
      && "$(grep -c "exec $GW32 mv /var/log/squid/access.log /var/log/squid/access.log.1" "$STATE/execlog")" == 1 \
      && "$(grep -c "exec $GW32 squid -k rotate" "$STATE/execlog")" == 1 \
      && "$(grep -c "exec $GW32 rm -f /var/log/squid/access.log.1" "$STATE/execlog")" == 0 \
      && -f "$STATE/containers-$GW32.access.log" \
      && -s "$STATE/containers-$GW32.access.log" \
      && "$v32_err" == *"restoring"* ]]; then
    a32 pass
else
    a32 fail "D1.7 failed rotate restores (rc=$v32_rc err=[$v32_err])"
fi

# D2.1 — allow rejects oversize/invalid-label hosts (rc 2, file
# unchanged, DNS-length message); a 253-char multi-label host is valid.
L63="$(printf 'l%.0s' $(seq 1 63))"
h253="$L63.$L63.$L63.$(printf 'm%.0s' $(seq 1 61))"
pre_md5="$(md5sum "$A32/s32-allowlist" | cut -d' ' -f1)"
for bad32 in "$(printf 'a%.0s' $(seq 1 254))" "${L63}a.$L63" 'a..b'; do
    d32_out="$(egresslock --config "$A32/gw.conf" allow s32 "$bad32" 2>&1)"; d32_rc=$?
    [[ "$d32_rc" == 2 && "$d32_out" == *"DNS length limits"* ]] \
        && a32 pass || a32 fail "D2.1 allow oversize host (${#bad32} bytes) (rc=$d32_rc out=$d32_out)"
done
[[ "$(md5sum "$A32/s32-allowlist" | cut -d' ' -f1)" == "$pre_md5" ]] \
    && a32 pass || a32 fail "D2.1 allowlist unchanged after rejects"
d32_out="$(egresslock --config "$A32/gw.conf" allow s32 "$h253" 2>&1)"; d32_rc=$?
[[ "$d32_rc" == 0 && "$d32_out" == *"added: $h253"* ]] \
    && a32 pass || a32 fail "D2.1 253-char host accepted (rc=$d32_rc out=$d32_out)"

# D2.2 — denied silently skips an oversize candidate (rc 0, no note,
# valid entries still printed; the skipped line is charset-legal so
# only the length gate can reject it). Build the fixture in a temp
# file first: redirecting the group straight onto the log would
# truncate it before the cat inside runs.
tmplog32="$STATE/containers-$GW32.access.log.new"
{
    cat "$STATE/containers-$GW32.access.log"
    printf '%s.000    120 10.199.90.5 TCP_DENIED/403 0 CONNECT %s:443 - HIER_NONE/- -\n' \
        "$now32" "$(printf 'b%.0s' $(seq 1 300))"
} > "$tmplog32"
mv "$tmplog32" "$STATE/containers-$GW32.access.log"
d32_out="$(env EGRESSLOCK_CONF="$A32/gw.conf" egresslock denied s32 --days 0 2>$TESTROOT/agent32f.err)"; d32_rc=$?
if [[ "$d32_rc" == 0 && "$d32_out" == *"a32-one.example.test"* \
      && "$d32_out" != *"$(printf 'b%.0s' $(seq 1 300))"* ]] \
   && ! grep -q 'invalid allowlist entry' $TESTROOT/agent32f.err; then
    a32 pass
else
    a32 fail "D2.2 denied skips oversize candidate (rc=$d32_rc out=[$d32_out])"
fi

# D2.3 — conf host fields take the same caps: allow-host and no-proxy
# oversize tokens are config errors (rc 2).
printf 'profile c32 10.199.91.0/24\n    rule allow-host %s:443\n' \
    "$(printf 'a%.0s' $(seq 1 254))" > "$A32/ah-bad.conf"
d32_out="$(egresslock --config "$A32/ah-bad.conf" list 2>&1)"; d32_rc=$?
[[ "$d32_rc" == 2 && "$d32_out" == *"exceeds DNS length limits"* ]] \
    && a32 pass || a32 fail "D2.3 conf allow-host oversize (rc=$d32_rc out=$d32_out)"
printf 'profile c32 10.199.91.0/24\n    no-proxy %s\n' \
    "$(printf 'a%.0s' $(seq 1 254))" > "$A32/np-bad.conf"
d32_out="$(egresslock --config "$A32/np-bad.conf" list 2>&1)"; d32_rc=$?
[[ "$d32_rc" == 2 && "$d32_out" == *"exceeds DNS length limits"* ]] \
    && a32 pass || a32 fail "D2.3 conf no-proxy oversize (rc=$d32_rc out=$d32_out)"
# Label > 63 in conf (host under 253) is rejected too.
printf 'profile c32 10.199.91.0/24\n    rule allow-host %s.test:443\n' "${L63}x" > "$A32/ah-label.conf"
d32_out="$(egresslock --config "$A32/ah-label.conf" list 2>&1)"; d32_rc=$?
[[ "$d32_rc" == 2 && "$d32_out" == *"exceeds DNS length limits"* ]] \
    && a32 pass || a32 fail "D2.3 conf allow-host label 64 (rc=$d32_rc out=$d32_out)"

# D2.4 — CLI allow-host oversize dies as usage (rc 2), conf unchanged,
# no ensure runs (no podman run between the checks).
cp "$A32/gw.conf" "$A32/gw-keep.conf"
pre_md5="$(md5sum "$A32/gw.conf" | cut -d' ' -f1)"
pre_runs="$(wc -l < "$STATE/runlog")"
d32_out="$(egresslock --config "$A32/gw.conf" allow-host s32 "$(printf 'a%.0s' $(seq 1 254)):443" 2>&1)"; d32_rc=$?
[[ "$d32_rc" == 2 && "$(md5sum "$A32/gw.conf" | cut -d' ' -f1)" == "$pre_md5" \
    && "$(wc -l < "$STATE/runlog")" == "$pre_runs" ]] \
    && a32 pass || a32 fail "D2.4 CLI allow-host oversize (rc=$d32_rc out=$d32_out)"

# D2.5 — a hand-edited allowlist line that is oversize fails `ensure`
# closed (the file path inherits the caps, ARC-59 D1.7 pattern).
printf '%s\n' "$(printf 'a%.0s' $(seq 1 254))" > "$A32/s32-allowlist"
d32_out="$(egresslock --config "$A32/gw.conf" ensure s32 2>&1)"; d32_rc=$?
[[ "$d32_rc" != 0 && "$d32_out" == *"exceeds DNS length limits"* ]] \
    && a32 pass || a32 fail "D2.5 oversize allowlist line fails closed (rc=$d32_rc out=$d32_out)"
: > "$A32/s32-allowlist"

# D3.1 — the gateway base image is pinned: fully qualified name AND a
# sha256 digest (supply-chain pin for kit-built TCB, ARC-32-D3).
if grep -qE '^FROM docker\.io/library/debian:13-slim@sha256:[0-9a-f]{64}$' \
      "$TREE_ROOT/gateway/Containerfile"; then
    a32 pass
else
    a32 fail "D3.1 Containerfile FROM not digest-pinned ($(grep '^FROM' "$TREE_ROOT/gateway/Containerfile"))"
fi

# D4.1 — NOPASSWD documented as unsupported; no sudoers file shipped.
if grep -q 'NOPASSWD' "$TREE_ROOT/docs/setup/install.md" \
   && grep -q 'NOPASSWD' "$TREE_ROOT/docs/reference/threat-model.md" \
   && [[ -z "$(find "$TREE_ROOT" -name '*sudoers*' -not -path '*/tests/*' 2>/dev/null)" ]]; then
    a32 pass
else
    a32 fail "D4.1 NOPASSWD docs / no sudoers file"
fi

arc32_pass=$pass; arc32_fail=$fail

# --- ARC-66: teardown --runtime sweeps our nft tables ---------------------
# D4: `inet egresslock` (live policy) + leftover `inet agent_policy` are
# deleted best-effort by the no-conf sweep (missing/netns-gone = skip,
# delete failure = note + rc 0).
pass=0; fail=0
a66() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# Reuse the ARC-60 fixture shape: kit runtime with NO conf anywhere.
H66="$TESTROOT/h66"; rm -rf "$H66"; mkdir -p "$H66"
run_a66() { env -u EGRESSLOCK_CONF HOME="$H66" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

# 1. Both tables present with kit runtime -> both deleted, named in the
#    output, rc 0.
mk_a60_runtime
printf 'chain p_lg {\n}\n' > "$STATE/nft/egresslock.p_lg"
printf 'chain p_dev {\n}\n' > "$STATE/nft/agent_policy.p_dev"
o="$(run_a66 teardown --runtime 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"removed nft table inet egresslock"* \
      && "$o" == *"removed nft table inet agent_policy"* \
      && ! -e "$STATE/nft/egresslock.p_lg" && ! -e "$STATE/nft/agent_policy.p_dev" ]]; then
    a66 pass
else
    a66 fail "D4 --runtime deletes both tables (rc=$rc, out: $o)"
fi

# 2. Nothing at all -> `no kit runtime`, no table lines, rc 0.
o="$(run_a66 teardown --runtime 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"no kit runtime"* && "$o" != *"removed nft table"* ]] \
    && a66 pass || a66 fail "D4 clean sweep has no table lines (rc=$rc, out: $o)"

# 3. A failing delete is a note + rc 0 (recovery command, not fail-closed).
mk_a60_runtime
printf 'chain p_lg {\n}\n' > "$STATE/nft/egresslock.p_lg"
: > "$STATE/nft/delete-table-fail"
o="$(run_a66 teardown --runtime 2>&1)"; rc=$?
rm -f "$STATE/nft/delete-table-fail"
if [[ "$rc" == 0 && "$o" == *"could not delete nft table inet egresslock"* \
      && "$o" == *"nft delete table inet egresslock"* && -e "$STATE/nft/egresslock.p_lg" ]]; then
    a66 pass
else
    a66 fail "D4 failing table delete notes + rc 0 (rc=$rc, out: $o)"
fi

arc66_pass=$pass; arc66_fail=$fail

# --- ARC-67: network ls {{.Name}} + fail-loud list policies ----------------
# D1/D2/D3: the helper uses {{.Name}} (the mock rejects {{.Names}} like
# the real binary); a broken network list kills `ensure` (fail closed),
# is "taken" for init, and only notes for --runtime.
pass=0; fail=0
a67() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# Failing-list podman shim: delegates to the mock except network ls.
S67="$TESTROOT/s67"; rm -rf "$S67"; mkdir -p "$S67/bin" "$S67/conf"
printf 'profile s67 10.199.92.0/24\n    rule public-only\n' > "$S67/conf/s67.conf"
real_podman="$(command -v podman)"
cat > "$S67/bin/podman" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == network && "\${2:-}" == ls ]]; then
    echo "mock podman: network list failure" >&2
    exit 2
fi
exec "$real_podman" "\$@"
EOF
chmod +x "$S67/bin/podman"
run67() { env PATH="$S67/bin:$PATH" EGRESSLOCK_CONF="$S67/conf/s67.conf" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

# 1. ensure with a failing network list dies closed BEFORE creating the
#    network (the overlap pre-check must never be silently disabled).
o="$(run67 ensure s67 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"cannot list Podman networks"* \
      && ! -e "$STATE/networks/egresslock-s67" ]]; then
    a67 pass
else
    a67 fail "D3 ensure dies on network-list failure (rc=$rc, out: $o)"
fi

# 2. teardown --runtime with a failing list: note + rc 0, containers
#    still swept, and NO `no kit runtime` for that run.
mkdir -p "$STATE/running"
: > "$STATE/running/egresslock-anchor-x67"
o="$(run67 teardown --runtime 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"could not list Podman networks"* \
      && "$o" == *"removed container egresslock-anchor-x67"* \
      && "$o" != *"no kit runtime"* ]]; then
    a67 pass
else
    a67 fail "D3 --runtime notes a failed list, no false 'no kit runtime' (rc=$rc, out: $o)"
fi

# 3. init with a failing list treats the CIDR as taken (never claims it).
o="$(run67 init fresh67 --subnet 10.199.93.0/24 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"overlaps an existing"* ]] \
    && a67 pass || a67 fail "D3 init list-failure = taken (rc=$rc, out: $o)"

arc67_pass=$pass; arc67_fail=$fail

# --- ARC-71: --runtime dispatches before the netns probe ------------------
# D1: the recovery sweep runs with a wedged rootless netns (probe would
# fail). D2: conf-scoped teardown still probes (and still fails loud).
pass=0; fail=0
a71() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# Fixture: live egresslock runtime + nft table, netns WEDGED (no
# EGRESSLOCK_SKIP_NETNS_PROBE — the probe must run and must not block).
H71="$TESTROOT/h71"; rm -rf "$H71"; mkdir -p "$H71"
rm -rf "$STATE/networks" "$STATE/running" "$STATE/containers" "$STATE/ips" "$STATE/nft"
mkdir -p "$STATE/networks" "$STATE/running" "$STATE/containers" "$STATE/ips" "$STATE/nft"
: > "$STATE/running/egresslock-anchor-main"; echo "egresslock-main" > "$STATE/containers/egresslock-anchor-main.net"
printf 'driver=bridge\nsubnet=10.199.0.0/24\n' > "$STATE/networks/egresslock-main"
printf 'chain p_main {\n}\n' > "$STATE/nft/egresslock.p_main"
touch "$STATE/netns-broken"

# 1. D1: --runtime ignores the wedge: sweeps containers, networks, nft
#    table; rc 0.
o="$(env -u EGRESSLOCK_CONF HOME="$H71" egresslock teardown --runtime 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"removed container egresslock-anchor-main"* \
    && "$o" == *"removed network egresslock-main"* \
    && "$o" == *"removed nft table inet egresslock"* \
    && ! -e "$STATE/running/egresslock-anchor-main" && ! -e "$STATE/networks/egresslock-main" ]] \
    && a71 pass || a71 fail "D1 --runtime runs with a wedged netns (rc=$rc, out: $o)"

# 2. D2: conf-scoped teardown still probes and still fails loud with the
#    ARC-26 guidance (re-seed the network: test 1 swept it).
printf 'profile main 10.199.0.0/24\n' > "$H71/main.conf"
printf 'driver=bridge\nsubnet=10.199.0.0/24\n' > "$STATE/networks/egresslock-main"
o="$(env EGRESSLOCK_CONF="$H71/main.conf" HOME="$H71" egresslock teardown main 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"rootless-netns is broken"* \
    && -f "$STATE/networks/egresslock-main" ]] \
    && a71 pass || a71 fail "D2 conf-scoped teardown still probes (rc=$rc, out: $o)"

rm -f "$STATE/netns-broken"
arc71_pass=$pass; arc71_fail=$fail

# --- ARC-69: teardown/ensure output honesty --------------------------------
# D1: removed / not present / kept (in use) decided by existence + rm rc.
# D2: the nft note only when it is true; nothing-left summary on a no-op.
# D3: ensure announces the anchor only on the actual create. D4: bare
# teardown is a usage error naming every form.
pass=0; fail=0
a69() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

H69="$TESTROOT/h69"; rm -rf "$H69"; mkdir -p "$H69"
cat > "$H69/main.conf" <<'EOF'
profile main 10.199.0.0/24
    rule gateway-only
    gateway 10.199.0.2 3128 main-allowlist
EOF
: > "$H69/main-allowlist"
run69() { env EGRESSLOCK_CONF="$H69/main.conf" HOME="$H69" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

# 1. D3: the first ensure announces the anchor create; a second ensure
#    (reuse) stays silent about it.
o="$(run69 ensure main 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(grep -c '^started anchor egresslock-anchor-main$' <<<"$o")" -eq 1 ]] \
    && a69 pass || a69 fail "D3 ensure announces the create (rc=$rc, out: $o)"
o="$(run69 ensure main 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" != *"started anchor"* ]] \
    && a69 pass || a69 fail "D3 reuse stays silent (rc=$rc, out: $o)"

# 2. D1/D2: teardown of a live profile — removed lines for every object
#    plus the nft note (something WAS removed); no not-present noise.
o="$(run69 teardown main 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"removed gateway egresslock-gateway-main"* \
      && "$o" == *"removed anchor egresslock-anchor-main"* \
      && "$o" == *"removed egresslock-main"* \
      && "$o" == *"'egresslock teardown --runtime' deletes it"* \
      && "$o" != *"not present"* && "$o" != *"nothing left"* ]]; then
    a69 pass
else
    a69 fail "D1 live teardown removed + D2 note (rc=$rc, out: $o)"
fi

# 3. D1/D2: repeat teardown — everything not present, `nothing left for
#    profile 'main'`, and NO nft note (a no-op proves nothing about the
#    table; the old two-line 'disappears on its own' note is gone).
o="$(run69 teardown main 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"not present gateway egresslock-gateway-main"* \
      && "$o" == *"not present anchor egresslock-anchor-main"* \
      && "$o" == *"not present egresslock-main"* \
      && "$o" == *"nothing left for profile 'main'"* \
      && "$o" != *"nft table"* ]]; then
    a69 pass
else
    a69 fail "D1 repeat teardown not present + D2 nothing-left (rc=$rc, out: $o)"
fi

# 4. D1: partial state (anchor + network back, gateway gone): mixed
#    vocabulary and the note (something was removed).
printf 'driver=bridge\nsubnet=10.199.0.0/24\n' > "$STATE/networks/egresslock-main"
: > "$STATE/running/egresslock-anchor-main"
o="$(run69 teardown main 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"not present gateway"* \
    && "$o" == *"removed anchor egresslock-anchor-main"* \
    && "$o" == *"removed egresslock-main"* \
    && "$o" != *"nothing left"* ]] \
    && a69 pass || a69 fail "D1 mixed state vocabulary (rc=$rc, out: $o)"

# 5. D1: a network that exists but refuses the rm is `kept (in use)`,
#    not `removed` and not `not present`.
printf 'driver=bridge\nsubnet=10.199.0.0/24\n' > "$STATE/networks/egresslock-main"
touch "$STATE/network-rm-fails"
o="$(run69 teardown main 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"kept egresslock-main (in use)"* \
    && "$o" != *"removed egresslock-main"* \
    && "$o" == *"'egresslock teardown --runtime' deletes it"* ]] \
    && a69 pass || a69 fail "D1 kept (in use) on failed network rm (rc=$rc, out: $o)"
rm -f "$STATE/network-rm-fails"

# 6. D1 (--runtime): a kept network is reported, but `no kit runtime`
#    keys off REAL removals only (kept networks are not found counts).
#    Clear the nft state first: table deletes WOULD be real removals.
rm -f "$STATE"/nft/egresslock.*
printf 'driver=bridge\nsubnet=10.199.0.0/24\n' > "$STATE/networks/egresslock-main"
touch "$STATE/network-rm-fails"
o="$(env -u EGRESSLOCK_CONF HOME="$H69" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock teardown --runtime 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"kept network egresslock-main (in use)"* \
    && "$o" == *"no kit runtime"* ]] \
    && a69 pass || a69 fail "D1 kept network is not a found count (rc=$rc, out: $o)"
rm -f "$STATE/network-rm-fails" "$STATE/networks/egresslock-main"

# 7. D1 (--runtime): a container rm failure is `note: could not remove`,
#    never a false `removed`; found stays 0 so no kit runtime is claimed.
: > "$STATE/running/egresslock-anchor-main"
echo "egresslock-main" > "$STATE/containers/egresslock-anchor-main.net"
touch "$STATE/rm-container-fails"
o="$(env -u EGRESSLOCK_CONF HOME="$H69" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock teardown --runtime 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"note: could not remove container egresslock-anchor-main"* \
    && "$o" != *"removed container"* ]] \
    && a69 pass || a69 fail "D1 container rm failure is honest (rc=$rc, out: $o)"
rm -f "$STATE/rm-container-fails"

# 8. D4: bare teardown is a usage error naming all three forms.
o="$(run69 teardown 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"teardown <profile>"* && "$o" == *"teardown all"* \
    && "$o" == *"teardown --runtime"* ]] \
    && a69 pass || a69 fail "D4 bare teardown usage error (rc=$rc, out: $o)"

arc69_pass=$pass; arc69_fail=$fail

# --- EGL-31: engine output hygiene (bare command name; no stale doc path) -
# D1 grep-guard: no engine output string references the hard-coded
# /opt/egresslock/egresslock path or the never-existed how-to/ page.
# (The launchers' `-x /opt/...` ENGINE-RESOLUTION probes are code, not
# output, and stay — ARC-16-D4.)
pass=0; fail=0
a31b() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

hits="$(grep -n -- '/opt/egresslock/egresslock\|how-to/' "$TREE_ROOT/egresslock" | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
if [[ -z "$hits" ]]; then
    a31b pass
else
    a31b fail "engine output references /opt path or how-to/ (EGL-31): $hits"
fi

# The root guard names the bare command (string-level: the harness runs
# non-root, so the guard's rc-1 path is not exercisable here — the
# grep-guard above is the real assertion; this pins the message shape).
grep -q -- "sudo -iu <account> -- egresslock ..." "$TREE_ROOT/egresslock" \
    && ! grep -q -- "/opt/egresslock/egresslock" <(grep -v '^[[:space:]]*#' "$TREE_ROOT/egresslock") \
    && a31b pass || a31b fail "root guard message shape (bare command, no /opt path)"

egl31_pass=$pass; egl31_fail=$fail

# --- EGL-45: engine doctor (host environment probe) -------------------------
# This container has no podman/nft/netavark, so the MISSING branch is the
# natural state; a stub PATH supplies the all-present shape.
pass=0; fail=0
a45() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# 1. No conf required, podman/nft/netavark missing -> required MISSING
#    lines, rc 1; never the "no profile config" error. The harness PATH
#    carries mock podman/nft stubs, so isolate with a minimal PATH (only
#    what the doctor code path needs) + the repo root for the engine.
none45="$TESTROOT/bin-doctor-none"
rm -rf "$none45"; mkdir -p "$none45"
for t in env bash cat id head dirname; do ln -s "$(command -v "$t")" "$none45/$t"; done
# EGL-80-L3: NFT_BIN is pinned to an absent path so the nft row reports
# MISSING regardless of the host's /usr/sbin/nft (the doctor's absolute
# resolution fallback; the host may legitimately have nftables installed).
d_out="$(env -u EGRESSLOCK_CONF NFT_BIN=/nonexistent PATH="$none45:$TREE_ROOT" egresslock doctor 2>&1)"; d_rc=$?
[[ "$d_rc" == 1 && "$d_out" == *"podman: MISSING"* \
    && "$d_out" == *"netavark: MISSING"* && "$d_out" == *"nft: MISSING"* \
    && "$d_out" != *"no profile config"* ]] \
    && a45 pass || a45 fail "doctor without conf, missing tools (rc=$d_rc, out: $d_out)"
[[ "$d_out" == *"rootless_netns: skipped (podman MISSING)"* ]] \
    && a45 pass || a45 fail "netns probe skipped when podman missing"

# 2/3/4b. EGL-81-D1: the rc-0 asserts below are hermetic — doctor's
# `userns:` row is pinned via the EGRESSLOCK_USERNS_SYSCTL harness
# override (default unset = the real /proc sysctl), so doctor's rc never
# depends on the host's userns state. Fixture: $TESTROOT/userns-on holds
# `1` (enabled). The EGL-80 SHIP NOTE is resolved: all three doctor rc-0
# cases are back, plus dedicated row-state coverage in 4c/4d/4e.

# userns fixtures for the row-state coverage (EGL-81-D2).
printf '1' > "$TESTROOT/userns-on"
printf '0' > "$TESTROOT/userns-off"

# 2. All required present (stub PATH) -> rc 0 + advisory lines.
stub45="$TESTROOT/bin-doctor-stub"
rm -rf "$stub45"; mkdir -p "$stub45"
cat > "$stub45/podman" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    --version) echo "podman version 5.4.2" ;;
    info) echo "netavark" ;;
    unshare) exit 0 ;;
    *) exit 0 ;;
esac
EOF
printf '#!/bin/sh\n' > "$stub45/netavark"
printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "nftables v1.1.3" ;; *) exit 0 ;; esac\n' > "$stub45/nft"
printf '#!/usr/bin/env bash\ncase "$1" in --version|-V) echo "conntrack v1.4.8 (stub)" ;; *) exit 0 ;; esac\n' > "$stub45/conntrack"
chmod +x "$stub45"/*
d_out="$(env -u EGRESSLOCK_CONF EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$stub45:$PATH" egresslock doctor 2>&1)"; d_rc=$?
[[ "$d_rc" == 0 && "$d_out" == *"podman: podman version 5.4.2"* \
    && "$d_out" == *"netavark: "* && "$d_out" == *"nft: nftables v1.1.3"* \
    && "$d_out" == *"userns: enabled"* \
    && "$d_out" == *"rootless_netns: ok"* ]] \
    && a45 pass || a45 fail "doctor all-present rc 0 (rc=$d_rc, out: $d_out)"

# 3. Advisory lines never affect rc: netns failure (rc 126 AppArmor
#    shape) + no pasta/slirp on PATH -> rc stays 0, fail line + stderr
#    hint name the apparmor check.
d_err="$TESTROOT/doctor-stderr"
rm -f "$stub45/pasta" "$stub45/slirp4netns"
cat > "$stub45/podman" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    --version) echo "podman version 5.4.2" ;;
    info) echo "netavark" ;;
    unshare) echo "kill network process: permission denied" >&2; exit 126 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$stub45/podman"
d_out="$(env -u EGRESSLOCK_CONF EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$stub45:$PATH" egresslock doctor 2>"$d_err")"; d_rc=$?
# EGL-80-L4: the old `network_backend: unknown` sub-assert asserted HOST
# state (no pasta/slirp4netns on the inherited PATH), not engine behavior
# — on a deployed host with pasta installed it fails while the behavior
# under test (advisory fail row + rc 0 + hint) is correct. The pasta
# branch is covered hermetically by case 4 below (its own stub pasta);
# the `unknown` branch stays covered on hosts without pasta. Restored
# without the sub-assert (EGL-81: the EGL-80-L4 decision stands).
[[ "$d_rc" == 0 && "$d_out" == *"rootless_netns: fail:kill network process: permission denied"* \
    && "$(grep -c 'apparmor-check' "$d_err")" -ge 1 ]] \
    && a45 pass || a45 fail "advisory netns fail keeps rc 0 + apparmor hint (rc=$d_rc, out: $d_out)"

# 4. pasta on PATH -> advisory network_backend: pasta.
printf '#!/bin/sh\n' > "$stub45/pasta"; chmod +x "$stub45/pasta"
d_out="$(env -u EGRESSLOCK_CONF EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" PATH="$stub45:$PATH" egresslock doctor 2>/dev/null)"
[[ "$d_out" == *"network_backend: pasta"* ]] \
    && a45 pass || a45 fail "advisory network_backend pasta (out: $d_out)"

# 4b. R-EGL-45-1 note 1: a NON-AppArmor netns failure (not rc 126, not
#     permission denied) must NOT get the --apparmor-check pointer.
cat > "$stub45/podman" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    --version) echo "podman version 5.4.2" ;;
    info) echo "netavark" ;;
    unshare) echo "cgroup manager died unexpectedly" >&2; exit 1 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$stub45/podman"
d_out="$(env -u EGRESSLOCK_CONF EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$stub45:$PATH" egresslock doctor 2>"$d_err")"; d_rc=$?
[[ "$d_rc" == 0 && "$d_out" == *"rootless_netns: fail:cgroup manager died unexpectedly"* \
    && "$(grep -c 'apparmor-check' "$d_err")" == 0 ]] \
    && a45 pass || a45 fail "non-apparmor netns failure keeps rc 0, no apparmor hint (rc=$d_rc, err: $(cat "$d_err"))"

# 4c/4d/4e. EGL-81-D2: dedicated hermetic coverage of all three userns
# row states (enabled / disabled / gateless), around the rc policy:
# `disabled` is a required-row failure (rc 1), the other two rows do not
# force rc. Same all-present stub PATH (the good podman stub restored)
# so every other required tool passes and the row under test is the only
# rc variable.
cat > "$stub45/podman" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    --version) echo "podman version 5.4.2" ;;
    info) echo "netavark" ;;
    unshare) exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$stub45/podman"

# 4c. hook -> fixture `1` -> `userns: enabled`, row does not force rc 1.
d_out="$(env -u EGRESSLOCK_CONF EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$stub45:$PATH" egresslock doctor 2>&1)"; d_rc=$?
[[ "$d_rc" == 0 && "$d_out" == *"userns: enabled"* ]] \
    && a45 pass || a45 fail "userns row enabled, rc not forced (rc=$d_rc, out: $d_out)"

# 4d. hook -> fixture `0` -> `userns: disabled`, doctor rc 1.
d_out="$(env -u EGRESSLOCK_CONF EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-off" \
    PATH="$stub45:$PATH" egresslock doctor 2>&1)"; d_rc=$?
[[ "$d_rc" == 1 && "$d_out" == *"userns: disabled"* ]] \
    && a45 pass || a45 fail "userns row disabled forces rc 1 (rc=$d_rc, out: $d_out)"

# 4e. hook -> absent path -> gateless message, row does not force rc 1.
d_out="$(env -u EGRESSLOCK_CONF EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-absent/gate" \
    PATH="$stub45:$PATH" egresslock doctor 2>&1)"; d_rc=$?
[[ "$d_rc" == 0 \
    && "$d_out" == *"userns: enabled (kernel has no unprivileged_userns_clone gate)"* ]] \
    && a45 pass || a45 fail "userns row gateless, rc not forced (rc=$d_rc, out: $d_out)"

# 5. Extra argument -> rc 2 (usage class).
env -u EGRESSLOCK_CONF egresslock doctor something >/dev/null 2>&1
[[ $? == 2 ]] && a45 pass || a45 fail "doctor extra argument exits 2"

# 6. Root guard (mock id reports uid 0), same message as other commands.
r_out="$(PATH="$TESTROOT/bin-root:$PATH" env -u EGRESSLOCK_CONF egresslock doctor 2>&1)"; r_rc=$?
[[ "$r_rc" == 1 && "$r_out" == *"must run as the account, not root"* ]] \
    && a45 pass || a45 fail "doctor root guard (rc=$r_rc, out: $r_out)"

# 7. --help and short usage list doctor.
egresslock --help | grep -q "egresslock doctor" \
    && a45 pass || a45 fail "--help lists doctor"
egresslock 2>&1 | grep -q "doctor" \
    && a45 pass || a45 fail "short usage lists doctor"

# 8/9. EGL-85-D1: the two bounded branches of the doctor's advisory
#      netns probe (EGL-78) that no earlier case covers: timeout(1)
#      absent and probe expiry (rc 124). A refactor could reintroduce
#      an unbounded probe or misroute the rc-124 hint to the
#      --apparmor-check pointer; these pin both.
# 8. timeout(1) absent: isolated PATH (bin-doctor-none technique) with
#    the healthy stub tools but NO timeout. The fail row must name
#    coreutils, carry the generic hint (not the apparmor pointer), and
#    doctor's rc stays 0 (advisory row policy unchanged).
nt45="$TESTROOT/bin-doctor-notimeout"
rm -rf "$nt45"; mkdir -p "$nt45"
for t in env bash cat id head dirname; do ln -s "$(command -v "$t")" "$nt45/$t"; done
# EGL-139-D2: conntrack is a REQUIRED doctor row — the fixture carries a
# stub so this test isolates the timeout-absent ADVISORY row only (rc 0),
# not a conntrack MISSING rc-1.
cp "$stub45/podman" "$stub45/netavark" "$stub45/nft" "$stub45/conntrack" "$nt45/"
d_out="$(env -u EGRESSLOCK_CONF EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$nt45:$TREE_ROOT" egresslock doctor 2>"$d_err")"; d_rc=$?
[[ "$d_rc" == 0 \
    && "$d_out" == *"rootless_netns: fail:timeout(1) (coreutils) not found in PATH"* \
    && "$(grep -c 'apparmor-check' "$d_err")" == 0 ]] \
    && a45 pass || a45 fail "doctor timeout-absent advisory row, rc 0 (rc=$d_rc, out: $d_out)"

# 9. probe expiry: podman shim sleeps 60s on the probe command only,
#    delegating everything else to the healthy stub. The rc-124 branch
#    must produce the named 5s-timeout row with the GENERIC
#    run-as-the-dedicated-account hint (deliberately NOT
#    --apparmor-check) and keep rc 0, well under the harness bound.
mkdir -p "$TESTROOT/bin-doctor-hang"
cat > "$TESTROOT/bin-doctor-hang/podman" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "unshare" && "\$2" == "--rootless-netns" && "\$3" == "true" ]]; then
    sleep 60
    exit 0
fi
exec "$stub45/podman" "\$@"
EOF
chmod +x "$TESTROOT/bin-doctor-hang/podman"
d_start=$SECONDS
d_out="$(env -u EGRESSLOCK_CONF EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$TESTROOT/bin-doctor-hang:$stub45:$PATH" egresslock doctor 2>"$d_err")"; d_rc=$?
d_elapsed=$(( SECONDS - d_start ))
[[ "$d_rc" == 0 && "$d_out" == *"rootless_netns: fail: probe timed out after 5s"* \
    && "$(grep -c 'run as the dedicated account' "$d_err")" -ge 1 \
    && "$(grep -c 'apparmor-check' "$d_err")" == 0 && "$d_elapsed" -lt 15 ]] \
    && a45 pass || a45 fail "doctor probe expiry: 5s row + generic hint, rc 0 (rc=$d_rc, elapsed=${d_elapsed}s, out: $d_out, err: $(cat "$d_err"))"

egl45_pass=$pass; egl45_fail=$fail

# --- ARC-74: deep state semantics (relocated from the site harness and
# --- neutralized to synthetic fixtures) ----------------------------------
# The tamper/re-ensure, v6deny self-heal, policy/anchor loss recovery and
# rule-order battery existed only in the site harness. Neutral copier
# fixtures (ARC-13-D5): docs-range IPs + example.test hosts, and a
# synthetic multi-profile conf replacing the site conf.
pass=0; fail=0
rm -rf "$STATE"
mkdir -p "$STATE/nft" "$STATE/networks" "$STATE/running" "$STATE/containers" \
         "$STATE/images" "$STATE/ips" "$STATE/runargs"
: > "$STATE/images/localhost_egresslock-gateway_latest"
DEEP_CONF="$TESTROOT/deep/deep.conf"
mkdir -p "$TESTROOT/deep"
: > "$TESTROOT/deep/llm-allowlist"
cat > "$DEEP_CONF" <<'EOF'
profile local-dev 10.50.0.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
    rule allow-host ${FORGEJO_HOST:-git.example.test}:2222
    rule allow-host ${OLLAMA_HOST:-cache.example.test}:11434

profile internet-only 10.50.1.0/24
    rule public-only

profile llm-cloud 10.50.2.0/24
    rule gateway-only
    gateway 10.50.2.2 3128 llm-allowlist

profile dev-llm 10.50.3.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
    rule allow-host ${FORGEJO_HOST:-git.example.test}:2222
    rule allow-host ${OLLAMA_HOST:-cache.example.test}:11434
    rule gateway-only
    gateway 10.50.3.2 3128 llm-allowlist
    no-proxy ${FORGEJO_HOST:-git.example.test},${OLLAMA_HOST:-cache.example.test}
EOF
export EGRESSLOCK_CONF="$DEEP_CONF"
# Setup ensures are uncounted harness setup (their asserts live in the
# site smoke battery); the moved block below opens its own counter.
egresslock ensure local-dev >/dev/null 2>&1
egresslock ensure internet-only >/dev/null 2>&1
egresslock ensure llm-cloud >/dev/null 2>&1
egresslock ensure dev-llm >/dev/null 2>&1
# R-003-2 regression 1: re-install over a POPULATED chain must work
# (flush+delete refresh, then clean re-add). The mock now rejects
# add-over-existing and delete-of-populated, so a plain delete+apply
# would fail here.
rule_count=$(grep -c 'daddr 192.0.2.10 tcp dport 443' "$STATE/nft/egresslock.p_local_dev")
[[ "$rule_count" == 1 ]] && { pass=$((pass+1)); echo "PASS: re-ensure does not duplicate rules"; } || { fail=$((fail+1)); echo "FAIL: re-ensure duplicated rules (count=$rule_count)"; }
# R-003-2 regression 2: the shared v6deny chain is NOT redeclared on
# re-ensure (would fail the whole transaction).
check "re-ensure keeps shared v6deny intact" 0 test -f "$STATE/nft/egresslock.p_v6deny"
# R-003-2 regression 3: a populated chain with STALE rules is fully
# replaced, not merged: rewrite the chain with a bogus rule, re-ensure,
# and confirm the stale rule is gone.
echo "ip saddr 10.50.0.0/24 ip daddr 203.0.113.9 tcp dport 9999 counter accept" >> "$STATE/nft/egresslock.p_local_dev"
check "re-ensure over stale populated chain" 0 egresslock ensure local-dev
grep -q '203.0.113.9' "$STATE/nft/egresslock.p_local_dev" \
    && { echo "FAIL: stale rule survived re-ensure"; fail=$((fail+1)); } \
    || { echo "PASS: stale rules replaced on re-ensure"; pass=$((pass+1)); }
# Other profiles' chains must survive a local-dev re-ensure.
check "other profile chains survive re-ensure" 0 test -f "$STATE/nft/egresslock.p_internet_only"

# R-003-3 regression 1: an existing network with WRONG config must be
# rejected (fail closed), and a matching one accepted.
mocknet() { # mocknet <name> <subnet> <ipv6_enabled> [driver]
    printf 'driver=%s\nsubnet=%s\ngateway=%s\nipv6_enabled=%s\n' \
        "${4:-bridge}" "$2" "${2%0/24}1" "$3" > "$STATE/networks/$1"
}
# a) wrong subnet
mocknet egresslock-local-dev 10.50.99.0/24 false
check "ensure rejects network with wrong subnet" 1 egresslock ensure local-dev
mocknet egresslock-local-dev 10.50.0.0/24 false
# b) IPv6 enabled
mocknet egresslock-local-dev 10.50.0.0/24 true
check "ensure rejects network with IPv6 enabled" 1 egresslock ensure local-dev
mocknet egresslock-local-dev 10.50.0.0/24 false
check "ensure accepts matching network" 0 egresslock ensure local-dev

# R-003-3 regression 2: deep verification.
# a) tampered chain: strip the RFC1918 drops from internet-only; the
#    shallow terminal-rule check would have passed this.
cp "$STATE/nft/egresslock.p_internet_only" "$TESTROOT/backup.io"
grep -v 'daddr 10.0.0.0/8' "$STATE/nft/egresslock.p_internet_only" > "$STATE/nft/egresslock.p_internet_only.tmp" \
    && mv "$STATE/nft/egresslock.p_internet_only.tmp" "$STATE/nft/egresslock.p_internet_only"
check "verify rejects internet-only chain missing RFC1918 drops" 1 egresslock verify internet-only
egresslock ensure internet-only >/dev/null 2>&1
check "ensure restores tampered internet-only chain" 0 egresslock verify internet-only
# b) tampered chain: local-dev missing the forgejo allows.
grep -v 'daddr 192.0.2.10' "$STATE/nft/egresslock.p_local_dev" > "$STATE/nft/egresslock.p_local_dev.tmp" \
    && mv "$STATE/nft/egresslock.p_local_dev.tmp" "$STATE/nft/egresslock.p_local_dev"
check "verify rejects local-dev chain missing forgejo rules" 1 egresslock verify local-dev
egresslock ensure local-dev >/dev/null 2>&1
check "ensure restores tampered local-dev chain" 0 egresslock verify local-dev
# c) missing shared v6-deny chain must fail verification.
rm -f "$STATE/nft/egresslock.p_v6deny"
check "verify fails when v6deny chain missing" 1 egresslock verify local-dev
check "ensure reinstalls v6deny chain" 0 egresslock ensure local-dev
# c2) legacy polluted v6deny (pre-rework versions appended a duplicate
#     drop rule per install under real additive semantics) must be
#     self-healed by install, not just rejected by verify.
cp "$STATE/nft/egresslock.p_v6deny" "$TESTROOT/v6.bak"
echo "meta nfproto ipv6 counter drop" >> "$STATE/nft/egresslock.p_v6deny"
echo "meta nfproto ipv6 counter drop" >> "$STATE/nft/egresslock.p_v6deny"
check "verify rejects v6deny with duplicate drops" 1 egresslock verify local-dev
check "ensure self-heals polluted v6deny chain" 0 egresslock ensure local-dev
check "verify passes after v6deny self-heal" 0 egresslock verify local-dev
[[ "$(grep -c 'meta nfproto ipv6 counter drop' "$STATE/nft/egresslock.p_v6deny")" == 1 ]] \
    && { echo "PASS: v6deny self-heal leaves exactly one drop rule"; pass=$((pass+1)); } \
    || { echo "FAIL: v6deny self-heal left duplicates"; fail=$((fail+1)); }
# d) extra foreign rule in the chain must fail verification.
echo "ip saddr 10.50.0.0/24 ip daddr 203.0.113.9 tcp dport 9999 counter accept" >> "$STATE/nft/egresslock.p_local_dev"
check "verify fails on unexpected extra rule" 1 egresslock verify local-dev
egresslock ensure local-dev >/dev/null 2>&1
check "ensure cleans foreign rule" 0 egresslock verify local-dev

# R-003-4 regression 1: canonicalize must handle INDENTED nft output
# (real 'nft list chain' format). The mock now emits indented bodies;
# verify below exercises it. Assert explicitly that verify works with
# indented output (it aborted before the fix).
check "verify works on indented real-format nft output" 0 egresslock verify local-dev
# And the raw listing really is indented (guards the mock against drift).
grep -qE '^        ip saddr 10\.93\.0\.0/24' "$TESTROOT/unused" 2>/dev/null || true
indented="$(PATH="$TESTROOT/bin:$PATH" bash -c "podman unshare --rootless-netns nft list chain inet egresslock p_local_dev" 2>/dev/null | grep -c '^        ip saddr')"
[[ "${indented:-0}" -gt 0 ]] && { pass=$((pass+1)); echo "PASS: mock nft emits indented rules"; } || { fail=$((fail+1)); echo "FAIL: mock nft not emitting indented rules"; }

# R-003-4 regression 2: a network with the expected subnet PLUS an extra
# subnet must be rejected (fail closed).
cat > "$STATE/networks/egresslock-local-dev" <<EOF2
subnet=10.50.0.0/24
subnet=10.50.4.0/24
gateway=10.50.0.1
ipv6_enabled=false
EOF2
check "ensure rejects network with two subnets" 1 egresslock ensure local-dev
mocknet egresslock-local-dev 10.50.0.0/24 false
check "ensure accepts single-subnet network again" 0 egresslock ensure local-dev

# Simulate the ARC-1 attempt-3 finding: netns state destroyed when the last
# container stops. Clear nft state; verify must fail; ensure must recover.
rm -f "$STATE/nft/"*
check "verify fails when policy lost (fail closed)" 1 egresslock verify local-dev
check "ensure reinstalls lost policy" 0 egresslock ensure local-dev
check "verify succeeds after re-ensure" 0 egresslock verify local-dev

# Simulate the anchor dying: verify must fail, ensure must recover.
rm -f "$STATE/running/egresslock-anchor-local-dev"
check "verify fails when anchor dead" 1 egresslock verify local-dev
check "ensure restarts anchor + verifies" 0 egresslock ensure local-dev

# The site battery's agent-run wrapper ensured this chain silently on its
# way here; re-ensure it (uncounted) so the R-003-7 assertions exercise
# the reorder, not the missing chain. EGL-91-D2: a FIRST ensure now ends
# on the create-with-rules transaction (no flush); the second call is a
# warm ensure whose last transaction is the flush+re-add refresh these
# assertions target.
egresslock ensure internet-only >/dev/null 2>&1
egresslock ensure internet-only >/dev/null 2>&1

# --- R-003-7 regressions (EGL-106 retarget) ---
# 1. Atomic refresh: the chain replacement must be ONE transaction
#    (flush + rules in the same nft file), never separate invocations —
#    and EGL-106: the WHOLE install (v6deny + profile) is that one
#    file, so the last (only) transaction carries BOTH chains: the
#    profile chain's flush is inline with its re-added ip saddr rules,
#    the p_v6deny block is in the same file with its rule re-added.
#    A split two-file install (v6deny file, then profile refresh) no
#    longer passes this pin.
if grep -q '^flush chain inet egresslock p_internet_only' "$STATE/nft/last-transaction.nft" \
   && grep -q '^flush chain inet egresslock p_v6deny' "$STATE/nft/last-transaction.nft" \
   && grep -qE '^[[:space:]]*chain p_internet_only \{' "$STATE/nft/last-transaction.nft" \
   && grep -qE '^[[:space:]]*chain p_v6deny \{' "$STATE/nft/last-transaction.nft" \
   && grep -q 'ip saddr' "$STATE/nft/last-transaction.nft" \
   && grep -q 'meta nfproto ipv6 counter drop' "$STATE/nft/last-transaction.nft"; then
    pass=$((pass+1)); echo "PASS: refresh is one combined flush+rules transaction (v6deny + profile)"
else
    fail=$((fail+1)); echo "FAIL: install transaction lacks the combined v6deny+profile flush+rules"
fi
# 2. Ordered verification: an accept reordered before the RFC1918 drops
#    must be REJECTED (the adversarial case from the review).
cp "$STATE/nft/egresslock.p_internet_only" "$TESTROOT/io.bak"
python3 - "$STATE/nft/egresslock.p_internet_only" <<'PY2'
import sys
p = sys.argv[1]
lines = open(p).readlines()
acc = next(i for i,l in enumerate(lines) if 'counter accept' in l and '10.50.1.0/24' in l and 'daddr' not in l)
drop = next(i for i,l in enumerate(lines) if '172.16.0.0/12' in l)
lines[acc], lines[drop] = lines[drop], lines[acc]
open(p,'w').writelines(lines)
PY2
check "verify rejects reordered internet-only accept/drop" 1 egresslock verify internet-only
cp "$TESTROOT/io.bak" "$STATE/nft/egresslock.p_internet_only"
check "verify passes restored internet-only chain" 0 egresslock verify internet-only
# 3. v6 chain tampering must be rejected (wrong priority, extra accept).
cp "$STATE/nft/egresslock.p_v6deny" "$TESTROOT/v6.bak"
sed -i 's/priority -160/priority -100/' "$STATE/nft/egresslock.p_v6deny"
check "verify rejects v6deny with wrong priority" 1 egresslock verify local-dev
cp "$TESTROOT/v6.bak" "$STATE/nft/egresslock.p_v6deny"
sed -i '1i ip saddr fe80::1 counter accept' "$STATE/nft/egresslock.p_v6deny"
check "verify rejects v6deny with leading accept" 1 egresslock verify local-dev
cp "$TESTROOT/v6.bak" "$STATE/nft/egresslock.p_v6deny"
# 4. Network driver validation: a same-name macvlan network is rejected.
mocknet egresslock-local-dev 10.50.0.0/24 false macvlan
check "ensure rejects non-bridge network driver" 1 egresslock ensure local-dev
mocknet egresslock-local-dev 10.50.0/24 false bridge 2>/dev/null || true
mocknet egresslock-local-dev 10.50.0.0/24 false bridge
# 5. Gateway mismatch rejected.
mocknet egresslock-local-dev 10.50.0.0/24 false bridge
sed -i 's/^gateway=.*/gateway=10.99.0.1/' "$STATE/networks/egresslock-local-dev"
check "ensure rejects network with wrong gateway" 1 egresslock ensure local-dev
mocknet egresslock-local-dev 10.50.0.0/24 false bridge
check "ensure accepts correct driver+gateway" 0 egresslock ensure local-dev

# --- dev-llm combined profile (ARC-6) ---
check_out "dev-llm network name" "egresslock-dev-llm" egresslock network dev-llm
check "ensure dev-llm" 0 egresslock ensure dev-llm
check "dev-llm gateway running" 0 test -f "$STATE/running/egresslock-gateway-dev-llm"
grep -q '10.50.3.2' "$STATE/containers/egresslock-gateway-dev-llm.ip" 2>/dev/null \
    && { pass=$((pass+1)); echo "PASS: dev-llm gateway at 10.50.3.2"; } \
    || { fail=$((fail+1)); echo "FAIL: dev-llm gateway IP wrong"; }
grep -q '10.50.3.254' "$STATE/containers/egresslock-anchor-dev-llm.ip" 2>/dev/null \
    && { pass=$((pass+1)); echo "PASS: dev-llm anchor at 10.50.3.254"; } \
    || { fail=$((fail+1)); echo "FAIL: dev-llm anchor IP not reserved"; }
# Combined chain: local-dev rules + gateway hop + exemption before drop.
grep -q 'daddr 192.0.2.10 tcp dport 2222' "$STATE/nft/egresslock.p_dev_llm" \
    && { pass=$((pass+1)); echo "PASS: dev-llm has forgejo SSH rule"; } \
    || { fail=$((fail+1)); echo "FAIL: dev-llm missing forgejo SSH rule"; }
grep -q 'daddr 192.0.2.11 tcp dport 11434' "$STATE/nft/egresslock.p_dev_llm" \
    && { pass=$((pass+1)); echo "PASS: dev-llm has ollama rule"; } \
    || { fail=$((fail+1)); echo "FAIL: dev-llm missing ollama rule"; }
grep -q 'ip saddr 10.50.3.0/24 iifname "podman1" ip daddr 10.50.3.2 tcp dport 3128' "$STATE/nft/egresslock.p_dev_llm" \
    && { pass=$((pass+1)); echo "PASS: dev-llm has gateway hop rule"; } \
    || { fail=$((fail+1)); echo "FAIL: dev-llm missing gateway hop rule"; }
# EGL-123-D2/D3: the gateway exemption is keyed on source IP + the
# kit-derived pinned MAC. The MAC derivation (gw_mac) is re-computed
# here from the same conf identity so a drift in the engine's
# derivation fails this pin instead of silently matching.
d_mac_hex="$(printf '%s' 'dev-llm|10.50.3.2' | sha256sum | cut -d' ' -f1)"
d_mac="02:${d_mac_hex:0:2}:${d_mac_hex:2:2}:${d_mac_hex:4:2}:${d_mac_hex:6:2}:${d_mac_hex:8:2}"
# D3: the gateway run argv carries --mac-address with the derived pin.
grep -q -- "--mac-address ${d_mac}" "$STATE/runlog" 2>/dev/null \
    && { pass=$((pass+1)); echo "PASS: dev-llm gateway run pins derived MAC"; } \
    || { fail=$((fail+1)); echo "FAIL: dev-llm gateway run missing --mac-address ${d_mac}"; }
grep -q "${d_mac}" "$STATE/containers/egresslock-gateway-dev-llm.mac" 2>/dev/null \
    && { pass=$((pass+1)); echo "PASS: dev-llm gateway stored MAC equals pin"; } \
    || { fail=$((fail+1)); echo "FAIL: dev-llm gateway stored MAC != pin"; }
grep -q "ip saddr 10.50.3.2 iifname \"podman1\" ether saddr ${d_mac} counter accept" "$STATE/nft/egresslock.p_dev_llm" \
    && { pass=$((pass+1)); echo "PASS: dev-llm exemption is saddr+derived-MAC"; } \
    || { fail=$((fail+1)); echo "FAIL: dev-llm exemption not saddr+derived-MAC"; }
d_accept="$(grep -n "ip saddr 10.50.3.2 iifname \"podman1\" ether saddr ${d_mac} counter accept" "$STATE/nft/egresslock.p_dev_llm" | cut -d: -f1 | head -1)"
d_drop="$(grep -n '^ip saddr 10.50.3.0/24 counter drop' "$STATE/nft/egresslock.p_dev_llm" | cut -d: -f1 | head -1)"
if [[ -n "$d_accept" && -n "$d_drop" && "$d_accept" -lt "$d_drop" ]]; then
    pass=$((pass+1)); echo "PASS: dev-llm exemption before drop"
else
    fail=$((fail+1)); echo "FAIL: dev-llm exemption missing or after drop"
fi
# D3: warm ensure of a matching-MAC gateway does NOT replace it (the
# EGL-114 converged skip survives the MAC gate).
: > "$STATE/opslog"
check "ensure dev-llm (warm, MAC matches)" 0 egresslock ensure dev-llm
if ! grep -qE '^podman (rm|run) .*egresslock-gateway-dev-llm' "$STATE/opslog" 2>/dev/null; then
    pass=$((pass+1)); echo "PASS: dev-llm warm ensure keeps matching-MAC gateway (no rm/run)"
else
    fail=$((fail+1)); echo "FAIL: dev-llm warm ensure replaced matching-MAC gateway (ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi
# D3: a drifted live MAC is identity drift — ensure replaces (rm + run
# with the pin); the exemption line in the new chain carries the pin.
echo 'ff:ff:ff:ff:ff:ff' > "$STATE/containers/egresslock-gateway-dev-llm.mac"
: > "$STATE/opslog"
check "ensure dev-llm (drifted MAC -> replace)" 0 egresslock ensure dev-llm
if grep -qE '^podman rm .* egresslock-gateway-dev-llm$' "$STATE/opslog" 2>/dev/null \
   && grep -qE "^podman run .*--name egresslock-gateway-dev-llm .*--mac-address ${d_mac}" "$STATE/opslog" 2>/dev/null; then
    pass=$((pass+1)); echo "PASS: dev-llm drifted-MAC ensure replaced with pinned MAC"
else
    fail=$((fail+1)); echo "FAIL: dev-llm drifted-MAC ensure did not replace with the pin (ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi
# D3: verify on a drifted MAC fails closed with the named line.
echo 'ff:ff:ff:ff:ff:ff' > "$STATE/containers/egresslock-gateway-dev-llm.mac"
o="$(egresslock verify dev-llm 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"verify: gateway MAC is 'ff:ff:ff:ff:ff:ff', expected '${d_mac}'"* ]]; then
    pass=$((pass+1)); echo "PASS: dev-llm verify fails closed on drifted MAC"
else
    fail=$((fail+1)); echo "FAIL: dev-llm verify drifted-MAC message (rc=$rc, out: $o)"
fi
# Restore: re-ensure recreates the gateway with the pinned MAC and
# verify is green again (the MAC gate closed the loop).
check "ensure dev-llm restores pinned MAC" 0 egresslock ensure dev-llm
grep -q "${d_mac}" "$STATE/containers/egresslock-gateway-dev-llm.mac" 2>/dev/null \
    && { pass=$((pass+1)); echo "PASS: dev-llm re-ensure re-pins MAC"; } \
    || { fail=$((fail+1)); echo "FAIL: dev-llm re-ensure did not re-pin MAC"; }
# Generated gateway config uses the dev-llm subnet.
check_out "dev-llm gateway config class ACL" "acl agent_class src 10.50.3.0/24" \
    cat "$STATE/containers-egresslock-gateway-dev-llm.allowlist.last"


deep_pass=$pass; deep_fail=$fail

# --- EGL-55: verify missing-network message points at ensure (D55-2) ------
# The network-inspect guard is the first check in verify_policy: with the
# network absent, rc 1 and the hint names `egresslock ensure <profile>`
# (bare egresslock spelling; never suggests `verify` itself).
pass=0; fail=0
rm -f "$STATE/networks/egresslock-local-dev"
o="$(egresslock verify local-dev 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"verify: network egresslock-local-dev missing"* \
    && "$o" == *"missing — run: egresslock ensure local-dev"* \
    && "$o" != *"egresslock verify"* ]] \
    && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: D55-2 verify missing-network names ensure (rc=$rc, out: $o)"; }
# The chain checks still fire normally when the network exists (existing
# pins above cover them); restore the network so nothing downstream of
# this section sees a half-removed fixture.
egresslock ensure local-dev >/dev/null 2>&1
[[ -f "$STATE/networks/egresslock-local-dev" ]] \
    && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: EGL-55 fixture restore (local-dev network recreated)"; }
egl55_pass=$pass; egl55_fail=$fail

# --- EGL-59: --help is operator UI — no ticket/process citations ----------
# The dumped header (help = the leading comment block, R-014-1 F1) must
# not leak ticket/decision IDs or ticket paths. The EGL-57 checks: block
# (already ID-free) must still be present in full.
pass=0; fail=0
h_out="$(env -u EGRESSLOCK_CONF egresslock --help 2>&1)"; h_rc=$?
if [[ "$h_rc" == 0 ]] && ! grep -qE 'ARC-[0-9]|EGL-[0-9]|docs/tickets/[A-Za-z0-9]' <<<"$h_out"; then
    pass=$((pass+1))
else
    fail=$((fail+1)); echo "FAIL: EGL-59 engine --help leaks ticket/process refs (rc=$h_rc)"
fi
h_ok=1
for c in "egresslock doctor " "egresslock-setup --doctor [--account]" \
         "egresslock-setup --apparmor-check" "egresslock verify <profile>"; do
    grep -qF "$c" <<<"$h_out" || h_ok=0
done
[[ "$h_ok" == 1 ]] \
    && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: EGL-57 checks: block dropped from engine --help"; }
egl59_pass=$pass; egl59_fail=$fail

# --- EGL-66: the anchor is hardened like the gateway -----------------------
# D1: the anchor `podman run` carries --cap-drop=all +
# --security-opt=no-new-privileges (it only sleeps). D2: the fallback
# anchor image is digest-pinned (never a floating third-party tag);
# the resolution order itself (env > localhost/base:latest > fallback)
# is unchanged.
pass=0; fail=0
e66() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S66="$TESTROOT/s66"; rm -rf "$S66"; mkdir -p "$S66"
cat > "$S66/anch.conf" <<'EOF'
profile s66 10.199.74.0/24
    rule public-only
EOF
# D2: with no env override and no localhost/base in the mock store, the
# anchor run names the digest-pinned fallback.
egresslock --config "$S66/anch.conf" teardown s66 >/dev/null 2>&1 || true
: > "$STATE/runlog"
e66_out="$(env -u EGRESSLOCK_ANCHOR_IMAGE egresslock --config "$S66/anch.conf" ensure s66 2>&1)"; e66_rc=$?
e66_anchor="$(grep -m1 'egresslock-anchor-s66' "$STATE/runlog" || true)"
[[ "$e66_rc" == 0 && -n "$e66_anchor" ]] \
    && e66 pass || e66 fail "ensure with default anchor image (rc=$e66_rc, anchor line: $e66_anchor)"
grep -q '@sha256:' <<<"$e66_anchor" \
    && e66 pass || e66 fail "fallback anchor image is digest-pinned (run line: $e66_anchor)"
grep -q 'alpine:3.22@sha256:' <<<"$e66_anchor" \
    && e66 pass || e66 fail "fallback names a concrete alpine version + digest (run line: $e66_anchor)"
if grep -q 'docker.io/library/alpine:latest' <<<"$e66_anchor"; then
    e66 fail "fallback still floats :latest (EGL-66-D2)"
else
    e66 pass
fi
# D1: the anchor run carries the gateway's hardening pair.
grep -q -- '--cap-drop=all' <<<"$e66_anchor" \
    && e66 pass || e66 fail "anchor run has --cap-drop=all (run line: $e66_anchor)"
grep -q -- '--security-opt=no-new-privileges' <<<"$e66_anchor" \
    && e66 pass || e66 fail "anchor run has --security-opt=no-new-privileges (run line: $e66_anchor)"
# D2: the shipped fallback string itself is pinned (static pin — the
# env-override and localhost/base branches stay reachable for tests).
grep -q 'docker.io/library/alpine:.*@sha256:' "$TREE_ROOT/egresslock" \
    && e66 pass || e66 fail "engine fallback anchor image carries a digest pin"
# D1/D2: an explicit env override still wins unchanged (resolution order
# preserved) — and still gets the hardening pair.
egresslock --config "$S66/anch.conf" teardown s66 >/dev/null 2>&1 || true
: > "$STATE/runlog"
env EGRESSLOCK_ANCHOR_IMAGE="localhost/base:latest" \
    egresslock --config "$S66/anch.conf" ensure s66 >/dev/null 2>&1; e66_rc=$?
e66_anchor="$(grep -m1 'egresslock-anchor-s66' "$STATE/runlog" || true)"
[[ "$e66_rc" == 0 && "$e66_anchor" == *'localhost/base:latest'* \
    && "$e66_anchor" == *'--cap-drop=all'* \
    && "$e66_anchor" == *'--security-opt=no-new-privileges'* ]] \
    && e66 pass || e66 fail "env override still wins + anchor hardened (rc=$e66_rc, run line: $e66_anchor)"
# Restore the harness default state for anything downstream.
egresslock --config "$S66/anch.conf" teardown s66 >/dev/null 2>&1 || true
egl66_pass=$pass; egl66_fail=$fail

echo
# --- EGL-91: anchor is the netns holder and starts first (D4); policy
#     lands after the holder, before the gateway; first create is ONE
#     transaction with rules (audit G-06/I-06, EGL-93 live finding) ---
pass=0; fail=0
a91() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S91="$TESTROOT/s91"; rm -rf "$S91"; mkdir -p "$S91"
: > "$STATE/images/localhost_egresslock-gateway_latest"
cat > "$S91/gw.conf" <<'EOF'
profile s91 10.199.95.0/24
    rule gateway-only
    gateway 10.199.95.2 3128 s91-allowlist
EOF
printf 'git.example.test\n' > "$S91/s91-allowlist"

# D3.1/D3.2 (amended by D4; EGL-106 retarget): on a FIRST ensure of a
# gateway profile the call order is: podman run (ANCHOR — the netns
# holder), then the ONE combined nft install transaction (EGL-106:
# p_v6deny refresh + p_s91 create-with-rules in a single -f), then
# podman run (GATEWAY). A pre-container nft write would land in an
# unheld netns and be discarded with it (EGL-93). callorder.log carries
# the mock's nft -f summary lines and podman run lines in call order.
: > "$STATE/callorder.log"
a91_out="$(egresslock --config "$S91/gw.conf" ensure s91 2>&1)"; a91_rc=$?
p91_first="$(grep -n 'chains=.*p_s91' "$STATE/callorder.log" | head -1 | cut -d: -f1)"
p91_entry="$(grep 'chains=.*p_s91' "$STATE/callorder.log" | head -1)"
mapfile -t p91_runs < <(grep -n '^podman run' "$STATE/callorder.log" | cut -d: -f1)
if [[ "$a91_rc" == 0 && ${#p91_runs[@]} -ge 2 && -n "$p91_first" \
      && "$p91_first" -gt "${p91_runs[0]}" && "$p91_first" -lt "${p91_runs[1]}" \
      && "$p91_entry" == *"p_v6deny"* && "${p91_entry##*rules=}" != 0 ]]; then
    a91 pass
else
    a91 fail "first-ensure order: anchor run, then one combined install -f, then gateway run (rc=$a91_rc entry=[$p91_entry] nft@$p91_first runs=${p91_runs[*]:-none} out=$a91_out)"
fi
# D3.1 (cont., EGL-106 retarget): the first ensure has exactly ONE -f
# (the combined install). By the time this section runs p_v6deny
# already exists, so the file flushes v6deny while CREATING p_s91 —
# no flush chain line may target p_s91 — and both chain blocks are in
# the file; the created p_s91 content carries the terminal drop.
n91_txn="$(grep -c '^nft -f ' "$STATE/callorder.log" || true)"
if [[ "$n91_txn" == 1 ]]; then
    a91 pass
else
    a91 fail "first-ensure = 1 install transaction, got $n91_txn: $(grep '^nft -f ' "$STATE/callorder.log" | tr '\n' '|')"
fi
if grep -q '^flush chain inet egresslock p_v6deny' "$STATE/nft/last-transaction.nft" \
   && grep -qE '^[[:space:]]*chain p_v6deny \{' "$STATE/nft/last-transaction.nft" \
   && grep -qE '^[[:space:]]*chain p_s91 \{' "$STATE/nft/last-transaction.nft" \
   && ! grep -q 'flush chain .* p_s91' "$STATE/nft/last-transaction.nft" \
   && grep -q 'counter drop' "$STATE/nft/last-transaction.nft"; then
    a91 pass
else
    a91 fail "first-ensure transaction: flush v6deny + create-with-rules p_s91, no p_s91 flush (file: $(tr '\n' '|' < "$STATE/nft/last-transaction.nft" 2>/dev/null))"
fi
# ... and the created chain state carries the terminal per-subnet drop
# (policy_rules inside the create transaction, end state verified by
# the ensure's own strict verify already).
grep -q 'counter drop' "$STATE/nft/egresslock.p_s91" \
    && a91 pass || a91 fail "created p_s91 chain carries rules (find: $(ls "$STATE/nft" | tr '\n' ' '))"

# D3.4 (EGL-106 retarget): warm ensure (both chains present) is ONE
# atomic transaction — the p_s91 flush AND its re-added rules live in
# the SAME file as the v6deny refresh; no create-style no-flush entry.
# (The combined summary flush= count is 2 — both chains; not pinned.)
: > "$STATE/callorder.log"
a91_out="$(egresslock --config "$S91/gw.conf" ensure s91 2>&1)"; a91_rc=$?
w91_entry="$(grep 'chains=.*p_s91' "$STATE/callorder.log" | head -1)"
if [[ "$a91_rc" == 0 && -n "$w91_entry" ]] \
      && ! grep -q 'chains=.*p_s91.*flush=0' "$STATE/callorder.log" \
      && grep -q '^flush chain inet egresslock p_s91' "$STATE/nft/last-transaction.nft" \
      && grep -q '^flush chain inet egresslock p_v6deny' "$STATE/nft/last-transaction.nft" \
      && grep -q 'ip saddr' "$STATE/nft/last-transaction.nft" \
      && grep -q 'counter drop' "$STATE/nft/last-transaction.nft"; then
    a91 pass
else
    a91 fail "warm ensure = one combined atomic flush+re-add (rc=$a91_rc entry=[$w91_entry])"
fi

arc91_pass=$pass; arc91_fail=$fail

# --- EGL-114: ensure is non-disruptive on a converged profile (D2/D5) ----
# D5 mock matrix: converged warm ensure must not restart or rm the
# gateway/anchor; a changed allowlist/conf applies + restarts; a dead
# gateway still replaces + applies; the EGL-91-D4 order pins above stay
# green. opslog (lib.sh mock) records podman rm/run/restart argv.
pass=0; fail=0
a114() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S114="$TESTROOT/s114"; rm -rf "$S114"; mkdir -p "$S114"
: > "$STATE/images/localhost_egresslock-gateway_latest"
cat > "$S114/gw.conf" <<'EOF'
profile s114 10.199.94.0/24
    rule gateway-only
    gateway 10.199.94.2 3128 s114-allowlist
EOF
printf 'git.example.test\n' > "$S114/s114-allowlist"
run114() { env EGRESSLOCK_CONF="$S114/gw.conf" HOME="$S114" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

# Setup / D4 first-create: bootstrap gateway has no deployed files, so
# the compare differs and the apply path runs (restart + honest line).
o="$(run114 ensure s114 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"gateway 'egresslock-gateway-s114' ready (allowlist applied, health verified)"* ]] \
   && grep -qE '^podman restart .* egresslock-gateway-s114$' "$STATE/opslog"; then
    a114 pass
else
    a114 fail "first create = apply path (rc=$rc, out: $o, ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi

# D5 pin 1: warm ensure, gateway healthy, generated config identical to
# the deployed files -> NO restart, NO rm -f of the gateway or anchor,
# NO anchor recreate, and the stdout line must not claim "allowlist
# applied" (D1: that would lie).
: > "$STATE/opslog"
o="$(run114 ensure s114 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"gateway 'egresslock-gateway-s114' ready (already converged, not restarted)"* \
      && "$o" != *"allowlist applied"* ]] \
   && ! grep -qE '^podman restart .* egresslock-gateway-s114' "$STATE/opslog" \
   && ! grep -qE '^podman rm .* egresslock-(gateway|anchor)-s114' "$STATE/opslog" \
   && ! grep -qE '^podman run .*--name egresslock-(gateway|anchor)-s114' "$STATE/opslog"; then
    a114 pass
else
    a114 fail "warm converged ensure skips restart/rm (rc=$rc, out: $o, ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi

# D5 pin 2 (allowlist mutator): warm ensure after an allowlist change ->
# the apply path DOES run (restart) and the line is the apply line.
printf 'git.example.test\ncache.example.test\n' >> "$S114/s114-allowlist"
: > "$STATE/opslog"
o="$(run114 ensure s114 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied, health verified"* ]] \
   && grep -qE '^podman restart .* egresslock-gateway-s114$' "$STATE/opslog"; then
    a114 pass
else
    a114 fail "allowlist change applies + restarts (rc=$rc, out: $o, ops: $(tr '\n' '|' < "$STATE/opslog"))"
fi

# D2 filename-completeness, converged side: after the mutator apply the
# NEXT redundant ensure converges again (an unreferenced live allowlist
# file — here the stale domains group from a config that no longer uses
# it, or the image entrypoint's allowlist.conf — must never wedge the
# skip; see the EGL-114 Decision History).
: > "$STATE/opslog"
o="$(run114 ensure s114 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"already converged, not restarted"* ]] \
    && a114 pass || a114 fail "converged again after mutator apply (rc=$rc, out: $o)"

# D5 pin 3: gateway NOT running -> today's replace (rm -f + run) still
# happens, then apply + restart (ensure stays crash recovery).
rm -f "$STATE/running/egresslock-gateway-s114"
: > "$STATE/opslog"
o="$(run114 ensure s114 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied, health verified"* ]] \
   && grep -q '^podman rm -f egresslock-gateway-s114$' "$STATE/opslog" \
   && grep -q '^podman run .*--name egresslock-gateway-s114' "$STATE/opslog" \
   && grep -qE '^podman restart .* egresslock-gateway-s114$' "$STATE/opslog"; then
    a114 pass
else
    a114 fail "dead gateway replaced + applied (rc=$rc, out: $o, ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi

egl114_pass=$pass; egl114_fail=$fail

# --- EGL-116: per-profile read-timeout knob (D1) -------------------------
# Grammar rejects (config_error, exit 2) + the generated conf always
# carries the explicit `read_timeout N seconds` line (default 900).
pass=0; fail=0
a116() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S116="$TESTROOT/s116"; rm -rf "$S116"; mkdir -p "$S116"

# 1. Default (directive absent): 900 in the generated conf.
cat > "$S116/d.conf" <<'EOF'
profile s116d 10.199.93.0/24
    rule gateway-only
    gateway 10.199.93.2 3128 s116d-allowlist
EOF
: > "$S116/s116d-allowlist"
o="$(egresslock --config "$S116/d.conf" ensure s116d 2>&1)"; rc=$?
sq="$(find "$STATE" -name 'containers-egresslock-gateway-s116d.squid-gw.conf' 2>/dev/null | head -1)"
if [[ "$rc" == 0 && -n "$sq" && "$(grep -m1 '^read_timeout ' "$sq")" == "read_timeout 900 seconds" ]]; then
    a116 pass
else
    a116 fail "default read_timeout 900 emitted (rc=$rc sq=[$sq] $(grep -m1 '^read_timeout ' "$sq" 2>/dev/null))"
fi
# ... and no other squid timer is touched (D1: only read_timeout).
[[ -n "$sq" && "$(grep -cE '^(client_lifetime|request_timeout|connect_timeout)' "$sq")" == 0 ]] \
    && a116 pass || a116 fail "no other squid timeout lines added (sq=$sq)"

# 2. Explicit value: interpolated verbatim.
cat > "$S116/v.conf" <<'EOF'
profile s116v 10.199.92.0/24
    rule gateway-only
    read-timeout 60
    gateway 10.199.92.2 3128 s116v-allowlist
EOF
: > "$S116/s116v-allowlist"
o="$(egresslock --config "$S116/v.conf" ensure s116v 2>&1)"; rc=$?
sq="$(find "$STATE" -name 'containers-egresslock-gateway-s116v.squid-gw.conf' 2>/dev/null | head -1)"
[[ "$rc" == 0 && -n "$sq" && "$(grep -m1 '^read_timeout ' "$sq")" == "read_timeout 60 seconds" ]] \
    && a116 pass || a116 fail "read-timeout 60 -> read_timeout 60 seconds (rc=$rc sq=[$sq])"

# 3. Grammar rejects: zero, suffix, negative, leading zero, non-integer,
#    duplicate, trailing text, outside a block — all exit 2.
bad116() { # bad116 <name> <content> <message-substring>
    printf '%s\n' "$2" > "$S116/$1.conf"
    local out rc=0
    out="$(egresslock --config "$S116/$1.conf" list 2>&1)" || rc=$?
    if [[ "$rc" == 2 && "$out" == *"$1.conf:"* && "$out" == *"$3"* ]]; then
        a116 pass
    else
        a116 fail "bad read-timeout '$1' (rc=$rc, msg: $out)"
    fi
}
bad116 rt-zero $'profile a 10.199.90.0/24\n    read-timeout 0' "invalid read-timeout '0'"
bad116 rt-suffix $'profile a 10.199.90.0/24\n    read-timeout 15m' "invalid read-timeout '15m'"
bad116 rt-negative $'profile a 10.199.90.0/24\n    read-timeout -5' "invalid read-timeout '-5'"
bad116 rt-leading-zero $'profile a 10.199.90.0/24\n    read-timeout 010' "invalid read-timeout '010'"
bad116 rt-text $'profile a 10.199.90.0/24\n    read-timeout soon' "invalid read-timeout 'soon'"
bad116 rt-dup $'profile a 10.199.90.0/24\n    read-timeout 60\n    read-timeout 120' "duplicate 'read-timeout'"
bad116 rt-trailing $'profile a 10.199.90.0/24\n    read-timeout 60 extra' "unexpected trailing text after read-timeout"
bad116 rt-outside $'read-timeout 60\nprofile a 10.199.90.0/24' "'read-timeout' outside a profile block"

egl116_pass=$pass; egl116_fail=$fail

# --- EGL-120: unresolvable allow-host — clean abort, hint, no nft dump ---
# D1: the swallowed-die footgun must abort BEFORE nft (no malformed
# rule consumed, no stacked nft error) and print the remediation hints.
pass=0; fail=0
a120() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S120="$TESTROOT/s120"; rm -rf "$S120"; mkdir -p "$S120"
cat > "$S120/gw.conf" <<'EOF'
profile s120 10.199.91.0/24
    rule allow-host nonexistent.example.test:8080
EOF
# EGL-106: snapshot the last consumed transaction — a rule-gen failure
# emits NO -f at all, so the failed ensure must not change it (no
# partial v6-deny file either).
egl120_lt_before="$(cat "$STATE/nft/last-transaction.nft" 2>/dev/null)"
o="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock --config "$S120/gw.conf" ensure s120 2>&1)"; rc=$?
if [[ "$rc" != 0 \
      && "$o" == *"cannot resolve nonexistent.example.test"* \
      && "$o" == *"disallow-host s120 nonexistent.example.test:8080"* \
      && "$o" == *"allow s120 nonexistent.example.test:8080"* \
      && "$o" == *"allow-host s120 169.254.1.2:8080"* \
      && "$o" != *"datatype mismatch"* \
      && "$o" != *"nft policy refresh failed"* \
      && "$o" != *"nft policy install failed"* ]]; then
    a120 pass
else
    a120 fail "unresolvable allow-host = one clean abort + hints (rc=$rc, out: $o)"
fi

# The malformed rule must never reach nft — and with EGL-106's
# single-transaction install, a rule-generation failure emits NO -f at
# all: last-transaction.nft is unchanged by the failed ensure (it holds
# whatever the harness's previous install wrote; the old two-file
# install would have landed the v6-deny file first).
egl120_lt_after="$(cat "$STATE/nft/last-transaction.nft" 2>/dev/null)"
if [[ "$egl120_lt_before" == "$egl120_lt_after" ]] \
   && ! grep -q 'ip daddr  tcp' "$STATE/nft/last-transaction.nft"; then
    a120 pass
else
    a120 fail "failed rule-gen must not consume any nft transaction ($(cat "$STATE/nft/last-transaction.nft" 2>/dev/null | tr '\n' '|' | head -c 200))"
fi

# ARC-38-D3 write-then-ensure unchanged: the conf still carries the rule
# after the failed ensure.
grep -q 'rule allow-host nonexistent.example.test:8080' "$S120/gw.conf" \
    && a120 pass || a120 fail "failed ensure keeps the rule in the conf"

egl120_pass=$pass; egl120_fail=$fail

# --- EGL-141: bridge-scoped accepts + counted anti-spoof drop (D1/D2) ----
# The compiler resolves the profile's live bridge token (the single
# netns-topology token; EGL-91 narrow amendment) and scopes EVERY
# saddr-keyed accept with `iifname "<bridge>"`; the anti-spoof drop is
# FIRST (iifname != form); the terminal drop stays saddr-keyed and
# UNscoped. Stale-token churn must fail verify closed (named iifname
# diff) and be repaired by ensure; an unconfirmable device fails the
# emit by rc (no partial file, no nft transaction).
pass=0; fail=0
a141() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S141="$TESTROOT/s141"; rm -rf "$S141"; mkdir -p "$S141"
cat > "$S141/gw.conf" <<'EOF'
profile s141a 10.199.81.0/24
    rule allow-host git.example.test:2222
    rule gateway-only
    gateway 10.199.81.2 3128 s141-allowlist
profile s141p 10.199.82.0/24
    rule public-only
EOF
: > "$S141/s141-allowlist"
egresslock --config "$S141/gw.conf" ensure s141a >/dev/null 2>&1; a141_rc=$?
egresslock --config "$S141/gw.conf" ensure s141p >/dev/null 2>&1; p141_rc=$?
GW_CHAIN="$STATE/nft/egresslock.p_s141a"
PUB_CHAIN="$STATE/nft/egresslock.p_s141p"
mac141="$(printf '%s' 's141a|10.199.81.2' | sha256sum | cut -d' ' -f1)"
mac141="02:${mac141:0:2}:${mac141:2:2}:${mac141:4:2}:${mac141:6:2}:${mac141:8:2}"

# 1. Anti-spoof drop is FIRST in the chain (D2), iifname != shape.
[[ "$(grep -m1 'counter' "$GW_CHAIN" 2>/dev/null)" == 'iifname != "podman1" ip saddr 10.199.81.0/24 counter drop' ]] \
    && a141 pass || a141 fail "anti-spoof drop first in gateway chain (head: $(grep -m1 'counter' "$GW_CHAIN" 2>/dev/null))"
[[ "$(grep -m1 'counter' "$PUB_CHAIN" 2>/dev/null)" == 'iifname != "podman1" ip saddr 10.199.82.0/24 counter drop' ]] \
    && a141 pass || a141 fail "anti-spoof drop first in public-only chain (head: $(grep -m1 'counter' "$PUB_CHAIN" 2>/dev/null))"

# 2. Every saddr-keyed ACCEPT is iifname-scoped (established, DNS, pin,
#    gateway hop, public terminal, exemption); terminal drop unscoped.
grep -q 'ip saddr 10.199.81.0/24 iifname "podman1" ct state established,related counter accept' "$GW_CHAIN" \
    && a141 pass || a141 fail "established/related is iifname-scoped"
grep -q 'ip saddr 10.199.81.0/24 iifname "podman1" ip daddr 10.199.81.1 meta l4proto { tcp, udp } th dport 53 counter accept' "$GW_CHAIN" \
    && a141 pass || a141 fail "DNS-to-bridge is iifname-scoped"
grep -q 'ip saddr 10.199.81.0/24 iifname "podman1" ip daddr 192.0.2.10 tcp dport 2222 counter accept' "$GW_CHAIN" \
    && a141 pass || a141 fail "allow-host pin is iifname-scoped (EGRESSLOCK_MOCK_DNS git.example.test)"
grep -q 'ip saddr 10.199.81.0/24 iifname "podman1" ip daddr 10.199.81.2 tcp dport 3128 counter accept' "$GW_CHAIN" \
    && a141 pass || a141 fail "gateway hop is iifname-scoped"
grep -q 'ip saddr 10.199.81.2 iifname "podman1" ether saddr '"$mac141"' counter accept' "$GW_CHAIN" \
    && a141 pass || a141 fail "exemption is saddr+iifname+MAC (EGL-123-D2 form kept)"
grep -q 'ip saddr 10.199.82.0/24 iifname "podman1" counter accept' "$PUB_CHAIN" \
    && a141 pass || a141 fail "public-only terminal accept is iifname-scoped"
[[ "$(grep -c '^ip saddr 10.199.81.0/24 counter drop' "$GW_CHAIN")" == 1 ]] \
    && a141 pass || a141 fail "terminal drop stays saddr-keyed UNscoped (exactly one unscoped drop)"
[[ "$(grep -cE '^ip saddr 10.199.81.0/24 (ip )?d?addr? ' "$GW_CHAIN")" == 0 ]] \
    && a141 pass || a141 fail "no accept line lost its saddr key (sanity)"
# Exemption immediately before the terminal drop (D1 emit order).
x141a="$(grep -n 'ether saddr '"$mac141" "$GW_CHAIN" | cut -d: -f1 | head -1)"
x141b="$(grep -n '^ip saddr 10.199.81.0/24 counter drop' "$GW_CHAIN" | cut -d: -f1 | head -1)"
[[ -n "$x141a" && -n "$x141b" && "$x141b" -eq "$((x141a + 1))" ]] \
    && a141 pass || a141 fail "exemption immediately before terminal drop ($x141a vs $x141b)"

# 3. Stale-token churn: flip the state-file interface (simulates an
#    out-of-band recreation) -> verify FAILS CLOSED with a named iifname
#    diff; ensure repairs to the new name; R6 warm-ensure (no flip) stays
#    byte-identical and non-disruptive (EGL-114 converged skip intact).
cp "$GW_CHAIN" "$TESTROOT/s141-chain-podman1"      # baseline snapshot (podman1)
egresslock --config "$S141/gw.conf" verify s141a >/dev/null 2>&1; a141 pass || a141 fail "baseline verify s141a"
sed -i 's/^interface=.*/interface=podman3/' "$STATE/networks/egresslock-s141a"
v141_out="$(egresslock --config "$S141/gw.conf" verify s141a 2>&1)"; v141_rc=$?
if [[ "$v141_rc" != 0 && "$v141_out" == *"does not match the expected ruleset"* && "$v141_out" == *'podman3'* ]]; then
    a141 pass
else
    a141 fail "stale bridge name -> verify fail-closed named iifname diff (rc=$v141_rc out: $(printf '%s' "$v141_out" | head -3 | tr '\n' '|'))"
fi
check141_rc=0; egresslock --config "$S141/gw.conf" ensure s141a >/dev/null 2>&1 || check141_rc=$?
[[ "$check141_rc" == 0 ]] && a141 pass || a141 fail "ensure repairs the stale bridge name (rc=$check141_rc)"
grep -q 'iifname "podman3"' "$GW_CHAIN" && a141 pass || a141 fail "repaired chain carries the re-resolved name podman3"
egresslock --config "$S141/gw.conf" verify s141a >/dev/null 2>&1; a141 pass || a141 fail "verify passes after repair"
sed -i 's/^interface=.*/interface=podman1/' "$STATE/networks/egresslock-s141a"
egresslock --config "$S141/gw.conf" ensure s141a >/dev/null 2>&1; a141 pass || a141 fail "ensure after device restore"
cp "$GW_CHAIN" "$TESTROOT/s141-chain-before-r6"    # post-restore snapshot (podman1)
# R6: warm ensure without a name flip is byte-identical (converged skip
# pin lives in the EGL-114 section; here: re-ensure rc 0, same chain).
egresslock --config "$S141/gw.conf" ensure s141a >/dev/null 2>&1; a141 pass || a141 fail "warm ensure after name restore"
cmp -s "$GW_CHAIN" "$TESTROOT/s141-chain-before-r6" \
    && a141 pass || a141 fail "R6 warm ensure byte-identical chain (same name re-resolved)"

# 4. Unconfirmable device: the inspect/cross-check mismatch must fail
#    the emit by rc — no new nft transaction, no changed chain, no
#    empty iifname (EGL-120-D1 pattern; EGL-141-D1 consequence 2).
sed -i 's/^interface=.*/interface=podman42/' "$STATE/networks/egresslock-s141a"
cp "$STATE/nft/last-transaction.nft" "$TESTROOT/s141-tx-before"
f141_out="$(egresslock --config "$S141/gw.conf" ensure s141a 2>&1)"; f141_rc=$?
if [[ "$f141_rc" != 0 && "$f141_out" == *"not confirmed in the rootless netns"* ]]; then
    a141 pass
else
    a141 fail "unconfirmable bridge device fails ensure by rc with named error (rc=$f141_rc out: $(printf '%s' "$f141_out" | tail -2 | tr '\n' '|'))"
fi
cmp -s "$STATE/nft/last-transaction.nft" "$TESTROOT/s141-tx-before" \
    && a141 pass || a141 fail "failed bridge resolution consumed no nft transaction"
cmp -s "$GW_CHAIN" "$TESTROOT/s141-chain-before-r6" \
    && a141 pass || a141 fail "failed bridge resolution left the live chain untouched"
grep -q 'iifname ""' "$GW_CHAIN" 2>/dev/null \
    && a141 fail "empty iifname rendered (never allowed)" || a141 pass
sed -i 's/^interface=.*/interface=podman1/' "$STATE/networks/egresslock-s141a"
egresslock --config "$S141/gw.conf" ensure s141a >/dev/null 2>&1 || a141 fail "ensure heals after device restore"

# 5. Last-transaction pin: the refresh file carries the anti-spoof line
#    (D2 first-position contract at the transaction level).
grep -qE '^[[:space:]]*iifname != "podman1" ip saddr 10.199.81.0/24 counter drop' "$STATE/nft/last-transaction.nft" \
    && a141 pass || a141 fail "last transaction carries the anti-spoof drop first"

egl141_pass=$pass; egl141_fail=$fail

# --- EGL-146: dstdomain -n on EVERY generated ACL (D1/D3) ----------------
# Numeric-host (IP-literal) CONNECTs must fail the name match outright
# (X-6 E8 rDNS adoption closed): both emit sites carry `-n`, and a grep
# belt future-proofs any new dstdomain group.
pass=0; fail=0
a146() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S146="$TESTROOT/s146"; rm -rf "$S146"; mkdir -p "$S146"
cat > "$S146/gw.conf" <<'EOF'
profile s146 10.199.84.0/24
    rule gateway-only
    gateway 10.199.84.2 3128 s146-allowlist
EOF
printf 'example.test\n' > "$S146/s146-allowlist"
egresslock --config "$S146/gw.conf" ensure s146 >/dev/null 2>&1; a146_rc=$?
sq146="$(find "$STATE" -name 'containers-egresslock-gateway-s146.squid-gw.conf' 2>/dev/null | head -1)"
# 1. No-port group carries -n (exact line).
[[ "$a146_rc" == 0 && -n "$sq146" && "$(grep -m1 '^acl agent_allowlist dstdomain' "$sq146")" == 'acl agent_allowlist dstdomain -n "/etc/squid/agent/allowlist.domains"' ]] \
    && a146 pass || a146 fail "no-port group: exact dstdomain -n line (rc=$a146_rc $(grep -m1 'acl agent_allowlist dstdomain' "$sq146" 2>/dev/null))"
# 2. Per-port group carries -n (exact line).
printf 'example.test:8443\n' >> "$S146/s146-allowlist"
egresslock --config "$S146/gw.conf" ensure s146 >/dev/null 2>&1 || a146 fail "re-ensure with per-port entry"
sq146="$(find "$STATE" -name 'containers-egresslock-gateway-s146.squid-gw.conf' 2>/dev/null | head -1)"
[[ -n "$sq146" && "$(grep -m1 '^acl agent_allowlist_p8443 dstdomain' "$sq146")" == 'acl agent_allowlist_p8443 dstdomain -n "/etc/squid/agent/allowlist.p8443"' ]] \
    && a146 pass || a146 fail "per-port group: exact dstdomain -n line ($(grep -m1 'agent_allowlist_p8443' "$sq146" 2>/dev/null))"
# 3. Grep belt: EVERY dstdomain line in the generated conf carries -n
#    (a `dstdomain "` without -n is a named fail — future-proofs a new
#    emit site).
if [[ -n "$sq146" ]] && [[ -z "$(grep 'dstdomain "' "$sq146" | grep -v ' -n ')" ]]; then
    a146 pass
else
    a146 fail "grep belt: dstdomain line without -n in $(basename "$sq146" 2>/dev/null): $(grep 'dstdomain "' "$sq146" 2>/dev/null | grep -v ' -n ' | head -2 | tr '\n' '|')"
fi

egl146_pass=$pass; egl146_fail=$fail

# --- EGL-147: trailing-dot entries are rejected (D1/D2/D3) ----------------
# Reject at allow time (CLI) and fail closed at ensure (file); never
# normalize, never warn. Leading-dot suffixes stay valid; request-side
# trailing dots are gateway-normalized (out of scope here).
pass=0; fail=0
a147() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

S147="$TESTROOT/s147"; rm -rf "$S147"; mkdir -p "$S147"
cat > "$S147/gw.conf" <<'EOF'
profile s147 10.199.86.0/24
    rule gateway-only
    gateway 10.199.86.2 3128 s147-allowlist
EOF
printf 'starter.example.test\n' > "$S147/s147-allowlist"
egresslock --config "$S147/gw.conf" ensure s147 >/dev/null 2>&1; a147_rc=$?
[[ "$a147_rc" == 0 ]] && a147 pass || a147 fail "s147 baseline ensure (rc=$a147_rc)"

# 1. CLI rejects: bare, host:port, leading+trailing, IPv4-shaped-with-dot.
#    rc 2, allowlist unchanged, no ensure/gateway churn, stderr names the
#    shape (`trailing dot` + the entry).
for bad in "example.test." "example.test.:443" ".example.test." "1.2.3.4." "1.2.3.4.:443"; do
    before147="$(md5sum "$S147/s147-allowlist" | cut -d' ' -f1)"
    : > "$STATE/opslog"
    o147="$(egresslock --config "$S147/gw.conf" allow s147 "$bad" 2>&1)"; r147=$?
    after147="$(md5sum "$S147/s147-allowlist" | cut -d' ' -f1)"
    if [[ "$r147" == 2 && "$before147" == "$after147" && "$o147" == *"trailing dot"* && "$o147" == *"$bad"* && ! -s "$STATE/opslog" ]]; then
        a147 pass
    else
        a147 fail "CLI trailing-dot reject '$bad' (rc=$r147 same=$([[ "$before147" == "$after147" ]] && echo y || echo n) ops=$(wc -c < "$STATE/opslog")B out: $(printf '%s' "$o147" | tail -1))"
    fi
done

# 2. File-path reject: a hand-edited dead line fails ensure CLOSED (and
#    a host:port one likewise) with the same sentence.
printf 'handedit.example.test\nexample.test.\n' > "$S147/s147-allowlist"
o147="$(egresslock --config "$S147/gw.conf" ensure s147 2>&1)"; r147=$?
if [[ "$r147" != 0 && "$o147" == *"trailing dot"* && "$o147" == *"example.test."* ]]; then
    a147 pass
else
    a147 fail "file-path trailing-dot reject fails ensure closed (rc=$r147 out: $(printf '%s' "$o147" | tail -1))"
fi
printf 'handedit.example.test\nexample.test.:8443\n' > "$S147/s147-allowlist"
o147="$(egresslock --config "$S147/gw.conf" ensure s147 2>&1)"; r147=$?
if [[ "$r147" != 0 && "$o147" == *"trailing dot"* ]]; then
    a147 pass
else
    a147 fail "file-path host:port trailing-dot reject fails ensure closed (rc=$r147 out: $(printf '%s' "$o147" | tail -1))"
fi

# 3. Generated-config non-leak: the failed ensure must not have deployed
#    the dead line — no allowlist.* staged under $STATE carries it (if
#    ensure dies before generate, absence IS the pass).
if [[ -z "$(grep -rl -- 'example.test\.' "$STATE" 2>/dev/null | grep -E 'allowlist\.|squid-gw\.conf' | head -1)" ]]; then
    a147 pass
else
    a147 fail "generated-config non-leak: a staged file carries the trailing-dot token ($(grep -rl -- 'example.test\.' "$STATE" 2>/dev/null | grep -E 'allowlist\.|squid-gw\.conf' | head -1))"
fi

# 4. Positive controls: bare names, leading-dot suffixes, port forms —
#    all still accepted; a mid-name empty label is still the DNS-length
#    reject (NOT the trailing-dot shape).
printf 'starter.example.test\n' > "$S147/s147-allowlist"
before147="$(md5sum "$S147/s147-allowlist" | cut -d' ' -f1)"
egresslock --config "$S147/gw.conf" allow s147 example.test >/dev/null 2>&1; r147=$?
grep -q '^example.test$' "$S147/s147-allowlist" && [[ "$r147" == 0 ]] \
    && a147 pass || a147 fail "positive control: allow example.test still rc 0 (rc=$r147)"
egresslock --config "$S147/gw.conf" allow s147 .example.test >/dev/null 2>&1; r147=$?
grep -q '^\.example\.test$' "$S147/s147-allowlist" && [[ "$r147" == 0 ]] \
    && a147 pass || a147 fail "positive control: allow .example.test (leading-dot suffix) still rc 0 (rc=$r147)"
o147="$(egresslock --config "$S147/gw.conf" allow s147 a..b 2>&1)"; r147=$?
if [[ "$r147" == 2 && "$o147" == *"DNS length limits"* && "$o147" != *"trailing dot"* ]]; then
    a147 pass
else
    a147 fail "a..b still named by the DNS-length gate, not trailing-dot (rc=$r147 out: $(printf '%s' "$o147" | tail -1))"
fi
# denied emit filter: a trailing-dot name candidate is a silent skip
# (inherited via allow_entry_ok), rc 0, nothing emitted; the valid name
# in the same log still emits.
: > "$STATE/running/egresslock-gateway-s147"
cat > "$STATE/containers-egresslock-gateway-s147.access.log" <<EOF
$(date +%s).000    120 10.199.86.5 TCP_DENIED/403 0 CONNECT example.test.:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.86.5 TCP_DENIED/403 0 CONNECT blocked.example.test:443 - HIER_NONE/- -
EOF
o147="$(egresslock --config "$S147/gw.conf" denied s147 --all 2>/dev/null)"; r147=$?
if [[ "$r147" == 0 && "$o147" == *"blocked.example.test"* && "$o147" != *"example.test.:443"* ]]; then
    a147 pass
else
    a147 fail "denied silently skips the trailing-dot candidate (rc=$r147 out: $o147)"
fi

# 5. allow-host / conf: the CLI and the parser name the same shape.
o147="$(egresslock --config "$S147/gw.conf" allow-host s147 example.test.:443 2>&1)"; r147=$?
if [[ "$r147" == 2 && "$o147" == *"trailing dot"* ]]; then
    a147 pass
else
    a147 fail "allow-host trailing-dot reject (rc=$r147 out: $(printf '%s' "$o147" | tail -1))"
fi
grep -q 'rule allow-host' "$S147/gw.conf" \
    && a147 fail "rejected allow-host must not have written the conf" || a147 pass
printf 'profile s147b 10.199.87.0/24\n    rule allow-host example.test.:443\n' > "$S147/b.conf"
o147="$(egresslock --config "$S147/b.conf" list 2>&1)"; r147=$?
if [[ "$r147" == 2 && "$o147" == *"trailing dot"* && "$o147" == *"b.conf:"* ]]; then
    a147 pass
else
    a147 fail "conf parser trailing-dot reject for allow-host (rc=$r147 out: $(printf '%s' "$o147" | tail -1))"
fi
printf 'profile s147c 10.199.88.0/24\n    no-proxy example.test.,other.example.test\n' > "$S147/c.conf"
o147="$(egresslock --config "$S147/c.conf" list 2>&1)"; r147=$?
if [[ "$r147" == 2 && "$o147" == *"trailing dot"* ]]; then
    a147 pass
else
    a147 fail "conf parser trailing-dot reject for no-proxy (rc=$r147 out: $(printf '%s' "$o147" | tail -1))"
fi

egl147_pass=$pass; egl147_fail=$fail

# --- EGL-139/EGL-140: revocation flush + tampered-pin verify detection ----
# EGL-139-D2: disallow-host runs a fail-closed conntrack probe BEFORE the
# conf mutation, captures the revoked pin's live daddr from the chain,
# and after the atomic re-ensure swap deletes + post-asserts the
# revoked tuple's conntrack state (zero-dep procfs reader); the
# `removed:` success line prints only after the post-condition holds.
# EGL-140-D1: ensure writes a confdir pin record (<profile>.pins, never
# matching the *.conf aggregate glob) from WHAT WAS JUST INSTALLED, and
# verify compares each live daddr against it — chain-vs-record
# divergence (tamper/torn record) fails closed named, while
# record-vs-resolver movement stays the warn-only drift channel (D2).
pass=0; fail=0
a139() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

EH="$TESTROOT/h139140"; rm -rf "$EH"; mkdir -p "$EH"
cat > "$EH/direct.conf" <<'EOF'
profile two 10.199.60.0/24
    rule allow-host git.example.test:2222
    rule allow-host cache.example.test:8080
profile plain 10.199.61.0/24
    rule public-only
EOF
export EGRESSLOCK_CONF="$EH/direct.conf"
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure two >/dev/null 2>&1
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure plain >/dev/null 2>&1

# 1. ensure writes the pin record beside the conf, conf order, from the
#    installed chain; no staging temp left behind; .pins never matches
#    the *.conf aggregate glob (list stays one-profile-per-conf).
[[ -f "$EH/two.pins" ]] \
    && a139 pass || a139 fail "ensure wrote the pin record (two.pins missing)"
r140="$(cat "$EH/two.pins")"
if [[ "$r140" == $'git.example.test|2222 192.0.2.10\ncache.example.test|8080 192.0.2.11' ]]; then
    a139 pass
else
    a139 fail "pin record content (got: $(echo "$r140" | tr '\n' '|'))"
fi
[[ -z "$(ls "$EH"/two.pins.* 2>/dev/null)" ]] \
    && a139 pass || a139 fail "pin record write left staging temp files"
list_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock list 2>/dev/null)"
if [[ "$list_out" == *"two"* && "$list_out" == *"plain"* && "$list_out" != *".pins"* ]]; then
    a139 pass
else
    a139 fail "aggregate/list must not treat .pins as a conf (out: $list_out)"
fi
# 2. zero-allow-host profile: NO record, verify silent-green.
[[ ! -e "$EH/plain.pins" ]] \
    && a139 pass || a139 fail "zero-allow-host profile must have no pin record"
v_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify plain 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" != *"pin record"* && "$v_out" != *"drift:"* ]]; then
    a139 pass
else
    a139 fail "zero-allow-host verify silent (rc=$v_rc, out: $v_out)"
fi
# 3. tampered chain daddr (port and position preserved) -> verify rc 1
#    with the NAMED pin-divergence error; the record pins the truth.
sed -i 's/ip daddr 192.0.2.10 tcp dport 2222/ip daddr 192.0.2.77 tcp dport 2222/' \
    "$STATE/nft/egresslock.p_two"
v_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify two 2>&1)"; v_rc=$?
if [[ "$v_rc" == 1 && "$v_out" == *"verify: allow-host pin daddr mismatch for git.example.test:2222 (record: 192.0.2.10, chain: 192.0.2.77) — re-run: egresslock ensure two"* ]]; then
    a139 pass
else
    a139 fail "tampered chain daddr -> named pin-divergence rc 1 (rc=$v_rc, out: $v_out)"
fi
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure two >/dev/null 2>&1
# 4. missing record (the 0.4.x upgrade shape) -> fail closed named
#    re-ensure; NEVER a live-chain adoption.
mv "$EH/two.pins" "$EH/two.pins.bak"
v_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify two 2>&1)"; v_rc=$?
if [[ "$v_rc" == 1 && "$v_out" == *"verify: pin record missing for profile 'two' — re-run: egresslock ensure two"* ]]; then
    a139 pass
else
    a139 fail "missing record -> named re-ensure failure (rc=$v_rc, out: $v_out)"
fi
mv "$EH/two.pins.bak" "$EH/two.pins"
# 5. corrupt record line -> same fail-closed class, named.
printf 'git.example.test|2222 not-an-ip\n' > "$EH/two.pins"
v_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify two 2>&1)"; v_rc=$?
if [[ "$v_rc" == 1 && "$v_out" == *"pin record corrupt for profile 'two'"* ]]; then
    a139 pass
else
    a139 fail "corrupt record -> named fail-closed (rc=$v_rc, out: $v_out)"
fi
# 6. record with a STALE extra entry (not a conf pin) -> corrupt, named.
printf 'git.example.test|2222 192.0.2.10\ncache.example.test|8080 192.0.2.11\nghost.example.test|9 192.0.2.99\n' > "$EH/two.pins"
v_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify two 2>&1)"; v_rc=$?
if [[ "$v_rc" == 1 && "$v_out" == *"pin record corrupt for profile 'two'"* ]]; then
    a139 pass
else
    a139 fail "stale extra record entry -> named fail-closed (rc=$v_rc, out: $v_out)"
fi
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure two >/dev/null 2>&1
# 7. ensure heals by re-writing the record (drift knob): chain, record,
#    and verify converge on the new address; the record-vs-resolver
#    channel then warns against the RECORD's pinned value (rc stays 0).
export EGRESSLOCK_MOCK_DNS="git.example.test=192.0.2.99"
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure two >/dev/null 2>&1
r140="$(cat "$EH/two.pins")"
[[ "$r140" == $'git.example.test|2222 192.0.2.99\ncache.example.test|8080 192.0.2.11' ]] \
    && a139 pass || a139 fail "ensure rewrote the record from the fresh resolve (got: $(echo "$r140" | tr '\n' '|'))"
unset EGRESSLOCK_MOCK_DNS
v_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify two 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" == *"drift: host git.example.test resolved to 192.0.2.10 but the policy pins 192.0.2.99"* ]]; then
    a139 pass
else
    a139 fail "record-vs-resolver movement is the warn channel, rc 0 (rc=$v_rc, out: $v_out)"
fi
# 8. the drift warn never mutated the policy (record untouched).
grep -q 'git.example.test|2222 192.0.2.99' "$EH/two.pins" \
    && a139 pass || a139 fail "drift check must not rewrite the pin record"
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure two >/dev/null 2>&1
v_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify two 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" != *"drift:"* ]]; then
    a139 pass
else
    a139 fail "verify silent after record-backed re-ensure (rc=$v_rc, out: $v_out)"
fi

# EGL-139-D2: the disallow-host flush battery. The mock conntrack's
# table models the account netns; conntrack.log records each argv.
CTLOG="$ARCMOCK_STATE/conntrack.log"
CTTABLE="$STATE/nft/conntrack-table"
: > "$CTLOG"; : > "$CTTABLE"

# 9. scoped flush with the captured tuple: probe (-C), scoped -D keyed
#    on the LIVE chain's daddr+dport, entry deleted, `removed:` AFTER
#    the post-assert, rc 0.
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.60.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431997 ESTABLISHED src=10.199.60.7 dst=192.0.2.11 sport=40001 dport=8080 src=192.0.2.11 dst=10.0.2.15 sport=8080 dport=40001 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$d_out" == *"removed: rule allow-host git.example.test:2222"* ]]; then
    a139 pass
else
    a139 fail "disallow-host success after flush (rc=$d_rc, out: $d_out)"
fi
grep -qxF 'conntrack -C' "$CTLOG" \
    && a139 pass || a139 fail "fail-closed probe ran in-netns (-C in conntrack log)"
grep -qxF 'conntrack -D -p tcp --dport 2222 -d 192.0.2.10' "$CTLOG" \
    && a139 pass || a139 fail "scoped -D invoked with the captured daddr+dport (log: $(tr '\n' '|' < "$CTLOG"))"
if grep -qF 'dst=192.0.2.11 ' "$CTTABLE" && ! grep -qF 'dst=192.0.2.10 ' "$CTTABLE"; then
    a139 pass
else
    a139 fail "scoped delete: revoked tuple gone, sibling pin's entry untouched (table: $(tr '\n' '|' < "$CTTABLE"))"
fi
! grep -q 'rule allow-host git.example.test:2222' "$EH/direct.conf" \
    && a139 pass || a139 fail "conf line removed"
# 10. the remaining record covers the surviving pin; verify green.
[[ "$(cat "$EH/two.pins")" == 'cache.example.test|8080 192.0.2.11' ]] \
    && a139 pass || a139 fail "record rewritten after revocation (got: $(cat "$EH/two.pins"))"
v_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify two 2>&1)"; v_rc=$?
[[ "$v_rc" == 0 ]] \
    && a139 pass || a139 fail "verify green after revocation (rc=$v_rc, out: $v_out)"

# 11. absent tool: fail-closed BEFORE the conf mutation — named error,
#     conf unchanged, no `removed:` line, no ensure consumed. Absence
#     is forced via CONNTRACK_BIN (the engine's first resolution
#     branch), NOT by renaming the mock away: conntrack is a required
#     dependency on provisioned hosts (v0.5.0), so PATH-state tricks
#     are non-hermetic (EGL-135 hygiene bucket, 2026-09-25).
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
tx_before="$(grep -c . "$ARCMOCK_STATE/callorder.log" 2>/dev/null || echo 0)"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 CONNTRACK_BIN=/nonexistent/conntrack egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
tx_after="$(grep -c . "$ARCMOCK_STATE/callorder.log" 2>/dev/null || echo 0)"
if [[ "$d_rc" == 1 && "$d_out" == *"is not executable"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -q 'rule allow-host git.example.test:2222' "$EH/direct.conf" \
   && [[ "$tx_before" == "$tx_after" ]]; then
    a139 pass
else
    a139 fail "absent conntrack tool aborts before mutation (rc=$d_rc, tx=$tx_before->$tx_after, out: $(echo "$d_out" | head -3 | tr '\n' '|'))"
fi

# 12. ctnetlink unavailable (probe marker): same fail-closed-before-
#     mutation shape as a missing binary.
touch "$ARCMOCK_STATE/nft/conntrack-probe-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-probe-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"conntrack probe failed"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -q 'rule allow-host git.example.test:2222' "$EH/direct.conf"; then
    a139 pass
else
    a139 fail "denied ctnetlink aborts at the probe (rc=$d_rc, out: $(echo "$d_out" | head -2 | tr '\n' '|'))"
fi

# 13. surviving ESTABLISHED entry after the swap -> die loudly with the
#     state disclosed, NEVER a green rc with the revoked flow alive
#     (the error-loudly-lie shape); `removed:` stays unprinted.
: > "$CTLOG"
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.60.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
touch "$ARCMOCK_STATE/nft/conntrack-delete-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-delete-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"still has an ESTABLISHED conntrack entry"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && ! grep -q 'rule allow-host git.example.test:2222' "$EH/direct.conf"; then
    a139 pass
else
    a139 fail "surviving ESTABLISHED entry dies loudly (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi

# 14. SYN_SENT-class transients are ignored (late in-flight packets may
#     mint them; every subsequent packet drops): rc 0, success line.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 119 SYN_SENT src=10.199.60.9 dst=192.0.2.10 sport=58670 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58670 mark=0 zone=0 use=1\n' > "$CTTABLE"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]]; then
    a139 pass
else
    a139 fail "SYN_SENT transient ignored, rc 0 (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi
: > "$CTTABLE"
# 15. CONNTRACK_BIN env guards mirror ARC-59 (leading-dash / non-exec).
d_out="$(CONNTRACK_BIN=-x env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two cache.example.test:8080 2>&1)"; d_rc=$?
[[ "$d_rc" == 1 && "$d_out" == *"must not start with '-'"* ]] \
    && a139 pass || a139 fail "CONNTRACK_BIN leading-dash guard (rc=$d_rc, out: $(echo "$d_out" | head -2 | tr '\n' '|'))"

egl139_pass=$pass; egl139_fail=$fail
egl140_pass=$egl139_pass; egl140_fail=$egl139_fail

echo "RESULTS (engine config validation): $extra_pass passed, $extra_fail failed"
echo "RESULTS (ARC-11 subnet hygiene): $arc11_pass passed, $arc11_fail failed"
echo "RESULTS (ARC-12 DNS drift): $arc12_pass passed, $arc12_fail failed"
echo "RESULTS (ARC-14 site defaults): $arc14_pass passed, $arc14_fail failed"
echo "RESULTS (ARC-16 kit surface): $arc16_pass passed, $arc16_fail failed"
echo "RESULTS (ARC-20 config required): $arc20_pass passed, $arc20_fail failed"
echo "RESULTS (ARC-25 root guard): $arc25_pass passed, $arc25_fail failed"
echo "RESULTS (ARC-26 netns probe): $arc26_pass passed, $arc26_fail failed"
echo "RESULTS (ARC-49 nft-temp): $arc49_pass passed, $arc49_fail failed"
echo "RESULTS (ARC-24 default probe): $arc24_pass passed, $arc24_fail failed"
echo "RESULTS (ARC-35 init): $arc35_pass passed, $arc35_fail failed"
echo "RESULTS (ARC-30 disallow): $arc30_pass passed, $arc30_fail failed"
echo "RESULTS (ARC-46 allow/disallow batch): $arc46_pass passed, $arc46_fail failed"
echo "RESULTS (BUG-002 no-trailing-newline allow): $arc_b2_pass passed, $arc_b2_fail failed"
echo "RESULTS (ARC-37 conf discovery): $arc37_pass passed, $arc37_fail failed"
echo "RESULTS (ARC-38 allow-host): $arc38_pass passed, $arc38_fail failed"
echo "RESULTS (ARC-31 denied filter): $arc31_pass passed, $arc31_fail failed"
echo "RESULTS (ARC-41 denied HTTP-origin): $arc41_pass passed, $arc41_fail failed"
echo "RESULTS (ARC-42 denied window): $arc42_pass passed, $arc42_fail failed"
echo "RESULTS (ARC-43 allowlist): $arc43_pass passed, $arc43_fail failed"
echo "RESULTS (ARC-44 proxy-env tokens): $arc44_pass passed, $arc44_fail failed"
echo "RESULTS (ARC-50 sinks): $arc50_pass passed, $arc50_fail failed"
echo "RESULTS (ARC-56 GW_DNS): $arc56_pass passed, $arc56_fail failed"
echo "RESULTS (ARC-58 path): $arc58_pass passed, $arc58_fail failed"
echo "RESULTS (ARC-51 allowlist literals): $arc51_pass passed, $arc51_fail failed"
echo "RESULTS (ARC-59 leading-dash): $arc59_pass passed, $arc59_fail failed"
echo "RESULTS (ARC-57 denied emit filter): $arc57_pass passed, $arc57_fail failed"
echo "RESULTS (EGL-18 IP destinations): $egl18_pass passed, $egl18_fail failed"
echo "RESULTS (ARC-54 legacy table): $arc54_pass passed, $arc54_fail failed"
echo "RESULTS (ARC-60 runtime sweep + cutover probe): $arc60_pass passed, $arc60_fail failed"
echo "RESULTS (ARC-32 pre-OSS hardening): $arc32_pass passed, $arc32_fail failed"
echo "RESULTS (ARC-66 runtime table sweep): $arc66_pass passed, $arc66_fail failed"
echo "RESULTS (ARC-67 network ls): $arc67_pass passed, $arc67_fail failed"
echo "RESULTS (ARC-71 probe dispatch): $arc71_pass passed, $arc71_fail failed"
echo "RESULTS (ARC-69 output honesty): $arc69_pass passed, $arc69_fail failed"
echo "RESULTS (EGL-31 output hygiene): $egl31_pass passed, $egl31_fail failed"
echo "RESULTS (EGL-45 doctor): $egl45_pass passed, $egl45_fail failed"
echo "RESULTS (EGL-59 help operator-UI): $egl59_pass passed, $egl59_fail failed"
echo "RESULTS (ARC-74 deep state semantics, synthetic): $deep_pass passed, $deep_fail failed"
echo "RESULTS (EGL-55 verify missing-network hint): $egl55_pass passed, $egl55_fail failed"
echo "RESULTS (EGL-66 anchor hardening + digest pin): $egl66_pass passed, $egl66_fail failed"
echo "RESULTS (EGL-117 resolution disclosure): $egl117_pass passed, $egl117_fail failed"
echo "RESULTS (EGL-114 converged-ensure gate): $egl114_pass passed, $egl114_fail failed"
echo "RESULTS (EGL-116 read-timeout knob): $egl116_pass passed, $egl116_fail failed"
echo "RESULTS (EGL-120 resolve error-path shape): $egl120_pass passed, $egl120_fail failed"
echo "RESULTS (EGL-141 bridge-scoped accepts): $egl141_pass passed, $egl141_fail failed"
echo "RESULTS (EGL-146 dstdomain -n): $egl146_pass passed, $egl146_fail failed"
echo "RESULTS (EGL-147 trailing-dot reject): $egl147_pass passed, $egl147_fail failed"
echo "RESULTS (EGL-139 conntrack revocation flush): $egl139_pass passed, $egl139_fail failed"
echo "RESULTS (EGL-140 pin record witness): $egl140_pass passed, $egl140_fail failed"
total_fail=$((extra_fail + arc11_fail + arc12_fail + arc14_fail + arc16_fail + arc20_fail + arc25_fail + arc26_fail + arc49_fail + arc91_fail + arc24_fail + arc35_fail + arc30_fail + arc46_fail + arc_b2_fail + arc37_fail + arc38_fail + arc31_fail + arc41_fail + arc42_fail + arc43_fail + arc44_fail + arc50_fail + arc56_fail + arc58_fail + arc51_fail + arc59_fail + arc57_fail + egl18_fail + egl45_fail + arc54_fail + arc52_fail + arc60_fail + arc32_fail + arc66_fail + arc67_fail + arc71_fail + arc69_fail + egl31_fail + deep_fail + egl55_fail + egl59_fail + egl66_fail + egl117_fail + egl114_fail + egl116_fail + egl120_fail + egl141_fail + egl146_fail + egl147_fail + egl139_fail))
# EGL-99: TOTAL line gains the skip count (0 here — the engine harness
# has no gated asserts) and the tree-shape tag, matching test-kit.sh.
echo "RESULTS TOTAL: $((extra_pass + arc11_pass + arc12_pass + arc14_pass + arc16_pass + arc20_pass + arc25_pass + arc26_pass + arc49_pass + arc91_pass + arc24_pass + arc35_pass + arc30_pass + arc46_pass + arc_b2_pass + arc37_pass + arc38_pass + arc31_pass + arc41_pass + arc42_pass + arc43_pass + arc44_pass + arc50_pass + arc56_pass + arc58_pass + arc51_pass + arc59_pass + arc57_pass + egl18_pass + arc54_pass + arc52_pass + arc60_pass + arc32_pass + arc66_pass + arc67_pass + arc71_pass + arc69_pass + egl31_pass + egl45_pass + egl59_pass + deep_pass + egl55_pass + egl66_pass + egl117_pass + egl114_pass + egl116_pass + egl120_pass + egl141_pass + egl146_pass + egl147_pass + egl139_pass)) passed, $total_fail failed$(skip_summary) ($(tree_shape_tag))"
[[ "$total_fail" -eq 0 ]]
