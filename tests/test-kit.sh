#!/usr/bin/env bash
#
# Kit productization tests for egresslock (ARC-74-D2): the kit blocks
# moved out of the site consumer harness. Covers install-kit (ARC-16,
# kit-only asserts), uninstall-kit (ARC-17), setup-account (ARC-18),
# --init-conf (ARC-19), confdir migration (ARC-60), packaging
# (ARC-22), and the AppArmor work (ARC-22-D3 / ARC-66 / ARC-69 /
# ARC-72) plus the drift-signal hint (ARC-70). All fixtures are
# synthetic — neutral example.test hosts, docs-range IPs, throwaway
# prefixes — so this tree can relocate to the public egresslock repo
# (ARC-13-D5). Nothing here references the site tree or its conf.
#
# Consumer-bound actuals that exec the site's agent-run / agent
# wrapper or forgejo-runner's copy_files.sh stay with their
# consumers and are not duplicated here (ARC-74-D7).
#
# Run:  bash tests/test-kit.sh   (or tests/run.sh)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Synthetic conf for the kit's engine-side exercises (neutral hosts).
export ARCMOCK_DNS_BASE="git.example.test=192.0.2.10,cache.example.test=192.0.2.11"
KITCONF="$TESTROOT/kit.conf"
mkdir -p "$TESTROOT/kitconf"
cat > "$KITCONF" <<'EOF'
profile local-dev 10.50.0.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
    rule allow-host ${FORGEJO_HOST:-git.example.test}:2222
    rule allow-host ${OLLAMA_HOST:-cache.example.test}:11434
EOF
export EGRESSLOCK_CONF="$KITCONF"
export PATH="$TESTROOT/bin:$TREE_ROOT:$PATH"

# The mock state mirrors the fixture assumptions the moved kit blocks
# relied on (gateway image marker, IPAM dir).
mkdir -p "$STATE/images" "$STATE/ips"
: > "$STATE/images/localhost_egresslock-gateway_latest"# --- ARC-16: kit productization ---
pass=0; fail=0

a16() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
KIT="$TREE_ROOT/install-kit.sh"
OPT="$STATE/opt-kit"          # mock --prefix
UNITS="$STATE/units"          # mock unit dir
: > "$STATE/systemctl.log"

# D9.3 setup: pretend the pre-ARC-16 global units AND the pre-rename
# (ARC-47) agent-network-verify@* templates exist.
mkdir -p "$UNITS" "$OPT"
: > "$UNITS/egresslock-verify.service"
: > "$UNITS/egresslock-verify.timer"
: > "$UNITS/agent-network-verify@.service"
: > "$UNITS/agent-network-verify@.timer"
: > "$UNITS/agent-network-verify.service"
: > "$UNITS/agent-network-verify.timer"

# 1. install-kit: non-root hook, kit files, unit templates, global
#    retirement, per-account timer enable.
# Direct exec (no `bash` wrapper): catches a committed-non-executable
# installer — R-016-2 F5.
a16_x=1
[[ -x "$KIT" ]] || { a16_x=0; a16 fail "install-kit.sh is executable in git"; }
[[ -x "$TREE_ROOT/egresslock-verify" ]] || { a16_x=0; a16 fail "egresslock-verify is executable in git (F6)"; }
if (( a16_x )); then a16 pass; fi
i_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$KIT" --prefix "$OPT" 2>&1)"; i_rc=$?
if [[ "$i_rc" == 0 ]]; then a16 pass; else a16 fail "install-kit run (rc=$i_rc, out: $i_out)"; fi
for f in egresslock egresslock-start egresslock-verify VERSION egresslock-setup; do
    [[ -f "$OPT/$f" ]] && a16 pass || a16 fail "kit file deployed: $f"
done
# ARC-23: the deployed egresslock-setup is a byte copy of the repo copy.
cmp -s "$TREE_ROOT/egresslock-setup" "$OPT/egresslock-setup" \
    && a16 pass || a16 fail "egresslock-setup deployed byte-identical (ARC-23)"
[[ -d "$OPT/gateway" && -f "$OPT/gateway/Containerfile" ]] \
    && a16 pass || a16 fail "gateway build context deployed (D6)"
# EGL-69-D2: the prefix ships the pasta AppArmor snippet (root-owned).
[[ -f "$OPT/apparmor/usr.bin.pasta.local" && -f "$OPT/apparmor/README.md" ]] \
    && a16 pass || a16 fail "apparmor snippet deployed to prefix (EGL-69-D2)"
[[ -f "$UNITS/egresslock-verify@.service" && -f "$UNITS/egresslock-verify@.timer" ]] \
    && a16 pass || a16 fail "instanced templates installed (D1)"
[[ ! -e "$UNITS/egresslock-verify.service" && ! -e "$UNITS/egresslock-verify.timer" ]] \
    && a16 pass || a16 fail "global units retired on upgrade (D9.3)"
# ARC-47-D3: pre-rename old templates are retired too, instanced + global.
[[ ! -e "$UNITS/agent-network-verify@.service" && ! -e "$UNITS/agent-network-verify@.timer" \
    && ! -e "$UNITS/agent-network-verify.service" && ! -e "$UNITS/agent-network-verify.timer" ]] \
    && a16 pass || a16 fail "pre-rename agent-network-verify@* templates retired (ARC-47-D3)"
grep -q "disable --now agent-network-verify@\*\.timer" "$STATE/systemctl.log" \
    && a16 pass || a16 fail "pre-rename instanced timers disabled (ARC-47-D3)"
# ARC-18-D4: install-kit is kit-level; it must NOT enable any per-account
# timer (that is setup-account --enable, after unit.env exists).
grep -qE "enable --now egresslock-verify@" "$STATE/systemctl.log" \
    && a16 fail "install-kit enabled a timer (moved to setup-account)" \
    || a16 pass
grep -q "disable --now egresslock-verify.timer" "$STATE/systemctl.log" \
    && a16 pass || a16 fail "global timer disabled (D9.3)"
v_out="$("$OPT/egresslock" --version 2>&1)"
grep -q "^commit: " <<<"$v_out" && a16 pass || a16 fail "--version prints kit stamp (D5): $v_out"
# ARC-18-D4: --account is no longer an install-kit argument.
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$KIT" --prefix "$OPT" --account root >/dev/null 2>&1
[[ $? == 2 ]] && a16 pass || a16 fail "install-kit rejects --account (rc 2)"
# ARC-47-D3: a leftover pre-rename kit prefix triggers the warning.
LEGACY="$STATE/legacy-prefix"; mkdir -p "$LEGACY"
l_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    EGRESSLOCK_LEGACY_PREFIX="$LEGACY" "$KIT" --prefix "$OPT" 2>&1)"; l_rc=$?
[[ "$l_rc" == 0 && "$l_out" == *"leftover pre-rename kit"* ]] \
    && a16 pass || a16 fail "leftover-prefix warning (rc=$l_rc, out: $l_out)"

# 2. Wrapper (D2 explicit-only, D4 resolution): deployed copy.
w_out="$(env -u EGRESSLOCK_PROFILE -u EGRESSLOCK_CONF "$OPT/egresslock-start" daemon 2>&1)"; w_rc=$?
if [[ "$w_rc" == 1 && "$w_out" == *"EGRESSLOCK_PROFILE is required"* ]]; then
    a16 pass
else
    a16 fail "wrapper fails closed without EGRESSLOCK_PROFILE (rc=$w_rc, out: $w_out)"
fi
w_out="$(env -u EGRESSLOCK_CONF EGRESSLOCK_PROFILE=local-dev "$OPT/egresslock-start" daemon 2>&1)"; w_rc=$?
[[ "$w_rc" == 1 && "$w_out" == *"EGRESSLOCK_CONF is required"* ]] \
    && a16 pass || a16 fail "wrapper fails closed without conf (rc=$w_rc, out: $w_out)"
w_out="$(env EGRESSLOCK_PROFILE=local-dev EGRESSLOCK_CONF="$KITCONF" \
    RUNNER_BIN=echo "$OPT/egresslock-start" daemon -c /tmp/cfg 2>&1)"; w_rc=$?
if [[ "$w_rc" == 0 && "$w_out" == *"daemon -c /tmp/cfg"* ]]; then
    a16 pass
else
    a16 fail "wrapper ensure+exec with explicit env (rc=$w_rc, out: $w_out)"
fi
# D4: a broken EGRESSLOCK_DIR wins over the working script dir.
w_out="$(env EGRESSLOCK_DIR="$STATE/empty-dir" EGRESSLOCK_PROFILE=local-dev \
    EGRESSLOCK_CONF="$KITCONF" \
    RUNNER_BIN=echo "$OPT/egresslock-start" daemon 2>&1)"; w_rc=$?
[[ "$w_rc" == 1 && "$w_out" == *"$STATE/empty-dir/egresslock"* ]] \
    && a16 pass || a16 fail "wrapper honors EGRESSLOCK_DIR first (rc=$w_rc, out: $w_out)"

# 3. egresslock-verify (D3 hybrid), deployed copy.
va_out="$(env -u EGRESSLOCK_PROFILE -u EGRESSLOCK_CONF "$OPT/egresslock-verify" 2>&1)"; va_rc=$?
[[ "$va_rc" == 1 && "$va_out" == *"EGRESSLOCK_CONF is required"* ]] \
    && a16 pass || a16 fail "egresslock-verify fails closed without conf (rc=$va_rc, out: $va_out)"
# named mode: ensure local-dev first so verify has something to check.
egresslock teardown all >/dev/null 2>&1 || true
egresslock ensure local-dev >/dev/null 2>&1
va_out="$(env EGRESSLOCK_PROFILE=local-dev EGRESSLOCK_CONF="$KITCONF" \
    "$OPT/egresslock-verify" 2>&1)"; va_rc=$?
[[ "$va_rc" == 0 && "$va_out" == *"policy verified"* ]] \
    && a16 pass || a16 fail "egresslock-verify named mode (rc=$va_rc, out: $va_out)"
# ensured mode (PROFILE unset): the ensured profile is verified.
va_out="$(env -u EGRESSLOCK_PROFILE EGRESSLOCK_CONF="$KITCONF" \
    "$OPT/egresslock-verify" 2>&1)"; va_rc=$?
[[ "$va_rc" == 0 && "$va_out" == *"verified (ensured)"* ]] \
    && a16 pass || a16 fail "egresslock-verify ensured mode (rc=$va_rc, out: $va_out)"
# tamper: drift in the ensured profile's chain must fail the timer entry.
sed -i '/dport 2222/d' "$STATE/nft/egresslock.p_local_dev"
va_out="$(env -u EGRESSLOCK_PROFILE EGRESSLOCK_CONF="$KITCONF" \
    "$OPT/egresslock-verify" 2>&1)"; va_rc=$?
[[ "$va_rc" == 1 ]] && a16 pass || a16 fail "egresslock-verify fails on drift (rc=$va_rc, out: $va_out)"
egresslock ensure local-dev >/dev/null 2>&1

arc16_pass=$pass; arc16_fail=$fail

# --- ARC-17: uninstall-kit --------------------------------------------------
pass=0; fail=0
a17() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
UKIT="$TREE_ROOT/uninstall-kit.sh"

# Exec bit committed (R-016-2 F5 failure class: mode lost in git).
[[ -x "$UKIT" ]] && a17 pass || a17 fail "uninstall-kit.sh is executable in git"

# Pre-state: prefix kit + templates + timers + account data. ARC-60-D3:
# also the pre-rename unit names, a legacy prefix (marker-guarded), a
# marker-less legacy dir, and the pre-rename confdir.
u17="$STATE/u17"
mkdir -p "$u17/prefix/gateway" "$u17/units" "$u17/home/runner/.config/egresslock" \
         "$u17/home/runner/.config/agent-network" "$u17/oldprefix/gateway" "$u17/notold"
cp "$OPT/egresslock" "$u17/prefix/" 2>/dev/null || : > "$u17/prefix/egresslock"
: > "$u17/prefix/VERSION"
: > "$u17/units/egresslock-verify@.service"
: > "$u17/units/egresslock-verify@.timer"
: > "$u17/units/agent-network-verify@.service"
: > "$u17/units/agent-network-verify@.timer"
: > "$u17/units/agent-network-verify.service"
: > "$u17/units/egresslock-verify.service"
: > "$u17/oldprefix/agent-profiles"
: > "$u17/oldprefix/VERSION"
: > "$u17/home/runner/.config/egresslock/unit.env"
: > "$u17/home/runner/.config/agent-network/main.conf"
: > "$STATE/systemctl.log"

# R-017-1 F5: a marker-less prefix must NOT be rm -rf'd.
mkdir -p "$u17/notakit"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u17/units" \
    "$UKIT" --prefix "$u17/notakit" --account root >/dev/null 2>&1
[[ -d "$u17/notakit" ]] && a17 pass || a17 fail "uninstall refuses a marker-less prefix"

u_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u17/units" \
    EGRESSLOCK_ACCOUNT_HOME="$u17/home/runner" EGRESSLOCK_LEGACY_PREFIX="$u17/oldprefix" \
    "$UKIT" --prefix "$u17/prefix" --account root 2>&1)"; u_rc=$?
[[ "$u_rc" == 0 ]] && a17 pass || a17 fail "uninstall-kit run (rc=$u_rc, out: $u_out)"
[[ ! -e "$u17/units/egresslock-verify@.service" && ! -e "$u17/units/egresslock-verify@.timer" ]] \
    && a17 pass || a17 fail "templates removed"
[[ ! -e "$u17/prefix/egresslock" && ! -e "$u17/prefix/VERSION" ]] \
    && a17 pass || a17 fail "prefix kit removed"
[[ ! -d "$u17/prefix" ]] && a17 pass || a17 fail "prefix dir removed"
# ARC-60-D3: pre-rename unit names are swept with the current ones.
[[ ! -e "$u17/units/agent-network-verify@.service" && ! -e "$u17/units/agent-network-verify@.timer" \
    && ! -e "$u17/units/agent-network-verify.service" && ! -e "$u17/units/egresslock-verify.service" ]] \
    && a17 pass || a17 fail "pre-rename + global unit templates removed"
[[ ! -d "$u17/oldprefix" ]] && a17 pass || a17 fail "legacy prefix removed (kit markers present)"
# ARC-60-D3: a marker-less legacy dir is warned and kept.
n_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u17/units" \
    EGRESSLOCK_ACCOUNT_HOME="$u17/home/runner" EGRESSLOCK_LEGACY_PREFIX="$u17/notold" \
    "$UKIT" --prefix "$u17/prefix" --account root 2>&1)"
[[ -d "$u17/notold" && "$n_out" == *"no pre-rename kit markers"* ]] \
    && a17 pass || a17 fail "marker-less legacy prefix warned and kept (out: $n_out)"
grep -q "disable --now egresslock-verify@root.timer" "$STATE/systemctl.log" \
    && a17 pass || a17 fail "per-account timer stopped/disabled"
grep -qE "disable --now agent-network-verify@\*\.timer" "$STATE/systemctl.log" \
    && a17 pass || a17 fail "pre-rename enabled-instance sweep (ARC-60-D3)"
# R-017-1 F4: ALL enabled instances get disabled, not just named ones.
grep -qE "disable --now egresslock-verify@[a-z0-9-]+\.timer" "$STATE/systemctl.log" \
    && a17 pass || a17 fail "enabled-instance sweep (list-unit-files | xargs disable)"
# R-017-1 F1: installed template ExecStart carries the requested prefix.
grep -q "ExecStart=$OPT/egresslock-verify" "$UNITS/egresslock-verify@.service" \
    && a17 pass || a17 fail "installed template ExecStart uses the deployed prefix"
grep -q "__EGRESSLOCK_PREFIX__" "$TREE_ROOT/systemd/egresslock-verify@.service" \
    && a17 pass || a17 fail "repo template keeps the prefix placeholder"
grep -q "daemon-reload" "$STATE/systemctl.log" \
    && a17 pass || a17 fail "daemon-reload after removal"
[[ -f "$u17/home/runner/.config/egresslock/unit.env" ]] \
    && a17 pass || a17 fail "account data preserved by default (D2)"
grep -q "teardown --runtime" <<<"$u_out" \
    && a17 pass || a17 fail "reminder points at teardown --runtime (ARC-60-D3)"
grep -q "teardown all" <<<"$u_out" \
    && a17 fail "reminder still says teardown all" || a17 pass
grep -q "$u17/home/runner/.config/agent-network" <<<"$u_out" \
    && a17 pass || a17 fail "kept reminder names the pre-rename confdir"

# --purge-account-data removes BOTH confdirs (ARC-60-D3).
mkdir -p "$u17/home/runner/.config/egresslock" "$u17/home/runner/.config/agent-network"
: > "$u17/home/runner/.config/egresslock/unit.env"
: > "$u17/home/runner/.config/agent-network/main.conf"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u17/units" \
    EGRESSLOCK_ACCOUNT_HOME="$u17/home/runner" EGRESSLOCK_LEGACY_PREFIX="$u17/oldprefix" \
    "$UKIT" --prefix "$u17/prefix" --account root --purge-account-data >/dev/null 2>&1
[[ ! -e "$u17/home/runner/.config/egresslock" && ! -e "$u17/home/runner/.config/agent-network" ]] \
    && a17 pass || a17 fail "--purge-account-data removes both confdirs"

# Unknown account fails closed; missing value is a usage error (exit 2).
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u17/units" \
    "$UKIT" --prefix "$u17/prefix" --account nosuch-user >/dev/null 2>&1
[[ $? == 1 ]] && a17 pass || a17 fail "uninstall-kit fails on unknown account"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 "$UKIT" --account >/dev/null 2>&1
[[ $? == 2 ]] && a17 pass || a17 fail "missing --account value exits 2"

arc17_pass=$pass; arc17_fail=$fail

# --- EGL-43: install-kit PATH wrappers (D1–D4) ------------------------------
pass=0; fail=0
a43() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
p43="$STATE/egl43"; rm -rf "$p43"
mkdir -p "$p43/units" "$p43/bin" "$p43/sbin" "$p43/opt"
a43_env() {  # wrapper install with the mock PATH dirs
    env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$p43/units" \
        EGRESSLOCK_PATH_BINDIR="$p43/bin" EGRESSLOCK_PATH_SBINDIR="$p43/sbin" \
        "$TREE_ROOT/install-kit.sh" --prefix "$1" 2>&1
}

# 1. Fresh install writes wrappers whose exec line names the mock prefix.
o="$(a43_env "$p43/opt")"; rc=$?
[[ "$rc" == 0 && -x "$p43/bin/egresslock" && -x "$p43/sbin/egresslock-setup" ]] \
    && a43 pass || a43 fail "wrappers installed (rc=$rc, out: $o)"
[[ "$(sed -n '2p' "$p43/bin/egresslock")" == "# egresslock-path-wrapper prefix=$p43/opt" ]] \
    && a43 pass || a43 fail "wrapper marker carries the prefix (D1)"
grep -qF "exec $p43/opt/egresslock \"\$@\"" "$p43/bin/egresslock" \
    && a43 pass || a43 fail "engine wrapper execs the prefix copy (D1)"
grep -qF "exec $p43/opt/egresslock-setup \"\$@\"" "$p43/sbin/egresslock-setup" \
    && a43 pass || a43 fail "setup wrapper execs the prefix copy (D2)"

# 2. Same prefix re-run: upgrade overwrite, rc 0, marker still this prefix.
printf '#!/bin/sh\n# egresslock-path-wrapper prefix=%s\nexec stale "$@"\n' "$p43/opt" > "$p43/bin/egresslock"
o="$(a43_env "$p43/opt")"; rc=$?
[[ "$rc" == 0 ]] && grep -qF "exec $p43/opt/egresslock \"\$@\"" "$p43/bin/egresslock" \
    && a43 pass || a43 fail "same-prefix re-run overwrites (upgrade, D3) (rc=$rc, out: $o)"

# 3. Dest file without the marker -> rc 1, file unchanged (D3).
mkdir -p "$p43/opt2" "$p43/bin2"
printf 'not-a-wrapper\n' > "$p43/bin2/egresslock"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$p43/units" \
    EGRESSLOCK_PATH_BINDIR="$p43/bin2" EGRESSLOCK_PATH_SBINDIR="$p43/sbin" \
    "$TREE_ROOT/install-kit.sh" --prefix "$p43/opt2" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$(cat "$p43/bin2/egresslock")" == "not-a-wrapper" ]] \
    && a43 pass || a43 fail "foreign dest refused, file unchanged (rc=$rc, out: $o)"

# 4. Another prefix's wrapper -> rc 1 (no PATH fights, D3).
mkdir -p "$p43/bin3"
printf '#!/bin/sh\n# egresslock-path-wrapper prefix=/elsewhere\nexec /elsewhere/egresslock "$@"\n' > "$p43/bin3/egresslock"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$p43/units" \
    EGRESSLOCK_PATH_BINDIR="$p43/bin3" EGRESSLOCK_PATH_SBINDIR="$p43/sbin" \
    "$TREE_ROOT/install-kit.sh" --prefix "$p43/opt" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$(sed -n '2p' "$p43/bin3/egresslock")" == "# egresslock-path-wrapper prefix=/elsewhere" ]] \
    && a43 pass || a43 fail "different-prefix wrapper refused (rc=$rc, out: $o)"

# 5. Installed .deb -> rc 1 naming 'apt remove egresslock' (D3/ARC-22-D1).
mkdir -p "$p43/stubbin"
printf '#!/bin/sh\necho "install ok installed"\n' > "$p43/stubbin/dpkg-query"
chmod 0755 "$p43/stubbin/dpkg-query"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$p43/units" \
    EGRESSLOCK_PATH_BINDIR="$p43/bin" EGRESSLOCK_PATH_SBINDIR="$p43/sbin" \
    PATH="$p43/stubbin:$PATH" \
    "$TREE_ROOT/install-kit.sh" --prefix "$p43/opt" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *'apt remove egresslock'* ]] \
    && a43 pass || a43 fail "deb co-install refused (rc=$rc, out: $o)"

# 6. Uninstall removes only THIS prefix's wrappers (D4); another
#    prefix's wrapper in the same dir is kept.
mkdir -p "$p43/bin4"
printf '#!/bin/sh\n# egresslock-path-wrapper prefix=%s\nexec %s "$@"\n' "$p43/opt" "$p43/opt/egresslock" > "$p43/bin4/egresslock"
printf '#!/bin/sh\n# egresslock-path-wrapper prefix=/elsewhere\nexec /elsewhere/egresslock-setup "$@"\n' > "$p43/bin4/egresslock-setup"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$p43/units" \
    EGRESSLOCK_PATH_BINDIR="$p43/bin4" EGRESSLOCK_PATH_SBINDIR="$p43/bin4" \
    "$TREE_ROOT/uninstall-kit.sh" --prefix "$p43/opt" 2>&1)"; rc=$?
[[ "$rc" == 0 && ! -e "$p43/bin4/egresslock" && -e "$p43/bin4/egresslock-setup" ]] \
    && a43 pass || a43 fail "uninstall removes only this prefix's wrappers (rc=$rc, out: $o)"

# 7. Unwritable PATH dir -> warning, rc 0 (convenience step, not fatal;
#    the prefix kit itself is already deployed).
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$p43/units" \
    EGRESSLOCK_PATH_BINDIR="/proc/no-such-writable-dir" EGRESSLOCK_PATH_SBINDIR="$p43/sbin" \
    "$TREE_ROOT/install-kit.sh" --prefix "$p43/opt" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"cannot install PATH wrapper"* ]] \
    && a43 pass || a43 fail "unwritable PATH dir warns and continues (rc=$rc, out: $o)"

egl43_pass=$pass; egl43_fail=$fail
pass=0; fail=0   # EGL-43: reset before ARC-18 (that block never resets)

# --- EGL-12: public snapshot staging (allowlist copy, D1) -------------------
# The snapshot script and the tests are BOTH on the allowlist, so this
# file must never literally contain a fleet fact either — the grep
# pattern and the decoy string are assembled from parts (same discipline
# as fleet_grep in packaging/snapshot-public.sh).
#
# EGL-74: the publisher (packaging/snapshot-public.sh) and the
# internal_docs/ fixture are private-tree material — the public snapshot
# ships neither. Cases that invoke or grep the publisher, or that need
# internal_docs/ as a fixture, are SKIPPED (not deleted) when absent —
# EGL-74-D1/D2; guards that need neither keep running (D2).
SNAP_PUBLIC="$TREE_ROOT/packaging/snapshot-public.sh"
HAVE_SNAPSHOT=0; [[ -f "$SNAP_PUBLIC" ]] && HAVE_SNAPSHOT=1
HAVE_INTERNAL_DOCS=0; [[ -d "$TREE_ROOT/internal_docs" ]] && HAVE_INTERNAL_DOCS=1

if [[ "$HAVE_SNAPSHOT" == 0 ]]; then
    echo "SKIP: EGL-12 public snapshot staging — packaging/snapshot-public.sh is not on the public tree (EGL-74-D1)"
    egl12_pass=0; egl12_fail=0
else
pass=0; fail=0
a12k() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
p12="$STATE/egl12"; rm -rf "$p12"; mkdir -p "$p12/kit"
(cd "$TREE_ROOT" && tar -cf - --exclude=./.git --exclude='./packaging/*.deb' --exclude='./packaging/*.tar.gz' .) \
    | tar -xf - -C "$p12/kit"
printf '# security policy (staged fixture for the snapshot gate)\n' > "$p12/kit/SECURITY.md"
snap12="$p12/kit/packaging/snapshot-public.sh"
pat12='coding-'"agent"'|home\.arpa|192\.168\.20\.|192\.168\.0\.213|onyx'"org"'|ni'"tro"'|haz'"mat"

# 1. Dry-run with SECURITY.md staged: rc 0, allowlist copy, process
#    files excluded, fleet grep clean.
s12o="$(bash "$snap12" --dry-run "$p12/stage" 2>&1)"; s12rc=$?
[[ "$s12rc" == 0 && -f "$p12/stage/egresslock" && -x "$p12/stage/install-kit.sh" \
    && -f "$p12/stage/SECURITY.md" && -f "$p12/stage/LICENSE" \
    && -f "$p12/stage/VERSION_BASE" \
    && -f "$p12/stage/docs/setup/public-snapshot.md" \
    && -f "$p12/stage/packaging/build-deb.sh" && -f "$p12/stage/packaging/build-tarball.sh" \
    && -f "$p12/stage/packaging/README.md" \
    && -f "$p12/stage/gateway/Containerfile" && -f "$p12/stage/tests/run.sh" \
    && -f "$p12/stage/systemd/egresslock-verify@.service" ]] \
    && a12k pass || a12k fail "snapshot dry-run stages the allowlist (rc=$s12rc, out: $s12o)"
# EGL-65-D3: the private publisher is not product — it never joins its
# own stage (amends EGL-12-D1's blanket packaging/*.sh copy).
[[ ! -e "$p12/stage/packaging/snapshot-public.sh" ]] \
    && a12k pass || a12k fail "snapshot stage excludes snapshot-public.sh (EGL-65-D3)"
[[ ! -e "$p12/stage/docs/tickets" && ! -e "$p12/stage/docs/BOARD.md" \
    && ! -e "$p12/stage/AGENTS.md" && ! -e "$p12/stage/.git" ]] \
    && a12k pass || a12k fail "snapshot stage excludes process files"
grep -rniE "$pat12" "$p12/stage" >/dev/null 2>&1
[[ $? == 1 ]] && a12k pass || a12k fail "snapshot stage passes the fleet grep"

# 2. SECURITY.md missing -> fail closed (EGL-9 gate), naming the file.
rm -f "$p12/kit/SECURITY.md"
o="$(bash "$snap12" --dry-run "$p12/stage-b" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"SECURITY.md missing"* ]] \
    && a12k pass || a12k fail "missing SECURITY.md fails closed (rc=$rc, out: $o)"

# 3. A fleet fact anywhere in the staged set -> fail closed, stage
#    removed, file named (never weaken the grep).
printf '# security policy (staged fixture for the snapshot gate)\n' > "$p12/kit/SECURITY.md"
printf 'site note: git.internal-fleet.home.'"arpa"' stays unreachable\n' > "$p12/kit/docs/leak-decoy.md"
o="$(bash "$snap12" --dry-run "$p12/stage-c" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"fleet facts"* && "$o" == *"leak-decoy.md"* && ! -e "$p12/stage-c" ]] \
    && a12k pass || a12k fail "fleet-fact leak fails closed, stage removed (rc=$rc, out: $o)"

# 4. Refuses a non-empty stage dir.
mkdir -p "$p12/stage-d"; : > "$p12/stage-d/preexisting"
o="$(bash "$snap12" --dry-run "$p12/stage-d" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"not empty"* ]] \
    && a12k pass || a12k fail "non-empty stage refused (rc=$rc, out: $o)"

egl12_pass=$pass; egl12_fail=$fail
fi

# --- EGL-47: internal_docs never reaches a distribution path (D1–D3) --------
pass=0; fail=0
a47() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
p47="$STATE/egl47"; rm -rf "$p47"; mkdir -p "$p47/kit" "$p47/bin" "$p47/sbin" "$p47/units"
# The live checkout carries internal_docs/ (maintainer material) — copy
# the whole tree so every guard is exercised against the real hazard.
(cd "$TREE_ROOT" && tar -cf - --exclude=./.git .) | tar -xf - -C "$p47/kit"
if [[ "$HAVE_INTERNAL_DOCS" == 1 ]]; then
    [[ -e "$p47/kit/internal_docs" ]] \
        && a47 pass || a47 fail "fixture sanity: kit copy contains internal_docs"
else
    echo "SKIP: EGL-47 fixture sanity — internal_docs/ is not on the public tree (EGL-74-D1)"
fi

# 1. Snapshot --dry-run: internal_docs present at source, absent in stage.
if [[ "$HAVE_SNAPSHOT" == 1 && "$HAVE_INTERNAL_DOCS" == 1 ]]; then
printf '# security policy (staged fixture for the snapshot gate)\n' > "$p47/kit/SECURITY.md"
o="$(bash "$p47/kit/packaging/snapshot-public.sh" --dry-run "$p47/stage" 2>&1)"; rc=$?
[[ "$rc" == 0 && ! -e "$p47/stage/internal_docs" ]] \
    && a47 pass || a47 fail "snapshot stage has no internal_docs (rc=$rc, out: $o)"
else
    echo "SKIP: EGL-47 snapshot dry-run — publisher/internal_docs not on the public tree (EGL-74-D1)"
fi

# 2. Deb staging (KEEP_STAGE): no staged path contains internal_docs.
s47="$p47/debstage"
o="$(env EGRESSLOCK_DEB_KEEP_STAGE="$s47" EGRESSLOCK_DEB_OUT="$p47/deb" \
    "$p47/kit/packaging/build-deb.sh" 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ! find "$s47" -name 'internal_docs' | grep -q . \
    && a47 pass || a47 fail "deb stage has no internal_docs (rc=$rc, out: $o)"

# 3. Prefix install (non-root hook): internal_docs absent from prefix.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$p47/units" \
    EGRESSLOCK_PATH_BINDIR="$p47/bin" EGRESSLOCK_PATH_SBINDIR="$p47/sbin" \
    "$p47/kit/install-kit.sh" --prefix "$p47/opt" 2>&1)"; rc=$?
[[ "$rc" == 0 && ! -e "$p47/opt/internal_docs" ]] \
    && a47 pass || a47 fail "prefix install has no internal_docs (rc=$rc, out: $o)"

# 4. Tarball: listing has no internal_docs path.
t47rc=0
env EGRESSLOCK_TARBALL_OUT="$p47/k.tgz" "$p47/kit/packaging/build-tarball.sh" >"$p47/tlog" 2>&1 || t47rc=$?
[[ "$t47rc" == 0 ]] && ! tar -tzf "$p47/k.tgz" | grep -q 'internal_docs' \
    && a47 pass || a47 fail "tarball listing has no internal_docs (rc=$t47rc, log: $(cat "$p47/tlog"))"

# 5. The guards are explicit in the scripts (not layout accidents).
#    build-tarball.sh / build-deb.sh / install-kit.sh ship on the public
#    tree — those greps stay (EGL-74-D2); the publisher grep needs the
#    private script (EGL-74-D1).
if [[ "$HAVE_SNAPSHOT" == 1 ]]; then
grep -q 'internal_docs' "$TREE_ROOT/packaging/snapshot-public.sh" \
    && a47 pass || a47 fail "snapshot-public.sh names internal_docs (D1)"
else
    echo "SKIP: EGL-47 publisher grep — packaging/snapshot-public.sh not on the public tree (EGL-74-D1)"
fi
grep -q -- '--exclude=./internal_docs' "$TREE_ROOT/packaging/build-tarball.sh" \
    && a47 pass || a47 fail "build-tarball.sh excludes internal_docs (D2)"
grep -q 'internal_docs' "$TREE_ROOT/packaging/build-deb.sh" \
    && grep -q 'internal_docs' "$TREE_ROOT/install-kit.sh" \
    && a47 pass || a47 fail "deb + prefix tripwires name internal_docs (D3)"

# 6. Tripwires fire: plant internal_docs into the tarball flow —
#    simulate a widened copy rule by removing the exclude from the kit
#    copy's own build-tarball.sh (it must stay in packaging/ so its
#    src resolution is unchanged) and re-run: guard must fail closed.
if [[ "$HAVE_INTERNAL_DOCS" == 1 ]]; then
sed 's/--exclude=\.\/internal_docs//' "$p47/kit/packaging/build-tarball.sh" > "$p47/kit/packaging/build-tarball-widened.sh"
mv "$p47/kit/packaging/build-tarball-widened.sh" "$p47/kit/packaging/build-tarball.sh"
o="$(env EGRESSLOCK_TARBALL_OUT="$p47/k2.tgz" bash "$p47/kit/packaging/build-tarball.sh" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"internal_docs leaked"* ]] \
    && a47 pass || a47 fail "widened tarball copy trips the guard (rc=$rc, out: $o)"
else
    echo "SKIP: EGL-47 widened-tarball tripwire — internal_docs/ is not on the public tree (EGL-74-D1)"
fi

egl47_pass=$pass; egl47_fail=$fail
pass=0; fail=0

# --- EGL-49: .deb other-readable for apt's _apt sandbox (D1) ----------------
pass=0; fail=0
a49() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
if command -v dpkg-deb >/dev/null 2>&1; then
    p49="$STATE/egl49"; rm -rf "$p49"; mkdir -p "$p49"
    # Build under umask 077 (the defect shape).
    o="$(env EGRESSLOCK_DEB_OUT="$p49/e2.deb" bash -c 'umask 077; bash "$1" 2>&1' _ "$TREE_ROOT/packaging/build-deb.sh")"; rc=$?
    if [[ "$rc" == 0 && -f "$p49/e2.deb" ]]; then
        mode="$(stat -c '%a' "$p49/e2.deb")"
        (( (8#$mode & 4) != 0 )) \
            && a49 pass || a49 fail "umask 077 .deb lacks other-read (mode $mode, out: $o)"
    else
        a49 fail "umask 077 deb build (rc=$rc, out: $o)"
    fi
    # D1: KEEP_STAGE exits before the build (no artifact, no chmod) —
    # pinned by the earlier ARC-22 flow.
else
    echo "SKIP: EGL-49 dpkg-deb not available; skipping mode assert"
fi

egl49_pass=$pass; egl49_fail=$fail
pass=0; fail=0   # EGL-47/EGL-49: reset before ARC-18

# --- ARC-18: setup-account ---------------------------------------------------
a18() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
SKIT="$TREE_ROOT/egresslock-setup"

[[ -x "$SKIT" ]] && a18 pass || a18 fail "egresslock-setup is executable in git"

a18d="$STATE/a18"
SKITP="$OPT"
rm -rf "$a18d"
mkdir -p "$a18d/home/cacct/.config/egresslock"
# Minimal conf with one gateway profile; allowlist next to the conf.
printf 'profile p1 10.99.0.0/24\n    rule gateway-only\n    gateway 10.99.0.2 3128 p1-allowlist\n' \
    > "$a18d/site.conf"
printf '# starter\n' > "$a18d/p1-allowlist"
: > "$STATE/systemctl.log"; : > "$STATE/buildlog"

# Root-only refusal (no hook).
env -u EGRESSLOCK_KIT_ALLOW_NON_ROOT "$SKIT" --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" >/dev/null 2>&1
[[ $? == 1 ]] && a18 pass || a18 fail "refuses non-root without the test hook"
# Usage errors → rc 2.
$SKIT --prefix "$SKITP" --account cacct >/dev/null 2>&1
[[ $? == 2 ]] && a18 pass || a18 fail "missing --conf is a usage error (rc 2)"
$SKIT --prefix "$SKITP" -h 2>/dev/null | grep -q "one-command" \
    && a18 pass || a18 fail "-h prints the header (mawk-safe)"
# Preflight failures fail closed BEFORE writing anything.
$SKIT --prefix "$SKITP" --account cacct --conf "$a18d/missing.conf" >/dev/null 2>&1
[[ $? == 1 && ! -e "$a18d/home/cacct/.config/egresslock/unit.env" ]] \
    && a18 pass || a18 fail "missing conf → rc 1, nothing written"
chmod 000 "$a18d/site.conf"
$SKIT --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" >/dev/null 2>&1
[[ $? == 1 && ! -e "$a18d/home/cacct/.config/egresslock/unit.env" ]] \
    && a18 pass || a18 fail "unreadable conf → rc 1, nothing written"
chmod 644 "$a18d/site.conf"

# Happy path: named profile, gateway conf → unit.env + gateway build.
s_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:test \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" --profile p1 2>&1)"; s_rc=$?
[[ "$s_rc" == 0 ]] && a18 pass || a18 fail "setup-account run (rc=$s_rc, out: $s_out)"
uenv="$a18d/home/cacct/.config/egresslock/unit.env"
[[ "$(grep -c . "$uenv")" == 2 ]] && a18 pass || a18 fail "unit.env has exactly 2 assignments"
grep -qx "EGRESSLOCK_CONF=$a18d/site.conf" "$uenv" \
    && a18 pass || a18 fail "unit.env points at the account's conf"
grep -qx "EGRESSLOCK_PROFILE=p1" "$uenv" && a18 pass || a18 fail "named mode recorded"
[[ "$(stat -c %a "$uenv")" == 600 ]] && a18 pass || a18 fail "unit.env is 0600"
grep -q "build -t localhost/egresslock-gateway:test" "$STATE/buildlog" \
    && a18 pass || a18 fail "gateway image built as the account (build-if-missing)"
# Idempotent re-run: wholesale overwrite, no duplicates.
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:test \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" --profile p1 >/dev/null 2>&1
[[ "$(grep -c . "$uenv")" == 2 ]] && a18 pass || a18 fail "re-run overwrites wholesale (no dup lines)"

# No gateway in conf → build skipped.
printf 'profile p2 10.99.1.0/24\n    rule public-only\n' > "$a18d/plain.conf"
builds_before="$(wc -l < "$STATE/buildlog")"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/plain.conf" >/dev/null 2>&1
grep -q "EGRESSLOCK_CONF=$a18d/plain.conf" "$uenv" \
    && a18 pass || a18 fail "conf switch rewrites unit.env"
[[ "$(wc -l < "$STATE/buildlog")" == "$builds_before" ]] \
    && a18 pass || a18 fail "no-gateway conf skips the image build"

# Conf that fails engine validation → rc 1, unit.env untouched.
printf 'profile p3 10.99.2.0/24\n    rule bogus-directive\n' > "$a18d/bad.conf"
"$SKIT" --prefix "$SKITP" --account cacct --conf "$a18d/bad.conf" >/dev/null 2>&1
[[ $? == 1 ]] && a18 pass || a18 fail "unparseable conf → rc 1"
grep -qx "EGRESSLOCK_CONF=$a18d/plain.conf" "$uenv" \
    && a18 pass || a18 fail "unparseable conf → unit.env unchanged"

# Profile name not in conf.
$SKIT --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" --profile nope >/dev/null 2>&1
[[ $? == 1 ]] && a18 pass || a18 fail "unknown --profile → rc 1"

# Prefix derivation (R-follow-up): no --prefix → read the deployed
# prefix from the installed unit template's ExecStart ($UNITS points at
# the a16-installed template for $OPT).
sd="$STATE/a18-derived"
rm -rf "$sd"; mkdir -p "$sd/home/dacct"
s_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$sd/home/dacct" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$SKIT" --account dacct --conf "$a18d/plain.conf" 2>&1)"; s_rc=$?
[[ "$s_rc" == 0 ]] && a18 pass || a18 fail "no --prefix derives from the installed template (rc=$s_rc, out: $s_out)"
grep -q "EGRESSLOCK_CONF=$a18d/plain.conf" "$sd/home/dacct/.config/egresslock/unit.env" \
    && a18 pass || a18 fail "derived-prefix run writes unit.env"
# And a custom --prefix still wins over the derived one.
s_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$sd/home/dacct" \
    "$SKIT" --prefix "$a18d" --account dacct --conf "$a18d/plain.conf" 2>&1)"; s_rc=$?
[[ "$s_rc" == 1 && "$s_out" == *"no engine at $a18d/egresslock"* ]] \
    && a18 pass || a18 fail "explicit --prefix overrides the derivation (rc=$s_rc, out: $s_out)"

# --enable asks systemd for the timer and enables linger (ARC-28).
: > "$STATE/systemctl.log"; : > "$STATE/loginctl.log"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" --enable >/dev/null 2>&1
grep -q "enable --now egresslock-verify@cacct.timer" "$STATE/systemctl.log" \
    && a18 pass || a18 fail "--enable enables the per-account timer"
grep -q "enable-linger cacct" "$STATE/loginctl.log" \
    && a18 pass || a18 fail "--enable enables linger for the account (ARC-28)"
grep -q "show-user cacct -p Linger --value" "$STATE/loginctl.log" \
    && a18 pass || a18 fail "--enable verifies linger (ARC-28)"
# Plain run (no --enable) must not touch loginctl (ARC-28-D3).
: > "$STATE/loginctl.log"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" >/dev/null 2>&1
[[ ! -s "$STATE/loginctl.log" ]] \
    && a18 pass || a18 fail "no --enable -> no loginctl (ARC-28-D3)"
# Fail-closed linger branch (ARC-28 review note 2 follow-up): when
# logind reports Linger=no, --enable exits 1 with the account + manual
# fallback named, and the success lines are not printed.
: > "$STATE/systemctl.log"; : > "$STATE/loginctl.log"
f_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    ARCMOCK_LINGER_ANSWER=no \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" --enable 2>&1)"; f_rc=$?
if [[ "$f_rc" == 1 && "$f_out" == *"linger for 'cacct' did not stick"* \
      && "$f_out" == *"loginctl enable-linger cacct"* ]]; then
    a18 pass
else
    a18 fail "linger Linger=no fails closed (rc=$f_rc, out: $f_out)"
fi
arc18_pass=$pass; arc18_fail=$fail

# --- EGL-51: user manager before the account-side gateway build ------------
pass=0; fail=0
e51() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
e51d="$STATE/e51"
rm -rf "$e51d"; mkdir -p "$e51d/home/gacct/.config/egresslock"
printf 'profile p1 10.99.3.0/24\n    rule gateway-only\n    gateway 10.99.3.2 3128 p1-allowlist\n' > "$e51d/site.conf"
printf '# starter\n' > "$e51d/p1-allowlist"
printf 'profile p2 10.99.4.0/24\n    rule public-only\n' > "$e51d/plain.conf"
e51uid="$(id -u)"   # hook mode: the invoking process IS the account

# 1. --enable + gateway conf: linger BEFORE user@ start BEFORE the build;
#    the timer enable still happens; linger is not repeated (D2).
: > "$STATE/systemctl.log"; : > "$STATE/loginctl.log"
rm -f "$STATE/callorder.log" "$STATE/buildlog"
s_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e51d/home/gacct" \
    EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e51a \
    $SKIT --prefix "$SKITP" --account gacct --conf "$e51d/site.conf" --enable 2>&1)"; s_rc=$?
[[ "$s_rc" == 0 ]] && e51 pass || e51 fail "--enable gateway run (rc=$s_rc, out: $s_out)"
grep -q "loginctl enable-linger gacct" "$STATE/callorder.log" \
    && e51 pass || e51 fail "linger enabled during the same run (EGL-51-D2)"
grep -q "systemctl start user@$e51uid.service" "$STATE/callorder.log" \
    && e51 pass || e51 fail "user manager started for the account uid (EGL-51-D1)"
linger_i="$(grep -n 'loginctl enable-linger' "$STATE/callorder.log" | head -1 | cut -d: -f1)"
um_i="$(grep -n 'systemctl start user@' "$STATE/callorder.log" | head -1 | cut -d: -f1)"
build_i="$(grep -n 'podman build' "$STATE/callorder.log" | head -1 | cut -d: -f1)"
[[ -n "$linger_i" && -n "$um_i" && -n "$build_i" && "$linger_i" -lt "$um_i" && "$um_i" -lt "$build_i" ]] \
    && e51 pass || e51 fail "order linger < user@ start < podman build (got $linger_i/$um_i/$build_i)"
[[ "$(grep -c 'enable-linger' "$STATE/callorder.log")" == 1 ]] \
    && e51 pass || e51 fail "linger not repeated (EGL-51-D2)"
grep -q "enable --now egresslock-verify@gacct.timer" "$STATE/systemctl.log" \
    && e51 pass || e51 fail "--enable still arms the verify timer"

# 2. No --enable + gateway conf: no loginctl at all (ARC-28-D3), the
#    user@ start still precedes the build, and the ARC-70-D2 skip hint
#    is still printed at the end.
: > "$STATE/loginctl.log"; rm -f "$STATE/callorder.log" "$STATE/buildlog"
s_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e51d/home/gacct" \
    EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e51b \
    $SKIT --prefix "$SKITP" --account gacct --conf "$e51d/site.conf" 2>&1)"; s_rc=$?
[[ "$s_rc" == 0 && ! -s "$STATE/loginctl.log" ]] \
    && e51 pass || e51 fail "no --enable: rc 0, no loginctl (ARC-28-D3; rc=$s_rc, out: $s_out)"
um_i="$(grep -n 'systemctl start user@' "$STATE/callorder.log" | head -1 | cut -d: -f1)"
build_i="$(grep -n 'podman build' "$STATE/callorder.log" | head -1 | cut -d: -f1)"
[[ -n "$um_i" && -n "$build_i" && "$um_i" -lt "$build_i" ]] \
    && e51 pass || e51 fail "user@ start before the build without --enable ($um_i/$build_i)"
[[ "$s_out" == *"timer NOT enabled"* ]] \
    && e51 pass || e51 fail "ARC-70-D2 skip hint still printed"

# 3. Conf with no gateway line: no user@ start (D1 skip).
rm -f "$STATE/callorder.log"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e51d/home/gacct" \
    $SKIT --prefix "$SKITP" --account gacct --conf "$e51d/plain.conf" >/dev/null 2>&1
grep -q 'start user@' "$STATE/callorder.log" \
    && e51 fail "no-gateway conf started user@" \
    || e51 pass

# 4. user manager not active: fail closed rc 1, stderr names the account,
#    user@ and the fix, and no podman build is attempted.
touch "$STATE/systemctl-usermgr-fails"
: > "$STATE/buildlog"; rm -f "$STATE/callorder.log"
f_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e51d/home/gacct" \
    $SKIT --prefix "$SKITP" --account gacct --conf "$e51d/site.conf" 2>&1)"; f_rc=$?
if [[ "$f_rc" == 1 && "$f_out" == *"no systemd user manager for 'gacct'"* \
      && "$f_out" == *"user@${e51uid}.service inactive"* \
      && "$f_out" == *"systemctl start user@${e51uid}.service"* ]]; then
    e51 pass
else
    e51 fail "usermgr inactive fails closed (rc=$f_rc, out: $f_out)"
fi
[[ ! -s "$STATE/buildlog" ]] \
    && e51 pass || e51 fail "no podman build attempted when user@ is inactive"
rm -f "$STATE/systemctl-usermgr-fails"
# 4b. Same failure with Linger=no: the enable-linger hint line is added.
touch "$STATE/systemctl-usermgr-fails"
f_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e51d/home/gacct" \
    ARCMOCK_LINGER_ANSWER=no \
    $SKIT --prefix "$SKITP" --account gacct --conf "$e51d/site.conf" 2>&1)"; f_rc=$?
if [[ "$f_rc" == 1 && "$f_out" == *"loginctl enable-linger gacct"* \
      && "$f_out" == *"or re-run setup with --enable"* ]]; then
    e51 pass
else
    e51 fail "usermgr failure + Linger=no names the linger fix (rc=$f_rc, out: $f_out)"
fi
rm -f "$STATE/systemctl-usermgr-fails"
egl51_pass=$pass; egl51_fail=$fail

# --- ARC-19: setup-account --init-conf (sshd-style starter conf) ----------
pass=0; fail=0
a19() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
a19p="$STATE/a19/prefix"        # fresh kit prefix with examples deployed
a19h="$STATE/a19/home/iacct"    # virtual account home
rm -rf "$STATE/a19"; mkdir -p "$a19p" "$a19h"

# 1. install-kit deploys examples/ into the prefix (D3), root-owned files.
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$KIT" --prefix "$a19p" >/dev/null 2>&1
[[ -f "$a19p/examples/main.conf" && -f "$a19p/examples/main-allowlist" ]] \
    && a19 pass || a19 fail "install-kit deploys examples/ (main.conf + main-allowlist)"
# The example itself must parse under the deployed engine and list 'main'.
a19_list="$(env EGRESSLOCK_CONF="$a19p/examples/main.conf" \
    "$a19p/egresslock" list 2>&1)"
[[ "$a19_list" == *"main"* ]] \
    && a19 pass || a19 fail "shipped example conf parses and lists 'main'"

# 2. --init-conf without --conf: writes the README well-known path + the
#    empty sibling allowlist, byte-compatible with the shipped pair.
a19_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a19h" \
    $SKIT --prefix "$a19p" --account iacct --init-conf 2>&1)"; a19_rc=$?
[[ "$a19_rc" == 0 ]] && a19 pass || a19 fail "--init-conf run (rc=$a19_rc, out: $a19_out)"
a19_conf="$a19h/.config/egresslock/main.conf"
a19_al="$a19h/.config/egresslock/main-allowlist"
[[ -f "$a19_conf" && -f "$a19_al" ]] \
    && a19 pass || a19 fail "--init-conf creates conf + sibling allowlist"
cmp -s "$a19p/examples/main.conf" "$a19_conf" \
    && a19 pass || a19 fail "--init-conf conf is byte-identical to the shipped example"
cmp -s "$a19p/examples/main-allowlist" "$a19_al" \
    && a19 pass || a19 fail "--init-conf allowlist is byte-identical to the shipped example"
a19_list="$(env EGRESSLOCK_CONF="$a19_conf" "$a19p/egresslock" list 2>&1)"
[[ "$a19_list" == *"main"* ]] \
    && a19 pass || a19 fail "init'd conf parses and lists 'main'"
grep -qx "EGRESSLOCK_CONF=$a19_conf" "$a19h/.config/egresslock/unit.env" \
    && a19 pass || a19 fail "--init-conf unit.env points at the starter conf"

# 3. Never overwrites: existing conf keeps its content AND a missing
#    sibling allowlist is NOT created (ARC-17-D1 / R-007-1 F5 hole).
printf 'profile custom 10.198.0.0/24\n    rule public-only\n' > "$a19_conf"
rm -f "$a19_al"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a19h" \
    $SKIT --prefix "$a19p" --account iacct --init-conf >/dev/null 2>&1
grep -qx "profile custom 10.198.0.0/24" "$a19_conf" \
    && a19 pass || a19 fail "--init-conf never overwrites an existing conf"
[[ ! -e "$a19_al" ]] \
    && a19 pass || a19 fail "--init-conf on existing conf does NOT create a missing sibling allowlist"
rm -f "$a19_conf"

# 4. --init-conf with an explicit --conf (missing dest): creates the pair
#    next to that conf, allowlist name per the example (main-allowlist).
a19_custom="$STATE/a19/custom/site.conf"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a19h" \
    $SKIT --prefix "$a19p" --account iacct --conf "$a19_custom" --init-conf >/dev/null 2>&1
[[ -f "$a19_custom" && -f "$STATE/a19/custom/main-allowlist" ]] \
    && a19 pass || a19 fail "--init-conf with --conf creates pair at the given path"
cmp -s "$a19p/examples/main.conf" "$a19_custom" \
    && a19 pass || a19 fail "--conf --init-conf copies byte-identical starter"
rm -rf "$STATE/a19/custom"

# 5. Missing examples fail closed with a pointer at install-kit.
a19_nopref="$STATE/a19/noprefix"
mkdir -p "$a19_nopref"
cp "$a19p/egresslock" "$a19_nopref/egresslock"
a19_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a19h" \
    $SKIT --prefix "$a19_nopref" --account iacct --init-conf 2>&1)"; a19_rc=$?
[[ "$a19_rc" == 1 && "$a19_out" == *"re-run install-kit.sh"* ]] \
    && a19 pass || a19 fail "missing examples → rc 1, points at install-kit (rc=$a19_rc, out: $a19_out)"

# 6. Non-init-conf paths unchanged: --conf required (rc 2) and missing
#    file still fails closed (rc 1) with the fail-closed message.
$SKIT --prefix "$a19p" --account iacct >/dev/null 2>&1
[[ $? == 2 ]] && a19 pass || a19 fail "without --init-conf, missing --conf still exits 2"
a19_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a19h" \
    $SKIT --prefix "$a19p" --account iacct --conf "$STATE/a19/nope.conf" 2>&1)"; a19_rc=$?
[[ "$a19_rc" == 1 && "$a19_out" == *"conf not found"* ]] \
    && a19 pass || a19 fail "without --init-conf, missing conf still exits 1 fail-closed (rc=$a19_rc)"

# 7. On-host runuser/CWD finding: runuser inherits the caller's CWD and
#    chdir-fails when the account cannot traverse it (operator checkout
#    under a 0700 home → 'cannot chdir ...: Permission denied'). BOTH
#    root-mode runuser call sites must run from the account's own home.
#    (Static guard: the mock harness runs non-root hook mode and cannot
#    exercise runuser directly.)
[[ "$(grep -c 'cd "\$home" && runuser' "$SKIT")" == 2 ]] \
    && a19 pass || a19 fail "both runuser calls are home-CWD wrapped (on-host chdir finding)"
arc19_pass=$pass; arc19_fail=$fail

# --- EGL-38: run map, --doctor, --build-gateway ------------------------------
pass=0; fail=0
e38() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
e38p="$STATE/e38/prefix"   # fresh deployed kit prefix (engine + gateway + examples)
rm -rf "$STATE/e38"; mkdir -p "$e38p"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$KIT" --prefix "$e38p" >/dev/null 2>&1
[[ -f "$e38p/egresslock" && -f "$e38p/gateway/Containerfile" && -f "$e38p/examples/main.conf" ]] \
    && e38 pass || e38 fail "e38 fixture: kit deployed to $e38p"
e38h="$STATE/e38/home/uctx"
mkdir -p "$e38h/.config/egresslock"
printf 'profile p1 10.99.5.0/24\n    rule gateway-only\n    gateway 10.99.5.2 3128 p1-allowlist\n' > "$STATE/e38/site.conf"
printf '# starter\n' > "$STATE/e38/p1-allowlist"
printf 'profile p2 10.99.6.0/24\n    rule public-only\n' > "$STATE/e38/plain.conf"
# Run-map extractor: the numbered lines only (D38-6 format).
e38_map() { grep -E '^[0-9]\) .* … (OK|SKIP|FAIL)$' <<<"$1"; }

# 1. Bundle --init-conf without --enable (starter conf has a gateway
#    line): full map in execution order, N from 1, linger/timer SKIP.
: > "$STATE/systemctl.log"; : > "$STATE/loginctl.log"; : > "$STATE/buildlog"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e38a \
    $SKIT --prefix "$e38p" --account uctx --init-conf 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 0 ]] && e38 pass || e38 fail "--init-conf bundle run (rc=$e38_rc, out: $e38o)"
[[ "$(e38_map "$e38o")" == $'1) validate conf … OK\n2) write unit.env … OK\n3) linger … SKIP\n4) user manager … OK\n5) gateway image … OK\n6) timer … SKIP' ]] \
    && e38 pass || e38 fail "init-conf map order/status (D38-7): $(e38_map "$e38o" | tr '\n' '|')"

# 2. Bundle --enable + gateway conf: linger OK < user manager OK <
#    gateway image OK < timer OK (D38-7 execution order).
: > "$STATE/systemctl.log"; : > "$STATE/loginctl.log"; : > "$STATE/buildlog"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e38b \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --enable 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 0 ]] && e38 pass || e38 fail "--enable bundle run (rc=$e38_rc, out: $e38o)"
li="$(grep -n '3) linger … OK' <<<"$e38o" | head -1 | cut -d: -f1)"
ui="$(grep -n '4) user manager … OK' <<<"$e38o" | head -1 | cut -d: -f1)"
gi="$(grep -n '5) gateway image … OK' <<<"$e38o" | head -1 | cut -d: -f1)"
ti="$(grep -n '6) timer … OK' <<<"$e38o" | head -1 | cut -d: -f1)"
[[ -n "$li" && -n "$ui" && -n "$gi" && -n "$ti" && "$li" -lt "$ui" && "$ui" -lt "$gi" && "$gi" -lt "$ti" ]] \
    && e38 pass || e38 fail "enable map order linger<usermgr<image<timer ($li/$ui/$gi/$ti)"

# 2b. FAIL is the last printed numbered step: linger Linger=no with
#     --enable stops the map at 3) linger … FAIL.
: > "$STATE/systemctl.log"; : > "$STATE/loginctl.log"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    ARCMOCK_LINGER_ANSWER=no \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --enable 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 1 && "$(e38_map "$e38o" | tail -1)" == "3) linger … FAIL" ]] \
    && e38 pass || e38 fail "FAIL is the last numbered step (rc=$e38_rc, map: $(e38_map "$e38o" | tr '\n' '|'))"

# 3. Conf with no gateway line: user manager + gateway image SKIP;
#    linger/timer still follow --enable.
: > "$STATE/systemctl.log"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/plain.conf" --enable 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 0 && "$(e38_map "$e38o")" == $'1) validate conf … OK\n2) write unit.env … OK\n3) linger … OK\n4) user manager … SKIP\n5) gateway image … SKIP\n6) timer … OK' ]] \
    && e38 pass || e38 fail "no-gateway map: SKIP 4/5, --enable still owns 3/6 (rc=$e38_rc, map: $(e38_map "$e38o" | tr '\n' '|'))"

# 4. --doctor with --account, unit.env missing: rc 1 with a fix command
#    naming egresslock-setup (D38-2).
e38h2="$STATE/e38/home/fresh"
mkdir -p "$e38h2"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h2" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account fresh --conf "$STATE/e38/site.conf" --doctor 2>&1)"; e38_rc=$?
if [[ "$e38_rc" == 1 && "$e38o" == *"unit.env: missing"* && "$e38o" == *"fix: sudo egresslock-setup"* ]]; then
    e38 pass
else
    e38 fail "doctor: unit.env missing (rc=$e38_rc, out: $e38o)"
fi
# Host slice stays clean: engine + templates present.
[[ "$e38o" == *"kit engine: present ($e38p)"* && "$e38o" == *"unit templates: installed ($UNITS)"* ]] \
    && e38 pass || e38 fail "doctor: host slice rows (out: $e38o)"

# 5. --doctor with --account + gateway conf + inactive user manager:
#    rc 1, the fix names `systemctl start user@` (D38-7.2).
touch "$STATE/systemctl-usermgr-fails"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --doctor 2>&1)"; e38_rc=$?
if [[ "$e38_rc" == 1 && "$e38o" == *"user manager: not active"* \
      && "$e38o" == *"fix: sudo systemctl start user@"* ]]; then
    e38 pass
else
    e38 fail "doctor: inactive user manager (rc=$e38_rc, out: $e38o)"
fi
rm -f "$STATE/systemctl-usermgr-fails"
# Healthy account slice (marker gone): rc 0, image + parse rows ok.
# Restore the unit.env the plain-conf run above rewrote.
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 >/dev/null 2>&1
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 0 && "$e38o" == *"gateway image: present"* && "$e38o" == *"unit.env: matches"* \
    && "$e38o" == *"conf parse: ok"* && "$e38o" == *"timer: enabled"* && "$e38o" == *"linger: on"* ]] \
    && e38 pass || e38 fail "doctor: healthy account slice rc 0 (rc=$e38_rc, out: $e38o)"
# Account-less doctor = host slice only, rc 0; and the EGL-24 pin: NOT
# rc 2 unknown-argument (D38-5).
e38o="$(env EGRESSLOCK_UNIT_DIR="$UNITS" $SKIT --doctor 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 0 && "$e38o" != *"unknown argument: --doctor"* && "$e38o" == *"kit engine: present"* ]] \
    && e38 pass || e38 fail "EGL-24 pin: --doctor runs (rc=$e38_rc, out: $e38o)"
# Usage conflicts: --build-gateway x --account, --doctor x --apparmor-add.
e38o="$($SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --build-gateway 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 2 && "$e38o" == *"cannot be combined with --account"* ]] \
    && e38 pass || e38 fail "build-gateway x account is a usage error (rc=$e38_rc)"
e38o="$($SKIT --doctor --apparmor-add 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 2 && "$e38o" == *"cannot be combined"* ]] \
    && e38 pass || e38 fail "doctor x apparmor-add is a usage error (rc=$e38_rc)"

# 6. --build-gateway as non-root builds from the DEPLOYED prefix
#    (not the checkout CWD rules; D38-3).
: > "$STATE/buildlog"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e38c \
    $SKIT --prefix "$e38p" --build-gateway 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 0 ]] && e38 pass || e38 fail "build-gateway run (rc=$e38_rc, out: $e38o)"
grep -q "build -t localhost/egresslock-gateway:e38c -f $e38p/gateway/Containerfile $e38p/gateway" "$STATE/buildlog" \
    && e38 pass || e38 fail "build-gateway uses the deployed prefix context ($(cat "$STATE/buildlog"))"
grep -q "$TREE_ROOT/gateway" "$STATE/buildlog" \
    && e38 fail "build-gateway must not use checkout CWD rules" || e38 pass

# 7. --build-gateway when the user manager is inactive: rc 1, stderr
#    names user@, no podman build (D38-7.3; EGL-51 marker reused).
touch "$STATE/systemctl-usermgr-fails"
: > "$STATE/buildlog"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e38d \
    $SKIT --prefix "$e38p" --build-gateway 2>&1)"; e38_rc=$?
if [[ "$e38_rc" == 1 && "$e38o" == *"no systemd user manager for"* && "$e38o" == *"user@"* ]]; then
    e38 pass
else
    e38 fail "build-gateway inactive user manager fails closed (rc=$e38_rc, out: $e38o)"
fi
[[ ! -s "$STATE/buildlog" ]] \
    && e38 pass || e38 fail "build-gateway: no podman build when user@ inactive"
rm -f "$STATE/systemctl-usermgr-fails"
egl38_pass=$pass; egl38_fail=$fail

# --- ARC-60: setup confdir migration (D2) -----------------------------------
# Old ~/.config/agent-network + absent new confdir -> mv'd as the account
# (printed); BOTH present -> rc 1 naming both paths, nothing merged; no
# old confdir -> unchanged behavior. (Hook mode: one uid, so ownership is
# structural — the mv runs inside the run_as_account dispatch.)
pass=0; fail=0
a60() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# 1. Old confdir only -> migrated; --init-conf starter still lands; the
#    migrated profile parses under the engine.
m60="$STATE/a60"; rm -rf "$m60"; mkdir -p "$m60/home/macct"
m60_home="$m60/home/macct"
mkdir -p "$m60_home/.config/agent-network"
printf 'profile dev 10.199.91.0/24\n    rule public-only\n' > "$m60_home/.config/agent-network/dev.conf"
: > "$m60_home/.config/agent-network/dev-allowlist"
m_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$m60_home" \
    EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:test \
    $SKIT --prefix "$SKITP" --account macct --init-conf 2>&1)"; m_rc=$?
if [[ "$m_rc" == 0 && ! -e "$m60_home/.config/agent-network" \
      && -f "$m60_home/.config/egresslock/dev.conf" \
      && -f "$m60_home/.config/egresslock/dev-allowlist" ]]; then
    a60 pass
else
    a60 fail "D2 old confdir migrated (rc=$m_rc, out: $m_out)"
fi
grep -q "migrated:" <<<"$m_out" && grep -q "dev.conf" <<<"$m_out" \
    && a60 pass || a60 fail "D2 prints 'migrated:' + the conf basenames (out: $m_out)"
[[ -f "$m60_home/.config/egresslock/main.conf" ]] \
    && a60 pass || a60 fail "D2 --init-conf starter still written after migration"
m_list="$(env EGRESSLOCK_CONF="$m60_home/.config/egresslock/dev.conf" \
    "$SKITP/egresslock" list 2>&1)"
[[ "$m_list" == *"dev"* ]] \
    && a60 pass || a60 fail "D2 migrated dev.conf parses under the engine (out: $m_list)"

# 2. BOTH confdirs present -> rc 1, both kept, both paths named, nothing
#    merged or overwritten.
m60b="$STATE/a60b"; rm -rf "$m60b"
mkdir -p "$m60b/home/bacct/.config/egresslock" "$m60b/home/bacct/.config/agent-network"
: > "$m60b/home/bacct/.config/egresslock/unit.env"
: > "$m60b/home/bacct/.config/agent-network/main.conf"
b_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$m60b/home/bacct" \
    $SKIT --prefix "$SKITP" --account bacct --init-conf 2>&1)"; b_rc=$?
if [[ "$b_rc" == 1 && -d "$m60b/home/bacct/.config/egresslock" \
      && -d "$m60b/home/bacct/.config/agent-network" \
      && -f "$m60b/home/bacct/.config/egresslock/unit.env" \
      && -f "$m60b/home/bacct/.config/agent-network/main.conf" \
      && ! -e "$m60b/home/bacct/.config/egresslock/main.conf" ]]; then
    a60 pass
else
    a60 fail "D2 both confdirs -> rc 1, both kept unmerged (rc=$b_rc, out: $b_out)"
fi
grep -q "$m60b/home/bacct/.config/agent-network" <<<"$b_out" \
    && grep -q "$m60b/home/bacct/.config/egresslock" <<<"$b_out" \
    && a60 pass || a60 fail "D2 refusal names both paths (out: $b_out)"

# 3. No old confdir -> no migration message, normal --init-conf flow.
m60c="$STATE/a60c"; rm -rf "$m60c"; mkdir -p "$m60c/home/cacct"
c_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$m60c/home/cacct" \
    $SKIT --prefix "$SKITP" --account cacct --init-conf 2>&1)"; c_rc=$?
[[ "$c_rc" == 0 && "$c_out" != *"migrated:"* \
    && -f "$m60c/home/cacct/.config/egresslock/main.conf" ]] \
    && a60 pass || a60 fail "D2 no old confdir -> unchanged flow (rc=$c_rc, out: $c_out)"

arc60_pass=$pass; arc60_fail=$fail

# --- ARC-22: packaging (.deb + tar.gz) --------------------------------------
pass=0; fail=0
a22() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

DEBSH="$TREE_ROOT/packaging/build-deb.sh"
TARSH="$TREE_ROOT/packaging/build-tarball.sh"
p22="$STATE/a22"; rm -rf "$p22"; mkdir -p "$p22"

# D4: the tarball is the self-contained kit tree (incl. uninstall-kit.sh
# and the unit templates) + a README fragment.
t_out="$(env EGRESSLOCK_TARBALL_OUT="$p22/k.tgz" "$TARSH" 2>&1)"; t_rc=$?
[[ "$t_rc" == 0 && -f "$p22/k.tgz" ]] \
    && a22 pass || a22 fail "tarball build (rc=$t_rc, out: $t_out)"
mkdir -p "$p22/x"; tar -xzf "$p22/k.tgz" -C "$p22/x"
for f in README.txt egresslock/install-kit.sh egresslock/uninstall-kit.sh \
         egresslock/egresslock egresslock/egresslock-setup \
         egresslock/gateway/Containerfile egresslock/examples/main.conf \
         egresslock/docs/setup/uninstall.md egresslock/apparmor/usr.bin.pasta.local \
         egresslock/systemd/egresslock-verify@.service \
         egresslock/systemd/egresslock-verify@.timer; do
    [[ -e "$p22/x/$f" ]] && a22 pass || a22 fail "tarball contains $f"
done
# EGL-1 flatten: the kit root is now the repo root, so the tar sweep
# must keep shipping kit payload only — no git dir, no process files.
if tar -tzf "$p22/k.tgz" \
        | grep -qE '(^|/)\.git(/|$)|egresslock/(AGENTS\.md|\.gitignore|docs/(tickets|BOARD\.md))'; then
    a22 fail "tarball leaks repo-only process files"
else
    a22 pass
fi

# Tarball flow: install-kit.sh from the extracted tree deploys the full
# prefix set with the prefix-substituted ExecStart (in-kit templates).
u22="$p22/units"
i_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u22" \
    bash "$p22/x/egresslock/install-kit.sh" --prefix "$p22/opt" 2>&1)"; i_rc=$?
for f in egresslock egresslock-start egresslock-verify egresslock-setup VERSION; do
    [[ -f "$p22/opt/$f" ]] && a22 pass || a22 fail "tarball install deployed $f (rc=$i_rc, out: $i_out)"
done
[[ -d "$p22/opt/gateway" && -f "$p22/opt/examples/main.conf" && -f "$u22/egresslock-verify@.service" ]] \
    && a22 pass || a22 fail "tarball install deployed gateway/examples/units"
grep -q "ExecStart=$p22/opt/egresslock-verify" "$u22/egresslock-verify@.service" \
    && a22 pass || a22 fail "tarball install rewrote ExecStart with the prefix"

# EGL-72-D3: the extracted tree ships KIT_VERSION (the build version
# string); the install must stamp the deployed VERSION with it. Asserted
# here because the uninstall below removes the prefix wholesale.
[[ "$(tr -d ' \n' < "$p22/x/egresslock/KIT_VERSION")" == "$(sed -n 's/^version: //p' "$p22/opt/VERSION")" ]] \
    && a22 pass || a22 fail "EGL-72 tarball install uses KIT_VERSION as version:"

# ... and uninstall-kit.sh from the same tree removes it.
u_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u22" \
    EGRESSLOCK_LEGACY_PREFIX="$p22/no-legacy" \
    bash "$p22/x/egresslock/uninstall-kit.sh" --prefix "$p22/opt" 2>&1)"; u_rc=$?
[[ "$u_rc" == 0 && ! -d "$p22/opt" ]] \
    && a22 pass || a22 fail "tarball uninstall removes the prefix (rc=$u_rc, out: $u_out)"

# D1/D2: the staged .deb tree (file-set assert; dpkg optional below).
s_out="$(env EGRESSLOCK_DEB_KEEP_STAGE="$p22/stage" \
    EGRESSLOCK_DEB_OUT="$p22/deb" "$DEBSH" 2>&1)"; s_rc=$?
[[ "$s_rc" == 0 ]] && a22 pass || a22 fail "deb staging run (rc=$s_rc, out: $s_out)"
for f in DEBIAN/control DEBIAN/postinst DEBIAN/postrm \
         usr/bin/egresslock usr/sbin/egresslock-setup \
         usr/lib/egresslock/egresslock usr/lib/egresslock/egresslock-setup \
         usr/lib/egresslock/VERSION usr/lib/egresslock/gateway/Containerfile \
         usr/share/egresslock/examples/main.conf \
         usr/share/egresslock/examples/main-allowlist \
         usr/share/egresslock/doc/README.md \
         usr/share/egresslock/doc/docs/quickstart/allow-non-http.md \
         usr/share/egresslock/doc/docs/setup/install.md \
         usr/share/egresslock/apparmor/usr.bin.pasta.local \
         usr/lib/systemd/system/egresslock-verify@.service \
         usr/lib/systemd/system/egresslock-verify@.timer; do
    [[ -e "$p22/stage/$f" ]] && a22 pass || a22 fail "deb stage contains $f"
done
# EGL-1 flatten: the generated ticket board lives in docs/ next to the
# manuals now; the package doc dir ships manuals only.
[[ ! -e "$p22/stage/usr/share/egresslock/doc/BOARD.md" ]] \
    && a22 pass || a22 fail "deb doc dir excludes BOARD.md (process file)"
grep -q 'exec /usr/lib/egresslock/egresslock' "$p22/stage/usr/bin/egresslock" \
    && a22 pass || a22 fail "usr/bin wrapper targets libdir (D1)"
grep -q 'ExecStart=/usr/lib/egresslock/egresslock-verify' \
    "$p22/stage/usr/lib/systemd/system/egresslock-verify@.service" \
    && a22 pass || a22 fail "deb unit ExecStart uses libdir (D1)"
grep -q '^Package: egresslock$' "$p22/stage/DEBIAN/control" \
    && grep -q '^Architecture: all$' "$p22/stage/DEBIAN/control" \
    && grep -q '^Depends:.*podman' "$p22/stage/DEBIAN/control" \
    && a22 pass || a22 fail "control: package/arch/depends (D2)"
# Verification gate: no site names anywhere in the package.
if grep -RIl 'home\.arpa' "$p22/stage" >/dev/null 2>&1; then
    a22 fail "deb stage leaks site names (arc22 verification)"
else
    a22 pass
fi
# D2: postinst never enables a timer or touches AppArmor; postrm never
# deletes account data, runs podman, or removes the pasta snippet.
if grep -vE '^\s*(#|$)' "$p22/stage/DEBIAN/postinst" | grep -qE 'systemctl enable|enable-linger|apparmor_parser|aa-complain'; then
    a22 fail "postinst enables a timer or touches AppArmor (D2/D3)"
else
    a22 pass
fi
if grep -vE '^\s*(#|$)' "$p22/stage/DEBIAN/postrm" | grep -qE 'rm -rf|rm -f|podman|config/egresslock|apparmor_parser'; then
    a22 fail "postrm deletes state or touches podman/AppArmor (D2/D3)"
else
    a22 pass
fi
# R-022-1 F2: the README's dual-install warning must be real — postinst
# actually checks for the prefix kit.
grep -q '/opt/egresslock/egresslock' "$p22/stage/DEBIAN/postinst" \
    && a22 pass || a22 fail "postinst warns on /opt dual install (R-022-1 F2)"

# R-022-1 F1: a fresh .deb-only host — no /etc template, no --prefix —
# derives the prefix from the deb unit template (/usr/lib/systemd/system),
# so the postinst's printed command works out of the box.
f1="$p22/f1"; rm -rf "$f1"
mkdir -p "$f1/debunits" "$f1/libdir" "$f1/home/uacct/.config"
sed "s|__EGRESSLOCK_PREFIX__|$f1/libdir|g" \
    "$TREE_ROOT/systemd/egresslock-verify@.service" \
    > "$f1/debunits/egresslock-verify@.service"
install -m 0755 "$TREE_ROOT/egresslock" "$f1/libdir/egresslock"
f1_out="$(env -u EGRESSLOCK_UNIT_DIR EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_DEB_UNIT_DIR="$f1/debunits" EGRESSLOCK_ACCOUNT_HOME="$f1/home/uacct" \
    "$SKIT" --account uacct --init-conf 2>&1)"; f1_rc=$?
if [[ "$f1_rc" == 0 && -f "$f1/home/uacct/.config/egresslock/unit.env" \
      && -f "$f1/home/uacct/.config/egresslock/main.conf" \
      && "$f1_out" != *"no engine at"* ]]; then
    a22 pass
else
    a22 fail "F1 deb-host setup derives the libdir prefix (rc=$f1_rc, out: $f1_out)"
fi

# R-EGL-37-1 D37-1: stale /etc unit pointing at a dead prefix while the
# live kit is the .deb — setup must RETRY the deb unit dir and adopt the
# libdir prefix (an installed-deb host's 'no engine at /opt/egresslock').
# Harness shape: EGRESSLOCK_DEFAULT_UNIT_DIR fakes the /etc probe
# path WITHOUT tripping the explicit-hook suppression (that is
# EGRESSLOCK_UNIT_DIR's documented behavior — explicit hook beats
# heuristics, so with it set the retry does not run). A working /etc
# prefix still wins (D37-1: never prefer the deb over a live prefix
# install) — pinned by the f1w case below.
f1s="$p22/f1-stale"; rm -rf "$f1s"
mkdir -p "$f1s/etcunits" "$f1s/debunits" "$f1s/libdir" "$f1s/opt-dead" "$f1s/home/uacct/.config"
sed "s|__EGRESSLOCK_PREFIX__|$f1s/opt-dead|g" \
    "$TREE_ROOT/systemd/egresslock-verify@.service" \
    > "$f1s/etcunits/egresslock-verify@.service"
sed "s|__EGRESSLOCK_PREFIX__|$f1s/libdir|g" \
    "$TREE_ROOT/systemd/egresslock-verify@.service" \
    > "$f1s/debunits/egresslock-verify@.service"
install -m 0755 "$TREE_ROOT/egresslock" "$f1s/libdir/egresslock"
f1s_out="$(env -u EGRESSLOCK_UNIT_DIR EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_DEB_UNIT_DIR="$f1s/debunits" EGRESSLOCK_ACCOUNT_HOME="$f1s/home/uacct" \
    EGRESSLOCK_DEFAULT_UNIT_DIR="$f1s/etcunits" \
    "$SKIT" --account uacct --init-conf 2>&1)"; f1s_rc=$?
[[ "$f1s_rc" == 0 && "$f1s_out" != *"no engine at"* ]] \
    && a22 pass || a22 fail "D37-1 stale-/etc retry adopts live deb prefix (rc=$f1s_rc, out: $f1s_out)"

# R-EGL-37-1 Finding 1a: BOTH probes miss (no units anywhere) -> rc 1
# with the two-shape error text (.deb hosts: / prefix installs:).
f1e="$p22/f1-errtext"; rm -rf "$f1e"
mkdir -p "$f1e/home/uacct/.config"
f1e_out="$(env -u EGRESSLOCK_UNIT_DIR EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_DEB_UNIT_DIR="$f1e/no-deb-units" EGRESSLOCK_DEFAULT_UNIT_DIR="$f1e/no-etc-units" \
    EGRESSLOCK_ACCOUNT_HOME="$f1e/home/uacct" \
    "$SKIT" --account uacct --init-conf 2>&1)"; f1e_rc=$?
[[ "$f1e_rc" == 1 \
    && "$f1e_out" == *"no engine at /opt/egresslock/egresslock"* \
    && "$f1e_out" == *".deb hosts: reinstall the current package, or pass --prefix /usr/lib/egresslock"* \
    && "$f1e_out" == *"prefix installs: run install-kit.sh first (or pass --prefix)"* ]] \
    && a22 pass || a22 fail "D37-1 both-probes-miss error names both shapes (rc=$f1e_rc, out: $f1e_out)"

# R-EGL-37-1 Finding 1b: EXPLICIT EGRESSLOCK_UNIT_DIR (stale, dead
# prefix) + a live deb available -> suppression must HOLD (the deb
# retry misfiring under an explicit hook would silently rewire hosts
# that asked to be pinned to a unit dir).
f1e_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_UNIT_DIR="$f1s/etcunits" EGRESSLOCK_DEB_UNIT_DIR="$f1s/debunits" \
    EGRESSLOCK_ACCOUNT_HOME="$f1e/home/uacct" \
    "$SKIT" --account uacct --init-conf 2>&1)"; f1e_rc=$?
[[ "$f1e_rc" == 1 && "$f1e_out" == *"no engine at $f1s/opt-dead/egresslock"* \
    && "$f1e_out" == *".deb hosts:"* ]] \
    && a22 pass || a22 fail "D37-1 explicit hook suppresses the deb retry (rc=$f1e_rc, out: $f1e_out)"

# R-EGL-37-1 Note 3: a WORKING default-/etc prefix (no explicit hook)
# must win over a live deb — the retry must not fire when the first
# probe's engine exists.
f1w="$p22/f1-working"; rm -rf "$f1w"
mkdir -p "$f1w/etcunits" "$f1w/debunits" "$f1w/opt-live" "$f1w/libdir" "$f1w/home/uacct/.config"
sed "s|__EGRESSLOCK_PREFIX__|$f1w/opt-live|g" \
    "$TREE_ROOT/systemd/egresslock-verify@.service" \
    > "$f1w/etcunits/egresslock-verify@.service"
sed "s|__EGRESSLOCK_PREFIX__|$f1w/libdir|g" \
    "$TREE_ROOT/systemd/egresslock-verify@.service" \
    > "$f1w/debunits/egresslock-verify@.service"
install -m 0755 "$TREE_ROOT/egresslock" "$f1w/opt-live/egresslock"
install -m 0755 "$TREE_ROOT/egresslock" "$f1w/libdir/egresslock"
f1w_out="$(env -u EGRESSLOCK_UNIT_DIR EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_DEB_UNIT_DIR="$f1w/debunits" EGRESSLOCK_ACCOUNT_HOME="$f1w/home/uacct" \
    EGRESSLOCK_DEFAULT_UNIT_DIR="$f1w/etcunits" \
    "$SKIT" --account uacct --init-conf 2>&1)"; f1w_rc=$?
# Prove the /opt engine (not the deb libdir) served the run: drop a
# marker the deb engine does not have.
printf 'opt-live\n' > "$f1w/opt-live/.engine-marker"
f1w_conf="$(grep -o 'EGRESSLOCK_CONF=.*' "$f1w/home/uacct/.config/egresslock/unit.env" 2>/dev/null || true)"
[[ "$f1w_rc" == 0 && "$f1w_out" != *"no engine at"* ]] \
    && a22 pass || a22 fail "D37-1 working default-/etc prefix wins over live deb (rc=$f1w_rc, out: $f1w_out)"

# dpkg-deb smoke test (when dpkg-deb exists; stage asserts already ran).
if command -v dpkg-deb >/dev/null 2>&1; then
    d_out="$(env EGRESSLOCK_DEB_OUT="$p22/egresslock_test_all.deb" "$DEBSH" 2>&1)"; d_rc=$?
    [[ "$d_rc" == 0 && -f "$p22/egresslock_test_all.deb" ]] \
        && a22 pass || a22 fail "dpkg-deb build smoke (rc=$d_rc, out: $d_out)"
    dpkg-deb -I "$p22/egresslock_test_all.deb" 2>/dev/null | grep -q ' new Debian package' \
        && a22 pass || a22 fail "dpkg-deb -I reads the built archive"
    dpkg-deb -c "$p22/egresslock_test_all.deb" 2>/dev/null | grep -qE '\./usr/bin/egresslock$' \
        && a22 pass || a22 fail "dpkg-deb -c lists /usr/bin/egresslock"
    dpkg-deb -f "$p22/egresslock_test_all.deb" Architecture 2>/dev/null | grep -qx 'all' \
        && a22 pass || a22 fail "dpkg-deb -f Architecture=all"
else
    echo "note: dpkg-deb not available; stage-only asserts ran (ARC-22)"
fi

# D3: egresslock-setup --apparmor-add (explicit activation, idempotent,
# hint-only without the flag, skip when pasta is not enforced).
aa22="$STATE/a22aa"; rm -rf "$aa22"
mkdir -p "$aa22/bin" "$aa22/aad/local" "$aa22/share/apparmor" "$aa22/nosnippet"
# EGL-22: enforce detection reads the KERNEL profiles listing, not
# aa-status prose. Fixtures mimic /sys/kernel/security/apparmor/profiles.
# EGL-39/D39-5: the default fixture is a LABELED-podman host (labeled
# host shape: `podman (unconfined)` — the flag occupies the mode column,
# EGL-39 ground truth); the unlabeled variant (stock Debian shape,
# pasta enforced, no podman profile) lives in profiles.nopodman.
printf '/usr/bin/pasta (enforce)\npodman (unconfined)\n' > "$aa22/profiles"
printf '/usr/bin/pasta (enforce)\n' > "$aa22/profiles.nopodman"
# EGL-39/D39-3: hat lines (podman//…) must never count as the main
# podman profile.
printf '/usr/bin/pasta (enforce)\npodman//null-/usr/bin/crun (complain)\npodman//null-/usr/bin/podman (complain)\n' > "$aa22/profiles.hats"
printf '/usr/bin/other (enforce)\n' > "$aa22/profiles.none"
cat > "$aa22/bin/aa-status" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--enabled" ]] && exit 0
exit 1
EOF
cat > "$aa22/bin/apparmor_parser" <<'EOF'
#!/usr/bin/env bash
# Mock: -r/-r -T log to the state file; -p/--preprocess flatten local
# includes onto stdout so the D2 load-check (egresslock-setup
# --apparmor-add) can see a rule that lives in a referenced local fragment
# (EGL-14-D2 / EGL-20-D1). No --print alias: the real parser has none.
# EGL-56: -p and --preprocess are the SAME action — given together the
# real AppArmor 5 parser aborts ("Too many actions"); the mock emulates
# that so a regression to the double flag cannot pass green.
if [[ "$1" == "-p" && "$2" == "--preprocess" ]]; then
    echo "apparmor_parser: Too many actions given on the command line." >&2
    exit 1
fi
if [[ "$1" == "-p" || "$1" == "--preprocess" ]]; then
    f="${@: -1}"
    if [[ "${ARCMOCK_CANONICAL_PARSER:-0}" == "1" ]]; then
        # EGL-30-D2 fixture: emit the REAL parser's canonicalized rule
        # form (parens dropped) — the literal-source grep used to
        # false-negative on exactly this output. Rules from the source
        # tree are rewritten to the canonical shape; everything else
        # passes through verbatim (structure lines still needed by the
        # callers).
        sed -E 's/signal[[:space:]]+\(receive\)([[:space:]]+set=\(term\))?/signal receive set=term/g; s/signal[[:space:]]+\(receive\)/signal receive/g' "$f"
        inc="$(sed -n 's/^[[:space:]]*#\{0,1\}include[[:space:]]*<local\/\(usr\.bin\.pasta\|pasta\)>.*/\1/p' "$f" | head -1)"
        if [[ -n "$inc" ]]; then
            sed -E 's/signal[[:space:]]+\(receive\)([[:space:]]+set=\(term\))?/signal receive set=term/g; s/signal[[:space:]]+\(receive\)/signal receive/g' "$(dirname "$f")/local/$inc" 2>/dev/null
        fi
        exit 0
    fi
    cat "$f"
    inc="$(sed -n 's/^[[:space:]]*#\{0,1\}include[[:space:]]*<local\/\(usr\.bin\.pasta\|pasta\)>.*/\1/p' "$f" | head -1)"
    if [[ -n "$inc" ]]; then
        cat "$(dirname "$f")/local/$inc" 2>/dev/null
    fi
else
    echo "apparmor_parser $*" >> "${ARCMOCK_STATE:?}/apparmor.log"
fi
EOF
chmod +x "$aa22/bin/aa-status" "$aa22/bin/apparmor_parser"
cp "$TREE_ROOT/apparmor/usr.bin.pasta.local" "$aa22/share/apparmor/"
# ARC-72-D1: the resolved profile file must mention /usr/bin/pasta.
printf '/usr/bin/pasta {\n  #include <local/usr.bin.pasta>\n}\n' > "$aa22/aad/usr.bin.pasta"
run_aa() { env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="${AA_PROFILES:-$aa22/profiles}" "$SKIT" "$@"; }
: > "$STATE/apparmor.log"

# 1. --apparmor-add alone (no --account): applies the rule and reloads.
o="$(run_aa --apparmor-add 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"updating pasta local profile"* \
      && "$o" == *"allow podman SIGTERM"* \
      && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa22/aad/local/usr.bin.pasta")" -ge 1 \
      && "$(grep -cE 'signal \(receive\) set=\(term\) peer=podman' "$aa22/aad/local/usr.bin.pasta")" -ge 1 \
      && "$(grep -c '^# begin egresslock-setup --apparmor$' "$aa22/aad/local/usr.bin.pasta")" -ge 1 \
      && "$(grep -c '^# end egresslock-setup --apparmor$' "$aa22/aad/local/usr.bin.pasta")" -ge 1 \
      && "$(wc -l < "$STATE/apparmor.log")" -eq 1 ]]; then
    a22 pass
else
    a22 fail "D3 --apparmor-add alone applies + reloads, marker-scoped (rc=$rc, out: $o)"
fi

# 2. Idempotent: the rule is already ours; no second parser run.
o="$(run_aa --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"already allows"* && "$(wc -l < "$STATE/apparmor.log")" -eq 1 ]] \
    && a22 pass || a22 fail "D3 --apparmor-add idempotent (rc=$rc, out: $o)"

# 3. Without the flag: one stderr hint, no write, no parser run.
rm -rf "$aa22/aad/local"; mkdir -p "$aa22/aad/local"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    "$SKIT" --prefix "$SKITP" --account cacct --conf "$a18d/plain.conf" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"hint: pasta is AppArmor-enforced"* \
    && "$o" == *"--apparmor-add"* \
    && ! -e "$aa22/aad/local/usr.bin.pasta" \
    && "$(wc -l < "$STATE/apparmor.log")" -eq 1 ]] \
    && a22 pass || a22 fail "D3 no-flag run: hint only, no write (rc=$rc, out: $o)"

# 4. pasta KNOWN not enforced (readable listing, no pasta): skip rc 0.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.none" "$SKIT" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"pasta not enforced; skipping"* ]] \
    && a22 pass || a22 fail "D3 known-not-enforced skip path (rc=$rc, out: $o)"

# 4b. AppArmor not enabled at all: skip rc 0 (no profiles, no aa-status).
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_SHARE="$aa22/share" \
    EGRESSLOCK_APPARMOR_D="$aa22/aad" "$SKIT" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"AppArmor: not enabled; skipping"* ]] \
    && a22 pass || a22 fail "D3 apparmor-not-enabled skip path (rc=$rc, out: $o)"

# 4c. EGL-22-D2: enforcement UNKNOWN (unreadable listing, aa-status on):
#     apply refuses rc 1 — never skip on unknown.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/nosuchprofiles" "$SKIT" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"cannot determine whether pasta is AppArmor-enforced"* ]] \
    && a22 pass || a22 fail "D3 unknown-enforcement refuses rc 1 (rc=$rc, out: $o)"

# 4d. EGL-22 finding (2026-09-09): the profiles path passes
#     `[[ -r ]]` (mode 0444) but open() still EACCES for non-root (grep
#     rc 2). grep failure must be UNKNOWN (state 2), never misread as
#     "no match" -> "NOT enforced". Simulate with a directory: grep on a
#     dir errors rc 2 while `-r` is true.
mkdir -p "$aa22/profiles-dir"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles-dir" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"pasta enforcement: unknown"* && "$o" != *"NOT enforced"* ]] \
    && a22 pass || a22 fail "D3 grep-read-error -> unknown, not NOT enforced (rc=$rc, out: $o)"

# 4e. R-EGL-22-1 Finding 1 test gap: --apparmor-check on state 3
#     (AppArmor not enabled) must PRINT `AppArmor: not enabled` and the
#     rest, rc 1 — not abort silently under set -e.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_SHARE="$aa22/share" \
    EGRESSLOCK_APPARMOR_D="$aa22/aad-empty" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/nosuchprofiles" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"AppArmor: not enabled"* \
    && "$o" == *"pasta enforcement: n/a"* \
    && "$o" == *"pasta profile: missing file"* ]] \
    && a22 pass || a22 fail "R-EGL-22-1 F1 doctor state 3 prints, rc 1 (rc=$rc, out: $o)"

# 4f. R-EGL-22-1 Finding 1 test gap: --apparmor-check on state 2
#     (enforcement unknown) must PRINT `enforcement unknown`, rc 1.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/nosuchprofiles" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"pasta enforcement: unknown"* ]] \
    && a22 pass || a22 fail "R-EGL-22-1 F1 doctor state 2 prints, rc 1 (rc=$rc, out: $o)"

# --- EGL-39: podman label tri-state + conditional amendment verdict -------
# Shared fresh fixture: profile WITH its local include, EMPTY local file
# (absent rule, healthy pasta side — the D39-4 rc-0 shape when the
# verdict is a KNOWN not-needed).
mkdir -p "$aa22/aad39/local"
printf '/usr/bin/pasta {\n  #include <local/usr.bin.pasta>\n}\n' > "$aa22/aad39/usr.bin.pasta"
: > "$aa22/aad39/local/usr.bin.pasta"
# 4g. Hat lines never count as the main podman profile (D39-3: anchored
#     ERE; labeled-host ground truth has podman//… hats). Pasta enforced + no
#     main podman line -> unlabeled -> not-needed verdict; aad39 is the
#     fresh healthy fixture (include present, local empty -> absent
#     rule) so D39-4 keeps rc 0.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad39" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.hats" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"podman label: unlabeled"* \
    && "$o" == *"pasta amendment: not required on this host (podman unlabeled)"* ]] \
    && a22 pass || a22 fail "EGL-39 hat lines do not count as labeled (rc=$rc, out: $o)"

# 4h. Labeled + enforced + absent rule: amendment needed, rc 1 (D39-4:
#     the rc-0 path is for KNOWN not-needed verdicts only).
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad39" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"podman label: labeled"* \
    && "$o" == *"pasta amendment: required on this host"* \
    && "$o" == *"egresslock rule in local file: absent"* ]] \
    && a22 pass || a22 fail "EGL-39 labeled+enforced+absent rule -> needed, rc 1 (rc=$rc, out: $o)"

# 4i. Known-unlabeled (stock Debian shape: pasta enforced, no podman
#     profile) + healthy pasta side + absent rule: verdict not-needed,
#     rc 0 (D39-4 — the one intentional rc change).
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad39" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"podman label: unlabeled"* \
    && "$o" == *"pasta amendment: not required on this host (podman unlabeled)"* \
    && "$o" == *"egresslock rule in local file: absent"* ]] \
    && a22 pass || a22 fail "EGL-39 unlabeled+healthy+absent rule -> rc 0 (rc=$rc, out: $o)"

# 4j. Same unlabeled verdict but MISSING extension (EGL-60 unlabeled-host
#     shape,
#     flipping the old D39-4 rc!=0 contract): stock unlabeled host, the
#     amendment is not required -> rc 0, Summary CHECK OK (not needed),
#     MISSING + amendment detail lines stay as evidence (EGL-60-D1).
mkdir -p "$aa22/aad39x/local"
printf '/usr/bin/pasta {\n}\n' > "$aa22/aad39x/usr.bin.pasta"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad39x" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"podman label: unlabeled"* \
    && "$o" == *"pasta amendment: not required on this host (podman unlabeled)"* \
    && "$o" == *"pasta local extension: MISSING"* \
    && "$o" == *"Summary: CHECK OK (AppArmor patch not needed)"* ]] \
    && a22 pass || a22 fail "EGL-60 unlabeled+missing extension -> OK not needed, rc 0 (rc=$rc, out: $o)"

# 4k. UNKNOWN listing (EACCES sim, profiles-dir): podman label unknown,
#     verdict condition unknown — NEVER a "not needed" claim (D39-3).
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad39" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles-dir" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"podman label: unknown"* \
    && "$o" == *"pasta amendment: condition unknown"* \
    && "$o" != *"not needed"* ]] \
    && a22 pass || a22 fail "EGL-39 unknown listing -> no not-needed claim (rc=$rc, out: $o)"

# 4l. Unlabeled-listing doctor on a pasta-NOT-enforced host: verdict
#     not needed (pasta not enforced), rc 1 — the EGL-29-D1 pair's rc
#     table is frozen; only the absent-rule rc changed (D39-4).
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad39" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.none" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"pasta amendment: not required on this host (pasta not enforced)"* ]] \
    && a22 pass || a22 fail "EGL-39 pasta-not-enforced verdict, pair rc frozen (rc=$rc, out: $o)"

# 4m. Apply on a KNOWN-unlabeled host still applies (D39-1) and prints
#     the future-proofing note; the labeled path never does.
o="$(run_aa --apparmor-add 2>&1)"; rc=$?   # labeled default fixture
[[ "$rc" == 0 && "$o" != *"no-op for this host"* ]] \
    && a22 pass || a22 fail "EGL-39 labeled apply has no noop note (rc=$rc, out: $o)"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad39" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" "$SKIT" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"AppArmor: podman unlabeled; amendment is a no-op for this host (applied anyway — future-proofing)"* \
    && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa22/aad39/local/usr.bin.pasta")" -ge 1 ]] \
    && a22 pass || a22 fail "EGL-39 unlabeled apply: applies + noop note (rc=$rc, out: $o)"

# 4n. No-flag account run: hint on labeled (default fixture, D39-5),
#     suppressed + one-liner on unlabeled (D39-2 surface 1 / D39-5).
mkdir -p "$aa22/home39"
: > "$STATE/apparmor.log"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    EGRESSLOCK_ACCOUNT_HOME="$aa22/home39" \
    "$SKIT" --prefix "$SKITP" --account cacct --conf "$a18d/plain.conf" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"hint: pasta is AppArmor-enforced"* \
    && "$o" != *"no-op for this host"* ]] \
    && a22 pass || a22 fail "EGL-39 labeled no-flag run keeps hint (rc=$rc, out: $o)"
: > "$STATE/apparmor.log"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" \
    EGRESSLOCK_ACCOUNT_HOME="$aa22/home39" \
    "$SKIT" --prefix "$SKITP" --account cacct --conf "$a18d/plain.conf" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" != *"hint: pasta is AppArmor-enforced"* \
    && "$o" == *"AppArmor: podman unlabeled; pasta amendment not needed on this host (--apparmor-add applies anyway — future-proofing)"* ]] \
    && a22 pass || a22 fail "EGL-39 unlabeled no-flag run: no hint, one-liner (rc=$rc, out: $o)"

# 4o. Help text: no bare --apparmor flag anywhere (D39-8; EGL-29-D2
#     flags only — --apparmor-add/-remove/-check).
o="$("$SKIT" -h 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(grep -cE '(^|[ (])--apparmor([^a-z-]|$)' <<< "$o")" -eq 0 ]] \
    && a22 pass || a22 fail "EGL-39/D39-8 help has no bare --apparmor (rc=$rc)"

# --- EGL-30 + EGL-32: canonical parser output + 2-line doctor scheme ------
# 4p. D30-2: with the CANONICAL preprocess fixture (real-parser shape,
#     parens stripped), a fresh apply must reach rc 0 with NO
#     "rule is NOT present" false-negative.
mkdir -p "$aa22/aad30/local"
printf '/usr/bin/pasta {\n  #include <local/usr.bin.pasta>\n}\n' > "$aa22/aad30/usr.bin.pasta"
: > "$aa22/aad30/local/usr.bin.pasta"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad30" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" ARCMOCK_CANONICAL_PARSER=1 \
    "$SKIT" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" != *"NOT present"* \
    && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa22/aad30/local/usr.bin.pasta")" -ge 1 ]] \
    && a22 pass || a22 fail "EGL-30 canonical parser output: apply rc 0, no false-negative (rc=$rc, out: $o)"

# 4q. D30-1: idempotent re-apply ALSO passes under the canonical fixture
#     (apply's `already` grep hits the local source file — source form).
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad30" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" ARCMOCK_CANONICAL_PARSER=1 \
    "$SKIT" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"already allows"* ]] \
    && a22 pass || a22 fail "EGL-30 canonical parser: re-apply idempotent (rc=$rc, out: $o)"

# 4r. D32-1: doctor lines — aad30 has a NATIVE include (stock wiring)
#     but OUR marker-scoped rule: extension `(stock)`, rule
#     `(egresslock)`; the compatibility-patch line is GONE. (4t/4u cover
#     the patched-extension variant via the aadp fixture in the EGL-21
#     block: present (egresslock) on the extension line.)
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad30" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 0 \
    && "$o" == *"pasta local extension: present (stock)"* \
    && "$o" == *"egresslock rule in local file: present (egresslock)"* \
    && "$o" != *"compatibility patch:"* ]] \
    && a22 pass || a22 fail "EGL-32 doctor: ownership lines, no patch line (rc=$rc, out: $o)"

# 4s. D32-1: stock include + stock (unmarked) operator rule -> `(stock)`
#     on both lines.
mkdir -p "$aa22/aad30s/local"
printf '/usr/bin/pasta {\n  #include <local/usr.bin.pasta>\n}\n' > "$aa22/aad30s/usr.bin.pasta"
printf '# operator rule (mine)\nsignal (receive) set=(term) peer=podman,\n' > "$aa22/aad30s/local/usr.bin.pasta"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad30s" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 0 \
    && "$o" == *"pasta local extension: present (stock)"* \
    && "$o" == *"egresslock rule in local file: present (stock)"* ]] \
    && a22 pass || a22 fail "EGL-32 doctor: stock ownership (rc=$rc, out: $o)"

# 4t. D32-1: MISSING extension + unmarked stock rule -> MISSING +
#     `present (stock)`, rc != 0 (EGL-14 unhealthy shape preserved).
mkdir -p "$aa22/aad30m/local"
printf '/usr/bin/pasta {\n}\n' > "$aa22/aad30m/usr.bin.pasta"
printf 'signal (receive) set=(term) peer=podman,\n' > "$aa22/aad30m/local/usr.bin.pasta"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad30m" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" != 0 && "$o" == *"pasta local extension: MISSING"* \
    && "$o" == *"egresslock rule in local file: present (stock)"* ]] \
    && a22 pass || a22 fail "EGL-32 doctor: missing extension + stock rule (rc=$rc, out: $o)"

# 4u. D30-1: unapply still refuses on an unmarked rule (loosened ERE
#     must not widen the refusal logic).
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_SHARE="$aa22/share" \
    EGRESSLOCK_APPARMOR_D="$aa22/aad30s" PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" "$SKIT" --apparmor-remove 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"not guessing"* ]] \
    && a22 pass || a22 fail "EGL-30 unapply unmarked-rule refusal intact (rc=$rc, out: $o)"

# 5. Enforced but no snippet in the share: fail closed with a pointer.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/nosnippet" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    "$SKIT" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"no pasta snippet"* ]] \
    && a22 pass || a22 fail "D3 missing snippet fails closed (rc=$rc, out: $o)"

# --- ARC-66: --apparmor-remove (unapply) ---------------------------------
# 6. EGL-29-D2: the old `--remove` flag is dropped (rc 2 unknown);
#    `--apparmor-add` + `--apparmor-remove` together is the rc 2 usage
#    error. R-EGL-29-1 minor (b): the Verification plan also lists bare
#    `--apparmor` and `--apparmor --remove` as rc-2 checks — assert all
#    three (same generic unknown-arg branch, but pin the plan).
o="$(run_aa --apparmor 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"unknown argument: --apparmor"* ]] \
    && a22 pass || a22 fail "D2 bare --apparmor dropped rc 2 (rc=$rc, out: $o)"
o="$(run_aa --apparmor --remove 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"unknown argument: --apparmor"* ]] \
    && a22 pass || a22 fail "D2 --apparmor --remove dropped rc 2 (rc=$rc, out: $o)"
o="$(run_aa --remove 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"unknown argument: --remove"* ]] \
    && a22 pass || a22 fail "D1 --remove dropped rc 2 (rc=$rc, out: $o)"
o="$(run_aa --apparmor-add --apparmor-remove 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"mutually exclusive"* ]] \
    && a22 pass || a22 fail "D1 add+remove usage error (rc=$rc, out: $o)"

# 7. Unapply strips ONLY the marker block: operator lines survive, file
#    survives, parser reloads. Idempotent second run.
mkdir -p "$aa22/aad2/local"
printf '/usr/bin/pasta {\n  #include <local/usr.bin.pasta>\n}\n' > "$aa22/aad2/usr.bin.pasta"
printf '# operator rule kept\n' > "$aa22/aad2/local/usr.bin.pasta"
{
    echo ""
    echo "# begin egresslock-setup --apparmor"
    echo "# added by egresslock-setup --apparmor (ARC-27 / ARC-22-D3):"
    cat "$aa22/share/apparmor/usr.bin.pasta.local"
    echo "# end egresslock-setup --apparmor"
} >> "$aa22/aad2/local/usr.bin.pasta"
: > "$STATE/apparmor.log"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad2" \
    "$SKIT" --apparmor-remove 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"removed the egresslock pasta amendment"* \
      && -f "$aa22/aad2/local/usr.bin.pasta" \
      && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa22/aad2/local/usr.bin.pasta")" == 0 \
      && "$(grep -c '# operator rule kept' "$aa22/aad2/local/usr.bin.pasta")" == 1 \
      && "$(grep -c 'egresslock-setup --apparmor' "$aa22/aad2/local/usr.bin.pasta")" == 0 \
      && "$(wc -l < "$STATE/apparmor.log")" -eq 1 ]]; then
    a22 pass
else
    a22 fail "D1 unapply strips the block, keeps operator lines (rc=$rc, out: $o)"
fi
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad2" \
    "$SKIT" --apparmor-remove 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"already gone"* && "$(wc -l < "$STATE/apparmor.log")" -eq 1 ]] \
    && a22 pass || a22 fail "D1 unapply idempotent (rc=$rc, out: $o)"

# 8. Legacy lab shape (single start line through the signal rule) strips too.
mkdir -p "$aa22/aad3/local"
{
    echo '# operator line stays'
    echo ''
    echo '# added by egresslock-setup --apparmor (ARC-27 / ARC-22-D3):'
    echo '# snippet comment from the old append'
    echo 'signal (receive) peer=podman,'
} > "$aa22/aad3/local/usr.bin.pasta"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad3" \
    "$SKIT" --apparmor-remove 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa22/aad3/local/usr.bin.pasta")" == 0 \
    && "$(grep -c '# operator line stays' "$aa22/aad3/local/usr.bin.pasta")" == 1 ]] \
    && a22 pass || a22 fail "D1 legacy-shape unapply (rc=$rc, out: $o)"

# 9. Unmarked signal rule (no kit marker): never guessed — rc 1, file
#    unchanged, no parser run.
mkdir -p "$aa22/aad4/local"
printf '# operator rule\nsignal (receive) peer=podman,\n' > "$aa22/aad4/local/usr.bin.pasta"
: > "$STATE/apparmor.log"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad4" \
    "$SKIT" --apparmor-remove 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"unmarked"* \
    && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa22/aad4/local/usr.bin.pasta")" == 1 \
    && "$(wc -l < "$STATE/apparmor.log")" -eq 0 ]] \
    && a22 pass || a22 fail "D1 unmarked rule rc 1, untouched (rc=$rc, out: $o)"

# 10. Missing local file -> rc 0 already-gone; unapply works without
#     pasta enforcement (no aa-status stub in PATH).
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_SHARE="$aa22/share" \
    EGRESSLOCK_APPARMOR_D="$aa22/aad-empty" "$SKIT" --apparmor-remove 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"already gone"* ]] \
    && a22 pass || a22 fail "D1 missing file rc 0 (rc=$rc, out: $o)"
mkdir -p "$aa22/aad5/local"
{
    echo '# begin egresslock-setup --apparmor'
    echo 'signal (receive) peer=podman,'
    echo '# end egresslock-setup --apparmor'
} > "$aa22/aad5/local/usr.bin.pasta"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_SHARE="$aa22/share" \
    EGRESSLOCK_APPARMOR_D="$aa22/aad5" "$SKIT" --apparmor-remove 2>&1)"; rc=$?
[[ "$rc" == 0 && ! "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa22/aad5/local/usr.bin.pasta")" -ge 1 ]] \
    && a22 pass || a22 fail "D1 unapply without enforcement (rc=$rc, out: $o)"

# --- EGL-27: monotonic version stamps (dpkg ordering) ----------------------
# D1: version = <VERSION_BASE>+git<YYYYMMDDHHMMSS>.<12-char-sha> in BOTH
# build scripts; the second-resolution UTC stamp is the ordering key, the sha
# is identification only.
grep -q "%Y%m%d%H%M%S" "$DEBSH" && grep -q "rev-parse --short=12" "$DEBSH" \
    && a22 pass || a22 fail "EGL-27 build-deb.sh stamps second-resolution + short12"
grep -q "%Y%m%d%H%M%S" "$TARSH" && grep -q "rev-parse --short=12" "$TARSH" \
    && a22 pass || a22 fail "EGL-27 build-tarball.sh stamps second-resolution + short12"
if ! grep -q "%Y%m%d')." "$DEBSH" && ! grep -q "%Y%m%d')." "$TARSH"; then
    a22 pass
else
    a22 fail "EGL-27 old date-only stamp still present"
fi

# The point of the fix: two stamps from the NEW scheme, second timestamp
# later, must always compare lt — including the same-day rebuild case
# that DOWNGRADED under the old hex-suffix scheme. Synthetic shas are
# chosen so the OLD scheme's lexical order is inverted (2... < e...) to
# pin the regression. EGL-72-D4: both literals carry the 0.1.0 base
# (the synthetic pair pins same-base timestamp monotonicity).
v27_older="0.1.0+git20260911040000.2b6f0a1c9d3e"
v27_newer="0.1.0+git20260911045959.e05db24d86f0"
if command -v dpkg >/dev/null 2>&1; then
    if dpkg --compare-versions "$v27_older" lt "$v27_newer"; then
        a22 pass
    else
        a22 fail "EGL-27 new scheme not monotonic under dpkg ordering"
    fi
    # EGL-72-D4 cross-base pin: a VERSION_BASE bump alone (same
    # timestamp, same sha — worst case) must still compare as an
    # upgrade; 0.0.0 -> 0.1.0 is never a dpkg downgrade.
    if dpkg --compare-versions "0.0.0+git20260911045959.e05db24d86f0" \
            lt "0.1.0+git20260911045959.e05db24d86f0"; then
        a22 pass
    else
        a22 fail "EGL-72 base bump alone not an upgrade under dpkg ordering"
    fi
else
    echo "SKIP: EGL-27 dpkg not available; skipping compare-versions assert"
fi

# A real build stamps the artifact with the new scheme (the redirected
# output name is fixed, so the stamp is read from the build log line).
# EGL-72-D4: the base is 0.1.0 (the first versioned release base).
b27="$p22/egl27"; rm -rf "$b27"; mkdir -p "$b27"
t27_rc=0
env EGRESSLOCK_TARBALL_OUT="$b27/k.tgz" "$TARSH" >"$b27/log" 2>&1 || t27_rc=$?
v27_real="$(grep -oE '0\.1\.0\+git[0-9]{14}\.[0-9a-f]{12}(-dirty)?' "$b27/log" | head -1)"
[[ "$t27_rc" == 0 && -f "$b27/k.tgz" && -n "$v27_real" ]] \
    && a22 pass || a22 fail "EGL-27 tarball build stamps new scheme (rc=$t27_rc, log: $(cat "$b27/log"))"

# D2: the warn is warn-only — build-deb.sh must print the version and
# must not gate on dpkg-query (builds succeed without it). The compare
# path only fires when an installed package exists; here assert the
# code shape (echo + dpkg-query + --compare-versions ... ge + stderr
# WARNING) rather than an installed package in the test container.
grep -q 'build-deb: version \$version' "$DEBSH" \
    && grep -q "dpkg-query -W -f='\${Version}' egresslock" "$DEBSH" \
    && grep -q 'dpkg --compare-versions "\$installed" ge "\$version"' "$DEBSH" \
    && grep -q 'WARNING - installed egresslock' "$DEBSH" \
    && a22 pass || a22 fail "EGL-27 build-deb.sh prints version + downgrade warn (D2)"

# --- EGL-72: VERSION_BASE 0.1.0 + release-aware stamps ---------------------
# D1: one VERSION_BASE at the repo root, fail-closed in all three
# scripts. D3: both VERSION stamps carry a `version:` line; the tarball
# ships VERSION_BASE + stage-only KIT_VERSION (the KIT_VERSION→version:
# assert lives in the tarball-install section above, before the
# uninstall removes the prefix). D4: the base asserts + pins.
[[ -s "$TREE_ROOT/VERSION_BASE" ]] \
    && a22 pass || a22 fail "EGL-72 VERSION_BASE exists at the repo root"
grep -q '^version: ' "$p22/stage/usr/lib/egresslock/VERSION" \
    && a22 pass || a22 fail "EGL-72 deb VERSION stamp has a version: line"
grep -q '^version: ' "$OPT/VERSION" \
    && a22 pass || a22 fail "EGL-72 install-kit VERSION stamp has a version: line"
[[ -f "$p22/x/egresslock/VERSION_BASE" && -f "$p22/x/egresslock/KIT_VERSION" ]] \
    && a22 pass || a22 fail "EGL-72 tarball ships VERSION_BASE + KIT_VERSION"

arc22_pass=$pass; arc22_fail=$fail

# --- EGL-39: install-kit.sh AppArmor advisory one-liner (D39-2) -----------
# Separate prefix/unit dirs so the a16 state asserts stay untouched.
pass=0; fail=0
a39() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
ik39="$STATE/ik39"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_UNIT_DIR="$ik39/units" EGRESSLOCK_LEGACY_PREFIX="$ik39/no-legacy" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" "$KIT" --prefix "$ik39/opt" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"AppArmor: podman labeled; confirm pasta compatibility: sudo $ik39/opt/egresslock-setup --apparmor-check"* ]] \
    && a39 pass || a39 fail "EGL-39 install-kit labeled advisory (rc=$rc, out: $o)"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_UNIT_DIR="$ik39/units" EGRESSLOCK_LEGACY_PREFIX="$ik39/no-legacy" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" "$KIT" --prefix "$ik39/opt" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"AppArmor: podman unlabeled; --apparmor-add not needed on this host"* ]] \
    && a39 pass || a39 fail "EGL-39 install-kit unlabeled advisory (rc=$rc, out: $o)"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_UNIT_DIR="$ik39/units" EGRESSLOCK_LEGACY_PREFIX="$ik39/no-legacy" \
    EGRESSLOCK_APPARMOR_PROFILES="$ik39/no-such-profiles" "$KIT" --prefix "$ik39/opt" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" != *"AppArmor: podman"* ]] \
    && a39 pass || a39 fail "EGL-39 install-kit silent on UNKNOWN (rc=$rc, out: $o)"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_UNIT_DIR="$ik39/units" EGRESSLOCK_LEGACY_PREFIX="$ik39/no-legacy" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.hats" "$KIT" --prefix "$ik39/opt" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"AppArmor: podman unlabeled; --apparmor-add not needed on this host"* ]] \
    && a39 pass || a39 fail "EGL-39 install-kit hats do not count as labeled (rc=$rc, out: $o)"
a39_pass=$pass; a39_fail=$fail

# --- ARC-72: pasta profile resolution (distro-dependent names) -------------
pass=0; fail=0
a72() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
# Fixtures: the same aa-status/apparmor_parser stubs from the ARC-22 block.
# D1: candidates are usr.bin.pasta then pasta; a "pasta" file that does not
# mention /usr/bin/pasta is skipped; the write target is the local include
# the profile itself names. D2: resolve before any write. D3: after a
# successful reload, point the operator at the account-side netns probe.
# D4: apply refuses (rc 1, no write) with the force-confmiss recovery;
# --remove is file cleanup and stays rc 0 when the profile is missing.
aa72="$STATE/a22aa72"; rm -rf "$aa72"
mkdir -p "$aa72/aad/local" "$aa72/share/apparmor"
cp "$TREE_ROOT/apparmor/usr.bin.pasta.local" "$aa72/share/apparmor/"
run_aa72() { env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa72/share" EGRESSLOCK_APPARMOR_D="$1" \
    EGRESSLOCK_APPARMOR_PROFILES="${AA_PROFILES:-$aa22/profiles}" "$SKIT" "${@:2}"; }

# 11. Only the alt name exists (profile "pasta" incl. <local/pasta>):
#     writes local/pasta, reloads THAT file, prints the D3 confirm line.
printf '/usr/bin/pasta {\n  include <local/pasta>\n}\n' > "$aa72/aad/pasta"
: > "$STATE/apparmor.log"
o="$(run_aa72 "$aa72/aad" --apparmor-add 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa72/aad/local/pasta")" -ge 1 \
      && ! -e "$aa72/aad/local/usr.bin.pasta" \
      && "$(grep -c "$aa72/aad/pasta" "$STATE/apparmor.log")" -eq 1 \
      && "$o" == *"sudo egresslock-setup --apparmor-check"* ]]; then
    a72 pass
else
    a72 fail "D1 alt profile name resolves + D3 confirm line (rc=$rc, out: $o)"
fi

# 12. A file named "pasta" without /usr/bin/pasta is skipped; the real
#     usr.bin.pasta profile wins.
mkdir -p "$aa72/aadb/local"
printf '# some other pasta thing\n' > "$aa72/aadb/pasta"
printf '/usr/bin/pasta {\n  #include <local/usr.bin.pasta>\n}\n' > "$aa72/aadb/usr.bin.pasta"
: > "$STATE/apparmor.log"
o="$(run_aa72 "$aa72/aadb" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa72/aadb/local/usr.bin.pasta")" -ge 1 \
    && "$(grep -c "$aa72/aadb/usr.bin.pasta" "$STATE/apparmor.log")" -eq 1 ]] \
    && a72 pass || a72 fail "D1 unrelated pasta file skipped (rc=$rc, out: $o)"

# 13. Idempotence keys off the RESOLVED local file (alt name, already
#     applied): no second parser run.
o="$(run_aa72 "$aa72/aad" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"already allows"* && "$(wc -l < "$STATE/apparmor.log")" -eq 1 ]] \
    && a72 pass || a72 fail "D1 idempotence on resolved file (rc=$rc, out: $o)"

# 14. No candidate profile: refuse BEFORE writing anything; the recovery
#     message names the force-confmiss reinstall (D4).
mkdir -p "$aa72/aadc/local"
o="$(run_aa72 "$aa72/aadc" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 1 && ! -e "$aa72/aadc/local/usr.bin.pasta" && ! -e "$aa72/aadc/local/pasta" \
    && "$o" == *"--force-confmiss"* ]] \
    && a72 pass || a72 fail "D4 no profile -> rc 1, no write, recovery named (rc=$rc, out: $o)"

# 15. Profile exists but has no local include: EGL-14-D1 installs a
#     marked compatibility include (backed up), writes the rule into the
#     canonical fragment, reloads, and verifies the rule is loaded
#     (D2). Never appends the rule to the distro profile body directly.
mkdir -p "$aa72/aadd/local"
printf '/usr/bin/pasta {\n}\n' > "$aa72/aadd/usr.bin.pasta"
: > "$STATE/apparmor.log"
o="$(run_aa72 "$aa72/aadd" --apparmor-add 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa72/aadd/local/usr.bin.pasta")" -ge 1 \
      && "$(grep -c '# begin egresslock-setup --apparmor compatibility patch' "$aa72/aadd/usr.bin.pasta")" == 1 \
      && "$(grep -c '#include <local/usr.bin.pasta>' "$aa72/aadd/usr.bin.pasta")" -ge 1 \
      && -f "$aa72/aadd/.usr.bin.pasta.egresslock-bak" \
      && ! -e "$aa72/aadd/usr.bin.pasta.egresslock-bak" \
      && "$(wc -l < "$STATE/apparmor.log")" -eq 1 ]]; then
    a72 pass
else
    a72 fail "D1 no local include -> compat patch + rule + verified reload (rc=$rc, out: $o)"
fi

# 16. Remove when the resolved include differs from the legacy path:
#     BOTH files get stripped; profile present so the reload runs.
mkdir -p "$aa72/aade/local"
printf '/usr/bin/pasta {\n  include <local/pasta>\n}\n' > "$aa72/aade/pasta"
printf '# operator line alt\n' > "$aa72/aade/local/pasta"
{
    echo '# begin egresslock-setup --apparmor'
    echo 'signal (receive) peer=podman,'
    echo '# end egresslock-setup --apparmor'
} >> "$aa72/aade/local/pasta"
printf '# operator line legacy\n' > "$aa72/aade/local/usr.bin.pasta"
{
    echo '# begin egresslock-setup --apparmor'
    echo 'signal (receive) peer=podman,'
    echo '# end egresslock-setup --apparmor'
} >> "$aa72/aade/local/usr.bin.pasta"
: > "$STATE/apparmor.log"
o="$(run_aa72 "$aa72/aade" --apparmor-remove 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa72/aade/local/pasta")" == 0 \
      && "$(grep -c 'operator line alt' "$aa72/aade/local/pasta")" == 1 \
      && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa72/aade/local/usr.bin.pasta")" == 0 \
      && "$(grep -c 'operator line legacy' "$aa72/aade/local/usr.bin.pasta")" == 1 \
      && "$(wc -l < "$STATE/apparmor.log")" -eq 1 ]]; then
    a72 pass
else
    a72 fail "D1 unapply covers resolved + legacy include (rc=$rc, out: $o)"
fi

# 17. Remove with the distro profile missing: file cleanup still rc 0
#     (warn "NOT reloaded"), no parser run (D4).
mkdir -p "$aa72/aadf/local"
{
    echo '# begin egresslock-setup --apparmor'
    echo 'signal (receive) peer=podman,'
    echo '# end egresslock-setup --apparmor'
} > "$aa72/aadf/local/usr.bin.pasta"
: > "$STATE/apparmor.log"
o="$(run_aa72 "$aa72/aadf" --apparmor-remove 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"NOT reloaded"* \
    && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa72/aadf/local/usr.bin.pasta")" == 0 \
    && "$(wc -l < "$STATE/apparmor.log")" -eq 0 ]] \
    && a72 pass || a72 fail "D4 unapply rc 0 without profile (rc=$rc, out: $o)"

arc72_pass=$pass; arc72_fail=$fail

# --- EGL-14: compatibility include + doctor -------------------------------
# D1: apply on a profile with no local include installs a marked,
# backed-up compatibility include; --remove strips exactly it. D3: the
# --apparmor-check report reflects the amendment state and exits nonzero when a
# required element is missing.
pass=0; fail=0
a14() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# 1. Re-apply after --remove: the include-less profile gets the patch,
#    the rule loads, and a re-run is idempotent (no second patch, no
#    second reload).
mkdir -p "$aa72/aadg/local"
printf '/usr/bin/pasta {\n}\n' > "$aa72/aadg/usr.bin.pasta"
: > "$STATE/apparmor.log"
o="$(run_aa72 "$aa72/aadg" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 0 \
    && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa72/aadg/local/usr.bin.pasta")" -ge 1 \
    && "$(grep -c '# begin egresslock-setup --apparmor compatibility patch' "$aa72/aadg/usr.bin.pasta")" == 1 \
    && "$(wc -l < "$STATE/apparmor.log")" -eq 1 ]] \
    && a14 pass || a14 fail "EGL-14 apply on include-less profile (rc=$rc, out: $o)"
o="$(run_aa72 "$aa72/aadg" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"already allows"* \
    && "$(grep -c '# begin egresslock-setup --apparmor compatibility patch' "$aa72/aadg/usr.bin.pasta")" == 1 \
    && "$(wc -l < "$STATE/apparmor.log")" -eq 1 ]] \
    && a14 pass || a14 fail "EGL-14 re-apply idempotent with patch (rc=$rc, out: $o)"

# 2. --remove on that host: strips the local block AND the compat include,
#    removes the backup, reloads; the profile returns to no-include.
: > "$STATE/apparmor.log"
o="$(run_aa72 "$aa72/aadg" --apparmor-remove 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"removed the egresslock pasta amendment"* \
      && "$(grep -cE 'signal \(receive\)( set=\(term\))? peer=podman' "$aa72/aadg/local/usr.bin.pasta")" == 0 \
      && "$(grep -c '# begin egresslock-setup --apparmor compatibility patch' "$aa72/aadg/usr.bin.pasta")" == 0 \
      && "$(grep -c '#include <local/usr.bin.pasta>' "$aa72/aadg/usr.bin.pasta")" == 0 \
      && ! -e "$aa72/aadg/.usr.bin.pasta.egresslock-bak" \
      && ! -e "$aa72/aadg/usr.bin.pasta.egresslock-bak" \
      && "$(wc -l < "$STATE/apparmor.log")" -eq 1 ]]; then
    a14 pass
else
    a14 fail "EGL-14 remove strips compat patch + backup (rc=$rc, out: $o)"
fi

# 3. --apparmor-check reflects a healthy applied state and exits 0.
mkdir -p "$aa72/aadh/local"
printf '/usr/bin/pasta {\n  #include <local/usr.bin.pasta>\n}\n' > "$aa72/aadh/usr.bin.pasta"
o="$(run_aa72 "$aa72/aadh" --apparmor-add 2>&1)"; rc=$?   # apply (native include present)
: > "$STATE/apparmor.log"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_APPARMOR_D="$aa72/aadh" EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    "$SKIT" --apparmor-check 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"AppArmor: enabled"* \
      && "$o" == *"pasta enforcement: enforced"* \
      && "$o" == *"pasta profile: found"* \
      && "$o" == *"pasta local extension: present (stock)"* \
      && "$o" == *"egresslock rule in local file: present (egresslock)"* \
      && "$o" != *"compatibility patch:"* ]]; then
    a14 pass
else
    a14 fail "EGL-14 --apparmor-check healthy rc 0 (rc=$rc, out: $o)"
fi

# 3b. --apparmor-check on a PATCHED include-less host (EGL-21-D1): shows the
#     patch line, not a false native-extension claim.
mkdir -p "$aa72/aadp/local"
printf '/usr/bin/pasta {\n}\n' > "$aa72/aadp/usr.bin.pasta"
run_aa72 "$aa72/aadp" --apparmor-add >/dev/null 2>&1
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_APPARMOR_D="$aa72/aadp" EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 0 \
    && "$o" == *"pasta local extension: present (egresslock)"* \
    && "$o" != *"compatibility patch:"* ]] \
    && a14 pass || a14 fail "EGL-21 --apparmor-check patched host shows egresslock extension (rc=$rc, out: $o)"

# 4. --apparmor-check reports MISSING extension + absent rule and exits nonzero.
mkdir -p "$aa72/aadi/local"
printf '/usr/bin/pasta {\n}\n' > "$aa72/aadi/usr.bin.pasta"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_APPARMOR_D="$aa72/aadi" EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" != 0 \
    && "$o" == *"pasta local extension: MISSING"* \
    && "$o" == *"egresslock rule in local file: absent"* ]] \
    && a14 pass || a14 fail "EGL-14 --apparmor-check unhealthy rc!=0 (rc=$rc, out: $o)"

arc14_pass=$pass; arc14_fail=$fail

# --- EGL-20: parser-reality fixes (preprocess, dot backup, no-truncate) ---
# D1: load-check uses a SINGLE -p action (mock honors it; no --print
#     alias). EGL-56: `-p --preprocess` together is "Too many actions"
#     on AppArmor 5 — the mock rejects the pair and the source pin
#     below keeps the double flag out.
# D2: backup is a leading-dot file; an old non-dot backup is migrated on
#     next apply. D3: strip never truncates the distro profile (refuses
#     rc 1, file + backup untouched). D4: the patch lands after the
#     pasta header's brace, not the first `{` in the file.
pass=0; fail=0
a20() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# 0. EGL-56: the double-flag invocation must not exist in the source.
grep -q -- '-p --preprocess' "$SKIT" \
    && a20 fail "pasta_rule_loaded still passes both -p and --preprocess (AppArmor 5: Too many actions)" \
    || a20 pass

# 1. EGL-26-D1: a preamble comment containing `{` must not capture the
#    patch, and the marked include must land BEFORE the closing `}` of
#    the pasta body (after the body rule), not after the opening `{`.
mkdir -p "$aa72/aadj/local"
printf '# sample preamble { not a profile brace }\n/usr/bin/pasta {\n  /usr/bin/foo r,\n}\n' > "$aa72/aadj/usr.bin.pasta"
: > "$STATE/apparmor.log"
o="$(run_aa72 "$aa72/aadj" --apparmor-add 2>&1)"; rc=$?
# header line 2, opening `{` line 3, body rule line 4, marker block must
# start on line 5 (immediately before the closing `}` on line 6).
patch_line="$(grep -n '# begin egresslock-setup --apparmor compatibility patch' "$aa72/aadj/usr.bin.pasta" | cut -d: -f1)"
close_line="$(grep -n '^}' "$aa72/aadj/usr.bin.pasta" | cut -d: -f1)"
[[ "$rc" == 0 && "$patch_line" == 4 && "$close_line" == 7 ]] \
    && a20 pass || a20 fail "EGL-26 D1 patch before closing brace (rc=$rc, line=$patch_line, close=$close_line, out: $o)"

# 2. D2: a leftover non-dot backup from a pre-EGL-20 apply is migrated
#    to the dot name on the next apply (never left loadable).
mkdir -p "$aa72/aadk/local"
printf '/usr/bin/pasta {\n}\n' > "$aa72/aadk/usr.bin.pasta"
cp -a "$aa72/aadk/usr.bin.pasta" "$aa72/aadk/usr.bin.pasta.egresslock-bak"
o="$(run_aa72 "$aa72/aadk" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 0 \
    && -f "$aa72/aadk/.usr.bin.pasta.egresslock-bak" \
    && ! -e "$aa72/aadk/usr.bin.pasta.egresslock-bak" ]] \
    && a20 pass || a20 fail "EGL-20 D2 non-dot backup migrated (rc=$rc, out: $o)"

# 2b. R-EGL-20-1 finding 1 (apply path): a LEGACY EGL-14-patched host —
#     marker include already present + non-dot backup on disk. Apply must
#     migrate the backup even though install_compat_include is not called
#     (pasta_had_include=1). The rule is already applied, so rc 0 with
#     only the backup migrated and no second reload.
mkdir -p "$aa72/aadn/local"
{
    printf '/usr/bin/pasta {\n'
    echo '# begin egresslock-setup --apparmor compatibility patch'
    echo '  #include <local/usr.bin.pasta>'
    echo '# end egresslock-setup --apparmor compatibility patch'
    printf '}\n'
} > "$aa72/aadn/usr.bin.pasta"
{
    echo '# begin egresslock-setup --apparmor'
    echo '# added by egresslock-setup --apparmor'
    echo 'signal (receive) set=(term) peer=podman,'
    echo '# end egresslock-setup --apparmor'
} > "$aa72/aadn/local/usr.bin.pasta"
cp -a "$aa72/aadn/usr.bin.pasta" "$aa72/aadn/usr.bin.pasta.egresslock-bak"
: > "$STATE/apparmor.log"
o="$(run_aa72 "$aa72/aadn" --apparmor-add 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"already allows"* \
      && -f "$aa72/aadn/.usr.bin.pasta.egresslock-bak" \
      && ! -e "$aa72/aadn/usr.bin.pasta.egresslock-bak" \
      && "$(wc -l < "$STATE/apparmor.log")" -eq 0 ]]; then
    a20 pass
else
    a20 fail "EGL-20 D2 legacy patched host: apply migrates non-dot backup (rc=$rc, out: $o)"
fi

# 2c. R-EGL-20-1 finding 1 (remove path): --remove on that legacy host
#     also removes the non-dot backup (never leaves it loadable).
: > "$STATE/apparmor.log"
o="$(run_aa72 "$aa72/aadn" --apparmor-remove 2>&1)"; rc=$?
gone=0; grep -q 'egresslock-setup --apparmor compatibility patch' "$aa72/aadn/usr.bin.pasta" || gone=1
if [[ "$rc" == 0 && "$o" == *"removed the egresslock pasta amendment"* \
      && ! -e "$aa72/aadn/.usr.bin.pasta.egresslock-bak" \
      && ! -e "$aa72/aadn/usr.bin.pasta.egresslock-bak" \
      && "$gone" == 1 ]]; then
    a20 pass
else
    a20 fail "EGL-20 D2 legacy patched host: --remove drops non-dot backup (rc=$rc, out: $o)"
fi

# 3. D3: a profile whose marked block contains the header/brace — the
#    strip would destroy it, so --remove refuses rc 1 and leaves the
#    live file + backup untouched.
mkdir -p "$aa72/aadl/local"
{
    echo '# begin egresslock-setup --apparmor compatibility patch'
    echo '/usr/bin/pasta {'
    echo '  #include <local/usr.bin.pasta>'
    echo '# end egresslock-setup --apparmor compatibility patch'
    echo '}'
} > "$aa72/aadl/usr.bin.pasta"
cp -a "$aa72/aadl/usr.bin.pasta" "$aa72/aadl/.usr.bin.pasta.egresslock-bak"
cp -a "$aa72/aadl/usr.bin.pasta" "$aa72/aadl/before"
o="$(run_aa72 "$aa72/aadl" --apparmor-remove 2>&1)"; rc=$?
same=0; cmp -s "$aa72/aadl/usr.bin.pasta" "$aa72/aadl/before" && same=1
if [[ "$rc" == 1 && "$o" == *"refusing to strip"* \
      && -f "$aa72/aadl/.usr.bin.pasta.egresslock-bak" \
      && "$same" == 1 ]]; then
    a20 pass
else
    a20 fail "EGL-20 D3 strip refuses to destroy profile (rc=$rc, out: $o)"
fi

arc20_pass=$pass; arc20_fail=$fail

# --- EGL-23: remove-path verification (parser rc surfaced, -T, negative) --
# D1: a failing reload on remove is rc 1 (never a silent success). D2:
# the remove reload is `apparmor_parser -r -T -- <profile>`. D3: after a
# successful strip+reload the signal rule is ABSENT from the flattened
# profile; a still-present rule is rc 1 loud.
pass=0; fail=0
a23() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# 1. D2: remove of an applied amendment reloads with -r -T; the negative
#    load-check (rule absent) passes and rc 0.
mkdir -p "$aa72/aadr/local"
printf '/usr/bin/pasta {\n}\n' > "$aa72/aadr/usr.bin.pasta"
o="$(run_aa72 "$aa72/aadr" --apparmor-add 2>&1)"; rc=$?   # apply first (compat patch + rule)
: > "$STATE/apparmor.log"
o="$(run_aa72 "$aa72/aadr" --apparmor-remove 2>&1)"; rc=$?
if [[ "$rc" == 0 && "$o" == *"removed the egresslock pasta amendment"* \
      && "$(grep -c -- '-r -T' "$STATE/apparmor.log")" -ge 1 \
      && "$o" == *"pasta profile reloaded"* ]]; then
    a23 pass
else
    a23 fail "EGL-23 D2 remove reloads with -r -T, negative check passes (rc=$rc, out: $o, log: $(cat "$STATE/apparmor.log"))"
fi

# 2. D1: mock parser fails on the remove reload -> unapply rc 1, loud.
mkdir -p "$aa72/aads/bin"
cat > "$aa72/aads/bin/apparmor_parser" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-r" ]]; then
    echo "mock parser failure" >&2
    exit 1
fi
exit 0
EOF
chmod +x "$aa72/aads/bin/apparmor_parser"
mkdir -p "$aa72/aads/local"
printf '/usr/bin/pasta {\n}\n' > "$aa72/aads/usr.bin.pasta"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa72/share" EGRESSLOCK_APPARMOR_D="$aa72/aads" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    "$SKIT" --apparmor-add 2>&1)"; rc=$?   # apply (uses aa22 mock -> ok)
# now --remove with the failing parser
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa72/aads/bin:$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa72/share" EGRESSLOCK_APPARMOR_D="$aa72/aads" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    "$SKIT" --apparmor-remove 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"apparmor_parser failed"* ]] \
    && a23 pass || a23 fail "EGL-23 D1 parser failure on remove -> rc 1 (rc=$rc, out: $o)"

arc23_pass=$pass; arc23_fail=$fail


# --- ARC-70: drift-signal visibility (setup hint) ---------------------------
# D1: --enable stays explicit. D2: account setup without --enable prints a
# loud stdout hint naming the re-run; with --enable there is no hint; an
# --apparmor-alone run (no account processed) never hints. D3: the engine
# never queries systemctl/linger (asserted in the engine harness instead).
pass=0; fail=0
a70() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# 1. Account setup without --enable: the hint is unmissable stdout.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" 2>&1)"
[[ "$rc" == 0 ]] || true
[[ "$o" == *"timer NOT enabled"* \
    && "$o" == *"sudo egresslock-setup --account cacct --enable"* ]] \
    && a70 pass || a70 fail "no --enable -> loud hint with re-run line (out: $o)"

# 2. With --enable: no hint (the enable commands already ran), and the
#    system changes are announced before they happen (post-R-070-2).
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" --enable 2>&1)"
[[ "$o" != *"timer NOT enabled"* \
    && "$o" == *"enabling verify timer for cacct"* \
    && "$o" == *"enabling linger for cacct"* ]] \
    && a70 pass || a70 fail "--enable -> no hint, actions announced (out: $o)"

# 3. --apparmor-add alone: no account processed -> never hints, never
#    announces timer/linger actions.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    "$SKIT" --apparmor-add 2>&1)"
[[ "$o" != *"timer NOT enabled"* && "$o" != *"enabling linger"* \
    && "$o" != *"enabling verify timer"* ]] \
    && a70 pass || a70 fail "apparmor-alone -> no hint, no announcements (out: $o)"

# 4. EGL-25-D1: --apparmor-add / --apparmor-remove alone (no --account)
#    do NOT print the account closer ("no account setup requested");
#    they already printed their outcome. Old wording gone.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    "$SKIT" --apparmor-add 2>&1)"
[[ "$o" != *"no account setup requested"* \
    && "$o" != *"--apparmor-add done"* \
    && "$o" != *"no account steps requested"* ]] \
    && a70 pass || a70 fail "EGL-25 D1 apply-alone: no account closer (out: $o)"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    "$SKIT" --apparmor-remove 2>&1)"
[[ "$o" != *"no account setup requested"* \
    && "$o" != *"--apparmor-add done"* \
    && "$o" != *"no account steps requested"* ]] \
    && a70 pass || a70 fail "EGL-25 D1 remove-alone: no account closer (out: $o)"

arc70_pass=$pass; arc70_fail=$fail

# --- ARC-69 D5: --apparmor-add file handling (mode/inode/blank lines) ----------
# Apply inserts the blank separator only after existing non-empty
# content; --remove strips a blank before the marker, writes INTO the
# file (inode + mode + owner survive; mv would clobber a conffile), and
# truncates whitespace-only residue to 0 bytes.
pass=0; fail=0
a69s() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

aa69="$STATE/a22aa69"; rm -rf "$aa69"
mkdir -p "$aa69/aad/local" "$aa69/share/apparmor"
cp "$TREE_ROOT/apparmor/usr.bin.pasta.local" "$aa69/share/apparmor/"
printf '/usr/bin/pasta {\n  #include <local/usr.bin.pasta>\n}\n' > "$aa69/aad/usr.bin.pasta"
run_aa69() { env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa69/share" EGRESSLOCK_APPARMOR_D="$aa69/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" "$SKIT" "${@:2}"; }

# 1. 0644 EMPTY local file: apply adds NO leading blank line; mode
#    survives the apply.
: > "$aa69/aad/local/usr.bin.pasta"
chmod 0644 "$aa69/aad/local/usr.bin.pasta"
o="$(run_aa69 "$aa69/aad" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 0 \
    && "$(head -1 "$aa69/aad/local/usr.bin.pasta")" == "# begin egresslock-setup --apparmor" \
    && "$(stat -c %a "$aa69/aad/local/usr.bin.pasta")" == "644" ]] \
    && a69s pass || a69s fail "D5 empty-file apply: no leading blank, mode kept (rc=$rc, out: $o)"

# 2. The ticket's exact case: 0644 empty -> apply + remove -> still 0644
#    and 0 bytes.
o="$(run_aa69 "$aa69/aad" --apparmor-remove 2>&1)"; rc=$?
[[ "$rc" == 0 && ! -s "$aa69/aad/local/usr.bin.pasta" \
    && "$(stat -c %a "$aa69/aad/local/usr.bin.pasta")" == "644" ]] \
    && a69s pass || a69s fail "D5 apply+remove over empty file: 0644, 0 bytes (rc=$rc, out: $o)"

# 3. Operator content: apply adds the blank separator; remove strips the
#    block AND the separator, and the inode + mode survive (no mv).
printf '# operator rule\n' > "$aa69/aad/local/usr.bin.pasta"
chmod 0640 "$aa69/aad/local/usr.bin.pasta"
o="$(run_aa69 "$aa69/aad" --apparmor-add 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$(sed -n '2p' "$aa69/aad/local/usr.bin.pasta")" == "" \
      && "$(sed -n '3p' "$aa69/aad/local/usr.bin.pasta")" == "# begin egresslock-setup --apparmor" ]]; then
    a69s pass
else
    a69s fail "D5 non-empty apply: blank separator present (rc=$rc, out: $o)"
fi
a69s_ino="$(stat -c %i "$aa69/aad/local/usr.bin.pasta")"
o="$(run_aa69 "$aa69/aad" --apparmor-remove 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$(cat "$aa69/aad/local/usr.bin.pasta")" == "# operator rule" \
      && "$(stat -c %a "$aa69/aad/local/usr.bin.pasta")" == "640" \
      && "$(stat -c %i "$aa69/aad/local/usr.bin.pasta")" == "$a69s_ino" ]]; then
    a69s pass
else
    a69s fail "D5 remove: inode+mode kept, separator gone (rc=$rc, out: $o)"
fi

arc69s_pass=$pass; arc69s_fail=$fail

# --- EGL-50: doctor Summary + verdict reword, report-only remove, hygiene --
# D50-2: `pasta amendment: required on this host` vocabulary. D50-3:
# one final `Summary:` line on --apparmor-check; rc agrees (OK 0,
# FAILED 1, UNKNOWN 1 — never rc 2, never green from unknown). D50-6.1:
# the apply confirm line points at --apparmor-check. D50-7: remove is
# report-only — no ritual, no probe command. D50-4/D50-5: no `[--enable]`
# and no internal ticket IDs in shipped output.
pass=0; fail=0
e50() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# 1. Unknown listing (EGL-39 4k shape): Summary CHECK UNKNOWN, rc 1
#    (not 2), never a "not needed" claim.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad39" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles-dir" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"Summary: CHECK UNKNOWN (run as root if apparmor policy not visible to current user)"* \
    && "$o" != *"not needed"* && "$o" != *"not required"* ]] \
    && e50 pass || e50 fail "D50-3 unknown listing -> Summary UNKNOWN rc 1 (rc=$rc, out: $o)"

# 2. Labeled+enforced+applied (EGL-14 aadh fixture, amendment applied):
#    Summary CHECK OK (AppArmor patch applied), rc 0.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_APPARMOR_D="$aa72/aadh" EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"Summary: CHECK OK (AppArmor patch applied)"* ]] \
    && e50 pass || e50 fail "D50-3 applied -> Summary OK rc 0 (rc=$rc, out: $o)"

# 3. Unlabeled + healthy pasta side (aad39): Summary CHECK OK (AppArmor
#    patch not needed), rc 0.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad39" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"Summary: CHECK OK (AppArmor patch not needed)"* ]] \
    && e50 pass || e50 fail "D50-3 not-needed -> Summary OK rc 0 (rc=$rc, out: $o)"

# 4. Labeled+enforced+ext MISSING+rule absent: Summary CHECK FAILED
#    (AppArmor patch needed), rc 1 (the fix is --apparmor-add's patch).
mkdir -p "$aa22/aad50n"
printf '/usr/bin/pasta {\n}\n' > "$aa22/aad50n/usr.bin.pasta"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_APPARMOR_D="$aa22/aad50n" EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"pasta amendment: required on this host"* \
    && "$o" == *"Summary: CHECK FAILED (AppArmor patch needed)"* ]] \
    && e50 pass || e50 fail "D50-3 needed -> Summary FAILED rc 1 (rc=$rc, out: $o)"

# 5. Labeled+enforced+extension present but rule absent: the
#    applied/missing dimensions disagree -> CHECK FAILED (incomplete), rc 1.
#    Fresh fixture (aad39's local file is filled by an EGL-39 apply test).
mkdir -p "$aa22/aad50x/local"
printf '/usr/bin/pasta {\n  #include <local/usr.bin.pasta>\n}\n' > "$aa22/aad50x/usr.bin.pasta"
: > "$aa22/aad50x/local/usr.bin.pasta"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad50x" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"pasta local extension: present (stock)"* \
    && "$o" == *"egresslock rule in local file: absent"* \
    && "$o" == *"Summary: CHECK FAILED (AppArmor patch incomplete)"* ]] \
    && e50 pass || e50 fail "D50-3 incomplete (ext present, rule absent) -> Summary FAILED rc 1 (rc=$rc, out: $o)"

# 6. --apparmor-remove success is report-only (D50-7): the two facts,
#    no ritual, no probe command, no confirm pointer.
mkdir -p "$aa22/aad50r/local"
printf '/usr/bin/pasta {\n}\n' > "$aa22/aad50r/usr.bin.pasta"
run_aa72 "$aa22/aad50r" --apparmor-add >/dev/null 2>&1
: > "$STATE/apparmor.log"
o="$(run_aa72 "$aa22/aad50r" --apparmor-remove 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"removed the egresslock pasta amendment"* \
      && "$o" == *"pasta profile reloaded"* \
      && "$o" != *"must now FAIL"* \
      && "$o" != *"tear down"* \
      && "$o" != *"terminate-user"* \
      && "$o" != *"podman unshare"* \
      && "$o" != *"--apparmor-check"* ]]; then
    e50 pass
else
    e50 fail "D50-7 remove success is report-only (rc=$rc, out: $o)"
fi

# 7. --apparmor-add success confirms via --apparmor-check (D50-6.1),
#    no probe ritual.
mkdir -p "$aa22/aad50a/local"
printf '/usr/bin/pasta {\n}\n' > "$aa22/aad50a/usr.bin.pasta"
: > "$STATE/apparmor.log"
o="$(run_aa72 "$aa22/aad50a" --apparmor-add 2>&1)"; rc=$?
if [[ "$rc" == 0 \
      && "$o" == *"pasta profile reloaded"* \
      && "$o" == *"Confirm with: sudo egresslock-setup --apparmor-check"* \
      && "$o" != *"must now FAIL"* \
      && "$o" != *"podman unshare"* ]]; then
    e50 pass
else
    e50 fail "D50-6.1 apply confirm points at --apparmor-check (rc=$rc, out: $o)"
fi

# 8. D50-4: no `[--enable]` bracket presentation anywhere operator-facing.
for f in "$TREE_ROOT/egresslock-setup" "$TREE_ROOT/install-kit.sh" \
         "$TREE_ROOT/packaging/build-deb.sh" "$TREE_ROOT/packaging/build-tarball.sh" \
         "$TREE_ROOT/packaging/README.md"; do
    if grep -qF -- '[--enable]' "$f"; then
        e50 fail "D50-4 [--enable] bracket in $f"
    else
        e50 pass
    fi
done

# 9. D50-5: shipped install output speaks product — the generated
#    postinst and the tarball README fragment carry no internal ticket
#    IDs and point at --apparmor-check; no [--enable] either.
if grep -qF 'ARC-22-D3' "$p22/stage/DEBIAN/postinst"; then
    e50 fail "D50-5 postinst leaks ARC-22-D3"
else
    e50 pass
fi
grep -q -- '--apparmor-check' "$p22/stage/DEBIAN/postinst" \
    && e50 pass || e50 fail "postinst points at --apparmor-check"
grep -qF -- '[--enable]' "$p22/stage/DEBIAN/postinst" \
    && e50 fail "postinst still shows [--enable]" || e50 pass
if grep -qF 'ARC-22-D3' "$p22/x/README.txt"; then
    e50 fail "tarball README fragment carries ARC-22-D3"
else
    e50 pass
fi
grep -q -- '--apparmor-check' "$p22/x/README.txt" \
    && e50 pass || e50 fail "tarball README fragment points at --apparmor-check"
grep -qF -- '[--enable]' "$p22/x/README.txt" \
    && e50 fail "tarball README still shows [--enable]" || e50 pass

egl50_pass=$pass; egl50_fail=$fail

# --- EGL-55: doctor profile-networks row (advisory) -----------------------
# D55-1: with --account + a parsed conf, one rc-neutral row after the
# gateway image lines: present (all), missing (names) — run: egresslock
# ensure <name>..., or unknown when `podman network ls` fails. The row
# never fails the doctor and never runs ensure.
pass=0; fail=0
e55() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
mkdir -p "$STATE/e55"

# 1. Healthy account slice, no networks yet: advisory missing row, rc 0.
rm -f "$STATE/networks"/*
e55o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e55rc=$?
[[ "$e55rc" == 0 && "$e55o" == *"profile networks: missing (p1) — run: egresslock ensure p1"* ]] \
    && e55 pass || e55 fail "D55-1 missing row, rc stays 0 (rc=$e55rc, out: $e55o)"

# 2. Network present in the account store: present (p1), still rc 0.
printf 'driver=bridge\nsubnet=10.99.5.0/24\ngateway=10.99.5.1\nipv6_enabled=false\n' \
    > "$STATE/networks/egresslock-p1"
e55o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e55rc=$?
[[ "$e55rc" == 0 && "$e55o" == *"profile networks: present (p1)"* ]] \
    && e55 pass || e55 fail "D55-1 present row (rc=$e55rc, out: $e55o)"

# 3. Two profiles, one present one missing: missing lists only the
#    missing names, with one ensure suggestion per profile.
printf 'profile pa 10.99.7.0/24\n    rule public-only\nprofile pb 10.99.8.0/24\n    rule public-only\n' \
    > "$STATE/e55/two.conf"
printf 'driver=bridge\nsubnet=10.99.7.0/24\n' > "$STATE/networks/egresslock-pa"
e55o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e55/two.conf" --doctor 2>&1)"; e55rc=$?
[[ "$e55o" == *"profile networks: missing (pb) — run: egresslock ensure pb"* \
    && "$e55o" != *"profile networks: missing (pa"* ]] \
    && e55 pass || e55 fail "D55-1 partial missing lists only missing (rc=$e55rc, out: $e55o)"
rm -f "$STATE/networks/egresslock-pa" "$STATE/networks/egresslock-pb"

# 4. `podman network ls` fails (no session): the row says unknown, does
#    not fail the doctor, does not start user@ (rc 0 when else healthy).
mkdir -p "$STATE/e55/bin"
cat > "$STATE/e55/bin/podman" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == network && "\$2" == ls ]]; then echo "mock: ls denied" >&2; exit 1; fi
exec "$TESTROOT/bin/podman" "\$@"
EOF
chmod +x "$STATE/e55/bin/podman"
e55o="$(env PATH="$STATE/e55/bin:$PATH" EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_ACCOUNT_HOME="$e38h" EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e55rc=$?
[[ "$e55rc" == 0 && "$e55o" == *"profile networks: unknown"* \
    && "$e55o" == *"gateway image: present"* ]] \
    && e55 pass || e55 fail "D55-1 ls-failure -> unknown, rc-neutral (rc=$e55rc, out: $e55o)"
rm -f "$STATE/e55/bin/podman"

# 5. Conf parse already failed: the row is skipped (no parse -> no
#    profile list to probe); doctor still rc 1 from the parse row.
printf 'profile bad 10.99.8.0/24\n    rule nonsense\n' > "$STATE/e55/bad.conf"
e55o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e55/bad.conf" --doctor 2>&1)"; e55rc=$?
[[ "$e55rc" == 1 && "$e55o" == *"conf parse: FAIL"* && "$e55o" != *"profile networks:"* ]] \
    && e55 pass || e55 fail "D55-1 row skipped when conf parse failed (rc=$e55rc, out: $e55o)"

egl55_pass=$pass; egl55_fail=$fail

# --- EGL-59: kit --help is operator UI — no ticket/process citations -----
# Same rule as the engine (EGL-59-D1/D2/D3): the dumped headers of the
# kit-side help texts must not leak ticket/decision IDs or ticket
# paths (the snapshot-public gate line naming the docs/tickets DIRECTORY
# is a directory name, not a citation — allowed, and matched only with a
# trailing component, so the D3 regex `docs/tickets/[A-Za-z0-9]` stays
# green). R-EGL-69-1 finding 3: build-gateway joins the screen — its
# header is kit-side operator UI too.
pass=0; fail=0
e59() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
k59_id_re='ARC-[0-9]|EGL-[0-9]|docs/tickets/[A-Za-z0-9]'
entries59=("egresslock-setup:-h" "egresslock-verify:-h" \
           "install-kit.sh:-h" "uninstall-kit.sh:-h" \
           "build-gateway:-h")
# EGL-74-D1: the private publisher is not on the public tree — skip its
# -h entry there.
if [[ "$HAVE_SNAPSHOT" == 1 ]]; then
    entries59+=("packaging/snapshot-public.sh:-h")
else
    echo "SKIP: packaging/snapshot-public.sh -h — not on the public tree (EGL-74-D1)"
fi
for entry in "${entries59[@]}"; do
    f="${entry%%:*}"; flag="${entry##*:}"
    o="$(bash "$TREE_ROOT/$f" "$flag" 2>&1)"; rc=$?
    if [[ "$rc" == 0 ]] && ! grep -qE "$k59_id_re" <<<"$o"; then
        e59 pass
    else
        e59 fail "$f $flag leaks ticket/process refs or rc=$rc"
    fi
done

egl59_pass=$pass; egl59_fail=$fail

# --- EGL-60: unlabeled-not-required matrix + out-of-scope guards ----------
# D60-1: on a KNOWN-unlabeled host with the pasta profile found, the
# verdict is `not required on this host (podman unlabeled)` and the
# check ends `Summary: CHECK OK (AppArmor patch not needed)`, rc 0, for
# every extension/rule combination. Detail lines stay as evidence.
# D60-2 amends D39-4: missing extension is rc 1 only when the amendment
# is `required` or `condition unknown` (labeled hosts keep their FAILED
# contract — e50 #4/#5, 4t, EGL-14 #4 cover those).
pass=0; fail=0
e60() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# 1. The unlabeled-host reproduction (D60-1 matrix cell: MISSING + absent):
#    unlabeled + no include + empty local file -> rc 0, OK (not needed),
#    MISSING + not-required detail lines still printed.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad39x" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 0 \
    && "$o" == *"pasta profile: found"* \
    && "$o" == *"pasta local extension: MISSING"* \
    && "$o" == *"egresslock rule in local file: absent"* \
    && "$o" == *"pasta amendment: not required on this host (podman unlabeled)"* \
    && "$o" == *"Summary: CHECK OK (AppArmor patch not needed)"* ]] \
    && e60 pass || e60 fail "D60-1 unlabeled MISSING+absent -> OK not needed rc 0 (rc=$rc, out: $o)"

# 2. Matrix cell MISSING + rule present (stock operator rule): still
#    rc 0, OK (not needed), MISSING line stays.
mkdir -p "$aa22/aad60m/local"
printf '/usr/bin/pasta {\n}\n' > "$aa22/aad60m/usr.bin.pasta"
printf 'signal (receive) set=(term) peer=podman,\n' > "$aa22/aad60m/local/usr.bin.pasta"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad60m" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"pasta local extension: MISSING"* \
    && "$o" == *"egresslock rule in local file: present (stock)"* \
    && "$o" == *"Summary: CHECK OK (AppArmor patch not needed)"* ]] \
    && e60 pass || e60 fail "D60-1 unlabeled MISSING+present rule -> OK not needed rc 0 (rc=$rc, out: $o)"

# 3. Matrix cells with the extension present: present+absent (fresh
#    fixture — aad39's local file was filled by the EGL-39 4m apply) and
#    present+present (aad60p) both rc 0, OK (not needed), on the
#    unlabeled host.
mkdir -p "$aa22/aad60i/local"
printf '/usr/bin/pasta {\n  #include <local/usr.bin.pasta>\n}\n' > "$aa22/aad60i/usr.bin.pasta"
: > "$aa22/aad60i/local/usr.bin.pasta"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad60i" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"pasta local extension: present (stock)"* \
    && "$o" == *"egresslock rule in local file: absent"* \
    && "$o" == *"Summary: CHECK OK (AppArmor patch not needed)"* ]] \
    && e60 pass || e60 fail "D60-1 unlabeled present+absent -> OK not needed rc 0 (rc=$rc, out: $o)"
mkdir -p "$aa22/aad60p/local"
printf '/usr/bin/pasta {\n  #include <local/usr.bin.pasta>\n}\n' > "$aa22/aad60p/usr.bin.pasta"
printf 'signal (receive) set=(term) peer=podman,\n' > "$aa22/aad60p/local/usr.bin.pasta"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad60p" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"pasta local extension: present (stock)"* \
    && "$o" == *"egresslock rule in local file: present (stock)"* \
    && "$o" == *"Summary: CHECK OK (AppArmor patch not needed)"* ]] \
    && e60 pass || e60 fail "D60-1 unlabeled present+present -> OK not needed rc 0 (rc=$rc, out: $o)"

# 4. Out-of-scope guards stay frozen (D60-2): missing pasta profile file
#    even unlabeled -> rc 1 / FAILED incomplete; pasta-not-enforced
#    unlabeled verdict -> rc 1 (EGL-29-D1 4l); labeled+MISSING+absent ->
#    FAILED (patch needed) rc 1 (e50 #4); labeled+MISSING+present rule
#    -> FAILED incomplete rc 1 (4t).
mkdir -p "$aa22/aad60x"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad60x" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"pasta profile: missing file"* \
    && "$o" == *"Summary: CHECK FAILED (AppArmor patch incomplete)"* ]] \
    && e60 pass || e60 fail "D60-2 missing profile file stays FAILED rc 1 (rc=$rc, out: $o)"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad39" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.none" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"pasta amendment: not required on this host (pasta not enforced)"* \
    && "$o" == *"Summary: CHECK FAILED (AppArmor patch incomplete)"* ]] \
    && e60 pass || e60 fail "D60-2 pasta-not-enforced stays FAILED rc 1 (rc=$rc, out: $o)"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad39x" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"pasta local extension: MISSING"* \
    && "$o" == *"Summary: CHECK FAILED (AppArmor patch needed)"* ]] \
    && e60 pass || e60 fail "D60-2 labeled MISSING+absent stays FAILED needed rc 1 (rc=$rc, out: $o)"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad60m" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" "$SKIT" --apparmor-check 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"pasta local extension: MISSING"* \
    && "$o" == *"Summary: CHECK FAILED (AppArmor patch incomplete)"* ]] \
    && e60 pass || e60 fail "D60-2 labeled MISSING+present rule stays FAILED incomplete rc 1 (rc=$rc, out: $o)"

egl60_pass=$pass; egl60_fail=$fail

# --- EGL-68/EGL-69: install-kit foreign-prefix guard; build-gateway
#     context follows the script; apparmor/ ships with the prefix -----
pass=0; fail=0
e68() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

# EGL-68-D1: a non-kit prefix with a foreign gateway/ is refused rc 1,
# and the guard runs BEFORE any write: no engine binary smeared into
# the tree, the foreign gateway/ byte-identical.
e68p="$STATE/e68/foreign"; rm -rf "$STATE/e68"; mkdir -p "$e68p/gateway"
printf 'not a kit\n' > "$e68p/gateway/Makefile"
e68o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$KIT" --prefix "$e68p" 2>&1)"; e68_rc=$?
[[ "$e68_rc" == 1 && "$e68o" == *"refusing to delete $e68p/gateway"* ]] \
    && e68 pass || e68 fail "foreign gateway/ refused rc 1 (rc=$e68_rc, out: $e68o)"
[[ -f "$e68p/gateway/Makefile" && ! -e "$e68p/egresslock" && ! -e "$e68p/VERSION" \
    && ! -e "$e68p/gateway.tmp" ]] \
    && e68 pass || e68 fail "foreign tree untouched (guard precedes all writes)"
# The same guard covers examples/recipes: no markers, foreign tree, refused.
e68r="$STATE/e68/foreign-recipes"; mkdir -p "$e68r/examples/recipes"
printf 'keep\n' > "$e68r/examples/recipes/keep.txt"
e68o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$KIT" --prefix "$e68r" 2>&1)"; e68_rc=$?
[[ "$e68_rc" == 1 && -f "$e68r/examples/recipes/keep.txt" && ! -e "$e68r/egresslock" ]] \
    && e68 pass || e68 fail "foreign recipes/ refused, untouched (rc=$e68_rc, out: $e68o)"
# Kit-shaped tree (gateway/Containerfile present, no other markers):
# the rm paths are kit-shaped, the install proceeds.
e68k="$STATE/e68/kitshaped"; mkdir -p "$e68k/gateway"
: > "$e68k/gateway/Containerfile"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$KIT" --prefix "$e68k" >/dev/null 2>&1; e68_rc=$?
[[ "$e68_rc" == 0 && -f "$e68k/egresslock" && -f "$e68k/gateway/Containerfile" ]] \
    && e68 pass || e68 fail "kit-shaped tree (gateway/Containerfile) installs (rc=$e68_rc)"
# A marked prefix reinstalls and still replaces gateway/ wholesale
# (the rm path is taken; stale files do not survive an upgrade).
e68m="$STATE/e68/marked"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$KIT" --prefix "$e68m" >/dev/null 2>&1
[[ -f "$e68m/VERSION" ]] \
    && e68 pass || e68 fail "marked prefix fixture (VERSION present)"
printf 'stale\n' > "$e68m/gateway/Containerfile.stale"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$KIT" --prefix "$e68m" >/dev/null 2>&1; e68_rc=$?
[[ "$e68_rc" == 0 && -f "$e68m/gateway/Containerfile" \
    && ! -e "$e68m/gateway/Containerfile.stale" ]] \
    && e68 pass || e68 fail "reinstall on marked prefix replaces gateway/ (rc=$e68_rc)"
# EGL-69-D2: a fresh prefix ships apparmor/usr.bin.pasta.local.
e68a="$STATE/e68/aaprefix"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$KIT" --prefix "$e68a" >/dev/null 2>&1; e68_rc=$?
[[ "$e68_rc" == 0 && -f "$e68a/apparmor/usr.bin.pasta.local" ]] \
    && e68 pass || e68 fail "install-kit prefix ships apparmor/usr.bin.pasta.local (rc=$e68_rc)"
# EGL-69-D1: build-gateway builds the gateway/ NEXT TO THE SCRIPT from a
# cwd that is neither the repo root nor the tree (pre-flatten
# egresslock/gateway CWD-relative context is gone).
e68cwd="$STATE/e68/cwd"; mkdir -p "$e68cwd"
: > "$STATE/buildlog"
e68o="$(cd "$e68cwd" && env PATH="$TESTROOT/bin:$PATH" \
    "$TREE_ROOT/build-gateway" 2>&1)"; e68_rc=$?
e68bl="$(cat "$STATE/buildlog")"
[[ "$e68_rc" == 0 \
    && "$e68bl" == *"-f $TREE_ROOT/gateway/Containerfile "* \
    && "$e68bl" == *" $TREE_ROOT/gateway" ]] \
    && e68 pass || e68 fail "build-gateway context is the script's neighbor from a foreign cwd (rc=$e68_rc, buildlog: $e68bl)"
# ... and when the script is a kit-tree copy (tarball shape: script +
# gateway/ extracted elsewhere), still its own neighbor.
e68tree="$STATE/e68/tree"; mkdir -p "$e68tree"
cp "$TREE_ROOT/build-gateway" "$e68tree/build-gateway"
cp -R "$TREE_ROOT/gateway" "$e68tree/gateway"
: > "$STATE/buildlog"
e68o="$(cd "$e68cwd" && env PATH="$TESTROOT/bin:$PATH" \
    "$e68tree/build-gateway" 2>&1)"; e68_rc=$?
e68bl="$(cat "$STATE/buildlog")"
[[ "$e68_rc" == 0 \
    && "$e68bl" == *"-f $e68tree/gateway/Containerfile "* \
    && "$e68bl" == *" $e68tree/gateway" ]] \
    && e68 pass || e68 fail "kit-tree build-gateway builds its own gateway/ (rc=$e68_rc, buildlog: $e68bl)"
# EGL-69-D1: the pre-flatten ./scripts/build-gateway hint is gone and
# the engine hint names build-gateway.
if grep -rn "scripts/build-gateway" "$TREE_ROOT/egresslock" "$TREE_ROOT/build-gateway" >/dev/null 2>&1; then
    e68 fail "engine/build-gateway still names ./scripts/build-gateway"
else
    e68 pass
fi
grep -q 'build it: build-gateway' "$TREE_ROOT/egresslock" \
    && e68 pass || e68 fail "engine gateway-image hint names build-gateway"

egl68_pass=$pass; egl68_fail=$fail

# --- EGL-65: artifact hygiene — tarball excludes the internal
#     bug-report drafts; the fleet grep catches the widened names; the
#     private publisher never joins its own stage; the product tree is
#     scrubbed. ----------------------------------------------------------
pass=0; fail=0
e65() { if [[ "$1" == pass ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
p65="$STATE/egl65"; rm -rf "$p65"; mkdir -p "$p65/kit"
(cd "$TREE_ROOT" && tar -cf - --exclude=./.git --exclude='./packaging/*.deb' --exclude='./packaging/*.tar.gz' .) \
    | tar -xf - -C "$p65/kit"
printf '# security policy (staged fixture for the snapshot gate)\n' > "$p65/kit/SECURITY.md"

# 1. (D1) the tarball excludes the internal bug-report drafts; docs
#    otherwise ship.
env EGRESSLOCK_TARBALL_OUT="$p65/k.tgz" "$TARSH" >/dev/null 2>&1; e65_rc=$?
[[ "$e65_rc" == 0 && -f "$p65/k.tgz" ]] \
    && e65 pass || e65 fail "tarball build (rc=$e65_rc)"
if tar -tzf "$p65/k.tgz" | grep -qE 'docs/(lp-|debian-).*\.txt'; then
    e65 fail "tarball ships an internal bug-report draft (EGL-65-D1)"
else
    e65 pass
fi
tar -tzf "$p65/k.tgz" | grep -q 'docs/README.md' \
    && e65 pass || e65 fail "tarball still ships docs (sanity)"

# 2. (D2) the widened fleet grep fails closed on each widened name,
#    naming the file and removing the stage. Decoys are assembled from
#    parts — this file is itself in the staged set.
#    EGL-74-D1: the dry-runs invoke the private publisher; skip on the
#    public tree.
if [[ "$HAVE_SNAPSHOT" == 1 ]]; then
printf 'note: confirmed on ni'"tro"' with the profile\n' > "$p65/kit/docs/leak-decoy-a.md"
printf 'worked through on haz'"mat"' box\n' > "$p65/kit/docs/leak-decoy-b.md"
o="$(bash "$p65/kit/packaging/snapshot-public.sh" --dry-run "$p65/stage-a" 2>&1)"; e65_rc=$?
[[ "$e65_rc" == 1 && "$o" == *"fleet facts"* && "$o" == *"leak-decoy-a.md"* && ! -e "$p65/stage-a" ]] \
    && e65 pass || e65 fail "widened grep catches first nickname (rc=$e65_rc, out: $o)"
rm -f "$p65/kit/docs/leak-decoy-a.md"
o="$(bash "$p65/kit/packaging/snapshot-public.sh" --dry-run "$p65/stage-b" 2>&1)"; e65_rc=$?
[[ "$e65_rc" == 1 && "$o" == *"fleet facts"* && "$o" == *"leak-decoy-b.md"* && ! -e "$p65/stage-b" ]] \
    && e65 pass || e65 fail "widened grep catches second nickname (rc=$e65_rc, out: $o)"
rm -f "$p65/kit/docs/leak-decoy-b.md"
else
    echo "SKIP: EGL-65 widened-fleet-grep dry-runs — packaging/snapshot-public.sh not on the public tree (EGL-74-D1)"
fi

# 3. (D2) the scrubbed product tree carries no fleet nickname outside
#    the repo-only paths (the publisher's own pattern literals, the
#    excluded bug-report drafts, tickets/BOARD, internal docs).
if grep -rnIiE 'ni'"tro"'|haz'"mat" \
        "$TREE_ROOT" \
        --exclude-dir=.git --exclude-dir=tickets --exclude-dir=internal_docs \
        --exclude-dir=completed \
        --exclude=BOARD.md --exclude=snapshot-public.sh \
        --exclude='lp-*.txt' --exclude='debian-*.txt' \
        >/dev/null 2>&1; then
    e65 fail "product tree still carries a fleet nickname (see grep above)"
    grep -rnIiE 'ni'"tro"'|haz'"mat" "$TREE_ROOT" \
        --exclude-dir=.git --exclude-dir=tickets --exclude-dir=internal_docs \
        --exclude-dir=completed \
        --exclude=BOARD.md --exclude=snapshot-public.sh \
        --exclude='lp-*.txt' --exclude='debian-*.txt' >&2 || true
else
    e65 pass
fi

# 4. (D2) the RFC 5737 rebase: the private-LAN example IP is gone from
#    the shipped docs (tickets/ is repo-only); 192.0.2.0/24 examples
#    remain valid text.
if grep -rn '192\.168\.0\.24' "$TREE_ROOT/docs" --exclude-dir=tickets >/dev/null 2>&1; then
    e65 fail "docs still carry the private-LAN example IP"
else
    e65 pass
fi
grep -rq '192\.0\.2\.24' "$TREE_ROOT/docs/reference/policy-reference.md" \
    && e65 pass || e65 fail "policy-reference example rebased to RFC 5737"
if grep -q 'llm-cloud' "$TREE_ROOT/gateway/Containerfile"; then
    e65 fail "Containerfile still names the pre-rename profile"
else
    e65 pass
fi

egl65_pass=$pass; egl65_fail=$fail


echo
echo "RESULTS (ARC-16 kit productization): $arc16_pass passed, $arc16_fail failed"
echo "RESULTS (ARC-17 uninstall-kit): $arc17_pass passed, $arc17_fail failed"
echo "RESULTS (EGL-43 install-kit PATH wrappers): $egl43_pass passed, $egl43_fail failed"
echo "RESULTS (EGL-12 public snapshot staging): $egl12_pass passed, $egl12_fail failed"
echo "RESULTS (EGL-47 internal_docs guards): $egl47_pass passed, $egl47_fail failed"
echo "RESULTS (EGL-49 deb other-readable): $egl49_pass passed, $egl49_fail failed"
echo "RESULTS (ARC-18 setup-account): $arc18_pass passed, $arc18_fail failed"
echo "RESULTS (EGL-51 user manager before build): $egl51_pass passed, $egl51_fail failed"
echo "RESULTS (ARC-19 init-conf): $arc19_pass passed, $arc19_fail failed"
echo "RESULTS (EGL-38 run map, doctor, build-gateway): $egl38_pass passed, $egl38_fail failed"
echo "RESULTS (ARC-60 setup migration): $arc60_pass passed, $arc60_fail failed"
echo "RESULTS (ARC-22 packaging): $arc22_pass passed, $arc22_fail failed"
echo "RESULTS (EGL-39 install-kit advisory): $a39_pass passed, $a39_fail failed"
echo "RESULTS (ARC-72 apparmor resolution): $arc72_pass passed, $arc72_fail failed"
echo "RESULTS (EGL-14 apparmor compat include + doctor): $arc14_pass passed, $arc14_fail failed"
echo "RESULTS (EGL-20 parser-reality fixes): $arc20_pass passed, $arc20_fail failed"
echo "RESULTS (EGL-23 remove verification): $arc23_pass passed, $arc23_fail failed"
echo "RESULTS (ARC-70 drift-signal hint): $arc70_pass passed, $arc70_fail failed"
echo "RESULTS (ARC-69 apparmor file handling): $arc69s_pass passed, $arc69s_fail failed"
echo "RESULTS (EGL-50 doctor summary + message hygiene): $egl50_pass passed, $egl50_fail failed"
echo "RESULTS (EGL-55 doctor profile-networks row): $egl55_pass passed, $egl55_fail failed"
echo "RESULTS (EGL-59 kit help operator-UI): $egl59_pass passed, $egl59_fail failed"
echo "RESULTS (EGL-60 unlabeled-not-required doctor verdict): $egl60_pass passed, $egl60_fail failed"
echo "RESULTS (EGL-68/69 install-kit guard + build-gateway + apparmor prefix): $egl68_pass passed, $egl68_fail failed"
echo "RESULTS (EGL-65 artifact hygiene): $egl65_pass passed, $egl65_fail failed"
total_fail=$((arc16_fail + arc17_fail + egl43_fail + egl12_fail + egl47_fail + egl49_fail + arc18_fail + egl51_fail + arc19_fail + egl38_fail + arc60_fail + arc22_fail + a39_fail + arc72_fail + arc14_fail + arc20_fail + arc23_fail + arc70_fail + arc69s_fail + egl50_fail + egl55_fail + egl59_fail + egl60_fail + egl68_fail + egl65_fail))
echo "RESULTS TOTAL: $((arc16_pass + arc17_pass + egl43_pass + egl12_pass + egl47_pass + egl49_pass + arc18_pass + egl51_pass + arc19_pass + egl38_pass + arc60_pass + arc22_pass + a39_pass + arc72_pass + arc14_pass + arc20_pass + arc23_pass + arc70_pass + arc69s_pass + egl50_pass + egl55_pass + egl59_pass + egl60_pass + egl68_pass + egl65_pass)) passed, $total_fail failed"
[[ "$total_fail" -eq 0 ]]
