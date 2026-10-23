#!/usr/bin/env bash
#
# Engine-only tests (ARC-15): config validation, config-only profiles,
# subnet hygiene (ARC-11), DNS drift (ARC-12), site-default hygiene
# (ARC-14), and state semantics (tamper/re-ensure, v6deny, gateway death/
# recovery, rule order — ARC-74 relocation). Fixtures are synthetic
# (example.test hosts, docs-range IPs) so this tree relocates to the
# public repo (ARC-13-D5); consumer harnesses stay with their consumers
# (repository AGENTS.md Testing).
#
# Run:  bash tests/run.sh   (or this file directly)


export ARCMOCK_DNS_BASE="git.example.test=192.0.2.10,gitXexample.test=192.0.2.12,cache.example.test=192.0.2.11"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
export PATH="$TESTROOT/bin:$TREE_ROOT:$PATH"

# --- EGL-184-D4: fail-closed negative controls (subshell-isolated) ---------
# The bookkeeping library must refuse a TOTAL when the section register is
# inconsistent: open section, never-begun op, double begin, stray increment,
# or grand/booked drift. Each control runs one refusal in a subshell and
# asserts a nonzero exit with a named FAIL. On success it prints nothing,
# opens no parent section, and moves no TOTAL (EGL-184-D3).
_ectl_bad=0
_ectl() { # _ectl <fn> — run control <fn> in a subshell; expect a named refusal
    local out="" rc=0
    out="$("$1" 2>&1)" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        echo "FAIL (EGL-184 control): $1 did not fail closed"; _ectl_bad=1
    elif [[ "$out" != *"FAIL"* ]]; then
        echo "FAIL (EGL-184 control): $1 refused without a named message (rc=$rc, out: $out)"; _ectl_bad=1
    fi
}
_ectl_dangling()     { section_begin ectl_a "control: dangling"; results_total; }
_ectl_end_unbegun()  { section_end ectl_ghost; }
_ectl_emit_unended() { section_begin ectl_b "control: emit-unended"; results_emit ectl_b; }
_ectl_double()       { section_begin ectl_c "control: double"; section_begin ectl_c "control: double"; }
_ectl_stray()        { assert pass; results_total; }
_ectl_drift()        { section_begin ectl_d "control: drift"; pass=$((pass+1)); section_end ectl_d; results_total; }
_ectl _ectl_dangling
_ectl _ectl_end_unbegun
_ectl _ectl_emit_unended
_ectl _ectl_double
_ectl _ectl_stray
_ectl _ectl_drift
unset -f _ectl _ectl_dangling _ectl_end_unbegun _ectl_emit_unended _ectl_double _ectl_stray _ectl_drift
if [[ "$_ectl_bad" -ne 0 ]]; then exit 1; fi
unset _ectl_bad

# Run a command with stdout on a PTY (script(1)). EGL-117-D1 lifted the
# probe-hint TTY gate (ARC-45), so the PTY is only a helper for future
# TTY-shaped asserts. EGL-78-1-F1: stdin is cut off (</dev/null); with a
# live TTY stdin, script's relay has no EOF and can wedge after the child
# exits. The child still gets a PTY on both fds.
pty() { script -qec "$1" /dev/null </dev/null; }

section_begin extra "engine config validation"

# --- config validation (ARC-8 engine-specific, synthetic fixtures) -------
# EGL-325: the confdir is fixed (<passwd-home>/.config/egresslock); the
# old --config / EGRESSLOCK_CONF selectors are gone. Validation errors
# still exit 2.


mkdir -p "$TESTROOT/validconf"
printf 'profile v 10.50.9.0/24\n' > "$TESTROOT/validconf/v.conf"
check "fixed confdir list works" 0 env ARCMOCK_PASSWD_HOME="$(conf_home_ro "$TESTROOT/validconf/v.conf")" \
    egresslock list

# EGL-325: both removed selectors are rejected/ignored, never used.
sel_out="$(egresslock --config "$TESTROOT/validconf/v.conf" list 2>&1)"; sel_rc=$?
if [[ "$sel_rc" == 2 && "$sel_out" == *"--config has been removed"* \
      && "$sel_out" == *"<account-home>/.config/egresslock/<profile>.conf"* ]]; then
    _sect_bump pass; echo "PASS: --config is rejected (removed selector)"
else
    _sect_bump fail; echo "FAIL: --config rejection (rc=$sel_rc, out: $sel_out)"
fi
sel_out="$(egresslock --config="$TESTROOT/validconf/v.conf" list 2>&1)"; sel_rc=$?
if [[ "$sel_rc" == 2 && "$sel_out" == *"--config has been removed"* ]]; then
    _sect_bump pass; echo "PASS: --config=<file> is rejected (removed selector)"
else
    _sect_bump fail; echo "FAIL: --config= rejection (rc=$sel_rc, out: $sel_out)"
fi
# EGL-325 A5: stale scripts may carry the removed selector after the
# command/profile. Every position is a usage error, never a silent
# ignored argument.
for _sel_argv in \
    "list --config $TESTROOT/validconf/v.conf" \
    "list --config=$TESTROOT/validconf/v.conf" \
    "verify v --config $TESTROOT/validconf/v.conf" \
    "teardown all --config $TESTROOT/validconf/v.conf"
do
    # shellcheck disable=SC2086  # deliberate word split of the argv case
    sel_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/validconf/v.conf")" egresslock $_sel_argv 2>&1)"; sel_rc=$?
    if [[ "$sel_rc" == 2 && "$sel_out" == *"--config has been removed"* ]]; then
        _sect_bump pass; echo "PASS: trailing removed selector rejected ($_sel_argv)"
    else
        _sect_bump fail; echo "FAIL: trailing removed selector ($_sel_argv) rc=$sel_rc out=$sel_out"
    fi
done
# EGL-325 n4: a traversal-shaped profile token is rejected before the
# confdir join, so it cannot disclose a readable conf outside the confdir.
sel_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/validconf/v.conf")" egresslock network ../elsewhere/secret 2>&1)"; sel_rc=$?
if [[ "$sel_rc" == 2 && "$sel_out" == *"invalid profile name '../elsewhere/secret'"* \
      && "$sel_out" != *"using config"* ]]; then
    _sect_bump pass; echo "PASS: traversal profile token refused before resolution"
else
    _sect_bump fail; echo "FAIL: traversal profile token (rc=$sel_rc, out: $sel_out)"
fi
# EGRESSLOCK_CONF is silently ignored: a valid conf named by the variable
# does NOT make an otherwise-empty default confdir resolve.
sel_out="$(env EGRESSLOCK_CONF="$TESTROOT/validconf/v.conf" egresslock list 2>&1)"; sel_rc=$?
if [[ "$sel_rc" == 2 && "$sel_out" == *"no profile config"* ]]; then
    _sect_bump pass; echo "PASS: EGRESSLOCK_CONF is ignored (no selector)"
else
    _sect_bump fail; echo "FAIL: EGRESSLOCK_CONF ignored (rc=$sel_rc, out: $sel_out)"
fi

# Every config-validation failure must exit 2 with a useful message.
bad_config() { # bad_config <name> <content> <expected-message-substring>
    local dir="$TESTROOT/badconf"
    mkdir -p "$dir"
    printf '%s\n' "$2" > "$dir/$1.conf"
    local out rc=0 chome cfname
    chome="$(conf_home_ro "$dir/$1.conf")"
    cfname="$(basename "$(ls "$chome/.config/egresslock/"*.conf | head -1)")"
    out="$(ARCMOCK_PASSWD_HOME="$chome" egresslock list 2>&1)" || rc=$?
    if [[ "$rc" == 2 && "$out" == *"$cfname:"* && "$out" == *"$3"* ]]; then
        _sect_bump pass; echo "PASS: bad config rejected: $1"
    else
        _sect_bump fail; echo "FAIL: bad config '$1' (rc=$rc, msg: $out)"
    fi
}

# EGL-323: one profile block per conf file — all four former multi-block
# shapes now fail at the second `profile` line (exit 2), citing the
# already-defined profile and its opening line.
bad_config dup-name \
    $'profile a 10.50.0.0/24\nprofile a 10.50.1.0/24' \
    "one profile per conf file: 'a' is already defined at line 1"
bad_config subnet-overlap \
    $'profile a 10.50.0.0/24\nprofile b 10.50.0.0/24' \
    "one profile per conf file: 'a' is already defined at line 1"
bad_config subnet-overlap-nested \
    $'profile a 10.50.0.0/16\nprofile b 10.50.1.0/24' \
    "one profile per conf file: 'a' is already defined at line 1"
bad_config subnet-overlap-nested-rev \
    $'profile a 10.50.0.0/24\nprofile b 10.50.0.0/16' \
    "one profile per conf file: 'a' is already defined at line 1"

# EGL-323: aggregate leg — a two-block file anywhere in the confdir
# aborts the sweep fail-closed (no partial list rows).
A323="$TESTROOT/one-profile"
rm -rf "$A323"; mkdir -p "$A323/.config/egresslock"
printf 'profile ok 10.51.0.0/24\n' > "$A323/.config/egresslock/ok.conf"
printf 'profile main 10.51.1.0/24\nprofile dev 10.51.2.0/24\n' \
    > "$A323/.config/egresslock/main.conf"
agg323_out="$(env HOME="$A323" ARCMOCK_PASSWD_HOME="$A323" egresslock list 2>$TESTROOT/e323agg.err)"; agg323_rc=$?
if [[ "$agg323_rc" == 2 && -z "$agg323_out" \
      && "$(cat $TESTROOT/e323agg.err)" == *"using configs in"*"$A323/.config/egresslock"* \
      && "$(cat $TESTROOT/e323agg.err)" == *"one profile per conf file: 'main' is already defined at line 1"* ]]; then
    _sect_bump pass; echo "PASS: aggregate list fails closed on a two-block conf"
else
    _sect_bump fail; echo "FAIL: aggregate list two-block (rc=$agg323_rc, out: $agg323_out, err: $(cat $TESTROOT/e323agg.err))"
fi
# EGL-323: named-probe leg — `ensure <p>` fails closed on the same file,
# resolution line first, exit 2 before any policy action.
np323_out="$(env HOME="$A323" ARCMOCK_PASSWD_HOME="$A323" egresslock ensure main 2>&1)"; np323_rc=$?
if [[ "$np323_rc" == 2 \
      && "$np323_out" == *"using config"*"$A323/.config/egresslock/main.conf"* \
      && "$np323_out" == *"one profile per conf file: 'main' is already defined at line 1"* \
      && "$np323_out" == *"offending line: profile dev 10.51.2.0/24"* ]]; then
    _sect_bump pass; echo "PASS: named-probe ensure fails closed on a two-block conf"
else
    _sect_bump fail; echo "FAIL: named-probe ensure two-block (rc=$np323_rc, out: $np323_out)"
fi
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
printf 'profile a 10.50.0.0/24\n' > "$TESTROOT/badconf/a.conf"
check "missing creds directive is now OK" 0 \
    env ARCMOCK_PASSWD_HOME="$(conf_home_ro "$TESTROOT/badconf/a.conf")" egresslock list
bad_config gw-only-no-gw \
    $'profile a 10.50.0.0/24\n    rule gateway-only' \
    "no 'gateway' directive"
bad_config leftover-public-only \
    $'profile a 10.50.0.0/24\n    rule public-only' \
    "unknown rule kind 'public-only'"
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
npc() { env ARCMOCK_PASSWD_HOME="$(conf_home "$NPDIR/ci.conf")" egresslock "$@"; }
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

section_end extra


# --- ARC-11: subnet hygiene ----------------------------------------------
section_begin arc11 "ARC-11 subnet hygiene"
A11="$TESTROOT/arc11"
mkdir -p "$A11"
a11() { env ARCMOCK_PASSWD_HOME="$(conf_home "$A11/$1")" egresslock "${@:2}"; }

# 1. Podman overlap pre-check: a colliding network (even a foreign one)
#    fails ensure with remediation, not the raw create error.
: > "$A11/allow"
cat > "$A11/ov.conf" <<'EOF'
profile ov 10.77.0.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
EOF
mkdir -p "$STATE/networks"
printf 'driver=bridge\nsubnet=10.77.0.0/24\ngateway=10.77.0.1\nipv6_enabled=false\n' > "$STATE/networks/someone-elses-net"
ov_out="$(a11 overlap.conf ensure ov 2>&1)"; ov_rc=$?
if [[ "$ov_rc" == 1 && "$ov_out" == *"overlaps existing Podman network 'someone-elses-net'"* \
      && "$ov_out" == *"podman network rm"* ]]; then
    _sect_bump pass; echo "PASS: ensure fails closed on overlapping foreign network (with remediation)"
else
    _sect_bump fail; echo "FAIL: overlap pre-check (rc=$ov_rc, out: $ov_out)"
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
    _sect_bump pass; echo "PASS: foreign /30 nested in profile range fails ensure"
else
    _sect_bump fail; echo "FAIL: tiny-prefix foreign subnet slipped the scan (rc=$ov_rc, out: $ov_out)"
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
    && { _sect_bump pass; echo "PASS: 28-prefix DNS allow targets first usable"; } \
    || { _sect_bump fail; echo "FAIL: 28-prefix DNS allow gateway wrong"; }
# Anchor/gateway address exclusion: 10.78.0.17 (bridge gw) as static gw.
bad_config sub28-gw-eq-bridge \
    $'profile a 10.78.0.16/28\n    rule gateway-only\n    gateway 10.78.0.17 3128 allow28' \
    "outside the usable range"
# Teardown for cleanliness.
check "28-prefix profile: teardown" 0 a11 sub28.conf teardown sub28

section_end arc11


# --- ARC-12: stale-DNS drift check ----------------------------------------
section_begin arc12 "ARC-12 DNS drift"
A12="$TESTROOT/arc12"
mkdir -p "$A12"
: > "$A12/allow"
cat > "$A12/dr.conf" <<'EOF'
profile dr 10.79.0.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
    rule allow-host ${FORGEJO_HOST:-git.example.test}:2222
    rule allow-host ${OLLAMA_HOST:-cache.example.test}:11434
EOF
drc() { env ARCMOCK_PASSWD_HOME="$(conf_home "$A12/dr.conf")" egresslock "$@"; }

# Baseline: ensure + verify with the base DNS mapping; verify silent.
check "drift profile: ensure" 0 drc ensure dr
v_out="$(drc verify dr 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" != *"drift:"* ]]; then
    _sect_bump pass; echo "PASS: no-drift verify is silent and passes"
else
    _sect_bump fail; echo "FAIL: no-drift verify (rc=$v_rc, out: $v_out)"
fi

# Drifted first-A: forgejo now resolves elsewhere. verify must exit 0,
# warn with old and new, and the live chain must KEEP the old pin.
export EGRESSLOCK_MOCK_DNS="git.example.test=192.0.2.99"
v_out="$(drc verify dr 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" == *"drift: host git.example.test resolved to 192.0.2.99 but the policy pins 192.0.2.10"* ]] \
   && [[ "$(grep -c 'drift:' <<<"$v_out")" == 1 ]]; then
    _sect_bump pass; echo "PASS: drifted verify warns once (per host) and exits 0"
else
    _sect_bump fail; echo "FAIL: drifted verify (rc=$v_rc, out: $v_out)"
fi
grep -q 'daddr 192.0.2.10 tcp dport 443' "$STATE/nft/egresslock.p_dr" \
    && { _sect_bump pass; echo "PASS: drift did not mutate the policy"; } \
    || { _sect_bump fail; echo "FAIL: drift check changed the pinned policy"; }
# Unresolvable host at verify: distinct warn, exit 0, pin kept.
export EGRESSLOCK_MOCK_DNS="git.example.test="
v_out="$(drc verify dr 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" == *"drift: host git.example.test no longer resolves; policy still pins 192.0.2.10"* ]]; then
    _sect_bump pass; echo "PASS: unresolvable host warns, exits 0"
else
    _sect_bump fail; echo "FAIL: unresolvable-at-verify (rc=$v_rc, out: $v_out)"
fi
unset EGRESSLOCK_MOCK_DNS

# ensure after a drift: heals and announces; subsequent verify silent.
export EGRESSLOCK_MOCK_DNS="git.example.test=192.0.2.99"
e_out="$(drc ensure dr 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 && "$e_out" == *"refreshed: host git.example.test 192.0.2.10 -> 192.0.2.99"* ]]; then
    _sect_bump pass; echo "PASS: ensure announces the refreshed host"
else
    _sect_bump fail; echo "FAIL: ensure refresh announce (rc=$e_rc, out: $e_out)"
fi
# R-012-1 F1: exactly ONE announce line per drifted HOST (forgejo has
# two allow-host ports; a naive per-port loop prints two lines).
announced_count="$(grep -c 'refreshed: host git.example.test' <<<"$e_out")"
if [[ "$announced_count" == 1 ]]; then
    _sect_bump pass; echo "PASS: one refreshed line per drifted host (not per port)"
else
    _sect_bump fail; echo "FAIL: refreshed announce count=$announced_count (want 1)"
fi
v_out="$(drc verify dr 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" != *"drift:"* ]]; then
    _sect_bump pass; echo "PASS: verify silent after the heal"
else
    _sect_bump fail; echo "FAIL: verify after heal (rc=$v_rc, out: $v_out)"
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
EOF
env ARCMOCK_PASSWD_HOME="$(conf_home "$A12/plain.conf")" egresslock ensure plain >/dev/null 2>&1
export EGRESSLOCK_MOCK_DNS="git.example.test=192.0.2.99,cache.example.test=192.0.2.98"
p_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$A12/plain.conf")" egresslock verify plain 2>&1)"; p_rc=$?
if [[ "$p_rc" == 0 && "$p_out" != *"drift:"* ]]; then
    _sect_bump pass; echo "PASS: no-allow-host profile verify silent"
else
    _sect_bump fail; echo "FAIL: no-allow-host profile (rc=$p_rc, out: $p_out)"
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

# EGL-219: multi-A allow-host — the pin is the whole ensure-time A set
# (any-of), not the resolver's first line. Separate profile so the
# single-A legs above stay byte-identical.
cat > "$A12/ma.conf" <<'EOF'
profile ma 10.79.2.0/24
    rule allow-host multi.example.test:443
EOF
mrc() { env ARCMOCK_PASSWD_HOME="$(conf_home "$A12/ma.conf")" egresslock "$@"; }

# The mock answer carries the addresses in NON-sorted order: the pin
# must be the sorted set (one accept per member) and the record the
# space-joined set.
export EGRESSLOCK_MOCK_DNS="multi.example.test=192.0.2.50+192.0.2.44"
check "multi-A: ensure pins the set" 0 mrc ensure ma
if [[ "$(grep -c 'ip daddr 192.0.2.44 tcp dport 443' "$STATE/nft/egresslock.p_ma")" == 1 \
      && "$(grep -c 'ip daddr 192.0.2.50 tcp dport 443' "$STATE/nft/egresslock.p_ma")" == 1 ]]; then
    _sect_bump pass; echo "PASS: multi-A host pinned with one accept per member"
else
    _sect_bump fail; echo "FAIL: multi-A host did not pin both members"
fi
[[ "$(cat "$A12/ma.pins")" == 'multi.example.test|443 192.0.2.44 192.0.2.50' ]] \
    && { _sect_bump pass; echo "PASS: multi-A pin record carries the sorted set"; } \
    || { _sect_bump fail; echo "FAIL: multi-A pin record content (got: $(cat "$A12/ma.pins"))"; }

# Resolver REORDER (same set, different mock order): no refreshed line,
# no policy churn, verify silent — the old first-A bug flapped here.
export EGRESSLOCK_MOCK_DNS="multi.example.test=192.0.2.44+192.0.2.50"
e_out="$(mrc ensure ma 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 && "$e_out" != *"refreshed:"* ]]; then
    _sect_bump pass; echo "PASS: resolver reorder does not announce"
else
    _sect_bump fail; echo "FAIL: reorder flapped the pin (rc=$e_rc, out: $e_out)"
fi
v_out="$(mrc verify ma 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" != *"drift:"* ]]; then
    _sect_bump pass; echo "PASS: reorder is not drift"
else
    _sect_bump fail; echo "FAIL: reorder warned drift (rc=$v_rc, out: $v_out)"
fi

# Member ADD (no re-ensure yet): verify warns with the SETS rendered
# (comma-joined), rc 0; then ensure announces the set change.
export EGRESSLOCK_MOCK_DNS="multi.example.test=192.0.2.60+192.0.2.50+192.0.2.44"
v_out="$(mrc verify ma 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" == *"drift: host multi.example.test resolved to 192.0.2.44,192.0.2.50,192.0.2.60 but the policy pins 192.0.2.44,192.0.2.50 — re-run ensure to update"* ]]; then
    _sect_bump pass; echo "PASS: member add warns drift with the sets rendered, rc 0"
else
    _sect_bump fail; echo "FAIL: member-add drift (rc=$v_rc, out: $v_out)"
fi
e_out="$(mrc ensure ma 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 && "$e_out" == *"refreshed: host multi.example.test 192.0.2.44,192.0.2.50 -> 192.0.2.44,192.0.2.50,192.0.2.60 (policy re-installed with the new address)"* ]]; then
    _sect_bump pass; echo "PASS: member add announces the set change"
else
    _sect_bump fail; echo "FAIL: member-add announce (rc=$e_rc, out: $e_out)"
fi

# Member REMOVE (disjoint fresh set): verify warns, rc 0; ensure
# announces the shrink and re-pins the smaller set.
export EGRESSLOCK_MOCK_DNS="multi.example.test=192.0.2.90"
v_out="$(mrc verify ma 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" == *"drift: host multi.example.test resolved to 192.0.2.90 but the policy pins 192.0.2.44,192.0.2.50,192.0.2.60 — re-run ensure to update"* ]]; then
    _sect_bump pass; echo "PASS: disjoint fresh set warns drift, rc 0"
else
    _sect_bump fail; echo "FAIL: disjoint drift (rc=$v_rc, out: $v_out)"
fi
e_out="$(mrc ensure ma 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 && "$e_out" == *"refreshed: host multi.example.test 192.0.2.44,192.0.2.50,192.0.2.60 -> 192.0.2.90 (policy re-installed with the new address)"* ]] \
   && [[ "$(cat "$A12/ma.pins")" == 'multi.example.test|443 192.0.2.90' ]]; then
    _sect_bump pass; echo "PASS: disjoint set re-pins and announces"
else
    _sect_bump fail; echo "FAIL: disjoint re-pin (rc=$e_rc, pins: $(cat "$A12/ma.pins"), out: $e_out)"
fi

# EGL-219-D2/D8: a >cap answer truncates with the pinned stderr note
# (rc and policy unaffected), and the note renders on the verify/drift
# resolve path too (stderr-only).
_cap_addrs="192.0.2.1"
for _ci in $(seq 2 17); do _cap_addrs="$_cap_addrs+192.0.2.$_ci"; done
export EGRESSLOCK_MOCK_DNS="multi.example.test=$_cap_addrs"
e_out="$(mrc ensure ma 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 && "$e_out" == *"note: multi.example.test resolves to 17 addresses; pinning the first 16 (DNS_SET_MAX), sorted"* ]] \
   && [[ "$(wc -w < "$A12/ma.pins")" == 17 ]]; then
    _sect_bump pass; echo "PASS: cap note on ensure, first 16 pinned (host|port + 16 addrs)"
else
    _sect_bump fail; echo "FAIL: cap truncation (rc=$e_rc, record: $(cat "$A12/ma.pins"), out: $e_out)"
fi
v_out="$(mrc verify ma 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" == *"note: multi.example.test resolves to 17 addresses; pinning the first 16 (DNS_SET_MAX), sorted"* \
      && "$v_out" != *"drift:"* ]]; then
    _sect_bump pass; echo "PASS: cap note renders on the verify resolve, no drift, rc 0"
else
    _sect_bump fail; echo "FAIL: verify-path cap note (rc=$v_rc, out: $v_out)"
fi
unset EGRESSLOCK_MOCK_DNS
unset _cap_addrs _ci

# EGL-219-D14/R4: stateful-resolver regression — one resolve per `ensure`
# (the D3 cache) and one per verify host, observed via the mock's dns-seq
# queue + dns-queries.log. Profile `seq` 10.199.65.0/24 (free until the
# egl139 `shr` fixture's deep reset), 443 + 8443 and a duplicate 443
# (legal, ordered-repeatable).
cat > "$A12/seq.conf" <<'EOF'
profile seq 10.199.65.0/24
    rule allow-host seq.example.test:443
    rule allow-host seq.example.test:8443
    rule allow-host seq.example.test:443
EOF
sqc() { env ARCMOCK_PASSWD_HOME="$(conf_home "$A12/seq.conf")" egresslock "$@"; }
printf '192.0.2.50+192.0.2.44\n192.0.2.60+192.0.2.44\n' > "$ARCMOCK_STATE/dns-seq-seq.example.test"
: > "$ARCMOCK_STATE/dns-queries.log"
check "seq: ensure single-resolves a multi-address host" 0 sqc ensure seq
q_n="$(wc -l < "$ARCMOCK_STATE/dns-queries.log")"
if [[ "$q_n" == 1 && "$(cat "$ARCMOCK_STATE/dns-queries.log")" == 'seq.example.test=192.0.2.50+192.0.2.44' ]]; then
    _sect_bump pass; echo "PASS: seq ensure made exactly ONE resolver query (the D3 cache)"
else
    _sect_bump fail; echo "FAIL: seq ensure queries=$q_n (log: $(tr '\n' '|' < "$ARCMOCK_STATE/dns-queries.log"))"
fi
acc_n="$(grep -cE 'ip daddr 192\.0\.2\.(44|50) tcp dport (443|8443) counter accept' "$STATE/nft/egresslock.p_seq")"
if [[ "$acc_n" == 6 ]]; then
    _sect_bump pass; echo "PASS: seq pins 3 entries x 2 members = 6 accepts"
else
    _sect_bump fail; echo "FAIL: seq accept count=$acc_n (want 6)"
fi
if [[ "$(cat "$A12/seq.pins")" == $'seq.example.test|443 192.0.2.44 192.0.2.50\nseq.example.test|8443 192.0.2.44 192.0.2.50\nseq.example.test|443 192.0.2.44 192.0.2.50' ]]; then
    _sect_bump pass; echo "PASS: seq record: one line per conf entry, sorted set, duplicate identical"
else
    _sect_bump fail; echo "FAIL: seq record content (got: $(tr '\n' '|' < "$A12/seq.pins"))"
fi
# verify: one fresh query (the second queued answer), exactly one drift
# line for the host (host-deduped although three entries share it), and
# no record/chain churn.
v_out="$(sqc verify seq 2>&1)"; v_rc=$?
q_n="$(wc -l < "$ARCMOCK_STATE/dns-queries.log")"
if [[ "$v_rc" == 0 && "$q_n" == 2 ]] \
   && [[ "$(tail -1 "$ARCMOCK_STATE/dns-queries.log")" == 'seq.example.test=192.0.2.60+192.0.2.44' ]] \
   && [[ "$(grep -c 'drift:' <<<"$v_out")" == 1 ]] \
   && [[ "$v_out" == *"drift: host seq.example.test resolved to 192.0.2.44,192.0.2.60 but the policy pins 192.0.2.44,192.0.2.50 — re-run ensure to update"* ]] \
   && [[ "$(cat "$A12/seq.pins")" == $'seq.example.test|443 192.0.2.44 192.0.2.50\nseq.example.test|8443 192.0.2.44 192.0.2.50\nseq.example.test|443 192.0.2.44 192.0.2.50' ]] \
   && [[ "$(grep -cE 'ip daddr 192\.0\.2\.(44|50) tcp dport (443|8443) counter accept' "$STATE/nft/egresslock.p_seq")" == 6 ]]; then
    _sect_bump pass; echo "PASS: seq verify: one fresh query, one drift line, no record/chain churn"
else
    _sect_bump fail; echo "FAIL: seq verify (rc=$v_rc, queries=$q_n, out: $(echo "$v_out" | tr '\n' '|'))"
fi
rm -f "$ARCMOCK_STATE/dns-seq-seq.example.test" "$ARCMOCK_STATE/dns-queries.log"

section_end arc12



arc14_pass=0; arc14_fail=0
A14="$(mktemp -d /tmp/agent-a14.XXXXXX)"
a14() { if [[ "$1" == pass ]]; then arc14_pass=$((arc14_pass+1)); else arc14_fail=$((arc14_fail+1)); echo "FAIL: $2"; fi; }

cat > "$A14/bare.conf" <<'EOF'
profile bare 10.80.0.0/24
    rule allow-host ${FORGEJO_HOST}:443
EOF

# Engine mode with the site env vars UNSET: a bare ${FORGEJO_HOST} with
# no fallback must fail closed at conf parse — the binary must NOT
# supply a site default hostname (ARC-14).
b_out="$(env -u FORGEJO_HOST -u OLLAMA_HOST ARCMOCK_PASSWD_HOME="$(conf_home "$A14/bare.conf")" egresslock rules bare 2>&1)"; b_rc=$?
if [[ "$b_rc" != 0 && "$b_out" != *"git.example.test"* ]]; then
    a14 pass
else
    a14 fail "bare \${FORGEJO_HOST} in engine mode (rc=$b_rc, out: $b_out)"
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
b3_out="$(env -u FORGEJO_HOST EGRESSLOCK_MOCK_DNS="fb.example.test=192.0.2.10,override.example.test=192.0.2.11" ARCMOCK_PASSWD_HOME="$(conf_home "$A14/fb.conf")" egresslock rules fb 2>&1)"; b3_rc=$?
if [[ "$b3_rc" == 0 && "$b3_out" == *"ip daddr 192.0.2.10 tcp dport 443"* ]]; then
    a14 pass
else
    a14 fail "conf fallback data without baked default (rc=$b3_rc, out: $b3_out)"
fi
b4_out="$(env FORGEJO_HOST=override.example.test EGRESSLOCK_MOCK_DNS="fb.example.test=192.0.2.10,override.example.test=192.0.2.11" ARCMOCK_PASSWD_HOME="$(conf_home "$A14/fb.conf")" egresslock rules fb 2>&1)"; b4_rc=$?
if [[ "$b4_rc" == 0 && "$b4_out" == *"ip daddr 192.0.2.11 tcp dport 443"* ]]; then
    a14 pass
else
    a14 fail "explicit env override of conf data (rc=$b4_rc, out: $b4_out)"
fi
rm -rf "$A14"

# R-014-1 F1 / ARC-21-D1: usage must document the env vars and required
# config (ARC-20: no compiled-in profiles). FORGEJO_HOST/OLLAMA_HOST are
# no longer overrides (D3) and must NOT appear. EGL-286: this pin reads
# `help env`/`help config`; EGL-325: the config page names the fixed
# confdir. Single compound assertion with explicit else: every run ticks
# the ARC-14 counter exactly once (R-019-1 F2).
u_out="$(env egresslock --help 2>&1; env egresslock help env 2>&1; env egresslock help config 2>&1)"; u_rc=$?
u_ok=1
for v in NFT_BIN EGRESSLOCK_ANCHOR_IMAGE EGRESSLOCK_GW_IMAGE \
         "localhost/egresslock-gateway:latest" "no profile config" \
         "<account-home>/.config/egresslock"; do
    [[ "$u_out" == *"$v"* ]] || u_ok=0
done
[[ "$u_out" == *"FORGEJO_HOST"* || "$u_out" == *"OLLAMA_HOST"* ]] && u_ok=0
if [[ "$u_ok" == 1 && "$u_rc" == 0 ]]; then
    a14 pass
else
    a14 fail "usage completeness (rc=$u_rc; missing a required entry or listing a forbidden name)"
fi

# --- ARC-16: kit surface (engine side) -------------------------------------
section_begin arc16 "ARC-16 kit surface"
a16() { assert "$@"; }

# D5: --version prints 'dev' when the binary has no VERSION file next
# to it (repo checkout), without touching profile state.
v_out="$(env egresslock --version 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" == "dev" ]]; then
    a16 pass
else
    a16 fail "--version dev (rc=$v_rc, out: $v_out)"
fi
v2_out="$(env egresslock --version extra-arg 2>&1)"; v2_rc=$?
if [[ "$v2_rc" == 0 && "$v2_out" == "dev" ]]; then
    a16 pass
else
    a16 fail "--version ignores extra args (rc=$v2_rc, out: $v2_out)"
fi

# D3: verify --ensured with nothing ensured is silent success. The
# no-config case is now the ARC-20 fail-closed check, so this runs on a
# fixture confdir (a profile with no live anchor).
env ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/validconf/v.conf")" egresslock teardown all >/dev/null 2>&1 || true
e_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/validconf/v.conf")" egresslock verify --ensured 2>"$TESTROOT/e16.err")"; e_rc=$?
if [[ "$e_rc" == 0 && -z "$e_out" ]] \
   && [[ "$(cat $TESTROOT/e16.err)" == *"using configs in"*"(1 profiles)"* ]]; then
    a16 pass
else
    a16 fail "verify --ensured silent stdout + scoped stderr (rc=$e_rc, out: $e_out, err: $(cat $TESTROOT/e16.err))"
fi

# D3: verify --ensured takes no profile argument.
x_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/validconf/v.conf")" egresslock verify --ensured local-dev 2>&1)"; x_rc=$?
[[ "$x_rc" == 2 ]] && a16 pass || a16 fail "verify --ensured rejects profile arg (rc=$x_rc)"

section_end arc16

# --- ARC-20: config required (no compiled-in profiles) -------------------
section_begin arc20 "ARC-20 config required"
a20() { assert "$@"; }

# Bare invocation with an empty fixed confdir fails closed for every
# profile subcommand with the required-config message. The message names
# the checked confdir and hints at running as the account; it does NOT
# dump the full usage (the error is a missing config, not a usage
# mistake).
b_out="$(env egresslock list 2>&1)"; b_rc=$?
if [[ "$b_rc" == 2 && "$b_out" == *"no profile config"* && "$b_out" == *"/.config/egresslock"* ]]; then
    a20 pass
else
    a20 fail "bare list fails closed (rc=$b_rc, out: $b_out)"
fi
b2_out="$(env egresslock list 2>&1)"; b2_rc=$?
if [[ "$b2_rc" == 2 && "$b2_out" == *"make sure you are running as the dedicated account"* ]]; then
    a20 pass
else
    a20 fail "no-config message hints at account/config (rc=$b2_rc, out: $b2_out)"
fi
b3_out="$(env egresslock list 2>&1)"; b3_rc=$?
if [[ "$b3_rc" == 2 && "$b3_out" != *"Usage:"* ]]; then
    a20 pass
else
    a20 fail "no-config does not dump usage (rc=$b3_rc, out: $b3_out)"
fi
check "bare ensure fails closed" 2 env egresslock ensure v
check "bare verify fails closed" 2 env egresslock verify v
check "bare verify --ensured fails closed" 2 env egresslock verify --ensured
check "bare teardown all fails closed" 2 env egresslock teardown all
check "bare network fails closed" 2 env egresslock network v
check "bare proxy-env fails closed" 2 env egresslock proxy-env v
check "bare rules fails closed" 2 env egresslock rules v
check "bare allowlist fails closed" 2 env egresslock allowlist v
check "bare denied fails closed" 2 env egresslock denied v
check "bare allow fails closed" 2 env egresslock allow v x
# EGL-325: EGRESSLOCK_CONF is no longer read (empty or set).
check "ignored EGRESSLOCK_CONF still fails closed" 2 env EGRESSLOCK_CONF= egresslock list
# --help / --version / no-args usage do NOT require a config.
check "bare --help works without a conf" 0 env egresslock --help
check "bare help works without a conf" 0 env egresslock help
check "bare --version works without a conf" 0 env egresslock --version
check "no-args usage works without a conf" 0 env egresslock
# Unknown subcommand is a usage error (exit 2), not a config requirement.
check "unknown subcommand without a conf exits 2" 2 env egresslock frobnicate
# The removed needs-creds subcommand now hits the unknown-command path.
check "needs-creds is an unknown command now" 2 env egresslock needs-creds v
# no-args shows the SHORT usage (command index), not the full header.
u0_out="$(env egresslock 2>&1)"; u0_rc=$?
if [[ "$u0_rc" == 0 && "$u0_out" == *"usage: egresslock"* && "$u0_out" == *"commands:"* ]]; then
    a20 pass
else
    a20 fail "no-args short usage (rc=$u0_rc, out: $u0_out)"
fi
# Unknown command prints short usage, not the full header.
u1_out="$(env egresslock bogus 2>&1)"; u1_rc=$?
if [[ "$u1_rc" == 2 && "$u1_out" == *"unknown command"* && "$u1_out" == *"commands:"* ]]; then
    a20 pass
else
    a20 fail "unknown command short usage (rc=$u1_rc, out: $u1_out)"
fi
# Missing profile arg gives a command-specific usage line.
u2_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/validconf/v.conf")" egresslock proxy-env 2>&1)"; u2_rc=$?
if [[ "$u2_rc" == 2 && "$u2_out" == *"proxy-env requires a profile name"* && "$u2_out" == *"usage: egresslock proxy-env <profile>"* ]]; then
    a20 pass
else
    a20 fail "proxy-env missing profile message (rc=$u2_rc, out: $u2_out)"
fi
# Missing allow entry gives a command-specific usage line (gateway profile).
u3_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$NPDIR/ci.conf")" egresslock allow ci 2>&1)"; u3_rc=$?
if [[ "$u3_rc" == 2 && "$u3_out" == *"allow requires a destination"* && "$u3_out" == *"usage: egresslock allow <profile> <host[:port]>"* ]]; then
    a20 pass
else
    a20 fail "allow missing entry message (rc=$u3_rc, out: $u3_out)"
fi
# list has column headers.
u4_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home_ro "$TESTROOT/validconf/v.conf")" egresslock list 2>/dev/null)"; u4_rc=$?
if [[ "$u4_rc" == 0 && "$u4_out" == *"NAME"* && "$u4_out" == *"NETWORK"* && "$u4_out" == *"SUBNET"* ]]; then
    a20 pass
else
    a20 fail "list column headers (rc=$u4_rc, out: $u4_out)"
fi

section_end arc20

# --- ARC-25: fail closed when run as root -------------------------------
section_begin arc25 "ARC-25 root guard"
a25() { assert "$@"; }

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
    r_out="$(PATH="$TESTROOT/bin-root:$PATH" env ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/validconf/v.conf")" egresslock $cmd 2>&1)"; r_rc=$?
    if [[ "$r_rc" != 0 && "$r_out" == *"must run as the account, not root"* ]]; then
        a25 pass
    else
        a25 fail "root guard '$cmd' (rc=$r_rc, out: $r_out)"
    fi
done

# --help / --version stay root-safe (read-only, config-free).
h_out="$(PATH="$TESTROOT/bin-root:$PATH" env egresslock --help 2>&1)"; h_rc=$?
[[ "$h_rc" == 0 && "$h_out" == *"Usage:"* ]] && a25 pass || a25 fail "--help as root works (rc=$h_rc)"
# EGL-286: the help verb is in the same class (config-free, no resolution
# line) — root-safe for both the summary and a topic page.
h2_out="$(PATH="$TESTROOT/bin-root:$PATH" env egresslock help ensure 2>&1)"; h2_rc=$?
[[ "$h2_rc" == 0 && "$h2_out" == *"egresslock ensure"* ]] && a25 pass || a25 fail "help ensure as root works (rc=$h2_rc)"
v_out="$(PATH="$TESTROOT/bin-root:$PATH" env egresslock --version 2>&1)"; v_rc=$?
[[ "$v_rc" == 0 && "$v_out" == "dev" ]] && a25 pass || a25 fail "--version as root works (rc=$v_rc)"

# Escape hatch: EGRESSLOCK_ALLOW_ROOT=1 lets the root path run.
e_out="$(PATH="$TESTROOT/bin-root:$PATH" env EGRESSLOCK_ALLOW_ROOT=1 ARCMOCK_PASSWD_HOME="$(conf_home_ro "$TESTROOT/validconf/v.conf")" egresslock list 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 && "$e_out" == *"egresslock-v"* ]]; then
    a25 pass
else
    a25 fail "escape hatch allows root list (rc=$e_rc, out: $e_out)"
fi

section_end arc25

# --- ARC-26: netns preflight probe --------------------------------------
section_begin arc26 "ARC-26 netns probe"
a26() { assert "$@"; }

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

# EGL-325: bare `teardown all` stays main.conf-only. Give the fixture
# confdir a main.conf so this leg reaches the preflight probe (the
# profile conf is still ci.conf for the other legs).
printf 'profile main 10.94.8.0/24\n' > "$NPDIR/main.conf"
for cmd in "ensure ci" "verify ci" "verify --ensured" "teardown all"; do
    # shellcheck disable=SC2086
    p_out="$(PATH="$TESTROOT/bin-broken:$PATH" npc $cmd 2>&1)"; p_rc=$?
    # EGL-35: the preflight guidance leads with the shipped fix
    # (verb form after EGL-287: egresslock-setup apparmor add, or
    # apparmor check to inspect); the manual
    # aa-status/parser archaeology moved to docs/troubleshooting.
    if [[ "$p_rc" == 1 && "$p_out" == *"podman rootless-netns is broken"* && "$p_out" == *"egresslock-setup apparmor add"* && "$p_out" == *"apparmor check"* ]]; then
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
s_out="$(PATH="$TESTROOT/bin-broken:$PATH" env EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$(conf_home "$NPDIR/ci.conf")" egresslock ensure ci 2>&1)"; s_rc=$?
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
# 600s bound (EGL-225). SKIP is deliberately NOT set on this call (D4:
# the bound, not the SKIP env, is the hang-prevention mechanism).
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
    _sect_bump pass; echo "PASS: ARC-26 hanging probe is a named timeout failure (rc=1, ${h_elapsed}s)"
else
    _sect_bump fail; echo "FAIL: ARC-26 hanging probe not bounded (rc=$h_rc, elapsed=${h_elapsed}s, out: $h_out)"
fi

section_end arc26

# --- ARC-49 R-049-1 F1: no /tmp/egresslock-policy.* leak on a failed nft -f -
# Regression for F1: the EXIT-trap cleanup (removed in the F1 fix) could
# not fire on implicit set -e exits; the fix uses explicit rm + die
# instead. Assert a mid-install_policy nft failure is fail-closed AND
# leaves no /tmp/egresslock-policy.* behind.
section_begin arc49 "ARC-49 nft-temp"
a49() { assert "$@"; }

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
before="$(find /tmp -maxdepth 1 -name 'egresslock-policy.*' 2>/dev/null | sort)"
nf_out="$(PATH="$TESTROOT/bin-nftfail:$PATH" env ARCMOCK_PASSWD_HOME="$(conf_home "$NPDIR/ci.conf")" egresslock ensure ci 2>&1)"; nf_rc=$?
after="$(find /tmp -maxdepth 1 -name 'egresslock-policy.*' 2>/dev/null | sort)"
new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
if [[ "$nf_rc" != 0 && -z "$new" ]]; then
    a49 pass
else
    a49 fail "failed nft -f leaks egresslock-policy temp (rc=$nf_rc, new=[$new], out: $nf_out)"
fi
# Restore a verified policy (the failed ensure left a partial state; the
# engine's next ensure self-heals, and later sections expect ci verified).
restore_out="$(npc ensure ci >/dev/null 2>&1)"; restore_rc=$?
[[ "$restore_rc" == 0 ]] && a49 pass || a49 fail "ensure ci after F1 probe self-heals (rc=$restore_rc)"
section_end arc49

# --- ARC-24: per-user default config probe ------------------------------
section_begin arc24 "ARC-24 default probe"
a24() { assert "$@"; }

# The account home's confdir: bare `list` AGGREGATES CONFDIR/*.conf
# (ARC-37-D3), prints 'using configs in <dir>' on stderr, and stdout
# stays pure payload.
mkdir -p "$TESTROOT/h24/.config/egresslock"
printf 'profile v 10.50.9.0/24\n' > "$TESTROOT/h24/.config/egresslock/v.conf"
d_out="$(pty "env HOME='$TESTROOT/h24' ARCMOCK_PASSWD_HOME='$TESTROOT/h24' egresslock list 2>$TESTROOT/agent24.err")"; d_rc=$?
if [[ "$d_rc" == 0 && "$d_out" == *"egresslock-v"* && "$(cat $TESTROOT/agent24.err)" == *"using configs in"*"$TESTROOT/h24/.config/egresslock"* ]]; then
    a24 pass
else
    a24 fail "default probe resolves + prints using configs in (rc=$d_rc, out: $d_out, err: $(cat $TESTROOT/agent24.err))"
fi

# ARC-49-D3: an account home containing a space must still resolve the
# fixed conf dir and aggregate — confdir_default quotes the passwd-home
# path, so a space in it must not break the probe (or any named path).
mkdir -p "$TESTROOT/home with space/.config/egresslock"
printf 'profile hsp 10.50.11.0/24\n' > "$TESTROOT/home with space/.config/egresslock/hsp.conf"
sp_out="$(pty "env HOME='$TESTROOT/home with space' ARCMOCK_PASSWD_HOME='$TESTROOT/home with space' egresslock list 2>$TESTROOT/agent24sp.err")"; sp_rc=$?
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
q_out="$(env HOME="$TESTROOT/h24" ARCMOCK_PASSWD_HOME="$TESTROOT/h24" egresslock list 2>$TESTROOT/agent24q.err)"; q_rc=$?
if [[ "$q_rc" == 0 && "$q_out" == *"egresslock-v"* \
      && "$(cat $TESTROOT/agent24q.err)" == *"using configs in"*"$TESTROOT/h24/.config/egresslock"*"(1 profiles)"* ]]; then
    a24 pass
else
    a24 fail "EGL-117: resolution line survives capture (rc=$q_rc, out: $q_out, err: $(cat $TESTROOT/agent24q.err))"
fi

# stderr only: stdout payload (list) unchanged.
d2_out="$(env HOME="$TESTROOT/h24" ARCMOCK_PASSWD_HOME="$TESTROOT/h24" egresslock network v 2>/dev/null)"; d2_rc=$?
if [[ "$d2_rc" == 0 && "$d2_out" == *"egresslock-v"* ]]; then
    a24 pass
else
    a24 fail "stdout payload unchanged by probe (rc=$d2_rc, out: $d2_out)"
fi

# HOME without the file: bare invocation still fails closed (exit 2).
mkdir -p "$TESTROOT/h24-empty"
m_out="$(env HOME="$TESTROOT/h24-empty" ARCMOCK_PASSWD_HOME="$TESTROOT/h24-empty" egresslock list 2>&1)"; m_rc=$?
if [[ "$m_rc" == 2 && "$m_out" == *"no profile config"* ]]; then
    a24 pass
else
    a24 fail "probe miss fails closed (rc=$m_rc, out: $m_out)"
fi

# EGL-325: the account home comes from the passwd database, NEVER $HOME
# — an alternate HOME neither selects nor hides the confdir. The
# disclosure names the passwd-home confdir.
x_out="$(env HOME="$TESTROOT/validconf" ARCMOCK_PASSWD_HOME="$TESTROOT/h24" egresslock list 2>$TESTROOT/agent24x.err)"; x_rc=$?
if [[ "$x_rc" == 0 \
      && "$(cat $TESTROOT/agent24x.err)" == *"using configs in $TESTROOT/h24/.config/egresslock"* \
      && "$(cat $TESTROOT/agent24x.err)" != *"$TESTROOT/validconf"* ]]; then
    a24 pass
else
    a24 fail "passwd home wins over \$HOME (rc=$x_rc, err: $(cat $TESTROOT/agent24x.err))"
fi

# EGL-325: EGRESSLOCK_CONF is no longer a selector — setting it to a
# valid conf does not scope or redirect a bare command.
y_out="$(env EGRESSLOCK_CONF="$TESTROOT/validconf/v.conf" ARCMOCK_PASSWD_HOME="$TESTROOT/h24" egresslock list 2>$TESTROOT/agent24y.err)"; y_rc=$?
if [[ "$y_rc" == 0 && "$y_out" == *"egresslock-v"* \
      && "$(cat $TESTROOT/agent24y.err)" == *"using configs in $TESTROOT/h24/.config/egresslock"* \
      && "$(cat $TESTROOT/agent24y.err)" != *"validconf"* ]]; then
    a24 pass
else
    a24 fail "EGRESSLOCK_CONF ignored, confdir aggregate used (rc=$y_rc, err: $(cat $TESTROOT/agent24y.err))"
fi

# getent home is authoritative even with HOME unset: the default probe
# still works from the passwd answer alone.
mkdir -p "$TESTROOT/h24-nohome/.config/egresslock"
printf 'profile w 10.50.10.0/24\n' > "$TESTROOT/h24-nohome/.config/egresslock/w.conf"
g_out="$(pty "env -u HOME ARCMOCK_PASSWD_HOME='$TESTROOT/h24-nohome' egresslock list 2>$TESTROOT/agent24g.err")"; g_rc=$?
if [[ "$g_rc" == 0 && "$g_out" == *"egresslock-w"* && "$(cat $TESTROOT/agent24g.err)" == *"using configs in"*"$TESTROOT/h24-nohome/.config/egresslock"* ]]; then
    a24 pass
else
    a24 fail "HOME-unset getent fallback resolves default conf (rc=$g_rc, out: $g_out, err: $(cat $TESTROOT/agent24g.err))"
fi

# HOME empty (''): the passwd answer alone resolves the confdir.
g2_out="$(pty "env HOME= ARCMOCK_PASSWD_HOME='$TESTROOT/h24-nohome' egresslock list 2>$TESTROOT/agent24g2.err")"; g2_rc=$?
if [[ "$g2_rc" == 0 && "$g2_out" == *"egresslock-w"* && "$(cat $TESTROOT/agent24g2.err)" == *"using configs in"*"$TESTROOT/h24-nohome/.config/egresslock"* ]]; then
    a24 pass
else
    a24 fail "HOME-empty getent fallback resolves default conf (rc=$g2_rc, out: $g2_out, err: $(cat $TESTROOT/agent24g2.err))"
fi

# getent home pointing at a nonexistent dir: probe miss stays fail-closed.
g3_out="$(env -u HOME ARCMOCK_PASSWD_HOME="$TESTROOT/h24-nohome-missing" egresslock list 2>&1)"; g3_rc=$?
if [[ "$g3_rc" == 2 && "$g3_out" == *"no profile config"* ]]; then
    a24 pass
else
    a24 fail "getent home miss stays fail-closed (rc=$g3_rc, out: $g3_out)"
fi

section_end arc24

# --- ARC-35: init (write a starter profile pair) ------------------------
section_begin arc35 "ARC-35 init"
a35() { assert "$@"; }

# init is a writer, not a config-requiring subcommand: works with no
# loadable conf, from $HOME/.config/egresslock.
rm -rf "$TESTROOT/i35"; mkdir -p "$TESTROOT/i35/.config/egresslock"
printf 'profile main 10.199.0.0/24\n    rule gateway-only\n    gateway 10.199.0.2 3128 main-allowlist\n' \
    > "$TESTROOT/i35/.config/egresslock/main.conf"

# Auto-pick skips main's 10.199.0.0/24 -> 10.199.1.0/24.
i_out="$(env HOME="$TESTROOT/i35" ARCMOCK_PASSWD_HOME="$TESTROOT/i35" egresslock init local 2>&1)"; i_rc=$?
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
i2_out="$(env HOME="$TESTROOT/i35" ARCMOCK_PASSWD_HOME="$TESTROOT/i35" egresslock init local 2>&1)"; i2_rc=$?
[[ "$i2_rc" == 1 && "$i2_out" == *"already exists"* ]] \
    && a35 pass || a35 fail "init re-run never overwrites (rc=$i2_rc, out: $i2_out)"

# Explicit --subnet (free) writes it; overlapping fails closed.
i3_out="$(env HOME="$TESTROOT/i35" ARCMOCK_PASSWD_HOME="$TESTROOT/i35" egresslock init dev --subnet 10.199.5.0/24 2>&1)"; i3_rc=$?
[[ "$i3_rc" == 0 && "$(grep '^profile dev' "$TESTROOT/i35/.config/egresslock/dev.conf")" == "profile dev 10.199.5.0/24" ]] \
    && a35 pass || a35 fail "init explicit subnet (rc=$i3_rc, out: $i3_out)"
i4_out="$(env HOME="$TESTROOT/i35" ARCMOCK_PASSWD_HOME="$TESTROOT/i35" egresslock init ov --subnet 10.199.1.0/24 2>&1)"; i4_rc=$?
[[ "$i4_rc" == 1 && "$i4_out" == *"overlaps"* ]] \
    && a35 pass || a35 fail "init overlapping subnet fails closed (rc=$i4_rc, out: $i4_out)"

# Bad name / missing name / bad --subnet are usage errors (exit 2).
i5_out="$(env HOME="$TESTROOT/i35" ARCMOCK_PASSWD_HOME="$TESTROOT/i35" egresslock init "Bad_Name" 2>&1)"; i5_rc=$?
[[ "$i5_rc" == 2 && "$i5_out" == *"invalid profile name"* ]] \
    && a35 pass || a35 fail "init invalid name (rc=$i5_rc, out: $i5_out)"
i6_out="$(env HOME="$TESTROOT/i35" ARCMOCK_PASSWD_HOME="$TESTROOT/i35" egresslock init 2>&1)"; i6_rc=$?
[[ "$i6_rc" == 2 && "$i6_out" == *"init requires a profile name"* ]] \
    && a35 pass || a35 fail "init missing name (rc=$i6_rc, out: $i6_out)"
i7_out="$(env HOME="$TESTROOT/i35" ARCMOCK_PASSWD_HOME="$TESTROOT/i35" egresslock init bad --subnet nope 2>&1)"; i7_rc=$?
[[ "$i7_rc" == 2 && "$i7_out" == *"invalid --subnet"* ]] \
    && a35 pass || a35 fail "init bad --subnet (rc=$i7_rc, out: $i7_out)"

# The written pair loads and lists.
i8_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home_ro "$TESTROOT/i35/.config/egresslock/local.conf")" egresslock list 2>&1)"; i8_rc=$?
[[ "$i8_rc" == 0 && "$i8_out" == *"local"* ]] \
    && a35 pass || a35 fail "init pair is loadable (rc=$i8_rc, out: $i8_out)"

# The written pair is end-to-end operable: ensure + verify against the
# generated conf (R-035-1 note 2 follow-up). Use a dedicated profile on
# a collision-free subnet (10.199.40.0/24 is unused by every other
# engine fixture) — the live network this creates must not trip the
# ARC-11 overlap pre-check of a later section (auto-pick's 10.199.1.0/24
# collides with the ARC-37 fixture).
env HOME="$TESTROOT/i35" ARCMOCK_PASSWD_HOME="$TESTROOT/i35" egresslock init e2e --subnet 10.199.40.0/24 >/dev/null 2>&1
i9_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/i35/.config/egresslock/e2e.conf")" egresslock ensure e2e 2>&1)"; i9_rc=$?
[[ "$i9_rc" == 0 ]] \
    && a35 pass || a35 fail "init pair ensures (rc=$i9_rc, out: $i9_out)"
i10_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/i35/.config/egresslock/e2e.conf")" egresslock verify e2e 2>&1)"; i10_rc=$?
[[ "$i10_rc" == 0 ]] \
    && a35 pass || a35 fail "init pair verifies (rc=$i10_rc, out: $i10_out)"

section_end arc35

# --- ARC-30: disallow (remove an exact allowlist entry) -----------------
section_begin arc30 "ARC-30 disallow"
a30() { assert "$@"; }

# ci.conf gateway allowlist (NPDIR/ci-allowlist). Seed two entries, one
# to remove, one to keep, plus a comment and an order check.
d_al="$NPDIR/ci-allowlist"
printf 'github.com\nexample.com:443\n# keep me\napi.local:8080\n' > "$d_al"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$NPDIR/ci.conf")" egresslock disallow ci example.com:443 2>&1)"; d_rc=$?
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

# The absent-entry case is owned by arc46 #6 (EGL-270 P3 #8): same rc-1 +
# "entry not present" on the shared cmd_disallow loop, plus allowlist
# unchanged and no re-ensuring.

# Missing destination -> usage error (exit 2).
d3_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$NPDIR/ci.conf")" egresslock disallow ci 2>&1)"; d3_rc=$?
[[ "$d3_rc" == 2 && "$d3_out" == *"disallow requires a destination"* ]] \
    && a30 pass || a30 fail "disallow missing entry (rc=$d3_rc, out: $d3_out)"

# Invalid grammar -> exit 2.
d4_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$NPDIR/ci.conf")" egresslock disallow ci 'bad entry!' 2>&1)"; d4_rc=$?
[[ "$d4_rc" == 2 && "$d4_out" == *"invalid allowlist entry"* ]] \
    && a30 pass || a30 fail "disallow invalid grammar (rc=$d4_rc, out: $d4_out)"

# Non-gateway profile -> the require_gateway_profile guard.
d5_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/validconf/v.conf")" egresslock disallow v example.com:443 2>&1)"; d5_rc=$?
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
env ARCMOCK_PASSWD_HOME="$(conf_home "$AD30/m.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow m example.com:443 >/dev/null 2>&1
if [[ "$(stat -c %a "$AD30/m-allowlist")" == 644 ]] && ! grep -q 'example.com:443' "$AD30/m-allowlist"; then
    a30 pass
else
    a30 fail "R-030-1f1: disallow preserves allowlist mode (mode=$(stat -c %a "$AD30/m-allowlist" 2>/dev/null))"
fi

section_end arc30

# --- ARC-46: multi-arg allow/disallow + re-ensuring status line ----------
section_begin arc46 "ARC-46 allow/disallow batch"
a46() { assert "$@"; }

AD46="$TESTROOT/h46"; rm -rf "$AD46"; mkdir -p "$AD46"
cat > "$AD46/mm.conf" <<'EOF'
profile mm 10.199.23.0/24
    rule gateway-only
    gateway 10.199.23.2 3128 mm-allowlist
EOF
: > "$AD46/mm-allowlist"
mkdir -p "$STATE/ips" "$STATE/containers"
: > "$STATE/running/egresslock-gateway-mm"
echo "egresslock-mm" > "$STATE/containers/egresslock-gateway-mm.net"
echo "10.199.23.2" > "$STATE/containers/egresslock-gateway-mm.ip"
run46() { env ARCMOCK_PASSWD_HOME="$(conf_home "$AD46/mm.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

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
cat > "$AD46/mm.conf" <<'EOF'
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

section_end arc46

# --- BUG-002: allow appends to a no-trailing-newline allowlist -----------
section_begin arc_b2 "BUG-002 no-trailing-newline allow"
b2() { assert "$@"; }

# A starter-like allowlist whose last line is a comment with NO trailing
# newline (the shipped examples/main-allowlist pre-fix shape). A plain
# append would glue the first entry onto that comment and silently drop
# it; the append guard must write a leading newline first.
B2="$TESTROOT/hb2"; rm -rf "$B2"; mkdir -p "$B2"
cat > "$B2/nn.conf" <<'EOF'
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
run_b2() { env ARCMOCK_PASSWD_HOME="$(conf_home "$B2/nn.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

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
cat > "$B2/q3.conf" <<'EOF'
profile q3 10.199.26.0/24
    rule gateway-only
    gateway 10.199.26.2 3128 g-allowlist
EOF
mkdir -p "$STATE/ips" "$STATE/containers"
: > "$STATE/running/egresslock-gateway-q3"
echo "egresslock-q3" > "$STATE/containers/egresslock-gateway-q3.net"
echo "10.199.26.2" > "$STATE/containers/egresslock-gateway-q3.ip"
run_b2g() { env ARCMOCK_PASSWD_HOME="$(conf_home "$B2/q3.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
b2g_out="$(run_b2g allow q3 new.example 2>&1)"; b2g_rc=$?
if [[ "$b2g_rc" == 0 ]] \
   && grep -qxF 'new.example' "$B2/g-allowlist" \
   && ! grep -q '^old.example:443$' "$B2/g-allowlist" \
   && grep -q '^# keep old.example:443 glued here no newline$' "$B2/g-allowlist"; then
    b2 pass
else
    b2 fail "glued entry not healed; new allow clean (rc=$b2g_rc, out: $b2g_out)"
fi

section_end arc_b2

# --- ARC-52: verify fail-closed on foreign early FORWARD hooks -----------
section_begin arc52 "ARC-52 foreign hooks"
a52() { assert "$@"; }

A52="$TESTROOT/arc52"; rm -rf "$A52"; mkdir -p "$A52"
cat > "$A52/a52.conf" <<'EOF'
profile a52 10.199.31.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
EOF
run_a52() { env ARCMOCK_PASSWD_HOME="$(conf_home "$A52/a52.conf")" egresslock "$@"; }

# Baseline: ensured profile verifies green with nothing foreign hooked.
run_a52 ensure a52 >/dev/null 2>&1
a52_out="$(run_a52 verify a52 2>&1)"; a52_rc=$?
if [[ "$a52_rc" == 0 ]]; then
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

# D3 check 2: a foreign table's early forward chain fails
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

# verify --ensured inherits the check.
printf 'chain p_early {\n    type filter hook forward priority mangle; policy accept;\n}\n' \
    > "$STATE/nft/other_kit.p_early"
a52_out="$(run_a52 verify --ensured 2>&1)"; a52_rc=$?
rm -f "$STATE/nft/other_kit.p_early"
if [[ "$a52_rc" == 1 && "$a52_out" == *"other_kit"* ]]; then
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

section_end arc52
results_emit arc52

# --- EGL-98: stale-unpolicied detection (post-reboot window) --------------
# The podman network survives a reboot; the netns nft policy does not, so
# a raw `podman run --network egresslock-<p>` is unpolicied. D2: the stale
# predicate (network exists + profile chain absent) names the state on
# `verify <p>` and the `--ensured` sweep instead of the anchor bail or a
# silent skip. Signal-only; teardown'd/never-ensured profiles keep the
# silent skip (ARC-16-D3, narrowed).
section_begin e98 "EGL-98 stale-unpolicied" excluded
e98() { assert "$@"; }

E98="$TESTROOT/e98"; rm -rf "$E98"; mkdir -p "$E98"
cat > "$E98/e98.conf" <<'EOF'
profile e98 10.199.32.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
EOF
run_e98() { env ARCMOCK_PASSWD_HOME="$(conf_home "$E98/e98.conf")" egresslock "$@"; }

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

section_end e98
results_emit e98

# --- ARC-37: per-profile conf probe + list aggregation -------------------
section_begin arc37 "ARC-37 conf discovery"
a37() { assert "$@"; }

H37="$TESTROOT/h37"
rm -rf "$H37"; mkdir -p "$H37/.config/egresslock"
printf 'profile main 10.199.0.0/24\n    rule gateway-only\n    gateway 10.199.0.2 3128 main-allowlist\n' \
    > "$H37/.config/egresslock/main.conf"
: > "$H37/.config/egresslock/main-allowlist"
printf 'profile a 10.199.1.0/24\n' > "$H37/.config/egresslock/a.conf"
printf 'profile b 10.199.2.0/24\n' > "$H37/.config/egresslock/b.conf"

# 1. bare list aggregates every *.conf (main + a + b).
l_out="$(pty "env HOME='$H37' ARCMOCK_PASSWD_HOME='$H37' egresslock list 2>$TESTROOT/a37.err")"; l_rc=$?
if [[ "$l_rc" == 0 && "$l_out" == *"main"* && "$l_out" == *"a"* && "$l_out" == *"b"* \
      && "$(cat $TESTROOT/a37.err)" == *"using configs in"*"$H37/.config/egresslock"* ]]; then
    a37 pass
else
    a37 fail "bare list aggregates main+a+b (rc=$l_rc, out: $l_out, err: $(cat $TESTROOT/a37.err))"
fi

# 2. named probe: <profile>.conf wins over main.conf.
n_out="$(pty "env HOME='$H37' ARCMOCK_PASSWD_HOME='$H37' egresslock network a 2>$TESTROOT/a37n.err")"; n_rc=$?
[[ "$n_rc" == 0 && "$n_out" == *"egresslock-a"* && "$(cat $TESTROOT/a37n.err)" == *"using config"*"a.conf"* ]] \
    && a37 pass || a37 fail "named probe uses <profile>.conf (rc=$n_rc, out: $n_out, err: $(cat $TESTROOT/a37n.err))"

# 3. EGL-325: no main.conf fallback — a missing <profile>.conf is a
#    named miss, never a silent load of another file.
rm -f "$H37/.config/egresslock/b.conf"
n2_out="$(env HOME="$H37" ARCMOCK_PASSWD_HOME="$H37" egresslock network b 2>&1)"; n2_rc=$?
if [[ "$n2_rc" == 2 && "$n2_out" == *"no profile config: '$H37/.config/egresslock/b.conf' not found"* \
      && "$n2_out" != *"unknown profile 'b'"* ]]; then
    a37 pass
else
    a37 fail "named miss, no main.conf fallback (rc=$n2_rc, out: $n2_out)"
fi

# 4. EGL-325: a conf whose basename is not the profile it defines is
#    rejected fail-closed by the aggregate (and never silently adopted).
H37B="$TESTROOT/h37b"
rm -rf "$H37B"; mkdir -p "$H37B/.config/egresslock"
printf 'profile z 10.199.4.0/24\n' > "$H37B/.config/egresslock/notz.conf"
d_out="$(env HOME="$H37B" ARCMOCK_PASSWD_HOME="$H37B" egresslock list 2>&1)"; d_rc=$?
if [[ "$d_rc" == 2 && "$d_out" == *"config name/profile mismatch"* \
      && "$d_out" == *"notz.conf"* && "$d_out" == *"profile 'z'"* \
      && "$d_out" == *"must be named 'z.conf'"* ]]; then
    a37 pass
else
    a37 fail "basename/profile mismatch rejected (rc=$d_rc, out: $d_out)"
fi

# 5. bare teardown all uses main.conf only (never scans siblings).
printf 'profile b 10.199.2.0/24\n' > "$H37/.config/egresslock/b.conf"
env HOME="$H37" ARCMOCK_PASSWD_HOME="$H37" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure a >/dev/null 2>&1
env HOME="$H37" ARCMOCK_PASSWD_HOME="$H37" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure main >/dev/null 2>&1
env HOME="$H37" ARCMOCK_PASSWD_HOME="$H37" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock teardown all >/dev/null 2>&1
[[ -f "$STATE/networks/egresslock-a" ]] && a37 pass || a37 fail "bare teardown all leaves a.conf network alone"
[[ ! -f "$STATE/networks/egresslock-main" ]] && a37 pass || a37 fail "bare teardown all removed main's network"

# 6. bare verify --ensured aggregates every *.conf (a check, not a delete).
env HOME="$H37" ARCMOCK_PASSWD_HOME="$H37" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure a >/dev/null 2>&1
env HOME="$H37" ARCMOCK_PASSWD_HOME="$H37" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure b >/dev/null 2>&1
v_out="$(env HOME="$H37" ARCMOCK_PASSWD_HOME="$H37" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify --ensured 2>&1)"; v_rc=$?
[[ "$v_rc" == 0 && "$v_out" == *"verified (ensured)"* ]] \
    && a37 pass || a37 fail "bare verify --ensured aggregates (rc=$v_rc, out: $v_out)"

# 7. init hint teaches bare ensure only (no --config remediation).
i37_out="$(env HOME="$H37" ARCMOCK_PASSWD_HOME="$H37" egresslock init x 2>&1)"; i37_rc=$?
[[ "$i37_rc" == 0 && "$i37_out" == *"egresslock ensure x"* && "$i37_out" != *"--config"* ]] \
    && a37 pass || a37 fail "init hint teaches bare ensure (rc=$i37_rc, out: $i37_out)"

# 8. a named command never adopts a mismatched file: the lookup path is
#    exactly <profile>.conf (the only file there defines z, so a is a
#    clean named miss). Aggregate on that confdir fails with the named
#    basename rule (covered by test 4).
x37_out="$(env HOME="$H37B" ARCMOCK_PASSWD_HOME="$H37B" egresslock network z 2>&1)"; x37_rc=$?
if [[ "$x37_rc" == 2 && "$x37_out" == *"no profile config: '$H37B/.config/egresslock/z.conf' not found"* ]]; then
    a37 pass
else
    a37 fail "named lookup ignores a mismatched filename (rc=$x37_rc, out: $x37_out)"
fi

section_end arc37

# --- EGL-117: resolution disclosure — every time, TTY-independent --------
# D1: exactly one stderr resolution line per conf-resolving invocation,
# exact deterministic wording, never gated on stdout being a terminal.
section_begin egl117 "EGL-117 resolution disclosure"
a117() { assert "$@"; }

H117="$TESTROOT/h117"
rm -rf "$H117"; mkdir -p "$H117/.config/egresslock"
printf 'profile main 10.199.0.0/24\n' > "$H117/.config/egresslock/main.conf"
printf 'profile p2 10.199.1.0/24\n' > "$H117/.config/egresslock/p2.conf"

# 1. Named probe hit: exact line (named command under capture).
o="$(env HOME="$H117" ARCMOCK_PASSWD_HOME="$H117" egresslock network p2 2>$TESTROOT/e117a.err)"; rc=$?
[[ "$rc" == 0 && "$(cat $TESTROOT/e117a.err)" == "using config $H117/.config/egresslock/p2.conf" ]] \
    && a117 pass || a117 fail "named probe line exact (rc=$rc, err: $(cat $TESTROOT/e117a.err))"

# 2. EGL-325: no fallback line exists — a missing <profile>.conf is a
#    named miss that names only the checked path (no other file loaded,
#    no disclosure line for a conf that was never loaded).
o="$(env HOME="$H117" ARCMOCK_PASSWD_HOME="$H117" egresslock network p3 2>$TESTROOT/e117b.err)"; rc=$?
if [[ "$rc" == 2 \
      && "$(cat $TESTROOT/e117b.err)" == *"no profile config: '$H117/.config/egresslock/p3.conf' not found"* \
      && "$(cat $TESTROOT/e117b.err)" != *"using config"* ]]; then
    a117 pass
else
    a117 fail "named miss names the checked path only (rc=$rc, err: $(cat $TESTROOT/e117b.err))"
fi

# 2b. profile 'main' hitting main.conf is a plain named hit (main.conf IS
#     <main>.conf).
o="$(env HOME="$H117" ARCMOCK_PASSWD_HOME="$H117" egresslock network main 2>$TESTROOT/e117b2.err)"; rc=$?
[[ "$rc" == 0 && "$(cat $TESTROOT/e117b2.err)" == "using config $H117/.config/egresslock/main.conf" ]] \
    && a117 pass || a117 fail "main-on-main is a named hit (rc=$rc, err: $(cat $TESTROOT/e117b2.err))"

# 3. Aggregate: exact line with the conf count (N = *.conf files loaded).
o="$(env HOME="$H117" ARCMOCK_PASSWD_HOME="$H117" egresslock list 2>$TESTROOT/e117c.err)"; rc=$?
[[ "$rc" == 0 && "$(cat $TESTROOT/e117c.err)" == "using configs in $H117/.config/egresslock (2 profiles)" ]] \
    && a117 pass || a117 fail "aggregate line with count (rc=$rc, err: $(cat $TESTROOT/e117c.err))"

# 4. Exactly ONE resolution line per invocation.
lines="$(wc -l < $TESTROOT/e117c.err)"
[[ "$lines" == 1 ]] && a117 pass || a117 fail "exactly one resolution line (got $lines: $(cat $TESTROOT/e117c.err))"

# 5. Under a pipe an exported EGRESSLOCK_CONF no longer narrows the
#    sweep (EGL-325): the aggregate line survives command substitution
#    and still names the whole confdir.
o="$(env EGRESSLOCK_CONF="$H117/.config/egresslock/p2.conf" ARCMOCK_PASSWD_HOME="$H117" HOME="$H117" egresslock list 2>$TESTROOT/e117d.err | cat)"; rc=$?
if [[ "$rc" == 0 \
      && "$(cat $TESTROOT/e117d.err)" == "using configs in $H117/.config/egresslock (2 profiles)" ]]; then
    a117 pass
else
    a117 fail "EGRESSLOCK_CONF ignored under pipe (rc=$rc, err: $(cat $TESTROOT/e117d.err))"
fi

section_end egl117

# --- ARC-38: allow-host / disallow-host (conf mutation) ------------------
section_begin arc38 "ARC-38 allow-host"
a38() { assert "$@"; }

AH="$TESTROOT/h38"; rm -rf "$AH"; mkdir -p "$AH"
cat > "$AH/one.conf" <<'EOF'
profile one 10.199.10.0/24
    rule allow-host first.example.test:443
    rule gateway-only
    gateway 10.199.10.2 3128 one-allowlist
EOF
cat > "$AH/two.conf" <<'EOF'
profile two 10.199.11.0/24
    rule gateway-only
    gateway 10.199.11.2 3128 two-allowlist
EOF
: > "$AH/one-allowlist"; : > "$AH/two-allowlist"

# 1. allow-host inserts into the NAMED profile's conf (one.conf untouched).
cp "$AH/one.conf" "$AH/one.conf.before"
a_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/two.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host two git.example.test:2222 2>&1)"; a_rc=$?
if [[ "$a_rc" == 0 && "$a_out" == *"added: rule allow-host git.example.test:2222"* ]] \
   && grep -q 'rule allow-host git.example.test:2222' "$AH/two.conf" \
   && cmp -s "$AH/one.conf" "$AH/one.conf.before"; then
    a38 pass
else
    a38 fail "allow-host inserts rule into the named profile's conf (rc=$a_rc, out: $a_out)"
fi

# 2. duplicate -> 'entry already present' + still ensures; no double-add.
a2_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/two.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host two git.example.test:2222 2>&1)"; a2_rc=$?
[[ "$a2_rc" == 0 && "$a2_out" == *"entry already present"* ]] \
    && a38 pass || a38 fail "duplicate allow-host (rc=$a2_rc, out: $a2_out)"
[[ "$(grep -c 'rule allow-host git.example.test:2222' "$AH/two.conf")" == 1 ]] \
    && a38 pass || a38 fail "duplicate did not double-add"

# 3. disallow-host removes the exact rule.
r_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/two.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow-host two git.example.test:2222 2>&1)"; r_rc=$?
if [[ "$r_rc" == 0 && "$r_out" == *"removed: rule allow-host git.example.test:2222"* ]] \
   && ! grep -q 'rule allow-host git.example.test:2222' "$AH/two.conf"; then
    a38 pass
else
    a38 fail "disallow-host removes the rule (rc=$r_rc, out: $r_out)"
fi

# 4. disallow-host of an absent rule -> exit 1, conf unchanged, no ensure.
r2_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/two.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow-host two git.example.test:2222 2>&1)"; r2_rc=$?
[[ "$r2_rc" == 1 && "$r2_out" == *"rule not present"* ]] \
    && a38 pass || a38 fail "disallow-host absent (rc=$r2_rc, out: $r2_out)"

# 5. malformed host:port -> exit 2, conf unchanged.
m_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/two.conf")" egresslock allow-host two 'bad entry' 2>&1)"; m_rc=$?
[[ "$m_rc" == 2 && "$m_out" == *"invalid allow-host entry"* ]] \
    && a38 pass || a38 fail "allow-host invalid grammar (rc=$m_rc, out: $m_out)"

# 6. leftover `rule public-only` (removed kind, EGL-153): allow-host
#    fails at PARSE — exit 2, unknown-kind error, conf unchanged.
printf 'profile pub 10.199.12.0/24\n    rule public-only\n' > "$AH/pub.conf"
p_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/pub.conf")" egresslock allow-host pub git.example.test:2222 2>&1)"; p_rc=$?
if [[ "$p_rc" == 2 && "$p_out" == *"unknown rule kind 'public-only'"* ]] && ! grep -q 'allow-host' "$AH/pub.conf"; then
    a38 pass
else
    a38 fail "allow-host on leftover public-only fails closed at parse (rc=$p_rc, out: $p_out)"
fi

# 7. non-gateway profile can take allow-host (no gateway guard).
printf 'profile d 10.199.13.0/24\n    rule allow-host git.example.test:443\n' > "$AH/d.conf"
dg_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/d.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host d cache.example.test:443 2>&1)"; dg_rc=$?
if [[ "$dg_rc" == 0 ]] && grep -q 'rule allow-host cache.example.test:443' "$AH/d.conf"; then
    a38 pass
else
    a38 fail "allow-host on non-gateway profile (rc=$dg_rc, out: $dg_out)"
fi

# 8. disallow-host only touches the named profile's conf (a same-named
#    rule in the sibling profile's conf is untouched).
cat > "$AH/p1.conf" <<'EOF'
profile p1 10.199.14.0/24
    rule allow-host git.example.test:2222
EOF
cat > "$AH/p2.conf" <<'EOF'
profile p2 10.199.15.0/24
    rule allow-host git.example.test:2222
EOF
cp "$AH/p2.conf" "$AH/p2.conf.before"
# EGL-296 D1a: the never-ensured revoke refusal — ensure first so the
# capture can prove chain/record agreement (the leg pins the file
# scoping, which still holds).
env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/p1.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure p1 >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/p1.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow-host p1 git.example.test:2222 >/dev/null 2>&1
p1_count="$(grep -c 'rule allow-host git.example.test:2222' "$AH/p1.conf")"
if [[ "$p1_count" == 0 ]] && cmp -s "$AH/p2.conf" "$AH/p2.conf.before"; then
    a38 pass
else
    a38 fail "disallow-host scoped to named profile (p1=$p1_count, p2 untouched: $(cmp -s "$AH/p2.conf" "$AH/p2.conf.before" && echo yes || echo no))"
fi

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
env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/pre.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure pre >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/pre.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
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
    env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/pre.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify pre

# R-038-1 finding 1b regression: disallow-host (the revocation path) must
# remove the rule from the enforced chain, not just the conf.
env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/pre.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow-host pre git.example.test:443 >/dev/null 2>&1
pre_chain_443_after="$(grep -c 'daddr 192.0.2.10 tcp dport 443' "$STATE/nft/egresslock.p_pre")"
pre_conf_443_after="$(grep -c 'rule allow-host git.example.test:443' "$AH/pre.conf")"
if [[ "$pre_chain_443_after" == 0 && "$pre_conf_443_after" == 0 ]]; then
    a38 pass
else
    a38 fail "R-038-1f1b: disallow-host revokes enforced rule (chain443=$pre_chain_443_after conf443=$pre_conf_443_after)"
fi
check "R-038-1f1b: fresh verify passes after disallow-host" 0 \
    env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/pre.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify pre

# R-038-1 finding 2 regression: regex near-collision host must NOT match.
# Use resolvable mock-DNS hosts so ensure passes after the conf write.
cat > "$AH/near.conf" <<'EOF'
profile near 10.199.17.0/24
    rule allow-host gitXexample.test:443
EOF
near_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/near.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host near git.example.test:443 2>&1)"; near_rc=$?
if [[ "$near_rc" == 0 && "$near_out" == *"added: rule allow-host git.example.test:443"* ]] \
   && grep -qF '    rule allow-host git.example.test:443' "$AH/near.conf" \
   && grep -qF '    rule allow-host gitXexample.test:443' "$AH/near.conf"; then
    a38 pass
else
    a38 fail "R-038-1f2: near-collision host not falsely matched (rc=$near_rc, out: $near_out)"
fi
# disallow of the near host must leave the exact-conflicting host alone.
env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/near.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow-host near git.example.test:443 >/dev/null 2>&1
if ! grep -qF '    rule allow-host git.example.test:443' "$AH/near.conf" \
    && grep -qF 'rule allow-host gitXexample.test:443' "$AH/near.conf"; then
    a38 pass
else
    a38 fail "R-038-1f2: disallow-host near-collision deletes the right line"
fi

section_end arc38

# --- ARC-31: denied filters allowlisted hosts ----------------------------
section_begin arc31 "ARC-31 denied filter"
a31() { assert "$@"; }

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
den_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD/gw.conf")" egresslock denied gw 2>&1)"; den_rc=$?
if [[ "$den_rc" == 0 && "$den_out" == *"blocked.example.test"* && "$den_out" != *"allowed.example.test"* \
      && "$(grep -c 'blocked.example.test' <<<"$den_out")" == 1 ]]; then
    a31 pass
else
    a31 fail "denied filters allowlisted host (rc=$den_rc, out: $den_out)"
fi

# 2. --all shows everything (pre-ARC-31 behavior).
all_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD/gw.conf")" egresslock denied gw --all 2>&1)"; all_rc=$?
[[ "$all_rc" == 0 && "$all_out" == *"allowed.example.test"* && "$all_out" == *"blocked.example.test"* ]] \
    && a31 pass || a31 fail "denied --all shows all (rc=$all_rc, out: $all_out)"

# 3. unknown flag -> exit 2.
b_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD/gw.conf")" egresslock denied gw --bogus 2>&1)"; b_rc=$?
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
ld_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD2/gw.conf")" egresslock denied gw 2>&1)"; ld_rc=$?
if [[ "$ld_rc" == 0 && "$ld_out" != *"sub.example.test"* && "$ld_out" != *"example.test"* \
      && "$ld_out" == *"other.example.net"* ]]; then
    a31 pass
else
    a31 fail "R-031-1f1: leading-dot allowlist filters subdomains+bare host (rc=$ld_rc, out: $ld_out)"
fi

section_end arc31

# --- ARC-41: denied surfaces plain-HTTP (GET/port-80) denials -----------
section_begin arc41 "ARC-41 denied HTTP-origin"
a41() { assert "$@"; }

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
g_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD3/gw.conf")" egresslock denied gw 2>&1)"; g_rc=$?
if [[ "$g_rc" == 0 && "$g_out" == *"deb.debian.org:80"* \
      && "$(grep -c 'deb.debian.org:80' <<<"$g_out")" == 1 ]]; then
    a41 pass
else
    a41 fail "GET denial emitted as host:80, de-duped (rc=$g_rc, out: $g_out)"
fi
all_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD3/gw.conf")" egresslock denied gw --all 2>&1)"; all_rc=$?
[[ "$all_rc" == 0 && "$all_out" == *"deb.debian.org:80"* && "$all_out" != *"allowed.example.test"* ]] \
    && a41 pass || a41 fail "--all union excludes non-DENIED rows (rc=$all_rc, out: $all_out)"

# 2. allow deb.debian.org:80 -> filtered denied no longer lists it (D3);
#    --all still does (raw log, pre-ARC-31).
printf 'deb.debian.org:80\n' >> "$AD3/gw-allowlist"
f_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD3/gw.conf")" egresslock denied gw 2>&1)"; f_rc=$?
[[ "$f_rc" == 0 && "$f_out" != *"deb.debian.org"* ]] \
    && a41 pass || a41 fail "D3: :80 allowlist hides :80 denial (rc=$f_rc, out: $f_out)"
all_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD3/gw.conf")" egresslock denied gw --all 2>&1)"
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
m_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD4/gw.conf")" egresslock denied gw 2>&1)"; m_rc=$?
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
ld_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD5/gw.conf")" egresslock denied gw 2>&1)"; ld_rc=$?
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
u_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD6/gw.conf")" egresslock denied gw 2>&1)"; u_rc=$?
if [[ "$u_rc" == 0 && "$(grep -c '^ok.example.test$' <<<"$u_out")" == 1 \
      && "$u_out" != *"bad.example.test"* && "$u_out" != *"::1"* ]]; then
    a41 pass
else
    a41 fail "non-HTTP/userinfo/IPv6/malformed skipped; CONNECT still listed (rc=$u_rc, out: $u_out)"
fi

section_end arc41

# --- ARC-42: denied time window (--days N, default 14) ------------------
section_begin arc42 "ARC-42 denied window"
a42() { assert "$@"; }

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
w_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD7/gw.conf")" egresslock denied gw 2>&1)"; w_rc=$?
if [[ "$w_rc" == 0 && "$w_out" == *"recent.example.test"* && "$w_out" != *"old.example.test"* ]]; then
    a42 pass
else
    a42 fail "default 14-day window hides old denial (rc=$w_rc, out: $w_out)"
fi
z_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD7/gw.conf")" egresslock denied gw --days 0 2>&1)"; z_rc=$?
[[ "$z_rc" == 0 && "$z_out" == *"old.example.test"* && "$z_out" == *"recent.example.test"* ]] \
    && a42 pass || a42 fail "--days 0 shows full log (rc=$z_rc, out: $z_out)"
za_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD7/gw.conf")" egresslock denied gw --all --days 0 2>&1)"; za_rc=$?
[[ "$za_rc" == 0 && "$za_out" == *"old.example.test"* && "$za_out" == *"recent.example.test"* ]] \
    && a42 pass || a42 fail "--all --days 0 raw union (rc=$za_rc, out: $za_out)"

# 2. old-only log: stdout empty rc 0, stderr carries the D3 note.
cat > "$STATE/containers-egresslock-gateway-gw.access.log" <<EOF
$old_sec.000    120 10.199.40.5 TCP_DENIED/403 0 CONNECT old.example.test:443 - HIER_NONE/- -
EOF
o_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD7/gw.conf")" egresslock denied gw 2>/dev/null)"; o_rc=$?
o_err="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD7/gw.conf")" egresslock denied gw 2>&1 >/dev/null)"
if [[ "$o_rc" == 0 && -z "$o_out" && "$o_err" == *"no denials in the last 14 days"* && "$o_err" == *"--days 0"* ]]; then
    a42 pass
else
    a42 fail "old-only log: empty stdout + D3 stderr note (rc=$o_rc, out=[$o_out], err=[$o_err])"
fi

# 3. empty/missing log: the stdout message, NO note.
: > "$STATE/containers-egresslock-gateway-gw.access.log"
e_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD7/gw.conf")" egresslock denied gw 2>&1)"; e_rc=$?
[[ "$e_rc" == 0 && "$e_out" == *"no gateway log"* && "$e_out" != *"no denials in the last"* ]] \
    && a42 pass || a42 fail "empty log: gateway message, no note (rc=$e_rc, out: $e_out)"

# 4. --days validation: missing value / negative / leading zero / unknown flag -> exit 2.
cat > "$STATE/containers-egresslock-gateway-gw.access.log" <<EOF
$now_sec.000    120 10.199.40.5 TCP_DENIED/403 0 CONNECT recent.example.test:443 - HIER_NONE/- -
EOF
for bad in "--days" "--days -1" "--days 014" "--bogus"; do
    # shellcheck disable=SC2086
    b_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD7/gw.conf")" egresslock denied gw $bad 2>&1)"; b_rc=$?
    [[ "$b_rc" == 2 ]] && a42 pass || a42 fail "denied $bad -> exit 2 (rc=$b_rc, out: $b_out)"
done

# 5. flag order equivalence.
f1="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD7/gw.conf")" egresslock denied gw --all --days 1 2>&1)"
f2="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD7/gw.conf")" egresslock denied gw --days 1 --all 2>&1)"
[[ "$f1" == "$f2" && "$f1" == *"recent.example.test"* ]] \
    && a42 pass || a42 fail "flag order equivalence (f1=[$f1] f2=[$f2])"

section_end arc42

# --- ARC-43: allowlist — print the allowlist file raw ---------------------
section_begin arc43 "ARC-43 allowlist"
a43() { assert "$@"; }

AD8="$TESTROOT/h43"; rm -rf "$AD8"; mkdir -p "$AD8"
cat > "$AD8/gw.conf" <<'EOF'
profile gw 10.199.50.0/24
    rule gateway-only
    gateway 10.199.50.2 3128 gw-allowlist
EOF
printf '# comment line\nexample.test\nother.test:8443\n' > "$AD8/gw-allowlist"
: > "$STATE/running/egresslock-gateway-gw"

# 1. prints the file bytes (comments included); path stays off stdout.
al_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/gw.conf")" egresslock allowlist gw 2>/dev/null)"; al_rc=$?
al_err="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/gw.conf")" egresslock allowlist gw 2>&1 >/dev/null)"
if [[ "$al_rc" == 0 && "$al_out" == *"# comment line"* && "$al_out" == *"example.test"* \
      && "$al_out" == *"other.test:8443"* && "$al_err" != *"gw-allowlist"* ]]; then
    a43 pass
else
    a43 fail "allowlist prints raw file, path not on stdout (rc=$al_rc, out: $al_out)"
fi

# 2. empty allowlist -> empty stdout (payload contract), rc 0; the
#    resolution line is stderr-only (EGL-117) and must not bleed here.
: > "$AD8/gw-allowlist"
ae_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/gw.conf")" egresslock allowlist gw 2>/dev/null)"; ae_rc=$?
[[ "$ae_rc" == 0 && -z "$ae_out" ]] \
    && a43 pass || a43 fail "allowlist empty allowlist (rc=$ae_rc, out: [$ae_out])"

# 3. comments-only starter -> the comment bytes, no invented entries.
printf '# main-allowlist — starter\n# EMPTY by design\n' > "$AD8/gw-allowlist"
ac_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/gw.conf")" egresslock allowlist gw 2>&1)"; ac_rc=$?
[[ "$ac_rc" == 0 && "$ac_out" == *"# main-allowlist"* && "$ac_out" != *"gateway-only"* ]] \
    && a43 pass || a43 fail "allowlist comments-only (rc=$ac_rc, out: $ac_out)"

# 4. extra arg -> exit 2.
ax_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/gw.conf")" egresslock allowlist gw extra 2>&1)"; ax_rc=$?
[[ "$ax_rc" == 2 && "$ax_out" == *"usage"* ]] \
    && a43 pass || a43 fail "allowlist extra arg (rc=$ax_rc, out: $ax_out)"

# ARC-45: the old `allowed` name is now an unknown command (no alias).
old_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/gw.conf")" egresslock allowed gw 2>&1)"; old_rc=$?
[[ "$old_rc" == 2 && "$old_out" == *"unknown command"* ]] \
    && a43 pass || a43 fail "ARC-45: old 'allowed' is unknown (rc=$old_rc, out: $old_out)"

# 5. non-gateway profile -> fail closed naming gateway.
cat > "$AD8/plain.conf" <<'EOF'
profile plain 10.199.51.0/24
    rule allow-host plain.example.test:443
EOF
an_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/plain.conf")" egresslock allowlist plain 2>&1)"; an_rc=$?
[[ "$an_rc" != 0 && "$an_out" == *"gateway"* ]] \
    && a43 pass || a43 fail "allowlist non-gateway fails closed (rc=$an_rc, out: $an_out)"

# 6. missing allowlist file -> fail closed naming the path.
mkdir -p "$AD8/missdir"
cat > "$AD8/missdir/gw.conf" <<'EOF'
profile gw 10.199.52.0/24
    rule gateway-only
    gateway 10.199.52.2 3128 nope-allowlist
EOF
am_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/missdir/gw.conf")" egresslock allowlist gw 2>&1)"; am_rc=$?
[[ "$am_rc" != 0 && "$am_out" == *"nope-allowlist"* ]] \
    && a43 pass || a43 fail "allowlist missing file names path (rc=$am_rc, out: $am_out)"

section_end arc43

# --- ARC-44: proxy-env tokens + network single-token output -------------
section_begin arc44 "ARC-44 proxy-env tokens"
a44() { assert "$@"; }

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
ip_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD9/gw.conf")" egresslock proxy-env gw proxyip 2>/dev/null)"; ip_rc=$?
port_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD9/gw.conf")" egresslock proxy-env gw proxyport 2>/dev/null)"; port_rc=$?
np_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD9/gw.conf")" egresslock proxy-env gw noproxy 2>/dev/null)"; np_rc=$?
[[ "$ip_rc" == 0 && "$ip_out" == "10.199.60.2" && "$port_rc" == 0 && "$port_out" == "3128" \
  && "$np_rc" == 0 && "$np_out" == "localhost,127.0.0.1,api.local" ]] \
    && a44 pass || a44 fail "proxy-env tokens exact (ip=[$ip_out] port=[$port_out] np=[$np_out])"

# 2. bare proxy-env still prints the six assignment lines (back-compat);
#    the EGL-117 resolution line is stderr-only (captured separately).
full_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD9/gw.conf")" egresslock proxy-env gw 2>"$TESTROOT/e44.err")"; full_rc=$?
if [[ "$full_rc" == 0 && "$full_out" == *"HTTP_PROXY=http://10.199.60.2:3128"* \
      && "$full_out" == *"NO_PROXY=localhost,127.0.0.1,api.local"* \
      && "$(grep -c '=' <<<"$full_out")" == 6 \
      && "$(cat $TESTROOT/e44.err)" == *"using config "*"gw.conf"* ]]; then
    a44 pass
else
    a44 fail "bare proxy-env six lines (rc=$full_rc, out: $full_out, err: $(cat $TESTROOT/e44.err))"
fi

# 3. unknown token / extra arg -> exit 2, no assignment lines on stdout.
for bad in "bogus" "proxyip extra"; do
    # shellcheck disable=SC2086
    t_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD9/gw.conf")" egresslock proxy-env gw $bad 2>/dev/null)"; t_rc=$?
    [[ "$t_rc" == 2 && -z "$t_out" ]] \
        && a44 pass || a44 fail "proxy-env token '$bad' exit 2 empty stdout (rc=$t_rc, out: [$t_out])"
done

# 4. non-gateway + token fails closed; non-gateway bare stays rc 0 empty.
ng_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/plain.conf")" egresslock proxy-env plain proxyip 2>&1)"; ng_rc=$?
[[ "$ng_rc" != 0 && "$ng_out" == *"gateway"* ]] \
    && a44 pass || a44 fail "proxy-env non-gateway token fails closed (rc=$ng_rc, out: $ng_out)"
ngb_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/plain.conf")" egresslock proxy-env plain 2>/dev/null)"; ngb_rc=$?
[[ "$ngb_rc" == 0 && -z "$ngb_out" ]] \
    && a44 pass || a44 fail "proxy-env non-gateway bare rc 0 empty (rc=$ngb_rc, out: [$ngb_out])"

# 5. network is a single safe token; extra arg -> exit 2.
net_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD9/gw.conf")" egresslock network gw 2>/dev/null)"; net_rc=$?
netx_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD9/gw.conf")" egresslock network gw extra 2>&1)"; netx_rc=$?
[[ "$net_rc" == 0 && "$net_out" == "egresslock-gw" && "$netx_rc" == 2 ]] \
    && a44 pass || a44 fail "network single token + extra-arg guard (net=[$net_out] rc=$net_rc xrc=$netx_rc)"

section_end arc44

# --- EGL-246: proxy-env --out[=<path>] out-file verb ---------------------
# Fresh verb that writes the six assignments atomically as mode 0600
# and prints the target path on stdout (D4/D5); bare --out targets the
# account runtime dir (D2), --out=<path> is allowed elsewhere with
# parent -d/-O/-w checks and no implicit mkdir (D11); unusable shapes
# fail closed named rc 1 (D3/D6), argv-shape errors rc 2 named (D14).
section_begin egl246 "EGL-246 proxy-env --out out-file verb"
a246() { assert "$@"; }

# EGL-246 section-local engine launcher (R-EGL-246-3 carry, scoped per
# the tests/lib.sh note): an absolute entry standing above this
# section's PATH shims, so PATH-shimmed cases resolve the tree-under-
# test engine, never a host or prefix-relative binary. PATH is
# restored before section end — no battery-wide radius.
E246_LBIN="$TESTROOT/egl246-launcher"
mkdir -p "$E246_LBIN"
printf '#!/bin/bash\nexec %s/egresslock "$@"\n' "$TREE_ROOT" > "$E246_LBIN/egresslock"
chmod +x "$E246_LBIN/egresslock"
E246_PATH_SAVE="$PATH"
PATH="$E246_LBIN:$PATH"

E246="$TESTROOT/e246"; rm -rf "$E246"; mkdir -p "$E246/run"
cat > "$E246/gw.conf" <<'EOF'
profile gw 10.199.70.0/24
    rule gateway-only
    gateway 10.199.70.2 3128 gw-allowlist
    no-proxy api.local
EOF
cat > "$E246/egl246fall.conf" <<'EOF'
profile egl246fall 10.199.72.0/24
    rule gateway-only
    gateway 10.199.72.2 3128 gw-allowlist
EOF
: > "$E246/gw-allowlist"
cat > "$E246/plain.conf" <<'EOF'
profile plain 10.199.71.0/24
    rule allow-host plain.example.test:443
EOF

# 1. default write with XDG_RUNTIME_DIR set: rc 0, one stdout line =
#    $XDG_RUNTIME_DIR/egresslock-proxy-<p>.env, mode 600, content
#    byte-identical to the bare form (D4/D5).
d1_out="$(env XDG_RUNTIME_DIR="$E246/run" ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out 2>"$E246/d1.err")"; d1_rc=$?
bare_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" egresslock proxy-env gw 2>/dev/null)"
if [[ "$d1_rc" == 0 && "$d1_out" == "$E246/run/egresslock-proxy-gw.env" \
      && "$(stat -c %a "$E246/run/egresslock-proxy-gw.env")" == "600" \
      && "$bare_out" == "$(cat "$E246/run/egresslock-proxy-gw.env")" ]]; then
    a246 pass
else
    a246 fail "default --out write (rc=$d1_rc, out: $d1_out, mode: $(stat -c %a "$E246/run/egresslock-proxy-gw.env" 2>/dev/null || echo missing))"
fi

# 2. explicit --out=<path>: rc 0, stdout = path, mode 600.
d2_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/run/explicit.env" 2>/dev/null)"; d2_rc=$?
[[ "$d2_rc" == 0 && "$d2_out" == "$E246/run/explicit.env" \
   && "$(stat -c %a "$E246/run/explicit.env")" == "600" ]] \
    && a246 pass || a246 fail "explicit --out=<path> (rc=$d2_rc, out: $d2_out)"

# 3. regeneration: a no-proxy change is reflected on re-run (no stale file).
out_after="$(cat "$E246/run/egresslock-proxy-gw.env")"
mkdir -p "$E246/regen"
ln -sfn "$E246/gw-allowlist" "$E246/regen/gw-allowlist"
sed 's/no-proxy api.local/no-proxy api.local,other.local/' "$E246/gw.conf" > "$E246/regen/gw.conf"
regen_out="$(env XDG_RUNTIME_DIR="$E246/run" ARCMOCK_PASSWD_HOME="$(conf_home "$E246/regen/gw.conf")" \
    egresslock proxy-env gw --out 2>/dev/null)"; regen_rc=$?
if [[ "$regen_rc" == 0 && "$regen_out" == "$E246/run/egresslock-proxy-gw.env" \
      && ! "$out_after" == *"other.local"* \
      && "$(cat "$E246/run/egresslock-proxy-gw.env")" == *"other.local"* ]]; then
    a246 pass
else
    a246 fail "regeneration reflects the conf change (rc=$regen_rc, out: $regen_out, after: $out_after)"
fi

# 4. fail closed, named, nothing written: missing dir; a path component
#    that is a file; read-only target dir.
m_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" egresslock proxy-env gw --out="$E246/absent/f.env" 2>&1)"; m_rc=$?
[[ "$m_rc" == 1 && "$m_out" == *"'$E246/absent'"*"missing or not a directory"* && "$m_out" == *"fail closed"* && -z "$(find "$E246/absent" 2>/dev/null)" ]] \
    && a246 pass || a246 fail "missing dir fail closed (rc=$m_rc, out: $m_out)"
touch "$E246/afile"
f_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" egresslock proxy-env gw --out="$E246/afile/f.env" 2>&1)"; f_rc=$?
[[ "$f_rc" == 1 && "$f_out" == *"missing or not a directory"* && "$f_out" == *"fail closed"* ]] \
    && a246 pass || a246 fail "file-as-dir fail closed (rc=$f_rc, out: $f_out)"
mkdir -p "$E246/rowdo"; chmod 500 "$E246/rowdo"
r_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" egresslock proxy-env gw --out="$E246/rowdo/r.env" 2>&1)"; r_rc=$?
[[ "$r_rc" == 1 && "$r_out" == *"'$E246/rowdo'"*"not owned or writable"* && "$r_out" == *"fail closed"* && ! -e "$E246/rowdo/r.env" ]] \
    && a246 pass || a246 fail "read-only dir fail closed (rc=$r_rc, out: $r_out)"
chmod 700 "$E246/rowdo"

# 5. non-gateway profile -> rc 1 named, no file (D6); bare stays rc 0 empty.
ng_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/plain.conf")" egresslock proxy-env plain --out 2>&1)"; ng_rc=$?
[[ "$ng_rc" == 1 && "$ng_out" == *"no gateway"* && "$ng_out" == *"proxy-env --out"* ]] \
    && a246 pass || a246 fail "non-gateway --out fail closed (rc=$ng_rc, out: $ng_out)"
ngb_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/plain.conf")" egresslock proxy-env plain 2>/dev/null)"; ngb_rc=$?
[[ "$ngb_rc" == 0 && -z "$ngb_out" ]] \
    && a246 pass || a246 fail "non-gateway bare unchanged (rc=$ngb_rc, out: [$ngb_out])"

# 6. rc-2 shape errors, empty stdout (D14).
for bad in "gw --out sp.out" "gw --out=" "gw proxyip --out" "gw --out --out" "gw --out=$E246/run/a.env extra" "gw nope --out"; do
    # shellcheck disable=SC2086
    s_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" egresslock proxy-env $bad 2>/dev/null)"; s_rc=$?
    [[ "$s_rc" == 2 && -z "$s_out" ]] \
        && a246 pass || a246 fail "rc-2 shape '$bad' (rc=$s_rc, out: [$s_out])"
done
sp_err="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" egresslock proxy-env gw --out sp.out 2>&1)"
# F3 rework: stderr now opens with the EGL-117 resolution disclosure —
# match the D14 sentence after it.
sp_err="$(printf %s "$sp_err" | grep -v "^using config")"
# (the D14 message follows the resolution disclosure line)
[[ "$sp_err" == *"--out takes no separate argument (use --out=<path>)."* ]] \
    && a246 pass || a246 fail "space form named error (out: $sp_err)"
eq_err="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" egresslock proxy-env gw --out= 2>&1)"
[[ "$eq_err" == *"--out= requires a path."* ]] \
    && a246 pass || a246 fail "--out= named error (out: $eq_err)"
[[ ! -e "$E246/sp.out" ]] && a246 pass || a246 fail "space form must not write"

# 7. malformed --out argv with a bogus conf -> rc 2 before any conf read
#    (the EGL-228 property).
for bad in "gw --out missing.out" "gw --out="; do
    # shellcheck disable=SC2086
    b_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/bogus-nonexistent.conf")" egresslock proxy-env $bad 2>&1)"; b_rc=$?
    [[ "$b_rc" == 2 && "$b_out" != *"config file not found"* ]] \
        && a246 pass || a246 fail "pre-conf rc-2 '$bad' (rc=$b_rc, out: $b_out)"
done

# 8. unset-XDG_RUNTIME_DIR fallback (/run/user/$(id -u)) — only assert
# when that dir exists on this runner, else a named skip.
# F4 (R-EGL-246-3): when the file already exists, this sub-case SKIPS
# (the refusal contract for a pre-existing runtime file is pinned by
# case 15 on a unique synthetic profile — this sub-case never
# overwrites a real account file).
if [[ -d "/run/user/$(id -u)" ]]; then
    if [[ -e "/run/user/$(id -u)/egresslock-proxy-gw.env" ]]; then
        skip "egl246-fallback-collision-gw" "F4: pre-existing /run/user/$(id -u)/egresslock-proxy-gw.env — overwrite sub-case refused here (case 15 pins the refusal contract on a unique synthetic profile)"
    else
        u_out="$(env -u XDG_RUNTIME_DIR ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
            egresslock proxy-env gw --out 2>/dev/null)"; u_rc=$?
        [[ "$u_rc" == 0 && "$u_out" == "/run/user/$(id -u)/egresslock-proxy-gw.env" \
           && "$(stat -c %a "/run/user/$(id -u)/egresslock-proxy-gw.env")" == "600" ]] \
            && a246 pass || a246 fail "unset fallback (rc=$u_rc, out: $u_out)"
        rm -f "/run/user/$(id -u)/egresslock-proxy-gw.env"
    fi
else
    skip "egl246-fallback-dir-absent" "unset-XDG_RUNTIME_DIR fallback not asserted: /run/user/$(id -u) absent on this runner"
fi

# 9. D14 edges: relative --out=rel.env in a scratch cwd (parent `.`);
#    an existing directory target (incl. trailing slash) fails closed.
mkdir -p "$E246/cwd"
rel_out="$(cd "$E246/cwd" && env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out=rel.env 2>/dev/null)"; rel_rc=$?
[[ "$rel_rc" == 0 && "$rel_out" == "rel.env" \
   && "$(stat -c %a "$E246/cwd/rel.env")" == "600" ]] \
    && a246 pass || a246 fail "relative out path (rc=$rel_rc, out: $rel_out)"
dr_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" egresslock proxy-env gw --out="$E246/run" 2>&1)"; dr_rc=$?
ds_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" egresslock proxy-env gw --out="$E246/run/" 2>&1)"; ds_rc=$?
[[ "$dr_rc" == 1 && "$dr_out" == *"'$E246/run'"*"is a directory"* \
   && "$ds_rc" == 1 && "$ds_out" == *"is a directory"* ]] \
    && a246 pass || a246 fail "directory target fail closed (rc=$dr_rc/$ds_rc)"
# No tempfile litter beside the targets after all failure shapes.
litter="$(find "$E246/run" -name 'egresslock-proxy-*' ! -name '*.env' 2>/dev/null)"
litter="${litter}$(find "$E246" -maxdepth 1 -name '*.env.*' 2>/dev/null)"
[[ -z "$litter" ]] && a246 pass || a246 fail "temp litter after failures: $litter"

# 10. R-EGL-246-3 F1: a producer write failure fails closed — rc 1, EMPTY
#     stdout, OLD file contents preserved, no temp litter. The hermetic
#     stand-in is a PATH shim on `chmod` (the engine's mode step between
#     temp creation and rename): it removes the temp, so chmod and the
#     F2/`-T` rename fail; the write guard dies named rc 1. The shim's kill
#     switch matches only this case's exact temp name. The old file must
#     survive intact.
mkdir -p "$E246/shim"
cat > "$E246/shim/chmod" <<'SHIM'
#!/bin/bash
# model a producer failure: make the temp disappear before the real
# chmod can succeed — the write guard must see the failure
mode="$1"; file="$2"
if [[ -n "${E246_FAIL_TEMP:-}" && "$file" == "${E246_FAIL_TEMP}"* ]]; then
    rm -f "$file"
fi
exec /usr/bin/chmod "$mode" "$file"
SHIM
chmod +x "$E246/shim/chmod"
: > "$E246/run/preserve.env"
f1_out="$(env PATH="$E246/shim:$PATH" E246_FAIL_TEMP="$E246/run/preserve.env" \
    ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" egresslock proxy-env gw \
    --out="$E246/run/preserve.env" 2>"$E246/f1.err")"; f1_rc=$?
[[ "$f1_rc" == 1 && -z "$f1_out" && "$(tail -1 "$E246/f1.err" 2>/dev/null)" == *"cannot set 0600"* ]] \
    && a246 pass || a246 fail "F1 temp-loss before chmod (rc=$f1_rc, out: [$f1_out], err: $(tail -1 "$E246/f1.err" 2>/dev/null))"
rm -f "$E246/shim/chmod"
# The write-guard's second leg: a real (injected) producer failure —
# the old six-echo producer under RLIMIT_FSIZE=1 tripped on the
# escalation; the fixed single-printf producer is smaller, so the
# FSIZE probe may legitimately NOT trip on this runner: that leg is
# then the named skip (the real failure contract is the chmod-shim
# leg above). When it DOES trip, the guard must fail closed rc 1 with
# empty stdout and the old file preserved.
f2_out="$(bash -c 'ulimit -f 1 2>/dev/null; exec env ARCMOCK_PASSWD_HOME="$(conf_home "$1")" egresslock proxy-env "$2" --out="$3"' _ "$E246/gw.conf" gw "$E246/run/preserve.env" 2>"$E246/f2.err")"; f2_rc=$?
# note: `ulimit -f 1` = one 512-byte block — the six assignments are
# smaller, so this probe is expected NOT to trip on most runners
# (planned; the named skip below is deliberate). A runner whose
# block-size arithmetic trips it still gets the full contract.
if [[ "$f2_rc" == 1 ]]; then
    [[ -z "$f2_out" && "$(cat "$E246/run/preserve.env" 2>/dev/null)" == "" && -z "$(find "$E246/run" -name 'preserve.env.*' 2>/dev/null)" ]] \
        && a246 pass || a246 fail "F1 FSIZE producer failure contract (rc=$f2_rc, out: $f2_out, contents: $(cat "$E246/run/preserve.env" 2>/dev/null | head -c 60))"
else
    skip "egl246-fsize-under-limit" "RLIMIT_FSIZE probe did not trip (six assignments < the block limit); the chmod-shim leg above is the producer-failure contract"
fi
rm -f "$E246/run/preserve.env"
rmdir "$E246/shim" 2>/dev/null || rm -rf "$E246/shim"

# 11. R-EGL-246-3 F1 (control leg, deterministic): a target that is a
#     directory is refused named and the pre-existing contents of the
#     shared-F4-style old files elsewhere are never touched — this is
#     the plain control the escalation ran (ordinary failure paths
#     preserve old state; the late-arrival variant is case 12).
mkdir -p "$E246/run/mvdir.env"
c_full="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" egresslock proxy-env gw --out="$E246/run/mvdir.env" 2>&1)"; c_rc=$?
c_out="$(printf %s "$c_full" | grep -v "^using config")"
[[ "$c_rc" == 1 && "$c_out" == *"target '$E246/run/mvdir.env' is a directory"* ]] \
    && a246 pass || a246 fail "F1 control mv-target-is-dir (rc=$c_rc, out: $c_out)"
rmdir "$E246/run/mvdir.env"

# 12. R-EGL-246-3 F2: a LATE directory target (appears between the
#     pre-write checks and the rename, via a scheduler shim that
#     pre-creates the target right before the real mv runs) must not
#     produce rc 0 at the requested path — the shim's dir-creation is
#     the modeled scheduling change; the engine's late-arrival check
#     then refuses named.
mkdir -p "$E246/shim"
cat > "$E246/shim/mv" <<SHIM
#!/bin/bash
# scheduling shim: model a late directory arrival at the target, then
# run the real mv unchanged
mkdir -p "\${E246_LATE_DIR:?}"
exec /usr/bin/mv "\$@"
SHIM
chmod +x "$E246/shim/mv"
late_full="$(env PATH="$E246/shim:$PATH" E246_LATE_DIR="$E246/run/late.env" \
    ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" egresslock proxy-env gw --out="$E246/run/late.env" 2>&1)"; late_rc=$?
late_out="$(printf %s "$late_full" | grep -v "^using config")"
[[ "$late_rc" == 1 && "$late_out" == *"cannot write '$E246/run/late.env'"* ]] \
    && a246 pass || a246 fail "F2 late directory arrival (rc=$late_rc, out: $late_out)"
# the temp must be cleaned and no egresslock-proxy-* litter remains
late_litter="$(find "$E246/run" \( -name 'late.env.*' -o \( -type f -name '*XXXXXX*' \) \) 2>/dev/null)"
[[ -z "$late_litter" ]] && a246 pass || a246 fail "F2 temp litter after late dir: $late_litter"
rm -f "$E246/shim/mv"

# 13. R-EGL-246-3 F2: a LATE directory SYMLINK (swapped after the pre-write
#     checks) must never land the env file inside its referent. `mv -T`
#     atomically replaces the link itself with a 0600 file, leaving the
#     referent empty; or the engine refuses first (rc 1 named). The
#     scheduling-dependent branch is fine — the D15/Q6 contract holds:
#     the referent never holds the content.
mkdir -p "$E246/shim"
cat > "$E246/shim/mv" <<SHIM
#!/bin/bash
ln -sfn "$E246/run/late-symdir" "$E246/run/symlink.env"
exec /usr/bin/mv "\$@"
SHIM
chmod +x "$E246/shim/mv"
mkdir -p "$E246/run/late-symdir"
sy_full="$(env PATH="$E246/shim:$PATH" ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/run/symlink.env" 2>&1)"; sy_rc=$?
sy_out="$(printf %s "$sy_full" | grep -v "^using config")"
sy_ref_files="$(find "$E246/run/late-symdir" -type f 2>/dev/null)"
sy_landed_ok=1
if [[ "$sy_rc" == 0 ]]; then
    [[ "$(stat -c %F "$E246/run/symlink.env" 2>/dev/null)" == "regular file" \
       && "$(stat -c %a "$E246/run/symlink.env" 2>/dev/null)" == "600" ]] || sy_landed_ok=0
else
    [[ "$sy_rc" == 1 && "$sy_out" == *"cannot write '$E246/run/symlink.env'"* ]] || sy_landed_ok=0
fi
[[ -z "$sy_ref_files" && "$sy_landed_ok" == 1 ]] \
    && a246 pass || a246 fail "F2 late symlink arrival (rc=$sy_rc, out: $sy_out, referent: $(ls -A "$E246/run/late-symdir" 2>/dev/null))"
sy_litter="$(find "$E246/run" -name 'symlink.env.*' 2>/dev/null)"
[[ -z "$sy_litter" ]] && a246 pass || a246 fail "F2 temp litter after late symlink: $sy_litter"
rm -f "$E246/shim/mv" "$E246/run/symlink.env"
rm -rf "$E246/run/late-symdir"
rm -f "$E246/run/symlink.env"

# 14. R-EGL-246-3 F3: quoted EMPTY arguments are real positionals —
#     every shape here is a usage error rc 2 with EMPTY stdout (the
#     old non-empty-value checks let these through to a malformed
#     write or a six-line print). Direct array invocation preserves
#     the empty strings (no word-split loop).
e246_empty() { env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" egresslock proxy-env "$@"; }
# empty as the last arg after --out=<path>
arr=(gw "--out=$E246/run/e3a.env" "")
em_out="$(e246_empty "${arr[@]}" 2>&1)"; em_rc=$?
[[ "$em_rc" == 2 && "$em_out" == *"at most one argument"* && ! -e "$E246/run/e3a.env" ]] \
    && a246 pass || a246 fail "F3 --out=<path> + empty arg (rc=$em_rc, out: $em_out)"
# empty BEFORE the --out form (resolves as a phantom token position)
arr2=(gw "" "--out=$E246/run/e3b.env")
em2_out="$(e246_empty "${arr2[@]}" 2>&1)"; em2_rc=$?
[[ "$em2_rc" == 2 && "$em2_out" == *"at most one argument"* && ! -e "$E246/run/e3b.env" ]] \
    && a246 pass || a246 fail "F3 empty arg before --out= (rc=$em2_rc, out: $em2_out)"
# empty as the token position with --out following (the R-EGL-246-3
# probe shape that printed the six lines under the old checks)
arr3=(gw "" --out)
em3_out="$(e246_empty "${arr3[@]}" 2>&1)"; em3_rc=$?
[[ "$em3_rc" == 2 && "$em3_out" == *"at most one argument"* ]] \
    && a246 pass || a246 fail "F3 empty token + --out (rc=$em3_rc, out: $em3_out)"
# trailing empty argument after the bare form: rc 2, never the six lines
arr4=(gw "" "")
em4_out="$(e246_empty "${arr4[@]}" 2>&1)"; em4_rc=$?
[[ "$em4_rc" == 2 && "$em4_out" == *"at most one argument"* ]] \
    && a246 pass || a246 fail "F3 bare form + extra empty (rc=$em4_rc, out: $em4_out)"
# empty string in the token position: the named unknown-token error
arr4b=(gw "")
em4b_out="$(e246_empty "${arr4b[@]}" 2>&1)"; em4b_rc=$?
[[ "$em4b_rc" == 2 && "$em4b_out" == *"unknown proxy-env token"* ]] \
    && a246 pass || a246 fail "F3 empty token (rc=$em4b_rc, out: $em4b_out)"
# space form with a PRESENT-but-empty next argument: the specific
# D14 space-form message (the shepherding message outranks the generic
# count error — same as the non-empty space form)
arr5=(gw --out "")
em5_out="$(e246_empty "${arr5[@]}" 2>&1)"; em5_rc=$?
[[ "$em5_rc" == 2 && "$em5_out" == *"--out takes no separate argument"* ]] \
    && a246 pass || a246 fail "F3 --out + present-empty arg (rc=$em5_rc, out: $em5_out)"
# F3 pre-conf order: malformed empty-arg shapes with a BOGUS conf are
# rc 2 (usage) and never the conf error (the EGL-228 property).
arr6=(gw "--out=$E246/run/e3c.env" "")
em6_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/bogus-nonexistent.conf")" egresslock proxy-env "${arr6[@]}" 2>&1)"; em6_rc=$?
[[ "$em6_rc" == 2 && "$em6_out" != *"config file not found"* ]] \
    && a246 pass || a246 fail "F3 pre-conf order with empty arg (rc=$em6_rc, out: $em6_out)"

# 15. R-EGL-246-3 F4 (D16): the unset-XDG_RUNTIME_DIR fallback writes to a
#     unique synthetic profile defined in egl246fall.conf (an undefined
#     profile would be rc 2 wherever /run/user/$(id -u) exists). Overwrite
#     stays deliberate (D4); the case touches only the engine's own
#     synthetic pathname — a collision is a named skip, never an overwrite
#     or delete. Case 8 protects the real `gw` runtime file.
e246_fall_profile="egl246fall"
e246_fall_file="/run/user/$(id -u)/egresslock-proxy-${e246_fall_profile}.env"
if [[ -d "/run/user/$(id -u)" ]]; then
    if [[ -e "$e246_fall_file" ]]; then
        skip "egl246-fallback-profile-collision" "F4: pre-existing file at the synthetic fallback name ($e246_fall_file) — sub-case skipped, nothing touched (overwrite stays deliberate, D16)"
    else
        fa_out="$(env -u XDG_RUNTIME_DIR ARCMOCK_PASSWD_HOME="$(conf_home "$E246/egl246fall.conf")" \
            egresslock proxy-env "$e246_fall_profile" --out 2>/dev/null)"; fa_rc=$?
        [[ "$fa_rc" == 0 && "$fa_out" == "$e246_fall_file" \
           && "$(stat -c %a "$e246_fall_file")" == "600" ]] \
            && a246 pass || a246 fail "F4 fallback unique-profile write (rc=$fa_rc, out: $fa_out)"
        rm -f "$e246_fall_file"
    fi
else
    skip "egl246-fallback-dir-absent" "unset-XDG_RUNTIME_DIR fallback not asserted: /run/user/$(id -u) absent on this runner"
fi

# 16. EGL-246-D19 (operator Q4, round-3/4 coverage item 1): a caller-
#     owned world-writable (002) parent is REFUSED rc 1 named — the
#     check runs on the CANONICAL parent, so a symlink-to-0777 parent
#     spelling cannot dodge it, and the bare form with a permissive
#     XDG_RUNTIME_DIR refuses the same way. Nothing written, stdout
#     empty, no temp litter.
mkdir -p "$E246/ww777"; chmod 777 "$E246/ww777"
w1_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/ww777/a.env" 2>"$E246/w1.err")"; w1_rc=$?
[[ "$w1_rc" == 1 && -z "$w1_out" \
   && "$(cat "$E246/w1.err")" == *"is world-writable"* \
   && "$(cat "$E246/w1.err")" == *"'$E246/ww777'"* \
   && "$(cat "$E246/w1.err")" == *"fail closed"* && ! -e "$E246/ww777/a.env" ]] \
    && a246 pass || a246 fail "D19 0777 parent refused (rc=$w1_rc, out: [$w1_out], err: $(cat "$E246/w1.err" 2>/dev/null))"
ln -sfn "$E246/ww777" "$E246/lnkww777"
w1b_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/lnkww777/b.env" 2>"$E246/w1b.err")"; w1b_rc=$?
[[ "$w1b_rc" == 1 && "$w1b_out" == "" \
   && "$(cat "$E246/w1b.err")" == *"is world-writable"* \
   && "$(cat "$E246/w1b.err")" == *"'$E246/ww777'"* ]] \
    && a246 pass || a246 fail "D19 symlink-to-0777 parent canonical refuse (rc=$w1b_rc, out: [$w1b_out], err: $(cat "$E246/w1b.err" 2>/dev/null))"
mkdir -p "$E246/xdg777"; chmod 777 "$E246/xdg777"
w1c_out="$(env XDG_RUNTIME_DIR="$E246/xdg777" ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out 2>"$E246/w1c.err")"; w1c_rc=$?
[[ "$w1c_rc" == 1 && "$w1c_out" == "" \
   && "$(cat "$E246/w1c.err")" == *"is world-writable"* && ! -e "$E246/xdg777/egresslock-proxy-gw.env" ]] \
    && a246 pass || a246 fail "D19 bare form on 0777 XDG_RUNTIME_DIR (rc=$w1c_rc, out: [$w1c_out])"
chmod 700 "$E246/ww777" "$E246/xdg777"   # keep litter checks clean

# 17. EGL-246-D19 (item 2) + W1: a caller-owned group-writable (020,
#     other bits clean) parent is ACCEPTED — rc 0, one-line stdout path,
#     file mode 600, and the rc-neutral W1 `warn:` line on stderr.
mkdir -p "$E246/gw0770"; chmod 770 "$E246/gw0770"
w2_full="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/gw0770/ok.env" 2>"$E246/w2.err")"; w2_rc=$?
[[ "$w2_rc" == 0 && "$w2_full" == "$E246/gw0770/ok.env" \
   && "$(stat -c %a "$E246/gw0770/ok.env")" == "600" \
   && "$(cat "$E246/w2.err")" == *"warn: target directory '$E246/gw0770' is group-writable"* ]] \
    && a246 pass || a246 fail "D19 0770 accepted + W1 warn (rc=$w2_rc, stdout: [$w2_full], err: $(cat "$E246/w2.err" 2>/dev/null))"
rm -f "$E246/gw0770/ok.env"

# 18. EGL-246-D19 (item 3): private/traversable-clean parents (0755,
#     0700) write with NO warn (no `group-writable` substring on
#     stderr) — the Q4 bar cases.
mkdir -p "$E246/p755" "$E246/p700"; chmod 755 "$E246/p755"; chmod 700 "$E246/p700"
w3_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/p755/ok.env" 2>"$E246/w3.err")"; w3_rc=$?
[[ "$w3_rc" == 0 && "$(stat -c %a "$E246/p755/ok.env")" == "600" \
   && ! "$(cat "$E246/w3.err")" == *"group-writable"* ]] \
    && a246 pass || a246 fail "D19 0755 no warn (rc=$w3_rc, err: $(cat "$E246/w3.err" 2>/dev/null))"
w3b_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/p700/ok.env" 2>"$E246/w3b.err")"; w3b_rc=$?
[[ "$w3b_rc" == 0 && "$(stat -c %a "$E246/p700/ok.env")" == "600" \
   && ! "$(cat "$E246/w3b.err")" == *"group-writable"* ]] \
    && a246 pass || a246 fail "D19 0700 no warn (rc=$w3b_rc, err: $(cat "$E246/w3b.err" 2>/dev/null))"
rm -f "$E246/p755/ok.env" "$E246/p700/ok.env"

# 19. EGL-246-D19 (item 4): `./` and `..` spellings canonicalize — the
#     outcome is the CANONICAL parent's, not the typed spelling's
#     (raw `${target%/*}` would judge a different directory).
mkdir -p "$E246/p700/sub"; chmod 700 "$E246/p700" "$E246/p700/sub"
w4_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/p700/sub/../dot.env" 2>"$E246/w4.err")"; w4_rc=$?
[[ "$w4_rc" == 0 && ! "$(cat "$E246/w4.err")" == *"world-writable"* \
   && ! "$(cat "$E246/w4.err")" == *"group-writable"* \
   && "$(stat -c %a "$E246/p700/dot.env" 2>/dev/null)" == "600" ]] \
    && a246 pass || a246 fail "D19 .. route whose canonical parent is 0700 passes (rc=$w4_rc, err: $(cat "$E246/w4.err" 2>/dev/null))"
rm -f "$E246/p700/dot.env"
mkdir -p "$E246/ww777o/sub2"; chmod 777 "$E246/ww777o"
w4b_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/ww777o/sub2/../dot.env" 2>"$E246/w4b.err")"; w4b_rc=$?
[[ "$w4b_rc" == 1 && "$(cat "$E246/w4b.err")" == *"is world-writable"* \
   && "$(cat "$E246/w4b.err")" == *"'$E246/ww777o'"* && ! -e "$E246/ww777o/dot.env" ]] \
    && a246 pass || a246 fail "D19 .. route refused on the canonical parent (rc=$w4b_rc, err: $(cat "$E246/w4b.err" 2>/dev/null))"
chmod 700 "$E246/ww777o/sub2"; rm -rf "$E246/ww777o/sub2"
w4c_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/../dotdot.env" 2>"$E246/w4c.err")"; w4c_rc=$?
[[ "$w4c_rc" == 0 && "$(stat -c %a "$TESTROOT/dotdot.env" 2>/dev/null)" == "600" \
   && ! "$(cat "$E246/w4c.err")" == *"group-writable"* ]] \
    && a246 pass || a246 fail "D19 .. spelling accepted where canonical passes (rc=$w4c_rc)"
rm -f "$TESTROOT/dotdot.env"

# 20. EGL-246-D19 (item 5): a symlink to a PRIVATE parent is accepted —
#     the file lands in the canonical referent; stdout is the TYPED
#     path (the caller's spelling, not the canonical referent).
mkdir -p "$E246/privdir"; chmod 700 "$E246/privdir"
ln -sfn "$E246/privdir" "$E246/privlnk"
w5_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/privlnk/typed.env" 2>"$E246/w5.err")"; w5_rc=$?
[[ "$w5_rc" == 0 && "$w5_out" == "$E246/privlnk/typed.env" \
   && "$(stat -c %a "$E246/privdir/typed.env")" == "600" \
   && ! "$(cat "$E246/w5.err")" == *"group-writable"* ]] \
    && a246 pass || a246 fail "D19 symlink-to-private parent (rc=$w5_rc, out: $w5_out)"
rm -f "$E246/privdir/typed.env"

# 21. EGL-246-D19 (item 6): a root-level path's parent is `/` — the
#     `-O`/`-w` parent check refuses named for this account (parent
#     `/`). No file created, nothing else touched (`[[ -n raw_dir ]] ||
#     raw_dir="/"` pins the empty-parent rule).
w6_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out=/egl246-do-not-create.env 2>"$E246/w6.err")"; w6_rc=$?
[[ "$w6_rc" == 1 && "$(cat "$E246/w6.err")" == *"is not owned or writable by this account"* \
   && "$(cat "$E246/w6.err")" == *"fail closed"* && ! -e /egl246-do-not-create.env ]] \
    && a246 pass || a246 fail "D19 root-level path refused named (rc=$w6_rc)"

# 22. EGL-246-D19 (item 7) — S2 leg: the parent's mode read fails (a
#     PATH shim on `stat`, exact-arg match on the fixture dir) → rc 1
#     named `cannot inspect target directory`, nothing written, no
#     litter. (`realpath -m` is lenient — a shim there cannot fire
#     deterministically; the stat leg carries S2.)
mkdir -p "$E246/ssbin"
cat > "$E246/ssbin/stat" <<SHIM
#!/bin/bash
# EGL-246-D19 S2: the fixture dir's mode read fails
# shellcheck disable=SC2312
if [[ "\${*: -1}" == "\${E246_STAT_FAIL_DIR:?}" ]]; then
    exit 1
fi
exec /usr/bin/stat "\$@"
SHIM
chmod +x "$E246/ssbin/stat"
mkdir -p "$E246/wfail"; chmod 755 "$E246/wfail"
w7_out="$(env PATH="$E246/ssbin:$PATH" E246_STAT_FAIL_DIR="$E246/wfail" \
    ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/wfail/s.env" 2>"$E246/w7.err")"; w7_rc=$?
w7_litter="$(find "$E246/wfail" -name 's.env.*' 2>/dev/null)"
[[ "$w7_rc" == 1 && "$w7_out" == "" \
   && "$(cat "$E246/w7.err")" == *"cannot inspect target directory"* \
   && "$(cat "$E246/w7.err")" == *"'$E246/wfail'"* && -z "$w7_litter" && ! -e "$E246/wfail/s.env" ]] \
    && a246 pass || a246 fail "D19 S2 stat-failure leg (rc=$w7_rc, err: $(cat "$E246/w7.err" 2>/dev/null))"
rm -f "$E246/ssbin/stat"; rmdir "$E246/ssbin" 2>/dev/null || true

# 23. EGL-246-D15 (operator Q6 — refuse a target symlink; coverage item):
#     a PRE-EXISTING symlink at the --out target is refused rc 1 named,
#     the referent's content and mode are untouched, the link stays
#     intact, and no temp litter survives; a dangling link refuses the
#     same way; a symlink to a DIRECTORY refuses via the directory leg
#     (`is a directory`). Never writes through the link.
: > "$E246/run/referent.env"; chmod 640 "$E246/run/referent.env"
ln -sfn "$E246/run/referent.env" "$E246/run/targetlink.env"
w8_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/run/targetlink.env" 2>"$E246/w8.err")"; w8_rc=$?
[[ "$w8_rc" == 1 && -z "$w8_out" \
   && "$(cat "$E246/w8.err")" == *"target '$E246/run/targetlink.env' is a symlink (pass a plain file path — fail closed)"* \
   && "$(cat "$E246/run/referent.env" 2>/dev/null)" == "" \
   && "$(stat -c %a "$E246/run/referent.env")" == "640" \
   && -L "$E246/run/targetlink.env" \
   && -z "$(find "$E246/run" -name 'targetlink.env.*' 2>/dev/null)" ]] \
    && a246 pass || a246 fail "D15 symlink-to-file refused (rc=$w8_rc, err: $(cat "$E246/w8.err" 2>/dev/null))"
ln -sfn "$E246/run/really-absent.file" "$E246/run/dangling.env"
w8b_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/run/dangling.env" 2>"$E246/w8b.err")"; w8b_rc=$?
[[ "$w8b_rc" == 1 && "$(cat "$E246/w8b.err")" == *"is a symlink"* \
   && -L "$E246/run/dangling.env" && ! -e "$E246/run/really-absent.file" ]] \
    && a246 pass || a246 fail "D15 dangling symlink refused (rc=$w8b_rc)"
ln -sfn "$E246/run" "$E246/run/dirlink.env"
w8c_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/run/dirlink.env" 2>"$E246/w8c.err")"; w8c_rc=$?
[[ "$w8c_rc" == 1 && "$(cat "$E246/w8c.err")" == *"is a directory"* ]] \
    && a246 pass || a246 fail "D15 symlink-to-dir refused (rc=$w8c_rc)"
rm -f "$E246/run/referent.env" "$E246/run/targetlink.env" "$E246/run/dangling.env" "$E246/run/dirlink.env"

# 24. EGL-246-D18/Q7: the engine help topic carries the approved caution
#     + caveat sentence (world-writable refused; group-write accepted;
#     the runtime-dir default always qualifies).
h246_full="$(egresslock help proxy-env 2>&1)"
[[ "$h246_full" == *"An explicit --out=<path> is refused if its directory is"* \
   && "$h246_full" == *"world-writable; a directory your group can also write to is accepted"* \
   && "$h246_full" == *"may tighten this. The runtime-dir default always qualifies."* ]] \
    && a246 pass || a246 fail "D18 help topic caution sentence missing (out: $(printf %s "$h246_full" | grep -c world-writable))"

PATH="$E246_PATH_SAVE"; unset E246_PATH_SAVE E246_LBIN

section_end egl246

# --- ARC-50: focused kit input→sink security review (D3 probes) ---------
# Probes that pin the review claim for rows the code already enforces.
# Each asserts a fail-closed/validated behavior that MUST stay green.
# (R-050-D3 corrected per EGL-270 P3: arc50_fail existence was the old
# wiring and is gone — the section's asserts run through the check/assert
# funnels into the per-section register and the RESULTS TOTAL like any
# other section; the sink rows are counted, not wired by hand.)
section_begin arc50 "ARC-50 sinks"
a50() { assert "$@"; }

S50="$TESTROOT/s50"; rm -rf "$S50"; mkdir -p "$S50"
cat > "$S50/s50.conf" <<'EOF'
profile s50 10.199.70.0/24
    rule gateway-only
    gateway 10.199.70.2 3128 s50-allowlist
EOF
: > "$S50/s50-allowlist"

# D3.1 — allow argv cannot carry shell metachars / newlines.
for bad in 'foo;rm' 'foo$(reboot)' $'foo\nbar'; do
    pre_md5="$(md5sum "$S50/s50-allowlist" | cut -d' ' -f1)"
    pre_runs="$(wc -l < "$STATE/runlog")"
    a50_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S50/s50.conf")" egresslock allow s50 "$bad" 2>&1)"; a50_rc=$?
    post_md5="$(md5sum "$S50/s50-allowlist" | cut -d' ' -f1)"
    post_runs="$(wc -l < "$STATE/runlog")"
    if [[ "$a50_rc" == 2 && "$pre_md5" == "$post_md5" && "$post_runs" == "$pre_runs" ]]; then
        a50 pass
    else
        a50 fail "D3.1 allow argv [$(printf %q "$bad")] (rc=$a50_rc unchanged=$([ "$pre_md5" == "$post_md5" ] && echo yes || echo no) newruns=$((post_runs-pre_runs)))"
    fi
done

# D3.2 — ${VAR} in conf cannot expand into a second directive (newline).
cat > "$S50/s50n.conf" <<'EOF'
profile s50n 10.199.71.0/24
    rule allow-host ${H}:443
EOF
a50_out="$(H=$'x.example\n    rule public-only' ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S50/s50n.conf")" egresslock list 2>&1)"; a50_rc=$?
[[ "$a50_rc" == 2 && "$a50_out" == *"invalid host"* ]] && a50 pass || a50 fail "D3.2 conf newline not a second directive (rc=$a50_rc, out: $a50_out)"

# D3.5 — gateway podman run carries --cap-drop=all + no-new-privileges.
ARCMOCK_PASSWD_HOME="$(conf_home "$S50/s50.conf")" egresslock ensure s50 >/dev/null 2>&1; a50_rc=$?
if [[ "$a50_rc" == 0 ]] \
   && grep -q -- '--cap-drop=all' "$STATE/runlog" \
   && grep -q -- 'no-new-privileges' "$STATE/runlog"; then
    a50 pass
else
    a50 fail "D3.5 gateway run has cap-drop=all + no-new-privileges (ensure rc=$a50_rc)"
fi

# D3.3 — empty allowlist ⇒ terminal deny-all, no allow rule.
: > "$S50/s50-allowlist"
ARCMOCK_PASSWD_HOME="$(conf_home "$S50/s50.conf")" egresslock ensure s50 >/dev/null 2>&1; a50_rc=$?
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
a50_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S50/s50.conf")" egresslock ensure s50 2>&1)"; a50_rc=$?
[[ "$a50_rc" != 0 && "$a50_out" == *"invalid allowlist entry 'foo;bar'"* ]] && a50 pass || a50 fail "D3.4 poisoned allowlist line fails closed (rc=$a50_rc, out: $a50_out)"

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

section_end arc50

# --- ARC-56: GW_DNS_NAMESERVERS strict IPv4 list (ARC-50 D7) ------------
# The override is interpolated into squid.conf dns_nameservers; it must
# be an ASCII-space list of cfg_is_ipv4-valid addresses (D1).
section_begin arc56 "ARC-56 GW_DNS"
a56() { assert "$@"; }

S56="$TESTROOT/s56"; rm -rf "$S56"; mkdir -p "$S56"
cat > "$S56/s56.conf" <<'EOF'
profile s56 10.199.72.0/24
    rule gateway-only
    gateway 10.199.72.2 3128 s56-allowlist
EOF
: > "$S56/s56-allowlist"

# default unset still works and emits the default nameserver.
ARCMOCK_PASSWD_HOME="$(conf_home "$S56/s56.conf")" egresslock ensure s56 >/dev/null 2>&1; a56_rc=$?
sq56="$(find "$STATE" -name 'containers-egresslock-gateway-s56.squid-gw.conf' 2>/dev/null | head -1)"
[[ "$a56_rc" == 0 && -n "$sq56" && "$(grep -m1 'dns_nameservers' "$sq56")" == "dns_nameservers 169.254.1.1" ]] \
    && a56 pass || a56 fail "D default unset → 169.254.1.1 (rc=$a56_rc sq=[$sq56] $(grep -m1 dns_nameservers "$sq56" 2>/dev/null))"

# single valid + two valid still work.
for val in "8.8.8.8" "8.8.8.8 1.1.1.1"; do
    ARCMOCK_PASSWD_HOME="$(conf_home "$S56/s56.conf")" egresslock teardown s56 >/dev/null 2>&1 || true
    a56_out="$(GW_DNS_NAMESERVERS="$val" ARCMOCK_PASSWD_HOME="$(conf_home "$S56/s56.conf")" egresslock ensure s56 2>&1)"; a56_rc=$?
    sq56="$(find "$STATE" -name 'containers-egresslock-gateway-s56.squid-gw.conf' 2>/dev/null | head -1)"
    [[ "$a56_rc" == 0 && -n "$sq56" && "$(grep -m1 'dns_nameservers' "$sq56")" == "dns_nameservers $val" ]] \
        && a56 pass || a56 fail "D valid '$val' (rc=$a56_rc $(grep -m1 dns_nameservers "$sq56" 2>/dev/null))"
done

# invalid: bad octet, newline, double space.
for val in "999.999" $'8.8.8.8\n1.1.1.1' "8.8.8.8  1.1.1.1" "1.2.3"; do
    ARCMOCK_PASSWD_HOME="$(conf_home "$S56/s56.conf")" egresslock teardown s56 >/dev/null 2>&1 || true
    a56_out="$(GW_DNS_NAMESERVERS="$val" ARCMOCK_PASSWD_HOME="$(conf_home "$S56/s56.conf")" egresslock ensure s56 2>&1)"; a56_rc=$?
    [[ "$a56_rc" != 0 && "$a56_out" == *"GW_DNS_NAMESERVERS"* ]] \
        && a56 pass || a56 fail "D invalid [$(printf %q "$val")] not fail-closed (rc=$a56_rc, out: $a56_out)"
done

section_end arc56

# --- ARC-58: relative gateway allowlist path is a confdir basename ------
# No '/' and no '..' segment in relative paths (D1); absolute unchanged.
section_begin arc58 "ARC-58 path"
a58() { assert "$@"; }

S58="$TESTROOT/s58"; rm -rf "$S58"; mkdir -p "$S58"
for bad in '../other/secret' 'foo/bar' '..'; do
    # EGL-78-D5: the old noisy `cat > "$S58/$bad.conf"` (which always
    # failed with "No such file or directory" for the two bad paths) is
    # gone — the test only reads the sanitized-basename conf written below.
    # sanitize the filename for the .conf suffix
    safe="$(printf %s "$bad" | tr '/.' '__')"
    printf 'profile g 10.199.73.0/24\n    rule gateway-only\n    gateway 10.199.73.2 3128 %s\n' "$bad" > "$S58/$safe.conf"
    a58_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S58/$safe.conf")" egresslock list 2>&1)"; a58_rc=$?
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
a58_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S58/ok.conf")" egresslock list 2>&1)"; a58_rc=$?
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
a58_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S58/abs.conf")" egresslock list 2>&1)"; a58_rc=$?
[[ "$a58_rc" == 0 && "$a58_out" == *"a2"* ]] && a58 pass || a58 fail "D absolute path loads (rc=$a58_rc, out: $a58_out)"

section_end arc58

# --- ARC-51: allowlist grammar rejects IPv4 literals (names only) ---------
# D1: `allow` of a literal exits 2 with the allowlist untouched; a literal
# line in the file fails `ensure` closed (not skipped). D2: `allow-host`
# still accepts a literal (conf rule + CLI insert). Hostname cases
# unchanged.
section_begin arc51 "ARC-51 allowlist literals"
a51() { assert "$@"; }

S51="$TESTROOT/s51"; rm -rf "$S51"; mkdir -p "$S51"
cat > "$S51/s51.conf" <<'EOF'
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
    a51_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S51/s51.conf")" egresslock allow s51 "$lit" 2>&1)"; a51_rc=$?
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
a51_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S51/s51.conf")" egresslock ensure s51 2>&1)"; a51_rc=$?
[[ "$a51_rc" != 0 && "$a51_out" == *"allow-host"* ]] \
    && a51 pass || a51 fail "D1.2 literal allowlist line fails ensure closed (rc=$a51_rc, out: $a51_out)"
printf '203.0.113.7:11434\n' > "$S51/s51-allowlist"
a51_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S51/s51.conf")" egresslock ensure s51 2>&1)"; a51_rc=$?
[[ "$a51_rc" != 0 && "$a51_out" == *"allow-host"* ]] \
    && a51 pass || a51 fail "D1.2b literal:port allowlist line fails ensure closed (rc=$a51_rc, out: $a51_out)"

# D2.1 — a conf `rule allow-host <literal>:<port>` still loads (D2: the
# allow-host path takes hostname or IPv4 literal).
cat > "$S51/ah.conf" <<'EOF'
profile ah 10.199.77.0/24
    rule allow-host 10.1.2.3:443
EOF
a51_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S51/ah.conf")" egresslock list 2>&1)"; a51_rc=$?
[[ "$a51_rc" == 0 ]] && a51 pass || a51 fail "D2.1 conf rule allow-host literal loads (rc=$a51_rc, out: $a51_out)"

# D2.2 — CLI allow-host of a literal inserts the rule and re-ensures (mock
# DNS echoes the literal like real getent ahostsv4, ARC-12 drift knob).
cat > "$S51/s51b.conf" <<'EOF'
profile s51b 10.199.78.0/24
    rule gateway-only
    gateway 10.199.78.2 3128 s51-allowlist
EOF
: > "$S51/s51-allowlist"
a51_out="$(EGRESSLOCK_MOCK_DNS="10.1.2.3=10.1.2.3" ARCMOCK_PASSWD_HOME="$(conf_home "$S51/s51b.conf")" egresslock allow-host s51b 10.1.2.3:443 2>&1)"; a51_rc=$?
if [[ "$a51_rc" == 0 && "$a51_out" == *"added: rule allow-host 10.1.2.3:443"* ]] \
   && grep -qF 'rule allow-host 10.1.2.3:443' "$S51/s51b.conf"; then
    a51 pass
else
    a51 fail "D2.2 CLI allow-host literal (rc=$a51_rc, out: $a51_out)"
fi

# D0 — normal hostname allow still works.
: > "$S51/s51-allowlist"
a51_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S51/s51.conf")" egresslock allow s51 example.com 2>&1)"; a51_rc=$?
[[ "$a51_rc" == 0 && "$a51_out" == *"added: example.com"* ]] \
    && a51 pass || a51 fail "D0 hostname allow unchanged (rc=$a51_rc, out: $a51_out)"

section_end arc51

# --- ARC-59: leading '-' / flag-shaped tokens rejected (ARC-50 D7) -------
# D1: profile names must start [a-z0-9]; host fields start alnum or '.';
# env overrides (GW_IMAGE / ANCHOR_IMAGE / NFT_BIN) reject a non-empty
# value that starts with '-'. Happy paths unchanged.
section_begin arc59 "ARC-59 leading-dash"
a59() { assert "$@"; }

# D1.1 — `profile -foo` is a config error (rc 2), not a live profile.
S59="$TESTROOT/s59"; rm -rf "$S59"; mkdir -p "$S59"
printf 'profile -foo 10.199.79.0/24\n' > "$S59/bad.conf"
a59_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S59/bad.conf")" egresslock list 2>&1)"; a59_rc=$?
[[ "$a59_rc" == 2 && "$a59_out" == *"invalid profile name"* ]] \
    && a59 pass || a59 fail "D1.1 conf profile -foo rejected (rc=$a59_rc, out: $a59_out)"

# D1.2 — a valid leading-alnum name (with later hyphens) still loads.
printf 'profile dev-llm 10.199.81.0/24\n' > "$S59/ok.conf"
a59_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S59/ok.conf")" egresslock list 2>&1)"; a59_rc=$?
[[ "$a59_rc" == 0 ]] && a59 pass || a59 fail "D1.2 dev-llm profile still loads (rc=$a59_rc, out: $a59_out)"

# D1.3 — init rejects a leading-dash name ('-x' is not a flag token, so it
# reaches the name validator; '--x' is rejected earlier by the option parser,
# also rc 2).
a59_out="$(egresslock init -x 2>&1)"; a59_rc=$?
[[ "$a59_rc" == 2 && "$a59_out" == *"invalid profile name"* ]] \
    && a59 pass || a59 fail "D1.3 init -x rejected (rc=$a59_rc, out: $a59_out)"

# D1.4 — init accepts a normal name (temp dest -> cleaned up).
mkdir -p "$S59/init-dest"
a59_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S59/init-dest/x.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock init dev-x --subnet 10.199.82.0/24 2>&1)"; a59_rc=$?
[[ "$a59_rc" == 0 ]] && a59 pass || a59 fail "D1.4 init dev-x works (rc=$a59_rc, out: $a59_out)"

# D1.5 — CLI `allow` of a leading-dash host exits 2, allowlist unchanged.
cat > "$S59/s59.conf" <<'EOF'
profile s59 10.199.83.0/24
    rule gateway-only
    gateway 10.199.83.2 3128 s59-allowlist
EOF
: > "$S59/s59-allowlist"
for bad in '--help' '-x'; do
    pre_md5="$(md5sum "$S59/s59-allowlist" | cut -d' ' -f1)"
    pre_runs="$(wc -l < "$STATE/runlog")"
    a59_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S59/s59.conf")" egresslock allow s59 "$bad" 2>&1)"; a59_rc=$?
    post_md5="$(md5sum "$S59/s59-allowlist" | cut -d' ' -f1)"
    post_runs="$(wc -l < "$STATE/runlog")"
    if [[ "$a59_rc" == 2 && "$pre_md5" == "$post_md5" && "$post_runs" == "$pre_runs" ]]; then
        a59 pass
    else
        a59 fail "D1.5 allow leading-dash [$(printf %q "$bad")] (rc=$a59_rc unchanged=$([ "$pre_md5" == "$post_md5" ] && echo yes || echo no) newruns=$((post_runs-pre_runs)) out=$a59_out)"
    fi
done

# D1.6 — CLI allow-host of a leading-dash host:port → rc 2.
a59_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S59/s59.conf")" egresslock allow-host s59 --help:443 2>&1)"; a59_rc=$?
[[ "$a59_rc" == 2 && "$a59_out" == *"invalid allow-host entry"* ]] \
    && a59 pass || a59 fail "D1.6 allow-host --help:443 rejected (rc=$a59_rc, out: $a59_out)"

# D1.7 — a poisoned allowlist line with a leading dash fails `ensure` closed.
printf -- '-bad\n' > "$S59/s59-allowlist"
a59_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S59/s59.conf")" egresslock ensure s59 2>&1)"; a59_rc=$?
[[ "$a59_rc" != 0 ]] && a59 pass || a59 fail "D1.7 allowlist '-bad' fails closed (rc=$a59_rc)"

# D1.8 — env overrides: `ensure` of a gateway profile with
# EGRESSLOCK_GW_IMAGE='-privileged' dies before a `podman run` could
# interpolate that token. The anchors already started (network first) is
# fine; the assert is that the token never reaches the runlog and the
# message names the variable.
cat > "$S59/s59b.conf" <<'EOF'
profile s59b 10.199.84.0/24
    rule gateway-only
    gateway 10.199.84.2 3128 s59-allowlist
EOF
: > "$S59/s59-allowlist"
: > "$STATE/runlog"
a59_out="$(EGRESSLOCK_GW_IMAGE='-privileged' ARCMOCK_PASSWD_HOME="$(conf_home "$S59/s59b.conf")" egresslock ensure s59b 2>&1)"; a59_rc=$?
if [[ "$a59_rc" != 0 && "$a59_out" == *"EGRESSLOCK_GW_IMAGE"* ]] && ! grep -q -- '-privileged' "$STATE/runlog"; then
    a59 pass
else
    a59 fail "D1.8 GW_IMAGE '-privileged' dies pre-run (rc=$a59_rc runs=$(wc -l < "$STATE/runlog") token-in-runlog=$(grep -c -- '-privileged' "$STATE/runlog" || true) out=$a59_out)"
fi
# NFT_BIN is only interpolated into `podman unshare` (not a run); the guard
# still fires with rc non-zero and names the var — no runlog assert needed.
: > "$STATE/runlog"
a59_out="$(NFT_BIN='-privileged' ARCMOCK_PASSWD_HOME="$(conf_home "$S59/s59b.conf")" egresslock ensure s59b 2>&1)"; a59_rc=$?
[[ "$a59_rc" != 0 && "$a59_out" == *"NFT_BIN"* ]] \
    && a59 pass || a59 fail "D1.8b NFT_BIN '-privileged' rejected (rc=$a59_rc out=$a59_out)"

# D1.8c — EGRESSLOCK_ANCHOR_IMAGE: the anchor's `podman run` is the first
# consumer; the die fires at that interpolation, token never in runlog.
# Own profile/network so the anchor container is actually created here.
cat > "$S59/s59c.conf" <<'EOF'
profile s59c 10.199.85.0/24
    rule gateway-only
    gateway 10.199.85.2 3128 s59-allowlist
EOF
: > "$STATE/runlog"
a59_out="$(EGRESSLOCK_ANCHOR_IMAGE='-privileged' ARCMOCK_PASSWD_HOME="$(conf_home "$S59/s59c.conf")" egresslock ensure s59c 2>&1)"; a59_rc=$?
if [[ "$a59_rc" != 0 && "$a59_out" == *"EGRESSLOCK_ANCHOR_IMAGE"* ]] && ! grep -q -- '-privileged' "$STATE/runlog"; then
    a59 pass
else
    a59 fail "D1.8c ANCHOR_IMAGE '-privileged' dies pre-run (rc=$a59_rc token-in-runlog=$(grep -c -- '-privileged' "$STATE/runlog" || true) out=$a59_out)"
fi

# D1.9 — valid env overrides still pass; the gateway image override keeps
# the default image-exists path (mock has it).
: > "$STATE/runlog"
a59_out="$(EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:latest \
    ARCMOCK_PASSWD_HOME="$(conf_home "$S59/s59b.conf")" egresslock ensure s59b 2>&1)"; a59_rc=$?
[[ "$a59_rc" == 0 ]] && a59 pass || a59 fail "D1.9 GW_IMAGE happy path (rc=$a59_rc runs=$(wc -l < "$STATE/runlog") out=$a59_out)"

section_end arc59

# --- ARC-57: denied emit filters strings the allow grammar rejects ------
# D1: a malicious/malformed log line must not make `denied` print a
# string `allow` would reject; skipped silently (rc 0, no invalid-entry
# stderr). ARC-59 leading-dash hosts are also omitted because the shared
# predicate picks them up. EGL-18-D1 AMENDED the ARC-51 IPv4 omission:
# well-formed IPv4 host[:port] candidates are now EMITTED (not allowlist
# entries — the allow-host pointer is the one-time stderr note).
section_begin arc57 "ARC-57 denied emit filter"
a57() { assert "$@"; }

S57="$TESTROOT/s57"; rm -rf "$S57"; mkdir -p "$S57"
cat > "$S57/s57.conf" <<'EOF'
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
d57_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S57/s57.conf")" egresslock denied s57 --days 0 2>&1)"; d57_rc=$?
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
all57_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S57/s57.conf")" egresslock denied s57 --days 0 --all 2>&1)"; all57_rc=$?
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
p57_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S57/s57.conf")" egresslock denied s57 --days 0 --all 2>&1)"; p57_rc=$?
[[ "$p57_rc" == 0 && "$p57_out" == *"cache.example.test:8080"* ]] \
    && a57 pass || a57 fail "D1c host:port denial preserved (rc=$p57_rc, out: $p57_out)"

# 4. allow still rejects the same payload string (defense-in-depth intact;
# the shared predicate is the same one denied uses).
a57_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S57/s57.conf")" egresslock allow s57 'foo;rm' 2>&1)"; a57_rc=$?
[[ "$a57_rc" == 2 && "$a57_out" == *"invalid allowlist entry"* ]] \
    && a57 pass || a57 fail "D1d allow rejects the payload string (rc=$a57_rc, out: $a57_out)"

section_end arc57

# --- EGL-18: IP destinations — denied emits IPv4 + note, allow-host ------
# hint, NO_PROXY unions allow-host IPv4 pins (D1/D2/D3; D5: the matrix is
# harness evidence, not a live-lab gate).
section_begin egl18 "EGL-18 IP destinations"
a18() { assert "$@"; }

S18="$TESTROOT/h18"; rm -rf "$S18"; mkdir -p "$S18"
cat > "$S18/s18.conf" <<'EOF'
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
d18_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S18/s18.conf")" egresslock denied s18 --days 0 2>"$S18/d1.err")"; d18_rc=$?
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
d18b_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S18/s18.conf")" egresslock denied s18 --days 0 2>"$S18/d1b.err")"; d18b_rc=$?
[[ "$d18b_rc" == 0 && "$d18b_out" == *"10.1.2.3:11434"* \
    && "$(cat "$S18/d1b.err")" == *"$D1_NOTE"* ]] \
    && a18 pass || a18 fail "D1 GET literal emitted host:port (rc=$d18b_rc, out: $d18b_out)"

# 3. D1: hostname-only denied log -> NO note on stderr.
printf '%s.000    120 10.199.87.5 TCP_DENIED/403 0 GET http://cache.example.test:8080/ - HIER_NONE/- -\n' "$(date +%s)" \
    > "$STATE/containers-egresslock-gateway-s18.access.log"
d18c_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S18/s18.conf")" egresslock denied s18 --days 0 2>"$S18/d1c.err")"; d18c_rc=$?
if [[ "$d18c_rc" == 0 && "$d18c_out" == *"cache.example.test:8080"* \
      && "$(grep -c '^note: IPv4' "$S18/d1c.err")" == 0 ]]; then
    a18 pass
else
    a18 fail "D1 hostname-only log has no note (rc=$d18c_rc, out: $d18c_out, err: $(cat "$S18/d1c.err"))"
fi

# 4. D2: allow-host of an IPv4 on a GATEWAY profile -> added: line on
#    stdout + the D2 note verbatim on stderr; conf has the rule.
cat > "$S18/s18h.conf" <<'EOF'
profile s18h 10.199.89.0/24
    rule gateway-only
    gateway 10.199.89.2 3128 s18h-allowlist
EOF
: > "$S18/s18h-allowlist"
h18_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S18/s18h.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host s18h 10.1.2.3:11434 2>"$S18/h1.err")"; h18_rc=$?
if [[ "$h18_rc" == 0 && "$h18_out" == *"added: rule allow-host 10.1.2.3:11434"* \
      && "$(cat "$S18/h1.err")" == *"$D2_NOTE"* \
      && "$(grep -c 'rule allow-host 10.1.2.3:11434' "$S18/s18h.conf")" == 1 ]]; then
    a18 pass
else
    a18 fail "D2 allow-host IPv4 hint (rc=$h18_rc, out: $h18_out, err: $(cat "$S18/h1.err"))"
fi

# 4b. D2: the duplicate (already present) still prints the hint.
h18d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S18/s18h.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host s18h 10.1.2.3:11434 2>"$S18/h1b.err")"; h18d_rc=$?
[[ "$h18d_rc" == 0 && "$h18d_out" == *"entry already present"* \
    && "$(cat "$S18/h1b.err")" == *"$D2_NOTE"* ]] \
    && a18 pass || a18 fail "D2 duplicate still hints (rc=$h18d_rc, out: $h18d_out)"

# 5. D2: IPv4 allow-host on a NON-gateway profile -> no hint (stderr
#    still carries the re-ensuring banner — assert the NOTE line count).
cat > "$S18/s18d.conf" <<'EOF'
profile s18d 10.199.88.0/24
    rule allow-host 10.1.2.3:11434
EOF
h18n_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S18/s18d.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host s18d 10.1.2.3:8080 2>"$S18/h2.err")"; h18n_rc=$?
[[ "$h18n_rc" == 0 && "$(grep -c '^note: IPv4 allow-host' "$S18/h2.err")" == 0 \
    && "$(grep -c 'rule allow-host 10.1.2.3:8080' "$S18/s18d.conf")" == 1 ]] \
    && a18 pass || a18 fail "D2 non-gateway no hint (rc=$h18n_rc, err: $(cat "$S18/h2.err"))"

# 6. D2: hostname allow-host on a GATEWAY profile -> no hint (ARC-38-D4
#    rationale: ssh ignores HTTP(S)_PROXY).
h18g_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S18/s18h.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host s18h git.example.test:2222 2>"$S18/h3.err")"; h18g_rc=$?
[[ "$h18g_rc" == 0 && "$(grep -c '^note: IPv4 allow-host' "$S18/h3.err")" == 0 \
    && "$(grep -c 'rule allow-host git.example.test:2222' "$S18/s18h.conf")" == 1 ]] \
    && a18 pass || a18 fail "D2 hostname pin no hint (rc=$h18g_rc, err: $(cat "$S18/h3.err"))"

# 7. D3: proxy-env noproxy unions allow-host IPv4 literals — IP once,
#    hostname pin absent.
cat > "$S18/s18n.conf" <<'EOF'
profile s18n 10.199.90.0/24
    rule allow-host 10.1.2.3:11434
    rule allow-host 10.1.2.3:443
    rule allow-host git.example.test:2222
    rule gateway-only
    gateway 10.199.90.2 3128 s18n-allowlist
EOF
: > "$S18/s18n-allowlist"
np18="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S18/s18n.conf")" egresslock proxy-env s18n noproxy 2>/dev/null)"
[[ "$np18" == "localhost,127.0.0.1,10.1.2.3" ]] \
    && a18 pass || a18 fail "D3 noproxy union (got: $np18)"

# 8. D3: conf no-proxy naming the same IP -> still exactly once.
cat > "$S18/s18n2.conf" <<'EOF'
profile s18n2 10.199.91.0/24
    rule allow-host 10.1.2.3:11434
    no-proxy 10.1.2.3
    rule gateway-only
    gateway 10.199.91.2 3128 s18n2-allowlist
EOF
: > "$S18/s18n2-allowlist"
np18b="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S18/s18n2.conf")" egresslock proxy-env s18n2 noproxy 2>/dev/null)"
[[ "$np18b" == "localhost,127.0.0.1,10.1.2.3" ]] \
    && a18 pass || a18 fail "D3 conf+pin dedup (got: $np18b)"

# 9. D3: hostname-only allow-host (no IPv4 pin, no conf no-proxy) ->
#    the ARC-44 default is byte-exact.
cat > "$S18/s18n3.conf" <<'EOF'
profile s18n3 10.199.92.0/24
    rule allow-host git.example.test:2222
    rule gateway-only
    gateway 10.199.92.2 3128 s18n3-allowlist
EOF
: > "$S18/s18n3-allowlist"
np18c="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S18/s18n3.conf")" egresslock proxy-env s18n3 noproxy 2>/dev/null)"
[[ "$np18c" == "localhost,127.0.0.1" ]] \
    && a18 pass || a18 fail "D3 hostname-only stays default (got: $np18c)"

section_end egl18

# --- ARC-60: teardown --runtime -------------------------------------------
# D1: the no-conf runtime sweep (ARC-68-D1: egresslock-only regexes; the
# agent-* family is NOT swept).
section_begin arc60 "ARC-60 runtime sweep"
a60() { assert "$@"; }

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
    # non-kit: the opencode recipe container
    : > "$STATE/running/agent-opencode"; echo "podman-default" > "$STATE/containers/agent-opencode.net"
}
run_a60() { env HOME="$H60" ARCMOCK_PASSWD_HOME="$H60" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

# 1. --runtime sweeps the egresslock-* generation only (ARC-68-D1: the
#    seeded agent-* family SURVIVES); an explicit EGRESSLOCK_CONF is
#    ignored (not loaded, not required).
mk_a60_runtime
a60_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H60/nope.conf")" HOME="$H60" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock teardown --runtime 2>&1)"; a60_rc=$?
if [[ "$a60_rc" == 0 \
      && "$a60_out" == *"removed container egresslock-anchor-main"* \
      && "$a60_out" == *"removed network egresslock-main"* ]] \
   && [[ -f "$STATE/running/agent-gateway-dev" && -f "$STATE/running/agent-anchor-dev" \
      && -f "$STATE/networks/agent-dev" \
      && ! -e "$STATE/running/egresslock-anchor-main" && ! -e "$STATE/networks/egresslock-main" ]] \
   && [[ -f "$STATE/running/agent-opencode" ]] \
   && [[ "$a60_out" != *"removed container agent-"* && "$a60_out" != *"removed network agent-"* \
      && "$a60_out" != *"agent-opencode"* ]]; then
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

section_end arc60
# --- ARC-32: pre-OSS hardening -------------------------------------------
# D1: `denied` streams/byte-caps the log read (EGRESSLOCK_DENIED_MAX_BYTES,
# 32 MiB default); EGL-252 parses the newest bytes within the cap and
# drops a partial first line; ensure/verify rotate overlay logs over
# EGRESSLOCK_GW_LOG_MAX_BYTES (mv -> squid -k rotate -> rm .1). D2: DNS
# length caps. D3: gateway base digest pin. D4: no sudoers shipped.
section_begin arc32 "ARC-32 pre-OSS hardening"
a32() { assert "$@"; }

A32="$TESTROOT/s32"; rm -rf "$A32"; mkdir -p "$A32"
cat > "$A32/s32.conf" <<'EOF'
profile s32 10.199.90.0/24
    rule gateway-only
    gateway 10.199.90.2 3128 s32-allowlist
EOF
: > "$A32/s32-allowlist"
GW32=egresslock-gateway-s32
: > "$STATE/running/$GW32"
now32="$(date +%s)"
old32="$(( now32 - 15 * 86400 ))"

mklog32() { # mklog32 <ts-line1> [ts-rest] — three CONNECT denials, one per host
    cat > "$STATE/containers-$GW32.access.log" <<EOF
$1.000    120 10.199.90.5 TCP_DENIED/403 0 CONNECT a32-one.example.test:443 - HIER_NONE/- -
${2:-$now32}.000    120 10.199.90.5 TCP_DENIED/403 0 CONNECT a32-two.example.test:443 - HIER_NONE/- -
${2:-$now32}.000    120 10.199.90.5 TCP_DENIED/403 0 CONNECT a32-three.example.test:443 - HIER_NONE/- -
EOF
}

# D1.1 — capped read (EGL-252): rc 0, the NEWEST bytes within the cap
# are parsed (partial first line dropped), one stderr line names the
# remedy. Cap = first line + 5 bytes -> line 3 full, line 2 partial.
mklog32 "$now32"
cap32="$(head -1 "$STATE/containers-$GW32.access.log" | wc -c)"; cap32=$(( cap32 + 5 ))
d32_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" EGRESSLOCK_DENIED_MAX_BYTES="$cap32" \
    egresslock denied s32 --days 0 2>$TESTROOT/agent32a.err)"; d32_rc=$?
d32_err="$(cat $TESTROOT/agent32a.err)"
if [[ "$d32_rc" == 0 && "$d32_out" == *"a32-three.example.test"* \
      && "$d32_out" != *"a32-one.example.test"* && "$d32_out" != *"a32-two.example.test"* \
      && "$d32_err" == *"only the newest ${cap32} bytes"* && "$d32_err" == *"EGRESSLOCK_DENIED_MAX_BYTES=0"* ]] \
   && [[ "$(grep -vc '^using config ' $TESTROOT/agent32a.err)" == 1 ]]; then
    a32 pass
else
    a32 fail "D1.1 denied byte cap tail-read (rc=$d32_rc out=[$d32_out] err=[$d32_err])"
fi

# D1.2 — the whole cap-window predates the --days cutoff (all-old
# fixture): newest bytes still parsed but filtered by the window ->
# empty stdout, truncate note + window note (had_denied came from the
# streamed meta, not a slurp).
mklog32 "$old32" "$old32"
cap32="$(head -1 "$STATE/containers-$GW32.access.log" | wc -c)"; cap32=$(( cap32 + 5 ))
d32_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" EGRESSLOCK_DENIED_MAX_BYTES="$cap32" \
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
d32_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" EGRESSLOCK_DENIED_MAX_BYTES=0 \
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
    d32_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" EGRESSLOCK_DENIED_MAX_BYTES="$bad32" \
        egresslock denied s32 2>&1)"; d32_rc=$?
    [[ "$d32_rc" == 2 ]] && a32 pass || a32 fail "D1.4 DENIED_MAX='$bad32' -> exit 2 (rc=$d32_rc out=$d32_out)"
done

# D1.8 (EGL-252) — cap == exact log size: the stat probe is <= (not >),
# so the whole file is catted — all three entries, NO truncation note.
mklog32 "$now32"
cap32="$(wc -c < "$STATE/containers-$GW32.access.log")"
d32_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" EGRESSLOCK_DENIED_MAX_BYTES="$cap32" \
    egresslock denied s32 --days 0 2>$TESTROOT/agent32g.err)"; d32_rc=$?
d32_err="$(cat $TESTROOT/agent32g.err)"
if [[ "$d32_rc" == 0 && "$d32_out" == *"a32-one.example.test"* \
      && "$d32_out" == *"a32-two.example.test"* && "$d32_out" == *"a32-three.example.test"* \
      && "$d32_err" != *"EGRESSLOCK_DENIED_MAX_BYTES"* ]]; then
    a32 pass
else
    a32 fail "D1.8 cap == size -> cat path (rc=$d32_rc out=[$d32_out] err=[$d32_err])"
fi

# D1.9 (EGL-252) — cap offset lands exactly on a line start: the +1
# probe byte makes the first record empty (the read window's first
# line is complete), so exactly a32-two + a32-three are emitted, no
# partial record leaks, note fires. (D1's rejected unconditional-drop
# simplification would emit a32-three only — this case pins the probe.)
mklog32 "$now32"
size32="$(wc -c < "$STATE/containers-$GW32.access.log")"
L1_32="$(head -1 "$STATE/containers-$GW32.access.log" | wc -c)"
cap32=$(( size32 - L1_32 ))
d32_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" EGRESSLOCK_DENIED_MAX_BYTES="$cap32" \
    egresslock denied s32 --days 0 2>$TESTROOT/agent32h.err)"; d32_rc=$?
d32_err="$(cat $TESTROOT/agent32h.err)"
n32="$(grep -c . <<<"$d32_out")"
if [[ "$d32_rc" == 0 && "$d32_out" == *"a32-two.example.test"* \
      && "$d32_out" == *"a32-three.example.test"* && "$d32_out" != *"a32-one.example.test"* \
      && "$n32" == 2 && "$d32_err" == *"only the newest ${cap32} bytes"* ]]; then
    a32 pass
else
    a32 fail "D1.9 exact line boundary probe (rc=$d32_rc n=$n32 out=[$d32_out] err=[$d32_err])"
fi

# D1.5 — `denied` never rotates: no mv/rm of the log, no `squid -k
# rotate`, even on a truncated read.
: > "$STATE/execlog"
mklog32 "$now32"
cap32="$(head -1 "$STATE/containers-$GW32.access.log" | wc -c)"
env ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" EGRESSLOCK_DENIED_MAX_BYTES="$cap32" \
    egresslock denied s32 --days 0 >/dev/null 2>&1
if ! grep -q 'access.log.1' "$STATE/execlog" && ! grep -q -- '-k rotate' "$STATE/execlog"; then
    a32 pass
else
    a32 fail "D1.5 denied must not rotate (execlog: $(grep -e 'access.log.1' -e -- '-k rotate' "$STATE/execlog" | head -3))"
fi

# D1.6 — verify rotates oversize overlay logs: a tiny cap must produce the
# exact mv -> `squid -k rotate` -> rm argv, leave NO .1 as the live file,
# and reopen fresh logs. One rotate covers BOTH stdio logs (real squid
# reopens every log), so cache.log asserts the reopen, not its own mv. The
# denied tests' fake running marker must go first so ensure really creates
# the gateway.
rm -f "$STATE/running/$GW32"
d32_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" egresslock ensure s32 2>&1)"; d32_rc=$?
[[ "$d32_rc" == 0 ]] && a32 pass || a32 fail "D1.6 setup ensure (rc=$d32_rc out=$d32_out)"
: > "$STATE/execlog"
printf '%s\n' "$(printf 'c%.0s' $(seq 1 90))" > "$STATE/containers-$GW32.cache.log"
mklog32 "$now32"
v32_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" EGRESSLOCK_GW_LOG_MAX_BYTES=50 \
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
v32_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" EGRESSLOCK_GW_LOG_MAX_BYTES=50 \
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
    d32_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" egresslock allow s32 "$bad32" 2>&1)"; d32_rc=$?
    [[ "$d32_rc" == 2 && "$d32_out" == *"DNS length limits"* ]] \
        && a32 pass || a32 fail "D2.1 allow oversize host (${#bad32} bytes) (rc=$d32_rc out=$d32_out)"
done
[[ "$(md5sum "$A32/s32-allowlist" | cut -d' ' -f1)" == "$pre_md5" ]] \
    && a32 pass || a32 fail "D2.1 allowlist unchanged after rejects"
d32_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" egresslock allow s32 "$h253" 2>&1)"; d32_rc=$?
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
d32_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" egresslock denied s32 --days 0 2>$TESTROOT/agent32f.err)"; d32_rc=$?
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
d32_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$A32/ah-bad.conf")" egresslock list 2>&1)"; d32_rc=$?
[[ "$d32_rc" == 2 && "$d32_out" == *"exceeds DNS length limits"* ]] \
    && a32 pass || a32 fail "D2.3 conf allow-host oversize (rc=$d32_rc out=$d32_out)"
printf 'profile c32 10.199.91.0/24\n    no-proxy %s\n' \
    "$(printf 'a%.0s' $(seq 1 254))" > "$A32/np-bad.conf"
d32_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$A32/np-bad.conf")" egresslock list 2>&1)"; d32_rc=$?
[[ "$d32_rc" == 2 && "$d32_out" == *"exceeds DNS length limits"* ]] \
    && a32 pass || a32 fail "D2.3 conf no-proxy oversize (rc=$d32_rc out=$d32_out)"
# Label > 63 in conf (host under 253) is rejected too.
printf 'profile c32 10.199.91.0/24\n    rule allow-host %s.test:443\n' "${L63}x" > "$A32/ah-label.conf"
d32_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$A32/ah-label.conf")" egresslock list 2>&1)"; d32_rc=$?
[[ "$d32_rc" == 2 && "$d32_out" == *"exceeds DNS length limits"* ]] \
    && a32 pass || a32 fail "D2.3 conf allow-host label 64 (rc=$d32_rc out=$d32_out)"

# D2.4 — CLI allow-host oversize dies as usage (rc 2), conf unchanged,
# no ensure runs (no podman run between the checks).
cp "$A32/s32.conf" "$A32/gw-keep.conf"
pre_md5="$(md5sum "$A32/s32.conf" | cut -d' ' -f1)"
pre_runs="$(wc -l < "$STATE/runlog")"
d32_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" egresslock allow-host s32 "$(printf 'a%.0s' $(seq 1 254)):443" 2>&1)"; d32_rc=$?
[[ "$d32_rc" == 2 && "$(md5sum "$A32/s32.conf" | cut -d' ' -f1)" == "$pre_md5" \
    && "$(wc -l < "$STATE/runlog")" == "$pre_runs" ]] \
    && a32 pass || a32 fail "D2.4 CLI allow-host oversize (rc=$d32_rc out=$d32_out)"

# D2.5 — a hand-edited allowlist line that is oversize fails `ensure`
# closed (the file path inherits the caps, ARC-59 D1.7 pattern).
printf '%s\n' "$(printf 'a%.0s' $(seq 1 254))" > "$A32/s32-allowlist"
d32_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$A32/s32.conf")" egresslock ensure s32 2>&1)"; d32_rc=$?
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

# D3.1b (EGL-203-D2) — the OCI base labels stamp the built image with
# the same base the FROM pins: both label keys present, and the label
# digest equals the FROM digest (drift guard — a pin refresh must move
# the label with it, never leave it behind).
c32_from_dig="$(grep '^FROM ' "$TREE_ROOT/gateway/Containerfile" \
    | grep -oE 'sha256:[0-9a-f]{64}' | head -1)"
c32_lbl_dig="$(grep -oE '^LABEL org\.opencontainers\.image\.base\.digest="sha256:[0-9a-f]{64}"$' \
    "$TREE_ROOT/gateway/Containerfile" | grep -oE 'sha256:[0-9a-f]{64}')"
if [[ -n "$c32_from_dig" && -n "$c32_lbl_dig" && "$c32_lbl_dig" == "$c32_from_dig" ]] \
      && grep -qE '^LABEL org\.opencontainers\.image\.base\.name="docker\.io/library/debian:13-slim"$' \
           "$TREE_ROOT/gateway/Containerfile"; then
    a32 pass
else
    a32 fail "D3.1b base labels missing or drifted from FROM (from=$c32_from_dig label=$c32_lbl_dig)"
fi

# D3.2 (EGL-232) — egl-base FROM is byte-equal to the gateway FROM
# (one pin refresh updates both; the battery fails if they drift).
c32_gw_from="$(grep '^FROM ' "$TREE_ROOT/gateway/Containerfile" | head -1)"
c32_egl_from="$(grep '^FROM ' "$TREE_ROOT/examples/egl-base/Containerfile" | head -1)"
if [[ -n "$c32_gw_from" && -n "$c32_egl_from" && "$c32_egl_from" == "$c32_gw_from" ]]; then
    a32 pass
else
    a32 fail "D3.2 egl-base FROM drifted from gateway (gw=$c32_gw_from egl=$c32_egl_from)"
fi

# D3.2b (EGL-240) — egl-base OCI base labels stamp the built image
# with the same base the FROM pins (same shape as D3.1b).
c32_egl_from_dig="$(grep '^FROM ' "$TREE_ROOT/examples/egl-base/Containerfile" \
    | grep -oE 'sha256:[0-9a-f]{64}' | head -1)"
c32_egl_lbl_dig="$(grep -oE '^LABEL org\.opencontainers\.image\.base\.digest="sha256:[0-9a-f]{64}"$' \
    "$TREE_ROOT/examples/egl-base/Containerfile" | grep -oE 'sha256:[0-9a-f]{64}')"
if [[ -n "$c32_egl_from_dig" && -n "$c32_egl_lbl_dig" && "$c32_egl_lbl_dig" == "$c32_egl_from_dig" ]] \
      && grep -qE '^LABEL org\.opencontainers\.image\.base\.name="docker\.io/library/debian:13-slim"$' \
           "$TREE_ROOT/examples/egl-base/Containerfile"; then
    a32 pass
else
    a32 fail "D3.2b egl-base base labels missing or drifted from FROM (from=$c32_egl_from_dig label=$c32_egl_lbl_dig)"
fi

# D4.1 — NOPASSWD documented as unsupported; no sudoers file shipped.
if grep -q 'NOPASSWD' "$TREE_ROOT/docs/setup/install.md" \
   && grep -q 'NOPASSWD' "$TREE_ROOT/docs/reference/threat-model.md" \
   && [[ -z "$(find "$TREE_ROOT" -name '*sudoers*' -not -path '*/tests/*' 2>/dev/null)" ]]; then
    a32 pass
else
    a32 fail "D4.1 NOPASSWD docs / no sudoers file"
fi

section_end arc32

# --- ARC-66: teardown --runtime sweeps our nft table ----------------------
# D4: `inet egresslock` (live policy) is deleted best-effort by the
# no-conf sweep (missing/netns-gone = skip, delete failure = note + rc 0).
section_begin arc66 "ARC-66 runtime table sweep"
a66() { assert "$@"; }

# Reuse the ARC-60 fixture shape: kit runtime with NO conf anywhere.
H66="$TESTROOT/h66"; rm -rf "$H66"; mkdir -p "$H66"
run_a66() { env HOME="$H66" ARCMOCK_PASSWD_HOME="$H66" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

# 1. The live table present with kit runtime -> deleted, named in the
#    output, rc 0.
mk_a60_runtime
printf 'chain p_lg {\n}\n' > "$STATE/nft/egresslock.p_lg"
o="$(run_a66 teardown --runtime 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"removed nft table inet egresslock"* \
      && ! -e "$STATE/nft/egresslock.p_lg" ]]; then
    a66 pass
else
    a66 fail "D4 --runtime deletes the table (rc=$rc, out: $o)"
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

section_end arc66

# --- ARC-67: network ls {{.Name}} + fail-loud list policies ----------------
# D1/D2/D3: the helper uses {{.Name}} (the mock rejects {{.Names}} like
# the real binary); a broken network list kills `ensure` (fail closed),
# is "taken" for init, and only notes for --runtime.
section_begin arc67 "ARC-67 network ls"
a67() { assert "$@"; }

# Failing-list podman shim: delegates to the mock except network ls.
S67="$TESTROOT/s67"; rm -rf "$S67"; mkdir -p "$S67/bin" "$S67/conf"
printf 'profile s67 10.199.92.0/24\n' > "$S67/conf/s67.conf"
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
run67() { env PATH="$S67/bin:$PATH" ARCMOCK_PASSWD_HOME="$(conf_home "$S67/conf/s67.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

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

section_end arc67

# --- ARC-71: --runtime dispatches before the netns probe ------------------
# D1: the recovery sweep runs with a wedged rootless netns (probe would
# fail). D2: conf-scoped teardown still probes (and still fails loud).
section_begin arc71 "ARC-71 probe dispatch"
a71() { assert "$@"; }

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
o="$(env HOME="$H71" ARCMOCK_PASSWD_HOME="$H71" egresslock teardown --runtime 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"removed container egresslock-anchor-main"* \
    && "$o" == *"removed network egresslock-main"* \
    && "$o" == *"removed nft table inet egresslock"* \
    && ! -e "$STATE/running/egresslock-anchor-main" && ! -e "$STATE/networks/egresslock-main" ]] \
    && a71 pass || a71 fail "D1 --runtime runs with a wedged netns (rc=$rc, out: $o)"

# 2. D2: conf-scoped teardown still probes and still fails loud with the
#    ARC-26 guidance (re-seed the network: test 1 swept it).
printf 'profile main 10.199.0.0/24\n' > "$H71/main.conf"
printf 'driver=bridge\nsubnet=10.199.0.0/24\n' > "$STATE/networks/egresslock-main"
o="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H71/main.conf")" HOME="$H71" egresslock teardown main 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"rootless-netns is broken"* \
    && -f "$STATE/networks/egresslock-main" ]] \
    && a71 pass || a71 fail "D2 conf-scoped teardown still probes (rc=$rc, out: $o)"

rm -f "$STATE/netns-broken"
section_end arc71

# --- ARC-69: teardown/ensure output honesty --------------------------------
# D1: removed / not present / kept (in use) decided by existence + rm rc.
# D2: the nft note only when it is true; nothing-left summary on a no-op.
# D3: ensure announces the anchor only on the actual create. D4: bare
# teardown is a usage error naming every form.
section_begin arc69 "ARC-69 output honesty"
a69() { assert "$@"; }

H69="$TESTROOT/h69"; rm -rf "$H69"; mkdir -p "$H69"
cat > "$H69/main.conf" <<'EOF'
profile main 10.199.0.0/24
    rule gateway-only
    gateway 10.199.0.2 3128 main-allowlist
EOF
: > "$H69/main-allowlist"
run69() { env ARCMOCK_PASSWD_HOME="$(conf_home "$H69/main.conf")" HOME="$H69" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

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

# 3b. EGL-325 A7: `teardown all` is the main.conf-only form. A sibling
#     profile exists and is untouched; the no-op sentence must name the
#     one profile it read, not "any profile".
printf 'profile z9 10.199.88.0/24\n' > "$H69/z9.conf"
o="$(run69 teardown all 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"nothing left for profile 'main' (teardown all reads main.conf only)"* \
      && "$o" != *"nothing left for any profile"* \
      && -f "$H69/z9.conf" ]]; then
    a69 pass
else
    a69 fail "A7 teardown all names main.conf only (rc=$rc, out: $o)"
fi
rm -f "$H69/z9.conf"

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
o="$(env HOME="$H69" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
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
o="$(env HOME="$H69" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
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

section_end arc69

# --- EGL-202: uninstall safety-prerequisite pins (R-EGL-202-3 F1/F2) -------
# Docs-only ticket; escalated review required narrow mock-backed coverage
# of the shipped behavior the uninstall page must spell out:
#   F1: `teardown --runtime` is account-scoped — cleaning account A leaves
#       B's store untouched (the runtime set can exceed the enabled-timer
#       set).
#   F2: a non-kit workload on a kit network SURVIVES the sweep while the
#       netns nft table is deleted, and the in-use network is kept (stop
#       attached workloads BEFORE teardown).
# These pins model the hazards, not a claim that teardown is unsafe by
# default (same findings independently probed; see ticket R-EGL-202-3).
section_begin egl202 "EGL-202 teardown scope pins (uninstall prerequisites)"
a202() { assert "$@"; }

# Per-account stores: the mock's ARCMOCK_STATE dir IS one account's
# rootless Podman store.
SA202="$TESTROOT/h202-a"; SB202="$TESTROOT/h202-b"
mk_egl202_store() { # mk_egl202_store <dir>
    rm -rf "$1"; mkdir -p "$1/nft" "$1/networks" "$1/running" "$1/containers"
    : > "$1/running/egresslock-anchor-main"
    echo "egresslock-main" > "$1/containers/egresslock-anchor-main.net"
    printf 'driver=bridge\nsubnet=10.199.0.0/24\n' > "$1/networks/egresslock-main"
    printf 'chain filter {\n}\n' > "$1/nft/egresslock.filter"
}
run_egl202() { # run_egl202 <store> <engine args...>
    local st="$1"; shift
    env ARCMOCK_STATE="$st" HOME="$st" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        egresslock "$@"
}

# F1: account-A cleanup leaves account-B untouched.
mk_egl202_store "$SA202"
mk_egl202_store "$SB202"
o="$(run_egl202 "$SA202" teardown --runtime 2>&1)"; rc=$?
[[ "$rc" == 0 \
    && "$o" == *"removed container egresslock-anchor-main"* \
    && "$o" == *"removed network egresslock-main"* \
    && "$o" == *"removed nft table inet egresslock"* \
    && ! -e "$SA202/running/egresslock-anchor-main" \
    && ! -e "$SA202/networks/egresslock-main" \
    && ! -e "$SA202/nft/egresslock.filter" ]] \
    && a202 pass || a202 fail "F1 account-A sweep removes A's runtime (rc=$rc, out: $o)"
[[ -f "$SB202/running/egresslock-anchor-main" \
    && -f "$SB202/networks/egresslock-main" \
    && -f "$SB202/nft/egresslock.filter" ]] \
    && a202 pass || a202 fail "F1 account-B store untouched by account-A sweep"

# F2: a non-kit workload attached to the kit network survives the sweep
# while the nft enforcement table is deleted; the in-use network is kept.
mk_egl202_store "$SA202"
: > "$SA202/running/agent-opencode"
echo "egresslock-main" > "$SA202/containers/agent-opencode.net"
touch "$SA202/network-rm-fails"
o="$(run_egl202 "$SA202" teardown --runtime 2>&1)"; rc=$?
[[ "$rc" == 0 \
    && "$o" == *"removed container egresslock-anchor-main"* \
    && "$o" == *"kept network egresslock-main (in use)"* \
    && "$o" == *"removed nft table inet egresslock"* \
    && -f "$SA202/running/agent-opencode" \
    && -f "$SA202/containers/agent-opencode.net" \
    && ! -e "$SA202/nft/egresslock.filter" ]] \
    && a202 pass || a202 fail "F2 attached non-kit workload survives while nft enforcement is deleted (rc=$rc, out: $o)"
rm -f "$SA202/network-rm-fails"

section_end egl202

# --- EGL-31: engine output hygiene (bare command name; no stale doc path) -
# D1 grep-guard: no engine output string references the hard-coded
# /opt/egresslock/egresslock path or the never-existed how-to/ page.
# (The launchers' `-x /opt/...` ENGINE-RESOLUTION probes are code, not
# output, and stay — ARC-16-D4.)
section_begin egl31 "EGL-31 output hygiene"
a31b() { assert "$@"; }

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

section_end egl31

# --- EGL-45: engine doctor (host environment probe) -------------------------
# This container has no podman/nft/netavark, so the MISSING branch is the
# natural state; a stub PATH supplies the all-present shape.
section_begin egl45 "EGL-45 doctor"
a45() { assert "$@"; }

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
d_out="$(env NFT_BIN=/nonexistent PATH="$none45:$TREE_ROOT" egresslock doctor 2>&1)"; d_rc=$?
[[ "$d_rc" == 1 && "$d_out" == *"podman: MISSING"* \
    && "$d_out" == *"netavark: MISSING"* && "$d_out" == *"nft: MISSING"* \
    && "$d_out" != *"no profile config"* ]] \
    && a45 pass || a45 fail "doctor without conf, missing tools (rc=$d_rc, out: $d_out)"
[[ "$d_out" == *"rootless_netns: skipped (podman MISSING)"* ]] \
    && a45 pass || a45 fail "netns probe skipped when podman missing"
# EGL-226-D6: the gateway-image row joins the podman-MISSING skip (additive
# assert — the required-row asserts above are unchanged).
[[ "$d_out" == *"gateway image: skipped (podman MISSING)"* ]] \
    && a45 pass || a45 fail "gateway image row skipped when podman missing"

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
d_out="$(env EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
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
d_out="$(env EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$stub45:$PATH" egresslock doctor 2>"$d_err")"; d_rc=$?
# EGL-80-L4: the old `network_backend: unknown` sub-assert asserted HOST
# state (no pasta/slirp4netns on the inherited PATH), not engine behavior
# — on a deployed host with pasta installed it fails while the behavior
# under test (advisory fail row + rc 0 + hint) is correct. The pasta
# branch is covered hermetically by case 4 below (its own stub pasta);
# the `unknown` branch stays covered on hosts without pasta. Restored
# without the sub-assert (EGL-81: the EGL-80-L4 decision stands).
[[ "$d_rc" == 0 && "$d_out" == *"rootless_netns: fail:kill network process: permission denied"* \
    && "$(grep -c 'apparmor check' "$d_err")" -ge 1 ]] \
    && a45 pass || a45 fail "advisory netns fail keeps rc 0 + apparmor hint (rc=$d_rc, out: $d_out)"

# 4. pasta on PATH -> advisory network_backend: pasta.
printf '#!/bin/sh\n' > "$stub45/pasta"; chmod +x "$stub45/pasta"
d_out="$(env EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" PATH="$stub45:$PATH" egresslock doctor 2>/dev/null)"
[[ "$d_out" == *"network_backend: pasta"* ]] \
    && a45 pass || a45 fail "advisory network_backend pasta (out: $d_out)"

# 4b. R-EGL-45-1 note 1: a NON-AppArmor netns failure (not rc 126, not
#     permission denied) must NOT get the apparmor check pointer.
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
d_out="$(env EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$stub45:$PATH" egresslock doctor 2>"$d_err")"; d_rc=$?
[[ "$d_rc" == 0 && "$d_out" == *"rootless_netns: fail:cgroup manager died unexpectedly"* \
    && "$(grep -c 'apparmor check' "$d_err")" == 0 ]] \
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
d_out="$(env EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$stub45:$PATH" egresslock doctor 2>&1)"; d_rc=$?
[[ "$d_rc" == 0 && "$d_out" == *"userns: enabled"* ]] \
    && a45 pass || a45 fail "userns row enabled, rc not forced (rc=$d_rc, out: $d_out)"

# 4d. hook -> fixture `0` -> `userns: disabled`, doctor rc 1.
d_out="$(env EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-off" \
    PATH="$stub45:$PATH" egresslock doctor 2>&1)"; d_rc=$?
[[ "$d_rc" == 1 && "$d_out" == *"userns: disabled"* ]] \
    && a45 pass || a45 fail "userns row disabled forces rc 1 (rc=$d_rc, out: $d_out)"

# 4e. hook -> absent path -> gateless message, row does not force rc 1.
d_out="$(env EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-absent/gate" \
    PATH="$stub45:$PATH" egresslock doctor 2>&1)"; d_rc=$?
[[ "$d_rc" == 0 \
    && "$d_out" == *"userns: enabled (kernel has no unprivileged_userns_clone gate)"* ]] \
    && a45 pass || a45 fail "userns row gateless, rc not forced (rc=$d_rc, out: $d_out)"

# 5. Extra argument -> rc 2 (usage class).
env egresslock doctor something >/dev/null 2>&1
[[ $? == 2 ]] && a45 pass || a45 fail "doctor extra argument exits 2"

# 6. Root guard (mock id reports uid 0), same message as other commands.
r_out="$(PATH="$TESTROOT/bin-root:$PATH" env egresslock doctor 2>&1)"; r_rc=$?
[[ "$r_rc" == 1 && "$r_out" == *"must run as the account, not root"* ]] \
    && a45 pass || a45 fail "doctor root guard (rc=$r_rc, out: $r_out)"

# 7. --help and short usage list doctor.
egresslock --help | grep -q "egresslock doctor" \
    && a45 pass || a45 fail "--help lists doctor"
egresslock 2>&1 | grep -q "doctor" \
    && a45 pass || a45 fail "short usage lists doctor"

# 7b. EGL-286: the doctor prose (the advisory rows it prints) moved to
#     `help doctor` — the topic page must still name them.
egresslock help doctor | grep -q "podman, netavark, nft" \
    && a45 pass || a45 fail "help doctor lists the probed tools"
egresslock help doctor | grep -q "egresslock-setup --help" \
    && a45 pass || a45 fail "help doctor carves out egresslock-setup"

# 8/9. EGL-85-D1: the two bounded branches of the doctor's advisory netns
#      probe (EGL-78) no earlier case covers — timeout(1) absent and probe
#      expiry (rc 124) — pinning against an unbounded probe or a misrouted
#      rc-124 hint.
# 8. timeout(1) absent: isolated PATH with healthy stubs but NO timeout;
#    the fail row names coreutils, generic hint (not apparmor), rc 0.
nt45="$TESTROOT/bin-doctor-notimeout"
rm -rf "$nt45"; mkdir -p "$nt45"
for t in env bash cat id head dirname; do ln -s "$(command -v "$t")" "$nt45/$t"; done
# EGL-139-D2: conntrack is a REQUIRED doctor row — the fixture carries a
# stub so this test isolates the timeout-absent ADVISORY row only (rc 0),
# not a conntrack MISSING rc-1.
cp "$stub45/podman" "$stub45/netavark" "$stub45/nft" "$stub45/conntrack" "$nt45/"
d_out="$(env EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$nt45:$TREE_ROOT" egresslock doctor 2>"$d_err")"; d_rc=$?
[[ "$d_rc" == 0 \
    && "$d_out" == *"rootless_netns: fail:timeout(1) (coreutils) not found in PATH"* \
    && "$(grep -c 'apparmor-check' "$d_err")" == 0 ]] \
    && a45 pass || a45 fail "doctor timeout-absent advisory row, rc 0 (rc=$d_rc, out: $d_out)"

# 9. probe expiry: podman shim sleeps 60s on the probe command only,
#    delegating everything else to the healthy stub. The rc-124 branch
#    must produce the named 5s-timeout row with the GENERIC
#    run-as-the-dedicated-account hint (deliberately NOT
#    apparmor check) and keep rc 0, well under the harness bound.
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
d_out="$(env EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$TESTROOT/bin-doctor-hang:$stub45:$PATH" egresslock doctor 2>"$d_err")"; d_rc=$?
d_elapsed=$(( SECONDS - d_start ))
[[ "$d_rc" == 0 && "$d_out" == *"rootless_netns: fail: probe timed out after 5s"* \
    && "$(grep -c 'run as the dedicated account' "$d_err")" -ge 1 \
    && "$(grep -c 'apparmor check' "$d_err")" == 0 && "$d_elapsed" -lt 15 ]] \
    && a45 pass || a45 fail "doctor probe expiry: 5s row + generic hint, rc 0 (rc=$d_rc, elapsed=${d_elapsed}s, out: $d_out, err: $(cat "$d_err"))"

section_end egl45

# --- EGL-226: doctor gateway-image staleness row (engine, account-side) ----
# The engine doctor mirrors the kit doctor's staleness peek
# (egresslock-setup kit_check_gateway) conf-less: image via gw_image(), pin
# from the ENGINE'S NEIGHBOR gateway/Containerfile (build-gateway's
# context), state via the rt_* seam. Rows are advisory/rc-neutral. Fixture
# bin-doctor-e226 wraps podman via ARCMOCK_STATE and delegates to healthy
# stubs. Cases mirror kit egl203 1-4 plus D10
# empty-inspect.
section_begin egl226 "EGL-226 doctor gateway-image staleness row"
a226() { assert "$@"; }

ENG226="$TREE_ROOT/egresslock"
E226IMG="localhost/egresslock-gateway:e226"   # isolated from the shared default fixture
e226state="$(echo "$E226IMG" | tr '/:' '__')"
E226IMGF="$STATE/images/$e226state"
E226INS="$STATE/image-inspect-$e226state"
# Pin source = the engine-under-test's neighbor; egl226 runs the TREE engine
# (never rewriting tree files) except case 2's copied engine.
e226dig="$(grep -oE 'sha256:[0-9a-f]{64}' "$TREE_ROOT/gateway/Containerfile" | head -1)"
e226short="${e226dig#sha256:}"; e226short="${e226short:0:12}"

# Restore the HEALTHY stub45/podman (a later egl45 case may have left a
# failure-shaped stub behind; the case-2 body below).
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

# The e226 podman wrapper: image exists/inspect from ARCMOCK_STATE markers
# (same tr'/:'->'__' layout as lib.sh), everything else execs stub45/podman.
mkdir -p "$TESTROOT/bin-doctor-e226"
cat > "$TESTROOT/bin-doctor-e226/podman" <<EOF
#!/usr/bin/env bash
D="\${ARCMOCK_STATE:?}"
if [[ "\$1" == image && "\$2" == exists ]]; then
    [[ -f "\$D/images/\$(echo "\$3" | tr '/:' '__')" ]] && exit 0
    exit 1
fi
if [[ "\$1" == image && "\$2" == inspect ]]; then
    img="\${@: -1}"
    [[ -f "\$D/images/\$(echo "\$img" | tr '/:' '__')" ]] \
        || { echo "Error: no such image \$img" >&2; exit 1; }
    if [[ -f "\$D/image-inspect-\$(echo "\$img" | tr '/:' '__')" ]]; then
        cat "\$D/image-inspect-\$(echo "\$img" | tr '/:' '__')"
        exit 0
    fi
    exit 0
fi
exec "$stub45/podman" "\$@"
EOF
chmod +x "$TESTROOT/bin-doctor-e226/podman"

e226run() { # e226run [engine] — env'd doctor invocation (rc-neutral expectation 0)
    env EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
        EGRESSLOCK_GW_IMAGE="$E226IMG" \
        PATH="$TESTROOT/bin-doctor-e226:$stub45:$PATH" \
        "${1:-$ENG226}" doctor 2>&1
}

# 1. Label == deployed pin -> present row with base (short digest) + built
#    date, no stale line, rc 0.
: > "$E226IMGF"
printf '%s 2026-09-01T00:00:00.000000000Z\n' "$e226dig" > "$E226INS"
o="$(e226run)"; rc=$?
[[ "$rc" == 0 && "$o" == *"gateway image: present ($E226IMG) — base $e226short"* \
    && "$o" == *", built 2026-09-01"* && "$o" != *"stale:"* ]] \
    && a226 pass || a226 fail "match row: base + built, rc-neutral (rc=$rc, out: $o)"

# 2. Pin moved in the COPIED engine's neighbor (the tree Containerfile is
#    never touched): stale row names both sides + the account-shell rebuild
#    pointer (byte-identical to the kit doctor's), rc 0.
rm -rf "$STATE/e226"; mkdir -p "$STATE/e226/kit/gateway"
cp "$ENG226" "$STATE/e226/kit/egresslock"
printf 'FROM docker.io/library/debian:13-slim@sha256:%064d\n' 0 \
    > "$STATE/e226/kit/gateway/Containerfile"
o="$(e226run "$STATE/e226/kit/egresslock")"; rc=$?
[[ "$rc" == 0 && "$o" == *"gateway image: present ($E226IMG) — base $e226short"* \
    && "$o" == *"stale: base pin moved (image base $e226short != deployed pin 000000000000) — rebuild in the account shell: egresslock build-gateway && egresslock ensure --replace-gateway <profile> per affected profile (see \"The gateway image\" reference page)"* ]] \
    && a226 pass || a226 fail "pin-moved stale row with pointer, rc-neutral (rc=$rc, out: $o)"

# 3. Pre-label image (inspect answered, base empty): the pre-label row +
#    the pre-label stale pointer, rc 0.
printf ' 2026-08-01T00:00:00.000000000Z\n' > "$E226INS"
o="$(e226run)"; rc=$?
[[ "$rc" == 0 \
    && "$o" == *"gateway image: present ($E226IMG) — base unknown (pre-label image), built 2026-08-01"* \
    && "$o" == *"stale: base unknown (pre-label image) — rebuild in the account shell: egresslock build-gateway && egresslock ensure --replace-gateway <profile> per affected profile (see \"The gateway image\" reference page)"* ]] \
    && a226 pass || a226 fail "pre-label row with pointer, rc-neutral (rc=$rc, out: $o)"

# 3b. EGL-254: the literal "<no value>" marker (missing Go-template key)
#     must classify exactly like the empty label — pre-label row +
#     pointer, never a "base <no" or "base pin moved" claim, rc 0.
printf '<no value> 2026-08-01T00:00:00.000000000Z\n' > "$E226INS"
o="$(e226run)"; rc=$?
[[ "$rc" == 0 \
    && "$o" == *"gateway image: present ($E226IMG) — base unknown (pre-label image), built 2026-08-01"* \
    && "$o" == *"stale: base unknown (pre-label image)"* \
    && "$o" != *"base pin moved"* && "$o" != *"<no value>"* ]] \
    && a226 pass || a226 fail "literal <no value> pre-label row, rc-neutral (rc=$rc, out: $o)"

# 4. Inspect FAILS (per-case wrapper exits 1 on image inspect, otherwise
#    execs the e226 wrapper): degrades to a bare base unknown — no
#    pre-label guess, no stale claim, rc 0.
mkdir -p "$STATE/e226/bin-inspectfail"
cat > "$STATE/e226/bin-inspectfail/podman" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == image && "\$2" == inspect ]]; then echo "mock: inspect denied" >&2; exit 1; fi
exec "$TESTROOT/bin-doctor-e226/podman" "\$@"
EOF
chmod +x "$STATE/e226/bin-inspectfail/podman"
o="$(env EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    EGRESSLOCK_GW_IMAGE="$E226IMG" \
    PATH="$STATE/e226/bin-inspectfail:$TESTROOT/bin-doctor-e226:$stub45:$PATH" \
    "$ENG226" doctor 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"gateway image: present ($E226IMG) — base unknown"* \
    && "$o" != *"pre-label"* && "$o" != *"stale:"* ]] \
    && a226 pass || a226 fail "inspect failure degrades to base unknown, rc-neutral (rc=$rc, out: $o)"

# 4b. EGL-226-D10: inspect rc 0 but EMPTY output is inspect-failed too —
#     never pre-label, never stale (the kit's exact hazard). Plain e226
#     run (no inspectfail wrapper in front): the wrapper itself answers
#     from the emptied fixture, rc 0 / empty, so D10's non-empty-inspect
#     discriminator is actually exercised (R-EGL-226-2 F1).
: > "$E226INS"
o="$(e226run)"; rc=$?
[[ "$rc" == 0 && "$o" == *"gateway image: present ($E226IMG) — base unknown"* \
    && "$o" != *"pre-label"* && "$o" != *"stale:"* ]] \
    && a226 pass || a226 fail "empty inspect output is base unknown, never pre-label (rc=$rc, out: $o)"

# 5. Image missing -> informational missing row + the account-shell build
#    pointer (NOT the kit's rc-1), rc 0.
rm -f "$E226IMGF" "$E226INS"
o="$(e226run)"; rc=$?
[[ "$rc" == 0 && "$o" == *"gateway image: missing ($E226IMG)"* \
    && "$o" == *"build it in the account shell: egresslock build-gateway (see \"The gateway image\" reference page)"* ]] \
    && a226 pass || a226 fail "missing-image row informational, rc-neutral (rc=$rc, out: $o)"

# 6. Conf-less class guard: no resolution line, no conf error on stdout.
o="$(env EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    EGRESSLOCK_GW_IMAGE="$E226IMG" \
    PATH="$TESTROOT/bin-doctor-e226:$stub45:$PATH" "$ENG226" doctor 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" != *"using config"* && "$o" != *"no profile config"* \
    && "$o" != *"scoped:"* ]] \
    && a226 pass || a226 fail "no conf resolution for doctor (rc=$rc, out: $o)"

# 7. EGL-226-D9: the doctor help page names the advisory image row
#    (asserted against the TREE engine, not a copied fixture; EGL-286
#    moved the bullet from top-level --help to the doctor topic page).
"$ENG226" help doctor | grep -q "gateway image base" \
    && a226 pass || a226 fail "help doctor names gateway image base"

# Keep the store clean for later sections (the deep reset re-creates only
# its own markers).
rm -rf "$STATE/e226" "$E226IMGF" "$E226INS"

section_end egl226

# --- ARC-74: deep state semantics (relocated from the site harness and
# --- neutralized to synthetic fixtures) ----------------------------------
# The tamper/re-ensure, v6deny self-heal, policy/anchor loss recovery and
# rule-order battery existed only in the site harness. Neutral copier
# fixtures (ARC-13-D5): docs-range IPs + example.test hosts, and
# one-profile-per-file synthetic confs replacing the site conf.
section_begin deep "ARC-74 deep state semantics, synthetic"
rm -rf "$STATE"
mkdir -p "$STATE/nft" "$STATE/networks" "$STATE/running" "$STATE/containers" \
         "$STATE/images" "$STATE/ips" "$STATE/runargs"
: > "$STATE/images/localhost_egresslock-gateway_latest"
# EGL-206-D2a: the anchor preflight inspects the RESOLVED anchor image
# before the run; re-seed the harness anchor marker after the state
# reset (the mock `podman run` never pulls).
: > "$STATE/images/docker.io_library_alpine_latest"
mkdir -p "$TESTROOT/deep"
: > "$TESTROOT/deep/llm-allowlist"
cat > "$TESTROOT/deep/local-dev.conf" <<'EOF'
profile local-dev 10.50.0.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
    rule allow-host ${FORGEJO_HOST:-git.example.test}:2222
    rule allow-host ${OLLAMA_HOST:-cache.example.test}:11434
EOF
cat > "$TESTROOT/deep/internet-only.conf" <<'EOF'
profile internet-only 10.50.1.0/24
EOF
cat > "$TESTROOT/deep/llm-cloud.conf" <<'EOF'
profile llm-cloud 10.50.2.0/24
    rule gateway-only
    gateway 10.50.2.2 3128 llm-allowlist
EOF
cat > "$TESTROOT/deep/dev-llm.conf" <<'EOF'
profile dev-llm 10.50.3.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
    rule allow-host ${FORGEJO_HOST:-git.example.test}:2222
    rule allow-host ${OLLAMA_HOST:-cache.example.test}:11434
    rule gateway-only
    gateway 10.50.3.2 3128 llm-allowlist
    no-proxy ${FORGEJO_HOST:-git.example.test},${OLLAMA_HOST:-cache.example.test}
EOF
# EGL-323: the fixture confs are one-profile-per-file; the section-local
# wrapper loads the conf of the profile named last (every invocation here
# names exactly one profile, last).
de() { env ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/deep/${@: -1}.conf")" egresslock "$@"; }
export ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/deep/local-dev.conf")"
# Setup ensures are uncounted harness setup (their asserts live in the
# site smoke battery); the moved block below opens its own counter.
de ensure local-dev >/dev/null 2>&1
de ensure internet-only >/dev/null 2>&1
de ensure llm-cloud >/dev/null 2>&1
de ensure dev-llm >/dev/null 2>&1
# R-003-2 regression 1: re-install over a POPULATED chain must work
# (flush+delete refresh, then clean re-add). The mock now rejects
# add-over-existing and delete-of-populated, so a plain delete+apply
# would fail here.
rule_count=$(grep -c 'daddr 192.0.2.10 tcp dport 443' "$STATE/nft/egresslock.p_local_dev")
[[ "$rule_count" == 1 ]] && { _sect_bump pass; echo "PASS: re-ensure does not duplicate rules"; } || { _sect_bump fail; echo "FAIL: re-ensure duplicated rules (count=$rule_count)"; }
# R-003-2 regression 2: the shared v6deny chain is NOT redeclared on
# re-ensure (would fail the whole transaction).
check "re-ensure keeps shared v6deny intact" 0 test -f "$STATE/nft/egresslock.p_v6deny"
# R-003-2 regression 3: a populated chain with STALE rules is fully
# replaced, not merged: rewrite the chain with a bogus rule, re-ensure,
# and confirm the stale rule is gone.
echo "ip saddr 10.50.0.0/24 ip daddr 203.0.113.9 tcp dport 9999 counter accept" >> "$STATE/nft/egresslock.p_local_dev"
check "re-ensure over stale populated chain" 0 de ensure local-dev
grep -q '203.0.113.9' "$STATE/nft/egresslock.p_local_dev" \
    && { echo "FAIL: stale rule survived re-ensure"; _sect_bump fail; } \
    || { echo "PASS: stale rules replaced on re-ensure"; _sect_bump pass; }
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
check "ensure rejects network with wrong subnet" 1 de ensure local-dev
mocknet egresslock-local-dev 10.50.0.0/24 false
# b) IPv6 enabled
mocknet egresslock-local-dev 10.50.0.0/24 true
check "ensure rejects network with IPv6 enabled" 1 de ensure local-dev
mocknet egresslock-local-dev 10.50.0.0/24 false
check "ensure accepts matching network" 0 de ensure local-dev

# R-003-3 regression 2: deep verification.
# a) tampered chain: strip the DNS allow from internet-only (EGL-153
#    reworked the subject after a rule class left the grammar); the
#    shallow terminal-rule check would have passed this.
cp "$STATE/nft/egresslock.p_internet_only" "$TESTROOT/backup.io"
grep -v 'th dport 53' "$STATE/nft/egresslock.p_internet_only" > "$STATE/nft/egresslock.p_internet_only.tmp" \
    && mv "$STATE/nft/egresslock.p_internet_only.tmp" "$STATE/nft/egresslock.p_internet_only"
check "verify rejects internet-only chain missing DNS allow" 1 de verify internet-only
de ensure internet-only >/dev/null 2>&1
check "ensure restores tampered internet-only chain" 0 de verify internet-only
# b) tampered chain: local-dev missing the forgejo allows.
grep -v 'daddr 192.0.2.10' "$STATE/nft/egresslock.p_local_dev" > "$STATE/nft/egresslock.p_local_dev.tmp" \
    && mv "$STATE/nft/egresslock.p_local_dev.tmp" "$STATE/nft/egresslock.p_local_dev"
check "verify rejects local-dev chain missing forgejo rules" 1 de verify local-dev
de ensure local-dev >/dev/null 2>&1
check "ensure restores tampered local-dev chain" 0 de verify local-dev
# c) missing shared v6-deny chain must fail verification.
rm -f "$STATE/nft/egresslock.p_v6deny"
check "verify fails when v6deny chain missing" 1 de verify local-dev
check "ensure reinstalls v6deny chain" 0 de ensure local-dev
# c2) legacy polluted v6deny (pre-rework versions appended a duplicate
#     drop rule per install under real additive semantics) must be
#     self-healed by install, not just rejected by verify.
cp "$STATE/nft/egresslock.p_v6deny" "$TESTROOT/v6.bak"
echo "meta nfproto ipv6 counter drop" >> "$STATE/nft/egresslock.p_v6deny"
echo "meta nfproto ipv6 counter drop" >> "$STATE/nft/egresslock.p_v6deny"
check "verify rejects v6deny with duplicate drops" 1 de verify local-dev
check "ensure self-heals polluted v6deny chain" 0 de ensure local-dev
check "verify passes after v6deny self-heal" 0 de verify local-dev
[[ "$(grep -c 'meta nfproto ipv6 counter drop' "$STATE/nft/egresslock.p_v6deny")" == 1 ]] \
    && { echo "PASS: v6deny self-heal leaves exactly one drop rule"; _sect_bump pass; } \
    || { echo "FAIL: v6deny self-heal left duplicates"; _sect_bump fail; }
# d) extra foreign rule in the chain must fail verification.
echo "ip saddr 10.50.0.0/24 ip daddr 203.0.113.9 tcp dport 9999 counter accept" >> "$STATE/nft/egresslock.p_local_dev"
check "verify fails on unexpected extra rule" 1 de verify local-dev
de ensure local-dev >/dev/null 2>&1
check "ensure cleans foreign rule" 0 de verify local-dev

# R-003-4 regression 1: canonicalize must handle INDENTED nft output
# (real 'nft list chain' format). The mock now emits indented bodies;
# verify below exercises it. Assert explicitly that verify works with
# indented output (it aborted before the fix).
check "verify works on indented real-format nft output" 0 de verify local-dev
# (EGL-270 P3: a dead `grep … "$TESTROOT/unused" || true` no-op line that
# could never fail sat here — deleted; the real mock-drift guard below is
# the kept assert.)
indented="$(PATH="$TESTROOT/bin:$PATH" bash -c "podman unshare --rootless-netns nft list chain inet egresslock p_local_dev" 2>/dev/null | grep -c '^        ip saddr')"
[[ "${indented:-0}" -gt 0 ]] && { _sect_bump pass; echo "PASS: mock nft emits indented rules"; } || { _sect_bump fail; echo "FAIL: mock nft not emitting indented rules"; }

# R-003-4 regression 2: a network with the expected subnet PLUS an extra
# subnet must be rejected (fail closed).
cat > "$STATE/networks/egresslock-local-dev" <<EOF2
subnet=10.50.0.0/24
subnet=10.50.4.0/24
gateway=10.50.0.1
ipv6_enabled=false
EOF2
check "ensure rejects network with two subnets" 1 de ensure local-dev
mocknet egresslock-local-dev 10.50.0.0/24 false
check "ensure accepts single-subnet network again" 0 de ensure local-dev

# Simulate the ARC-1 attempt-3 finding: netns state destroyed when the last
# container stops. Clear nft state; verify must fail; ensure must recover.
rm -f "$STATE/nft/"*
check "verify fails when policy lost (fail closed)" 1 de verify local-dev
check "ensure reinstalls lost policy" 0 de ensure local-dev
check "verify succeeds after re-ensure" 0 de verify local-dev

# Simulate the anchor dying: verify must fail, ensure must recover.
rm -f "$STATE/running/egresslock-anchor-local-dev"
check "verify fails when anchor dead" 1 de verify local-dev
check "ensure restarts anchor + verifies" 0 de ensure local-dev

# The site battery's agent-run wrapper ensured this chain silently on its
# way here; re-ensure it (uncounted) so the R-003-7 assertions exercise
# the reorder, not the missing chain. EGL-91-D2: a FIRST ensure now ends
# on the create-with-rules transaction (no flush); the second call is a
# warm ensure whose last transaction is the flush+re-add refresh these
# assertions target.
de ensure internet-only >/dev/null 2>&1
de ensure internet-only >/dev/null 2>&1

# --- R-003-7 regressions (EGL-106 retarget) ---
# 1. Atomic refresh: the chain replacement is ONE nft transaction (flush +
#    rules). EGL-106: the WHOLE install (v6deny + profile) is one file, so
#    the single transaction carries both: the profile chain flush with its
#    re-added ip saddr rules and the p_v6deny block. A split two-file
#    install no longer passes.
if grep -q '^flush chain inet egresslock p_internet_only' "$STATE/nft/last-transaction.nft" \
   && grep -q '^flush chain inet egresslock p_v6deny' "$STATE/nft/last-transaction.nft" \
   && grep -qE '^[[:space:]]*chain p_internet_only \{' "$STATE/nft/last-transaction.nft" \
   && grep -qE '^[[:space:]]*chain p_v6deny \{' "$STATE/nft/last-transaction.nft" \
   && grep -q 'ip saddr' "$STATE/nft/last-transaction.nft" \
   && grep -q 'meta nfproto ipv6 counter drop' "$STATE/nft/last-transaction.nft"; then
    _sect_bump pass; echo "PASS: refresh is one combined flush+rules transaction (v6deny + profile)"
else
    _sect_bump fail; echo "FAIL: install transaction lacks the combined v6deny+profile flush+rules"
fi
# 2. Ordered verification: an accept reordered ahead of an earlier
#    accept must be REJECTED (the adversarial case from the review;
#    EGL-153: swap is accepts-only after the removed-mode rework —
#    canonicalize still preserves order).
cp "$STATE/nft/egresslock.p_internet_only" "$TESTROOT/io.bak"
python3 - "$STATE/nft/egresslock.p_internet_only" <<'PY2'
import sys
p = sys.argv[1]
lines = open(p).readlines()
est = next(i for i,l in enumerate(lines) if 'counter accept' in l and '10.50.1.0/24' in l and 'daddr' not in l)
dns = next(i for i,l in enumerate(lines) if 'th dport 53' in l)
lines[est], lines[dns] = lines[dns], lines[est]
open(p,'w').writelines(lines)
PY2
check "verify rejects reordered internet-only accepts" 1 de verify internet-only
cp "$TESTROOT/io.bak" "$STATE/nft/egresslock.p_internet_only"
check "verify passes restored internet-only chain" 0 de verify internet-only
# 3. v6 chain tampering must be rejected (wrong priority, extra accept).
cp "$STATE/nft/egresslock.p_v6deny" "$TESTROOT/v6.bak"
sed -i 's/priority -160/priority -100/' "$STATE/nft/egresslock.p_v6deny"
check "verify rejects v6deny with wrong priority" 1 de verify local-dev
cp "$TESTROOT/v6.bak" "$STATE/nft/egresslock.p_v6deny"
sed -i '1i ip saddr fe80::1 counter accept' "$STATE/nft/egresslock.p_v6deny"
check "verify rejects v6deny with leading accept" 1 de verify local-dev
cp "$TESTROOT/v6.bak" "$STATE/nft/egresslock.p_v6deny"
# 4. Network driver validation: a same-name macvlan network is rejected.
mocknet egresslock-local-dev 10.50.0.0/24 false macvlan
check "ensure rejects non-bridge network driver" 1 de ensure local-dev
mocknet egresslock-local-dev 10.50.0/24 false bridge 2>/dev/null || true
mocknet egresslock-local-dev 10.50.0.0/24 false bridge
# 5. Gateway mismatch rejected.
mocknet egresslock-local-dev 10.50.0.0/24 false bridge
sed -i 's/^gateway=.*/gateway=10.99.0.1/' "$STATE/networks/egresslock-local-dev"
check "ensure rejects network with wrong gateway" 1 de ensure local-dev
mocknet egresslock-local-dev 10.50.0.0/24 false bridge
check "ensure accepts correct driver+gateway" 0 de ensure local-dev

# --- dev-llm combined profile (ARC-6) ---
check_out "dev-llm network name" "egresslock-dev-llm" de network dev-llm
check "ensure dev-llm" 0 de ensure dev-llm
check "dev-llm gateway running" 0 test -f "$STATE/running/egresslock-gateway-dev-llm"
grep -q '10.50.3.2' "$STATE/containers/egresslock-gateway-dev-llm.ip" 2>/dev/null \
    && { _sect_bump pass; echo "PASS: dev-llm gateway at 10.50.3.2"; } \
    || { _sect_bump fail; echo "FAIL: dev-llm gateway IP wrong"; }
grep -q '10.50.3.254' "$STATE/containers/egresslock-anchor-dev-llm.ip" 2>/dev/null \
    && { _sect_bump pass; echo "PASS: dev-llm anchor at 10.50.3.254"; } \
    || { _sect_bump fail; echo "FAIL: dev-llm anchor IP not reserved"; }
# Combined chain: local-dev rules + gateway hop + exemption before drop.
grep -q 'daddr 192.0.2.10 tcp dport 2222' "$STATE/nft/egresslock.p_dev_llm" \
    && { _sect_bump pass; echo "PASS: dev-llm has forgejo SSH rule"; } \
    || { _sect_bump fail; echo "FAIL: dev-llm missing forgejo SSH rule"; }
grep -q 'daddr 192.0.2.11 tcp dport 11434' "$STATE/nft/egresslock.p_dev_llm" \
    && { _sect_bump pass; echo "PASS: dev-llm has ollama rule"; } \
    || { _sect_bump fail; echo "FAIL: dev-llm missing ollama rule"; }
grep -q 'ip saddr 10.50.3.0/24 iifname "podman1" ip daddr 10.50.3.2 tcp dport 3128' "$STATE/nft/egresslock.p_dev_llm" \
    && { _sect_bump pass; echo "PASS: dev-llm has gateway hop rule"; } \
    || { _sect_bump fail; echo "FAIL: dev-llm missing gateway hop rule"; }
# EGL-123-D2/D3: the gateway exemption is keyed on source IP + the
# kit-derived pinned MAC. The MAC derivation (gw_mac) is re-computed
# here from the same conf identity so a drift in the engine's
# derivation fails this pin instead of silently matching.
d_mac_hex="$(printf '%s' 'dev-llm|10.50.3.2' | sha256sum | cut -d' ' -f1)"
d_mac="02:${d_mac_hex:0:2}:${d_mac_hex:2:2}:${d_mac_hex:4:2}:${d_mac_hex:6:2}:${d_mac_hex:8:2}"
# D3: the gateway run argv carries --mac-address with the derived pin.
grep -q -- "--mac-address ${d_mac}" "$STATE/runlog" 2>/dev/null \
    && { _sect_bump pass; echo "PASS: dev-llm gateway run pins derived MAC"; } \
    || { _sect_bump fail; echo "FAIL: dev-llm gateway run missing --mac-address ${d_mac}"; }
grep -q "${d_mac}" "$STATE/containers/egresslock-gateway-dev-llm.mac" 2>/dev/null \
    && { _sect_bump pass; echo "PASS: dev-llm gateway stored MAC equals pin"; } \
    || { _sect_bump fail; echo "FAIL: dev-llm gateway stored MAC != pin"; }
grep -q "ip saddr 10.50.3.2 iifname \"podman1\" ether saddr ${d_mac} counter accept" "$STATE/nft/egresslock.p_dev_llm" \
    && { _sect_bump pass; echo "PASS: dev-llm exemption is saddr+derived-MAC"; } \
    || { _sect_bump fail; echo "FAIL: dev-llm exemption not saddr+derived-MAC"; }
d_accept="$(grep -n "ip saddr 10.50.3.2 iifname \"podman1\" ether saddr ${d_mac} counter accept" "$STATE/nft/egresslock.p_dev_llm" | cut -d: -f1 | head -1)"
d_drop="$(grep -n '^ip saddr 10.50.3.0/24 counter drop' "$STATE/nft/egresslock.p_dev_llm" | cut -d: -f1 | head -1)"
if [[ -n "$d_accept" && -n "$d_drop" && "$d_accept" -lt "$d_drop" ]]; then
    _sect_bump pass; echo "PASS: dev-llm exemption before drop"
else
    _sect_bump fail; echo "FAIL: dev-llm exemption missing or after drop"
fi
# D3: warm ensure of a matching-MAC gateway does NOT replace it (the
# EGL-114 converged skip survives the MAC gate).
: > "$STATE/opslog"
check "ensure dev-llm (warm, MAC matches)" 0 de ensure dev-llm
if ! grep -qE '^podman (rm|run) .*egresslock-gateway-dev-llm' "$STATE/opslog" 2>/dev/null; then
    _sect_bump pass; echo "PASS: dev-llm warm ensure keeps matching-MAC gateway (no rm/run)"
else
    _sect_bump fail; echo "FAIL: dev-llm warm ensure replaced matching-MAC gateway (ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi
# D3: a drifted live MAC is identity drift — ensure replaces (rm + run
# with the pin); the exemption line in the new chain carries the pin.
echo 'ff:ff:ff:ff:ff:ff' > "$STATE/containers/egresslock-gateway-dev-llm.mac"
: > "$STATE/opslog"
check "ensure dev-llm (drifted MAC -> replace)" 0 de ensure dev-llm
if grep -qE '^podman rm .* egresslock-gateway-dev-llm$' "$STATE/opslog" 2>/dev/null \
   && grep -qE "^podman run .*--name egresslock-gateway-dev-llm .*--mac-address ${d_mac}" "$STATE/opslog" 2>/dev/null; then
    _sect_bump pass; echo "PASS: dev-llm drifted-MAC ensure replaced with pinned MAC"
else
    _sect_bump fail; echo "FAIL: dev-llm drifted-MAC ensure did not replace with the pin (ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi
# D3: verify on a drifted MAC fails closed with the named line.
echo 'ff:ff:ff:ff:ff:ff' > "$STATE/containers/egresslock-gateway-dev-llm.mac"
o="$(de verify dev-llm 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"verify: gateway MAC is 'ff:ff:ff:ff:ff:ff', expected '${d_mac}'"* ]]; then
    _sect_bump pass; echo "PASS: dev-llm verify fails closed on drifted MAC"
else
    _sect_bump fail; echo "FAIL: dev-llm verify drifted-MAC message (rc=$rc, out: $o)"
fi
# Restore: re-ensure recreates the gateway with the pinned MAC and
# verify is green again (the MAC gate closed the loop).
check "ensure dev-llm restores pinned MAC" 0 de ensure dev-llm
grep -q "${d_mac}" "$STATE/containers/egresslock-gateway-dev-llm.mac" 2>/dev/null \
    && { _sect_bump pass; echo "PASS: dev-llm re-ensure re-pins MAC"; } \
    || { _sect_bump fail; echo "FAIL: dev-llm re-ensure did not re-pin MAC"; }
# Generated gateway config uses the dev-llm subnet.
check_out "dev-llm gateway config class ACL" "acl agent_class src 10.50.3.0/24" \
    cat "$STATE/containers-egresslock-gateway-dev-llm.allowlist.last"


section_end deep

# --- EGL-55: verify missing-network message points at ensure (D55-2) ------
# The network-inspect guard is the first check in verify_policy: with the
# network absent, rc 1 and the hint names `egresslock ensure <profile>`
# (bare egresslock spelling; never suggests `verify` itself).
section_begin egl55 "EGL-55 verify missing-network hint"
rm -f "$STATE/networks/egresslock-local-dev"
o="$(egresslock verify local-dev 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"verify: network egresslock-local-dev missing"* \
    && "$o" == *"missing — run: egresslock ensure local-dev"* \
    && "$o" != *"egresslock verify"* ]] \
    && _sect_bump pass || { _sect_bump fail; echo "FAIL: D55-2 verify missing-network names ensure (rc=$rc, out: $o)"; }
# The chain checks still fire normally when the network exists (existing
# pins above cover them); restore the network so nothing downstream of
# this section sees a half-removed fixture.
egresslock ensure local-dev >/dev/null 2>&1
[[ -f "$STATE/networks/egresslock-local-dev" ]] \
    && _sect_bump pass || { _sect_bump fail; echo "FAIL: EGL-55 fixture restore (local-dev network recreated)"; }
section_end egl55

# --- EGL-59: help is operator UI — no ticket/process citations ------------
# EGL-286: every help surface — the summary, all 17 command topics, and
# the config/env reference pages — is operator UI and must not leak
# ticket/decision IDs or ticket paths. The EGL-57 checks: block (already
# ID-free) must still be present in full — relocated verbatim to
# `help config` (ticket D4).
section_begin egl59 "EGL-59 help operator-UI"
h_out="$(env egresslock --help 2>&1)"; h_rc=$?
h_all="$h_out
$(env egresslock help env 2>&1)
$(env egresslock help config 2>&1)"
for c in ensure verify network proxy-env rules allowlist denied allow disallow allow-host disallow-host drop-unauthorized init list doctor build-gateway teardown; do
    h_all="$h_all
$(env egresslock help "$c" 2>&1)"
done
if [[ "$h_rc" == 0 ]] && ! grep -qE 'ARC-[0-9]|EGL-[0-9]|docs/tickets/[A-Za-z0-9]' <<<"$h_all"; then
    _sect_bump pass
else
    _sect_bump fail; echo "FAIL: EGL-59 engine help surfaces leak ticket/process refs (rc=$h_rc)"
fi
h_ok=1
for c in "egresslock doctor " "egresslock-setup doctor [--account]" \
         "egresslock-setup apparmor check" "egresslock verify <profile>"; do
    grep -qF "$c" <<<"$h_all" || h_ok=0
done
[[ "$h_ok" == 1 ]] \
    && _sect_bump pass || { _sect_bump fail; echo "FAIL: EGL-57 checks: block dropped from engine help config"; }
section_end egl59

# --- EGL-66: the anchor is hardened like the gateway -----------------------
# D1: the anchor `podman run` carries --cap-drop=all +
# --security-opt=no-new-privileges (it only sleeps). D2: the fallback
# anchor image is digest-pinned (never a floating third-party tag);
# the resolution order itself (env > localhost/base:latest > fallback)
# is unchanged.
section_begin egl66 "EGL-66 anchor hardening + digest pin"
e66() { assert "$@"; }

S66="$TESTROOT/s66"; rm -rf "$S66"; mkdir -p "$S66"
cat > "$S66/s66.conf" <<'EOF'
profile s66 10.199.74.0/24
EOF
# EGL-206-D2a: the anchor preflight inspects the RESOLVED image before
# the run — the digest-pinned fallback must exist in the mock store
# (the mock `podman run` never pulls); localhost/base stays absent so
# the fallback resolution below keeps its premise.
: > "$STATE/images/docker.io_library_alpine_3.22@sha256_14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce"
# D2: with no env override and no localhost/base in the mock store, the
# anchor run names the digest-pinned fallback.
ARCMOCK_PASSWD_HOME="$(conf_home "$S66/s66.conf")" egresslock teardown s66 >/dev/null 2>&1 || true
: > "$STATE/runlog"
e66_out="$(env -u EGRESSLOCK_ANCHOR_IMAGE ARCMOCK_PASSWD_HOME="$(conf_home "$S66/s66.conf")" egresslock ensure s66 2>&1)"; e66_rc=$?
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
# preserved) — and still gets the hardening pair. EGL-206-D2a: the mock
# store must hold the override image for the new checkpoint-annotation
# preflight (inspect-before-run).
: > "$STATE/images/localhost_base_latest"
ARCMOCK_PASSWD_HOME="$(conf_home "$S66/s66.conf")" egresslock teardown s66 >/dev/null 2>&1 || true
: > "$STATE/runlog"
env EGRESSLOCK_ANCHOR_IMAGE="localhost/base:latest" \
    ARCMOCK_PASSWD_HOME="$(conf_home "$S66/s66.conf")" egresslock ensure s66 >/dev/null 2>&1; e66_rc=$?
e66_anchor="$(grep -m1 'egresslock-anchor-s66' "$STATE/runlog" || true)"
[[ "$e66_rc" == 0 && "$e66_anchor" == *'localhost/base:latest'* \
    && "$e66_anchor" == *'--cap-drop=all'* \
    && "$e66_anchor" == *'--security-opt=no-new-privileges'* ]] \
    && e66 pass || e66 fail "env override still wins + anchor hardened (rc=$e66_rc, run line: $e66_anchor)"
# Restore the harness default state for anything downstream.
ARCMOCK_PASSWD_HOME="$(conf_home "$S66/s66.conf")" egresslock teardown s66 >/dev/null 2>&1 || true
section_end egl66

echo
# --- EGL-91: anchor is the netns holder and starts first (D4); policy
#     lands after the holder, before the gateway; first create is ONE
#     transaction with rules (audit G-06/I-06, EGL-93 live finding) ---
section_begin arc91 "ARC-91 first-create atomicity"
a91() { assert "$@"; }

S91="$TESTROOT/s91"; rm -rf "$S91"; mkdir -p "$S91"
: > "$STATE/images/localhost_egresslock-gateway_latest"
cat > "$S91/s91.conf" <<'EOF'
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
a91_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S91/s91.conf")" egresslock ensure s91 2>&1)"; a91_rc=$?
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
a91_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S91/s91.conf")" egresslock ensure s91 2>&1)"; a91_rc=$?
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

section_end arc91

# --- EGL-114: ensure is non-disruptive on a converged profile (D2/D5) ----
# D5 mock matrix: converged warm ensure must not restart or rm the
# gateway/anchor; a changed allowlist/conf applies + restarts; a dead
# gateway still replaces + applies; the EGL-91-D4 order pins above stay
# green. opslog (lib.sh mock) records podman rm/run/restart argv.
section_begin egl114 "EGL-114 converged-ensure gate"
a114() { assert "$@"; }

S114="$TESTROOT/s114"; rm -rf "$S114"; mkdir -p "$S114"
: > "$STATE/images/localhost_egresslock-gateway_latest"
cat > "$S114/s114.conf" <<'EOF'
profile s114 10.199.94.0/24
    rule gateway-only
    gateway 10.199.94.2 3128 s114-allowlist
EOF
printf 'git.example.test\n' > "$S114/s114-allowlist"
run114() { env ARCMOCK_PASSWD_HOME="$(conf_home "$S114/s114.conf")" HOME="$S114" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

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

# D5 pin 3: gateway NOT running -> the replace (rm -f + run) still
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

section_end egl114

# --- EGL-116: per-profile read-timeout knob (D1) -------------------------
# Grammar rejects (config_error, exit 2) + the generated conf always
# carries the explicit `read_timeout N seconds` line (default 900).
section_begin egl116 "EGL-116 read-timeout knob"
a116() { assert "$@"; }

S116="$TESTROOT/s116"; rm -rf "$S116"; mkdir -p "$S116"

# 1. Default (directive absent): 900 in the generated conf.
cat > "$S116/s116d.conf" <<'EOF'
profile s116d 10.199.93.0/24
    rule gateway-only
    gateway 10.199.93.2 3128 s116d-allowlist
EOF
: > "$S116/s116d-allowlist"
o="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S116/s116d.conf")" egresslock ensure s116d 2>&1)"; rc=$?
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
cat > "$S116/s116v.conf" <<'EOF'
profile s116v 10.199.92.0/24
    rule gateway-only
    read-timeout 60
    gateway 10.199.92.2 3128 s116v-allowlist
EOF
: > "$S116/s116v-allowlist"
o="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S116/s116v.conf")" egresslock ensure s116v 2>&1)"; rc=$?
sq="$(find "$STATE" -name 'containers-egresslock-gateway-s116v.squid-gw.conf' 2>/dev/null | head -1)"
[[ "$rc" == 0 && -n "$sq" && "$(grep -m1 '^read_timeout ' "$sq")" == "read_timeout 60 seconds" ]] \
    && a116 pass || a116 fail "read-timeout 60 -> read_timeout 60 seconds (rc=$rc sq=[$sq])"

# 3. Grammar rejects: zero, suffix, negative, leading zero, non-integer,
#    duplicate, trailing text, outside a block — all exit 2.
bad116() { # bad116 <name> <content> <message-substring>
    printf '%s\n' "$2" > "$S116/$1.conf"
    local out rc=0
    out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S116/$1.conf")" egresslock list 2>&1)" || rc=$?
    if [[ "$rc" == 2 && "$out" == *"a.conf:"* && "$out" == *"$3"* ]]; then
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

section_end egl116

# --- EGL-120: unresolvable allow-host — clean abort, hint, no nft dump ---
# D1: the swallowed-die footgun must abort BEFORE nft (no malformed
# rule consumed, no stacked nft error) and print the remediation hints.
section_begin egl120 "EGL-120 resolve error-path shape"
a120() { assert "$@"; }

S120="$TESTROOT/s120"; rm -rf "$S120"; mkdir -p "$S120"
cat > "$S120/s120.conf" <<'EOF'
profile s120 10.199.91.0/24
    rule allow-host nonexistent.example.test:8080
EOF
# EGL-106: snapshot the last consumed transaction — a rule-gen failure
# emits NO -f at all, so the failed ensure must not change it (no
# partial v6-deny file either).
egl120_lt_before="$(cat "$STATE/nft/last-transaction.nft" 2>/dev/null)"
o="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$(conf_home "$S120/s120.conf")" egresslock ensure s120 2>&1)"; rc=$?
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
grep -q 'rule allow-host nonexistent.example.test:8080' "$S120/s120.conf" \
    && a120 pass || a120 fail "failed ensure keeps the rule in the conf"

section_end egl120

# --- EGL-141: bridge-scoped accepts + counted anti-spoof drop (D1/D2) ----
# The compiler resolves the profile's live bridge token (EGL-91 amendment)
# and scopes every saddr-keyed accept with `iifname "<bridge>"`; the
# anti-spoof drop is FIRST (iifname != form); the terminal drop stays
# saddr-keyed and UNscoped. Stale-token churn fails verify closed and
# ensure repairs it; an unconfirmable device fails the emit (no partial
# file, no nft transaction).
section_begin egl141 "EGL-141 bridge-scoped accepts"
a141() { assert "$@"; }

S141="$TESTROOT/s141"; rm -rf "$S141"; mkdir -p "$S141"
cat > "$S141/s141a.conf" <<'EOF'
profile s141a 10.199.81.0/24
    rule allow-host git.example.test:2222
    rule gateway-only
    gateway 10.199.81.2 3128 s141-allowlist
EOF
cat > "$S141/s141b.conf" <<'EOF'
profile s141b 10.199.82.0/24
EOF
: > "$S141/s141-allowlist"
ARCMOCK_PASSWD_HOME="$(conf_home "$S141/s141a.conf")" egresslock ensure s141a >/dev/null 2>&1; a141_rc=$?
GW_CHAIN="$STATE/nft/egresslock.p_s141a"
mac141="$(printf '%s' 's141a|10.199.81.2' | sha256sum | cut -d' ' -f1)"
mac141="02:${mac141:0:2}:${mac141:2:2}:${mac141:4:2}:${mac141:6:2}:${mac141:8:2}"

# 1. Anti-spoof drop is FIRST in the chain (D2), iifname != shape.
[[ "$(grep -m1 'counter' "$GW_CHAIN" 2>/dev/null)" == 'iifname != "podman1" ip saddr 10.199.81.0/24 counter drop' ]] \
    && a141 pass || a141 fail "anti-spoof drop first in gateway chain (head: $(grep -m1 'counter' "$GW_CHAIN" 2>/dev/null))"

# 2. Every saddr-keyed ACCEPT is iifname-scoped (established, DNS, pin,
#    gateway hop, exemption); terminal drop unscoped.
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
ARCMOCK_PASSWD_HOME="$(conf_home "$S141/s141a.conf")" egresslock verify s141a >/dev/null 2>&1; a141 pass || a141 fail "baseline verify s141a"
sed -i 's/^interface=.*/interface=podman3/' "$STATE/networks/egresslock-s141a"
v141_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S141/s141a.conf")" egresslock verify s141a 2>&1)"; v141_rc=$?
if [[ "$v141_rc" != 0 && "$v141_out" == *"does not match the expected ruleset"* && "$v141_out" == *'podman3'* ]]; then
    a141 pass
else
    a141 fail "stale bridge name -> verify fail-closed named iifname diff (rc=$v141_rc out: $(printf '%s' "$v141_out" | head -3 | tr '\n' '|'))"
fi
check141_rc=0; ARCMOCK_PASSWD_HOME="$(conf_home "$S141/s141a.conf")" egresslock ensure s141a >/dev/null 2>&1 || check141_rc=$?
[[ "$check141_rc" == 0 ]] && a141 pass || a141 fail "ensure repairs the stale bridge name (rc=$check141_rc)"
grep -q 'iifname "podman3"' "$GW_CHAIN" && a141 pass || a141 fail "repaired chain carries the re-resolved name podman3"
ARCMOCK_PASSWD_HOME="$(conf_home "$S141/s141a.conf")" egresslock verify s141a >/dev/null 2>&1; a141 pass || a141 fail "verify passes after repair"
sed -i 's/^interface=.*/interface=podman1/' "$STATE/networks/egresslock-s141a"
ARCMOCK_PASSWD_HOME="$(conf_home "$S141/s141a.conf")" egresslock ensure s141a >/dev/null 2>&1; a141 pass || a141 fail "ensure after device restore"
cp "$GW_CHAIN" "$TESTROOT/s141-chain-before-r6"    # post-restore snapshot (podman1)
# R6: warm ensure without a name flip is byte-identical (converged skip
# pin lives in the EGL-114 section; here: re-ensure rc 0, same chain).
ARCMOCK_PASSWD_HOME="$(conf_home "$S141/s141a.conf")" egresslock ensure s141a >/dev/null 2>&1; a141 pass || a141 fail "warm ensure after name restore"
cmp -s "$GW_CHAIN" "$TESTROOT/s141-chain-before-r6" \
    && a141 pass || a141 fail "R6 warm ensure byte-identical chain (same name re-resolved)"

# 4. Unconfirmable device: the inspect/cross-check mismatch must fail
#    the emit by rc — no new nft transaction, no changed chain, no
#    empty iifname (EGL-120-D1 pattern; EGL-141-D1 consequence 2).
sed -i 's/^interface=.*/interface=podman42/' "$STATE/networks/egresslock-s141a"
cp "$STATE/nft/last-transaction.nft" "$TESTROOT/s141-tx-before"
f141_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S141/s141a.conf")" egresslock ensure s141a 2>&1)"; f141_rc=$?
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
ARCMOCK_PASSWD_HOME="$(conf_home "$S141/s141a.conf")" egresslock ensure s141a >/dev/null 2>&1 || a141 fail "ensure heals after device restore"

# 5. Last-transaction pin: the refresh file carries the anti-spoof line
#    (D2 first-position contract at the transaction level).
grep -qE '^[[:space:]]*iifname != "podman1" ip saddr 10.199.81.0/24 counter drop' "$STATE/nft/last-transaction.nft" \
    && a141 pass || a141 fail "last transaction carries the anti-spoof drop first"

# 6. EGL-193: bare-profile chain shape (non-gateway). The
#    public-only half of these pins retired with EGL-153;
#    re-anchor on a no-rules profile. Same three EGL-141-D1/D2
#    properties. Last-transaction pin above already fired on
#    the gateway chain — this ensure overwrites
#    last-transaction.nft after that pin.
ARCMOCK_PASSWD_HOME="$(conf_home "$S141/s141b.conf")" egresslock ensure s141b >/dev/null 2>&1
BARE_CHAIN="$STATE/nft/egresslock.p_s141b"

[[ "$(grep -m1 'counter' "$BARE_CHAIN" 2>/dev/null)" == 'iifname != "podman1" ip saddr 10.199.82.0/24 counter drop' ]] \
    && a141 pass || a141 fail "anti-spoof drop first in bare chain (head: $(grep -m1 'counter' "$BARE_CHAIN" 2>/dev/null))"
grep -q 'ip saddr 10.199.82.0/24 iifname "podman1" ct state established,related counter accept' "$BARE_CHAIN" \
    && a141 pass || a141 fail "bare established/related is iifname-scoped"
grep -q 'ip saddr 10.199.82.0/24 iifname "podman1" ip daddr 10.199.82.1 meta l4proto { tcp, udp } th dport 53 counter accept' "$BARE_CHAIN" \
    && a141 pass || a141 fail "bare DNS-to-bridge is iifname-scoped"
[[ "$(grep -c '^ip saddr 10.199.82.0/24 counter drop' "$BARE_CHAIN")" == 1 ]] \
    && a141 pass || a141 fail "bare terminal drop stays saddr-keyed UNscoped (exactly one unscoped drop)"

section_end egl141

# --- EGL-146: dstdomain -n on EVERY generated ACL (D1/D3) ----------------
# Numeric-host (IP-literal) CONNECTs must fail the name match outright
# (X-6 E8 rDNS adoption closed): both emit sites carry `-n`, and a grep
# belt future-proofs any new dstdomain group.
section_begin egl146 "EGL-146 dstdomain -n"
a146() { assert "$@"; }

S146="$TESTROOT/s146"; rm -rf "$S146"; mkdir -p "$S146"
cat > "$S146/s146.conf" <<'EOF'
profile s146 10.199.84.0/24
    rule gateway-only
    gateway 10.199.84.2 3128 s146-allowlist
EOF
printf 'example.test\n' > "$S146/s146-allowlist"
ARCMOCK_PASSWD_HOME="$(conf_home "$S146/s146.conf")" egresslock ensure s146 >/dev/null 2>&1; a146_rc=$?
sq146="$(find "$STATE" -name 'containers-egresslock-gateway-s146.squid-gw.conf' 2>/dev/null | head -1)"
# 1. No-port group carries -n (exact line).
[[ "$a146_rc" == 0 && -n "$sq146" && "$(grep -m1 '^acl agent_allowlist dstdomain' "$sq146")" == 'acl agent_allowlist dstdomain -n "/etc/squid/agent/allowlist.domains"' ]] \
    && a146 pass || a146 fail "no-port group: exact dstdomain -n line (rc=$a146_rc $(grep -m1 'acl agent_allowlist dstdomain' "$sq146" 2>/dev/null))"
# 2. Per-port group carries -n (exact line).
printf 'example.test:8443\n' >> "$S146/s146-allowlist"
ARCMOCK_PASSWD_HOME="$(conf_home "$S146/s146.conf")" egresslock ensure s146 >/dev/null 2>&1 || a146 fail "re-ensure with per-port entry"
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

section_end egl146

# --- EGL-147: trailing-dot entries are rejected (D1/D2/D3) ----------------
# Reject at allow time (CLI) and fail closed at ensure (file); never
# normalize, never warn. Leading-dot suffixes stay valid; request-side
# trailing dots are gateway-normalized (out of scope here).
section_begin egl147 "EGL-147 trailing-dot reject"
a147() { assert "$@"; }

S147="$TESTROOT/s147"; rm -rf "$S147"; mkdir -p "$S147"
cat > "$S147/s147.conf" <<'EOF'
profile s147 10.199.86.0/24
    rule gateway-only
    gateway 10.199.86.2 3128 s147-allowlist
EOF
printf 'starter.example.test\n' > "$S147/s147-allowlist"
ARCMOCK_PASSWD_HOME="$(conf_home "$S147/s147.conf")" egresslock ensure s147 >/dev/null 2>&1; a147_rc=$?
[[ "$a147_rc" == 0 ]] && a147 pass || a147 fail "s147 baseline ensure (rc=$a147_rc)"

# 1. CLI rejects: bare, host:port, leading+trailing, IPv4-shaped-with-dot.
#    rc 2, allowlist unchanged, no ensure/gateway churn, stderr names the
#    shape (`trailing dot` + the entry).
for bad in "example.test." "example.test.:443" ".example.test." "1.2.3.4." "1.2.3.4.:443"; do
    before147="$(md5sum "$S147/s147-allowlist" | cut -d' ' -f1)"
    : > "$STATE/opslog"
    o147="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S147/s147.conf")" egresslock allow s147 "$bad" 2>&1)"; r147=$?
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
o147="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S147/s147.conf")" egresslock ensure s147 2>&1)"; r147=$?
if [[ "$r147" != 0 && "$o147" == *"trailing dot"* && "$o147" == *"example.test."* ]]; then
    a147 pass
else
    a147 fail "file-path trailing-dot reject fails ensure closed (rc=$r147 out: $(printf '%s' "$o147" | tail -1))"
fi
printf 'handedit.example.test\nexample.test.:8443\n' > "$S147/s147-allowlist"
o147="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S147/s147.conf")" egresslock ensure s147 2>&1)"; r147=$?
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
ARCMOCK_PASSWD_HOME="$(conf_home "$S147/s147.conf")" egresslock allow s147 example.test >/dev/null 2>&1; r147=$?
grep -q '^example.test$' "$S147/s147-allowlist" && [[ "$r147" == 0 ]] \
    && a147 pass || a147 fail "positive control: allow example.test still rc 0 (rc=$r147)"
ARCMOCK_PASSWD_HOME="$(conf_home "$S147/s147.conf")" egresslock allow s147 .example.test >/dev/null 2>&1; r147=$?
grep -q '^\.example\.test$' "$S147/s147-allowlist" && [[ "$r147" == 0 ]] \
    && a147 pass || a147 fail "positive control: allow .example.test (leading-dot suffix) still rc 0 (rc=$r147)"
o147="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S147/s147.conf")" egresslock allow s147 a..b 2>&1)"; r147=$?
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
o147="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S147/s147.conf")" egresslock denied s147 --all 2>/dev/null)"; r147=$?
if [[ "$r147" == 0 && "$o147" == *"blocked.example.test"* && "$o147" != *"example.test.:443"* ]]; then
    a147 pass
else
    a147 fail "denied silently skips the trailing-dot candidate (rc=$r147 out: $o147)"
fi

# 5. allow-host / conf: the CLI and the parser name the same shape.
o147="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S147/s147.conf")" egresslock allow-host s147 example.test.:443 2>&1)"; r147=$?
if [[ "$r147" == 2 && "$o147" == *"trailing dot"* ]]; then
    a147 pass
else
    a147 fail "allow-host trailing-dot reject (rc=$r147 out: $(printf '%s' "$o147" | tail -1))"
fi
grep -q 'rule allow-host' "$S147/s147.conf" \
    && a147 fail "rejected allow-host must not have written the conf" || a147 pass
printf 'profile s147b 10.199.87.0/24\n    rule allow-host example.test.:443\n' > "$S147/s147b.conf"
o147="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S147/s147b.conf")" egresslock list 2>&1)"; r147=$?
if [[ "$r147" == 2 && "$o147" == *"trailing dot"* && "$o147" == *"b.conf:"* ]]; then
    a147 pass
else
    a147 fail "conf parser trailing-dot reject for allow-host (rc=$r147 out: $(printf '%s' "$o147" | tail -1))"
fi
printf 'profile s147c 10.199.88.0/24\n    no-proxy example.test.,other.example.test\n' > "$S147/s147c.conf"
o147="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S147/s147c.conf")" egresslock list 2>&1)"; r147=$?
if [[ "$r147" == 2 && "$o147" == *"trailing dot"* ]]; then
    a147 pass
else
    a147 fail "conf parser trailing-dot reject for no-proxy (rc=$r147 out: $(printf '%s' "$o147" | tail -1))"
fi

section_end egl147

# --- EGL-139/EGL-140: revocation flush + tampered-pin verify detection ----
# EGL-139-D2: disallow-host runs a fail-closed conntrack probe BEFORE the
# conf mutation, captures the revoked pin's live daddr, then after the
# atomic re-ensure swap deletes and post-asserts the revoked tuple
# (scoped ctnetlink -L, EGL-231); `removed:` prints only after that holds.
# EGL-140-D1: ensure records the installed pins in <profile>.pins (not
# globbed as *.conf); verify fails closed on chain-vs-record divergence
# while record-vs-resolver movement stays warn-only drift (D2).
section_begin egl139 "EGL-139 conntrack revocation flush"
a139() { assert "$@"; }

EH="$TESTROOT/h139140"; rm -rf "$EH"; mkdir -p "$EH"
cat > "$EH/two.conf" <<'EOF'
profile two 10.199.60.0/24
    rule allow-host git.example.test:2222
    rule allow-host cache.example.test:8080
EOF
cat > "$EH/plain.conf" <<'EOF'
profile plain 10.199.61.0/24
EOF
export ARCMOCK_PASSWD_HOME="$(conf_home "$EH/two.conf")"
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure two >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/plain.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure plain >/dev/null 2>&1

# 1. ensure writes the pin record beside the conf, conf order, from the
#    installed chain; no staging temp left behind; .pins is never loaded
#    as a conf (scoped list of two.conf stays one-profile-per-conf).
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
list_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$(conf_home_ro "$EH/two.conf")" egresslock list 2>/dev/null)"
if [[ "$list_out" == *"two"* && "$list_out" != *".pins"* ]]; then
    a139 pass
else
    a139 fail "scoped list must not treat .pins as a conf (out: $list_out)"
fi
# 2. zero-allow-host profile: NO record, verify silent-green.
[[ ! -e "$EH/plain.pins" ]] \
    && a139 pass || a139 fail "zero-allow-host profile must have no pin record"
v_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/plain.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify plain 2>&1)"; v_rc=$?
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
grep -qxF 'conntrack -D -p tcp -s 10.199.60.5 --sport 58666 -d 192.0.2.10 --dport 2222' "$CTLOG" \
    && a139 pass || a139 fail "exact-tuple -D for the workload row (log: $(tr '\n' '|' < "$CTLOG"))"
# EGL-231-D8: the post-assert reads ctnetlink `-L` with the same tuple,
# after -C and -D, before `removed:` prints.
grep -qxF 'conntrack -L -p tcp --dport 2222 -d 192.0.2.10' "$CTLOG" \
    && a139 pass || a139 fail "post-assert reads via scoped -L (log: $(tr '\n' '|' < "$CTLOG"))"
# EGL-313 re-contract: the flush order is -C / the orig enumerate / the
# per-row exact-tuple orig -D / the orig witness -L / the peer -L (pre-
# delete read) / exact-tuple peer -D when a reversed row exists / peer
# -L (witness) / the reconcile's -dport enumerate / the reconcile's
# sport-only reversed enumerate. The healthy fixture has no reversed
# row and one in-scope orig row, so exactly one exact-tuple -D appears
# and the two peer reads return empty.
expected_log=$'conntrack -C\nconntrack -L -p tcp --dport 2222 -d 192.0.2.10\nconntrack -D -p tcp -s 10.199.60.5 --sport 58666 -d 192.0.2.10 --dport 2222\nconntrack -L -p tcp --dport 2222 -d 192.0.2.10\nconntrack -L -p tcp --sport 2222 -s 192.0.2.10\nconntrack -L -p tcp --sport 2222 -s 192.0.2.10\nconntrack -L -p tcp --dport 2222\nconntrack -L -p tcp --sport 2222'
[[ "$(cat "$CTLOG")" == "$expected_log" ]] \
    && a139 pass || a139 fail "conntrack argv order -C/-D/member -L then the port-only enumerate before removed: (log: $(tr '\n' '|' < "$CTLOG"))"
if grep -qF 'dst=192.0.2.11 ' "$CTTABLE" && ! grep -qF 'dst=192.0.2.10 ' "$CTTABLE"; then
    a139 pass
else
    a139 fail "scoped delete: revoked tuple gone, sibling pin's entry untouched (table: $(tr '\n' '|' < "$CTTABLE"))"
fi
! grep -q 'rule allow-host git.example.test:2222' "$EH/two.conf" \
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
   && grep -q 'rule allow-host git.example.test:2222' "$EH/two.conf" \
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
   && grep -q 'rule allow-host git.example.test:2222' "$EH/two.conf"; then
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
if [[ "$d_rc" == 1 && "$d_out" == *"still has a live conntrack entry"* \
      && "$d_out" == *"— next action: end the leftover connections: egresslock drop-unauthorized two 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"* \
      && "$d_out" == *"not proven gone"* \
      && "$d_out" != *"finish the kill-switch by hand"* \
      && "$d_out" != *"fresh packets now drop and the entry drains"* \
      && "$d_out" != *"retry disallow-host"* \
      && "$d_out" != *"sudo apt install conntrack"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && ! grep -q 'rule allow-host git.example.test:2222' "$EH/two.conf"; then
    a139 pass
else
    a139 fail "surviving ESTABLISHED entry dies loudly (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi
# EGL-327 D5 effect pin: the printed recovery is the engine verb, not a
# hand-typed -D — extract it from the die and run it against the mock
# (delete marker cleared); the survivor's exact row goes and the verb
# prints its success line.
cmd139x="${d_out##*end the leftover connections: }"; cmd139x="${cmd139x%% (drops*}"
[[ "$cmd139x" == "egresslock drop-unauthorized two 2222" ]] \
    && a139 pass || a139 fail "S1 printed command parsed verbatim ('$cmd139x')"
u139x="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 bash -c "$cmd139x" 2>&1)"; u139x_rc=$?
if [[ "$u139x_rc" == 0 ]] \
   && grep -qxF "drop-unauthorized: no leftover connection on port 2222 remains that profile 'two' does not allow" <<<"$u139x" \
   && [[ ! -s "$CTTABLE" ]]; then
    a139 pass
else
    a139 fail "S1 printed recovery removes the survivor (rc=$u139x_rc, out: $u139x, table: $(tr '\n' '|' < "$CTTABLE"))"
fi

# EGL-297-D5/M1: the state-free witness — every observed entry for the
# tuple dies with the S1 message (an observed entry's packet already left
# under the revoked accept); CLOSE_WAIT is the live-confirmed X20c shape.
# 13c. CLOSE_WAIT survivor: conntrack-delete-fails keeps the row, so the
#      scoped -L returns it and the witness sees it -> rc 1, S1, no
#      `removed:`.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 59 CLOSE_WAIT src=10.199.60.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58666 mark=0 zone=0 use=1\n' > "$CTTABLE"
touch "$ARCMOCK_STATE/nft/conntrack-delete-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-delete-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"still has a live conntrack entry"* \
      && "$d_out" == *"CLOSE_WAIT"* \
      && "$d_out" == *"— next action: end the leftover connections: egresslock drop-unauthorized two 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"* \
      && "$d_out" != *"finish the kill-switch by hand"* \
      && "$d_out" == *"not proven gone"* \
      && "$d_out" != *"fresh packets now drop and the entry drains"* ]] \
   && ! grep -q 'removed:' <<<"$d_out"; then
    a139 pass
else
    a139 fail "CLOSE_WAIT survivor dies loudly (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi

# 13d. SYN_SENT2 survivor (the critique-fix pin — a v1 denylist
#      regression that excluded SYN_SENT2 fails here): reply-seen
#      simultaneous-open entry stays in the table -> rc 1, the S1 die,
#      no `removed:`.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 117 SYN_SENT2 src=10.199.60.9 dst=192.0.2.10 sport=58670 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58670 mark=0 zone=0 use=1\n' > "$CTTABLE"
touch "$ARCMOCK_STATE/nft/conntrack-delete-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-delete-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"still has a live conntrack entry"* \
      && "$d_out" == *"SYN_SENT2"* \
      && "$d_out" == *"— next action: end the leftover connections: egresslock drop-unauthorized two 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"* \
      && "$d_out" != *"finish the kill-switch by hand"* \
      && "$d_out" == *"not proven gone"* \
      && "$d_out" != *"fresh packets now drop and the entry drains"* ]] \
   && ! grep -q 'removed:' <<<"$d_out"; then
    a139 pass
else
    a139 fail "SYN_SENT2 survivor dies loudly (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi

# 13e. SYN_RECV boundary pin (state-complete witness): a SYN_RECV
#      entry (handshake race; reply-seen) is accepted by the chain ->
#      it dies rc 1 (an allowlist regression that missed SYN_RECV
#      fails here).
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 117 SYN_RECV src=10.199.60.9 dst=192.0.2.10 sport=58670 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58670 mark=0 zone=0 use=1\n' > "$CTTABLE"
touch "$ARCMOCK_STATE/nft/conntrack-delete-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-delete-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"still has a live conntrack entry"* \
      && "$d_out" == *"SYN_RECV"* \
      && "$d_out" == *"— next action: end the leftover connections: egresslock drop-unauthorized two 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"* \
      && "$d_out" != *"finish the kill-switch by hand"* \
      && "$d_out" == *"not proven gone"* \
      && "$d_out" != *"fresh packets now drop and the entry drains"* ]] \
   && ! grep -q 'removed:' <<<"$d_out"; then
    a139 pass
else
    a139 fail "SYN_RECV survivor dies loudly (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi

# 13f. NONE observed survivor (EGL-297-D5/M1: the state-free witness —
#      the old "reply-less transient ignored" rc-0 expectation is
#      retired; an observed entry's packet already left under the
#      revoked accept): conntrack-delete-fails keeps the row -> rc 1,
#      the S1 die, no `removed:`.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 117 NONE src=10.199.60.9 dst=192.0.2.10 sport=58670 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58670 mark=0 zone=0 use=1\n' > "$CTTABLE"
touch "$ARCMOCK_STATE/nft/conntrack-delete-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-delete-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"still has a live conntrack entry"* \
      && "$d_out" == *"NONE"* \
      && "$d_out" == *"— next action: end the leftover connections: egresslock drop-unauthorized two 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"* \
      && "$d_out" != *"finish the kill-switch by hand"* \
      && "$d_out" == *"not proven gone"* \
      && "$d_out" != *"fresh packets now drop and the entry drains"* ]] \
   && ! grep -q 'removed:' <<<"$d_out"; then
    a139 pass
else
    a139 fail "NONE observed survivor dies loudly (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi

# e231-list-fails (13b; EGL-317 S3 update): a failing -L after the swap
# dies at the READ with the working $bin -L hint (EGL-231-D1/D3), not the
# proc-read remediation, apt install, or retry advice. The post-swap trap
# prints the new one-line S3 drop-unauthorized recovery command (EGL-317)
# instead of the retired member-phase hand-finish; `removed:` stays
# unprinted.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.60.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58670 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
touch "$ARCMOCK_STATE/nft/conntrack-list-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-list-fails"
S3_139="disallow-host: the revocation is only half done — the rule is out of the firewall, but the connections that were open were not ended — state: conf line removed, ruleset swapped, conntrack not proven clean; next action: end the leftover connections: egresslock drop-unauthorized two 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"
if [[ "$d_rc" == 1 && "$d_out" == *"cannot read the rootless netns conntrack table"* \
      && "$d_out" == *"$TESTROOT/bin/conntrack -L -p tcp --dport 2222 -d 192.0.2.10"* \
      && "$d_out" != *"cat /proc/net/nf_conntrack"* \
      && "$d_out" != *"retry disallow-host"* \
      && "$d_out" != *"sudo apt install conntrack"* ]] \
   && ! grep -qE '^Error: cannot read the rootless netns conntrack table.*-D ' <<<"$d_out" \
   && grep -qxF "$S3_139" <<<"$d_out" \
   && ! grep -q 'removed:' <<<"$d_out" \
   && ! grep -q 'rule allow-host git.example.test:2222' "$EH/two.conf"; then
    a139 pass
else
    a139 fail "failed -L read dies at the read with the -L hint (rc=$d_rc, out: $(echo "$d_out" | tr '\n' '|' | head -c 500))"
fi

# 14. SYN_SENT observed survivor (EGL-297-D5/M1 — the old
#     "transient ignored" rc-0 expectation is retired; an observed
#     entry can still complete if the peer replies): conntrack-delete-
#     fails keeps the row in the table so the $1=="tcp" -L-shape awk is
#     actually exercised (EGL-231-D4) -> rc 1, the S1 die, no
#     `removed:`.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 119 SYN_SENT src=10.199.60.9 dst=192.0.2.10 sport=58670 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58670 mark=0 zone=0 use=1\n' > "$CTTABLE"
touch "$ARCMOCK_STATE/nft/conntrack-delete-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-delete-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"still has a live conntrack entry"* \
      && "$d_out" == *"SYN_SENT"* \
      && "$d_out" == *"— next action: end the leftover connections: egresslock drop-unauthorized two 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"* \
      && "$d_out" != *"finish the kill-switch by hand"* \
      && "$d_out" == *"not proven gone"* \
      && "$d_out" != *"fresh packets now drop and the entry drains"* ]] \
   && ! grep -q 'removed:' <<<"$d_out"; then
    a139 pass
else
    a139 fail "SYN_SENT observed survivor dies loudly (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi

# e231-absent-proc (EGL-231-D4, the reporter's host shape): the netns has
# NO /proc/net/nf_conntrack (conntrack-table-absent marker = ENOENT for
# any proc reader) — the disallow completes rc 0 with `removed:` because
# the proof reads ctnetlink -L; a regressed proc reader would die ENOENT.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.60.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
touch "$ARCMOCK_STATE/nft/conntrack-table-absent"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-table-absent"
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]] \
   && grep -qxF 'conntrack -L -p tcp --dport 2222 -d 192.0.2.10' "$CTLOG"; then
    a139 pass
else
    a139 fail "absent proc table: -L reader completes rc 0 (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi

# e231-flush-noop-message (EGL-231-D2/Q2): an empty table — the flush
# deletes nothing (the reporter's no-live-flow case) — prints NO
# `warn: conntrack delete ... failed` line, and the empty -L dump is
# rc 0 (upstream print_stats exempts the list summary from the
# zero-count failure — R-EGL-231-3 finding 1) and completes rc 0 with
# `removed:`.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
: > "$CTTABLE"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]] \
   && [[ "$d_out" != *"warn: conntrack delete"* ]]; then
    a139 pass
else
    a139 fail "no-op flush is silent, empty -L dump is success (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi
: > "$CTTABLE"

# R-EGL-231-3 finding 1 regression battery: EVERY nonzero -L rc must
# die at the read — `removed:` stays unprinted, the post-swap state is
# disclosed (conf line removed, ruleset swapped, ct unproven), and no
# summary text (a 0-shown summary, a zero-summary-plus-error
# transcript, a positive count ending in zero, partial rows) can bless
# a failed read into a success.
e231_list_fail_case() { # e231_list_fail_case <marker> <label>
    local marker="$1" label="$2"
    env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
    printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.60.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
    : > "$CTLOG"
    touch "$ARCMOCK_STATE/nft/$marker"
    d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
    rm -f "$ARCMOCK_STATE/nft/$marker"
    if [[ "$d_rc" == 1 && "$d_out" == *"cannot read the rootless netns conntrack table (rc=1)"* \
          && "$d_out" == *"state: conf line removed, ruleset swapped, ct unproven"* \
          && "$d_out" == *"$TESTROOT/bin/conntrack -L -p tcp --dport 2222 -d 192.0.2.10"* ]] \
       && ! grep -q 'removed:' <<<"$d_out" \
       && ! grep -q 'rule allow-host git.example.test:2222' "$EH/two.conf"; then
        a139 pass
    else
        a139 fail "failed -L shape $label dies at the read, no removed: (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
    fi
}
# nonzero rc + empty output (empty stdout/stderr beyond the error).
e231_list_fail_case conntrack-list-fails 'empty-output'
# nonzero rc + a zero-shown summary (the withdrawn D6 exception shape:
# the substring exception would have wrongly blessed this into a green
# `removed:`).
e231_list_fail_case conntrack-list-nonzero-empty 'zero-summary'
# nonzero rc + zero summary PLUS an error line in the transcript (the
# combined shape the substring exception would have matched).
e231_list_fail_case conntrack-list-zero-summary-error 'zero-summary-plus-error'
# nonzero rc + a POSITIVE count ending in zero ("10 … shown") — the
# substring match could begin at the count's final digit; the delimited
# read gate ignores summary text entirely.
e231_list_fail_case conntrack-list-nonzero-count 'positive-count-nonzero-rc'
# nonzero rc + partial rows on stdout (a truncated dump followed by
# failure) — never a success, and never the survivor die either (the
# read itself failed).
e231_list_fail_case conntrack-list-partial-rows-fail 'partial-rows'

# e231-tuple-direction (re-contracted EGL-312): a row matching the
# revoked tuple on the reply side is the reversed-orig shape the
# reviewer's F2 probe reproduces (R-EGL-306-3 F2) — the pre-EGL-312
# "neither deleted nor listed" pin is superseded (the row IS the
# finding): the peer-direction delete/witness covers it, the scoped
# flush proves its absence, and the disallow still completes.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.10 dst=10.199.60.9 sport=2222 dport=58670 src=10.199.60.9 dst=192.0.2.10 sport=58670 dport=2222 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]] \
   && ! grep -qF 'src=192.0.2.10 ' "$CTTABLE" \
   && grep -qxF 'conntrack -L -p tcp --dport 2222 -d 192.0.2.10' "$CTLOG" \
   && ! grep -qF 'conntrack -D -p tcp --dport 2222 -d 192.0.2.10' "$CTLOG" \
   && grep -qxF 'conntrack -L -p tcp --sport 2222 -s 192.0.2.10' "$CTLOG" \
   && grep -qxF 'conntrack -D -p tcp -s 192.0.2.10 --sport 2222 -d 10.199.60.9 --dport 58670' "$CTLOG"; then
    a139 pass
else
    a139 fail "peer-direction row is covered (rc=$d_rc, table: $(tr '\n' '|' < "$CTTABLE"), log: $(tr '\n' '|' < "$CTLOG"), out: $(echo "$d_out" | tail -1))"
fi
: > "$CTTABLE"

# EGL-312 survivor-die (the F5 exact-tuple pin): the reversed row stays
# alive (conntrack-delete-fails hits the exact-tuple peer delete) and the
# peer-direction witness dies rc 1 named (S1r) — the printed recovery is
# the profile-scoped engine verb (EGL-327), not a hand-typed tuple. The
# orig enumerate/witness are empty (orig dst/dport do not match — no
# in-scope row means no orig -D at all, EGL-313) and they run first; the
# peer -L finds the row.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.10 dst=10.199.60.9 sport=2222 dport=58670 src=10.199.60.9 dst=192.0.2.10 sport=58670 dport=2222 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
touch "$ARCMOCK_STATE/nft/conntrack-delete-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-delete-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"from 192.0.2.10:2222"* \
      && "$d_out" == *"(the peer's direction)"* \
      && "$d_out" == *"— next action: end the leftover connections: egresslock drop-unauthorized two 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"* \
      && "$d_out" != *"finish the kill-switch by hand"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -qxF 'conntrack -D -p tcp -s 192.0.2.10 --sport 2222 -d 10.199.60.9 --dport 58670' "$CTLOG" \
   && grep -qxF 'conntrack -L -p tcp --sport 2222 -s 192.0.2.10' "$CTLOG"; then
    a139 pass
else
    a139 fail "peer-direction survivor dies named (rc=$d_rc, out: $(echo "$d_out" | tail -1), log: $(tr '\n' '|' < "$CTLOG"))"
fi
# R-EGL-312-2 F2 (EGL-327 D5): the printed recovery's effect — run the
# verb the die names (marker already cleared) and confirm the survivor is
# gone (the fixture carries only that row; the die's displayed entry and
# the command agree); the verb's peer-direction pass covers this row.
u139p="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock drop-unauthorized two 2222 2>&1)"; u139p_rc=$?
if [[ "$u139p_rc" == 0 ]] \
   && grep -qxF "drop-unauthorized: no leftover connection on port 2222 remains that profile 'two' does not allow" <<<"$u139p" \
   && [[ ! -s "$CTTABLE" ]]; then
    a139 pass
else
    a139 fail "S1r printed recovery removes the survivor (rc=$u139p_rc, out: $u139p, table: $(tr '\n' '|' < "$CTTABLE"))"
fi

# EGL-312 half-closed survivor (the X20c class the widened witness must
# keep): the same peer-direction shape with row state CLOSE_WAIT — the
# witness is state-free (M1), so the survivor dies named.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 59 CLOSE_WAIT src=192.0.2.10 dst=10.199.60.9 sport=2222 dport=58670 src=10.199.60.9 dst=192.0.2.10 sport=58670 dport=2222 mark=0 zone=0 use=1\n' > "$CTTABLE"
: > "$CTLOG"
touch "$ARCMOCK_STATE/nft/conntrack-delete-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-delete-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"from 192.0.2.10:2222"* \
      && "$d_out" == *"(the peer's direction)"* \
      && "$d_out" == *"CLOSE_WAIT"* ]] \
   && ! grep -q 'removed:' <<<"$d_out"; then
    a139 pass
else
    a139 fail "peer-direction CLOSE_WAIT survivor dies named (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi
: > "$CTTABLE"
# 15. CONNTRACK_BIN env guards mirror ARC-59 (leading-dash / non-exec).
d_out="$(CONNTRACK_BIN=-x env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two cache.example.test:8080 2>&1)"; d_rc=$?
[[ "$d_rc" == 1 && "$d_out" == *"must not start with '-'"* ]] \
    && a139 pass || a139 fail "CONNTRACK_BIN leading-dash guard (rc=$d_rc, out: $(echo "$d_out" | head -2 | tr '\n' '|'))"

# EGL-219: the set-shaped pin record / verify zip / multi-daddr flush.
cat > "$EH/mset.conf" <<'EOF'
profile mset 10.199.62.0/24
    rule allow-host duo.example.test:443
EOF
cat > "$EH/dup.conf" <<'EOF'
profile dup 10.199.63.0/24
    rule allow-host dup.example.test:8443
    rule allow-host dup.example.test:8443
EOF
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/mset.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="duo.example.test=192.0.2.21+192.0.2.20,dup.example.test=192.0.2.31+192.0.2.30" \
    egresslock ensure mset >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/dup.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="dup.example.test=192.0.2.30+192.0.2.31" \
    egresslock ensure dup >/dev/null 2>&1

# 16. multi-A record content: one line per conf entry, value = the
#     sorted set; the chain carries one accept per member.
[[ "$(cat "$EH/mset.pins")" == 'duo.example.test|443 192.0.2.20 192.0.2.21' ]] \
    && a139 pass || a139 fail "multi-A record content (got: $(cat "$EH/mset.pins"))"
if [[ "$(grep -c 'ip daddr 192.0.2.20 tcp dport 443' "$STATE/nft/egresslock.p_mset")" == 1 \
      && "$(grep -c 'ip daddr 192.0.2.21 tcp dport 443' "$STATE/nft/egresslock.p_mset")" == 1 ]]; then
    a139 pass
else
    a139 fail "multi-A chain accepts missing"
fi
v_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/mset.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="duo.example.test=192.0.2.20+192.0.2.21" egresslock verify mset 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" != *"drift:"* ]]; then
    a139 pass
else
    a139 fail "multi-A verify green (rc=$v_rc, out: $v_out)"
fi

# 17. old single-A record (pre-EGL-219 shape) parses as a 1-element
#     set: drop the chain to the old 1-accept shape, keep a single
#     token in the record -> verify green (drift warns on the set
#     change, rc 0).
sed -i '/ip daddr 192.0.2.21 tcp dport 443/d' "$STATE/nft/egresslock.p_mset"
printf 'duo.example.test|443 192.0.2.20\n' > "$EH/mset.pins"
v_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/mset.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="duo.example.test=192.0.2.20+192.0.2.21" egresslock verify mset 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" == *"drift: host duo.example.test resolved to 192.0.2.20,192.0.2.21 but the policy pins 192.0.2.20 — re-run ensure to update"* ]]; then
    a139 pass
else
    a139 fail "old single-A record accepted as a 1-element set (rc=$v_rc, out: $v_out)"
fi

# 18. one-member tamper -> named rc-1 mismatch; the record value in the
#     message is the entry's whole set, the chain value the tampered
#     member.
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/mset.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="duo.example.test=192.0.2.20+192.0.2.21" \
    egresslock ensure mset >/dev/null 2>&1
sed -i 's/ip daddr 192.0.2.21 tcp dport 443/ip daddr 192.0.2.77 tcp dport 443/' \
    "$STATE/nft/egresslock.p_mset"
v_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/mset.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify mset 2>&1)"; v_rc=$?
if [[ "$v_rc" == 1 && "$v_out" == *"verify: allow-host pin daddr mismatch for duo.example.test:443 (record: 192.0.2.20 192.0.2.21, chain: 192.0.2.77) — re-run: egresslock ensure mset"* ]]; then
    a139 pass
else
    a139 fail "one-member tamper -> named set mismatch rc 1 (rc=$v_rc, out: $v_out)"
fi
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/mset.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="duo.example.test=192.0.2.20+192.0.2.21" \
    egresslock ensure mset >/dev/null 2>&1

# 19. legal duplicate conf entry (the grammar is "ordered, repeatable"):
#     the ensure writes its identical record line twice; the reader
#     collapses identicals; the count is Σ per conf entry (4 accepts,
#     2 entries x 2 members) -> verify green, NOT a false mismatch.
[[ "$(cat "$EH/dup.pins")" == $'dup.example.test|8443 192.0.2.30 192.0.2.31\ndup.example.test|8443 192.0.2.30 192.0.2.31' ]] \
    && a139 pass || a139 fail "duplicate conf entry writes identical record lines (got: $(cat "$EH/dup.pins" | tr '\n' '|'))"
v_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/dup.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="dup.example.test=192.0.2.30+192.0.2.31" egresslock verify dup 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 && "$v_out" != *"drift:"* ]]; then
    a139 pass
else
    a139 fail "legal duplicate conf entry verifies green (rc=$v_rc, out: $v_out)"
fi

# 20. disagreeing duplicate key -> named corrupt rc 1 (strictness gain
#     over the old silent last-wins).
printf 'dup.example.test|8443 192.0.2.30 192.0.2.31\ndup.example.test|8443 192.0.2.30 192.0.2.99\n' > "$EH/dup.pins"
v_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/dup.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify dup 2>&1)"; v_rc=$?
if [[ "$v_rc" == 1 && "$v_out" == *"disagreeing duplicate key for dup.example.test:8443) — re-run: egresslock ensure dup"* ]]; then
    a139 pass
else
    a139 fail "disagreeing duplicate key -> named corrupt (rc=$v_rc, out: $v_out)"
fi

# 21. repeated address within one line -> named corrupt.
printf 'dup.example.test|8443 192.0.2.30 192.0.2.30\n' > "$EH/dup.pins"
v_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/dup.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify dup 2>&1)"; v_rc=$?
if [[ "$v_rc" == 1 && "$v_out" == *"repeated address in line: 'dup.example.test|8443 192.0.2.30 192.0.2.30') — re-run: egresslock ensure dup"* ]]; then
    a139 pass
else
    a139 fail "repeated token in record line -> named corrupt (rc=$v_rc, out: $v_out)"
fi
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/dup.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="dup.example.test=192.0.2.30+192.0.2.31" \
    egresslock ensure dup >/dev/null 2>&1

# 22. D9: a corrupt pin record aborts disallow-host named BEFORE the
#     conf mutation — no removed: line, conf line still present.
printf 'duo.example.test|443 not-an-ip\n' > "$EH/mset.pins"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/mset.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host mset duo.example.test:443 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 && "$d_out" == *"disallow-host: pin record unreadable for profile 'mset' (corrupt line: 'duo.example.test|443 not-an-ip') — re-run: egresslock ensure mset"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -q 'rule allow-host duo.example.test:443' "$EH/mset.conf"; then
    a139 pass
else
    a139 fail "corrupt record aborts disallow-host named (rc=$d_rc, out: $(echo "$d_out" | head -2 | tr '\n' '|'))"
fi

# 23. D9: a missing record file aborts disallow-host named, likewise
#     before the mutation.
mv "$EH/mset.pins" "$EH/mset.pins.bak"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/mset.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host mset duo.example.test:443 2>&1)"; d_rc=$?
mv "$EH/mset.pins.bak" "$EH/mset.pins"
if [[ "$d_rc" == 1 && "$d_out" == *"disallow-host: pin record unreadable for profile 'mset' (missing file)"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -q 'rule allow-host duo.example.test:443' "$EH/mset.conf"; then
    a139 pass
else
    a139 fail "missing record aborts disallow-host named (rc=$d_rc, out: $(echo "$d_out" | head -2 | tr '\n' '|'))"
fi

# 24. disallow-host flushes EVERY pinned member's conntrack tuple
#     (-D then -L per member), `removed:` last; a single-address pin
#     stays byte-identical (leg 9 above).
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/mset.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="duo.example.test=192.0.2.20+192.0.2.21" \
    egresslock ensure mset >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.62.5 dst=192.0.2.20 sport=50001 dport=443 src=192.0.2.20 dst=10.0.2.15 sport=443 dport=50001 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=10.199.62.6 dst=192.0.2.21 sport=50002 dport=443 src=192.0.2.21 dst=10.0.2.15 sport=443 dport=50002 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/mset.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host mset duo.example.test:443 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]] \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.62.5 --sport 50001 -d 192.0.2.20 --dport 443' "$CTLOG" \
   && grep -qxF 'conntrack -L -p tcp --dport 443 -d 192.0.2.20' "$CTLOG" \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.62.6 --sport 50002 -d 192.0.2.21 --dport 443' "$CTLOG" \
   && grep -qxF 'conntrack -L -p tcp --dport 443 -d 192.0.2.21' "$CTLOG"; then
    a139 pass
else
    a139 fail "multi-member flush (-D/-L per member) (rc=$d_rc, log: $(tr '\n' '|' < "$CTLOG"))"
fi
! grep -q 'rule allow-host duo.example.test:443' "$EH/mset.conf" \
    && a139 pass || a139 fail "multi-member disallow removed the conf line"
# The revoked profile now has zero allow-hosts: its record is removed.
[[ ! -e "$EH/mset.pins" ]] \
    && a139 pass || a139 fail "zero-allow-host record removed after revocation"

# EGL-295: the post-swap port reconcile. Fixture `rot` 10.199.64.0/24 with
# two same-port name pins (`rot.example.test:2222` +
# `keep.example.test:2222`; keep stays fixed). The ct table models the
# account netns: the OLD rot entry (192.0.2.20, in-subnet), the keep entry
# (192.0.2.30, still accepted) and a foreign source (169.254.2.5).
cat > "$EH/rot.conf" <<'EOF'
profile rot 10.199.64.0/24
    rule allow-host rot.example.test:2222
    rule allow-host keep.example.test:2222
EOF
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.20,keep.example.test=192.0.2.30" \
    egresslock ensure rot >/dev/null 2>&1
# e295-a. rotated pin: pinned flow to .20, then the EGL-219 refresh moves it
#     to .21; disallow must flush the CURRENT member (.21) AND the earlier
#     .20 (the reconcile), leaving the accepted sibling (.30) and foreign
#     row (.40). An extra .21 in-scope row keeps the member leg observable
#     (EGL-313: no unconditional broad -D when the member has no row).
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.64.5 dst=192.0.2.20 sport=58666 dport=2222 src=192.0.2.20 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=10.199.64.7 dst=192.0.2.21 sport=58668 dport=2222 src=192.0.2.21 dst=10.0.2.15 sport=2222 dport=58668 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=10.199.64.6 dst=192.0.2.30 sport=40001 dport=2222 src=192.0.2.30 dst=10.0.2.15 sport=2222 dport=40001 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=169.254.2.5 dst=192.0.2.40 sport=50000 dport=2222 src=192.0.2.40 dst=10.0.2.15 sport=2222 dport=50000 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock ensure rot >/dev/null 2>&1
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock disallow-host rot rot.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]] \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.64.7 --sport 58668 -d 192.0.2.21 --dport 2222' "$CTLOG" \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.64.5 --sport 58666 -d 192.0.2.20 --dport 2222' "$CTLOG" \
   && grep -qxF 'conntrack -L -p tcp --dport 2222 -d 192.0.2.20' "$CTLOG" \
   && ! grep -qE 'conntrack -D .*-d 192\.0\.2\.30 ' "$CTLOG" \
   && ! grep -qE 'conntrack -D .*-d 192\.0\.2\.40 ' "$CTLOG"; then
    a139 pass
else
    a139 fail "reconcile: rotated-pin old member flushed, sibling/foreign untouched (rc=$d_rc, log: $(tr '\n' '|' < "$CTLOG"))"
fi
grep -qF 'dst=192.0.2.30 ' "$CTTABLE" && grep -qF 'dst=192.0.2.40 ' "$CTTABLE" \
    && ! grep -qF 'dst=192.0.2.20 ' "$CTTABLE" \
    && a139 pass || a139 fail "reconcile: old-address row gone; accepted sibling + foreign rows remain (table: $(tr '\n' '|' < "$CTTABLE"))"
# e295-b. the reconcile's enumerate read fails -> fail closed named with
#     the S6 line (`conntrack unproven`; `removed:` unprinted; the
#     -d-scoped member read already succeeded first).
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock allow-host rot rot.example.test:2222 >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock ensure rot >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.64.6 dst=192.0.2.30 sport=40001 dport=2222 src=192.0.2.30 dst=10.0.2.15 sport=2222 dport=40001 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
touch "$ARCMOCK_STATE/nft/conntrack-list-port-fails"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock disallow-host rot rot.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-list-port-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"cannot read the rootless netns conntrack table (rc=1)"* \
      && "$d_out" == *"state: conf line removed, ruleset swapped, conntrack unproven"* \
      && "$d_out" == *"$TESTROOT/bin/conntrack -L -p tcp --dport 2222"* \
      && "$d_out" != *'-d 192.0.2.20'* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && ! grep -qF 'conntrack -D -p tcp --dport 2222 -d 192.0.2.30' "$CTLOG"; then
    a139 pass
else
    a139 fail "enumerate read failure dies named at the read, no removed: (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi

# e295-c (EGL-297 critique fold): a SYN_SENT2 candidate on the rotated
#     earlier address must reach the widened candidate parse + the
#     witness — pre-fold the `[A-Z_]+` parse drops the digit-bearing
#     token (rc 0 + `removed:` over a live reply-seen flow); now the
#     reconcile flushes .20, the scoped -L returns the row, and the v2
#     witness dies rc 1 naming the profile-scoped verb (EGL-327).
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock allow-host rot rot.example.test:2222 >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock ensure rot >/dev/null 2>&1
printf 'ipv4 2 tcp 6 117 SYN_SENT2 src=10.199.64.5 dst=192.0.2.20 sport=58666 dport=2222 src=192.0.2.20 dst=10.0.2.15 sport=2222 dport=58666 mark=0 zone=0 use=1\n' > "$CTTABLE"
: > "$CTLOG"
touch "$ARCMOCK_STATE/nft/conntrack-delete-fails"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock disallow-host rot rot.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-delete-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"still has a live conntrack entry"* \
      && "$d_out" == *"SYN_SENT2"* \
      && "$d_out" == *"— next action: end the leftover connections: egresslock drop-unauthorized rot 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"* \
      && "$d_out" != *"finish the kill-switch by hand"* \
      && "$d_out" == *"not proven gone"* \
      && "$d_out" != *"fresh packets now drop and the entry drains"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.64.5 --sport 58666 -d 192.0.2.20 --dport 2222' "$CTLOG" \
   && grep -qxF 'conntrack -L -p tcp --dport 2222 -d 192.0.2.20' "$CTLOG"; then
    a139 pass
else
    a139 fail "reconcile SYN_SENT2 candidate flushed + witness-checked (rc=$d_rc, log: $(tr '\n' '|' < "$CTLOG"))"
fi

# EGL-312 reconcile reversed admission (R-EGL-306-3 F2): reversed-orig
# rows (src=<peer> sport=2222 — the shape an incoming packet mints) are
# admitted from the sport-only enumerate when the workload end (orig
# dst) is in this profile's subnet and the peer is not a current chain
# member; each admitted row is flushed by its exact original tuple. The
# accepted keep member's reversed row stays (accepted-set skip) and no
# delete names it.
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock allow-host rot rot.example.test:2222 >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock ensure rot >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.20 dst=10.199.64.5 sport=2222 dport=58666 src=10.199.64.5 dst=192.0.2.20 sport=58666 dport=2222 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.30 dst=10.199.64.6 sport=2222 dport=40001 src=10.199.64.6 dst=192.0.2.30 sport=40001 dport=2222 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock disallow-host rot rot.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]] \
   && ! grep -qF 'src=192.0.2.20 ' "$CTTABLE" \
   && grep -qF 'src=192.0.2.30 ' "$CTTABLE" \
   && grep -qxF 'conntrack -L -p tcp --sport 2222' "$CTLOG" \
   && grep -qxF 'conntrack -L -p tcp --sport 2222 -s 192.0.2.20' "$CTLOG" \
   && grep -qxF 'conntrack -D -p tcp -s 192.0.2.20 --sport 2222 -d 10.199.64.5 --dport 58666' "$CTLOG" \
   && ! grep -qF 'conntrack -D -p tcp -s 192.0.2.30' "$CTLOG"; then
    a139 pass
else
    a139 fail "reconcile admits reversed earlier-address candidate (rc=$d_rc, table: $(tr '\n' '|' < "$CTTABLE"), log: $(tr '\n' '|' < "$CTLOG"))"
fi

# EGL-312 same fixture, delete-fails: the admitted reversed row's
# exact-tuple delete fails, the peer witness still sees the row and the
# command dies rc 1 named (S1r, the peer's direction); nothing completed.
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock allow-host rot rot.example.test:2222 >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock ensure rot >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.20 dst=10.199.64.5 sport=2222 dport=58666 src=10.199.64.5 dst=192.0.2.20 sport=58666 dport=2222 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.30 dst=10.199.64.6 sport=2222 dport=40001 src=10.199.64.6 dst=192.0.2.30 sport=40001 dport=2222 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
touch "$ARCMOCK_STATE/nft/conntrack-delete-fails"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock disallow-host rot rot.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-delete-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"from 192.0.2.20:2222"* \
      && "$d_out" == *"(the peer's direction)"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -qxF 'conntrack -D -p tcp -s 192.0.2.20 --sport 2222 -d 10.199.64.5 --dport 58666' "$CTLOG"; then
    a139 pass
else
    a139 fail "reconcile reversed row delete-fails dies named (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi

# EGL-312 cross-profile preservation (F5): two reversed rows for the
# SAME peer:port with different workload ends — 10.199.60.9 (profile
# two's subnet, admitted) and 10.199.64.5 (profile rot's subnet,
# another profile's row). The `two` disallow deletes the admitted row
# only; the rot row is intact and no delete names its workload end.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.10 dst=10.199.60.9 sport=2222 dport=58670 src=10.199.60.9 dst=192.0.2.10 sport=58670 dport=2222 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.10 dst=10.199.64.5 sport=2222 dport=40001 src=10.199.64.5 dst=192.0.2.10 sport=40001 dport=2222 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]] \
   && ! grep -qF 'dst=10.199.60.9 sport=2222' "$CTTABLE" \
   && grep -qF 'dst=10.199.64.5 sport=2222' "$CTTABLE" \
   && ! grep -qF 'conntrack -D -p tcp -s 192.0.2.10 --sport 2222 -d 10.199.64.5' "$CTLOG"; then
    a139 pass
else
    a139 fail "cross-profile reversed row preserved (rc=$d_rc, table: $(tr '\n' '|' < "$CTTABLE"), log: $(tr '\n' '|' < "$CTLOG"))"
fi
: > "$CTTABLE"

# EGL-312 cross-profile recovery (R-EGL-312-2 F2): the same two-row
# fixture, conntrack-delete-fails — the admitted `two` row's exact-tuple
# delete fails and the witness dies S1r naming the profile-scoped verb
# (EGL-327); the output never names the rot row's 10.199.64.5. Running
# the verb (marker cleared) removes only that row.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure two >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.10 dst=10.199.60.9 sport=2222 dport=58670 src=10.199.60.9 dst=192.0.2.10 sport=58670 dport=2222 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.10 dst=10.199.64.5 sport=2222 dport=40001 src=10.199.64.5 dst=192.0.2.10 sport=40001 dport=2222 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
touch "$ARCMOCK_STATE/nft/conntrack-delete-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-delete-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"(the peer's direction)"* \
      && "$d_out" == *"— next action: end the leftover connections: egresslock drop-unauthorized two 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"* \
      && "$d_out" != *"finish the kill-switch by hand"* \
      && "$d_out" != *"10.199.64.5"* ]] \
   && grep -qF 'dst=10.199.60.9 sport=2222' "$CTTABLE" \
   && grep -qF 'dst=10.199.64.5 sport=2222' "$CTTABLE"; then
    a139 pass
else
    a139 fail "cross-profile S1r names the profile-scoped verb (rc=$d_rc, out: $(echo "$d_out" | tail -2), table: $(tr '\n' '|' < "$CTTABLE"))"
fi
u139c="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock drop-unauthorized two 2222 2>&1)"; u139c_rc=$?
if [[ "$u139c_rc" == 0 ]] \
   && grep -qxF "drop-unauthorized: no leftover connection on port 2222 remains that profile 'two' does not allow" <<<"$u139c" \
   && ! grep -qF 'dst=10.199.60.9 sport=2222' "$CTTABLE" \
   && grep -qF 'dst=10.199.64.5 sport=2222' "$CTTABLE"; then
    a139 pass
else
    a139 fail "S1r printed recovery removes only the profile-two row (rc=$u139c_rc, out: $u139c, table: $(tr '\n' '|' < "$CTTABLE"))"
fi
: > "$CTTABLE"

# EGL-312 digit-bearing reversed class (F4): a reversed SYN_SENT2 row
# for the unaccepted earlier address is admitted by the reconcile (the
# parse class admits the digit-bearing token) and flushed; with
# conntrack-delete-fails the M1 state-free witness dies named.
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock allow-host rot rot.example.test:2222 >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock ensure rot >/dev/null 2>&1
printf 'ipv4 2 tcp 6 117 SYN_SENT2 src=192.0.2.20 dst=10.199.64.5 sport=2222 dport=58666 src=10.199.64.5 dst=192.0.2.20 sport=58666 dport=2222 mark=0 zone=0 use=1\n' > "$CTTABLE"
: > "$CTLOG"
touch "$ARCMOCK_STATE/nft/conntrack-delete-fails"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock disallow-host rot rot.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-delete-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"from 192.0.2.20:2222"* \
      && "$d_out" == *"(the peer's direction)"* \
      && "$d_out" == *"SYN_SENT2"* ]] \
   && ! grep -q 'removed:' <<<"$d_out"; then
    a139 pass
else
    a139 fail "reversed SYN_SENT2 admitted + witness dies named (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi
: > "$CTTABLE"

# EGL-312 read-failure legs (F3): each new engine read branch dies named
# with its exact recovery argv + `ct unproven`, no `removed:`; earlier
# reads/deletes succeed first. Mutations verified separately (per-branch
# rc-gate removal: the witness gate reds only the recheck leg).

# peer read (member leg pre-read): the orig enumerate/witness ran first
# (no in-scope orig row, so no orig -D, EGL-313); the
# phase counter pins the die to the FIRST peer-shaped read (the
# witness never fired — gate-1 removal is observable as counter==2).
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.10 dst=10.199.60.9 sport=2222 dport=58670 src=10.199.60.9 dst=192.0.2.10 sport=58670 dport=2222 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
rm -f "$ARCMOCK_STATE/nft/conntrack-peer-reads"
touch "$ARCMOCK_STATE/nft/conntrack-list-peer-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-list-peer-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"cannot read the rootless netns conntrack table (rc=1)"* \
      && "$d_out" == *"state: conf line removed, ruleset swapped, ct unproven"* \
      && "$d_out" == *"$TESTROOT/bin/conntrack -L -p tcp --sport 2222 -s 192.0.2.10"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && ! grep -qF 'conntrack -D -p tcp --dport 2222 -d 192.0.2.10' "$CTLOG" \
   && grep -qxF 'conntrack -L -p tcp --dport 2222 -d 192.0.2.10' "$CTLOG" \
   && ! grep -qF 'conntrack -D -p tcp -s 192.0.2.10 --sport 2222' "$CTLOG" \
   && [[ "$(cat "$ARCMOCK_STATE/nft/conntrack-peer-reads" 2>/dev/null || echo 0)" == 1 ]]; then
    a139 pass
else
    a139 fail "peer read dies named after the orig pair (rc=$d_rc, out: $(echo "$d_out" | tail -1), log: $(tr '\n' '|' < "$CTLOG"))"
fi
rm -f "$ARCMOCK_STATE/nft/conntrack-peer-reads"
: > "$CTTABLE"

# peer recheck (post-delete witness): the pre-delete read returned the
# row and the exact-tuple delete ran first (counter rm'd before/after).
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.10 dst=10.199.60.9 sport=2222 dport=58670 src=10.199.60.9 dst=192.0.2.10 sport=58670 dport=2222 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
rm -f "$ARCMOCK_STATE/nft/conntrack-peer-reads"
touch "$ARCMOCK_STATE/nft/conntrack-list-peer-recheck-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-list-peer-recheck-fails" "$ARCMOCK_STATE/nft/conntrack-peer-reads"
if [[ "$d_rc" == 1 && "$d_out" == *"cannot read the rootless netns conntrack table (rc=1)"* \
      && "$d_out" == *"$TESTROOT/bin/conntrack -L -p tcp --sport 2222 -s 192.0.2.10"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -qxF 'conntrack -D -p tcp -s 192.0.2.10 --sport 2222 -d 10.199.60.9 --dport 58670' "$CTLOG" \
   && ! grep -qF 'src=192.0.2.10 dst=10.199.60.9 sport=2222' "$CTTABLE" \
   && [[ "$(grep -cxF 'conntrack -L -p tcp --sport 2222 -s 192.0.2.10' "$CTLOG")" == 2 ]]; then
    a139 pass
else
    a139 fail "witness recheck dies named after the exact-tuple delete (rc=$d_rc, out: $(echo "$d_out" | tail -1), log: $(tr '\n' '|' < "$CTLOG"))"
fi
: > "$CTTABLE"

# sport-only enumerate (reconcile reversed read): earlier reads fine.
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock allow-host rot rot.example.test:2222 >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock ensure rot >/dev/null 2>&1
: > "$CTLOG"
touch "$ARCMOCK_STATE/nft/conntrack-list-sport-fails"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock disallow-host rot rot.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-list-sport-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"cannot read the rootless netns conntrack table (rc=1)"* \
      && "$d_out" == *"ct unproven"* \
      && "$d_out" == *"$TESTROOT/bin/conntrack -L -p tcp --sport 2222"* ]] \
   && ! grep -qF "$TESTROOT/bin/conntrack -L -p tcp --sport 2222 -s" "$d_out" \
   && ! grep -q 'removed:' <<<"$d_out"; then
    a139 pass
else
    a139 fail "reversed enumerate read dies named (rc=$d_rc, out: $(echo "$d_out" | tail -1))"
fi

# EGL-311: the post-swap chain read is a proof input, not a belt. The
# reconcile must die named before `removed:` when the read fails, comes
# back empty, or is not a usable profile chain — and must not run the
# port enumerate or a broad flush. Reuses the e295 `rot` fixture; the
# mock markers are gated on a member -D so they fire at the reconcile
# read, not at write_pin_record/verify_expected_rules.
S1_311="Error: cannot read the firewall rules for profile 'rot' after the rule was removed (rc=1): Error: mock nft: netlink read of chain 'p_rot' failed once (fail-list-chain-after-flush); state: conf line removed, ruleset swapped, conntrack unproven; next action: the rule is already out and the firewall already replaced, but any connection left on port 2222 cannot be checked against the removed rule while the rules are unreadable — inspect what is left: podman unshare --rootless-netns $TESTROOT/bin/nft list chain inet egresslock p_rot; podman unshare --rootless-netns $TESTROOT/bin/conntrack -L -p tcp --dport 2222; then delete a leftover by hand: podman unshare --rootless-netns $TESTROOT/bin/conntrack -D -p tcp --dport 2222 -d <destination>"
S2_311="Error: the firewall rules for profile 'rot' came back empty, incomplete, or unusable after the rule was removed; state: conf line removed, ruleset swapped, conntrack unproven; next action: the rule is already out and the firewall already replaced, but any connection left on port 2222 cannot be checked against the removed rule while the rules are unreadable — inspect what is left: podman unshare --rootless-netns $TESTROOT/bin/nft list chain inet egresslock p_rot; podman unshare --rootless-netns $TESTROOT/bin/conntrack -L -p tcp --dport 2222; then delete a leftover by hand: podman unshare --rootless-netns $TESTROOT/bin/conntrack -D -p tcp --dport 2222 -d <destination>"
reset311() {
    cat > "$EH/rot.conf" <<'EOF'
profile rot 10.199.64.0/24
    rule allow-host rot.example.test:2222
    rule allow-host keep.example.test:2222
EOF
    rm -f "$STATE/nft/fail-list-chain-after-flush" \
          "$STATE/nft/partial-list-chain-after-flush" \
          "$STATE/nft/empty-list-chain-after-flush" \
          "$STATE/nft/header-list-chain-after-flush" \
          "$STATE/nft/garbage-list-chain-after-flush"
    env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.20,keep.example.test=192.0.2.30" \
        egresslock ensure rot >/dev/null 2>&1
    env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
        egresslock ensure rot >/dev/null 2>&1
    : > "$CTLOG"; : > "$CTTABLE"
}
seed311() {
    printf '%s\n' \
      'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.64.5 dst=192.0.2.20 sport=58666 dport=2222 src=192.0.2.20 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2' \
      'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.64.7 dst=192.0.2.21 sport=58668 dport=2222 src=192.0.2.21 dst=10.0.2.15 sport=2222 dport=58668 [ASSURED] mark=0 zone=0 use=2' \
      'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.64.6 dst=192.0.2.30 sport=40001 dport=2222 src=192.0.2.30 dst=10.0.2.15 sport=2222 dport=40001 [ASSURED] mark=0 zone=0 use=2' \
      'ipv4 2 tcp 6 431998 ESTABLISHED src=169.254.2.5 dst=192.0.2.40 sport=50000 dport=2222 src=192.0.2.40 dst=10.0.2.15 sport=2222 dport=50000 [ASSURED] mark=0 zone=0 use=2' \
      > "$CTTABLE"
}
run311() { # run311 [marker]
    [[ -n "${1:-}" ]] && touch "$STATE/nft/$1"
    e311_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
        egresslock disallow-host rot rot.example.test:2222 2>&1)"; e311_rc=$?
}
no_flush311() { # no_flush311 <label>
    ! grep -qxF 'conntrack -L -p tcp --dport 2222' "$CTLOG" \
        && a139 pass || a139 fail "$1: the port enumerate ran (log: $(tr '\n' '|' < "$CTLOG"))"
    ! grep -qE 'conntrack -D .*-d 192\.0\.2\.20 ' "$CTLOG" \
        && a139 pass || a139 fail "$1: the earlier address was flushed (log: $(tr '\n' '|' < "$CTLOG"))"
    grep -qF 'dst=192.0.2.20 ' "$CTTABLE" \
        && a139 pass || a139 fail "$1: the earlier-address row changed"
    grep -qF 'dst=192.0.2.30 ' "$CTTABLE" && grep -qF 'dst=192.0.2.40 ' "$CTTABLE" \
        && a139 pass || a139 fail "$1: sibling/foreign rows changed"
}

# e311-a: nonzero read, empty output -> S1 exact, no removed:, no flush.
reset311; seed311; run311 fail-list-chain-after-flush
[[ "$e311_rc" == 1 ]] && grep -qxF "$S1_311" <<<"$e311_out" \
    && a139 pass || a139 fail "e311-a rc 1 + S1 exact (rc=$e311_rc, out: $e311_out)"
! grep -q 'removed:' <<<"$e311_out" && a139 pass || a139 fail "e311-a printed removed:"
[[ ! -e "$STATE/nft/fail-list-chain-after-flush" ]] && a139 pass || a139 fail "e311-a marker not consumed"
no_flush311 e311-a

# e311-b: nonzero read with a complete-looking listing -> still S1
# (the status wins over stdout; the F1 matching-output shape).
reset311; seed311; run311 partial-list-chain-after-flush
[[ "$e311_rc" == 1 && "$e311_out" == *"cannot read the firewall rules for profile 'rot' after the rule was removed (rc=1)"* \
   && "$e311_out" == *"state: conf line removed, ruleset swapped, conntrack unproven"* ]] \
    && a139 pass || a139 fail "e311-b rc 1 + S1 cause on partial output (rc=$e311_rc, out: $(echo "$e311_out" | tail -1))"
! grep -q 'removed:' <<<"$e311_out" && a139 pass || a139 fail "e311-b printed removed:"
no_flush311 e311-b

# e311-c: rc 0 empty read -> S2 exact, no removed:, no flush.
reset311; seed311; run311 empty-list-chain-after-flush
[[ "$e311_rc" == 1 ]] && grep -qxF "$S2_311" <<<"$e311_out" \
    && a139 pass || a139 fail "e311-c rc 1 + S2 exact on empty read (rc=$e311_rc, out: $e311_out)"
! grep -q 'removed:' <<<"$e311_out" && a139 pass || a139 fail "e311-c printed removed:"
no_flush311 e311-c

# e311-d: rc 0 header-only listing -> S2 (the finding-3 broad-flush shape).
reset311; seed311; run311 header-list-chain-after-flush
[[ "$e311_rc" == 1 ]] && grep -qxF "$S2_311" <<<"$e311_out" \
    && a139 pass || a139 fail "e311-d rc 1 + S2 exact on header-only read (rc=$e311_rc, out: $e311_out)"
! grep -q 'removed:' <<<"$e311_out" && a139 pass || a139 fail "e311-d printed removed:"
no_flush311 e311-d

# e311-e: rc 0 non-chain text -> canonicalize rc 1 -> S2 (the unnamed
# set -e exit becomes a named refusal).
reset311; seed311; run311 garbage-list-chain-after-flush
[[ "$e311_rc" == 1 ]] && grep -qxF "$S2_311" <<<"$e311_out" \
    && a139 pass || a139 fail "e311-e rc 1 + S2 exact on unusable read (rc=$e311_rc, out: $e311_out)"
! grep -q 'removed:' <<<"$e311_out" && a139 pass || a139 fail "e311-e printed removed:"
no_flush311 e311-e

# e311-f: healthy control — the gate does not fire; the earlier address is
# still flushed and the accepted sibling / foreign source stay untouched.
reset311; seed311; run311
[[ "$e311_rc" == 0 && "$(grep -c '^removed:' <<<"$e311_out")" == 1 ]] \
    && a139 pass || a139 fail "e311-f healthy rc 0 + one removed: (rc=$e311_rc, out: $(echo "$e311_out" | tail -1))"
grep -qxF 'conntrack -D -p tcp -s 10.199.64.7 --sport 58668 -d 192.0.2.21 --dport 2222' "$CTLOG" \
    && grep -qxF 'conntrack -D -p tcp -s 10.199.64.5 --sport 58666 -d 192.0.2.20 --dport 2222' "$CTLOG" \
    && grep -qxF 'conntrack -L -p tcp --dport 2222 -d 192.0.2.20' "$CTLOG" \
    && ! grep -qE 'conntrack -D .*-d 192\.0\.2\.30 ' "$CTLOG" \
    && ! grep -qE 'conntrack -D .*-d 192\.0\.2\.40 ' "$CTLOG" \
    && a139 pass || a139 fail "e311-f healthy earlier-address flush + sibling/foreign untouched (log: $(tr '\n' '|' < "$CTLOG"))"
! grep -q 'cannot read the firewall rules\|came back empty, incomplete, or unusable' <<<"$e311_out" \
    && a139 pass || a139 fail "e311-f healthy path used a refusal string"

# e295-d. shared historical address: two rules pin the same address:port;
#     revoking one must NOT flush the earlier address the chain still
#     accepts via the sibling (EGL-295's accepted-set skip). Fixture `rot2`
#     10.199.80.0/24: rr.example.test:2222 rotates 192.0.2.50 -> .51;
#     sh.example.test:2222 stays .50. A .51 in-scope row keeps the member
#     leg observable (EGL-313: exact-tuple delete; .50 gets no -D).
cat > "$EH/rot2.conf" <<'EOF'
profile rot2 10.199.80.0/24
    rule allow-host rr.example.test:2222
    rule allow-host sh.example.test:2222
EOF
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rr.example.test=192.0.2.50,sh.example.test=192.0.2.50" \
    egresslock ensure rot2 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.80.5 dst=192.0.2.50 sport=58666 dport=2222 src=192.0.2.50 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=10.199.80.6 dst=192.0.2.51 sport=58667 dport=2222 src=192.0.2.51 dst=10.0.2.15 sport=2222 dport=58667 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rr.example.test=192.0.2.51,sh.example.test=192.0.2.50" \
    egresslock ensure rot2 >/dev/null 2>&1
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rr.example.test=192.0.2.51,sh.example.test=192.0.2.50" \
    egresslock disallow-host rot2 rr.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]] \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.80.6 --sport 58667 -d 192.0.2.51 --dport 2222' "$CTLOG" \
   && ! grep -qE 'conntrack -D .*-d 192\.0\.2\.50 ' "$CTLOG" \
   && grep -qF 'dst=192.0.2.50 ' "$CTTABLE" \
   && ! grep -qF 'dst=192.0.2.51 ' "$CTTABLE"; then
    a139 pass
else
    a139 fail "shared historical address preserved (rc=$d_rc, log: $(tr '\n' '|' < "$CTLOG"), table: $(tr '\n' '|' < "$CTTABLE"))"
fi

# EGL-313: the cross-profile delete-scope battery (R-EGL-306-3 F3).
# Fixture `xg` 10.199.96.0/24 with one name pin (xg.example.test:2222 ->
# 192.0.2.60) and a gateway line (gateway 10.199.96.2 3128 xg-allowlist) so
# the gateway-source class is real. Four rows to the same 192.0.2.60:2222:
# (1) revoked rule's own workload flow (10.199.96.5, deleted), (2) gateway
# source (10.199.96.2, excluded in-subnet — no accepted gateway-leg side
# effect), (3) independently authorized profile-B source (10.199.81.5), and
# (4) foreign source (169.254.2.5) — both preserved. The old daddr+dport
# delete removed every source for the destination.
cat > "$EH/xg.conf" <<'EOF'
profile xg 10.199.96.0/24
    rule allow-host xg.example.test:2222
    gateway 10.199.96.2 3128 xg-allowlist
EOF
: > "$EH/xg-allowlist"
xg_ensure_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/xg.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="xg.example.test=192.0.2.60" \
    egresslock ensure xg 2>&1)"; xg_ensure_rc=$?
[[ "$xg_ensure_rc" == 0 ]] \
    && a139 pass || a139 fail "e313 setup: ensure xg must be green (rc=$xg_ensure_rc, out: $(echo "$xg_ensure_out" | head -3 | tr '\n' '|'))"
XG_ROWS='ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.96.5 dst=192.0.2.60 sport=58666 dport=2222 src=192.0.2.60 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=10.199.96.2 dst=192.0.2.60 sport=58667 dport=2222 src=192.0.2.60 dst=10.0.2.15 sport=2222 dport=58667 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=10.199.81.5 dst=192.0.2.60 sport=58668 dport=2222 src=192.0.2.60 dst=10.0.2.15 sport=2222 dport=58668 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=169.254.2.5 dst=192.0.2.60 sport=58669 dport=2222 src=192.0.2.60 dst=10.0.2.15 sport=2222 dport=58669 [ASSURED] mark=0 zone=0 use=2\n'
# e313-a (member leg): revoke; exactly one exact-tuple delete runs (the
#     workload row) — never a broad daddr+dport -D; the enumerate and
#     the witness share the argv and run once each before/after it.
printf "${XG_ROWS}" > "$CTTABLE"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/xg.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="xg.example.test=192.0.2.60" \
    egresslock disallow-host xg xg.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]] \
   && [[ "$(grep -cxF 'conntrack -L -p tcp --dport 2222 -d 192.0.2.60' "$CTLOG")" == 2 ]] \
   && [[ "$(grep -cxF 'conntrack -D -p tcp -s 10.199.96.5 --sport 58666 -d 192.0.2.60 --dport 2222' "$CTLOG")" == 1 ]] \
   && ! grep -qF 'conntrack -D -p tcp --dport 2222 -d 192.0.2.60' "$CTLOG" \
   && ! grep -qE 'conntrack -D .*-s 10\.199\.94\.2 ' "$CTLOG" \
   && ! grep -qE 'conntrack -D .*-s 10\.199\.81\.5 ' "$CTLOG" \
   && ! grep -qE 'conntrack -D .*-s 169\.254\.2\.5 ' "$CTLOG"; then
    a139 pass
else
    a139 fail "e313-a cross-profile delete scoped to the profile's own row (rc=$d_rc, out: $(echo "$d_out" | tail -2 | tr '\n' '|'), log: $(tr '\n' '|' < "$CTLOG"))"
fi
if grep -qF 'src=10.199.96.2 ' "$CTTABLE" && grep -qF 'src=10.199.81.5 ' "$CTTABLE" \
   && grep -qF 'src=169.254.2.5 ' "$CTTABLE" \
   && ! grep -qF 'src=10.199.96.5 ' "$CTTABLE"; then
    a139 pass
else
    a139 fail "e313-a rows: workload row deleted; gateway/profile-B/foreign preserved (table: $(tr '\n' '|' < "$CTTABLE"))"
fi
# e313-b (reconcile leg): rotate the pin (192.0.2.60 -> 192.0.2.61 via
#     the mock-DNS refresh, the e295-a idiom), reseed the four rows
#     against the EARLIER address 192.0.2.60, revoke; the reconcile's
#     flush uses the same scope — only the workload row goes.
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/xg.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="xg.example.test=192.0.2.60" \
    egresslock allow-host xg xg.example.test:2222 >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/xg.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="xg.example.test=192.0.2.60" \
    egresslock ensure xg >/dev/null 2>&1
printf "${XG_ROWS}" > "$CTTABLE"
: > "$CTLOG"
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/xg.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="xg.example.test=192.0.2.61" \
    egresslock ensure xg >/dev/null 2>&1
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/xg.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="xg.example.test=192.0.2.61" \
    egresslock disallow-host xg xg.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]] \
   && [[ "$(grep -cxF 'conntrack -L -p tcp --dport 2222 -d 192.0.2.60' "$CTLOG")" == 2 ]] \
   && [[ "$(grep -cxF 'conntrack -D -p tcp -s 10.199.96.5 --sport 58666 -d 192.0.2.60 --dport 2222' "$CTLOG")" == 1 ]] \
   && ! grep -qF 'conntrack -D -p tcp --dport 2222 -d 192.0.2.60' "$CTLOG" \
   && ! grep -qE 'conntrack -D .*-s 10\.199\.94\.2 ' "$CTLOG" \
   && ! grep -qE 'conntrack -D .*-s 10\.199\.81\.5 ' "$CTLOG" \
   && ! grep -qE 'conntrack -D .*-s 169\.254\.2\.5 ' "$CTLOG"; then
    a139 pass
else
    a139 fail "e313-b rotated-pin reconcile delete scoped (rc=$d_rc, out: $(echo "$d_out" | tail -2 | tr '\n' '|'), log: $(tr '\n' '|' < "$CTLOG"))"
fi
if grep -qF 'src=10.199.96.2 ' "$CTTABLE" && grep -qF 'src=10.199.81.5 ' "$CTTABLE" \
   && grep -qF 'src=169.254.2.5 ' "$CTTABLE" \
   && ! grep -qF 'src=10.199.96.5 ' "$CTTABLE"; then
    a139 pass
else
    a139 fail "e313-b rows: workload row deleted; gateway/profile-B/foreign preserved (table: $(tr '\n' '|' < "$CTTABLE"))"
fi
ARCMOCK_PASSWD_HOME="$(conf_home "$EH/xg.conf")" egresslock teardown xg >/dev/null 2>&1 || true
: > "$CTTABLE"

# e313-c: the flush recheck (witness) read fails -> die named AT the read,
#     rc 1, no `removed:`, conf line gone (EGL-313 (c): an unreturnable
#     view proves nothing, so the read's rc gate is mandatory). The
#     phase-selective marker fails ONLY the second -d/--dport-shaped -L
#     read; conntrack-delete-fails keeps the row real. Mutation pin: drop
#     the witness rc gate -> this leg goes red while the already-flushed
#     pin_ips skip rides a green `removed:`.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.60.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
rm -f "$ARCMOCK_STATE/nft/conntrack-flush-reads"
touch "$ARCMOCK_STATE/nft/conntrack-delete-fails" "$ARCMOCK_STATE/nft/conntrack-flush-recheck-fails"
d_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host two git.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-delete-fails" "$ARCMOCK_STATE/nft/conntrack-flush-recheck-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"cannot read the rootless netns conntrack table (rc=1)"* \
      && "$d_out" == *"$TESTROOT/bin/conntrack -L -p tcp --dport 2222 -d 192.0.2.10"* \
      && "$d_out" != *"fresh packets now drop and the entry drains"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && ! grep -q 'rule allow-host git.example.test:2222' "$EH/two.conf" \
   && grep -qF 'src=10.199.60.5 ' "$CTTABLE"; then
    a139 pass
else
    a139 fail "e313-c flush recheck (witness) read failure dies at the read (rc=$d_rc, out: $(echo "$d_out" | tail -2 | tr '\n' '|'))"
fi
: > "$CTTABLE"

# EGL-296: the live_pin_daddr full-agreement refusal gate. Fixtures
# `gate.conf` + `gate2.conf` (G4's `never` has never.conf; default mock DNS
# "git.example.test=192.0.2.10,gitXexample.test=192.0.2.12,cache.example.test=192.0.2.11";
# chain tampering edits $STATE/nft/egresslock.p_<profile> as leg 3 does).
# Subnets 66-68 avoid the live EGL-295 `rot` network. G8's both-drifted
# corner uses $EH/gate8.conf (gate3, 10.199.69.0/24, three entries —
# R-EGL-296-2 F2).
cat > "$EH/gate.conf" <<'EOF'
profile gate 10.199.66.0/24
    rule allow-host git.example.test:2222
    rule allow-host cache.example.test:8080
EOF
cat > "$EH/gate2.conf" <<'EOF'
profile gate2 10.199.67.0/24
    rule allow-host git.example.test:9999
    rule allow-host cache.example.test:9999
EOF
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure gate >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure gate2 >/dev/null 2>&1

# 25. G1 — b1 count mismatch (the deleted-pin-rule shape): refuse named
#     S2 BEFORE the conf mutation; nothing changed, no flush.
sed -i '/ip daddr 192.0.2.10 tcp dport 2222/d' "$STATE/nft/egresslock.p_gate"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host gate git.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow-host: the installed allow-host rules for profile 'gate' no longer match its pin record — expected 2, found 1 (allow-host rule count mismatch); nothing was changed; re-run: egresslock ensure gate, then retry: egresslock disallow-host gate git.example.test:2222"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -q 'rule allow-host git.example.test:2222' "$EH/gate.conf" \
   && [[ "$(grep -c conntrack "$CTLOG")" == 1 ]] && grep -qxF 'conntrack -C' "$CTLOG"; then
    a139 pass
else
    a139 fail "G1 count-mismatch refusal, nothing changed (rc=$d_rc, out: $(echo "$d_out" | head -1), log: $(tr '\n' '|' < "$CTLOG"))"
fi
# 26. G2 — b2 cross-port reorder: positional zip refuses S3, no flush.
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure gate >/dev/null 2>&1
awk '
  /ip daddr 192.0.2.10 tcp dport 2222/ { gitline=$0; next }
  /ip daddr 192.0.2.11 tcp dport 8080/ { print; print gitline; next }
  { print }' "$STATE/nft/egresslock.p_gate" > "$STATE/nft/egresslock.p_gate.tmp" \
    && mv "$STATE/nft/egresslock.p_gate.tmp" "$STATE/nft/egresslock.p_gate"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host gate git.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow-host: the installed allow-host rules for profile 'gate' are in a different order than the config — config expects git.example.test:2222, the installed rule has port 8080 (allow-host port order mismatch)"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -q 'rule allow-host git.example.test:2222' "$EH/gate.conf" \
   && ! grep -qF 'conntrack -D' "$CTLOG" && ! grep -qF 'conntrack -L' "$CTLOG"; then
    a139 pass
else
    a139 fail "G2 cross-port reorder refusal, nothing changed (rc=$d_rc, out: $(echo "$d_out" | head -1), log: $(tr '\n' '|' < "$CTLOG"))"
fi
# 27. G3 — b2 same-port reorder (the live X20b shape): refuse S4.
awk '
  /ip daddr 192.0.2.10 tcp dport 9999/ { gline=$0; next }
  /ip daddr 192.0.2.11 tcp dport 9999/ { print; print gline; next }
  { print }' "$STATE/nft/egresslock.p_gate2" > "$STATE/nft/egresslock.p_gate2.tmp" \
    && mv "$STATE/nft/egresslock.p_gate2.tmp" "$STATE/nft/egresslock.p_gate2"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host gate2 git.example.test:9999 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow-host: a pinned address for git.example.test:9999 no longer matches the installed rule in profile 'gate2' — pin record: 192.0.2.10, installed rule: 192.0.2.11 (allow-host pin daddr mismatch)"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -q 'rule allow-host git.example.test:9999' "$EH/gate2.conf" \
   && ! grep -qF 'conntrack -D' "$CTLOG" && ! grep -qF 'conntrack -L' "$CTLOG"; then
    a139 pass
else
    a139 fail "G3 same-port reorder refusal, nothing changed (rc=$d_rc, out: $(echo "$d_out" | head -1), log: $(tr '\n' '|' < "$CTLOG"))"
fi
# 28. G4 — chain absent (never ensured): refuse S1, conf line stays.
cat > "$EH/never.conf" <<'EOF'
profile never 10.199.68.0/24
    rule allow-host git.example.test:2222
EOF
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/never.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host never git.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow-host: profile 'never' has no installed firewall rules, or they cannot be read — nothing was changed; re-run: egresslock ensure never, then retry: egresslock disallow-host never git.example.test:2222"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -q 'rule allow-host git.example.test:2222' "$EH/never.conf" \
   && ! grep -qF 'conntrack -D' "$CTLOG" && ! grep -qF 'conntrack -L' "$CTLOG"; then
    a139 pass
else
    a139 fail "G4 chain-absent refusal, nothing changed (rc=$d_rc, out: $(echo "$d_out" | head -1), log: $(tr '\n' '|' < "$CTLOG"))"
fi
# 29. G5 — daddr tamper: refuse S4 with the tampered member.
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure gate2 >/dev/null 2>&1
sed -i 's/ip daddr 192.0.2.10 tcp dport 9999/ip daddr 192.0.2.77 tcp dport 9999/' \
    "$STATE/nft/egresslock.p_gate2"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host gate2 git.example.test:9999 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow-host: a pinned address for git.example.test:9999 no longer matches the installed rule in profile 'gate2' — pin record: 192.0.2.10, installed rule: 192.0.2.77 (allow-host pin daddr mismatch)"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -q 'rule allow-host git.example.test:9999' "$EH/gate2.conf"; then
    a139 pass
else
    a139 fail "G5 daddr-tamper refusal, nothing changed (rc=$d_rc, out: $(echo "$d_out" | head -1))"
fi
# 30. G6 — legal duplicate conf entry stays green (negative control):
#     record identical-lines collapse, count 4 == 4 accepts, full zip
#     passes, both members flushed (-D+-L), both conf lines gone,
#     record file removed.
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/dup.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="dup.example.test=192.0.2.30+192.0.2.31" \
    egresslock ensure dup >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.63.5 dst=192.0.2.30 sport=51001 dport=8443 src=192.0.2.30 dst=10.0.2.15 sport=8443 dport=51001 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=10.199.63.6 dst=192.0.2.31 sport=51002 dport=8443 src=192.0.2.31 dst=10.0.2.15 sport=8443 dport=51002 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/dup.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS="dup.example.test=192.0.2.30+192.0.2.31" egresslock disallow-host dup dup.example.test:8443 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]] \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.63.5 --sport 51001 -d 192.0.2.30 --dport 8443' "$CTLOG" \
   && grep -qxF 'conntrack -L -p tcp --dport 8443 -d 192.0.2.30' "$CTLOG" \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.63.6 --sport 51002 -d 192.0.2.31 --dport 8443' "$CTLOG" \
   && grep -qxF 'conntrack -L -p tcp --dport 8443 -d 192.0.2.31' "$CTLOG" \
   && [[ "$(grep -c 'rule allow-host dup.example.test:8443' "$EH/dup.conf")" == 0 ]] \
   && [[ ! -e "$EH/dup.pins" ]]; then
    a139 pass
else
    a139 fail "G6 legal duplicate stays green (rc=$d_rc, out: $(echo "$d_out" | head -1), log: $(tr '\n' '|' < "$CTLOG"))"
fi
: > "$CTTABLE"
# 31. G7 — healthy path unchanged: post-tamper heal via ensure, then the
#     disallow flushes the target member only; `removed:` last.
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure gate >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.66.5 dst=192.0.2.10 sport=52001 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=52001 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host gate git.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]] \
   && [[ "$(tail -1 <<<"$d_out")" == "removed: rule allow-host git.example.test:2222"* ]] \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.66.5 --sport 52001 -d 192.0.2.10 --dport 2222' "$CTLOG" \
   && grep -qxF 'conntrack -L -p tcp --dport 2222 -d 192.0.2.10' "$CTLOG" \
   && ! grep -qF -- '-d 192.0.2.11' "$CTLOG"; then
    a139 pass
else
    a139 fail "G7 healthy path unchanged (rc=$d_rc, out: $(echo "$d_out" | head -1), log: $(tr '\n' '|' < "$CTLOG"))"
fi
: > "$CTTABLE"
# 32. G8 — the zip's missing-key die (both-drifted corner, R-EGL-296-2
#     F2): a record key missing for a conf entry AFTER the target while
#     the chain is short in step with the record — the count check
#     passes (2==2), so only the full-agreement zip's D9 die (the
#     "no entry for" branch inside the zip) can refuse; nothing changed.
cat > "$EH/gate3.conf" <<'EOF'
profile gate3 10.199.69.0/24
    rule allow-host git.example.test:2222
    rule allow-host cache.example.test:8080
    rule allow-host gitXexample.test:3333
EOF
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate3.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure gate3 >/dev/null 2>&1
sed -i '/ip daddr 192.0.2.12 tcp dport 3333/d' "$STATE/nft/egresslock.p_gate3"
sed -i '/^gitXexample.test|3333 /d' "$EH/gate3.pins"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate3.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host gate3 git.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow-host: pin record unreadable for profile 'gate3' (no entry for gitXexample.test:3333) — re-run: egresslock ensure gate3"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -q 'rule allow-host gitXexample.test:3333' "$EH/gate3.conf" \
   && ! grep -qF 'conntrack -D' "$CTLOG" && ! grep -qF 'conntrack -L' "$CTLOG"; then
    a139 pass
else
    a139 fail "G8 zip missing-key refusal, nothing changed (rc=$d_rc, out: $(echo "$d_out" | head -1), log: $(tr '\n' '|' < "$CTLOG"))"
fi

# 33. G9 — matching-output failed read (behavior-change pin): rc 1 + S1
#     rendered for gate2, conf/chain/record byte-identical, no flush,
#     marker consumed. (Pre-fix: rc 0 + removed:.)
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure gate2 >/dev/null 2>&1
cp "$STATE/nft/egresslock.p_gate2" "$STATE/g9-chain"
cp "$EH/gate2.pins" "$STATE/g9-pins"
: > "$STATE/nft/fail-list-chain-output-rc1"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host gate2 git.example.test:9999 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"Error: disallow-host: profile 'gate2' has no installed firewall rules, or they cannot be read — nothing was changed; re-run: egresslock ensure gate2, then retry: egresslock disallow-host gate2 git.example.test:9999"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -q 'rule allow-host git.example.test:9999' "$EH/gate2.conf" \
   && cmp -s "$STATE/nft/egresslock.p_gate2" "$STATE/g9-chain" \
   && cmp -s "$EH/gate2.pins" "$STATE/g9-pins" \
   && [[ "$(grep -c conntrack "$CTLOG")" == 1 ]] && grep -qxF 'conntrack -C' "$CTLOG" \
   && [[ ! -f "$STATE/nft/fail-list-chain-output-rc1" ]]; then
    a139 pass
else
    a139 fail "G9 matching-output failed read refuses S1 (rc=$d_rc, out: $(echo "$d_out" | head -1), log: $(tr '\n' '|' < "$CTLOG"))"
fi
# 34. G10 — partial-output failed read: same asserts, S1 (pre-fix: S2 —
#     right refusal, wrong cause).
: > "$STATE/nft/fail-list-chain-partial-rc1"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host gate2 git.example.test:9999 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"Error: disallow-host: profile 'gate2' has no installed firewall rules, or they cannot be read"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -q 'rule allow-host git.example.test:9999' "$EH/gate2.conf" \
   && cmp -s "$STATE/nft/egresslock.p_gate2" "$STATE/g9-chain" \
   && cmp -s "$EH/gate2.pins" "$STATE/g9-pins" \
   && [[ "$(grep -c conntrack "$CTLOG")" == 1 ]] && grep -qxF 'conntrack -C' "$CTLOG" \
   && [[ ! -f "$STATE/nft/fail-list-chain-partial-rc1" ]]; then
    a139 pass
else
    a139 fail "G10 partial-output failed read refuses S1 (rc=$d_rc, out: $(echo "$d_out" | head -1))"
fi
# 35. G11 — empty-output failed read (netns-nft-fails): S1 both pre/post;
#     remove the marker in the leg so later legs' nft runs stay clean.
: > "$STATE/netns-nft-fails"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host gate2 git.example.test:9999 2>&1)"; d_rc=$?
rm -f "$STATE/netns-nft-fails"
if [[ "$d_rc" == 1 \
      && "$d_out" == *"Error: disallow-host: profile 'gate2' has no installed firewall rules, or they cannot be read"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && grep -q 'rule allow-host git.example.test:9999' "$EH/gate2.conf" \
   && cmp -s "$STATE/nft/egresslock.p_gate2" "$STATE/g9-chain" \
   && cmp -s "$EH/gate2.pins" "$STATE/g9-pins" \
   && [[ "$(grep -c conntrack "$CTLOG")" == 1 ]] && grep -qxF 'conntrack -C' "$CTLOG"; then
    a139 pass
else
    a139 fail "G11 empty failed read refuses S1 (rc=$d_rc, out: $(echo "$d_out" | head -1))"
fi
# 36. G12 — healthy + target NXDOMAIN control: rc 0, exactly one
#     removed:, scoped -D+-L, conf line gone, record key gone.
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.67.5 dst=192.0.2.10 sport=53001 dport=9999 src=192.0.2.10 dst=10.0.2.15 sport=9999 dport=53001 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='git.example.test=' egresslock disallow-host gate2 git.example.test:9999 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c 'removed:' <<<"$d_out")" == 1 ]] \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.67.5 --sport 53001 -d 192.0.2.10 --dport 9999' "$CTLOG" \
   && grep -qxF 'conntrack -L -p tcp --dport 9999 -d 192.0.2.10' "$CTLOG" \
   && [[ "$(grep -c 'rule allow-host git.example.test:9999' "$EH/gate2.conf")" == 0 ]] \
   && ! grep -q '^git.example.test|9999 ' "$EH/gate2.pins"; then
    a139 pass
else
    a139 fail "G12 healthy + NXDOMAIN target revokes (rc=$d_rc, out: $(echo "$d_out" | head -1), log: $(tr '\n' '|' < "$CTLOG"))"
fi
# 37. G13 — drift + NXDOMAIN deadlock: disallow S2; ensure cannot
#     resolve + hint; retry S2; nothing changed; exactly two probes.
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host gate2 git.example.test:9999 >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure gate2 >/dev/null 2>&1
sed -i '/ip daddr 192.0.2.10 tcp dport 9999/d' "$STATE/nft/egresslock.p_gate2"
# Snapshots are the POST-tamper refusal-start state: the cmp below proves
# the deadlocked window (S2 refusal + the cannot-resolve ensure + the
# retry refusal) changed nothing beyond the deliberate drift tamper.
cp "$EH/gate2.conf" "$STATE/g13-conf"
cp "$STATE/nft/egresslock.p_gate2" "$STATE/g13-chain"
cp "$EH/gate2.pins" "$STATE/g13-pins"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='git.example.test=' egresslock disallow-host gate2 git.example.test:9999 2>&1)"; d_rc=$?
e_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='git.example.test=' egresslock ensure gate2 2>&1)"; e_rc=$?
d2_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='git.example.test=' egresslock disallow-host gate2 git.example.test:9999 2>&1)"; d2_rc=$?
if [[ "$d_rc" == 1 && "$d_out" == *"(allow-host rule count mismatch)"* ]] \
   && [[ "$d_out" == *"expected 2, found 1"* ]] \
   && [[ "$e_rc" == 1 && "$e_out" == *"Error: cannot resolve git.example.test"* ]] \
   && [[ "$(grep -c '^hint:' <<<"$e_out")" == 3 ]] \
   && [[ "$e_out" == *"remove it with: disallow-host gate2 git.example.test:9999"* ]] \
   && [[ "$d2_rc" == 1 && "$d2_out" == *"(allow-host rule count mismatch)"* ]] \
   && cmp -s "$EH/gate2.conf" "$STATE/g13-conf" \
   && cmp -s "$STATE/nft/egresslock.p_gate2" "$STATE/g13-chain" \
   && cmp -s "$EH/gate2.pins" "$STATE/g13-pins" \
   && [[ "$(grep -c conntrack "$CTLOG")" == 2 ]] \
   && grep -qxF 'conntrack -C' "$CTLOG" && ! grep -qF 'conntrack -D' "$CTLOG" && ! grep -qF 'conntrack -L' "$CTLOG" \
   && ! grep -q 'removed:' <<<"$d_out$d2_out"; then
    a139 pass
else
    a139 fail "G13 drift + NXDOMAIN deadlock (dis rc=$d_rc, ensure rc=$e_rc, retry rc=$d2_rc, log: $(tr '\n' '|' < "$CTLOG"))"
fi
# 38. G14 — removal heals in the mock: delete the conf line by hand,
#     ensure under the override resolves the sibling only; verify green;
#     record + chain lack the target.
sed -i '/rule allow-host git.example.test:9999/d' "$EH/gate2.conf"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='git.example.test=' egresslock ensure gate2 2>&1)"; d_rc=$?
d2_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='git.example.test=' egresslock verify gate2 2>&1)"; d2_rc=$?
if [[ "$d_rc" == 0 && "$d2_rc" == 0 ]] \
   && ! grep -q 'ip daddr 192.0.2.10 tcp dport 9999' "$STATE/nft/egresslock.p_gate2" \
   && ! grep -q '^git.example.test|9999 ' "$EH/gate2.pins" \
   && grep -q 'rule allow-host cache.example.test:9999' "$EH/gate2.conf"; then
    a139 pass
else
    a139 fail "G14 removal heals (ensure rc=$d_rc, verify rc=$d2_rc, out: $(echo "$d_out" | head -1))"
fi
: > "$CTTABLE"

# EGL-307: the member-leg accepted-set guard. Two allow-host rules pin
# the SAME address:port (legal shape, EGL-219 §4); revoking one must NOT
# sever the shared flows the sibling still authorizes — the post-swap
# chain's accepted set is the survivor test on both legs. Fixture `shr`
# (subnet 10.199.65.0/24 — free at this pass, re-checked via the pool
# grep), aa.example.test:2222 + bb.example.test:2222 both mock-resolved
# to 192.0.2.70.
reset307() {
    cat > "$EH/shr.conf" <<'EOF'
profile shr 10.199.65.0/24
    rule allow-host aa.example.test:2222
    rule allow-host bb.example.test:2222
EOF
    rm -f "$STATE/nft/fail-list-chain-read-n" \
          "$STATE/nft/fail-list-chain-after-flush" \
          "$STATE/nft/f-list-reads"
    env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/shr.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        EGRESSLOCK_MOCK_DNS="aa.example.test=192.0.2.70,bb.example.test=192.0.2.70" \
        egresslock ensure shr >/dev/null 2>&1
    # The ordinal counter resets on every -f, so the ensure above leaves
    # its post-swap tail reads (5) in $STATE/nft/f-list-reads. Zero it:
    # the next command's PRE-swap read (live_pin_daddr, before its own
    # -f) would otherwise land on the pin's ordinal and fire the seam at
    # the pre-mutation gate instead of the guard (observed: N=6 fired in
    # live_pin_daddr -> the "nothing was changed" die).
    : > "$STATE/nft/f-list-reads"
    printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.65.5 dst=192.0.2.70 sport=58666 dport=2222 src=192.0.2.70 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\n' \
        > "$CTTABLE"
    : > "$CTLOG"
}

# e307-a: shared member preserved — the sibling still authorizes the
# address:port, so the member flush is skipped entirely (no -D at all)
# and the reconcile's accepted-skip keeps the row; rc 0 + one removed:.
reset307
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/shr.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="aa.example.test=192.0.2.70,bb.example.test=192.0.2.70" \
    egresslock disallow-host shr aa.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c '^removed:' <<<"$d_out")" == 1 ]] \
   && ! grep -q 'conntrack -D' "$CTLOG" \
   && grep -qF 'dst=192.0.2.70 ' "$CTTABLE" \
   && ! grep -q 'rule allow-host aa.example.test:2222' "$EH/shr.conf" \
   && grep -q 'rule allow-host bb.example.test:2222' "$EH/shr.conf" \
   && grep -q 'ip daddr 192.0.2.70 tcp dport 2222 counter accept' "$STATE/nft/egresslock.p_shr"; then
    a139 pass
else
    a139 fail "e307-a shared member preserved, no -D (rc=$d_rc, log: $(tr '\n' '|' < "$CTLOG"), out: $(echo "$d_out" | tail -1))"
fi
# Ordinal observation (the e307-c/d seam's pin): a healthy revocation's
# post-(-f) chain reads are write_pin_record -> profile_stale_unpolicied
# (verify preflight) -> verify_v6deny_chain -> verify_profile_chain ->
# verify_expected_rules -> guard -> reconcile = 7 (host-measured; the
# design's pre-observation "N=4" list omitted write_pin_record's own
# position and the stale-window read — the coder re-pins by observation).
[[ "$(cat "$STATE/nft/f-list-reads" 2>/dev/null)" == 7 ]] \
    && a139 pass || a139 fail "e307-a ordinal counter (got: $(cat "$STATE/nft/f-list-reads" 2>/dev/null))"

# e307-b: severance resumes when the last grant goes — revoking the
# sibling flushes the shared row (-D naming -d 192.0.2.70, the
# land-order-safe match) and the row is gone; rc 0 + one removed:.
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/shr.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="aa.example.test=192.0.2.70,bb.example.test=192.0.2.70" \
    egresslock disallow-host shr bb.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c '^removed:' <<<"$d_out")" == 1 ]] \
   && grep -qE 'conntrack -D .*-d 192\.0\.2\.70 ' "$CTLOG" \
   && ! grep -qF 'dst=192.0.2.70 ' "$CTTABLE"; then
    a139 pass
else
    a139 fail "e307-b last-grant severance (rc=$d_rc, log: $(tr '\n' '|' < "$CTLOG"), table: $(tr '\n' '|' < "$CTTABLE"))"
fi

# EGL-354: the post-swap S3 disclosure for the `shr` fixture. Exact full
# line, occurrence-count checked (the S3_305 pin shape); `e307-c` pins
# its absence on the reconcile-success control, `e307-d` requires it once
# on the reconcile-failure regression.
S3_307="disallow-host: the revocation is only half done — the rule is out of the firewall, but the connections that were open were not ended — state: conf line removed, ruleset swapped, conntrack not proven clean; next action: end the leftover connections: egresslock drop-unauthorized shr 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"

# e307-c: unusable guard read severs on doubt — the ordinal seam fails
# the guard's read (N=6, the observed ordinal above) once; every member
# is flushed (the shared row is gone) and the reconcile's own read
# succeeds -> rc 0 + removed: and NO S3 disclosure (the trap/context are
# cleared only after the reconcile proves — EGL-354).
reset307
printf '6\n' > "$STATE/nft/fail-list-chain-read-n"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/shr.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="aa.example.test=192.0.2.70,bb.example.test=192.0.2.70" \
    egresslock disallow-host shr aa.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 0 && "$(grep -c '^removed:' <<<"$d_out")" == 1 ]] \
   && grep -qE 'conntrack -D .*-d 192\.0\.2\.70 ' "$CTLOG" \
   && ! grep -qF 'dst=192.0.2.70 ' "$CTTABLE" \
   && [[ ! -e "$STATE/nft/fail-list-chain-read-n" ]] \
   && ! grep -q 'cannot read the firewall rules\|came back empty, incomplete, or unusable' <<<"$d_out" \
   && ! grep -qF 'disallow-host:' <<<"$d_out"; then
    a139 pass
else
    a139 fail "e307-c doubt severs, reconcile read survived (rc=$d_rc, log: $(tr '\n' '|' < "$CTLOG"), out: $(echo "$d_out" | tail -1))"
fi

# e307-d: unusable guard read + failed reconcile read — the ordinal seam
# fails the guard's read, the member is flushed, and the reconcile's own
# read then dies S1 named (the EGL-311 contract, re-anchored); rc 1, no
# removed:, and the S3 drop-unauthorized disclosure exactly once (the
# trap stays armed through the reconcile — EGL-354).
reset307
: > "$STATE/nft/fail-list-chain-after-flush"
printf '6\n' > "$STATE/nft/fail-list-chain-read-n"
S1_307="Error: cannot read the firewall rules for profile 'shr' after the rule was removed (rc=1): Error: mock nft: netlink read of chain 'p_shr' failed once (fail-list-chain-after-flush); state: conf line removed, ruleset swapped, conntrack unproven; next action: the rule is already out and the firewall already replaced, but any connection left on port 2222 cannot be checked against the removed rule while the rules are unreadable — inspect what is left: podman unshare --rootless-netns $TESTROOT/bin/nft list chain inet egresslock p_shr; podman unshare --rootless-netns $TESTROOT/bin/conntrack -L -p tcp --dport 2222; then delete a leftover by hand: podman unshare --rootless-netns $TESTROOT/bin/conntrack -D -p tcp --dport 2222 -d <destination>"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/shr.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="aa.example.test=192.0.2.70,bb.example.test=192.0.2.70" \
    egresslock disallow-host shr aa.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 && "$(grep -qxF "$S1_307" <<<"$d_out"; echo $?)" == 0 ]] \
   && [[ "$(grep -cxF "$S3_307" <<<"$d_out")" == 1 ]] \
   && grep -qE 'conntrack -D .*-d 192\.0\.2\.70 ' "$CTLOG" \
   && ! grep -qF 'dst=192.0.2.70 ' "$CTTABLE" \
   && [[ ! -e "$STATE/nft/fail-list-chain-after-flush" ]] \
   && ! grep -q 'removed:' <<<"$d_out"; then
    a139 pass
else
    a139 fail "e307-d guard severed, reconcile died S1 named + S3 disclosure (rc=$d_rc, out: $(echo "$d_out" | tail -2))"
fi
rm -f "$STATE/nft/fail-list-chain-read-n" \
      "$STATE/nft/fail-list-chain-after-flush" \
      "$STATE/nft/f-list-reads"
: > "$CTTABLE"

# EGL-219-D12/D9 (R4): record-input legs — the reworked reader's causes
# are named, rc 1, and pre-mutation. Fixture: the e295 `rot` profile
# (two single-member entries, so a missing record line can be the
# target's or its predecessor's). Re-ensure before each leg — the
# record is the mutation target and `ensure` is the supported restore.
reset_rot219() {
    cat > "$EH/rot.conf" <<'EOF'
profile rot 10.199.64.0/24
    rule allow-host rot.example.test:2222
    rule allow-host keep.example.test:2222
EOF
    env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.20,keep.example.test=192.0.2.30" \
        egresslock ensure rot >/dev/null 2>&1
}
d9_disallow() { # d9_disallow <host:port> — fills d9_out/d9_rc
    d9_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.20,keep.example.test=192.0.2.30" \
        egresslock disallow-host rot "$1" 2>&1)"; d9_rc=$?
}
d9_expect() { # d9_expect <desc> <cause-substr>
    if [[ "$d9_rc" == 1 && "$d9_out" == *"disallow-host: pin record unreadable for profile 'rot'"*"$2"* ]] \
       && ! grep -q 'removed:' <<<"$d9_out" \
       && ! grep -qE 'conntrack -D ' "$CTLOG" \
       && grep -q 'rule allow-host rot.example.test:2222' "$EH/rot.conf" \
       && grep -q 'rule allow-host keep.example.test:2222' "$EH/rot.conf"; then
        a139 pass
    else
        a139 fail "$1 (rc=$d9_rc, out: $(echo "$d9_out" | tail -1))"
    fi
}
reset_rot219
# a. permission-denied read: mapfile's own status is the read proof.
chmod 000 "$EH/rot.pins"
: > "$CTLOG"
d9_disallow rot.example.test:2222
chmod 644 "$EH/rot.pins"
d9_expect "d9-read chmod-000: named cannot-read rc 1, nothing changed" "cannot read "
reset_rot219
# b. empty record: coverage names the missing key (not a count shape).
: > "$EH/rot.pins"
: > "$CTLOG"
d9_disallow rot.example.test:2222
d9_expect "d9-read empty record: named no-entry rc 1, nothing changed" "no entry for rot.example.test:2222"
reset_rot219
# c. missing TARGET line (target is the second conf entry).
printf 'rot.example.test|2222 192.0.2.20\n' > "$EH/rot.pins"
: > "$CTLOG"
d9_disallow keep.example.test:2222
d9_expect "d9-read missing target line: named no-entry rc 1, nothing changed" "no entry for keep.example.test:2222"
reset_rot219
# d. missing PREDECESSOR line (first conf entry; target is the second).
printf 'keep.example.test|2222 192.0.2.30\n' > "$EH/rot.pins"
: > "$CTLOG"
d9_disallow keep.example.test:2222
d9_expect "d9-read missing predecessor line: named no-entry rc 1, nothing changed" "no entry for rot.example.test:2222"
reset_rot219

# EGL-219-D12/D9 (R4): same-size repeated-token line. A multi-member entry
# is required. Fixture `fail` 10.199.105.0/24 (design's 66-subnet collides
# with live `gate`; PROC-065). `duo` is a two-address name: the corrupted
# line keeps the 2-token size so Σ-size still matches and only the
# repeated-token check refuses.
cat > "$EH/fail.conf" <<'EOF'
profile fail 10.199.105.0/24
    rule allow-host duo.example.test:443
    rule allow-host keep.example.test:443
EOF
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/fail.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="duo.example.test=192.0.2.20+192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock ensure fail >/dev/null 2>&1
printf 'duo.example.test|443 192.0.2.20 192.0.2.20\nkeep.example.test|443 192.0.2.30\n' > "$EH/fail.pins"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/fail.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="duo.example.test=192.0.2.20+192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock disallow-host fail duo.example.test:443 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow-host: pin record unreadable for profile 'fail' (repeated address in line: 'duo.example.test|443 192.0.2.20 192.0.2.20') — re-run: egresslock ensure fail"* ]] \
   && ! grep -q 'removed:' <<<"$d_out" \
   && ! grep -qE 'conntrack -D ' "$CTLOG" \
   && grep -q 'rule allow-host duo.example.test:443' "$EH/fail.conf"; then
    a139 pass
else
    a139 fail "d9-read repeated-token line: named rc 1, nothing changed (rc=$d_rc, out: $(echo "$d_out" | head -1))"
fi
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/fail.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="duo.example.test=192.0.2.20+192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock ensure fail >/dev/null 2>&1

# EGL-219-D10/D11/D14 (R4) / EGL-317: first-member failure, deterministic.
# The marker fails the flush helper's enumerate read (`-L … -d
# 192.0.2.20` — EGL-313's enumerate-before-delete), so no delete runs and
# the post-swap trap prints the new one-line S3 (drop-unauthorized fail
# 443); `.30` is another grant's address and never appears. `removed:`
# stays unprinted. The S3-printed command run verbatim then severs both
# duo rows (.20/.21, the earlier and current members) and keeps `.30`.
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.105.5 dst=192.0.2.20 sport=59101 dport=443 src=192.0.2.20 dst=10.0.2.15 sport=443 dport=59101 [ASSURED] mark=0 zone=0 use=2\n' > "$CTTABLE"
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.105.6 dst=192.0.2.21 sport=59102 dport=443 src=192.0.2.21 dst=10.0.2.15 sport=443 dport=59102 [ASSURED] mark=0 zone=0 use=2\n' >> "$CTTABLE"
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.105.7 dst=192.0.2.30 sport=59103 dport=443 src=192.0.2.30 dst=10.0.2.15 sport=443 dport=59103 [ASSURED] mark=0 zone=0 use=2\n' >> "$CTTABLE"
: > "$CTLOG"
printf '192.0.2.20\n' > "$STATE/nft/conntrack-list-fail-daddr"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/fail.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="duo.example.test=192.0.2.20+192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock disallow-host fail duo.example.test:443 2>&1)"; d_rc=$?
S3_139D="disallow-host: the revocation is only half done — the rule is out of the firewall, but the connections that were open were not ended — state: conf line removed, ruleset swapped, conntrack not proven clean; next action: end the leftover connections: egresslock drop-unauthorized fail 443 (drops the connections on port 443 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"
if [[ "$d_rc" == 1 \
      && "$d_out" == *"cannot read the rootless netns conntrack table (rc=1): mock conntrack: netlink error: Operation failed; state: conf line removed, ruleset swapped, ct unproven; next action: podman unshare --rootless-netns $TESTROOT/bin/conntrack -L -p tcp --dport 443 -d 192.0.2.20"* ]] \
      && grep -qxF "$S3_139D" <<<"$d_out" \
      && ! grep -qF '192.0.2.30' <<<"$d_out" \
      && ! grep -q 'removed:' <<<"$d_out" \
      && ! grep -qE 'conntrack -D ' "$CTLOG" \
      && [[ ! -e "$STATE/nft/conntrack-list-fail-daddr" ]]; then
    a139 pass
else
    a139 fail "fail loop: first-member die + one-line S3 rc 1 (rc=$d_rc, out: $(echo "$d_out" | tr '\n' '|' | head -c 600))"
fi
if ! grep -q 'rule allow-host duo.example.test:443' "$EH/fail.conf" \
   && grep -q 'rule allow-host keep.example.test:443' "$EH/fail.conf" \
   && ! grep -q 'ip daddr 192.0.2.20 tcp dport 443 counter accept' "$STATE/nft/egresslock.p_fail" \
   && ! grep -q 'ip daddr 192.0.2.21 tcp dport 443 counter accept' "$STATE/nft/egresslock.p_fail" \
   && grep -q 'ip daddr 192.0.2.30 tcp dport 443 counter accept' "$STATE/nft/egresslock.p_fail" \
   && grep -qF 'dst=192.0.2.20 ' "$CTTABLE" \
   && grep -qF 'dst=192.0.2.21 ' "$CTTABLE" \
   && grep -qF 'dst=192.0.2.30 ' "$CTTABLE"; then
    a139 pass
else
    a139 fail "fail loop: duo conf/accepts gone, keep intact, all three rows remain (conf: $(tr '\n' '|' < "$EH/fail.conf" | head -c 240); table: $(tr '\n' '|' < "$CTTABLE" | head -c 360))"
fi
# The S3-printed recovery command run verbatim: both duo rows go (the
# earlier .20 member included), the keep row stays; exactly those -D
# tuples — no hand-typed per-member deletes.
cmd139="${d_out##*end the leftover connections: }"; cmd139="${cmd139%% (drops*}"
[[ "$cmd139" == "egresslock drop-unauthorized fail 443" ]] \
    && a139 pass || a139 fail "fail loop: printed command parsed verbatim ('$cmd139')"
: > "$CTLOG"
u139="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/fail.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 bash -c "$cmd139" 2>&1)"; u139_rc=$?
if [[ "$u139_rc" == 0 ]] \
   && grep -qxF "drop-unauthorized: no leftover connection on port 443 remains that profile 'fail' does not allow" <<<"$u139" \
   && ! grep -qF 'dst=192.0.2.20 ' "$CTTABLE" \
   && ! grep -qF 'dst=192.0.2.21 ' "$CTTABLE" \
   && grep -qF 'dst=192.0.2.30 ' "$CTTABLE" \
   && [[ "$(grep -c '^conntrack -D ' "$CTLOG")" == 2 ]] \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.105.5 --sport 59101 -d 192.0.2.20 --dport 443' "$CTLOG" \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.105.6 --sport 59102 -d 192.0.2.21 --dport 443' "$CTLOG"; then
    a139 pass
else
    a139 fail "fail loop: printed recovery severs both duo rows, keeps the keep row (rc=$u139_rc, out: $u139, table: $(tr '\n' '|' < "$CTTABLE" | head -c 360))"
fi
: > "$CTTABLE"

egl139_pass=$pass; egl139_fail=$fail
section_end egl139
# EGL-184-D2 / EGL-194-D5: egl140 stays a manual alias of egl139.
# Capture is inside the egl139 window (before section_end) so a
# later pass/fail reset cannot silently zero the witness.
egl140_pass=$egl139_pass; egl140_fail=$egl139_fail

# --- EGL-305: disallow-host partial-failure recovery -----------------------
# R-EGL-260-3 F1: the conf-delete -> severance-proof failure interval.
# State (i) L1/L2: cmd_ensure fails BEFORE the atomic -f (sibling host
# unresolvable via EGRESSLOCK_MOCK_DNS) — the trap restores the deleted
# rule at its original position (S1), or names S2 + S2w when the confdir
# is unwritable. State (ii) L3: the -f swap succeeds and the first
# post-swap chain read fails once — write_pin_record dies NAMED (S4) and
# the trap prints the exact scoped hand-finish (S3). L4: no disclosure
# outside a disallow-host window. L5: healthy path unchanged.
section_begin egl305 "EGL-305 disallow-host partial-failure recovery (state i restore/disclose + state ii disclose)"
a305() { assert "$@"; }

H305="$TESTROOT/h305"; rm -rf "$H305"; mkdir -p "$H305"
cat > "$H305/pristine.conf" <<'EOF'
profile t305 10.199.90.0/24
    rule allow-host git.example.test:2222
    rule allow-host cache.example.test:8080
EOF
cat > "$H305/p305.conf" <<'EOF'
profile p305 10.199.91.0/24
EOF
export ARCMOCK_PASSWD_HOME="$(conf_home "$H305/t305.conf")"
C305LOG="$ARCMOCK_STATE/conntrack.log"
A305CT="$STATE/nft/conntrack-table"
CHAIN305="$STATE/nft/egresslock.p_t305"
reset305() {
    cp "$H305/pristine.conf" "$H305/t305.conf"
    rm -f "$STATE/nft/fail-list-chain-after-f" "$STATE/nft/confdir-unwritable" "$STATE/nft/confdir-unwritable-seen" "$STATE/nft/f-done"
    env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure t305 >/dev/null 2>&1
    env EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$(conf_home "$H305/p305.conf")" egresslock ensure p305 >/dev/null 2>&1
    : > "$C305LOG"; : > "$A305CT"
}
S1_305='disallow-host: nothing was revoked — the reinstall failed before the policy was replaced and the rule was put back — state: rule restored, ruleset not replaced (the rule is back in the config; the revocation ended no connection) — next action: fix the underlying failure, then retry: egresslock disallow-host t305 git.example.test:2222'
S2_305='disallow-host: nothing was revoked — the reinstall failed before the policy was replaced, and the rule could not be put back — state: config line removed, ruleset not replaced (the revocation ended no connection) — next action: fix the underlying failure, then put the rule back and retry: egresslock allow-host t305 git.example.test:2222, then egresslock disallow-host t305 git.example.test:2222'
S2W_305="disallow-host: warning: a plain 'egresslock ensure t305' would drop allow-host git.example.test:2222 from the firewall without ending its open connections — restore the rule first (the allow-host command above)."
S3_305="disallow-host: the revocation is only half done — the rule is out of the firewall, but the connections that were open were not ended — state: conf line removed, ruleset swapped, conntrack not proven clean; next action: end the leftover connections: egresslock drop-unauthorized t305 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"
S4_305="Error: cannot record the installed pins for profile 't305' (the just-installed firewall rules could not be read back — fail closed)"

# L1, state (i), restore: the ensure dies pre-swap at ensure_resolve_pins
# (the sibling host cannot resolve), the trap restores the deleted line
# at its original index — the conf is byte-identical to its pre-image,
# the chain file and the conntrack table are untouched, only the -C
# probe ran, no `removed:`. Then the S1-documented retry works
# end-to-end (rc 0, removed:, the member -D/-L pair).
reset305
cp "$H305/t305.conf" "$H305/pre.conf"
cp "$CHAIN305" "$H305/chain.pre"
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.90.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\n' > "$A305CT"
d305="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow-host t305 git.example.test:2222 2>&1)"; d305_rc=$?
if [[ "$d305_rc" == 1 ]] && grep -qxF "$S1_305" <<<"$d305"; then
    a305 pass
else
    a305 fail "L1 rc 1 + S1 exact (rc=$d305_rc, out: $d305)"
fi
cmp -s "$H305/pre.conf" "$H305/t305.conf" \
    && a305 pass || a305 fail "L1 conf restored byte-identical (diff: $(diff "$H305/pre.conf" "$H305/t305.conf" | tr '\n' '|'))"
cmp -s "$H305/chain.pre" "$CHAIN305" \
    && a305 pass || a305 fail "L1 chain file unchanged"
[[ "$(cat "$A305CT")" == *'dst=192.0.2.10 sport=58666 dport=2222'* ]] \
    && a305 pass || a305 fail "L1 conntrack table untouched (got: $(tr '\n' '|' < "$A305CT"))"
[[ "$(cat "$C305LOG")" == 'conntrack -C' ]] \
    && a305 pass || a305 fail "L1 only the -C probe ran (log: $(tr '\n' '|' < "$C305LOG"))"
[[ "$d305" != *'removed:'* ]] \
    && a305 pass || a305 fail "L1 must not print removed: on the partial-failure path"
[[ "$d305" != *'could not be put back'* && "$d305" != *'the revocation is only half done'* ]] \
    && a305 pass || a305 fail "L1 must not print S2/S3 (out: $d305)"
: > "$C305LOG"
d305="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host t305 git.example.test:2222 2>&1)"; d305_rc=$?
if [[ "$d305_rc" == 0 && "$d305" == *'removed: rule allow-host git.example.test:2222'* && "$d305" != *'disallow-host:'* ]]; then
    a305 pass
else
    a305 fail "L1 retry (S1's documented next step) rc 0 + removed:, no disclosure (rc=$d305_rc, out: $d305)"
fi
expected_log305=$'conntrack -C\nconntrack -L -p tcp --dport 2222 -d 192.0.2.10\nconntrack -D -p tcp -s 10.199.90.5 --sport 58666 -d 192.0.2.10 --dport 2222\nconntrack -L -p tcp --dport 2222 -d 192.0.2.10\nconntrack -L -p tcp --sport 2222 -s 192.0.2.10\nconntrack -L -p tcp --sport 2222 -s 192.0.2.10\nconntrack -L -p tcp --dport 2222\nconntrack -L -p tcp --sport 2222'
[[ "$(cat "$C305LOG")" == "$expected_log305" ]] \
    && a305 pass || a305 fail "L1 retry flush ran end-to-end (log: $(tr '\n' '|' < "$C305LOG"))"

# L2, state (i), restore-failure: the L1 trigger PLUS a confdir-unwritable
# marker (list-chain read 2 chmod 0555s the conf dir — read 1 is the
# pre-delete capture, read 2 ensure_snapshot_pins' probe, so the delete
# stands). ensure dies pre-swap at ensure_resolve_pins; restore's mktemp
# fails -> S2 + S2w, conf line gone, no `removed:`. The test restores the
# mode.
reset305
printf '%s\n' "$H305" > "$STATE/nft/confdir-unwritable"
d305="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow-host t305 git.example.test:2222 2>&1)"; d305_rc=$?
chmod 0755 "$H305"
if [[ "$d305_rc" == 1 ]] && grep -qxF "$S2_305" <<<"$d305" && grep -qxF "$S2W_305" <<<"$d305"; then
    a305 pass
else
    a305 fail "L2 rc 1 + S2 exact + S2w warning (rc=$d305_rc, out: $d305)"
fi
grep -qF 'rule allow-host git.example.test:2222' "$H305/t305.conf" \
    && a305 fail "L2 restore failed -> the conf line stays gone" \
    || a305 pass
[[ "$(cat "$C305LOG")" == 'conntrack -C' && "$d305" != *'removed:'* && "$d305" != *"the revocation is only half done"* ]] \
    && a305 pass || a305 fail "L2 pre-swap shape intact (log: $(tr '\n' '|' < "$C305LOG"), out: $d305)"

# L3, state (ii): the -f swap succeeds (f-done) and the FIRST post-swap
# chain read fails once (fail-list-chain-after-f): write_pin_record dies
# NAMED (S4), the trap discloses the half-done revocation with the new
# one-line S3 (the drop-unauthorized recovery command), the conf line
# and the target accept are gone, the established entry survives, no
# conntrack reads beyond the -C probe, no `removed:`, the marker
# consumed.
reset305
# EGL-312/EGL-317: four rows — the kept original-direction row, a
# reversed row from the current pin address (192.0.2.10), a reversed row
# from an earlier address (192.0.2.20), and a cross-profile reversed row
# (the p305 workload end 10.199.91.5). The new S3 performs no conntrack
# reads and names no rows — the log pin below proves it.
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.90.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.10 dst=10.199.90.5 sport=2222 dport=58670 src=10.199.90.5 dst=192.0.2.10 sport=58670 dport=2222 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.20 dst=10.199.90.6 sport=2222 dport=58671 src=10.199.90.6 dst=192.0.2.20 sport=58671 dport=2222 [ASSURED] mark=0 zone=0 use=2\nipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.10 dst=10.199.91.5 sport=2222 dport=58672 src=10.199.91.5 dst=192.0.2.10 sport=58672 dport=2222 [ASSURED] mark=0 zone=0 use=2\n' > "$A305CT"
rm -f "$STATE/nft/f-done"; : > "$STATE/nft/fail-list-chain-after-f"
d305="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host t305 git.example.test:2222 2>&1)"; d305_rc=$?
if [[ "$d305_rc" == 1 ]] && grep -qxF "$S4_305" <<<"$d305" && grep -qxF "$S3_305" <<<"$d305"; then
    a305 pass
else
    a305 fail "L3 rc 1 + S4 cause + S3 line (rc=$d305_rc, out: $d305)"
fi
grep -qF 'rule allow-host git.example.test:2222' "$H305/t305.conf" \
    && a305 fail "L3 conf line removed by the delete" \
    || a305 pass
grep -qF '192.0.2.10' "$CHAIN305" \
    && a305 fail "L3 the swapped chain no longer accepts the target" \
    || a305 pass
[[ "$(cat "$A305CT")" == *'dst=192.0.2.10 sport=58666 dport=2222'* ]] \
    && a305 pass || a305 fail "L3 the established entry survives (got: $(tr '\n' '|' < "$A305CT"))"
# EGL-317: the new S3 performs no conntrack reads — the log is the -C
# probe only (the retired member-phase disclosure's -L/-D calls are
# gone).
[[ "$(cat "$C305LOG")" == 'conntrack -C' ]] \
    && a305 pass || a305 fail "L3 no member -D/-L ran (log: $(tr '\n' '|' < "$C305LOG"))"
[[ "$d305" != *'removed:'* && ! -e "$STATE/nft/fail-list-chain-after-f" ]] \
    && a305 pass || a305 fail "L3 no removed: + fault marker consumed"
: > "$A305CT"

# L4 guard: the same failure shape WITHOUT the disallow context (plain
# ensure) must stay disclose-free; the ensure still dies named pre-swap.
reset305
d305="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock ensure t305 2>&1)"; d305_rc=$?
if [[ "$d305_rc" == 1 && "$d305" != *'disallow-host:'* && "$d305" != *'rule restored'* ]]; then
    a305 pass
else
    a305 fail "L4 plain ensure: no disallow-host disclosure outside the window (rc=$d305_rc, out: $d305)"
fi

# L5 healthy path unchanged: covered by the L1 retry tail above (rc 0,
# removed:, no disclosure line) — explicit guard against wording drift
# on the SUCCESS path of a disallow-host run.
reset305
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.90.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\n' > "$A305CT"
d305="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host t305 git.example.test:2222 2>&1)"; d305_rc=$?
if [[ "$d305_rc" == 0 && "$d305" != *'disallow-host:'* && "$d305" != *'nothing was revoked'* ]]; then
    a305 pass
else
    a305 fail "L5 healthy path prints no recovery lines (rc=$d305_rc, out: $d305)"
fi
[[ "$(cat "$C305LOG")" == "$expected_log305" ]] \
    && a305 pass || a305 fail "L5 healthy flush shape unchanged (log: $(tr '\n' '|' < "$C305LOG"))"

# L6, pre-mutation silence (the CONF_DELETED_COMMITTED gate + the
# pre-delete arm + the cmd_disallow_host EXIT trap): the conf dir is
# made unwritable BEFORE the run, so conf_delete_allow_host dies at its
# mktemp while the disallow context is already armed — the COMMITTED
# gate must keep the armed trap silent (nothing was mutated): rc 1 with
# the named mktemp die only, no disallow-host: line, the conf untouched,
# the conntrack log only the -C probe. Restore the mode first.
reset305
cp "$H305/t305.conf" "$H305/pre305conf"
chmod 0555 "$H305"
d305="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow-host t305 git.example.test:2222 2>&1)"; d305_rc=$?
chmod 0755 "$H305"
if [[ "$d305_rc" == 1 && "$d305" == *'cannot create temp next to'* && "$d305" != *'disallow-host:'* && "$d305" != *'nothing was revoked'* ]]; then
    a305 pass
else
    a305 fail "L6 pre-delete failure stayed silent beyond its named die (rc=$d305_rc, out: $d305)"
fi
cmp -s "$H305/pre305conf" "$H305/t305.conf" \
    && a305 pass || a305 fail "L6 conf untouched when the delete never committed (diff: $(diff "$H305/pre305conf" "$H305/t305.conf" | tr '\n' '|'))"
[[ "$(cat "$C305LOG")" == 'conntrack -C' ]] \
    && a305 pass || a305 fail "L6 only the -C probe ran before the delete died (log: $(tr '\n' '|' < "$C305LOG"))"

# L7, config identity (the ER's F2 recipe): a custom conf under a
# directory with a space + a conflicting default conf (same profile
# name, different subnet) — no EGRESSLOCK_CONF anywhere. The printed
# recovery commands carry the selected conf (--config, %q-quoted); the
# S1 retry and the S2 allow-host/disallow-host pair are run VERBATIM
# (as printed) and must touch only the selected file.
reset305
mkdir -p "$H305/custom dir" "$H305/home/.config/egresslock"
cp "$H305/pristine.conf" "$H305/quilt"
cp "$H305/pristine.conf" "$H305/custom dir/t305.conf"
cat > "$H305/home/.config/egresslock/t305.conf" <<'EOF'
profile t305 10.200.100.0/24
EOF
cp "$H305/home/.config/egresslock/t305.conf" "$H305/quilt.default"
Q305="$(printf '%q' "$H305/custom dir/t305.conf")"
S1Q_305="disallow-host: nothing was revoked — the reinstall failed before the policy was replaced and the rule was put back — state: rule restored, ruleset not replaced (the rule is back in the config; the revocation ended no connection) — next action: fix the underlying failure, then retry: egresslock disallow-host t305 git.example.test:2222"
S2Q_305="disallow-host: nothing was revoked — the reinstall failed before the policy was replaced, and the rule could not be put back — state: config line removed, ruleset not replaced (the revocation ended no connection) — next action: fix the underlying failure, then put the rule back and retry: egresslock allow-host t305 git.example.test:2222, then egresslock disallow-host t305 git.example.test:2222"
S2WQ_305="disallow-host: warning: a plain 'egresslock ensure t305' would drop allow-host git.example.test:2222 from the firewall without ending its open connections — restore the rule first (the allow-host command above)."
# Seed state via the custom conf only (creates the custom confdir's
# t305.pins; the decoy default conf is never ensured).
d305="$(env HOME="$H305/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$(conf_home "$H305/custom dir/t305.conf")" egresslock ensure t305 2>&1)"; e305_rc=$?
if [[ "$e305_rc" == 0 && -f "$H305/custom dir/t305.pins" ]]; then
    a305 pass
else
    a305 fail "L7 custom-conf ensure seeds the custom confdir's pins (rc=$e305_rc, out: $d305)"
fi
# S1 path: the L1 failure shape via --config (DNS override kills the
# sibling resolve; the rule is restored, the printed retry carries
# --config). Run that printed retry verbatim -> rc 0 + removed:.
d305="$(env HOME="$H305/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' ARCMOCK_PASSWD_HOME="$(conf_home "$H305/custom dir/t305.conf")" egresslock disallow-host t305 git.example.test:2222 2>&1)"; d305_rc=$?
if [[ "$d305_rc" == 1 ]] && grep -qxF "$S1Q_305" <<<"$d305"; then
    a305 pass
else
    a305 fail "L7 S1 rc 1 + exact --config rendering (rc=$d305_rc, out: $d305)"
fi
retry305="${d305##*then retry: }"
[[ "$retry305" == "$S1Q_305" || "$retry305" == "egresslock disallow-host t305 git.example.test:2222" ]] \
    && a305 pass || a305 fail "L7 S1 printed retry parsed verbatim: '$retry305'"
d305="$(env HOME="$H305/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$(conf_home "$H305/custom dir/t305.conf")" bash -c "$retry305" 2>&1)"; d305_rc=$?
if [[ "$d305_rc" == 0 && "$d305" == *'removed: rule allow-host git.example.test:2222'* ]]; then
    a305 pass
else
    a305 fail "L7 verbatim S1 retry rc 0 + removed: (rc=$d305_rc, out: $d305)"
fi
cmp -s "$H305/quilt.default" "$H305/home/.config/egresslock/t305.conf" \
    && a305 pass || a305 fail "L7 conflicting default conf stays byte-identical (diff: $(diff "$H305/quilt.default" "$H305/home/.config/egresslock/t305.conf" | tr '\n' '|'))"
[[ ! -e "$H305/home/.config/egresslock/t305.pins" ]] \
    && a305 pass || a305 fail "L7 no decoy pin record created in the default confdir"
# S2 path: the L2 injections against the custom conf (the marker
# chmods the CUSTOM conf dir post-delete; the restore mktemp fails):
# rc 1 + S2/S2w exact with the quoted --config; then run BOTH printed
# commands verbatim (DNS override unset, as S2 itself instructs):
# allow-host puts the rule back (rc 0), disallow-host completes
# (rc 0 + removed:); only the selected file changed throughout.
cp "$H305/pristine.conf" "$H305/custom dir/t305.conf"
# Re-stage the rule AND refresh the custom confdir's pins record (the
# S1 path's post-deletion ensure dropped the revoked pin from it —
# live_pin_daddr refuses pre-mutation on a missing entry, named).
d305="$(env HOME="$H305/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$(conf_home "$H305/custom dir/t305.conf")" egresslock ensure t305 2>&1)"; e305_rc=$?
[[ "$e305_rc" == 0 ]] \
    && a305 pass || a305 fail "L7 S2 re-seed ensure rc 0 (rc=$e305_rc, out: $d305)"
printf '%s\n' "$H305/custom dir" > "$STATE/nft/confdir-unwritable"
d305="$(env HOME="$H305/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' ARCMOCK_PASSWD_HOME="$(conf_home "$H305/custom dir/t305.conf")" egresslock disallow-host t305 git.example.test:2222 2>&1)"; d305_rc=$?
chmod 0755 "$H305/custom dir"
if [[ "$d305_rc" == 1 ]] && grep -qxF "$S2Q_305" <<<"$d305" && grep -qxF "$S2WQ_305" <<<"$d305"; then
    a305 pass
else
    a305 fail "L7 S2 rc 1 + exact --config S2/S2w rendering (rc=$d305_rc, out: $d305)"
fi
grep -qxF 'rule allow-host git.example.test:2222' "$H305/custom dir/t305.conf" \
    && a305 fail "L7 S2 restore failed -> the conf line stays gone" \
    || a305 pass
pair305="${d305##*then put the rule back and retry: }"
hop305="${pair305%%, then *}"
hop2_305="${pair305#*, then }"
hop305="${hop305%%$'\n'*}"
hop2_305="${hop2_305%%$'\n'*}"
[[ "$hop305" == "egresslock allow-host t305 git.example.test:2222" \
    && "$hop2_305" == "egresslock disallow-host t305 git.example.test:2222" ]] \
    && a305 pass || a305 fail "L7 S2 printed pair parsed verbatim ('$hop305' / '$hop2_305')"
d305="$(env HOME="$H305/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$(conf_home "$H305/custom dir/t305.conf")" bash -c "$hop305" 2>&1)"; d305_rc=$?
if [[ "$d305_rc" == 0 && "$d305" == *'added: rule allow-host git.example.test:2222'* ]]; then
    a305 pass
else
    a305 fail "L7 verbatim S2 allow-host rc 0, rule back (rc=$d305_rc, out: $d305)"
fi
d305="$(env HOME="$H305/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$(conf_home "$H305/custom dir/t305.conf")" bash -c "$hop2_305" 2>&1)"; d305_rc=$?
if [[ "$d305_rc" == 0 && "$d305" == *'removed: rule allow-host git.example.test:2222'* ]]; then
    a305 pass
else
    a305 fail "L7 verbatim S2 disallow-host rc 0 + removed: (rc=$d305_rc, out: $d305)"
fi
grep -qxF 'rule allow-host git.example.test:2222' "$H305/custom dir/t305.conf" \
    && a305 fail "L7 the retry removed the custom conf line at the end" \
    || a305 pass
cmp -s "$H305/quilt.default" "$H305/home/.config/egresslock/t305.conf" \
    && a305 pass || a305 fail "L7 conflicting default conf byte-identical throughout the S2 path (diff: $(diff "$H305/quilt.default" "$H305/home/.config/egresslock/t305.conf" | tr '\n' '|'))"
rm -rf "$H305/custom dir" "$H305/home" "$H305/quilt" "$H305/quilt.default" "$H305/pre305conf"
egresslock teardown t305 >/dev/null 2>&1 || true
: > "$A305CT"

egl305_pass=$pass; egl305_fail=$fail
section_end egl305
# --- EGL-317: drop-unauthorized (the interrupted disallow-host recovery) ---
# ER-EGL-305-3 F1: a disallow-host that fails after the ruleset swap must
# be finishable by one operator-run command: `egresslock drop-unauthorized
# <profile> <port>` ends leftover workload flows on <port> the live policy
# no longer allows (earlier DNS addresses included), keeps independently
# authorized destinations, and prints success only after a fresh witness
# pass finds no residue. It reads the post-swap chain and mutates only
# conntrack. Legs: ER regression (rotation -> post-swap failure -> printed
# command verbatim), repeat-safety, authorized-dest, four read failures,
# lying scoped read (witness mutation control), writer-lock contention,
# space-path config identity, usage.
# Subnets: design's t317 10.199.92.0/24 is live (egresslock-s116v) and
# ensure_no_overlap is global, so t317/p317/q317 use 10.199.96.0/24 /
# 10.199.73.0/24 / 10.199.79.0/24 (EGL-219 precedent; ticket Log).
section_begin egl317 "EGL-317 drop-unauthorized recovery command"
a317() { assert "$@"; }

H317="$TESTROOT/h317"; rm -rf "$H317"; mkdir -p "$H317"
CTLOG317="$ARCMOCK_STATE/conntrack.log"
TT317="$STATE/nft/conntrack-table"
BIN317="$TESTROOT/bin/conntrack"
NFT317="$TESTROOT/bin/nft"
cat > "$H317/pristine.conf" <<'EOF'
profile t317 10.199.96.0/24
    rule allow-host git.example.test:2222
    rule allow-host cache.example.test:2222
EOF
cat > "$H317/p317.conf" <<'EOF'
profile p317 10.199.73.0/24
EOF
# rows317: the ER table — git's earlier address (.10), the rotated-in
# address (.20), the sibling grant's address (.11 — still accepted after
# the revocation), an unrelated-port row, and a row sourced from the
# control profile p317 (inside the port enumerate, outside t317's subnet).
rows317() {
    cat > "$TT317" <<'EOF'
ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.96.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2
ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.96.6 dst=192.0.2.20 sport=58667 dport=2222 src=192.0.2.20 dst=10.0.2.15 sport=2222 dport=58667 [ASSURED] mark=0 zone=0 use=2
ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.96.7 dst=192.0.2.11 sport=58668 dport=2222 src=192.0.2.11 dst=10.0.2.15 sport=2222 dport=58668 [ASSURED] mark=0 zone=0 use=2
ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.96.8 dst=192.0.2.30 sport=58669 dport=9999 src=192.0.2.30 dst=10.0.2.15 sport=9999 dport=58669 [ASSURED] mark=0 zone=0 use=2
ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.73.5 dst=192.0.2.10 sport=58670 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58670 [ASSURED] mark=0 zone=0 use=2
EOF
}
# reset317: the pre-revocation ER state — both grants on the conf, git
# ROTATED to .20 (the DNS refresh), p317 ensured, the full row set
# staged, the seam markers/counters cleared, the conntrack log clean.
reset317() {
    cp "$H317/pristine.conf" "$H317/t317.conf"
    rm -f "$STATE/nft/fail-list-chain-after-f" "$STATE/nft/fail-list-chain-after-flush" \
          "$STATE/nft/fail-list-chain-read-n" "$STATE/nft/f-done" \
          "$STATE/nft/conntrack-list-fails" "$STATE/nft/conntrack-list-port-fails" \
          "$STATE/nft/conntrack-list-port-recheck-fails" "$STATE/nft/conntrack-list-scoped-hides" \
          "$STATE/nft/conntrack-port-reads" "$STATE/nft/conntrack-flush-reads"
    env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        egresslock ensure t317 >/dev/null 2>&1
    env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        EGRESSLOCK_MOCK_DNS='git.example.test=192.0.2.20' \
        egresslock ensure t317 >/dev/null 2>&1
    env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/p317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        egresslock ensure p317 >/dev/null 2>&1
    : > "$STATE/nft/f-list-reads"
    rows317
    : > "$CTLOG317"
}
# s1_317: the EGL-311 S1 die exactly as printed (the reconcile's
# unusable-chain read, reused verbatim), marker tag interpolated.
s1_317() { # s1_317 <marker-tag>
    printf "Error: cannot read the firewall rules for profile 't317' after the rule was removed (rc=1): Error: mock nft: netlink read of chain 'p_t317' failed once (%s); state: conf line removed, ruleset swapped, conntrack unproven; next action: the rule is already out and the firewall already replaced, but any connection left on port 2222 cannot be checked against the removed rule while the rules are unreadable — inspect what is left: podman unshare --rootless-netns %s list chain inet egresslock p_t317; podman unshare --rootless-netns %s -L -p tcp --dport 2222; then delete a leftover by hand: podman unshare --rootless-netns %s -D -p tcp --dport 2222 -d <destination>" \
        "$1" "$NFT317" "$BIN317" "$BIN317"
}
Q317C="$(printf '%q' "$H317/t317.conf")"
S3T317="disallow-host: the revocation is only half done — the rule is out of the firewall, but the connections that were open were not ended — state: conf line removed, ruleset swapped, conntrack not proven clean; next action: end the leftover connections: egresslock drop-unauthorized t317 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"
OK317="drop-unauthorized: no leftover connection on port 2222 remains that profile 't317' does not allow"

# L1 (the ER regression): git rotated .10 -> .20; the -f swap succeeds and
# the FIRST post-swap chain read fails (fail-list-chain-after-f) ->
# disallow-host rc 1 + S4 + the new S3; the S3-printed command run verbatim
# -> rc 0 + the success line; .10/.20 gone; .11, the unrelated-port row,
# and the p317 row preserved; exactly the .10/.20 -D tuples; no removed:.
reset317
rm -f "$STATE/nft/f-done"; : > "$STATE/nft/fail-list-chain-after-f"
d317="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS='git.example.test=192.0.2.20' \
    egresslock disallow-host t317 git.example.test:2222 2>&1)"; d317_rc=$?
if [[ "$d317_rc" == 1 ]] \
   && grep -qxF "Error: cannot record the installed pins for profile 't317' (the just-installed firewall rules could not be read back — fail closed)" <<<"$d317" \
   && grep -qxF "$S3T317" <<<"$d317" \
   && [[ ! -e "$STATE/nft/fail-list-chain-after-f" ]] \
   && ! grep -q 'removed:' <<<"$d317"; then
    a317 pass
else
    a317 fail "L1 disallow-host post-swap fail: rc 1 + S4 + the drop-unauthorized S3 (rc=$d317_rc, out: $(echo "$d317" | tr '\n' '|' | head -c 600))"
fi
cmd317="${d317##*end the leftover connections: }"; cmd317="${cmd317%% (drops*}"
[[ "$cmd317" == "egresslock drop-unauthorized t317 2222" ]] \
    && a317 pass || a317 fail "L1 printed command parsed verbatim ('$cmd317')"
: > "$CTLOG317"
u317="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 bash -c "$cmd317" 2>&1)"; u317_rc=$?
if [[ "$u317_rc" == 0 ]] && grep -qxF "$OK317" <<<"$u317"; then
    a317 pass
else
    a317 fail "L1 printed command verbatim rc 0 + success (rc=$u317_rc, out: $u317)"
fi
if ! grep -qF 'src=10.199.96.5 dst=192.0.2.10 ' "$TT317" \
   && ! grep -qF 'src=10.199.96.6 dst=192.0.2.20 ' "$TT317" \
   && grep -qF 'src=10.199.96.7 dst=192.0.2.11 ' "$TT317" \
   && grep -qF 'dport=9999 ' "$TT317" \
   && grep -qF 'src=10.199.73.5 dst=192.0.2.10 ' "$TT317"; then
    a317 pass
else
    a317 fail "L1 .10/.20 gone; .11, unrelated-port, p317 rows preserved (table: $(tr '\n' '|' < "$TT317" | head -c 600))"
fi
if [[ "$(grep -c '^conntrack -D ' "$CTLOG317")" == 2 ]] \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.96.5 --sport 58666 -d 192.0.2.10 --dport 2222' "$CTLOG317" \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.96.6 --sport 58667 -d 192.0.2.20 --dport 2222' "$CTLOG317"; then
    a317 pass
else
    a317 fail "L1 exactly the .10/.20 -D tuples (log: $(tr '\n' '|' < "$CTLOG317" | head -c 600))"
fi

# L2 repeat after success: rc 0 + success; no new -D.
: > "$CTLOG317"
u317="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock drop-unauthorized t317 2222 2>&1)"; u317_rc=$?
if [[ "$u317_rc" == 0 ]] && grep -qxF "$OK317" <<<"$u317" \
   && ! grep -q '^conntrack -D ' "$CTLOG317"; then
    a317 pass
else
    a317 fail "L2 repeat after success: rc 0 + success + no new -D (rc=$u317_rc, log: $(tr '\n' '|' < "$CTLOG317"))"
fi

# L3 repeat after partial progress: one row hand-deleted; rc 0; exactly the
# remaining row's -D (the command picks up where the interruption left off).
rows317
"$BIN317" -D -p tcp -s 10.199.96.5 --sport 58666 -d 192.0.2.10 --dport 2222 >/dev/null 2>&1
: > "$CTLOG317"
u317="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock drop-unauthorized t317 2222 2>&1)"; u317_rc=$?
if [[ "$u317_rc" == 0 ]] && grep -qxF "$OK317" <<<"$u317" \
   && [[ "$(grep -c '^conntrack -D ' "$CTLOG317")" == 1 ]] \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.96.6 --sport 58667 -d 192.0.2.20 --dport 2222' "$CTLOG317" \
   && ! grep -qF 'src=10.199.96.6 dst=192.0.2.20 ' "$TT317"; then
    a317 pass
else
    a317 fail "L3 repeat after partial progress: rc 0 + only the .20 -D (rc=$u317_rc, log: $(tr '\n' '|' < "$CTLOG317" | head -c 500))"
fi

# L4 no refusal, authorized dest preserved (D6): the grant is still in the
# conf — an accepted dest row (.10) and the sibling (.11) are kept, the
# unaccepted dest row (.20) is dropped; rc 0, only the .20 -D.
cp "$H317/pristine.conf" "$H317/t317.conf"
env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure t317 >/dev/null 2>&1
rows317
: > "$CTLOG317"
u317="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock drop-unauthorized t317 2222 2>&1)"; u317_rc=$?
if [[ "$u317_rc" == 0 ]] && grep -qxF "$OK317" <<<"$u317" \
   && grep -qF 'src=10.199.96.5 dst=192.0.2.10 ' "$TT317" \
   && grep -qF 'src=10.199.96.7 dst=192.0.2.11 ' "$TT317" \
   && ! grep -qF 'src=10.199.96.6 dst=192.0.2.20 ' "$TT317" \
   && [[ "$(grep -c '^conntrack -D ' "$CTLOG317")" == 1 ]] \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.96.6 --sport 58667 -d 192.0.2.20 --dport 2222' "$CTLOG317"; then
    a317 pass
else
    a317 fail "L4 no refusal: accepted dest kept, only .20 dropped (rc=$u317_rc, table: $(tr '\n' '|' < "$TT317" | head -c 500))"
fi

# L5a fail-closed: conntrack-list-port-fails (the flush pass's port-only
# enumerate) -> the named enumerate die, rc 1, no success, no -D.
rows317
touch "$STATE/nft/conntrack-list-port-fails"
: > "$CTLOG317"
u317="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock drop-unauthorized t317 2222 2>&1)"; u317_rc=$?
rm -f "$STATE/nft/conntrack-list-port-fails"
if [[ "$u317_rc" == 1 ]] \
   && grep -qxF "Error: cannot read the rootless netns conntrack table (rc=1): mock conntrack: port list failed; state: conf line removed, ruleset swapped, conntrack unproven; next action: podman unshare --rootless-netns $BIN317 -L -p tcp --dport 2222" <<<"$u317" \
   && [[ "$u317" != *'drop-unauthorized:'* ]] \
   && ! grep -q '^conntrack -D ' "$CTLOG317"; then
    a317 pass
else
    a317 fail "L5a port enumerate read fails closed named (rc=$u317_rc, out: $(echo "$u317" | tr '\n' '|' | head -c 500))"
fi

# L5b fail-closed: the flush pass's chain read (EGL-311 S1) -> rc 1, no
# success (f-done hand-created; the marker consumed by the fire).
: > "$STATE/nft/f-done"; : > "$STATE/nft/fail-list-chain-after-f"
: > "$CTLOG317"
u317="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock drop-unauthorized t317 2222 2>&1)"; u317_rc=$?
if [[ "$u317_rc" == 1 ]] \
   && grep -qxF "$(s1_317 fail-list-chain-after-f)" <<<"$u317" \
   && [[ "$u317" != *'drop-unauthorized:'* ]] \
   && [[ ! -e "$STATE/nft/fail-list-chain-after-f" ]] \
   && ! grep -q '^conntrack -D ' "$CTLOG317"; then
    a317 pass
else
    a317 fail "L5b unreadable chain (S1) fails closed named (rc=$u317_rc, out: $(echo "$u317" | tr '\n' '|' | head -c 500))"
fi

# L5c fail-closed: the WITNESS pass's chain read (fail-list-chain-after-flush
# — gated on the flush pass's -D) -> EGL-311 S1 at the witness, rc 1, no
# success; the flush's deletes remain (the .20 row is gone; the accepted
# .10 row stays).
rows317
: > "$STATE/nft/f-done"; : > "$STATE/nft/fail-list-chain-after-flush"
: > "$CTLOG317"
u317="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock drop-unauthorized t317 2222 2>&1)"; u317_rc=$?
if [[ "$u317_rc" == 1 ]] \
   && grep -qxF "$(s1_317 fail-list-chain-after-flush)" <<<"$u317" \
   && [[ "$u317" != *'drop-unauthorized:'* ]] \
   && [[ ! -e "$STATE/nft/fail-list-chain-after-flush" ]] \
   && ! grep -qF 'src=10.199.96.6 dst=192.0.2.20 ' "$TT317" \
   && grep -qF 'src=10.199.96.5 dst=192.0.2.10 ' "$TT317"; then
    a317 pass
else
    a317 fail "L5c unreadable chain at the witness (S1) fails closed named (rc=$u317_rc, out: $(echo "$u317" | tr '\n' '|' | head -c 500))"
fi

# L5d fail-closed: conntrack-list-port-recheck-fails (the witness pass's
# port-only enumerate — the SECOND such read) -> the named enumerate die,
# rc 1, no success; the flush's deletes remain.
rows317
rm -f "$STATE/nft/conntrack-port-reads"
touch "$STATE/nft/conntrack-list-port-recheck-fails"
: > "$CTLOG317"
u317="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock drop-unauthorized t317 2222 2>&1)"; u317_rc=$?
rm -f "$STATE/nft/conntrack-list-port-recheck-fails" "$STATE/nft/conntrack-port-reads"
if [[ "$u317_rc" == 1 ]] \
   && grep -qxF "Error: cannot read the rootless netns conntrack table (rc=1): mock conntrack: port recheck list failed; state: conf line removed, ruleset swapped, conntrack unproven; next action: podman unshare --rootless-netns $BIN317 -L -p tcp --dport 2222" <<<"$u317" \
   && [[ "$u317" != *'drop-unauthorized:'* ]] \
   && ! grep -qF 'src=10.199.96.6 dst=192.0.2.20 ' "$TT317" \
   && grep -qF 'src=10.199.96.5 dst=192.0.2.10 ' "$TT317"; then
    a317 pass
else
    a317 fail "L5d witness enumerate recheck fails closed named (rc=$u317_rc, out: $(echo "$u317" | tr '\n' '|' | head -c 500))"
fi

# L6 lying scoped read (the mutation control for the witness pass): the
# seam fools EVERY flush-shaped read (the flush helper's enumerate AND its
# own witness) with the empty dump, so the flush pass ends with no -D and
# no survivor die — but the witness pass's port-only enumerate is a
# DIFFERENT read shape and still sees the rows -> F3 exact, rc 1, no
# success. Witness arg ignored -> a false success (rc 0) and this pin red.
sed -i '/rule allow-host git.example.test:2222/d' "$H317/t317.conf"
env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure t317 >/dev/null 2>&1
rows317
touch "$STATE/nft/conntrack-list-scoped-hides"
: > "$CTLOG317"
u317="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock drop-unauthorized t317 2222 2>&1)"; u317_rc=$?
rm -f "$STATE/nft/conntrack-list-scoped-hides"
if [[ "$u317_rc" == 1 ]] \
   && grep -qxF "Error: the connections on port 2222 to 192.0.2.10 192.0.2.20 still have live conntrack entries and the policy does not allow them; state: conf line removed, ruleset swapped, some connections remain; next action: run the same command again (safe to repeat): egresslock drop-unauthorized t317 2222" <<<"$u317" \
   && [[ "$u317" != *'drop-unauthorized:'* ]] \
   && ! grep -q '^conntrack -D ' "$CTLOG317" \
   && grep -qF 'src=10.199.96.5 dst=192.0.2.10 ' "$TT317" \
   && grep -qF 'src=10.199.96.6 dst=192.0.2.20 ' "$TT317"; then
    a317 pass
else
    a317 fail "L6 lying scoped read: witness sees the rows -> F3, no -D, no success (rc=$u317_rc, out: $(echo "$u317" | tr '\n' '|' | head -c 500))"
fi

# L7 writer lock: with the account lock held exclusively and wait 0, the
# command fails closed with the named contended line BEFORE any conf or
# conntrack work (log delta empty), no success line.
H317LOCKHOME="$(conf_home "$H317/t317.conf")"
mkdir -p "$H317LOCKHOME/.local/state/egresslock"
: > "$CTLOG317"
exec 8>>"$H317LOCKHOME/.local/state/egresslock/engine.lock"
flock -x 8
printf 'pid=%s mode=write started=%s\n' 99997 "2026-01-01T00:00:00-07:00" >&8
u317="$(EGRESSLOCK_LOCK_WAIT=0 env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock drop-unauthorized t317 2222 2>&1)"; u317_rc=$?
flock -u 8; exec 8>&-
if [[ "$u317_rc" == 1 ]] \
   && [[ "$u317" == *"another egresslock command is running for this account"* ]] \
   && [[ "$u317" == *"holder: pid=99997"* ]] \
   && [[ "$u317" != *'drop-unauthorized:'* ]] \
   && [[ ! -s "$CTLOG317" ]]; then
    a317 pass
else
    a317 fail "L7 writer contention: named refusal, no reads, no success (rc=$u317_rc, out: $(echo "$u317" | tr '\n' '|' | head -c 400))"
fi

# L8 config identity (ER's F2 recipe): the fixed confdir lives under a path
# with a space while a decoy conf for the same profile sits under another
# $HOME (which must not move it); no EGRESSLOCK_CONF. S3 carries no conf
# path, but the printed command resolves the same fixed confdir — the .20
# row is dropped; decoy resolution would skip it and claim success. The
# decoy never changes.
mkdir -p "$H317/custom dir" "$H317/home/.config/egresslock"
cat > "$H317/custom dir/q317.conf" <<'EOF'
profile q317 10.199.79.0/24
    rule allow-host git.example.test:2222
EOF
cat > "$H317/home/.config/egresslock/q317.conf" <<'EOF'
profile q317 10.200.101.0/24
EOF
cp "$H317/home/.config/egresslock/q317.conf" "$H317/decoy.pre"
env HOME="$H317/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    ARCMOCK_PASSWD_HOME="$(conf_home "$H317/custom dir/q317.conf")" egresslock ensure q317 >/dev/null 2>&1
env HOME="$H317/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS='git.example.test=192.0.2.20' \
    ARCMOCK_PASSWD_HOME="$(conf_home "$H317/custom dir/q317.conf")" egresslock ensure q317 >/dev/null 2>&1
S3Q317="disallow-host: the revocation is only half done — the rule is out of the firewall, but the connections that were open were not ended — state: conf line removed, ruleset swapped, conntrack not proven clean; next action: end the leftover connections: egresslock drop-unauthorized q317 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"
OKQ317="drop-unauthorized: no leftover connection on port 2222 remains that profile 'q317' does not allow"
rm -f "$STATE/nft/f-done"; : > "$STATE/nft/fail-list-chain-after-f"
d317="$(env HOME="$H317/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS='git.example.test=192.0.2.20' \
    ARCMOCK_PASSWD_HOME="$(conf_home "$H317/custom dir/q317.conf")" egresslock disallow-host q317 git.example.test:2222 2>&1)"; d317_rc=$?
if [[ "$d317_rc" == 1 ]] \
   && grep -qxF "Error: cannot probe the nft policy for profile 'q317' in the rootless netns (rc=1): Error: mock nft: netlink read of chain 'p_q317' failed once (fail-list-chain-after-f); check pasta/podman health — run: egresslock ensure q317" <<<"$d317" \
   && grep -qxF "Error: policy verification failed for profile 'q317' (fail closed)" <<<"$d317" \
   && grep -qxF "$S3Q317" <<<"$d317"; then
    a317 pass
else
    a317 fail "L8 S3 carries the fixed-confdir half-done revocation text (rc=$d317_rc, out: $(echo "$d317" | tr '\n' '|' | head -c 600))"
fi
cmd317="${d317##*end the leftover connections: }"; cmd317="${cmd317%% (drops*}"
[[ "$cmd317" == "egresslock drop-unauthorized q317 2222" ]] \
    && a317 pass || a317 fail "L8 printed command parsed verbatim ('$cmd317')"
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.79.5 dst=192.0.2.20 sport=59001 dport=2222 src=192.0.2.20 dst=10.0.2.15 sport=2222 dport=59001 [ASSURED] mark=0 zone=0 use=2\n' > "$TT317"
: > "$CTLOG317"
u317="$(env HOME="$H317/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$(conf_home "$H317/custom dir/q317.conf")" bash -c "$cmd317" 2>&1)"; u317_rc=$?
if [[ "$u317_rc" == 0 ]] \
   && grep -qxF "$OKQ317" <<<"$u317" \
   && ! grep -qF 'dst=192.0.2.20 ' "$TT317" \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.79.5 --sport 59001 -d 192.0.2.20 --dport 2222' "$CTLOG317" \
   && cmp -s "$H317/home/.config/egresslock/q317.conf" "$H317/decoy.pre" \
   && [[ ! -e "$H317/home/.config/egresslock/q317.pins" ]]; then
    a317 pass
else
    a317 fail "L8 verbatim command uses the selected conf's scope (rc=$u317_rc, out: $u317, table: $(tr '\n' '|' < "$TT317" | head -c 300))"
fi

# L9 usage: the exact rc-2 strings, and the unknown profile rc 2 after the
# conf load (nothing read).
u317="$(env egresslock drop-unauthorized 2>&1)"; u317_rc=$?
[[ "$u317_rc" == 2 && "$u317" == $'Error: drop-unauthorized requires a profile name.\nusage: egresslock drop-unauthorized <profile> <port>' ]] \
    && a317 pass || a317 fail "L9 missing profile rc 2 exact (rc=$u317_rc, out: $u317)"
u317="$(env egresslock drop-unauthorized t317 2>&1)"; u317_rc=$?
[[ "$u317_rc" == 2 && "$u317" == $'Error: drop-unauthorized requires a port.\nusage: egresslock drop-unauthorized <profile> <port>' ]] \
    && a317 pass || a317 fail "L9 missing port rc 2 exact (rc=$u317_rc, out: $u317)"
u317="$(env egresslock drop-unauthorized t317 2222 3 2>&1)"; u317_rc=$?
[[ "$u317_rc" == 2 && "$u317" == $'Error: drop-unauthorized takes exactly one port.\nusage: egresslock drop-unauthorized <profile> <port>' ]] \
    && a317 pass || a317 fail "L9 extra arg rc 2 exact (rc=$u317_rc, out: $u317)"
u317_ok=1
for p317_bad in 0 70000 abc; do
    u317="$(env egresslock drop-unauthorized t317 "$p317_bad" 2>&1)"; u317_rc=$?
    [[ "$u317_rc" == 2 && "$u317" == "Error: invalid port '$p317_bad' (expected 1-65535)." ]] || u317_ok=0
done
[[ "$u317_ok" == 1 ]] \
    && a317 pass || a317 fail "L9 bad port rc 2 exact (last: $u317)"
: > "$CTLOG317"
u317="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock drop-unauthorized nosuchprof 2222 2>&1)"; u317_rc=$?
if [[ "$u317_rc" == 2 && "$u317" == *"no profile config: "*"nosuchprof.conf' not found"* ]] && [[ ! -s "$CTLOG317" ]]; then
    a317 pass
else
    a317 fail "L9 unknown profile rc 2, conf-loaded, nothing read (rc=$u317_rc, out: $u317)"
fi

env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/t317.conf")" egresslock teardown t317 >/dev/null 2>&1 || true
env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/p317.conf")" egresslock teardown p317 >/dev/null 2>&1 || true
env ARCMOCK_PASSWD_HOME="$(conf_home "$H317/custom dir/q317.conf")" egresslock teardown q317 >/dev/null 2>&1 || true
: > "$TT317"
egl317_pass=$pass; egl317_fail=$fail
section_end egl317
# --- EGL-318: disallow-host failure-handler hardening (cleanup guards, S1T, S2 accuracy) ---
# The disclosure is the last line of the fail-closed contract. EGL-318
# guards ensure_cleanup's diagnostic writes (behind EGL-305's set +e),
# records removals in ENSURE_REMOVED BEFORE the write, appends S1T after
# S1 only when cleanup removed the profile's anchor, and drops S2's
# running-rules claim (false exactly then). Legs: H1 (removed -> S1T +
# working start command), H2 (removal failure -> warning, no trailer),
# H3 (converged -> no trailer), H4 (restore failed -> S2 accuracy), H5a/b
# (diagnostic writes cannot lose disclosure), H6 (healthy unchanged).
section_begin egl318 "EGL-318 disallow-host failure-handler hardening (cleanup guards, S1T, S2 accuracy)"
a318() { assert "$@"; }

H318="$TESTROOT/h318"; rm -rf "$H318"; mkdir -p "$H318"
cat > "$H318/pristine.conf" <<'EOF'
profile t318 10.199.108.0/24
    rule allow-host git.example.test:2222
    rule allow-host cache.example.test:8080
EOF
cat > "$H318/p318.conf" <<'EOF'
profile p318 10.199.109.0/24
EOF
export ARCMOCK_PASSWD_HOME="$(conf_home "$H318/t318.conf")"
reset318() {
    cp "$H318/pristine.conf" "$H318/t318.conf"
    rm -f "$STATE/rm-container-fails" "$STATE/nft/confdir-unwritable" "$STATE/nft/f-done"
    env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure t318 >/dev/null 2>&1
    env EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$(conf_home "$H318/p318.conf")" egresslock ensure p318 >/dev/null 2>&1
}
S1_318="disallow-host: nothing was revoked — the reinstall failed before the policy was replaced and the rule was put back — state: rule restored, ruleset not replaced (the rule is back in the config; the revocation ended no connection) — next action: fix the underlying failure, then retry: egresslock disallow-host t318 git.example.test:2222"
S1T_318="disallow-host: note: the failed reinstall removed containers it had started for profile 't318' — if the profile is not running now, start it again: egresslock ensure t318"
S2_318="disallow-host: nothing was revoked — the reinstall failed before the policy was replaced, and the rule could not be put back — state: config line removed, ruleset not replaced (the revocation ended no connection) — next action: fix the underlying failure, then put the rule back and retry: egresslock allow-host t318 git.example.test:2222, then egresslock disallow-host t318 git.example.test:2222"
S2W_318="disallow-host: warning: a plain 'egresslock ensure t318' would drop allow-host git.example.test:2222 from the firewall without ending its open connections — restore the rule first (the allow-host command above)."

# H1 — handler-abort leg: the anchor is stopped before the run, so the
# failed reinstall restarts and OWNS it; the resolve die fires pre-swap,
# the cleanup removes the anchor (removal line BEFORE S1), and the S1T
# trailer names the removal and the start-again command.
reset318
cp "$H318/t318.conf" "$H318/pre.conf"
rm -f "$STATE/running/egresslock-anchor-t318"
d318="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow-host t318 git.example.test:2222 2>&1)"; d318_rc=$?
if [[ "$d318_rc" == 1 ]] \
   && grep -qxF "$S1_318" <<<"$d318" \
   && grep -qxF "$S1T_318" <<<"$d318" \
   && [[ "$d318" != *'removed:'* ]]; then
    a318 pass
else
    a318 fail "H1 rc 1 + S1 exact + S1T exact, no removed: (rc=$d318_rc, out: $d318)"
fi
n318_rm="$(grep -nF "removed container 'egresslock-anchor-t318' (rm -f)" <<<"$d318" | head -n1 | cut -d: -f1)"
n318_s1="$(grep -nF "$S1_318" <<<"$d318" | head -n1 | cut -d: -f1)"
[[ -n "$n318_rm" && -n "$n318_s1" && "$n318_rm" -lt "$n318_s1" ]] \
    && a318 pass || a318 fail "H1 the cleanup removal line precedes S1 (removed@$n318_rm, s1@$n318_s1)"
cmp -s "$H318/pre.conf" "$H318/t318.conf" \
    && a318 pass || a318 fail "H1 conf restored byte-identical (diff: $(diff "$H318/pre.conf" "$H318/t318.conf" | tr '\n' '|'))"
[[ -f "$STATE/running/egresslock-anchor-p318" ]] \
    && a318 pass || a318 fail "H1 the unrelated p318 anchor is still running"
# the S1T-printed start-again command works as printed (the skip-probe
# env knob is the mock environment's, not part of the printed command).
d318="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$(conf_home "$H318/t318.conf")" egresslock ensure t318 2>&1)"; d318_rc=$?
if [[ "$d318_rc" == 0 && -f "$STATE/running/egresslock-anchor-t318" ]]; then
    a318 pass
else
    a318 fail "H1 S1T start-again command rc 0 + anchor running (rc=$d318_rc, out: $d318)"
fi
egresslock teardown t318 >/dev/null 2>&1 || true

# H2 — cleanup-removal failure: the rm seam makes the owned-anchor removal
# fail; the warning prints (before S1), the trailer stays absent (no
# successful removal recorded), the failure stays named.
reset318
cp "$H318/t318.conf" "$H318/pre.conf"
rm -f "$STATE/running/egresslock-anchor-t318"
: > "$STATE/rm-container-fails"
d318="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow-host t318 git.example.test:2222 2>&1)"; d318_rc=$?
rm -f "$STATE/rm-container-fails"
if [[ "$d318_rc" == 1 ]] \
   && grep -qxF "$S1_318" <<<"$d318" \
   && ! grep -qF "$S1T_318" <<<"$d318" \
   && ! grep -qF "removed container 'egresslock-anchor-t318' (rm -f)" <<<"$d318" \
   && [[ "$d318" != *'removed:'* ]]; then
    a318 pass
else
    a318 fail "H2 rc 1 + S1 exact, no trailer, no removal line (rc=$d318_rc, out: $d318)"
fi
warn318="$(grep -F 'cleanup: removal failed:' <<<"$d318" | head -n1)"
[[ "$warn318" == *'egresslock-anchor-t318'* ]] \
    && a318 pass || a318 fail "H2 the removal-failure warning names the anchor (warn: '$warn318')"
n318_warn="$(grep -nF 'cleanup: removal failed:' <<<"$d318" | head -n1 | cut -d: -f1)"
n318_s1="$(grep -nF "$S1_318" <<<"$d318" | head -n1 | cut -d: -f1)"
[[ -n "$n318_warn" && -n "$n318_s1" && "$n318_warn" -lt "$n318_s1" ]] \
    && a318 pass || a318 fail "H2 the removal-failure warning precedes S1 (warn@$n318_warn, s1@$n318_s1)"
cmp -s "$H318/pre.conf" "$H318/t318.conf" \
    && a318 pass || a318 fail "H2 conf restored byte-identical (diff: $(diff "$H318/pre.conf" "$H318/t318.conf" | tr '\n' '|'))"
egresslock teardown t318 >/dev/null 2>&1 || true

# H3 — converged profile (negative): the anchor is running and unowned,
# so the failed reinstall owns nothing and the cleanup removes nothing —
# S1 restores the rule, the trailer must NOT appear (no false claim).
reset318
d318="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow-host t318 git.example.test:2222 2>&1)"; d318_rc=$?
if [[ "$d318_rc" == 1 ]] \
   && grep -qxF "$S1_318" <<<"$d318" \
   && ! grep -qF "$S1T_318" <<<"$d318" \
   && ! grep -qF "removed container 'egresslock-anchor-t318' (rm -f)" <<<"$d318" \
   && ! grep -q 'cleanup:' <<<"$d318"; then
    a318 pass
else
    a318 fail "H3 rc 1 + S1 exact, no trailer, no cleanup lines (rc=$d318_rc, out: $d318)"
fi

# H4 — S2 accuracy (the anchor was removed, the restore failed): the
# confdir seam makes the trap-context restore's mktemp fail after the
# delete; the S2 text drops the running-rules claim (false once the
# anchor is removed), S2w stays, the removal was recorded (no trailer —
# S1-only), the conf line stays gone.
reset318
cp "$H318/t318.conf" "$H318/pre.conf"
rm -f "$STATE/running/egresslock-anchor-t318"
printf '%s\n' "$H318" > "$STATE/nft/confdir-unwritable"
d318="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow-host t318 git.example.test:2222 2>&1)"; d318_rc=$?
chmod 0755 "$H318"
if [[ "$d318_rc" == 1 ]] \
   && grep -qxF "$S2_318" <<<"$d318" \
   && grep -qxF "$S2W_318" <<<"$d318" \
   && [[ "$d318" != *'the running rules still allow'* ]] \
   && grep -qF "removed container 'egresslock-anchor-t318' (rm -f)" <<<"$d318" \
   && ! grep -qF "$S1T_318" <<<"$d318"; then
    a318 pass
else
    a318 fail "H4 rc 1 + S2/S2w exact, no running-rules claim, removal recorded, no trailer (rc=$d318_rc, out: $d318)"
fi
grep -qF 'rule allow-host git.example.test:2222' "$H318/t318.conf" \
    && a318 fail "H4 restore failed -> the conf line stays gone" \
    || a318 pass

# H5a — a failed `removed container` diagnostic write cannot lose the
# disclosure: the write fails, the removal is still recorded, S1 + S1T
# still print, no removal line.
reset318
cp "$H318/t318.conf" "$H318/pre.conf"
rm -f "$STATE/running/egresslock-anchor-t318"
d318="$(
  echo() { case "${1:-}" in "removed container "*) return 1;; esac; builtin echo "$@"; }
  export -f echo
  env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow-host t318 git.example.test:2222 2>&1
)"; d318_rc=$?
if [[ "$d318_rc" == 1 ]] \
   && grep -qxF "$S1_318" <<<"$d318" \
   && grep -qxF "$S1T_318" <<<"$d318" \
   && ! grep -qF "removed container 'egresslock-anchor-t318' (rm -f)" <<<"$d318"; then
    a318 pass
else
    a318 fail "H5a rc 1 + S1/S1T despite the failed write, no removal line (rc=$d318_rc, out: $d318)"
fi
cmp -s "$H318/pre.conf" "$H318/t318.conf" \
    && a318 pass || a318 fail "H5a conf restored byte-identical (diff: $(diff "$H318/pre.conf" "$H318/t318.conf" | tr '\n' '|'))"
egresslock teardown t318 >/dev/null 2>&1 || true

# H5b — a failed `cleanup: removal failed` diagnostic write: the removal
# fails, its named write fails, S1 still prints, no trailer (nothing was
# removed), no warning line.
reset318
cp "$H318/t318.conf" "$H318/pre.conf"
rm -f "$STATE/running/egresslock-anchor-t318"
: > "$STATE/rm-container-fails"
d318="$(
  echo() { case "${1:-}" in "cleanup: removal failed: "*) return 1;; esac; builtin echo "$@"; }
  export -f echo
  env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow-host t318 git.example.test:2222 2>&1
)"; d318_rc=$?
rm -f "$STATE/rm-container-fails"
if [[ "$d318_rc" == 1 ]] \
   && grep -qxF "$S1_318" <<<"$d318" \
   && ! grep -qF "$S1T_318" <<<"$d318" \
   && ! grep -q 'cleanup: removal failed' <<<"$d318"; then
    a318 pass
else
    a318 fail "H5b rc 1 + S1 exact despite the failed write, no trailer, no warning (rc=$d318_rc, out: $d318)"
fi
cmp -s "$H318/pre.conf" "$H318/t318.conf" \
    && a318 pass || a318 fail "H5b conf restored byte-identical (diff: $(diff "$H318/pre.conf" "$H318/t318.conf" | tr '\n' '|'))"

# H6 — success path unchanged: healthy disallow-host -> rc 0, removed:,
# no disclosure and no trailer.
reset318
d318="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host t318 git.example.test:2222 2>&1)"; d318_rc=$?
if [[ "$d318_rc" == 0 ]] \
   && [[ "$d318" == *'removed: rule allow-host git.example.test:2222'* ]] \
   && [[ "$d318" != *'disallow-host:'* ]] \
   && ! grep -qF "$S1T_318" <<<"$d318"; then
    a318 pass
else
    a318 fail "H6 healthy path rc 0 + removed:, no disclosure (rc=$d318_rc, out: $d318)"
fi

egresslock teardown t318 >/dev/null 2>&1 || true
env ARCMOCK_PASSWD_HOME="$(conf_home "$H318/p318.conf")" egresslock teardown p318 >/dev/null 2>&1 || true
egl318_pass=$pass; egl318_fail=$fail
section_end egl318
# --- EGL-206: checkpoint-annotation refusal + live hardening assertions ----
# D2a: every kit-owned run inspects the RESOLVED image for
# io.podman.annotations.checkpoint.runtime.name and refuses named before
# any `podman run` (CVE-2026-94603). D2b: CapEff all-zero + NoNewPrivs 1
# are asserted LIVE at start and verify (both containers, both verbs), and
# converged short-circuits are caps-aware (bad caps never bless; EGL-123-D3).
section_begin egl206 "EGL-206 checkpoint-annotation refusal + live hardening"
e206() { assert "$@"; }

S206="$TESTROOT/s206"; rm -rf "$S206"; mkdir -p "$S206"
cat > "$S206/s206.conf" <<'EOF'
profile s206 10.199.98.0/24
    rule gateway-only
    gateway 10.199.98.2 3128 s206-allowlist
EOF
printf '# starter\n' > "$S206/s206-allowlist"
cat > "$S206/s206b.conf" <<'EOF'
profile s206b 10.199.99.0/24
EOF

# D2a-1: annotated gateway image refused named, with no run of it (the
# anchor still starts first — ensure_anchor precedes the gateway).
: > "$STATE/image-annotated-localhost_egresslock-gateway_latest"
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206.conf")" egresslock ensure s206 2>&1)"; e206_rc=$?
if [[ "$e206_rc" != 0 && "$e206_out" == *"io.podman.annotations.checkpoint.runtime.name"* \
      && "$e206_out" == *"CVE-2026-94603"* ]] \
   && ! grep -q -- '--name egresslock-gateway-s206' "$STATE/runlog"; then
    e206 pass
else
    e206 fail "D2a annotated gateway image refused named, no run (rc=$e206_rc, out: $e206_out, gwruns=$(grep -c -- '--name egresslock-gateway-s206' "$STATE/runlog" 2>/dev/null || echo 0))"
fi
rm -f "$STATE/image-annotated-localhost_egresslock-gateway_latest"

# D2a-2: annotated anchor image (env override) refused named, no anchor
# run — the anchor preflight covers EGRESSLOCK_ANCHOR_IMAGE too.
: > "$STATE/images/localhost_base_latest"
: > "$STATE/image-annotated-localhost_base_latest"
e206_out="$(env EGRESSLOCK_ANCHOR_IMAGE="localhost/base:latest" \
    ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206b.conf")" egresslock ensure s206b 2>&1)"; e206_rc=$?
if [[ "$e206_rc" != 0 && "$e206_out" == *"io.podman.annotations.checkpoint.runtime.name"* ]] \
   && ! grep -q -- '--name egresslock-anchor-s206b' "$STATE/runlog"; then
    e206 pass
else
    e206 fail "D2a annotated anchor image refused named, no run (rc=$e206_rc, out: $e206_out, anchruns=$(grep -c -- '--name egresslock-anchor-s206b' "$STATE/runlog" 2>/dev/null || echo 0))"
fi
rm -f "$STATE/image-annotated-localhost_base_latest"

# D2a-3 (R-EGL-206-2 #1): fresh-account first-create — the resolved
# anchor image is NOT in the mock store (seed marker removed). The
# preflight must provision it (the same pull rt_run would do, in front
# of the inspect) and the ensure must come up green — not die in the
# preflight (the live-matrix 32/16 regression).
rm -f "$STATE/images/docker.io_library_alpine_latest"
: > "$STATE/callorder.log"
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206b.conf")" egresslock ensure s206b 2>&1)"; e206_rc=$?
if [[ "$e206_rc" == 0 ]] \
   && grep -q '^podman pull docker.io/library/alpine:latest$' "$STATE/callorder.log" \
   && [[ "$(grep -n '^podman pull docker.io/library/alpine:latest$' "$STATE/callorder.log" | head -1 | cut -d: -f1)" \
         -lt "$(grep -n -- '--name egresslock-anchor-s206b' "$STATE/callorder.log" | head -1 | cut -d: -f1)" ]]; then
    e206 pass
else
    e206 fail "D2a fresh-account missing anchor image: pull-then-start green (rc=$e206_rc, out: $e206_out, order: $(tr '\n' '|' < "$STATE/callorder.log" 2>/dev/null | head -c 300))"
fi

# D2a-4 (R-EGL-206-2 #1): missing anchor image whose pull FAILS dies
# named, with no anchor run (fail closed, never a silent run).
ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206b.conf")" egresslock teardown s206b >/dev/null 2>&1 || true
rm -f "$STATE/images/docker.io_library_alpine_latest"
: > "$STATE/pull-fails"
e206_runs_before="$(wc -l < "$STATE/runlog")"
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206b.conf")" egresslock ensure s206b 2>&1)"; e206_rc=$?
e206_runs_after="$(wc -l < "$STATE/runlog")"
if [[ "$e206_rc" != 0 && "$e206_out" == *"pulling it failed"* \
      && "$e206_out" == *"CVE-2026-94603"* ]] \
   && [[ "$e206_runs_after" == "$e206_runs_before" ]]; then
    e206 pass
else
    e206 fail "D2a failed pull on missing anchor image dies named, no run (rc=$e206_rc, out: $e206_out, runlog delta: $((e206_runs_after - e206_runs_before)))"
fi
rm -f "$STATE/pull-fails"

# D2a-5 (R-EGL-206-2 #1): an ANNOTATED image absent from the store is
# pulled first, then refused named — the refusal stays preventative
# even on first-create, with no run of the pulled image.
ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206b.conf")" egresslock teardown s206b >/dev/null 2>&1 || true
rm -f "$STATE/images/docker.io_library_alpine_latest"
: > "$STATE/image-annotated-docker.io_library_alpine_latest"
: > "$STATE/callorder.log"
e206_runs_before="$(wc -l < "$STATE/runlog")"
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206b.conf")" egresslock ensure s206b 2>&1)"; e206_rc=$?
e206_runs_after="$(wc -l < "$STATE/runlog")"
if [[ "$e206_rc" != 0 && "$e206_out" == *"io.podman.annotations.checkpoint.runtime.name"* \
      && "$e206_out" == *"CVE-2026-94603"* ]] \
   && grep -q '^podman pull docker.io/library/alpine:latest$' "$STATE/callorder.log" \
   && [[ "$e206_runs_after" == "$e206_runs_before" ]]; then
    e206 pass
else
    e206 fail "D2a annotated missing image pulled then refused, no run (rc=$e206_rc, out: $e206_out, runlog delta: $((e206_runs_after - e206_runs_before)))"
fi
rm -f "$STATE/image-annotated-docker.io_library_alpine_latest"
# restore the seeded marker the harness (and the D2b cases below) anchor on
: > "$STATE/images/docker.io_library_alpine_latest"

# Clean slate for the D2b cases: green ensure for the gateway profile.
ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206.conf")" egresslock teardown s206 >/dev/null 2>&1 || true
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206.conf")" egresslock ensure s206 2>&1)"; e206_rc=$?
[[ "$e206_rc" == 0 ]] \
    && e206 pass || e206 fail "D2b setup: clean ensure green (rc=$e206_rc, out: $e206_out)"

# D2b-1: live gateway CapEff non-zero fails verify named (no HostConfig
# oracle involved).
: > "$STATE/caps-bad-egresslock-gateway-s206"
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206.conf")" egresslock verify s206 2>&1)"; e206_rc=$?
if [[ "$e206_rc" != 0 && "$e206_out" == *"gateway container 'egresslock-gateway-s206' CapEff"* ]]; then
    e206 pass
else
    e206 fail "D2b gateway CapEff mismatch fails verify named (rc=$e206_rc, out: $e206_out)"
fi
rm -f "$STATE/caps-bad-egresslock-gateway-s206"

# D2b-2: live gateway NoNewPrivs 0 fails verify named.
: > "$STATE/caps-nnp-egresslock-gateway-s206"
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206.conf")" egresslock verify s206 2>&1)"; e206_rc=$?
if [[ "$e206_rc" != 0 && "$e206_out" == *"gateway container 'egresslock-gateway-s206' NoNewPrivs"* ]]; then
    e206 pass
else
    e206 fail "D2b gateway NoNewPrivs mismatch fails verify named (rc=$e206_rc, out: $e206_out)"
fi
rm -f "$STATE/caps-nnp-egresslock-gateway-s206"

# D2b-3: unreadable status fails closed named — on verify…
: > "$STATE/caps-unreadable-egresslock-gateway-s206"
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206.conf")" egresslock verify s206 2>&1)"; e206_rc=$?
if [[ "$e206_rc" != 0 && "$e206_out" == *"hardening state unreadable"* ]]; then
    e206 pass
else
    e206 fail "D2b unreadable status fails verify closed named (rc=$e206_rc, out: $e206_out)"
fi
rm -f "$STATE/caps-unreadable-egresslock-gateway-s206"
# …and on ensure (the start assertion dies named, never a silent pass).
: > "$STATE/caps-unreadable-egresslock-gateway-s206"
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206.conf")" egresslock ensure s206 2>&1)"; e206_rc=$?
if [[ "$e206_rc" != 0 && "$e206_out" == *"hardening state unreadable"* ]]; then
    e206 pass
else
    e206 fail "D2b unreadable status fails ensure closed named (rc=$e206_rc, out: $e206_out)"
fi
rm -f "$STATE/caps-unreadable-egresslock-gateway-s206"

# D2b-4: a mismatched anchor fails BOTH verify verbs (bare profile: the
# anchor is the only kit container).
ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206b.conf")" egresslock teardown s206b >/dev/null 2>&1 || true
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206b.conf")" egresslock ensure s206b 2>&1)"; e206_rc=$?
[[ "$e206_rc" == 0 ]] \
    && e206 pass || e206 fail "D2b setup: bare-profile ensure green (rc=$e206_rc, out: $e206_out)"
: > "$STATE/caps-bad-egresslock-anchor-s206b"
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206b.conf")" egresslock verify s206b 2>&1)"; e206_rc=$?
[[ "$e206_rc" != 0 && "$e206_out" == *"anchor container 'egresslock-anchor-s206b' CapEff"* ]] \
    && e206 pass || e206 fail "D2b anchor mismatch fails plain verify named (rc=$e206_rc, out: $e206_out)"
e206_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206b.conf")" egresslock verify --ensured 2>&1)"; e206_rc=$?
if [[ "$e206_rc" != 0 && "$e206_out" == *"anchor container 'egresslock-anchor-s206b' CapEff"* \
      && "$e206_out" == *"FAILED anchor hardening verification"* ]]; then
    e206 pass
else
    e206 fail "D2b anchor mismatch fails verify --ensured named (rc=$e206_rc, out: $e206_out)"
fi
rm -f "$STATE/caps-bad-egresslock-anchor-s206b"

# D2b-5: converged short-circuit is caps-aware — a converged gateway
# whose live caps went bad is REPLACED (rm+run in the opslog), never
# blessed; with the image fixed, the next ensure is green again.
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206.conf")" egresslock ensure s206 2>&1)"; e206_rc=$?
[[ "$e206_rc" == 0 ]] \
    && e206 pass || e206 fail "D2b setup: ensure green before converged case (rc=$e206_rc, out: $e206_out)"
: > "$STATE/caps-bad-egresslock-gateway-s206"
: > "$STATE/opslog"
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206.conf")" egresslock ensure s206 2>&1)"; e206_rc=$?
if [[ "$e206_rc" != 0 && "$e206_out" == *"gateway container 'egresslock-gateway-s206' CapEff"* ]] \
   && grep -q 'podman rm -f egresslock-gateway-s206' "$STATE/opslog" \
   && grep -q -- '--name egresslock-gateway-s206' "$STATE/opslog"; then
    e206 pass
else
    e206 fail "D2b converged bad-caps gateway replaced, named (rc=$e206_rc, out: $e206_out, ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null | head -c 400))"
fi
rm -f "$STATE/caps-bad-egresslock-gateway-s206"
e206_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206.conf")" egresslock ensure s206 2>&1)"; e206_rc=$?
[[ "$e206_rc" == 0 && "$e206_out" != *"already converged, not restarted"* ]] \
    && e206 pass || e206 fail "D2b ensure green again after the fix (rc=$e206_rc, out: $e206_out)"

ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206.conf")" egresslock teardown s206 >/dev/null 2>&1 || true
ARCMOCK_PASSWD_HOME="$(conf_home "$S206/s206b.conf")" egresslock teardown s206b >/dev/null 2>&1 || true
section_end egl206

# --- EGL-208: assert_kit_caps removes the bad container before dying -------
# The start-path assert (ensure_anchor/ensure_gateway) runs after rt_run
# started a --restart=always container; a bare die used to leave it alive
# — on the gateway, under the live policy's fixed-IP+MAC egress
# exemption. D1: the assert force-removes before dying; D3: the die
# reports the removal outcome (success clause / loud manual-removal
# failure, rc 1 either way); D4/Q2: verify never removes.
section_begin egl208 "EGL-208 assert_kit_caps fail-closed removal"
e208() { assert "$@"; }

S208="$TESTROOT/s208"; rm -rf "$S208"; mkdir -p "$S208"
cat > "$S208/s208.conf" <<'EOF'
profile s208 10.199.100.0/24
    rule gateway-only
    gateway 10.199.100.2 3128 s208-allowlist
EOF
printf '# starter\n' > "$S208/s208-allowlist"
cat > "$S208/s208b.conf" <<'EOF'
profile s208b 10.199.101.0/24
EOF

# EGL-208-1: fresh-start gateway bad caps — the die carries the named
# CapEff problem AND the removal clause; the container is gone
# ($STATE/running/...) and the opslog shows `podman rm -f <gw>` AFTER
# the `--name <gw>` run line (tests/lib.sh's rm/run mirrors; the pre-run
# stale-removal rm sits before the run line — order is the pin).
: > "$STATE/caps-bad-egresslock-gateway-s208"
: > "$STATE/opslog"
e208_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S208/s208.conf")" egresslock ensure s208 2>&1)"; e208_rc=$?
e208_runline="$(grep -n -- '--name egresslock-gateway-s208' "$STATE/opslog" | head -1 | cut -d: -f1)"
e208_rmafter="$(awk -v r="$e208_runline" '$0=="podman rm -f egresslock-gateway-s208"{ if (NR>r) {print NR; exit} }' "$STATE/opslog")"
if [[ "$e208_rc" == 1 && "$e208_out" == *"gateway container 'egresslock-gateway-s208' CapEff"* \
      && "$e208_out" == *"removed container 'egresslock-gateway-s208' (rm -f)"* ]] \
   && [[ -n "$e208_runline" && -n "$e208_rmafter" ]] \
   && [[ ! -f "$STATE/running/egresslock-gateway-s208" ]]; then
    e208 pass
else
    e208 fail "fresh-start bad-caps gateway removed before die (rc=$e208_rc, out: $e208_out, runline=$e208_runline, rmafter=$e208_rmafter, running=$([[ -f "$STATE/running/egresslock-gateway-s208" ]] && echo yes || echo no))"
fi
rm -f "$STATE/caps-bad-egresslock-gateway-s208"

# EGL-208-2: fresh-start anchor bad caps — same shape on the bare
# profile (the anchor start-path case EGL-206's review recorded as
# missing); the anchor dies pre-policy, nothing left running.
: > "$STATE/caps-bad-egresslock-anchor-s208b"
: > "$STATE/opslog"
e208_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S208/s208b.conf")" egresslock ensure s208b 2>&1)"; e208_rc=$?
e208_runline="$(grep -n -- '--name egresslock-anchor-s208b' "$STATE/opslog" | head -1 | cut -d: -f1)"
e208_rmafter="$(awk -v r="$e208_runline" '$0=="podman rm -f egresslock-anchor-s208b"{ if (NR>r) {print NR; exit} }' "$STATE/opslog")"
if [[ "$e208_rc" == 1 && "$e208_out" == *"anchor container 'egresslock-anchor-s208b' CapEff"* \
      && "$e208_out" == *"removed container 'egresslock-anchor-s208b' (rm -f)"* ]] \
   && [[ -n "$e208_runline" && -n "$e208_rmafter" ]] \
   && [[ ! -f "$STATE/running/egresslock-anchor-s208b" ]]; then
    e208 pass
else
    e208 fail "fresh-start bad-caps anchor removed before die (rc=$e208_rc, out: $e208_out, runline=$e208_runline, rmafter=$e208_rmafter, running=$([[ -f "$STATE/running/egresslock-anchor-s208b" ]] && echo yes || echo no))"
fi
rm -f "$STATE/caps-bad-egresslock-anchor-s208b"

# EGL-208-3: removal failure is loud, never "recovered" — rc stays 1,
# the message keeps the named problem + the runtime error + the
# could-not-be-removed warning + the manual `podman rm -f <n>`, and the
# container state is still present (never silently reported removed).
: > "$STATE/caps-bad-egresslock-gateway-s208"
: > "$STATE/rm-container-fails"
e208_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S208/s208.conf")" egresslock ensure s208 2>&1)"; e208_rc=$?
if [[ "$e208_rc" == 1 && "$e208_out" == *"gateway container 'egresslock-gateway-s208' CapEff"* \
      && "$e208_out" == *"removal failed:"* \
      && "$e208_out" == *"could not be removed and may still be running"* \
      && "$e208_out" == *"remove it manually: 'podman rm -f egresslock-gateway-s208'"* ]] \
   && [[ -f "$STATE/running/egresslock-gateway-s208" ]]; then
    e208 pass
else
    e208 fail "removal failure loud with the manual command (rc=$e208_rc, out: $e208_out, running=$([[ -f "$STATE/running/egresslock-gateway-s208" ]] && echo yes || echo no))"
fi
rm -f "$STATE/rm-container-fails" "$STATE/caps-bad-egresslock-gateway-s208"
ARCMOCK_PASSWD_HOME="$(conf_home "$S208/s208.conf")" egresslock teardown s208 >/dev/null 2>&1 || true

# EGL-208-4 (Q2 pin): verify removes nothing — bad caps + a running
# gateway → verify rc 1 naming the state, the container still running
# after, and no rm in the opslog at all.
e208_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S208/s208.conf")" egresslock ensure s208 2>&1)"; e208_rc=$?
[[ "$e208_rc" == 0 ]] \
    && e208 pass || e208 fail "EGL-208 setup: green ensure before the verify pin (rc=$e208_rc, out: $e208_out)"
: > "$STATE/opslog"
: > "$STATE/caps-bad-egresslock-gateway-s208"
e208_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S208/s208.conf")" egresslock verify s208 2>&1)"; e208_rc=$?
if [[ "$e208_rc" == 1 && "$e208_out" == *"verify: gateway container 'egresslock-gateway-s208' CapEff"* ]] \
   && [[ -f "$STATE/running/egresslock-gateway-s208" ]] \
   && ! grep -q '^podman rm' "$STATE/opslog"; then
    e208 pass
else
    e208 fail "verify named the bad caps and removed nothing (rc=$e208_rc, out: $e208_out, running=$([[ -f "$STATE/running/egresslock-gateway-s208" ]] && echo yes || echo no))"
fi
rm -f "$STATE/caps-bad-egresslock-gateway-s208"
ARCMOCK_PASSWD_HOME="$(conf_home "$S208/s208.conf")" egresslock teardown s208 >/dev/null 2>&1 || true
ARCMOCK_PASSWD_HOME="$(conf_home "$S208/s208b.conf")" egresslock teardown s208b >/dev/null 2>&1 || true
section_end egl208

# --- EGL-217: family-wide ensure-failure container cleanup -----------------
# The wait dies and the no-die set -e exits before/outside
# assert_kit_caps used to leave this run's --restart=always container
# behind — on the gateway, running-but-unhealthy under the fixed-IP+MAC
# egress exemption. cmd_ensure arms an EXIT-trap cleanup removing ONLY
# containers this run started/replaced (R1) or restarted via config apply
# (R2); a converged pair on a failing refresh is never touched (EGL-217-6).
# Self-contained section (sibling-file rule: after egl208).
# Mock knobs (tests/lib.sh): run-sick[-<name>] registers but skips
# running/; probe-fails[-<name>] fails from start or config restart (marker
# probe-fails-active-<name>, so a pre-existing healthy gateway answers
# until restart). bin-nosleep no-ops `sleep` (inverse of bin-hang) to keep
# 10s/60s waits cheap.
section_begin egl217 "EGL-217 ensure-failure container cleanup"
e217() { assert "$@"; }

mkdir -p "$TESTROOT/bin-nosleep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTROOT/bin-nosleep/sleep"
chmod +x "$TESTROOT/bin-nosleep/sleep"
E217PATH="$TESTROOT/bin-nosleep:$PATH"

S217="$TESTROOT/s217"; rm -rf "$S217"; mkdir -p "$S217"
cat > "$S217/s217.conf" <<'EOF'
profile s217 10.199.102.0/24
    rule gateway-only
    gateway 10.199.102.2 3128 s217-allowlist
EOF
printf '# starter\n' > "$S217/s217-allowlist"
cat > "$S217/s217b.conf" <<'EOF'
profile s217b 10.199.103.0/24
EOF
cat > "$S217/s217f.conf" <<'EOF'
profile s217f 10.199.104.0/24
    rule allow-host nonexistent.example.test:8080
EOF

# EGL-217-1: anchor wait die — the run registers the anchor (run-sick)
# but it never reports running; the die used to leave the
# --restart=always container behind. Now the EXIT trap removes it: rc 1 +
# named die + the M3 success line, the opslog `podman rm -f` AFTER the
# run line (tests/lib.sh mirrors run and rm; order is the pin), and
# nothing left registered/running.
: > "$STATE/run-sick-egresslock-anchor-s217b"
: > "$STATE/opslog"
e217_out="$(PATH="$E217PATH" ARCMOCK_PASSWD_HOME="$(conf_home "$S217/s217b.conf")" egresslock ensure s217b 2>&1)"; e217_rc=$?
e217_runline="$(grep -n -- '--name egresslock-anchor-s217b' "$STATE/opslog" | head -1 | cut -d: -f1)"
e217_rmafter="$(awk -v r="$e217_runline" '$0=="podman rm -f egresslock-anchor-s217b"{ if (NR>r) {print NR; exit} }' "$STATE/opslog")"
if [[ "$e217_rc" == 1 \
      && "$e217_out" == *"anchor container 'egresslock-anchor-s217b' did not reach running state"* \
      && "$e217_out" == *"removed container 'egresslock-anchor-s217b' (rm -f)"* ]] \
   && [[ -n "$e217_runline" && -n "$e217_rmafter" ]] \
   && [[ ! -f "$STATE/running/egresslock-anchor-s217b" \
      && ! -f "$STATE/containers/egresslock-anchor-s217b.net" ]]; then
    e217 pass
else
    e217 fail "anchor wait die removes the registered container (rc=$e217_rc, out: $e217_out, runline=$e217_runline, rmafter=$e217_rmafter, running=$([[ -f "$STATE/running/egresslock-anchor-s217b" ]] && echo yes || echo no), registered=$([[ -f "$STATE/containers/egresslock-anchor-s217b.net" ]] && echo yes || echo no))"
fi
rm -f "$STATE/run-sick-egresslock-anchor-s217b"

# EGL-217-2: gateway wait die, first create — the gateway is running but
# the proxy never answers (probe-fails; the sharper filed case), the
# 60s-wait die fires, and the trap rolls back the WHOLE family: the
# gateway AND the anchor started by the same run, each with its own M3
# line and its own rm-after-run pin; nothing left registered/running.
: > "$STATE/probe-fails-egresslock-gateway-s217"
: > "$STATE/opslog"
e217_out="$(PATH="$E217PATH" ARCMOCK_PASSWD_HOME="$(conf_home "$S217/s217.conf")" egresslock ensure s217 2>&1)"; e217_rc=$?
e217_gwrun="$(grep -n -- '--name egresslock-gateway-s217' "$STATE/opslog" | head -1 | cut -d: -f1)"
e217_gwrmafter="$(awk -v r="$e217_gwrun" '$0=="podman rm -f egresslock-gateway-s217"{ if (NR>r) {print NR; exit} }' "$STATE/opslog")"
e217_anrun="$(grep -n -- '--name egresslock-anchor-s217' "$STATE/opslog" | head -1 | cut -d: -f1)"
e217_anrmafter="$(awk -v r="$e217_anrun" '$0=="podman rm -f egresslock-anchor-s217"{ if (NR>r) {print NR; exit} }' "$STATE/opslog")"
if [[ "$e217_rc" == 1 \
      && "$e217_out" == *"gateway container 'egresslock-gateway-s217' did not become healthy (proxy not answering on 3128)"* \
      && "$e217_out" == *"removed container 'egresslock-gateway-s217' (rm -f)"* \
      && "$e217_out" == *"removed container 'egresslock-anchor-s217' (rm -f)"* ]] \
   && [[ -n "$e217_gwrun" && -n "$e217_gwrmafter" && -n "$e217_anrun" && -n "$e217_anrmafter" ]] \
   && [[ ! -f "$STATE/running/egresslock-gateway-s217" \
      && ! -f "$STATE/containers/egresslock-gateway-s217.net" \
      && ! -f "$STATE/running/egresslock-anchor-s217" \
      && ! -f "$STATE/containers/egresslock-anchor-s217.net" ]]; then
    e217 pass
else
    e217 fail "gateway wait die rolls back the family (rc=$e217_rc, out: $e217_out, gwrun=$e217_gwrun, gwrmafter=$e217_gwrmafter, anrun=$e217_anrun, anrmafter=$e217_anrmafter, gw_running=$([[ -f "$STATE/running/egresslock-gateway-s217" ]] && echo yes || echo no), an_running=$([[ -f "$STATE/running/egresslock-anchor-s217" ]] && echo yes || echo no))"
fi
rm -f "$STATE/probe-fails-egresslock-gateway-s217"

# EGL-217-3: apply-health die on a PRE-EXISTING converged gateway (R2).
# Seed green, change the allowlist so gw_apply_allowlist restarts, arm
# probe-fails: the gateway answers until the config-activation restart (no
# replace, so NO `podman run`), the post-restart health wait dies, and the
# R2 marker (before restart) removes the broken gateway: rm AFTER
# `podman restart` (tests/lib.sh's restart arm). The anchor was never
# owned and is untouched — the R2-doesn't-touch-anchor boundary.
e217_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S217/s217.conf")" egresslock ensure s217 2>&1)"; e217_rc=$?
[[ "$e217_rc" == 0 ]] \
    && e217 pass || e217 fail "EGL-217 setup: green ensure before the apply-die pin (rc=$e217_rc, out: $e217_out)"
printf 'changed.example.test\n' >> "$S217/s217-allowlist"
: > "$STATE/probe-fails-egresslock-gateway-s217"
: > "$STATE/opslog"
e217_out="$(PATH="$E217PATH" ARCMOCK_PASSWD_HOME="$(conf_home "$S217/s217.conf")" egresslock ensure s217 2>&1)"; e217_rc=$?
e217_restart="$(grep -n '^podman restart' "$STATE/opslog" | head -1 | cut -d: -f1)"
e217_rmafter="$(awk -v r="$e217_restart" '$0=="podman rm -f egresslock-gateway-s217"{ if (NR>r) {print NR; exit} }' "$STATE/opslog")"
e217_gwrun="$(grep -c -- '--name egresslock-gateway-s217' "$STATE/opslog" || true)"
if [[ "$e217_rc" == 1 \
      && "$e217_out" == *"gateway did not come back healthy after config application (fail closed)"* \
      && "$e217_out" == *"removed container 'egresslock-gateway-s217' (rm -f)"* ]] \
   && [[ -n "$e217_restart" && -n "$e217_rmafter" ]] \
   && [[ "$e217_gwrun" == 0 ]] \
   && [[ -f "$STATE/running/egresslock-anchor-s217" ]] \
   && ! grep -q '^podman rm -f egresslock-anchor-s217' "$STATE/opslog"; then
    e217 pass
else
    e217 fail "apply-health die removes the restarted gateway, anchor untouched (rc=$e217_rc, out: $e217_out, restart=$e217_restart, rmafter=$e217_rmafter, gwrun_lines=$e217_gwrun, an_running=$([[ -f "$STATE/running/egresslock-anchor-s217" ]] && echo yes || echo no))"
fi
rm -f "$STATE/probe-fails-egresslock-gateway-s217"

# EGL-217-4: the no-die family case — a first-create ensure whose
# rule-gen fails by rc (unresolvable allow-host -> resolved_dest failure
# -> install_policy rc 1 -> set -e exit; there is NO die site to edit, so
# the A1 per-die alternative cannot pass this). The EXIT trap removes the
# anchor started this run with its M3 line and the rm-after-run pin. The
# rule-gen stderr wording is EGL-120-D1's — deliberately not pinned here.
: > "$STATE/opslog"
e217_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S217/s217f.conf")" egresslock ensure s217f 2>&1)"; e217_rc=$?
e217_runline="$(grep -n -- '--name egresslock-anchor-s217f' "$STATE/opslog" | head -1 | cut -d: -f1)"
e217_rmafter="$(awk -v r="$e217_runline" '$0=="podman rm -f egresslock-anchor-s217f"{ if (NR>r) {print NR; exit} }' "$STATE/opslog")"
if [[ "$e217_rc" == 1 \
      && "$e217_out" == *"removed container 'egresslock-anchor-s217f' (rm -f)"* ]] \
   && [[ -n "$e217_runline" && -n "$e217_rmafter" ]] \
   && [[ ! -f "$STATE/running/egresslock-anchor-s217f" \
      && ! -f "$STATE/containers/egresslock-anchor-s217f.net" ]]; then
    e217 pass
else
    e217 fail "no-die rule-gen exit removes the started anchor (rc=$e217_rc, out: $e217_out, runline=$e217_runline, rmafter=$e217_rmafter, running=$([[ -f "$STATE/running/egresslock-anchor-s217f" ]] && echo yes || echo no))"
fi

# EGL-217-5: removal failure is loud, never "recovered" — the trap's
# rt_rm fails (rm-container-fails, the tests/lib.sh removal-failure
# precedent), rc stays 1 (the trap never alters it), the stderr keeps the
# cleanup clause words + the runtime error + the manual `podman rm -f <n>`,
# and the container state is still present.
: > "$STATE/probe-fails-egresslock-gateway-s217"
: > "$STATE/rm-container-fails"
e217_out="$(PATH="$E217PATH" ARCMOCK_PASSWD_HOME="$(conf_home "$S217/s217.conf")" egresslock ensure s217 2>&1)"; e217_rc=$?
if [[ "$e217_rc" == 1 \
      && "$e217_out" == *"gateway container 'egresslock-gateway-s217' did not become healthy"* \
      && "$e217_out" == *"cleanup: removal failed:"* \
      && "$e217_out" == *"could not be removed and may still be running"* \
      && "$e217_out" == *"remove it manually: 'podman rm -f egresslock-gateway-s217'"* ]] \
   && [[ -f "$STATE/running/egresslock-gateway-s217" ]]; then
    e217 pass
else
    e217 fail "cleanup removal failure loud with the manual command (rc=$e217_rc, out: $e217_out, running=$([[ -f "$STATE/running/egresslock-gateway-s217" ]] && echo yes || echo no))"
fi
rm -f "$STATE/probe-fails-egresslock-gateway-s217" "$STATE/rm-container-fails"

# EGL-217-6: the no-collateral pin (Q5's R1 boundary) — a failing refresh
# on a converged pair removes NOTHING. Green ensure, then add an
# unresolvable allow-host and re-ensure: install_policy rc 1 lands after
# the anchor's converged short-circuit and before any gateway marker, so
# the trap registry is empty — rc 1, no `podman rm`, no `removed
# container`, both containers still registered. The A2 full-sweep
# alternative fails this.
rm -f "$STATE/probe-fails-egresslock-gateway-s217" "$STATE/rm-container-fails"
ARCMOCK_PASSWD_HOME="$(conf_home "$S217/s217.conf")" egresslock teardown s217 >/dev/null 2>&1 || true
e217_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S217/s217.conf")" egresslock ensure s217 2>&1)"; e217_rc=$?
[[ "$e217_rc" == 0 ]] \
    && e217 pass || e217 fail "EGL-217 setup: green ensure before the no-collateral pin (rc=$e217_rc, out: $e217_out)"
: > "$STATE/opslog"
printf '    rule allow-host nonexistent.example.test:8080\n' >> "$S217/s217.conf"
e217_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S217/s217.conf")" egresslock ensure s217 2>&1)"; e217_rc=$?
if [[ "$e217_rc" == 1 \
      && "$e217_out" != *"removed container"* ]] \
   && ! grep -q '^podman rm -f egresslock-anchor-s217' "$STATE/opslog" \
   && ! grep -q '^podman rm -f egresslock-gateway-s217' "$STATE/opslog" \
   && [[ -f "$STATE/running/egresslock-anchor-s217" \
      && -f "$STATE/running/egresslock-gateway-s217" ]]; then
    e217 pass
else
    e217 fail "failing refresh on a converged pair removes nothing (rc=$e217_rc, out: $e217_out, an_running=$([[ -f "$STATE/running/egresslock-anchor-s217" ]] && echo yes || echo no), gw_running=$([[ -f "$STATE/running/egresslock-gateway-s217" ]] && echo yes || echo no))"
fi
ARCMOCK_PASSWD_HOME="$(conf_home "$S217/s217.conf")" egresslock teardown s217 >/dev/null 2>&1 || true
ARCMOCK_PASSWD_HOME="$(conf_home "$S217/s217b.conf")" egresslock teardown s217b >/dev/null 2>&1 || true
ARCMOCK_PASSWD_HOME="$(conf_home "$S217/s217f.conf")" egresslock teardown s217f >/dev/null 2>&1 || true

# EGL-250: the disarm pin — a post-ensure failure in a re-ensure caller
# must not remove owned containers. Stop the anchor so disallow-host's
# re-ensure replaces + marks it; seed a survivor ESTABLISHED tuple and arm
# conntrack-delete-fails so conntrack_flush_and_assert dies: `trap - EXIT`
# (the disarm) leaves rc 1 with NO cleanup. Deleting it makes
# ensure_cleanup remove the marked anchor (R-EGL-217-3 finding 1;
# EGL-242 T2 §10).
S250="$TESTROOT/s250"; rm -rf "$S250"; mkdir -p "$S250"
cat > "$S250/s250.conf" <<'EOF'
profile s250 10.199.106.0/24
    rule allow-host git.example.test:2222
EOF
e250_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S250/s250.conf")" egresslock ensure s250 2>&1)"; e250_rc=$?
[[ "$e250_rc" == 0 ]] \
    && e217 pass || e217 fail "EGL-250 setup: green ensure before the disarm pin (rc=$e250_rc, out: $e250_out)"
# Stop the anchor: registered in the mock store, not running.
rm -f "$STATE/running/egresslock-anchor-s250"
# Survivor tuple for the flushed pin (original direction; mock -L shape)
# + a failed scoped -D so the post-assert still finds it.
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.106.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\n' > "$STATE/nft/conntrack-table"
: > "$STATE/conntrack.log"
: > "$STATE/opslog"
touch "$STATE/nft/conntrack-delete-fails"
e250_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S250/s250.conf")" egresslock disallow-host s250 git.example.test:2222 2>&1)"; e250_rc=$?
rm -f "$STATE/nft/conntrack-delete-fails"
e250_run="$(grep -n -- '--name egresslock-anchor-s250' "$STATE/opslog" | head -1 | cut -d: -f1)"
e250_rmafter="$(awk -v r="$e250_run" '$0=="podman rm -f egresslock-anchor-s250"{ if (NR>r) {print NR; exit} }' "$STATE/opslog")"
if [[ "$e250_rc" == 1 \
      && "$e250_out" == *"still has a live conntrack entry"* \
      && "$e250_out" != *"cleanup:"* \
      && "$e250_out" != *"removed container"* \
      && "$e250_out" != *"removed:"* ]] \
   && grep -qxF 'conntrack -D -p tcp -s 10.199.106.5 --sport 58666 -d 192.0.2.10 --dport 2222' "$STATE/conntrack.log" \
   && [[ -n "$e250_run" && -z "$e250_rmafter" ]] \
   && [[ -f "$STATE/running/egresslock-anchor-s250" \
      && -f "$STATE/containers/egresslock-anchor-s250.net" ]]; then
    e217 pass
else
    e217 fail "post-ensure failure keeps the replaced anchor; disarm held (rc=$e250_rc, out: $e250_out, run=$e250_run, rmafter=$e250_rmafter, running=$([[ -f "$STATE/running/egresslock-anchor-s250" ]] && echo yes || echo no))"
fi
ARCMOCK_PASSWD_HOME="$(conf_home "$S250/s250.conf")" egresslock teardown s250 >/dev/null 2>&1 || true
: > "$STATE/nft/conntrack-table"
section_end egl217

# --- EGL-175: runtime-seam grep-gate (D8/D12, tightened EGL-194-D1) ----
# The contract's acceptance test (internal_docs/RUNTIME_BACKEND_CONTRACT.md):
# after extracting the rt_* adapter bodies, the rest of the engine has zero
# podman command-word invocations. Carve-outs (D8): full-line comments;
# operator remediation strings (podman network rm '$name'|'$net'|'$1'|<name>
# / podman unshare ... nft delete / podman network inspect '<name>'); the
# netns-probe diagnostics (… --rootless-netns true', quote-anchored); doctor
# stdout keys; gw_apply_allowlist die strings; EGL-231 remediation strings
# (podman unshare ... $bin -L / scoped $bin -D, quote-tailed literals).
# Dropped as dead at HEAD (EGL-194): command -v podman (only in
# rt_have_runtime), podman run --network (comment-only), podman system
# migrate (no hit). Residual false negative: a real core invocation
# byte-identical to a carved remediation string is still subtracted. A hit
# fails the battery with the offending lines.
# --- EGL-222: egresslock build-gateway (no-conf rebuild verb) ---------------
# Mock podman `build` records to $STATE/buildlog (tests/lib.sh); -t makes
# the image exist. systemctl mocks active unless systemctl-usermgr-fails.
section_begin egl222 "EGL-222 build-gateway"
a222() { assert "$@"; }

ENG222="$TREE_ROOT/egresslock"
e222d="$STATE/e222"; rm -rf "$e222d"; mkdir -p "$e222d/cwd" "$e222d/confless-cwd"
# Deployed-copy fixture: engine + its neighbor gateway/, like the kit's
# prefix layout (install-kit.sh deploys both side by side). The synthetic
# pin is a fixed 64-hex digest — nothing in the harness reads the real
# one (the mock build never inspects the Containerfile).
E222PIN="sha256:$(printf 'a%.0s' $(seq 1 64))"
E222IMG="localhost/egresslock-gateway:e222"
E222INS="$STATE/image-inspect-$(echo "$E222IMG" | tr '/:' '__')"
e222eng="$e222d/kit"; mkdir -p "$e222eng/gateway"
cp "$ENG222" "$e222eng/egresslock"
printf 'FROM docker.io/library/debian:13-slim@%s\n' "$E222PIN" \
    > "$e222eng/gateway/Containerfile"
e222run() { # e222run <cwd> [args...] — run the fixture engine from cwd
    local cwd="$1"; shift
    (cd "$cwd" && env EGRESSLOCK_GW_IMAGE="$E222IMG" \
        "$e222eng/egresslock" build-gateway "$@" 2>&1)
}
e222pinfix() { # e222pinfix <label-field> — seed the image + its inspect fixture
    : > "$STATE/images/$(echo "$E222IMG" | tr '/:' '__')"
    printf '%s\n' "$1" > "$E222INS"
}
e222clean() { # e222clean — no image, no fixture, empty buildlog
    rm -f "$STATE/images/$(echo "$E222IMG" | tr '/:' '__')" "$E222INS"
    : > "$STATE/buildlog"
}

# 1. Context resolves from the ENGINE's own dir, not CWD: the deployed-copy
#    fixture run from an unrelated cwd names <dir>/gateway in the buildlog.
e222clean
e222o="$(e222run "$e222d/cwd")"; e222_rc=$?
e222bl="$(cat "$STATE/buildlog")"
[[ "$e222_rc" == 0 && "$e222bl" == *"build -t $E222IMG --format docker -f $e222eng/gateway/Containerfile $e222eng/gateway"* \
    && "$e222bl" != *"$TREE_ROOT/gateway"* && "$e222o" == *">> Building $E222IMG FROM aaaaaaaaaaaa"* ]] \
    && a222 pass || a222 fail "context is the engine's neighbor, not CWD (rc=$e222_rc, bl: $e222bl, out: $e222o)"

# 2. Missing image -> build (D2 trigger, never a silent no-op).
e222clean
e222o="$(e222run "$e222d/cwd")"; e222_rc=$?
[[ "$e222_rc" == 0 && -s "$STATE/buildlog" ]] \
    && a222 pass || a222 fail "missing image builds (rc=$e222_rc, out: $e222o)"

# 3. Label != deployed pin -> build.
e222clean
e222pinfix "sha256:$(printf 'b%.0s' $(seq 1 64)) 2026-09-01T00:00:00.000000000Z"
e222o="$(e222run "$e222d/cwd")"; e222_rc=$?
[[ "$e222_rc" == 0 && -s "$STATE/buildlog" ]] \
    && a222 pass || a222 fail "pin-mismatch rebuilds (rc=$e222_rc, out: $e222o)"

# 4. Empty label (the leading-space case + the inspect-answered-nothing
#    case) -> build.
e222clean
e222pinfix " 2026-08-01T00:00:00.000000000Z"
e222o="$(e222run "$e222d/cwd")"; e222_rc=$?
[[ "$e222_rc" == 0 && -s "$STATE/buildlog" ]] \
    && a222 pass || a222 fail "empty base label rebuilds (rc=$e222_rc, out: $e222o)"
e222clean
e222pinfix " 2026-08-01T00:00:00.000000000Z"
: > "$E222INS"   # inspect answers nothing (rc 0, empty) — not comparable
e222o="$(e222run "$e222d/cwd")"; e222_rc=$?
[[ "$e222_rc" == 0 && -s "$STATE/buildlog" ]] \
    && a222 pass || a222 fail "empty inspect output rebuilds (rc=$e222_rc, out: $e222o)"

# 5. Label == deployed pin -> the explicit up-to-date line, rc 0, NO build.
e222clean
e222pinfix "$E222PIN 2026-09-01T00:00:00.000000000Z"
e222o="$(e222run "$e222d/cwd")"; e222_rc=$?
[[ "$e222_rc" == 0 && "$e222o" == "already built from deployed pin aaaaaaaaaaaa — use --force to rebuild" \
    && ! -s "$STATE/buildlog" ]] \
    && a222 pass || a222 fail "equal pin is an explicit up-to-date, not a silent no-op (rc=$e222_rc, out: $e222o)"

# 6. --force on an equal pin -> build (same-pin squid refresh path); the
#    `>> Building … FROM <base>` banner is pinned on the forced path too
#    (R-EGL-270-5 N1 — restores the deleted egl203r F4b banner leg; #1
#    checks the banner on the unforced missing-image path only).
e222o="$(e222run "$e222d/cwd" --force)"; e222_rc=$?
[[ "$e222_rc" == 0 && -s "$STATE/buildlog" \
    && "$e222o" == *">> Building $E222IMG FROM aaaaaaaaaaaa"* ]] \
    && a222 pass || a222 fail "--force rebuilds an equal-pin image + banner (rc=$e222_rc, out: $e222o)"

# 7. The build log pins the D5/D8 flag order: -t first, --format docker
#    between, -f Containerfile, context last.
e222clean
e222o="$(e222run "$e222d/cwd")"; e222_rc=$?
e222bl="$(cat "$STATE/buildlog")"
[[ "$e222bl" == *"--format docker"* && "$e222bl" == *"-t $E222IMG --format docker -f"* ]] \
    && a222 pass || a222 fail "buildlog carries -t first + --format docker (bl: $e222bl)"

# 8. Inactive user@ -> fail closed: rc 1, stderr names user@, no build.
e222clean
touch "$STATE/systemctl-usermgr-fails"
e222o="$(e222run "$e222d/cwd")"; e222_rc=$?
[[ "$e222_rc" == 1 && "$e222o" == *"no systemd user manager for"* && "$e222o" == *"user@"* \
    && ! -s "$STATE/buildlog" ]] \
    && a222 pass || a222 fail "inactive user manager fails closed (rc=$e222_rc, out: $e222o)"
rm -f "$STATE/systemctl-usermgr-fails"

# 9. Root invocation -> rc 1 (require_nonroot; ARC-25 mock id reports 0).
e222o="$(PATH="$TESTROOT/bin-root:$PATH" env \
    EGRESSLOCK_GW_IMAGE="$E222IMG" "$e222eng/egresslock" build-gateway 2>&1)"; e222_rc=$?
[[ "$e222_rc" == 1 && "$e222o" == *"must run as the account, not root"* ]] \
    && a222 pass || a222 fail "root guard (rc=$e222_rc, out: $e222o)"

# 10. Missing context -> rc 1, named (D10 string).
e222nc="$e222d/noctx"; mkdir -p "$e222nc"; cp "$ENG222" "$e222nc/egresslock"
e222o="$(cd "$e222d/cwd" && env EGRESSLOCK_GW_IMAGE="$E222IMG" \
    "$e222nc/egresslock" build-gateway 2>&1)"; e222_rc=$?
[[ "$e222_rc" == 1 && "$e222o" == *"no gateway build context at $e222nc/gateway/Containerfile"* ]] \
    && a222 pass || a222 fail "missing context named rc 1 (rc=$e222_rc, out: $e222o)"

# 11. Unknown/extra args -> usage rc 2.
e222clean
e222o="$(e222run "$e222d/cwd" extra)"; e222_rc=$?
[[ "$e222_rc" == 2 ]] && a222 pass || a222 fail "unknown arg rc 2 (rc=$e222_rc, out: $e222o)"
e222o="$(e222run "$e222d/cwd" --force extra)"; e222_rc=$?
[[ "$e222_rc" == 2 ]] && a222 pass || a222 fail "extra arg after --force rc 2 (rc=$e222_rc, out: $e222o)"

# 12. No conf is loaded (the doctor class): run from a conf-less cwd with
#     EGRESSLOCK_CONF unset — no resolution line, no conf error.
e222o="$(e222run "$e222d/confless-cwd")"; e222_rc=$?
[[ "$e222_rc" == 0 && "$e222o" != *"using config"* && "$e222o" != *"scoped:"* \
    && "$e222o" != *"no profile config"* ]] \
    && a222 pass || a222 fail "no conf resolution for build-gateway (rc=$e222_rc, out: $e222o)"

# 13. The verb is listed on all three usage surfaces (D7).
"$ENG222" --help | grep -q "egresslock build-gateway \[--force\]" \
    && a222 pass || a222 fail "--help lists build-gateway"
"$ENG222" 2>&1 | grep -q "build-gateway" \
    && a222 pass || a222 fail "short usage lists build-gateway"

# 14. R-EGL-222-3 F1: --force must invalidate layer cache (--no-cache);
#     the pin-mismatch/missing-image path must NOT carry it (the moved
#     FROM digest invalidates the layer chain on its own).
e222clean
e222o="$(e222run "$e222d/cwd")"; e222_rc=$?
e222bl="$(cat "$STATE/buildlog")"
[[ "$e222_rc" == 0 && "$e222bl" != *"--no-cache"* ]] \
    && a222 pass || a222 fail "unforced build carries no --no-cache (rc=$e222_rc, bl: $e222bl)"
e222pinfix "$E222PIN 2026-09-01T00:00:00.000000000Z"
: > "$STATE/buildlog"
e222o="$(e222run "$e222d/cwd" --force)"; e222_rc=$?
e222bl="$(cat "$STATE/buildlog")"
[[ "$e222_rc" == 0 && "$e222bl" == *"-t $E222IMG --format docker -f $e222eng/gateway/Containerfile $e222eng/gateway --no-cache"* ]] \
    && a222 pass || a222 fail "forced build carries --no-cache after the context (rc=$e222_rc, bl: $e222bl)"

# 15. R-EGL-222-3 F3 + R-EGL-222-7: a failed build names a retry that can
#     actually retry — --force preserved on the forced path, the actual
#     engine executable (path-invoked; no PATH wrapper assumed), bare on
#     the unforced path.
touch "$STATE/build-fails"
e222o="$(e222run "$e222d/cwd" --force)"; e222_rc=$?
[[ "$e222_rc" == 1 && "$e222o" == *"fix the cause and re-run: EGRESSLOCK_GW_IMAGE=$E222IMG $e222eng/egresslock build-gateway --force"* ]] \
    && a222 pass || a222 fail "failed forced rebuild retries with --force + engine path + override (rc=$e222_rc, out: $e222o)"
e222clean   # missing-image path, still failing builds
e222o="$(e222run "$e222d/cwd")"; e222_rc=$?
[[ "$e222_rc" == 1 && "$e222o" == *"fix the cause and re-run: EGRESSLOCK_GW_IMAGE=$E222IMG $e222eng/egresslock build-gateway"* \
    && "$e222o" != *"build-gateway --force"* ]] \
    && a222 pass || a222 fail "failed unforced rebuild keeps the bare retry (rc=$e222_rc, out: $e222o)"

# 16. R-EGL-222-7: the printed retry, EXECUTED, retries the same target —
#     one-shot custom-tag failures (forced and unforced) must round-trip:
#     extract the retry from stderr, remove the failure marker, run it.
#     The minimal-PATH fixture (no engine wrapper, mock podman, no
#     systemctl) doubles as the no-PATH-wrapper environment.
e222retryof() { sed -n 's/.*fix the cause and re-run: //p' <<<"$1"; }
e222bin="$e222d/bin-nosystemd"; rm -rf "$e222bin"; mkdir -p "$e222bin"
for t in bash id dirname grep head; do ln -s "$(command -v "$t")" "$e222bin/$t"; done
ln -s "$TESTROOT/bin/podman" "$e222bin/podman"
# a) forced one-shot custom-tag failure; the retry runs under a minimal
#    PATH with NO engine wrapper and no EGRESSLOCK_GW_IMAGE in the
#    environment (the retry carries its own assignment).
e222clean
e222o="$(cd "$e222d/cwd" && env EGRESSLOCK_GW_IMAGE=localhost/custom-gw:v2 \
    "$e222eng/egresslock" build-gateway --force 2>&1)"; e222_rc=$?
[[ "$e222_rc" == 1 && -n "$(e222retryof "$e222o")" ]] \
    && a222 pass || a222 fail "forced custom-tag failure produces a retry (rc=$e222_rc, out: $e222o)"
e222retry="$(e222retryof "$e222o")"
rm -f "$STATE/build-fails"; : > "$STATE/buildlog"
e222o="$(env -u EGRESSLOCK_GW_IMAGE PATH="$e222bin" bash -c "$e222retry" 2>&1)"; e222_rc=$?
e222bl="$(cat "$STATE/buildlog")"
[[ "$e222_rc" == 0 && "$e222bl" == *"build -t localhost/custom-gw:v2 --format docker -f $e222eng/gateway/Containerfile"* ]] \
    && a222 pass || a222 fail "executed forced retry rebuilds the CUSTOM tag without a PATH wrapper (rc=$e222_rc, bl: $e222bl, out: $e222o)"
# b) unforced one-shot custom-tag failure -> same round trip, no --force.
e222clean
touch "$STATE/build-fails"
e222o="$(cd "$e222d/cwd" && env EGRESSLOCK_GW_IMAGE=localhost/custom-gw:v2 \
    "$e222eng/egresslock" build-gateway 2>&1)"; e222_rc=$?
e222retry="$(e222retryof "$e222o")"
[[ "$e222_rc" == 1 && "$e222retry" != *"--force" ]] \
    && a222 pass || a222 fail "unforced custom-tag failure retry has no --force (rc=$e222_rc, retry: $e222retry)"
e222o="$(bash -c "$e222retry" 2>&1)"; e222_rc=$?   # still failing
rm -f "$STATE/build-fails"; : > "$STATE/buildlog"
e222o="$(bash -c "$e222retry" 2>&1)"; e222_rc=$?
e222bl="$(cat "$STATE/buildlog")"
[[ "$e222_rc" == 0 && "$e222bl" == *"build -t localhost/custom-gw:v2"* ]] \
    && a222 pass || a222 fail "executed unforced retry rebuilds the CUSTOM tag (rc=$e222_rc, bl: $e222bl, out: $e222o)"
# c) shell-safe quoting: an override with a space survives %q and the
#    executed retry still builds that exact (space-containing) tag.
e222clean
touch "$STATE/build-fails"
e222o="$(cd "$e222d/cwd" && env EGRESSLOCK_GW_IMAGE='localhost/custom gw:v2' \
    "$e222eng/egresslock" build-gateway --force 2>&1)"; e222_rc=$?
e222retry="$(e222retryof "$e222o")"
rm -f "$STATE/build-fails"; : > "$STATE/buildlog"
e222o="$(bash -c "$e222retry" 2>&1)"; e222_rc=$?
e222bl="$(cat "$STATE/buildlog")"
[[ "$e222_rc" == 0 && "$e222bl" == *"build -t localhost/custom gw:v2 --format docker"* ]] \
    && a222 pass || a222 fail "quoted override survives the printed retry (rc=$e222_rc, bl: $e222bl, out: $e222o)"
rm -f "$STATE/build-fails"

# 17. Permanent contract case (R-EGL-222-3 first-pass note): systemctl
#     ABSENT -> the preflight proceeds to the build (the engine carries
#     no systemd dependency). Minimal PATH with the mock podman but no
#     systemctl (the $e222bin fixture above).
e222clean
e222o="$(cd "$e222d/cwd" && env PATH="$e222bin" \
    EGRESSLOCK_GW_IMAGE="$E222IMG" "$e222eng/egresslock" build-gateway 2>&1)"; e222_rc=$?
[[ "$e222_rc" == 0 && -s "$STATE/buildlog" && "$e222o" == *">> Building"* ]] \
    && a222 pass || a222 fail "absent systemctl proceeds to the build (rc=$e222_rc, out: $e222o)"

section_end egl222

# --- EGL-223: ensure --replace-gateway (explicit replace even when healthy)
# D1: the flag forces the existing replace path; plain ensure stays
# byte-identical (EGL-114 pins green unmodified — R6 exact). D2: both flag
# positions legal; unknown flags rc 2; non-gateway profile rc 2; mutators
# never pass it. D3: preflight — missing/checkpoint-annotated target image
# dies named BEFORE any rt_rm, so the gateway stays up and is never owned
# by the EGL-217 trap.
# EGL-270 (P4): whole-section window wrap. R-EGL-270-5 F1 unregistered
# egl223 (security-classed: EGL-223-D9 anchor retention + EGL-206
# checkpoint refusal), so this guard is currently inert. Registration stays
# the single membership control (tests/lib.sh _slow_sections); a
# re-registration skips the body with skip() (G4); section lines stay
# byte-identical.
if slow_section_run egl223; then
section_begin egl223 "EGL-223 ensure --replace-gateway"
a223() { assert "$@"; }

S223="$TESTROOT/s223"; rm -rf "$S223"; mkdir -p "$S223"
: > "$STATE/images/localhost_egresslock-gateway_latest"
cat > "$S223/s223.conf" <<'EOF'
profile s223 10.199.97.0/24
    rule gateway-only
    gateway 10.199.97.2 3128 s223-allowlist
EOF
printf 'git.example.test\n' > "$S223/s223-allowlist"
cat > "$S223/s223ng.conf" <<'EOF'
profile s223ng 10.199.97.16/28
EOF
run223() { env ARCMOCK_PASSWD_HOME="$(conf_home "$S223/s223.conf")" HOME="$S223" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

# Healthy seed (unasserted setup — a broken seed surfaces in
# e223-plain-converged's fail line). After this the gateway is running +
# probe + MAC + caps green: exactly the state plain ensure must skip.
o="$(run223 ensure s223 2>&1)"

# e223-plain-converged: healthy gateway, no flag → the converged skip
# line, and NO rm/run of the gateway (EGL-114 R6 unchanged by the flag).
: > "$STATE/opslog"
o="$(run223 ensure s223 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"gateway 'egresslock-gateway-s223' ready (already converged, not restarted)"* \
      && "$o" != *"replacing the running container"* ]] \
   && ! grep -qE '^podman rm .* egresslock-gateway-s223' "$STATE/opslog" \
   && ! grep -qE '^podman run .*--name egresslock-gateway-s223' "$STATE/opslog"; then
    a223 pass
else
    a223 fail "plain converged ensure skips (rc=$rc, out: $o, ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi

# e223-flag-replaces: healthy gateway + --replace-gateway (flag before
# profile) → rm + run of the gateway, the exact stderr disclosure, and
# the applied/verified ready line (a replace applies — not the skip line).
: > "$STATE/opslog"
o="$(run223 ensure --replace-gateway s223 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"gateway 'egresslock-gateway-s223' --replace-gateway — replacing the running container (profile sessions will drop)"* \
      && "$o" == *"gateway 'egresslock-gateway-s223' ready (allowlist applied, health verified)"* \
      && "$o" != *"already converged"* ]] \
   && grep -q '^podman rm -f egresslock-gateway-s223$' "$STATE/opslog" \
   && grep -qE '^podman run .*--name egresslock-gateway-s223' "$STATE/opslog"; then
    a223 pass
else
    a223 fail "flag replaces healthy gateway (rc=$rc, out: $o, ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi

# e223-flag-after-profile: the flag AFTER the profile is the same replace
# (D2: both positions legal). The post-replace state is converged again,
# so this run replaces a healthy gateway too.
: > "$STATE/opslog"
o="$(run223 ensure s223 --replace-gateway 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"--replace-gateway — replacing the running container"* \
      && "$o" == *"ready (allowlist applied, health verified)"* ]] \
   && grep -q '^podman rm -f egresslock-gateway-s223$' "$STATE/opslog" \
   && grep -qE '^podman run .*--name egresslock-gateway-s223' "$STATE/opslog"; then
    a223 pass
else
    a223 fail "flag after profile replaces too (rc=$rc, out: $o, ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi

# e223-flag-before-profile-conf: no EGRESSLOCK_CONF — the named probe
# must load <profile>.conf (the flag must not reach resolve_conf_for as
# the profile name; the resolution line names it) and the replace still
# happens (EGL-223 dispatch pin).
mkdir -p "$S223/.config/egresslock"
cp "$S223/s223.conf" "$S223/.config/egresslock/s223.conf"
printf 'git.example.test\n' > "$S223/.config/egresslock/s223-allowlist"
o="$(env HOME="$S223" ARCMOCK_PASSWD_HOME="$S223" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure --replace-gateway s223 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"using config $S223/.config/egresslock/s223.conf"* \
      && "$o" == *"--replace-gateway — replacing the running container"* \
      && "$o" == *"ready (allowlist applied, health verified)"* ]] \
   && grep -q '^podman rm -f egresslock-gateway-s223$' "$STATE/opslog"; then
    a223 pass
else
    a223 fail "flag-before-profile resolves the profile conf + replaces (rc=$rc, out: $o)"
fi
: > "$STATE/opslog"

# e223-missing-tag-intact: flag + missing target image → the D3
# preflight dies named BEFORE any removal; the running gateway is intact
# and un-owned (no cleanup line, no rm of it in opslog).
rm -f "$STATE/images/localhost_egresslock-gateway_latest"
o="$(run223 ensure --replace-gateway s223 2>&1)"; rc=$?
if [[ "$rc" == 1 \
      && "$o" == *"gateway image localhost/egresslock-gateway:latest not found; build it: egresslock build-gateway"* \
      && "$o" != *"removed container"* ]] \
   && [[ -f "$STATE/running/egresslock-gateway-s223" ]] \
   && ! grep -qE '^podman rm .* egresslock-gateway-s223' "$STATE/opslog"; then
    a223 pass
else
    a223 fail "missing tag dies before rm, gateway intact (rc=$rc, out: $o, running=$([[ -f "$STATE/running/egresslock-gateway-s223" ]] && echo yes || echo no))"
fi
: > "$STATE/images/localhost_egresslock-gateway_latest"

# e223-checkpoint-intact: flag + checkpoint-annotated target → the
# EGL-206 refusal dies BEFORE any gateway rm; gateway still running.
: > "$STATE/image-annotated-localhost_egresslock-gateway_latest"
o="$(run223 ensure --replace-gateway s223 2>&1)"; rc=$?
rm -f "$STATE/image-annotated-localhost_egresslock-gateway_latest"
if [[ "$rc" == 1 \
      && "$o" == *"io.podman.annotations.checkpoint.runtime.name"* \
      && "$o" != *"removed container"* ]] \
   && [[ -f "$STATE/running/egresslock-gateway-s223" ]] \
   && ! grep -qE '^podman rm .* egresslock-gateway-s223' "$STATE/opslog"; then
    a223 pass
else
    a223 fail "checkpoint-poisoned tag dies before rm, gateway intact (rc=$rc, out: $o, running=$([[ -f "$STATE/running/egresslock-gateway-s223" ]] && echo yes || echo no))"
fi

# e223-non-gateway-rc2: the flag on a profile with no gateway line →
# named rc 2 and no container change (opslog untouched by the invocation).
o="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S223/s223ng.conf")" HOME="$S223" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure --replace-gateway s223ng 2>&1)"; rc=$?
if [[ "$rc" == 2 \
      && "$o" == *"--replace-gateway requires a gateway profile (no gateway line in this conf)"* ]] \
   && ! grep -qE '^podman rm .* s223ng' "$STATE/opslog"; then
    a223 pass
else
    a223 fail "non-gateway flag rc 2 (rc=$rc, out: $o)"
fi

# e223-unknown-flag-rc2: an unknown ensure flag is a usage error —
# named line + the flag-shaped usage line, rc 2.
o="$(run223 ensure --bogus s223 2>&1)"; rc=$?
if [[ "$rc" == 2 && "$o" == *"Error: ensure takes --replace-gateway only."* \
      && "$o" == *"usage: egresslock ensure [--replace-gateway] <profile>"* ]]; then
    a223 pass
else
    a223 fail "unknown flag rc 2 (rc=$rc, out: $o)"
fi

# e223-mutator-no-flag: allow on a healthy gateway (after the mock
# rebuild above) never inherits the flag — the mutator apply may
# restart, but there is NO gateway rm/run (no replace).
: > "$STATE/opslog"
o="$(run223 allow s223 cache.example.test 2>&1)"; rc=$?
if [[ "$rc" == 0 ]] \
   && ! grep -qE '^podman rm .* egresslock-gateway-s223' "$STATE/opslog" \
   && ! grep -qE '^podman run .*--name egresslock-gateway-s223' "$STATE/opslog" \
   && [[ -f "$STATE/running/egresslock-gateway-s223" ]]; then
    a223 pass
else
    a223 fail "mutator never inherits the flag (rc=$rc, out: $o, ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi

# e223-dup-flag-rc2 (EGL-223-D8): a duplicate --replace-gateway is an
# argv-contract usage error (rc 2, named "only once") — nothing
# container-touching happens, and the resolver's one-leading-flag skip
# stays singular (no silent main.conf fallback line in the resolution
# output; explicit EGRESSLOCK_CONF is the only source named).
: > "$STATE/opslog"
o="$(run223 ensure --replace-gateway --replace-gateway s223 2>&1)"; rc=$?
if [[ "$rc" == 2 \
      && "$o" == *"Error: ensure takes --replace-gateway only once."* \
      && "$o" == *"usage: egresslock ensure [--replace-gateway] <profile>"* \
      && "$o" != *"named fallback"* ]] \
   && ! grep -qE '^podman (rm|run) .*egresslock-gateway-s223' "$STATE/opslog"; then
    a223 pass
else
    a223 fail "dup flag rc 2, no container work (rc=$rc, out: $o, ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi

# R-EGL-223-3 F2 fold pin: a leading empty-string argument is again a
# usage rc 2 (the D2 parser may not accept "" as elidable the way the
# first cut did).
o="$(run223 ensure "" s223 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: ensure takes one profile name."* ]] \
    && a223 pass || a223 fail "empty-string arg rc 2 (rc=$rc, out: $o)"

# e223-start-fail-keeps-anchor (EGL-223-D9): a gw_start failure dies
# named and KEEPS the anchor holder — the ARC-5 anchor recycle block is
# gone (it never recreated holder/policy; supplementary S2). opslog has
# no rm of the anchor; the anchor is still running after the failure.
# (The foreign IPAM holder makes every gateway start fail with the
# named IPAM-conflict line — the same fixture the ARC-5 on-host shape
# showed.)
: > "$STATE/opslog"
printf 'other\n' > "$STATE/ips/10.199.97.2"
o="$(run223 ensure --replace-gateway s223 2>&1)"; rc=$?
if [[ "$rc" == 1 \
      && "$o" == *"Error: gateway start failed (static IP 10.199.97.2 conflict?)"* ]] \
   && ! grep -qE '^podman rm .* egresslock-anchor-s223' "$STATE/opslog" \
   && [[ -f "$STATE/running/egresslock-anchor-s223" ]]; then
    a223 pass
else
    a223 fail "start failure keeps the anchor (rc=$rc, out: $o, anchor=$([[ -f "$STATE/running/egresslock-anchor-s223" ]] && echo up || echo down))"
fi
# Leave the section converged again (same no-teardown leave-behind the
# rest of the section has): free the foreign holder and re-converge.
rm -f "$STATE/ips/10.199.97.2"
o="$(run223 ensure s223 2>&1)"

section_end egl223
fi # EGL-270: slow_section_run egl223

# --- EGL-97: conmon-wedged containers no longer block one ensure pass
# A rootless-runtime kill leaves podman's failed `rm -f` stopped-but-
# registered, so one swallowed rm used to block the recreate (first ensure
# rc 125; a second pass converged). rt_rm_retry retries while the name
# stays registered (3 attempts); one pass converges.
# Assert 1: stale anchor wedge — exactly two rm ops (knob-fail + retry).
# Assert 2: gateway replace-wedge — three rm ops (retry pair + gw_start's
# clearing rm; the mock succeeds against a gone name).
section_begin egl97 "EGL-97 rm retry converges one ensure pass"
a97() { assert "$@"; }

S97="$TESTROOT/s97"; rm -rf "$S97"; mkdir -p "$S97"
: > "$STATE/images/localhost_egresslock-gateway_latest"
cat > "$S97/s97.conf" <<'EOF'
profile s97 10.199.107.0/24
    rule gateway-only
    gateway 10.199.107.2 3128 s97-allowlist
EOF
printf 'git.example.test\n' > "$S97/s97-allowlist"
run97() { env ARCMOCK_PASSWD_HOME="$(conf_home "$S97/s97.conf")" HOME="$S97" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

# Healthy seed (unasserted — assert 2 starts from the healthy pair
# assert 1 reconverged, so no second seed is needed).
o="$(run97 ensure s97 2>&1)"

# e97-anchor-stale-wedge: a stale anchor whose rm is conmon-wedged no
# longer fails the pass — the retry removes it and the ensure converges:
# rc 0, exactly two rm ops (the wedged attempt + the retry), no libpod
# error text in the output, anchor running again.
: > "$STATE/opslog"
rm -f "$STATE/running/egresslock-anchor-s97"
: > "$STATE/rm-wedged-egresslock-anchor-s97"
o="$(run97 ensure s97 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$(grep -c '^podman rm -f egresslock-anchor-s97$' "$STATE/opslog")" == 2 \
      && "$o" != *"conmon exited prematurely"* ]] \
   && [[ -f "$STATE/running/egresslock-anchor-s97" ]]; then
    a97 pass
else
    a97 fail "stale-wedged anchor converges in one pass (rc=$rc, rms: $(grep -c '^podman rm -f egresslock-anchor-s97$' "$STATE/opslog" 2>/dev/null), out: $o)"
fi

# e97-gateway-replace-wedge: --replace-gateway with the wedged knob on
# the gateway — the retry pair clears the stale registration, then
# gw_start's clearing rm succeeds against the already-removed name:
# three gateway rm ops, rc 0, no libpod error text, gateway running.
: > "$STATE/opslog"
: > "$STATE/rm-wedged-egresslock-gateway-s97"
o="$(run97 ensure --replace-gateway s97 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$(grep -c '^podman rm -f egresslock-gateway-s97$' "$STATE/opslog")" == 3 \
      && "$o" != *"conmon exited prematurely"* ]] \
   && [[ -f "$STATE/running/egresslock-gateway-s97" ]]; then
    a97 pass
else
    a97 fail "replace-wedged gateway converges in one pass (rc=$rc, rms: $(grep -c '^podman rm -f egresslock-gateway-s97$' "$STATE/opslog" 2>/dev/null), out: $o)"
fi

section_end egl97

section_begin egl228 "EGL-228 argv shape before config load"
a228() { assert "$@"; }
E228="$TESTROOT/e228"; mkdir -p "$E228/.config/egresslock"
printf 'profile main 10.89.0.0/24\n    frobnicate yes\n' > "$E228/.config/egresslock/main.conf"
printf 'profile ng 10.89.1.0/24\n' > "$E228/ng.conf"
E228EMPTY="$TESTROOT/e228-empty"; rm -rf "$E228EMPTY"; mkdir -p "$E228EMPTY"
e228miss() { # e228miss <args...> — missing profile conf (empty confdir)
    env ARCMOCK_PASSWD_HOME="$E228EMPTY" HOME="$E228EMPTY" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        egresslock "$@" 2>&1
}
e228mal() { # e228mal <args...> — malformed profile conf
    env ARCMOCK_PASSWD_HOME="$E228" HOME="$E228" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        egresslock "$@" 2>&1
}
e228home() { # e228home <args...> — empty confdir
    env HOME="$E228EMPTY" ARCMOCK_PASSWD_HOME="$E228EMPTY" \
        EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@" 2>&1
}

# e228-dup-flag-missing-conf
o="$(e228miss ensure --replace-gateway --replace-gateway main)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: ensure takes --replace-gateway only once."* \
   && "$o" == *"usage: egresslock ensure [--replace-gateway] <profile>"* \
   && "$o" != *"config file not found"* ]] && a228 pass \
   || a228 fail "dup + missing conf (rc=$rc, out: $o)"

# e228-dup-flag-malformed-conf
o="$(e228mal ensure --replace-gateway --replace-gateway main)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: ensure takes --replace-gateway only once."* \
   && "$o" != *"unknown directive"* ]] && a228 pass \
   || a228 fail "dup + malformed conf (rc=$rc, out: $o)"

# e228-dup-flag-unreadable-conf
chmod 000 "$E228/.config/egresslock/main.conf"
o="$(e228mal ensure --replace-gateway --replace-gateway main)"; rc=$?
chmod 644 "$E228/.config/egresslock/main.conf"
[[ "$rc" == 2 && "$o" == *"Error: ensure takes --replace-gateway only once."* \
   && "$o" != *"Permission denied"* ]] && a228 pass \
   || a228 fail "dup + unreadable conf (rc=$rc, out: $o)"

# e228-unknown-flag-missing-conf
o="$(e228miss ensure --bogus main)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: ensure takes --replace-gateway only."* \
   && "$o" != *"config file not found"* ]] && a228 pass \
   || a228 fail "unknown flag + missing conf (rc=$rc, out: $o)"

# e228-network-extra-missing-conf
o="$(e228miss network p extra)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: network takes no extra arguments."* \
   && "$o" != *"config file not found"* && "$o" != *"no profile config"* ]] \
   && a228 pass || a228 fail "network extra + missing conf (rc=$rc, out: $o)"

# e228-allow-bad-entry-missing-conf
o="$(e228miss allow main 1.2.3.4)"; rc=$?
[[ "$rc" == 2 && "$o" == *"IPv4 literal"* && "$o" != *"config file not found"* ]] \
   && a228 pass || a228 fail "allow literal + missing conf (rc=$rc, out: $o)"

# e228-verify-ensured-extra-missing-conf
o="$(e228miss verify --ensured p)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: verify --ensured takes no profile argument."* \
   && "$o" != *"config file not found"* ]] \
   && a228 pass || a228 fail "verify --ensured extra + missing conf (rc=$rc, out: $o)"

# e228-bare-teardown-no-conf
o="$(e228home teardown)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: teardown requires an argument."* \
   && "$o" != *"no profile config"* ]] && a228 pass \
   || a228 fail "bare teardown + empty confdir (rc=$rc, out: $o)"

# e228-nongw-shape-wins (D8)
o="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E228/ng.conf")" HOME="$E228" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow ng 1.2.3.4 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"IPv4 literal"* \
   && "$o" != *"has no gateway"* ]] && a228 pass \
   || a228 fail "nongw shape wins (rc=$rc, out: $o)"

# e228-usage-no-disclosure (D4)
o="$(e228mal ensure --bogus main)"; rc=$?
[[ "$rc" == 2 && "$o" != *"scoped:"* && "$o" != *"using config"* ]] \
   && a228 pass || a228 fail "usage-invalid has no disclosure (rc=$rc, out: $o)"

# e228-valid-argv-config-error
o="$(e228mal ensure main)"; rc=$?
[[ "$rc" == 2 && "$o" == *"unknown directive"* ]] && a228 pass \
   || a228 fail "valid argv still config-errors (rc=$rc, out: $o)"

# e228-valid-argv-no-conf
o="$(e228home ensure main)"; rc=$?
[[ "$rc" == 2 && "$o" == *"no profile config"* ]] && a228 pass \
   || a228 fail "valid argv + empty confdir (rc=$rc, out: $o)"

section_end egl228

# --- EGL-203 (R-EGL-203-6 F1/F2): the page recipe, composed -----------------
# Recipe-level checks run against the page's exact lines. F1: a failed
# build leaves the replacement uninvoked (recipe `&&` + build-gateway exit
# 1) — an un-gated replace would drop the profile's sessions while
# re-installing the same old base. F2: replacement is profile-scoped — a
# second gateway profile keeps its container and plain ensure stays
# converged (the doctor's staleness row inspects the IMAGE, not running
# containers, so absent `stale:` is not rollout verification).
# Mock limitation: no image IDs, so old-image retention is established by
# the engine's image-agnostic converge predicate, not container identity.
# EGL-270 (P4): whole-section window wrap. egl203r is the round-1 member
# (non-security recipe composition); it consumes egl223's seeded fixture,
# which now always runs (security-classed, R-EGL-270-5 F1).
if slow_section_run egl203r; then
section_begin egl203r "EGL-203 F1/F2: page recipe composed"
e203r() { assert "$@"; }

# Reuses egl223's seeded fixture: s223's gateway is running healthy
# (the section left it converged) and the default image is in the store.
r203run() { # r203run <recipe-line> — the env'd composed-recipe invocation
    env ARCMOCK_PASSWD_HOME="$(conf_home "$S223/s223.conf")" HOME="$S223" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        bash -c "$1" 2>&1
}

# F1a. Failed build: rc 1, NOTHING container-touching — opslog stays
#      empty and the healthy gateway keeps running (no rm/run).
touch "$STATE/build-fails"
: > "$STATE/opslog"
o="$(r203run 'egresslock build-gateway && egresslock ensure --replace-gateway s223')"; rc=$?
if [[ "$rc" == 1 && "$o" == *"gateway image build failed"* ]] \
   && ! grep -qE '^podman (rm|run) .*egresslock-gateway-s223' "$STATE/opslog" \
   && [[ -f "$STATE/running/egresslock-gateway-s223" ]]; then
    e203r pass
else
    e203r fail "F1: failed build gates the replace (rc=$rc, ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi
rm -f "$STATE/build-fails"

# F1b. The gate passes a good build through: the same composed line
#      replaces (rm + run) — the recipe's `&&` is a gate, not a no-op.
: > "$STATE/opslog"
o="$(r203run 'egresslock build-gateway && egresslock ensure --replace-gateway s223')"; rc=$?
if [[ "$rc" == 0 && "$o" == *"--replace-gateway — replacing the running container"* ]] \
   && grep -q '^podman rm -f egresslock-gateway-s223$' "$STATE/opslog" \
   && grep -qE '^podman run .*--name egresslock-gateway-s223' "$STATE/opslog"; then
    e203r pass
else
    e203r fail "F1: good build passes the gate and replaces (rc=$rc, ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi

# F4 (R-EGL-203-8) legs deleted per EGL-270 P3 (candidate 2): F4a/F4b
# re-pinned egl222's build-gateway contract — exact `>> Building $IMG FROM
# <base>` stdout, unchanged-pin no-op, --force rebuild, --no-cache — the same
# properties. F1a/F1b (`&&` gate legs) and F2 stay for unique page
# composition coverage.

# F2. Two gateway profiles, both seeded healthy: replace ONE — the other
#     profile's container is untouched (its rollout step is a separate,
#     still-owed `--replace-gateway`), and plain ensure of it stays
#     converged on the old image (no image compare in the converge
#     predicate). EGL-323: one profile per conf — each profile gets its
#     own conf file (the one-per-conf rule; same fixture coverage).
cat > "$S223/s223a.conf" <<'EOF'
profile s223a 10.199.98.0/24
    rule gateway-only
    gateway 10.199.98.2 3128 s223a-allowlist
EOF
cat > "$S223/s223b.conf" <<'EOF'
profile s223b 10.199.99.0/24
    rule gateway-only
    gateway 10.199.99.2 3128 s223b-allowlist
EOF
printf 'git.example.test\n' > "$S223/s223a-allowlist"
printf 'git.example.test\n' > "$S223/s223b-allowlist"
run2g() { # run2g <verb> [...flags] <profile> — conf picked by the profile arg
    env ARCMOCK_PASSWD_HOME="$(conf_home "$S223/${@: -1}.conf")" HOME="$S223" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"
}
o="$(run2g ensure s223a 2>&1)"; rcA=$?
o="$(run2g ensure s223b 2>&1)"; rcB=$?
[[ "$rcA" == 0 && "$rcB" == 0 && -f "$STATE/running/egresslock-gateway-s223a" \
    && -f "$STATE/running/egresslock-gateway-s223b" ]] \
    && e203r pass || e203r fail "F2 seed: both profiles ensured (a rc=$rcA, b rc=$rcB)"
: > "$STATE/opslog"
o="$(run2g ensure --replace-gateway s223a 2>&1)"; rc=$?
if [[ "$rc" == 0 ]] \
   && grep -qE '^podman (rm|run) .*egresslock-gateway-s223a' "$STATE/opslog" \
   && ! grep -qE '^podman (rm|run) .*egresslock-gateway-s223b' "$STATE/opslog" \
   && [[ -f "$STATE/running/egresslock-gateway-s223b" ]]; then
    e203r pass
else
    e203r fail "F2: replace is profile-scoped, s223b untouched (rc=$rc, ops: $(tr '\n' '|' < "$STATE/opslog" 2>/dev/null))"
fi
# The un-replaced profile stays converged on the old image: plain ensure
# does not compare image identity — this is why "absence of `stale:`" and
# "no doctor complaint" are NOT rollout verification.
: > "$STATE/opslog"
o="$(run2g ensure s223b 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"already converged, not restarted"* ]] \
   && ! grep -qE '^podman (rm|run) .*egresslock-gateway-s223b' "$STATE/opslog"; then
    e203r pass
else
    e203r fail "F2: plain ensure of the un-replaced profile stays converged (rc=$rc, out: $o)"
fi
# Leave-behind: free the two-profile state so later sections see no
# holder state (same no-teardown leave-behind hygiene as egl223).
# EGL-323: teardown is conf-scoped, so each profile is freed through
# its own conf (`teardown all` would only see the loaded conf's one).
o="$(run2g teardown s223a 2>&1)"; rc=$?
o="$(run2g teardown s223b 2>&1)"; rc=$?

section_end egl203r
fi # EGL-270: slow_section_run egl203r

section_begin egl175 "EGL-175 runtime seam"
a175() { assert "$@"; }

ENG175="$TREE_ROOT/egresslock"

egl175_seam_hits() { # egl175_seam_hits <file> — remaining podman command-word hits; empty = pass
  awk '
      /^rt_[a-z0-9_]+\(\)/ { in_rt=1 }
      in_rt && /^\}/ { in_rt=0; next }
      in_rt { next }
      { print }
  ' "$1" \
    | grep -vE "^[[:space:]]*#" \
    | grep -vE "podman network rm ('[$]name'|'[$]net'|'[$]1'|<name>)" \
    | grep -vE "podman unshare --rootless-netns nft delete" \
    | grep -vE "podman unshare --rootless-netns true'" \
    | grep -vE 'podman unshare --rootless-netns \$bin -L -p tcp' \
    | grep -vE 'podman unshare --rootless-netns \$bin -D -p tcp' \
    | grep -vE "podman network inspect '" \
    | grep -vE "\(podman (MISSING|NetworkBackend)" \
    | grep -vE "\(podman cp;" \
    | grep -nE '(^|[[:space:]`$(])podman([[:space:]|&;<>]|$)' || true
}
egl175_cap_flags() { # egl175_cap_flags <file> — rt_capabilities heredoc body (no EOF markers)
  awk '/^rt_capabilities\(\)/{p=1} p && /<<'\''EOF'\''/{p=2; next} p==2 && /^EOF$/{exit} p==2{print}' "$1"
}

# D3: the frozen rt_* primitive vocabulary is present (the closed adapter
# set the gate reasons about).
missing175=""
for p in rt_unshare rt_image_exists rt_image_inspect rt_image_pull \
         rt_image_build \
         rt_network_ls \
         rt_network_inspect rt_network_create rt_network_rm rt_ps rt_run \
         rt_rm rt_exec rt_cp rt_restart rt_inspect rt_info rt_version \
         rt_have_runtime rt_capabilities; do
    grep -qE "^${p}\(\)" "$ENG175" || missing175="$missing175 $p"
done
[[ -z "$missing175" ]] \
    && a175 pass || a175 fail "rt_* primitive vocabulary incomplete:$missing175"

# EGL-194-D4: rt_capabilities' heredoc body is pinned to exactly the four
# contract lines in contract order — extra, missing, renamed, or
# reordered capability flags fail (existence alone still lets
# rt_capabilities answer the wrong flags).
cap_want=$'stable-shared-netns\nrootless\nns-join\ninspect'
cap_got="$(egl175_cap_flags "$ENG175")"
[[ "$cap_got" == "$cap_want" ]] \
    && a175 pass || a175 fail "rt_capabilities flags drifted: $(printf %q "$cap_got")"

# D8/D12: zero podman invocations outside rt_* bodies (carve-outs applied).
# The awk state machine ends an rt_* body at the first column-0 '}'; every
# rt_* function is written multi-line so that anchor is exact.
gate175="$(egl175_seam_hits "$ENG175")"
[[ -z "$gate175" ]] \
    && a175 pass || a175 fail "podman invocation outside rt_* (EGL-175 gate):
$gate175"

# Negative control (EGL-194-D3): a bare network-rm outside rt_* is flagged.
_plant="$STATE/e175-plant"
cp "$ENG175" "$_plant"
printf '\n    podman network rm foo\n' >> "$_plant"
_hits="$(egl175_seam_hits "$_plant")"
[[ -n "$_hits" && "$_hits" == *"podman network rm foo"* ]] \
    && a175 pass || a175 fail "EGL-194 plant 'podman network rm foo' not flagged: $_hits"
rm -f "$_plant"

# Negative control: mutating a contract flag fails the content pin.
_cap="$STATE/e175-cap"
cp "$ENG175" "$_cap"
awk '
  /^rt_capabilities\(\)/ { p=1 }
  p && /<<'\''EOF'\''/ { p=2; print; next }
  p==2 && /^EOF$/ { p=0; print; next }
  p==2 && /^inspect$/ { print "inspectX"; next }
  { print }
' "$_cap" > "$_cap.m" && mv "$_cap.m" "$_cap"
_mut="$(egl175_cap_flags "$_cap")"
[[ "$_mut" != "$cap_want" ]] \
    && a175 pass || a175 fail "EGL-194 cap mutation not caught (got: $(printf %q "$_mut"))"
rm -f "$_cap"

section_end egl175

# --- EGL-283: verify names an exec/container failure, not a config
# failure ----------------------------------------------------------------
section_begin egl283 "EGL-283 verify exec-failure naming"
e283() { assert "$@"; }

S283="$TESTROOT/s283"; rm -rf "$S283"; mkdir -p "$S283"
cat > "$S283/s283.conf" <<'EOF'
profile s283 10.199.102.0/24
    rule gateway-only
    gateway 10.199.102.2 3128 s283-allowlist
EOF
printf '# starter\n' > "$S283/s283-allowlist"
e283_gw="egresslock-gateway-s283"

e283_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S283/s283.conf")" egresslock ensure s283 2>&1)"; e283_rc=$?
[[ "$e283_rc" == 0 ]] \
    && e283 pass || e283 fail "EGL-283 setup: green ensure (rc=$e283_rc, out: $e283_out)"

# 1. Genuine parse rejection: squid ran, rc 1 — its error is surfaced.
: > "$STATE/allowlist-invalid"
e283_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S283/s283.conf")" egresslock verify s283 2>&1)"; e283_rc=$?
if [[ "$e283_rc" == 1 && "$e283_out" == *"verify: gateway squid config invalid: mock squid: config invalid"* ]]; then
    e283 pass
else
    e283 fail "EGL-283 parse rejection surfaced (rc=$e283_rc, out: $e283_out)"
fi
rm -f "$STATE/allowlist-invalid"

# 2. Exec/container failure (rc 125) while the container lists as
# running -> distinct name, no config claim, podman detail surfaced,
# rc still 1 (fail closed). Per-container knob: the anchor's caps read
# is untouched.
: > "$STATE/exec-fails-$e283_gw"
e283_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S283/s283.conf")" egresslock verify s283 2>&1)"; e283_rc=$?
if [[ "$e283_rc" == 1 \
      && "$e283_out" == *"verify: gateway container '$e283_gw' not exec-able"* \
      && "$e283_out" == *"container state improper"* \
      && "$e283_out" != *"squid config invalid"* ]]; then
    e283 pass
else
    e283 fail "EGL-283 exec failure named, config claim absent (rc=$e283_rc, out: $e283_out)"
fi
rm -f "$STATE/exec-fails-$e283_gw"

# 3. verify removes nothing (drift signal, EGL-208 Q2 family pin).
[[ -f "$STATE/running/$e283_gw" ]] && e283 pass || e283 fail "EGL-283 verify removed the container"
ARCMOCK_PASSWD_HOME="$(conf_home "$S283/s283.conf")" egresslock teardown s283 >/dev/null 2>&1 || true
section_end egl283

# --- EGL-227: account lock — contention, release, re-entrancy -------------
section_begin egl227 "EGL-227 account lock serialization"
e227() { assert "$@"; }

S227="$TESTROOT/s227"; rm -rf "$S227"; mkdir -p "$S227"
rm -f "$STATE/egl227-fd9-leak"
cat > "$S227/s227.conf" <<'EOF'
profile s227 10.199.103.0/24
    rule gateway-only
    gateway 10.199.103.2 3128 s227-allowlist
EOF
printf '# starter\n' > "$S227/s227-allowlist"
# EGL-325: the conf's directory is the account confdir, so the account
# home (and therefore the lock path) is the synthetic passwd home.
E227HOME="$(conf_home "$S227/s227.conf")"
rm -rf "$E227HOME/.local/state"
e227_lock="$E227HOME/.local/state/egresslock/engine.lock"

# 1. Read-only verbs take no lock and create no lock file.
ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S227/s227.conf")" egresslock list >/dev/null 2>&1
[[ ! -e "$e227_lock" ]] && e227 pass || e227 fail "EGL-227 list created the lock file"

# 2. A green ensure takes and releases the lock (kernel release on exit).
e227_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S227/s227.conf")" egresslock ensure s227 2>&1)"; e227_rc=$?
[[ "$e227_rc" == 0 ]] && e227 pass || e227 fail "EGL-227 setup ensure (rc=$e227_rc, out: $e227_out)"
exec 8>>"$e227_lock"
if flock -n 8; then e227 pass; else e227 fail "EGL-227 lock not free after a green ensure"; fi
flock -u 8

# 2b. D10 pin: the container-starting spawns (rt_run -> mock podman run;
#     rt_restart -> mock podman restart, hit by this first-create apply)
#     must not leak the lock fd into the child — a conmon grandchild
#     holding fd 9 would keep the lock past the engine's exit and lock
#     the account out.
[[ ! -e "$STATE/egl227-fd9-leak" ]] && e227 pass || e227 fail "EGL-227 container child inherited fd 9 (the lock would outlive the engine)"

# 2c. D11 pin: the exclusive holder truncates the record — one line per
#     holder, not an append-only file growing ~1.4 MB/year/account.
[[ "$(wc -l < "$e227_lock" 2>/dev/null || echo 0)" == "1" ]] \
    && e227 pass || e227 fail "EGL-227 holder record not truncated per exclusive acquire (lines: $(wc -l < "$e227_lock" 2>/dev/null || echo 0))"

# 2d. F1 identity/refusal: the account home comes from the account
#     database, and when it answers nothing a lock-taker fails closed
#     with S1 — verify included (it takes the shared lock). A read-only
#     verb takes no lock, but since EGL-325 its CONFDIR also comes from
#     that account-database home, so it fails closed named rather than
#     guessing a directory ($HOME is never consulted).
e227_out="$(ARCMOCK_PASSWD_MISSING=1 ARCMOCK_PASSWD_HOME="$(conf_home "$S227/s227.conf")" egresslock ensure s227 2>&1)"; e227_rc=$?
[[ "$e227_rc" == 1 && "$e227_out" == *"cannot resolve the account home for the account lock"* ]] \
    && e227 pass || e227 fail "EGL-227 unresolved account home fails closed named (rc=$e227_rc, out: $e227_out)"
e227_out="$(ARCMOCK_PASSWD_MISSING=1 ARCMOCK_PASSWD_HOME="$(conf_home "$S227/s227.conf")" egresslock verify s227 2>&1)"; e227_rc=$?
[[ "$e227_rc" == 1 && "$e227_out" == *"cannot resolve the account home for the account lock"* ]] \
    && e227 pass || e227 fail "EGL-227 verify needs the account home too (rc=$e227_rc, out: $e227_out)"
e227_out="$(ARCMOCK_PASSWD_MISSING=1 ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S227/s227.conf")" egresslock list 2>&1)"; e227_rc=$?
[[ "$e227_rc" == 1 && "$e227_out" == *"cannot resolve the account home for the config directory"* \
   && "$e227_out" != *"another egresslock command is running"* ]] \
    && e227 pass || e227 fail "EGL-227 read-only verb needs no LOCK but its confdir needs the account home (rc=$e227_rc, out: $e227_out)"

# 3. Writer contention: an exclusive holder (this shell) + wait 0 -> the
#    named fail-closed line, the holder record carried, nothing changed.
flock -x 8
printf 'pid=%s mode=write started=%s\n' 99999 "2026-01-01T00:00:00-07:00" >&8
e227_out="$(EGRESSLOCK_LOCK_WAIT=0 ARCMOCK_PASSWD_HOME="$(conf_home "$S227/s227.conf")" egresslock allow s227 blocked.example.test:8080 2>&1)"; e227_rc=$?
if [[ "$e227_rc" == 1 \
      && "$e227_out" == *"another egresslock command is running for this account"* \
      && "$e227_out" == *"holder: pid=99999"* \
      && "$e227_out" != *"added: blocked.example.test:8080"* ]] \
      && ! grep -qxF "blocked.example.test:8080" "$S227/s227-allowlist"; then
    e227 pass
else
    e227 fail "EGL-227 writer contention named + untouched (rc=$e227_rc, out: $e227_out)"
fi

# 3b. F1: the lock identity is the account home from the account
#     database, not $HOME — a command started with an alternate HOME
#     still contends on the same lock, and no lock file appears under
#     the alternate HOME.
e227_alt="$S227/home-alt"; mkdir -p "$e227_alt"
e227_out="$(EGRESSLOCK_LOCK_WAIT=0 env HOME="$e227_alt" ARCMOCK_PASSWD_HOME="$(conf_home "$S227/s227.conf")" egresslock ensure s227 2>&1)"; e227_rc=$?
if [[ "$e227_rc" == 1 \
      && "$e227_out" == *"another egresslock command is running for this account"* \
      && ! -e "$e227_alt/.local/state/egresslock/engine.lock" ]]; then
    e227 pass
else
    e227 fail "EGL-227 alternate HOME shares the account lock (rc=$e227_rc, out: $e227_out)"
fi

# 4. The conf-less recovery path serializes too (lock before load_config).
e227_out="$(EGRESSLOCK_LOCK_WAIT=0 env HOME="$HOME" ARCMOCK_PASSWD_HOME="$E227HOME" egresslock teardown --runtime 2>&1)"; e227_rc=$?
[[ "$e227_rc" == 1 && "$e227_out" == *"another egresslock command is running for this account"* ]] \
    && e227 pass || e227 fail "EGL-227 teardown --runtime contention (rc=$e227_rc, out: $e227_out)"

# 5. Re-entrancy: the mutator's in-process ensure must not re-acquire
#    (wait 0 would deadlock a double acquire).
flock -u 8
e227_out="$(EGRESSLOCK_LOCK_WAIT=0 ARCMOCK_PASSWD_HOME="$(conf_home "$S227/s227.conf")" egresslock allow s227 ok.example.test:8080 2>&1)"; e227_rc=$?
[[ "$e227_rc" == 0 && "$e227_out" == *"added: ok.example.test:8080"* ]] \
    && e227 pass || e227 fail "EGL-227 re-entrancy: mutator re-ensure deadlocked (rc=$e227_rc, out: $e227_out)"

# 5b. D11 sensitivity pin (R-EGL-227-2 F1): leg 2's record + leg 3's fake
#     holder line are in the file by now, so leg 5's second exclusive
#     acquire leaves exactly one line only if the holder truncates — leg
#     2c's fresh-file count passes with or without the truncate and cannot
#     distinguish it (mutation M3 proved exactly that).
[[ "$(wc -l < "$e227_lock" 2>/dev/null || echo 0)" == "1" ]] \
    && e227 pass || e227 fail "EGL-227 holder record not truncated by a second exclusive acquire (lines: $(wc -l < "$e227_lock" 2>/dev/null || echo 0))"

# 5c. F1 (green direction): on a free lock, the alternate-HOME command
#     takes and releases the canonical lock; nothing is created under the
#     alternate HOME.
e227_out="$(env HOME="$e227_alt" ARCMOCK_PASSWD_HOME="$(conf_home "$S227/s227.conf")" egresslock allow s227 alt.example.test:8080 2>&1)"; e227_rc=$?
if [[ "$e227_rc" == 0 && "$e227_out" == *"added: alt.example.test:8080"* \
      && -f "$e227_lock" && ! -e "$e227_alt/.local/state" ]]; then
    e227 pass
else
    e227 fail "EGL-227 alternate HOME uses the canonical lock (rc=$e227_rc, out: $e227_out)"
fi

# 6. Shared readers degrade, writers still exclude them: verify proceeds
#    under an exclusive holder (rc follows policy state, here 0) ...
flock -x 8
e227_out="$(EGRESSLOCK_LOCK_WAIT=0 ARCMOCK_PASSWD_HOME="$(conf_home "$S227/s227.conf")" egresslock verify s227 2>&1)"; e227_rc=$?
[[ "$e227_rc" == 0 ]] && e227 pass || e227 fail "EGL-227 verify under exclusive holder (rc=$e227_rc, out: $e227_out)"
flock -u 8
# ... and an exclusive writer is refused while a shared holder is active.
flock -s 8
e227_out="$(EGRESSLOCK_LOCK_WAIT=0 ARCMOCK_PASSWD_HOME="$(conf_home "$S227/s227.conf")" egresslock ensure s227 2>&1)"; e227_rc=$?
[[ "$e227_rc" == 1 && "$e227_out" == *"another egresslock command is running for this account"* ]] \
    && e227 pass || e227 fail "EGL-227 writer excludes a shared holder (rc=$e227_rc, out: $e227_out)"
flock -u 8; exec 8>&-

# 7. A malformed wait override fails closed, named.
e227_out="$(EGRESSLOCK_LOCK_WAIT=abc ARCMOCK_PASSWD_HOME="$(conf_home "$S227/s227.conf")" egresslock ensure s227 2>&1)"; e227_rc=$?
[[ "$e227_rc" == 1 && "$e227_out" == *"EGRESSLOCK_LOCK_WAIT must be a non-negative integer"* ]] \
    && e227 pass || e227 fail "EGL-227 invalid wait override (rc=$e227_rc, out: $e227_out)"
ARCMOCK_PASSWD_HOME="$(conf_home "$S227/s227.conf")" egresslock teardown s227 >/dev/null 2>&1 || true
section_end egl227

# --- EGL-100: torn conf pair / generation error shape --------------------
section_begin egl100 "EGL-100 torn conf pair / generation error shape"
e100() { assert "$@"; }

S100="$TESTROOT/s100"; rm -rf "$S100"; mkdir -p "$S100"
mkdir -p "$STATE/ips" "$STATE/containers"
cat > "$S100/s100.conf" <<'EOF'
profile s100 10.199.101.0/24
    rule gateway-only
    gateway 10.199.101.2 3128 s100-allowlist
EOF

# 1. Missing allowlist: ONE named line with the allow/disallow fix
#    shape; the old mislabelling outer line is gone; rc 1 (fail closed).
e100_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S100/s100.conf")" egresslock ensure s100 2>&1)"; e100_rc=$?
if [[ "$e100_rc" == 1 \
      && "$e100_out" == *"Error: allowlist file missing: "*"/s100-allowlist (check the profile's 'gateway' directive)"* \
      && "$e100_out" != *"invalid entries"* ]]; then
    e100 pass
else
    e100 fail "missing allowlist = one named line (rc=$e100_rc, out: $e100_out)"
fi
# 2. Fail closed: the failed ensure's own containers are gone (EGL-217).
if [[ ! -e "$STATE/running/egresslock-anchor-s100" \
      && ! -e "$STATE/running/egresslock-gateway-s100" ]]; then
    e100 pass
else
    e100 fail "failed ensure left kit containers behind"
fi
# 3. Invalid entry: the inner named line only — no second
#    "generation failed" stack line.
printf '!!!garbage\n' > "$S100/s100-allowlist"
e100_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S100/s100.conf")" egresslock ensure s100 2>&1)"; e100_rc=$?
if [[ "$e100_rc" == 1 \
      && "$e100_out" == *"invalid allowlist entry '!!!garbage'"* \
      && "$e100_out" != *"generation failed"* ]]; then
    e100 pass
else
    e100 fail "invalid entry = one named line, no stack (rc=$e100_rc, out: $e100_out)"
fi
# 4. Success path unchanged: a valid allowlist still applies, rc 0.
printf 'git.example.test:443\n' > "$S100/s100-allowlist"
e100_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S100/s100.conf")" egresslock ensure s100 2>&1)"; e100_rc=$?
[[ "$e100_rc" == 0 && "$e100_out" == *"allowlist applied"* ]] \
    && e100 pass || e100 fail "valid allowlist baseline green (rc=$e100_rc)"
ARCMOCK_PASSWD_HOME="$(conf_home "$S100/s100.conf")" egresslock teardown s100 >/dev/null 2>&1 || true
section_end egl100

# --- EGL-259: denied counts squid's CONNECT-abort denies ------------------
# Squid logs client-close-race CONNECT denies as TCP_DENIED_ABORTED/403
# (EGL-211 R-EGL-211-2). The parser must count them (entries + the
# had-denied window note) while non-deny *_ABORTED codes stay excluded.
section_begin egl259 "EGL-259 denied _ABORTED"
a259() { assert "$@"; }

S259="$TESTROOT/h259"; rm -rf "$S259"; mkdir -p "$S259"
cat > "$S259/gw.conf" <<'EOF'
profile gw 10.199.88.0/24
    rule gateway-only
    gateway 10.199.88.2 3128 gw-allowlist
EOF
: > "$S259/gw-allowlist"
: > "$STATE/running/egresslock-gateway-gw"
cat > "$STATE/containers-egresslock-gateway-gw.access.log" <<EOF
$(date +%s).000    120 10.199.88.5 TCP_DENIED_ABORTED/403 0 CONNECT aborted.example.test:443 - HIER_NONE/- -
$(date +%s).000    120 10.199.88.5 TCP_DENIED_ABORTED/403 3454 GET http://aborted-http.example.test/ - HIER_NONE/- text/html
$(date +%s).000    120 10.199.88.5 TCP_MISS_ABORTED/200 3454 GET http://notdenied.example.test/x - HIER_NONE/- text/html
EOF

# 1. both _ABORTED deny entries are listed (CONNECT bare host; GET host:80);
#    a non-deny *_ABORTED row stays excluded.
d259_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S259/gw.conf")" egresslock denied gw 2>&1)"; d259_rc=$?
if [[ "$d259_rc" == 0 && "$d259_out" == *"aborted.example.test"* \
      && "$d259_out" == *"aborted-http.example.test:80"* \
      && "$d259_out" != *"notdenied.example.test"* ]]; then
    a259 pass
else
    a259 fail "D1 _ABORTED denials listed, non-deny _ABORTED excluded (rc=$d259_rc, out: $d259_out)"
fi

# 2. had_denied must count _ABORTED too: an old-only _ABORTED log with the
#    default window prints the window note (was silent before EGL-259);
#    --days 0 lists the entry. Both rc 0.
cat > "$STATE/containers-egresslock-gateway-gw.access.log" <<EOF
$(( $(date +%s) - 15 * 86400 )).000    120 10.199.88.5 TCP_DENIED_ABORTED/403 0 CONNECT stale-abort.example.test:443 - HIER_NONE/- -
EOF
w259_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S259/gw.conf")" egresslock denied gw 2>&1)"; w259_rc=$?
if [[ "$w259_rc" == 0 \
      && "$w259_out" == *"note: no denials in the last 14 days (older entries exist; denied <profile> --days 0)"* \
      && "$w259_out" != *"stale-abort.example.test"* ]]; then
    a259 pass
else
    a259 fail "D2 window note fires for _ABORTED-only log (rc=$w259_rc, out: $w259_out)"
fi
z259_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S259/gw.conf")" egresslock denied gw --days 0 2>&1)"; z259_rc=$?
[[ "$z259_rc" == 0 && "$z259_out" == *"stale-abort.example.test"* ]] \
    && a259 pass || a259 fail "D2 --days 0 lists the old _ABORTED deny (rc=$z259_rc, out: $z259_out)"

section_end egl259

# --- EGL-286: concise --help summary + per-command help topics -------------
# The summary is the new top-level --help (index + pointer); per-command
# pages and the config/env reference live on `egresslock help <topic>`
# (17 command topics + config + env). Contract: --help == bare help ==
# plain -h byte-identical; trailing tokens after --help are ignored
# (kept from the old header dump); help is config-free (no resolution
# line) and root-safe; error/unknown surfaces exit 2.
section_begin egl286 "EGL-286 help summary + help topics"
e286() { assert "$@"; }

# 1. The three summary aliases are byte-identical.
diff <(env egresslock --help 2>&1) <(env egresslock help 2>&1) >/dev/null \
    && e286 pass || e286 fail "--help and help differ"
diff <(env egresslock -h 2>&1) <(env egresslock --help 2>&1) >/dev/null \
    && e286 pass || e286 fail "-h and --help differ"

# 2. --help keeps its trailing-tokens-ignored contract.
t286_out="$(env egresslock --help anything 2>&1)"; t286_rc=$?
diff <(printf '%s\n' "$t286_out") <(env egresslock --help 2>&1) >/dev/null && t286_ok=1 || t286_ok=0
[[ "$t286_rc" == 0 && "$t286_ok" == 1 ]] \
    && e286 pass || e286 fail "--help ignores trailing tokens (rc=$t286_rc)"

# 3. Every topic (17 commands + config + env) exits 0 with a non-empty page.
for t in ensure verify network proxy-env rules allowlist denied allow disallow \
         allow-host disallow-host drop-unauthorized init list doctor build-gateway teardown config env; do
    p286_out="$(env egresslock help "$t" 2>&1)"; p286_rc=$?
    if [[ "$p286_rc" == 0 && -n "$p286_out" ]]; then
        e286 pass
    else
        e286 fail "help $t (rc=$p286_rc)"
    fi
done

# 4. Every summary index line matches "^  <command> ...desc>" — a
#    missing/empty CMD_INDEX entry prints a bare or absent line.
s286_out="$(env egresslock --help 2>&1)"
s286_ok=1
for c in ensure verify network proxy-env rules allowlist denied allow disallow \
         allow-host disallow-host drop-unauthorized init list doctor build-gateway teardown; do
    [[ "$(grep -cE "^  egresslock $c .+" <<<"$s286_out")" == 1 ]] || s286_ok=0
done
# exactly 17 command index lines + the --help/--version footer lines
# (the two-space Usage body line "  egresslock <command> ..." must NOT
# be counted — index lines never start with '<' or a literal '[')
[[ "$(grep -cE '^  egresslock [^<[]' <<<"$s286_out")" == 19 ]] || s286_ok=0
[[ "$s286_ok" == 1 ]] \
    && e286 pass || e286 fail "summary index incomplete or misformatted"

# 5. Unknown topic: rc 2, names the topic, prints short usage.
u286_out="$(env egresslock help bogus-topic 2>&1)"; u286_rc=$?
[[ "$u286_rc" == 2 && "$u286_out" == *"unknown help topic 'bogus-topic'".* \
    && "$u286_out" == *"commands:"* ]] \
    && e286 pass || e286 fail "unknown help topic rc=2 (rc=$u286_rc, out: $u286_out)"

# 6. Extra argument: rc 2 with the exact message.
m286_out="$(env egresslock help a b 2>&1)"; m286_rc=$?
[[ "$m286_rc" == 2 && "$m286_out" == *"egresslock help takes at most one topic".* ]] \
    && e286 pass || e286 fail "help with two topics rc=2 (rc=$m286_rc, out: $m286_out)"
m286b_out="$(env egresslock help --help 2>&1)"; m286b_rc=$?
[[ "$m286b_rc" == 2 && "$m286b_out" == *"unknown help topic"* ]] \
    && e286 pass || e286 fail "help --help is an unknown topic (rc=$m286b_rc, out: $m286b_out)"

# 7. Config-free: no conf resolution line on stderr (the resolution line
#    is stderr-only by ARC-24), even with a loadable confdir; the
#    stdout/stderr split keeps the checks-block text in help config (it
#    quotes the resolution-line forms) from tripping the pin.
c286_err="$(env egresslock help ensure 2>&1 >/dev/null)"
[[ -z "$c286_err" ]] \
    && e286 pass || e286 fail "help ensure conf-free (err: $c286_err)"
c286b_rc=0
c286b_err="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/validconf/v.conf")" egresslock help config 2>&1 >/dev/null)" || c286b_rc=$?
[[ "$c286b_rc" == 0 && -z "$c286b_err" ]] \
    && e286 pass || e286 fail "help config never resolves a conf (rc=$c286b_rc, err: $c286b_err)"

# 8. Error paths print the summary, not the 139-line dump. The removed
#    --config selector is rejected through the short-usage path.
e286d="$(egresslock --config list 2>&1)"; e286rc=$?
[[ "$e286rc" == 2 && "$(wc -l <<<"$e286d" | tr -d ' ')" -lt 40 \
   && "$e286d" == *"--config has been removed"* ]] \
    && e286 pass || e286 fail "--config rejection prints the summary (rc=$e286rc)"

section_end egl286

results_emit extra
results_emit arc11
results_emit arc12
echo "RESULTS (ARC-14 site defaults): $arc14_pass passed, $arc14_fail failed"
results_emit arc16
results_emit arc20
results_emit arc25
results_emit arc26
results_emit arc49
results_emit arc24
results_emit arc35
results_emit arc30
results_emit arc46
results_emit arc_b2
results_emit arc37
results_emit arc38
results_emit arc31
results_emit arc41
results_emit arc42
results_emit arc43
results_emit arc44
results_emit egl246
results_emit arc50
results_emit arc56
results_emit arc58
results_emit arc51
results_emit arc59
results_emit arc57
results_emit egl18
results_emit arc60
results_emit arc32
results_emit arc66
results_emit arc67
results_emit arc71
results_emit arc69
results_emit egl31
results_emit egl45
results_emit egl226
results_emit egl59
results_emit deep
results_emit egl55
results_emit egl66
results_emit egl117
results_emit egl114
results_emit egl116
results_emit egl120
results_emit egl141
results_emit egl146
results_emit egl147
results_emit egl139
results_emit egl305
results_emit egl317
results_emit egl318
results_emit egl222
results_emit egl223
results_emit egl228
results_emit egl97
results_emit egl203r
echo "RESULTS (EGL-140 pin record witness): $egl140_pass passed, $egl140_fail failed"
results_emit egl175
results_emit egl208
results_emit egl217
results_emit egl202
results_emit arc91
results_emit egl206
results_emit egl283
results_emit egl227
results_emit egl100
results_emit egl259
results_emit egl286
# EGL-184: the hand-maintained 52-term sums are replaced by the register:
# counted snapshots plus the declared arc14 external (own counters via the
# untouched a14 delegate, EGL-179-D3). Fail-closed completeness per
# EGL-184-D4; the TOTAL line keeps the EGL-99 skip count + tree-shape tag.
results_total "$arc14_pass" "$arc14_fail"
[[ "$total_fail" -eq 0 ]]
