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
# EGL-392: proxy `allow` now rewrites only an existing regular 0600
# source. Test fixtures are created under an owner-only umask so an
# ordinary fixture is rewrite-eligible; legs that pin the 0644/0444/
# symlink refusal set that shape explicitly.
umask 077
# EGL-346: the account the engine runs as — the scope named by the
# verify-surface ensure hints.
ENSURE_ACCT="$(id -un)"

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
printf 'profile v 10.50.9.0/24\n    gateway 10.50.9.2 3128 v-allowlist\n' > "$TESTROOT/validconf/v.conf"
: > "$TESTROOT/validconf/v-allowlist"
check "fixed confdir list works" 0 env ARCMOCK_PASSWD_HOME="$(conf_home_ro "$TESTROOT/validconf/v.conf")" \
    egresslock list

# EGL-325 / EGL-385: --config is rejected; EGRESSLOCK_CONF is retired and
# only warns, never used.
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
# EGL-385: a set EGRESSLOCK_CONF is retired, not a usage error — it warns
# on stderr, is never read, and the command continues with the same
# outcome as the unset control (rc, stdout, resolution line).
sel_home="$(conf_home_ro "$TESTROOT/validconf/v.conf")"
sel_out="$(env EGRESSLOCK_CONF="$TESTROOT/validconf/v.conf" ARCMOCK_PASSWD_HOME="$sel_home" egresslock list 2>$TESTROOT/agent385a.err)"; sel_rc=$?
ctl_out="$(env ARCMOCK_PASSWD_HOME="$sel_home" egresslock list 2>$TESTROOT/agent385a-ctl.err)"; ctl_rc=$?
if [[ "$sel_rc" == "$ctl_rc" && "$sel_out" == "$ctl_out" \
      && "$sel_out" == *"egresslock-v"* \
      && "$(cat $TESTROOT/agent385a.err)" == *"Warning: EGRESSLOCK_CONF is retired and is no longer read."* \
      && "$(cat $TESTROOT/agent385a.err)" == *"$(cat $TESTROOT/agent385a-ctl.err)"* ]]; then
    _sect_bump pass; echo "PASS: EGRESSLOCK_CONF warns and continues (removed selector)"
else
    _sect_bump fail; echo "FAIL: EGRESSLOCK_CONF warn-plus-continue (rc=$sel_rc/$ctl_rc, out: $sel_out)"
fi
# EGL-385: no command-class exceptions — --version prints the version at
# rc 0 and the warning on stderr (the no-env --version leg in arc20 stays
# silent).
ctl_out="$(egresslock --version 2>$TESTROOT/agent385v-ctl.err)"; ctl_rc=$?
sel_out="$(env EGRESSLOCK_CONF="$TESTROOT/validconf/v.conf" egresslock --version 2>$TESTROOT/agent385v.err)"; sel_rc=$?
if [[ "$sel_rc" == "$ctl_rc" && "$sel_out" == "$ctl_out" \
      && "$(cat $TESTROOT/agent385v.err)" == *"Warning: EGRESSLOCK_CONF is retired and is no longer read."* \
      && "$(cat $TESTROOT/agent385v-ctl.err)" != *"Warning: EGRESSLOCK_CONF"* ]]; then
    _sect_bump pass; echo "PASS: EGRESSLOCK_CONF warns before --version"
else
    _sect_bump fail; echo "FAIL: EGRESSLOCK_CONF --version scope (rc=$sel_rc, out: $sel_out)"
fi
# EGL-385: --config keeps precedence — its argv scan runs first, so the
# env warning is not printed on that path.
sel_out="$(env EGRESSLOCK_CONF="$TESTROOT/validconf/v.conf" egresslock --config "$TESTROOT/validconf/v.conf" list 2>&1)"; sel_rc=$?
if [[ "$sel_rc" == 2 && "$sel_out" == *"--config has been removed"* \
      && "$sel_out" != *"Warning: EGRESSLOCK_CONF"* ]]; then
    _sect_bump pass; echo "PASS: --config wins when both removed selectors are present"
else
    _sect_bump fail; echo "FAIL: both-present precedence (rc=$sel_rc, out: $sel_out)"
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
printf 'profile ok 10.51.0.0/24\n    gateway 10.51.0.2 3128 ok-allowlist\n' > "$A323/.config/egresslock/ok.conf"
: > "$A323/.config/egresslock/ok-allowlist"
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
printf 'profile a 10.50.0.0/24\n    gateway 10.50.0.2 3128 a-allowlist\n' > "$TESTROOT/badconf/a.conf"
: > "$TESTROOT/badconf/a-allowlist"
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
    gateway 10.77.0.2 3128 ov-allowlist
EOF
: > "$A11/ov-allowlist"
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
: > "$A11/sub28-allowlist"
cat > "$A11/sub28.conf" <<'EOF'
profile sub28 10.78.0.16/28
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
    rule gateway-only
    gateway 10.78.0.18 3128 sub28-allowlist
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
    gateway 10.79.0.2 3128 dr-allowlist
EOF
: > "$A12/dr-allowlist"
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
    gateway 10.79.1.2 3128 plain-allowlist
EOF
: > "$A12/plain-allowlist"
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
    gateway 10.79.2.2 3128 ma-allowlist
EOF
: > "$A12/ma-allowlist"
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
    gateway 10.199.65.2 3128 seq-allowlist
EOF
: > "$A12/seq-allowlist"
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
    gateway 10.80.0.2 3128 bare-allowlist
EOF
: > "$A14/bare-allowlist"

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
    gateway 10.80.1.2 3128 fb-allowlist
EOF
: > "$A14/fb-allowlist"
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

# D3: verify --ensured takes no profile argument (the named error, not
# any usage error).
x_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$TESTROOT/validconf/v.conf")" egresslock verify --ensured local-dev 2>&1)"; x_rc=$?
[[ "$x_rc" == 2 && "$x_out" == *"Error: verify --ensured takes no profile argument."* ]] \
    && a16 pass || a16 fail "verify --ensured rejects profile arg named (rc=$x_rc, out: $x_out)"

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
# EGL-385: an empty EGRESSLOCK_CONF still counts as SET (presence
# semantics) — the warning is emitted and the command continues as if
# unset (the rc is the command's, not this gate's).
ec_out="$(env EGRESSLOCK_CONF= egresslock list 2>&1)"; ec_rc=$?
if [[ "$ec_rc" == 2 && "$ec_out" == *"Warning: EGRESSLOCK_CONF is retired and is no longer read."* \
      && "$ec_out" == *"no profile config"* ]]; then
    a20 pass
else
    a20 fail "empty EGRESSLOCK_CONF warns and continues (rc=$ec_rc, out: $ec_out)"
fi
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
if [[ "$u3_rc" == 2 && "$u3_out" == *"allow requires a destination"* && "$u3_out" == *"usage: egresslock allow [--direct] <profile> <host[:port]>"* ]]; then
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

# Mock `id` to report uid 0 (root). The `id` uses these tests reach —
# the ARC-25 guard and the account-lock home lookup (engine_lock_path) —
# only need the uid, so a PATH shim in the test bin is a faithful root
# mock (other engine paths call `id` too; this shim is not a claim about
# the whole binary).
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
           "network v" "proxy-env v" "rules v" "allowlist v" "allowlist --direct v" \
           "allowlist-direct v" "denied v" "allow v x" "list" "init x"; do
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
printf 'profile main 10.94.8.0/24\n    gateway 10.94.8.2 3128 main-allowlist\n' > "$NPDIR/main.conf"
: > "$NPDIR/main-allowlist"
for cmd in "ensure ci" "verify ci" "verify --ensured" "teardown all"; do
    # shellcheck disable=SC2086
    p_out="$(PATH="$TESTROOT/bin-broken:$PATH" npc $cmd 2>&1)"; p_rc=$?
    # EGL-347-D1: the AppArmor-shaped failure prints podman's actual
    # output under the probe header and routes through the checker
    # (check first, add when required). The old fixed claim that the
    # host runs a labeled podman is gone.
    if [[ "$p_rc" == 1 \
        && "$p_out" == *"podman rootless-netns is broken"* \
        && "$p_out" == *"rc=126"* \
        && "$p_out" == *"Error: rootless netns: kill network process: permission denied"* \
        && "$p_out" == *"Check whether AppArmor is the cause: sudo egresslock-setup apparmor check"* \
        && "$p_out" == *"egresslock-setup apparmor add"* \
        && "$p_out" != *"-> 'kill network process"* \
        && "$p_out" != *"Podman is running under an AppArmor label (any profile mode)"* ]]; then
        a26 pass
    else
        a26 fail "broken probe '$cmd' (rc=$p_rc, out: $p_out)"
    fi
done

# EGL-347-D1(a): a stray/manual inherited-CWD line is excluded from the
# AppArmor shape rule even though it is rc 126 and contains "Permission
# denied"; it gets the netns pointer and no CWD-specific advice.
mkdir -p "$TESTROOT/bin-cwd"
cat > "$TESTROOT/bin-cwd/podman" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "unshare" && "\$2" == "--rootless-netns" && "\$3" == "true" ]]; then
    echo "cannot chdir to /home/ben: Permission denied" >&2
    exit 126
fi
exec "$TESTROOT/bin/podman" "\$@"
EOF
chmod +x "$TESTROOT/bin-cwd/podman"
c_out="$(PATH="$TESTROOT/bin-cwd:$PATH" npc ensure ci 2>&1)"; c_rc=$?
if [[ "$c_rc" == 1 \
    && "$c_out" == *"cannot chdir to /home/ben: Permission denied"* \
    && "$c_out" == *"docs/troubleshooting/netns-inspection"* \
    && "$c_out" != *"apparmor check"* && "$c_out" != *"apparmor add"* \
    && "$c_out" != *"sudo -iu"* \
    && "$c_out" != *"cannot use the directory"* ]]; then
    a26 pass
else
    a26 fail "inherited-CWD probe gets netns pointer, not AppArmor (rc=$c_rc, out: $c_out)"
fi

# EGL-347-D1(b): a "permission denied" shape without the CWD signature
# takes the checker-led branch even when rc is not 126.
mkdir -p "$TESTROOT/bin-perm"
cat > "$TESTROOT/bin-perm/podman" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "unshare" && "\$2" == "--rootless-netns" && "\$3" == "true" ]]; then
    echo "Error: opening /run/user/1000/netns/podman: permission denied" >&2
    exit 1
fi
exec "$TESTROOT/bin/podman" "\$@"
EOF
chmod +x "$TESTROOT/bin-perm/podman"
pm_out="$(PATH="$TESTROOT/bin-perm:$PATH" npc ensure ci 2>&1)"; pm_rc=$?
if [[ "$pm_rc" == 1 \
    && "$pm_out" == *"opening /run/user/1000/netns/podman: permission denied"* \
    && "$pm_out" == *"Check whether AppArmor is the cause: sudo egresslock-setup apparmor check"* \
    && "$pm_out" == *"egresslock-setup apparmor add"* ]]; then
    a26 pass
else
    a26 fail "permission-denied shape takes checker branch (rc=$pm_rc, out: $pm_out)"
fi

# EGL-347-D1(c): any other failure gets the netns pointer and no
# AppArmor statement at all.
mkdir -p "$TESTROOT/bin-generic"
cat > "$TESTROOT/bin-generic/podman" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "unshare" && "\$2" == "--rootless-netns" && "\$3" == "true" ]]; then
    echo "cgroup manager died unexpectedly" >&2
    exit 1
fi
exec "$TESTROOT/bin/podman" "\$@"
EOF
chmod +x "$TESTROOT/bin-generic/podman"
g_out="$(PATH="$TESTROOT/bin-generic:$PATH" npc ensure ci 2>&1)"; g_rc=$?
if [[ "$g_rc" == 1 \
    && "$g_out" == *"cgroup manager died unexpectedly"* \
    && "$g_out" == *"docs/troubleshooting/netns-inspection"* \
    && "$g_out" != *"AppArmor"* && "$g_out" != *"apparmor"* ]]; then
    a26 pass
else
    a26 fail "generic probe keeps netns pointer, no AppArmor token (rc=$g_rc, out: $g_out)"
fi

# EGL-347-D1(d): a probe that fails with no output still reports the
# placeholder and routes to the netns pointer — the empty-output branch
# is a pinned failure path, not a silent pass.
mkdir -p "$TESTROOT/bin-silent"
cat > "$TESTROOT/bin-silent/podman" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "unshare" && "\$2" == "--rootless-netns" && "\$3" == "true" ]]; then
    exit 1
fi
exec "$TESTROOT/bin/podman" "\$@"
EOF
chmod +x "$TESTROOT/bin-silent/podman"
si_out="$(PATH="$TESTROOT/bin-silent:$PATH" npc ensure ci 2>&1)"; si_rc=$?
if [[ "$si_rc" == 1 \
    && "$si_out" == *"(probe printed no output)"* \
    && "$si_out" == *"docs/troubleshooting/netns-inspection"* \
    && "$si_out" != *"apparmor check"* && "$si_out" != *"apparmor add"* ]]; then
    a26 pass
else
    a26 fail "silent probe gets placeholder + netns pointer (rc=$si_rc, out: $si_out)"
fi

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
printf 'profile v 10.50.9.0/24\n    gateway 10.50.9.2 3128 v-allowlist\n' > "$TESTROOT/h24/.config/egresslock/v.conf"
: > "$TESTROOT/h24/.config/egresslock/v-allowlist"
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
printf 'profile hsp 10.50.11.0/24\n    gateway 10.50.11.2 3128 hsp-allowlist\n' > "$TESTROOT/home with space/.config/egresslock/hsp.conf"
: > "$TESTROOT/home with space/.config/egresslock/hsp-allowlist"
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

# EGL-385: a set EGRESSLOCK_CONF warns and continues as if unset — the
# normal aggregate resolution line and rows still print.
y_out="$(env EGRESSLOCK_CONF="$TESTROOT/validconf/v.conf" ARCMOCK_PASSWD_HOME="$TESTROOT/h24" egresslock list 2>$TESTROOT/agent24y.err)"; y_rc=$?
if [[ "$y_rc" == 0 && "$y_out" == *"egresslock-v"* \
      && "$(cat $TESTROOT/agent24y.err)" == *"Warning: EGRESSLOCK_CONF is retired and is no longer read."* \
      && "$(cat $TESTROOT/agent24y.err)" == *"using configs in $TESTROOT/h24/.config/egresslock"* ]]; then
    a24 pass
else
    a24 fail "EGRESSLOCK_CONF warns and continues (rc=$y_rc, out: $y_out, err: $(cat $TESTROOT/agent24y.err))"
fi

# getent home is authoritative even with HOME unset: the default probe
# still works from the passwd answer alone.
mkdir -p "$TESTROOT/h24-nohome/.config/egresslock"
printf 'profile w 10.50.10.0/24\n    gateway 10.50.10.2 3128 w-allowlist\n' > "$TESTROOT/h24-nohome/.config/egresslock/w.conf"
: > "$TESTROOT/h24-nohome/.config/egresslock/w-allowlist"
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
# EGL-380: 'all' is reserved — refuse rc 2 before writing either half.
i5b_out="$(env HOME="$TESTROOT/i35" ARCMOCK_PASSWD_HOME="$TESTROOT/i35" egresslock init all 2>&1)"; i5b_rc=$?
[[ "$i5b_rc" == 2 && "$i5b_out" == *"reserved"* \
   && "$i5b_out" == *"teardown all"* && "$i5b_out" == *"choose another name"* \
   && ! -e "$TESTROOT/i35/.config/egresslock/all.conf" \
   && ! -e "$TESTROOT/i35/.config/egresslock/all-allowlist" ]] \
    && a35 pass || a35 fail "init all reserved, no files (rc=$i5b_rc, out: $i5b_out)"
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

# Gateway-less profile (EGL-366-D3): the conf no longer loads at all, so
# the old require_gateway_profile guard is now unreachable for it — the
# named parse error is the (rc 2) refusal here.
mkdir -p "$TESTROOT/nogw30"
printf 'profile v 10.50.9.0/24\n' > "$TESTROOT/nogw30/v.conf"
d5_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home_ro "$TESTROOT/nogw30/v.conf")" egresslock disallow v example.com:443 2>&1)"; d5_rc=$?
if [[ "$d5_rc" == 2 && "$d5_out" == *"profile 'v' has no 'gateway' directive"* \
      && "$d5_out" == *"fix: add a gateway line to this conf"* ]]; then
    a30 pass
else
    a30 fail "disallow on gateway-less profile is rejected named (rc=$d5_rc, out: $d5_out)"
fi

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
printf '# keep old.example:443 glued here no newline' > "$B2/q3-allowlist"
cat > "$B2/q3.conf" <<'EOF'
profile q3 10.199.26.0/24
    rule gateway-only
    gateway 10.199.26.2 3128 q3-allowlist
EOF
mkdir -p "$STATE/ips" "$STATE/containers"
: > "$STATE/running/egresslock-gateway-q3"
echo "egresslock-q3" > "$STATE/containers/egresslock-gateway-q3.net"
echo "10.199.26.2" > "$STATE/containers/egresslock-gateway-q3.ip"
run_b2g() { env ARCMOCK_PASSWD_HOME="$(conf_home "$B2/q3.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
b2g_out="$(run_b2g allow q3 new.example 2>&1)"; b2g_rc=$?
if [[ "$b2g_rc" == 0 ]] \
   && grep -qxF 'new.example' "$B2/q3-allowlist" \
   && ! grep -q '^old.example:443$' "$B2/q3-allowlist" \
   && grep -q '^# keep old.example:443 glued here no newline$' "$B2/q3-allowlist"; then
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
    gateway 10.199.31.2 3128 a52-allowlist
EOF
: > "$A52/a52-allowlist"
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
    gateway 10.199.32.2 3128 e98-allowlist
EOF
: > "$E98/e98-allowlist"
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
      && "$e98_out" == *"egresslock ensure e98 (as $ENSURE_ACCT)"* ]]; then
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
      && "$e98_out" == *"egresslock ensure e98 (as $ENSURE_ACCT)"* ]]; then
    e98 pass
else
    e98 fail "stale verify --ensured named failure (rc=$e98_rc, out: $e98_out)"
fi
rm -f "$STATE/networks/egresslock-e98"

# 3. Regressions: network object missing keeps the existing named line
# (never-ensured / teardown'd shape) — and --ensured stays silent rc 0
# when nothing is stale.
e98_out="$(run_e98 verify e98 2>&1)"; e98_rc=$?
if [[ "$e98_rc" == 1 && "$e98_out" == *"network egresslock-e98 missing — run: egresslock ensure e98 (as $ENSURE_ACCT)"* ]]; then
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
printf 'profile a 10.199.1.0/24\n    gateway 10.199.1.2 3128 a-allowlist\n' > "$H37/.config/egresslock/a.conf"
: > "$H37/.config/egresslock/a-allowlist"
printf 'profile b 10.199.2.0/24\n    gateway 10.199.2.2 3128 b-allowlist\n' > "$H37/.config/egresslock/b.conf"
: > "$H37/.config/egresslock/b-allowlist"

# 1. bare list aggregates every *.conf (main + a + b).
l_out="$(pty "env HOME='$H37' ARCMOCK_PASSWD_HOME='$H37' egresslock list 2>$TESTROOT/a37.err")"; l_rc=$?
if [[ "$l_rc" == 0 \
      && "$(cat $TESTROOT/a37.err)" == *"using configs in"*"$H37/.config/egresslock"* ]] \
   && grep -qE '^main[[:space:]]' <<<"$l_out" \
   && grep -qE '^a[[:space:]]' <<<"$l_out" \
   && grep -qE '^b[[:space:]]' <<<"$l_out"; then
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
printf 'profile z 10.199.4.0/24\n    gateway 10.199.4.2 3128 z-allowlist\n' > "$H37B/.config/egresslock/notz.conf"
: > "$H37B/.config/egresslock/z-allowlist"
d_out="$(env HOME="$H37B" ARCMOCK_PASSWD_HOME="$H37B" egresslock list 2>&1)"; d_rc=$?
if [[ "$d_rc" == 2 && "$d_out" == *"config name/profile mismatch"* \
      && "$d_out" == *"notz.conf"* && "$d_out" == *"profile 'z'"* \
      && "$d_out" == *"must be named 'z.conf'"* ]]; then
    a37 pass
else
    a37 fail "basename/profile mismatch rejected (rc=$d_rc, out: $d_out)"
fi

# 5. bare teardown all uses main.conf only (never scans siblings).
printf 'profile b 10.199.2.0/24\n    gateway 10.199.2.2 3128 b-allowlist\n' > "$H37/.config/egresslock/b.conf"
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
printf 'profile main 10.199.0.0/24\n    gateway 10.199.0.2 3128 main-allowlist\n' > "$H117/.config/egresslock/main.conf"
: > "$H117/.config/egresslock/main-allowlist"
printf 'profile p2 10.199.1.0/24\n    gateway 10.199.1.2 3128 p2-allowlist\n' > "$H117/.config/egresslock/p2.conf"
: > "$H117/.config/egresslock/p2-allowlist"

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

# 4. Under a pipe the aggregate line survives command substitution and
#    still names the whole confdir (EGL-325: no env selector narrows it;
#    EGL-385 rejects the variable, so it is not set here).
o="$(env ARCMOCK_PASSWD_HOME="$H117" HOME="$H117" egresslock list 2>$TESTROOT/e117d.err | cat)"; rc=$?
if [[ "$rc" == 0 \
      && "$(cat $TESTROOT/e117d.err)" == "using configs in $H117/.config/egresslock (2 profiles)" ]]; then
    a117 pass
else
    a117 fail "aggregate line under pipe (rc=$rc, err: $(cat $TESTROOT/e117d.err))"
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
[[ "$m_rc" == 2 && "$m_out" == *"requires host:port — there is no default port"* ]] \
    && a38 pass || a38 fail "allow-host invalid grammar (rc=$m_rc, out: $m_out)"

# 6. leftover `rule public-only` (removed kind, EGL-153): allow-host
#    fails at PARSE — exit 2, unknown-kind error, conf unchanged.
printf 'profile pub 10.199.12.0/24\n    rule public-only\n    gateway 10.199.12.2 3128 pub-allowlist\n' > "$AH/pub.conf"
: > "$AH/pub-allowlist"
p_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/pub.conf")" egresslock allow-host pub git.example.test:2222 2>&1)"; p_rc=$?
if [[ "$p_rc" == 2 && "$p_out" == *"unknown rule kind 'public-only'"* ]] && ! grep -q 'allow-host' "$AH/pub.conf"; then
    a38 pass
else
    a38 fail "allow-host on leftover public-only fails closed at parse (rc=$p_rc, out: $p_out)"
fi

# 7. EGL-366-D3: a gateway-less profile no longer loads, so the old
#    "non-gateway profile can take allow-host" shape is a named refusal
#    (rc 2, nothing written). The fixture lives in its own confdir so it
#    cannot poison the shared $AH aggregate.
mkdir -p "$AH/nogw"
printf 'profile d 10.199.13.0/24\n    rule allow-host git.example.test:443\n' > "$AH/nogw/d.conf"
dg_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AH/nogw/d.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host d cache.example.test:443 2>&1)"; dg_rc=$?
if [[ "$dg_rc" == 2 && "$dg_out" == *"profile 'd' has no 'gateway' directive"* ]] \
   && ! grep -q 'allow-host cache.example.test:443' "$AH/nogw/d.conf"; then
    a38 pass
else
    a38 fail "allow-host on a gateway-less profile is rejected named (rc=$dg_rc, out: $dg_out)"
fi

# 8. disallow-host only touches the named profile's conf (a same-named
#    rule in the sibling profile's conf is untouched).
cat > "$AH/p1.conf" <<'EOF'
profile p1 10.199.14.0/24
    rule allow-host git.example.test:2222
    gateway 10.199.14.2 3128 p1-allowlist
EOF
: > "$AH/p1-allowlist"
cat > "$AH/p2.conf" <<'EOF'
profile p2 10.199.15.0/24
    rule allow-host git.example.test:2222
    gateway 10.199.15.2 3128 p2-allowlist
EOF
: > "$AH/p2-allowlist"
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
    gateway 10.199.17.2 3128 near-allowlist
EOF
: > "$AH/near-allowlist"
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

# --- ARC-43: allowlist — render the configured proxy entries -------------
section_begin arc43 "ARC-43 allowlist"
a43() { assert "$@"; }

AD8="$TESTROOT/h43"; rm -rf "$AD8"; mkdir -p "$AD8"
cat > "$AD8/gw.conf" <<'EOF'
profile gw 10.199.50.0/24
    rule gateway-only
    gateway 10.199.50.2 3128 gw-allowlist
EOF
: > "$STATE/running/egresslock-gateway-gw"
h43="profile 'gw' — 6 proxy entries from the allowlist file (the proxy resolves each entry per request):"
h43e="profile 'gw' — 0 proxy entries from the allowlist file (the proxy resolves each entry per request):"

# 1. EGL-375-D1/D2/D3: comments/blank lines stripped; stored spelling and
#    file order preserved (explicit :443 and the leading-zero port are NOT
#    folded/normalized); exact header; path/basename only off stdout.
#    Mutations: cat the file (comment/row set reds), fold :443 (row reds),
#    print the path or basename (leg reds).
cat > "$AD8/gw-allowlist" <<'EOF'
# comment line
example.test
other.test:8443
Explicit.TEST:443
leading0.test:0443
.suffix.test
# trailing comment
no-such-host.invalid
EOF
exp43="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s' "$h43" \
    'example.test' 'other.test:8443' 'Explicit.TEST:443' 'leading0.test:0443' \
    '.suffix.test' 'no-such-host.invalid')"
al_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/gw.conf")" egresslock allowlist gw 2>"$AD8/a1.err")"; al_rc=$?
al_err="$(cat "$AD8/a1.err")"
if [[ "$al_rc" == 0 && "$al_out" == "$exp43" \
      && "$al_err" == *"using config "*"gw.conf"* \
      && "$al_out" != *"# comment"* && "$al_out" != *"gw-allowlist"* && "$al_out" != *"$AD8"* \
      && "$al_out" != *"using config"* ]]; then
    a43 pass
else
    a43 fail "allowlist renders stored entries + header (rc=$al_rc, out: $al_out, err: $al_err)"
fi

# 2. EGL-375-D2: an empty allowlist is explicit — the one header line with
#    `0 proxy entries`, rc 0, no extra blank line. Mutation: suppress the
#    header when empty (out becomes empty) reds this leg.
: > "$AD8/gw-allowlist"
ae_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/gw.conf")" egresslock allowlist gw 2>/dev/null)"; ae_rc=$?
[[ "$ae_rc" == 0 && "$ae_out" == "$h43e" ]] \
    && a43 pass || a43 fail "allowlist empty allowlist (rc=$ae_rc, out: [$ae_out])"

# 3. comments-only starter -> the same 0-entry header, no comment bytes.
printf '# main-allowlist — starter\n# EMPTY by design\n' > "$AD8/gw-allowlist"
ac_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/gw.conf")" egresslock allowlist gw 2>/dev/null)"; ac_rc=$?
[[ "$ac_rc" == 0 && "$ac_out" == "$h43e" ]] \
    && a43 pass || a43 fail "allowlist comments-only (rc=$ac_rc, out: $ac_out)"

# 4. EGL-375-D4: an invalid line fails closed, named, with nothing on
#    stdout (not even the header) — the view must not look healthier than
#    the apply path. Mutations: keep the old `cat` (rc 0 dump) or print
#    the header before validating (stdout non-empty) red these legs.
for bad in '192.0.2.10:443' 'bad.test.:443' 'bad.test:99999' '-bad.test'; do
    printf '%s\n' "$bad" > "$AD8/gw-allowlist"
    ai_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/gw.conf")" egresslock allowlist gw 2>"$AD8/a4.err")"; ai_rc=$?
    ai_err="$(cat "$AD8/a4.err")"
    if [[ "$ai_rc" == 1 && -z "$ai_out" && "$ai_err" == *"$bad"* \
          && "$ai_err" != *"proxy entries"* ]]; then
        a43 pass
    else
        a43 fail "invalid allowlist line '$bad' fails closed named (rc=$ai_rc, out: $ai_out, err: $ai_err)"
    fi
done

# 5. extra arg -> exit 2.
ax_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/gw.conf")" egresslock allowlist gw extra 2>&1)"; ax_rc=$?
[[ "$ax_rc" == 2 && "$ax_out" == *"usage"* ]] \
    && a43 pass || a43 fail "allowlist extra arg (rc=$ax_rc, out: $ax_out)"

# ARC-45: the old `allowed` name is now an unknown command (no alias).
old_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/gw.conf")" egresslock allowed gw 2>&1)"; old_rc=$?
[[ "$old_rc" == 2 && "$old_out" == *"unknown command"* ]] \
    && a43 pass || a43 fail "ARC-45: old 'allowed' is unknown (rc=$old_rc, out: $old_out)"

# 6. EGL-366-D3: a gateway-less profile no longer loads — the named parse
#    error replaces the old require_gateway_profile refusal. The fixture
#    lives in its own confdir (arc44 reuses it) so it cannot poison $AD8.
mkdir -p "$AD8/nogw"
cat > "$AD8/nogw/plain.conf" <<'EOF'
profile plain 10.199.51.0/24
    rule allow-host plain.example.test:443
EOF
an_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/nogw/plain.conf")" egresslock allowlist plain 2>&1)"; an_rc=$?
[[ "$an_rc" == 2 && "$an_out" == *"profile 'plain' has no 'gateway' directive"* ]] \
    && a43 pass || a43 fail "allowlist on a gateway-less profile is rejected named (rc=$an_rc, out: $an_out)"

# 7. missing allowlist file -> fail closed naming the path, stdout empty.
mkdir -p "$AD8/missdir"
cat > "$AD8/missdir/gw.conf" <<'EOF'
profile gw 10.199.52.0/24
    rule gateway-only
    gateway 10.199.52.2 3128 gw-allowlist
EOF
am_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/missdir/gw.conf")" egresslock allowlist gw 2>"$AD8/a7.err")"; am_rc=$?
am_err="$(cat "$AD8/a7.err")"
[[ "$am_rc" == 1 && -z "$am_out" && "$am_err" == *"allowlist file missing:"* && "$am_err" == *"gw-allowlist"* ]] \
    && a43 pass || a43 fail "allowlist missing file names path (rc=$am_rc, out: $am_out, err: $am_err)"

# 8. unreadable allowlist file -> the named EGL-395 error (not a raw
#    `cat:` line), rc 1, nothing on stdout.
printf 'example.test\n' > "$AD8/gw-allowlist"
chmod 000 "$AD8/gw-allowlist"
au_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/gw.conf")" egresslock allowlist gw 2>"$AD8/a8.err")"; au_rc=$?
chmod 600 "$AD8/gw-allowlist"
au_err="$(cat "$AD8/a8.err")"
[[ "$au_rc" == 1 && -z "$au_out" && "$au_err" == *"allowlist file unreadable:"* \
   && "$au_err" == *"gw-allowlist"* && "$au_err" != *"cat:"* ]] \
    && a43 pass || a43 fail "allowlist unreadable file named (rc=$au_rc, out: $au_out, err: $au_err)"

# 9. D6: read-only — an exclusively held account lock does not block the
#    view; conf/allowlist bytes and modes are unchanged and no pin record
#    appears. Mutations: take the lock or call ensure in the bare path.
AD8H="$(conf_home "$AD8/gw.conf")"
printf 'readonly.example.test:443\n' > "$AD8/gw-allowlist"
ro_before="$(sha256sum "$AD8/gw.conf" "$AD8/gw-allowlist")"
ro_modes="$(stat -c '%a %n' "$AD8/gw.conf" "$AD8/gw-allowlist")"
ro_pins_before=0; [[ -e "$AD8/gw.pins" ]] && ro_pins_before=1
mkdir -p "$AD8H/.local/state/egresslock"
exec 8>>"$AD8H/.local/state/egresslock/engine.lock"
flock -x 8
ro_out="$(EGRESSLOCK_LOCK_WAIT=0 env ARCMOCK_PASSWD_HOME="$AD8H" egresslock allowlist gw 2>"$AD8/a9.err")"; ro_rc=$?
flock -u 8; exec 8>&-
ro_after="$(sha256sum "$AD8/gw.conf" "$AD8/gw-allowlist")"
ro_modes_after="$(stat -c '%a %n' "$AD8/gw.conf" "$AD8/gw-allowlist")"
ro_pins_after=0; [[ -e "$AD8/gw.pins" ]] && ro_pins_after=1
h43ro="profile 'gw' — 1 proxy entries from the allowlist file (the proxy resolves each entry per request):"
if [[ "$ro_rc" == 0 && "$ro_out" == "$h43ro"$'\n'"readonly.example.test:443" \
      && "$ro_before" == "$ro_after" && "$ro_modes" == "$ro_modes_after" \
      && "$ro_pins_before" == 0 && "$ro_pins_after" == 0 \
      && "$(cat "$AD8/a9.err")" != *"re_ensuring"* && "$(cat "$AD8/a9.err")" != *"added:"* ]]; then
    a43 pass
else
    a43 fail "read-only under held lock / byte+mode+pin stability (rc=$ro_rc, out: $ro_out)"
fi

# 10. EGL-375-D5: the two lanes share one header shape — profile, decimal
#     count, lane word, `entries from the`, source noun, parenthesized
#     resolution. Mutation: change one header's punctuation/order (that
#     leg reds while the other stays green).
gd_out="$(env ARCMOCK_PASSWD_HOME="$AD8H" egresslock allowlist gw --direct 2>/dev/null)"; gd_rc=$?
rx43="^profile 'gw' — [0-9]+ (proxy|direct) entries from the (allowlist file|profile conf) \(.+\):$"
ro_h="${ro_out%%$'\n'*}"
gd_h="${gd_out%%$'\n'*}"
if [[ "$gd_rc" == 0 && "$ro_h" =~ $rx43 && "$gd_h" =~ $rx43 ]]; then
    a43 pass
else
    a43 fail "both lanes share the header template (rc=$gd_rc, proxy: $ro_h, direct: $gd_h)"
fi

# 11. R-EGL-375-3 F1: the direct lane is structurally ungated. EGL-366-D3
#     rejects a gateway-less conf at load, so every loadable profile is a
#     gateway profile and a re-added gateway guard in the direct branch is
#     behaviorally unobservable; pin the branch shape instead. The bare
#     branch keeps the one gateway guard. Mutation: insert
#     `require_gateway_profile "$profile" allowlist` into the direct branch
#     (or drop it from the bare path) -> reds.
a43_body="$(awk '/^cmd_allowlist\(\)/{p=1} p{print} p && /^}$/{exit}' "$TREE_ROOT/egresslock")"
a43_direct="$(printf '%s\n' "$a43_body" | awk '/^    if \(\( ALLOWLIST_DIRECT \)\); then$/{p=1} p{print} p && /^    fi$/{exit}')"
a43_direct_code="$(printf '%s\n' "$a43_direct" | grep -vE '^[[:space:]]*#')"
a43_gate_hits="$(printf '%s\n' "$a43_direct_code" | grep -nE 'require_gateway_profile|is_gateway_profile' || true)"
a43_guard_count="$(printf '%s\n' "$a43_body" | grep -cE '^[[:space:]]*require_gateway_profile[[:space:]]+"\$profile"[[:space:]]+allowlist[[:space:]]*$')"
a43_return_ok=0
printf '%s\n' "$a43_direct_code" | grep -qE '^[[:space:]]*return 0[[:space:]]*$' && a43_return_ok=1
if [[ "$a43_direct" == *profile_allow_hosts* && "$a43_return_ok" == 1 \
      && -z "$a43_gate_hits" && "$a43_guard_count" == 1 ]]; then
    a43 pass
else
    a43 fail "direct branch stays ungated (branch found: $([[ "$a43_direct" == *profile_allow_hosts* ]] && echo yes || echo no), direct return 0: $a43_return_ok, gate hits: ${a43_gate_hits:-none}, bare guard count: $a43_guard_count)"
fi

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

# 4. EGL-366-D3: a gateway-less profile no longer loads, so neither the
#    token form nor the bare form reaches the proxy-env gateway guard.
ng_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/nogw/plain.conf")" egresslock proxy-env plain proxyip 2>&1)"; ng_rc=$?
[[ "$ng_rc" == 2 && "$ng_out" == *"profile 'plain' has no 'gateway' directive"* ]] \
    && a44 pass || a44 fail "proxy-env token on a gateway-less profile is rejected named (rc=$ng_rc, out: $ng_out)"
ngb_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$AD8/nogw/plain.conf")" egresslock proxy-env plain 2>&1)"; ngb_rc=$?
[[ "$ngb_rc" == 2 && "$ngb_out" == *"profile 'plain' has no 'gateway' directive"* ]] \
    && a44 pass || a44 fail "proxy-env bare on a gateway-less profile is rejected named (rc=$ngb_rc, out: $ngb_out)"

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
    gateway 10.199.72.2 3128 egl246fall-allowlist
EOF
: > "$E246/gw-allowlist"
: > "$E246/egl246fall-allowlist"
mkdir -p "$E246/nogw"
cat > "$E246/nogw/plain.conf" <<'EOF'
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

# 5. EGL-366-D3: a gateway-less profile no longer loads, so neither the
#    --out form nor the bare form reaches the proxy-env guard, and no
#    file is written.
ng_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/nogw/plain.conf")" egresslock proxy-env plain --out 2>&1)"; ng_rc=$?
if [[ "$ng_rc" == 2 && "$ng_out" == *"profile 'plain' has no 'gateway' directive"* \
      && ! -e "$E246/run/egresslock-proxy-plain.env" ]]; then
    a246 pass
else
    a246 fail "gateway-less --out is rejected named, nothing written (rc=$ng_rc, out: $ng_out)"
fi
ngb_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/nogw/plain.conf")" egresslock proxy-env plain 2>&1)"; ngb_rc=$?
[[ "$ngb_rc" == 2 && "$ngb_out" == *"profile 'plain' has no 'gateway' directive"* ]] \
    && a246 pass || a246 fail "gateway-less bare is rejected named (rc=$ngb_rc, out: $ngb_out)"

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

# 9. D14 edges: relative --out=rel.env in a scratch cwd (parent `.`)
#    prints the canonical absolute path (EGL-387-D6: `$dir/<basename>`,
#    never the typed spelling); an existing directory target (incl.
#    trailing slash) fails closed.
mkdir -p "$E246/cwd"
rel_out="$(cd "$E246/cwd" && env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out=rel.env 2>/dev/null)"; rel_rc=$?
[[ "$rel_rc" == 0 && "$rel_out" == "$E246/cwd/rel.env" \
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

# 17. EGL-387-D5: a caller-owned group-writable (020, other bits
#     clean) parent is REFUSED rc 1 named — the W1 accept+warn is
#     gone. Nothing written, stdout empty, no `warn:`, no temp litter.
#     F3 (R-EGL-387-3): the refusal runs BEFORE any temp exists — a
#     `mktemp` shim records every request, so a mutation that creates
#     (and later deletes) a temp before the mode check reds here.
mkdir -p "$E246/sentinel-bin"
cat > "$E246/sentinel-bin/mktemp" <<'SHIM'
#!/bin/bash
# EGL-387 F3: record that a temp was requested (args only; no path read)
printf '%s\n' "$*" >> "${E246_MKTEMP_LOG:?}"
exec /usr/bin/mktemp "$@"
SHIM
chmod +x "$E246/sentinel-bin/mktemp"
mkdir -p "$E246/gw0770"; chmod 770 "$E246/gw0770"
: > "$E246/mktemp-0770.log"
w2_out="$(env PATH="$E246/sentinel-bin:$PATH" E246_MKTEMP_LOG="$E246/mktemp-0770.log" \
    ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/gw0770/ok.env" 2>"$E246/w2.err")"; w2_rc=$?
[[ "$w2_rc" == 1 && -z "$w2_out" \
   && "$(cat "$E246/w2.err")" == *"is group-writable"* \
   && "$(cat "$E246/w2.err")" == *"'$E246/gw0770'"* \
   && "$(cat "$E246/w2.err")" == *"fail closed"* \
   && ! "$(cat "$E246/w2.err")" == *"warn:"* \
   && ! -e "$E246/gw0770/ok.env" \
   && -z "$(find "$E246/gw0770" -name 'ok.env.*' 2>/dev/null)" \
   && ! -s "$E246/mktemp-0770.log" ]] \
    && a246 pass || a246 fail "EGL-387 0770 parent refused (rc=$w2_rc, stdout: [$w2_out], err: $(cat "$E246/w2.err" 2>/dev/null), mktemp: $(cat "$E246/mktemp-0770.log" 2>/dev/null))"
chmod 700 "$E246/gw0770"

# 17b. EGL-387-D5: other-write-only (0703) parent is REFUSED rc 1
#      `is world-writable` — the 002 leg carries the world key alone,
#      nothing is written, no temp is requested, no litter.
mkdir -p "$E246/wo703"; chmod 703 "$E246/wo703"
: > "$E246/mktemp-0703.log"
w2b_out="$(env PATH="$E246/sentinel-bin:$PATH" E246_MKTEMP_LOG="$E246/mktemp-0703.log" \
    ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/wo703/a.env" 2>"$E246/w2b.err")"; w2b_rc=$?
[[ "$w2b_rc" == 1 && -z "$w2b_out" \
   && "$(cat "$E246/w2b.err")" == *"is world-writable"* \
   && "$(cat "$E246/w2b.err")" == *"'$E246/wo703'"* \
   && ! -e "$E246/wo703/a.env" \
   && -z "$(find "$E246/wo703" -name 'a.env.*' 2>/dev/null)" \
   && ! -s "$E246/mktemp-0703.log" ]] \
    && a246 pass || a246 fail "EGL-387 0703 parent refused (rc=$w2b_rc, out: [$w2b_out], err: $(cat "$E246/w2b.err" 2>/dev/null), mktemp: $(cat "$E246/mktemp-0703.log" 2>/dev/null))"
chmod 700 "$E246/wo703"

# 17b-control. EGL-387 F3 sentinel positive control: the same shim on an
#      ACCEPTED write records exactly one temp request — the sentinel is
#      live, so the empty logs above are ordering evidence, not a dead
#      shim.
mkdir -p "$E246/p700s"; chmod 700 "$E246/p700s"
: > "$E246/mktemp-control.log"
w2ctrl_out="$(env PATH="$E246/sentinel-bin:$PATH" E246_MKTEMP_LOG="$E246/mktemp-control.log" \
    ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/p700s/ctrl.env" 2>/dev/null)"; w2ctrl_rc=$?
[[ "$w2ctrl_rc" == 0 && "$w2ctrl_out" == "$E246/p700s/ctrl.env" \
   && -s "$E246/mktemp-control.log" ]] \
    && a246 pass || a246 fail "EGL-387 F3 sentinel control (rc=$w2ctrl_rc, out: $w2ctrl_out, mktemp: $(cat "$E246/mktemp-control.log" 2>/dev/null))"
rm -f "$E246/p700s/ctrl.env"; rmdir "$E246/p700s" 2>/dev/null || true
rm -f "$E246/sentinel-bin/mktemp"; rmdir "$E246/sentinel-bin" 2>/dev/null || true
rm -f "$E246/mktemp-0770.log" "$E246/mktemp-0703.log" "$E246/mktemp-control.log"

# 17c. EGL-387-D1/D5: the bare form on a group-writable
#      XDG_RUNTIME_DIR is REFUSED rc 1 `is group-writable` — the
#      accepted-downside leg; the default path is not written.
mkdir -p "$E246/xdg770"; chmod 770 "$E246/xdg770"
w2c_out="$(env XDG_RUNTIME_DIR="$E246/xdg770" ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out 2>"$E246/w2c.err")"; w2c_rc=$?
[[ "$w2c_rc" == 1 && -z "$w2c_out" \
   && "$(cat "$E246/w2c.err")" == *"is group-writable"* \
   && ! -e "$E246/xdg770/egresslock-proxy-gw.env" \
   && -z "$(find "$E246/xdg770" -name 'egresslock-proxy-gw.env.*' 2>/dev/null)" ]] \
    && a246 pass || a246 fail "EGL-387 bare form on 0770 XDG_RUNTIME_DIR (rc=$w2c_rc, out: [$w2c_out])"
chmod 700 "$E246/xdg770"

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

# 19b. EGL-387 R-EGL-387-6 F1: a typed parent with a MISSING component
#      before `..` is unresolvable and must fail closed before any write.
#      `realpath -m` erased the component, so the D6 rewrite would replace
#      the sentinel at the normalized destination; the typed parent must
#      never be silently rewritten. Empty stdout, no temp litter, and the
#      missing component is not created.
mkdir -p "$E246/raw19"; chmod 700 "$E246/raw19"
printf 'SENTINEL\n' > "$E246/raw19/victim"
f1a_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/raw19/missing/../victim" 2>"$E246/f1a.err")"; f1a_rc=$?
[[ "$f1a_rc" == 1 && -z "$f1a_out" \
   && "$(cat "$E246/raw19/victim")" == "SENTINEL" \
   && ! -e "$E246/raw19/missing" \
   && -z "$(find "$E246/raw19" -name 'victim.*' 2>/dev/null)" \
   && "$(cat "$E246/f1a.err")" == *"cannot resolve target directory"* \
   && "$(cat "$E246/f1a.err")" == *"fail closed"* ]] \
    && a246 pass || a246 fail "F1 missing-component .. refused (rc=$f1a_rc, out: [$f1a_out], victim: $(head -c 60 "$E246/raw19/victim" 2>/dev/null))"

# 19c. EGL-387 R-EGL-387-6 F1: the same for a REGULAR-FILE component
#      followed by `..` (ENOTDIR): the typed parent cannot be traversed,
#      so the sentinel at the normalized destination must survive.
printf 'SENTINEL\n' > "$E246/raw19/victim"
touch "$E246/raw19/afile"
f1b_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/raw19/afile/../victim" 2>"$E246/f1b.err")"; f1b_rc=$?
[[ "$f1b_rc" == 1 && -z "$f1b_out" \
   && "$(cat "$E246/raw19/victim")" == "SENTINEL" \
   && -f "$E246/raw19/afile" \
   && -z "$(find "$E246/raw19" -name 'victim.*' 2>/dev/null)" \
   && "$(cat "$E246/f1b.err")" == *"cannot resolve target directory"* \
   && "$(cat "$E246/f1b.err")" == *"fail closed"* ]] \
    && a246 pass || a246 fail "F1 regular-file-component .. refused (rc=$f1b_rc, out: [$f1b_out], victim: $(head -c 60 "$E246/raw19/victim" 2>/dev/null))"
rm -rf "$E246/raw19"

# 19d. EGL-387 R-EGL-387-6 F2: a newline in the typed parent is refused
#      before any write. Command substitution strips the trailing newline
#      from `realpath` output, which would send the D6 rewrite to the
#      newline-less sibling; neither the sibling nor the intended file may
#      change, stdout is empty, no temp litter.
mkdir -p "$E246/nl19/project"; nl19_dir="$E246/nl19/project"$'\n'; mkdir -p "$nl19_dir"
chmod 700 "$E246/nl19" "$E246/nl19/project" "$nl19_dir"
printf 'SIBLING\n' > "$E246/nl19/project/victim"
printf 'INTENDED\n' > "$nl19_dir/victim"
f2a_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$nl19_dir/victim" 2>"$E246/f2a.err")"; f2a_rc=$?
[[ "$f2a_rc" == 1 && -z "$f2a_out" \
   && "$(cat "$E246/nl19/project/victim")" == "SIBLING" \
   && "$(cat "$nl19_dir/victim")" == "INTENDED" \
   && -z "$(find "$E246/nl19" -name 'victim.*' 2>/dev/null)" \
   && "$(cat "$E246/f2a.err")" == *"target path contains a newline"* \
   && "$(cat "$E246/f2a.err")" == *"fail closed"* ]] \
    && a246 pass || a246 fail "F2 newline parent refused (rc=$f2a_rc, out: [$f2a_out], sibling: $(head -c 60 "$E246/nl19/project/victim" 2>/dev/null), intended: $(head -c 60 "$nl19_dir/victim" 2>/dev/null))"
rm -rf "$E246/nl19"

# 19e. EGL-387 R-EGL-387-6 F2 (resolved path): a symlink parent whose
#      referent ends in a newline is refused too — the sentinel-preserving
#      capture keeps the trailing byte from being stripped, so the guard
#      sees the path D6 would really use. Both the newline-less sibling
#      and the referent file stay unchanged.
mkdir -p "$E246/nl19b/proj"; nl19b_dir="$E246/nl19b/proj"$'\n'; mkdir -p "$nl19b_dir"
chmod 700 "$E246/nl19b" "$E246/nl19b/proj" "$nl19b_dir"
printf 'SIBLING\n' > "$E246/nl19b/proj/victim"
printf 'REFERENT\n' > "$nl19b_dir/victim"
ln -sfn "$nl19b_dir" "$E246/nl19b/link"
f2b_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/nl19b/link/victim" 2>"$E246/f2b.err")"; f2b_rc=$?
[[ "$f2b_rc" == 1 && -z "$f2b_out" \
   && "$(cat "$E246/nl19b/proj/victim")" == "SIBLING" \
   && "$(cat "$nl19b_dir/victim")" == "REFERENT" \
   && -z "$(find "$E246/nl19b" -name 'victim.*' 2>/dev/null)" \
   && "$(cat "$E246/f2b.err")" == *"target path contains a newline"* \
   && "$(cat "$E246/f2b.err")" == *"fail closed"* ]] \
    && a246 pass || a246 fail "F2 newline referent refused (rc=$f2b_rc, out: [$f2b_out], sibling: $(head -c 60 "$E246/nl19b/proj/victim" 2>/dev/null), referent: $(head -c 60 "$nl19b_dir/victim" 2>/dev/null))"
rm -rf "$E246/nl19b"

# 19f. EGL-387 R-EGL-387-9 F1: a newline in the FINAL component is refused
#      by the typed-path guard before any write. Only that guard sees it —
#      the post-`realpath` check inspects the parent — so the guard's
#      unique coverage needs its own pin: a consumer's
#      `--env-file="$(…)"` capture would strip the trailing newline and
#      open the newline-less sibling. Sibling sentinel preserved, no
#      newline-named file created, empty stdout, no temp litter.
mkdir -p "$E246/nl19c"; chmod 700 "$E246/nl19c"
printf 'SIBLING\n' > "$E246/nl19c/victim"
nl19c_target="$E246/nl19c/victim"$'\n'
f2c_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$nl19c_target" 2>"$E246/f2c.err")"; f2c_rc=$?
[[ "$f2c_rc" == 1 && -z "$f2c_out" \
   && "$(cat "$E246/nl19c/victim")" == "SIBLING" \
   && ! -e "$nl19c_target" \
   && -z "$(find "$E246/nl19c" -name 'victim.*' 2>/dev/null)" \
   && "$(cat "$E246/f2c.err")" == *"target path contains a newline"* \
   && "$(cat "$E246/f2c.err")" == *"fail closed"* ]] \
    && a246 pass || a246 fail "F2 newline basename refused (rc=$f2c_rc, out: [$f2c_out], sibling: $(head -c 60 "$E246/nl19c/victim" 2>/dev/null))"
rm -rf "$E246/nl19c"

# 19g. EGL-424: the typed-parent refusal must not depend on the host
#      `realpath`. uutils coreutils 0.10.0 canonicalize pops a
#      regular-file component's `..` lexically (no ENOTDIR), so the same
#      typed parent 19c refuses can reach the D6 rewrite there. A
#      `realpath` PATH shim reproduces that shape for the fixture path
#      (delegating all other calls; the marker proves the shim fired);
#      the kernel-enforced typed-parent check must refuse, sentinel
#      preserved, shim path never written, no temp litter.
mkdir -p "$E246/raw19g/dir" "$E246/raw19g/rpbin"
chmod 700 "$E246/raw19g" "$E246/raw19g/dir"
printf 'SENTINEL\n' > "$E246/raw19g/dir/victim"
touch "$E246/raw19g/dir/afile"
E246_RP_REAL="$(command -v realpath)"
cat > "$E246/raw19g/rpbin/realpath" <<SHIM
#!/bin/bash
# EGL-424: emulate uutils coreutils 0.10.0 — a regular-file component
# before '..' is popped lexically (no directory check). Exact fixture
# path only; every other call delegates to the host realpath.
if [[ "\${*: -1}" == "$E246/raw19g/dir/afile/.." ]]; then
    : > "$E246/raw19g/rpbin-fired"
    printf '%s\n' "$E246/raw19g/dir"
    exit 0
fi
exec "$E246_RP_REAL" "\$@"
SHIM
chmod +x "$E246/raw19g/rpbin/realpath"
f1g_out="$(env PATH="$E246/raw19g/rpbin:$PATH" \
    ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/raw19g/dir/afile/../victim" 2>"$E246/f1g.err")"; f1g_rc=$?
[[ "$f1g_rc" == 1 && -z "$f1g_out" \
   && -e "$E246/raw19g/rpbin-fired" \
   && "$(cat "$E246/raw19g/dir/victim")" == "SENTINEL" \
   && -f "$E246/raw19g/dir/afile" \
   && -z "$(find "$E246/raw19g/dir" -name 'victim.*' 2>/dev/null)" \
   && "$(cat "$E246/f1g.err")" == *"cannot resolve target directory"* \
   && "$(cat "$E246/f1g.err")" == *"$E246/raw19g/dir/afile/.."* \
   && "$(cat "$E246/f1g.err")" == *"fail closed"* ]] \
    && a246 pass || a246 fail "F1 non-conforming realpath afile/.. refused (rc=$f1g_rc, out: [$f1g_out], shim: $([[ -e "$E246/raw19g/rpbin-fired" ]] && echo fired || echo not-fired), victim: $(head -c 60 "$E246/raw19g/dir/victim" 2>/dev/null))"
rm -rf "$E246/raw19g"

# 19h. EGL-424: the typed-parent refusal is a kernel IDENTITY check, not
#      a directory test. A `realpath` that returns a DIFFERENT existing
#      0700 directory for a valid typed parent passes `-d` on both
#      paths, so a `-d "$raw_dir"` check would accept and the D6 rewrite
#      would replace a file outside the typed parent (the
#      R-EGL-387-6 F1 wrong-destination class). The kernel (`-ef`,
#      device+inode) must refuse: both sentinels intact, no temp litter
#      in either directory, and the error names the typed parent.
mkdir -p "$E246/id19h/dir" "$E246/id19h/other" "$E246/id19h/rpbin"
chmod 700 "$E246/id19h" "$E246/id19h/dir" "$E246/id19h/other"
printf 'SENTINEL\n' > "$E246/id19h/dir/victim"
printf 'OTHER\n' > "$E246/id19h/other/victim"
cat > "$E246/id19h/rpbin/realpath" <<SHIM
#!/bin/bash
# EGL-424: a realpath returning a DIFFERENT existing directory for the
# valid typed parent. Exact fixture path only; every other call delegates
# to the host realpath.
if [[ "\${*: -1}" == "$E246/id19h/dir" ]]; then
    : > "$E246/id19h/rpbin-fired"
    printf '%s\n' "$E246/id19h/other"
    exit 0
fi
exec "$E246_RP_REAL" "\$@"
SHIM
chmod +x "$E246/id19h/rpbin/realpath"
f1h_out="$(env PATH="$E246/id19h/rpbin:$PATH" \
    ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/id19h/dir/victim" 2>"$E246/f1h.err")"; f1h_rc=$?
[[ "$f1h_rc" == 1 && -z "$f1h_out" \
   && -e "$E246/id19h/rpbin-fired" \
   && "$(cat "$E246/id19h/dir/victim")" == "SENTINEL" \
   && "$(cat "$E246/id19h/other/victim")" == "OTHER" \
   && -z "$(find "$E246/id19h" -name 'victim.*' 2>/dev/null)" \
   && "$(cat "$E246/f1h.err")" == *"cannot resolve target directory '$E246/id19h/dir'"* \
   && "$(cat "$E246/f1h.err")" == *"fail closed"* ]] \
    && a246 pass || a246 fail "F1 realpath wrong-directory parent refused (rc=$f1h_rc, out: [$f1h_out], shim: $([[ -e "$E246/id19h/rpbin-fired" ]] && echo fired || echo not-fired), dir: $(head -c 60 "$E246/id19h/dir/victim" 2>/dev/null), other: $(head -c 60 "$E246/id19h/other/victim" 2>/dev/null))"
rm -rf "$E246/id19h"

# 20. EGL-246-D19 (item 5) / EGL-387-D6: a symlink to a PRIVATE parent is
#     accepted — the file lands in the canonical referent; stdout is the
#     REAL path of the file written (the canonical referent, not the
#     caller's typed link spelling).
mkdir -p "$E246/privdir"; chmod 700 "$E246/privdir"
ln -sfn "$E246/privdir" "$E246/privlnk"
w5_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/privlnk/typed.env" 2>"$E246/w5.err")"; w5_rc=$?
[[ "$w5_rc" == 0 && "$w5_out" == "$E246/privdir/typed.env" \
   && "$(stat -c %a "$E246/privdir/typed.env")" == "600" \
   && ! "$(cat "$E246/w5.err")" == *"group-writable"* ]] \
    && a246 pass || a246 fail "D19 symlink-to-private parent (rc=$w5_rc, out: $w5_out)"
rm -f "$E246/privdir/typed.env"

# 20b. EGL-387-D6 / R-EGL-387-3 F1: the printed path is the file in the
#      checked parent, not a mutable symlink spelling. A parent symlink
#      inside a sticky 1777 directory starts at the account's 0700
#      directory; after the write succeeds the link is repointed at
#      another directory. Reading the PRINTED path must still return the
#      assignments we wrote — never whatever the link names now.
mkdir -p "$E246/sticky/private" "$E246/sticky/elsewhere"
chmod 1777 "$E246/sticky"
chmod 700 "$E246/sticky/private" "$E246/sticky/elsewhere"
ln -sfn "$E246/sticky/private" "$E246/sticky/parent"
f1p_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E246/gw.conf")" \
    egresslock proxy-env gw --out="$E246/sticky/parent/sticky.env" 2>/dev/null)"; f1p_rc=$?
ln -sfn "$E246/sticky/elsewhere" "$E246/sticky/parent"
printf 'HTTP_PROXY=http://192.0.2.99:8888\n' > "$E246/sticky/elsewhere/sticky.env"
if [[ "$f1p_rc" == 0 && "$f1p_out" == "$E246/sticky/private/sticky.env" \
      && "$(cat "$f1p_out" 2>/dev/null)" == *"HTTP_PROXY=http://10.199.70.2:3128"* \
      && "$(cat "$f1p_out" 2>/dev/null)" != *"192.0.2.99"* ]]; then
    a246 pass
else
    a246 fail "D6 sticky-symlink printed path (rc=$f1p_rc, out: $f1p_out, content: $(cat "$f1p_out" 2>/dev/null | tr '\n' '|'))"
fi
rm -rf "$E246/sticky"

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
#     litter. (`realpath` is strict since R-EGL-387-6 F1, so a shim
#     there could fire deterministically; the stat leg carries S2 here.)
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

# 24. EGL-398: the engine help topic names the bare `--out` as the
#     recommended form and an explicit `--out=<path>` as the backup, with
#     the unchanged group-/world-write refusal and the `--env` fallback;
#     it still names the printed path as the real file path; no promise
#     of a future tightening / acceptance / always-qualifying default.
h246_full="$(egresslock help proxy-env 2>&1)"
[[ "$h246_full" == *"The recommended way to write the env file is the bare --out form:"* \
   && "$h246_full" == *"Use --out=<path> only as a backup when you"* \
   && "$h246_full" == *"the real path of that file"* \
   && "$h246_full" == *"(directory"* \
   && "$h246_full" == *"symlinks are resolved)."* \
   && "$h246_full" == *"a group- or world-writable directory is"* \
   && "$h246_full" == *"refused). If you cannot make the directory private,"* \
   && "$h246_full" == *"pass them to podman run with --env KEY=value."* \
   && "$h246_full" != *"future release"* \
   && "$h246_full" != *"accepted for now"* \
   && "$h246_full" != *"always qualifies"* ]] \
    && a246 pass || a246 fail "EGL-398 help topic recommended-bare --out framing missing (out: $(printf %s "$h246_full" | grep -c world-writable))"

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
    gateway 10.199.71.2 3128 s50n-allowlist
EOF
: > "$S50/s50n-allowlist"
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
sq="$(mock_cfg_file egresslock-gateway-s50 squid.conf)"
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
sq56="$(mock_cfg_file egresslock-gateway-s56 squid.conf)"
[[ "$a56_rc" == 0 && -n "$sq56" && "$(grep -m1 'dns_nameservers' "$sq56")" == "dns_nameservers 169.254.1.1" ]] \
    && a56 pass || a56 fail "D default unset → 169.254.1.1 (rc=$a56_rc sq=[$sq56] $(grep -m1 dns_nameservers "$sq56" 2>/dev/null))"

# single valid + two valid still work.
for val in "8.8.8.8" "8.8.8.8 1.1.1.1"; do
    ARCMOCK_PASSWD_HOME="$(conf_home "$S56/s56.conf")" egresslock teardown s56 >/dev/null 2>&1 || true
    a56_out="$(GW_DNS_NAMESERVERS="$val" ARCMOCK_PASSWD_HOME="$(conf_home "$S56/s56.conf")" egresslock ensure s56 2>&1)"; a56_rc=$?
    sq56="$(mock_cfg_file egresslock-gateway-s56 squid.conf)"
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

# --- ARC-58/EGL-381: the gateway allowlist is the profile's pair half ---
# Only "<profile>-allowlist" loads (EGL-381-D2): no '/', no '..'
# segment, no other basename, and no absolute path.
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
    [[ "$a58_rc" == 2 && "$a58_out" == *"expected 'g-allowlist'"* ]] \
        && a58 pass || a58 fail "D bad relative '$bad' not rejected (rc=$a58_rc, out: $a58_out)"
done

# normal relative basename still loads.
cat > "$S58/ok.conf" <<'EOF'
profile g 10.199.74.0/24
    rule gateway-only
    gateway 10.199.74.2 3128 g-allowlist
EOF
: > "$S58/g-allowlist"
a58_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S58/ok.conf")" egresslock list 2>&1)"; a58_rc=$?
if [[ "$a58_rc" == 0 ]] && grep -qE '^g[[:space:]]' <<<"$a58_out"; then
    a58 pass
else
    a58 fail "D normal relative basename loads (rc=$a58_rc, out: $a58_out)"
fi

# EGL-80-L6/EGL-381-D1: absolute allowlist path — under TESTROOT, not a
# fixed shared /tmp file (no real-environment write, no cross-run
# collision) — is now refused, naming the pair half. The file exists, so
# the refusal is the name rule, not a missing file.
abs58="$TESTROOT/s58-abs-allowlist"
cat > "$S58/abs.conf" <<EOF
profile a2 10.199.75.0/24
    rule gateway-only
    gateway 10.199.75.2 3128 $abs58
EOF
: > "$abs58"
a58_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S58/abs.conf")" egresslock list 2>&1)"; a58_rc=$?
if [[ "$a58_rc" == 2 && "$a58_out" == *"expected 'a2-allowlist'"* \
      && "$a58_out" != *"a2 " ]]; then
    a58 pass
else
    a58 fail "D absolute path refused naming the pair half (rc=$a58_rc, out: $a58_out)"
fi

section_end arc58

# --- EGL-381: the allowlist pairing (no cross-wire) -----------------------
# A conf naming another profile's allowlist no longer loads; `allow` on it
# exits 2 before the lane line/append, so the other profile's bytes stay
# untouched. With the pair name the same probe appends to its own file.
section_begin egl381 "EGL-381 allowlist pairing"
a381() { assert "$@"; }

S381="$TESTROOT/s381"; rm -rf "$S381"; mkdir -p "$S381"
cat > "$S381/main.conf" <<'EOF'
profile main 10.199.140.0/24
    rule gateway-only
    gateway 10.199.140.2 3128 main-allowlist
EOF
printf 'main.example.test\n' > "$S381/main-allowlist"
cat > "$S381/x.conf" <<'EOF'
profile x 10.199.141.0/24
    rule gateway-only
    gateway 10.199.141.2 3128 main-allowlist
EOF
main381_sum="$(sha256sum "$S381/main-allowlist" | cut -d' ' -f1)"

# 1. Aggregate load refuses the cross-wired conf: names the conf line and
#    the expected pair half.
e381_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S381")" egresslock list 2>&1)"; e381_rc=$?
if [[ "$e381_rc" == 2 \
      && "$e381_out" == *"x.conf:3:"* \
      && "$e381_out" == *"expected 'x-allowlist'"* \
      && "$e381_out" == *"offending line:"*"gateway 10.199.141.2 3128 main-allowlist"* \
      && "$e381_out" == *"copy the entries you intend"* \
      && "$e381_out" == *"do not move a shared or externally owned file"* ]]; then
    a381 pass
else
    a381 fail "cross-wired conf refused named with safe-copy guidance (rc=$e381_rc, out: $e381_out)"
fi

# 1b. The same aggregate load failure hits the timer's `verify --ensured`
#     (one legacy conf breaks the whole account, not only `ensure`).
e381_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S381")" egresslock verify --ensured 2>&1)"; e381_rc=$?
if [[ "$e381_rc" == 2 && "$e381_out" == *"expected 'x-allowlist'"* ]]; then
    a381 pass
else
    a381 fail "verify --ensured refuses the cross-wired conf (rc=$e381_rc, out: $e381_out)"
fi

# 2. `allow x` refuses before the path line and writes nothing: the named
#    profile's file is untouched (the EGL-368 live probe).
e381_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S381")" egresslock allow x shared.example 2>&1)"; e381_rc=$?
if [[ "$e381_rc" == 2 && "$e381_out" == *"expected 'x-allowlist'"* \
      && "$e381_out" != *"path:"* && "$e381_out" != *"added:"* \
      && "$(sha256sum "$S381/main-allowlist" | cut -d' ' -f1)" == "$main381_sum" ]]; then
    a381 pass
else
    a381 fail "cross-wire allow refused, no path/append, bytes unchanged (rc=$e381_rc, out: $e381_out)"
fi

# 3. Safe migration (R-EGL-381-4 F1): COPY the source entries into
#    x-allowlist (never move main's file), then name the pair half. The
#    copied entry stays; `allow x` appends only to x-allowlist and
#    main-allowlist's bytes stay untouched.
cp -p "$S381/main-allowlist" "$S381/x-allowlist"
cat > "$S381/x.conf" <<'EOF'
profile x 10.199.141.0/24
    rule gateway-only
    gateway 10.199.141.2 3128 x-allowlist
EOF
mkdir -p "$STATE/ips" "$STATE/containers"
: > "$STATE/running/egresslock-gateway-x"
echo "egresslock-x" > "$STATE/containers/egresslock-gateway-x.net"
echo "10.199.141.2" > "$STATE/containers/egresslock-gateway-x.ip"
e381_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S381")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow x shared.example 2>&1)"; e381_rc=$?
if [[ "$e381_rc" == 0 && "$e381_out" == *"path: proxy — gateway allowlist "*"x-allowlist"* \
      && "$e381_out" == *"added: shared.example"* \
      && -f "$S381/main-allowlist" \
      && "$(grep -cxF 'main.example.test' "$S381/x-allowlist")" == 1 \
      && "$(grep -cxF 'shared.example' "$S381/x-allowlist")" == 1 \
      && "$(sha256sum "$S381/main-allowlist" | cut -d' ' -f1)" == "$main381_sum" ]]; then
    a381 pass
else
    a381 fail "safe copy migrates; pair-named allow appends to x-allowlist only (rc=$e381_rc, out: $e381_out)"
fi

# 4. R-EGL-381-8 F1: load_config trims [[:space:]] before matching a
#    directive, so a gateway line indented after a leading CR/VT is
#    engine-accepted. The importer must recognize the same forms (kit
#    egl328 8c) or it would import the conf without its pair.
for lead in cr vt; do
    case "$lead" in
        cr) lpre=$'\r' ;;
        vt) lpre=$'\v' ;;
    esac
    p="w$lead"
    d="$S381/ws-$lead"; rm -rf "$d"; mkdir -p "$d"
    printf 'profile %s 10.199.143.0/24\n    rule gateway-only\n%s    gateway 10.199.143.2 3128 %s-allowlist\n' \
        "$p" "$lpre" "$p" > "$d/$p.conf"
    printf 'ws.example.test\n' > "$d/$p-allowlist"
    e381_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$d")" egresslock list 2>&1)"; e381_rc=$?
    if [[ "$e381_rc" == 0 && "$e381_out" == *"$p"* ]]; then
        a381 pass
    else
        a381 fail "$lead-prefixed gateway loads (rc=$e381_rc, out: $e381_out)"
    fi
done

section_end egl381

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
# gateway run. Message points the operator at a runnable canonical direct
# retry (EGL-365-D12: a bare literal names the required port and a real
# :443 example, never a `:<port>` placeholder; a leading dot is stripped).
for lit in '203.0.113.7:11434' '10.1.2.3' '.10.1.2.3'; do
    pre_md5="$(md5sum "$S51/s51-allowlist" | cut -d' ' -f1)"
    pre_runs="$(wc -l < "$STATE/runlog")"
    a51_out="$(ARCMOCK_PASSWD_HOME="$(conf_home "$S51/s51.conf")" egresslock allow s51 "$lit" 2>&1)"; a51_rc=$?
    post_md5="$(md5sum "$S51/s51-allowlist" | cut -d' ' -f1)"
    post_runs="$(wc -l < "$STATE/runlog")"
    if [[ "$lit" == *:* ]]; then
        a51_want="retry with --direct: egresslock allow s51 ${lit#.} --direct"
    else
        a51_want="the direct path requires a port, e.g. retry with: egresslock allow s51 ${lit#.}:443 --direct"
    fi
    if [[ "$a51_rc" == 2 && "$pre_md5" == "$post_md5" && "$post_runs" == "$pre_runs" \
          && "$a51_out" == *"$a51_want"* \
          && "$a51_out" != *"allow-host"* ]]; then
        a51 pass
    else
        a51 fail "D1.1 allow literal [$(printf %q "$lit")] (rc=$a51_rc unchanged=$([ "$pre_md5" == "$post_md5" ] && echo yes || echo no) newruns=$((post_runs-pre_runs)) msg=$a51_out)"
    fi
done

# D1.2 — a literal line in the allowlist file fails `ensure` closed (fail
# closed, not skipped), and the recovery names the file to edit first —
# the direct pin cannot run while the bad line is still there.
a51_home="$(conf_home "$S51/s51.conf")"
a51_al="$a51_home/.config/egresslock/s51-allowlist"
printf '10.1.2.3\n' > "$S51/s51-allowlist"
a51_out="$(ARCMOCK_PASSWD_HOME="$a51_home" egresslock ensure s51 2>&1)"; a51_rc=$?
[[ "$a51_rc" != 0 \
   && "$a51_out" == *"remove that line from $a51_al, then add a direct pin with the service port (e.g. egresslock allow s51 10.1.2.3:443 --direct)"* ]] \
    && a51 pass || a51 fail "D1.2 literal allowlist line fails ensure closed with file-named recovery (rc=$a51_rc, out: $a51_out)"
# D1.2r — execute that printed recovery: remove the line from the named
# file, extract the printed pin command and run that string (D12(e)).
# The pin's own re-ensure and a later ensure are green (the old wording
# printed a dead-end command that re-read the same bad line).
{ grep -vxF '10.1.2.3' "$a51_al" || true; } > "$S51/s51-fix.tmp"
mv "$S51/s51-fix.tmp" "$a51_al"
a51_cmd="$(sed -n 's/.*(e\.g\. \(egresslock .*\))$/\1/p' <<<"$a51_out")"
if [[ "$a51_cmd" == "egresslock allow s51 10.1.2.3:443 --direct" ]]; then
    a51 pass
else
    a51 fail "D1.2r bare-host recovery command parses (cmd=[$a51_cmd], out: $a51_out)"
fi
a51_out="$(EGRESSLOCK_MOCK_DNS="10.1.2.3=10.1.2.3" ARCMOCK_PASSWD_HOME="$a51_home" bash -c "$a51_cmd" 2>&1)"; a51_rc=$?
a51b_out="$(ARCMOCK_PASSWD_HOME="$a51_home" egresslock ensure s51 2>&1)"; a51b_rc=$?
[[ "$a51_rc" == 0 && "$a51b_rc" == 0 && "$(grep -c 'rule allow-host 10.1.2.3:443' "$S51/s51.conf")" == 1 ]] \
    && a51 pass || a51 fail "D1.2r printed bare-host recovery reaches green (allow rc=$a51_rc, ensure rc=$a51b_rc, out: $a51_out)"
printf '203.0.113.7:11434\n' > "$S51/s51-allowlist"
a51_out="$(ARCMOCK_PASSWD_HOME="$a51_home" egresslock ensure s51 2>&1)"; a51_rc=$?
[[ "$a51_rc" != 0 \
   && "$a51_out" == *"remove that line from $a51_al, then add the direct pin: egresslock allow s51 203.0.113.7:11434 --direct"* ]] \
    && a51 pass || a51 fail "D1.2b literal:port allowlist line fails ensure closed with file-named recovery (rc=$a51_rc, out: $a51_out)"
# D1.2c — extract that printed recovery command (D12(e)): remove the
# line, run the emitted pin; green re-ensure, no dead end.
{ grep -vxF '203.0.113.7:11434' "$a51_al" || true; } > "$S51/s51-fix.tmp"
mv "$S51/s51-fix.tmp" "$a51_al"
a51_cmd="$(sed -n 's/.*then add the direct pin: \(egresslock .*\)$/\1/p' <<<"$a51_out")"
if [[ "$a51_cmd" == "egresslock allow s51 203.0.113.7:11434 --direct" ]]; then
    a51 pass
else
    a51 fail "D1.2c literal:port recovery command parses (cmd=[$a51_cmd], out: $a51_out)"
fi
a51_out="$(EGRESSLOCK_MOCK_DNS="203.0.113.7=203.0.113.7" ARCMOCK_PASSWD_HOME="$a51_home" bash -c "$a51_cmd" 2>&1)"; a51_rc=$?
a51b_out="$(ARCMOCK_PASSWD_HOME="$a51_home" egresslock ensure s51 2>&1)"; a51b_rc=$?
[[ "$a51_rc" == 0 && "$a51b_rc" == 0 && "$(grep -c 'rule allow-host 203.0.113.7:11434' "$S51/s51.conf")" == 1 ]] \
    && a51 pass || a51 fail "D1.2c printed literal:port recovery reaches green (allow rc=$a51_rc, ensure rc=$a51b_rc, out: $a51_out)"
# D1.2d/D1.2e (EGL-365-D12(a)): a leading-dot IPv4 in the file recovers
# with the STRIPPED pin-grammar token — the printed dotted token is not
# runnable. Execute both printed recoveries to green.
printf '.198.51.100.9\n' > "$S51/s51-allowlist"
a51_out="$(ARCMOCK_PASSWD_HOME="$a51_home" egresslock ensure s51 2>&1)"; a51_rc=$?
[[ "$a51_rc" != 0 \
   && "$a51_out" == *"remove that line from $a51_al, then add a direct pin with the service port (e.g. egresslock allow s51 198.51.100.9:443 --direct)"* \
   && "$a51_out" != *".198.51.100.9:443 --direct"* ]] \
    && a51 pass || a51 fail "D1.2d dotted bare literal recovery strips the dot (rc=$a51_rc, out: $a51_out)"
{ grep -vxF '.198.51.100.9' "$a51_al" || true; } > "$S51/s51-fix.tmp"
mv "$S51/s51-fix.tmp" "$a51_al"
a51_cmd="$(sed -n 's/.*(e\.g\. \(egresslock .*\))$/\1/p' <<<"$a51_out")"
if [[ "$a51_cmd" == "egresslock allow s51 198.51.100.9:443 --direct" ]]; then
    a51 pass
else
    a51 fail "D1.2d bare-host recovery command parses (cmd=[$a51_cmd], out: $a51_out)"
fi
a51_out="$(EGRESSLOCK_MOCK_DNS="198.51.100.9=198.51.100.9" ARCMOCK_PASSWD_HOME="$a51_home" bash -c "$a51_cmd" 2>&1)"; a51_rc=$?
[[ "$a51_rc" == 0 && "$(grep -c 'rule allow-host 198.51.100.9:443' "$S51/s51.conf")" == 1 ]] \
    && a51 pass || a51 fail "D1.2d printed bare-host recovery reaches green (allow rc=$a51_rc, out: $a51_out)"
printf '.198.51.100.10:11434\n' > "$S51/s51-allowlist"
a51_out="$(ARCMOCK_PASSWD_HOME="$a51_home" egresslock ensure s51 2>&1)"; a51_rc=$?
[[ "$a51_rc" != 0 \
   && "$a51_out" == *"remove that line from $a51_al, then add the direct pin: egresslock allow s51 198.51.100.10:11434 --direct"* \
   && "$a51_out" != *".198.51.100.10:11434 --direct"* ]] \
    && a51 pass || a51 fail "D1.2e dotted literal:port recovery strips the dot (rc=$a51_rc, out: $a51_out)"
{ grep -vxF '.198.51.100.10:11434' "$a51_al" || true; } > "$S51/s51-fix.tmp"
mv "$S51/s51-fix.tmp" "$a51_al"
a51_cmd="$(sed -n 's/.*then add the direct pin: \(egresslock .*\)$/\1/p' <<<"$a51_out")"
if [[ "$a51_cmd" == "egresslock allow s51 198.51.100.10:11434 --direct" ]]; then
    a51 pass
else
    a51 fail "D1.2e literal:port recovery command parses (cmd=[$a51_cmd], out: $a51_out)"
fi
a51_out="$(EGRESSLOCK_MOCK_DNS="198.51.100.10=198.51.100.10" ARCMOCK_PASSWD_HOME="$a51_home" bash -c "$a51_cmd" 2>&1)"; a51_rc=$?
[[ "$a51_rc" == 0 && "$(grep -c 'rule allow-host 198.51.100.10:11434' "$S51/s51.conf")" == 1 ]] \
    && a51 pass || a51 fail "D1.2e printed literal:port recovery reaches green (allow rc=$a51_rc, out: $a51_out)"

# D2.1 — a conf `rule allow-host <literal>:<port>` still loads (D2: the
# allow-host path takes hostname or IPv4 literal).
cat > "$S51/ah.conf" <<'EOF'
profile ah 10.199.77.0/24
    rule allow-host 10.1.2.3:443
    gateway 10.199.77.2 3128 ah-allowlist
EOF
: > "$S51/ah-allowlist"
a51_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S51/ah.conf")" egresslock list 2>&1)"; a51_rc=$?
[[ "$a51_rc" == 0 ]] && a51 pass || a51 fail "D2.1 conf rule allow-host literal loads (rc=$a51_rc, out: $a51_out)"

# D2.2 — CLI allow-host of a literal inserts the rule and re-ensures (mock
# DNS echoes the literal like real getent ahostsv4, ARC-12 drift knob).
cat > "$S51/s51b.conf" <<'EOF'
profile s51b 10.199.78.0/24
    rule gateway-only
    gateway 10.199.78.2 3128 s51b-allowlist
EOF
: > "$S51/s51b-allowlist"
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
printf 'profile dev-llm 10.199.81.0/24\n    gateway 10.199.81.2 3128 dev-llm-allowlist\n' > "$S59/ok.conf"
: > "$S59/dev-llm-allowlist"
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
[[ "$a59_rc" == 2 && "$a59_out" == *"unknown allow option '--help:443'"* ]] \
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
    gateway 10.199.84.2 3128 s59b-allowlist
EOF
: > "$S59/s59b-allowlist"
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
    gateway 10.199.85.2 3128 s59c-allowlist
EOF
: > "$S59/s59c-allowlist"
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

# D1.10 (EGL-380) — 'all' is reserved: a legacy `profile all` conf fails
# the loader (list) before any profile row, and a named command refuses
# before the not-found probe when no all.conf exists.
S59ALL="$TESTROOT/s59-all"; rm -rf "$S59ALL"; mkdir -p "$S59ALL"
cat > "$S59ALL/all.conf" <<'EOF'
profile all 10.199.85.0/24
    rule gateway-only
    gateway 10.199.85.2 3128 all-allowlist
EOF
: > "$S59ALL/all-allowlist"
a59_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S59ALL/all.conf")" egresslock list 2>&1)"; a59_rc=$?
if [[ "$a59_rc" == 2 && "$a59_out" == *"reserved"* \
      && "$a59_out" == *"teardown all"* \
      && "$a59_out" == *"rename this profile and its conf file"* \
      && "$a59_out" != *"NAME"* ]]; then
    a59 pass
else
    a59 fail "D1.10 legacy all.conf fails list closed (rc=$a59_rc, out: $a59_out)"
fi
mkdir -p "$S59ALL/empty-home"
a59_out="$(ARCMOCK_PASSWD_HOME="$S59ALL/empty-home" egresslock ensure all 2>&1)"; a59_rc=$?
if [[ "$a59_rc" == 2 && "$a59_out" == *"reserved"* \
      && "$a59_out" == *"teardown all"* \
      && "$a59_out" != *"no profile config"* && "$a59_out" != *"using config"* ]]; then
    a59 pass
else
    a59 fail "D1.10 ensure all refuses before the conf probe (rc=$a59_rc, out: $a59_out)"
fi

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
D1_NOTE="note: IPv4 destinations are not allowlist hostnames — use --direct: egresslock allow <profile> <ip:port> --direct. Proxied clients 403 unless the IP is in NO_PROXY (proxy-env includes direct IPv4 pins; recreate the workload)."
D2_NOTE="note: IPv4 direct pins are included in proxy-env NO_PROXY; recreate running workloads to pick up the new env."

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

# 5. EGL-366-D3: the old "IPv4 allow-host on a NON-gateway profile ->
#    no hint" shape no longer loads — it is a named refusal, nothing
#    written. Its own confdir keeps the shared $S18 aggregate clean.
mkdir -p "$S18/nogw"
cat > "$S18/nogw/s18d.conf" <<'EOF'
profile s18d 10.199.88.0/24
    rule allow-host 10.1.2.3:11434
EOF
h18n_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S18/nogw/s18d.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host s18d 10.1.2.3:8080 2>&1)"; h18n_rc=$?
if [[ "$h18n_rc" == 2 && "$h18n_out" == *"profile 's18d' has no 'gateway' directive"* \
      && "$h18n_out" == *"fix: add a gateway line to this conf"* \
      && "$(grep -c 'rule allow-host 10.1.2.3:8080' "$S18/nogw/s18d.conf")" == 0 ]]; then
    a18 pass
else
    a18 fail "gateway-less allow-host refused named (rc=$h18n_rc, out: $h18n_out)"
fi

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
# foreign-object family is NOT swept).
section_begin arc60 "ARC-60 runtime sweep"
a60() { assert "$@"; }

# Fixture: the dogfood-host shape — foreign containers/network not owned
# by the kit still up with NO conf anywhere, plus current kit objects,
# plus non-kit names that must survive.
H60="$TESTROOT/h60"; rm -rf "$H60"; mkdir -p "$H60"
mk_a60_runtime() {
    rm -rf "$STATE/networks" "$STATE/running" "$STATE/containers" "$STATE/ips"
    mkdir -p "$STATE/networks" "$STATE/running" "$STATE/containers" "$STATE/ips"
    # foreign objects not owned by the kit (conf deleted)
    : > "$STATE/running/other-tool-gateway"; echo "other-tool-net" > "$STATE/containers/other-tool-gateway.net"
    : > "$STATE/running/other-tool-anchor";  echo "other-tool-net" > "$STATE/containers/other-tool-anchor.net"
    printf 'driver=bridge\nsubnet=192.0.2.0/24\n' > "$STATE/networks/other-tool-net"
    # current kit objects
    : > "$STATE/running/egresslock-anchor-main"; echo "egresslock-main" > "$STATE/containers/egresslock-anchor-main.net"
    printf 'driver=bridge\nsubnet=10.199.0.0/24\n' > "$STATE/networks/egresslock-main"
    # non-kit: an arbitrary user container
    : > "$STATE/running/user-container"; echo "podman-default" > "$STATE/containers/user-container.net"
}
run_a60() { env HOME="$H60" ARCMOCK_PASSWD_HOME="$H60" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }

# 1. --runtime sweeps the egresslock-* generation only (ARC-68-D1: the
#    seeded foreign objects SURVIVE); a set EGRESSLOCK_CONF only warns
#    (EGL-385) and is never loaded.
mk_a60_runtime
a60_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H60/nope.conf")" HOME="$H60" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock teardown --runtime 2>&1)"; a60_rc=$?
if [[ "$a60_rc" == 0 \
      && "$a60_out" == *"removed container egresslock-anchor-main"* \
      && "$a60_out" == *"removed network egresslock-main"* ]] \
   && [[ -f "$STATE/running/other-tool-gateway" && -f "$STATE/running/other-tool-anchor" \
      && -f "$STATE/networks/other-tool-net" \
      && ! -e "$STATE/running/egresslock-anchor-main" && ! -e "$STATE/networks/egresslock-main" ]] \
   && [[ -f "$STATE/running/user-container" ]] \
   && [[ "$a60_out" != *"removed container other-tool-"* && "$a60_out" != *"removed network other-tool-"* \
      && "$a60_out" != *"user-container"* ]]; then
    a60 pass
else
    a60 fail "D1 --runtime sweeps egresslock-* only, foreign objects survive (rc=$a60_rc, out: $a60_out)"
fi

# 1b. ARC-68-D1: the leftover foreign objects are untouched by the
#     sweep — a second --runtime still says `no kit runtime` (foreign
#     names do not count as kit runtime).
a60d_out="$(run_a60 teardown --runtime 2>&1)"; a60d_rc=$?
[[ "$a60d_rc" == 0 && "$a60d_out" == *"no kit runtime"* \
    && -f "$STATE/running/other-tool-gateway" && -f "$STATE/networks/other-tool-net" ]] \
    && a60 pass || a60 fail "D1 foreign leftovers are invisible to --runtime (rc=$a60d_rc, out: $a60d_out)"

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
printf 'profile c32 10.199.91.0/24\n    rule allow-host %s:443\n    gateway 10.199.91.2 3128 c32-allowlist\n' \
    "$(printf 'a%.0s' $(seq 1 254))" > "$A32/ah-bad.conf"
: > "$A32/c32-allowlist"
d32_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$A32/ah-bad.conf")" egresslock list 2>&1)"; d32_rc=$?
[[ "$d32_rc" == 2 && "$d32_out" == *"exceeds DNS length limits"* ]] \
    && a32 pass || a32 fail "D2.3 conf allow-host oversize (rc=$d32_rc out=$d32_out)"
printf 'profile c32 10.199.91.0/24\n    no-proxy %s\n    gateway 10.199.91.2 3128 c32-allowlist\n' \
    "$(printf 'a%.0s' $(seq 1 254))" > "$A32/np-bad.conf"
: > "$A32/c32-allowlist"
d32_out="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$A32/np-bad.conf")" egresslock list 2>&1)"; d32_rc=$?
[[ "$d32_rc" == 2 && "$d32_out" == *"exceeds DNS length limits"* ]] \
    && a32 pass || a32 fail "D2.3 conf no-proxy oversize (rc=$d32_rc out=$d32_out)"
# Label > 63 in conf (host under 253) is rejected too.
printf 'profile c32 10.199.91.0/24\n    rule allow-host %s.test:443\n    gateway 10.199.91.2 3128 c32-allowlist\n' "${L63}x" > "$A32/ah-label.conf"
: > "$A32/c32-allowlist"
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
# names the real cause in `init` (EGL-383), and only notes for --runtime.
section_begin arc67 "ARC-67 network ls"
a67() { assert "$@"; }

# Failing-list podman shim: delegates to the mock except network ls.
S67="$TESTROOT/s67"; rm -rf "$S67"; mkdir -p "$S67/bin" "$S67/conf"
printf 'profile s67 10.199.92.0/24\n    gateway 10.199.92.2 3128 s67-allowlist\n' > "$S67/conf/s67.conf"
: > "$S67/conf/s67-allowlist"
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

# 3. init with a failing list refuses with the ensure diagnosis (EGL-383),
#    never the misleading overlap message, and writes no pair.
o="$(run67 init fresh67 --subnet 10.199.93.0/24 2>&1)"; rc=$?
if [[ "$rc" == 1 \
      && "$o" == *"cannot list Podman networks; the subnet-overlap pre-check cannot run (fail closed): mock podman: network list failure"* \
      && "$o" != *"overlaps an existing"* \
      && ! -e "$S67/conf/fresh67.conf" && ! -e "$S67/conf/fresh67-allowlist" ]]; then
    a67 pass
else
    a67 fail "D3 init --subnet names the list failure (rc=$rc, out: $o)"
fi

# 4. init auto-pick with a failing list: same line, never "no free /24",
#    and no pair on disk.
o="$(run67 init fresh67-auto 2>&1)"; rc=$?
if [[ "$rc" == 1 \
      && "$o" == *"cannot list Podman networks; the subnet-overlap pre-check cannot run (fail closed): mock podman: network list failure"* \
      && "$o" != *"no free /24"* \
      && ! -e "$S67/conf/fresh67-auto.conf" && ! -e "$S67/conf/fresh67-auto-allowlist" ]]; then
    a67 pass
else
    a67 fail "D3 init auto-pick names the list failure (rc=$rc, out: $o)"
fi

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
printf 'profile main 10.199.0.0/24\n    gateway 10.199.0.2 3128 main-allowlist\n' > "$H71/main.conf"
: > "$H71/main-allowlist"
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
H69_CF="$(conf_home "$H69/main.conf")/.config/egresslock"
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
printf 'profile z9 10.199.88.0/24\n    gateway 10.199.88.2 3128 z9-allowlist\n' > "$H69/z9.conf"
: > "$H69/z9-allowlist"
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

# 3c. EGL-380: a legacy all.conf makes `teardown all` refuse (rc 2) —
#     it must never read main.conf and tear main down on the operator's
#     behalf. Main's live objects and all's objects stay in place.
run69 ensure main >/dev/null 2>&1
cat > "$H69/all.conf" <<'EOF'
profile all 10.199.89.0/24
    rule gateway-only
    gateway 10.199.89.2 3128 all-allowlist
EOF
: > "$H69/all-allowlist"
: > "$STATE/running/egresslock-anchor-all"
echo "egresslock-all" > "$STATE/containers/egresslock-anchor-all.net"
printf 'driver=bridge\nsubnet=10.199.89.0/24\n' > "$STATE/networks/egresslock-all"
o="$(run69 teardown all 2>&1)"; rc=$?
if [[ "$rc" == 2 \
      && "$o" == *"refusing 'teardown all'"* \
      && "$o" == *"$H69_CF/all.conf"* && "$o" == *"$H69_CF/main.conf"* \
      && "$o" == *"reserved"* && "$o" != *"using config"* \
      && -f "$STATE/running/egresslock-anchor-main" \
      && -f "$STATE/running/egresslock-gateway-main" \
      && -f "$STATE/networks/egresslock-main" \
      && -f "$STATE/running/egresslock-anchor-all" \
      && -f "$STATE/networks/egresslock-all" ]]; then
    a69 pass
else
    a69 fail "EGL-380 teardown all refuses on all.conf, main untouched (rc=$rc, out: $o)"
fi
# Control: with all.conf moved aside, `teardown all` is main-only as today.
mv "$H69/all.conf" "$H69/all.conf.legacy"
o="$(run69 teardown all 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"using config $H69_CF/main.conf"* \
      && "$o" == *"removed anchor egresslock-anchor-main"* \
      && ! -e "$STATE/running/egresslock-anchor-main" ]]; then
    a69 pass
else
    a69 fail "EGL-380 teardown all main-only once all.conf is gone (rc=$rc, out: $o)"
fi
rm -f "$STATE/running/egresslock-anchor-all" "$STATE/containers/egresslock-anchor-all.net" \
    "$STATE/networks/egresslock-all" "$H69/all.conf.legacy" "$H69/all-allowlist"

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
: > "$SA202/running/user-container"
echo "egresslock-main" > "$SA202/containers/user-container.net"
touch "$SA202/network-rm-fails"
o="$(run_egl202 "$SA202" teardown --runtime 2>&1)"; rc=$?
[[ "$rc" == 0 \
    && "$o" == *"removed container egresslock-anchor-main"* \
    && "$o" == *"kept network egresslock-main (in use)"* \
    && "$o" == *"removed nft table inet egresslock"* \
    && -f "$SA202/running/user-container" \
    && -f "$SA202/containers/user-container.net" \
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
# override (honored only with EGRESSLOCK_KIT_ALLOW_NON_ROOT=1; default
# unset = the real /proc sysctl), so doctor's rc never depends on the
# host's userns state. Fixture: $TESTROOT/userns-on holds
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
d_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
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
d_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
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
d_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" PATH="$stub45:$PATH" egresslock doctor 2>/dev/null)"
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
d_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$stub45:$PATH" egresslock doctor 2>"$d_err")"; d_rc=$?
[[ "$d_rc" == 0 && "$d_out" == *"rootless_netns: fail:cgroup manager died unexpectedly"* \
    && "$(grep -c 'apparmor check' "$d_err")" == 0 ]] \
    && a45 pass || a45 fail "non-apparmor netns failure keeps rc 0, no apparmor hint (rc=$d_rc, err: $(cat "$d_err"))"

# 4f. EGL-347-D1: a cannot-chdir probe is excluded from the AppArmor
# shape rule (it is rc 126 and contains "Permission denied") and gets
# the existing generic netns hint — no directory / sudo -iu advice.
cat > "$stub45/podman" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    --version) echo "podman version 5.4.2" ;;
    info) echo "netavark" ;;
    unshare) echo "cannot chdir to /home/ben: Permission denied" >&2; exit 126 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$stub45/podman"
d_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$stub45:$PATH" egresslock doctor 2>"$d_err")"; d_rc=$?
[[ "$d_rc" == 0 \
    && "$d_out" == *"rootless_netns: fail:cannot chdir to /home/ben: Permission denied"* \
    && "$(grep -c 'netns-inspection' "$d_err")" -ge 1 \
    && "$(grep -c 'cannot use the directory' "$d_err")" == 0 \
    && "$(grep -c 'sudo -iu' "$d_err")" == 0 \
    && "$(grep -c 'apparmor check' "$d_err")" == 0 ]] \
    && a45 pass || a45 fail "cannot-chdir netns failure gets generic hint, not AppArmor (rc=$d_rc, out: $d_out, err: $(cat "$d_err"))"

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
d_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
    PATH="$stub45:$PATH" egresslock doctor 2>&1)"; d_rc=$?
[[ "$d_rc" == 0 && "$d_out" == *"userns: enabled"* ]] \
    && a45 pass || a45 fail "userns row enabled, rc not forced (rc=$d_rc, out: $d_out)"

# 4d. hook -> fixture `0` -> `userns: disabled`, doctor rc 1.
d_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-off" \
    PATH="$stub45:$PATH" egresslock doctor 2>&1)"; d_rc=$?
[[ "$d_rc" == 1 && "$d_out" == *"userns: disabled"* ]] \
    && a45 pass || a45 fail "userns row disabled forces rc 1 (rc=$d_rc, out: $d_out)"

# 4e. hook -> absent path -> gateless message, row does not force rc 1.
d_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-absent/gate" \
    PATH="$stub45:$PATH" egresslock doctor 2>&1)"; d_rc=$?
[[ "$d_rc" == 0 \
    && "$d_out" == *"userns: enabled (kernel has no unprivileged_userns_clone gate)"* ]] \
    && a45 pass || a45 fail "userns row gateless, rc not forced (rc=$d_rc, out: $d_out)"

# 4f. EGL-382: the userns hook is test-only — without the flag it is
# ignored silently, so the `userns:` row equals the no-hook control.
# Both fixture values are tried, so the check is independent of the
# host's own sysctl value.
d_ctl="$(env -u EGRESSLOCK_KIT_ALLOW_NON_ROOT -u EGRESSLOCK_USERNS_SYSCTL \
    PATH="$stub45:$PATH" egresslock doctor 2>&1 | sed -n 's/^userns: //p')"
d_hook_bad=0
for d_fix in "$TESTROOT/userns-on" "$TESTROOT/userns-off"; do
    d_out="$(env -u EGRESSLOCK_KIT_ALLOW_NON_ROOT EGRESSLOCK_USERNS_SYSCTL="$d_fix" \
        PATH="$stub45:$PATH" egresslock doctor 2>&1)"
    d_row="$(sed -n 's/^userns: //p' <<<"$d_out")"
    [[ "$d_row" == "$d_ctl" ]] || d_hook_bad=1
done
[[ -n "$d_ctl" && "$d_hook_bad" == 0 ]] \
    && a45 pass || a45 fail "userns hook ignored without the test flag (control='$d_ctl', fixture='$d_row')"

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
d_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
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
d_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
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
    env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
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
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
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
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_USERNS_SYSCTL="$TESTROOT/userns-on" \
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
: > "$TESTROOT/deep/llm-cloud-allowlist"
: > "$TESTROOT/deep/dev-llm-allowlist"
cat > "$TESTROOT/deep/local-dev.conf" <<'EOF'
profile local-dev 10.50.0.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
    rule allow-host ${FORGEJO_HOST:-git.example.test}:2222
    rule allow-host ${OLLAMA_HOST:-cache.example.test}:11434
    gateway 10.50.0.2 3128 local-dev-allowlist
EOF
: > "$TESTROOT/deep/local-dev-allowlist"
cat > "$TESTROOT/deep/internet-only.conf" <<'EOF'
profile internet-only 10.50.1.0/24
    gateway 10.50.1.2 3128 internet-only-allowlist
EOF
: > "$TESTROOT/deep/internet-only-allowlist"
cat > "$TESTROOT/deep/llm-cloud.conf" <<'EOF'
profile llm-cloud 10.50.2.0/24
    rule gateway-only
    gateway 10.50.2.2 3128 llm-cloud-allowlist
EOF
cat > "$TESTROOT/deep/dev-llm.conf" <<'EOF'
profile dev-llm 10.50.3.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
    rule allow-host ${FORGEJO_HOST:-git.example.test}:2222
    rule allow-host ${OLLAMA_HOST:-cache.example.test}:11434
    rule gateway-only
    gateway 10.50.3.2 3128 dev-llm-allowlist
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

# The site battery's consumer wrapper ensured this chain silently on its
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
check_out "dev-llm gateway config class ACL" "acl profile_subnet src 10.50.3.0/24" \
    cat "$(mock_cfg_file egresslock-gateway-dev-llm squid.conf)"


section_end deep

# --- EGL-55: verify missing-network message points at ensure (D55-2) ------
# The network-inspect guard is the first check in verify_policy: with the
# network absent, rc 1 and the hint names `egresslock ensure <profile>`
# (bare egresslock spelling; never suggests `verify` itself).
section_begin egl55 "EGL-55 verify missing-network hint"
rm -f "$STATE/networks/egresslock-local-dev"
o="$(egresslock verify local-dev 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"verify: network egresslock-local-dev missing"* \
    && "$o" == *"missing — run: egresslock ensure local-dev (as $ENSURE_ACCT)"* \
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
# EGL-286: every help surface — the summary, all 19 command topics, and
# the config/env reference pages — is operator UI and must not leak
# ticket/decision IDs or ticket paths. The EGL-57 checks: block (already
# ID-free) must still be present in full — relocated verbatim to
# `help config` (ticket D4).
section_begin egl59 "EGL-59 help operator-UI"
h_out="$(env egresslock --help 2>&1)"; h_rc=$?
h_all="$h_out
$(env egresslock help env 2>&1)
$(env egresslock help config 2>&1)"
for c in ensure verify network proxy-env rules allowlist allowlist-direct denied allow disallow \
         allow-direct disallow-direct allow-host disallow-host \
         drop-unauthorized init list doctor build-gateway teardown; do
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
    gateway 10.199.74.2 3128 s66-allowlist
EOF
: > "$S66/s66-allowlist"
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
sq="$(mock_cfg_file egresslock-gateway-s116d squid.conf)"
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
sq="$(mock_cfg_file egresslock-gateway-s116v squid.conf)"
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
    gateway 10.199.91.2 3128 s120-allowlist
EOF
: > "$S120/s120-allowlist"
S120HOME="$(conf_home "$S120/s120.conf")"
S120CONF="$S120HOME/.config/egresslock/s120.conf"
# EGL-365-D14: the proven-never-installed branch needs a READABLE live
# chain, so seed the healthy gateway-only profile first; only then add
# the unresolvable rule and run the failing ensure. A missing chain is
# the unknown branch, not proof of absence.
env EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$S120HOME" egresslock ensure s120 >/dev/null 2>&1 \
    || a120 fail "healthy s120 chain seed"
cat > "$S120/s120.conf" <<'EOF'
profile s120 10.199.91.0/24
    rule allow-host nonexistent.example.test:8080
    gateway 10.199.91.2 3128 s120-allowlist
EOF
# EGL-106: snapshot the last consumed transaction — a rule-gen failure
# emits NO -f at all, so the failed ensure must not change it (no
# partial v6-deny file either).
egl120_lt_before="$(cat "$STATE/nft/last-transaction.nft" 2>/dev/null)"
o="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$S120HOME" egresslock ensure s120 2>&1)"; rc=$?
# EGL-365-D14: the rule was NEVER installed (no pin-record key for this
# host:port, readable chain with no pin-accept on 8080), so the hint must
# NOT recommend `disallow --direct` (it would refuse on the missing pin
# record); it names the manual conf-line deletion and says no live flows
# were opened. Mutation: drop the proof or print the old disallow retry
# -> reds here.
s120_del_line="$(sed -n "s/^hint: this rule is in .*; delete the line '\\(rule allow-host [^']*\\)' from .*$/\\1/p" <<<"$o")"
if [[ "$rc" != 0 \
      && "$o" == *"cannot resolve nonexistent.example.test"* \
      && "$o" == *"egresslock allow s120 nonexistent.example.test:8080"* \
      && "$o" == *"egresslock allow s120 169.254.1.2:8080 --direct"* \
      && "$o" == *"this rule is in $S120CONF but was not installed — no live flows were opened; delete the line 'rule allow-host nonexistent.example.test:8080' from $S120CONF"* \
      && "$s120_del_line" == "rule allow-host nonexistent.example.test:8080" \
      && "$o" != *"disallow"* \
      && "$o" != *"datatype mismatch"* \
      && "$o" != *"nft policy refresh failed"* \
      && "$o" != *"nft policy install failed"* ]]; then
    a120 pass
else
    a120 fail "unresolvable never-installed allow-host = clean abort + state-aware hints (rc=$rc, out: $o)"
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

# Execute the extracted never-installed recovery: delete the named conf
# line, re-ensure green. The entry was never installed, so no pin record
# and no dport-8080 accept may exist afterwards (the mutation leg drops
# the proof and prints an unrunnable disallow earlier).
grep -vxF "    $s120_del_line" "$S120/s120.conf" > "$S120/s120.fix"
mv "$S120/s120.fix" "$S120/s120.conf"
o="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$S120HOME" egresslock ensure s120 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"profile 's120' ready (network egresslock-s120, policy verified)"* \
      && -f "$STATE/nft/egresslock.p_s120" \
      && ! -e "$S120/s120.pins" ]] \
      && ! grep -q 'tcp dport 8080' "$STATE/nft/egresslock.p_s120"; then
    a120 pass
else
    a120 fail "manual conf-line deletion recovers green, no pin/flow (rc=$rc, out: $o, pins: $(cat "$S120/s120.pins" 2>/dev/null))"
fi

# EGL-365-D14 state-sensitive other half: when the pin record HAS the
# host:port and matches the live chain, the failed ensure left the old
# ruleset installed — the firewall still allows it — so the hint
# recommends the direct revocation, which runs to green and clears
# conf + record + chain. Extract that command and execute it (D12(e)).
cat > "$S120/s120i.conf" <<'EOF'
profile s120i 10.199.110.0/24
    rule allow-host git.example.test:8080
    gateway 10.199.110.2 3128 s120i-allowlist
EOF
: > "$S120/s120i-allowlist"
S120IHOME="$(conf_home "$S120/s120i.conf")"
o="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$S120IHOME" egresslock ensure s120i 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied, health verified"* ]] \
   && grep -qx 'git.example.test|8080 192.0.2.10' "$S120/s120i.pins" \
   && grep -q 'ip daddr 192.0.2.10 tcp dport 8080 counter accept' "$STATE/nft/egresslock.p_s120i"; then
    a120 pass
else
    a120 fail "installed-pin seed for the state-sensitive hint (rc=$rc, out: $o, pins: $(cat "$S120/s120i.pins" 2>/dev/null))"
fi
o="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$S120IHOME" \
    EGRESSLOCK_MOCK_DNS="git.example.test=" egresslock ensure s120i 2>&1)"; rc=$?
if [[ "$rc" != 0 \
      && "$o" == *"cannot resolve git.example.test"* \
      && "$o" == *"this rule was installed before the resolve failure; the running firewall still allows it — remove it and end its flows with: egresslock disallow s120i git.example.test:8080 --direct"* \
      && "$o" != *"was not installed"* && "$o" != *"delete the line"* ]]; then
    a120 pass
else
    a120 fail "installed-pin resolve failure recommends the direct revocation (rc=$rc, out: $o)"
fi
# The failed ensure is fail-closed BEFORE the swap: the already-installed
# pin accept is still live, which is exactly why the hint is state-aware.
if grep -qx 'git.example.test|8080 192.0.2.10' "$S120/s120i.pins" \
   && grep -q 'ip daddr 192.0.2.10 tcp dport 8080 counter accept' "$STATE/nft/egresslock.p_s120i"; then
    a120 pass
else
    a120 fail "failed resolve ensure leaves the installed pin live (pins: $(cat "$S120/s120i.pins" 2>/dev/null))"
fi
s120_revoke="$(sed -n 's/.*with: \(egresslock .*\)$/\1/p' <<<"$o")"
if [[ "$s120_revoke" == "egresslock disallow s120i git.example.test:8080 --direct" ]]; then
    a120 pass
else
    a120 fail "installed-pin revocation command parses (cmd=[$s120_revoke], out: $o)"
fi
o="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$S120IHOME" bash -c "$s120_revoke" 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"removed: rule allow-host git.example.test:8080"* ]] \
   && ! grep -q 'rule allow-host git.example.test:8080' "$S120/s120i.conf" \
   && ! grep -q '^git\.example\.test|8080 ' "$S120/s120i.pins" 2>/dev/null \
   && ! grep -q 'ip daddr 192.0.2.10 tcp dport 8080 counter accept' "$STATE/nft/egresslock.p_s120i"; then
    a120 pass
else
    a120 fail "printed direct revocation recovers green (rc=$rc, out: $o, pins: $(cat "$S120/s120i.pins" 2>/dev/null))"
fi

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
    gateway 10.199.81.2 3128 s141a-allowlist
EOF
cat > "$S141/s141b.conf" <<'EOF'
profile s141b 10.199.82.0/24
    gateway 10.199.82.2 3128 s141b-allowlist
EOF
: > "$S141/s141a-allowlist"
: > "$S141/s141b-allowlist"
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

# 6. EGL-193: bare-profile chain shape. The public-only half of
#    these pins retired with EGL-153; re-anchor on a rules-free
#    profile. EGL-366-D3 retired the gateway-less variant: the
#    profile now carries a gateway line and no rules, which is
#    the new "bare" shape. Same three EGL-141-D1/D2 properties.
#    Last-transaction pin above already fired on the gateway
#    chain — this ensure overwrites last-transaction.nft after
#    that pin.
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
sq146="$(mock_cfg_file egresslock-gateway-s146 squid.conf)"
# 1. No-port group carries -n (exact line).
[[ "$a146_rc" == 0 && -n "$sq146" && -f "$sq146" ]] \
    && grep -qE '^acl allowlist dstdomain -n "/etc/squid/egresslock/allowlist\.domains\.[0-9a-f]{64}"$' "$sq146" \
    && a146 pass || a146 fail "no-port group: exact dstdomain -n line (rc=$a146_rc $(grep -m1 'acl allowlist dstdomain' "$sq146" 2>/dev/null))"
# 2. Per-port group carries -n (exact line).
printf 'example.test:8443\n' >> "$S146/s146-allowlist"
ARCMOCK_PASSWD_HOME="$(conf_home "$S146/s146.conf")" egresslock ensure s146 >/dev/null 2>&1 || a146 fail "re-ensure with per-port entry"
sq146="$(mock_cfg_file egresslock-gateway-s146 squid.conf)"
[[ -n "$sq146" && -f "$sq146" ]] \
    && grep -qE '^acl allowlist_p8443 dstdomain -n "/etc/squid/egresslock/allowlist\.p8443\.[0-9a-f]{64}"$' "$sq146" \
    && a146 pass || a146 fail "per-port group: exact dstdomain -n line ($(grep -m1 'allowlist_p8443' "$sq146" 2>/dev/null))"
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
printf 'profile s147b 10.199.87.0/24\n    rule allow-host example.test.:443\n    gateway 10.199.87.2 3128 s147b-allowlist\n' > "$S147/s147b.conf"
: > "$S147/s147b-allowlist"
o147="$(ARCMOCK_PASSWD_HOME="$(conf_home_ro "$S147/s147b.conf")" egresslock list 2>&1)"; r147=$?
if [[ "$r147" == 2 && "$o147" == *"trailing dot"* && "$o147" == *"b.conf:"* ]]; then
    a147 pass
else
    a147 fail "conf parser trailing-dot reject for allow-host (rc=$r147 out: $(printf '%s' "$o147" | tail -1))"
fi
printf 'profile s147c 10.199.88.0/24\n    no-proxy example.test.,other.example.test\n    gateway 10.199.88.2 3128 s147c-allowlist\n' > "$S147/s147c.conf"
: > "$S147/s147c-allowlist"
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

# EGL-362 P1: the four reset blocks below repeat a green fixture setup on
# every leg. Freeze the fixture-ready $EH+$STATE once per block and restore
# it for the following legs; the append-only cumulative logs
# ($STATE/callorder.log, $STATE/opslog) are never reverted.
# R-EGL-362-3 F2/F3: preserve the real opslog path, and make every
# snapshot/restore step fail the section explicitly — a final `rm` must
# never turn a partial copy into a silent success.
SNAP139="$TESTROOT/egl139-snap"
if ! rm -rf "$SNAP139" || ! mkdir -p "$SNAP139"; then
    a139 fail "EGL-362: cannot create the egl139 snapshot root $SNAP139"
fi
snap139() { # snap139 <name> — freeze the asserted-green fixture tree
    local name="$1"
    local dest="$SNAP139/$name"
    if ! rm -rf "$dest"; then
        a139 fail "snap139 $name: cannot clear $dest"; return 1
    fi
    if ! mkdir -p "$dest/eh" "$dest/state"; then
        a139 fail "snap139 $name: cannot create $dest"; return 1
    fi
    if ! cp -a "$EH/." "$dest/eh/"; then
        a139 fail "snap139 $name: cannot copy $EH"; return 1
    fi
    if ! cp -a "$STATE/." "$dest/state/"; then
        a139 fail "snap139 $name: cannot copy $STATE"; return 1
    fi
    if ! rm -f "$dest/state/callorder.log" "$dest/state/opslog"; then
        a139 fail "snap139 $name: cannot exclude the cumulative logs"; return 1
    fi
    return 0
}
restore139() { # restore139 <name> — restore $EH+$STATE; keep cumulative logs
    local name="$1"
    local dest="$SNAP139/$name"
    local saved="$SNAP139/.saved.$$"
    local had_callorder=0 had_opslog=0 rc=0
    if [[ ! -d "$dest/eh" || ! -d "$dest/state" ]]; then
        a139 fail "restore139 $name: snapshot $dest is missing"
        return 1
    fi
    if ! rm -rf "$saved"; then
        a139 fail "restore139 $name: cannot clear $saved"; return 1
    fi
    if ! mkdir -p "$saved"; then
        a139 fail "restore139 $name: cannot create $saved"; return 1
    fi
    # Preserve the live logs before touching the tree. A failed preserve
    # aborts with the tree intact, so evidence is never dropped.
    if [[ -f "$STATE/callorder.log" ]]; then
        had_callorder=1
        if ! cp -a "$STATE/callorder.log" "$saved/callorder.log"; then
            a139 fail "restore139 $name: cannot preserve $STATE/callorder.log"
            rm -rf "$saved"; return 1
        fi
    fi
    if [[ -f "$STATE/opslog" ]]; then
        had_opslog=1
        if ! cp -a "$STATE/opslog" "$saved/opslog"; then
            a139 fail "restore139 $name: cannot preserve $STATE/opslog"
            rm -rf "$saved"; return 1
        fi
    fi
    if ! rm -rf "$EH" "$STATE"; then
        a139 fail "restore139 $name: cannot clear $EH or $STATE"; rc=1
    fi
    if (( rc == 0 )) && ! mkdir -p "$EH" "$STATE"; then
        a139 fail "restore139 $name: cannot recreate $EH or $STATE"; rc=1
    fi
    if (( rc == 0 )) && ! cp -a "$dest/eh/." "$EH/"; then
        a139 fail "restore139 $name: cannot restore $EH"; rc=1
    fi
    if (( rc == 0 )) && ! cp -a "$dest/state/." "$STATE/"; then
        a139 fail "restore139 $name: cannot restore $STATE"; rc=1
    fi
    # Re-apply the logs even after a tree failure: losing evidence is a
    # second, independent defect.
    if (( had_callorder )) && [[ -d "$STATE" ]] \
       && ! cp -a "$saved/callorder.log" "$STATE/callorder.log"; then
        a139 fail "restore139 $name: cannot restore $STATE/callorder.log"; rc=1
    fi
    if (( had_opslog )) && [[ -d "$STATE" ]] \
       && ! cp -a "$saved/opslog" "$STATE/opslog"; then
        a139 fail "restore139 $name: cannot restore $STATE/opslog"; rc=1
    fi
    if ! rm -rf "$saved"; then
        a139 fail "restore139 $name: cannot clear $saved"; rc=1
    fi
    return "$rc"
}

EH="$TESTROOT/h139140"; rm -rf "$EH"; mkdir -p "$EH"
cat > "$EH/two.conf" <<'EOF'
profile two 10.199.60.0/24
    rule allow-host git.example.test:2222
    rule allow-host cache.example.test:8080
    gateway 10.199.60.2 3128 two-allowlist
EOF
: > "$EH/two-allowlist"
cat > "$EH/plain.conf" <<'EOF'
profile plain 10.199.61.0/24
    gateway 10.199.61.2 3128 plain-allowlist
EOF
: > "$EH/plain-allowlist"
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
if [[ "$v_rc" == 1 && "$v_out" == *"verify: direct pin daddr mismatch for git.example.test:2222 (record: 192.0.2.10, chain: 192.0.2.77) — re-run: egresslock ensure two (as $ENSURE_ACCT)"* ]]; then
    a139 pass
else
    a139 fail "tampered chain daddr -> named pin-divergence rc 1 (rc=$v_rc, out: $v_out)"
fi
env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure two >/dev/null 2>&1
# 4. missing record (the 0.4.x upgrade shape) -> fail closed named
#    re-ensure; NEVER a live-chain adoption.
mv "$EH/two.pins" "$EH/two.pins.bak"
v_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify two 2>&1)"; v_rc=$?
if [[ "$v_rc" == 1 && "$v_out" == *"verify: pin record missing for profile 'two' — re-run: egresslock ensure two (as $ENSURE_ACCT)"* ]]; then
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
S3_139="disallow --direct: the revocation is only half done — the rule is out of the firewall, but the connections that were open were not ended — state: conf line removed, ruleset swapped, conntrack not proven clean; next action: end the leftover connections: egresslock drop-unauthorized two 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"
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
    local marker="$1" label="$2" setup_out="" setup_rc=0
    if [[ -d "$SNAP139/e231" ]]; then
        restore139 e231 || return 1
    else
        setup_out="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow-host two git.example.test:2222 2>&1)"; setup_rc=$?
        if [[ "$setup_rc" -ne 0 ]]; then
            a139 fail "e231 fixture setup not green (rc=$setup_rc, out: $(echo "$setup_out" | tail -1))"
            return 1
        fi
        snap139 e231 || return 1
    fi
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
    gateway 10.199.62.2 3128 mset-allowlist
EOF
: > "$EH/mset-allowlist"
cat > "$EH/dup.conf" <<'EOF'
profile dup 10.199.63.0/24
    rule allow-host dup.example.test:8443
    rule allow-host dup.example.test:8443
    gateway 10.199.63.2 3128 dup-allowlist
EOF
: > "$EH/dup-allowlist"
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
if [[ "$v_rc" == 1 && "$v_out" == *"verify: direct pin daddr mismatch for duo.example.test:443 (record: 192.0.2.20 192.0.2.21, chain: 192.0.2.77) — re-run: egresslock ensure mset (as $ENSURE_ACCT)"* ]]; then
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
if [[ "$v_rc" == 1 && "$v_out" == *"disagreeing duplicate key for dup.example.test:8443) — re-run: egresslock ensure dup (as $ENSURE_ACCT)"* ]]; then
    a139 pass
else
    a139 fail "disagreeing duplicate key -> named corrupt (rc=$v_rc, out: $v_out)"
fi

# 21. repeated address within one line -> named corrupt.
printf 'dup.example.test|8443 192.0.2.30 192.0.2.30\n' > "$EH/dup.pins"
v_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/dup.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock verify dup 2>&1)"; v_rc=$?
if [[ "$v_rc" == 1 && "$v_out" == *"repeated address in line: 'dup.example.test|8443 192.0.2.30 192.0.2.30') — re-run: egresslock ensure dup (as $ENSURE_ACCT)"* ]]; then
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
if [[ "$d_rc" == 1 && "$d_out" == *"disallow --direct: pin record unreadable for profile 'mset' (corrupt line: 'duo.example.test|443 not-an-ip') — re-run: egresslock ensure mset"* ]] \
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
if [[ "$d_rc" == 1 && "$d_out" == *"disallow --direct: pin record unreadable for profile 'mset' (missing file)"* ]] \
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
    gateway 10.199.64.2 3128 rot-allowlist
EOF
: > "$EH/rot-allowlist"
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
: > "$CTLOG"
touch "$ARCMOCK_STATE/nft/conntrack-list-sport-fails"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock disallow-host rot rot.example.test:2222 2>&1)"; d_rc=$?
rm -f "$ARCMOCK_STATE/nft/conntrack-list-sport-fails"
if [[ "$d_rc" == 1 && "$d_out" == *"cannot read the rootless netns conntrack table (rc=1)"* \
      && "$d_out" == *"ct unproven"* \
      && "$d_out" == *"$TESTROOT/bin/conntrack -L -p tcp --sport 2222"* ]] \
   && ! grep -qF "$TESTROOT/bin/conntrack -L -p tcp --sport 2222 -s" <<<"$d_out" \
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
    if [[ -d "$SNAP139/reset311" ]]; then
        restore139 reset311 || return 1
        return 0
    fi
    local setup_out="" setup_rc=0
    cat > "$EH/rot.conf" <<'EOF'
profile rot 10.199.64.0/24
    rule allow-host rot.example.test:2222
    rule allow-host keep.example.test:2222
    gateway 10.199.64.2 3128 rot-allowlist
EOF
    rm -f "$STATE/nft/fail-list-chain-after-flush" \
          "$STATE/nft/partial-list-chain-after-flush" \
          "$STATE/nft/empty-list-chain-after-flush" \
          "$STATE/nft/header-list-chain-after-flush" \
          "$STATE/nft/garbage-list-chain-after-flush"
    setup_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.20,keep.example.test=192.0.2.30" \
        egresslock ensure rot 2>&1)"; setup_rc=$?
    if [[ "$setup_rc" -ne 0 ]]; then
        a139 fail "reset311 first ensure not green (rc=$setup_rc, out: $(echo "$setup_out" | tail -1))"
        return 1
    fi
    setup_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.21,keep.example.test=192.0.2.30" \
        egresslock ensure rot 2>&1)"; setup_rc=$?
    if [[ "$setup_rc" -ne 0 ]]; then
        a139 fail "reset311 second ensure not green (rc=$setup_rc, out: $(echo "$setup_out" | tail -1))"
        return 1
    fi
    : > "$CTLOG"; : > "$CTTABLE"
    snap139 reset311 || return 1
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
    gateway 10.199.80.2 3128 rot2-allowlist
EOF
: > "$EH/rot2-allowlist"
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
    gateway 10.199.66.2 3128 gate-allowlist
EOF
: > "$EH/gate-allowlist"
cat > "$EH/gate2.conf" <<'EOF'
profile gate2 10.199.67.0/24
    rule allow-host git.example.test:9999
    rule allow-host cache.example.test:9999
    gateway 10.199.67.2 3128 gate2-allowlist
EOF
: > "$EH/gate2-allowlist"
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure gate >/dev/null 2>&1
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure gate2 >/dev/null 2>&1

# 25. G1 — b1 count mismatch (the deleted-pin-rule shape): refuse named
#     S2 BEFORE the conf mutation; nothing changed, no flush.
sed -i '/ip daddr 192.0.2.10 tcp dport 2222/d' "$STATE/nft/egresslock.p_gate"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow gate git.example.test:2222 --direct 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow --direct: the installed direct rules for profile 'gate' no longer match its pin record — expected 2, found 1 (direct rule count mismatch); nothing was changed; re-run: egresslock ensure gate, then retry: egresslock disallow gate git.example.test:2222 --direct"* ]] \
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
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow gate git.example.test:2222 --direct 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow --direct: the installed direct rules for profile 'gate' are in a different order than the config — config expects git.example.test:2222, the installed rule has port 8080 (direct rule port order mismatch)"* ]] \
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
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow gate2 git.example.test:9999 --direct 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow --direct: a pinned address for git.example.test:9999 no longer matches the installed rule in profile 'gate2' — pin record: 192.0.2.10, installed rule: 192.0.2.11 (direct pin daddr mismatch)"* ]] \
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
    gateway 10.199.68.2 3128 never-allowlist
EOF
: > "$EH/never-allowlist"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/never.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow never git.example.test:2222 --direct 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow --direct: profile 'never' has no installed firewall rules, or they cannot be read — nothing was changed; re-run: egresslock ensure never, then retry: egresslock disallow never git.example.test:2222 --direct"* ]] \
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
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow gate2 git.example.test:9999 --direct 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow --direct: a pinned address for git.example.test:9999 no longer matches the installed rule in profile 'gate2' — pin record: 192.0.2.10, installed rule: 192.0.2.77 (direct pin daddr mismatch)"* ]] \
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
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow gate git.example.test:2222 --direct 2>&1)"; d_rc=$?
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
    gateway 10.199.69.2 3128 gate3-allowlist
EOF
: > "$EH/gate3-allowlist"
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate3.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure gate3 >/dev/null 2>&1
sed -i '/ip daddr 192.0.2.12 tcp dport 3333/d' "$STATE/nft/egresslock.p_gate3"
sed -i '/^gitXexample.test|3333 /d' "$EH/gate3.pins"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate3.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow-host gate3 git.example.test:2222 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow --direct: pin record unreadable for profile 'gate3' (no entry for gitXexample.test:3333) — re-run: egresslock ensure gate3"* ]] \
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
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow gate2 git.example.test:9999 --direct 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"Error: disallow --direct: profile 'gate2' has no installed firewall rules, or they cannot be read — nothing was changed; re-run: egresslock ensure gate2, then retry: egresslock disallow gate2 git.example.test:9999 --direct"* ]] \
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
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow gate2 git.example.test:9999 --direct 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"Error: disallow --direct: profile 'gate2' has no installed firewall rules, or they cannot be read"* ]] \
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
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow gate2 git.example.test:9999 --direct 2>&1)"; d_rc=$?
rm -f "$STATE/netns-nft-fails"
if [[ "$d_rc" == 1 \
      && "$d_out" == *"Error: disallow --direct: profile 'gate2' has no installed firewall rules, or they cannot be read"* ]] \
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
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='git.example.test=' egresslock disallow gate2 git.example.test:9999 --direct 2>&1)"; d_rc=$?
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
#     resolve + D14 unknown hint (the pin record still has the entry but
#     the tampered chain no longer matches it, so the state is unproved:
#     inspect, never a conf-only delete or a failing disallow); retry S2;
#     nothing changed; exactly two probes.
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow-host gate2 git.example.test:9999 >/dev/null 2>&1
sed -i '/ip daddr 192.0.2.10 tcp dport 9999/d' "$STATE/nft/egresslock.p_gate2"
# Snapshots are the POST-tamper refusal-start state: the cmp below proves
# the deadlocked window (S2 refusal + the cannot-resolve ensure + the
# retry refusal) changed nothing beyond the deliberate drift tamper.
cp "$EH/gate2.conf" "$STATE/g13-conf"
cp "$STATE/nft/egresslock.p_gate2" "$STATE/g13-chain"
cp "$EH/gate2.pins" "$STATE/g13-pins"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='git.example.test=' egresslock disallow gate2 git.example.test:9999 --direct 2>&1)"; d_rc=$?
e_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='git.example.test=' egresslock ensure gate2 2>&1)"; e_rc=$?
d2_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/gate2.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='git.example.test=' egresslock disallow gate2 git.example.test:9999 --direct 2>&1)"; d2_rc=$?
if [[ "$d_rc" == 1 && "$d_out" == *"(direct rule count mismatch)"* ]] \
   && [[ "$d_out" == *"expected 2, found 1"* ]] \
   && [[ "$e_rc" == 1 && "$e_out" == *"Error: cannot resolve git.example.test"* ]] \
   && [[ "$(grep -c '^hint:' <<<"$e_out")" == 3 ]] \
   && [[ "$e_out" == *"the name did not resolve. Whether a firewall grant for this host:port is live is not proved."* ]] \
   && [[ "$e_out" == *"hint: inspect: egresslock verify gate2"* ]] \
   && [[ "$e_out" != *"egresslock disallow gate2 git.example.test:9999 --direct"* ]] \
   && [[ "$e_out" != *"no live flows"* && "$e_out" != *"delete the line"* ]] \
   && [[ "$d2_rc" == 1 && "$d2_out" == *"(direct rule count mismatch)"* ]] \
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
    if [[ -d "$SNAP139/reset307" ]]; then
        restore139 reset307 || return 1
        return 0
    fi
    local setup_out="" setup_rc=0
    cat > "$EH/shr.conf" <<'EOF'
profile shr 10.199.65.0/24
    rule allow-host aa.example.test:2222
    rule allow-host bb.example.test:2222
    gateway 10.199.65.2 3128 shr-allowlist
EOF
: > "$EH/shr-allowlist"
    rm -f "$STATE/nft/fail-list-chain-read-n" \
          "$STATE/nft/fail-list-chain-after-flush" \
          "$STATE/nft/f-list-reads"
    setup_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/shr.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        EGRESSLOCK_MOCK_DNS="aa.example.test=192.0.2.70,bb.example.test=192.0.2.70" \
        egresslock ensure shr 2>&1)"; setup_rc=$?
    if [[ "$setup_rc" -ne 0 ]]; then
        a139 fail "reset307 ensure not green (rc=$setup_rc, out: $(echo "$setup_out" | tail -1))"
        return 1
    fi
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
    snap139 reset307 || return 1
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
S3_307="disallow --direct: the revocation is only half done — the rule is out of the firewall, but the connections that were open were not ended — state: conf line removed, ruleset swapped, conntrack not proven clean; next action: end the leftover connections: egresslock drop-unauthorized shr 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"

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
   && ! grep -qF 'disallow --direct:' <<<"$d_out"; then
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
    if [[ -d "$SNAP139/reset_rot219" ]]; then
        restore139 reset_rot219 || return 1
        return 0
    fi
    local setup_out="" setup_rc=0
    cat > "$EH/rot.conf" <<'EOF'
profile rot 10.199.64.0/24
    rule allow-host rot.example.test:2222
    rule allow-host keep.example.test:2222
    gateway 10.199.64.2 3128 rot-allowlist
EOF
    setup_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.20,keep.example.test=192.0.2.30" \
        egresslock ensure rot 2>&1)"; setup_rc=$?
    if [[ "$setup_rc" -ne 0 ]]; then
        a139 fail "reset_rot219 ensure not green (rc=$setup_rc, out: $(echo "$setup_out" | tail -1))"
        return 1
    fi
    snap139 reset_rot219 || return 1
}
d9_disallow() { # d9_disallow <host:port> — fills d9_out/d9_rc
    d9_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/rot.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        EGRESSLOCK_MOCK_DNS="rot.example.test=192.0.2.20,keep.example.test=192.0.2.30" \
        egresslock disallow-host rot "$1" 2>&1)"; d9_rc=$?
}
d9_expect() { # d9_expect <desc> <cause-substr>
    if [[ "$d9_rc" == 1 && "$d9_out" == *"disallow --direct: pin record unreadable for profile 'rot'"*"$2"* ]] \
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
    gateway 10.199.105.2 3128 fail-allowlist
EOF
: > "$EH/fail-allowlist"
env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/fail.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="duo.example.test=192.0.2.20+192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock ensure fail >/dev/null 2>&1
printf 'duo.example.test|443 192.0.2.20 192.0.2.20\nkeep.example.test|443 192.0.2.30\n' > "$EH/fail.pins"
: > "$CTLOG"
d_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$EH/fail.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="duo.example.test=192.0.2.20+192.0.2.21,keep.example.test=192.0.2.30" \
    egresslock disallow-host fail duo.example.test:443 2>&1)"; d_rc=$?
if [[ "$d_rc" == 1 \
      && "$d_out" == *"disallow --direct: pin record unreadable for profile 'fail' (repeated address in line: 'duo.example.test|443 192.0.2.20 192.0.2.20') — re-run: egresslock ensure fail"* ]] \
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
S3_139D="disallow --direct: the revocation is only half done — the rule is out of the firewall, but the connections that were open were not ended — state: conf line removed, ruleset swapped, conntrack not proven clean; next action: end the leftover connections: egresslock drop-unauthorized fail 443 (drops the connections on port 443 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"
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

# --- EGL-362: mock fidelity + snapshot/restore regressions -----------------
# R-EGL-362-3 F1-F4: the conntrack mock must keep the base awk's numeric
# matching (leading-zero spellings are accepted engine input), the real
# cumulative opslog must survive restores, and a failed snapshot/restore
# copy must fail the section instead of being masked by the final rm.
# The direct mock legs are differential in spirit: each fails on the
# pre-rework P2 mock and passes only when the base semantics are back.
section_begin egl362 "EGL-362 mock fidelity regressions"
a362() { assert "$@"; }

ROW362='ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.113.5 dst=192.0.2.10 sport=58666 dport=443 src=192.0.2.10 dst=10.0.2.15 sport=443 dport=58666 [ASSURED] mark=0 zone=0 use=2'
CT362="$STATE/nft/conntrack-table"

# F2: repeated restores preserve callorder.log AND opslog; absent logs
# are not invented, and a log created after the snapshot survives.
f2_out="$(
    SNAP139="$TESTROOT/h362-snap"
    EH="$TESTROOT/h362-eh"; STATE="$TESTROOT/h362-state"
    rm -rf "$SNAP139" "$EH" "$STATE"
    mkdir -p "$EH" "$STATE" || exit 1
    printf 'fixture\n' > "$EH/fixture"
    printf 'state\n' > "$STATE/fixture"
    printf 'callorder-before\n' > "$STATE/callorder.log"
    printf 'opslog-before\n' > "$STATE/opslog"
    snap139 f2 || exit 1
    printf 'callorder-after\n' >> "$STATE/callorder.log"
    printf 'opslog-after\n' >> "$STATE/opslog"
    restore139 f2 || exit 1
    grep -qx 'callorder-before' "$STATE/callorder.log" || exit 1
    grep -qx 'callorder-after' "$STATE/callorder.log" || exit 1
    grep -qx 'opslog-before' "$STATE/opslog" || exit 1
    grep -qx 'opslog-after' "$STATE/opslog" || exit 1
    printf 'opslog-second\n' >> "$STATE/opslog"
    restore139 f2 || exit 1
    grep -qx 'callorder-after' "$STATE/callorder.log" || exit 1
    grep -qx 'opslog-second' "$STATE/opslog" || exit 1
    [[ ! -e "$SNAP139/f2/state/callorder.log" ]] || exit 1
    [[ ! -e "$SNAP139/f2/state/opslog" ]] || exit 1
    rm -f "$STATE/callorder.log" "$STATE/opslog"
    snap139 f2b || exit 1
    printf 'opslog-fresh\n' > "$STATE/opslog"
    restore139 f2b || exit 1
    [[ ! -e "$STATE/callorder.log" ]] || exit 1
    grep -qx 'opslog-fresh' "$STATE/opslog" || exit 1
    # A log absent both in the snapshot and live stays absent (restore
    # must not invent an empty file).
    rm -f "$STATE/opslog"
    restore139 f2b || exit 1
    [[ ! -e "$STATE/callorder.log" && ! -e "$STATE/opslog" ]] || exit 1
)"; f2_rc=$?
if [[ "$f2_rc" == 0 ]]; then
    a362 pass
else
    a362 fail "restore139 must preserve callorder.log and opslog across repeats (rc=$f2_rc, out: $(echo "$f2_out" | tail -2 | tr '\n' '|'))"
fi

# F3a: a failed snapshot copy is named and returns nonzero.
f3a_out="$(
    SNAP139="$TESTROOT/h362-snap"
    EH="$TESTROOT/h362-eh"; STATE="$TESTROOT/h362-state"
    rm -rf "$SNAP139" "$EH" "$STATE"
    mkdir -p "$EH" "$STATE" || exit 1
    printf 'fixture\n' > "$EH/fixture"
    cp() { [[ "$1" == "-a" && "$2" == "$EH/." ]] && return 1; command cp "$@"; }
    snap139 f3a
)"; f3a_rc=$?
if [[ "$f3a_rc" -ne 0 && "$f3a_out" == *"snap139 f3a: cannot copy"* ]]; then
    a362 pass
else
    a362 fail "snap139 must fail named on a copy error (rc=$f3a_rc, out: $(echo "$f3a_out" | tail -2 | tr '\n' '|'))"
fi

# F3b: a failed log-preservation copy aborts before the tree is touched,
# so the cumulative logs and fixture survive.
f3b_out="$(
    SNAP139="$TESTROOT/h362-snap"
    EH="$TESTROOT/h362-eh"; STATE="$TESTROOT/h362-state"
    rm -rf "$SNAP139" "$EH" "$STATE"
    mkdir -p "$EH" "$STATE" || exit 1
    printf 'fixture\n' > "$EH/fixture"
    printf 'callorder-keep\n' > "$STATE/callorder.log"
    printf 'opslog-keep\n' > "$STATE/opslog"
    snap139 f3b || exit 1
    cp() { [[ "$1" == "-a" && "$2" == "$STATE/callorder.log" ]] && return 1; command cp "$@"; }
    restore139 f3b
)"; f3b_rc=$?
if [[ "$f3b_rc" -ne 0 && "$f3b_out" == *"restore139 f3b: cannot preserve"*"callorder.log"* \
      && "$(cat "$TESTROOT/h362-state/callorder.log" 2>/dev/null)" == 'callorder-keep' \
      && "$(cat "$TESTROOT/h362-state/opslog" 2>/dev/null)" == 'opslog-keep' \
      && -f "$TESTROOT/h362-eh/fixture" ]]; then
    a362 pass
else
    a362 fail "restore139 must abort named on a log-preserve error and keep the tree (rc=$f3b_rc, out: $(echo "$f3b_out" | tail -2 | tr '\n' '|'))"
fi

# F3c: a failed tree copy after the wipe returns nonzero (the final rm
# must not turn a partial fixture into a success).
f3c_out="$(
    SNAP139="$TESTROOT/h362-snap"
    EH="$TESTROOT/h362-eh"; STATE="$TESTROOT/h362-state"
    rm -rf "$SNAP139" "$EH" "$STATE"
    mkdir -p "$EH" "$STATE" || exit 1
    printf 'fixture\n' > "$EH/fixture"
    snap139 f3c || exit 1
    cp() { [[ "$1" == "-a" && "$2" == "$SNAP139/f3c/state/." ]] && return 1; command cp "$@"; }
    restore139 f3c
)"; f3c_rc=$?
if [[ "$f3c_rc" -ne 0 && "$f3c_out" == *"restore139 f3c: cannot restore"*"h362-state"* ]]; then
    a362 pass
else
    a362 fail "restore139 must fail named when the state copy fails (rc=$f3c_rc, out: $(echo "$f3c_out" | tail -2 | tr '\n' '|'))"
fi

# F1: the base awk compared numeric-looking ports numerically. Each leg
# fails on the string-comparison P2 mock.
printf '%s\n' "$ROW362" > "$CT362"
f1_out="$(conntrack -L -p tcp --dport 0443 2>&1)"; f1_rc=$?
if [[ "$f1_rc" == 0 && "$f1_out" == *"dport=443"* \
      && "$f1_out" == *"1 flow entries have been shown."* ]]; then
    a362 pass
else
    a362 fail "conntrack -L matches a leading-zero dport numerically (rc=$f1_rc, out: $(echo "$f1_out" | tr '\n' '|'))"
fi
printf '%s\n' "$ROW362" > "$CT362"
f1_out="$(conntrack -D -p tcp --dport 0443 2>&1)"; f1_rc=$?
if [[ "$f1_rc" == 0 && "$f1_out" == *"1 flow entries have been deleted."* \
      && ! -s "$CT362" ]]; then
    a362 pass
else
    a362 fail "conntrack -D deletes a leading-zero dport numerically (rc=$f1_rc, out: $(echo "$f1_out" | tr '\n' '|'), table: $(tr '\n' '|' < "$CT362"))"
fi
printf '%s\n' "$ROW362" > "$CT362"
f1_out="$(conntrack -L -p tcp --sport 058666 -s 10.199.113.5 2>&1)"; f1_rc=$?
if [[ "$f1_rc" == 0 && "$f1_out" == *"sport=58666"* ]]; then
    a362 pass
else
    a362 fail "conntrack -L matches a leading-zero source port numerically (rc=$f1_rc, out: $(echo "$f1_out" | tr '\n' '|'))"
fi
printf '%s\n' "$ROW362" > "$CT362"
f1_out="$(conntrack -D -p tcp -s 10.199.113.5 --sport 058666 -d 192.0.2.10 --dport 0443 2>&1)"; f1_rc=$?
if [[ "$f1_rc" == 0 && "$f1_out" == *"1 flow entries have been deleted."* \
      && ! -s "$CT362" ]]; then
    a362 pass
else
    a362 fail "conntrack -D deletes a leading-zero source port numerically (rc=$f1_rc, out: $(echo "$f1_out" | tr '\n' '|'), table: $(tr '\n' '|' < "$CT362"))"
fi
printf '%s\n' "$ROW362" > "$CT362"
f1_out="$(conntrack -L -p tcp --dport 0443x 2>&1)"; f1_rc=$?
if [[ "$f1_rc" == 0 && "$f1_out" == *"0 flow entries have been shown."* \
      && -s "$CT362" ]]; then
    a362 pass
else
    a362 fail "non-numeric filters stay exact string compares (rc=$f1_rc, out: $(echo "$f1_out" | tr '\n' '|'))"
fi

# F1 end-to-end: the engine canonicalizes the accepted `:0443` spelling
# and must still delete the dport=443 row (no false `removed:` with a
# surviving flow). The second leg is the survivor regression the string-
# compare mock hid: a leading-zero row field is still the same flow, so
# the engine must fail closed (no `removed:`) instead of claiming success.
H362E="$TESTROOT/h362e"; rm -rf "$H362E"; mkdir -p "$H362E"
cat > "$H362E/ct.conf" <<'EOF'
profile ct 10.199.113.0/24
    rule allow-host zero.example.test:443
    gateway 10.199.113.2 3128 ct-allowlist
EOF
: > "$H362E/ct-allowlist"
env ARCMOCK_PASSWD_HOME="$(conf_home "$H362E/ct.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="zero.example.test=192.0.2.90" \
    egresslock ensure ct >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.113.5 dst=192.0.2.90 sport=40000 dport=443 src=192.0.2.90 dst=10.0.2.15 sport=443 dport=40000 [ASSURED] mark=0 zone=0 use=2\n' > "$CT362"
: > "$STATE/conntrack.log"
f1_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H362E/ct.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="zero.example.test=192.0.2.90" \
    egresslock disallow-host ct zero.example.test:0443 2>&1)"; f1_rc=$?
if [[ "$f1_rc" == 0 && "$(grep -c 'removed:' <<<"$f1_out")" == 1 \
      && ! -s "$CT362" ]] \
   && ! grep -q 'rule allow-host zero.example.test:443' "$H362E/ct.conf"; then
    a362 pass
else
    a362 fail "end-to-end :0443 revokes the canonical dport=443 flow (rc=$f1_rc, out: $(echo "$f1_out" | tail -1), table: $(tr '\n' '|' < "$CT362"))"
fi
# Survivor leg: the flow row spells the port with a leading zero (the
# base awk compared it numerically), so a string-compare mock reports the
# delete as a no-op yet the engine still prints `removed:` — the false
# success this regression must catch.
cat > "$H362E/ct.conf" <<'EOF'
profile ct 10.199.113.0/24
    rule allow-host zero.example.test:443
    gateway 10.199.113.2 3128 ct-allowlist
EOF
: > "$H362E/ct-allowlist"
env ARCMOCK_PASSWD_HOME="$(conf_home "$H362E/ct.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="zero.example.test=192.0.2.90" \
    egresslock ensure ct >/dev/null 2>&1
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.113.5 dst=192.0.2.90 sport=40000 dport=0443 src=192.0.2.90 dst=10.0.2.15 sport=443 dport=40000 [ASSURED] mark=0 zone=0 use=2\n' > "$CT362"
: > "$STATE/conntrack.log"
f1_out="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$H362E/ct.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="zero.example.test=192.0.2.90" \
    egresslock disallow-host ct zero.example.test:0443 2>&1)"; f1_rc=$?
if [[ "$f1_rc" -ne 0 && "$f1_out" != *"removed:"* \
      && "$f1_out" == *"still has a live conntrack entry"* && -s "$CT362" ]]; then
    a362 pass
else
    a362 fail "end-to-end :0443 fails closed on a leading-zero survivor row (rc=$f1_rc, out: $(echo "$f1_out" | tail -1), table: $(tr '\n' '|' < "$CT362"))"
fi
: > "$CT362"
: > "$STATE/conntrack.log"

section_end egl362

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
    gateway 10.199.90.2 3128 t305-allowlist
EOF
: > "$H305/t305-allowlist"
cat > "$H305/p305.conf" <<'EOF'
profile p305 10.199.91.0/24
    gateway 10.199.91.2 3128 p305-allowlist
EOF
: > "$H305/p305-allowlist"
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
S1_305='disallow --direct: nothing was revoked — the reinstall failed before the policy was replaced and the rule was put back — state: rule restored, ruleset not replaced (the rule is back in the config; the revocation ended no connection) — next action: fix the underlying failure, then retry: egresslock disallow t305 git.example.test:2222 --direct'
S2_305='disallow --direct: nothing was revoked — the reinstall failed before the policy was replaced, and the rule could not be put back — state: config line removed, ruleset not replaced (the revocation ended no connection) — next action: fix the underlying failure, then put the rule back and retry: egresslock allow t305 git.example.test:2222 --direct, then egresslock disallow t305 git.example.test:2222 --direct'
S2W_305="disallow --direct: warning: a plain 'egresslock ensure t305' would drop the direct rule git.example.test:2222 from the firewall without ending its open connections — restore the rule first (the allow command above)."
S3_305="disallow --direct: the revocation is only half done — the rule is out of the firewall, but the connections that were open were not ended — state: conf line removed, ruleset swapped, conntrack not proven clean; next action: end the leftover connections: egresslock drop-unauthorized t305 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"
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
d305="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow t305 git.example.test:2222 --direct 2>&1)"; d305_rc=$?
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
d305="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow t305 git.example.test:2222 --direct 2>&1)"; d305_rc=$?
if [[ "$d305_rc" == 0 && "$d305" == *'removed: rule allow-host git.example.test:2222'* && "$d305" != *'disallow --direct:'* ]]; then
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
d305="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow t305 git.example.test:2222 --direct 2>&1)"; d305_rc=$?
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
d305="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow t305 git.example.test:2222 --direct 2>&1)"; d305_rc=$?
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
if [[ "$d305_rc" == 1 && "$d305" != *'disallow --direct:'* && "$d305" != *'rule restored'* ]]; then
    a305 pass
else
    a305 fail "L4 plain ensure: no disallow-host disclosure outside the window (rc=$d305_rc, out: $d305)"
fi

# L5 healthy path unchanged: covered by the L1 retry tail above (rc 0,
# removed:, no disclosure line) — explicit guard against wording drift
# on the SUCCESS path of a disallow-host run.
reset305
printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.90.5 dst=192.0.2.10 sport=58666 dport=2222 src=192.0.2.10 dst=10.0.2.15 sport=2222 dport=58666 [ASSURED] mark=0 zone=0 use=2\n' > "$A305CT"
d305="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow t305 git.example.test:2222 --direct 2>&1)"; d305_rc=$?
if [[ "$d305_rc" == 0 && "$d305" != *'disallow --direct:'* && "$d305" != *'nothing was revoked'* ]]; then
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
# the named mktemp die only, no disallow --direct: line, the conf untouched,
# the conntrack log only the -C probe. Restore the mode first.
reset305
cp "$H305/t305.conf" "$H305/pre305conf"
chmod 0555 "$H305"
d305="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow t305 git.example.test:2222 --direct 2>&1)"; d305_rc=$?
chmod 0755 "$H305"
if [[ "$d305_rc" == 1 && "$d305" == *'cannot create temp next to'* && "$d305" != *'disallow --direct:'* && "$d305" != *'nothing was revoked'* ]]; then
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
: > "$H305/custom dir/t305-allowlist"
cat > "$H305/home/.config/egresslock/t305.conf" <<'EOF'
profile t305 10.200.100.0/24
    gateway 10.200.100.2 3128 t305-allowlist
EOF
: > "$H305/home/.config/egresslock/t305-allowlist"
cp "$H305/home/.config/egresslock/t305.conf" "$H305/quilt.default"
Q305="$(printf '%q' "$H305/custom dir/t305.conf")"
S1Q_305="disallow --direct: nothing was revoked — the reinstall failed before the policy was replaced and the rule was put back — state: rule restored, ruleset not replaced (the rule is back in the config; the revocation ended no connection) — next action: fix the underlying failure, then retry: egresslock disallow t305 git.example.test:2222 --direct"
S2Q_305="disallow --direct: nothing was revoked — the reinstall failed before the policy was replaced, and the rule could not be put back — state: config line removed, ruleset not replaced (the revocation ended no connection) — next action: fix the underlying failure, then put the rule back and retry: egresslock allow t305 git.example.test:2222 --direct, then egresslock disallow t305 git.example.test:2222 --direct"
S2WQ_305="disallow --direct: warning: a plain 'egresslock ensure t305' would drop the direct rule git.example.test:2222 from the firewall without ending its open connections — restore the rule first (the allow command above)."
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
d305="$(env HOME="$H305/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' ARCMOCK_PASSWD_HOME="$(conf_home "$H305/custom dir/t305.conf")" egresslock disallow t305 git.example.test:2222 --direct 2>&1)"; d305_rc=$?
if [[ "$d305_rc" == 1 ]] && grep -qxF "$S1Q_305" <<<"$d305"; then
    a305 pass
else
    a305 fail "L7 S1 rc 1 + exact --config rendering (rc=$d305_rc, out: $d305)"
fi
retry305="${d305##*then retry: }"
[[ "$retry305" == "$S1Q_305" || "$retry305" == "egresslock disallow t305 git.example.test:2222 --direct" ]] \
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
d305="$(env HOME="$H305/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' ARCMOCK_PASSWD_HOME="$(conf_home "$H305/custom dir/t305.conf")" egresslock disallow t305 git.example.test:2222 --direct 2>&1)"; d305_rc=$?
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
[[ "$hop305" == "egresslock allow t305 git.example.test:2222 --direct" \
    && "$hop2_305" == "egresslock disallow t305 git.example.test:2222 --direct" ]] \
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
    gateway 10.199.96.2 3128 t317-allowlist
EOF
: > "$H317/t317-allowlist"
cat > "$H317/p317.conf" <<'EOF'
profile p317 10.199.73.0/24
    gateway 10.199.73.2 3128 p317-allowlist
EOF
: > "$H317/p317-allowlist"
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
S3T317="disallow --direct: the revocation is only half done — the rule is out of the firewall, but the connections that were open were not ended — state: conf line removed, ruleset swapped, conntrack not proven clean; next action: end the leftover connections: egresslock drop-unauthorized t317 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"
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
    gateway 10.199.79.2 3128 q317-allowlist
EOF
: > "$H317/custom dir/q317-allowlist"
cat > "$H317/home/.config/egresslock/q317.conf" <<'EOF'
profile q317 10.200.101.0/24
    gateway 10.200.101.2 3128 q317-allowlist
EOF
: > "$H317/home/.config/egresslock/q317-allowlist"
cp "$H317/home/.config/egresslock/q317.conf" "$H317/decoy.pre"
env HOME="$H317/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    ARCMOCK_PASSWD_HOME="$(conf_home "$H317/custom dir/q317.conf")" egresslock ensure q317 >/dev/null 2>&1
env HOME="$H317/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS='git.example.test=192.0.2.20' \
    ARCMOCK_PASSWD_HOME="$(conf_home "$H317/custom dir/q317.conf")" egresslock ensure q317 >/dev/null 2>&1
S3Q317="disallow --direct: the revocation is only half done — the rule is out of the firewall, but the connections that were open were not ended — state: conf line removed, ruleset swapped, conntrack not proven clean; next action: end the leftover connections: egresslock drop-unauthorized q317 2222 (drops the connections on port 2222 the policy no longer allows, keeps the connections the policy still allows, then checks none remain; safe to run again)"
OKQ317="drop-unauthorized: no leftover connection on port 2222 remains that profile 'q317' does not allow"
rm -f "$STATE/nft/f-done"; : > "$STATE/nft/fail-list-chain-after-f"
d317="$(env HOME="$H317/home" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS='git.example.test=192.0.2.20' \
    ARCMOCK_PASSWD_HOME="$(conf_home "$H317/custom dir/q317.conf")" egresslock disallow-host q317 git.example.test:2222 2>&1)"; d317_rc=$?
if [[ "$d317_rc" == 1 ]] \
   && grep -qxF "Error: cannot probe the nft policy for profile 'q317' in the rootless netns (rc=1): Error: mock nft: netlink read of chain 'p_q317' failed once (fail-list-chain-after-f); check pasta/podman health — run: egresslock ensure q317 (as $ENSURE_ACCT)" <<<"$d317" \
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
# --- EGL-350: revocation accept-shape drift tripwire ---
# The revocation invariant (internal_docs/REVOCATION_INVARIANT.md, walk
# pairing) requires every accept shape the policy compiler emits to join
# BOTH the accepted-set walk (chain_accepted_daddrs via
# conntrack_accepted_set) and the EGL-312 reversed-orig read. The landed
# tests exercise the shapes that already exist, so a new unpaired shape
# would stay green. This section generates the chain from the compiler
# instead of committing one: `egresslock rules drift` is the oracle,
# every accept line is classified (baseline established, gateway MAC
# exemption, or daddr+dport), and every accepted daddr's forward and
# reversed-orig conntrack row must survive `drop-unauthorized`; the
# control daddr must be flushed. An accept shape the walk does not know
# is not in its accepted set, so the reconcile flushes that row and the
# survival leg goes red by port/daddr. The anti-vacuity leg inserts a
# synthetic unpaired shape and requires its row flushed.
# Fixture: gateway profile `drift` (pin + gateway-hop + implicit DNS).
# Subnet 10.199.158.0/24 is free in this tree (re-checked at coding; the
# design's 10.199.150.0/24 was taken by EGL-366's `hw` fixture).
section_begin egl350 "EGL-350 revocation accept-shape drift tripwire"
a350() { assert "$@"; }

H350="$TESTROOT/h350"; rm -rf "$H350"; mkdir -p "$H350"
CTLOG350="$ARCMOCK_STATE/conntrack.log"
TT350="$STATE/nft/conntrack-table"
SUBNET350="10.199.158.0/24"
GW350="10.199.158.2"
DNSGW350="10.199.158.1"
PINIP350="192.0.2.10"
CONTROL350="192.0.2.99"
CHAIN350="$STATE/nft/egresslock.p_drift"
cat > "$H350/drift.conf" <<'EOF'
profile drift 10.199.158.0/24
    rule allow-host git.example.test:2222
    rule gateway-only
    gateway 10.199.158.2 3128 drift-allowlist
EOF
: > "$H350/drift-allowlist"

# classify350: the accept-line oracle. Only the three emitted classes are
# known; anything else is "unclassified" and the section fails by line.
# A daddr+dport accept is protocol-agnostic on purpose: a new emitter
# shape in that class joins the expected set and is exercised by the
# survival legs, which is where an unpaired walk shows up.
classify350() { # classify350 <accept-line> -> baseline|mac|daddr <ip> <port>|unclassified
    local _c350="$1" _cip350
    if [[ "$_c350" == *"ct state established,related counter accept"* ]]; then
        echo "baseline"; return 0
    fi
    if [[ "$_c350" == *"ether saddr "* && "$_c350" != *" ip daddr "* ]]; then
        echo "mac"; return 0
    fi
    if [[ "$_c350" =~ ip[[:space:]]daddr[[:space:]]+([0-9.]+) ]]; then
        _cip350="${BASH_REMATCH[1]}"
        if [[ "$_c350" =~ (^|[[:space:]])dport[[:space:]]+([0-9]+) ]]; then
            echo "daddr $_cip350 ${BASH_REMATCH[2]}"; return 0
        fi
    fi
    echo "unclassified"
}

DRIFT_HOME350="$(conf_home "$H350/drift.conf")"
setup350_out="$(env ARCMOCK_PASSWD_HOME="$DRIFT_HOME350" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure drift 2>&1)"; setup350_rc=$?
if [[ "$setup350_rc" == 0 && -f "$CHAIN350" ]]; then
    a350 pass
else
    a350 fail "fixture ensure drift (rc=$setup350_rc, out: $(echo "$setup350_out" | tail -2 | tr '\n' '|'))"
fi

rules350_out="$(env ARCMOCK_PASSWD_HOME="$DRIFT_HOME350" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock rules drift 2>/dev/null)"; rules350_rc=$?
if [[ "$rules350_rc" == 0 && -n "$rules350_out" ]]; then
    a350 pass
else
    a350 fail "rules oracle drift (rc=$rules350_rc)"
fi
# Oracle fidelity: the classified text is the chain the consumer reads.
if diff -q <(grep 'counter accept' <<<"$rules350_out") \
           <(grep 'counter accept' "$CHAIN350") >/dev/null 2>&1; then
    a350 pass
else
    a350 fail "rules oracle differs from the installed chain ($(diff <(grep 'counter accept' <<<"$rules350_out") <(grep 'counter accept' "$CHAIN350") | tr '\n' '|' | head -c 400))"
fi

declare -A EXP350=()
nbase350=0; nmac350=0; ndaddr350=0; class350_bad=""; _l350=""
while IFS= read -r _l350; do
    [[ "$_l350" == *"counter accept"* ]] || continue
    _c350="$(classify350 "$_l350")"
    case "$_c350" in
        baseline) nbase350=$((nbase350 + 1)) ;;
        mac)      nmac350=$((nmac350 + 1)) ;;
        "daddr "*)
            read -r _ _d350 _p350 <<<"$_c350"
            EXP350[$_p350]="${EXP350[$_p350]:-} $_d350"
            ndaddr350=$((ndaddr350 + 1))
            ;;
        *) class350_bad+=" [$_l350]" ;;
    esac
done <<<"$rules350_out"
if [[ -z "$class350_bad" && "$nbase350" == 1 && "$nmac350" == 1 && "$ndaddr350" -ge 3 ]]; then
    a350 pass
else
    a350 fail "accept classifier: baseline=$nbase350 mac=$nmac350 daddr=$ndaddr350 unclassified=${class350_bad:-none}"
fi
# Shape inventory: a removed emitter shape must fail rather than silently
# shrink coverage.
if [[ " ${EXP350[2222]:-} " == *" $PINIP350 "* \
   && " ${EXP350[3128]:-} " == *" $GW350 "* \
   && " ${EXP350[53]:-} " == *" $DNSGW350 "* ]]; then
    a350 pass
else
    a350 fail "shape inventory missing a pin/hop/DNS accept (2222:'${EXP350[2222]:-}' 3128:'${EXP350[3128]:-}' 53:'${EXP350[53]:-}')"
fi
# A no-daddr accept the classifier does not know must fail closed.
if [[ "$(classify350 "ip saddr $SUBNET350 iifname \"podmanX\" counter accept")" == "unclassified" ]]; then
    a350 pass
else
    a350 fail "classifier accepted a no-daddr accept shape"
fi

# rows350: forward + reversed-orig rows for every expected daddr plus the
# control, each tagged with a deterministic original sport so survival is
# checked on the original tuple (a reply tuple carries the same addresses).
rows350() { # rows350 <port> <daddr...>
    local _p="$1"; shift
    local _d _n=0 _sport
    : > "$TT350"
    for _d in "$@"; do
        _n=$((_n + 1)); _sport="$(printf '57%03d' "$_n")"
        printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.158.5 dst=%s sport=%s dport=%s src=%s dst=10.0.2.15 sport=%s dport=%s [ASSURED] mark=0 zone=0 use=2\n' \
            "$_d" "$_sport" "$_p" "$_d" "$_p" "$_sport" >> "$TT350"
        printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=%s dst=10.199.158.5 sport=%s dport=%s src=10.199.158.5 dst=%s sport=%s dport=%s [ASSURED] mark=0 zone=0 use=2\n' \
            "$_d" "$_p" "$_sport" "$_d" "$_sport" "$_p" >> "$TT350"
    done
    printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.158.5 dst=%s sport=57999 dport=%s src=%s dst=10.0.2.15 sport=%s dport=57999 [ASSURED] mark=0 zone=0 use=2\n' \
        "$CONTROL350" "$_p" "$CONTROL350" "$_p" >> "$TT350"
    printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=%s dst=10.199.158.5 sport=%s dport=57998 src=10.199.158.5 dst=%s sport=57998 dport=%s [ASSURED] mark=0 zone=0 use=2\n' \
        "$CONTROL350" "$_p" "$CONTROL350" "$_p" >> "$TT350"
}
# survive350: every expected daddr's forward AND reversed-orig row is
# still present and the control is gone; fills SURV350 with what is wrong.
survive350() { # survive350 <port> <daddr...>
    local _p="$1"; shift
    local _d _n=0 _sport
    SURV350=""
    for _d in "$@"; do
        _n=$((_n + 1)); _sport="$(printf '57%03d' "$_n")"
        grep -qF "src=10.199.158.5 dst=$_d sport=$_sport dport=$_p " "$TT350" \
            || SURV350+=" fwd:$_d"
        grep -qF "src=$_d dst=10.199.158.5 sport=$_p dport=$_sport " "$TT350" \
            || SURV350+=" rev:$_d"
    done
    grep -qF "src=10.199.158.5 dst=$CONTROL350 sport=57999 dport=$_p " "$TT350" \
        && SURV350+=" control-fwd-left"
    grep -qF "src=$CONTROL350 dst=10.199.158.5 sport=$_p dport=57998 " "$TT350" \
        && SURV350+=" control-rev-left"
    [[ -z "$SURV350" ]]
}

for _p350 in 2222 3128 53; do
    read -ra _set350 <<<"${EXP350[$_p350]:-}"
    if (( ${#_set350[@]} == 0 )); then
        a350 fail "port $_p350: no emitted accept daddr in the rules oracle"
        continue
    fi
    rows350 "$_p350" "${_set350[@]}"
    : > "$CTLOG350"
    _out350="$(env ARCMOCK_PASSWD_HOME="$DRIFT_HOME350" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        egresslock drop-unauthorized drift "$_p350" 2>&1)"; _rc350=$?
    _want350="drop-unauthorized: no leftover connection on port $_p350 remains that profile 'drift' does not allow"
    SURV350=""
    if [[ "$_rc350" == 0 ]] && grep -qxF "$_want350" <<<"$_out350" \
       && survive350 "$_p350" "${_set350[@]}"; then
        _dels350="$(grep -c '^conntrack -D ' "$CTLOG350")"
        _bad_dels350="$(grep '^conntrack -D ' "$CTLOG350" \
            | grep -vF -- "-d $CONTROL350 " | grep -vF -- "-s $CONTROL350 " || true)"
        if [[ "$_dels350" == 2 && -z "$_bad_dels350" ]]; then
            a350 pass
        else
            a350 fail "port $_p350: control flush log is not exactly the two control deletes (count=$_dels350, other: ${_bad_dels350:-none})"
        fi
    else
        a350 fail "port $_p350: accepted daddr survival failed: ${SURV350:-rc=$_rc350/out=$(echo "$_out350" | tail -1)}"
    fi
done

# Anti-vacuity: the survival legs must bite on an accept shape the walk
# does not know. Insert the pin line's structural sibling with a shape
# chain_accepted_daddrs does not match (`meta l4proto tcp th dport`), put
# the control row behind it, and require the flush to take it. A surviving
# row here means the legs above prove nothing for a new shape.
_pin_line350="$(grep -F "ip daddr $PINIP350 tcp dport 2222 counter accept" <<<"$rules350_out" | head -n1)"
if [[ -n "$_pin_line350" ]]; then
    _synth350="${_pin_line350/ip daddr $PINIP350 tcp dport 2222/ip daddr $CONTROL350 meta l4proto tcp th dport 2222}"
    cp "$CHAIN350" "$H350/p_drift.pre350"
    awk -v synth="$_synth350" \
        '$0 == "ip saddr 10.199.158.0/24 counter drop" && !done { print synth; done=1 } { print }' \
        "$H350/p_drift.pre350" > "$CHAIN350"
    printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.158.5 dst=%s sport=57997 dport=2222 src=%s dst=10.0.2.15 sport=2222 dport=57997 [ASSURED] mark=0 zone=0 use=2\n' \
        "$CONTROL350" "$CONTROL350" > "$TT350"
    : > "$CTLOG350"
    _out350="$(env ARCMOCK_PASSWD_HOME="$DRIFT_HOME350" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
        egresslock drop-unauthorized drift 2222 2>&1)"; _rc350=$?
    if [[ "$_rc350" == 0 ]] \
       && grep -qxF "drop-unauthorized: no leftover connection on port 2222 remains that profile 'drift' does not allow" <<<"$_out350" \
       && grep -qF "$_synth350" "$CHAIN350" \
       && ! grep -qF "dst=$CONTROL350 " "$TT350"; then
        a350 pass
    else
        a350 fail "anti-vacuity: an unpaired accept shape was not flushed (rc=$_rc350, out: $(echo "$_out350" | tail -1))"
    fi
    cp "$H350/p_drift.pre350" "$CHAIN350"
else
    a350 fail "anti-vacuity: the pin accept line is missing from the rules oracle"
fi

env ARCMOCK_PASSWD_HOME="$DRIFT_HOME350" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock teardown drift >/dev/null 2>&1 || true
: > "$TT350"
section_end egl350
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
    gateway 10.199.108.2 3128 t318-allowlist
EOF
: > "$H318/t318-allowlist"
cat > "$H318/p318.conf" <<'EOF'
profile p318 10.199.109.0/24
    gateway 10.199.109.2 3128 p318-allowlist
EOF
: > "$H318/p318-allowlist"
export ARCMOCK_PASSWD_HOME="$(conf_home "$H318/t318.conf")"
reset318() {
    cp "$H318/pristine.conf" "$H318/t318.conf"
    rm -f "$STATE/rm-container-fails" "$STATE/nft/confdir-unwritable" "$STATE/nft/f-done"
    env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure t318 >/dev/null 2>&1
    env EGRESSLOCK_SKIP_NETNS_PROBE=1 ARCMOCK_PASSWD_HOME="$(conf_home "$H318/p318.conf")" egresslock ensure p318 >/dev/null 2>&1
}
S1_318="disallow --direct: nothing was revoked — the reinstall failed before the policy was replaced and the rule was put back — state: rule restored, ruleset not replaced (the rule is back in the config; the revocation ended no connection) — next action: fix the underlying failure, then retry: egresslock disallow t318 git.example.test:2222 --direct"
S1T_318="disallow --direct: note: the failed reinstall removed containers it had started for profile 't318' — if the profile is not running now, start it again: egresslock ensure t318"
S2_318="disallow --direct: nothing was revoked — the reinstall failed before the policy was replaced, and the rule could not be put back — state: config line removed, ruleset not replaced (the revocation ended no connection) — next action: fix the underlying failure, then put the rule back and retry: egresslock allow t318 git.example.test:2222 --direct, then egresslock disallow t318 git.example.test:2222 --direct"
S2W_318="disallow --direct: warning: a plain 'egresslock ensure t318' would drop the direct rule git.example.test:2222 from the firewall without ending its open connections — restore the rule first (the allow command above)."

# H1 — handler-abort leg: the anchor is stopped before the run, so the
# failed reinstall restarts and OWNS it; the resolve die fires pre-swap,
# the cleanup removes the anchor (removal line BEFORE S1), and the S1T
# trailer names the removal and the start-again command.
reset318
cp "$H318/t318.conf" "$H318/pre.conf"
rm -f "$STATE/running/egresslock-anchor-t318"
d318="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow t318 git.example.test:2222 --direct 2>&1)"; d318_rc=$?
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
d318="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow t318 git.example.test:2222 --direct 2>&1)"; d318_rc=$?
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
d318="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow t318 git.example.test:2222 --direct 2>&1)"; d318_rc=$?
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
d318="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow t318 git.example.test:2222 --direct 2>&1)"; d318_rc=$?
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
  env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow t318 git.example.test:2222 --direct 2>&1
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
  env EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='cache.example.test=' egresslock disallow t318 git.example.test:2222 --direct 2>&1
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
d318="$(env EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock disallow t318 git.example.test:2222 --direct 2>&1)"; d318_rc=$?
if [[ "$d318_rc" == 0 ]] \
   && [[ "$d318" == *'removed: rule allow-host git.example.test:2222'* ]] \
   && [[ "$d318" != *'disallow --direct:'* ]] \
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
    gateway 10.199.99.2 3128 s206b-allowlist
EOF
: > "$S206/s206b-allowlist"

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
    gateway 10.199.101.2 3128 s208b-allowlist
EOF
: > "$S208/s208b-allowlist"

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
    gateway 10.199.103.2 3128 s217b-allowlist
EOF
: > "$S217/s217b-allowlist"
cat > "$S217/s217f.conf" <<'EOF'
profile s217f 10.199.104.0/24
    rule allow-host nonexistent.example.test:8080
    gateway 10.199.104.2 3128 s217f-allowlist
EOF
: > "$S217/s217f-allowlist"

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
    gateway 10.199.106.2 3128 s250-allowlist
EOF
: > "$S250/s250-allowlist"
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
# netns-probe diagnostics (… --rootless-netns true', quote-anchored; the
# failure-header prose 'podman rootless-netns is broken for this user'; EGL-347);
# doctor
# stdout keys; gw_apply_allowlist die strings; EGL-231 remediation strings
# (podman unshare ... $bin -L / scoped $bin -D, quote-tailed literals);
# EGL-387's whole-line `help proxy-env` fallback sentence (F2: a real
# invocation on the same line is not carved); EGL-389's printed
# `(podman exec test -e; …)` and `then remove the gateway by hand: podman
# rm -f` disclosures.
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
#     systemctl) doubles as the no-PATH-wrapper environment. `cat` is
#     present because the verified invocation-environment snapshot
#     (EGL-310 R-EGL-310-13 F1) is a normal startup dependency, like the
#     `env` dump it replaced.
e222retryof() { sed -n 's/.*fix the cause and re-run: //p' <<<"$1"; }
e222bin="$e222d/bin-nosystemd"; rm -rf "$e222bin"; mkdir -p "$e222bin"
for t in bash cat id dirname grep head; do ln -s "$(command -v "$t")" "$e222bin/$t"; done
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
mkdir -p "$S223/nogw"
cat > "$S223/nogw/s223ng.conf" <<'EOF'
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

# e223-gateway-less-rc2: EGL-366-D3 made every profile carry a gateway, so
# a conf with no gateway line no longer loads: the named parse error (rc 2)
# fires before the D2 --replace-gateway guard. That guard stays in the
# engine (D6 keeps the runtime guards; removing them is a follow-up), but
# it is unreachable from a valid conf. No container change either way.
o="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$S223/nogw/s223ng.conf")" HOME="$S223" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure --replace-gateway s223ng 2>&1)"; rc=$?
if [[ "$rc" == 2 \
      && "$o" == *"profile 's223ng' has no 'gateway' directive"* \
      && "$o" == *"fix: add a gateway line to this conf"* ]] \
   && ! grep -qE '^podman rm .* s223ng' "$STATE/opslog"; then
    a223 pass
else
    a223 fail "gateway-less flag rc 2 named (rc=$rc, out: $o)"
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
# output; the one source named is the fixed confdir, EGL-325 — a set
# EGRESSLOCK_CONF only warns and is never read, EGL-385).
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
# e223-plain-missing-tag-hint (EGL-372): plain ensure on a not-running
# gateway with the target image absent dies with the named build hint.
# This is the runtime behaviour the egl68 engine-source grep used to pin;
# it replaces that grep. Unlike e223-missing-tag-intact, the non-replace
# path legitimately rm's/owns the gateway before the image check, so this
# leg asserts only rc 1 + the named hint. The die precedes gw_start, so
# the leftover foreign IPAM holder cannot interfere.
rm -f "$STATE/running/egresslock-gateway-s223"
rm -f "$STATE/images/localhost_egresslock-gateway_latest"
o="$(run223 ensure s223 2>&1)"; rc=$?
if [[ "$rc" == 1 \
      && "$o" == *"gateway image localhost/egresslock-gateway:latest not found; build it: egresslock build-gateway"* ]]; then
    a223 pass
else
    a223 fail "plain missing-tag hint (rc=$rc, out: $o)"
fi
: > "$STATE/images/localhost_egresslock-gateway_latest"

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
printf 'profile main 10.89.0.0/24\n    frobnicate yes\n    gateway 10.89.0.2 3128 main-allowlist\n' > "$E228/.config/egresslock/main.conf"
: > "$E228/.config/egresslock/main-allowlist"
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

# e228-allowlist-all-missing-conf (EGL-310: --all is not a hidden mode)
o="$(e228miss allowlist --all main)"; rc=$?
[[ "$rc" == 2 && "$o" == *"unknown allowlist option '--all'"* \
   && "$o" == *"usage: egresslock allowlist [--direct] <profile>"* \
   && "$o" != *"config file not found"* ]] && a228 pass \
   || a228 fail "allowlist --all + missing conf (rc=$rc, out: $o)"

# e228-allowlist-dup-direct-missing-conf
o="$(e228miss allowlist --direct --direct main)"; rc=$?
[[ "$rc" == 2 && "$o" == *"allowlist takes --direct only once."* \
   && "$o" != *"config file not found"* ]] && a228 pass \
   || a228 fail "dup --direct + missing conf (rc=$rc, out: $o)"

# e228-allowlist-extra-missing-conf
o="$(e228miss allowlist main --direct extra)"; rc=$?
[[ "$rc" == 2 && "$o" == *"allowlist takes one profile name."* \
   && "$o" != *"config file not found"* ]] && a228 pass \
   || a228 fail "allowlist extra positional + missing conf (rc=$rc, out: $o)"

# e228-allowlist-direct-flag-missing-conf
o="$(e228miss allowlist-direct main --direct)"; rc=$?
[[ "$rc" == 2 && "$o" == *"the direct view is already selected; drop --direct."* \
   && "$o" == *"usage: egresslock allowlist <profile> --direct"* \
   && "$o" != *"config file not found"* ]] && a228 pass \
   || a228 fail "allowlist-direct flag + missing conf (rc=$rc, out: $o)"

# e228-allowlist-direct-extra-missing-conf
o="$(e228miss allowlist-direct main extra)"; rc=$?
[[ "$rc" == 2 && "$o" == *"allowlist-direct takes one profile name."* \
   && "$o" != *"config file not found"* ]] && a228 pass \
   || a228 fail "allowlist-direct extra + missing conf (rc=$rc, out: $o)"

# e228-allowlist-unknown-flag-missing-conf (R-EGL-310-3 F3: the generic
# --* arm, separate from the named --all arm)
o="$(e228miss allowlist --bogus main)"; rc=$?
[[ "$rc" == 2 && "$o" == *"unknown allowlist option '--bogus'"* \
   && "$o" == *"usage: egresslock allowlist [--direct] <profile>"* \
   && "$o" != *"config file not found"* && "$o" != *"direct entries"* ]] \
   && a228 pass || a228 fail "allowlist unknown flag + missing conf (rc=$rc, out: $o)"

# e228-allowlist-direct-unknown-flag-missing-conf
o="$(e228miss allowlist-direct --bogus main)"; rc=$?
[[ "$rc" == 2 && "$o" == *"unknown allowlist-direct option '--bogus'"* \
   && "$o" == *"usage: egresslock allowlist <profile> --direct"* \
   && "$o" != *"config file not found"* && "$o" != *"direct entries"* ]] \
   && a228 pass || a228 fail "allowlist-direct unknown flag + missing conf (rc=$rc, out: $o)"

# e228-allowlist-direct-missing-conf (valid argv reaches the conf load:
# rc 2 named, no inventory header)
o="$(e228miss allowlist --direct main)"; rc=$?
[[ "$rc" == 2 && "$o" == *"no profile config"* && "$o" != *"direct entries"* ]] \
   && a228 pass || a228 fail "allowlist --direct missing conf (rc=$rc, out: $o)"

# e228-allowlist-direct-shortcut-missing-conf
o="$(e228miss allowlist-direct main)"; rc=$?
[[ "$rc" == 2 && "$o" == *"no profile config"* && "$o" != *"direct entries"* ]] \
   && a228 pass || a228 fail "allowlist-direct missing conf (rc=$rc, out: $o)"

# e228-verify-ensured-extra-missing-conf
o="$(e228miss verify --ensured p)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: verify --ensured takes no profile argument."* \
   && "$o" != *"config file not found"* ]] \
   && a228 pass || a228 fail "verify --ensured extra + missing conf (rc=$rc, out: $o)"

# EGL-379: extra argv is a named usage error on verify/rules/list/teardown,
# rejected before any conf read (the empty confdir proves ordering: a read
# would fail with a config/no-profile token instead).
# e228-verify-extra-missing-conf
o="$(e228miss verify main --ensured)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: verify takes no extra arguments."* \
   && "$o" == *"usage: egresslock verify <profile> | egresslock verify --ensured"* \
   && "$o" != *"config file not found"* && "$o" != *"no profile config"* \
   && "$o" != *"using config"* ]] && a228 pass \
   || a228 fail "verify extra + missing conf (rc=$rc, out: $o)"

# e228-verify-quoted-empty-extra (D2: argc, not emptiness — a quoted empty
# trailing token is a real positional)
o="$(e228miss verify main "")"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: verify takes no extra arguments."* \
   && "$o" != *"config file not found"* && "$o" != *"no profile config"* ]] \
   && a228 pass || a228 fail "verify quoted-empty extra (rc=$rc, out: $o)"

# e228-teardown-all-runtime-missing-conf (the destructive footgun: the
# runtime sweep is `teardown --runtime` alone)
o="$(e228miss teardown all --runtime)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: teardown takes no extra arguments."* \
   && "$o" == *"usage: egresslock teardown <profile> | egresslock teardown all | egresslock teardown --runtime"* \
   && "$o" != *"config file not found"* && "$o" != *"no profile config"* \
   && "$o" != *"using config"* ]] && a228 pass \
   || a228 fail "teardown all --runtime + missing conf (rc=$rc, out: $o)"

# e228-teardown-extra-missing-conf
o="$(e228miss teardown main extra)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: teardown takes no extra arguments."* \
   && "$o" != *"config file not found"* && "$o" != *"no profile config"* ]] \
   && a228 pass || a228 fail "teardown extra + missing conf (rc=$rc, out: $o)"

# e228-list-extra-missing-conf
o="$(e228miss list extra)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: list takes no extra arguments."* \
   && "$o" == *"usage: egresslock list"* \
   && "$o" != *"config file not found"* && "$o" != *"no profile config"* ]] \
   && a228 pass || a228 fail "list extra + missing conf (rc=$rc, out: $o)"

# e228-rules-extra-missing-conf
o="$(e228miss rules main extra)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: rules takes no extra arguments."* \
   && "$o" == *"usage: egresslock rules <profile>"* \
   && "$o" != *"config file not found"* && "$o" != *"no profile config"* ]] \
   && a228 pass || a228 fail "rules extra + missing conf (rc=$rc, out: $o)"

# e228-teardown-runtime-extra-message (D2: the existing --runtime-first
# message stays byte-identical)
o="$(e228miss teardown --runtime extra)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: teardown --runtime takes no other arguments."* \
   && "$o" == *"usage: egresslock teardown --runtime"* \
   && "$o" != *"takes no extra arguments"* ]] && a228 pass \
   || a228 fail "teardown --runtime extra keeps its message (rc=$rc, out: $o)"

# e228-verify-presence-ordering (D2: the existing presence error wins over
# the new argc check)
o="$(e228miss verify "" extra)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: verify requires a profile name."* \
   && "$o" != *"takes no extra arguments"* ]] && a228 pass \
   || a228 fail "verify empty-then-extra presence order (rc=$rc, out: $o)"

# e228-teardown-presence-ordering (D2)
o="$(e228miss teardown "" extra)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: teardown requires an argument."* \
   && "$o" != *"takes no extra arguments"* ]] && a228 pass \
   || a228 fail "teardown empty-then-extra presence order (rc=$rc, out: $o)"

# e228-verify-ensured-quoted-empty (D2: the preserved --ensured message
# still wins for an empty profile token)
o="$(e228miss verify --ensured "")"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: verify --ensured takes no profile argument."* \
   && "$o" != *"takes no extra arguments"* ]] && a228 pass \
   || a228 fail "verify --ensured quoted-empty (rc=$rc, out: $o)"

# e228-bare-teardown-no-conf
o="$(e228home teardown)"; rc=$?
[[ "$rc" == 2 && "$o" == *"Error: teardown requires an argument."* \
   && "$o" != *"no profile config"* ]] && a228 pass \
   || a228 fail "bare teardown + empty confdir (rc=$rc, out: $o)"

# e228-nongw-shape-wins (D8): the argv shape error still precedes the
# config load, so a gateway-less conf (EGL-366-D3: a parse error now)
# never masks it.
o="$(env ARCMOCK_PASSWD_HOME="$(conf_home "$E228/ng.conf")" HOME="$E228" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allow ng 1.2.3.4 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"IPv4 literal"* \
   && "$o" != *"has no 'gateway' directive"* ]] && a228 pass \
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

# EGL-379 valid-form control: every documented shape still reaches its
# handler on a converged profile (no over-rejection). The control runs on
# its own mock state so the `teardown --runtime` sweep cannot disturb the
# sections that follow (egl203r consumes egl223's seeded fixture).
E228OK="$TESTROOT/e228-ok"; rm -rf "$E228OK"; mkdir -p "$E228OK"
E228STATE="$TESTROOT/e228-ok-state"; rm -rf "$E228STATE"
mkdir -p "$E228STATE/nft" "$E228STATE/networks" "$E228STATE/running" \
    "$E228STATE/containers" "$E228STATE/runargs" "$E228STATE/images"
: > "$E228STATE/images/localhost_egresslock-gateway_latest"
: > "$E228STATE/images/docker.io_library_alpine_latest"
cat > "$E228OK/main.conf" <<'EOF'
profile main 10.89.9.0/24
    gateway 10.89.9.2 3128 main-allowlist
EOF
: > "$E228OK/main-allowlist"
e228ok() { # e228ok <args...> — converged-profile fixture, isolated mock state
    env ARCMOCK_STATE="$E228STATE" ARCMOCK_PASSWD_HOME="$(conf_home "$E228OK/main.conf")" \
        HOME="$E228OK" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@" 2>&1
}

o="$(e228ok ensure main)"; rc=$?
[[ "$rc" == 0 ]] && a228 pass || a228 fail "valid form 'ensure main' (rc=$rc, out: $o)"
for _e228cmd in "verify main" "verify --ensured" "rules main" "list"; do
    # shellcheck disable=SC2086  # deliberate word split of the argv case
    o="$(e228ok $_e228cmd)"; rc=$?
    [[ "$rc" == 0 ]] && a228 pass \
       || a228 fail "valid form '$_e228cmd' (rc=$rc, out: $o)"
done
for _e228cmd in "teardown all" "teardown --runtime"; do
    # shellcheck disable=SC2086  # deliberate word split of the argv case
    o="$(e228ok $_e228cmd)"; rc=$?
    [[ "$rc" == 0 ]] && a228 pass \
       || a228 fail "valid form '$_e228cmd' (rc=$rc, out: $o)"
done

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

# EGL-387: the `proxy-env --out` help prose names the shipped backend as
# the shared-location fallback (`podman run --env KEY=value`) — a printed
# string, not an invocation, the same class as the D8 operator-remediation
# carve-outs. Whole-line match: the standalone help sentence only, nothing
# else (R-EGL-387-3 F2: a real invocation with the sentence in a trailing
# comment stays a hit).
# EGL-389: S-P3f's operator-remediation sentence names the manual removal
# (`podman rm -f <gwname>`) inside a printed disclosure — a string, not an
# invocation (same D8 class; the S-P2s sibling deliberately omits it), and
# the D2 probe die's `(podman exec test -e; ...)` parenthetical is the
# same printed-diagnostic class as the existing `(podman cp;` carve-out.
# EGL-395: the mktemp-stage die parenthetical and the S-P6 lost-result note
# likewise describe a runtime symptom to the operator; neither invokes
# podman (all calls go through rt_*).
egl175_seam_hits() { # egl175_seam_hits <file> — remaining podman command-word hits; empty = pass
  awk '
      /^rt_[a-z0-9_]+\(\)/ { in_rt=1 }
      in_rt && /^\}/ { in_rt=0; next }
      in_rt { next }
      { print }
  ' "$1" \
    | grep -vE "^[[:space:]]*#" \
    | grep -vxE '[[:space:]]*pass them to podman run with --env KEY=value\.' \
    | grep -vE "podman network rm ('[$]name'|'[$]net'|'[$]1'|<name>)" \
    | grep -vE "podman unshare --rootless-netns nft delete" \
    | grep -vE "podman unshare --rootless-netns true'" \
    | grep -vE "podman rootless-netns is broken for this user" \
    | grep -vE 'podman unshare --rootless-netns \$bin -L -p tcp' \
    | grep -vE 'podman unshare --rootless-netns \$bin -D -p tcp' \
    | grep -vE "podman network inspect '" \
    | grep -vE "\(podman (MISSING|NetworkBackend)" \
    | grep -vE "\(podman cp;" \
    | grep -vE "\(podman exec (test -e|test -L|test -f|mktemp);" \
    | grep -vE "gateway: note: podman reported an error while publishing the configuration" \
    | grep -vF "then remove the gateway by hand: podman rm -f" \
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

# EGL-387 R-EGL-387-3 F2: the help-sentence carve-out is whole-line only —
# a real invocation sharing the line with the sentence is still a hit (the
# old substring filter dropped it).
_plant="$STATE/e175-plant-sameline"
cp "$ENG175" "$_plant"
printf '\n    podman run --network=host alpine # pass them to podman run with --env KEY=value\n' >> "$_plant"
_hits="$(egl175_seam_hits "$_plant")"
[[ -n "$_hits" && "$_hits" == *"podman run --network=host alpine"* ]] \
    && a175 pass || a175 fail "EGL-387 same-line invocation plant not flagged: $_hits"
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
# (19 command names incl. shortcuts and compat aliases + config + env). Contract: --help == bare help ==
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

# 3. Every topic (20 command names incl. the two visible shortcuts, two
#    hidden compat aliases, and the hidden allowlist-direct + config + env)
#    exits 0 with a non-empty page.
for t in ensure verify network proxy-env rules allowlist allowlist-direct denied allow disallow \
         allow-direct disallow-direct allow-host disallow-host \
         drop-unauthorized init list doctor build-gateway teardown config env; do
    p286_out="$(env egresslock help "$t" 2>&1)"; p286_rc=$?
    if [[ "$p286_rc" == 0 && -n "$p286_out" ]]; then
        e286 pass
    else
        e286 fail "help $t (rc=$p286_rc)"
    fi
done

# 4. Every visible summary index line matches "^  <command> ...desc>" — a
#    missing/empty CMD_INDEX entry prints a bare or absent line. The two
#    shortcuts, two compat aliases, and the allowlist-direct view stay
#    hidden (EGL-365-D9 / EGL-310-D2).
s286_out="$(env egresslock --help 2>&1)"
s286_ok=1
for c in ensure verify network proxy-env rules allowlist denied allow disallow \
         drop-unauthorized init list doctor build-gateway teardown; do
    [[ "$(grep -cE "^  egresslock $c .+" <<<"$s286_out")" == 1 ]] || s286_ok=0
done
for c in allow-direct disallow-direct allow-host disallow-host allowlist-direct; do
    [[ "$(grep -cE "^  egresslock $c " <<<"$s286_out")" == 0 ]] || s286_ok=0
done
# exactly 15 visible command index lines + the --help/--version footer lines
# (the two-space Usage body line "  egresslock <command> ..." must NOT
# be counted — index lines never start with '<' or a literal '[')
[[ "$(grep -cE '^  egresslock [^<[]' <<<"$s286_out")" == 17 ]] || s286_ok=0
[[ "$s286_ok" == 1 ]] \
    && e286 pass || e286 fail "summary index incomplete or misformatted"

# 4b. D2 render bounds: every summary-index line <=100 columns; every line
#     of every help page (all 20 command topics + config/env) <=80 columns.
b286_bad=""
while IFS= read -r l; do
    (( ${#l} <= 100 )) || b286_bad="summary line ${#l} cols: $l"
done < <(env egresslock --help 2>&1)
for t in ensure verify network proxy-env rules allowlist allowlist-direct denied allow disallow \
         allow-direct disallow-direct allow-host disallow-host \
         drop-unauthorized init list doctor build-gateway teardown config env; do
    while IFS= read -r l; do
        (( ${#l} <= 80 )) || b286_bad="help $t line ${#l} cols: $l"
    done < <(env egresslock help "$t" 2>&1)
done
[[ -z "$b286_bad" ]] && e286 pass || e286 fail "render bound: $b286_bad"

# 5. Unknown topic: rc 2, names the topic, points at `egresslock help`
#    (the generic short usage is no longer printed).
u286_out="$(env egresslock help bogus-topic 2>&1)"; u286_rc=$?
u286_exp="Error: unknown help topic 'bogus-topic'.
usage: egresslock help [<command>|config|env]
run 'egresslock help' for the command list."
[[ "$u286_rc" == 2 && "$u286_out" == "$u286_exp" ]] \
    && e286 pass || e286 fail "unknown help topic rc=2 (rc=$u286_rc, out: $u286_out)"

# 5b. D1/D3 exact usage-error blocks.
o286="$(env egresslock --bogus 2>&1)"; r286=$?
o286_exp="Error: unknown option '--bogus'.
usage: egresslock <command> [args...]
commands:
  ensure verify network proxy-env rules allowlist denied allow disallow
  drop-unauthorized init list doctor build-gateway teardown
run 'egresslock help <command>' for one command's details"
[[ "$r286" == 2 && "$o286" == "$o286_exp" ]] \
    && e286 pass || e286 fail "unknown option block (rc=$r286, out: $o286)"
o286="$(env egresslock doctor extra 2>&1)"; r286=$?
o286_exp="Error: doctor takes no arguments.
usage: egresslock doctor
run 'egresslock help doctor' for details."
[[ "$r286" == 2 && "$o286" == "$o286_exp" ]] \
    && e286 pass || e286 fail "doctor extra-args block (rc=$r286, out: $o286)"
o286="$(env egresslock build-gateway --force extra 2>&1)"; r286=$?
o286_exp="Error: build-gateway takes no arguments other than --force.
usage: egresslock build-gateway [--force]
run 'egresslock help build-gateway' for details."
[[ "$r286" == 2 && "$o286" == "$o286_exp" ]] \
    && e286 pass || e286 fail "build-gateway extra-args block (rc=$r286, out: $o286)"
o286="$(env egresslock verify --ensured p 2>&1)"; r286=$?
o286_exp="Error: verify --ensured takes no profile argument.
usage: egresslock verify --ensured
run 'egresslock help verify' for details."
[[ "$r286" == 2 && "$o286" == "$o286_exp" ]] \
    && e286 pass || e286 fail "verify --ensured extra-args block (rc=$r286, out: $o286)"

# 6. Extra argument: rc 2 with the exact message and help pointer.
m286_out="$(env egresslock help a b 2>&1)"; m286_rc=$?
m286_exp="Error: egresslock help takes at most one topic.
usage: egresslock help [<command>|config|env]
run 'egresslock help' for the command list."
[[ "$m286_rc" == 2 && "$m286_out" == "$m286_exp" ]] \
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

# --- EGL-365: one allow/disallow verb, explicit path, no port defaulting --
# Mutation-proof notes name the change each assert reds:
#   path asserts      -> remove/duplicate the path line or print it after the
#                        entry lines (D7);
#   hint asserts      -> drop the hint, fire it on 80/443/bare/suffix/direct,
#                        restore the old two-command `;` switch, or move it
#                        before the entry lines (D8);
#   ACL asserts       -> restore octal (( port == 443 )) grouping or a
#                        non-decimal group label (D11);
#   refusal asserts   -> accept a literal on the proxy, default a direct port,
#                        mix paths, or let a removed protocol flag through (D1/D3/D4);
#   retry asserts     -> print a leading-dot pin token or an unfilled
#                        `:<port>` placeholder (D12(a)/(b));
#   path-scope asserts-> search both stores on disallow, drop the both-store
#                        seed, let a direct removal touch the proxy entry/ACL,
#                        or let a proxy removal touch the conf pin (D5/F5);
#   alias/gate asserts-> drop a hidden name from COMMANDS/path parsers, or lose
#                        the root/argv/lock/conf gate while hiding usage (D9);
#   spelling asserts  -> print a compat alias or a per-spelling failure label (D10);
#   help asserts      -> restore "bypasses the proxy" in the shortcut help (D6).
section_begin egl365 "EGL-365 unified allow/disallow paths"
e365() { assert "$@"; }

S365="$TESTROOT/h365"; rm -rf "$S365"; mkdir -p "$S365"
cat > "$S365/main.conf" <<'EOF'
profile main 10.199.120.0/24
    rule gateway-only
    gateway 10.199.120.2 3128 main-allowlist
EOF
: > "$S365/main-allowlist"
# EGL-366-D3: the old gateway-less (direct-only) shape lives in its own
# confdir — it no longer loads, and a sibling here would poison $S365.
mkdir -p "$S365/nogw"
cat > "$S365/nogw/direct-only.conf" <<'EOF'
profile direct-only 10.199.121.0/24
EOF
cat > "$S365/nopin.conf" <<'EOF'
profile nopin 10.199.122.0/24
    rule allow-host git.example.test:2222
    gateway 10.199.122.2 3128 nopin-allowlist
EOF
: > "$S365/nopin-allowlist"
# F1(b) regression fixture: a commented proxy source line stays effective.
cat > "$S365/comment.conf" <<'EOF'
profile comment 10.199.123.0/24
    rule gateway-only
    gateway 10.199.123.2 3128 comment-allowlist
EOF
printf 'git.example.test:2222 # retained rule\n' > "$S365/comment-allowlist"
mkdir -p "$STATE/ips" "$STATE/containers"
: > "$STATE/running/egresslock-gateway-main"
echo "egresslock-main" > "$STATE/containers/egresslock-gateway-main.net"
echo "10.199.120.2" > "$STATE/containers/egresslock-gateway-main.ip"
: > "$STATE/running/egresslock-gateway-comment"
echo "egresslock-comment" > "$STATE/containers/egresslock-gateway-comment.net"
echo "10.199.123.2" > "$STATE/containers/egresslock-gateway-comment.ip"
E365HOME="$(conf_home "$S365/main.conf")"
E365CHOME="$(conf_home "$S365/comment.conf")"
run365() { env ARCMOCK_PASSWD_HOME="$E365HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run365c() { env ARCMOCK_PASSWD_HOME="$E365CHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run365d() { env ARCMOCK_PASSWD_HOME="$(conf_home "$S365/nogw/direct-only.conf")" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
path_proxy="path: proxy — gateway allowlist $E365HOME/.config/egresslock/main-allowlist"
path_direct="path: direct — firewall rule in $E365HOME/.config/egresslock/main.conf (does not change client proxy settings)"
path_direct_comment="path: direct — firewall rule in $E365CHOME/.config/egresslock/comment.conf (does not change client proxy settings)"
note_8443_l1="note: port 8443 is not the usual HTTP(S) port. If example.test:8443 is a non-HTTP service, add a direct rule as well (this does not remove the allowlist entry):"
note_8443_l2="  egresslock allow main example.test:8443 --direct"
# Line-order proof: both fixed strings present and the first occurrence of
# <first> precedes the first occurrence of <second> (D7/D8 placement).
e365_ordered() { # e365_ordered <output> <first> <second> -> 1/0
    local a b
    a="$(grep -n -m1 -F "$2" <<<"$1" | cut -d: -f1)"
    b="$(grep -n -m1 -F "$3" <<<"$1" | cut -d: -f1)"
    if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then echo 1; else echo 0; fi
}
# EGL-365-D12(e): execute the command string the engine actually printed
# (the two-space D8 indent stripped by e365_hint_cmd) — not a hard-coded
# twin. A malformed printed command must red the calling assert.
e365_hint_cmd() { # <stderr-file> -> the single indented command line, dedented
    sed -n 's/^  \(egresslock .*\)$/\1/p' "$1"
}
e365_exec() { # <passwd-home> <command-string> [mock-dns]
    local home="$1" cmd="$2" dns="${3:-}"
    if [[ -n "$dns" ]]; then
        env ARCMOCK_PASSWD_HOME="$home" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
            EGRESSLOCK_MOCK_DNS="$dns" bash -c "$cmd"
    else
        env ARCMOCK_PASSWD_HOME="$home" EGRESSLOCK_SKIP_NETNS_PROBE=1 bash -c "$cmd"
    fi
}

# 1. A bare name defaults to the proxy path: one path line before `added:`,
#    no port hint, and the entry lands in the allowlist (not the conf).
p1_out="$(run365 allow main example.test 2>"$S365/p1.err")"; p1_rc=$?
if [[ "$p1_rc" == 0 && "$p1_out" == *"$path_proxy"* \
      && "$p1_out" == *"added: example.test"* \
      && "$(grep -c '^path:' <<<"$p1_out")" == 1 \
      && "$(e365_ordered "$p1_out" "$path_proxy" "added: example.test")" == 1 \
      && "$(grep -c '^note:' "$S365/p1.err")" == 0 ]] \
      && grep -qxF 'example.test' "$S365/main-allowlist" \
      && ! grep -q 'rule allow-host example.test' "$S365/main.conf"; then
    e365 pass
else
    e365 fail "proxy default bare name (rc=$p1_rc, out: $p1_out, err: $(cat "$S365/p1.err"))"
fi

# 2. A name:port still defaults to the proxy and a non-80/443 port prints
#    the revised D8 hint on stderr — add-a-pin advice, never a switch:
#    no `;` chain, no `disallow`, the proxy entry stays. Tested after the
#    entry line and before re_ensuring; stdout stays path + added.
p2_out="$(run365 allow main example.test:8443 2>"$S365/p2.err")"; p2_rc=$?
p2_err="$(cat "$S365/p2.err")"
if [[ "$p2_rc" == 0 && "$p2_out" == *"$path_proxy"* \
      && "$p2_out" == *"added: example.test:8443"* \
      && "$p2_err" == *"$note_8443_l1"* \
      && "$p2_err" == *"$note_8443_l2"* \
      && "$p2_err" != *";"* && "$p2_err" != *"disallow"* \
      && "$p2_err" == *"this does not remove the allowlist entry"* \
      && "$(grep -c '^note:' "$S365/p2.err")" == 1 \
      && "$(sed -n '/^note: port 8443 /,+1p' "$S365/p2.err")" == "$(printf '%s\n%s' "$note_8443_l1" "$note_8443_l2")" \
      && "$p2_out" != *"note:"* ]] \
      && grep -qxF 'example.test:8443' "$S365/main-allowlist"; then
    e365 pass
else
    e365 fail "proxy non-80/443 hint on stderr (rc=$p2_rc, out: $p2_out, err: $p2_err)"
fi

# 2b. D8 ordering in one combined stream: the hint follows the entry line
#     and precedes re_ensuring; moving it either way reds this.
p2c_out="$(run365 allow main example.test:9443 2>&1)"; p2c_rc=$?
p2c_note="note: port 9443 is not the usual HTTP(S) port. If example.test:9443 is a non-HTTP service, add a direct rule as well (this does not remove the allowlist entry):"
p2c_cmd="  egresslock allow main example.test:9443 --direct"
if [[ "$p2c_rc" == 0 && "$(grep -c '^path:' <<<"$p2c_out")" == 1 \
      && "$(grep -c '^note:' <<<"$p2c_out")" == 1 \
      && "$p2c_out" == *"$p2c_note"* \
      && "$p2c_out" == *"$p2c_cmd"* \
      && "$p2c_out" != *";"* \
      && "$(e365_ordered "$p2c_out" "$path_proxy" "added: example.test:9443")" == 1 \
      && "$(e365_ordered "$p2c_out" "added: example.test:9443" "$p2c_note")" == 1 \
      && "$(e365_ordered "$p2c_out" "$p2c_note" "$p2c_cmd")" == 1 \
      && "$(e365_ordered "$p2c_out" "$p2c_cmd" "re-ensuring profile 'main' ...")" == 1 ]] \
      && grep -qxF 'example.test:9443' "$S365/main-allowlist"; then
    e365 pass
else
    e365 fail "port hint ordering after entry, before re-ensuring (rc=$p2c_rc, out: $p2c_out)"
fi

# 2c. F1(c): a leading-dot suffix has no single-pin equivalent — the hint
#     is silent and never offers `--direct`. The suffix still lands on the
#     proxy path.
p2s_out="$(run365 allow main .suffix.example.test:2222 2>"$S365/p2s.err")"; p2s_rc=$?
if [[ "$p2s_rc" == 0 && "$p2s_out" == *"$path_proxy"* \
      && "$p2s_out" == *"added: .suffix.example.test:2222"* \
      && "$(grep -c '^note:' "$S365/p2s.err")" == 0 \
      && "$p2s_out" != *"--direct"* ]] \
      && grep -qxF '.suffix.example.test:2222' "$S365/main-allowlist"; then
    e365 pass
else
    e365 fail "leading-dot suffix is hint-silent (rc=$p2s_rc, out: $p2s_out, err: $(cat "$S365/p2s.err"))"
fi

# 2d. F1(a)/D12(e): executing the printed add-a-pin advice is additive —
#     it returns 0 and BOTH stores hold the destination afterwards (the
#     advice never claims or performs a proxy removal). The test extracts
#     the actual printed command (dedented) and runs that string; a
#     malformed printed command (e.g. appended --bad) reds this leg.
p2d_out="$(run365 allow main cache.example.test:9443 2>"$S365/p2d.err")"; p2d_rc=$?
p2d_note1="note: port 9443 is not the usual HTTP(S) port. If cache.example.test:9443 is a non-HTTP service, add a direct rule as well (this does not remove the allowlist entry):"
p2d_cmd="$(e365_hint_cmd "$S365/p2d.err")"
p2d_pin="$(e365_exec "$E365HOME" "$p2d_cmd" 2>&1)"; p2d_pin_rc=$?
if [[ "$p2d_rc" == 0 && "$(cat "$S365/p2d.err")" == *"$p2d_note1"* \
      && "$p2d_cmd" == "egresslock allow main cache.example.test:9443 --direct" \
      && "$p2d_pin_rc" == 0 && "$p2d_pin" == *"$path_direct"* \
      && "$(grep -c 'rule allow-host cache.example.test:9443' "$S365/main.conf")" == 1 ]] \
      && grep -qxF 'cache.example.test:9443' "$S365/main-allowlist"; then
    e365 pass
else
    e365 fail "add-a-pin advice leaves both stores (rc=$p2d_rc/$p2d_pin_rc, cmd=[$p2d_cmd], out: $p2d_pin, err: $(cat "$S365/p2d.err"))"
fi
run365 disallow --direct main cache.example.test:9443 >/dev/null 2>&1

# 2e. F1(b)/D12(e): a commented source entry is still effective (the
#     parser strips the comment). The hint says the proxy entry stays, and
#     the extracted add-a-pin command leaves that effective ACL in place.
p2e_out="$(run365c allow comment git.example.test:2222 2>"$S365/p2e.err")"; p2e_rc=$?
p2e_err="$(cat "$S365/p2e.err")"
p2e_cmd="$(e365_hint_cmd "$S365/p2e.err")"
p2e_pin="$(e365_exec "$E365CHOME" "$p2e_cmd" 2>&1)"; p2e_pin_rc=$?
if [[ "$p2e_rc" == 0 && "$p2e_err" == *"this does not remove the allowlist entry"* \
      && "$p2e_cmd" == "egresslock allow comment git.example.test:2222 --direct" \
      && "$p2e_err" != *";"* && "$p2e_err" != *"disallow"* \
      && "$p2e_pin_rc" == 0 && "$p2e_pin" == *"$path_direct_comment"* \
      && "$(grep -cxF 'git.example.test:2222 # retained rule' "$S365/comment-allowlist")" == 1 \
      && "$(grep -cxF 'git.example.test:2222' "$S365/comment-allowlist")" == 1 \
      && "$(grep -c 'rule allow-host git.example.test:2222' "$S365/comment.conf")" == 1 ]] \
      && grep -qx 'git.example.test' "$(mock_group_file egresslock-gateway-comment allowlist_p2222)"; then
    e365 pass
else
    e365 fail "commented proxy entry stays effective after add-a-pin (rc=$p2e_rc/$p2e_pin_rc, cmd=[$p2e_cmd], out: $p2e_pin, err: $p2e_err)"
fi
run365c disallow --direct comment git.example.test:2222 >/dev/null 2>&1

# 3. The hint is silent on port 80 (and on the bare name in #1).
p3_out="$(run365 allow main example.test:80 2>"$S365/p3.err")"; p3_rc=$?
if [[ "$p3_rc" == 0 && "$p3_out" == *"$path_proxy"* \
      && "$(grep -c '^note:' "$S365/p3.err")" == 0 ]]; then
    e365 pass
else
    e365 fail "proxy port 80 is hint-silent (rc=$p3_rc, out: $p3_out, err: $(cat "$S365/p3.err"))"
fi

# 4. D8 fires for an already-present entry too (the operator still typed
#    the port); stdout has the no-op entry line, stderr one hint.
p4_out="$(run365 allow main example.test:8443 2>"$S365/p4.err")"; p4_rc=$?
if [[ "$p4_rc" == 0 && "$p4_out" == *"entry already present: example.test:8443"* \
      && "$(grep -c '^note:' "$S365/p4.err")" == 1 \
      && "$(grep -c '^path:' <<<"$p4_out")" == 1 \
      && "$(e365_ordered "$p4_out" "$path_proxy" "entry already present: example.test:8443")" == 1 ]]; then
    e365 pass
else
    e365 fail "hint on already-present entry (rc=$p4_rc, out: $p4_out, err: $(cat "$S365/p4.err"))"
fi

# 4b. A leading-zero standard port is still the standard port: :0443 must
#     not print the non-80/443 hint (numeric compare, not string compare).
p4b_out="$(run365 allow main example.test:0443 2>"$S365/p4b.err")"; p4b_rc=$?
if [[ "$p4b_rc" == 0 && "$p4b_out" == *"added: example.test:0443"* \
      && "$(grep -c '^note:' "$S365/p4b.err")" == 0 ]]; then
    e365 pass
else
    e365 fail "leading-zero :0443 is hint-silent (rc=$p4b_rc, err: $(cat "$S365/p4b.err"))"
fi

# 4c. ... while a leading-zero non-standard port still gets the hint,
#     with the canonical decimal port in both lines.
p4c_out="$(run365 allow main example.test:0444 2>"$S365/p4c.err")"; p4c_rc=$?
p4c_cmd="$(e365_hint_cmd "$S365/p4c.err")"
if [[ "$p4c_rc" == 0 && "$(grep -c '^note:' "$S365/p4c.err")" == 1 \
      && "$(cat "$S365/p4c.err")" == *"port 444 is not the usual HTTP(S) port"* \
      && "$p4c_cmd" == "egresslock allow main example.test:444 --direct" ]]; then
    e365 pass
else
    e365 fail "leading-zero :0444 hints canonically (rc=$p4c_rc, cmd=[$p4c_cmd], err: $(cat "$S365/p4c.err"))"
fi

# 4d. D11/D8: the generated Squid ACL groups by the DECIMAL port, and the
#     printed add-a-pin command names the canonical decimal port too.
#     :0673 is port 673 — its own p673 group, never the 443/domains group
#     (the old octal `(( port == 443 ))` put it in allowlist.domains and
#     authorized 443 instead). The allowlist keeps the operator's :0673
#     spelling. Extract and RUN the printed command: conf, pin record and
#     mock chain must all carry 673, never 443 and never 0673.
#     Mutations: octal compare, raw-string group label, or printing :0673
#     in the command -> these exact lines red.
sq365="$(mock_cfg_file egresslock-gateway-main squid.conf)"
dep365="$STATE/containers-egresslock-gateway-main.cfg"
p4d_out="$(run365 allow main d11a.example.test:0673 2>"$S365/p4d.err")"; p4d_rc=$?
p4d_cmd="$(e365_hint_cmd "$S365/p4d.err")"
p4d_direct="$(e365_exec "$E365HOME" "$p4d_cmd" "d11a.example.test=192.0.2.10" 2>&1)"; p4d_direct_rc=$?
g365_domains="$(mock_group_file egresslock-gateway-main allowlist)"
g365_p673="$(mock_group_file egresslock-gateway-main allowlist_p673)"
if [[ "$p4d_rc" == 0 && "$(grep -c '^note:' "$S365/p4d.err")" == 1 \
      && "$(cat "$S365/p4d.err")" == *"port 673 is not the usual HTTP(S) port"* \
      && "$p4d_cmd" == "egresslock allow main d11a.example.test:673 --direct" \
      && "$p4d_direct_rc" == 0 && "$p4d_direct" == *"$path_direct"* ]] \
      && grep -qxF 'd11a.example.test:0673' "$S365/main-allowlist" \
      && grep -qx '    rule allow-host d11a.example.test:673' "$S365/main.conf" \
      && ! grep -q 'rule allow-host d11a.example.test:0673' "$S365/main.conf" \
      && grep -qx 'd11a.example.test|673 192.0.2.10' "$S365/main.pins" \
      && grep -q 'ip daddr 192.0.2.10 tcp dport 673 counter accept' "$STATE/nft/egresslock.p_main" \
      && ! grep -q 'ip daddr 192.0.2.10 tcp dport 443 counter accept' "$STATE/nft/egresslock.p_main" \
      && [[ -n "$g365_p673" ]] && grep -qx 'd11a.example.test' "$g365_p673" \
      && [[ -n "$g365_domains" ]] && ! grep -qx 'd11a.example.test' "$g365_domains" \
      && ! grep -q 'allowlist\.p0673\|allowlist\.p443\.' "$sq365" \
      && [[ -z "$(compgen -G "$dep365/allowlist.p0673.*")" ]] \
      && [[ -z "$(compgen -G "$dep365/allowlist.p443.*")" ]] \
      && grep -qE '^acl allowlist_p673 dstdomain -n "/etc/squid/egresslock/allowlist\.p673\.[0-9a-f]{64}"$' "$sq365" \
      && grep -qx 'acl port_p673 port 673' "$sq365" \
      && grep -qx 'http_access allow profile_subnet allowlist_p673 port_p673' "$sq365"; then
    e365 pass
else
    e365 fail "D11 :0673 ACL + printed pin are decimal p673 (rc=$p4d_rc/$p4d_direct_rc, cmd=[$p4d_cmd], out: $p4d_direct, err: $(cat "$S365/p4d.err"), acl: $(grep -m1 'p673' "$sq365" 2>/dev/null))"
fi
run365 disallow --direct main d11a.example.test:673 >/dev/null 2>&1
# 4e. D11/D8: :0443 folds into the 443 group (bare entry in domains), and
#     :08 is port 8 (own p8 group); following the printed :8 command
#     stores port 8, not :08 and not an octal-derived value. No
#     octal-derived groups appear.
p4e_out="$(run365 allow main d11b.example.test:0443 2>"$S365/p4e.err")"; p4e_rc=$?
p4f_out="$(run365 allow main d11c.example.test:08 2>"$S365/p4f.err")"; p4f_rc=$?
p4f_cmd="$(e365_hint_cmd "$S365/p4f.err")"
p4f_direct="$(e365_exec "$E365HOME" "$p4f_cmd" "d11c.example.test=192.0.2.10" 2>&1)"; p4f_direct_rc=$?
g365_domains="$(mock_group_file egresslock-gateway-main allowlist)"
g365_p8="$(mock_group_file egresslock-gateway-main allowlist_p8)"
if [[ "$p4e_rc" == 0 && "$(grep -c '^note:' "$S365/p4e.err")" == 0 \
      && "$p4f_rc" == 0 && "$(grep -c '^note:' "$S365/p4f.err")" == 1 \
      && "$(cat "$S365/p4f.err")" == *"port 8 is not the usual HTTP(S) port"* \
      && "$p4f_cmd" == "egresslock allow main d11c.example.test:8 --direct" \
      && "$p4f_direct_rc" == 0 ]] \
      && grep -qx '    rule allow-host d11c.example.test:8' "$S365/main.conf" \
      && grep -qx 'd11c.example.test|8 192.0.2.10' "$S365/main.pins" \
      && grep -q 'ip daddr 192.0.2.10 tcp dport 8 counter accept' "$STATE/nft/egresslock.p_main" \
      && [[ -n "$g365_domains" ]] && grep -qxF 'd11b.example.test' "$g365_domains" \
      && [[ -z "$(compgen -G "$dep365/allowlist.p0443.*")" ]] \
      && [[ -z "$(compgen -G "$dep365/allowlist.p443.*")" ]] \
      && [[ -n "$g365_p8" ]] && grep -qxF 'd11c.example.test' "$g365_p8" \
      && grep -qx 'acl port_p8 port 8' "$sq365" \
      && ! grep -qx 'd11c.example.test' "$g365_domains"; then
    e365 pass
else
    e365 fail "D11 :0443 folds to 443, :08 is port 8 (rc=$p4e_rc/$p4f_rc/$p4f_direct_rc, cmd=[$p4f_cmd], err: $(cat "$S365/p4e.err")/$(cat "$S365/p4f.err"))"
fi
run365 disallow --direct main d11c.example.test:8 >/dev/null 2>&1

# 5. --direct before the profile: direct path line, exactly one conf rule,
#    allowlist untouched, no port hint. Removal uses the same path flag.
p5_before="$(cat "$S365/main-allowlist")"
p5_out="$(run365 allow --direct main git.example.test:2222 2>"$S365/p5.err")"; p5_rc=$?
if [[ "$p5_rc" == 0 && "$p5_out" == *"$path_direct"* \
      && "$p5_out" == *"added: rule allow-host git.example.test:2222"* \
      && "$(grep -c '^path:' <<<"$p5_out")" == 1 \
      && "$(grep -c 'rule allow-host git.example.test:2222' "$S365/main.conf")" == 1 \
      && "$(cat "$S365/main-allowlist")" == "$p5_before" \
      && "$(e365_ordered "$p5_out" "$path_direct" "added: rule allow-host git.example.test:2222")" == 1 \
      && "$(grep -c '^note:' "$S365/p5.err")" == 0 ]]; then
    e365 pass
else
    e365 fail "--direct before profile (rc=$p5_rc, out: $p5_out, err: $(cat "$S365/p5.err"))"
fi
p5r_out="$(run365 disallow --direct main git.example.test:2222 2>&1)"; p5r_rc=$?
if [[ "$p5r_rc" == 0 && "$p5r_out" == *"$path_direct"* \
      && "$(grep -c '^path:' <<<"$p5r_out")" == 1 \
      && "$p5r_out" == *"removed: rule allow-host git.example.test:2222"* \
      && "$(e365_ordered "$p5r_out" "$path_direct" "removed: rule allow-host git.example.test:2222")" == 1 ]] \
      && ! grep -q 'rule allow-host git.example.test:2222' "$S365/main.conf"; then
    e365 pass
else
    e365 fail "disallow --direct before profile (rc=$p5r_rc, out: $p5r_out)"
fi

# 6. --direct after the destination is the same path; keep this pin for the
#    coexistence case below.
p6_out="$(run365 allow main git.example.test:2222 --direct 2>"$S365/p6.err")"; p6_rc=$?
if [[ "$p6_rc" == 0 && "$p6_out" == *"$path_direct"* \
      && "$(grep -c 'rule allow-host git.example.test:2222' "$S365/main.conf")" == 1 \
      && "$(grep -c '^note:' "$S365/p6.err")" == 0 ]]; then
    e365 pass
else
    e365 fail "--direct after destination (rc=$p6_rc, out: $p6_out, err: $(cat "$S365/p6.err"))"
fi

# 7. D1/D3/D4 refusals: duplicate flag, bare direct name, multiple
#    destinations, shortcut-plus-flag, and the unaccepted protocol flags all
#    exit 2 with no mutation.
p7_before_conf="$(cat "$S365/main.conf")"
p7_before_al="$(cat "$S365/main-allowlist")"
p7_bad=0
p7_dup="$(run365 allow --direct main --direct cache.example.test:8080 2>&1)"; p7_rc=$?
[[ "$p7_rc" == 2 && "$p7_dup" == *"only once"* ]] || p7_bad=1
p7_bare="$(run365 allow --direct main cache.example.test 2>&1)"; p7_rc=$?
[[ "$p7_rc" == 2 && "$p7_bare" == *"requires host:port — there is no default port"* ]] || p7_bad=1
p7_short="$(run365 allow-direct main cache.example.test 2>&1)"; p7_rc=$?
[[ "$p7_rc" == 2 && "$p7_short" == *"requires host:port — there is no default port"* ]] || p7_bad=1
p7_multi="$(run365 allow --direct main cache.example.test:8080 git.example.test:2222 2>&1)"; p7_rc=$?
[[ "$p7_rc" == 2 && "$p7_multi" == *"exactly one"* ]] || p7_bad=1
p7_flag="$(run365 allow-direct main cache.example.test:8080 --direct 2>&1)"; p7_rc=$?
[[ "$p7_rc" == 2 && "$p7_flag" == *"already selected"* ]] || p7_bad=1
for pf in --http --https --proxy; do
    p7_proto="$(run365 allow main example.test:80 "$pf" 2>&1)"; p7_rc=$?
    [[ "$p7_rc" == 2 && "$p7_proto" == *"protocol flags (--http/--https/--proxy) are not accepted"* ]] || p7_bad=1
done
if [[ "$p7_bad" == 0 && "$(cat "$S365/main.conf")" == "$p7_before_conf" \
      && "$(cat "$S365/main-allowlist")" == "$p7_before_al" ]]; then
    e365 pass
else
    e365 fail "direct/flag refusals mutate nothing (bad=$p7_bad, dup=$p7_dup, bare=$p7_bare, short=$p7_short, multi=$p7_multi, flag=$p7_flag)"
fi

# 8. D12(a)/(b): a proxy-path IPv4 literal is refused with a retry in
#    pin grammar — a leading dot is stripped, and a bare literal names the
#    required port with a runnable :443 example instead of `:<port>`.
p8_out="$(run365 allow main 192.0.2.24:11434 2>&1)"; p8_rc=$?
if [[ "$p8_rc" == 2 && "$p8_out" == *"retry with --direct: egresslock allow main 192.0.2.24:11434 --direct"* ]] \
      && ! grep -qxF '192.0.2.24:11434' "$S365/main-allowlist"; then
    e365 pass
else
    e365 fail "proxy literal refusal/retry (rc=$p8_rc, out: $p8_out)"
fi
p8dot_out="$(run365 allow main .192.0.2.24:11434 2>&1)"; p8dot_rc=$?
p8bare_out="$(run365 allow main 192.0.2.24 2>&1)"; p8bare_rc=$?
p8bdot_out="$(run365 allow main .192.0.2.24 2>&1)"; p8bdot_rc=$?
if [[ "$p8dot_rc" == 2 && "$p8dot_out" == *"retry with --direct: egresslock allow main 192.0.2.24:11434 --direct"* \
      && "$p8dot_out" != *".192.0.2.24:11434 --direct"* ]] \
      && [[ "$p8bare_rc" == 2 && "$p8bare_out" == *"the direct path requires a port, e.g. retry with: egresslock allow main 192.0.2.24:443 --direct"* ]] \
      && [[ "$p8bdot_rc" == 2 && "$p8bdot_out" == *"egresslock allow main 192.0.2.24:443 --direct"* ]] \
      && [[ "$p8bare_out" != *":<port>"* && "$p8bdot_out" != *":<port>"* ]] \
      && ! grep -qxF '.192.0.2.24:11434' "$S365/main-allowlist"; then
    e365 pass
else
    e365 fail "D12 dotted/bare literal retries are runnable (rc=$p8dot_rc/$p8bare_rc/$p8bdot_rc, out: $p8dot_out | $p8bare_out | $p8bdot_out)"
fi
# D12(e): run the retry the engine printed (not a hard-coded twin) and
# require it to reach green.
p8_cmd="$(sed -n 's/.*retry with --direct: \(egresslock .*\)$/\1/p' <<<"$p8_out")"
p8b_out="$(e365_exec "$E365HOME" "$p8_cmd" 2>&1)"; p8b_rc=$?
if [[ "$p8_cmd" == "egresslock allow main 192.0.2.24:11434 --direct" \
      && "$p8b_rc" == 0 && "$p8b_out" == *"$path_direct"* \
      && "$(grep -c 'rule allow-host 192.0.2.24:11434' "$S365/main.conf")" == 1 ]]; then
    e365 pass
else
    e365 fail "literal on direct path from the printed retry (rc=$p8b_rc, cmd=[$p8_cmd], out: $p8b_out)"
fi
run365 disallow --direct main 192.0.2.24:11434 >/dev/null 2>&1

# 9. D5 path scope (F5): the same host:port exists in BOTH stores for
#    every direct-side case. A successful direct removal and an absent-
#    direct removal leave the proxy entry AND the effective proxy ACL in
#    place; a successful proxy removal and an absent-proxy removal leave
#    the direct pin. Mutation: search both stores, or remove from the
#    wrong store -> one of these legs reds.
run365 allow main git.example.test:2222 >/dev/null 2>&1
run365 allow --direct main git.example.test:2222 >/dev/null 2>&1
if grep -qxF 'git.example.test:2222' "$S365/main-allowlist" \
   && grep -q 'rule allow-host git.example.test:2222' "$S365/main.conf" \
   && grep -qx 'git.example.test' "$(mock_group_file egresslock-gateway-main allowlist_p2222)"; then
    e365 pass
else
    e365 fail "proxy and direct entries coexist (effective proxy ACL present)"
fi
p9c_out="$(run365 disallow --direct main git.example.test:2222 2>&1)"; p9c_rc=$?
if [[ "$p9c_rc" == 0 && "$p9c_out" == *"$path_direct"* ]] \
      && [[ "$(e365_ordered "$p9c_out" "$path_direct" "removed: rule allow-host git.example.test:2222")" == 1 ]] \
      && ! grep -q 'rule allow-host git.example.test:2222' "$S365/main.conf" \
      && grep -qxF 'git.example.test:2222' "$S365/main-allowlist" \
      && grep -qx 'git.example.test' "$(mock_group_file egresslock-gateway-main allowlist_p2222)"; then
    e365 pass
else
    e365 fail "direct disallow leaves the proxy store+ACL (rc=$p9c_rc, out: $p9c_out)"
fi
p9d_out="$(run365 disallow --direct main git.example.test:2222 2>&1)"; p9d_rc=$?
if [[ "$p9d_rc" == 1 && "$p9d_out" == *"rule not present"* && "$p9d_out" == *"(direct path)"* ]] \
      && grep -qxF 'git.example.test:2222' "$S365/main-allowlist" \
      && grep -qx 'git.example.test' "$(mock_group_file egresslock-gateway-main allowlist_p2222)"; then
    e365 pass
else
    e365 fail "absent direct path exits 1 and leaves the proxy store+ACL (rc=$p9d_rc, out: $p9d_out)"
fi
run365 allow --direct main git.example.test:2222 >/dev/null 2>&1
p9_out="$(run365 disallow main git.example.test:2222 2>&1)"; p9_rc=$?
if [[ "$p9_rc" == 0 && "$p9_out" == *"$path_proxy"* ]] \
      && [[ "$(e365_ordered "$p9_out" "$path_proxy" "removed: git.example.test:2222")" == 1 ]] \
      && ! grep -qxF 'git.example.test:2222' "$S365/main-allowlist" \
      && grep -q 'rule allow-host git.example.test:2222' "$S365/main.conf"; then
    e365 pass
else
    e365 fail "proxy disallow leaves the direct pin (rc=$p9_rc, out: $p9_out)"
fi
p9b_out="$(run365 disallow main git.example.test:2222 2>&1)"; p9b_rc=$?
if [[ "$p9b_rc" == 1 && "$p9b_out" == *"entry not present: git.example.test:2222 (proxy path)"* ]] \
      && grep -q 'rule allow-host git.example.test:2222' "$S365/main.conf"; then
    e365 pass
else
    e365 fail "absent proxy path does not search direct (rc=$p9b_rc, out: $p9b_out)"
fi
run365 disallow --direct main git.example.test:2222 >/dev/null 2>&1

# 10. allow-direct/disallow-direct are the flag's shortcut; allow-host and
#     disallow-host remain full compat aliases; help marks the alias.
p10_out="$(run365 allow-direct main cache.example.test:8080 2>&1)"; p10_rc=$?
if [[ "$p10_rc" == 0 && "$p10_out" == *"$path_direct"* \
      && "$(grep -c 'rule allow-host cache.example.test:8080' "$S365/main.conf")" == 1 ]]; then
    e365 pass
else
    e365 fail "allow-direct shortcut (rc=$p10_rc, out: $p10_out)"
fi
p10b_out="$(run365 disallow-direct main cache.example.test:8080 2>&1)"; p10b_rc=$?
[[ "$p10b_rc" == 0 && "$p10b_out" == *"$path_direct"* \
   && "$p10b_out" == *"removed: rule allow-host cache.example.test:8080"* ]] \
    && e365 pass || e365 fail "disallow-direct shortcut (rc=$p10b_rc, out: $p10b_out)"
p10c_out="$(run365 allow-host main cache.example.test:8080 2>&1)"; p10c_rc=$?
[[ "$p10c_rc" == 0 && "$p10c_out" == *"$path_direct"* \
   && "$(grep -c 'rule allow-host cache.example.test:8080' "$S365/main.conf")" == 1 ]] \
    && e365 pass || e365 fail "allow-host compat alias (rc=$p10c_rc, out: $p10c_out)"
p10d_out="$(run365 disallow-host main cache.example.test:8080 2>&1)"; p10d_rc=$?
[[ "$p10d_rc" == 0 && "$p10d_out" == *"$path_direct"* \
   && "$p10d_out" == *"removed: rule allow-host cache.example.test:8080"* ]] \
    && e365 pass || e365 fail "disallow-host compat alias (rc=$p10d_rc, out: $p10d_out)"
# Flatten help's line wrapping before matching the honesty sentence
# (F6): the phrase must be present, but it may be folded at any width.
p10h_out="$(env egresslock help allow-host 2>&1 | tr '\n' ' ')"
[[ "$p10h_out" == *"Compatibility name for"* \
   && "$p10h_out" == *"egresslock allow <profile> <host:port> --direct"* \
   && "$p10h_out" == *"does not change client proxy settings"* \
   && "$p10h_out" != *"bypasses the proxy"* ]] \
    && e365 pass || e365 fail "help allow-host marks compatibility + canonical form"
p10h2_out="$(env egresslock help allow-direct 2>&1 | tr '\n' ' ')"
[[ "$p10h2_out" == *"Shortcut for"* \
   && "$p10h2_out" == *"does not change client proxy settings"* \
   && "$p10h2_out" != *"bypasses the proxy"* ]] \
    && e365 pass || e365 fail "help allow-direct is firewall-only honest (F6)"
# F4: help allow/disallow match the released pages verbatim, including the
# D13 vocabulary and the D8 add-a-rule description. A wording drift on
# either page reds these two exact pins (help-page width stays EGL-286's).
p10h3_exp="$(cat <<'EOF'
egresslock allow [--direct] <profile> <host...>

Allow a destination. A name, with or without a port, uses the proxy
path and lands in the gateway allowlist; a bare name means HTTPS/443.
--direct adds a firewall rule instead.

Arguments and flags:
  <profile>    profile (required)
  <host...>    one or more destinations (proxy path), or exactly one
               host:port with --direct
  --direct     add a firewall rule instead of an allowlist entry; the
               flag is command-level and takes no port. Direct always
               needs host:port (there is no default port). An IPv4
               literal is refused on the proxy path and needs --direct.
               Shortcut: egresslock allow-direct <profile> <host:port>

Every successful run prints one `path:` line naming the store it
changed. A proxy allow on a port other than 80/443 prints a stderr
note with the command to add a firewall rule as well.

Examples:
  egresslock allow main example.com
  egresslock allow main example.com:8443
  egresslock allow main git.example.test:2222 --direct

Exit codes:
  0  success
  1  fail closed (the message names the cause)
  2  usage error
EOF
)"
p10h3_out="$(env egresslock help allow 2>&1)"
[[ "$p10h3_out" == "$p10h3_exp" ]] \
    && e365 pass || e365 fail "help allow matches the F4 page"
p10h4_exp="$(cat <<'EOF'
egresslock disallow [--direct] <profile> <host...>

Remove a destination from one path and re-ensure the profile.

Arguments and flags:
  <profile>    profile (required)
  <host...>    one or more destinations (proxy path), or exactly one
               host:port with --direct
  --direct     remove the firewall rule instead of the allowlist
               entry; the flag is command-level. Removal is
               path-scoped: the same host:port may exist in both
               stores, and each removal needs its matching path.
               Removing a direct rule also ends the established
               flows it allowed, except flows to a destination the
               policy still allows on the same TCP port.
               Shortcut: egresslock disallow-direct <profile> <host:port>

Every successful run prints one `path:` line naming the store it
changed.

Examples:
  egresslock disallow main example.com:443
  egresslock disallow main git.example.test:2222 --direct

Exit codes:
  0  success
  1  fail closed (the message names the cause)
  2  usage error
EOF
)"
p10h4_out="$(env egresslock help disallow 2>&1)"
[[ "$p10h4_out" == "$p10h4_exp" ]] \
    && e365 pass || e365 fail "help disallow matches the F4 page"
p10u_out="$(env egresslock --help 2>&1)"; p10su_out="$(env egresslock 2>&1)"
if [[ "$p10u_out" != *"allow-host"* && "$p10u_out" != *"disallow-host"* \
      && "$p10u_out" != *"allow-direct"* && "$p10u_out" != *"disallow-direct"* \
      && "$p10u_out" == *"remove a destination from one path"* \
      && "$p10u_out" != *"lane"* \
      && "$p10su_out" != *"allow-host"* && "$p10su_out" != *"allow-direct"* ]]; then
    e365 pass
else
    e365 fail "usage/short usage hide the four non-canonical names"
fi

# 11. D9: every hidden spelling still runs the pre-dispatch gate. Root
#     guard (PATH id=0) and argv shape (bad host:port) are asserted for
#     all four; the account writer lock for all four (allow and disallow,
#     shortcut and compat alias) with no mutation on either disallow.
p11_bad=0
for pc in "allow-direct main cache.example.test:8080" \
          "disallow-direct main cache.example.test:8080" \
          "allow-host main cache.example.test:8080" \
          "disallow-host main cache.example.test:8080"; do
    # shellcheck disable=SC2086
    p11_out="$(PATH="$TESTROOT/bin-root:$PATH" env ARCMOCK_PASSWD_HOME="$E365HOME" egresslock $pc 2>&1)"; p11_rc=$?
    [[ "$p11_rc" == 1 && "$p11_out" == *"must run as the account, not root"* ]] || p11_bad=1
done
for pc in "allow-direct main bad~entry:8080" "disallow-direct main bad~entry:8080" \
          "allow-host main bad~entry:8080" "disallow-host main bad~entry:8080"; do
    # shellcheck disable=SC2086
    p11_out="$(env ARCMOCK_PASSWD_HOME="$E365HOME" egresslock $pc 2>&1)"; p11_rc=$?
    [[ "$p11_rc" == 2 && "$p11_out" == *"invalid direct entry"* ]] || p11_bad=1
done
[[ "$p11_bad" == 0 ]] && e365 pass || e365 fail "alias root guard + argv shape gates"
# Seed both stores so a disallow spelling that skipped the account lock
# would remove its entry — the no-mutation half of the pin. Each disallow
# spelling gets its own direct pin (9090/9091) and its own proxy entry, so
# dropping one spelling from the lock reds only that spelling's pin, never
# the innocent sibling.
run365 allow main git.example.test:9090 >/dev/null 2>&1
run365 allow --direct main git.example.test:9090 >/dev/null 2>&1
run365 allow main git.example.test:9091 >/dev/null 2>&1
run365 allow --direct main git.example.test:9091 >/dev/null 2>&1
p11l_direct9090="$(grep -c 'rule allow-host git.example.test:9090' "$S365/main.conf")"
p11l_direct9091="$(grep -c 'rule allow-host git.example.test:9091' "$S365/main.conf")"
p11l_proxy9090="$(grep -c '^git\.example\.test:9090$' "$S365/main-allowlist")"
p11l_proxy9091="$(grep -c '^git\.example\.test:9091$' "$S365/main-allowlist")"
# Pin the seed at exactly one each: a silently failed seed would make the
# 0 == 0 no-mutation halves vacuous (the rc/message legs still name a
# lock-list mutation, but the store halves would not).
if [[ "$p11l_direct9090" == 1 && "$p11l_direct9091" == 1 \
      && "$p11l_proxy9090" == 1 && "$p11l_proxy9091" == 1 ]]; then
    e365 pass
else
    e365 fail "D9 lock seeds present once (conf: $p11l_direct9090/$p11l_direct9091, proxy: $p11l_proxy9090/$p11l_proxy9091)"
fi
mkdir -p "$E365HOME/.local/state/egresslock"
exec 8>>"$E365HOME/.local/state/egresslock/engine.lock"
flock -x 8
# shellcheck disable=SC2086
p11l_out="$(EGRESSLOCK_LOCK_WAIT=0 env ARCMOCK_PASSWD_HOME="$E365HOME" egresslock allow-direct main cache.example.test:8080 2>&1)"; p11l_rc=$?
# shellcheck disable=SC2086
p11l2_out="$(EGRESSLOCK_LOCK_WAIT=0 env ARCMOCK_PASSWD_HOME="$E365HOME" egresslock allow-host main cache.example.test:8080 2>&1)"; p11l2_rc=$?
# shellcheck disable=SC2086
p11l3_out="$(EGRESSLOCK_LOCK_WAIT=0 env ARCMOCK_PASSWD_HOME="$E365HOME" egresslock disallow-direct main git.example.test:9090 2>&1)"; p11l3_rc=$?
# shellcheck disable=SC2086
p11l4_out="$(EGRESSLOCK_LOCK_WAIT=0 env ARCMOCK_PASSWD_HOME="$E365HOME" egresslock disallow-host main git.example.test:9091 2>&1)"; p11l4_rc=$?
flock -u 8; exec 8>&-
if [[ "$p11l_rc" == 1 && "$p11l_out" == *"another egresslock command is running"* \
      && "$p11l2_rc" == 1 && "$p11l2_out" == *"another egresslock command is running"* ]]; then
    e365 pass
else
    e365 fail "alias allow account lock gate (rc=$p11l_rc/$p11l2_rc)"
fi
if [[ "$p11l3_rc" == 1 && "$p11l3_out" == *"another egresslock command is running"* \
      && "$(grep -c 'rule allow-host git.example.test:9090' "$S365/main.conf")" == "$p11l_direct9090" \
      && "$(grep -c '^git\.example\.test:9090$' "$S365/main-allowlist")" == "$p11l_proxy9090" ]]; then
    e365 pass
else
    e365 fail "disallow-direct account lock gate + no mutation (rc=$p11l3_rc, out: $p11l3_out)"
fi
if [[ "$p11l4_rc" == 1 && "$p11l4_out" == *"another egresslock command is running"* \
      && "$(grep -c 'rule allow-host git.example.test:9091' "$S365/main.conf")" == "$p11l_direct9091" \
      && "$(grep -c '^git\.example\.test:9091$' "$S365/main-allowlist")" == "$p11l_proxy9091" ]]; then
    e365 pass
else
    e365 fail "disallow-host account lock gate + no mutation (rc=$p11l4_rc, out: $p11l4_out)"
fi

# 12. EGL-366-D3: a gateway-less (direct-only) profile no longer loads.
#     The direct path is not a separate parse mode, so BOTH spellings stop
#     at the named parse error and nothing is written to the conf.
p12_out="$(run365d allow-direct direct-only cache.example.test:8080 2>&1)"; p12_rc=$?
p12b_out="$(run365d allow direct-only cache.example.test 2>&1)"; p12b_rc=$?
if [[ "$p12_rc" == 2 && "$p12_out" == *"profile 'direct-only' has no 'gateway' directive"* \
      && "$p12b_rc" == 2 && "$p12b_out" == *"profile 'direct-only' has no 'gateway' directive"* \
      && "$(grep -c 'rule allow-host cache.example.test:8080' "$S365/nogw/direct-only.conf")" == 0 ]]; then
    e365 pass
else
    e365 fail "gateway-less direct path refused named (rc=$p12_rc/$p12b_rc, out: $p12_out / $p12b_out)"
fi

# 13. D10(a): a failure reached via disallow-host prints the canonical
#     disallow retry -- never the compat alias, and the label is canonical.
p13_out="$(env ARCMOCK_PASSWD_HOME="$E365HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow-host nopin git.example.test:2222 2>&1)"; p13_rc=$?
if [[ "$p13_rc" == 1 && "$p13_out" == *"disallow --direct: profile 'nopin' has no installed firewall rules"* \
      && "$p13_out" == *"retry: egresslock disallow nopin git.example.test:2222 --direct"* \
      && "$p13_out" != *"egresslock disallow-host"* \
      && "$p13_out" != *"disallow-host:"* ]]; then
    e365 pass
else
    e365 fail "disallow-host canonical retry/label (rc=$p13_rc, out: $(echo "$p13_out" | tr '\n' '|'))"
fi

# 14. D10(b): the shared deep failure/recovery label is byte-identical for
#     all three spellings (canonical flag, shortcut, compat alias). The
#     mocked -L failure lands after the conf delete + swap, so the S3
#     disclosure prints; the pin is re-added before each run.
p14_lines=()
p14_bad=0
for pc in "disallow --direct main cache.example.test:8080" \
          "disallow-direct main cache.example.test:8080" \
          "disallow-host main cache.example.test:8080"; do
    run365 allow --direct main cache.example.test:8080 >/dev/null 2>&1 || p14_bad=1
    printf 'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.120.5 dst=192.0.2.11 sport=40001 dport=8080 src=192.0.2.11 dst=10.0.2.15 sport=8080 dport=40001 [ASSURED] mark=0 zone=0 use=2\n' \
        > "$STATE/nft/conntrack-table"
    touch "$STATE/nft/conntrack-list-fails"
    # shellcheck disable=SC2086
    p14_out="$(run365 $pc 2>&1)"; p14_rc=$?
    rm -f "$STATE/nft/conntrack-list-fails"
    [[ "$p14_rc" == 1 && "$p14_out" != *"removed:"* ]] || p14_bad=1
    p14_line="$(grep -m1 '^disallow --direct:' <<<"$p14_out" || true)"
    [[ -n "$p14_line" ]] || p14_bad=1
    p14_lines+=("$p14_line")
done
if [[ "$p14_bad" == 0 && "${p14_lines[0]}" == "${p14_lines[1]}" \
      && "${p14_lines[1]}" == "${p14_lines[2]}" \
      && "${p14_lines[0]}" == *"next action: end the leftover connections: egresslock drop-unauthorized main 8080"* ]]; then
    e365 pass
else
    e365 fail "deep label identical across spellings (bad=$p14_bad, lines: ${p14_lines[*]})"
fi

# 15. D14: the EGL-120 resolve-failure hint is state-proved, three ways.
#     never-installed = no pin key + readable chain + no pin accept on
#     the port; installed = pin key AND record matches the live chain
#     (the proof disallow --direct needs); anything else = unknown.
#     Every suggested command is extracted from the emitted text and run
#     (D12(e)); each alternative gets an independently reset fixture.
S14="$S365/d14"; rm -rf "$S14"; mkdir -p "$S14"
mk_d14_conf() {
    cat > "$S14/d14.conf" <<'EOF'
profile d14 10.199.124.0/24
    rule gateway-only
    gateway 10.199.124.2 3128 d14-allowlist
EOF
}
mk_d14_conf
: > "$S14/d14-allowlist"
D14HOME="$(conf_home "$S14/d14.conf")"
D14CONF="$D14HOME/.config/egresslock/d14.conf"
: > "$STATE/running/egresslock-gateway-d14"
echo "egresslock-d14" > "$STATE/containers/egresslock-gateway-d14.net"
echo "10.199.124.2" > "$STATE/containers/egresslock-gateway-d14.ip"
run14() { env ARCMOCK_PASSWD_HOME="$D14HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
mkdir -p "$S14/bin"
cat > "$S14/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
case ",${D14_PINMKTEMP:-}," in
    *,on,*) for a in "$@"; do [[ "$a" == *"/d14.pins."?????? ]] && exit 1; done ;;
esac
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$S14/bin/mktemp"
run14p() { env PATH="$S14/bin:$PATH" D14_PINMKTEMP=on ARCMOCK_PASSWD_HOME="$D14HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
reset14() {
    mk_d14_conf
    : > "$S14/d14-allowlist"
    rm -f "$S14/d14.pins" "$STATE/nft/egresslock.p_d14"
    run14 ensure d14 >/dev/null 2>&1
}
d14_hint_cmd() { # <text> <prefix> -> the command after prefix
    sed -n "s/^$2 \\(egresslock .*\\)$/\\1/p" <<<"$1"
}
add14_rule() { printf '    rule allow-host %s\n' "$1" >> "$D14CONF"; }

# 15a. never-installed: a healthy chain with no pin key and no accept on
#      8080, reached by an unresolvable `allow --direct` (the CLI path).
reset14 || e365 fail "D14 never-installed seed ensure"
o="$(run14 allow --direct d14 nonexistent.example.test:8080 2>&1)"; rc=$?
d14_h1="hint: this rule is in $D14CONF but was not installed — no live flows were opened; delete the line 'rule allow-host nonexistent.example.test:8080' from $D14CONF"
d14_h2="hint: after that line is gone, for a same-host HTTP(S) service use: egresslock allow d14 nonexistent.example.test:8080"
d14_h3="hint: after that line is gone, for a same-host non-HTTP service use: egresslock allow d14 169.254.1.2:8080 --direct"
if [[ "$rc" == 1 && "$o" == *"cannot resolve nonexistent.example.test"* \
      && "$o" == *"$d14_h1"* && "$o" == *"$d14_h2"* && "$o" == *"$d14_h3"* \
      && "$(grep -c '^hint:' <<<"$o")" == 3 \
      && "$o" != *"egresslock disallow"* \
      && "$o" == *"no live flows were opened"* \
      && "$o" != *"was installed before"* && "$o" != *"is not proved"* ]]; then
    e365 pass
else
    e365 fail "D14 never-installed branch (rc=$rc, out: $(echo "$o" | tr '\n' '|'))"
fi
d14_del_line="$(sed -n "s/^hint: this rule is in .*; delete the line '\\(rule allow-host [^']*\\)' from .*$/\\1/p" <<<"$o")"
d14_del_conf="$(sed -n "s/^hint: this rule is in \\(.*\\) but was not installed.*$/\\1/p" <<<"$o")"
d14_http_cmd="$(d14_hint_cmd "$o" 'hint: after that line is gone, for a same-host HTTP(S) service use:')"
d14_ip_cmd="$(d14_hint_cmd "$o" 'hint: after that line is gone, for a same-host non-HTTP service use:')"
if [[ "$d14_del_line" == "rule allow-host nonexistent.example.test:8080" \
      && "$d14_del_conf" == "$D14CONF" \
      && "$d14_http_cmd" == "egresslock allow d14 nonexistent.example.test:8080" \
      && "$d14_ip_cmd" == "egresslock allow d14 169.254.1.2:8080 --direct" ]]; then
    e365 pass
else
    e365 fail "D14 never-installed printed instructions parse (line=[$d14_del_line], conf=[$d14_del_conf], http=[$d14_http_cmd], ip=[$d14_ip_cmd])"
fi
# The named line is the only edit; a re-ensure is green and leaves no
# pin record and no dport-8080 accept (never installed).
{ grep -vxF "    $d14_del_line" "$d14_del_conf" || true; } > "$S14/d14.fix"
mv "$S14/d14.fix" "$d14_del_conf"
o="$(run14 ensure d14 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"profile 'd14' ready (network egresslock-d14, policy verified)"* \
      && ! -e "$S14/d14.pins" ]] \
      && ! grep -q 'tcp dport 8080' "$STATE/nft/egresslock.p_d14"; then
    e365 pass
else
    e365 fail "D14 never-installed conf deletion recovers green, no pin/flow (rc=$rc, out: $o)"
fi
# Each alternative runs on its own reset fixture (the conf line is gone).
reset14 || e365 fail "D14 HTTP-alternative reset"
o="$(e365_exec "$D14HOME" "$d14_http_cmd" 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"added: nonexistent.example.test:8080"* ]] \
      && grep -qxF 'nonexistent.example.test:8080' "$S14/d14-allowlist" \
      && ! grep -q 'rule allow-host nonexistent.example.test' "$D14CONF" \
      && [[ ! -e "$S14/d14.pins" ]] \
      && ! grep -q 'tcp dport 8080' "$STATE/nft/egresslock.p_d14"; then
    e365 pass
else
    e365 fail "D14 printed HTTP(S) alternative reaches green (rc=$rc, out: $o)"
fi
reset14 || e365 fail "D14 IP-alternative reset"
o="$(e365_exec "$D14HOME" "$d14_ip_cmd" 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"added: rule allow-host 169.254.1.2:8080"* ]] \
      && grep -qx '    rule allow-host 169.254.1.2:8080' "$D14CONF" \
      && grep -qx '169.254.1.2|8080 169.254.1.2' "$S14/d14.pins" \
      && grep -q 'ip daddr 169.254.1.2 tcp dport 8080 counter accept' "$STATE/nft/egresslock.p_d14"; then
    e365 pass
else
    e365 fail "D14 printed non-HTTP alternative reaches green (rc=$rc, out: $o)"
fi

# 15b. installed: pin key present and matching the live chain, then DNS
#      down -> the running firewall still allows it; the extracted direct
#      revocation runs green (conf + pin + chain cleared).
reset14 || e365 fail "D14 installed seed ensure"
add14_rule 'git.example.test:8080'
o="$(run14 ensure d14 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"profile 'd14' ready (network egresslock-d14, policy verified)"* ]] \
      && grep -qx 'git.example.test|8080 192.0.2.10' "$S14/d14.pins" \
      && grep -q 'ip daddr 192.0.2.10 tcp dport 8080 counter accept' "$STATE/nft/egresslock.p_d14"; then
    e365 pass
else
    e365 fail "D14 installed seed (rc=$rc, out: $o, pins: $(cat "$S14/d14.pins" 2>/dev/null))"
fi
o="$(EGRESSLOCK_MOCK_DNS="git.example.test=" run14 ensure d14 2>&1)"; rc=$?
d14_hinst="hint: this rule was installed before the resolve failure; the running firewall still allows it — remove it and end its flows with: egresslock disallow d14 git.example.test:8080 --direct"
if [[ "$rc" == 1 && "$o" == *"cannot resolve git.example.test"* \
      && "$o" == *"$d14_hinst"* && "$(grep -c '^hint:' <<<"$o")" == 1 \
      && "$o" != *"was not installed"* && "$o" != *"after that line is gone"* ]]; then
    e365 pass
else
    e365 fail "D14 installed branch (rc=$rc, out: $(echo "$o" | tr '\n' '|'))"
fi
d14_revoke="$(sed -n 's/.*with: \(egresslock .*\)$/\1/p' <<<"$o")"
if [[ "$d14_revoke" == "egresslock disallow d14 git.example.test:8080 --direct" ]]; then
    e365 pass
else
    e365 fail "D14 installed revocation parses (cmd=[$d14_revoke])"
fi
o="$(e365_exec "$D14HOME" "$d14_revoke" 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"removed: rule allow-host git.example.test:8080"* ]] \
      && ! grep -q 'rule allow-host git.example.test:8080' "$D14CONF" \
      && ! grep -q '^git\.example\.test|8080 ' "$S14/d14.pins" 2>/dev/null \
      && ! grep -q 'ip daddr 192.0.2.10 tcp dport 8080 counter accept' "$STATE/nft/egresslock.p_d14"; then
    e365 pass
else
    e365 fail "D14 extracted installed revocation reaches green (rc=$rc, out: $o)"
fi

# 15c. unknown: a post-swap pin-record write failure leaves a live accept
#      with no pin record. With DNS down the hint must say the state is
#      unproved: no "no live flows", no conf-only delete, no disallow
#      command, and the live accept stays.
reset14 || e365 fail "D14 unknown-missing-pin seed ensure"
o="$(run14p allow --direct d14 git.example.test:8080 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"cannot write the pin record"* \
      && ! -e "$S14/d14.pins" ]] \
      && grep -q 'rule allow-host git.example.test:8080' "$D14CONF" \
      && grep -q 'ip daddr 192.0.2.10 tcp dport 8080 counter accept' "$STATE/nft/egresslock.p_d14"; then
    e365 pass
else
    e365 fail "D14 unknown seed: post-swap pin write failure (rc=$rc, out: $o)"
fi
o="$(EGRESSLOCK_MOCK_DNS="git.example.test=" run14 ensure d14 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"cannot resolve git.example.test"* \
      && "$o" == *"hint: the name did not resolve. Whether a firewall grant for this host:port is live is not proved."* \
      && "$o" == *"hint: inspect: egresslock verify d14"* \
      && "$o" == *"hint: do not delete the conf line and re-ensure"* \
      && "$o" != *"no live flows"* && "$o" != *"was not installed"* \
      && "$o" != *"delete the line"* && "$o" != *"egresslock disallow"* ]] \
      && grep -q 'ip daddr 192.0.2.10 tcp dport 8080 counter accept' "$STATE/nft/egresslock.p_d14"; then
    e365 pass
else
    e365 fail "D14 unknown (missing pin + live accept) branch (rc=$rc, out: $(echo "$o" | tr '\n' '|'))"
fi

# 15d. unknown: a stale pin (IP A) vs live chain (IP B) is not proof of
#      either state; the extracted candidate `disallow --direct` must not
#      be recommended (it would fail on daddr mismatch), and the
#      kill-switch pin-record proof stays enforced.
reset14 || e365 fail "D14 unknown-stale seed ensure"
add14_rule 'git.example.test:8080'
run14 ensure d14 >/dev/null 2>&1
o="$(EGRESSLOCK_MOCK_DNS="git.example.test=192.0.2.13" run14p ensure d14 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"cannot write the pin record"* ]] \
      && grep -qx 'git.example.test|8080 192.0.2.10' "$S14/d14.pins" \
      && grep -q 'ip daddr 192.0.2.13 tcp dport 8080 counter accept' "$STATE/nft/egresslock.p_d14"; then
    e365 pass
else
    e365 fail "D14 unknown-stale seed: record A / chain B split (rc=$rc, out: $o)"
fi
o="$(EGRESSLOCK_MOCK_DNS="git.example.test=" run14 ensure d14 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"hint: the name did not resolve. Whether a firewall grant for this host:port is live is not proved."* \
      && "$o" == *"hint: inspect: egresslock verify d14"* \
      && "$o" != *"egresslock disallow"* && "$o" != *"no live flows"* \
      && "$o" != *"was not installed"* && "$o" != *"delete the line"* ]] \
      && grep -qx 'git.example.test|8080 192.0.2.10' "$S14/d14.pins" \
      && grep -q 'ip daddr 192.0.2.13 tcp dport 8080 counter accept' "$STATE/nft/egresslock.p_d14"; then
    e365 pass
else
    e365 fail "D14 unknown (stale pin vs chain) branch (rc=$rc, out: $(echo "$o" | tr '\n' '|'))"
fi
o="$(run14 disallow --direct d14 git.example.test:8080 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"direct pin daddr mismatch"* ]] \
      && grep -q 'rule allow-host git.example.test:8080' "$D14CONF" \
      && grep -q 'ip daddr 192.0.2.13 tcp dport 8080 counter accept' "$STATE/nft/egresslock.p_d14"; then
    e365 pass
else
    e365 fail "D14 kill-switch proof unchanged on the stale-record path (rc=$rc, out: $o)"
fi
# 15e. F-A (R-EGL-365-18): a direct pin to a service hosted on the
#      gateway IP is a real pin. The gateway-IP exclusion is hop-precise
#      (daddr == gw_ip AND dport == GW_PORT), so a post-swap record-write
#      failure leaves a live accept that must classify as unknown — never
#      "not installed / no live flows". Mutation: restore the daddr-only
#      skip -> this leg reds (the hint prints the never-installed branch).
reset14 || e365 fail "D14 gateway-IP pin seed ensure"
o="$(EGRESSLOCK_MOCK_DNS="gwsrv.example.test=10.199.124.2" run14p allow --direct d14 gwsrv.example.test:2222 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"cannot record the installed pins"* \
      && ! -e "$S14/d14.pins" ]] \
      && grep -q 'rule allow-host gwsrv.example.test:2222' "$D14CONF" \
      && grep -q 'ip daddr 10.199.124.2 tcp dport 2222 counter accept' "$STATE/nft/egresslock.p_d14"; then
    e365 pass
else
    e365 fail "D14 gateway-IP pin seed: post-swap record failure (rc=$rc, out: $(echo "$o" | tr '\n' '|'))"
fi
o="$(EGRESSLOCK_MOCK_DNS="gwsrv.example.test=" run14 ensure d14 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"cannot resolve gwsrv.example.test"* \
      && "$o" == *"hint: the name did not resolve. Whether a firewall grant for this host:port is live is not proved."* \
      && "$o" == *"hint: inspect: egresslock verify d14"* \
      && "$o" != *"no live flows"* && "$o" != *"was not installed"* \
      && "$o" != *"delete the line"* && "$o" != *"egresslock disallow"* ]] \
      && grep -q 'ip daddr 10.199.124.2 tcp dport 2222 counter accept' "$STATE/nft/egresslock.p_d14"; then
    e365 pass
else
    e365 fail "D14 gateway-IP live accept is unknown, not never-installed (rc=$rc, out: $(echo "$o" | tr '\n' '|'))"
fi

# 15f. F-B (R-EGL-365-18): the never-installed delete instruction quotes
#      the conf line AS STORED. A hand-edited leading-zero port and a
#      ${VAR} host must be quoted verbatim so the printed deletion removes
#      the real line and the re-ensure reaches green. Mutation: quote the
#      canonical in-memory form -> the quoted line is absent from the conf
#      and the deletion leg reds.
mk_d14raw_conf() { # <dir> <profile> <subnet> <gwip>
    local dir="$1" prof="$2" subnet="$3" gwip="$4"
    mkdir -p "$dir"
    cat > "$dir/$prof.conf" <<EOF
profile $prof $subnet
    rule gateway-only
    gateway $gwip 3128 $prof-allowlist
EOF
    : > "$dir/$prof-allowlist"
    : > "$STATE/running/egresslock-gateway-$prof"
    echo "egresslock-$prof" > "$STATE/containers/egresslock-gateway-$prof.net"
    echo "$gwip" > "$STATE/containers/egresslock-gateway-$prof.ip"
}
S14R1="$S14/raw0673"
mk_d14raw_conf "$S14R1" d14r1 10.199.125.0/24 10.199.125.2
R1HOME="$(conf_home "$S14R1/d14r1.conf")"
R1CONF="$R1HOME/.config/egresslock/d14r1.conf"
run14r1() { env ARCMOCK_PASSWD_HOME="$R1HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run14r1 ensure d14r1 >/dev/null 2>&1 || e365 fail "D14 hand-edited :0673 seed ensure"
printf '%s\n' '    rule allow-host gone.example.test:0673' >> "$R1CONF"
o="$(run14r1 ensure d14r1 2>&1)"; rc=$?
r1_line="$(sed -n "s/^hint: this rule is in .*; delete the line '\\(rule allow-host [^']*\\)' from .*$/\\1/p" <<<"$o")"
if [[ "$rc" == 1 && "$o" == *"cannot resolve gone.example.test"* \
      && "$r1_line" == "rule allow-host gone.example.test:0673" \
      && "$(grep -Fc "    $r1_line" "$R1CONF")" == 1 \
      && "$o" != *"rule allow-host gone.example.test:673'"* ]]; then
    e365 pass
else
    e365 fail "D14 hand-edited :0673 delete instruction quotes the stored line (rc=$rc, line=[$r1_line], out: $(echo "$o" | tr '\n' '|'))"
fi
{ grep -vxF "    $r1_line" "$R1CONF" || true; } > "$S14R1/d14r1.fix"
mv "$S14R1/d14r1.fix" "$R1CONF"
o="$(run14r1 ensure d14r1 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"profile 'd14r1' ready"* \
      && ! -e "$S14R1/d14r1.pins" ]] \
      && ! grep -q 'tcp dport 673' "$STATE/nft/egresslock.p_d14r1"; then
    e365 pass
else
    e365 fail "D14 hand-edited :0673 quoted deletion recovers green (rc=$rc, out: $o)"
fi
S14R2="$S14/rawvar"
mk_d14raw_conf "$S14R2" d14r2 10.199.126.0/24 10.199.126.2
R2HOME="$(conf_home "$S14R2/d14r2.conf")"
R2CONF="$R2HOME/.config/egresslock/d14r2.conf"
run14r2() { env D14VHOST=varhost.example.test ARCMOCK_PASSWD_HOME="$R2HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run14r2 ensure d14r2 >/dev/null 2>&1 || e365 fail "D14 hand-edited \${VAR} seed ensure"
printf '%s\n' '    rule allow-host ${D14VHOST}:8080' >> "$R2CONF"
o="$(run14r2 ensure d14r2 2>&1)"; rc=$?
r2_line="$(sed -n "s/^hint: this rule is in .*; delete the line '\\(rule allow-host [^']*\\)' from .*$/\\1/p" <<<"$o")"
if [[ "$rc" == 1 && "$o" == *"cannot resolve varhost.example.test"* \
      && "$r2_line" == 'rule allow-host ${D14VHOST}:8080' \
      && "$(grep -Fc "    $r2_line" "$R2CONF")" == 1 \
      && "$o" != *"rule allow-host varhost.example.test:8080'"* ]]; then
    e365 pass
else
    e365 fail "D14 hand-edited \${VAR} delete instruction quotes the stored line (rc=$rc, line=[$r2_line], out: $(echo "$o" | tr '\n' '|'))"
fi
{ grep -vxF "    $r2_line" "$R2CONF" || true; } > "$S14R2/d14r2.fix"
mv "$S14R2/d14r2.fix" "$R2CONF"
o="$(run14r2 ensure d14r2 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"profile 'd14r2' ready"* \
      && ! -e "$S14R2/d14r2.pins" ]] \
      && ! grep -q 'tcp dport 8080' "$STATE/nft/egresslock.p_d14r2"; then
    e365 pass
else
    e365 fail "D14 hand-edited \${VAR} quoted deletion recovers green (rc=$rc, out: $o)"
fi

reset14 || e365 fail "D14 final reset"

section_end egl365

# --- EGL-310: read-only direct-lane allowlist view ------------------------
section_begin egl310 "EGL-310 direct-lane allowlist view"
e310() { assert "$@"; }

S310="$TESTROOT/h310"; rm -rf "$S310"; mkdir -p "$S310"
cat > "$S310/main.conf" <<'EOF'
profile main 10.199.130.0/24
    rule gateway-only
    gateway 10.199.130.2 3128 main-allowlist
    rule allow-host git.example.test:2222
    rule allow-host no-such-host.invalid:9418
    rule allow-host 192.0.2.24:11434
    rule allow-host ${EGL310_HOST:-var.example.test}:9022
EOF
: > "$S310/main-allowlist"
# EGL-366-D3: the gateway-less (direct-only) shape lives in its own
# confdir so the rejection cannot poison the $S310 aggregate.
mkdir -p "$S310/nogw"
cat > "$S310/nogw/direct-only.conf" <<'EOF'
profile direct-only 10.199.131.0/24
    rule allow-host cache.example.test:8080
EOF
cat > "$S310/noallow.conf" <<'EOF'
profile noallow 10.199.132.0/24
    rule gateway-only
    gateway 10.199.132.2 3128 noallow-allowlist
    rule allow-host missing-file.example.test:22
EOF
cat > "$S310/empty.conf" <<'EOF'
profile empty 10.199.133.0/24
    gateway 10.199.133.2 3128 empty-allowlist
EOF
: > "$S310/empty-allowlist"
# R-EGL-310-3 F1/F3: a malformed rule line must exit 2 with the named
# config error and print no inventory on either spelling.
cat > "$S310/badport.conf" <<'EOF'
profile badport 10.199.134.0/24
    gateway 10.199.134.2 3128 badport-allowlist
    rule allow-host invalid:99999
EOF
: > "$S310/badport-allowlist"
E310HOME="$(conf_home_ro "$S310/main.conf")"
E310DHOME="$(conf_home_ro "$S310/nogw/direct-only.conf")"
E310NHOME="$(conf_home_ro "$S310/noallow.conf")"
E310EHOME="$(conf_home_ro "$S310/empty.conf")"
E310BHOME="$(conf_home_ro "$S310/badport.conf")"
# R-EGL-310-3 F4: the default-view wrappers must not inherit EGL310_HOST
# from the caller — the fixture's `${EGL310_HOST:-var.example.test}` line
# would then expand to the caller's value while the expected rows say
# var.example.test. Unset it here; the explicit-override leg sets it.
run310() { env -u EGL310_HOST ARCMOCK_PASSWD_HOME="$E310HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run310d() { env -u EGL310_HOST ARCMOCK_PASSWD_HOME="$E310DHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run310n() { env -u EGL310_HOST ARCMOCK_PASSWD_HOME="$E310NHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run310e() { env -u EGL310_HOST ARCMOCK_PASSWD_HOME="$E310EHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run310b() { env -u EGL310_HOST ARCMOCK_PASSWD_HOME="$E310BHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
h310="profile 'main' — 4 direct entries from the profile conf (pinned to addresses at ensure; traffic is not proxied):"
e310_expected="$(printf '%s\n%s\n%s\n%s\n%s' "$h310" \
    'git.example.test:2222' 'no-such-host.invalid:9418' '192.0.2.24:11434' 'var.example.test:9022')"

# 1. The direct view: exact header + rows in conf order (including a name
#    that no longer resolves and an IPv4 literal), rc 0, resolution
#    disclosure on stderr only. Mutation: change the header or point the
#    render at the compiled rules (the unresolvable name leg reds).
p1_out="$(run310 allowlist main --direct 2>"$S310/p1.err")"; p1_rc=$?
if [[ "$p1_rc" == 0 && "$p1_out" == "$e310_expected" \
      && "$(cat "$S310/p1.err")" == "using config $E310HOME/.config/egresslock/main.conf" \
      && "$p1_out" != *"using config"* ]]; then
    e310 pass
else
    e310 fail "direct view header/rows/conf order (rc=$p1_rc, out: $p1_out, err: $(cat "$S310/p1.err"))"
fi

# 2. --direct before the profile, after the profile, and the hidden
#    shortcut are byte-identical on stdout. Mutation: drop the resolver
#    flag-skip (the flag-first invocation resolves '--direct' as a profile).
p2a_out="$(run310 allowlist --direct main 2>"$S310/p2a.err")"; p2a_rc=$?
p2b_out="$(run310 allowlist main --direct 2>"$S310/p2b.err")"; p2b_rc=$?
p2c_out="$(run310 allowlist-direct main 2>"$S310/p2c.err")"; p2c_rc=$?
if [[ "$p2a_rc" == 0 && "$p2b_rc" == 0 && "$p2c_rc" == 0 \
      && "$p2a_out" == "$e310_expected" && "$p2b_out" == "$p2a_out" \
      && "$p2c_out" == "$p2a_out" \
      && "$(cat "$S310/p2c.err")" == "using config $E310HOME/.config/egresslock/main.conf" ]]; then
    e310 pass
else
    e310 fail "flag positions + shortcut byte-identical (rc=$p2a_rc/$p2b_rc/$p2c_rc)"
fi

# 3. An empty direct lane is visible, not silent: one header line with
#    `0 direct entries` (the shared EGL-375 template), rc 0.
p3_out="$(run310e allowlist --direct empty 2>"$S310/p3.err")"; p3_rc=$?
if [[ "$p3_rc" == 0 \
      && "$p3_out" == "profile 'empty' — 0 direct entries from the profile conf (pinned to addresses at ensure; traffic is not proxied):" \
      && "$(grep -c '^using config ' "$S310/p3.err")" == 1 ]]; then
    e310 pass
else
    e310 fail "empty direct lane line (rc=$p3_rc, out: $p3_out)"
fi

# 4. EGL-366-D3: a gateway-less profile no longer loads, so the direct
#    view does not exist as a gateway-free read path either — all three
#    spellings stop at the named parse error with nothing on stdout.
p4_out="$(run310d allowlist --direct direct-only 2>&1)"; p4_rc=$?
p4b_out="$(run310d allowlist-direct direct-only 2>&1)"; p4b_rc=$?
p4c_out="$(run310d allowlist direct-only 2>&1)"; p4c_rc=$?
if [[ "$p4_rc" == 2 && "$p4b_rc" == 2 && "$p4c_rc" == 2 \
      && "$p4_out" == *"profile 'direct-only' has no 'gateway' directive"* \
      && "$p4b_out" == *"profile 'direct-only' has no 'gateway' directive"* \
      && "$p4c_out" == *"profile 'direct-only' has no 'gateway' directive"* \
      && "$p4_out" != *"direct entries"* && "$p4b_out" != *"direct entries"* ]]; then
    e310 pass
else
    e310 fail "gateway-less direct view refused named (rc=$p4_rc/$p4b_rc/$p4c_rc, out: $p4c_out)"
fi

# 5. A missing proxy allowlist file does not matter to the direct view;
#    the bare file view still fails closed on it.
p5_out="$(run310n allowlist --direct noallow 2>/dev/null)"; p5_rc=$?
p5b_out="$(run310n allowlist noallow 2>&1)"; p5b_rc=$?
if [[ "$p5_rc" == 0 \
      && "$p5_out" == "profile 'noallow' — 1 direct entries from the profile conf (pinned to addresses at ensure; traffic is not proxied):"$'\n'"missing-file.example.test:22" \
      && "$p5b_rc" == 1 && "$p5b_out" == *"allowlist file missing:"* \
      && "$p5b_out" == *"noallow-allowlist"* ]]; then
    e310 pass
else
    e310 fail "missing proxy file: direct rc 0 / bare fails closed (rc=$p5_rc/$p5b_rc, out: $p5b_out)"
fi

# 6. Read-only proof: an exclusively held account lock (EGRESSLOCK_LOCK_WAIT=0)
#    does not block the view; conf/allowlist bytes and modes are unchanged;
#    no .pins appears; no ensure/mutation output. Mutation: take the lock or
#    call ensure in the direct path.
p6_conf="$E310HOME/.config/egresslock/main.conf"
p6_al="$E310HOME/.config/egresslock/main-allowlist"
p6_before="$(sha256sum "$p6_conf" "$p6_al")"
p6_modes="$(stat -c '%a %n' "$p6_conf" "$p6_al")"
p6_pins_before=0; [[ -e "$E310HOME/.config/egresslock/main.pins" ]] && p6_pins_before=1
mkdir -p "$E310HOME/.local/state/egresslock"
exec 8>>"$E310HOME/.local/state/egresslock/engine.lock"
flock -x 8
p6_out="$(EGRESSLOCK_LOCK_WAIT=0 run310 allowlist --direct main 2>"$S310/p6.err")"; p6_rc=$?
p6b_out="$(EGRESSLOCK_LOCK_WAIT=0 run310 allowlist-direct main 2>"$S310/p6b.err")"; p6b_rc=$?
flock -u 8; exec 8>&-
p6_after="$(sha256sum "$p6_conf" "$p6_al")"
p6_modes_after="$(stat -c '%a %n' "$p6_conf" "$p6_al")"
p6_pins_after=0; [[ -e "$E310HOME/.config/egresslock/main.pins" ]] && p6_pins_after=1
if [[ "$p6_rc" == 0 && "$p6b_rc" == 0 \
      && "$p6_out" == "$e310_expected" && "$p6b_out" == "$p6_out" \
      && "$p6_before" == "$p6_after" && "$p6_modes" == "$p6_modes_after" \
      && "$p6_pins_before" == 0 && "$p6_pins_after" == 0 \
      && "$p6_out" != *"re_ensuring"* && "$p6_out" != *"added:"* && "$p6_out" != *"removed:"* \
      && "$(cat "$S310/p6.err")" != *"re_ensuring"* \
      && "$(cat "$S310/p6.err")" != *"added:"* \
      && "$(cat "$S310/p6.err")" != *"removed:"* ]]; then
    e310 pass
else
    e310 fail "read-only under held lock / byte+mode+pin stability (rc=$p6_rc/$p6b_rc, pins=$p6_pins_before/$p6_pins_after)"
fi

# 6b. R-EGL-310-3 F3: an EXISTING pin record is untouched by both forms
#     (bytes and mode), not only "absent stays absent".
p6b_pins="$E310HOME/.config/egresslock/main.pins"
printf 'git.example.test|2222 192.0.2.10\n' > "$p6b_pins"
chmod 640 "$p6b_pins"
p6b_before="$(sha256sum "$p6b_pins")"
p6b_mode="$(stat -c '%a' "$p6b_pins")"
p6b_out="$(run310 allowlist --direct main 2>"$S310/p6b1.err")"; p6b_rc=$?
p6b2_out="$(run310 allowlist-direct main 2>"$S310/p6b2.err")"; p6b2_rc=$?
p6b_after="$(sha256sum "$p6b_pins")"
p6b_mode_after="$(stat -c '%a' "$p6b_pins")"
if [[ "$p6b_rc" == 0 && "$p6b2_rc" == 0 \
      && "$p6b_out" == "$e310_expected" && "$p6b2_out" == "$p6b_out" \
      && "$p6b_before" == "$p6b_after" && "$p6b_mode" == "$p6b_mode_after" ]]; then
    e310 pass
else
    e310 fail "existing pin record untouched by both forms (rc=$p6b_rc/$p6b2_rc, bytes=$([[ "$p6b_before" == "$p6b_after" ]] && echo same || echo changed), mode=$p6b_mode/$p6b_mode_after)"
fi
rm -f "$p6b_pins"

# 7. D3: a ${VAR} reference in a rule line prints expanded, exactly as
#    ensure would see it.
p7_out="$(env EGL310_HOST=custom.example.test ARCMOCK_PASSWD_HOME="$E310HOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist-direct main 2>/dev/null)"; p7_rc=$?
p7_expected="$(printf '%s\n%s\n%s\n%s\n%s' "$h310" \
    'git.example.test:2222' 'no-such-host.invalid:9418' '192.0.2.24:11434' 'custom.example.test:9022')"
if [[ "$p7_rc" == 0 && "$p7_out" == "$p7_expected" ]]; then
    e310 pass
else
    e310 fail "VAR expansion in the direct view (rc=$p7_rc, out: $p7_out)"
fi

# 7b. R-EGL-310-3 F4: a caller-set EGL310_HOST does not leak into the
#     default view (the wrappers unset it); the explicit override still
#     wins in leg 7.
p7b_out="$(EGL310_HOST=leaked.example.test run310 allowlist --direct main 2>/dev/null)"; p7b_rc=$?
if [[ "$p7b_rc" == 0 && "$p7b_out" == "$e310_expected" ]]; then
    e310 pass
else
    e310 fail "caller EGL310_HOST does not leak into the default view (rc=$p7b_rc, out: $p7b_out)"
fi

# 8. R-EGL-310-3 F3: neither spelling performs a DNS query. A failing
#    resolver wrapper logs any ahostsv4 lookup and exits 2, so a
#    gratuitous lookup whose result is discarded still reds this leg.
mkdir -p "$S310/bin-nodns"
cat > "$S310/bin-nodns/getent" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == ahostsv4 ]]; then
    printf '%s\n' "\$2" >> "$S310/dns-queries.log"
    exit 2
fi
exec "$TESTROOT/bin/getent" "\$@"
EOF
chmod +x "$S310/bin-nodns/getent"
rm -f "$S310/dns-queries.log"
p8_out="$(env -u EGL310_HOST PATH="$S310/bin-nodns:$PATH" ARCMOCK_PASSWD_HOME="$E310HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist --direct main 2>"$S310/p8.err")"; p8_rc=$?
p8b_out="$(env -u EGL310_HOST PATH="$S310/bin-nodns:$PATH" ARCMOCK_PASSWD_HOME="$E310HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist-direct main 2>"$S310/p8b.err")"; p8b_rc=$?
if [[ "$p8_rc" == 0 && "$p8b_rc" == 0 && "$p8_out" == "$e310_expected" \
      && "$p8b_out" == "$p8_out" && ! -e "$S310/dns-queries.log" ]]; then
    e310 pass
else
    e310 fail "no DNS lookups in either form (rc=$p8_rc/$p8b_rc, queries=$(cat "$S310/dns-queries.log" 2>/dev/null | tr '\n' '|'))"
fi

# 9. R-EGL-310-3 F1/F3: a malformed conf exits 2 with the named config
#    error and no inventory on stdout, on both spellings.
p9_out="$(run310b allowlist --direct badport 2>"$S310/p9.err")"; p9_rc=$?
p9b_out="$(run310b allowlist-direct badport 2>"$S310/p9b.err")"; p9b_rc=$?
p9_err="$(cat "$S310/p9.err")"; p9b_err="$(cat "$S310/p9b.err")"
if [[ "$p9_rc" == 2 && "$p9b_rc" == 2 && -z "$p9_out" && -z "$p9b_out" \
      && "$p9_err" == *"invalid port '99999'"* \
      && "$p9b_err" == *"invalid port '99999'"* \
      && "$p9_err" != *"direct entries"* && "$p9b_err" != *"direct entries"* ]]; then
    e310 pass
else
    e310 fail "malformed conf rc 2 / no inventory (rc=$p9_rc/$p9b_rc, out: $p9_out, err: $p9_err)"
fi

# 10. R-EGL-310-6 F1: a ${VAR} reference whose NAME collides with an engine
#     local (${cmd} is resolve_conf_for's local) must still read the
#     invocation environment. Both views agree, set and unset. Mutation:
#     revert cfg_expand to indirect expansion (${!name}) — the two views
#     print their own command name instead, so this leg reds.
cat > "$S310/collide.conf" <<'EOF'
profile collide 10.199.135.0/24
    rule gateway-only
    gateway 10.199.135.2 3128 collide-allowlist
    rule allow-host ${cmd:-fallback.example.test}:2222
EOF
: > "$S310/collide-allowlist"
E310CHOME="$(conf_home_ro "$S310/collide.conf")"
h310c="profile 'collide' — 1 direct entries from the profile conf (pinned to addresses at ensure; traffic is not proxied):"
exp310_set="$(printf '%s\n%s' "$h310c" 'from-env.example.test:2222')"
exp310_unset="$(printf '%s\n%s' "$h310c" 'fallback.example.test:2222')"
p10a_out="$(env cmd=from-env.example.test ARCMOCK_PASSWD_HOME="$E310CHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist collide --direct 2>/dev/null)"; p10a_rc=$?
p10b_out="$(env cmd=from-env.example.test ARCMOCK_PASSWD_HOME="$E310CHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist-direct collide 2>/dev/null)"; p10b_rc=$?
p10c_out="$(env -u cmd ARCMOCK_PASSWD_HOME="$E310CHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist collide --direct 2>/dev/null)"; p10c_rc=$?
p10d_out="$(env -u cmd ARCMOCK_PASSWD_HOME="$E310CHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist-direct collide 2>/dev/null)"; p10d_rc=$?
if [[ "$p10a_rc" == 0 && "$p10b_rc" == 0 && "$p10c_rc" == 0 && "$p10d_rc" == 0 \
      && "$p10a_out" == "$exp310_set" && "$p10b_out" == "$exp310_set" \
      && "$p10c_out" == "$exp310_unset" && "$p10d_out" == "$exp310_unset" ]]; then
    e310 pass
else
    e310 fail "colliding-name expansion (set: $p10a_out | $p10b_out; unset: $p10c_out | $p10d_out)"
fi

# 11. R-EGL-310-6 F1: ensure's parsed value is the same colliding-name
#     expansion. A section-local mock state keeps the writes out of the
#     shared harness state; the pin record is the ensure-time witness.
S310ST="$S310/state"; rm -rf "$S310ST"
mkdir -p "$S310ST/nft" "$S310ST/networks" "$S310ST/running" \
         "$S310ST/containers" "$S310ST/images" "$S310ST/ips" "$S310ST/runargs"
: > "$S310ST/images/localhost_egresslock-gateway_latest"
: > "$S310ST/images/docker.io_library_alpine_latest"
p11_dns="from-env.example.test=192.0.2.77,fallback.example.test=192.0.2.78"
env ARCMOCK_STATE="$S310ST" cmd=from-env.example.test EGRESSLOCK_MOCK_DNS="$p11_dns" \
    ARCMOCK_PASSWD_HOME="$E310CHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure collide >/dev/null 2>&1; p11_rc=$?
p11_pins="$(cat "$E310CHOME/.config/egresslock/collide.pins" 2>/dev/null || true)"
env -u cmd ARCMOCK_STATE="$S310ST" EGRESSLOCK_MOCK_DNS="$p11_dns" \
    ARCMOCK_PASSWD_HOME="$E310CHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure collide >/dev/null 2>&1; p11b_rc=$?
p11b_pins="$(cat "$E310CHOME/.config/egresslock/collide.pins" 2>/dev/null || true)"
if [[ "$p11_rc" == 0 && "$p11b_rc" == 0 \
      && "$p11_pins" == 'from-env.example.test|2222 192.0.2.77' \
      && "$p11b_pins" == 'fallback.example.test|2222 192.0.2.78' ]]; then
    e310 pass
else
    e310 fail "colliding-name ensure parse (rc=$p11_rc/$p11b_rc, pins: '$p11_pins' / '$p11b_pins')"
fi

# 12. R-EGL-310-6 F2: an UNREADABLE profile conf is a named rc-2 load
#     failure on both forms (the shell's raw redirection error used to
#     exit 1 while the help pages promise 2). Mutation: drop the loader's
#     readability guard — rc 1 with "Permission denied" reds this leg.
cat > "$S310/unreadable.conf" <<'EOF'
profile unreadable 10.199.138.0/24
    rule gateway-only
    gateway 10.199.138.2 3128 unreadable-allowlist
    rule allow-host git.example.test:2222
EOF
: > "$S310/unreadable-allowlist"
E310UHOME="$(conf_home_ro "$S310/unreadable.conf")"
u310conf="$E310UHOME/.config/egresslock/unreadable.conf"
chmod 000 "$u310conf"
p12_out="$(env ARCMOCK_PASSWD_HOME="$E310UHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist unreadable --direct 2>"$S310/p12.err")"; p12_rc=$?
p12b_out="$(env ARCMOCK_PASSWD_HOME="$E310UHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist-direct unreadable 2>"$S310/p12b.err")"; p12b_rc=$?
chmod 600 "$u310conf"
p12_err="$(cat "$S310/p12.err")"; p12b_err="$(cat "$S310/p12b.err")"
if [[ "$p12_rc" == 2 && "$p12b_rc" == 2 && -z "$p12_out" && -z "$p12b_out" \
      && "$p12_err" == *"config file cannot be read"* \
      && "$p12b_err" == *"config file cannot be read"* \
      && "$p12_err" != *"direct entries"* && "$p12b_err" != *"direct entries"* ]]; then
    e310 pass
else
    e310 fail "unreadable conf rc 2 / no inventory (rc=$p12_rc/$p12b_rc, err: $p12_err)"
fi

# 13. R-EGL-310-6 F3: a port outside 1-65535 that WRAPS in 64-bit Bash
#     arithmetic must fail the conf load, not inventory as valid; the
#     gateway-port twin uses the same predicate. Mutation: restore the
#     old `(( port < 1 || port > 65535 ))` checks — the wrap passes and
#     both legs list/accept the entry.
cat > "$S310/overflow.conf" <<'EOF'
profile overflow 10.199.136.0/24
    rule gateway-only
    gateway 10.199.136.2 3128 overflow-allowlist
    rule allow-host example.test:18446744073709551617
EOF
: > "$S310/overflow-allowlist"
cat > "$S310/gwoverflow.conf" <<'EOF'
profile gwoverflow 10.199.137.0/24
    gateway 10.199.137.2 18446744073709551617 gwoverflow-allowlist
EOF
: > "$S310/gwoverflow-allowlist"
E310OHOME="$(conf_home_ro "$S310/overflow.conf")"
E310WHOME="$(conf_home_ro "$S310/gwoverflow.conf")"
p13_out="$(env ARCMOCK_PASSWD_HOME="$E310OHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist overflow --direct 2>"$S310/p13.err")"; p13_rc=$?
p13b_out="$(env ARCMOCK_PASSWD_HOME="$E310OHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist-direct overflow 2>"$S310/p13b.err")"; p13b_rc=$?
p13c_out="$(env ARCMOCK_PASSWD_HOME="$E310WHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist gwoverflow --direct 2>"$S310/p13c.err")"; p13c_rc=$?
p13_err="$(cat "$S310/p13.err")"; p13b_err="$(cat "$S310/p13b.err")"; p13c_err="$(cat "$S310/p13c.err")"
if [[ "$p13_rc" == 2 && "$p13b_rc" == 2 && "$p13c_rc" == 2 \
      && -z "$p13_out" && -z "$p13b_out" && -z "$p13c_out" \
      && "$p13_err" == *"invalid port '18446744073709551617' (expected 1-65535)"* \
      && "$p13b_err" == *"invalid port '18446744073709551617' (expected 1-65535)"* \
      && "$p13c_err" == *"invalid gateway port '18446744073709551617' (expected 1-65535)"* ]]; then
    e310 pass
else
    e310 fail "overflow port rc 2 (rc=$p13_rc/$p13b_rc/$p13c_rc, err: $p13_err)"
fi

# 14. R-EGL-310-6 F3: the same overflow-safe predicate guards the CLI
#     entry points (direct entry + drop-unauthorized port). Both used the
#     wrapping arithmetic idiom before the shared helper.
p14_out="$(run310 allow main example.test:18446744073709551617 --direct 2>&1)"; p14_rc=$?
p14b_out="$(run310 drop-unauthorized main 18446744073709551617 2>&1)"; p14b_rc=$?
if [[ "$p14_rc" == 2 && "$p14b_rc" == 2 \
      && "$p14_out" == *"invalid port in direct entry 'example.test:18446744073709551617'"* \
      && "$p14b_out" == *"invalid port '18446744073709551617'"* ]]; then
    e310 pass
else
    e310 fail "CLI overflow port rc 2 (rc=$p14_rc/$p14b_rc, out: $p14_out / $p14b_out)"
fi

# 15. R-EGL-310-6 F3: the digit-length bound must not shrink the accepted
#     range — a 5-digit port at the 65535 ceiling still parses and lists.
cat > "$S310/maxport.conf" <<'EOF'
profile maxport 10.199.139.0/24
    rule gateway-only
    gateway 10.199.139.2 3128 maxport-allowlist
    rule allow-host example.test:65535
EOF
: > "$S310/maxport-allowlist"
E310MHOME="$(conf_home_ro "$S310/maxport.conf")"
p15_out="$(env ARCMOCK_PASSWD_HOME="$E310MHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist maxport --direct 2>/dev/null)"; p15_rc=$?
if [[ "$p15_rc" == 0 \
      && "$p15_out" == "profile 'maxport' — 1 direct entries from the profile conf (pinned to addresses at ensure; traffic is not proxied):"$'\n'"example.test:65535" ]]; then
    e310 pass
else
    e310 fail "65535 ceiling still accepted (rc=$p15_rc, out: $p15_out)"
fi

# 16. R-EGL-310-8 F2: the proxy-path `allow` argv path uses the same
#     overflow-safe predicate (`allow_entry_ok` -> `cfg_is_port`); a
#     64-bit wrap token and the first out-of-range value must both be the
#     named rc-2 usage error, with the allowlist file untouched and no
#     engine run. A section-local mock state proves the latter (the argv
#     gate exits before any podman call). Mutation: restore the old
#     `(( port < 1 || port > 65535 ))` arithmetic — the wrap token wraps
#     to 1, passes, and the entry lands in the allowlist.
S310ST2="$S310/state2"; rm -rf "$S310ST2"
mkdir -p "$S310ST2/nft" "$S310ST2/networks" "$S310ST2/running" \
         "$S310ST2/containers" "$S310ST2/images" "$S310ST2/ips" "$S310ST2/runargs"
: > "$S310ST2/images/localhost_egresslock-gateway_latest"
: > "$S310ST2/images/docker.io_library_alpine_latest"
p16_al="$E310HOME/.config/egresslock/main-allowlist"
p16_before="$(sha256sum "$p16_al")"
p16_out="$(env ARCMOCK_STATE="$S310ST2" ARCMOCK_PASSWD_HOME="$E310HOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow main example.test:18446744073709551617 2>&1)"; p16_rc=$?
p16b_out="$(env ARCMOCK_STATE="$S310ST2" ARCMOCK_PASSWD_HOME="$E310HOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow main example.test:65536 2>&1)"; p16b_rc=$?
p16_after="$(sha256sum "$p16_al")"
if [[ "$p16_rc" == 2 && "$p16b_rc" == 2 \
      && "$p16_out" == *"invalid port in entry 'example.test:18446744073709551617'"* \
      && "$p16b_out" == *"invalid port in entry 'example.test:65536'"* \
      && "$p16_before" == "$p16_after" \
      && ! -e "$S310ST2/runlog" ]]; then
    e310 pass
else
    e310 fail "proxy allow overflow rc 2 / no mutation (rc=$p16_rc/$p16b_rc, out: $p16_out / $p16b_out)"
fi

# 17. R-EGL-310-8 F2: a hand-edited allowlist file carrying the same
#     wrap token fails `ensure` closed with the named entry error (the
#     stored-file call site, distinct from the argv one above). A
#     dedicated gateway-only fixture keeps the parse the first failure.
#     Mutation: the old arithmetic accepts the line and ensure proceeds.
cat > "$S310/proxyoverflow.conf" <<'EOF'
profile proxyoverflow 10.199.142.0/24
    rule gateway-only
    gateway 10.199.142.2 3128 proxyoverflow-allowlist
EOF
printf 'example.test:18446744073709551617\n' > "$S310/proxyoverflow-allowlist"
E310POHOME="$(conf_home_ro "$S310/proxyoverflow.conf")"
p17_out="$(env ARCMOCK_STATE="$S310ST2" ARCMOCK_PASSWD_HOME="$E310POHOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure proxyoverflow 2>&1)"; p17_rc=$?
if [[ "$p17_rc" == 1 \
      && "$p17_out" == *"invalid port in allowlist entry 'example.test:18446744073709551617'"* \
      && "$p17_out" != *"started gateway"* ]]; then
    e310 pass
else
    e310 fail "hand-edited allowlist overflow fails ensure closed (rc=$p17_rc, out: $(printf '%s' "$p17_out" | tail -3 | tr '\n' '|'))"
fi

# 18. R-EGL-310-8 F4: an EXPORTED name that collides with the engine's
#     snapshot storage (`CFG_ENV`, which the first implementation
#     `declare -A`'d before reading) must still expand from the
#     invocation environment on both views, and `ensure` must parse the
#     same value into the pin record. Mutation: declare the internal
#     array before opening the environment dump — the exported value is
#     replaced, so this prints/takes the `:-default`.
cat > "$S310/envcollide.conf" <<'EOF'
profile envcollide 10.199.141.0/24
    rule gateway-only
    gateway 10.199.141.2 3128 envcollide-allowlist
    rule allow-host ${CFG_ENV:-fallback.example.test}:443
EOF
: > "$S310/envcollide-allowlist"
E310E2HOME="$(conf_home_ro "$S310/envcollide.conf")"
h310e="profile 'envcollide' — 1 direct entries from the profile conf (pinned to addresses at ensure; traffic is not proxied):"
exp310e_set="$(printf '%s\n%s' "$h310e" 'invocation.example.test:443')"
exp310e_unset="$(printf '%s\n%s' "$h310e" 'fallback.example.test:443')"
p18a_out="$(env CFG_ENV=invocation.example.test ARCMOCK_PASSWD_HOME="$E310E2HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist envcollide --direct 2>/dev/null)"; p18a_rc=$?
p18b_out="$(env CFG_ENV=invocation.example.test ARCMOCK_PASSWD_HOME="$E310E2HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist-direct envcollide 2>/dev/null)"; p18b_rc=$?
p18c_out="$(env -u CFG_ENV ARCMOCK_PASSWD_HOME="$E310E2HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist envcollide --direct 2>/dev/null)"; p18c_rc=$?
if [[ "$p18a_rc" == 0 && "$p18b_rc" == 0 && "$p18c_rc" == 0 \
      && "$p18a_out" == "$exp310e_set" && "$p18b_out" == "$exp310e_set" \
      && "$p18c_out" == "$exp310e_unset" ]]; then
    e310 pass
else
    e310 fail "exported CFG_ENV collision (set: $p18a_out | $p18b_out; unset: $p18c_out)"
fi

# 18b. The same exported collision at `ensure` time: the pin record is
#      the ensure-time witness of the parsed destination.
S310ST3="$S310/state3"; rm -rf "$S310ST3"
mkdir -p "$S310ST3/nft" "$S310ST3/networks" "$S310ST3/running" \
         "$S310ST3/containers" "$S310ST3/images" "$S310ST3/ips" "$S310ST3/runargs"
: > "$S310ST3/images/localhost_egresslock-gateway_latest"
: > "$S310ST3/images/docker.io_library_alpine_latest"
p18_dns="invocation.example.test=192.0.2.91,fallback.example.test=192.0.2.92"
env CFG_ENV=invocation.example.test ARCMOCK_STATE="$S310ST3" EGRESSLOCK_MOCK_DNS="$p18_dns" \
    ARCMOCK_PASSWD_HOME="$E310E2HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure envcollide >/dev/null 2>&1; p18d_rc=$?
p18_pins="$(cat "$E310E2HOME/.config/egresslock/envcollide.pins" 2>/dev/null || true)"
env -u CFG_ENV ARCMOCK_STATE="$S310ST3" EGRESSLOCK_MOCK_DNS="$p18_dns" \
    ARCMOCK_PASSWD_HOME="$E310E2HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure envcollide >/dev/null 2>&1; p18e_rc=$?
p18b_pins="$(cat "$E310E2HOME/.config/egresslock/envcollide.pins" 2>/dev/null || true)"
if [[ "$p18d_rc" == 0 && "$p18e_rc" == 0 \
      && "$p18_pins" == 'invocation.example.test|443 192.0.2.91' \
      && "$p18b_pins" == 'fallback.example.test|443 192.0.2.92' ]]; then
    e310 pass
else
    e310 fail "exported CFG_ENV collision at ensure (rc=$p18d_rc/$p18e_rc, pins: '$p18_pins' / '$p18b_pins')"
fi

# 18c. The reserved internal names themselves are also invocation
#      environment names: the dump is opened BEFORE the internal array
#      is declared, so an operator-exported `__EGL_CFG_ENV` (or the fd
#      variable) still expands from the environment. Mutation: declare
#      the internal array above the `exec {…}< <(env -0)` line — the
#      exported value is replaced by the empty array and both rows fall
#      to their `:-default`.
cat > "$S310/reserved.conf" <<'EOF'
profile reserved 10.199.143.0/24
    rule gateway-only
    gateway 10.199.143.2 3128 reserved-allowlist
    rule allow-host ${__EGL_CFG_ENV:-arrfallback.example.test}:443
    rule allow-host ${__egl_cfg_env_fd:-fdfallback.example.test}:443
EOF
: > "$S310/reserved-allowlist"
E310R2HOME="$(conf_home_ro "$S310/reserved.conf")"
h310r="profile 'reserved' — 2 direct entries from the profile conf (pinned to addresses at ensure; traffic is not proxied):"
exp310r_set="$(printf '%s\n%s\n%s' "$h310r" 'arrexport.example.test:443' 'fdexport.example.test:443')"
exp310r_unset="$(printf '%s\n%s\n%s' "$h310r" 'arrfallback.example.test:443' 'fdfallback.example.test:443')"
p18f_out="$(env __EGL_CFG_ENV=arrexport.example.test __egl_cfg_env_fd=fdexport.example.test \
    ARCMOCK_PASSWD_HOME="$E310R2HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist reserved --direct 2>/dev/null)"; p18f_rc=$?
p18g_out="$(env -u __EGL_CFG_ENV -u __egl_cfg_env_fd \
    ARCMOCK_PASSWD_HOME="$E310R2HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist reserved --direct 2>/dev/null)"; p18g_rc=$?
if [[ "$p18f_rc" == 0 && "$p18g_rc" == 0 \
      && "$p18f_out" == "$exp310r_set" && "$p18g_out" == "$exp310r_unset" ]]; then
    e310 pass
else
    e310 fail "reserved-prefix exported names (set: $p18f_out; unset: $p18g_out)"
fi

# 19. R-EGL-310-13 F1: a failed/partial snapshot producer is a named
#     fail-closed refusal, never a silent `:-default` substitution. A
#     PATH-local `cat` emits a partial NUL record and exits 1; with the
#     variable exported, both direct views must refuse before printing an
#     inventory. Mutation: accept a missing/nonzero status sentinel — the
#     partial dump is used and the `:-default` row is listed instead.
cat > "$S310/snapshot.conf" <<'EOF'
profile snapshot 10.199.144.0/24
    rule gateway-only
    gateway 10.199.144.2 3128 snapshot-allowlist
    rule allow-host ${EGL310_SNAP:-fallback.example.test}:443
EOF
: > "$S310/snapshot-allowlist"
E310SNAP="$(conf_home_ro "$S310/snapshot.conf")"
mkdir -p "$S310/bin-badcat"
cat > "$S310/bin-badcat/cat" <<'EOF'
#!/usr/bin/env bash
printf 'EGL310_SNAP=partial.example.test\0'
exit 1
EOF
chmod +x "$S310/bin-badcat/cat"
p19_out="$(env EGL310_SNAP=selected.example.test PATH="$S310/bin-badcat:$PATH" \
    ARCMOCK_PASSWD_HOME="$E310SNAP" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allowlist snapshot --direct 2>"$S310/p19.err")"; p19_rc=$?
p19b_out="$(env EGL310_SNAP=selected.example.test PATH="$S310/bin-badcat:$PATH" \
    ARCMOCK_PASSWD_HOME="$E310SNAP" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allowlist-direct snapshot 2>"$S310/p19b.err")"; p19b_rc=$?
p19_err="$(cat "$S310/p19.err")"; p19b_err="$(cat "$S310/p19b.err")"
if [[ "$p19_rc" == 2 && "$p19b_rc" == 2 && -z "$p19_out" && -z "$p19b_out" \
      && "$p19_err" == *"cannot read the environment egresslock was started with"* \
      && "$p19b_err" == *"cannot read the environment egresslock was started with"* \
      && "$p19_out" != *"fallback.example.test"* ]]; then
    e310 pass
else
    e310 fail "failed snapshot producer refused on both views (rc=$p19_rc/$p19b_rc, out: $p19_out, err: $p19_err)"
fi

# 19b. The same failed producer must stop `ensure` before any config parse,
#      pin write, or engine run — a partial snapshot cannot silently pick
#      a different destination for installed policy.
S310ST4="$S310/state4"; rm -rf "$S310ST4"
mkdir -p "$S310ST4/nft" "$S310ST4/networks" "$S310ST4/running" \
         "$S310ST4/containers" "$S310ST4/images" "$S310ST4/ips" "$S310ST4/runargs"
: > "$S310ST4/images/localhost_egresslock-gateway_latest"
: > "$S310ST4/images/docker.io_library_alpine_latest"
p19c_out="$(env EGL310_SNAP=selected.example.test PATH="$S310/bin-badcat:$PATH" \
    ARCMOCK_STATE="$S310ST4" EGRESSLOCK_MOCK_DNS="fallback.example.test=192.0.2.78" \
    ARCMOCK_PASSWD_HOME="$E310SNAP" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure snapshot 2>&1)"; p19c_rc=$?
if [[ "$p19c_rc" == 2 \
      && "$p19c_out" == *"cannot read the environment egresslock was started with"* \
      && ! -e "$E310SNAP/.config/egresslock/snapshot.pins" \
      && ! -e "$S310ST4/runlog" ]]; then
    e310 pass
else
    e310 fail "failed snapshot producer stops ensure closed (rc=$p19c_rc, out: $(printf '%s' "$p19c_out" | tail -3 | tr '\n' '|'))"
fi

# 20. R-EGL-310-13 F2: a Bash-created name uses the EXEC-TIME environment.
#     SHLVL absent -> `${SHLVL:-fallback}` takes the default on both views,
#     and bare `${SHLVL}` is the named unset-variable load failure (rc 2,
#     no inventory). Mutation: snapshot `env -0` instead of the exec-time
#     dump — Bash supplies SHLVL=1, so the default leg lists `1:443` and
#     the bare leg loads rc 0 instead of refusing.
cat > "$S310/shlvl.conf" <<'EOF'
profile shlvl 10.199.145.0/24
    rule gateway-only
    gateway 10.199.145.2 3128 shlvl-allowlist
    rule allow-host ${SHLVL:-fallback.example.test}:443
EOF
: > "$S310/shlvl-allowlist"
cat > "$S310/shlvlbare.conf" <<'EOF'
profile shlvlbare 10.199.146.0/24
    rule gateway-only
    gateway 10.199.146.2 3128 shlvlbare-allowlist
    rule allow-host ${SHLVL}:443
EOF
: > "$S310/shlvlbare-allowlist"
E310SLHOME="$(conf_home_ro "$S310/shlvl.conf")"
E310SBHOME="$(conf_home_ro "$S310/shlvlbare.conf")"
h310sl="profile 'shlvl' — 1 direct entries from the profile conf (pinned to addresses at ensure; traffic is not proxied):"
exp310sl="$(printf '%s\n%s' "$h310sl" 'fallback.example.test:443')"
p20a_out="$(env -u SHLVL ARCMOCK_PASSWD_HOME="$E310SLHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allowlist shlvl --direct 2>/dev/null)"; p20a_rc=$?
p20b_out="$(env -u SHLVL ARCMOCK_PASSWD_HOME="$E310SLHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allowlist-direct shlvl 2>/dev/null)"; p20b_rc=$?
p20c_out="$(env -u SHLVL ARCMOCK_PASSWD_HOME="$E310SBHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allowlist shlvlbare --direct 2>"$S310/p20c.err")"; p20c_rc=$?
p20d_out="$(env -u SHLVL ARCMOCK_PASSWD_HOME="$E310SBHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allowlist-direct shlvlbare 2>"$S310/p20d.err")"; p20d_rc=$?
p20c_err="$(cat "$S310/p20c.err")"; p20d_err="$(cat "$S310/p20d.err")"
if [[ "$p20a_rc" == 0 && "$p20b_rc" == 0 \
      && "$p20a_out" == "$exp310sl" && "$p20b_out" == "$exp310sl" \
      && "$p20c_rc" == 2 && "$p20d_rc" == 2 && -z "$p20c_out" && -z "$p20d_out" \
      && "$p20c_err" == *"environment variable in '\${SHLVL}' is unset and has no default"* \
      && "$p20d_err" == *"environment variable in '\${SHLVL}' is unset and has no default"* ]]; then
    e310 pass
else
    e310 fail "absent SHLVL: default on both views / bare fails closed (rc=$p20a_rc/$p20b_rc/$p20c_rc/$p20d_rc, out: $p20a_out | $p20c_out)"
fi

# 20b. An EXPORTED SHLVL takes its exact invocation value, not Bash's
#      increment/reset: nonnumeric `not-a-number` lists verbatim on both
#      views, and `7` lists 7 (not 8). Mutation: `env -0` — the values
#      become 1/8 (Bash's post-start state).
p20e_out="$(env SHLVL=not-a-number ARCMOCK_PASSWD_HOME="$E310SLHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allowlist shlvl --direct 2>/dev/null)"; p20e_rc=$?
p20f_out="$(env SHLVL=not-a-number ARCMOCK_PASSWD_HOME="$E310SLHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allowlist-direct shlvl 2>/dev/null)"; p20f_rc=$?
p20g_out="$(env SHLVL=7 ARCMOCK_PASSWD_HOME="$E310SLHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allowlist shlvl --direct 2>/dev/null)"; p20g_rc=$?
exp310sn="$(printf '%s\n%s' "$h310sl" 'not-a-number:443')"
exp310s7="$(printf '%s\n%s' "$h310sl" '7:443')"
if [[ "$p20e_rc" == 0 && "$p20f_rc" == 0 && "$p20g_rc" == 0 \
      && "$p20e_out" == "$exp310sn" && "$p20f_out" == "$exp310sn" \
      && "$p20g_out" == "$exp310s7" ]]; then
    e310 pass
else
    e310 fail "exported SHLVL takes the invocation value (not-a-number: $p20e_out | $p20f_out; 7: $p20g_out)"
fi

# 21. The same exec-time value reaches `ensure`: absent SHLVL pins the
#     `:-default` host and exported nonnumeric SHLVL pins its verbatim
#     value. Mutation: `env -0` pins `1|443` for both.
p21_dns="fallback.example.test=192.0.2.78,not-a-number=192.0.2.93"
env -u SHLVL ARCMOCK_STATE="$S310ST4" EGRESSLOCK_MOCK_DNS="$p21_dns" \
    ARCMOCK_PASSWD_HOME="$E310SLHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure shlvl >/dev/null 2>&1; p21a_rc=$?
p21a_pins="$(cat "$E310SLHOME/.config/egresslock/shlvl.pins" 2>/dev/null || true)"
env SHLVL=not-a-number ARCMOCK_STATE="$S310ST4" EGRESSLOCK_MOCK_DNS="$p21_dns" \
    ARCMOCK_PASSWD_HOME="$E310SLHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure shlvl >/dev/null 2>&1; p21b_rc=$?
p21b_pins="$(cat "$E310SLHOME/.config/egresslock/shlvl.pins" 2>/dev/null || true)"
if [[ "$p21a_rc" == 0 && "$p21b_rc" == 0 \
      && "$p21a_pins" == 'fallback.example.test|443 192.0.2.78' \
      && "$p21b_pins" == 'not-a-number|443 192.0.2.93' ]]; then
    e310 pass
else
    e310 fail "ensure parses the exec-time SHLVL (rc=$p21a_rc/$p21b_rc, pins: '$p21a_pins' / '$p21b_pins')"
fi

# 21b. Bare `${SHLVL}` with SHLVL absent fails the ensure load closed and
#      writes no pin record.
p21c_out="$(env -u SHLVL ARCMOCK_STATE="$S310ST4" EGRESSLOCK_MOCK_DNS="$p21_dns" \
    ARCMOCK_PASSWD_HOME="$E310SBHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure shlvlbare 2>&1)"; p21c_rc=$?
if [[ "$p21c_rc" == 2 \
      && "$p21c_out" == *"environment variable in '\${SHLVL}' is unset and has no default"* \
      && ! -e "$E310SBHOME/.config/egresslock/shlvlbare.pins" ]]; then
    e310 pass
else
    e310 fail "absent bare SHLVL stops ensure closed (rc=$p21c_rc, out: $(printf '%s' "$p21c_out" | tail -3 | tr '\n' '|'))"
fi

# 22. R-EGL-310-16 F1: a successful snapshot can still carry a bare
#     non-variable record (execve permits environment strings without
#     `=`). It is not an exported variable: `${NAME:-default}` takes the
#     default on both views, and a bare `${NAME}` fails the load closed.
#     R-EGL-310-19: an empty-name record (`=value`) is not a variable
#     either and must be ignored, not abort on an empty array subscript.
#     Mutation: treat a record without `=` as `NAME=NAME` — both views
#     list `EGL310_BARE:443` and the bare conf starts loading; dropping
#     the empty-name guard aborts the shell before dispatch.
cat > "$S310/malformedenv.conf" <<'EOF'
profile malformedenv 10.199.147.0/24
    rule gateway-only
    gateway 10.199.147.2 3128 malformedenv-allowlist
    rule allow-host ${EGL310_BARE:-fallback.example.test}:443
EOF
: > "$S310/malformedenv-allowlist"
cat > "$S310/malformedbare.conf" <<'EOF'
profile malformedbare 10.199.148.0/24
    rule gateway-only
    gateway 10.199.148.2 3128 malformedbare-allowlist
    rule allow-host ${EGL310_BARE}:443
EOF
: > "$S310/malformedbare-allowlist"
E310MEHOME="$(conf_home_ro "$S310/malformedenv.conf")"
E310MBHOME="$(conf_home_ro "$S310/malformedbare.conf")"
mkdir -p "$S310/bin-bareenv"
e310_real_cat="$(command -v cat)"
cat > "$S310/bin-bareenv/cat" <<EOF
#!/usr/bin/env bash
# Only the invocation-environment dump gets the malformed records; every
# other cat (chain/config reads) must stay byte-transparent.
if [[ "\$1" == /proc/*/environ ]]; then printf 'EGL310_BARE\0=value\0'; fi
exec "$e310_real_cat" "\$@"
EOF
chmod +x "$S310/bin-bareenv/cat"
h310me="profile 'malformedenv' — 1 direct entries from the profile conf (pinned to addresses at ensure; traffic is not proxied):"
exp310me="$(printf '%s\n%s' "$h310me" 'fallback.example.test:443')"
p22a_out="$(env -u EGL310_BARE PATH="$S310/bin-bareenv:$PATH" ARCMOCK_PASSWD_HOME="$E310MEHOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist malformedenv --direct 2>/dev/null)"; p22a_rc=$?
p22b_out="$(env -u EGL310_BARE PATH="$S310/bin-bareenv:$PATH" ARCMOCK_PASSWD_HOME="$E310MEHOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist-direct malformedenv 2>/dev/null)"; p22b_rc=$?
p22c_out="$(env -u EGL310_BARE PATH="$S310/bin-bareenv:$PATH" ARCMOCK_PASSWD_HOME="$E310MBHOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist malformedbare --direct 2>"$S310/p22c.err")"; p22c_rc=$?
p22d_out="$(env -u EGL310_BARE PATH="$S310/bin-bareenv:$PATH" ARCMOCK_PASSWD_HOME="$E310MBHOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allowlist-direct malformedbare 2>"$S310/p22d.err")"; p22d_rc=$?
p22c_err="$(cat "$S310/p22c.err")"; p22d_err="$(cat "$S310/p22d.err")"
if [[ "$p22a_rc" == 0 && "$p22b_rc" == 0 \
      && "$p22a_out" == "$exp310me" && "$p22b_out" == "$exp310me" \
      && "$p22c_rc" == 2 && "$p22d_rc" == 2 && -z "$p22c_out" && -z "$p22d_out" \
      && "$p22c_err" == *"environment variable in '\${EGL310_BARE}' is unset and has no default"* \
      && "$p22d_err" == *"environment variable in '\${EGL310_BARE}' is unset and has no default"* ]]; then
    e310 pass
else
    e310 fail "malformed exec-env record is not a variable (set: $p22a_out | $p22b_out; bare rc=$p22c_rc/$p22d_rc, err: $p22c_err)"
fi

# 23. The same malformed record at `ensure`: the pin record proves the
#     parsed destination is the `:-default`, never the literal record
#     name. Mutation: the missing `=` guard pins `EGL310_BARE` instead.
S310ST5="$S310/state5"; rm -rf "$S310ST5"
mkdir -p "$S310ST5/nft" "$S310ST5/networks" "$S310ST5/running" \
         "$S310ST5/containers" "$S310ST5/images" "$S310ST5/ips" "$S310ST5/runargs"
: > "$S310ST5/images/localhost_egresslock-gateway_latest"
: > "$S310ST5/images/docker.io_library_alpine_latest"
p23_dns="fallback.example.test=192.0.2.101,EGL310_BARE=192.0.2.102"
p23_out="$(env -u EGL310_BARE PATH="$S310/bin-bareenv:$PATH" ARCMOCK_STATE="$S310ST5" \
    EGRESSLOCK_MOCK_DNS="$p23_dns" ARCMOCK_PASSWD_HOME="$E310MEHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure malformedenv 2>&1)"; p23_rc=$?
p23_pins="$(cat "$E310MEHOME/.config/egresslock/malformedenv.pins" 2>/dev/null || true)"
if [[ "$p23_rc" == 0 \
      && "$p23_pins" == 'fallback.example.test|443 192.0.2.101' ]]; then
    e310 pass
else
    e310 fail "malformed exec-env record does not reach ensure (rc=$p23_rc, pins: '$p23_pins', out: $(printf '%s' "$p23_out" | tail -2 | tr '\n' '|'))"
fi

# 24. R-EGL-310-16 F2: a conf `allow-host` port keeps the accepted
#     `:0443` spelling but is parsed/normalized to decimal 443 before the
#     compiler, pin record, and view — nft would read a raw `0443` as
#     octal 291. Mutation: drop the cfg_rule normalization — the chain
#     and pin carry `0443` and the view lists `:0443`.
cat > "$S310/direct443.conf" <<'EOF'
profile direct443 10.199.149.0/24
    rule gateway-only
    gateway 10.199.149.2 3128 direct443-allowlist
    rule allow-host entry.example.test:0443
EOF
: > "$S310/direct443-allowlist"
E310D4HOME="$(conf_home_ro "$S310/direct443.conf")"
p24_out="$(env ARCMOCK_STATE="$S310ST5" EGRESSLOCK_MOCK_DNS="entry.example.test=192.0.2.79" \
    ARCMOCK_PASSWD_HOME="$E310D4HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure direct443 2>&1)"; p24_rc=$?
p24_pins="$(cat "$E310D4HOME/.config/egresslock/direct443.pins" 2>/dev/null || true)"
p24_chain="$(cat "$S310ST5/nft/egresslock.p_direct443" 2>/dev/null || true)"
p24_view="$(env ARCMOCK_PASSWD_HOME="$E310D4HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allowlist direct443 --direct 2>/dev/null)"; p24v_rc=$?
p24_verify="$(env ARCMOCK_STATE="$S310ST5" EGRESSLOCK_MOCK_DNS="entry.example.test=192.0.2.79" \
    ARCMOCK_PASSWD_HOME="$E310D4HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock verify direct443 2>&1)"; p24x_rc=$?
if [[ "$p24_rc" == 0 && "$p24v_rc" == 0 && "$p24x_rc" == 0 \
      && "$p24_pins" == 'entry.example.test|443 192.0.2.79' \
      && "$p24_chain" == *'ip daddr 192.0.2.79 tcp dport 443 counter accept'* \
      && "$p24_chain" != *'dport 0443'* && "$p24_chain" != *'dport 291'* \
      && "$p24_view" == *'entry.example.test:443'* \
      && "$p24_view" != *'entry.example.test:0443'* \
      && "$p24_verify" != *'mismatch'* && "$p24_verify" != *'drift'* ]]; then
    e310 pass
else
    e310 fail "conf :0443 normalizes before nft/pin/view/verify (rc=$p24_rc/$p24v_rc/$p24x_rc, pins: '$p24_pins', view: $p24_view, verify: $p24_verify)"
fi

# 24b. The CLI direct `allow` path uses the same normalization and the
#      conf matcher treats a leading-zero spelling as the same rule:
#      adding `:0443` stores/pins/emits `:443`, and the view lists it.
cat > "$S310/cli443.conf" <<'EOF'
profile cli443 10.199.153.0/24
    rule gateway-only
    gateway 10.199.153.2 3128 cli443-allowlist
EOF
: > "$S310/cli443-allowlist"
E310C4HOME="$(conf_home_ro "$S310/cli443.conf")"
p24b_out="$(env ARCMOCK_STATE="$S310ST5" ARCMOCK_PASSWD_HOME="$E310C4HOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock allow cli443 192.0.2.77:0443 --direct 2>&1)"; p24b_rc=$?
p24b_conf="$(cat "$E310C4HOME/.config/egresslock/cli443.conf" 2>/dev/null || true)"
p24b_pins="$(cat "$E310C4HOME/.config/egresslock/cli443.pins" 2>/dev/null || true)"
p24b_chain="$(cat "$S310ST5/nft/egresslock.p_cli443" 2>/dev/null || true)"
p24b_view="$(env ARCMOCK_PASSWD_HOME="$E310C4HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allowlist-direct cli443 2>/dev/null)"; p24bv_rc=$?
if [[ "$p24b_rc" == 0 && "$p24bv_rc" == 0 \
      && "$p24b_out" == *'added: rule allow-host 192.0.2.77:443 -> '* \
      && "$p24b_conf" == *'rule allow-host 192.0.2.77:443'* \
      && "$p24b_conf" != *':0443'* \
      && "$p24b_pins" == '192.0.2.77|443 192.0.2.77' \
      && "$p24b_chain" == *'ip daddr 192.0.2.77 tcp dport 443 counter accept'* \
      && "$p24b_view" == *'192.0.2.77:443'* ]]; then
    e310 pass
else
    e310 fail "CLI :0443 normalizes into conf/pin/chain/view (rc=$p24b_rc/$p24bv_rc, pins: '$p24b_pins', out: $(printf '%s' "$p24b_out" | tail -2 | tr '\n' '|'))"
fi

# 25. R-EGL-310-16 F2: the gateway-hop port goes through the same
#     normalization — a conf `gateway <ip> 0443` emits `tcp dport 443`,
#     never the raw token nft would read as octal. Mutation: drop the
#     cfg_gateway normalization.
cat > "$S310/gw443.conf" <<'EOF'
profile gw443 10.199.150.0/24
    rule gateway-only
    gateway 10.199.150.2 0443 gw443-allowlist
EOF
: > "$S310/gw443-allowlist"
E310GW4HOME="$(conf_home_ro "$S310/gw443.conf")"
p25_out="$(env ARCMOCK_STATE="$S310ST5" ARCMOCK_PASSWD_HOME="$E310GW4HOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock ensure gw443 2>&1)"; p25_rc=$?
p25_chain="$(cat "$S310ST5/nft/egresslock.p_gw443" 2>/dev/null || true)"
if [[ "$p25_rc" == 0 \
      && "$p25_chain" == *'ip daddr 10.199.150.2 tcp dport 443 counter accept'* \
      && "$p25_chain" != *'tcp dport 0443'* && "$p25_chain" != *'tcp dport 291'* ]]; then
    e310 pass
else
    e310 fail "gateway :0443 normalizes before nft (rc=$p25_rc, out: $(printf '%s' "$p25_out" | tail -2 | tr '\n' '|'))"
fi

# 26. R-EGL-310-16 F3: `drop-unauthorized ... 0443` must reconcile the
#     canonical port 443 in both directions — a leading-zero spelling
#     used to skip every canonical conntrack row and print a false clean
#     witness. Mutation: drop the port normalization — no -D is issued
#     and the leftover rows survive.
cat > "$S310/dropport.conf" <<'EOF'
profile dropport 10.199.151.0/24
    rule gateway-only
    gateway 10.199.151.2 3128 dropport-allowlist
    rule allow-host 192.0.2.88:443
EOF
: > "$S310/dropport-allowlist"
E310DPHOME="$(conf_home_ro "$S310/dropport.conf")"
env ARCMOCK_STATE="$S310ST5" ARCMOCK_PASSWD_HOME="$E310DPHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure dropport >/dev/null 2>&1
p26_table="$S310ST5/nft/conntrack-table"
printf '%s\n%s\n' \
    'ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.151.5 dst=192.0.2.99 sport=50001 dport=443 src=192.0.2.99 dst=10.0.2.15 sport=443 dport=50001 [ASSURED] mark=0 zone=0 use=2' \
    'ipv4 2 tcp 6 431998 ESTABLISHED src=192.0.2.98 dst=10.199.151.7 sport=443 dport=50002 src=10.199.151.7 dst=192.0.2.98 sport=50002 dport=443 [ASSURED] mark=0 zone=0 use=2' \
    > "$p26_table"
: > "$S310ST5/conntrack.log"
p26_out="$(env ARCMOCK_STATE="$S310ST5" ARCMOCK_PASSWD_HOME="$E310DPHOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock drop-unauthorized dropport 0443 2>&1)"; p26_rc=$?
if [[ "$p26_rc" == 0 \
      && "$p26_out" == *"drop-unauthorized: no leftover connection on port 443 remains"* \
      && "$(grep -cxF 'conntrack -D -p tcp -s 10.199.151.5 --sport 50001 -d 192.0.2.99 --dport 443' "$S310ST5/conntrack.log")" == 1 \
      && "$(grep -cxF 'conntrack -D -p tcp -s 192.0.2.98 --sport 443 -d 10.199.151.7 --dport 50002' "$S310ST5/conntrack.log")" == 1 ]] \
   && ! grep -q . "$p26_table"; then
    e310 pass
else
    e310 fail "drop-unauthorized :0443 flushes canonical 443 both directions (rc=$p26_rc, table: $(tr '\n' '|' < "$p26_table"), log: $(tr '\n' '|' < "$S310ST5/conntrack.log"))"
fi

# 27. R-EGL-310-16 F3: a leading-zero revoke names the same decimal rule
#     (conf line kept in its original spelling) and the accepted-set walk
#     then keeps a flow the sibling grant still authorizes — no -D, rc 0,
#     one removed:. Mutation: drop the CLI normalization or the conf
#     matcher's `0*` — the rule is reported absent / the shared flow is
#     flushed.
cat > "$S310/shared443.conf" <<'EOF'
profile shared443 10.199.152.0/24
    rule gateway-only
    gateway 10.199.152.2 3128 shared443-allowlist
    rule allow-host aa.example.test:0443
    rule allow-host bb.example.test:443
EOF
: > "$S310/shared443-allowlist"
E310SHHOME="$(conf_home_ro "$S310/shared443.conf")"
env ARCMOCK_STATE="$S310ST5" ARCMOCK_PASSWD_HOME="$E310SHHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_MOCK_DNS="aa.example.test=192.0.2.70,bb.example.test=192.0.2.70" \
    egresslock ensure shared443 >/dev/null 2>&1
p27_row='ipv4 2 tcp 6 431998 ESTABLISHED src=10.199.152.5 dst=192.0.2.70 sport=58666 dport=443 src=192.0.2.70 dst=10.0.2.15 sport=443 dport=58666 [ASSURED] mark=0 zone=0 use=2'
printf '%s\n' "$p27_row" > "$p26_table"
: > "$S310ST5/conntrack.log"
p27_out="$(env ARCMOCK_STATE="$S310ST5" ARCMOCK_PASSWD_HOME="$E310SHHOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS="aa.example.test=192.0.2.70,bb.example.test=192.0.2.70" \
    egresslock disallow --direct shared443 aa.example.test:0443 2>&1)"; p27_rc=$?
p27_conf="$(cat "$E310SHHOME/.config/egresslock/shared443.conf" 2>/dev/null || true)"
if [[ "$p27_rc" == 0 && "$(grep -c '^removed:' <<<"$p27_out")" == 1 ]] \
      && ! grep -q 'conntrack -D' "$S310ST5/conntrack.log" \
      && grep -qF 'dst=192.0.2.70 ' "$p26_table" \
      && ! grep -qF 'rule allow-host aa.example.test:0443' <<<"$p27_conf" \
      && grep -qF 'rule allow-host bb.example.test:443' <<<"$p27_conf" \
      && grep -q 'ip daddr 192.0.2.70 tcp dport 443 counter accept' "$S310ST5/nft/egresslock.p_shared443"; then
    e310 pass
else
    e310 fail "leading-zero revoke matches the canonical shared grant, no over-flush (rc=$p27_rc, table: $(tr '\n' '|' < "$p26_table"), out: $(printf '%s' "$p27_out" | tail -2 | tr '\n' '|'))"
fi

# 28. R-EGL-310-19 F1: xtrace must not disclose inherited environment
#     values while the snapshot is captured/parsed, and the verified
#     producer must still complete under tracing. A synthetic token is
#     exported but referenced by no config; it must appear in neither
#     stream. The trace marker proves tracing really was active.
#     Mutation: remove the `set +x` window — the token is printed by the
#     record test and the array assignment.
p28_secret='SYNTHETIC_egl310_trace_only'
p28_out="$(env API_TOKEN="$p28_secret" SHELLOPTS=xtrace ARCMOCK_PASSWD_HOME="$E310HOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock --version 2>"$S310/p28.err")"; p28_rc=$?
p28b_out="$(env API_TOKEN="$p28_secret" SHELLOPTS=xtrace BASH_XTRACEFD=1 \
    ARCMOCK_PASSWD_HOME="$E310HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock --version 2>"$S310/p28b.err")"; p28b_rc=$?
p28c_out="$(env -u EGL310_HOST API_TOKEN="$p28_secret" SHELLOPTS=xtrace \
    ARCMOCK_PASSWD_HOME="$E310HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allowlist main --direct 2>"$S310/p28c.err")"; p28c_rc=$?
p28_err="$(cat "$S310/p28.err")"
p28b_err="$(cat "$S310/p28b.err")"
p28c_err="$(cat "$S310/p28c.err")"
if [[ "$p28_rc" == 0 && "$p28b_rc" == 0 && "$p28c_rc" == 0 \
      && "$p28_err" == *"+ "* && "$p28b_out" == *"+ "* \
      && "$p28_out" != *"$p28_secret"* && "$p28_err" != *"$p28_secret"* \
      && "$p28b_out" != *"$p28_secret"* && "$p28b_err" != *"$p28_secret"* \
      && "$p28c_out" == "$e310_expected" && "$p28c_err" == *"+ "* \
      && "$p28c_err" != *"$p28_secret"* \
      && "$p28_err" == *"+ exit 0"* ]]; then
    e310 pass
else
    e310 fail "xtrace does not disclose the invocation environment (rc=$p28_rc/$p28b_rc/$p28c_rc, out: $p28_out | $p28b_out, stderr token: $([[ "$p28_err" == *"$p28_secret"* ]] && echo yes || echo no)/$([[ "$p28c_err" == *"$p28_secret"* ]] && echo yes || echo no))"
fi

# 29. R-EGL-310-19 F2: a pre-swap reinstall failure restores the COMPLETE
#     conf preimage, including the equivalent leading-zero spelling the
#     canonical matcher deleted alongside the named rule. The disclosure's
#     "rule restored" claim must be true, and the advertised retry must
#     work once DNS recovers. Mutation: capture only the first deleted
#     line (the old rollback) — the `:02222` line is lost and the conf
#     hash differs.
cat > "$S310/rollback.conf" <<'EOF'
profile rollback 10.199.155.0/24
    rule gateway-only
    gateway 10.199.155.2 3128 rollback-allowlist
    rule allow-host git.example.test:2222
    rule allow-host git.example.test:02222
    rule allow-host cache.example.test:8080
EOF
: > "$S310/rollback-allowlist"
E310RBHOME="$(conf_home_ro "$S310/rollback.conf")"
S310ST6="$S310/state6"; rm -rf "$S310ST6"
mkdir -p "$S310ST6/nft" "$S310ST6/networks" "$S310ST6/running" \
         "$S310ST6/containers" "$S310ST6/images" "$S310ST6/ips" "$S310ST6/runargs"
: > "$S310ST6/images/localhost_egresslock-gateway_latest"
: > "$S310ST6/images/docker.io_library_alpine_latest"
p29_dns_ok="git.example.test=192.0.2.60,cache.example.test=192.0.2.61"
p29_conf="$E310RBHOME/.config/egresslock/rollback.conf"
env ARCMOCK_STATE="$S310ST6" EGRESSLOCK_MOCK_DNS="$p29_dns_ok" \
    ARCMOCK_PASSWD_HOME="$E310RBHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure rollback >/dev/null 2>&1; p29_ensure_rc=$?
p29_before="$(sha256sum "$p29_conf")"
p29_chain_before="$(sha256sum "$S310ST6/nft/egresslock.p_rollback")"
p29_out="$(env ARCMOCK_STATE="$S310ST6" \
    EGRESSLOCK_MOCK_DNS="git.example.test=192.0.2.60,cache.example.test=" \
    ARCMOCK_PASSWD_HOME="$E310RBHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow --direct rollback git.example.test:2222 2>&1)"; p29_rc=$?
p29_after="$(sha256sum "$p29_conf")"
p29_chain_after="$(sha256sum "$S310ST6/nft/egresslock.p_rollback")"
p29_conf_text="$(cat "$p29_conf")"
p29_retry_out="$(env ARCMOCK_STATE="$S310ST6" EGRESSLOCK_MOCK_DNS="$p29_dns_ok" \
    ARCMOCK_PASSWD_HOME="$E310RBHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow --direct rollback git.example.test:2222 2>&1)"; p29r_rc=$?
p29_verify_out="$(env ARCMOCK_STATE="$S310ST6" EGRESSLOCK_MOCK_DNS="$p29_dns_ok" \
    ARCMOCK_PASSWD_HOME="$E310RBHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock verify rollback 2>&1)"; p29v_rc=$?
p29_conf_retry="$(cat "$p29_conf")"
p29_view="$(env ARCMOCK_PASSWD_HOME="$E310RBHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock allowlist-direct rollback 2>/dev/null)"; p29view_rc=$?
if [[ "$p29_ensure_rc" == 0 && "$p29_rc" == 1 \
      && "$p29_out" == *"nothing was revoked"* && "$p29_out" == *"rule restored"* \
      && "$p29_out" != *"could not be put back"* \
      && "$p29_before" == "$p29_after" && "$p29_chain_before" == "$p29_chain_after" \
      && "$p29_conf_text" == *"rule allow-host git.example.test:02222"* \
      && "$p29r_rc" == 0 && "$(grep -c '^removed:' <<<"$p29_retry_out")" == 1 \
      && "$p29_conf_retry" != *"git.example.test:2222"* \
      && "$p29_conf_retry" != *"git.example.test:02222"* \
      && "$p29_conf_retry" == *"cache.example.test:8080"* \
      && "$p29v_rc" == 0 && "$p29view_rc" == 0 \
      && "$p29_view" != *"git.example.test"* ]]; then
    e310 pass
else
    e310 fail "pre-swap revoke restores the complete preimage and retries (rc=$p29_rc/$p29r_rc/$p29v_rc, hash equal: $([[ "$p29_before" == "$p29_after" ]] && echo yes || echo no), out: $(printf '%s' "$p29_out" | tail -2 | tr '\n' '|'))"
fi

# 30. R-EGL-310-21 F1: the pre-delete conf capture is a VERIFIED read. A
#     partial read that exits 1 (injected `cat` wrapper) must refuse
#     named BEFORE the delete — never accept the truncated preimage and
#     later restore it while claiming "rule restored". Conf and chain
#     bytes stay identical, no recovery claim is printed, and the
#     advertised retry succeeds once the read is healthy. Mutation:
#     capture with the old unverified `cat "$conf"; printf x` — the
#     truncated preimage is accepted, the pre-swap DNS failure restores
#     it (losing the unrelated cache line) and prints "rule restored".
cat > "$S310/confcapture.conf" <<'EOF'
profile confcapture 10.199.156.0/24
    rule gateway-only
    gateway 10.199.156.2 3128 confcapture-allowlist
    rule allow-host git.example.test:2222
    rule allow-host cache.example.test:8080
EOF
: > "$S310/confcapture-allowlist"
E310CCHOME="$(conf_home_ro "$S310/confcapture.conf")"
S310ST7="$S310/state7"; rm -rf "$S310ST7"
mkdir -p "$S310ST7/nft" "$S310ST7/networks" "$S310ST7/running" \
         "$S310ST7/containers" "$S310ST7/images" "$S310ST7/ips" "$S310ST7/runargs"
: > "$S310ST7/images/localhost_egresslock-gateway_latest"
: > "$S310ST7/images/docker.io_library_alpine_latest"
p30_dns_ok="git.example.test=192.0.2.62,cache.example.test=192.0.2.63"
p30_conf="$E310CCHOME/.config/egresslock/confcapture.conf"
env ARCMOCK_STATE="$S310ST7" EGRESSLOCK_MOCK_DNS="$p30_dns_ok" \
    ARCMOCK_PASSWD_HOME="$E310CCHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure confcapture >/dev/null 2>&1; p30_ensure_rc=$?
p30_before="$(sha256sum "$p30_conf")"
p30_chain_before="$(sha256sum "$S310ST7/nft/egresslock.p_confcapture")"
mkdir -p "$S310/bin-badpreimage"
cat > "$S310/bin-badpreimage/cat" <<EOF
#!/usr/bin/env bash
# Only the pre-delete conf capture is truncated+failed; every other cat
# (the startup environment dump, chain/config reads) stays transparent.
for a in "\$@"; do
    if [[ "\$a" == "$p30_conf" ]]; then
        head -n 2 "$p30_conf"
        exit 1
    fi
done
exec "$e310_real_cat" "\$@"
EOF
chmod +x "$S310/bin-badpreimage/cat"
p30_out="$(env ARCMOCK_STATE="$S310ST7" \
    EGRESSLOCK_MOCK_DNS="git.example.test=192.0.2.62,cache.example.test=" \
    PATH="$S310/bin-badpreimage:$PATH" ARCMOCK_PASSWD_HOME="$E310CCHOME" \
    EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow --direct confcapture git.example.test:2222 2>&1)"; p30_rc=$?
p30_after="$(sha256sum "$p30_conf")"
p30_chain_after="$(sha256sum "$S310ST7/nft/egresslock.p_confcapture")"
p30_retry_out="$(env ARCMOCK_STATE="$S310ST7" EGRESSLOCK_MOCK_DNS="$p30_dns_ok" \
    ARCMOCK_PASSWD_HOME="$E310CCHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock disallow --direct confcapture git.example.test:2222 2>&1)"; p30r_rc=$?
p30_conf_retry="$(cat "$p30_conf")"
p30_verify_out="$(env ARCMOCK_STATE="$S310ST7" EGRESSLOCK_MOCK_DNS="$p30_dns_ok" \
    ARCMOCK_PASSWD_HOME="$E310CCHOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock verify confcapture 2>&1)"; p30v_rc=$?
if [[ "$p30_ensure_rc" == 0 && "$p30_rc" == 1 \
      && "$p30_out" == *"cannot read config"* \
      && "$p30_out" == *"completely for the direct-rule removal"* \
      && "$p30_out" == *"nothing was changed"* \
      && "$p30_out" != *"rule restored"* && "$p30_out" != *"could not be put back"* \
      && "$p30_out" != *"removed:"* \
      && "$p30_before" == "$p30_after" && "$p30_chain_before" == "$p30_chain_after" \
      && "$p30r_rc" == 0 && "$(grep -c '^removed:' <<<"$p30_retry_out")" == 1 \
      && "$p30_conf_retry" != *"git.example.test:2222"* \
      && "$p30_conf_retry" == *"cache.example.test:8080"* \
      && "$p30v_rc" == 0 ]]; then
    e310 pass
else
    e310 fail "unverified preimage capture refused before the delete (rc=$p30_ensure_rc/$p30_rc/$p30r_rc/$p30v_rc, hash equal: $([[ "$p30_before" == "$p30_after" ]] && echo yes || echo no), out: $(printf '%s' "$p30_out" | tail -2 | tr '\n' '|'))"
fi

section_end egl310

# --- EGL-369: gateway config-dir + ACL vocabulary rename (D1/D3/D7) -------
# The current image carries /etc/squid/egresslock (real dir) + an
# /etc/squid/agent symlink; an un-replaced old image carries the old dir
# only. One probe picks the layout and the same dir is used for
# generation, the converged compare, and staging. The mock models both
# layouts and a missing destination parent (D7).
section_begin egl369 "EGL-369 gateway vocabulary rename"
e369() { assert "$@"; }

S369="$TESTROOT/h369"; rm -rf "$S369"; mkdir -p "$S369"
cat > "$S369/g369.conf" <<'EOF'
profile g369 10.199.140.0/24
    rule gateway-only
    gateway 10.199.140.2 3128 g369-allowlist
EOF
printf 'no-port.example.test\nport.example.test:8443\n' > "$S369/g369-allowlist"
E369HOME="$(conf_home_ro "$S369/g369.conf")"
run369() { env ARCMOCK_PASSWD_HOME="$E369HOME" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
G369=egresslock-gateway-g369

# 1. Current (new) image layout: the probe answers the new dir, so the
#    generated config carries the new path + unprefixed ACL labels.
#    Mutation: remove the probe (fall back to the old dir) -> the exact
#    lines below red.
o="$(run369 ensure g369 2>&1)"; rc=$?
sq="$(mock_cfg_file "$G369" squid.conf)"
if [[ "$rc" == 0 && -f "$sq" ]] \
   && grep -qx 'acl profile_subnet src 10.199.140.0/24' "$sq" \
   && grep -qE '^acl allowlist dstdomain -n "/etc/squid/egresslock/allowlist\.domains\.[0-9a-f]{64}"$' "$sq" \
   && grep -qx 'acl port_443 port 443' "$sq" \
   && grep -qx 'http_access allow profile_subnet allowlist port_443' "$sq" \
   && grep -qE '^acl allowlist_p8443 dstdomain -n "/etc/squid/egresslock/allowlist\.p8443\.[0-9a-f]{64}"$' "$sq" \
   && grep -qx 'acl port_p8443 port 8443' "$sq" \
   && grep -qx 'http_access allow profile_subnet allowlist_p8443 port_p8443' "$sq"; then
    e369 pass
else
    e369 fail "new-layout generated config (rc=$rc, out: $o)"
fi

# 2. Converged re-ensure with the same layout: no restart.
: > "$STATE/opslog"
o="$(run369 ensure g369 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"already converged, not restarted"* ]] \
   && ! grep -qE '^podman restart .*'"$G369" "$STATE/opslog"; then
    e369 pass
else
    e369 fail "new-layout converged re-ensure (rc=$rc, out: $o)"
fi

# 3. Un-replaced (old) image layout: the probe answers the old dir and the
#    same old dir is generated/staged. Mutation: remove the probe (always
#    new) -> the mock cp has no new parent on this container and ensure
#    fails closed, so this leg is non-vacuous.
touch "$STATE/gw-layout-agent-$G369"
o="$(run369 ensure --replace-gateway g369 2>&1)"; rc=$?
sq="$(mock_cfg_file "$G369" squid.conf)"
if [[ "$rc" == 0 && -f "$sq" ]] \
   && grep -qx 'acl profile_subnet src 10.199.140.0/24' "$sq" \
   && grep -qE '^acl allowlist dstdomain -n "/etc/squid/agent/allowlist\.domains\.[0-9a-f]{64}"$' "$sq" \
   && grep -qE '^acl allowlist_p8443 dstdomain -n "/etc/squid/agent/allowlist\.p8443\.[0-9a-f]{64}"$' "$sq"; then
    e369 pass
else
    e369 fail "old-layout generated config (rc=$rc, out: $o)"
fi

# 4. Fail-closed layout mismatch (D3/D7): force the probe to answer the
#    new dir on the old-layout container. The first cp must fail (missing
#    destination parent) and the die must name the detected layout —
#    never a silent wrong-layout write.
touch "$STATE/gw-probe-egresslock-$G369"
o="$(run369 ensure --replace-gateway g369 2>&1)"; rc=$?
if [[ "$rc" != 0 ]] \
   && [[ "$o" == *"detected layout '/etc/squid/egresslock'"* ]] \
   && [[ "$o" == *"gateway allowlist staging failed (podman exec mktemp; fail closed;"* \
      || "$o" == *"gateway allowlist staging failed (podman cp; fail closed;"* ]]; then
    e369 pass
else
    e369 fail "layout-mismatch staging fails closed + names layout (rc=$rc, out: $o)"
fi
rm -f "$STATE/gw-layout-agent-$G369" "$STATE/gw-probe-egresslock-$G369"

# 5. R-EGL-369-10 F1: a probe RUNTIME error (rc 125) is not an absent new
#    dir. Ensure must fail closed before any generation/publication and
#    name the probe failure — never default to the old layout (which,
#    through the new image's symlink, would write old-path references).
#    Mutation: treat every rc as "old" -> ensure succeeds and leaves a
#    deployed squid.conf, so this leg reds.
touch "$STATE/gw-probe-fails-$G369"
o="$(run369 ensure --replace-gateway g369 2>&1)"; rc=$?
sq="$(mock_cfg_file "$G369" squid.conf)"
if [[ "$rc" != 0 ]] \
   && [[ "$o" == *"gateway config-directory probe failed (runtime exec test -d returned rc 125; fail closed)"* ]] \
   && [[ "$o" != *"detected layout"* ]] \
   && [[ ! -f "$sq" ]]; then
    e369 pass
else
    e369 fail "probe runtime error fails closed before mutation (rc=$rc, out: $o)"
fi
rm -f "$STATE/gw-probe-fails-$G369"

# 6. R-EGL-369-10 F1: the layout detected by the apply is bound through
#    verify/cleanup. The one-shot knob makes the apply probe answer the
#    old dir, then answer the new dir on any later probe (the pre-rework
#    finalize re-probe). Cleanup must keep the just-written referenced
#    groups even with grace 0: scanning only the re-probed spelling would
#    delete them. The probe count pins the binding itself — a re-probe
#    that answers the new dir is otherwise masked by cleanup's
#    unexpected-reference keep-all (R-EGL-369-13 F3).
#    Mutation: restore the finalize re-probe -> second probe + red.
run369 teardown g369 >/dev/null 2>&1 || true
touch "$STATE/gw-probe-old-once-$G369"
: > "$STATE/execlog"
o="$(EGRESSLOCK_GW_CLEANUP_GRACE=0 run369 ensure g369 2>&1)"; rc=$?
probes="$(grep -c "^exec $G369 test -d /etc/squid/egresslock$" "$STATE/execlog" || true)"
sq="$(mock_cfg_file "$G369" squid.conf)"
grp="$(mock_group_file "$G369" allowlist_p8443)"
ref="$(mock_cfg_ref "$G369" allowlist_p8443)"
if [[ "$rc" == 0 && "$probes" == 1 && -f "$sq" && -n "$grp" && -f "$grp" ]] \
   && [[ "$ref" == /etc/squid/agent/* ]] \
   && [[ "$o" == *"gateway 'egresslock-gateway-g369' ready"* ]]; then
    e369 pass
else
    e369 fail "apply-bound layout keeps referenced groups (rc=$rc, probes=$probes, ref=$ref, grp=$grp, out: $o)"
fi
rm -f "$STATE/gw-probe-old-once-$G369"
run369 teardown g369 >/dev/null 2>&1 || true

# 7. R-EGL-369-13 F3: a later transient probe error cannot sneak past the
#    binding. The apply probe answers the old dir once; every later probe
#    is a runtime error (rc 125). With verify/cleanup reusing the bound
#    layout, no later probe runs and ensure is green; losing either
#    binding forces a second probe, which fails closed -> red. Exactly one
#    probe per ensure is the direct binding pin (both mutants red).
run369 teardown g369 >/dev/null 2>&1 || true
touch "$STATE/gw-probe-old-once-$G369" "$STATE/gw-probe-fail-after-old-once-$G369"
: > "$STATE/execlog"
o="$(EGRESSLOCK_GW_CLEANUP_GRACE=0 run369 ensure g369 2>&1)"; rc=$?
probes="$(grep -c "^exec $G369 test -d /etc/squid/egresslock$" "$STATE/execlog" || true)"
sq="$(mock_cfg_file "$G369" squid.conf)"
ref="$(mock_cfg_ref "$G369" allowlist_p8443)"
if [[ "$rc" == 0 && "$probes" == 1 && -f "$sq" && "$ref" == /etc/squid/agent/* ]]; then
    e369 pass
else
    e369 fail "one probe per ensure; verify/cleanup reuse the apply's bound layout (rc=$rc, probes=$probes, ref=$ref, out: $o)"
fi
rm -f "$STATE/gw-probe-old-once-$G369" "$STATE/gw-probe-fail-after-old-once-$G369"
run369 teardown g369 >/dev/null 2>&1 || true

# 8. R-EGL-369-13 F3: a STANDALONE verify (no apply to bind) probes once
#    and fails closed on a runtime probe error, naming the exec failure.
#    Nothing may mutate: deployed config/group bytes and StartedAt stay
#    identical. Mutation: treat the error as the old layout -> verify
#    parses the wrong path and returns green.
o="$(run369 ensure g369 2>&1)"; rc=$?
sq="$(mock_cfg_file "$G369" squid.conf)"
grp="$(mock_group_file "$G369" allowlist_p8443)"
sq_before="$(sha256sum "$sq" 2>/dev/null | cut -d' ' -f1)"
grp_before="$(sha256sum "$grp" 2>/dev/null | cut -d' ' -f1)"
st_before="$(cat "$STATE/containers-$G369.started" 2>/dev/null)"
touch "$STATE/gw-probe-fails-$G369"
: > "$STATE/execlog"
o="$(run369 verify g369 2>&1)"; rc=$?
probes="$(grep -c "^exec $G369 test -d /etc/squid/egresslock$" "$STATE/execlog" || true)"
sq_after="$(sha256sum "$sq" 2>/dev/null | cut -d' ' -f1)"
grp_after="$(sha256sum "$grp" 2>/dev/null | cut -d' ' -f1)"
st_after="$(cat "$STATE/containers-$G369.started" 2>/dev/null)"
if [[ "$rc" == 1 && "$probes" == 1 && -f "$sq" && -f "$grp" \
      && "$sq_before" == "$sq_after" \
      && "$grp_before" == "$grp_after" && "$st_before" == "$st_after" ]] \
   && [[ "$o" == *"not exec-able (config-directory probe rc=125"* ]]; then
    e369 pass
else
    e369 fail "standalone verify probe error fails closed without mutation (rc=$rc, probes=$probes, out: $o)"
fi
rm -f "$STATE/gw-probe-fails-$G369"

# 9. R-EGL-369-13 F3: the same probe error on a PRE-EXISTING healthy
#    gateway (plain ensure, not --replace-gateway) fails closed before
#    any mutation: same container, deployed bytes, StartedAt. The older
#    rc-125 leg only covered a fresh replace (no live state to protect).
sq="$(mock_cfg_file "$G369" squid.conf)"
grp="$(mock_group_file "$G369" allowlist_p8443)"
sq_before="$(sha256sum "$sq" 2>/dev/null | cut -d' ' -f1)"
grp_before="$(sha256sum "$grp" 2>/dev/null | cut -d' ' -f1)"
st_before="$(cat "$STATE/containers-$G369.started" 2>/dev/null)"
touch "$STATE/gw-probe-fails-$G369"
: > "$STATE/execlog"
o="$(run369 ensure g369 2>&1)"; rc=$?
probes="$(grep -c "^exec $G369 test -d /etc/squid/egresslock$" "$STATE/execlog" || true)"
sq_after="$(sha256sum "$sq" 2>/dev/null | cut -d' ' -f1)"
grp_after="$(sha256sum "$grp" 2>/dev/null | cut -d' ' -f1)"
st_after="$(cat "$STATE/containers-$G369.started" 2>/dev/null)"
if [[ "$rc" != 0 && "$probes" == 1 && -f "$sq" && -f "$grp" \
      && "$sq_before" == "$sq_after" \
      && "$grp_before" == "$grp_after" && "$st_before" == "$st_after" ]] \
   && [[ -f "$STATE/running/$G369" ]] \
   && [[ "$o" == *"gateway config-directory probe failed (runtime exec test -d returned rc 125; fail closed)"* ]]; then
    e369 pass
else
    e369 fail "pre-existing gateway probe error fails closed without mutation (rc=$rc, probes=$probes, out: $o)"
fi
rm -f "$STATE/gw-probe-fails-$G369"
run369 teardown g369 >/dev/null 2>&1 || true

# 10. Shipped image bootstrap carries the same vocabulary and layout as
#    the generator: one rename, no drift between image and engine.
if grep -qx 'acl profile_subnet src 10.199.2.0/24' "$TREE_ROOT/gateway/squid.conf" \
   && grep -qx 'acl allowlist dstdomain -n "/etc/squid/egresslock/allowlist.conf"' "$TREE_ROOT/gateway/squid.conf" \
   && grep -qx 'http_access allow profile_subnet allowlist' "$TREE_ROOT/gateway/squid.conf" \
   && grep -q 'ln -s egresslock /etc/squid/agent' "$TREE_ROOT/gateway/Containerfile" \
   && grep -qx 'ALLOWLIST=/etc/squid/egresslock/allowlist.conf' "$TREE_ROOT/gateway/entrypoint.sh" \
   && grep -qx 'CFG=/etc/squid/egresslock/squid.conf' "$TREE_ROOT/gateway/entrypoint.sh"; then
    e369 pass
else
    e369 fail "shipped gateway bootstrap/layout vocabulary drifted"
fi

section_end egl369

section_begin egl366 "EGL-366 every profile needs a gateway"
e366() { assert "$@"; }

# D1/D3: a gateway-less (direct-only) profile no longer loads — one named
# error at the opening `profile` line, the gateway line + allowlist
# recipe, rc 2, nothing on stdout. Mutation: delete the block-close
# check -> leg 1/2/3 red (rc 0 and a list row), leg 4 red (the mutator
# succeeds).
S366="$TESTROOT/h366"; rm -rf "$S366"; mkdir -p "$S366"

# 1. Allow-host rule only: the shape the filing found in the wild.
cat > "$S366/hw.conf" <<'EOF'
profile hw 10.199.150.0/24
    rule allow-host git.example.test:443
EOF
H366="$(conf_home_ro "$S366/hw.conf")"
run366() { env ARCMOCK_PASSWD_HOME="$H366" egresslock "$@"; }

o="$(run366 list 2>"$S366/e1")"; rc=$?
if [[ "$rc" == 2 && -z "$o" \
      && "$(grep -c '^Error:' "$S366/e1")" == 1 \
      && "$(cat "$S366/e1")" == *"hw.conf:1: profile 'hw' has no 'gateway' directive; every profile needs a gateway (a direct-only profile is not a supported mode)."* \
      && "$(cat "$S366/e1")" == *"offending line: profile hw 10.199.150.0/24"* \
      && "$(cat "$S366/e1")" == *"  fix: add a gateway line to this conf, e.g.: gateway 10.199.150.2 3128 hw-allowlist"* \
      && "$(cat "$S366/e1")" == *"       (10.199.150.2 is an example address — any unused address strictly between the bridge gateway (first usable) and the anchor (last usable) works; 'egresslock init' uses the subnet's second usable one on a fresh profile)"* \
      && "$(cat "$S366/e1")" == *"  fix: create $H366/.config/egresslock/hw-allowlist next to this conf (a new empty 0600 file allows no proxied destinations; if it already exists, review its entries first), then run: egresslock ensure hw"* ]]; then
    e366 pass
else
    e366 fail "gateway-less allow-host conf is rejected named (rc=$rc, out: $o, err: $(cat "$S366/e1"))"
fi

# 1b. The resolution line still comes first (R7/EGL-117), then the one
# named cause — never a generic line stacked over it.
res366="$(grep -n '^using configs in' "$S366/e1" | head -1 | cut -d: -f1)"
err366="$(grep -n '^Error:' "$S366/e1" | head -1 | cut -d: -f1)"
if [[ -n "$res366" && -n "$err366" && "$res366" -lt "$err366" ]]; then
    e366 pass
else
    e366 fail "resolution line precedes the named error (res=$res366 err=$err366)"
fi

# 2. Rules-free profile (the `profile` line alone): rejected too — the
# check is global, not gated on a rule kind. Mutation: gate the check on
# `rule allow-host` -> this leg reds while 1 stays green.
cat > "$S366/rfree.conf" <<'EOF'
profile rfree 10.199.151.0/24
EOF
H366R="$(conf_home_ro "$S366/rfree.conf")"
o="$(env ARCMOCK_PASSWD_HOME="$H366R" egresslock list 2>"$S366/e2")"; rc=$?
if [[ "$rc" == 2 && -z "$o" \
      && "$(grep -c '^Error:' "$S366/e2")" == 1 \
      && "$(cat "$S366/e2")" == *"rfree.conf:1: profile 'rfree' has no 'gateway' directive"* \
      && "$(cat "$S366/e2")" == *"fix: add a gateway line to this conf, e.g.: gateway 10.199.151.2 3128 rfree-allowlist"* ]]; then
    e366 pass
else
    e366 fail "rules-free gateway-less profile is rejected (rc=$rc, out: $o, err: $(cat "$S366/e2"))"
fi

# 3. `rule gateway-only` without a gateway keeps its specific cause and
# gains the same two fix lines — one error, never the generic one too.
cat > "$S366/gwo.conf" <<'EOF'
profile gwo 10.199.152.0/24
    rule gateway-only
EOF
H366G="$(conf_home_ro "$S366/gwo.conf")"
o="$(env ARCMOCK_PASSWD_HOME="$H366G" egresslock list 2>"$S366/e3")"; rc=$?
if [[ "$rc" == 2 && -z "$o" \
      && "$(grep -c '^Error:' "$S366/e3")" == 1 \
      && "$(cat "$S366/e3")" == *"profile 'gwo' has 'rule gateway-only' but no 'gateway' directive"* \
      && "$(cat "$S366/e3")" != *"has no 'gateway' directive; every profile needs a gateway"* \
      && "$(cat "$S366/e3")" == *"offending line: profile gwo 10.199.152.0/24"* \
      && "$(cat "$S366/e3")" == *"fix: add a gateway line to this conf, e.g.: gateway 10.199.152.2 3128 gwo-allowlist"* \
      && "$(cat "$S366/e3")" == *"fix: create $H366G/.config/egresslock/gwo-allowlist next to this conf"* ]]; then
    e366 pass
else
    e366 fail "gateway-only miss keeps its cause + gains both fix lines (rc=$rc, out: $o, err: $(cat "$S366/e3"))"
fi

# 4. A mutator fails closed at load: rc 2, the named cause, and the conf
# bytes are untouched (nothing enforced or changed).
before366="$(sha256sum "$H366/.config/egresslock/hw.conf" | cut -d' ' -f1)"
o="$(run366 allow hw git.example.test 2>"$S366/e4")"; rc=$?
after366="$(sha256sum "$H366/.config/egresslock/hw.conf" | cut -d' ' -f1)"
if [[ "$rc" == 2 && -z "$o" && "$before366" == "$after366" \
      && "$(cat "$S366/e4")" == *"profile 'hw' has no 'gateway' directive"* \
      && "$(cat "$S366/e4")" != *"added:"* ]]; then
    e366 pass
else
    e366 fail "mutator fails closed on a gateway-less conf, conf unchanged (rc=$rc, out: $o, err: $(cat "$S366/e4"))"
fi

# 5. A valid `init` starter (which always writes a gateway) still loads,
# lists, and answers the direct-lane view unchanged.
rm -rf "$S366/init"; mkdir -p "$S366/init/.config/egresslock"
i366="$(env HOME="$S366/init" ARCMOCK_PASSWD_HOME="$S366/init" egresslock init g366 --subnet 10.199.153.0/24 2>&1)"; irc=$?
l366="$(env ARCMOCK_PASSWD_HOME="$S366/init" egresslock list 2>/dev/null)"; lrc=$?
al366="$(env ARCMOCK_PASSWD_HOME="$S366/init" egresslock allowlist g366 --direct 2>/dev/null)"; alrc=$?
if [[ "$irc" == 0 && "$lrc" == 0 && "$alrc" == 0 \
      && "$l366" == *"g366"*"10.199.153.0/24"* \
      && "$al366" == *"profile 'g366' — 0 direct entries from the profile conf (pinned to addresses at ensure; traffic is not proxied):"* ]]; then
    e366 pass
else
    e366 fail "init starter loads; list/allowlist --direct unchanged (rc=$irc/$lrc/$alrc, list: $l366, direct: $al366)"
fi

# 6. The aggregate path (append mode) names the offending file, and a
# valid sibling still loads — one check, every conf file.
rm -rf "$S366/agg"; mkdir -p "$S366/agg"
printf 'profile aa 10.199.154.0/24\n    rule gateway-only\n    gateway 10.199.154.2 3128 aa-allowlist\n' > "$S366/agg/aa.conf"
printf 'profile bb 10.199.155.0/24\n' > "$S366/agg/bb.conf"
H366A="$(conf_home "$S366/agg")"
o="$(env ARCMOCK_PASSWD_HOME="$H366A" egresslock list 2>"$S366/e6")"; rc=$?
if [[ "$rc" == 2 && -z "$o" \
      && "$(cat "$S366/e6")" == *"(2 profiles)"* \
      && "$(cat "$S366/e6")" == *"bb.conf:1: profile 'bb' has no 'gateway' directive"* \
      && "$(cat "$S366/e6")" != *"aa.conf"* ]]; then
    e366 pass
else
    e366 fail "aggregate load names the gateway-less file only (rc=$rc, out: $o, err: $(cat "$S366/e6"))"
fi

# 7. Retired 2026-10-29 (operator docs rework, EGL-366): the
#    profile-no-gateway troubleshooting page is deleted — the engine's
#    `fix:` hint owns the 0600/new-file guidance now. That wording is
#    pinned verbatim in leg 1 above; do not re-add a page-recipe leg.

section_end egl366

# --- EGL-378: inherited-CWD guard (runtime commands run from /) ---------
# The engine + the verify wrapper run every rootless podman call from /
# in a throwaway subshell, so `sudo -u <account>` from a directory the
# account cannot traverse no longer dies on podman's startup chdir. The
# engine process itself never chdirs (EGL-305), so relative arguments
# keep the invocation-directory basis. The mock podman models the real
# startup chdir (tests/lib.sh), which makes a missing guard behavioral.
section_begin egl378 "EGL-378 inherited-CWD guard"
e378() { assert "$@"; }

S378="$TESTROOT/s378"; rm -rf "$S378"; mkdir -p "$S378" "$STATE/ips"
cat > "$S378/s378.conf" <<'EOF'
profile s378 10.199.160.0/24
    rule gateway-only
    gateway 10.199.160.2 3128 s378-allowlist
EOF
printf '# starter\n' > "$S378/s378-allowlist"
cat > "$S378/s378b.conf" <<'EOF'
profile s378b 10.199.161.0/24
    gateway 10.199.161.2 3128 s378b-allowlist
EOF
printf '# starter\n' > "$S378/s378b-allowlist"
E378HOME="$(conf_home "$S378/s378.conf")"

# 1. Mock fidelity (the foundation): the mock itself models the startup
#    chdir. Control leg: run it directly from a mode-000 directory; rc
#    125 + podman's own line. Mutation: remove the mock's chdir check ->
#    this leg reds, and every blocked-CWD assert below goes vacuous.
e378b="$S378/blocked-control"; mkdir -p "$e378b"
( cd "$e378b" && chmod 000 . && ARCMOCK_STATE="$STATE" "$TESTROOT/bin/podman" --version ) \
    > "$S378/control.out" 2>&1; e378c_rc=$?
chmod 755 "$e378b"
if [[ "$e378c_rc" == 125 \
      && "$(cat "$S378/control.out")" == *"cannot chdir to $e378b: Permission denied"* ]]; then
    e378 pass
else
    e378 fail "mock podman models the startup chdir (rc=$e378c_rc, out: $(cat "$S378/control.out"))"
fi

# 2. Blocked CWD, guard on: `ensure` from a mode-000 directory returns 0,
#    and every podman call it made started in / (the CWD log is exactly
#    /). Mutation: drop rt_in_root from any exercised primitive -> the
#    mock exits 125 at that call -> nonzero rc (and the log shows the
#    blocked directory).
e378cwd="$S378/blocked-ensure"; mkdir -p "$e378cwd"
e378log="$S378/podman-cwd.log"; : > "$e378log"
( cd "$e378cwd" && chmod 000 . \
    && env ARCMOCK_PASSWD_HOME="$E378HOME" ARCMOCK_PODMAN_CWD_LOG="$e378log" \
        egresslock ensure s378 ) > "$S378/ensure.out" 2>&1; e378e_rc=$?
chmod 755 "$e378cwd"
e378cwd_seen="$(sort -u "$e378log")"
if [[ "$e378e_rc" == 0 && "$e378cwd_seen" == "/" \
      && "$(cat "$S378/ensure.out")" != *"cannot chdir"* ]]; then
    e378 pass
else
    e378 fail "ensure from an untraversable CWD is green and runs every runtime call from / (rc=$e378e_rc, cwd-log: $(printf '%s' "$e378cwd_seen" | tr '\n' '|'), out: $(cat "$S378/ensure.out"))"
fi

# 3. All 18 podman-invoking rt_* bodies route through rt_in_root. The
#    blocked-CWD leg only exercises ensure's subset; this source pin
#    covers teardown/doctor/build-gateway calls too. Carve-outs:
#    rt_have_runtime's `command -v podman` (no invocation) and
#    rt_capabilities (declarative). Mutation: revert one body to a bare
#    podman call -> that body's line has no rt_in_root -> reds.
e378eng="$TREE_ROOT/egresslock"
e378_bodies=0; e378_bad=""
while IFS= read -r e378fn; do
    e378body="$(awk -v fn="$e378fn" '$0 ~ "^" fn "\\(\\)" {p=1} p {print} p && /^}$/ {exit}' "$e378eng")"
    e378hits="$(printf '%s\n' "$e378body" | grep -vE '^[[:space:]]*#' \
        | grep -vE 'command -v podman' \
        | grep -E '(^|[[:space:]`$(])podman([[:space:]|&;<>]|$)')"
    [[ -n "$e378hits" ]] || continue
    e378_bodies=$((e378_bodies + 1))
    while IFS= read -r e378line; do
        [[ "$e378line" == *rt_in_root* ]] || e378_bad+=" $e378fn"
    done <<<"$e378hits"
done < <(grep -oE '^rt_[a-z_]+\(\)' "$e378eng" | sed 's/()$//')
if [[ "$e378_bodies" == 18 && -z "$e378_bad" ]]; then
    e378 pass
else
    e378 fail "every podman-invoking rt_* body routes through rt_in_root (bodies=$e378_bodies, unrouted:$e378_bad)"
fi

# 4. Relative build-gateway invocation (D3): a path-invoked engine must
#    pass canonical absolute -f/context tokens, resolved from the
#    engine's own neighbor gateway/ — not the invocation CWD. Mutation:
#    revert the gdir absolutization -> the buildlog carries ./kit/...
#    tokens (or the relative context resolves to /gateway) -> reds.
e378pin="sha256:$(printf 'b%.0s' $(seq 1 64))"
e378img="localhost/egresslock-gateway:e378"
e378k="$S378/kroot"; mkdir -p "$e378k/kit/gateway"
cp "$TREE_ROOT/egresslock" "$e378k/kit/egresslock"
printf 'FROM docker.io/library/debian:13-slim@%s\n' "$e378pin" \
    > "$e378k/kit/gateway/Containerfile"
rm -f "$STATE/images/$(echo "$e378img" | tr '/:' '__')"
: > "$STATE/buildlog"
( cd "$e378k" && env EGRESSLOCK_GW_IMAGE="$e378img" ./kit/egresslock build-gateway ) \
    > "$S378/build.out" 2>&1; e378b_rc=$?
e378bl="$(cat "$STATE/buildlog")"
if [[ "$e378b_rc" == 0 \
      && "$e378bl" == *"build -t $e378img --format docker -f $e378k/kit/gateway/Containerfile $e378k/kit/gateway"* \
      && "$e378bl" != *"./kit/"* ]]; then
    e378 pass
else
    e378 fail "relative build-gateway carries canonical absolute context tokens (rc=$e378b_rc, buildlog: $e378bl, out: $(cat "$S378/build.out"))"
fi

# 5. Relative NFT_BIN keeps its invocation-directory meaning (D6). The
#    resolved binary is the command word of `podman unshare …`, now
#    exec'd from / — absolutize at $PWD so ./nft-rel still resolves where
#    the operator ran the engine. Mutation: drop the D6 normalization ->
#    the child execs ./nft-rel from / -> named failure -> reds.
e378nd="$S378/nftdir"; mkdir -p "$e378nd"
cat > "$e378nd/nft-rel" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$0" >> "$S378/nft-log"
exec "$TESTROOT/bin/nft" "\$@"
EOF
chmod +x "$e378nd/nft-rel"
: > "$S378/nft-log"
( cd "$e378nd" && env ARCMOCK_PASSWD_HOME="$E378HOME" NFT_BIN=./nft-rel \
    egresslock ensure s378b ) > "$S378/nft-ensure.out" 2>&1; e378n_rc=$?
e378n_first="$(head -n 1 "$S378/nft-log" 2>/dev/null)"
if [[ "$e378n_rc" == 0 && -s "$S378/nft-log" \
      && "$e378n_first" == "$e378nd/"*"nft-rel" ]]; then
    e378 pass
else
    e378 fail "relative NFT_BIN keeps its invocation-directory meaning (rc=$e378n_rc, first: $e378n_first, out: $(cat "$S378/nft-ensure.out"))"
fi

# 6. Relative CONNTRACK_BIN keeps its invocation-directory meaning (D6),
#    pinned on a command that actually reaches netns_conntrack: `ensure`
#    never does (why dropping conntrack_bin's normalization alone reds
#    nothing). `disallow-host` runs conntrack_probe (-C) and the flush's
#    scoped reads (-L) through the unshare child. Mutation: drop only
#    conntrack_bin's $PWD normalization -> the child execs
#    ./conntrack-rel from / -> named probe failure -> reds.
e378ctd="$S378/ctdir"; mkdir -p "$e378ctd"
cat > "$e378ctd/conntrack-rel" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$0" >> "$S378/conntrack-log"
exec "$TESTROOT/bin/conntrack" "\$@"
EOF
chmod +x "$e378ctd/conntrack-rel"
cat > "$S378/s378c.conf" <<'EOF'
profile s378c 10.199.162.0/24
    rule allow-host cache.example.test:8080
    gateway 10.199.162.2 3128 s378c-allowlist
EOF
printf '# starter\n' > "$S378/s378c-allowlist"
E378HOME_CT="$(conf_home "$S378/s378c.conf")"
env ARCMOCK_PASSWD_HOME="$E378HOME_CT" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    egresslock ensure s378c >/dev/null 2>&1 || true
: > "$S378/conntrack-log"; : > "$STATE/conntrack.log"; : > "$STATE/nft/conntrack-table"
( cd "$e378ctd" && env ARCMOCK_PASSWD_HOME="$E378HOME_CT" EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    CONNTRACK_BIN=./conntrack-rel \
    egresslock disallow-host s378c cache.example.test:8080 ) > "$S378/conntrack-disallow.out" 2>&1; e378ct_rc=$?
e378ct_first="$(head -n 1 "$S378/conntrack-log" 2>/dev/null)"
if [[ "$e378ct_rc" == 0 && -s "$S378/conntrack-log" \
      && "$e378ct_first" == "$e378ctd/"*"conntrack-rel" \
      && "$(cat "$STATE/conntrack.log")" == *"conntrack -C"* ]]; then
    e378 pass
else
    e378 fail "relative CONNTRACK_BIN keeps its invocation-directory meaning through netns_conntrack (rc=$e378ct_rc, first: $e378ct_first, ct-log: $(head -n 2 "$STATE/conntrack.log" 2>/dev/null | tr '\n' '|'), out: $(tail -n 2 "$S378/conntrack-disallow.out" | tr '\n' '|'))"
fi

# 7. Fail-closed engine branch (D5), exercised live: an unprivileged test
#    cannot make / untraversable, so a scratch copy substitutes the
#    helper's target (`cd /` -> a path that does not exist) at the exact
#    `|| {` boundary. `ensure` must print the named line, exit 1, and
#    start NO podman call. Mutation: restore the real `cd /` (run the
#    unmodified tree engine) -> rc 0, no named line, podman calls logged
#    -> reds.
e378fi="$S378/failclosed-engine"; mkdir -p "$e378fi"
sed 's@^        cd / || {@        cd /egl378-no-such-target || {@' \
    "$e378eng" > "$e378fi/egresslock"
chmod +x "$e378fi/egresslock"
: > "$S378/failclosed-engine.log"
env ARCMOCK_PASSWD_HOME="$E378HOME" ARCMOCK_PODMAN_CWD_LOG="$S378/failclosed-engine.log" \
    "$e378fi/egresslock" ensure s378 > "$S378/failclosed-engine.out" 2>&1; e378fe_rc=$?
if [[ "$e378fe_rc" == 1 && ! -s "$S378/failclosed-engine.log" \
      && "$(cat "$S378/failclosed-engine.out")" == *"Error: cannot change directory to / before running the container runtime; no runtime command was run"* ]]; then
    e378 pass
else
    e378 fail "engine fail-closed line is a live refusal (rc=$e378fe_rc, podman-calls=$(grep -c . "$S378/failclosed-engine.log" 2>/dev/null || true), out: $(head -n 2 "$S378/failclosed-engine.out" | tr '\n' '|'))"
fi

# 8. Fail-closed wrapper branch (D5), exercised live: same target
#    substitution at the wrapper's pre-check. The probe must not run
#    (0 podman calls) and the wrapper exits 1 with its named line.
#    Mutation: restore the real `cd /` -> the probe runs and the wrapper
#    exits 0 -> reds.
e378fv="$S378/failclosed-verify"; mkdir -p "$e378fv"
sed 's@if ! ( cd / ) 2>/dev/null; then@if ! ( cd /egl378-no-such-target ) 2>/dev/null; then@' \
    "$TREE_ROOT/egresslock-verify" > "$e378fv/egresslock-verify"
chmod +x "$e378fv/egresslock-verify"
printf '#!/usr/bin/env bash\nexit 0\n' > "$e378fv/egresslock"
chmod +x "$e378fv/egresslock"
: > "$S378/failclosed-verify.log"
env -u EGRESSLOCK_PROFILE -u EGRESSLOCK_SKIP_NETNS_PROBE EGRESSLOCK_DIR="$e378fv" \
    ARCMOCK_PODMAN_CWD_LOG="$S378/failclosed-verify.log" \
    "$e378fv/egresslock-verify" > "$S378/failclosed-verify.out" 2>&1; e378fv_rc=$?
if [[ "$e378fv_rc" == 1 && ! -s "$S378/failclosed-verify.log" \
      && "$(cat "$S378/failclosed-verify.out")" == *"egresslock-verify: cannot change directory to / before the netns probe; the probe was not run"* ]]; then
    e378 pass
else
    e378 fail "wrapper fail-closed line is a live refusal (rc=$e378fv_rc, podman-calls=$(grep -c . "$S378/failclosed-verify.log" 2>/dev/null || true), out: $(head -n 2 "$S378/failclosed-verify.out" | tr '\n' '|'))"
fi

# 9. D3 engine-directory failure (R-EGL-378-5 note): when the engine's
#    own directory cannot be entered, the refusal names that cause; it
#    must not degrade into the generic missing-context line (or bash's
#    bare cd error). Scratch-copy substitution at the exact engine-dir
#    `cd`; no podman call may start. Mutation: restore the real `cd` ->
#    the missing-context line prints -> reds.
e378gd="$S378/gdir-failclosed"; mkdir -p "$e378gd/kit"
cp "$e378eng" "$e378gd/kit/egresslock"
python3 - "$e378gd/kit/egresslock" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'if ! edir="$(CDPATH=\'\' cd -- "$edir_src" 2>/dev/null && pwd)"; then'
new = 'if ! edir="$(CDPATH=\'\' cd -- /egl378-no-such-target 2>/dev/null && pwd)"; then'
if old not in s:
    sys.exit("EGL-378: gdir guard anchor not found")
open(p, 'w').write(s.replace(old, new, 1))
PY
chmod +x "$e378gd/kit/egresslock"
: > "$S378/gdir-failclosed.log"
env ARCMOCK_PODMAN_CWD_LOG="$S378/gdir-failclosed.log" \
    "$e378gd/kit/egresslock" build-gateway > "$S378/gdir-failclosed.out" 2>&1; e378gd_rc=$?
if [[ "$e378gd_rc" == 1 && ! -s "$S378/gdir-failclosed.log" \
      && "$(cat "$S378/gdir-failclosed.out")" == "Error: cannot enter the engine's own directory ($e378gd/kit) to find the gateway build context; check that it is accessible" ]]; then
    e378 pass
else
    e378 fail "engine-directory failure names the cause (rc=$e378gd_rc, podman-calls=$(grep -c . "$S378/gdir-failclosed.log" 2>/dev/null || true), out: $(head -n 2 "$S378/gdir-failclosed.out" | tr '\n' '|'))"
fi

# 10. Relative Podman path-valued settings keep their invocation-
#     directory meaning across the cd / seam (R-EGL-378-8). The mock
#     podman resolves each named setting at startup as seen from its
#     inherited CWD; with preservation every relative value is
#     absolutized at $PWD and opens, without it the first `/…` lookup is
#     missing (rc 125). Covers the documented config files and the
#     directory-valued settings. Mutation: drop rt_absolutize_podman_env
#     from rt_in_root -> ensure rc 125/missing config -> reds.
e378envd="$S378/envdir"; rm -rf "$e378envd"
mkdir -p "$e378envd/tmp" "$e378envd/helpers" "$e378envd/xdg-config" \
         "$e378envd/xdg-data" "$e378envd/xdg-runtime"
printf '[engine]\n' > "$e378envd/podman.conf"
printf '[engine]\n' > "$e378envd/podman-override.conf"
printf 'unqualified-search-registries = ["example.test"]\n' > "$e378envd/registries.conf"
printf '[storage]\n' > "$e378envd/storage.conf"
printf '{}\n' > "$e378envd/connections.json"
printf 'synthetic-key\n' > "$e378envd/sshkey"
printf '{}\n' > "$e378envd/auth.json"
: > "$S378/podman-env.log"
( cd "$e378envd" && env ARCMOCK_PASSWD_HOME="$E378HOME" \
    ARCMOCK_PODMAN_CONFIG_VARS="CONTAINERS_CONF CONTAINERS_CONF_OVERRIDE CONTAINERS_REGISTRIES_CONF CONTAINERS_STORAGE_CONF CONTAINERS_HELPER_BINARY_DIR PODMAN_CONNECTIONS_CONF CONTAINER_SSHKEY REGISTRY_AUTH_FILE TMPDIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_RUNTIME_DIR" \
    ARCMOCK_PODMAN_CONFIG_LOG="$S378/podman-env.log" \
    CONTAINERS_CONF=./podman.conf CONTAINERS_CONF_OVERRIDE=./podman-override.conf \
    CONTAINERS_REGISTRIES_CONF=./registries.conf CONTAINERS_STORAGE_CONF=./storage.conf \
    CONTAINERS_HELPER_BINARY_DIR=./helpers PODMAN_CONNECTIONS_CONF=./connections.json \
    CONTAINER_SSHKEY=./sshkey REGISTRY_AUTH_FILE=./auth.json TMPDIR=./tmp \
    XDG_CONFIG_HOME=./xdg-config XDG_DATA_HOME=./xdg-data XDG_RUNTIME_DIR=./xdg-runtime \
    egresslock ensure s378 ) > "$S378/podman-env-ensure.out" 2>&1; e378env_rc=$?
e378envlog="$(sort -u "$S378/podman-env.log")"
e378env_n="$(grep -c . <<<"$e378envlog" || true)"
e378env_bad="$(grep -vc "^[A-Z_]*=$e378envd/\./" <<<"$e378envlog" || true)"
if [[ "$e378env_rc" == 0 && "$e378env_n" == 12 && "$e378env_bad" == 0 \
      && "$e378envlog" == *"CONTAINERS_CONF=$e378envd/./podman.conf"* \
      && "$e378envlog" == *"XDG_RUNTIME_DIR=$e378envd/./xdg-runtime"* \
      && "$(cat "$S378/podman-env-ensure.out")" != *"no such file"* ]]; then
    e378 pass
else
    e378 fail "relative Podman path settings keep their invocation-directory meaning (rc=$e378env_rc, lines=$e378env_n, outside-prefix=$e378env_bad, log: $(printf '%s' "$e378envlog" | tr '\n' '|'), out: $(tail -n 2 "$S378/podman-env-ensure.out" | tr '\n' '|'))"
fi

# 11. Absolute control for the same seam (R-EGL-378-8): an already
#     absolute value must pass through byte-identical — no $PWD/./ prefix
#     and no second copy. Mutation: prefix unconditionally -> the logged
#     path differs -> reds.
: > "$S378/podman-env-abs.log"
( cd "$e378envd" && env ARCMOCK_PASSWD_HOME="$E378HOME" \
    ARCMOCK_PODMAN_CONFIG_VARS="CONTAINERS_CONF TMPDIR" \
    ARCMOCK_PODMAN_CONFIG_LOG="$S378/podman-env-abs.log" \
    CONTAINERS_CONF="$e378envd/podman.conf" TMPDIR="$e378envd/tmp" \
    egresslock ensure s378 ) > "$S378/podman-env-abs.out" 2>&1; e378abs_rc=$?
e378abslog="$(sort -u "$S378/podman-env-abs.log")"
if [[ "$e378abs_rc" == 0 \
      && "$(grep -c . <<<"$e378abslog" || true)" == 2 \
      && "$e378abslog" == *"CONTAINERS_CONF=$e378envd/podman.conf"* \
      && "$e378abslog" == *"TMPDIR=$e378envd/tmp"* \
      && "$e378abslog" != *"/./"* ]]; then
    e378 pass
else
    e378 fail "absolute Podman path settings pass through unchanged (rc=$e378abs_rc, log: $(printf '%s' "$e378abslog" | tr '\n' '|'), out: $(tail -n 2 "$S378/podman-env-abs.out" | tr '\n' '|'))"
fi

# 12. Exported CDPATH must not change engine-neighbor canonicalization
#     (R-EGL-378-8): with CDPATH set to the invocation directory, a
#     non-`./` relative invocation (`kit/egresslock`, not
#     `./kit/egresslock`) must still resolve the gateway context once.
#     Without `CDPATH=` on the `cd`, bash prints the matched directory,
#     $edir becomes two lines, and the build dies on a false
#     missing-Containerfile before any runtime call. Mutation: drop
#     `CDPATH=` from the canonicalization -> rc 1, no build -> reds.
e378cd2="$S378/kroot-cdpath"; rm -rf "$e378cd2"; mkdir -p "$e378cd2/kit/gateway"
cp "$e378eng" "$e378cd2/kit/egresslock"
cp "$e378k/kit/gateway/Containerfile" "$e378cd2/kit/gateway/Containerfile"
e378img2="localhost/egresslock-gateway:e378cd"
rm -f "$STATE/images/$(echo "$e378img2" | tr '/:' '__')"
: > "$STATE/buildlog"
( cd "$e378cd2" && env CDPATH="$e378cd2" EGRESSLOCK_GW_IMAGE="$e378img2" \
    kit/egresslock build-gateway ) > "$S378/build-cdpath.out" 2>&1; e378cd_rc=$?
e378cdbl="$(cat "$STATE/buildlog")"
if [[ "$e378cd_rc" == 0 \
      && "$e378cdbl" == *"build -t $e378img2 --format docker -f $e378cd2/kit/gateway/Containerfile $e378cd2/kit/gateway"* \
      && "$e378cdbl" != *"./kit/"* ]]; then
    e378 pass
else
    e378 fail "CDPATH exported, non-./ relative invocation still resolves the context (rc=$e378cd_rc, buildlog: $e378cdbl, out: $(cat "$S378/build-cdpath.out"))"
fi

# 13. Exported CDPATH must not change the standalone build-gateway's
#     engine-neighbor canonicalization (R-EGL-378-10): a non-`./`
#     relative invocation (`kit/build-gateway`) must resolve the
#     gateway/ context next to the script, never a foreign CDPATH hit.
#     Without `CDPATH=` on the script's own `cd`, bash lands in the
#     foreign kit/ and the script dies on a false missing-Containerfile
#     error before any build. Mutation: drop the guard -> rc 1, no build
#     -> reds.
e378bg="$S378/kroot-buildgw"; rm -rf "$e378bg"; mkdir -p "$e378bg/kit/gateway"
cp "$TREE_ROOT/build-gateway" "$e378bg/kit/build-gateway"
cp "$e378k/kit/gateway/Containerfile" "$e378bg/kit/gateway/Containerfile"
e378bg_foreign="$S378/foreign-buildgw"; rm -rf "$e378bg_foreign"; mkdir -p "$e378bg_foreign/kit"
e378img3="localhost/egresslock-gateway:e378bg"
rm -f "$STATE/images/$(echo "$e378img3" | tr '/:' '__')"
: > "$STATE/buildlog"
( cd "$e378bg" && env CDPATH="$e378bg_foreign" IMAGE="$e378img3" \
    kit/build-gateway ) > "$S378/buildgw-cdpath.out" 2>&1; e378bg_rc=$?
e378bgbl="$(cat "$STATE/buildlog")"
if [[ "$e378bg_rc" == 0 \
      && "$e378bgbl" == *"build --format docker -t $e378img3 -f $e378bg/kit/gateway/Containerfile $e378bg/kit/gateway"* \
      && "$e378bgbl" != *"$e378bg_foreign"* ]]; then
    e378 pass
else
    e378 fail "build-gateway ignores CDPATH for its own context (rc=$e378bg_rc, buildlog: $e378bgbl, out: $(cat "$S378/buildgw-cdpath.out"))"
fi

# 14. Class sweep (R-EGL-378-12/R-EGL-378-14 note): every shipped
#     script that canonicalizes a script-relative directory carries the
#     CDPATH='' guard, and every such canonicalization site in those
#     files is guarded (presence per file alone would pass a second
#     unguarded site). Legs 12-13 pin the two build helpers
#     behaviorally. Absolute-operand cd sites (engine `dirname "$conf"`,
#     setup `$home`/`$7`) are intentionally absent: CDPATH is never
#     consulted for an absolute operand. Mutation: drop the guard from
#     any listed file or site -> reds.
e378sweep_bad=""
e378_sweep_files=(
    build-gateway egresslock-verify egresslock-start egresslock-setup
    install-kit.sh examples/egl-base/build-egl-base
)
for e378sf in "${e378_sweep_files[@]}"; do
    grep -q "CDPATH='' cd --" "$TREE_ROOT/$e378sf" || e378sweep_bad+=" $e378sf"
    e378bare="$(grep -nE 'cd (-- )?"\$\(dirname' "$TREE_ROOT/$e378sf" \
        | grep -v "CDPATH='' cd --" || true)"
    [[ -z "$e378bare" ]] || e378sweep_bad+=" $e378sf(unguarded-site)"
done
e378_engine_guarded="$(grep -c "CDPATH='' cd --" "$e378eng" || true)"
if [[ -z "$e378sweep_bad" && "$e378_engine_guarded" -ge 2 ]]; then
    e378 pass
else
    e378 fail "shipped script-dir canonicalizations carry the CDPATH guard (bad:${e378sweep_bad:- none}; engine guarded sites=$e378_engine_guarded)"
fi

# 15. Standalone build-gateway from an untraversable CWD (R-EGL-378-15):
#     the shipped checkout helper runs podman from / like the engine
#     verb, so `sudo -u <account> build-gateway` from a 0700 home works.
#     Mutation: drop podman_in_root -> the mock's startup chdir fails ->
#     rc 125 with the raw `cannot chdir ...` line.
e378bgcwd="$S378/buildgw-blocked"; rm -rf "$e378bgcwd"; mkdir -p "$e378bgcwd"
e378bgkit="$S378/buildgw-blocked-kit"; rm -rf "$e378bgkit"; mkdir -p "$e378bgkit/gateway"
cp "$TREE_ROOT/build-gateway" "$e378bgkit/build-gateway"
cp "$e378k/kit/gateway/Containerfile" "$e378bgkit/gateway/Containerfile"
chmod +x "$e378bgkit/build-gateway"
e378img4="localhost/egresslock-gateway:e378bgb"
rm -f "$STATE/images/$(echo "$e378img4" | tr '/:' '__')"
: > "$STATE/buildlog"; : > "$S378/buildgw-blocked.log"
( cd "$e378bgcwd" && chmod 000 . \
    && env PATH="$TESTROOT/bin:$PATH" IMAGE="$e378img4" \
        ARCMOCK_PODMAN_CWD_LOG="$S378/buildgw-blocked.log" \
        "$e378bgkit/build-gateway" ) > "$S378/buildgw-blocked.out" 2>&1; e378bgb_rc=$?
chmod 755 "$e378bgcwd"
e378bgb_cwd="$(sort -u "$S378/buildgw-blocked.log")"
e378bgb_bl="$(cat "$STATE/buildlog")"
if [[ "$e378bgb_rc" == 0 && "$e378bgb_cwd" == "/" \
      && "$e378bgb_bl" == *"build --format docker -t $e378img4 -f $e378bgkit/gateway/Containerfile $e378bgkit/gateway"* \
      && "$(cat "$S378/buildgw-blocked.out")" != *"cannot chdir"* ]]; then
    e378 pass
else
    e378 fail "build-gateway runs podman from / under an untraversable CWD (rc=$e378bgb_rc, cwd-log: $(printf '%s' "$e378bgb_cwd" | tr '\n' '|'), out: $(cat "$S378/buildgw-blocked.out" | tr '\n' '|'))"
fi

# 16. Installed build-egl-base helper from an untraversable CWD
#     (R-EGL-378-15): the documented account helper runs its three
#     podman calls from /, so the headline `sudo -u` shape builds the
#     example image instead of dying on startup. Mutation: drop
#     podman_in_root from any call -> that call exits 125 at the mock's
#     startup chdir -> reds.
e378ebcwd="$S378/eglbase-blocked"; rm -rf "$e378ebcwd"; mkdir -p "$e378ebcwd"
rm -f "$STATE/images/localhost_egl-base_latest" \
      "$STATE/image-inspect-localhost_egl-base_latest"
: > "$STATE/buildlog"; : > "$S378/eglbase-blocked.log"
( cd "$e378ebcwd" && chmod 000 . \
    && env PATH="$TESTROOT/bin:$PATH" \
        ARCMOCK_PODMAN_CWD_LOG="$S378/eglbase-blocked.log" \
        "$TREE_ROOT/examples/egl-base/build-egl-base" ) > "$S378/eglbase-blocked.out" 2>&1; e378ebb_rc=$?
chmod 755 "$e378ebcwd"
e378ebb_cwd="$(sort -u "$S378/eglbase-blocked.log")"
e378ebb_bl="$(cat "$STATE/buildlog")"
if [[ "$e378ebb_rc" == 0 && "$e378ebb_cwd" == "/" \
      && "$e378ebb_bl" == "build -t localhost/egl-base:latest -f $TREE_ROOT/examples/egl-base/Containerfile $TREE_ROOT/examples/egl-base" \
      && "$(cat "$S378/eglbase-blocked.out")" != *"cannot chdir"* ]]; then
    e378 pass
else
    e378 fail "build-egl-base runs podman from / under an untraversable CWD (rc=$e378ebb_rc, cwd-log: $(printf '%s' "$e378ebb_cwd" | tr '\n' '|'), out: $(cat "$S378/eglbase-blocked.out" | tr '\n' '|'))"
fi

# 17. build-gateway fail-closed branch (D5 idiom, R-EGL-378-15),
#     exercised live at the exact `cd / || {` boundary. A scratch copy
#     substitutes a missing target: rc 1, the named line, and 0 podman
#     calls. Mutation: restore the real `cd /` -> rc 0, build runs ->
#     reds.
e378bgf="$S378/buildgw-failclosed"; rm -rf "$e378bgf"; mkdir -p "$e378bgf/gateway"
sed 's@^        cd / || {@        cd /egl378-no-such-target || {@' \
    "$TREE_ROOT/build-gateway" > "$e378bgf/build-gateway"
cp "$e378k/kit/gateway/Containerfile" "$e378bgf/gateway/Containerfile"
chmod +x "$e378bgf/build-gateway"
: > "$S378/buildgw-failclosed.log"
env PATH="$TESTROOT/bin:$PATH" IMAGE="localhost/egresslock-gateway:e378bgf" \
    ARCMOCK_PODMAN_CWD_LOG="$S378/buildgw-failclosed.log" \
    "$e378bgf/build-gateway" > "$S378/buildgw-failclosed.out" 2>&1; e378bgf_rc=$?
if [[ "$e378bgf_rc" == 1 && ! -s "$S378/buildgw-failclosed.log" \
      && "$(cat "$S378/buildgw-failclosed.out")" == *"build-gateway: cannot change directory to / before running the container runtime; no runtime command was run"* ]]; then
    e378 pass
else
    e378 fail "build-gateway fail-closed line is a live refusal (rc=$e378bgf_rc, podman-calls=$(grep -c . "$S378/buildgw-failclosed.log" 2>/dev/null || true), out: $(head -n 2 "$S378/buildgw-failclosed.out" | tr '\n' '|'))"
fi

# 18. build-egl-base fail-closed branch (D5 idiom, R-EGL-378-15), same
#     live injection. The probe call's stderr is deliberately quiet, so
#     the refusal surfaces on the build call; rc 1, the named line, 0
#     podman calls. Mutation: restore the real `cd /` -> rc 0 -> reds.
e378ebf="$S378/eglbase-failclosed"; rm -rf "$e378ebf"; mkdir -p "$e378ebf"
sed 's@^        cd / || {@        cd /egl378-no-such-target || {@' \
    "$TREE_ROOT/examples/egl-base/build-egl-base" > "$e378ebf/build-egl-base"
cp "$TREE_ROOT/examples/egl-base/Containerfile" "$e378ebf/Containerfile"
chmod +x "$e378ebf/build-egl-base"
rm -f "$STATE/images/localhost_egl-base_latest"
: > "$S378/eglbase-failclosed.log"
env PATH="$TESTROOT/bin:$PATH" \
    ARCMOCK_PODMAN_CWD_LOG="$S378/eglbase-failclosed.log" \
    "$e378ebf/build-egl-base" > "$S378/eglbase-failclosed.out" 2>&1; e378ebf_rc=$?
if [[ "$e378ebf_rc" == 1 && ! -s "$S378/eglbase-failclosed.log" \
      && "$(cat "$S378/eglbase-failclosed.out")" == *"Error: cannot change directory to / before running the container runtime; no runtime command was run"* ]]; then
    e378 pass
else
    e378 fail "build-egl-base fail-closed line is a live refusal (rc=$e378ebf_rc, podman-calls=$(grep -c . "$S378/eglbase-failclosed.log" 2>/dev/null || true), out: $(head -n 2 "$S378/eglbase-failclosed.out" | tr '\n' '|'))"
fi

# 19. Relative Podman path settings keep their invocation-directory
#     meaning in both helpers too (R-EGL-378-8 idiom, R-EGL-378-15):
#     CONTAINERS_CONF=./podman.conf must open from the directory the
#     operator ran the helper in, not from /. Mutation: drop the env
#     loop from either helper -> its podman call sees ./podman.conf at /
#     -> mock rc 125 -> reds.
e378henv="$S378/helper-env"; rm -rf "$e378henv"; mkdir -p "$e378henv/bg/gateway" "$e378henv/eb"
cp "$TREE_ROOT/build-gateway" "$e378henv/bg/build-gateway"
cp "$e378k/kit/gateway/Containerfile" "$e378henv/bg/gateway/Containerfile"
cp "$TREE_ROOT/examples/egl-base/build-egl-base" "$e378henv/eb/build-egl-base"
cp "$TREE_ROOT/examples/egl-base/Containerfile" "$e378henv/eb/Containerfile"
chmod +x "$e378henv/bg/build-gateway" "$e378henv/eb/build-egl-base"
printf '[engine]\n' > "$e378henv/bg/podman.conf"
printf '[engine]\n' > "$e378henv/eb/podman.conf"
rm -f "$STATE/images/localhost_egl-base_latest"
: > "$STATE/buildlog"
: > "$S378/helper-env-bg.log"; : > "$S378/helper-env-eb.log"
( cd "$e378henv/bg" && env PATH="$TESTROOT/bin:$PATH" IMAGE="localhost/egresslock-gateway:e378henv" \
    CONTAINERS_CONF=./podman.conf ARCMOCK_PODMAN_CONFIG_VARS=CONTAINERS_CONF \
    ARCMOCK_PODMAN_CONFIG_LOG="$S378/helper-env-bg.log" \
    "$e378henv/bg/build-gateway" ) > "$S378/helper-env-bg.out" 2>&1; e378henvb_rc=$?
( cd "$e378henv/eb" && env PATH="$TESTROOT/bin:$PATH" \
    CONTAINERS_CONF=./podman.conf ARCMOCK_PODMAN_CONFIG_VARS=CONTAINERS_CONF \
    ARCMOCK_PODMAN_CONFIG_LOG="$S378/helper-env-eb.log" \
    "$e378henv/eb/build-egl-base" ) > "$S378/helper-env-eb.out" 2>&1; e378henve_rc=$?
e378henv_bg="$(sort -u "$S378/helper-env-bg.log")"
e378henv_eb="$(sort -u "$S378/helper-env-eb.log")"
e378henv_bad="$(printf '%s\n%s\n' "$e378henv_bg" "$e378henv_eb" \
    | grep -v "^CONTAINERS_CONF=$e378henv/\(bg\|eb\)/\./podman\.conf$" || true)"
if [[ "$e378henvb_rc" == 0 && "$e378henve_rc" == 0 \
      && "$e378henv_bg" == "CONTAINERS_CONF=$e378henv/bg/./podman.conf" \
      && "$e378henv_eb" == "CONTAINERS_CONF=$e378henv/eb/./podman.conf" \
      && -z "$e378henv_bad" ]]; then
    e378 pass
else
    e378 fail "helper relative Podman settings keep their invocation-directory meaning (bg rc=$e378henvb_rc log: $(printf '%s' "$e378henv_bg" | tr '\n' '|'); eb rc=$e378henve_rc log: $(printf '%s' "$e378henv_eb" | tr '\n' '|'))"
fi

# 20. Direct-podman inventory sweep (R-EGL-378-15): enumerate the
#     shipped set by defect mechanism — bare podman command words — and
#     require every hit to sit in a traversable-CWD-guarded shape. The
#     engine's 18 rt_* bodies are pin-covered by leg 3; setup's two bare
#     calls live in the build_gw heredoc and are safe only when that
#     script is dispatched through run_as_account (which cd's to the
#     account home, ARC-19). Mutation: de-guard either helper call ->
#     its bare podman line, or the guarded-call count, reds here.
e378pods_bad=""
e378_pods_files=(build-gateway egresslock-verify egresslock-start \
                 egresslock-setup install-kit.sh uninstall-kit.sh \
                 examples/egl-base/build-egl-base)
for e378pf in "${e378_pods_files[@]}"; do
    [[ "$e378pf" == egresslock-setup ]] && continue
    while IFS= read -r e378pl; do
        [[ -n "$e378pl" ]] || continue
        case "$e378pl" in
            *rt_in_root*|*run_as_account*|*'cd / &&'*) continue ;;
        esac
        e378pods_bad+=" $e378pf:${e378pl%%[[:space:]]*}"
    done < <(grep -nE '^[[:space:]]*(if |elif |! )?podman([[:space:]]|$)' "$TREE_ROOT/$e378pf" \
                 | grep -v 'command -v podman' || true)
done
e378setup_ok=0
if grep -qF 'run_as_account bash -c "$build_gw"' "$TREE_ROOT/egresslock-setup" \
   && grep -qF '( cd "$home" && runuser' "$TREE_ROOT/egresslock-setup"; then
    e378setup_ok=1
fi
e378wrap_ok=0
if grep -qF 'cd / && timeout 5 podman unshare --rootless-netns true' "$TREE_ROOT/egresslock-verify"; then
    e378wrap_ok=1
fi
e378bg_guarded="$(grep -c 'podman_in_root podman' "$TREE_ROOT/build-gateway" || true)"
e378eb_guarded="$(grep -c 'podman_in_root podman' "$TREE_ROOT/examples/egl-base/build-egl-base" || true)"
if [[ -z "$e378pods_bad" && "$e378setup_ok" == 1 && "$e378wrap_ok" == 1 \
      && "$e378bg_guarded" == 1 && "$e378eb_guarded" == 3 ]]; then
    e378 pass
else
    e378 fail "direct-podman inventory: every shipped podman call runs from a traversable CWD (bad:${e378pods_bad:- none}; setup-guarded=$e378setup_ok wrapper-guarded=$e378wrap_ok; helper calls bg=$e378bg_guarded eb=$e378eb_guarded)"
fi

ARCMOCK_PASSWD_HOME="$E378HOME" egresslock teardown s378 >/dev/null 2>&1 || true
ARCMOCK_PASSWD_HOME="$E378HOME" egresslock teardown s378b >/dev/null 2>&1 || true
ARCMOCK_PASSWD_HOME="$E378HOME_CT" egresslock teardown s378c >/dev/null 2>&1 || true
section_end egl378

# --- EGL-389: proxy-path disallow failed-apply rollback/disclosure --------
section_begin egl389 "EGL-389 proxy-path disallow failed-apply rollback + disclosure"
e389() { assert "$@"; }

S389="$TESTROOT/s389"; rm -rf "$S389"; mkdir -p "$S389"
cat > "$S389/s389.conf" <<'EOF'
profile s389 10.199.140.0/24
    rule allow-host git.example.test:2222
    gateway 10.199.140.2 3128 s389-allowlist
EOF
cp "$S389/s389.conf" "$S389/s389.conf.pristine"
# The removal target SHARES its port group with a remaining entry (the
# design's common skip-bless shape): after `disallow`, the candidate's
# allowlist.p8443 differs from the deployed one while squid.conf is
# byte-identical. Every deployed-file cmp below is therefore non-vacuous
# — a missing D2 rollback leaves the staged one-entry file behind and
# reds it.
printf 'keep.example.test\nstay.example.test:8443\nrevoke.example.test:8443\n' > "$S389/s389-allowlist"
H389="$(conf_home "$S389/s389.conf")"
SRC389="$H389/.config/egresslock/s389-allowlist"
GW389="egresslock-gateway-s389"
DEP389="$STATE/containers-$GW389.cfg"
: > "$STATE/images/localhost_egresslock-gateway_latest"
mkdir -p "$TESTROOT/bin-nosleep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTROOT/bin-nosleep/sleep"
chmod +x "$TESTROOT/bin-nosleep/sleep"
E389PATH="$TESTROOT/bin-nosleep:$PATH"
run389() { env PATH="$E389PATH" ARCMOCK_PASSWD_HOME="$H389" HOME="$S389" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run389dns() { env PATH="$E389PATH" ARCMOCK_PASSWD_HOME="$H389" HOME="$S389" EGRESSLOCK_SKIP_NETNS_PROBE=1 EGRESSLOCK_MOCK_DNS='git.example.test=' egresslock "$@"; }
reset389() {
    chmod 0755 "$S389" 2>/dev/null || true
    rm -f "$STATE/allowlist-invalid" "$STATE/deployed-config-invalid" \
          "$STATE/mv-check-fails" "$STATE/rm-container-fails" \
          "$STATE"/cp-stage-fails-* "$STATE"/cp-snapshot-fails-* \
          "$STATE"/cp-restore-fails-* "$STATE"/exec-test-e-fails* \
          "$STATE"/restart-vanishes-* "$STATE"/restart-stop-fails* "$STATE"/probe-fails* \
          "$STATE"/ps-fails* "$STATE/replace-src-with-dir" \
          "$STATE/gateway-stops-at-verify" \
          "$STATE/nft/proxy-source-restore-fails" "$STATE/proxy-source-restore-fails-cp" \
          "$STATE/nft/confdir-unwritable"*
    cp "$S389/s389.conf.pristine" "$S389/s389.conf"
    rm -rf "$S389/s389-allowlist"
    rm -f "$S389"/s389-allowlist.egresslock-disallow-backup.*
    printf 'keep.example.test\nstay.example.test:8443\nrevoke.example.test:8443\n' > "$S389/s389-allowlist"
    # EGL-389 runtime: after the first green ensure, every reset restores
    # that exact mock state instead of paying a teardown+ensure. A leg
    # whose cleanup removed the gateway gets its running marker back too,
    # so no leg pays the process-spawn-heavy ensure; the next command sees
    # exactly what a fresh ensure seeded.
    if [[ -d "$S389/state-pristine" ]]; then
        rm -rf "$STATE"
        cp -a "$S389/state-pristine" "$STATE"
        : > "$STATE/opslog"
        return 0
    fi
    run389 teardown s389 >/dev/null 2>&1 || true
    run389 ensure s389 >/dev/null 2>&1
    : > "$STATE/opslog"
}
e389_order() { # e389_order <output> <first> <second> -> 1/0
    local a b
    a="$(grep -n -m1 -F "$2" <<<"$1" | cut -d: -f1)"
    b="$(grep -n -m1 -F "$3" <<<"$1" | cut -d: -f1)"
    if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then echo 1; else echo 0; fi
}
e389_hash() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

S_P1_389="disallow: nothing was revoked — the reinstall failed before the new allowlist was applied and the allowlist was put back — state: allowlist restored; gateway container running — next action: fix the underlying failure, then retry: egresslock disallow s389 revoke.example.test:8443"
S_P1N_389="disallow: nothing was revoked — the reinstall failed before the new allowlist was applied and the allowlist was put back — state: allowlist restored; gateway container not running — next action: fix the underlying failure, then retry: egresslock disallow s389 revoke.example.test:8443"
S_P1U_389="disallow: nothing was revoked — the reinstall failed before the new allowlist was applied and the allowlist was put back — state: allowlist restored; gateway container state could not be determined — next action: fix the underlying failure, then retry: egresslock disallow s389 revoke.example.test:8443"
S_P1R_389="disallow: nothing was revoked — the reinstall failed before the new allowlist was applied and the allowlist was put back — state: allowlist restored; gateway container '$GW389' removed by the failed apply's cleanup (connections through it ended) — next action: fix the underlying failure, then retry: egresslock disallow s389 revoke.example.test:8443"
S_P2_389="disallow: nothing was revoked — the reinstall failed before the new allowlist was applied, and the allowlist could not be put back after a retry — state: the requested entries are no longer in $SRC389; this attempt did not restart or replace the running gateway, which still serves them — next action: fix the underlying failure, then either put the entries back and retry: egresslock allow s389 revoke.example.test:8443; egresslock disallow s389 revoke.example.test:8443, or keep the removal and apply it: egresslock ensure s389"
S_P2W_389="disallow: warning: a plain 'egresslock ensure s389' will restart the gateway and apply the removal from $SRC389 — restore the entries first if that was not the intent."
S_P2U_389="disallow: nothing was revoked — the reinstall failed before the new allowlist was applied, and the allowlist could not be put back after a retry — state: the requested entries are no longer in $SRC389; gateway container state could not be determined (it may still be serving them) — next action: fix the underlying failure, then either put the entries back and retry: egresslock allow s389 revoke.example.test:8443; egresslock disallow s389 revoke.example.test:8443, or keep the removal and apply it: egresslock ensure s389"
S_P2R_389="disallow: the reinstall failed before the new allowlist was applied, and the allowlist could not be put back after a retry — state: the requested entries are no longer in $SRC389; gateway container '$GW389' removed by the failed apply's cleanup (it is not serving anything) — next action: fix the underlying failure, then apply the current configuration: egresslock ensure s389"
S_P2N_389="disallow: the reinstall failed before the new allowlist was applied, and the allowlist could not be put back after a retry — state: the requested entries are no longer in $SRC389; gateway container not running — next action: fix the underlying failure, then apply the current configuration: egresslock ensure s389"
S_P2S_389="disallow: the reinstall failed before the new allowlist was applied, and the allowlist could not be put back after a retry — state: the requested entries are no longer in $SRC389; gateway container '$GW389' still running (its removal failed) — next action: fix the underlying failure, then apply the current configuration: egresslock ensure s389"
S_P3_389="disallow: the new allowlist was written into the gateway's configuration, but the reinstall failed after that — state: the requested entries are no longer in $SRC389; the new allowlist is in the gateway's configuration — next action: fix the underlying failure, then apply the current configuration: egresslock ensure s389"
S_P3S_389="disallow: the gateway's configuration already matched the new allowlist (the reinstall skipped the apply), but the reinstall failed after that — state: the requested entries are no longer in $SRC389; the deployed configuration already matches the new allowlist — next action: fix the underlying failure, then apply the current configuration: egresslock ensure s389"
S_P3C_389="disallow: the new allowlist was written into the gateway's configuration, but the reinstall failed after that — state: the requested entries are no longer in $SRC389; gateway container '$GW389' removed by the failed reinstall's cleanup (it is not serving anything) — next action: fix the underlying failure, then apply the current configuration: egresslock ensure s389"
S_P3F_389="disallow: the new allowlist was written into the gateway's configuration, but the reinstall failed after that — state: the requested entries are no longer in $SRC389; gateway container '$GW389' still running (its removal failed) — next action: fix the underlying failure, then remove the gateway by hand: podman rm -f $GW389; then apply the current configuration: egresslock ensure s389"
S_P3N_389="disallow: the new allowlist was written into the gateway's configuration, but the reinstall failed after that — state: the requested entries are no longer in $SRC389; gateway container '$GW389' not running (its removal was not confirmed) — next action: fix the underlying failure, then apply the current configuration: egresslock ensure s389"
S_P5_389="disallow: the new allowlist was written into the gateway's configuration, but this run could not confirm the running gateway loaded it — state: the requested entries are no longer in $SRC389; the previous configuration may still be active — next action: run: egresslock ensure s389"
S_P5U_389="disallow: the new allowlist was written into the gateway's configuration, but this run could not confirm the running gateway loaded it — state: the requested entries are no longer in $SRC389; the gateway container state could not be determined; the previous configuration may still be active — next action: run: egresslock ensure s389"
S_NOTE_389="disallow: note: the failed reinstall removed containers it had started for profile 's389' — if the profile is not running now, start it again: egresslock ensure s389"

reset389
[[ -f "$STATE/running/$GW389" && -n "$(mock_group_file "$GW389" allowlist_p8443)" ]] \
    && e389 pass || e389 fail "setup: green ensure seeds the gateway and deployed files"
rm -rf "$S389/state-pristine"
cp -a "$STATE" "$S389/state-pristine"

# L1: parse die after the rewrite -> source byte-identical, deployed
# allowlist.* restored, the new port group the candidate introduced
# removed, no restart, S-P1, no removed:, and the documented retry
# re-attempts instead of dying `entry not present`. The removed entry
# shares p8443 with `stay.example.test:8443` (see the fixture comment),
# so the deployed p8443 cmp below really pins D2's rollback; p9443 did
# not exist deployed (staged before the parse die), so its absence
# really pins the not-existed removal.
reset389
printf 'new.example.test:9443\n' >> "$SRC389"
cp "$SRC389" "$S389/pre-source"
d1_domains="$(mock_group_file "$GW389" allowlist)"
d1_p8443="$(mock_group_file "$GW389" allowlist_p8443)"
n1_p9443="$(mock_group_name p9443 $'new.example.test\n')"
cp "$d1_domains" "$S389/pre-deploy.domains"
cp "$d1_p8443" "$S389/pre-deploy.p8443"
: > "$STATE/allowlist-invalid"
: > "$STATE/opslog"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/allowlist-invalid"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P1_389" <<<"$o" \
      && [[ "$o" != *"removed:"* && "$o" != *"removed container '$GW389'"* \
         && "$o" != *"$S_P1N_389"* && "$o" != *"$S_P1U_389"* \
         && "$o" != *"$S_P1R_389"* ]] \
      && ! grep -q '^podman restart' "$STATE/opslog"; then
    e389 pass
else
    e389 fail "L1 rc1 + S-P1 + no restart/removed (rc=$rc, out: $o)"
fi
cmp -s "$S389/pre-source" "$SRC389" \
    && e389 pass || e389 fail "L1 source restored byte-identical"
cmp -s "$S389/pre-deploy.domains" "$d1_domains" \
    && e389 pass || e389 fail "L1 deployed allowlist.domains untouched"
cmp -s "$S389/pre-deploy.p8443" "$d1_p8443" \
    && e389 pass || e389 fail "L1 deployed allowlist.p8443 untouched"
[[ ! -f "$DEP389/$n1_p9443" ]] \
    && e389 pass || e389 fail "L1 staged new group p9443 removed by the rollback"
o2="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc2=$?
if [[ "$rc2" == 0 && "$o2" == *"removed: revoke.example.test:8443"* ]] \
      && ! grep -qxF 'revoke.example.test:8443' "$SRC389"; then
    e389 pass
else
    e389 fail "L1 retry re-attempts and succeeds (rc=$rc2, out: $o2)"
fi

# L1u: restore succeeds but the container list fails at disclosure ->
# S-P1u. Unknown is not "not running" (D7): S-P1n must be absent.
reset389
cp "$SRC389" "$S389/pre-source1u"
: > "$STATE/allowlist-invalid"
: > "$STATE/ps-fails-late"
: > "$STATE/opslog"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/allowlist-invalid" "$STATE/ps-fails-late" "$STATE/ps-fails-active"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P1U_389" <<<"$o" \
      && [[ "$o" != *"$S_P1N_389"* && "$o" != *"$S_P1_389"* \
         && "$o" != *"$S_P1R_389"* && "$o" != *"removed:"* ]] \
      && cmp -s "$S389/pre-source1u" "$SRC389" \
      && [[ -f "$STATE/running/$GW389" ]] \
      && ! grep -q '^podman restart' "$STATE/opslog"; then
    e389 pass
else
    e389 fail "L1u restore-success + failed ps -> S-P1u, not S-P1n (rc=$rc, out: $o)"
fi

# L2: partial allowlist staging -> already-staged files restored, the
# not-yet-staged candidate restored/removed. Two new port groups are in
# the candidate: p9443 is staged before the p9555 copy fails, so its
# absence pins the rollback's not-existed removal (a missing rollback
# leaves it behind); the shared-group p8443 cmp pins byte restoration.
reset389
printf 'new.example.test:9443\nnewer.example.test:9555\n' >> "$SRC389"
cp "$SRC389" "$S389/pre-source2"
d2_domains="$(mock_group_file "$GW389" allowlist)"
d2_p8443="$(mock_group_file "$GW389" allowlist_p8443)"
n2_p9443="$(mock_group_name p9443 $'new.example.test\n')"
n2_p9555="$(mock_group_name p9555 $'newer.example.test\n')"
cp "$d2_domains" "$S389/pre-deploy2.domains"
cp "$d2_p8443" "$S389/pre-deploy2.p8443"
: > "$STATE/cp-stage-fails-$n2_p9555"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/cp-stage-fails-$n2_p9555"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P1_389" <<<"$o" \
      && [[ "$o" != *"removed:"* ]] \
      && ! grep -q '^podman restart' "$STATE/opslog"; then
    e389 pass
else
    e389 fail "L2 partial staging rc1 + S-P1 + no restart (rc=$rc, out: $o)"
fi
cmp -s "$S389/pre-source2" "$SRC389" \
    && e389 pass || e389 fail "L2 source restored byte-identical"
cmp -s "$S389/pre-deploy2.domains" "$d2_domains" \
    && e389 pass || e389 fail "L2 deployed domains untouched"
cmp -s "$S389/pre-deploy2.p8443" "$d2_p8443" \
    && e389 pass || e389 fail "L2 deployed p8443 untouched"
[[ ! -f "$DEP389/$n2_p9443" ]] \
    && e389 pass || e389 fail "L2 already-staged new group p9443 removed by the rollback"
[[ ! -f "$DEP389/$n2_p9555" ]] \
    && e389 pass || e389 fail "L2 failing new group p9555 never left staged"

# L3: candidate staging and swap failures -> the newly published
# content-addressed groups are removed, the private stage is gone,
# source restored, and the deployed refs are untouched. Both dice fire
# after every group copy, so the new p9443 group (absent before) is
# already in the live config dir: its absence pins the not-existed
# removal.
for l3_knob in cp-stage-fails-squid.conf mv-check-fails; do
    reset389
    printf 'new.example.test:9443\n' >> "$SRC389"
    cp "$SRC389" "$S389/pre-source3"
    d3_domains="$(mock_group_file "$GW389" allowlist)"
    d3_p8443="$(mock_group_file "$GW389" allowlist_p8443)"
    n3_p9443="$(mock_group_name p9443 $'new.example.test\n')"
    cp "$d3_domains" "$S389/pre-deploy3.domains"
    cp "$d3_p8443" "$S389/pre-deploy3.p8443"
    : > "$STATE/$l3_knob"
    o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
    rm -f "$STATE/$l3_knob"
    if [[ "$rc" == 1 ]] && grep -qxF "$S_P1_389" <<<"$o" \
          && [[ "$o" != *"removed:"* ]] \
          && [[ -z "$(compgen -G "$DEP389/.egresslock-stage.*")" ]]; then
        e389 pass
    else
        e389 fail "L3 $l3_knob rc1 + S-P1 + stage removed (rc=$rc, out: $o)"
    fi
    cmp -s "$S389/pre-source3" "$SRC389" \
        && e389 pass || e389 fail "L3 $l3_knob source restored"
    cmp -s "$S389/pre-deploy3.domains" "$d3_domains" \
        && e389 pass || e389 fail "L3 $l3_knob deployed domains untouched"
    cmp -s "$S389/pre-deploy3.p8443" "$d3_p8443" \
        && e389 pass || e389 fail "L3 $l3_knob deployed p8443 untouched"
    [[ ! -f "$DEP389/$n3_p9443" ]] \
        && e389 pass || e389 fail "L3 $l3_knob new group p9443 removed by the rollback"
done

# L4: snapshot probe error -> named die before any staging, source restored.
reset389
cp "$SRC389" "$S389/pre-source4"
d4_domains="$(mock_group_file "$GW389" allowlist)"
cp "$d4_domains" "$S389/pre-deploy4.domains"
: > "$STATE/exec-test-e-fails"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/exec-test-e-fails"
if [[ "$rc" == 1 && "$o" == *"gateway deployed-config probe failed"* ]] \
      && grep -qxF "$S_P1_389" <<<"$o" && [[ "$o" != *"removed:"* ]]; then
    e389 pass
else
    e389 fail "L4 snapshot probe error named + S-P1 (rc=$rc, out: $o)"
fi
cmp -s "$S389/pre-source4" "$SRC389" \
    && e389 pass || e389 fail "L4 source restored after the probe die"
cmp -s "$S389/pre-deploy4.domains" "$d4_domains" \
    && e389 pass || e389 fail "L4 deployed set untouched before staging"

# L4b: snapshot-copy failure (container -> host into $stage/prev) -> named
# snapshot die before any staging copy, source restored, deployed files
# unchanged, no restart.
reset389
cp "$SRC389" "$S389/pre-source4b"
d4b_domains="$(mock_group_file "$GW389" allowlist)"
d4b_p8443="$(mock_group_file "$GW389" allowlist_p8443)"
cp "$d4b_domains" "$S389/pre-deploy4b.domains"
cp "$d4b_p8443" "$S389/pre-deploy4b.p8443"
: > "$STATE/cp-snapshot-fails-$(basename "$d4b_domains")"
: > "$STATE/opslog"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/cp-snapshot-fails-$(basename "$d4b_domains")"
if [[ "$rc" == 1 && "$o" == *"gateway allowlist snapshot failed"* ]] \
      && grep -qxF "$S_P1_389" <<<"$o" && [[ "$o" != *"removed:"* ]] \
      && ! grep -q '^podman restart' "$STATE/opslog"; then
    e389 pass
else
    e389 fail "L4b snapshot-copy die named + S-P1 + no restart (rc=$rc, out: $o)"
fi
cmp -s "$S389/pre-source4b" "$SRC389" \
    && e389 pass || e389 fail "L4b source restored"
cmp -s "$S389/pre-deploy4b.domains" "$d4b_domains" \
    && e389 pass || e389 fail "L4b deployed domains untouched"
cmp -s "$S389/pre-deploy4b.p8443" "$d4b_p8443" \
    && e389 pass || e389 fail "L4b deployed p8443 untouched"
[[ -z "$(compgen -G "$DEP389/.egresslock-stage.*")" ]] \
    && e389 pass || e389 fail "L4b no container stage left"

# L5: rollback copy failure -> no ownership/disclosure misread; the
# deployed set is left as it stands (the shared-group p8443 stays the
# candidate's one-entry file — that is the accepted residual), and the
# source restore still decides the branch (S-P1 here).
reset389
cp "$SRC389" "$S389/pre-source5"
d5_p8443="$(mock_group_file "$GW389" allowlist_p8443)"
n5_p8443="$(mock_group_name p8443 $'stay.example.test\n')"
cp "$d5_p8443" "$S389/pre-deploy5.p8443"
: > "$STATE/allowlist-invalid"
: > "$STATE/rm-config-fails-$n5_p8443"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/allowlist-invalid" "$STATE/rm-config-fails-$n5_p8443"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P1_389" <<<"$o" \
      && [[ "$o" != *"removed:"* && "$o" != *"the new allowlist was written"* ]]; then
    e389 pass
else
    e389 fail "L5 rollback copy failure branches from the source restore (rc=$rc, out: $o)"
fi
cmp -s "$S389/pre-source5" "$SRC389" \
    && e389 pass || e389 fail "L5 source restored"
cmp -s "$S389/pre-deploy5.p8443" "$d5_p8443" \
    && e389 pass || e389 fail "L5 failed rollback left the deployed p8443 group untouched"
grep -qxF 'stay.example.test' "$DEP389/$n5_p8443" \
    && ! grep -qxF 'revoke.example.test' "$DEP389/$n5_p8443" \
    && e389 pass || e389 fail "L5 failed rollback leaves the new p8443 group (out of step, accepted residual)"

# L6: source restore failure on a running pre-existing gateway -> S-P2 +
# S-P2w, gateway not removed or restarted, entries absent from $src,
# deployed allowlist.* rolled back, no removed:. The restore-failure
# seam fires at the first staging copy (after the source rewrite and
# inside the apply), so the parse die below follows real staging and the
# deployed-file cmps really pin D2's rollback.
reset389
d6_domains="$(mock_group_file "$GW389" allowlist)"
d6_p8443="$(mock_group_file "$GW389" allowlist_p8443)"
cp "$d6_domains" "$S389/pre-deploy6.domains"
cp "$d6_p8443" "$S389/pre-deploy6.p8443"
: > "$STATE/allowlist-invalid"
printf '%s\n' "$S389" > "$STATE/proxy-source-restore-fails-cp"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
chmod 0755 "$S389"
rm -f "$STATE/allowlist-invalid" "$STATE/proxy-source-restore-fails-cp"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P2_389" <<<"$o" \
      && grep -qxF "$S_P2W_389" <<<"$o" \
      && [[ "$o" != *"removed:"* && "$o" != *"removed container '$GW389'"* ]] \
      && [[ "$o" != *"$S_P2U_389"* && "$o" != *"$S_P2N_389"* \
         && "$o" != *"$S_P2R_389"* && "$o" != *"$S_P2S_389"* ]] \
      && [[ -f "$STATE/running/$GW389" ]] \
      && ! grep -qxF 'revoke.example.test:8443' "$SRC389" \
      && ! grep -q '^podman restart' "$STATE/opslog"; then
    e389 pass
else
    e389 fail "L6 S-P2 + S-P2w + leave-serving (rc=$rc, out: $o)"
fi
cmp -s "$S389/pre-deploy6.domains" "$d6_domains" \
    && e389 pass || e389 fail "L6 deployed allowlist.domains untouched"
cmp -s "$S389/pre-deploy6.p8443" "$d6_p8443" \
    && e389 pass || e389 fail "L6 deployed allowlist.p8443 untouched"

# L6b: source restore failure with the gateway replaced by this run ->
# S-P2r (no S-P2w), the cleanup removed the replacement, no removed:.
reset389
rm -f "$STATE/running/$GW389"
: > "$STATE/allowlist-invalid"
printf '%s\n' "$S389" > "$STATE/proxy-source-restore-fails-cp"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
chmod 0755 "$S389"
rm -f "$STATE/allowlist-invalid" "$STATE/proxy-source-restore-fails-cp"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P2R_389" <<<"$o" \
      && [[ "$o" != *"$S_P2W_389"* && "$o" != *"removed:"* ]] \
      && [[ "$o" != *"$S_P2_389"* && "$o" != *"$S_P2N_389"* \
         && "$o" != *"$S_P2S_389"* && "$o" != *"$S_P2U_389"* ]] \
      && [[ ! -f "$STATE/running/$GW389" && ! -f "$STATE/containers/$GW389.net" ]]; then
    e389 pass
else
    e389 fail "L6b S-P2r + removed replacement (rc=$rc, out: $o)"
fi

# L6c: source restore failure, gateway not running and not owned ->
# S-P2n, no S-P2w.
reset389
rm -f "$STATE/running/$GW389"
printf '%s\n' "$S389" > "$STATE/nft/proxy-source-restore-fails"
o="$(run389dns disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
chmod 0755 "$S389"
rm -f "$STATE/nft/proxy-source-restore-fails"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P2N_389" <<<"$o" \
      && [[ "$o" != *"$S_P2W_389"* && "$o" != *"removed:"* ]] \
      && [[ "$o" != *"$S_P2_389"* && "$o" != *"$S_P2U_389"* \
         && "$o" != *"$S_P2R_389"* && "$o" != *"$S_P2S_389"* ]] \
      && [[ ! -f "$STATE/running/$GW389" ]]; then
    e389 pass
else
    e389 fail "L6c S-P2n (rc=$rc, out: $o)"
fi

# L6d: source restore failure, this run's replacement still running
# because cleanup removal failed -> S-P2s, no S-P2w, EGL-318 line present.
reset389
rm -f "$STATE/running/$GW389"
: > "$STATE/allowlist-invalid"
: > "$STATE/rm-container-fails"
printf '%s\n' "$S389" > "$STATE/proxy-source-restore-fails-cp"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
chmod 0755 "$S389"
rm -f "$STATE/allowlist-invalid" "$STATE/rm-container-fails" "$STATE/proxy-source-restore-fails-cp"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P2S_389" <<<"$o" \
      && [[ "$o" != *"$S_P2W_389"* && "$o" != *"removed:"* ]] \
      && [[ "$o" != *"$S_P2_389"* && "$o" != *"$S_P2N_389"* \
         && "$o" != *"$S_P2R_389"* && "$o" != *"$S_P2U_389"* ]] \
      && [[ "$o" == *"cleanup: removal failed:"* ]] \
      && [[ -f "$STATE/running/$GW389" ]]; then
    e389 pass
else
    e389 fail "L6d S-P2s + cleanup-failure line (rc=$rc, out: $o)"
fi
rm -f "$STATE/rm-container-fails"

# L6e: $src replaced by a directory at restore time -> the restore must
# refuse to move the backup into it, retain the backup, and select the
# restore-failure branch (S-P2 + S-P2w on the unowned running gateway).
reset389
cp "$SRC389" "$S389/pre-source6e"
: > "$STATE/allowlist-invalid"
printf '%s\n' "$SRC389" > "$STATE/replace-src-with-dir"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/allowlist-invalid" "$STATE/replace-src-with-dir"
bak="$(ls -1 "$S389"/s389-allowlist.egresslock-disallow-backup.* 2>/dev/null | head -n1)"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P2_389" <<<"$o" \
      && grep -qxF "$S_P2W_389" <<<"$o" \
      && [[ "$o" != *"$S_P1_389"* && "$o" != *"$S_P1U_389"* && "$o" != *"removed:"* ]] \
      && [[ -d "$SRC389" && -n "$bak" && -f "$bak" ]] \
      && [[ ! -e "$SRC389/$(basename "${bak:-none}")" ]] \
      && cmp -s "$S389/pre-source6e" "$bak"; then
    e389 pass
else
    e389 fail "L6e directory leaf: restore fails without swallowing the backup (rc=$rc, out: $o, backup: ${bak:-none})"
fi
rm -rf "$SRC389"

# L6f: source restore failure + failed container list, unowned pre-existing
# gateway -> S-P2u + S-P2w, never S-P2n (unknown is not "not running").
reset389
: > "$STATE/allowlist-invalid"
printf '%s\n' "$S389" > "$STATE/proxy-source-restore-fails-cp"
: > "$STATE/ps-fails-late"
: > "$STATE/opslog"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
chmod 0755 "$S389"
rm -f "$STATE/allowlist-invalid" "$STATE/proxy-source-restore-fails-cp" \
      "$STATE/ps-fails-late" "$STATE/ps-fails-active"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P2U_389" <<<"$o" \
      && grep -qxF "$S_P2W_389" <<<"$o" \
      && [[ "$o" != *"$S_P2N_389"* && "$o" != *"$S_P2_389"* \
         && "$o" != *"$S_P2R_389"* && "$o" != *"$S_P2S_389"* \
         && "$o" != *"removed:"* ]] \
      && [[ -f "$STATE/running/$GW389" ]] \
      && ! grep -q '^podman restart' "$STATE/opslog"; then
    e389 pass
else
    e389 fail "L6f restore-failure + failed ps -> S-P2u + S-P2w (rc=$rc, out: $o)"
fi

# L6g: source restore failure, this run's replacement owned, cleanup
# removal fails, container list fails -> S-P2s, never S-P2n.
reset389
rm -f "$STATE/running/$GW389"
: > "$STATE/allowlist-invalid"
: > "$STATE/rm-container-fails"
printf '%s\n' "$S389" > "$STATE/proxy-source-restore-fails-cp"
: > "$STATE/ps-fails-late"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
chmod 0755 "$S389"
rm -f "$STATE/allowlist-invalid" "$STATE/rm-container-fails" \
      "$STATE/proxy-source-restore-fails-cp" "$STATE/ps-fails-late" \
      "$STATE/ps-fails-active"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P2S_389" <<<"$o" \
      && [[ "$o" != *"$S_P2W_389"* && "$o" != *"removed:"* ]] \
      && [[ "$o" != *"$S_P2_389"* && "$o" != *"$S_P2N_389"* \
         && "$o" != *"$S_P2R_389"* && "$o" != *"$S_P2U_389"* ]] \
      && [[ "$o" == *"cleanup: removal failed:"* ]] \
      && [[ -f "$STATE/running/$GW389" ]]; then
    e389 pass
else
    e389 fail "L6g restore-failure + owned + failed ps -> S-P2s (rc=$rc, out: $o)"
fi
rm -f "$STATE/rm-container-fails"

# L7: committed restart/health failure -> no source restore, S-P3c, the
# EGL-217 cleanup removes the gateway.
reset389
: > "$STATE/probe-fails-$GW389"
o="$(PATH="$E389PATH" run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/probe-fails-$GW389" "$STATE/probe-fails-active-$GW389"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P3C_389" <<<"$o" \
      && [[ "$o" != *"removed:"* ]] \
      && [[ "$o" != *"$S_P3_389"* && "$o" != *"$S_P3S_389"* \
         && "$o" != *"$S_P3F_389"* && "$o" != *"$S_P3N_389"* ]] \
      && [[ ! -f "$STATE/running/$GW389" && ! -f "$STATE/containers/$GW389.net" ]] \
      && ! grep -qxF 'revoke.example.test:8443' "$SRC389"; then
    e389 pass
else
    e389 fail "L7 S-P3c + cleanup removed gateway (rc=$rc, out: $o)"
fi

# L8: committed verify failure -> no source restore, S-P3c: the
# post-swap-owned gateway is removed by the cleanup.
reset389
: > "$STATE/deployed-config-invalid"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/deployed-config-invalid"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P3C_389" <<<"$o" \
      && [[ "$o" == *"gateway verification failed"* && "$o" != *"removed:"* ]] \
      && [[ "$o" != *"$S_P3_389"* && "$o" != *"$S_P3S_389"* \
         && "$o" != *"$S_P3F_389"* && "$o" != *"$S_P3N_389"* ]] \
      && [[ ! -f "$STATE/running/$GW389" && ! -f "$STATE/containers/$GW389.net" ]] \
      && ! grep -qxF 'revoke.example.test:8443' "$SRC389"; then
    e389 pass
else
    e389 fail "L8 verify-failure S-P3c + cleanup removal (rc=$rc, out: $o)"
fi

# L8b: committed verify failure + failed container list at disclosure +
# failed cleanup removal -> owned + unknown stays conservative leftover
# (S-P3f), never S-P3n ("not running").
reset389
: > "$STATE/deployed-config-invalid"
: > "$STATE/rm-container-fails"
: > "$STATE/ps-fails-at-verify"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/deployed-config-invalid" "$STATE/rm-container-fails" \
      "$STATE/ps-fails-at-verify" "$STATE/ps-fails-active"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P3F_389" <<<"$o" \
      && [[ "$o" != *"$S_P3N_389"* && "$o" != *"$S_P3C_389"* \
         && "$o" != *"$S_P3S_389"* && "$o" != *"$S_P3_389"* \
         && "$o" != *"removed:"* ]] \
      && [[ "$o" == *"cleanup: removal failed:"* ]] \
      && [[ "$o" == *"gateway verification failed"* ]]; then
    e389 pass
else
    e389 fail "L8b committed verify + failed ps -> S-P3f, not S-P3n (rc=$rc, out: $o)"
fi
rm -f "$STATE/rm-container-fails"

# L9: converged skip is committed -> a later failure never restores the
# source and prints S-P3s, not S-P3.
reset389
sed -i '/^revoke\.example\.test:8443$/d' "$SRC389"
run389 ensure s389 >/dev/null 2>&1
printf 'revoke.example.test:8443\n' >> "$SRC389"
: > "$STATE/deployed-config-invalid"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/deployed-config-invalid"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P3S_389" <<<"$o" \
      && [[ "$o" != *"removed:"* ]] \
      && [[ "$o" != *"$S_P3_389"* && "$o" != *"$S_P3C_389"* \
         && "$o" != *"$S_P3F_389"* && "$o" != *"$S_P3N_389"* ]] \
      && [[ -f "$STATE/running/$GW389" ]] \
      && ! grep -qxF 'revoke.example.test:8443' "$SRC389"; then
    e389 pass
else
    e389 fail "L9 converged-skip S-P3s + no restore (rc=$rc, out: $o)"
fi

# L9b: converged skip then the gateway stops before disclosure -> still
# S-P3s, and the string makes no current-liveness claim (D7).
reset389
sed -i '/^revoke\.example\.test:8443$/d' "$SRC389"
run389 ensure s389 >/dev/null 2>&1
printf 'revoke.example.test:8443\n' >> "$SRC389"
: > "$STATE/deployed-config-invalid"
: > "$STATE/gateway-stops-at-verify"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/deployed-config-invalid" "$STATE/gateway-stops-at-verify"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P3S_389" <<<"$o" \
      && [[ "$o" != *"gateway container running"* ]] \
      && [[ "$o" != *"$S_P3_389"* && "$o" != *"$S_P3C_389"* \
         && "$o" != *"$S_P3F_389"* && "$o" != *"$S_P3N_389"* ]] \
      && [[ ! -f "$STATE/running/$GW389" ]] \
      && ! grep -qxF 'revoke.example.test:8443' "$SRC389"; then
    e389 pass
else
    e389 fail "L9b converged-skip + stopped gateway -> S-P3s, no liveness claim (rc=$rc, out: $o)"
fi

# L10: multi-entry success -> every entry removed, all `removed:` lines
# after the ready lines (D6), one re-ensuring.
reset389
printf 'revoke2.example.test:9443\n' >> "$SRC389"
run389 ensure s389 >/dev/null 2>&1
o="$(run389 disallow s389 revoke.example.test:8443 revoke2.example.test:9443 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$(grep -c '^re-ensuring profile' <<<"$o")" == 1 \
      && "$o" == *"removed: revoke.example.test:8443"* \
      && "$o" == *"removed: revoke2.example.test:9443"* \
      && "$(e389_order "$o" "profile 's389' ready" "removed: revoke.example.test:8443")" == 1 \
      && "$(e389_order "$o" "profile 's389' ready" "removed: revoke2.example.test:9443")" == 1 ]] \
      && ! grep -qxF 'revoke.example.test:8443' "$SRC389" \
      && ! grep -qxF 'revoke2.example.test:9443' "$SRC389"; then
    e389 pass
else
    e389 fail "L10 multi-entry success + removed:-last (rc=$rc, out: $o)"
fi

# L11: success path (single entry) -> path line, removed after ready, no
# disclosure, then the retry is the named absent entry.
reset389
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"path: proxy — gateway allowlist $SRC389"* \
      && "$(e389_order "$o" "path: proxy" "re-ensuring profile 's389'" )" == 1 \
      && "$(e389_order "$o" "profile 's389' ready" "removed: revoke.example.test:8443")" == 1 \
      && "$o" != *"disallow: nothing was revoked"* ]] \
      && ! grep -qxF 'revoke.example.test:8443' "$SRC389"; then
    e389 pass
else
    e389 fail "L11 success order + removed:-last (rc=$rc, out: $o)"
fi
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"entry not present: revoke.example.test:8443 (proxy path)"* ]] \
    && e389 pass || e389 fail "L11 absent-entry retry rc1 (rc=$rc, out: $o)"

# L12: absent entry -> rc 1, no mutation, no disclosure, no re-ensure.
reset389
cp "$SRC389" "$S389/pre-source12"
: > "$STATE/opslog"
o="$(run389 disallow s389 absent.example.test 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"entry not present: absent.example.test (proxy path)"* ]] \
      && [[ "$o" != *"disallow: nothing was revoked"* && "$o" != *"re-ensuring"* ]] \
      && cmp -s "$S389/pre-source12" "$SRC389" \
      && ! grep -q '^podman restart' "$STATE/opslog"; then
    e389 pass
else
    e389 fail "L12 absent entry mutates nothing (rc=$rc, out: $o)"
fi

# L13: restore-success pre-activation failure with the gateway container
# not running -> S-P1n (gw_running false; no ownership).
reset389
rm -f "$STATE/running/$GW389"
o="$(run389dns disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
if [[ "$rc" == 1 ]] && grep -qxF "$S_P1N_389" <<<"$o" \
      && [[ "$o" != *"removed:"* ]] \
      && [[ "$o" != *"$S_P1_389"* && "$o" != *"$S_P1U_389"* \
         && "$o" != *"$S_P1R_389"* ]] \
      && [[ ! -f "$STATE/running/$GW389" ]] \
      && cmp -s "$S389/s389-allowlist" "$SRC389"; then
    e389 pass
else
    e389 fail "L13 S-P1n restore-success/not-running (rc=$rc, out: $o)"
fi

# L14: restore-success pre-activation failure with a replacement this run
# started -> cleanup removes it: S-P1r + the D4(a) anchor note (the anchor
# was replaced too).
reset389
rm -f "$STATE/running/$GW389" "$STATE/running/egresslock-anchor-s389"
cp "$SRC389" "$S389/pre-source14"
: > "$STATE/allowlist-invalid"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/allowlist-invalid"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P1R_389" <<<"$o" \
      && grep -qxF "$S_NOTE_389" <<<"$o" \
      && [[ "$o" != *"removed:"* ]] \
      && [[ "$o" != *"$S_P1_389"* && "$o" != *"$S_P1N_389"* \
         && "$o" != *"$S_P1U_389"* ]] \
      && [[ ! -f "$STATE/running/$GW389" && ! -f "$STATE/containers/$GW389.net" \
         && ! -f "$STATE/running/egresslock-anchor-s389" ]] \
      && cmp -s "$S389/pre-source14" "$SRC389"; then
    e389 pass
else
    e389 fail "L14 S-P1r + anchor note + cleanup (rc=$rc, out: $o)"
fi

# L15: post-publication health failure (activation unproven) plus a
# cleanup-removal failure -> the single S-P5 running/indeterminate body,
# never the old pre-activation S-P3f claim, never "nothing was revoked",
# and never a started-by-this-attempt / enforcement claim.
reset389
: > "$STATE/probe-fails-$GW389"
: > "$STATE/rm-container-fails"
o="$(PATH="$E389PATH" run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/probe-fails-$GW389" "$STATE/probe-fails-active-$GW389" "$STATE/rm-container-fails"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P5_389" <<<"$o" \
      && [[ "$o" == *"cleanup: removal failed:"* && "$o" != *"removed:"* ]] \
      && [[ "$o" != *"$S_P1_389"* && "$o" != *"nothing was revoked"* ]] \
      && [[ "$o" != *"started by this attempt"* \
         && "$o" != *"not the entries this reinstall removed"* ]] \
      && [[ "$o" != *"$S_P3_389"* && "$o" != *"$S_P3C_389"* \
         && "$o" != *"$S_P3F_389"* && "$o" != *"$S_P3N_389"* \
         && "$o" != *"$S_P3S_389"* ]] \
      && [[ -f "$STATE/running/$GW389" ]]; then
    e389 pass
else
    e389 fail "L15 S-P5 + cleanup-failure line (rc=$rc, out: $o)"
fi
rm -f "$STATE/rm-container-fails"

# L15b: a pre-existing running gateway's restart fails at the stop phase;
# the old instance survives (old live config/ACL) while publication is
# committed but activation unproven. The same single S-P5 body prints —
# ENSURE_OWNED is not a selector and the text never says this attempt
# started the gateway (F1).
reset389
live_before="$(e389_hash "$STATE/containers-$GW389.live")"
: > "$STATE/restart-stop-fails-$GW389"
: > "$STATE/rm-container-fails"
o="$(PATH="$E389PATH" run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/restart-stop-fails-$GW389" "$STATE/rm-container-fails"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P5_389" <<<"$o" \
      && [[ "$o" == *"cleanup: removal failed:"* && "$o" != *"removed:"* ]] \
      && [[ "$o" != *"started by this attempt"* \
         && "$o" != *"not the entries this reinstall removed"* ]] \
      && [[ -f "$STATE/running/$GW389" ]] \
      && [[ "$(e389_hash "$STATE/containers-$GW389.live")" == "$live_before" ]] \
      && [[ ! -e "$DEP389/.egresslock-activated" ]] \
      && ! grep -qxF 'revoke.example.test:8443' "$SRC389"; then
    e389 pass
else
    e389 fail "L15b pre-existing restart-stop-fail keeps old live instance + same S-P5 (rc=$rc, live=$(e389_hash "$STATE/containers-$GW389.live")/$live_before out: $o)"
fi

# L15c: this run starts the container (ENSURE_OWNED contains it) and
# publication is committed but activation unproven. The same single S-P5
# body prints — never "started by this attempt" and never a claim about
# which entries the live instance enforces.
reset389
rm -f "$STATE/running/$GW389"
: > "$STATE/restart-stop-fails-$GW389"
: > "$STATE/rm-container-fails"
o="$(PATH="$E389PATH" run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/restart-stop-fails-$GW389" "$STATE/rm-container-fails"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P5_389" <<<"$o" \
      && [[ "$o" == *"cleanup: removal failed:"* && "$o" != *"removed:"* ]] \
      && [[ "$o" != *"started by this attempt"* \
         && "$o" != *"not the entries this reinstall removed"* ]] \
      && grep -q '^podman run .*--name egresslock-gateway-s389' "$STATE/opslog" \
      && [[ -f "$STATE/running/$GW389" ]] \
      && [[ ! -e "$DEP389/.egresslock-activated" ]] \
      && ! grep -qxF 'revoke.example.test:8443' "$SRC389"; then
    e389 pass
else
    e389 fail "L15c this-run-started container uses the same S-P5 body (rc=$rc, out: $o)"
fi

# L15d: committed but activation unproven with a failed container list at
# disclosure -> the S-P5 unknown-state body, not the running/indeterminate
# one and not the pre-activation S-P3 variants.
reset389
: > "$STATE/probe-fails-$GW389"
: > "$STATE/rm-container-fails"
: > "$STATE/ps-fails-late"
o="$(PATH="$E389PATH" run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/probe-fails-$GW389" "$STATE/probe-fails-active-$GW389" \
      "$STATE/rm-container-fails" "$STATE/ps-fails-late" "$STATE/ps-fails-active"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P5U_389" <<<"$o" \
      && [[ "$o" == *"cleanup: removal failed:"* && "$o" != *"removed:"* ]] \
      && [[ "$o" != *"$S_P5_389"* && "$o" != *"nothing was revoked"* ]] \
      && [[ "$o" != *"started by this attempt"* \
         && "$o" != *"not the entries this reinstall removed"* ]] \
      && [[ "$o" != *"$S_P3_389"* && "$o" != *"$S_P3C_389"* \
         && "$o" != *"$S_P3F_389"* && "$o" != *"$S_P3N_389"* \
         && "$o" != *"$S_P3S_389"* ]] \
      && [[ -f "$STATE/running/$GW389" ]]; then
    e389 pass
else
    e389 fail "L15d S-P5 unknown-observation body (rc=$rc, out: $o)"
fi

# L16: committed, the container vanished before the restart -> owned but
# not registered, cleanup skips: S-P3n.
reset389
: > "$STATE/restart-vanishes-$GW389"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/restart-vanishes-$GW389"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P3N_389" <<<"$o" \
      && [[ "$o" != *"removed:"* ]] \
      && [[ "$o" != *"$S_P3_389"* && "$o" != *"$S_P3C_389"* \
         && "$o" != *"$S_P3F_389"* && "$o" != *"$S_P3S_389"* ]] \
      && [[ ! -f "$STATE/running/$GW389" && ! -f "$STATE/containers/$GW389.net" ]]; then
    e389 pass
else
    e389 fail "L16 S-P3n vanished-before-restart (rc=$rc, out: $o)"
fi

# L17: symlinked source -> a failed apply restores the link itself (same
# target), never a regular file over the operator's symlink.
reset389
mv "$SRC389" "$S389/real-allowlist"
ln -s "$S389/real-allowlist" "$SRC389"
cp "$S389/real-allowlist" "$S389/pre-real17"
: > "$STATE/allowlist-invalid"
o="$(run389 disallow s389 revoke.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/allowlist-invalid"
if [[ "$rc" == 1 ]] && grep -qxF "$S_P1_389" <<<"$o" \
      && [[ "$o" != *"removed:"* ]] \
      && [[ "$o" != *"$S_P1N_389"* && "$o" != *"$S_P1U_389"* ]] \
      && [[ -L "$SRC389" && "$(readlink "$SRC389")" == "$S389/real-allowlist" ]]; then
    e389 pass
else
    e389 fail "L17 symlink restored as the link (rc=$rc, out: $o, type: $(stat -c %F "$SRC389" 2>/dev/null))"
fi
cmp -s "$S389/pre-real17" "$S389/real-allowlist" \
    && e389 pass || e389 fail "L17 symlink target unchanged"

chmod 0755 "$S389" 2>/dev/null || true
run389 teardown s389 >/dev/null 2>&1 || true
rm -f "$STATE"/restart-vanishes-* "$STATE"/cp-stage-fails-* \
      "$STATE"/cp-snapshot-fails-* "$STATE"/cp-restore-fails-* \
      "$STATE"/exec-test-e-fails* "$STATE"/probe-fails* "$STATE"/ps-fails* \
      "$STATE/replace-src-with-dir" "$STATE/gateway-stops-at-verify" \
      "$STATE/nft/proxy-source-restore-fails" "$STATE/proxy-source-restore-fails-cp" \
      "$STATE/nft/confdir-unwritable"*
rm -rf "$S389/s389-allowlist" "$S389"/s389-allowlist.egresslock-disallow-backup.*
section_end egl389


# --- EGL-395: content-addressed publication + activation witness ---------
# Staged, deployed and live state are independent in the mock: the
# deployed cfg dir is $STATE/containers-<gw>.cfg/, the staged candidate is
# observed at $STATE/containers-<gw>.candidate, and a restart copies the
# deployed bytes to $STATE/containers-<gw>.live. Group basenames carry a
# SHA-256 and are resolved from the deployed squid.conf, never hard-coded.
section_begin egl395 "EGL-395 content-addressed gateway publication"
e395() { assert "$@"; }

S395="$TESTROOT/s395"; rm -rf "$S395"; mkdir -p "$S395"
cat > "$S395/s395.conf" <<'EOF'
profile s395 10.199.150.0/24
    rule gateway-only
    gateway 10.199.150.2 3128 s395-allowlist
EOF
printf 'keep.example.test\nshare.example.test:8443\nold.example.test:8443\n' > "$S395/s395-allowlist"
cat > "$S395/s395u.conf" <<'EOF'
profile s395u 10.199.151.0/24
    rule gateway-only
    gateway 10.199.151.2 3128 s395u-allowlist
EOF
printf 'safe.example.test:8443\nother.example.test:8443\n' > "$S395/s395u-allowlist"
cat > "$S395/s395l.conf" <<'EOF'
profile s395l 10.199.152.0/24
    rule gateway-only
    gateway 10.199.152.2 3128 s395l-allowlist
EOF
printf 'layout.example.test\n' > "$S395/s395l-allowlist"
: > "$STATE/images/localhost_egresslock-gateway_latest"
mkdir -p "$TESTROOT/bin-nosleep395"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTROOT/bin-nosleep395/sleep"
chmod +x "$TESTROOT/bin-nosleep395/sleep"
E395PATH="$TESTROOT/bin-nosleep395:$PATH"
run395() { env PATH="$E395PATH" ARCMOCK_PASSWD_HOME="$(conf_home "$S395/s395.conf")" \
    HOME="$S395" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run395u() { env PATH="$E395PATH" ARCMOCK_PASSWD_HOME="$(conf_home "$S395/s395u.conf")" \
    HOME="$S395" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run395l() { env PATH="$E395PATH" ARCMOCK_PASSWD_HOME="$(conf_home "$S395/s395l.conf")" \
    HOME="$S395" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
cat > "$S395/s395x.conf" <<'EOF'
profile s395x 10.199.153.0/24
    rule gateway-only
    gateway 10.199.153.2 3128 s395x-allowlist
EOF
printf 'keepx.example.test\n' > "$S395/s395x-allowlist"
cat > "$S395/s395y.conf" <<'EOF'
profile s395y 10.199.154.0/24
    rule gateway-only
    gateway 10.199.154.2 3128 s395y-allowlist
EOF
printf 'ready.example.test\n' > "$S395/s395y-allowlist"
cat > "$S395/s395z.conf" <<'EOF'
profile s395z 10.199.155.0/24
    rule gateway-only
    gateway 10.199.155.2 3128 s395z-allowlist
EOF
printf 'zkeep.example.test\nzgone.example.test\nzvanish.example.test\n' > "$S395/s395z-allowlist"
cat > "$S395/s395r.conf" <<'EOF'
profile s395r 10.199.156.0/24
    rule gateway-only
    gateway 10.199.156.2 3128 s395r-allowlist
EOF
printf 'rkeep.example.test\nrremove.example.test\n' > "$S395/s395r-allowlist"
run395x() { env PATH="$E395PATH" ARCMOCK_PASSWD_HOME="$(conf_home "$S395/s395x.conf")" \
    HOME="$S395" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run395y() { env PATH="$E395PATH" ARCMOCK_PASSWD_HOME="$(conf_home "$S395/s395y.conf")" \
    HOME="$S395" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run395z() { env PATH="$E395PATH" ARCMOCK_PASSWD_HOME="$(conf_home "$S395/s395z.conf")" \
    HOME="$S395" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run395r() { env PATH="$E395PATH" ARCMOCK_PASSWD_HOME="$(conf_home "$S395/s395r.conf")" \
    HOME="$S395" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
GW395=egresslock-gateway-s395
cfg395="$STATE/containers-$GW395.cfg"
GW395U=egresslock-gateway-s395u
cfg395U="$STATE/containers-$GW395U.cfg"
GW395l=egresslock-gateway-s395l
cfg395l="$STATE/containers-$GW395l.cfg"
GW395X=egresslock-gateway-s395x
cfg395X="$STATE/containers-$GW395X.cfg"
GW395Y=egresslock-gateway-s395y
cfg395Y="$STATE/containers-$GW395Y.cfg"
GW395Z=egresslock-gateway-s395z
cfg395Z="$STATE/containers-$GW395Z.cfg"
GW395R=egresslock-gateway-s395r
cfg395R="$STATE/containers-$GW395R.cfg"
H395U="$(conf_home "$S395/s395u.conf")"
SRC395U="$H395U/.config/egresslock/s395u-allowlist"
H395X="$(conf_home "$S395/s395x.conf")"
SRC395X="$H395X/.config/egresslock/s395x-allowlist"
H395Y="$(conf_home "$S395/s395y.conf")"
SRC395Y="$H395Y/.config/egresslock/s395y-allowlist"
H395Z="$(conf_home "$S395/s395z.conf")"
SRC395Z="$H395Z/.config/egresslock/s395z-allowlist"
H395R="$(conf_home "$S395/s395r.conf")"
SRC395R="$H395R/.config/egresslock/s395r-allowlist"

sq_hash() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
sp4_395() { # <profile> <src> <entries> -> running/indeterminate S-P4 line
    local p="$1" s="$2" e="$3"
    printf 'disallow: the reinstall could not confirm whether the new configuration was published — state: the requested entries are no longer in %s; the deployed configuration may or may not have been replaced; the previous configuration may still be active — next action: inspect the gateway, then either put the entries back and retry: egresslock allow %s %s; egresslock disallow %s %s, or keep the removal and apply it: egresslock ensure %s\n' \
        "$s" "$p" "$e" "$p" "$e" "$p"
}
sp4_removed_395() { # <profile> <src> <gwname> -> removed S-P4 line (entries unused)
    local p="$1" s="$2" g="$3"
    printf 'disallow: the reinstall could not confirm whether the new configuration was published — state: the requested entries are no longer in %s; gateway container '\''%s'\'' was removed (it is not serving anything) — next action: inspect the gateway, then apply the current configuration: egresslock ensure %s\n' \
        "$s" "$g" "$p"
}
sp4_notrunning_395() { # <profile> <src> <entries> -> not-running S-P4 line
    local p="$1" s="$2"
    printf 'disallow: the reinstall could not confirm whether the new configuration was published — state: the requested entries are no longer in %s; gateway container not running — next action: inspect the gateway, then apply the current configuration: egresslock ensure %s\n' \
        "$s" "$p"
}
sp4_unknown_395() { # <profile> <src> <entries> -> indeterminate-observation S-P4 line
    local p="$1" s="$2" e="$3"
    printf 'disallow: the reinstall could not confirm whether the new configuration was published — state: the requested entries are no longer in %s; the deployed configuration may or may not have been replaced; the gateway container state could not be determined; the previous configuration may still be active — next action: inspect the gateway, then either put the entries back and retry: egresslock allow %s %s; egresslock disallow %s %s, or keep the removal and apply it: egresslock ensure %s\n' \
        "$s" "$p" "$e" "$p" "$e" "$p"
}
w395_ok() { # <cfgdir> <gwname> <expected-generation> — exact four-line witness
    local cfg="$1" gw="$2" gen="$3" w="$1/.egresslock-activated" cid started
    [[ -f "$w" && ! -L "$w" ]] || return 1
    [[ "$(wc -l < "$w" | tr -d ' ')" == 4 ]] || return 1
    [[ "$(sed -n '1p' "$w")" == "format=1" ]] || return 1
    [[ "$(sed -n '2p' "$w")" == "generation=$gen" ]] || return 1
    cid="$(cat "$STATE/containers-$gw.id" 2>/dev/null)" || return 1
    started="$(cat "$STATE/containers-$gw.started" 2>/dev/null)" || return 1
    [[ -n "$cid" && "$(sed -n '3p' "$w")" == "container=$cid" ]] || return 1
    [[ -n "$started" && "$(sed -n '4p' "$w")" == "started=$started" ]]
}
restart_count() { grep -c '^podman restart ' "$STATE/opslog" 2>/dev/null || true; }

# L1: content-addressed generation. Every non-empty group is a regular
# file named allowlist.<kind>.<sha256-of-exact-bytes>, the deployed
# squid.conf references those exact basenames under the detected cfgdir,
# and no fixed name or stage temp survives a successful apply.
o="$(run395 ensure s395 2>&1)"; rc=$?
sq395="$cfg395/squid.conf"
dom395="$(mock_group_file "$GW395" allowlist)"
p395="$(mock_group_file "$GW395" allowlist_p8443)"
if [[ "$rc" == 0 && "$o" == *"allowlist applied, health verified"* && -f "$sq395" ]]; then
    e395 pass
else
    e395 fail "L1 initial apply (rc=$rc, out: $o)"
fi
if [[ -n "$dom395" && -f "$dom395" && ! -L "$dom395" \
      && "$(basename "$dom395")" =~ ^allowlist\.domains\.[0-9a-f]{64}$ \
      && "$(basename "$dom395")" == "allowlist.domains.$(sq_hash "$dom395")" \
      && "$(cat "$dom395")" == "keep.example.test" ]]; then
    e395 pass
else
    e395 fail "L1 domains group content-addressed (file: ${dom395:-none})"
fi
if [[ -n "$p395" && -f "$p395" && ! -L "$p395" \
      && "$(basename "$p395")" =~ ^allowlist\.p8443\.[0-9a-f]{64}$ \
      && "$(basename "$p395")" == "allowlist.p8443.$(sq_hash "$p395")" \
      && "$(cat "$p395")" == $'share.example.test\nold.example.test' ]]; then
    e395 pass
else
    e395 fail "L1 p8443 group content-addressed (file: ${p395:-none})"
fi
if grep -qxF "acl allowlist dstdomain -n \"$(mock_cfg_ref "$GW395" allowlist)\"" "$sq395" \
      && grep -qxF "acl allowlist_p8443 dstdomain -n \"$(mock_cfg_ref "$GW395" allowlist_p8443)\"" "$sq395"; then
    e395 pass
else
    e395 fail "L1 squid.conf references the exact deployed group names"
fi
if [[ "$(compgen -G "$cfg395/allowlist.domains.*" | wc -l | tr -d ' ')" == 1 \
      && "$(compgen -G "$cfg395/allowlist.p8443.*" | wc -l | tr -d ' ')" == 1 \
      && ! -e "$cfg395/allowlist.domains" && ! -e "$cfg395/allowlist.p8443" \
      && ! -e "$cfg395/.allowlist.domains.tmp" && ! -e "$cfg395/check.conf" ]]; then
    e395 pass
else
    e395 fail "L1 exactly one name per group; no fixed names/check.conf"
fi
if [[ -z "$(compgen -G "$cfg395/.egresslock-stage.*")" ]]; then
    e395 pass
else
    e395 fail "L1 successful apply leaves no container stage"
fi
if w395_ok "$cfg395" "$GW395" "$(sq_hash "$sq395")"; then
    e395 pass
else
    e395 fail "L1 activation witness binds the deployed generation to this instance"
fi

# L2: warm ensure skips only with a valid witness; skips do not restart.
: > "$STATE/opslog"
o="$(run395 ensure s395 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"already converged, not restarted"* \
      && "$o" != *"allowlist applied"* && "$(restart_count)" == 0 ]]; then
    e395 pass
else
    e395 fail "L2 witness-proven skip (rc=$rc, restarts=$(restart_count), out: $o)"
fi

# L3: an unchanged group is reused (same inode/name), never re-published;
# a genuinely new group is published through the private stage with a
# no-clobber link, and only that new name appears.
dom395_name="$(basename "$dom395")"
dom395_ino="$(stat -c %i "$dom395")"
printf 'newport.example.test:9444\n' >> "$S395/s395-allowlist"
: > "$STATE/opslog"
o="$(run395 ensure s395 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* \
      && "$(basename "$dom395")" == "$dom395_name" \
      && "$(stat -c %i "$dom395")" == "$dom395_ino" \
      && "$(compgen -G "$cfg395/allowlist.domains.*" | wc -l | tr -d ' ')" == 1 ]]; then
    e395 pass
else
    e395 fail "L3 identical group reused in place (rc=$rc, out: $o)"
fi
new9444="$(mock_group_file "$GW395" allowlist_p9444)"
if [[ -n "$new9444" && -f "$new9444" \
      && "$(basename "$new9444")" == "allowlist.p9444.$(sq_hash "$new9444")" \
      && "$(cat "$new9444")" == "newport.example.test" ]] \
      && grep -q "exec $GW395 ln -T /etc/squid/egresslock/\.egresslock-stage\..*/$(basename "$new9444") /etc/squid/egresslock/$(basename "$new9444")" "$STATE/execlog"; then
    e395 pass
else
    e395 fail "L3 new group published by no-clobber ln -T from the private stage"
fi

# L4: unsafe publication targets fail closed before the config mutation and
# leave the old deployed refs, old witness and old squid.conf untouched.
# (a) a symlink at the expected new name; (b) a directory; (c) wrong bytes.
printf 'danger.example.test\n' >> "$S395/s395u-allowlist"
o="$(run395u ensure s395u 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]]; then
    e395 pass
else
    e395 fail "L4 setup apply s395u (rc=$rc, out: $o)"
fi
u_sq="$cfg395U/squid.conf"
u_sq_before="$(sq_hash "$u_sq")"
u_p="$(mock_group_file "$GW395U" allowlist_p8443)"
u_p_before="$(sq_hash "$u_p")"
u_w_before="$(cat "$cfg395U/.egresslock-activated" 2>/dev/null)"
# Exercise the unsafe targets on a name this source does not deploy
# yet: the already-deployed danger group must stay untouched (it is a
# real old reference, not a shape fixture).
printf 'safe.example.test:8443\nother.example.test:8443\nshape.example.test\n' \
    > "$S395/s395u-allowlist"
exp_dom_u="$(mock_group_name domains $'shape.example.test\n')"
for u_shape in symlink dir wrongbytes; do
    rm -rf "$cfg395U/$exp_dom_u"
    case "$u_shape" in
        symlink) ln -s /etc/passwd "$cfg395U/$exp_dom_u" ;;
        dir)     mkdir "$cfg395U/$exp_dom_u" ;;
        wrongbytes) printf 'junk\n' > "$cfg395U/$exp_dom_u" ;;
    esac
    o="$(run395u ensure s395u 2>&1)"; rc=$?
    if [[ "$rc" == 1 && "$(sq_hash "$u_sq")" == "$u_sq_before" \
          && "$(sq_hash "$u_p")" == "$u_p_before" ]]; then
        e395 pass
    else
        e395 fail "L4 $u_shape leaves squid.conf/refs untouched (rc=$rc, out: $o)"
    fi
    if [[ "$u_shape" == wrongbytes ]]; then
        [[ "$o" == *"an existing content-addressed file has different bytes"* ]] \
            && e395 pass || e395 fail "L4 wrong-bytes refusal names the cause (out: $o)"
    else
        [[ "$o" == *"exists but is not a regular file (symbolic link, directory, or other type)"* \
           && "$o" == *"nothing was replaced"* ]] \
            && e395 pass || e395 fail "L4 $u_shape refusal names the unsafe type (out: $o)"
    fi
    if [[ "$(cat "$cfg395U/.egresslock-activated" 2>/dev/null)" == "$u_w_before" ]]; then
        e395 pass
    else
        e395 fail "L4 $u_shape leaves the old activation witness intact"
    fi
done
rm -rf "$cfg395U/$exp_dom_u"
printf 'safe.example.test:8443\nother.example.test:8443\ndanger.example.test\n' \
    > "$S395/s395u-allowlist"

# L5: a staging/parse failure after group publication removes only this
# run's new names/stage and leaves the old config, old refs and old
# witness valid, so the next ensure still skips.
u_w_before="$(cat "$cfg395U/.egresslock-activated" 2>/dev/null)"
printf 'new.example.test:9443\n' >> "$S395/s395u-allowlist"
exp_p_u="$(mock_group_name p9443 $'new.example.test\n')"
for l5_knob in "cp-stage-fails-$exp_p_u" allowlist-invalid; do
    : > "$STATE/$l5_knob"
    o="$(run395u ensure s395u 2>&1)"; rc=$?
    rm -f "$STATE/$l5_knob"
    if [[ "$rc" == 1 && "$(sq_hash "$u_sq")" == "$u_sq_before" \
          && "$(sq_hash "$u_p")" == "$u_p_before" \
          && ! -e "$cfg395U/$exp_p_u" \
          && -z "$(compgen -G "$cfg395U/.egresslock-stage.*")" \
          && "$(cat "$cfg395U/.egresslock-activated" 2>/dev/null)" == "$u_w_before" ]]; then
        e395 pass
    else
        e395 fail "L5 $l5_knob pre-publication failure keeps old set+witness (rc=$rc, sq=$(sq_hash "$u_sq")/$u_sq_before p=$(sq_hash "$u_p")/$u_p_before new=$([ -e "$cfg395U/$exp_p_u" ] && echo present || echo absent) stage=$(compgen -G "$cfg395U/.egresslock-stage.*" | tr '\n' ',') w=$([ -f "$cfg395U/.egresslock-activated" ] && echo yes || echo no) out: $o)"
    fi
done
printf 'safe.example.test:8443\nother.example.test:8443\ndanger.example.test\n' > "$S395/s395u-allowlist"
: > "$STATE/opslog"
o="$(run395u ensure s395u 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"already converged, not restarted"* && "$(restart_count)" == 0 \
      && "$(cat "$cfg395U/.egresslock-activated" 2>/dev/null)" == "$u_w_before" ]]; then
    e395 pass
else
    e395 fail "L5 old witness still proves the old generation after the failure (rc=$rc, w=$([ -f "$cfg395U/.egresslock-activated" ] && cat "$cfg395U/.egresslock-activated" | tr '\n' '|' || echo MISSING), out: $o)"
fi

# L5b: a deployed-config shape probe that errors (rc 125) is a failed
# probe, never "not a symlink": the apply aborts before publication and
# the old config + witness remain. The next ensure applies the kept
# source entry normally.
printf 'probe.example.test:9452\n' >> "$S395/s395u-allowlist"
u_sq_before="$(sq_hash "$u_sq")"
u_w_before="$(cat "$cfg395U/.egresslock-activated" 2>/dev/null)"
: > "$STATE/exec-test-L-fails-deployed"
o="$(run395u ensure s395u 2>&1)"; rc=$?
rm -f "$STATE/exec-test-L-fails-deployed"
if [[ "$rc" == 1 && "$o" == *"gateway deployed-config probe failed (podman exec test -L"* \
      && "$(sq_hash "$u_sq")" == "$u_sq_before" \
      && "$(cat "$cfg395U/.egresslock-activated" 2>/dev/null)" == "$u_w_before" ]]; then
    e395 pass
else
    e395 fail "L5b test -L probe error fails closed before publication (rc=$rc, sq=$(sq_hash "$u_sq")/$u_sq_before w=$([ -f "$cfg395U/.egresslock-activated" ] && echo yes || echo no), out: $o)"
fi
o="$(run395u ensure s395u 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395U" "$GW395U" "$(sq_hash "$u_sq")"; then
    e395 pass
else
    e395 fail "L5b next ensure applies the kept entry + records the witness (rc=$rc, out: $o)"
fi

# L6: the rename lands but its client result is lost -> bounded read-back
# proves publication, the apply continues (S-P6), the source is NOT
# restored, and the new witness matches the new deployed generation.
old_p395="$p395"
: > "$STATE/opslog"
: > "$STATE/mv-lost-result-landed"
o="$(run395 disallow s395 old.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/mv-lost-result-landed"
sq_after6="$(sq_hash "$sq395")"
if [[ "$rc" == 0 && "$o" == *"gateway: note: podman reported an error while publishing the configuration, but the deployed configuration matches the new bytes"* \
      && "$o" != *"nothing was revoked"* && "$o" == *"removed: old.example.test:8443"* ]] \
      && ! grep -qxF 'old.example.test:8443' "$S395/s395-allowlist"; then
    e395 pass
else
    e395 fail "L6 lost-result-landed continues + source not restored (rc=$rc, out: $o)"
fi
if w395_ok "$cfg395" "$GW395" "$sq_after6" \
      && [[ "$(cat "$(mock_group_file "$GW395" allowlist_p8443)")" == "share.example.test" ]] \
      && [[ -f "$old_p395" ]]; then
    e395 pass
else
    e395 fail "L6 new generation active/witnessed; old group still present but unreferenced"
fi

# L7: the rename does not land -> sweep + re-read prove pre-publication;
# the existing EGL-389 source restore/disclosure runs (S-P1), old bytes
# stay deployed, no witness is claimed for the failed publish.
u_sq_before="$(sq_hash "$u_sq")"
u_p_before="$(sq_hash "$u_p")"
u_w_before="$(cat "$cfg395U/.egresslock-activated" 2>/dev/null)"
: > "$STATE/mv-lost-result-not-landed"
o="$(run395u disallow s395u safe.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/mv-lost-result-not-landed"
if [[ "$rc" == 1 && "$o" == *"nothing was revoked — the reinstall failed before the new allowlist was applied and the allowlist was put back"* \
      && "$o" != *"removed:"* ]] \
      && grep -qxF 'safe.example.test:8443' "$S395/s395u-allowlist" \
      && [[ "$(sq_hash "$u_sq")" == "$u_sq_before" ]] \
      && [[ "$(sq_hash "$u_p")" == "$u_p_before" ]]; then
    e395 pass
else
    e395 fail "L7 not-landed proves pre-publication + restores source (rc=$rc, src=$(grep -cxF 'safe.example.test:8443' "$S395/s395u-allowlist") sq=$(sq_hash "$u_sq")/$u_sq_before p=$(sq_hash "$u_p")/$u_p_before out: $o)"
fi
[[ ! -e "$cfg395U/.egresslock-activated" ]] \
    && e395 pass || e395 fail "L7 invalidated witness is not re-recorded on a failed publish"
: > "$STATE/opslog"
o="$(run395u ensure s395u 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* && "$(restart_count)" == 1 ]] \
      && w395_ok "$cfg395U" "$GW395U" "$(sq_hash "$u_sq")"; then
    e395 pass
else
    e395 fail "L7 next ensure restarts instead of skip-blessing (rc=$rc, out: $o)"
fi

# L8: the sweep fails -> outcome is ambiguous (S-P4): neither the source
# nor the old config is claimed, and a pre-existing gateway is NOT removed
# by this run's cleanup (it was never restarted/owned). The single
# running/indeterminate variant is state-true and never says this attempt
# started the gateway or that the removed entries are not enforced.
: > "$STATE/mv-lost-result-not-landed"
: > "$STATE/rm-stage-fails"
o="$(run395u disallow s395u safe.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/mv-lost-result-not-landed" "$STATE/rm-stage-fails"
if [[ "$rc" == 1 ]] \
      && grep -qxF "$(sp4_395 s395u "$SRC395U" safe.example.test:8443)" <<<"$o" \
      && [[ "$o" == *"gateway config publication could not be confirmed (the rename outcome or the deployed configuration could not be proven)"* \
      && "$o" != *"nothing was revoked"* && "$o" != *"removed:"* \
      && "$o" != *"this attempt did not restart"* \
      && "$o" != *"started by this attempt"* \
      && "$o" != *"not the entries this reinstall removed"* ]] \
      && ! grep -qxF 'safe.example.test:8443' "$S395/s395u-allowlist" \
      && [[ -f "$STATE/running/$GW395U" ]] \
      && [[ "$(sq_hash "$u_sq")" == "$u_sq_before" ]]; then
    e395 pass
else
    e395 fail "L8 sweep failure -> S-P4, source untouched, no revocation claim (rc=$rc, src=$(grep -cxF 'safe.example.test:8443' "$S395/s395u-allowlist") sq=$(sq_hash "$u_sq")/$u_sq_before running=$([ -f "$STATE/running/$GW395U" ] && echo yes || echo no) w=$([ -e "$cfg395U/.egresslock-activated" ] && echo yes || echo no) out: $o)"
fi
[[ ! -e "$cfg395U/.egresslock-activated" ]] \
    && e395 pass || e395 fail "L8 no witness after unknown publication"
o="$(run395u ensure s395u 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && ! grep -qxF 'safe.example.test:8443' "$S395/s395u-allowlist"; then
    e395 pass
else
    e395 fail "L8 next ensure converges the kept removal (rc=$rc, out: $o)"
fi

# L8b: `mv -T` rc 0 with a read-back equal to the old deployed generation
# is Unknown (S-P4), never proven pre-publication: the source stays
# removed (not restored), the old config is not rolled back, and no
# witness is claimed.
o="$(run395x ensure s395x 2>&1)"; rc=$?
sqX="$cfg395X/squid.conf"
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395X" "$GW395X" "$(sq_hash "$sqX")"; then
    e395 pass
else
    e395 fail "L8b setup apply s395x (rc=$rc, out: $o)"
fi
sqX_before="$(sq_hash "$sqX")"
: > "$STATE/mv-rc0-old"
o="$(run395x disallow s395x keepx.example.test 2>&1)"; rc=$?
rm -f "$STATE/mv-rc0-old"
if [[ "$rc" == 1 ]] \
      && grep -qxF "$(sp4_395 s395x "$SRC395X" keepx.example.test)" <<<"$o" \
      && [[ "$o" == *"gateway config publication could not be confirmed (the rename outcome or the deployed configuration could not be proven)"* \
      && "$o" != *"nothing was revoked"* && "$o" != *"removed:"* \
      && "$o" != *"started by this attempt"* \
      && "$o" != *"not the entries this reinstall removed"* ]] \
      && ! grep -qxF 'keepx.example.test' "$S395/s395x-allowlist" \
      && [[ "$(sq_hash "$sqX")" == "$sqX_before" ]] \
      && [[ ! -e "$cfg395X/.egresslock-activated" ]] \
      && [[ -f "$STATE/running/$GW395X" ]]; then
    e395 pass
else
    e395 fail "L8b rc0 + old read-back -> S-P4, source untouched (rc=$rc, src=$(grep -cxF 'keepx.example.test' "$S395/s395x-allowlist") sq=$(sq_hash "$sqX")/$sqX_before out: $o)"
fi
o="$(run395x ensure s395x 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395X" "$GW395X" "$(sq_hash "$sqX")"; then
    e395 pass
else
    e395 fail "L8b next ensure converges (rc=$rc, out: $o)"
fi

# L8c: `mv -T` rc 0 with a read-back that is absent is Unknown (S-P4),
# never proven pre-publication, even though the candidate was expected at
# a path that existed before the rename.
printf 'second.example.test\n' > "$S395/s395x-allowlist"
o="$(run395x ensure s395x 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]]; then
    e395 pass
else
    e395 fail "L8c setup apply s395x (rc=$rc, out: $o)"
fi
sqX_before="$(sq_hash "$sqX")"
: > "$STATE/mv-rc0-absent"
o="$(run395x disallow s395x second.example.test 2>&1)"; rc=$?
rm -f "$STATE/mv-rc0-absent"
if [[ "$rc" == 1 ]] \
      && grep -qxF "$(sp4_395 s395x "$SRC395X" second.example.test)" <<<"$o" \
      && [[ "$o" == *"gateway config publication could not be confirmed"* \
      && "$o" != *"nothing was revoked"* && "$o" != *"removed:"* \
      && "$o" != *"started by this attempt"* ]] \
      && ! grep -qxF 'second.example.test' "$S395/s395x-allowlist" \
      && [[ ! -e "$sqX" && -n "$sqX_before" ]] \
      && [[ ! -e "$cfg395X/.egresslock-activated" ]] \
      && [[ -f "$STATE/running/$GW395X" ]]; then
    e395 pass
else
    e395 fail "L8c rc0 + absent read-back -> S-P4, source untouched (rc=$rc, src=$(grep -cxF 'second.example.test' "$S395/s395x-allowlist") sq=$([ -e "$sqX" ] && sq_hash "$sqX" || echo absent) out: $o)"
fi
o="$(run395x ensure s395x 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395X" "$GW395X" "$(sq_hash "$sqX")"; then
    e395 pass
else
    e395 fail "L8c next ensure converges from an absent deployed config (rc=$rc, out: $o)"
fi

# L8d: `mv -T` rc 0 with different bytes at the deployed path is Unknown
# (S-P4); no "another writer" diagnosis and no source restore.
printf 'third.example.test:9443\n' > "$S395/s395x-allowlist"
o="$(run395x ensure s395x 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]]; then
    e395 pass
else
    e395 fail "L8d setup apply s395x (rc=$rc, out: $o)"
fi
sqX_before="$(sq_hash "$sqX")"
tampered_hash="$(printf 'tampered\n' | sha256sum | cut -d' ' -f1)"
: > "$STATE/mv-rc0-other"
o="$(run395x disallow s395x third.example.test:9443 2>&1)"; rc=$?
rm -f "$STATE/mv-rc0-other"
if [[ "$rc" == 1 ]] \
      && grep -qxF "$(sp4_395 s395x "$SRC395X" third.example.test:9443)" <<<"$o" \
      && [[ "$o" == *"gateway config publication could not be confirmed"* \
      && "$o" != *"nothing was revoked"* && "$o" != *"removed:"* \
      && "$o" != *"another writer"* && "$o" != *"started by this attempt"* ]] \
      && ! grep -qxF 'third.example.test:9443' "$S395/s395x-allowlist" \
      && [[ "$(sq_hash "$sqX")" == "$tampered_hash" && "$tampered_hash" != "$sqX_before" ]] \
      && [[ ! -e "$cfg395X/.egresslock-activated" ]] \
      && [[ -f "$STATE/running/$GW395X" ]]; then
    e395 pass
else
    e395 fail "L8d rc0 + different bytes -> S-P4, source untouched (rc=$rc, src=$(grep -cxF 'third.example.test:9443' "$S395/s395x-allowlist") sq=$(sq_hash "$sqX")/$tampered_hash out: $o)"
fi
o="$(run395x ensure s395x 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395X" "$GW395X" "$(sq_hash "$sqX")"; then
    e395 pass
else
    e395 fail "L8d next ensure replaces the tampered config (rc=$rc, out: $o)"
fi

# L8e: a sweep absence probe that errors is a failed probe, never
# "absent": the stage is not proved gone, so the outcome is Unknown
# (S-P4), the source is not restored and the old config is kept.
sqU_before="$(sq_hash "$u_sq")"
: > "$STATE/mv-lost-result-not-landed"
: > "$STATE/exec-test-e-fails-stage"
o="$(run395u disallow s395u other.example.test:8443 2>&1)"; rc=$?
rm -f "$STATE/mv-lost-result-not-landed" "$STATE/exec-test-e-fails-stage"
if [[ "$rc" == 1 ]] \
      && grep -qxF "$(sp4_395 s395u "$SRC395U" other.example.test:8443)" <<<"$o" \
      && [[ "$o" == *"gateway config publication could not be confirmed"* \
      && "$o" != *"nothing was revoked"* && "$o" != *"removed:"* \
      && "$o" != *"started by this attempt"* ]] \
      && ! grep -qxF 'other.example.test:8443' "$S395/s395u-allowlist" \
      && [[ "$(sq_hash "$u_sq")" == "$sqU_before" ]] \
      && [[ ! -e "$cfg395U/.egresslock-activated" ]] \
      && [[ -f "$STATE/running/$GW395U" ]]; then
    e395 pass
else
    e395 fail "L8e sweep absence-probe error -> S-P4, source/old config kept (rc=$rc, src=$(grep -cxF 'other.example.test:8443' "$S395/s395u-allowlist") sq=$(sq_hash "$u_sq")/$sqU_before out: $o)"
fi
o="$(run395u ensure s395u 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395U" "$GW395U" "$(sq_hash "$u_sq")"; then
    e395 pass
else
    e395 fail "L8e next ensure converges after the probe error (rc=$rc, out: $o)"
fi

# L8f: the deployed read errors after a lost rename result -> Unknown
# (S-P4), never absent/pre-publication; the source stays removed and the
# old bytes are kept.
sqU_before="$(sq_hash "$u_sq")"
: > "$STATE/mv-arm-read-fails"
o="$(run395u disallow s395u probe.example.test:9452 2>&1)"; rc=$?
rm -f "$STATE/mv-arm-read-fails" "$STATE/read-fails-$GW395U"
if [[ "$rc" == 1 ]] \
      && grep -qxF "$(sp4_395 s395u "$SRC395U" probe.example.test:9452)" <<<"$o" \
      && [[ "$o" == *"gateway config publication could not be confirmed"* \
      && "$o" != *"nothing was revoked"* && "$o" != *"removed:"* \
      && "$o" != *"started by this attempt"* ]] \
      && ! grep -qxF 'probe.example.test:9452' "$S395/s395u-allowlist" \
      && [[ "$(sq_hash "$u_sq")" == "$sqU_before" ]] \
      && [[ ! -e "$cfg395U/.egresslock-activated" ]] \
      && [[ -f "$STATE/running/$GW395U" ]]; then
    e395 pass
else
    e395 fail "L8f deployed read error -> S-P4, source/old config kept (rc=$rc, src=$(grep -cxF 'probe.example.test:9452' "$S395/s395u-allowlist") sq=$(sq_hash "$u_sq")/$sqU_before out: $o)"
fi
o="$(run395u ensure s395u 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395U" "$GW395U" "$(sq_hash "$u_sq")"; then
    e395 pass
else
    e395 fail "L8f next ensure converges after the read error (rc=$rc, out: $o)"
fi

# L8g: a container this run started (ENSURE_OWNED contains it) with an
# Unknown publication outcome prints the same single S-P4 running variant:
# ENSURE_OWNED is not a selector and no variant claims this run started
# the gateway.
rm -f "$STATE/running/$GW395Y"
: > "$STATE/mv-lost-result-not-landed"
: > "$STATE/rm-stage-fails"
: > "$STATE/rm-container-fails"
o="$(run395y disallow s395y ready.example.test 2>&1)"; rc=$?
rm -f "$STATE/mv-lost-result-not-landed" "$STATE/rm-stage-fails" "$STATE/rm-container-fails"
if [[ "$rc" == 1 ]] \
      && grep -qxF "$(sp4_395 s395y "$SRC395Y" ready.example.test)" <<<"$o" \
      && [[ "$o" == *"gateway config publication could not be confirmed"* \
      && "$o" == *"cleanup: removal failed:"* \
      && "$o" != *"nothing was revoked"* && "$o" != *"removed:"* \
      && "$o" != *"started by this attempt"* \
      && "$o" != *"not the entries this reinstall removed"* ]] \
      && ! grep -qxF 'ready.example.test' "$S395/s395y-allowlist" \
      && [[ -f "$STATE/running/$GW395Y" ]] \
      && [[ ! -e "$cfg395Y/squid.conf" ]] \
      && [[ ! -e "$cfg395Y/.egresslock-activated" ]]; then
    e395 pass
else
    e395 fail "L8g ENSURE_OWNED does not change S-P4 (rc=$rc, src=$(grep -cxF 'ready.example.test' "$S395/s395y-allowlist") running=$([ -f "$STATE/running/$GW395Y" ] && echo yes || echo no) sq=$([ -e "$cfg395Y/squid.conf" ] && echo present || echo absent) out: $o)"
fi
o="$(run395y ensure s395y 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395Y" "$GW395Y" "$(sq_hash "$cfg395Y/squid.conf")"; then
    e395 pass
else
    e395 fail "L8g next ensure applies after the owned-unknown failure (rc=$rc, out: $o)"
fi

# L8h: bootstrap (old generation absent) + a lost rename result + a
# deployed read/probe error. A failed probe is never `absent`, so the
# bootstrap cell must stay Unknown/S-P4: no proven-pre-publication claim,
# no source restore, no swap-failure line and no deployed config. (This
# is the R-EGL-395-4 F1(a) cell that the pre-3a `gw_ctr_generation`
# misroute would turn into a false rollback/source restore.)
: > "$STATE/mv-lost-result-not-landed"
: > "$STATE/mv-arm-probe-fails"
: > "$STATE/rm-container-fails"
o="$(run395z disallow s395z zgone.example.test 2>&1)"; rc=$?
rm -f "$STATE/mv-lost-result-not-landed" "$STATE/mv-arm-probe-fails" \
      "$STATE/read-fails-$GW395Z" "$STATE/exec-test-L-fails-deployed" \
      "$STATE/rm-container-fails"
if [[ "$rc" == 1 ]] \
      && grep -qxF "$(sp4_395 s395z "$SRC395Z" zgone.example.test)" <<<"$o" \
      && [[ "$o" == *"gateway config publication could not be confirmed"* \
      && "$o" != *"nothing was revoked"* \
      && "$o" != *"gateway config swap failed"* \
      && "$o" != *"removed:"* ]] \
      && ! grep -qxF 'zgone.example.test' "$SRC395Z" \
      && [[ ! -e "$cfg395Z/squid.conf" && ! -e "$cfg395Z/.egresslock-activated" ]] \
      && [[ -f "$STATE/running/$GW395Z" ]]; then
    e395 pass
else
    e395 fail "L8h bootstrap failed-read stays S-P4, no restore (rc=$rc, src=$(grep -cxF 'zgone.example.test' "$SRC395Z") conf=$([ -e "$cfg395Z/squid.conf" ] && echo present || echo absent) out: $o)"
fi
o="$(run395z ensure s395z 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395Z" "$GW395Z" "$(sq_hash "$cfg395Z/squid.conf")"; then
    e395 pass
else
    e395 fail "L8h next ensure publishes the bootstrap config + witnesses it (rc=$rc, out: $o)"
fi

# L8i: an unproved witness invalidation aborts before the config rename.
# The old deployed config is untouched, the source is restored (S-P1) and
# no new witness can be minted from the aborted publish.
printf 'third.example.test:9443\n' > "$S395/s395x-allowlist"
o="$(run395x ensure s395x 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]]; then
    e395 pass
else
    e395 fail "L8i setup apply s395x (rc=$rc, out: $o)"
fi
sqX_before="$(sq_hash "$sqX")"
: > "$STATE/exec-test-e-fails-witness"
o="$(run395x disallow s395x third.example.test:9443 2>&1)"; rc=$?
rm -f "$STATE/exec-test-e-fails-witness"
if [[ "$rc" == 1 ]] \
      && [[ "$o" == *"gateway config publication aborted: the activation record could not be proved invalidated"* \
      && "$o" == *"nothing was revoked"* \
      && "$o" != *"gateway config publication could not be confirmed"* ]] \
      && grep -qxF 'third.example.test:9443' "$S395/s395x-allowlist" \
      && [[ "$(sq_hash "$sqX")" == "$sqX_before" ]] \
      && [[ ! -e "$cfg395X/.egresslock-activated" ]]; then
    e395 pass
else
    e395 fail "L8i unproved witness invalidation aborts pre-publication (rc=$rc, src=$(grep -cxF 'third.example.test:9443' "$S395/s395x-allowlist") sq=$(sq_hash "$sqX")/$sqX_before out: $o)"
fi
o="$(run395x ensure s395x 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395X" "$GW395X" "$(sq_hash "$sqX")"; then
    e395 pass
else
    e395 fail "L8i next ensure recovers after the aborted invalidation (rc=$rc, out: $o)"
fi

# L8m: an unprobed witness shape is not a converged skip. A failed -L
# probe on the witness must make the witness "not proved" (apply path),
# never "not a symlink" (which would allow the raw-probe skip to accept a
# witness whose shape could not actually be read).
x_sq_before="$(sq_hash "$sqX")"
: > "$STATE/exec-test-L-fails-witness"
o="$(run395x ensure s395x 2>&1)"; rc=$?
rm -f "$STATE/exec-test-L-fails-witness"
if [[ "$rc" == 1 ]] \
      && [[ "$o" == *"gateway config publication aborted: the activation record could not be proved invalidated"* ]] \
      && [[ "$o" != *"already converged, not restarted"* ]] \
      && [[ "$(sq_hash "$sqX")" == "$x_sq_before" ]] \
      && grep -qxF 'third.example.test:9443' "$SRC395X"; then
    e395 pass
else
    e395 fail "L8m unprobed witness shape is not a converged skip (rc=$rc, sq=$(sq_hash "$sqX")/$x_sq_before out: $o)"
fi
o="$(run395x ensure s395x 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395X" "$GW395X" "$(sq_hash "$sqX")"; then
    e395 pass
else
    e395 fail "L8m next ensure recovers after the witness probe error (rc=$rc, out: $o)"
fi

# L8j: the container stops after the apply starts; the publication outcome
# is Unknown and the observation is a proven not-running state. The S-P4
# not-running body must print (not the running/indeterminate or removed
# variants), with the old deployed config kept and the source untouched.
z_sq_before="$(sq_hash "$cfg395Z/squid.conf")"
: > "$STATE/mv-lost-result-not-landed"
: > "$STATE/rm-stage-fails"
: > "$STATE/gateway-stops-late-$GW395Z"
o="$(run395z disallow s395z zvanish.example.test 2>&1)"; rc=$?
rm -f "$STATE/mv-lost-result-not-landed" "$STATE/rm-stage-fails" \
      "$STATE/gateway-stops-late-$GW395Z"
if [[ "$rc" == 1 ]] \
      && grep -qxF "$(sp4_notrunning_395 s395z "$SRC395Z")" <<<"$o" \
      && [[ "$o" == *"gateway config publication could not be confirmed"* \
      && "$o" != *"nothing was revoked"* && "$o" != *"removed:"* ]] \
      && ! grep -qxF 'zvanish.example.test' "$SRC395Z" \
      && [[ "$(sq_hash "$cfg395Z/squid.conf")" == "$z_sq_before" ]] \
      && [[ ! -e "$cfg395Z/.egresslock-activated" ]] \
      && [[ ! -f "$STATE/running/$GW395Z" ]] \
      && [[ -f "$STATE/containers/$GW395Z.net" ]]; then
    e395 pass
else
    e395 fail "L8j unknown + stopped container -> S-P4 not-running body (rc=$rc, src=$(grep -cxF 'zvanish.example.test' "$SRC395Z") sq=$(sq_hash "$cfg395Z/squid.conf")/$z_sq_before running=$([ -f "$STATE/running/$GW395Z" ] && echo yes || echo no) out: $o)"
fi
o="$(run395z ensure s395z 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395Z" "$GW395Z" "$(sq_hash "$cfg395Z/squid.conf")"; then
    e395 pass
else
    e395 fail "L8j next ensure restarts the stopped gateway + witnesses (rc=$rc, out: $o)"
fi

# L8k: a fresh-profile Unknown publication whose cleanup removed the
# container prints the proven removed S-P4 body, never running/not-running.
: > "$STATE/mv-lost-result-not-landed"
: > "$STATE/rm-stage-fails"
o="$(run395r disallow s395r rremove.example.test 2>&1)"; rc=$?
rm -f "$STATE/mv-lost-result-not-landed" "$STATE/rm-stage-fails"
if [[ "$rc" == 1 ]] \
      && grep -qxF "$(sp4_removed_395 s395r "$SRC395R" "$GW395R")" <<<"$o" \
      && [[ "$o" == *"gateway config publication could not be confirmed"* \
      && "$o" != *"nothing was revoked"* && "$o" != *"removed:"* ]] \
      && ! grep -qxF 'rremove.example.test' "$SRC395R" \
      && [[ ! -f "$STATE/running/$GW395R" && ! -f "$STATE/containers/$GW395R.net" ]] \
      && [[ ! -e "$cfg395R/squid.conf" && ! -e "$cfg395R/.egresslock-activated" ]]; then
    e395 pass
else
    e395 fail "L8k unknown + cleanup removal -> S-P4 removed body (rc=$rc, src=$(grep -cxF 'rremove.example.test' "$SRC395R") net=$([ -f "$STATE/containers/$GW395R.net" ] && echo present || echo absent) out: $o)"
fi
o="$(run395r ensure s395r 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395R" "$GW395R" "$(sq_hash "$cfg395R/squid.conf")"; then
    e395 pass
else
    e395 fail "L8k next ensure recreates the removed gateway (rc=$rc, out: $o)"
fi

# L8l: an indeterminate container observation (failed ps at disclosure)
# prints the S-P4 unknown-state body, not the running or not-running one.
u_sq_before="$(sq_hash "$u_sq")"
: > "$STATE/mv-lost-result-not-landed"
: > "$STATE/rm-stage-fails"
: > "$STATE/ps-fails-late"
o="$(run395u disallow s395u danger.example.test 2>&1)"; rc=$?
rm -f "$STATE/mv-lost-result-not-landed" "$STATE/rm-stage-fails" \
      "$STATE/ps-fails-late" "$STATE/ps-fails-active"
if [[ "$rc" == 1 ]] \
      && grep -qxF "$(sp4_unknown_395 s395u "$SRC395U" danger.example.test)" <<<"$o" \
      && [[ "$o" == *"gateway config publication could not be confirmed"* \
      && "$o" != *"nothing was revoked"* && "$o" != *"removed:"* ]] \
      && ! grep -qxF 'danger.example.test' "$SRC395U" \
      && [[ "$(sq_hash "$u_sq")" == "$u_sq_before" ]] \
      && [[ ! -e "$cfg395U/.egresslock-activated" ]] \
      && [[ -f "$STATE/running/$GW395U" ]]; then
    e395 pass
else
    e395 fail "L8l unknown observation -> S-P4 indeterminate body (rc=$rc, src=$(grep -cxF 'danger.example.test' "$SRC395U") sq=$(sq_hash "$u_sq")/$u_sq_before out: $o)"
fi
o="$(run395u ensure s395u 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* ]] \
      && w395_ok "$cfg395U" "$GW395U" "$(sq_hash "$u_sq")"; then
    e395 pass
else
    e395 fail "L8l next ensure recovers after the unknown observation (rc=$rc, out: $o)"
fi

# L9: publication succeeds but activation fails (restart comes up sick) ->
# no witness is recorded; the next ensure takes the apply path, never the
# byte-only skip. The failed run's cleanup is blocked so the deployed
# candidate bytes can be inspected.
printf 'later.example.test:9443\n' >> "$S395/s395u-allowlist"
: > "$STATE/probe-fails-$GW395U"
: > "$STATE/rm-container-fails"
o="$(run395u ensure s395u 2>&1)"; rc=$?
rm -f "$STATE"/probe-fails* "$STATE/rm-container-fails"
if [[ "$rc" == 1 && "$o" == *"gateway did not come back healthy after config application"* ]] \
      && [[ -f "$STATE/containers-$GW395U.candidate" ]]; then
    e395 pass
else
    e395 fail "L9 post-publication health failure (rc=$rc, out: $o)"
fi
if [[ -f "$cfg395U/squid.conf" ]] \
      && cmp -s "$cfg395U/squid.conf" "$STATE/containers-$GW395U.candidate" \
      && [[ ! -e "$cfg395U/.egresslock-activated" ]]; then
    e395 pass
else
    e395 fail "L9 deployed candidate present but no witness (deployed: $(sq_hash "$cfg395U/squid.conf"), candidate: $(sq_hash "$STATE/containers-$GW395U.candidate"))"
fi
: > "$STATE/opslog"
o="$(run395u ensure s395u 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* && "$(restart_count)" == 1 ]] \
      && w395_ok "$cfg395U" "$GW395U" "$(sq_hash "$cfg395U/squid.conf")"; then
    e395 pass
else
    e395 fail "L9 next ensure restarts and records the witness (rc=$rc, out: $o)"
fi

# L10: a delayed container-side rename that lands before the sweep is
# caught by the re-read: same published outcome, S-P6, no S-P4.
printf 'late.example.test:9444\n' >> "$S395/s395u-allowlist"
: > "$STATE/mv-delayed-lands"
o="$(run395u ensure s395u 2>&1)"; rc=$?
rm -f "$STATE/mv-delayed-lands"
if [[ "$rc" == 0 && "$o" == *"gateway: note: podman reported an error while publishing the configuration"* \
      && "$o" != *"could not confirm whether the new configuration was published"* ]] \
      && w395_ok "$cfg395U" "$GW395U" "$(sq_hash "$cfg395U/squid.conf")" \
      && cmp -s "$cfg395U/squid.conf" "$STATE/containers-$GW395U.candidate"; then
    e395 pass
else
    e395 fail "L10 delayed rename caught by sweep/read-back (rc=$rc, out: $o)"
fi

# L11: a missing/malformed/stale/mismatched witness never skips. Every
# variant forces the apply/restart path and records a fresh exact witness.
for wvar in missing malformed generation container started; do
    case "$wvar" in
        missing) rm -f "$cfg395/.egresslock-activated" ;;
        malformed) printf 'not-a-witness\n' > "$cfg395/.egresslock-activated" ;;
        generation) sed -i 's/^generation=.*/generation=0000000000000000000000000000000000000000000000000000000000000000/' "$cfg395/.egresslock-activated" ;;
        container) sed -i 's/^container=.*/container=wronginstance/' "$cfg395/.egresslock-activated" ;;
        started) sed -i 's/^started=.*/started=1999-01-01T00:00:00.000000000Z#0/' "$cfg395/.egresslock-activated" ;;
    esac
    : > "$STATE/opslog"
    o="$(run395 ensure s395 2>&1)"; rc=$?
    if [[ "$rc" == 0 && "$o" == *"allowlist applied"* && "$o" != *"already converged"* \
          && "$(restart_count)" == 1 ]] \
          && w395_ok "$cfg395" "$GW395" "$(sq_hash "$sq395")"; then
        e395 pass
    else
        e395 fail "L11 $wvar witness -> apply/restart/re-record (rc=$rc, out: $o)"
    fi
done

# L12: a reboot (StartedAt change) and --replace-gateway (new container ID)
# both invalidate the witness; each forces an apply and a fresh record.
printf '2026-01-01T00:00:00.000000000Z#999\n' > "$STATE/containers-$GW395.started"
: > "$STATE/opslog"
o="$(run395 ensure s395 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* && "$(restart_count)" == 1 ]] \
      && w395_ok "$cfg395" "$GW395" "$(sq_hash "$sq395")"; then
    e395 pass
else
    e395 fail "L12 StartedAt change -> restart + re-record (rc=$rc, out: $o)"
fi
old_id="$(cat "$STATE/containers-$GW395.id" 2>/dev/null)"
: > "$STATE/opslog"
o="$(run395 ensure --replace-gateway s395 2>&1)"; rc=$?
new_id="$(cat "$STATE/containers-$GW395.id" 2>/dev/null)"
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* && -n "$new_id" && "$new_id" != "$old_id" ]] \
      && grep -q '^podman rm -f egresslock-gateway-s395$' "$STATE/opslog" \
      && grep -q '^podman run .*--name egresslock-gateway-s395' "$STATE/opslog" \
      && w395_ok "$cfg395" "$GW395" "$(sq_hash "$sq395")"; then
    e395 pass
else
    e395 fail "L12 replace-gateway -> new ID + re-record (rc=$rc, out: $o)"
fi

# L13: cleanup is reference-driven. It keeps squid.conf/allowlist.conf/the
# witness/every deployed ref; deletes only old unreferenced regular files,
# legacy check.conf and old stage dirs; keeps young leftovers, symlinks and
# any unreadable set; warns without changing rc.
stale_p="$(mock_group_name p9999 $'stale.example.test\n')"
young_p="$(mock_group_name p9998 $'young.example.test\n')"
late_p="$(mock_group_name p9996 $'late.example.test\n')"
fail_p="$(mock_group_name p9995 $'fail.example.test\n')"
printf 'stale.example.test\n' > "$cfg395/$stale_p"; touch -d '3 hours ago' "$cfg395/$stale_p"
printf 'young.example.test\n' > "$cfg395/$young_p"
printf 'legacy\n' > "$cfg395/check.conf"; touch -d '3 hours ago' "$cfg395/check.conf"
mkdir -p "$cfg395/.egresslock-stage.oldtest" "$cfg395/.egresslock-stage.youngtest"
touch -d '3 hours ago' "$cfg395/.egresslock-stage.oldtest"
link_p="allowlist.p7777.$(printf 'link\n' | sha256sum | cut -d' ' -f1)"
ln -s /etc/passwd "$cfg395/$link_p"
o="$(run395 ensure s395 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"already converged"* \
      && ! -e "$cfg395/$stale_p" && ! -e "$cfg395/check.conf" \
      && ! -e "$cfg395/.egresslock-stage.oldtest" \
      && -e "$cfg395/$young_p" && -e "$cfg395/.egresslock-stage.youngtest" \
      && -L "$cfg395/$link_p" \
      && "$o" == *"kept "*"unreferenced gateway configuration file(s)"* \
      && "$o" == *"symbolic link or unexpected type"* ]]; then
    e395 pass
else
    e395 fail "L13 cleanup keeps refs/young/symlinks and deletes only old files (rc=$rc, out: $o)"
fi
if [[ -f "$sq395" && -f "$cfg395/allowlist.conf" \
      && -f "$cfg395/.egresslock-activated" \
      && -f "$(mock_group_file "$GW395" allowlist)" \
      && -f "$(mock_group_file "$GW395" allowlist_p8443)" ]]; then
    e395 pass
else
    e395 fail "L13 cleanup keeps squid.conf/allowlist.conf/witness/all refs"
fi
# Old stage dirs are swept too (the above young one stays; age it now).
touch -d '3 hours ago' "$cfg395/.egresslock-stage.youngtest"
printf 'late.example.test\n' > "$cfg395/$late_p"; touch -d '3 hours ago' "$cfg395/$late_p"
: > "$STATE/cleanup-sha-fails"
o="$(run395 ensure s395 2>&1)"; rc=$?
rm -f "$STATE/cleanup-sha-fails"
if [[ "$rc" == 0 && "$o" == *"cleanup: skipped removing old gateway configuration files — the deployed configuration could not be read"* \
      && -e "$cfg395/$late_p" && -e "$cfg395/.egresslock-stage.youngtest" ]]; then
    e395 pass
else
    e395 fail "L13 unreadable reference set skips cleanup and deletes nothing (rc=$rc, out: $o)"
fi
printf 'fail.example.test\n' > "$cfg395/$fail_p"; touch -d '3 hours ago' "$cfg395/$fail_p"
: > "$STATE/cleanup-rm-fails"
o="$(run395 ensure s395 2>&1)"; rc=$?
rm -f "$STATE/cleanup-rm-fails"
if [[ "$rc" == 0 && "$o" == *"cleanup: could not remove"* \
      && "$o" == *"the next ensure retries"* && -e "$cfg395/$late_p" ]]; then
    e395 pass
else
    e395 fail "L13 removal failure warns + keeps the file + rc0 (rc=$rc, out: $o)"
fi
: > "$STATE/cleanup-rm-enospc"
o="$(run395 ensure s395 2>&1)"; rc=$?
rm -f "$STATE/cleanup-rm-enospc"
if [[ "$rc" == 0 && "$o" == *"No space left on device"* \
      && "$o" == *"free space in /etc/squid/egresslock"* ]]; then
    e395 pass
else
    e395 fail "L13 ENOSPC warning names storage consequence (rc=$rc, out: $o)"
fi
# A successful cleanup (with the failure seams gone) removes the aged
# leftovers, including the aged young stage dir.
o="$(run395 ensure s395 2>&1)"; rc=$?
if [[ "$rc" == 0 && ! -e "$cfg395/$late_p" && ! -e "$cfg395/$fail_p" \
      && ! -e "$cfg395/.egresslock-stage.youngtest" \
      && -f "$cfg395/.egresslock-activated" && -f "$sq395" ]]; then
    e395 pass
else
    e395 fail "L13 retry removes aged unreferenced files, keeps the witness (rc=$rc, out: $o)"
fi
rm -f "$cfg395/$young_p" "$cfg395/$link_p"

# L14: both layouts use the same detected cfgdir for generation, witness,
# argv proof and cleanup; a wrong live argv is never blessed by the skip.
touch "$STATE/gw-layout-agent-$GW395l"
o="$(run395l ensure s395l 2>&1)"; rc=$?
sqL="$cfg395l/squid.conf"
domL="$(mock_group_file "$GW395l" allowlist)"
domL_ref="$(mock_cfg_ref "$GW395l" allowlist)"
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* && -f "$sqL" \
      && "$domL" == "$cfg395l/$(basename "$domL")" \
      && "$(basename "$domL")" =~ ^allowlist\.domains\.[0-9a-f]{64}$ \
      && "$(grep -cF "acl allowlist dstdomain -n \"$domL_ref\"" "$sqL")" == 1 \
      && "$domL_ref" == /etc/squid/agent/* ]] \
      && w395_ok "$cfg395l" "$GW395l" "$(sq_hash "$sqL")"; then
    e395 pass
else
    e395 fail "L14 old layout hashed refs + witness (rc=$rc, out: $o)"
fi
mkdir -p "$cfg395l/.egresslock-stage.oldlay"; touch -d '3 hours ago' "$cfg395l/.egresslock-stage.oldlay"
o="$(run395l ensure s395l 2>&1)"; rc=$?
[[ "$rc" == 0 && ! -e "$cfg395l/.egresslock-stage.oldlay" ]] \
    && e395 pass || e395 fail "L14 old-layout cleanup uses the detected cfgdir (rc=$rc, out: $o)"
printf 'argv.example.test:9443\n' >> "$S395/s395l-allowlist"
: > "$STATE/argv-bad-$GW395l"
: > "$STATE/opslog"
o="$(run395l ensure s395l 2>&1)"; rc=$?
rm -f "$STATE/argv-bad-$GW395l"
if [[ "$rc" == 0 && "$o" == *"the running Squid process could not be confirmed as loading it"* \
      && "$o" == *"ready (configuration deployed; activation not confirmed"* \
      && "$(restart_count)" == 1 && ! -e "$cfg395l/.egresslock-activated" ]]; then
    e395 pass
else
    e395 fail "L14 bad argv warns, ready line is truthful, no witness (rc=$rc, out: $o)"
fi
: > "$STATE/opslog"
o="$(run395l ensure s395l 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"allowlist applied"* && "$(restart_count)" == 1 ]] \
      && w395_ok "$cfg395l" "$GW395l" "$(sq_hash "$sqL")"; then
    e395 pass
else
    e395 fail "L14 argv proof recovers on the next ensure (rc=$rc, out: $o)"
fi

# Hygiene: remove only this battery's knobs/markers and tear the profiles
# down (the section is last; later sections must not inherit them).
rm -f "$STATE"/mv-lost-result-* "$STATE"/mv-delayed-lands \
      "$STATE"/mv-rc0-* "$STATE"/mv-arm-read-fails "$STATE"/mv-arm-probe-fails \
      "$STATE"/read-fails-* "$STATE"/rm-stage-fails "$STATE"/probe-fails* \
      "$STATE"/rm-container-fails "$STATE"/cleanup-* \
      "$STATE"/argv-bad* "$STATE"/cp-stage-fails-* "$STATE"/cp-snapshot-fails-* \
      "$STATE"/exec-test-e-fails* "$STATE"/exec-test-L-fails* \
      "$STATE"/gateway-stops-late-* "$STATE"/ps-fails-late "$STATE"/ps-fails-active
rm -f "$STATE/gw-layout-agent-$GW395l"
run395 teardown s395 >/dev/null 2>&1 || true
run395u teardown s395u >/dev/null 2>&1 || true
run395l teardown s395l >/dev/null 2>&1 || true
run395x teardown s395x >/dev/null 2>&1 || true
run395y teardown s395y >/dev/null 2>&1 || true
run395z teardown s395z >/dev/null 2>&1 || true
run395r teardown s395r >/dev/null 2>&1 || true
section_end egl395

section_begin egl392 "EGL-392 proxy allow atomic source transaction"
e392() { assert "$@"; }

S392="$TESTROOT/s392"; rm -rf "$S392"; mkdir -p "$S392"
cat > "$S392/e392.conf" <<'EOF'
profile e392 10.199.192.0/24
    rule gateway-only
    gateway 10.199.192.2 3128 e392-allowlist
EOF
H392="$(conf_home "$S392/e392.conf")"
SRC392="$H392/.config/egresslock/e392-allowlist"
GW392="egresslock-gateway-e392"
mkdir -p "$STATE/ips" "$STATE/containers"
: > "$STATE/running/$GW392"
echo "egresslock-e392" > "$STATE/containers/$GW392.net"
echo "10.199.192.2" > "$STATE/containers/$GW392.ip"
run392() { env ARCMOCK_PASSWD_HOME="$H392" HOME="$S392" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
seed392() {
    rm -f "$SRC392"
    printf '# keep this comment\nkeep.example.test:443\n\nkeep2.example.test\n' > "$SRC392"
    chmod 600 "$SRC392"
}
reset392() {
    chmod 700 "$S392" 2>/dev/null || true
    rm -rf "$S392"/e392-allowlist.egresslock-stage.* "$S392"/mark "$S392"/release \
          "$S392"/bg.out "$S392"/targetdir "$S392"/aclprobe "$S392"/e392-peer
    if [[ -d "$S392/state-pristine" ]]; then
        rm -rf "$STATE"; cp -a "$S392/state-pristine" "$STATE"; : > "$STATE/opslog"
    else
        run392 teardown e392 >/dev/null 2>&1 || true
        run392 ensure e392 >/dev/null 2>&1
        : > "$STATE/opslog"
    fi
    seed392
}
e392_sha() { sha256sum "$1" | cut -d' ' -f1; }
e392_no_result() { # <output>
    [[ "$1" != *"added:"* && "$1" != *"entry already present:"* && "$1" != *"re-ensuring"* ]]
}

# Scoped command shims for the injected failure / interruption legs. They
# are section-local (the EGL-246 precedent), and every one delegates to
# the real tool unless its E392_MODE names that leg.
E392SH="$TESTROOT/bin-e392"; rm -rf "$E392SH"; mkdir -p "$E392SH"
cat > "$E392SH/mktemp" <<EOF
#!/usr/bin/env bash
if [[ "\${E392_MODE:-}" == "mktemp-stage" ]]; then
    for a in "\$@"; do
        if [[ "\$a" == "\${E392_SRC:-}.egresslock-stage."* ]]; then
            [[ -n "\${E392_MARK:-}" ]] && : > "\$E392_MARK"
            echo "mktemp: injected private-stage creation failure" >&2
            exit 1
        fi
    done
fi
exec /usr/bin/mktemp "\$@"
EOF
cat > "$E392SH/cat" <<EOF
#!/usr/bin/env bash
if [[ "\${E392_MODE:-}" == "cat-src" ]]; then
    for a in "\$@"; do [[ "\$a" == "\${E392_SRC:-}" ]] && exit 1; done
fi
if [[ "\${E392_MODE:-}" == "cat-pause" ]]; then
    c392_dd=0
    for a in "\$@"; do
        [[ "\$a" == "--" ]] && c392_dd=1
        if (( c392_dd )) && [[ "\$a" == "\${E392_SRC:-}" ]]; then
            : > "\${E392_MARK:-/nonexistent}"
            while [[ ! -e "\${E392_RELEASE:-/nonexistent}" ]]; do sleep 0.02; done
            break
        fi
    done
fi
exec "$TESTROOT/bin/cat" "\$@"
EOF
cat > "$E392SH/grep" <<EOF
#!/usr/bin/env bash
if [[ "\${E392_MODE:-}" == "grep-src" ]]; then
    for a in "\$@"; do [[ "\$a" == "\${E392_SRC:-}" ]] && exit 2; done
fi
exec /usr/bin/grep "\$@"
EOF
cat > "$E392SH/tail" <<EOF
#!/usr/bin/env bash
if [[ "\${E392_MODE:-}" == "tail-src" ]]; then
    for a in "\$@"; do [[ "\$a" == "\${E392_SRC:-}" ]] && exit 1; done
fi
exec /usr/bin/tail "\$@"
EOF
cat > "$E392SH/chown" <<EOF
#!/usr/bin/env bash
if [[ "\${E392_MODE:-}" == "chown-stage" ]]; then
    for a in "\$@"; do [[ "\$a" == "\${E392_SRC:-}.egresslock-stage."* ]] && exit 1; done
fi
exec /usr/bin/chown "\$@"
EOF
cat > "$E392SH/chmod" <<EOF
#!/usr/bin/env bash
if [[ "\${E392_MODE:-}" == "chmod-stage" ]]; then
    for a in "\$@"; do [[ "\$a" == "\${E392_SRC:-}.egresslock-stage."* ]] && { echo "chmod: injected failure" >&2; exit 1; }; done
fi
exec /usr/bin/chmod "\$@"
EOF
cat > "$E392SH/stat" <<EOF
#!/usr/bin/env bash
if [[ "\${E392_MODE:-}" == "stat-lie" ]]; then
    for a in "\$@"; do
        if [[ "\$a" == */candidate ]]; then echo "600|0|0"; exit 0; fi
    done
fi
exec /usr/bin/stat "\$@"
EOF
cat > "$E392SH/mv" <<EOF
#!/usr/bin/env bash
m392_commit=0
for a in "\$@"; do [[ "\$a" == "\${E392_SRC:-}.egresslock-stage."* ]] && m392_commit=1; done
if (( m392_commit )); then
    case "\${E392_MODE:-}" in
        mv-fail|mv-fail-rm-stage) echo "mv: injected rename failure" >&2; exit 1 ;;
        mv-late-dir)
            rm -f "\${E392_SRC:-}"; mkdir -p "\${E392_SRC:-}"
            : > "\${E392_SRC:-}/sentinel" ;;
        mv-late-symlink)
            rm -f "\${E392_SRC:-}"; ln -s "\${E392_TARGET:-}" "\${E392_SRC:-}" ;;
        mv-pause)
            : > "\${E392_MARK:-/nonexistent}"
            while [[ ! -e "\${E392_RELEASE:-/nonexistent}" ]]; do sleep 0.02; done ;;
    esac
fi
exec /usr/bin/mv "\$@"
EOF
cat > "$E392SH/rm" <<EOF
#!/usr/bin/env bash
if [[ "\${E392_MODE:-}" == *rm-stage* ]]; then
    for a in "\$@"; do
        if [[ "\$a" == "\${E392_SRC:-}.egresslock-stage."* ]]; then
            if [[ "\${E392_MODE:-}" == "rm-stage-pause" && -n "\${E392_MARK:-}" ]]; then
                : > "\$E392_MARK"
                while [[ ! -e "\${E392_RELEASE:-/nonexistent}" ]]; do sleep 0.02; done
            fi
            exit 1
        fi
    done
fi
exec /usr/bin/rm "\$@"
EOF
cat > "$E392SH/podman" <<EOF
#!/usr/bin/env bash
if [[ "\${E392_MODE:-}" == "podman-fail" ]]; then
    echo "podman: injected apply failure" >&2
    exit 1
fi
exec "$TESTROOT/bin/podman" "\$@"
EOF
chmod +x "$E392SH"/*
run392p() { # <mode> <cmd...> — exec so the background pid IS the engine
    local mode="$1"; shift
    exec env PATH="$E392SH:$PATH" E392_MODE="$mode" E392_SRC="$SRC392" \
        E392_TARGET="$S392/targetdir" E392_MARK="$S392/mark" \
        E392_RELEASE="$S392/release" ARCMOCK_PASSWD_HOME="$H392" \
        HOME="$S392" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"
}
e392_wait_mark() {
    local i
    for i in {1..300}; do
        [[ -e "$S392/mark" ]] && return 0
        sleep 0.01
    done
    return 1
}
e392_order() { # <output> <first> <second> -> 1/0
    local a b
    a="$(grep -n -m1 -F "$2" <<<"$1" | cut -d: -f1)"
    b="$(grep -n -m1 -F "$3" <<<"$1" | cut -d: -f1)"
    if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then echo 1; else echo 0; fi
}

reset392
run392 ensure e392 >/dev/null 2>&1
[[ -f "$STATE/running/$GW392" ]] \
    && e392 pass || e392 fail "setup: green ensure seeds the gateway"
rm -rf "$S392/state-pristine"
cp -a "$STATE" "$S392/state-pristine"

# A. success: comments/blanks and existing bytes preserved; multi-entry
#    argv order (including a repeated entry) reported only after commit;
#    0600 mode/owner/group preserved; atomic replacement changes inode.
reset392
printf '# keep this comment\nkeep.example.test:443\n\nkeep2.example.test\n' > "$SRC392"
chmod 600 "$SRC392"
pre_sha="$(e392_sha "$SRC392")"; pre_mode="$(stat -c %a "$SRC392")"
pre_uid="$(stat -c %u "$SRC392")"; pre_gid="$(stat -c %g "$SRC392")"
pre_inode="$(stat -c %i "$SRC392")"; pre_size="$(stat -c %s "$SRC392")"
printf '# keep this comment\nkeep.example.test:443\n\nkeep2.example.test\nnew.example.test\nnew2.example:8443\n' > "$S392/a.expected"
o="$(run392 allow e392 new.example.test new2.example:8443 new.example.test 2>&1)"; rc=$?
if [[ "$rc" == 0 ]] \
   && grep -qxF "added: new.example.test -> $SRC392" <<<"$o" \
   && grep -qxF "added: new2.example:8443 -> $SRC392" <<<"$o" \
   && grep -qxF "entry already present: new.example.test" <<<"$o" \
   && [[ "$(grep -c 'added:' <<<"$o")" == 2 ]] \
   && [[ "$(grep -c 'entry already present:' <<<"$o")" == 1 ]] \
   && cmp -s "$S392/a.expected" "$SRC392" \
   && [[ "$(stat -c %a "$SRC392")" == "$pre_mode" && "$(stat -c %u "$SRC392")" == "$pre_uid" && "$(stat -c %g "$SRC392")" == "$pre_gid" ]] \
   && [[ "$(stat -c %i "$SRC392")" != "$pre_inode" ]] \
   && grep -q 're-ensuring profile' <<<"$o"; then
    e392 pass
else
    e392 fail "A success batch/order/bytes/mode (rc=$rc, out: $o)"
fi
[[ "$(grep -c 'added:\|entry already present:' <<<"$o")" == 3 ]] \
    && e392 pass || e392 fail "A one result line per argv entry (out: $o)"
[[ "$(grep -c '^path: proxy' <<<"$o")" == 1 ]] \
    && e392 pass || e392 fail "A one path disclosure line (out: $o)"
[[ "$(e392_order "$o" 'added: new.example.test' 'added: new2.example:8443')" == 1 ]] \
    && e392 pass || e392 fail "A argv order: new.example.test before new2 (out: $o)"
[[ "$(e392_order "$o" 'added: new2.example:8443' 'entry already present: new.example.test')" == 1 ]] \
    && e392 pass || e392 fail "A argv order: new2 before repeated present (out: $o)"
# The original prefix is byte-identical (size grows by exactly the two lines).
cmp -s -n "$pre_size" "$S392/a.expected" "$SRC392" \
    && e392 pass || e392 fail "A source prefix byte-identical"
# A hard-link peer keeps the pre-rewrite bytes: the rename replaces one
# name only (documented compatibility boundary).
reset392
printf '# keep\nkeep.example.test\n' > "$SRC392"; chmod 600 "$SRC392"
rm -f "$S392/e392-peer"
ln "$S392/e392-allowlist" "$S392/e392-peer"
peer_inode="$(stat -c %i "$S392/e392-peer")"
peer_sha="$(e392_sha "$S392/e392-peer")"
o="$(run392 allow e392 hardlink.example 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$(e392_sha "$S392/e392-peer")" == "$peer_sha" ]] \
   && [[ "$(stat -c %i "$S392/e392-peer")" == "$peer_inode" ]] \
   && [[ "$(stat -c %i "$SRC392")" != "$peer_inode" ]] \
   && [[ "$(grep -cxF 'hardlink.example' "$SRC392")" == 1 ]] \
   && [[ "$(grep -cxF 'hardlink.example' "$S392/e392-peer")" == 0 ]] \
   && grep -qxF "added: hardlink.example -> $SRC392" <<<"$o"; then
    e392 pass
else
    e392 fail "A hard-link peer keeps pre-rewrite bytes (rc=$rc, peer-inode=$(stat -c %i "$S392/e392-peer" 2>/dev/null)/$peer_inode, out: $o)"
fi
rm -f "$S392/e392-peer"

# B. clean no-op: no stage, no inode replacement, still applies; readable
#    0444 / 0644 / symlink sources are allowed when no rewrite is needed.
for b_mode in 600 444 644; do
    reset392
    printf '# keep this comment\nkeep.example.test:443\n\nkeep2.example.test\npresent.example\n' > "$SRC392"
    b_inode="$(stat -c %i "$SRC392")"
    chmod "$b_mode" "$SRC392"
    b_sha="$(e392_sha "$SRC392")"
    rm -f "$S392/mark"
    o="$(run392p mktemp-stage allow e392 present.example 2>&1)"; rc=$?
    if [[ "$rc" == 0 && "$o" == *"entry already present: present.example"* ]] \
       && [[ "$o" != *"added:"* ]] && [[ ! -e "$S392/mark" ]] \
       && [[ "$(stat -c %i "$SRC392")" == "$b_inode" ]] \
       && [[ "$(e392_sha "$SRC392")" == "$b_sha" ]]; then
        e392 pass
    else
        e392 fail "B no-op mode $b_mode (rc=$rc, inode=$(stat -c %i "$SRC392")/$b_inode, mark=$([[ -e $S392/mark ]] && echo yes || echo no), out: $o)"
    fi
done
# 0644 and 0444 no-ops still call ensure (the apply tail survives).
[[ "$(grep -c 're-ensuring profile' <<<"$o")" == 1 ]] \
    && e392 pass || e392 fail "B no-op keeps the apply tail (out: $o)"
# A symlink source with every entry present is a clean no-op: the link
# and its target are untouched.
reset392
printf '# keep this comment\nkeep.example.test:443\n\nkeep2.example.test\npresent.example\n' > "$S392/target-allowlist"
chmod 600 "$S392/target-allowlist"
ln -sfn "$S392/target-allowlist" "$SRC392"
b_sha="$(e392_sha "$S392/target-allowlist")"
o="$(run392 allow e392 present.example 2>&1)"; rc=$?
if [[ "$rc" == 0 && -L "$SRC392" && "$(readlink "$SRC392")" == "$S392/target-allowlist" ]] \
   && [[ "$(e392_sha "$S392/target-allowlist")" == "$b_sha" ]] \
   && [[ "$o" == *"entry already present: present.example"* ]]; then
    e392 pass
else
    e392 fail "B symlink clean no-op (rc=$rc, out: $o)"
fi

# C. newline repair is part of the same transaction: heal-only, heal+add,
#    and a byte-safe final-NUL probe (Bash command substitution would drop
#    the NUL). A read/tail probe error fails before any entry line.
reset392
printf '# alpha\nkeep.example.test' > "$SRC392"; chmod 600 "$SRC392"
o="$(run392 allow e392 keep.example.test 2>&1)"; rc=$?
printf '# alpha\nkeep.example.test\n' > "$S392/c.expected"
if [[ "$rc" == 0 && "$o" == *"entry already present: keep.example.test"* ]] \
   && [[ "$o" != *"added:"* ]] && cmp -s "$S392/c.expected" "$SRC392"; then
    e392 pass
else
    e392 fail "C heal-only repair (rc=$rc, out: $o)"
fi
reset392
printf 'keep.example.test' > "$SRC392"; chmod 600 "$SRC392"
o="$(run392 allow e392 new.example.test 2>&1)"; rc=$?
printf 'keep.example.test\nnew.example.test\n' > "$S392/c2.expected"
if [[ "$rc" == 0 && -s "$SRC392" ]] && cmp -s "$S392/c2.expected" "$SRC392"; then
    e392 pass
else
    e392 fail "C heal then append (rc=$rc, out: $o)"
fi
reset392
printf '# comment\0' > "$SRC392"; chmod 600 "$SRC392"
o="$(run392 allow e392 new.example.test 2>&1)"; rc=$?
printf '# comment\0\nnew.example.test\n' > "$S392/c3.expected"
if [[ "$rc" == 0 ]] && cmp -s "$S392/c3.expected" "$SRC392"; then
    e392 pass
else
    e392 fail "C final NUL preserved + newline heal (rc=$rc, out: $o)"
fi
reset392
printf 'keep.example.test\n' > "$SRC392"; chmod 600 "$SRC392"
c_before="$(e392_sha "$SRC392")"
o="$(run392p tail-src allow e392 keep.example.test 2>&1)"; rc=$?
if [[ "$rc" == 1 ]] && [[ "$(e392_sha "$SRC392")" == "$c_before" ]] && e392_no_result "$o"; then
    e392 pass
else
    e392 fail "C last-byte probe failure named + no lines (rc=$rc, out: $o)"
fi
[[ "$o" == *"cannot read the last byte"* ]] \
    && e392 pass || e392 fail "C last-byte probe names the cause (out: $o)"

# D. non-0600 / symlink rewrites refuse before commit, leave every byte
#    and mode alone, print no entry line and do not apply.
for d_case in "0644 add" "0640 heal" "0444 add" "4600 add"; do
    reset392
    d_mode="${d_case% *}"; d_kind="${d_case#* }"
    if [[ "$d_kind" == heal ]]; then
        printf '# keep\nkeep.example.test' > "$SRC392"
        d_out_arg=keep.example.test
    else
        printf '# keep\nkeep.example.test\n' > "$SRC392"
        d_out_arg=new.example.test
    fi
    d_oct="$d_mode"; [[ "$d_oct" == 0644 ]] && d_oct=644
    [[ "$d_oct" == 0640 ]] && d_oct=640
    [[ "$d_oct" == 0444 ]] && d_oct=444
    [[ "$d_oct" == 4600 ]] && d_oct=4600
    chmod "$d_oct" "$SRC392" 2>/dev/null || true
    d_sha="$(e392_sha "$SRC392")"; d_perm="$(stat -c %a "$SRC392")"
    : > "$STATE/opslog"
    o="$(run392 allow e392 "$d_out_arg" 2>&1)"; rc=$?
    if [[ "$rc" == 1 && "$o" == *"not 0600"* ]] \
       && [[ "$o" == *"its mode is $d_perm, not 0600"* ]] \
       && [[ "$o" == *"chmod 600 -- $SRC392"* ]] \
       && [[ "$o" == *"retry the same egresslock allow command"* ]] \
       && [[ "$o" != *"ensure"* ]] \
       && [[ "$(e392_sha "$SRC392")" == "$d_sha" && "$(stat -c %a "$SRC392")" == "$d_perm" ]] \
       && e392_no_result "$o" && [[ ! -s "$STATE/opslog" ]]; then
        e392 pass
    else
        e392 fail "D $d_case refusal (rc=$rc, mode=$(stat -c %a "$SRC392")/$d_perm, out: $o)"
    fi
done
# Symlink rewrite: link and target bytes/mode unchanged, named refusal.
reset392
printf 'keep.example.test\n' > "$S392/target-allowlist"; chmod 600 "$S392/target-allowlist"
ln -sfn "$S392/target-allowlist" "$SRC392"
t_sha="$(e392_sha "$S392/target-allowlist")"; t_perm="$(stat -c %a "$S392/target-allowlist")"
: > "$STATE/opslog"
o="$(run392 allow e392 link-add.example 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"symbolic link"* && -L "$SRC392" ]] \
   && [[ "$(readlink "$SRC392")" == "$S392/target-allowlist" ]] \
   && [[ "$(e392_sha "$S392/target-allowlist")" == "$t_sha" && "$(stat -c %a "$S392/target-allowlist")" == "$t_perm" ]] \
   && e392_no_result "$o" && [[ ! -s "$STATE/opslog" ]]; then
    e392 pass
else
    e392 fail "D symlink rewrite refusal (rc=$rc, out: $o)"
fi
# Symlink to a 0644 target in a 0700 directory linked from a traversable
# parent must still refuse, and the target must not be written through.
reset392
mkdir -p "$S392/targetdir"; chmod 700 "$S392/targetdir"
printf 'keep.example.test\n' > "$S392/targetdir/secret-allowlist"; chmod 644 "$S392/targetdir/secret-allowlist"
ln -sfn "$S392/targetdir/secret-allowlist" "$SRC392"
t_sha="$(e392_sha "$S392/targetdir/secret-allowlist")"
o="$(run392 allow e392 private-target.example 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"symbolic link"* && -L "$SRC392" ]] \
   && [[ "$(e392_sha "$S392/targetdir/secret-allowlist")" == "$t_sha" ]] \
   && [[ "$(stat -c %a "$S392/targetdir/secret-allowlist")" == 644 ]]; then
    e392 pass
else
    e392 fail "D symlink to 0644 target in 0700 dir (rc=$rc, out: $o)"
fi
# Missing source and a read-only parent still fail named with no apply.
reset392
rm -f "$SRC392"
o="$(run392 allow e392 missing.example 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"allowlist file missing"* && "$o" != *"re-ensuring"* ]] \
    && e392 pass || e392 fail "D missing source named (rc=$rc, out: $o)"
reset392
printf '# keep\nkeep.example.test\n' > "$SRC392"; chmod 600 "$SRC392"
p_sha="$(e392_sha "$SRC392")"
chmod 500 "$S392"
o="$(run392 allow e392 parent-add.example 2>&1)"; rc=$?
chmod 700 "$S392"
if [[ "$rc" == 1 && "$o" == *"cannot create temp staging"* && "$(e392_sha "$SRC392")" == "$p_sha" ]] && e392_no_result "$o"; then
    e392 pass
else
    e392 fail "D read-only parent named (rc=$rc, out: $o)"
fi

# E. injected pre-commit failures: named rc 1, source bytes/mode intact,
#    no entry lines and no apply. Every attributable leg also removes the
#    stage; the rm-stage leg reports the cleanup failure honestly.
for e_mode in mktemp-stage cat-src grep-src chown-stage chmod-stage stat-lie mv-fail; do
    reset392
    printf '# keep\nkeep.example.test\n' > "$SRC392"; chmod 600 "$SRC392"
    e_sha="$(e392_sha "$SRC392")"; e_perm="$(stat -c %a "$SRC392")"
    : > "$STATE/opslog"
    o="$(run392p "$e_mode" allow e392 injected.example 2>&1)"; rc=$?
    if [[ "$rc" == 1 && "$(e392_sha "$SRC392")" == "$e_sha" && "$(stat -c %a "$SRC392")" == "$e_perm" ]] \
       && e392_no_result "$o" && [[ ! -s "$STATE/opslog" ]]; then
        e392 pass
    else
        e392 fail "E $e_mode pre-commit refusal (rc=$rc, out: $o)"
    fi
    [[ -z "$(compgen -G "$SRC392.egresslock-stage.*")" ]] \
        && e392 pass || e392 fail "E $e_mode removes the private stage"
done
# A read failure after the exact-line match on a no-op is still caught.
reset392
printf 'keep.example.test\n' > "$SRC392"; chmod 600 "$SRC392"
e_sha="$(e392_sha "$SRC392")"
o="$(run392p cat-src allow e392 keep.example.test 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$(e392_sha "$SRC392")" == "$e_sha" ]] && e392_no_result "$o"; then
    e392 pass
else
    e392 fail "E no-op full-read failure after early match (rc=$rc, out: $o)"
fi
# Pre-commit cleanup failure: the named cause plus an honest warning.
reset392
printf '# keep\nkeep.example.test\n' > "$SRC392"; chmod 600 "$SRC392"
e_sha="$(e392_sha "$SRC392")"
o="$(run392p mv-fail-rm-stage allow e392 cleanup.example 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$(e392_sha "$SRC392")" == "$e_sha" ]] \
   && [[ "$o" == *"the allowlist was not changed"* ]] \
   && [[ "$o" != *"was replaced"* && "$o" != *"may or may not"* ]] \
   && [[ "$o" == *"could not be removed"* ]] && e392_no_result "$o"; then
    e392 pass
else
    e392 fail "E pre-commit cleanup failure warning (rc=$rc, out: $o)"
fi
rm -rf "$SRC392".egresslock-stage.*
# Post-commit cleanup failure: commit is kept, warning truthful, apply tail
# still runs, and the entry lines are reported.
reset392
printf '# keep\nkeep.example.test\n' > "$SRC392"; chmod 600 "$SRC392"
printf '# keep\nkeep.example.test\npost.example\n' > "$S392/e-post.expected"
o="$(run392p rm-stage allow e392 post.example 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"the allowlist was replaced"* && "$o" == *"could not be removed"* ]] \
   && cmp -s "$S392/e-post.expected" "$SRC392" \
   && grep -qxF "added: post.example -> $SRC392" <<<"$o" \
   && grep -q 're-ensuring profile' <<<"$o"; then
    e392 pass
else
    e392 fail "E post-commit cleanup warning + committed continuation (rc=$rc, out: $o)"
fi
rm -rf "$SRC392".egresslock-stage.*
# Late directory arrival: never move into it and never claim success.
reset392
printf '# keep\nkeep.example.test\n' > "$SRC392"; chmod 600 "$SRC392"
o="$(run392p mv-late-dir allow e392 late.example 2>&1)"; rc=$?
if [[ "$rc" == 1 && -d "$SRC392" && -f "$SRC392/sentinel" ]] && e392_no_result "$o"; then
    e392 pass
else
    e392 fail "E late directory arrival refused (rc=$rc, out: $o)"
fi
rm -rf "$SRC392"
# Late directory-symlink arrival: mv -T replaces the link, never follows
# it into the referent; the referent and its sentinel stay untouched.
reset392
printf '# keep\nkeep.example.test\n' > "$SRC392"; chmod 600 "$SRC392"
mkdir -p "$S392/targetdir"; : > "$S392/targetdir/sentinel"
o="$(run392p mv-late-symlink allow e392 late-link.example 2>&1)"; rc=$?
if [[ "$rc" == 0 && -f "$SRC392" && ! -L "$SRC392" && -f "$S392/targetdir/sentinel" ]] \
   && [[ ! -e "$S392/targetdir/late-link.example" ]] \
   && grep -qxF "added: late-link.example -> $SRC392" <<<"$o"; then
    e392 pass
else
    e392 fail "E late directory-symlink arrival never moves into referent (rc=$rc, out: $o)"
fi

# F. private stage is owner-only 0700 while staging; a TERM during the
#    stage removes it and leaves the source alone.
reset392
printf '# keep\nkeep.example.test\n' > "$SRC392"; chmod 600 "$SRC392"
f_sha="$(e392_sha "$SRC392")"
rm -f "$S392/mark" "$S392/release"
run392p cat-pause allow e392 term.example > "$S392/bg.out" 2>&1 &
f_pid=$!
if e392_wait_mark; then
    f_stage="$(compgen -G "$SRC392.egresslock-stage.*" | head -1)"
    if [[ -n "$f_stage" ]] \
       && [[ "$(stat -c %a "$f_stage")" == 700 ]] \
       && [[ "$(stat -c %u "$f_stage")" == "$(id -u)" ]] \
       && [[ "$(stat -c %a "$f_stage/candidate")" == 600 ]]; then
        e392 pass
    else
        e392 fail "F private stage not owner-only 0700/0600 (stage=$f_stage mode=$(stat -c %a "$f_stage" 2>/dev/null))"
    fi
    kill -TERM "$f_pid" 2>/dev/null || true
    : > "$S392/release"
    f_rc=0; wait "$f_pid" || f_rc=$?
    if [[ "$f_rc" == 143 && "$(e392_sha "$SRC392")" == "$f_sha" ]] \
       && [[ -z "$(compgen -G "$SRC392.egresslock-stage.*")" ]] \
       && e392_no_result "$(cat "$S392/bg.out")"; then
        e392 pass
    else
        e392 fail "F TERM during stage cleanup (rc=$f_rc, out: $(cat "$S392/bg.out"))"
    fi
else
    kill -TERM "$f_pid" 2>/dev/null || true
    : > "$S392/release"
    wait "$f_pid" 2>/dev/null || true
    e392 fail "F staging pause marker did not appear"
fi
# A TERM after the rename but during the stage-directory cleanup (the
# F4 trap window) must report the source as replaced, never "not
# changed"/"may or may not"; the committed bytes stand. The signal
# variant is reachable: the rm shim marks, pauses and fails the
# post-rename stage removal, then the harness TERMs the engine.
reset392
printf '# keep\nkeep.example.test\n' > "$SRC392"; chmod 600 "$SRC392"
printf '# keep\nkeep.example.test\nsig-post.example\n' > "$S392/f-post.expected"
f_sha="$(e392_sha "$S392/f-post.expected")"
rm -f "$S392/mark" "$S392/release"
run392p rm-stage-pause allow e392 sig-post.example > "$S392/bg.out" 2>&1 &
f_pid=$!
if e392_wait_mark; then
    # The pause is post-rename: the commit must already be visible.
    if [[ "$(e392_sha "$SRC392")" == "$f_sha" ]]; then
        e392 pass
    else
        e392 fail "F post-rename pause is before the commit (sha=$(e392_sha "$SRC392"))"
    fi
    kill -TERM "$f_pid" 2>/dev/null || true
    : > "$S392/release"
    f_rc=0; wait "$f_pid" || f_rc=$?
    f_out="$(cat "$S392/bg.out")"
    if [[ "$f_rc" == 143 ]] \
       && [[ "$f_out" == *"the allowlist was replaced"* ]] \
       && [[ "$f_out" == *"could not be removed"* ]] \
       && [[ "$f_out" != *"was not changed"* && "$f_out" != *"may or may not"* ]] \
       && [[ "$(e392_sha "$SRC392")" == "$f_sha" ]]; then
        e392 pass
    else
        e392 fail "F post-rename TERM reports the committed source (rc=$f_rc, out: $f_out)"
    fi
else
    kill -TERM "$f_pid" 2>/dev/null || true
    : > "$S392/release"
    wait "$f_pid" 2>/dev/null || true
    e392 fail "F post-rename cleanup pause marker did not appear"
fi
rm -rf "$SRC392".egresslock-stage.*
# An interruption around the rename can leave the outcome unknown: the
# source must be exactly the old or exactly the new bytes, never torn.
reset392
printf '# keep\nkeep.example.test\n' > "$SRC392"; chmod 600 "$SRC392"
f_old="$(e392_sha "$SRC392")"
printf '# keep\nkeep.example.test\nrename.example\n' > "$S392/f-new.expected"
f_new="$(e392_sha "$S392/f-new.expected")"
rm -f "$S392/mark" "$S392/release"
run392p mv-pause allow e392 rename.example > "$S392/bg.out" 2>&1 &
f_pid=$!
if e392_wait_mark; then
    kill -TERM "$f_pid" 2>/dev/null || true
    : > "$S392/release"
    f_rc=0; wait "$f_pid" || f_rc=$?
    f_now="$(e392_sha "$SRC392" 2>/dev/null || echo missing)"
    if [[ ( "$f_now" == "$f_old" || "$f_now" == "$f_new" ) ]] \
       && [[ "$f_rc" == 143 ]] && [[ -z "$(compgen -G "$SRC392.egresslock-stage.*")" ]]; then
        e392 pass
    else
        e392 fail "F interrupted rename: old/new only, no torn state (rc=$f_rc, sha=$f_now)"
    fi
else
    kill -TERM "$f_pid" 2>/dev/null || true
    : > "$S392/release"
    wait "$f_pid" 2>/dev/null || true
    e392 fail "F rename pause marker did not appear"
fi

# G. real RLIMIT_FSIZE short writes: a copy larger than the limit and a
#    copy that fits but whose added line / heal crosses it both reach the
#    checked cleanup instead of killing the shell.
run392lim() { # <limit-blocks> <cmd...> — optional E392_MODE for a PATH shim
    local lim="$1"; shift
    local mode="${E392_MODE:-}"
    ( ulimit -f "$lim" 2>/dev/null || exit 99
      exec env PATH="$E392SH:$PATH" E392_MODE="$mode" E392_SRC="$SRC392" \
        ARCMOCK_PASSWD_HOME="$H392" HOME="$S392" \
        EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@" )
}
reset392
{ printf '# pad\nkeep.example.test\n'; head -c 2048 /dev/zero | tr '\0' '#' ; printf '\n'; } > "$SRC392"
chmod 600 "$SRC392"
g_sha="$(e392_sha "$SRC392")"
o="$(run392lim 1 allow e392 rlim-copy.example 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$(e392_sha "$SRC392")" == "$g_sha" ]] && e392_no_result "$o" \
   && [[ -z "$(compgen -G "$SRC392.egresslock-stage.*")" ]]; then
    e392 pass
else
    e392 fail "G copy larger than RLIMIT (rc=$rc, out: $o)"
fi
# Copy fits (1000B) but the added line crosses the 1024B limit.
reset392
{ printf '# pad\nkeep.example.test\n'; head -c 980 /dev/zero | tr '\0' '#' ; printf '\n'; } > "$SRC392"
g_size="$(stat -c %s "$SRC392")"
[[ "$g_size" == 1005 ]] || e392 fail "G fixture size expected 1005, got $g_size"
chmod 600 "$SRC392"
g_sha="$(e392_sha "$SRC392")"
o="$(run392lim 1 allow e392 rlim-append-long.example.test 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$(e392_sha "$SRC392")" == "$g_sha" ]] && e392_no_result "$o" \
   && [[ "$o" == *"cannot write the staged allowlist"* ]] \
   && [[ -z "$(compgen -G "$SRC392.egresslock-stage.*")" ]]; then
    e392 pass
else
    e392 fail "G added line crossing RLIMIT (rc=$rc, out: $o)"
fi
# Copy fits at 1023B with no final newline; the one-byte heal reaches the
# 1024B limit and lands (a shell-builtin write at the limit succeeds), so
# the process must not die. A heal followed by an added line that crosses
# the limit must fail through the checked path instead.
reset392
{ printf 'keep.example.test\n'; head -c 1005 /dev/zero | tr '\0' '#' ; } > "$SRC392"
g_size="$(stat -c %s "$SRC392")"
[[ "$g_size" == 1023 ]] || e392 fail "G heal fixture size expected 1023, got $g_size"
chmod 600 "$SRC392"
o="$(E392_MODE=podman-fail run392lim 1 allow e392 keep.example.test 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$rc" != 153 \
   && "$(tail -c 1 "$SRC392" | od -An -tx1 | tr -d ' \n')" == "0a" ]] \
   && [[ "$o" == *"entry already present: keep.example.test"* ]]; then
    e392 pass
else
    e392 fail "G heal-only at RLIMIT boundary survives (rc=$rc, out: $o)"
fi
reset392
{ printf 'keep.example.test\n'; head -c 1005 /dev/zero | tr '\0' '#' ; } > "$SRC392"
chmod 600 "$SRC392"
g_sha="$(e392_sha "$SRC392")"
o="$(run392lim 1 allow e392 rlim-heal-then-append.example.test 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$(e392_sha "$SRC392")" == "$g_sha" ]] && e392_no_result "$o" \
   && [[ "$o" == *"cannot write the staged allowlist"* ]] \
   && [[ -z "$(compgen -G "$SRC392.egresslock-stage.*")" ]]; then
    e392 pass
else
    e392 fail "G heal then added line crossing RLIMIT (rc=$rc, out: $o)"
fi
# Mutation-red: the old in-place append on the same platform leaves a torn
# partial line (recorded, not assumed).
reset392
{ printf 'keep.example.test\n'; head -c 990 /dev/zero | tr '\0' '#' ; } > "$S392/old-append"
old_rc=0
( ulimit -f 1 2>/dev/null; printf 'mutation-red.example.test\n' >> "$S392/old-append" ) 2>/dev/null || old_rc=$?
old_last="$(tail -c 1 "$S392/old-append" | od -An -tx1 | tr -d ' \n')"
if [[ "$old_rc" != 0 && "$old_last" != "0a" ]] \
   && ! grep -qxF 'mutation-red.example.test' "$S392/old-append"; then
    e392 pass
else
    skip "egl392-mutation-red-platform" "old append did not tear on this platform (rc=$old_rc, last=$old_last)"
fi

# H. POSIX ACL pins, created/inspected through system.posix_acl_access
#    (no getfacl/setfacl needed). If the host cannot create ACLs, record
#    the skip; the VM matrix supplies the same checks before handoff.
e392_acl_py() {
    python3 - "$@" <<'PY'
import os, struct, sys
op = sys.argv[1]

def blob(entries):
    out = struct.pack('<I', 2)
    for tag, perm, id_ in entries:
        out += struct.pack('<HHI', tag, perm, id_)
    return out

def entries(raw):
    if len(raw) < 4:
        return []
    out = []
    for i in range(4, len(raw) - 7, 8):
        tag, perm, id_ = struct.unpack('<HHI', raw[i:i+8])
        out.append((tag, perm, id_))
    return out

def eff(path, uid):
    try:
        es = entries(os.getxattr(path, 'system.posix_acl_access'))
    except OSError:
        print('0')
        return
    named = None
    mask = None
    for tag, perm, id_ in es:
        if tag == 0x10:
            mask = perm
        elif tag == 0x02 and id_ == uid:
            named = perm
    print(0 if named is None or mask is None else (named & mask))

if op == 'set-default':
    d, uid, perm = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    os.setxattr(d, 'system.posix_acl_default',
                blob([(0x01, 7, 0xffffffff), (0x02, perm, uid),
                      (0x04, 5, 0xffffffff), (0x10, perm, 0xffffffff),
                      (0x20, 0, 0xffffffff)]))
elif op == 'set-access':
    f, uid, perm = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    os.setxattr(f, 'system.posix_acl_access',
                blob([(0x01, 6, 0xffffffff), (0x02, perm, uid),
                      (0x04, 0, 0xffffffff), (0x10, perm, 0xffffffff),
                      (0x20, 0, 0xffffffff)]))
elif op == 'eff':
    eff(sys.argv[2], int(sys.argv[3]))
elif op == 'has':
    try:
        os.getxattr(sys.argv[2], 'system.posix_acl_access')
        print('1')
    except OSError:
        print('0')
elif op == 'rm-default':
    try:
        os.removexattr(sys.argv[2], 'system.posix_acl_default')
    except OSError:
        pass
PY
}
if ! command -v python3 >/dev/null 2>&1; then
    skip "egl392-acl-tools-absent" "python3 unavailable; POSIX ACL pins skipped on host (run in VM)"
else
    reset392
    mkdir -p "$S392/aclprobe"
    if ! e392_acl_py set-default "$S392/aclprobe" 12345 6 2>/dev/null; then
        skip "egl392-acl-fixture-unavailable" "host cannot create POSIX ACL fixtures; run the ACL pins in the VM"
    else
        : > "$S392/aclprobe/child"
        if [[ "$(e392_acl_py has "$S392/aclprobe/child")" != 1 ]]; then
            skip "egl392-acl-fixture-unavailable" "default ACL did not inherit on this host; run the ACL pins in the VM"
        else
            # ACL-bearing 0600 source + parent default ACL granting uid 12345.
            e392_acl_py set-default "$S392" 12345 6 2>/dev/null || true
            printf '# keep\nkeep.example.test\n' > "$SRC392"
            e392_acl_py set-access "$SRC392" 12345 6 2>/dev/null || true
            chmod 600 "$SRC392"
            h_sha="$(e392_sha "$SRC392")"
            [[ "$(stat -c %a "$SRC392")" == 600 ]] && [[ "$(e392_acl_py has "$SRC392")" == 1 ]] \
                && e392 pass || e392 fail "H ACL-bearing 0600 source fixture"
            rm -f "$S392/mark" "$S392/release"
            run392p mv-pause allow e392 acl.example > "$S392/bg.out" 2>&1 &
            h_pid=$!
            if e392_wait_mark; then
                h_stage="$(compgen -G "$SRC392.egresslock-stage.*" | head -1)"
                h_candidate="$h_stage/candidate"
                if [[ -n "$h_stage" && "$(stat -c %a "$h_stage")" == 700 \
                      && "$(stat -c %a "$h_candidate")" == 600 \
                      && "$(e392_acl_py eff "$h_candidate" 12345)" == 0 ]]; then
                    e392 pass
                else
                    e392 fail "H staged candidate grants no ACL access and stays 0600 (stage=$h_stage)"
                fi
                : > "$S392/release"; h_rc=0; wait "$h_pid" || h_rc=$?
                if [[ "$h_rc" == 0 && "$(stat -c %a "$SRC392")" == 600 ]] \
                   && [[ "$(e392_acl_py eff "$SRC392" 12345)" == 0 ]]; then
                    e392 pass
                else
                    e392 fail "H committed source grants no current ACL access (rc=$h_rc, out: $(cat "$S392/bg.out"))"
                fi
                # Later chmod can activate inherited dormant entries: the
                # mode-600 mask is what keeps them inert at commit time.
                chmod 640 "$SRC392"
                if [[ "$(e392_acl_py eff "$SRC392" 12345)" != 0 ]]; then
                    e392 pass
                else
                    skip "egl392-acl-dormant" "no inherited dormant ACL entry on this host; documented warning still required"
                fi
            else
                kill -TERM "$h_pid" 2>/dev/null || true
                : > "$S392/release"; wait "$h_pid" 2>/dev/null || true
                e392 fail "H ACL staging pause marker did not appear"
            fi
            e392_acl_py rm-default "$S392" 2>/dev/null || true
            # A non-0600 ACL-bearing source still refuses on mode alone.
            reset392
            printf '# keep\nkeep.example.test\n' > "$SRC392"
            e392_acl_py set-access "$SRC392" 12345 6 2>/dev/null || true
            chmod 644 "$SRC392"
            h_sha="$(e392_sha "$SRC392")"
            o="$(run392 allow e392 acl-refuse.example 2>&1)"; rc=$?
            if [[ "$rc" == 1 && "$o" == *"not 0600"* && "$(e392_sha "$SRC392")" == "$h_sha" ]] \
               && [[ "$o" == *"chmod 600 -- $SRC392"* ]] && [[ "$o" != *"ensure"* ]] \
               && [[ "$(stat -c %a "$SRC392")" == 644 ]] && e392_no_result "$o"; then
                e392 pass
            else
                e392 fail "H non-0600 ACL source refuses on mode (rc=$rc, out: $o)"
            fi
        fi
    fi
fi

reset392
section_end egl392

section_begin egl391 "EGL-391 disk-full (ENOSPC) write-path robustness"
e391() { assert "$@"; }

# The fixture is isolated from every other section: its own conf home,
# its own canonical conf/pins/state image, and section-local shims. The
# engine reads only ordinary environment/PATH (no test hook); the shims
# below fail a named write point, and the real-filesystem legs use a
# private `unshare -rm` tmpfs. No `/dev/full` target is used anywhere.
S391="$TESTROOT/s391"; rm -rf "$S391"; mkdir -p "$S391"
cat > "$S391/e391.conf" <<'EOF'
profile e391 10.199.191.0/24
    rule allow-host keep.example.test:443
    rule allow-host keep2.example.test:8443
    rule gateway-only
    gateway 10.199.191.2 3128 e391-allowlist
EOF
: > "$S391/e391-allowlist"; chmod 600 "$S391/e391-allowlist"
H391="$(conf_home "$S391/e391.conf")"
export ARCMOCK_DNS_BASE="${ARCMOCK_DNS_BASE},keep.example.test=192.0.2.10,keep2.example.test=192.0.2.12,other.example.test=192.0.2.20,new391.example.test=192.0.2.30"
export TESTROOT

run391() { env ARCMOCK_PASSWD_HOME="$H391" HOME="$S391" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"; }
run391i() { # <fail-mode> <cmd...> — BASH_ENV one-shot write failure on the engine's builtin printf
    local fail="$1"; shift
    env BASH_ENV="$S391/inject.sh" E391_FAIL="$fail" E391_COUNT="$S391/inject-count" \
        E391_CONF="$S391/e391.conf" ARCMOCK_PASSWD_HOME="$H391" HOME="$S391" \
        EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"
}
run391p() { # <comma-modes> <cmd...> — PATH shims fail only the named leg
    local modes="$1"; shift
    env PATH="$E391SH:$PATH" E391_MODE="$modes" E391_REC="$H391/.config/egresslock/e391.pins" \
        E391_LOCK="$H391/.local/state/egresslock/engine.lock" E391_MARK="$S391/mark" \
        E391_RM_MARK="$S391/l7-rm" E391_ARM="$S391/l18-arm" E391_RACE_MARK="$S391/l12-race" \
        ARCMOCK_PASSWD_HOME="$H391" HOME="$S391" \
        EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"
}
run391lp() { # <fail-mode> <cmd...> — lock warning + pause at the first `ip saddr` emission
    local fail="$1"; shift
    env BASH_ENV="$S391/inject.sh" E391_FAIL="$fail" E391_PAUSE='ip saddr' \
        E391_MARK="$S391/mark" E391_RELEASE="$S391/release" \
        ARCMOCK_PASSWD_HOME="$H391" HOME="$S391" EGRESSLOCK_SKIP_NETNS_PROBE=1 egresslock "$@"
}

# --- section-local injection launcher --------------------------------------
# BASH_ENV overrides the engine's builtin `printf` for exactly this
# process: the `$0` gate keeps every child bash (mock podman/nft, shims)
# on the builtin, so a mock's own rendering cannot consume/count an
# injection. Modes:
#   lock-record    - the ~50-byte holder record write fails (S1)
#   anti-spoof:N   - the Nth anti-spoof nft-input emission fails (L5);
#                    both the fixed `printf` form and the pre-fix `echo`
#                    form are intercepted, so the mutation instrument
#                    bites after the write form changed (R-EGL-391-3 F4)
#   policy-close   - the closing `}` policy emission fails (L6)
#   conf-write     - the direct-conf temp write fails (L13/L14)
#   verify-header  - verify's `.new` forward-hook header write fails (L8)
# E391_PAUSE also holds the engine (mark + release file) at a chosen
# emission so a contender can race the held account lock (L1/L2).
cat > "$S391/inject.sh" <<'EOF'
case "${0##*/}" in
    egresslock) ;;
    *) return 0 ;;
esac
__e391_anti_spoof() { # <arg> — count and maybe fail the Nth anti-spoof write
    [[ "${1-}" == 'iifname != '* ]] || return 1
    local want="${E391_FAIL#anti-spoof:}" n=0
    [[ -f "$E391_COUNT" ]] && { read -r n < "$E391_COUNT" || true; }
    n=$((n + 1)); echo "$n" > "$E391_COUNT"
    [[ "$n" == "$want" ]] && return 0
    return 1
}
printf() {
    local fmt="${1-}" arg="${2-}"
    if [[ -n "${E391_FAIL:-}" ]]; then
        case "$E391_FAIL" in
        lock-record)
            if [[ "$fmt" == 'pid=%s mode=%s started=%s\n' ]]; then
                echo "egl391: injected holder-record write failure" >&2
                return 1
            fi ;;
        anti-spoof:*)
            if [[ "$fmt" == '%s\n' ]] && __e391_anti_spoof "$arg"; then
                return 1
            fi ;;
        policy-close)
            if [[ "$fmt" == '%s\n' && "$arg" == '}' ]]; then return 1; fi ;;
        verify-header)
            if [[ "$fmt" == '%s\n' && "$arg" == 'type filter hook forward priority -150; policy accept;' ]]; then
                echo "egl391: injected verify header write failure" >&2
                return 1
            fi ;;
        conf-write)
            if [[ "$fmt" == '%s\n' && -n "${E391_CONF:-}" ]]; then
                # fd 1 of the shell ($$), not of the readlink process:
                # the conf writer's redirection is on the function call.
                local tgt; tgt="$(readlink "/proc/$$/fd/1" 2>/dev/null || true)"
                if [[ "$tgt" == "$E391_CONF".* ]]; then return 1; fi
            fi ;;
        esac
    fi
    if [[ -n "${E391_PAUSE:-}" && "$fmt" == '%s\n' && "$arg" == *"$E391_PAUSE"* && ! -e "$E391_MARK" ]]; then
        : > "$E391_MARK"
        while [[ ! -e "$E391_RELEASE" ]]; do sleep 0.02; done
    fi
    builtin printf "$@"
}
echo() {
    # R-EGL-391-3 F4: the pre-fix compiler emitted the anti-spoof line
    # with `echo`; intercept that form too so mutation-red can prove the
    # injection was consumed and the old code installed an incomplete
    # chain. Only the anti-spoof argument is counted; everything else
    # falls through to the builtin untouched.
    if [[ "${E391_FAIL:-}" == anti-spoof:* && $# -eq 1 ]] \
       && __e391_anti_spoof "$1"; then
        return 1
    fi
    builtin echo "$@"
}
EOF

# --- section-local PATH shims ----------------------------------------------
# Each shim is inert unless E391_MODE names its comma-separated mode, and
# delegates to the real tool otherwise (the EGL-246/EGL-392 precedent).
E391SH="$S391/bin"; mkdir -p "$E391SH"
cat > "$E391SH/mktemp" <<'EOF'
#!/usr/bin/env bash
case ",${E391_MODE:-}," in
    *,policy-mktemp,*) for a in "$@"; do [[ "$a" == *egresslock-policy.* ]] && exit 1; done ;;
esac
case ",${E391_MODE:-}," in
    *,pin-mktemp,*)
        for a in "$@"; do
            [[ "$a" == *"/e391.pins."?????? ]] || continue
            # Arm the section-local holder-probe shim only after the pin
            # write has failed (L18) — never during the ensure itself.
            [[ -n "${E391_ARM:-}" ]] && : > "$E391_ARM"
            exit 1
        done ;;
esac
case ",${E391_MODE:-}," in
    *,verify-mktemp,*) for a in "$@"; do [[ "$a" == *egresslock-verify.* ]] && exit 1; done ;;
esac
exec /usr/bin/mktemp "$@"
EOF
cat > "$E391SH/mv" <<'EOF'
#!/usr/bin/env bash
case ",${E391_MODE:-}," in
    *,verify-mv,*) for a in "$@"; do [[ "$a" == *egresslock-verify.* ]] && exit 1; done ;;
esac
if [[ ",${E391_MODE:-}," == *",mv-race,"* ]]; then
    # R-EGL-391-3 F4: win the race independently of the `-T` flag so a
    # plain-`mv` mutant cannot dodge it. Replace the target leaf with a
    # directory immediately before the real rename; `-T` then refuses,
    # while a plain mv moves the temp INTO the directory.
    for a in "$@"; do
        if [[ "$a" == *"/e391.pins" ]]; then
            rm -f "$a"; mkdir -p "$a"; : > "$a/sentinel"
            [[ -n "${E391_RACE_MARK:-}" ]] && : > "$E391_RACE_MARK"
            break
        fi
    done
fi
exec /usr/bin/mv "$@"
EOF
cat > "$E391SH/podman" <<'EOF'
#!/usr/bin/env bash
# L18: after the pin write has failed (E391_ARM), answer the
# disclosure's holder observations in the named state and delegate every
# other call. Non-match modes keep the mock's normal answer.
if [[ -n "${E391_ARM:-}" && -f "$E391_ARM" ]]; then
    if [[ "${1:-}" == ps && " $* " != *" -a "* ]]; then
        case ",${E391_MODE:-}," in
            *,holder-ps-fail,*) echo "Error: unable to connect to Podman: cannot invoke Podman API" >&2; exit 125 ;;
            *,holder-hidden,*) exit 0 ;;
        esac
    elif [[ "${1:-}" == unshare ]]; then
        case ",${E391_MODE:-}," in
            *,holder-chain-absent,*) echo "Error: No such file or directory" >&2; exit 1 ;;
            *,holder-chain-fail,*) echo "Error: mock netlink read failed" >&2; exit 1 ;;
        esac
    fi
fi
exec "$TESTROOT/bin/podman" "$@"
EOF
cat > "$E391SH/nft" <<'EOF'
#!/usr/bin/env bash
case ",${E391_MODE:-}," in
    *,nft-fail-once,*) for a in "$@"; do [[ "$a" == "-f" ]] && exit 1; done ;;
esac
exec "$TESTROOT/bin/nft" "$@"
EOF
cat > "$E391SH/rm" <<'EOF'
#!/usr/bin/env bash
case ",${E391_MODE:-}," in
    *,rm-policy-fail,*)
        for a in "$@"; do
            if [[ "$a" == *egresslock-policy.* ]]; then : > "${E391_RM_MARK:?}"; exit 1; fi
        done ;;
esac
exec /usr/bin/rm "$@"
EOF
cat > "$E391SH/flock" <<'EOF'
#!/usr/bin/env bash
case ",${E391_MODE:-}," in
    *,lock-truncate,*)
        if [[ -n "${E391_LOCK:-}" && -f "$E391_LOCK" ]]; then rm -f "$E391_LOCK"; mkdir -p "$E391_LOCK"; fi ;;
esac
exec /usr/bin/flock "$@"
EOF
chmod +x "$E391SH"/*

e391_nft_f() { grep -c '^nft -f ' "$STATE/callorder.log" 2>/dev/null || true; }
e391_tmpcount() { find /tmp -maxdepth 1 -name "$1" 2>/dev/null | wc -l; }
e391_wait_mark() { local i; for i in {1..500}; do [[ -e "$S391/mark" ]] && return 0; sleep 0.01; done; return 1; }
e391_chain_same() { cmp -s "$S391/chain-pristine" "$STATE/nft/egresslock.p_e391"; }
e391_no_s3() { [[ "$1" != *"this run applied new firewall rules"* ]]; }
e391_conf_same() { cmp -s "$S391/conf-pristine" "$S391/e391.conf"; }

reset391() {
    rm -rf "$STATE"; cp -a "$S391/state-pristine" "$STATE"
    : > "$STATE/callorder.log"
    rm -rf "$S391/e391.pins" "$S391/real-pins"
    cp "$S391/pins-pristine" "$S391/e391.pins"; chmod 600 "$S391/e391.pins"
    cp "$S391/conf-pristine" "$S391/e391.conf"
    : > "$S391/e391-allowlist"; chmod 600 "$S391/e391-allowlist"
    rm -f "$S391/inject-count" "$S391/mark" "$S391/release" "$S391/l7-rm" \
          "$S391/l18-arm" "$S391/l12-race"
    rm -rf "$H391/.local/state/egresslock/engine.lock"
    : > "$H391/.local/state/egresslock/engine.lock"
}

# Seed the pristine image: one green ensure, then freeze conf/pins/state.
run391 ensure e391 >/dev/null 2>&1; e391_rc=$?
if [[ "$e391_rc" == 0 && -f "$S391/e391.pins" && -f "$STATE/nft/egresslock.p_e391" ]]; then
    e391 pass
else
    e391 fail "setup: green ensure seeds the pin record and chain (rc=$e391_rc)"
fi
cp "$S391/e391.conf" "$S391/conf-pristine"
cp "$S391/e391.pins" "$S391/pins-pristine"
cp "$STATE/nft/egresslock.p_e391" "$S391/chain-pristine"
rm -rf "$S391/state-pristine"; cp -a "$STATE" "$S391/state-pristine"
reset391

# --- L1/L2: lock holder-record failure is a diagnostic (S1), the lock is
# held, and a contender does not run. Mutation-red: the pre-fix engine
# dies on the raw printf/write error at the holder record.
reset391
( run391lp lock-record verify e391 >"$S391/l1.out" 2>&1; echo $? >"$S391/l1.rc" ) &
e391_l1pid=$!
if e391_wait_mark; then e391 pass; else e391 fail "L1: verify paused at the expected-rules emission"; fi
EGRESSLOCK_LOCK_WAIT=1 run391 ensure e391 >"$S391/l1c.out" 2>&1; e391_l1c=$?
: > "$S391/release"; wait "$e391_l1pid" 2>/dev/null || true
o="$(cat "$S391/l1.out")"; rc="$(cat "$S391/l1.rc" 2>/dev/null || echo 99)"
if [[ "$rc" == 0 && "$o" == *"the account lock could not record who holds it"* \
      && "$o" == *"the lock is held for this run"* \
      && "$o" == *'may show "holder: unknown" or a stale record'* \
      && "$o" == *"policy and gateway verified"* ]]; then
    e391 pass
else
    e391 fail "L1: read-lock record failure prints S1 and verify stays green (rc=$rc, out: $o)"
fi
o="$(cat "$S391/l1c.out")"
if [[ "$e391_l1c" == 1 && "$o" == *"another egresslock command is running"* \
      && "$(e391_nft_f)" == 0 ]]; then
    e391 pass
else
    e391 fail "L1: contender did not run while the shared lock was held (rc=$e391_l1c, nft=$(e391_nft_f), out: $o)"
fi

reset391
( run391lp lock-record ensure e391 >"$S391/l2.out" 2>&1; echo $? >"$S391/l2.rc" ) &
e391_l2pid=$!
if e391_wait_mark; then e391 pass; else e391 fail "L2: ensure paused at the expected-rules emission"; fi
EGRESSLOCK_LOCK_WAIT=1 run391 ensure e391 >"$S391/l2c.out" 2>&1; e391_l2c=$?
: > "$S391/release"; wait "$e391_l2pid" 2>/dev/null || true
o="$(cat "$S391/l2.out")"; rc="$(cat "$S391/l2.rc" 2>/dev/null || echo 99)"
if [[ "$rc" == 0 && "$o" == *"the account lock could not record who holds it"* \
      && "$o" == *"profile 'e391' ready"* ]]; then
    e391 pass
else
    e391 fail "L2: write-lock record failure prints S1 and ensure converges (rc=$rc, out: $o)"
fi
o="$(cat "$S391/l2c.out")"
if [[ "$e391_l2c" == 1 && "$o" == *"another egresslock command is running"* \
      && "$o" == *"holder: unknown"* && "$(e391_nft_f)" == 1 ]]; then
    e391 pass
else
    e391 fail "L2: writer contender did not run after the failed record (rc=$e391_l2c, nft=$(e391_nft_f), out: $o)"
fi

# --- L3: open/truncate stay named-fatal. A directory at the lock path
# fails the append-open; the flock shim replaces the open file with a
# directory between open and the writer truncate.
reset391
rm -rf "$H391/.local/state/egresslock/engine.lock"
mkdir -p "$H391/.local/state/egresslock/engine.lock"
o="$(run391 verify e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"cannot open the account lock"* && "$o" == *"(fail closed)"* ]]; then
    e391 pass
else
    e391 fail "L3: open failure stays named-fatal (rc=$rc, out: $o)"
fi
reset391
o="$(run391p lock-truncate ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"cannot truncate the account lock record"* \
      && "$o" == *"(fail closed)"* && "$(e391_nft_f)" == 0 ]]; then
    e391 pass
else
    e391 fail "L3: truncate failure stays named-fatal (rc=$rc, nft=$(e391_nft_f), out: $o)"
fi

# --- L4: policy mktemp failure (S4) -> named, no nft -f, chain/pins
# byte-identical. Mutation-red: pre-fix dies with the raw shell error.
reset391
o="$(run391p policy-mktemp ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 1 \
      && "$o" == *"Error: cannot create a temporary policy file in /tmp: the firewall is unchanged"* \
      && "$(e391_nft_f)" == 0 && e391_chain_same ]] \
   && cmp -s "$S391/pins-pristine" "$S391/e391.pins" && e391_no_s3 "$o"; then
    e391 pass
else
    e391 fail "L4: policy mktemp S4/no-apply (rc=$rc, nft=$(e391_nft_f), out: $o)"
fi

# --- L5: a middle emission (install-copy anti-spoof) fails; a later
# emission must not rescue the build. Assert no nft -f and the prior
# chain byte-identical. Mutation-red: the pre-fix engine installed the
# valid-but-weaker chain (the A4 reproduction). The count file proves
# occurrence 1 (snapshot) succeeded and occurrence 2 failed.
reset391
o="$(run391i anti-spoof:2 ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 1 \
      && "$o" == *"Error: cannot write the temporary policy file for profile 'e391' in /tmp: the firewall is unchanged"* \
      && "$(e391_nft_f)" == 0 && e391_chain_same \
      && "$(cat "$S391/inject-count" 2>/dev/null)" == 2 ]] \
   && cmp -s "$S391/pins-pristine" "$S391/e391.pins" && e391_no_s3 "$o"; then
    e391 pass
else
    e391 fail "L5: middle-emission failure aborts before nft -f (rc=$rc, nft=$(e391_nft_f), count=$(cat "$S391/inject-count" 2>/dev/null), chain=$(sha256sum "$STATE/nft/egresslock.p_e391" 2>/dev/null | cut -d' ' -f1)/$(sha256sum "$S391/chain-pristine" | cut -d' ' -f1), out: $o)"
fi

# --- L6: the closing policy write fails (S5), temp removed, no apply.
reset391
e391_pol_before="$(e391_tmpcount 'egresslock-policy.*')"
o="$(run391i policy-close ensure e391 2>&1)"; rc=$?
e391_pol_after="$(e391_tmpcount 'egresslock-policy.*')"
if [[ "$rc" == 1 \
      && "$o" == *"Error: cannot write the temporary policy file for profile 'e391' in /tmp: the firewall is unchanged"* \
      && "$(e391_nft_f)" == 0 && e391_chain_same \
      && "$e391_pol_after" == "$e391_pol_before" ]] && e391_no_s3 "$o"; then
    e391 pass
else
    e391 fail "L6: final policy write S5/temp cleanup (rc=$rc, nft=$(e391_nft_f), tmp $e391_pol_before->$e391_pol_after, out: $o)"
fi

# --- L7: a cleanup `rm` failure must not mask the primary install
# failure. The nft shim fails -f; the rm shim fails the policy-temp
# cleanup (marker proves it fired). The named nft failure and rc survive.
reset391
o="$(run391p nft-fail-once,rm-policy-fail ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && -e "$S391/l7-rm" \
      && "$o" == *"Error: nft policy install failed for profile 'e391' (fail closed)"* \
      && "$o" != *"cannot create a temporary policy file"* \
      && "$o" != *"cannot write the temporary policy file"* \
      && "$(e391_nft_f)" == 0 ]] && e391_no_s3 "$o"; then
    e391 pass
else
    e391 fail "L7: cleanup rm failure preserves the primary rc/message (rc=$rc, mark=$([[ -e $S391/l7-rm ]] && echo yes || echo no), out: $o)"
fi

# --- L8: verify /tmp temp operations name S9, never a false-green or a
# spurious chain-mismatch. A named pin-record failure keeps priority.
reset391
e391_tmp_before="$(e391_tmpcount 'egresslock-verify.*')"
o="$(run391p verify-mktemp verify e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"verify: cannot write the temporary expected-ruleset file in /tmp; the policy could not be checked (exit 1)"* \
      && "$o" != *"does not match"* ]]; then
    e391 pass
else
    e391 fail "L8: verify mktemp S9 (rc=$rc, out: $o)"
fi
o="$(run391p verify-mv verify e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"verify: cannot write the temporary expected-ruleset file in /tmp; the policy could not be checked (exit 1)"* \
      && "$o" != *"does not match"* ]]; then
    e391 pass
else
    e391 fail "L8: verify rename S9 (rc=$rc, out: $o)"
fi
o="$(run391i anti-spoof:1 verify e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"verify: cannot write the temporary expected-ruleset file in /tmp; the policy could not be checked (exit 1)"* \
      && "$o" != *"does not match"* ]]; then
    e391 pass
else
    e391 fail "L8: verify expected-write S9 (rc=$rc, out: $o)"
fi
if [[ "$(e391_tmpcount 'egresslock-verify.*')" == "$e391_tmp_before" ]]; then
    e391 pass
else
    e391 fail "L8: verify temp cleanup (before=$e391_tmp_before after=$(e391_tmpcount 'egresslock-verify.*'))"
fi
rm -f "$S391/e391.pins"
o="$(run391p verify-mv verify e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"verify: pin record missing for profile 'e391'"* \
      && "$o" != *"cannot write the temporary expected-ruleset file"* ]]; then
    e391 pass
else
    e391 fail "L8: named pin-record failure is not replaced by S9 (rc=$rc, out: $o)"
fi
# R-EGL-391-3 F1/F4: the `.new` rewrite's forward-hook header is its own
# checked write. A failed header followed by a successful `cat` must not
# verify a chain that has no hook. With the hook present the failure is
# S9; with it absent the control (no injection) is the only run allowed
# to report the mismatch — and even then the verdict is rc 1.
reset391
o="$(run391i verify-header verify e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"verify: cannot write the temporary expected-ruleset file in /tmp; the policy could not be checked (exit 1)"* \
      && "$o" != *"does not match"* ]]; then
    e391 pass
else
    e391 fail "L8: header write failure with the hook present is S9 (rc=$rc, out: $o)"
fi
reset391
sed -i '/type filter hook forward/d' "$STATE/nft/egresslock.p_e391"
o="$(run391i verify-header verify e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"verify: cannot write the temporary expected-ruleset file in /tmp; the policy could not be checked (exit 1)"* \
      && "$o" != *"policy and gateway verified"* && "$o" != *"does not match"* ]]; then
    e391 pass
else
    e391 fail "L8: hookless chain + header write failure is S9, not false green (rc=$rc, out: $o)"
fi
reset391
sed -i '/type filter hook forward/d' "$STATE/nft/egresslock.p_e391"
o="$(run391 verify e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"policy chain p_e391 does not match the expected ruleset"* \
      && "$o" != *"policy and gateway verified"* ]]; then
    e391 pass
else
    e391 fail "L8: no-injection control still reports the hookless-chain mismatch (rc=$rc, out: $o)"
fi

# --- L9: changed pin + pin-record mktemp failure -> S2 + S3 (chain new,
# record old, verify rc 1). The S3 state is the probed running holder.
reset391
sed -i 's/keep\.example\.test:443/other.example.test:443/' "$S391/e391.conf"
o="$(run391p pin-mktemp ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 1 \
      && "$o" == *"Error: cannot write the pin record "* \
      && "$o" == *"the stored list of allowed addresses was not updated by this run"* \
      && "$o" == *"ensure: this run applied new firewall rules for profile 'e391' but did not update the pin record"* \
      && "$o" == *"state: firewall rules are present (holder container running)"* \
      && "$o" == *"next action: fix the underlying failure, then inspect and re-run: egresslock ensure e391"* \
      && "$(e391_nft_f)" == 1 ]] \
   && grep -q '192.0.2.20' "$STATE/nft/egresslock.p_e391" \
   && ! grep -q '192.0.2.10' "$STATE/nft/egresslock.p_e391" \
   && cmp -s "$S391/pins-pristine" "$S391/e391.pins"; then
    e391 pass
else
    e391 fail "L9: changed-pin S2+S3 chain-new/record-old (rc=$rc, nft=$(e391_nft_f), out: $o)"
fi
o="$(run391 verify e391 2>&1)"; rc=$?
if [[ "$rc" == 1 ]]; then e391 pass; else e391 fail "L9: verify after the split fails closed (rc=$rc, out: $o)"; fi

# --- L10: same pin + pin-record write failure -> S3, chain rebuilt,
# record still matches, verify rc 0 (the bounded "may pass" claim).
reset391
o="$(run391p pin-mktemp ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"cannot write the pin record"* \
      && "$o" == *"ensure: this run applied new firewall rules"* \
      && "$o" == *"state: firewall rules are present (holder container running)"* \
      && "$(e391_nft_f)" == 1 ]] \
   && cmp -s "$S391/pins-pristine" "$S391/e391.pins"; then
    e391 pass
else
    e391 fail "L10: unchanged-pin S2+S3 (rc=$rc, nft=$(e391_nft_f), out: $o)"
fi
o="$(run391 verify e391 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"policy and gateway verified"* ]]; then
    e391 pass
else
    e391 fail "L10: verify may pass when the stored pins already match (rc=$rc, out: $o)"
fi

# --- L11: pin commit target protection. A directory/symlink is refused
# pre-swap (S8, no nft -f); a zero-allow-host profile warns S7 and still
# succeeds. A direct disallow post-swap pin failure keeps the path's
# recovery line and suppresses the unconditional ensure next-action.
reset391
sed -i 's/keep\.example\.test:443/other.example.test:443/' "$S391/e391.conf"
rm -rf "$S391/e391.pins"; mkdir "$S391/e391.pins"
o="$(run391 ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"Error: the pin record path "* \
      && "$o" == *"is not a regular file; refusing to replace it (the firewall was not changed; move it aside and re-run: egresslock ensure e391)"* \
      && "$(e391_nft_f)" == 0 && e391_chain_same ]]; then
    e391 pass
else
    e391 fail "L11: directory pin target refused pre-swap (rc=$rc, nft=$(e391_nft_f), out: $o)"
fi
reset391
sed -i 's/keep\.example\.test:443/other.example.test:443/' "$S391/e391.conf"
rm -rf "$S391/e391.pins"; printf 'x\n' > "$S391/real-pins"; ln -s "$S391/real-pins" "$S391/e391.pins"
o="$(run391 ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"is a symbolic link; refusing to replace it (the firewall was not changed; move it aside and re-run: egresslock ensure e391)"* \
      && "$(e391_nft_f)" == 0 && e391_chain_same ]]; then
    e391 pass
else
    e391 fail "L11: symlink pin target refused pre-swap (rc=$rc, nft=$(e391_nft_f), out: $o)"
fi
reset391
sed -i '/rule allow-host/d' "$S391/e391.conf"
rm -rf "$S391/e391.pins"; mkdir "$S391/e391.pins"
o="$(run391 ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"warning: could not remove the stale pin record "* \
      && "$o" == *"verify does not use the pin record for a profile with no allow-hosts"* \
      && "$o" != *"cannot write the pin record"* && -d "$S391/e391.pins" ]]; then
    e391 pass
else
    e391 fail "L11: zero-pin S7 warning keeps ensure rc 0 (rc=$rc, out: $o)"
fi
o="$(run391 verify e391 2>&1)"; rc=$?
if [[ "$rc" == 0 ]]; then e391 pass; else e391 fail "L11: zero-pin verify stays green (rc=$rc, out: $o)"; fi
# Direct-disallow context: the pin write fails after the swap while the
# rule removal is in flight. S3 keeps the state sentence but no
# `next action` (the path's drop-unauthorized recovery leads).
reset391
o="$(run391p pin-mktemp disallow e391 --direct keep.example.test:443 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"cannot write the pin record"* \
      && "$o" == *"disallow --direct: the revocation is only half done"* \
      && "$o" == *"drop-unauthorized e391 443"* \
      && "$o" == *"state: firewall rules are present (holder container running)"* \
      && "$o" != *"next action: fix the underlying failure, then inspect and re-run: egresslock ensure"* ]]; then
    e391 pass
else
    e391 fail "L11: disallow-context S3 suppresses the ensure next action (rc=$rc, out: $o)"
fi

# --- L12: `mv -T` on a late directory target: the temp is not absorbed
# into the directory; S2 names the failed record commit. Mutation-red:
# a plain mv would move the temp inside and still exit 0.
reset391
o="$(run391p mv-race ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && -e "$S391/l12-race" && "$o" == *"cannot write the pin record"* \
      && -d "$S391/e391.pins" \
      && "$(ls -A "$S391/e391.pins" 2>/dev/null)" == "sentinel" \
      && -z "$(find "$S391" -maxdepth 1 -name 'e391.pins.*' -print -quit)" ]]; then
    e391 pass
else
    e391 fail "L12: mv -T does not absorb the temp into a directory target (rc=$rc, race=$([[ -e $S391/l12-race ]] && echo fired || echo missed), type=$(stat -c %F "$S391/e391.pins" 2>/dev/null), dir=[$(ls -A "$S391/e391.pins" 2>/dev/null | tr '\n' ' ')], out: $o)"
fi

# --- L13/L14: direct conf temp-write failure dies S6; the conf bytes are
# unchanged and no false already-present/invalid-config/added/removed/
# ensure path runs. Mutation-red: pre-fix fell through to load_config
# (`invalid config`) and allow still ran cmd_ensure.
reset391
o="$(run391i conf-write allow e391 --direct new391.example.test:8443 2>&1)"; rc=$?
if [[ "$rc" == 1 \
      && "$o" == *"Error: cannot write the new config next to "* \
      && "$o" == *"the temporary file could not be written; the config was not replaced by this run"* \
      && "$o" != *"invalid config"* && "$o" != *"already present"* \
      && "$o" != *"added:"* && "$o" != *"re-ensuring profile"* \
      && "$(e391_nft_f)" == 0 ]] && e391_conf_same \
   && [[ -z "$(find "$S391" -maxdepth 1 -name 'e391.conf.*' -print -quit)" ]]; then
    e391 pass
else
    e391 fail "L13: direct allow write failure S6/no-fallthrough (rc=$rc, nft=$(e391_nft_f), out: $o)"
fi
reset391
o="$(run391i conf-write disallow e391 --direct keep.example.test:443 2>&1)"; rc=$?
if [[ "$rc" == 1 \
      && "$o" == *"Error: cannot write the new config next to "* \
      && "$o" == *"the config was not replaced by this run"* \
      && "$o" != *"removed:"* && "$o" != *"rule not present"* \
      && "$(e391_nft_f)" == 0 ]] && e391_conf_same; then
    e391 pass
else
    e391 fail "L14: direct disallow write failure S6/conf-identical (rc=$rc, nft=$(e391_nft_f), out: $o)"
fi

# --- L16/L17: S8's `next action` is context-suppressed in the two
# disallow lanes (R-EGL-391-3 F2/D6). The lane's own restore advice is
# the next action; a plain `ensure` there would contradict it.
reset391
cp "$S391/pins-pristine" "$S391/real-pins"
rm -f "$S391/e391.pins"; ln -s "$S391/real-pins" "$S391/e391.pins"
o="$(run391 disallow e391 --direct keep.example.test:443 2>&1)"; rc=$?
if [[ "$rc" == 1 \
      && "$o" == *"Error: the pin record path "*" is a symbolic link; refusing to replace it (the firewall was not changed)"* \
      && "$o" != *"(the firewall was not changed; move it aside"* \
      && "$o" != *"egresslock ensure"* \
      && "$o" == *"disallow --direct: nothing was revoked"* \
      && "$o" == *"retry: egresslock disallow e391 keep.example.test:443"* \
      && "$(e391_nft_f)" == 0 && e391_chain_same ]] && e391_conf_same; then
    e391 pass
else
    e391 fail "L16: direct-disallow S8 suppresses the ensure next action, keeps lane restore advice (rc=$rc, nft=$(e391_nft_f), out: $o)"
fi
reset391
printf 'keep.example.test:443\n' > "$S391/e391-allowlist"
cp "$S391/pins-pristine" "$S391/real-pins"
rm -f "$S391/e391.pins"; ln -s "$S391/real-pins" "$S391/e391.pins"
o="$(run391 disallow e391 keep.example.test:443 2>&1)"; rc=$?
if [[ "$rc" == 1 \
      && "$o" == *"Error: the pin record path "*" is a symbolic link; refusing to replace it (the firewall was not changed)"* \
      && "$o" != *"(the firewall was not changed; move it aside"* \
      && "$o" != *"egresslock ensure"* \
      && "$o" == *"disallow: nothing was revoked"* \
      && "$o" == *"allowlist restored; gateway container running"* \
      && "$o" == *"retry: egresslock disallow e391 keep.example.test:443"* \
      && "$(e391_nft_f)" == 0 && e391_chain_same ]]; then
    e391 pass
else
    e391 fail "L17: proxy-disallow S8 suppresses the ensure next action, keeps lane retry advice (rc=$rc, nft=$(e391_nft_f), out: $o)"
fi

# --- L18: the S3 states are probe-true. The pin failure arms a
# section-local holder shim after the swap; each leg forces one honest
# observation. `anchor_running`'s boolean contract is untouched.
reset391
o="$(run391p pin-mktemp,holder-chain-absent ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"ensure: this run applied new firewall rules"* \
      && "$o" == *"state: firewall chain absent (holder container running)"* ]]; then
    e391 pass
else
    e391 fail "L18: running holder + absent chain reports the absent state (rc=$rc, out: $o)"
fi
reset391
o="$(run391p pin-mktemp,holder-hidden ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"state: firewall not proved live (holder container not running)"* \
      && "$o" != *"holder container state unknown"* ]]; then
    e391 pass
else
    e391 fail "L18: confirmed-not-running holder reports not proved live (rc=$rc, out: $o)"
fi
reset391
o="$(run391p pin-mktemp,holder-ps-fail ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"state: firewall presence could not be read (holder container state unknown)"* \
      && "$o" != *"holder container not running"* ]]; then
    e391 pass
else
    e391 fail "L18: failed holder listing reports state unknown, never not-running (rc=$rc, out: $o)"
fi
reset391
o="$(run391p pin-mktemp,holder-chain-fail ensure e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"state: firewall presence could not be read (holder container running)"* \
      && "$o" != *"holder container not running"* ]]; then
    e391 pass
else
    e391 fail "L18: running holder + failed chain read reports presence unreadable (rc=$rc, out: $o)"
fi
# R-EGL-391-3 F3: `anchor_running` stays boolean liveness for
# ensure/verify. The disclosure-local observer above is the only
# tri-state path; a failed container listing here must still read as
# "not running", never the disclosure's `state unknown`.
reset391
: > "$S391/l18-arm"
o="$(run391p holder-ps-fail verify e391 2>&1)"; rc=$?
if [[ "$rc" == 1 && "$o" == *"verify: anchor egresslock-anchor-e391 not running"* \
      && "$o" != *"holder container state unknown"* ]]; then
    e391 pass
else
    e391 fail "L18: anchor_running stays boolean for verify liveness (rc=$rc, out: $o)"
fi

# --- Control: the armed launcher and shims with non-matching names leave
# a normal ensure/verify green (no leaked one-shot state).
reset391
o="$(run391i anti-spoof:99 ensure e391 2>&1)"; rc=$?
o2="$(run391p policy-mktemp-unused,verify-mv-unused ensure e391 2>&1)"; rc2=$?
if [[ "$rc" == 0 && "$rc2" == 0 ]]; then e391 pass; else e391 fail "control: armed non-matching injections stay green (rc=$rc/$rc2, out: $o | $o2)"; fi
o="$(run391 verify e391 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"policy and gateway verified"* ]]; then
    e391 pass
else
    e391 fail "control: verify green after armed non-matching injections (rc=$rc, out: $o)"
fi

# --- L15: real 64k tmpfs legs (real ENOSPC; mocked nft/podman). One
# self-test gates the group; if userns+mount is unavailable the skip is
# named and cannot count as a pass. The VM matrix must show it unskipped.
E391_REAL=0
if command -v unshare >/dev/null 2>&1 \
   && unshare -rm bash -c 'd=$(mktemp -d /tmp/e391-mnt.XXXXXX) && mount -t tmpfs -o size=64k tmpfs "$d" && umount "$d" && rmdir "$d"' >/dev/null 2>&1; then
    E391_REAL=1
fi
if (( ! E391_REAL )); then
    skip "no-userns-full-fs" "EGL-391 real-filesystem legs need unshare -rm plus tmpfs mount; unavailable here"
else
    # The engine refuses uid 0; inside this private user+mount namespace
    # the mapped root is the only uid with mount capability. The
    # documented root escape hatch is used only for this mocked fs leg —
    # the live `A-pin-window-full` VM case runs as the account.
    E391NS_ENV="EGRESSLOCK_ALLOW_ROOT=1 EGRESSLOCK_SKIP_NETNS_PROBE=1"

    # L15a: lock filesystem full -> S1 + verify green (the read path
    # survives a real ENOSPC once the lock file exists).
    reset391
    mkdir -p "$H391/.local/state/egresslock"
    unshare -rm bash -c '
set -u
H="$1"; S="$2"
mount -t tmpfs -o size=64k tmpfs "$H/.local/state/egresslock" || exit 90
: > "$H/.local/state/egresslock/engine.lock"
dd if=/dev/zero of="$H/.local/state/egresslock/fill" bs=4096 2>/dev/null || true
if ( echo x > "$H/.local/state/egresslock/probe" ) 2>/dev/null; then echo NOTFULL; exit 91; fi
env '"$E391NS_ENV"' ARCMOCK_PASSWD_HOME="$H" HOME="$S" egresslock verify e391
echo "verify-rc=$?"
' _ "$H391" "$S391" >"$S391/l15a.out" 2>&1; e391_ns=$?
o="$(cat "$S391/l15a.out")"
if [[ "$e391_ns" == 0 && "$o" == *"the account lock could not record who holds it"* \
      && "$o" == *"verify-rc=0"* && "$o" == *"policy and gateway verified"* ]]; then
    e391 pass
else
    e391 fail "L15a: real full lock fs -> S1 + verify green (ns=$e391_ns, out: $o)"
fi

    # L15b: conf directory full, changed pin -> policy applies, pin mktemp
    # fails with real ENOSPC: S2 + S3, chain new, record old, verify rc 1.
    reset391
    sed -i 's/keep\.example\.test:443/other.example.test:443/' "$S391/e391.conf"
    W="$(mktemp -d /var/tmp/e391b.XXXXXX)"
    mkdir -p "$W/home/.config/egresslock" "$W/home/.local/state/egresslock"
    unshare -rm bash -c '
set -u
W="$1"; SRC="$2"
mount -t tmpfs -o size=64k tmpfs "$W/home/.config/egresslock" || exit 90
cp "$SRC/e391.conf" "$W/home/.config/egresslock/e391.conf"
cp "$SRC/e391-allowlist" "$W/home/.config/egresslock/e391-allowlist"
cp "$SRC/e391.pins" "$W/home/.config/egresslock/e391.pins"
chmod 600 "$W/home/.config/egresslock/e391.conf" "$W/home/.config/egresslock/e391-allowlist" "$W/home/.config/egresslock/e391.pins"
dd if=/dev/zero of="$W/home/.config/egresslock/fill" bs=4096 2>/dev/null || true
if ( echo x > "$W/home/.config/egresslock/probe" ) 2>/dev/null; then echo NOTFULL; exit 91; fi
env '"$E391NS_ENV"' ARCMOCK_PASSWD_HOME="$W/home" HOME="$W" egresslock ensure e391 >"$W/ensure.out" 2>&1
echo $? >"$W/ensure.rc"
cp "$W/home/.config/egresslock/e391.pins" "$W/pins.after" 2>/dev/null || true
env '"$E391NS_ENV"' ARCMOCK_PASSWD_HOME="$W/home" HOME="$W" egresslock verify e391 >"$W/verify.out" 2>&1
echo $? >"$W/verify.rc"
' _ "$W" "$S391" >"$S391/l15b.ns" 2>&1; e391_ns=$?
o="$(cat "$W/ensure.out" 2>/dev/null)"; orc="$(cat "$W/ensure.rc" 2>/dev/null || echo 99)"
ov="$(cat "$W/verify.out" 2>/dev/null)"; vrc="$(cat "$W/verify.rc" 2>/dev/null || echo 99)"
if [[ "$e391_ns" == 0 && "$orc" == 1 \
      && "$o" == *"cannot write the pin record"* \
      && "$o" == *"ensure: this run applied new firewall rules for profile 'e391'"* \
      && "$o" == *"state: firewall rules are present (holder container running)"* \
      && "$vrc" == 1 \
      && "$(cat "$W/pins.after" 2>/dev/null)" == *"keep.example.test|443 192.0.2.10"* ]] \
     && grep -q '192.0.2.20' "$STATE/nft/egresslock.p_e391" \
     && ! grep -q '192.0.2.10' "$STATE/nft/egresslock.p_e391"; then
    e391 pass
else
    e391 fail "L15b: real full confdir -> S2+S3 chain-new/record-old (ns=$e391_ns, rc=$orc/$vrc, out: $o | $ov)"
fi
    rm -rf "$W"

    # L15c: /tmp full -> verify names S9 (no false green, no mismatch).
    # TMPDIR is moved off the full mount so bash's own here-doc temp use
    # cannot confuse the engine's fixed /tmp temp paths.
    reset391
    W="$(mktemp -d /var/tmp/e391c.XXXXXX)"
    mkdir -p "$W/home/.config/egresslock" "$W/bin" "$W/bashtmp"
    cp "$S391/e391.conf" "$S391/e391-allowlist" "$S391/e391.pins" "$W/home/.config/egresslock/"
    cp -a "$STATE" "$W/state"; cp -a "$TESTROOT/bin/." "$W/bin/"
    unshare -rm bash -c '
set -u
W="$1"; TR="$2"
mount -t tmpfs -o size=64k tmpfs /tmp || exit 90
dd if=/dev/zero of=/tmp/fill bs=4096 2>/dev/null || true
env '"$E391NS_ENV"' TMPDIR="$W/bashtmp" PATH="$W/bin:'"$TREE_ROOT"':$PATH" ARCMOCK_STATE="$W/state" ARCMOCK_PASSWD_HOME="$W/home" HOME="$W" egresslock verify e391 >"$W/out" 2>&1
echo $? >"$W/rc"
' _ "$W" "$TESTROOT" >"$S391/l15c.ns" 2>&1; e391_ns=$?
o="$(cat "$W/out" 2>/dev/null)"; rc="$(cat "$W/rc" 2>/dev/null || echo 99)"
if [[ "$e391_ns" == 0 && "$rc" == 1 \
      && "$o" == *"verify: cannot write the temporary expected-ruleset file in /tmp; the policy could not be checked (exit 1)"* \
      && "$o" != *"does not match"* ]]; then
    e391 pass
else
    e391 fail "L15c: real full /tmp -> S9 (ns=$e391_ns, rc=$rc, out: $o)"
fi
    rm -rf "$W"

    # L15d: proxy-env --out on a full target filesystem preserves the old
    # target bytes (the write is atomic; no partial file at the target).
    reset391
    W="$(mktemp -d /var/tmp/e391d.XXXXXX)"
    mkdir -p "$W/home/.config/egresslock" "$W/proxy"
    cp "$S391/e391.conf" "$S391/e391-allowlist" "$S391/e391.pins" "$W/home/.config/egresslock/"
    unshare -rm bash -c '
set -u
W="$1"
mount -t tmpfs -o size=64k tmpfs "$W/proxy" || exit 90
chmod 700 "$W/proxy"
printf "OLD-BYTES\n" > "$W/proxy/out.env"; chmod 600 "$W/proxy/out.env"
dd if=/dev/zero of="$W/proxy/fill" bs=4096 2>/dev/null || true
env '"$E391NS_ENV"' ARCMOCK_PASSWD_HOME="$W/home" HOME="$W" egresslock proxy-env e391 --out="$W/proxy/out.env" >"$W/out" 2>&1
echo $? >"$W/rc"
cat "$W/proxy/out.env" >"$W/old"
' _ "$W" >"$S391/l15d.ns" 2>&1; e391_ns=$?
o="$(cat "$W/out" 2>/dev/null)"; rc="$(cat "$W/rc" 2>/dev/null || echo 99)"; old="$(cat "$W/old" 2>/dev/null)"
if [[ "$e391_ns" == 0 && "$rc" == 1 && "$old" == "OLD-BYTES" \
      && "$o" == *"proxy-env --out:"* \
      && ( "$o" == *"cannot write"* || "$o" == *"cannot create temp"* ) ]]; then
    e391 pass
else
    e391 fail "L15d: real full target filesystem preserves the old proxy-env file (ns=$e391_ns, rc=$rc, old=[$old], out: $o)"
fi
    rm -rf "$W"
fi

# Leave the shared mock state on the canonical image for any later
# bookkeeping and remove the section-local shims.
reset391
rm -rf "$E391SH" "$S391/state-pristine"
section_end egl391

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
results_emit egl381
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
results_emit egl362
results_emit egl305
results_emit egl317
results_emit egl350
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
results_emit egl365
results_emit egl310
results_emit egl369
results_emit egl366
results_emit egl378
results_emit egl389
results_emit egl395
results_emit egl392
results_emit egl391
# EGL-184: the hand-maintained 52-term sums are replaced by the register:
# counted snapshots plus the declared arc14 external (own counters via the
# untouched a14 delegate, EGL-179-D3). Fail-closed completeness per
# EGL-184-D4; the TOTAL line keeps the EGL-99 skip count + tree-shape tag.
results_total "$arc14_pass" "$arc14_fail"
[[ "$total_fail" -eq 0 ]]
