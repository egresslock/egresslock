#!/usr/bin/env bash
#
# Kit productization tests for egresslock (ARC-74-D2): the kit blocks moved
# out of the site consumer harness. Covers install-kit (ARC-16, kit-only
# asserts), uninstall-kit (ARC-17), setup-account (ARC-18), --init-conf
# (ARC-19), packaging (ARC-22), AppArmor work (ARC-22-D3 / ARC-66 / ARC-69
# / ARC-72) and the drift-signal hint (ARC-70). Fixtures are synthetic
# (example.test hosts, docs-range IPs, throwaway prefixes) so the tree
# relocates to the public repo (ARC-13-D5); nothing references the site
# tree or its conf.
#
# Consumer-bound actuals that exec the site's agent-run / agent wrapper or
# forgejo-runner's copy_files.sh stay with their consumers (ARC-74-D7).
#
# Run:  bash tests/test-kit.sh   (or tests/run.sh)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Synthetic conf for the kit's engine-side exercises (neutral hosts).
# EGL-325: there is no runtime conf selector. The account confdir is fixed
# at <passwd-home>/.config/egresslock and the file basename must match the
# profile it defines, so the fixture lives there as local-dev.conf.
export ARCMOCK_DNS_BASE="git.example.test=192.0.2.10,cache.example.test=192.0.2.11"
mkdir -p "$HOME/.config/egresslock"
KITCONF="$HOME/.config/egresslock/local-dev.conf"
cat > "$KITCONF" <<'EOF'
profile local-dev 10.50.0.0/24
    rule allow-host ${FORGEJO_HOST:-git.example.test}:443
    rule allow-host ${FORGEJO_HOST:-git.example.test}:2222
    rule allow-host ${OLLAMA_HOST:-cache.example.test}:11434
EOF
export PATH="$TESTROOT/bin:$TREE_ROOT:$PATH"

# The mock state mirrors the fixture assumptions the moved kit blocks
# relied on (gateway image marker, IPAM dir).
mkdir -p "$STATE/images" "$STATE/ips"
: > "$STATE/images/localhost_egresslock-gateway_latest"
# EGL-206-D2a: the alpine:latest anchor marker the kit's engine-side
# exercises inspect is already seeded by tests/lib.sh (the mock `podman
# run` never pulls) — do not re-seed here.

# --- ARC-16: kit productization ---
section_begin arc16 "ARC-16 kit productization"

a16() { assert "$@"; }
KIT="$TREE_ROOT/install-kit.sh"
OPT="$STATE/opt-kit"          # mock --prefix
UNITS="$STATE/units"          # mock unit dir
: > "$STATE/systemctl.log"

mkdir -p "$UNITS" "$OPT"

# 1. install-kit: non-root hook, kit files, unit templates, per-account
#    timer enable.
# Direct exec (no `bash` wrapper): catches a committed-non-executable
# installer — R-016-2 F5.
a16_x=1
[[ -x "$KIT" ]] || { a16_x=0; a16 fail "install-kit.sh is executable in git"; }
[[ -x "$TREE_ROOT/egresslock-verify" ]] || { a16_x=0; a16 fail "egresslock-verify is executable in git (F6)"; }
if (( a16_x )); then a16 pass; fi
i_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    EGRESSLOCK_PATH_BINDIR="$OPT/wbin" EGRESSLOCK_PATH_SBINDIR="$OPT/wsbin" \
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
# EGL-232: the shared example base image (egl-base) ships with the kit;
# EGL-240: the build helper ships executable beside it.
[[ -f "$OPT/examples/egl-base/Containerfile" && -f "$OPT/examples/egl-base/README.md" && -x "$OPT/examples/egl-base/build-egl-base" ]] \
    && a16 pass || a16 fail "egl-base build context deployed (EGL-232)"
[[ -f "$UNITS/egresslock-verify@.service" && -f "$UNITS/egresslock-verify@.timer" ]] \
    && a16 pass || a16 fail "instanced templates installed (D1)"
# EGL-103-D1: shipped unit text carries the generated-file notice and
# short comments — no internal ticket IDs ride along.
if grep -q "do not edit" "$UNITS/egresslock-verify@.service" \
   && grep -q "do not edit" "$UNITS/egresslock-verify@.timer"; then
    a16 pass
else
    a16 fail "installed unit files carry the generated-file notice (EGL-103)"
fi
if grep -qE 'EGL-|ARC-' "$UNITS/egresslock-verify@.service" \
                        "$UNITS/egresslock-verify@.timer"; then
    a16 fail "shipped unit text leaks ticket IDs (EGL-103)"
else
    a16 pass
fi
# ARC-18-D4: install-kit is kit-level; it must NOT enable any per-account
# timer (that is setup-account --enable, after unit.env exists).
grep -qE "enable --now egresslock-verify@" "$STATE/systemctl.log" \
    && a16 fail "install-kit enabled a timer (moved to setup-account)" \
    || a16 pass
v_out="$("$OPT/egresslock" --version 2>&1)"
grep -q "^commit: " <<<"$v_out" && a16 pass || a16 fail "--version prints kit stamp (D5): $v_out"
# ARC-18-D4: --account is no longer an install-kit argument.
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    EGRESSLOCK_PATH_BINDIR="$OPT/wbin" EGRESSLOCK_PATH_SBINDIR="$OPT/wsbin" \
    "$KIT" --prefix "$OPT" --account root >/dev/null 2>&1
[[ $? == 2 ]] && a16 pass || a16 fail "install-kit rejects --account (rc 2)"
# 2. Wrapper (D2 explicit-only, D4 resolution): deployed copy.
w_out="$(env -u EGRESSLOCK_PROFILE "$OPT/egresslock-start" daemon 2>&1)"; w_rc=$?
if [[ "$w_rc" == 1 && "$w_out" == *"EGRESSLOCK_PROFILE is required"* ]]; then
    a16 pass
else
    a16 fail "wrapper fails closed without EGRESSLOCK_PROFILE (rc=$w_rc, out: $w_out)"
fi
w_out="$(env EGRESSLOCK_PROFILE=local-dev "$OPT/egresslock-start" daemon 2>&1)"; w_rc=$?
[[ "$w_rc" == 1 && "$w_out" == *"RUNNER_BIN is required"* ]] \
    && a16 pass || a16 fail "wrapper fails closed without RUNNER_BIN (rc=$w_rc, out: $w_out)"
w_out="$(env EGRESSLOCK_PROFILE=local-dev \
    RUNNER_BIN=echo "$OPT/egresslock-start" daemon -c /tmp/cfg 2>&1)"; w_rc=$?
if [[ "$w_rc" == 0 && "$w_out" == *"daemon -c /tmp/cfg"* ]]; then
    a16 pass
else
    a16 fail "wrapper ensure+exec with explicit env (rc=$w_rc, out: $w_out)"
fi
# D4: a broken EGRESSLOCK_DIR wins over the working script dir.
w_out="$(env EGRESSLOCK_DIR="$STATE/empty-dir" EGRESSLOCK_PROFILE=local-dev \
    RUNNER_BIN=echo "$OPT/egresslock-start" daemon 2>&1)"; w_rc=$?
[[ "$w_rc" == 1 && "$w_out" == *"$STATE/empty-dir/egresslock"* ]] \
    && a16 pass || a16 fail "wrapper honors EGRESSLOCK_DIR first (rc=$w_rc, out: $w_out)"

# 3. egresslock-verify (D3 hybrid), deployed copy.
# EGL-325: nothing but the engine is required. Sweep mode with no profile
# and nothing ensured is rc 0 with only the aggregate resolution line.
egresslock teardown local-dev >/dev/null 2>&1 || true
va_out="$(env -u EGRESSLOCK_PROFILE "$OPT/egresslock-verify" 2>&1)"; va_rc=$?
[[ "$va_rc" == 0 && "$va_out" == "using configs in $HOME/.config/egresslock (1 profiles)"* \
   && "$va_out" != *"verified (ensured)"* ]] \
    && a16 pass || a16 fail "egresslock-verify sweep with nothing ensured (rc=$va_rc, out: $va_out)"
# named mode: ensure local-dev first so verify has something to check.
egresslock ensure local-dev >/dev/null 2>&1
va_out="$(env EGRESSLOCK_PROFILE=local-dev "$OPT/egresslock-verify" 2>&1)"; va_rc=$?
[[ "$va_rc" == 0 && "$va_out" == *"policy verified"* ]] \
    && a16 pass || a16 fail "egresslock-verify named mode (rc=$va_rc, out: $va_out)"
# ensured mode (PROFILE unset): the sweep runs bare `verify --ensured`
# against the account's fixed confdir aggregate. The local-dev fixture
# already lives in that confdir, so the named-mode ensure above is the
# anchor the sweep must find.
# EGL-140-D1: the pin record is a sibling of the RESOLVED conf; re-ensure
# so the record is present beside the confdir conf the sweep resolves.
egresslock ensure local-dev >/dev/null 2>&1
va_out="$(env -u EGRESSLOCK_PROFILE "$OPT/egresslock-verify" 2>&1)"; va_rc=$?
[[ "$va_rc" == 0 && "$va_out" == *"verified (ensured)"* ]] \
    && a16 pass || a16 fail "egresslock-verify ensured mode (rc=$va_rc, out: $va_out)"
# tamper: drift in the ensured profile's chain must fail the timer entry.
sed -i '/dport 2222/d' "$STATE/nft/egresslock.p_local_dev"
va_out="$(env -u EGRESSLOCK_PROFILE "$OPT/egresslock-verify" 2>&1)"; va_rc=$?
[[ "$va_rc" == 1 ]] && a16 pass || a16 fail "egresslock-verify fails on drift (rc=$va_rc, out: $va_out)"
egresslock ensure local-dev >/dev/null 2>&1

section_end arc16

# --- EGL-85: verify wrapper's bounded-probe failure modes (deployed
# --- copy; the ARC-26 engine test covers the engine path) ---------------
# The netns preflight (EGL-78) has two uncovered branches: timeout(1)
# absent (fail closed) and probe expiry (named 5s failure). Both run
# BEFORE the engine exec, so chain state is untouched. D2: real 5s wait,
# far under the 600s harness bound (EGL-225).
section_begin egl85 "EGL-85 verify timeout paths"
a85() { assert "$@"; }

# 1. timeout(1) absent -> rc 1 + the coreutils message, before any
#    engine run. Isolated PATH (bin-doctor-none technique): only what
#    the wrapper needs before the probe gate, deliberately NO timeout.
ntk="$TESTROOT/bin-verify-notimeout"
rm -rf "$ntk"; mkdir -p "$ntk"
for t in env bash dirname id cat head; do ln -s "$(command -v "$t")" "$ntk/$t"; done
v_out="$(env -u EGRESSLOCK_PROFILE PATH="$ntk" \
    "$OPT/egresslock-verify" 2>&1)"; v_rc=$?
[[ "$v_rc" == 1 && "$v_out" == *"timeout(1) (coreutils) is required for the netns probe"* ]] \
    && a85 pass || a85 fail "verify without timeout(1) fails closed (rc=$v_rc, out: $v_out)"

# 2. probe expiry: podman shim sleeps 60s on the probe command only;
#    the wrapper must die with the named 5s-timeout message well under
#    the harness bound (and never fall through to the engine verify).
mkdir -p "$TESTROOT/bin-verify-hang"
cat > "$TESTROOT/bin-verify-hang/podman" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "unshare" && "\$2" == "--rootless-netns" && "\$3" == "true" ]]; then
    sleep 60
    exit 0
fi
exec "$TESTROOT/bin/podman" "\$@"
EOF
chmod +x "$TESTROOT/bin-verify-hang/podman"
v_start=$SECONDS
v_out="$(env -u EGRESSLOCK_PROFILE PATH="$TESTROOT/bin-verify-hang:$PATH" \
    "$OPT/egresslock-verify" 2>&1)"; v_rc=$?
v_elapsed=$(( SECONDS - v_start ))
[[ "$v_rc" == 1 && "$v_out" == *"netns probe timed out after 5s"* && "$v_elapsed" -lt 15 ]] \
    && a85 pass || a85 fail "verify probe expiry is a named 5s failure (rc=$v_rc, elapsed=${v_elapsed}s, out: $v_out)"

section_end egl85

# --- EGL-115: sweep-mode wrapper scoping (deployed copy) ----------------
# The timer's sweep must exec the BARE `verify --ensured`; the engine then
# default-probes the account's fixed confdir and aggregates every *.conf
# there (EGL-325 removed --config and EGRESSLOCK_CONF entirely). Named
# mode passes only the profile name. Neither mode may leak a selector
# into the engine child.
section_begin egl115 "EGL-115 sweep-mode wrapper scoping"
a115() { assert "$@"; }

# Recording engine: EGRESSLOCK_DIR wins the kit-dir resolution, so the
# wrapper execs this instead of the real engine and we can pin the
# exact argv + child env. Netns probe skipped (argv is the subject).
mk115="$STATE/mockkit115"; rm -rf "$mk115"; mkdir -p "$mk115"
cat > "$mk115/egresslock" <<EOF
#!/usr/bin/env bash
{
    printf 'argv:'
    for a in "\$@"; do printf ' <%s>' "\$a"; done
    printf '\n'
    printf 'conf-env:%s\n' "\${EGRESSLOCK_CONF:-<unset>}"
} >> "$mk115/record"
exit 0
EOF
chmod +x "$mk115/egresslock"

# 1. Sweep mode: PROFILE unset -> argv is exactly `verify --ensured` and
#    the child env carries no EGRESSLOCK_CONF (EGL-325: no conf wiring).
: > "$mk115/record"
v_out="$(env -u EGRESSLOCK_PROFILE EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_DIR="$mk115" \
    "$OPT/egresslock-verify" 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 \
      && "$(sed -n 1p "$mk115/record")" == "argv: <verify> <--ensured>" \
      && "$(sed -n 2p "$mk115/record")" == "conf-env:<unset>" ]]; then
    a115 pass
else
    a115 fail "sweep argv is bare --ensured with no conf env (rc=$v_rc, record: $(cat "$mk115/record"), out: $v_out)"
fi

# 2. Named mode: only the profile name reaches the engine child — no
#    --config and no EGRESSLOCK_CONF.
: > "$mk115/record"
v_out="$(env EGRESSLOCK_PROFILE=local-dev EGRESSLOCK_SKIP_NETNS_PROBE=1 \
    EGRESSLOCK_DIR="$mk115" \
    "$OPT/egresslock-verify" 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 \
      && "$(sed -n 1p "$mk115/record")" == "argv: <verify> <local-dev>" \
      && "$(sed -n 2p "$mk115/record")" == "conf-env:<unset>" ]]; then
    a115 pass
else
    a115 fail "named mode passes profile only, no selector (rc=$v_rc, record: $(cat "$mk115/record"), out: $v_out)"
fi

# 3. End-to-end aggregate: two *.conf in the fixed confdir, both anchors
#    ensured -> the sweep verifies BOTH profiles (and the engine's
#    aggregate disclosure names the confdir).
cat > "$HOME/.config/egresslock/second.conf" <<'EOF'
profile second 10.50.1.0/24
    rule allow-host git.example.test:443
EOF
egresslock ensure second >/dev/null 2>&1
# EGL-140-D1: re-ensure local-dev so its pin record is a sibling of the
# conf the sweep resolves (the tamper drill above expects a green sweep
# baseline for the tampered half only).
egresslock ensure local-dev >/dev/null 2>&1
v_out="$(env -u EGRESSLOCK_PROFILE \
    "$OPT/egresslock-verify" 2>&1)"; v_rc=$?
if [[ "$v_rc" == 0 \
      && "$v_out" == *"profile 'local-dev' verified (ensured)"* \
      && "$v_out" == *"profile 'second' verified (ensured)"* \
      && "$v_out" == *"using configs in"*"(2 profiles)"* ]]; then
    a115 pass
else
    a115 fail "sweep verifies every ensured profile in the confdir (rc=$v_rc, out: $v_out)"
fi

# Cleanup: restore the harness's fixed-confdir and profile state. The
# local-dev fixture (KITCONF) stays for the rest of the harness.
egresslock teardown second >/dev/null 2>&1 || true
rm -f "$HOME/.config/egresslock/second.conf" \
      "$HOME/.config/egresslock/local-dev.pins" "$HOME/.config/egresslock/second.pins"

section_end egl115

# --- ARC-17: uninstall-kit --------------------------------------------------
section_begin arc17 "ARC-17 uninstall-kit"
a17() { assert "$@"; }
UKIT="$TREE_ROOT/uninstall-kit.sh"

# Exec bit committed (R-016-2 F5 failure class: mode lost in git).
[[ -x "$UKIT" ]] && a17 pass || a17 fail "uninstall-kit.sh is executable in git"

# Pre-state: prefix kit + templates + timers + account data. EGL-89-D1:
# the prefix must be a REAL kit — the marker quadruple (egresslock
# executable, egresslock-verify, VERSION, gateway/Containerfile) —
# because a lone egresslock/VERSION pair no longer authorizes rm -rf.
u17="$STATE/u17"
mkdir -p "$u17/prefix/gateway" "$u17/units" "$u17/home/runner/.config/egresslock"
cp "$OPT/egresslock" "$u17/prefix/" 2>/dev/null \
    || { : > "$u17/prefix/egresslock"; chmod +x "$u17/prefix/egresslock"; }
: > "$u17/prefix/egresslock-verify"
: > "$u17/prefix/VERSION"
: > "$u17/prefix/gateway/Containerfile"
: > "$u17/units/egresslock-verify@.service"
: > "$u17/units/egresslock-verify@.timer"
: > "$u17/home/runner/.config/egresslock/unit.env"
: > "$STATE/systemctl.log"
# R-017-1 F5: a marker-less prefix must NOT be rm -rf'd.
mkdir -p "$u17/notakit"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u17/units" \
    EGRESSLOCK_PATH_BINDIR="$u17/wbin" EGRESSLOCK_PATH_SBINDIR="$u17/wbin" \
    "$UKIT" --prefix "$u17/notakit" --account root >/dev/null 2>&1
[[ -d "$u17/notakit" ]] && a17 pass || a17 fail "uninstall refuses a marker-less prefix"

# EGL-102-D6-R2: stage a dangling kit wants symlink (template gone) so
# the uninstall's sweep has something to clear. Staged after the F5
# refusal run — that run sweeps wants/ too and would consume it.
mkdir -p "$u17/units/timers.target.wants"
ln -s "$u17/units/egresslock-verify@ghost.timer" "$u17/units/timers.target.wants/egresslock-verify@ghost.timer"

u_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u17/units" \
    EGRESSLOCK_ACCOUNT_HOME="$u17/home/runner" \
    EGRESSLOCK_PATH_BINDIR="$u17/wbin" EGRESSLOCK_PATH_SBINDIR="$u17/wbin" \
    "$UKIT" --prefix "$u17/prefix" --account root 2>&1)"; u_rc=$?
[[ "$u_rc" == 0 ]] && a17 pass || a17 fail "uninstall-kit run (rc=$u_rc, out: $u_out)"
# EGL-102-D6-R2: a dangling kit wants symlink (template already gone,
# disable cannot clear it) is swept by the uninstall.
[[ ! -L "$u17/units/timers.target.wants/egresslock-verify@ghost.timer" \
    && "$u_out" == *"removed dangling timer enablement"* ]] \
    && a17 pass || a17 fail "dangling kit wants symlink swept (out: $u_out)"
[[ ! -e "$u17/units/egresslock-verify@.service" && ! -e "$u17/units/egresslock-verify@.timer" ]] \
    && a17 pass || a17 fail "templates removed"
[[ ! -e "$u17/prefix/egresslock" && ! -e "$u17/prefix/VERSION" ]] \
    && a17 pass || a17 fail "prefix kit removed"
[[ ! -d "$u17/prefix" ]] && a17 pass || a17 fail "prefix dir removed"
grep -q "disable --now egresslock-verify@root.timer" "$STATE/systemctl.log" \
    && a17 pass || a17 fail "per-account timer stopped/disabled"
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

# --purge-account-data removes the confdir. EGL-140-D1:
# the pin record rides the confdir — a fixture <profile>.pins is kept by
# the default keep path and removed by the purge, never orphaned.
mkdir -p "$u17/home/runner/.config/egresslock"
: > "$u17/home/runner/.config/egresslock/unit.env"
: > "$u17/home/runner/.config/egresslock/main.pins"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u17/units" \
    EGRESSLOCK_ACCOUNT_HOME="$u17/home/runner" \
    EGRESSLOCK_PATH_BINDIR="$u17/wbin" EGRESSLOCK_PATH_SBINDIR="$u17/wbin" \
    "$UKIT" --prefix "$u17/prefix" --account root --purge-account-data >/dev/null 2>&1
[[ ! -e "$u17/home/runner/.config/egresslock" ]] \
    && a17 pass || a17 fail "--purge-account-data removes the confdir"

# EGL-140-D1: the default (no --purge) keep path keeps the pin record
# WITH the confdir (account data, no root-side orphans).
mkdir -p "$u17/home/runner/.config/egresslock"
: > "$u17/home/runner/.config/egresslock/unit.env"
: > "$u17/home/runner/.config/egresslock/main.pins"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u17/units" \
    EGRESSLOCK_ACCOUNT_HOME="$u17/home/runner" \
    EGRESSLOCK_PATH_BINDIR="$u17/wbin" EGRESSLOCK_PATH_SBINDIR="$u17/wbin" \
    "$UKIT" --prefix "$u17/prefix" --account root >/dev/null 2>&1
[[ -f "$u17/home/runner/.config/egresslock/main.pins" ]] \
    && a17 pass || a17 fail "uninstall-kit default keeps the pin record with the confdir (EGL-140-D1)"

# Unknown account fails closed; missing value is a usage error (exit 2).
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u17/units" \
    EGRESSLOCK_PATH_BINDIR="$u17/wbin" EGRESSLOCK_PATH_SBINDIR="$u17/wbin" \
    "$UKIT" --prefix "$u17/prefix" --account nosuch-user >/dev/null 2>&1
[[ $? == 1 ]] && a17 pass || a17 fail "uninstall-kit fails on unknown account"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 "$UKIT" --account >/dev/null 2>&1
[[ $? == 2 ]] && a17 pass || a17 fail "missing --account value exits 2"

# --- EGL-89-D2: rm -rf guard hardening (audit I-01) ---
# e89run: uninstall-kit with the mock env, capturing rc + output.
e89run() {
    env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u17/units" \
        EGRESSLOCK_ACCOUNT_HOME="$u17/home/runner" \
        EGRESSLOCK_PATH_BINDIR="$u17/wbin" EGRESSLOCK_PATH_SBINDIR="$u17/wbin" \
        "$UKIT" --prefix "$1" --account root 2>&1
}
# 1. Victim dir with only VERSION + a precious file -> NOT removed, and
#    the closing line must not claim "kit removed from" (honest summary).
mkdir -p "$u17/victim-ver"
: > "$u17/victim-ver/VERSION"
echo precious > "$u17/victim-ver/important.txt"
e89_out="$(e89run "$u17/victim-ver")"; e89_rc=$?
[[ "$e89_rc" == 0 && -d "$u17/victim-ver" && -f "$u17/victim-ver/important.txt" \
    && "$e89_out" == *"not a real kit prefix"* \
    && "$e89_out" == *"left in place"* && "$e89_out" != *"kit removed from"* ]] \
    && a17 pass || a17 fail "VERSION-only victim kept (rc=$e89_rc, out: $e89_out)"
# 2. Checkout-shape victim: an egresslock file only -> NOT removed.
mkdir -p "$u17/victim-co"
: > "$u17/victim-co/egresslock"
e89_out="$(e89run "$u17/victim-co")"; e89_rc=$?
[[ "$e89_rc" == 0 && -d "$u17/victim-co" && "$e89_out" == *"not a real kit prefix"* ]] \
    && a17 pass || a17 fail "checkout-shape victim kept (rc=$e89_rc, out: $e89_out)"
# 3. Non-absolute / traversal --prefix -> rc 2, nothing deleted.
e89_sentinel="$u17/victim-ver/important.txt"
for e89_p in . .. not/absolute "$u17/prefix/../victim-ver" "$u17//victim-ver"; do
    e89_out="$(e89run "$e89_p")"; e89_rc=$?
    if [[ "$e89_rc" == 2 && "$e89_out" == *"must be an absolute kit path"* \
          && -f "$e89_sentinel" && -f "$TREE_ROOT/uninstall-kit.sh" ]]; then
        a17 pass
    else
        a17 fail "bad --prefix '$e89_p' rejected rc 2 (rc=$e89_rc, out: $e89_out)"
    fi
done
# 4. Charset-illegal absolute --prefix -> rc 2.
e89_out="$(e89run "$u17/eg;id")"; e89_rc=$?
[[ "$e89_rc" == 2 && "$e89_out" == *"must be an absolute kit path"* ]] \
    && a17 pass || a17 fail "charset-illegal --prefix rejected rc 2 (rc=$e89_rc, out: $e89_out)"
# 4b. EGL-185: whitespace-class --prefix rejects (parity with e90's
#     '/tmp/a b' pin; the newline case hits the explicit branch at
#     uninstall-kit.sh's whitespace-class branch, which had zero coverage).
#     Both internal branches exit 2 with the same message, so the
#     branch that fired is not pinned — only the rc/behavior class.
e89_out="$(e89run '/tmp/a b')"; e89_rc=$?
[[ "$e89_rc" == 2 && "$e89_out" == *"must be an absolute kit path"* \
    && -f "$e89_sentinel" && -f "$TREE_ROOT/uninstall-kit.sh" ]] \
    && a17 pass || a17 fail "space --prefix rejected rc 2 (rc=$e89_rc)"
e89_out="$(e89run $'/tmp/a\tb')"; e89_rc=$?
[[ "$e89_rc" == 2 && "$e89_out" == *"must be an absolute kit path"* \
    && -f "$e89_sentinel" && -f "$TREE_ROOT/uninstall-kit.sh" ]] \
    && a17 pass || a17 fail "tab --prefix rejected rc 2 (rc=$e89_rc)"
e89_out="$(e89run $'/tmp/a\nb')"; e89_rc=$?
[[ "$e89_rc" == 2 && "$e89_out" == *"must be an absolute kit path"* \
    && -f "$e89_sentinel" && -f "$TREE_ROOT/uninstall-kit.sh" ]] \
    && a17 pass || a17 fail "newline --prefix rejected rc 2 (rc=$e89_rc)"
# 5. Positive path: a real kit (the quadruple) IS still removed — the
#    full run above already asserts it; re-check the quadruple guard
#    explicitly with a throwaway fake kit.
mkdir -p "$u17/fakekit/gateway"
: > "$u17/fakekit/egresslock"; chmod +x "$u17/fakekit/egresslock"
: > "$u17/fakekit/egresslock-verify"; : > "$u17/fakekit/VERSION"
: > "$u17/fakekit/gateway/Containerfile"
e89_out="$(e89run "$u17/fakekit")"; e89_rc=$?
[[ "$e89_rc" == 0 && ! -e "$u17/fakekit" ]] \
    && a17 pass || a17 fail "real-kit quadruple still removed (rc=$e89_rc, out: $e89_out)"
section_end arc17

# --- EGL-43: install-kit PATH wrappers (D1–D4) ------------------------------
section_begin egl43 "EGL-43 install-kit PATH wrappers"
a43() { assert "$@"; }
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
grep -qF "exec \"$p43/opt/egresslock\" \"\$@\"" "$p43/bin/egresslock" \
    && a43 pass || a43 fail "engine wrapper execs the prefix copy, quoted (D1, EGL-90-D1.2)"
grep -qF "exec \"$p43/opt/egresslock-setup\" \"\$@\"" "$p43/sbin/egresslock-setup" \
    && a43 pass || a43 fail "setup wrapper execs the prefix copy, quoted (D2, EGL-90-D1.2)"

# 2. Same prefix re-run: upgrade overwrite, rc 0, marker still this prefix.
printf '#!/bin/sh\n# egresslock-path-wrapper prefix=%s\nexec stale "$@"\n' "$p43/opt" > "$p43/bin/egresslock"
o="$(a43_env "$p43/opt")"; rc=$?
[[ "$rc" == 0 ]] && grep -qF "exec \"$p43/opt/egresslock\" \"\$@\"" "$p43/bin/egresslock" \
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

# 5b. EGL-80-L2: the deb-shape guard is env-pinnable — a NON-wrapper
#     file at EGRESSLOCK_UB_BIN refuses rc 1. Hermetic coverage for the
#     guard that previously read the real /usr/bin/egresslock (present
#     on deployed hosts, where it made every install-kit run refuse).
mkdir -p "$p43/ub"
printf '#!/bin/sh\n# the deb engine, not a kit PATH wrapper\n' > "$p43/ub/egresslock"
chmod 0755 "$p43/ub/egresslock"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$p43/units" \
    EGRESSLOCK_PATH_BINDIR="$p43/bin" EGRESSLOCK_PATH_SBINDIR="$p43/sbin" \
    EGRESSLOCK_UB_BIN="$p43/ub/egresslock" \
    "$TREE_ROOT/install-kit.sh" --prefix "$p43/opt" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"exists and is not an egresslock kit PATH"* ]] \
    && a43 pass || a43 fail "deb-shape /usr/bin guard refused (rc=$rc, out: $o)"

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

section_end egl43
section_begin egl12 "EGL-12 public snapshot staging"   # begin before the EGL-74 skip branch — one window owns both paths (EGL-184-D2)

# --- EGL-12: public snapshot staging (allowlist copy, D1) -------------------
# The snapshot script and tests are BOTH on the allowlist, so this file must
# never contain a fleet fact literally — grep pattern and decoy are
# assembled from parts (fleet_grep discipline).
# EGL-74: the publisher and internal_docs/ are private-tree material; cases
# that invoke/grep them, or need internal_docs/, SKIP when absent
# (EGL-74-D1/D2). Guards needing neither keep running (D2).
SNAP_PUBLIC="$TREE_ROOT/packaging/snapshot-public.sh"
HAVE_SNAPSHOT=0; [[ -f "$SNAP_PUBLIC" ]] && HAVE_SNAPSHOT=1
HAVE_INTERNAL_DOCS=0; [[ -d "$TREE_ROOT/internal_docs" ]] && HAVE_INTERNAL_DOCS=1
# EGL-107-D1: third tree shape (extracted manual-install tarball) — the
# tarball excludes ./packaging by design (ARC-22-D4), so the two build
# scripts are absent there and every check that invokes, greps, or
# consumes their artifacts skips with a named cause instead of rc-127.
# Independent of HAVE_SNAPSHOT: the public snapshot tree SHIPS the build
# scripts (EGL-74-D2) and must keep running those checks.
HAVE_BUILD_DEB=0; [[ -f "$TREE_ROOT/packaging/build-deb.sh" ]] && HAVE_BUILD_DEB=1
HAVE_BUILD_TARBALL=0; [[ -f "$TREE_ROOT/packaging/build-tarball.sh" ]] && HAVE_BUILD_TARBALL=1
PKG_SKIP_TAG="packaging-build-scripts absent"

if [[ "$HAVE_SNAPSHOT" == 0 ]]; then
    skip "snapshot-public.sh absent" "EGL-12 public snapshot staging — packaging/snapshot-public.sh is not on the public tree (EGL-74-D1)"
else
a12k() { assert "$@"; }
p12="$STATE/egl12"; rm -rf "$p12"; mkdir -p "$p12/kit"
(cd "$TREE_ROOT" && tar -cf - --exclude=./.git --exclude='./packaging/*.deb' --exclude='./packaging/*.tar.gz' .) \
    | tar -xf - -C "$p12/kit"
printf '# security policy (staged fixture for the snapshot gate)\n' > "$p12/kit/SECURITY.md"
snap12="$p12/kit/packaging/snapshot-public.sh"
# EGL-104-D2: synthetic pattern. This stage-clean assertion is a
# re-assertion; the authoritative fail-closed fleet gate lives in
# packaging/snapshot-public.sh (never shipped, EGL-65-D3). The local copy
# uses synthetic literals of the same shapes (reserved TLD, docs-range
# hosts, neutral words) so the shipped test publishes no fleet facts. The
# dotted alternatives are escaped and word alternatives split, so this line
# never matches its own grep (the stage includes this file; expect rc 1).
pat12='kit-'"platform"'|example\.invalid|192\.0\.2\.250|192\.0\.2\.251|synthetic-'"org"'|sen'"try"'|haz'"less"

# 1. Dry-run with SECURITY.md staged: rc 0, allowlist copy, process
#    files excluded, fleet grep clean.
s12o="$(bash "$snap12" --dry-run "$p12/stage" 2>&1)"; s12rc=$?
[[ "$s12rc" == 0 && -f "$p12/stage/egresslock" && -x "$p12/stage/install-kit.sh" \
    && -f "$p12/stage/SECURITY.md" && -f "$p12/stage/LICENSE" \
    && -f "$p12/stage/VERSION_BASE" \
    && -f "$p12/stage/CHANGELOG.md" \
    && -f "$p12/stage/packaging/build-deb.sh" && -f "$p12/stage/packaging/build-tarball.sh" \
    && -f "$p12/stage/packaging/README.md" \
    && -f "$p12/stage/gateway/Containerfile" && -f "$p12/stage/tests/run.sh" \
    && -f "$p12/stage/systemd/egresslock-verify@.service" ]] \
    && a12k pass || a12k fail "snapshot dry-run stages the allowlist (rc=$s12rc, out: $s12o)"
# EGL-75: the snapshot procedure doc moved to internal_docs/ (maintainer
# material, EGL-47) — it must NOT appear in the stage.
[[ ! -e "$p12/stage/docs/setup/public-snapshot.md" && ! -e "$p12/stage/internal_docs" ]] \
    && a12k pass || a12k fail "snapshot stage excludes the now-internal procedure doc (EGL-75)"
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

fi
section_end egl12   # after the skip/else fi — both paths snapshot (EGL-184-D2)

# --- EGL-47: internal_docs never reaches a distribution path (D1–D3) --------
section_begin egl47 "EGL-47 internal_docs guards"
a47() { assert "$@"; }
p47="$STATE/egl47"; rm -rf "$p47"; mkdir -p "$p47/kit" "$p47/bin" "$p47/sbin" "$p47/units"
# The live checkout carries internal_docs/ (maintainer material) — copy
# the whole tree so every guard is exercised against the real hazard.
(cd "$TREE_ROOT" && tar -cf - --exclude=./.git .) | tar -xf - -C "$p47/kit"
if [[ "$HAVE_INTERNAL_DOCS" == 1 ]]; then
    [[ -e "$p47/kit/internal_docs" ]] \
        && a47 pass || a47 fail "fixture sanity: kit copy contains internal_docs"
else
    skip "internal_docs absent" "EGL-47 fixture sanity — internal_docs/ is not on the public tree (EGL-74-D1)"
fi

# 1. Snapshot --dry-run: internal_docs present at source, absent in stage.
if [[ "$HAVE_SNAPSHOT" == 1 && "$HAVE_INTERNAL_DOCS" == 1 ]]; then
printf '# security policy (staged fixture for the snapshot gate)\n' > "$p47/kit/SECURITY.md"
o="$(bash "$p47/kit/packaging/snapshot-public.sh" --dry-run "$p47/stage" 2>&1)"; rc=$?
[[ "$rc" == 0 && ! -e "$p47/stage/internal_docs" ]] \
    && a47 pass || a47 fail "snapshot stage has no internal_docs (rc=$rc, out: $o)"
else
    skip "internal_docs absent" "EGL-47 snapshot dry-run — publisher/internal_docs not on the public tree (EGL-74-D1)"
fi

# 2. Deb staging (KEEP_STAGE): no staged path contains internal_docs.
s47="$p47/debstage"
if [[ "$HAVE_BUILD_DEB" == 1 ]]; then
    o="$(env EGRESSLOCK_DEB_KEEP_STAGE="$s47" EGRESSLOCK_DEB_OUT="$p47/deb" \
        "$p47/kit/packaging/build-deb.sh" 2>&1)"; rc=$?
    [[ "$rc" == 0 ]] && ! find "$s47" -name 'internal_docs' | grep -q . \
        && a47 pass || a47 fail "deb stage has no internal_docs (rc=$rc, out: $o)"
else
    skip "$PKG_SKIP_TAG" "EGL-47 deb stage tripwire — packaging/build-deb.sh is not on this tree (extracted kit)"
fi

# 3. Prefix install (non-root hook): internal_docs absent from prefix.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$p47/units" \
    EGRESSLOCK_PATH_BINDIR="$p47/bin" EGRESSLOCK_PATH_SBINDIR="$p47/sbin" \
    "$p47/kit/install-kit.sh" --prefix "$p47/opt" 2>&1)"; rc=$?
[[ "$rc" == 0 && ! -e "$p47/opt/internal_docs" ]] \
    && a47 pass || a47 fail "prefix install has no internal_docs (rc=$rc, out: $o)"

# 4. Tarball: listing has no internal_docs path.
t47rc=0
if [[ "$HAVE_BUILD_TARBALL" == 1 ]]; then
    env EGRESSLOCK_TARBALL_OUT="$p47/k.tgz" "$p47/kit/packaging/build-tarball.sh" >"$p47/tlog" 2>&1 || t47rc=$?
    [[ "$t47rc" == 0 ]] && ! tar -tzf "$p47/k.tgz" | grep -q 'internal_docs' \
        && a47 pass || a47 fail "tarball listing has no internal_docs (rc=$t47rc, log: $(cat "$p47/tlog"))"
else
    skip "$PKG_SKIP_TAG" "EGL-47 tarball listing tripwire — packaging/build-tarball.sh is not on this tree (extracted kit)"
fi

# 5. The guards are explicit in the scripts (not layout accidents).
#    build-tarball.sh / build-deb.sh / install-kit.sh ship on the public
#    tree — those greps stay (EGL-74-D2); the publisher grep needs the
#    private script (EGL-74-D1).
if [[ "$HAVE_SNAPSHOT" == 1 ]]; then
grep -q 'internal_docs' "$TREE_ROOT/packaging/snapshot-public.sh" \
    && a47 pass || a47 fail "snapshot-public.sh names internal_docs (D1)"
else
    skip "snapshot-public.sh absent" "EGL-47 publisher grep — packaging/snapshot-public.sh not on the public tree (EGL-74-D1)"
fi
# EGL-107-D1: the build-script greps skip on the extracted kit (scripts
# absent there); the install-kit half always runs (shipped kit file).
if [[ "$HAVE_BUILD_TARBALL" == 1 ]]; then
grep -q -- '--exclude=./internal_docs' "$TREE_ROOT/packaging/build-tarball.sh" \
    && a47 pass || a47 fail "build-tarball.sh excludes internal_docs (D2)"
else
    skip "$PKG_SKIP_TAG" "EGL-47 build-tarball exclude grep — packaging/build-tarball.sh is not on this tree (extracted kit)"
fi
grep -q 'internal_docs' "$TREE_ROOT/install-kit.sh" \
    && a47 pass || a47 fail "prefix tripwire names internal_docs (D3)"
if [[ "$HAVE_BUILD_DEB" == 1 ]]; then
grep -q 'internal_docs' "$TREE_ROOT/packaging/build-deb.sh" \
    && a47 pass || a47 fail "deb tripwire names internal_docs (D3)"
else
    skip "$PKG_SKIP_TAG" "EGL-47 build-deb tripwire grep — packaging/build-deb.sh is not on this tree (extracted kit)"
fi

# 6. Tripwires fire: plant internal_docs into the tarball flow —
#    simulate a widened copy rule by removing the exclude from the kit
#    copy's own build-tarball.sh (it must stay in packaging/ so its
#    src resolution is unchanged) and re-run: guard must fail closed.
#    EGL-107-D1: needs BOTH the build script and the internal_docs
#    fixture; on the extracted kit the script absence is the reason.
if [[ "$HAVE_BUILD_TARBALL" == 0 ]]; then
    skip "$PKG_SKIP_TAG" "EGL-47 widened-tarball tripwire — packaging/build-tarball.sh is not on this tree (extracted kit)"
elif [[ "$HAVE_INTERNAL_DOCS" == 1 ]]; then
sed 's/--exclude=\.\/internal_docs//' "$p47/kit/packaging/build-tarball.sh" > "$p47/kit/packaging/build-tarball-widened.sh"
mv "$p47/kit/packaging/build-tarball-widened.sh" "$p47/kit/packaging/build-tarball.sh"
o="$(env EGRESSLOCK_TARBALL_OUT="$p47/k2.tgz" bash "$p47/kit/packaging/build-tarball.sh" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"internal_docs leaked"* ]] \
    && a47 pass || a47 fail "widened tarball copy trips the guard (rc=$rc, out: $o)"
else
    skip "internal_docs absent" "EGL-47 widened-tarball tripwire — internal_docs/ is not on the public tree (EGL-74-D1)"
fi

section_end egl47

# --- EGL-49: .deb other-readable for apt's _apt sandbox (D1) ----------------
section_begin egl49 "EGL-49 deb other-readable"
a49() { assert "$@"; }
if command -v dpkg-deb >/dev/null 2>&1 && [[ "$HAVE_BUILD_DEB" == 1 ]]; then
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
elif [[ "$HAVE_BUILD_DEB" == 0 ]]; then
    skip "$PKG_SKIP_TAG" "EGL-49 umask build assert — packaging/build-deb.sh is not on this tree (extracted kit)"
else
    skip "dpkg-deb absent" "EGL-49 dpkg-deb not available; skipping mode assert"
fi

section_end egl49
section_begin arc18 "ARC-18 setup-account"

# --- ARC-18: setup-account ---------------------------------------------------
a18() { assert "$@"; }
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
a18_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    $SKIT --prefix "$SKITP" --account cacct 2>&1)"; a18_rc=$?
[[ "$a18_rc" == 1 && "$a18_out" == *"no profile configs in"* \
    && "$a18_out" == *"--init-conf"* && "$a18_out" == *"import --account cacct --from"* ]] \
    && a18 pass || a18 fail "pathless init on an empty confdir → rc 1 naming both writers (rc=$a18_rc, out: $a18_out)"
$SKIT --prefix "$SKITP" -h 2>/dev/null | grep -q "one-command" \
    && a18 pass || a18 fail "-h prints the header (mawk-safe)"
# Preflight failures fail closed BEFORE writing anything. Hook mode so
# the run reaches the check (without it the root guard exits first and
# the assertion is vacuous — R-EGL-325-2 F3).
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/missing.conf" >/dev/null 2>&1
[[ $? == 1 && ! -e "$a18d/home/cacct/.config/egresslock/unit.env" ]] \
    && a18 pass || a18 fail "missing conf → rc 1, nothing written"
chmod 000 "$a18d/site.conf"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" >/dev/null 2>&1
[[ $? == 1 && ! -e "$a18d/home/cacct/.config/egresslock/unit.env" ]] \
    && a18 pass || a18 fail "unreadable conf → rc 1, nothing written"
chmod 644 "$a18d/site.conf"

# Happy path: named profile, gateway conf → unit.env + gateway build.
s_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:test \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" --profile p1 2>&1)"; s_rc=$?
[[ "$s_rc" == 0 ]] && a18 pass || a18 fail "setup-account run (rc=$s_rc, out: $s_out)"
# EGL-200 M1: the named tail ends on the next-step block (--profile wins).
[[ "$s_out" == *"next steps (as the account):"* \
    && "$s_out" == *"  sudo -iu cacct"* \
    && "$s_out" == *"  egresslock ensure p1"* \
    && "$s_out" == *"  egresslock verify p1"* \
    && "$s_out" == *"read more: egresslock-setup help"* ]] \
    && a18 pass || a18 fail "EGL-200 M1: next-step block names account + profile (out: $s_out)"
uenv="$a18d/home/cacct/.config/egresslock/unit.env"
[[ "$(grep -c . "$uenv")" == 1 ]] && a18 pass || a18 fail "unit.env has exactly 1 assignment"
grep -qx "EGRESSLOCK_PROFILE=p1" "$uenv" && a18 pass || a18 fail "named mode recorded"
[[ -f "$a18d/home/cacct/.config/egresslock/p1.conf" ]] \
    && a18 pass || a18 fail "--conf installed as <profile>.conf in the fixed confdir"
[[ "$(stat -c %a "$uenv")" == 600 ]] && a18 pass || a18 fail "unit.env is 0600"
grep -q "build -t localhost/egresslock-gateway:test" "$STATE/buildlog" \
    && a18 pass || a18 fail "gateway image built as the account (build-if-missing)"
# Idempotent re-run: wholesale overwrite, no duplicates.
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:test \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" --profile p1 >/dev/null 2>&1
[[ "$(grep -c . "$uenv")" == 1 ]] && a18 pass || a18 fail "re-run overwrites wholesale (no dup lines)"

# No gateway in conf → build skipped.
printf 'profile p2 10.99.1.0/24\n' > "$a18d/plain.conf"
builds_before="$(wc -l < "$STATE/buildlog")"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/plain.conf" >/dev/null 2>&1
[[ ! -s "$uenv" ]] \
    && a18 pass || a18 fail "pathless init rewrites unit.env without EGRESSLOCK_PROFILE (aggregate; D8)"
[[ -f "$a18d/home/cacct/.config/egresslock/p2.conf" ]] \
    && a18 pass || a18 fail "conf switch imports <profile>.conf"
[[ "$(wc -l < "$STATE/buildlog")" == "$builds_before" ]] \
    && a18 pass || a18 fail "no-gateway conf skips the image build"

# Conf that fails engine validation → rc 1, unit.env untouched, and the
# install really rolled back (hook mode so install/validation actually
# run — R-EGL-325-2 F3; without the hook the root guard exits first).
printf 'profile p3 10.99.2.0/24\n    rule bogus-directive\n' > "$a18d/bad.conf"
p3conf="$a18d/home/cacct/.config/egresslock/p3.conf"
rm -f "$p3conf"
bad_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    "$SKIT" --prefix "$SKITP" --account cacct --conf "$a18d/bad.conf" 2>&1)"; bad_rc=$?
if [[ "$bad_rc" == 1 && "$bad_out" == *"staged pair failed validation"* ]]; then
    a18 pass
else
    a18 fail "unparseable conf → rc 1 at import validation (rc=$bad_rc, out: $bad_out)"
fi
[[ ! -s "$uenv" ]] \
    && a18 pass || a18 fail "unparseable conf → unit.env unchanged"
[[ ! -e "$p3conf" ]] \
    && a18 pass || a18 fail "unparseable conf → no partial dest"
# A pre-existing different destination is never replaced (A1): import
# refuses before validation/copy; the prior bytes stay.
printf 'profile p3 10.99.77.0/24\n' > "$p3conf"; chmod 600 "$p3conf"
cp -p "$p3conf" "$a18d/p3.prior"
bad_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    "$SKIT" --prefix "$SKITP" --account cacct --conf "$a18d/bad.conf" 2>&1)"; bad_rc=$?
[[ "$bad_rc" == 1 && "$bad_out" == *"destination conf differs"* ]] \
    && a18 pass || a18 fail "differing prior dest refused (A1; rc=$bad_rc, out: $bad_out)"
cmp -s "$a18d/p3.prior" "$p3conf" \
    && a18 pass || a18 fail "differing prior dest untouched byte-identically"
rm -f "$p3conf" "$a18d/p3.prior"

# Profile name that contradicts the source conf (hook mode: the refusal
# must be the mismatch check, not the root guard).
bad_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    "$SKIT" --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" --profile nope 2>&1)"; bad_rc=$?
if [[ "$bad_rc" == 2 && "$bad_out" == *"does not match the source conf's profile 'p1'"* ]]; then
    a18 pass
else
    a18 fail "unknown --profile → rc 2 with the mismatch line (rc=$bad_rc, out: $bad_out)"
fi

# Prefix derivation (R-follow-up): no --prefix → read the deployed
# prefix from the installed unit template's ExecStart ($UNITS points at
# the a16-installed template for $OPT).
sd="$STATE/a18-derived"
rm -rf "$sd"; mkdir -p "$sd/home/dacct"
s_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$sd/home/dacct" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$SKIT" --account dacct --conf "$a18d/plain.conf" 2>&1)"; s_rc=$?
[[ "$s_rc" == 0 ]] && a18 pass || a18 fail "no --prefix derives from the installed template (rc=$s_rc, out: $s_out)"
[[ -f "$sd/home/dacct/.config/egresslock/p2.conf" ]] \
    && a18 pass || a18 fail "derived-prefix run installs <profile>.conf"
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
section_end arc18

# --- EGL-328: import pair writer; pathless init; doctor resolve -------------
section_begin egl328 "EGL-328 import pair writer + pathless init"
e328() { assert "$@"; }
e328d="$STATE/e328"
rm -rf "$e328d"; mkdir -p "$e328d/home"
printf 'profile ci 10.98.0.0/24\n    rule gateway-only\n    gateway 10.98.0.2 3128 ci-allowlist\n' \
    > "$e328d/site.conf"
printf '# ci allowlist\n+ .example.test\n' > "$e328d/ci-allowlist"
printf 'profile p2 10.98.1.0/24\n' > "$e328d/p2.conf"
printf 'profile abs 10.98.2.0/24\n    rule gateway-only\n    gateway 10.98.2.2 3128 %s/abs-allowlist\n' "$e328d" \
    > "$e328d/abs.conf"
printf '+ .abs.example.test\n' > "$e328d/abs-allowlist"
e328_run() { # <home> <setup args...>
    local h="$1"; shift
    env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$h" \
        EGRESSLOCK_UNIT_DIR="$UNITS" EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:latest \
        "$SKIT" "$@" --prefix "$SKITP"
}
e328_h="$e328d/home/u1"

# 1. import copies the pair; dest name comes from the source profile line
#    (source basename differs), mode 0600, no unit.env written.
o="$(e328_run "$e328_h" import --account u1 --from "$e328d/site.conf" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"installed conf $e328_h/.config/egresslock/ci.conf (profile 'ci')"* \
    && "$o" == *"installed allowlist $e328_h/.config/egresslock/ci-allowlist"* \
    && -f "$e328_h/.config/egresslock/ci.conf" \
    && -f "$e328_h/.config/egresslock/ci-allowlist" \
    && ! -e "$e328_h/.config/egresslock/unit.env" ]] \
    && e328 pass || e328 fail "import pair + dest-name from profile, no unit.env (rc=$rc, out: $o)"
cmp -s "$e328d/site.conf" "$e328_h/.config/egresslock/ci.conf" \
    && e328 pass || e328 fail "import conf byte-identical"
cmp -s "$e328d/ci-allowlist" "$e328_h/.config/egresslock/ci-allowlist" \
    && e328 pass || e328 fail "import allowlist byte-identical"
[[ "$(stat -c %a "$e328_h/.config/egresslock/ci.conf")" == 600 \
    && "$(stat -c %a "$e328_h/.config/egresslock/ci-allowlist")" == 600 ]] \
    && e328 pass || e328 fail "import halves are 0600"

# 2. Identical re-run = no-op rc 0 (same inode, no temp leftovers).
ci_conf="$e328_h/.config/egresslock/ci.conf"
ci_ino="$(stat -c %i "$ci_conf")"; ci_sum="$(sha256sum "$ci_conf" | cut -d' ' -f1)"
o="$(e328_run "$e328_h" import --account u1 --from "$e328d/site.conf" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"unchanged"* \
    && "$(stat -c %i "$ci_conf")" == "$ci_ino" \
    && "$(sha256sum "$ci_conf" | cut -d' ' -f1)" == "$ci_sum" \
    && -z "$(find "$e328_h/.config/egresslock" -maxdepth 1 -name '.import*' -print -quit)" ]] \
    && e328 pass || e328 fail "identical import is a no-op (rc=$rc, out: $o)"

# 3. A differing destination is refused without clobbering (A1).
printf 'profile ci 10.98.9.0/24\n' > "$e328d/site.conf"
printf 'this is the live allowlist\n' > "$e328_h/.config/egresslock/ci-allowlist"
cp -p "$ci_conf" "$e328d/ci.prior"
o="$(e328_run "$e328_h" import --account u1 --from "$e328d/site.conf" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"destination conf differs"* ]] \
    && e328 pass || e328 fail "differing conf refused rc 1 (rc=$rc, out: $o)"
cmp -s "$e328d/ci.prior" "$ci_conf" \
    && e328 pass || e328 fail "refused import leaves the dest conf byte-identical"

# 4. Missing source allowlist is A2: refuse before any dest write.
printf 'profile ci 10.98.0.0/24\n    rule gateway-only\n    gateway 10.98.0.2 3128 ci-allowlist\n' \
    > "$e328d/site.conf"
e328_h2="$e328d/home/u2"
mv "$e328d/ci-allowlist" "$e328d/ci-allowlist.away"
o="$(e328_run "$e328_h2" import --account u2 --from "$e328d/site.conf" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"allowlist not found"* \
    && ! -e "$e328_h2/.config/egresslock/ci.conf" \
    && ! -e "$e328_h2/.config/egresslock/unit.env" ]] \
    && e328 pass || e328 fail "missing allowlist refuses before dest write (rc=$rc, out: $o)"
mv "$e328d/ci-allowlist.away" "$e328d/ci-allowlist"

# 5. Torn destination: refused by default; --force replaces both halves
#    (never writes only the missing half). Restore the source first.
printf 'profile ci 10.98.0.0/24\n    rule gateway-only\n    gateway 10.98.0.2 3128 ci-allowlist\n' \
    > "$e328d/site.conf"
printf '# ci allowlist\n+ .example.test\n' > "$e328d/ci-allowlist"
e328_h3="$e328d/home/u3"
mkdir -p "$e328_h3/.config/egresslock"
cp "$e328d/site.conf" "$e328_h3/.config/egresslock/ci.conf"
o="$(e328_run "$e328_h3" import --account u3 --from "$e328d/site.conf" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"destination pair is torn"* \
    && ! -e "$e328_h3/.config/egresslock/ci-allowlist" ]] \
    && e328 pass || e328 fail "torn destination refused, no half written (rc=$rc, out: $o)"
o="$(e328_run "$e328_h3" import --account u3 --from "$e328d/site.conf" --force 2>&1)"; rc=$?
[[ "$rc" == 0 && -f "$e328_h3/.config/egresslock/ci-allowlist" \
    && -f "$e328_h3/.config/egresslock/ci.conf" ]] \
    && e328 pass || e328 fail "import --force replaces a torn pair (rc=$rc, out: $o)"

# 6. --force replaces a differing pair (allowlist and conf together).
printf 'profile ci 10.98.3.0/24\n    rule gateway-only\n    gateway 10.98.3.2 3128 ci-allowlist\n' \
    > "$e328d/site.conf"
printf '+ .forced.example.test\n' > "$e328d/ci-allowlist"
o="$(e328_run "$e328_h" import --account u1 --from "$e328d/site.conf" --force 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && e328 pass || e328 fail "import --force replaces a differing pair (rc=$rc, out: $o)"
cmp -s "$e328d/site.conf" "$ci_conf" \
    && cmp -s "$e328d/ci-allowlist" "$e328_h/.config/egresslock/ci-allowlist" \
    && e328 pass || e328 fail "--force installed both source halves byte-identically"

# 6b. Commit-failure restore: fail the install-half renames with an mv
#     shim. The prior pair must come back byte-identically and no staging
#     or backup directory may survive; an absent destination must not be
#     left with a torn half. F1/R-EGL-328-3.
rb_src="$e328d/rb.conf"
cat > "$rb_src" <<'EOF'
profile rbci 10.98.4.0/24
    rule gateway-only
    gateway 10.98.4.2 3128 rbci-allowlist
EOF
printf '+ .new.example.test\n' > "$e328d/rbci-allowlist"
rb_conf="$e328_h/.config/egresslock/rbci.conf"
rb_al="$e328_h/.config/egresslock/rbci-allowlist"
printf 'profile rbci 10.98.5.0/24\n' > "$rb_conf"
printf '# prior\n+ .prior.example.test\n' > "$rb_al"
rb_conf_sum="$(sha256sum "$rb_conf" | cut -d' ' -f1)"
rb_al_sum="$(sha256sum "$rb_al" | cut -d' ' -f1)"

real_mv="$(type -P mv)"
imp_shim="$e328d/mv-shim-import"
mkdir -p "$imp_shim"
cat > "$imp_shim/mv" <<EOF
#!/usr/bin/env bash
args=("\$@")
n=\${#args[@]}
src="\${args[n-2]:-}"
dst="\${args[n-1]:-}"
if [[ "\$src" == *"/.import."* && ( "\$dst" == */rbci.conf || "\$dst" == */rbci-allowlist ) ]]; then
    echo "mv-shim: refusing install-half rename" >&2
    exit 1
fi
exec "$real_mv" "\$@"
EOF
chmod +x "$imp_shim/mv"
o="$(PATH="$imp_shim:$PATH" e328_run "$e328_h" import --account u1 --from "$rb_src" --force 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"could not commit the pair; destination restored"* \
    && "$(sha256sum "$rb_conf" | cut -d' ' -f1)" == "$rb_conf_sum" \
    && "$(sha256sum "$rb_al" | cut -d' ' -f1)" == "$rb_al_sum" \
    && -z "$(find "$e328_h/.config/egresslock" -maxdepth 1 -name '.import*' -print -quit)" ]] \
    && e328 pass || e328 fail "failed commit restores the prior pair, no leftovers (rc=$rc, out: $o)"

conf_shim="$e328d/mv-shim-import-conf"
order_marker="$e328d/commit-order.marker"
mkdir -p "$conf_shim"
cat > "$conf_shim/mv" <<EOF
#!/usr/bin/env bash
args=("\$@")
n=\${#args[@]}
src="\${args[n-2]:-}"
dst="\${args[n-1]:-}"
if [[ "\$src" == *"/.import."* && "\$dst" == */rbci.conf ]]; then
    # F1/R-EGL-328-9: witness the commit order at the conf rename. The
    # allowlist must already be installed (byte-identical to the source)
    # or a conf-first commit would leave a live conf with no allowlist
    # after a crash in the window (A2).
    d="\${dst%/*}"
    if [[ -f "\$d/rbci-allowlist" ]] && cmp -s "\$d/rbci-allowlist" "$e328d/rbci-allowlist"; then
        printf 'allowlist-installed-before-conf\n' > "$order_marker"
    else
        printf 'allowlist-missing-or-differs-before-conf\n' > "$order_marker"
    fi
    echo "mv-shim: refusing conf rename" >&2
    exit 1
fi
exec "$real_mv" "\$@"
EOF
chmod +x "$conf_shim/mv"
o="$(PATH="$conf_shim:$PATH" e328_run "$e328_h" import --account u1 --from "$rb_src" --force 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"could not commit the pair; destination restored"* \
    && "$(sha256sum "$rb_conf" | cut -d' ' -f1)" == "$rb_conf_sum" \
    && "$(sha256sum "$rb_al" | cut -d' ' -f1)" == "$rb_al_sum" \
    && -z "$(find "$e328_h/.config/egresslock" -maxdepth 1 -name '.import*' -print -quit)" ]] \
    && e328 pass || e328 fail "conf-half failure removes the newly installed allowlist (rc=$rc, out: $o)"

rb_h2="$e328d/home/u13"
mkdir -p "$rb_h2"
o="$(PATH="$imp_shim:$PATH" e328_run "$rb_h2" import --account u13 --from "$rb_src" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"could not commit the pair; destination restored"* \
    && ! -e "$rb_h2/.config/egresslock/rbci.conf" \
    && ! -e "$rb_h2/.config/egresslock/rbci-allowlist" \
    && -z "$(find "$rb_h2/.config/egresslock" -maxdepth 1 -name '.import*' -print -quit)" ]] \
    && e328 pass || e328 fail "failed commit into an absent dest leaves no torn pair (rc=$rc, out: $o)"

# The absent-dest case above fails the allowlist rename, so it never
# reaches the new_al rollback. Exercise the same absent dest with the
# conf-only shim: the allowlist installs first, the conf rename fails,
# and the newly-installed allowlist must be removed. F1/R-EGL-328-5.
rb_h4="$e328d/home/u15"
mkdir -p "$rb_h4"
rm -f "$order_marker"
o="$(PATH="$conf_shim:$PATH" e328_run "$rb_h4" import --account u15 --from "$rb_src" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"could not commit the pair; destination restored"* \
    && ! -e "$rb_h4/.config/egresslock/rbci.conf" \
    && ! -e "$rb_h4/.config/egresslock/rbci-allowlist" \
    && -z "$(find "$rb_h4/.config/egresslock" -maxdepth 1 -name '.import*' -print -quit)" ]] \
    && e328 pass || e328 fail "failed conf rename into an absent dest removes the installed allowlist (rc=$rc, out: $o)"
# F1/R-EGL-328-9: the same run's shim also witnesses the commit order.
# The allowlist dest must exist, byte-identical to the source, when the
# conf rename is attempted; a conf-first commit leaves it absent there
# (the crash window would be conf-present/allowlist-missing, A2).
[[ "$(cat "$order_marker" 2>/dev/null)" == "allowlist-installed-before-conf" ]] \
    && e328 pass || e328 fail "commit installs the allowlist before the conf (marker: $(cat "$order_marker" 2>/dev/null || echo missing))"

# 6b-rev. Reverse torn destination (stray allowlist, no conf) is refused
#     before any dest write; the stray allowlist is untouched. F2/
#     R-EGL-328-9.
rb_h5="$e328d/home/u16"
mkdir -p "$rb_h5/.config/egresslock"
printf '# stray allowlist\n+ .stray.example.test\n' > "$rb_h5/.config/egresslock/rbci-allowlist"
cp -p "$rb_h5/.config/egresslock/rbci-allowlist" "$e328d/rbci-allowlist.prior"
o="$(e328_run "$rb_h5" import --account u16 --from "$rb_src" 2>&1)"; rc=$?
[[ "$rc" == 1 \
    && "$o" == *"destination pair is torn: missing $rb_h5/.config/egresslock/rbci.conf, present $rb_h5/.config/egresslock/rbci-allowlist"* \
    && ! -e "$rb_h5/.config/egresslock/rbci.conf" \
    && ! -e "$rb_h5/.config/egresslock/unit.env" ]] \
    && e328 pass || e328 fail "reverse torn destination refused, no conf written (rc=$rc, out: $o)"
cmp -s "$e328d/rbci-allowlist.prior" "$rb_h5/.config/egresslock/rbci-allowlist" \
    && e328 pass || e328 fail "reverse torn refusal leaves the stray allowlist untouched"

# 6c. init --init-conf rename-failure rollback: the starter allowlist is
#     created first, then the conf rename fails. The newly-created
#     allowlist must be removed (no torn starter pair) and no temp files
#     may survive. F1/R-EGL-328-3.
init_shim="$e328d/mv-shim-init"
mkdir -p "$init_shim"
cat > "$init_shim/mv" <<EOF
#!/usr/bin/env bash
args=("\$@")
n=\${#args[@]}
src="\${args[n-2]:-}"
dst="\${args[n-1]:-}"
if [[ "\$src" == *"/.main.conf.init."* && "\$dst" == */main.conf ]]; then
    echo "mv-shim: refusing starter conf rename" >&2
    exit 1
fi
exec "$real_mv" "\$@"
EOF
chmod +x "$init_shim/mv"
rb_h3="$e328d/home/u14"
mkdir -p "$rb_h3"
o="$(PATH="$init_shim:$PATH" e328_run "$rb_h3" init --account u14 --init-conf 2>&1)"; rc=$?
[[ "$rc" == 1 \
    && ! -e "$rb_h3/.config/egresslock/main.conf" \
    && ! -e "$rb_h3/.config/egresslock/main-allowlist" \
    && -z "$(find "$rb_h3/.config/egresslock" -maxdepth 1 \( -name '.main.conf.init.*' -o -name '.main-allowlist.init.*' \) -print -quit)" ]] \
    && e328 pass || e328 fail "failed init-conf rename rolls back the new allowlist (rc=$rc, out: $o)"

# 7. Import usage surface: --from required; no --conf/--profile/--init-conf.
o="$(e328_run "$e328_h2" import --account u2 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"import requires --from"* ]] \
    && e328 pass || e328 fail "import missing --from rc 2 (rc=$rc)"
o="$(e328_run "$e328_h2" import --account u2 --conf "$e328d/site.conf" 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"takes --from, not --conf"* ]] \
    && e328 pass || e328 fail "import --conf rc 2 (rc=$rc, out: $o)"
o="$(e328_run "$e328_h2" import --account u2 --from "$e328d/site.conf" --profile ci 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"--profile is an init flag"* ]] \
    && e328 pass || e328 fail "import --profile rc 2 (rc=$rc, out: $o)"
o="$(e328_run "$e328_h2" import --account u2 --from "$e328d/site.conf" --init-conf 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"belong to init"* ]] \
    && e328 pass || e328 fail "import --init-conf rc 2 (rc=$rc, out: $o)"
o="$(e328_run "$e328_h2" import --account u2 --from "$e328d/site.conf" --enable 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"belong to init"* ]] \
    && e328 pass || e328 fail "import --enable rc 2 (rc=$rc, out: $o)"

# 7b. --allowlist overrides the source sibling; the destination name is
#     still the gateway basename. Source bytes stay untouched.
printf '+ .override.example.test\n' > "$e328d/ci-override"
cp -p "$e328d/ci-allowlist" "$e328d/ci-allowlist.before-override"
o="$(e328_run "$e328_h2" import --account u2 --from "$e328d/site.conf" --allowlist "$e328d/ci-override" 2>&1)"; rc=$?
[[ "$rc" == 0 && -f "$e328_h2/.config/egresslock/ci-allowlist" \
    && "$(cat "$e328_h2/.config/egresslock/ci-allowlist")" == "+ .override.example.test" \
    && "$(cat "$e328d/ci-allowlist")" == "$(cat "$e328d/ci-allowlist.before-override")" ]] \
    && e328 pass || e328 fail "import --allowlist override installs the pair (rc=$rc, out: $o)"

# 7c. A gateway allowlist basename may not collide with the confdir
#     conf/unit.env namespace (it would overwrite a profile conf or the
#     wiring witness); reject before any dest write.
printf 'profile collide 10.98.6.0/24\n    rule gateway-only\n    gateway 10.98.6.2 3128 ci.conf\n' \
    > "$e328d/collide.conf"
rm -rf "$e328d/home/u12"
o="$(e328_run "$e328d/home/u12" import --account u12 --from "$e328d/collide.conf" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"collides with the confdir"* \
    && ! -e "$e328d/home/u12/.config/egresslock/collide.conf" \
    && ! -e "$e328d/home/u12/.config/egresslock/ci.conf" ]] \
    && e328 pass || e328 fail "allowlist/conf namespace collision refused (rc=$rc, out: $o)"

# 7d. --allowlist with a conf that has no gateway line is refused.
o="$(e328_run "$e328d/home/u12" import --account u12 --from "$e328d/p2.conf" --allowlist "$e328d/ci-override" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"no gateway line"* \
    && ! -e "$e328d/home/u12/.config/egresslock/p2.conf" ]] \
    && e328 pass || e328 fail "--allowlist without gateway refused (rc=$rc, out: $o)"

# 8. Absolute allowlist ref is left in the conf and not copied.
e328_h4="$e328d/home/u4"
o="$(e328_run "$e328_h4" import --account u4 --from "$e328d/abs.conf" 2>&1)"; rc=$?
[[ "$rc" == 0 && -f "$e328_h4/.config/egresslock/abs.conf" \
    && ! -e "$e328_h4/.config/egresslock/abs-allowlist" \
    && "$(cat "$e328_h4/.config/egresslock/abs.conf")" == "$(cat "$e328d/abs.conf")" ]] \
    && e328 pass || e328 fail "absolute allowlist left in place, not copied (rc=$rc, out: $o)"

# 9. --from already the destination: validate in place, no-op rc 0.
o="$(e328_run "$e328_h" import --account u1 --from "$ci_conf" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"source is the destination"* ]] \
    && e328 pass || e328 fail "import --from dest validates in place (rc=$rc, out: $o)"

# 10. init --from wires after import; no --profile = aggregate (D8).
e328_h5="$e328d/home/u5"
: > "$STATE/systemctl.log"; : > "$STATE/loginctl.log"
o="$(e328_run "$e328_h5" init --account u5 --from "$e328d/site.conf" --enable 2>&1)"; rc=$?
[[ "$rc" == 0 && -f "$e328_h5/.config/egresslock/ci.conf" \
    && -f "$e328_h5/.config/egresslock/unit.env" && ! -s "$e328_h5/.config/egresslock/unit.env" \
    && "$o" == *"the scheduled check will verify every profile"* ]] \
    && e328 pass || e328 fail "init --from imports then wires aggregate (rc=$rc, out: $o)"
grep -q "enable --now egresslock-verify@u5.timer" "$STATE/systemctl.log" \
    && e328 pass || e328 fail "init --from --enable arms the timer"

# 11. init --from --profile must match the source profile (rc 2, no writes).
e328_h6="$e328d/home/u6"
o="$(e328_run "$e328_h6" init --account u6 --from "$e328d/site.conf" --profile nope 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"does not match the source conf's profile 'ci'"* \
    && ! -e "$e328_h6/.config/egresslock/ci.conf" \
    && ! -e "$e328_h6/.config/egresslock/unit.env" ]] \
    && e328 pass || e328 fail "init --from --profile mismatch rc 2 before wiring (rc=$rc, out: $o)"

# 12. Named init: pathless re-arm preserves only an explicit --profile;
#     import itself never rewrites unit.env (A4).
e328_h7="$e328d/home/u7"
e328_run "$e328_h7" import --account u7 --from "$e328d/site.conf" >/dev/null 2>&1
e328_run "$e328_h7" init --account u7 --profile ci --enable >/dev/null 2>&1
[[ "$(cat "$e328_h7/.config/egresslock/unit.env")" == "EGRESSLOCK_PROFILE=ci" ]] \
    && e328 pass || e328 fail "init --profile ci writes named unit.env"
cp -p "$e328_h7/.config/egresslock/unit.env" "$e328d/u7.unit.env"
e328_run "$e328_h7" import --account u7 --from "$e328d/p2.conf" >/dev/null 2>&1
cmp -s "$e328d/u7.unit.env" "$e328_h7/.config/egresslock/unit.env" \
    && e328 pass || e328 fail "import of another profile leaves unit.env untouched (A4)"
e328_run "$e328_h7" init --account u7 --enable >/dev/null 2>&1
[[ ! -s "$e328_h7/.config/egresslock/unit.env" ]] \
    && e328 pass || e328 fail "pathless init without --profile clears named mode (D8)"

# 13. Doctor resolves unit.env (named) with no --conf; a missing named conf
#     fails rc 1 and the fix points at import --from.
e328_h8="$e328d/home/u8"
e328_run "$e328_h8" import --account u8 --from "$e328d/site.conf" >/dev/null 2>&1
: > "$STATE/systemctl.log"
e328_run "$e328_h8" init --account u8 --profile ci --enable >/dev/null 2>&1
grep -q "enable --now egresslock-verify@u8.timer" "$STATE/systemctl.log" \
    && e328 pass || e328 fail "pathless init --profile arms the timer without --from"
o="$(e328_run "$e328_h8" doctor --account u8 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"OK: conf parse: ok (profile 'ci'"* \
    && "$o" == *"OK: unit.env: matches"* && "$o" == *"(named mode: ci)"* ]] \
    && e328 pass || e328 fail "doctor resolves named unit.env without --conf (rc=$rc, out: $o)"
rm -f "$e328_h8/.config/egresslock/ci.conf"
o="$(e328_run "$e328_h8" doctor --account u8 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"PROBLEM: conf parse: FAIL (profile 'ci')"* \
    && "$o" == *"PROBLEM: unit.env: named profile 'ci' has no conf"* \
    && "$o" == *"import --account u8 --from"* && "$o" != *"OK: conf parse"* ]] \
    && e328 pass || e328 fail "doctor names missing named conf + import fix (rc=$rc, out: $o)"

# 14. Doctor on an empty confdir fails closed, naming both writers (never
#     inventing main.conf).
e328_h9="$e328d/home/u9"
mkdir -p "$e328_h9"
o="$(e328_run "$e328_h9" doctor --account u9 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"PROBLEM: conf parse: FAIL ($e328_h9/.config/egresslock)"* \
    && "$o" == *"init --account u9 --init-conf"* \
    && "$o" == *"import --account u9 --from"* ]] \
    && e328 pass || e328 fail "empty-confdir doctor names --init-conf/import --from (rc=$rc, out: $o)"

# 14b. A --conf hint selects the profile for inspection but is NOT a
#      named-mode request: doctor's pathless fix must not narrow the timer.
e328_h11="$e328d/home/u11"
e328_run "$e328_h11" import --account u11 --from "$e328d/site.conf" >/dev/null 2>&1
rm -f "$e328_h11/.config/egresslock/unit.env"
o="$(e328_run "$e328_h11" doctor --account u11 --conf "$e328_h11/.config/egresslock/ci.conf" 2>&1)"; rc=$?
[[ "$rc" == 1 \
    && "$o" == *"OK: conf parse: ok (profile 'ci'"* \
    && "$o" == *"fix: sudo egresslock-setup init --account u11 --enable"* \
    && "$o" != *"init --account u11 --profile ci --enable"* ]] \
    && e328 pass || e328 fail "doctor --conf hint does not narrow the fix (rc=$rc, out: $o)"

# 14c. An invalid unit.env profile token is reported, never joined into
#      a path; the fix is pathless (aggregate rewrite).
printf 'EGRESSLOCK_PROFILE=../evil\n' > "$e328_h11/.config/egresslock/unit.env"
o="$(e328_run "$e328_h11" doctor --account u11 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"PROBLEM: unit.env: invalid EGRESSLOCK_PROFILE '../evil'"* \
    && "$o" == *"fix: sudo egresslock-setup init --account u11 --enable"* ]] \
    && e328 pass || e328 fail "doctor rejects invalid unit.env profile, pathless fix (rc=$rc, out: $o)"

# 15. Unreadable source refused before dest write.
chmod 000 "$e328d/p2.conf"
o="$(e328_run "$e328_h2" import --account u2 --from "$e328d/p2.conf" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$o" == *"cannot read"* \
    && ! -e "$e328_h2/.config/egresslock/p2.conf" ]] \
    && e328 pass || e328 fail "unreadable source refused (rc=$rc, out: $o)"
chmod 644 "$e328d/p2.conf"

# 16. init --init-conf and --from are mutually exclusive (rc 2, no writes).
e328_h10="$e328d/home/u10"
o="$(e328_run "$e328_h10" init --account u10 --init-conf --from "$e328d/site.conf" 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"mutually exclusive"* \
    && ! -e "$e328_h10/.config/egresslock/main.conf" ]] \
    && e328 pass || e328 fail "--init-conf + --from rc 2, no writes (rc=$rc, out: $o)"
# 16b. The legacy flat bundle runs the alias coalesce after the verb-time
#      checks; it must still refuse --conf + --init-conf before import.
o="$(e328_run "$e328_h10" --account u10 --conf "$e328d/site.conf" --init-conf 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"mutually exclusive"* \
    && ! -e "$e328_h10/.config/egresslock/main.conf" \
    && ! -e "$e328_h10/.config/egresslock/ci.conf" ]] \
    && e328 pass || e328 fail "flat --conf + --init-conf rc 2, no writes (rc=$rc, out: $o)"

section_end egl328

# --- EGL-51: user manager before the account-side gateway build ------------
section_begin egl51 "EGL-51 user manager before build"
e51() { assert "$@"; }
e51d="$STATE/e51"
rm -rf "$e51d"; mkdir -p "$e51d/home/gacct/.config/egresslock"
printf 'profile p1 10.99.3.0/24\n    rule gateway-only\n    gateway 10.99.3.2 3128 p1-allowlist\n' > "$e51d/site.conf"
printf '# starter\n' > "$e51d/p1-allowlist"
printf 'profile p2 10.99.4.0/24\n' > "$e51d/plain.conf"
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

# EGL-52: the first-run build carries docker format too — one artifact
# shape across the three gateway-build surfaces (mirrors the egl38 pin;
# the WARN is gone because HEALTHCHECK becomes honored).
grep -q "build -t localhost/egresslock-gateway:e51a --format docker -f $SKITP/gateway/Containerfile $SKITP/gateway" "$STATE/buildlog" \
    && e51 pass || e51 fail "first-run build uses --format docker (EGL-52)"

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
#    EGL-80: grep -s — the negative assert legitimately targets a file
#    that rm just removed; the stderr "No such file" line is noise.
rm -f "$STATE/callorder.log"
e51plain="$e51d/home/plain"
rm -rf "$e51plain"; mkdir -p "$e51plain"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e51plain" \
    $SKIT --prefix "$SKITP" --account gacct --conf "$e51d/plain.conf" >/dev/null 2>&1
grep -s -q 'start user@' "$STATE/callorder.log" \
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
section_end egl51

# --- ARC-19: setup-account --init-conf (sshd-style starter conf) ----------
section_begin arc19 "ARC-19 init-conf"
a19() { assert "$@"; }
a19p="$STATE/a19/prefix"        # fresh kit prefix with examples deployed
a19h="$STATE/a19/home/iacct"    # virtual account home
rm -rf "$STATE/a19"; mkdir -p "$a19p" "$a19h"

# 1. install-kit deploys examples/ into the prefix (D3), root-owned files.
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    EGRESSLOCK_PATH_BINDIR="$a19p/wbin" EGRESSLOCK_PATH_SBINDIR="$a19p/wsbin" \
    "$KIT" --prefix "$a19p" >/dev/null 2>&1
[[ -f "$a19p/examples/main.conf" && -f "$a19p/examples/main-allowlist" ]] \
    && a19 pass || a19 fail "install-kit deploys examples/ (main.conf + main-allowlist)"
# The example itself must parse under the deployed engine and list 'main'.
a19_list="$(env ARCMOCK_PASSWD_HOME="$(conf_home_ro "$a19p/examples/main.conf")" \
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
a19_list="$(env ARCMOCK_PASSWD_HOME="$a19h" "$a19p/egresslock" list 2>&1)"
[[ "$a19_list" == *"main"* ]] \
    && a19 pass || a19 fail "init'd conf parses and lists 'main'"
[[ ! -s "$a19h/.config/egresslock/unit.env" ]] \
    && a19 pass || a19 fail "--init-conf unit.env carries no conf path (fixed confdir)"

# 2b. EGL-325 F5: --init-conf ships `profile main`; a named --profile
#     without --conf is rejected as a usage error instead of failing
#     step 1 with a misleading "no profile config: <name>.conf".
a19f5h="$STATE/a19/f5home"
rm -rf "$a19f5h"; mkdir -p "$a19f5h"
a19_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a19f5h" \
    $SKIT --prefix "$a19p" --account iacct --init-conf --profile named 2>&1)"; a19_rc=$?
[[ "$a19_rc" == 2 && "$a19_out" == *"ships the 'main' starter"* \
    && "$a19_out" == *"import --from <path>"* ]] \
    && a19 pass || a19 fail "--init-conf --profile named → usage rc 2 (rc=$a19_rc, out: $a19_out)"
[[ ! -e "$a19f5h/.config/egresslock/main.conf" && ! -e "$a19f5h/.config/egresslock/named.conf" ]] \
    && a19 pass || a19 fail "--init-conf --profile named writes nothing"
# --profile main still describes the starter it ships.
a19_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a19f5h" \
    $SKIT --prefix "$a19p" --account iacct --init-conf --profile main 2>&1)"; a19_rc=$?
[[ "$a19_rc" == 0 && -f "$a19f5h/.config/egresslock/main.conf" \
    && "$(grep -x 'EGRESSLOCK_PROFILE=main' "$a19f5h/.config/egresslock/unit.env")" == "EGRESSLOCK_PROFILE=main" ]] \
    && a19 pass || a19 fail "--init-conf --profile main still works (rc=$a19_rc, out: $a19_out)"
rm -rf "$a19f5h"

# 3. Never overwrites: an existing conf keeps its content. A complete
#    pair re-run stays rc 0 (no refusal); a missing sibling allowlist
#    makes the pair torn and --init-conf REFUSES (EGL-100: rc 1, names
#    present + missing, never heals, never announces ready).
a19_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a19h" \
    $SKIT --prefix "$a19p" --account iacct --init-conf 2>&1)"; a19_rc=$?
[[ "$a19_rc" == 0 && "$a19_out" != *"torn conf pair"* ]] \
    && a19 pass || a19 fail "complete pair re-run stays rc 0, no refusal (rc=$a19_rc, out: $a19_out)"
printf 'profile custom 10.198.0.0/24\n' > "$a19_conf"
rm -f "$a19_al"
a19_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a19h" \
    $SKIT --prefix "$a19p" --account iacct --init-conf 2>&1)"; a19_rc=$?
grep -qx "profile custom 10.198.0.0/24" "$a19_conf" \
    && a19 pass || a19 fail "--init-conf never overwrites an existing conf"
[[ ! -e "$a19_al" ]] \
    && a19 pass || a19 fail "--init-conf on existing conf does NOT create a missing sibling allowlist"
[[ "$a19_rc" == 1 ]] \
    && a19 pass || a19 fail "torn pair refused (rc=$a19_rc, out: $a19_out)"
[[ "$a19_out" == *"torn conf pair"* && "$a19_out" == *"present:"* && "$a19_out" == *"missing:"* ]] \
    && a19 pass || a19 fail "torn refusal names present + missing halves (out: $a19_out)"
[[ "$a19_out" != *"is ready"* ]] \
    && a19 pass || a19 fail "torn run never announces ready (out: $a19_out)"
rm -f "$a19_conf"

# 4. EGL-325: --conf is an install-time copy into the fixed confdir,
#    not a destination selector. The source is installed as
#    <profile>.conf (profile from the source's first `profile` line),
#    0600, and the source path is left untouched; no starter pair is
#    written next to the source.
a19_src="$STATE/a19/custom/site.conf"
mkdir -p "$STATE/a19/custom"
printf 'profile site 10.197.0.0/24\n' > "$a19_src"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a19h" \
    $SKIT --prefix "$a19p" --account iacct --conf "$a19_src" >/dev/null 2>&1
[[ -f "$a19h/.config/egresslock/site.conf" && -f "$a19_src" ]] \
    && a19 pass || a19 fail "--conf installs as <profile>.conf in the fixed confdir"
cmp -s "$a19_src" "$a19h/.config/egresslock/site.conf" \
    && a19 pass || a19 fail "--conf install copies the source byte-identically"
[[ "$(stat -c %a "$a19h/.config/egresslock/site.conf" 2>/dev/null)" == "600" ]] \
    && a19 pass || a19 fail "--conf install is 0600"
[[ ! -e "$STATE/a19/custom/main-allowlist" ]] \
    && a19 pass || a19 fail "--conf install writes no starter pair next to the source"
rm -rf "$STATE/a19/custom"

# 5. Missing examples fail closed with a pointer at install-kit.
a19_nopref="$STATE/a19/noprefix"
mkdir -p "$a19_nopref"
cp "$a19p/egresslock" "$a19_nopref/egresslock"
a19_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a19h" \
    $SKIT --prefix "$a19_nopref" --account iacct --init-conf 2>&1)"; a19_rc=$?
[[ "$a19_rc" == 1 && "$a19_out" == *"re-run install-kit.sh"* ]] \
    && a19 pass || a19 fail "missing examples → rc 1, points at install-kit (rc=$a19_rc, out: $a19_out)"

# 6. EGL-328: pathless init wires the on-disk confdir without a path;
#    an explicit missing --from still fails closed before wiring.
a19_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a19h" \
    $SKIT --prefix "$a19p" --account iacct 2>&1)"; a19_rc=$?
[[ "$a19_rc" == 0 && "$a19_out" == *"1) validate conf … OK"* ]] \
    && a19 pass || a19 fail "pathless init wires an existing confdir (rc=$a19_rc, out: $a19_out)"
a19_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a19h" \
    $SKIT --prefix "$a19p" --account iacct --conf "$STATE/a19/nope.conf" --profile nope 2>&1)"; a19_rc=$?
[[ "$a19_rc" == 1 && "$a19_out" == *"conf not found"* ]] \
    && a19 pass || a19 fail "missing --from still exits 1 fail-closed (rc=$a19_rc)"

# 7. On-host runuser/CWD finding: runuser inherits the caller's CWD and
#    chdir-fails when the account cannot traverse it (operator checkout
#    under a 0700 home → 'cannot chdir ...: Permission denied'). BOTH
#    root-mode runuser call sites must run from the account's own home.
#    (Static guard: the mock harness runs non-root hook mode and cannot
#    exercise runuser directly.)
[[ "$(grep -c 'cd "\$home" && runuser' "$SKIT")" == 2 ]] \
    && a19 pass || a19 fail "both runuser calls are home-CWD wrapped (on-host chdir finding)"
section_end arc19

# --- EGL-38: run map, --doctor, --build-gateway ------------------------------
section_begin egl38 "EGL-38 run map, doctor, build-gateway"
e38() { assert "$@"; }
e38p="$STATE/e38/prefix"   # fresh deployed kit prefix (engine + gateway + examples)
rm -rf "$STATE/e38"; mkdir -p "$e38p"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    EGRESSLOCK_PATH_BINDIR="$e38p/wbin" EGRESSLOCK_PATH_SBINDIR="$e38p/wsbin" \
    "$KIT" --prefix "$e38p" >/dev/null 2>&1
[[ -f "$e38p/egresslock" && -f "$e38p/gateway/Containerfile" && -f "$e38p/examples/main.conf" ]] \
    && e38 pass || e38 fail "e38 fixture: kit deployed to $e38p"
e38h="$STATE/e38/home/uctx"
mkdir -p "$e38h/.config/egresslock"
printf 'profile p1 10.99.5.0/24\n    rule gateway-only\n    gateway 10.99.5.2 3128 p1-allowlist\n' > "$STATE/e38/site.conf"
printf '# starter\n' > "$STATE/e38/p1-allowlist"
printf 'profile p2 10.99.6.0/24\n' > "$STATE/e38/plain.conf"
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
# EGL-200 M1: the init-conf tail ends on the next-step block (starter
# conf first profile 'main').
[[ "$e38o" == *"next steps (as the account):"* \
    && "$e38o" == *"  sudo -iu uctx"* \
    && "$e38o" == *"  egresslock ensure main"* ]] \
    && e38 pass || e38 fail "EGL-200 M1: init-conf block names starter first profile (out: $e38o)"

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
#    linger/timer still follow --enable. Fresh home: pathless init is an
#    AGGREGATE over the confdir, so the earlier p1 gateway conf would
#    otherwise keep steps 4/5 live.
e38plain="$STATE/e38/home/plain"
rm -rf "$e38plain"; mkdir -p "$e38plain"
: > "$STATE/systemctl.log"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38plain" \
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
if [[ "$e38_rc" == 1 && "$e38o" == *"PROBLEM: unit.env: missing"* && "$e38o" == *"fix: sudo egresslock-setup"* ]]; then
    e38 pass
else
    e38 fail "doctor: unit.env missing (rc=$e38_rc, out: $e38o)"
fi
# Host slice stays clean: engine + templates present.
[[ "$e38o" == *"OK: kit engine: present ($e38p)"* && "$e38o" == *"OK: unit templates: installed ($UNITS)"* ]] \
    && e38 pass || e38 fail "doctor: host slice rows (out: $e38o)"

# 5. --doctor with --account + gateway conf + inactive user manager:
#    rc 1, the fix names `systemctl start user@` (D38-7.2).
touch "$STATE/systemctl-usermgr-fails"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --doctor 2>&1)"; e38_rc=$?
if [[ "$e38_rc" == 1 && "$e38o" == *"PROBLEM: user manager: not active"* \
      && "$e38o" == *"fix: sudo systemctl start user@"* ]]; then
    e38 pass
else
    e38 fail "doctor: inactive user manager (rc=$e38_rc, out: $e38o)"
fi
rm -f "$STATE/systemctl-usermgr-fails"
# Healthy account slice (marker gone): rc 0, image + parse rows ok.
# Restore the unit.env the plain-conf run above rewrote.
# The unit.env pin carries the full OK row incl. its EGL-62 clause, so a
# dropped clause bites the battery too (negative-control coverage).
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 >/dev/null 2>&1
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 0 && "$e38o" == *"OK: gateway image: present"* && "$e38o" == *"OK: unit.env: matches ($e38h/.config/egresslock/unit.env) — the account's fixed confdir is wired (named mode: p1)"* \
    && "$e38o" == *"OK: conf parse: ok"* && "$e38o" == *"OK: timer: enabled"* && "$e38o" == *"OK: linger: on"* ]] \
    && e38 pass || e38 fail "doctor: healthy account slice rc 0 (rc=$e38_rc, out: $e38o)"
# EGL-62 uniform-token pin: every non-indented output line of the
# healthy doctor capture carries the `OK:`/`PROBLEM:`/`NOTE:` tokens;
# continuation lines keep the two-space indent. Greps for any line
# matching neither.
printf '%s\n' "$e38o" | grep -qvE '^(OK|PROBLEM|NOTE): |^  ' \
    && e38 fail "doctor: non-token row or unindented continuation in output" \
    || e38 pass
# EGL-325 F4: a pre-325 unit.env that still carries a conf path is a
# distinct STALE PROBLEM row (rc 1), with the full re-run fix.
e38uenv="$e38h/.config/egresslock/unit.env"
cp -p "$e38uenv" "$STATE/e38/unit.env.good"
printf 'EGRESSLOCK_PROFILE=p1\nEGRESSLOCK_CONF=%s\n' "$e38h/.config/egresslock/p1.conf" > "$e38uenv"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e38_rc=$?
if [[ "$e38_rc" == 1 \
      && "$e38o" == *"PROBLEM: unit.env: STALE (carries the removed EGRESSLOCK_CONF wiring; see $e38uenv)"* \
      && "$e38o" == *"fix: sudo egresslock-setup init --account uctx --profile p1 --enable"* ]]; then
    e38 pass
else
    e38 fail "doctor: legacy unit.env STALE row (rc=$e38_rc, out: $e38o)"
fi
cp -p "$STATE/e38/unit.env.good" "$e38uenv"; rm -f "$STATE/e38/unit.env.good"
# Account-less doctor = host slice only, rc 0; and the EGL-24 pin: NOT
# rc 2 unknown-argument (D38-5). EGL-201: no fixtures -> the M8 NOTE.
e38o="$(env EGRESSLOCK_UNIT_DIR="$UNITS" $SKIT --doctor 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 0 && "$e38o" != *"unknown argument: --doctor"* && "$e38o" == *"OK: kit engine: present"* \
    && "$e38o" == *"NOTE: no accounts have egresslock-verify services on this host"* ]] \
    && e38 pass || e38 fail "EGL-24 pin: --doctor runs (rc=$e38_rc, out: $e38o)"
# Usage conflicts: --build-gateway x --account, --doctor x --apparmor-add.
e38o="$($SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --build-gateway 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 2 && "$e38o" == *"cannot be combined with --account"* ]] \
    && e38 pass || e38 fail "build-gateway x account is a usage error (rc=$e38_rc)"
e38o="$($SKIT --doctor --apparmor-add 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 2 && "$e38o" == *"cannot be combined"* ]] \
    && e38 pass || e38 fail "doctor x apparmor-add is a usage error (rc=$e38_rc)"

# 6. --build-gateway as non-root builds from the DEPLOYED prefix
#    (not the checkout CWD rules; D38-3). EGL-222: the standalone is now
#    an exec alias of the engine verb, so the build carries the engine's
#    `--format docker` between -t and -f (D5; -t stays first).
: > "$STATE/buildlog"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e38c \
    $SKIT --prefix "$e38p" --build-gateway 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 0 ]] && e38 pass || e38 fail "build-gateway run (rc=$e38_rc, out: $e38o)"
grep -q "build -t localhost/egresslock-gateway:e38c --format docker -f $e38p/gateway/Containerfile $e38p/gateway" "$STATE/buildlog" \
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

# 8. EGL-222-D3/D9: the standalone is an exec ALIAS of the engine verb —
#    on an equal pin the "already built from deployed pin ..." line can
#    only come from `egresslock build-gateway`, and no second build runs.
e38pin="$(grep -oE 'sha256:[0-9a-f]{64}' "$e38p/gateway/Containerfile" | head -1)"
printf '%s 2026-09-01T00:00:00.000000000Z\n' "$e38pin" \
    > "$STATE/image-inspect-localhost_egresslock-gateway_e38c"
: > "$STATE/buildlog"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e38c \
    $SKIT --prefix "$e38p" --build-gateway 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 0 && "$e38o" == *"already built from deployed pin"* && ! -s "$STATE/buildlog" ]] \
    && e38 pass || e38 fail "build-gateway alias delegates to the engine verb (rc=$e38_rc, out: $e38o)"
# ... and --force forwards through the alias: an equal pin still rebuilds.
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e38c \
    $SKIT --prefix "$e38p" --build-gateway --force 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 0 && -s "$STATE/buildlog" ]] \
    && e38 pass || e38 fail "build-gateway alias forwards --force (rc=$e38_rc, out: $e38o)"
rm -f "$STATE/image-inspect-localhost_egresslock-gateway_e38c"

# 9. R-EGL-222-3 note: the alias with no engine at the prefix fails
#    closed with the remedy named (rc 1, not a bare exec 127).
e38neng="$STATE/e38/noeng"; mkdir -p "$e38neng"
e38o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 $SKIT --prefix "$e38neng" --build-gateway 2>&1)"; e38_rc=$?
[[ "$e38_rc" == 1 && "$e38o" == *"no engine at $e38neng/egresslock"* ]] \
    && e38 pass || e38 fail "alias without an engine fails closed named (rc=$e38_rc, out: $e38o)"
section_end egl38

# --- ARC-22: packaging (.deb + tar.gz) --------------------------------------
section_begin arc22 "ARC-22 packaging"
a22() { assert "$@"; }

DEBSH="$TREE_ROOT/packaging/build-deb.sh"
TARSH="$TREE_ROOT/packaging/build-tarball.sh"
p22="$STATE/a22"; rm -rf "$p22"; mkdir -p "$p22"

# D4: the tarball is the self-contained kit tree (incl. uninstall-kit.sh
# and the unit templates) + a README fragment.
# EGL-107-D1: the whole tarball flow (build, content asserts, extracted-
# tree install/uninstall) skips on the extracted kit — the producer and
# its artifacts are packaging/build-tarball.sh's; the f1*/AppArmor parts
# of this counter (no packaging deps) still run.
if [[ "$HAVE_BUILD_TARBALL" == 1 ]]; then
t_out="$(env EGRESSLOCK_TARBALL_OUT="$p22/k.tgz" "$TARSH" 2>&1)"; t_rc=$?
[[ "$t_rc" == 0 && -f "$p22/k.tgz" ]] \
    && a22 pass || a22 fail "tarball build (rc=$t_rc, out: $t_out)"
mkdir -p "$p22/x"; tar -xzf "$p22/k.tgz" -C "$p22/x"
for f in README.txt egresslock/install-kit.sh egresslock/uninstall-kit.sh \
         egresslock/egresslock egresslock/egresslock-setup \
         egresslock/gateway/Containerfile egresslock/examples/main.conf \
         egresslock/examples/egl-base/Containerfile \
         egresslock/examples/egl-base/build-egl-base \
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
# EGL-80-1-F1: explicit wrapper hooks (lib.sh defaults also exist; these
# make the tarball-flow call sites self-evidently non-host-writing).
u22="$p22/units"
i_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u22" \
    EGRESSLOCK_PATH_BINDIR="$p22/wbin" EGRESSLOCK_PATH_SBINDIR="$p22/wsbin" \
    bash "$p22/x/egresslock/install-kit.sh" --prefix "$p22/opt" 2>&1)"; i_rc=$?
for f in egresslock egresslock-start egresslock-verify egresslock-setup VERSION; do
    [[ -f "$p22/opt/$f" ]] && a22 pass || a22 fail "tarball install deployed $f (rc=$i_rc, out: $i_out)"
done
[[ -d "$p22/opt/gateway" && -f "$p22/opt/examples/main.conf" \
    && -f "$p22/opt/examples/egl-base/Containerfile" \
    && -x "$p22/opt/examples/egl-base/build-egl-base" \
    && -f "$u22/egresslock-verify@.service" ]] \
    && a22 pass || a22 fail "tarball install deployed gateway/examples/egl-base/units"
grep -q "ExecStart=$p22/opt/egresslock-verify" "$u22/egresslock-verify@.service" \
    && a22 pass || a22 fail "tarball install rewrote ExecStart with the prefix"

# EGL-72-D3: the extracted tree ships KIT_VERSION (the build version
# string); the install must stamp the deployed VERSION with it. Asserted
# here because the uninstall below removes the prefix wholesale.
[[ "$(tr -d ' \n' < "$p22/x/egresslock/KIT_VERSION")" == "$(sed -n 's/^version: //p' "$p22/opt/VERSION")" ]] \
    && a22 pass || a22 fail "EGL-72 tarball install uses KIT_VERSION as version:"

# ... and uninstall-kit.sh from the same tree removes it (same explicit
# wrapper hooks — EGL-80-1-F1).
u_out="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$u22" \
    EGRESSLOCK_PATH_BINDIR="$p22/wbin" EGRESSLOCK_PATH_SBINDIR="$p22/wsbin" \
    bash "$p22/x/egresslock/uninstall-kit.sh" --prefix "$p22/opt" 2>&1)"; u_rc=$?
[[ "$u_rc" == 0 && ! -d "$p22/opt" ]] \
    && a22 pass || a22 fail "tarball uninstall removes the prefix (rc=$u_rc, out: $u_out)"
else
    skip "$PKG_SKIP_TAG" "ARC-22 tarball flow (build + content asserts + extracted-tree install/uninstall) — packaging/build-tarball.sh is not on this tree (extracted kit)"
fi

# D1/D2: the staged .deb tree (file-set assert; dpkg optional below).
# EGL-107-D1: staging + every staged-tree assert skip with the producer.
if [[ "$HAVE_BUILD_DEB" == 1 ]]; then
s_out="$(env EGRESSLOCK_DEB_KEEP_STAGE="$p22/stage" \
    EGRESSLOCK_DEB_OUT="$p22/deb" "$DEBSH" 2>&1)"; s_rc=$?
[[ "$s_rc" == 0 ]] && a22 pass || a22 fail "deb staging run (rc=$s_rc, out: $s_out)"
for f in DEBIAN/control DEBIAN/postinst DEBIAN/postrm \
         usr/bin/egresslock usr/sbin/egresslock-setup \
         usr/lib/egresslock/egresslock usr/lib/egresslock/egresslock-setup \
         usr/lib/egresslock/VERSION usr/lib/egresslock/gateway/Containerfile \
         usr/share/egresslock/examples/main.conf \
         usr/share/egresslock/examples/main-allowlist \
         usr/share/egresslock/examples/egl-base/Containerfile \
         usr/share/egresslock/examples/egl-base/README.md \
         usr/share/egresslock/examples/egl-base/build-egl-base \
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
# EGL-103-D1: the deb's unit copies keep the generated-file notice and
# stay ticket-ID-free.
if grep -q "do not edit" "$p22/stage/usr/lib/systemd/system/egresslock-verify@.service" \
   && grep -q "do not edit" "$p22/stage/usr/lib/systemd/system/egresslock-verify@.timer"; then
    a22 pass
else
    a22 fail "deb unit copies carry the generated-file notice (EGL-103)"
fi
if grep -qE 'EGL-|ARC-' "$p22/stage/usr/lib/systemd/system/egresslock-verify@.service" \
                        "$p22/stage/usr/lib/systemd/system/egresslock-verify@.timer"; then
    a22 fail "deb unit text leaks ticket IDs (EGL-103)"
else
    a22 pass
fi
grep -q '^Package: egresslock$' "$p22/stage/DEBIAN/control" \
    && grep -q '^Architecture: all$' "$p22/stage/DEBIAN/control" \
    && grep -q '^Depends:.*podman' "$p22/stage/DEBIAN/control" \
    && grep -q '^Depends:.*conntrack' "$p22/stage/DEBIAN/control" \
    && a22 pass || a22 fail "control: package/arch/depends (D2; conntrack is the revocation-flush prerequisite)"
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
else
    skip "$PKG_SKIP_TAG" "ARC-22 deb staging + staged-tree asserts — packaging/build-deb.sh is not on this tree (extracted kit)"
fi

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

# R-EGL-37-1 D37-1: a stale /etc unit pointing at a dead prefix while the
# live kit is the .deb — setup must RETRY the deb unit dir and adopt the
# libdir prefix. EGRESSLOCK_DEFAULT_UNIT_DIR fakes the /etc probe without
# tripping explicit-hook suppression (EGRESSLOCK_UNIT_DIR would); a
# working /etc prefix still wins (f1w).
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
[[ "$f1w_rc" == 0 && "$f1w_out" != *"no engine at"* ]] \
    && a22 pass || a22 fail "D37-1 working default-/etc prefix wins over live deb (rc=$f1w_rc, out: $f1w_out)"

# dpkg-deb smoke test (when dpkg-deb exists and the producer is present;
# stage asserts already ran).
if command -v dpkg-deb >/dev/null 2>&1 && [[ "$HAVE_BUILD_DEB" == 1 ]]; then
    d_out="$(env EGRESSLOCK_DEB_OUT="$p22/egresslock_test_all.deb" "$DEBSH" 2>&1)"; d_rc=$?
    [[ "$d_rc" == 0 && -f "$p22/egresslock_test_all.deb" ]] \
        && a22 pass || a22 fail "dpkg-deb build smoke (rc=$d_rc, out: $d_out)"
    dpkg-deb -I "$p22/egresslock_test_all.deb" 2>/dev/null | grep -q ' new Debian package' \
        && a22 pass || a22 fail "dpkg-deb -I reads the built archive"
    dpkg-deb -c "$p22/egresslock_test_all.deb" 2>/dev/null | grep -qE '\./usr/bin/egresslock$' \
        && a22 pass || a22 fail "dpkg-deb -c lists /usr/bin/egresslock"
    dpkg-deb -f "$p22/egresslock_test_all.deb" Architecture 2>/dev/null | grep -qx 'all' \
        && a22 pass || a22 fail "dpkg-deb -f Architecture=all"
elif [[ "$HAVE_BUILD_DEB" == 0 ]]; then
    skip "$PKG_SKIP_TAG" "ARC-22 dpkg-deb smoke — packaging/build-deb.sh is not on this tree (extracted kit)"
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
# EGL-80-L5: a FAILING aa-status stub — the deterministic stand-in for
# "AppArmor not enabled" (state 3 needs `aa-status --enabled` to fail or
# be missing; the real host binary may be present and succeed).
mkdir -p "$aa22/bin-noaa"
printf '#!/usr/bin/env bash\nexit 1\n' > "$aa22/bin-noaa/aa-status"
chmod +x "$aa22/bin-noaa/aa-status"
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
[[ "$rc" == 0 && "$o" == *"hint: the podman network helper (pasta) is confined by AppArmor"* \
    && "$o" == *"apparmor add"* \
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
#     EGL-80-L5: pin the profiles path to an absent file and shadow the
#     host's real aa-status (which may exist and succeed) with the
#     failing stub, so state 3 is deterministic on any host.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin-noaa:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/nosuchprofiles" "$SKIT" --apparmor-add 2>&1)"; rc=$?
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
#     EGL-80-L5: failing aa-status stub on PATH (the host's real
#     aa-status may exist and report enabled -> state 2, not 3).
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin-noaa:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad-empty" \
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
#     the no-effect note (EGL-200 M5); the labeled path never does.
o="$(run_aa --apparmor-add 2>&1)"; rc=$?   # labeled default fixture
[[ "$rc" == 0 && "$o" != *"no effect on this host"* ]] \
    && a22 pass || a22 fail "EGL-39 labeled apply has no noop note (rc=$rc, out: $o)"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad39" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" "$SKIT" --apparmor-add 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"AppArmor: the egresslock rule is in place but has no effect on this host."* \
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
[[ "$rc" == 0 && "$o" == *"hint: the podman network helper (pasta) is confined by AppArmor"* \
    && "$o" == *"is confined by AppArmor."* \
    && "$o" != *"(rule file:"* \
    && "$o" == *"'kill network process: permission denied', run: sudo egresslock-setup apparmor add"* \
    && "$o" != *"no effect on this host"* ]] \
    && a22 pass || a22 fail "EGL-39 labeled no-flag run keeps hint (rc=$rc, out: $o)"
: > "$STATE/apparmor.log"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" \
    EGRESSLOCK_ACCOUNT_HOME="$aa22/home39" \
    "$SKIT" --prefix "$SKITP" --account cacct --conf "$a18d/plain.conf" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" != *"hint: the podman network helper"* \
    && "$o" == *"AppArmor: this host's podman is not confined by AppArmor, so no extra AppArmor rule is needed — no action needed."* ]] \
    && a22 pass || a22 fail "EGL-39 unlabeled no-flag run: no hint, one-liner (rc=$rc, out: $o)"

# EGL-301: the AppArmor preamble (hint + the unlabeled one-liner) prints
#     only on the account-setup path — doctor and build-gateway are
#     silent on both (the account-bundle run above keeps them). Both
#     profiles fixture: pasta enforced + podman unconfined, so the
#     pre-EGL-301 code printed here.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 PATH="$aa22/bin:$PATH" \
    EGRESSLOCK_SHARE="$aa22/share" EGRESSLOCK_APPARMOR_D="$aa22/aad" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    "$SKIT" doctor 2>&1)"; rc=$?
[[ "$o" != *"hint: the podman network helper"* \
    && "$o" != *"not confined by AppArmor"* \
    && "$o" == *"NOTE: AppArmor: see egresslock-setup apparmor check (pasta slice)"* ]] \
    && a22 pass || a22 fail "EGL-301 doctor is silent on the AppArmor preamble (rc=$rc, out: $o)"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e301 \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" \
    "$SKIT" --prefix "$e38p" --build-gateway 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" != *"hint: the podman network helper"* \
    && "$o" != *"not confined by AppArmor"* ]] \
    && a22 pass || a22 fail "EGL-301 build-gateway is silent on the AppArmor preamble (rc=$rc, out: $o)"

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
# is identification only. EGL-107-D1: the script-shape greps skip on the
# extracted kit (scripts absent there); the dpkg-ordering pins below stay.
if [[ "$HAVE_BUILD_DEB" == 1 && "$HAVE_BUILD_TARBALL" == 1 ]]; then
grep -q "%Y%m%d%H%M%S" "$DEBSH" && grep -q "rev-parse --short=12" "$DEBSH" \
    && a22 pass || a22 fail "EGL-27 build-deb.sh stamps second-resolution + short12"
grep -q "%Y%m%d%H%M%S" "$TARSH" && grep -q "rev-parse --short=12" "$TARSH" \
    && a22 pass || a22 fail "EGL-27 build-tarball.sh stamps second-resolution + short12"
if ! grep -q "%Y%m%d')." "$DEBSH" && ! grep -q "%Y%m%d')." "$TARSH"; then
    a22 pass
else
    a22 fail "EGL-27 old date-only stamp still present"
fi
else
    skip "$PKG_SKIP_TAG" "EGL-27 build-script stamp-shape greps — packaging/build-*.sh are not on this tree (extracted kit)"
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
    # EGL-273: cross-base ordering derived from VERSION_BASE — a base
    # bump alone (same timestamp, same sha — worst case) must still
    # compare as an upgrade; a release bump needs no test edit
    # (replaces the per-release literal pairs, EGL-72-D4 .. EGL-242-D8).
    e273_base="$(tr -d ' \t\n' < "$TREE_ROOT/VERSION_BASE" 2>/dev/null || true)"
    e273_prev=""
    if [[ "$e273_base" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        if (( BASH_REMATCH[2] > 0 )); then
            e273_prev="${BASH_REMATCH[1]}.$((BASH_REMATCH[2]-1)).${BASH_REMATCH[3]}"
        elif (( BASH_REMATCH[1] > 0 )); then
            e273_prev="$((BASH_REMATCH[1]-1)).0.0"
        fi
    fi
    if [[ -z "$e273_prev" ]]; then
        a22 fail "EGL-273 cross-base check: cannot derive a previous base from VERSION_BASE '$e273_base' (EGL-164-D1 N.N.N shape)"
    elif dpkg --compare-versions "${e273_prev}+git20260924192516.76f1e51d345a" \
            lt "${e273_base}+git20260924192516.76f1e51d345a"; then
        a22 pass
    else
        a22 fail "EGL-273 derived cross-base stamp not an upgrade under dpkg ordering ($e273_prev -> $e273_base)"
    fi
else
    skip "dpkg absent" "EGL-27 dpkg not available; skipping compare-versions assert"
fi

# A real build stamps the artifact with the new scheme (the output name is
# fixed, so the stamp is read from the build-log line). EGL-164: the
# live-base pin derives from VERSION_BASE (shape B). EGL-273: the cross-base
# dpkg-ordering check also derives its previous base from VERSION_BASE,
# replacing the per-release literal pairs (EGL-72-D4, EGL-82-D4, EGL-88-D8,
# EGL-118-D8, EGL-135-D8, EGL-188-D8, EGL-204-D8, EGL-242-D8).
# EGL-80-L8: the stamp embeds the git commit; without .git (exported
# snapshot) build-tarball falls back to 'unknown' (named SKIP, EGL-74).
# Full assert runs in the private tree and public git clones.
b27="$p22/egl27"; rm -rf "$b27"; mkdir -p "$b27"
if [[ "$HAVE_BUILD_TARBALL" == 0 ]]; then
    # EGL-107-D1: the producer is absent (extracted kit) — the shape
    # cause names the real reason; .git shape is irrelevant here.
    skip "$PKG_SKIP_TAG" "EGL-27 tarball stamp assert — packaging/build-tarball.sh is not on this tree (extracted kit)"
elif [[ ! -d "$TREE_ROOT/.git" ]]; then
    skip "git-metadata absent" "EGL-27 tarball stamp assert needs .git metadata (absent in exported/staged trees); build-tarball falls back to 'unknown' by design"
else
    t27_rc=0
    env EGRESSLOCK_TARBALL_OUT="$b27/k.tgz" "$TARSH" >"$b27/log" 2>&1 || t27_rc=$?
    # EGL-164: the live-base pin derives from VERSION_BASE — a bump
    # needs no test edit here.
    base164="$(tr -d ' \t\n' < "$TREE_ROOT/VERSION_BASE" 2>/dev/null || true)"
    if [[ -z "$base164" ]]; then
        a22 fail "EGL-164 VERSION_BASE missing/empty at $TREE_ROOT/VERSION_BASE — derived live-base pin cannot run"
        base164="IMPOSSIBLE_BASE_EGL_164"   # never matches; downstream assert stays fail-closed
    fi
    # EGL-164-D1: base format assumption is N.N.N — escape only '.'.
    # Inside double quotes \\+ / \\. yield \+ / \. in the ERE —
    # byte-identical to the old hardcoded literal (the EGL-188-D8 shape);
    # a maintainer-written base could only widen the match (in-repo,
    # reviewed file; accepted, EGL-164-D1).
    re164="$(printf '%s' "$base164" | sed 's/\./\\./g')\\+git[0-9]{14}\\.[0-9a-f]{12}(-dirty)?"
    v27_real="$(grep -oE "$re164" "$b27/log" | head -1)"
    [[ "$t27_rc" == 0 && -f "$b27/k.tgz" && -n "$v27_real" ]] \
        && a22 pass || a22 fail "EGL-27 tarball build stamps new scheme (rc=$t27_rc, log: $(cat "$b27/log"))"
fi

# D2: the warn is warn-only — build-deb.sh must print the version and
# must not gate on dpkg-query (builds succeed without it). The compare
# path only fires when an installed package exists; here assert the
# code shape (echo + dpkg-query + --compare-versions ... ge + stderr
# WARNING) rather than an installed package in the test container.
if [[ "$HAVE_BUILD_DEB" == 1 ]]; then
grep -q 'build-deb: version \$version' "$DEBSH" \
    && grep -q "dpkg-query -W -f='\${Version}' egresslock" "$DEBSH" \
    && grep -q 'dpkg --compare-versions "\$installed" ge "\$version"' "$DEBSH" \
    && grep -q 'WARNING - installed egresslock' "$DEBSH" \
    && a22 pass || a22 fail "EGL-27 build-deb.sh prints version + downgrade warn (D2)"
else
    skip "$PKG_SKIP_TAG" "EGL-27 build-deb warn-shape grep — packaging/build-deb.sh is not on this tree (extracted kit)"
fi

# --- EGL-72: VERSION_BASE 0.1.0 + release-aware stamps ---------------------
# D1: one VERSION_BASE at the repo root, fail-closed in all three
# scripts. D3: both VERSION stamps carry a `version:` line; the tarball
# ships VERSION_BASE + stage-only KIT_VERSION (the KIT_VERSION→version:
# assert lives in the tarball-install section above, before the
# uninstall removes the prefix). D4: the base asserts + pins.
[[ -s "$TREE_ROOT/VERSION_BASE" ]] \
    && a22 pass || a22 fail "EGL-72 VERSION_BASE exists at the repo root"
# EGL-72-D3 stage/tarball VERSION consumers (EGL-107-D1: skip with the
# producers on the extracted kit; the install-kit stamp assert stays).
if [[ "$HAVE_BUILD_DEB" == 1 ]]; then
grep -q '^version: ' "$p22/stage/usr/lib/egresslock/VERSION" \
    && a22 pass || a22 fail "EGL-72 deb VERSION stamp has a version: line"
else
    skip "$PKG_SKIP_TAG" "EGL-72 deb-stage VERSION stamp assert — packaging/build-deb.sh is not on this tree (extracted kit)"
fi
grep -q '^version: ' "$OPT/VERSION" \
    && a22 pass || a22 fail "EGL-72 install-kit VERSION stamp has a version: line"
if [[ "$HAVE_BUILD_TARBALL" == 1 ]]; then
[[ -f "$p22/x/egresslock/VERSION_BASE" && -f "$p22/x/egresslock/KIT_VERSION" ]] \
    && a22 pass || a22 fail "EGL-72 tarball ships VERSION_BASE + KIT_VERSION"
else
    skip "$PKG_SKIP_TAG" "EGL-72 tarball VERSION_BASE/KIT_VERSION assert — packaging/build-tarball.sh is not on this tree (extracted kit)"
fi

section_end arc22

# --- EGL-39: install-kit.sh AppArmor advisory one-liner (D39-2) -----------
# Separate prefix/unit dirs so the a16 state asserts stay untouched.
section_begin a39 "EGL-39 install-kit advisory"
a39() { assert "$@"; }
ik39="$STATE/ik39"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_UNIT_DIR="$ik39/units" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles" EGRESSLOCK_PATH_BINDIR="$ik39/wbin" EGRESSLOCK_PATH_SBINDIR="$ik39/wbin" \
    "$KIT" --prefix "$ik39/opt" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"AppArmor: podman labeled; confirm pasta compatibility: sudo $ik39/opt/egresslock-setup apparmor check"* ]] \
    && a39 pass || a39 fail "EGL-39 install-kit labeled advisory (rc=$rc, out: $o)"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_UNIT_DIR="$ik39/units" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.nopodman" EGRESSLOCK_PATH_BINDIR="$ik39/wbin" EGRESSLOCK_PATH_SBINDIR="$ik39/wbin" \
    "$KIT" --prefix "$ik39/opt" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"AppArmor: this host's podman is not confined by AppArmor, so no extra AppArmor rule is needed — no action needed."* ]] \
    && a39 pass || a39 fail "EGL-39 install-kit unlabeled advisory (rc=$rc, out: $o)"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_UNIT_DIR="$ik39/units" \
    EGRESSLOCK_APPARMOR_PROFILES="$ik39/no-such-profiles" EGRESSLOCK_PATH_BINDIR="$ik39/wbin" EGRESSLOCK_PATH_SBINDIR="$ik39/wbin" \
    "$KIT" --prefix "$ik39/opt" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" != *"AppArmor:"* ]] \
    && a39 pass || a39 fail "EGL-39 install-kit silent on UNKNOWN (rc=$rc, out: $o)"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_UNIT_DIR="$ik39/units" \
    EGRESSLOCK_APPARMOR_PROFILES="$aa22/profiles.hats" EGRESSLOCK_PATH_BINDIR="$ik39/wbin" EGRESSLOCK_PATH_SBINDIR="$ik39/wbin" \
    "$KIT" --prefix "$ik39/opt" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"AppArmor: this host's podman is not confined by AppArmor, so no extra AppArmor rule is needed — no action needed."* ]] \
    && a39 pass || a39 fail "EGL-39 install-kit hats do not count as labeled (rc=$rc, out: $o)"
section_end a39

# --- ARC-72: pasta profile resolution (distro-dependent names) -------------
section_begin arc72 "ARC-72 apparmor resolution"
a72() { assert "$@"; }
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
      && "$o" == *"sudo egresslock-setup apparmor check"* ]]; then
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

section_end arc72

# --- EGL-14: compatibility include + doctor -------------------------------
# D1: apply on a profile with no local include installs a marked,
# backed-up compatibility include; --remove strips exactly it. D3: the
# --apparmor-check report reflects the amendment state and exits nonzero when a
# required element is missing.
section_begin arc14 "EGL-14 apparmor compat include + doctor"
a14() { assert "$@"; }

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

section_end arc14

# --- EGL-20: parser-reality fixes (preprocess, dot backup, no-truncate) ---
# D1: load-check uses a SINGLE -p action; EGL-56: `-p --preprocess` is
#     "Too many actions" on AppArmor 5, so the source pin keeps the pair out.
# D2: backup is a leading-dot file; an old non-dot backup migrates on apply.
# D3: strip never truncates the distro profile (rc 1, file + backup intact).
# D4: the patch lands after the pasta header's brace, not the first `{`.
section_begin arc20 "EGL-20 parser-reality fixes"
a20() { assert "$@"; }

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

section_end arc20

# --- EGL-23: remove-path verification (parser rc surfaced, -T, negative) --
# D1: a failing reload on remove is rc 1 (never a silent success). D2:
# the remove reload is `apparmor_parser -r -T -- <profile>`. D3: after a
# successful strip+reload the signal rule is ABSENT from the flattened
# profile; a still-present rule is rc 1 loud.
section_begin arc23 "EGL-23 remove verification"
a23() { assert "$@"; }

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

section_end arc23


# --- ARC-70: drift-signal visibility (setup hint) ---------------------------
# D1: --enable stays explicit. D2: account setup without --enable prints a
# loud stdout hint naming the re-run; with --enable there is no hint; an
# --apparmor-alone run (no account processed) never hints. D3: the engine
# never queries systemctl/linger (asserted in the engine harness instead).
section_begin arc70 "ARC-70 drift-signal hint"
a70() { assert "$@"; }

# 1. Account setup without --enable: the re-run line is runnable and
#    named with the account's own paths (EGL-102-F1/R4: carries --conf,
#    and --profile when one was passed; the old text claimed "linger not
#    set", which is false on a re-run of a wired account). EGL-270 P3
#    (candidate 5): the bare "timer NOT enabled" clause was trimmed —
#    egl51 #2 pins the hint line's presence; the ("did not arm drift
#    checks" + re-arm) bits below are its only home.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$a18d/home/cacct" \
    $SKIT --prefix "$SKITP" --account cacct --conf "$a18d/site.conf" --profile p1 2>&1)"
[[ "$rc" == 0 ]] || true
[[ "$o" == *"this run did not arm drift checks"* \
    && "$o" == *"sudo egresslock-setup init --account cacct --profile p1 --enable"* ]] \
    && a70 pass || a70 fail "no --enable -> loud hint with runnable re-run line (out: $o)"

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

section_end arc70

# --- ARC-69 D5: --apparmor-add file handling (mode/inode/blank lines) ----------
# Apply inserts the blank separator only after existing non-empty
# content; --remove strips a blank before the marker, writes INTO the
# file (inode + mode + owner survive; mv would clobber a conffile), and
# truncates whitespace-only residue to 0 bytes.
section_begin arc69s "ARC-69 apparmor file handling"
a69s() { assert "$@"; }

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

section_end arc69s

# --- EGL-50: doctor Summary + verdict reword, report-only remove, hygiene --
# D50-2: `pasta amendment: required on this host` vocabulary. D50-3:
# one final `Summary:` line on --apparmor-check; rc agrees (OK 0,
# FAILED 1, UNKNOWN 1 — never rc 2, never green from unknown). D50-6.1:
# the apply confirm line points at --apparmor-check. D50-7: remove is
# report-only — no ritual, no probe command. D50-4/D50-5: no `[--enable]`
# and no internal ticket IDs in shipped output.
section_begin egl50 "EGL-50 doctor summary + message hygiene"
e50() { assert "$@"; }

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
      && "$o" == *"Confirm with: sudo egresslock-setup apparmor check"* \
      && "$o" != *"must now FAIL"* \
      && "$o" != *"podman unshare"* ]]; then
    e50 pass
else
    e50 fail "D50-6.1 apply confirm points at apparmor check (rc=$rc, out: $o)"
fi

# 8. D50-4: no `[--enable]` bracket presentation anywhere operator-facing.
#    EGL-107-D1: packaging files skip per-file on the extracted kit; the
#    shipped kit scripts always assert (an absent file must not turn
#    the grep into a vacuous pass).
for f in "$TREE_ROOT/egresslock-setup" "$TREE_ROOT/install-kit.sh" \
         "$TREE_ROOT/packaging/build-deb.sh" "$TREE_ROOT/packaging/build-tarball.sh" \
         "$TREE_ROOT/packaging/README.md"; do
    if [[ ! -f "$f" ]]; then
        skip "$PKG_SKIP_TAG" "D50-4 [--enable] sweep — $f is not on this tree (extracted kit)"
    elif grep -qF -- '[--enable]' "$f"; then
        e50 fail "D50-4 [--enable] bracket in $f"
    else
        e50 pass
    fi
done

# 9. D50-5: shipped install output speaks product — the generated
#    postinst and the tarball README fragment carry no internal ticket
#    IDs and point at apparmor check; no [--enable] either.
#    EGL-107-D1: both artifacts are packaging producers' outputs; skip
#    with them on the extracted kit.
if [[ "$HAVE_BUILD_DEB" == 1 ]]; then
if grep -qF 'ARC-22-D3' "$p22/stage/DEBIAN/postinst"; then
    e50 fail "D50-5 postinst leaks ARC-22-D3"
else
    e50 pass
fi
grep -q 'apparmor check' "$p22/stage/DEBIAN/postinst" \
    && e50 pass || e50 fail "postinst points at apparmor check"
grep -qF -- '[--enable]' "$p22/stage/DEBIAN/postinst" \
    && e50 fail "postinst still shows [--enable]" || e50 pass
else
    skip "$PKG_SKIP_TAG" "D50-5 postinst hygiene greps — packaging/build-deb.sh is not on this tree (extracted kit)"
fi
if [[ "$HAVE_BUILD_TARBALL" == 1 ]]; then
if grep -qF 'ARC-22-D3' "$p22/x/README.txt"; then
    e50 fail "tarball README fragment carries ARC-22-D3"
else
    e50 pass
fi
grep -q 'apparmor check' "$p22/x/README.txt" \
    && e50 pass || e50 fail "tarball README fragment points at apparmor check"
grep -qF -- '[--enable]' "$p22/x/README.txt" \
    && e50 fail "tarball README still shows [--enable]" || e50 pass
else
    skip "$PKG_SKIP_TAG" "D50-5 tarball README hygiene greps — packaging/build-tarball.sh is not on this tree (extracted kit)"
fi

section_end egl50

# --- EGL-55: doctor profile-networks row (advisory) -----------------------
# D55-1: with --account + a parsed conf, one rc-neutral row after the
# gateway image lines: present (all), missing (names) — run: egresslock
# ensure <name>..., or unknown when `podman network ls` fails. The row
# never fails the doctor and never runs ensure.
section_begin egl55 "EGL-55 doctor profile-networks row"
e55() { assert "$@"; }
mkdir -p "$STATE/e55"

# 1. Healthy account slice, no networks yet: advisory missing row, rc 0.
rm -f "$STATE/networks"/*
e55o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e55rc=$?
[[ "$e55rc" == 0 && "$e55o" == *"NOTE: profile networks: missing (p1) — run as the account: egresslock ensure p1"* ]] \
    && e55 pass || e55 fail "D55-1 missing row, rc stays 0 (rc=$e55rc, out: $e55o)"

# 2. Network present in the account store: present (p1), still rc 0.
printf 'driver=bridge\nsubnet=10.99.5.0/24\ngateway=10.99.5.1\nipv6_enabled=false\n' \
    > "$STATE/networks/egresslock-p1"
e55o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e55rc=$?
[[ "$e55rc" == 0 && "$e55o" == *"OK: profile networks: present (p1)"* ]] \
    && e55 pass || e55 fail "D55-1 present row (rc=$e55rc, out: $e55o)"

# 3. EGL-323: a conf with a second `profile` block is refused at load
#    (one profile per conf file). The walked path shows the engine error
#    under the parse FAIL row and the row's named skip; doctor rc 1.
#    EGL-325: doctor reads the account's fixed confdir, so stage the
#    fixture as <profile>.conf there before the read-only run.
printf 'profile pa 10.99.7.0/24\nprofile pb 10.99.8.0/24\n' \
    > "$STATE/e55/two.conf"
cp "$STATE/e55/two.conf" "$e38h/.config/egresslock/pa.conf"
e55o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e55/two.conf" --profile pa --doctor 2>&1)"; e55rc=$?
[[ "$e55rc" == 1 && "$e55o" == *"PROBLEM: conf parse: FAIL"* \
    && "$e55o" == *"$e38h/.config/egresslock/pa.conf:2: one profile per conf file: 'pa' is already defined at line 1; put each profile in its own conf file"* \
    && "$e55o" == *"NOTE: profile networks: skipped (conf parse failed above)"* ]] \
    && e55 pass || e55 fail "D55-1 two-profile conf rejected at load, row skipped (rc=$e55rc, out: $e55o)"
rm -f "$e38h/.config/egresslock/pa.conf"

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
[[ "$e55rc" == 0 && "$e55o" == *"NOTE: profile networks: unknown"* \
    && "$e55o" == *"OK: gateway image: present"* ]] \
    && e55 pass || e55 fail "D55-1 ls-failure -> unknown, rc-neutral (rc=$e55rc, out: $e55o)"
rm -f "$STATE/e55/bin/podman"

# 5. Conf parse already failed: the row is a NAMED skip with the cause
#    (EGL-102-D6-R2: disclose why, never silently absent); doctor still
#    rc 1 from the parse row.
printf 'profile bad 10.99.8.0/24\n    rule nonsense\n' > "$STATE/e55/bad.conf"
cp "$STATE/e55/bad.conf" "$e38h/.config/egresslock/bad.conf"
e55o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e55/bad.conf" --profile bad --doctor 2>&1)"; e55rc=$?
[[ "$e55rc" == 1 && "$e55o" == *"PROBLEM: conf parse: FAIL"* \
    && "$e55o" == *"NOTE: profile networks: skipped (conf parse failed above)"* ]] \
    && e55 pass || e55 fail "D55-1 row skipped when conf parse failed (rc=$e55rc, out: $e55o)"
rm -f "$e38h/.config/egresslock/bad.conf"

section_end egl55

# --- EGL-203: doctor gateway-image staleness row (advisory) --------------
# The present branch peeks at the image's base label and compares it with
# the deployed Containerfile pin, read from the engine's NEIGHBOR gateway/
# (build-gateway's context; R-EGL-222-3 F2, share override never feeds it).
# Advisory/rc-neutral (the EGL-55 precedent). Fixture: mock podman
# image-inspect ($D/image-inspect-<img>); default empty => "base unknown".
section_begin egl203 "EGL-203 doctor gateway-image staleness row"
e203() { assert "$@"; }
e203img="localhost/egresslock-gateway:latest"
e203fix="$STATE/image-inspect-$(echo "$e203img" | tr '/:' '__')"
e203dig="$(grep '^FROM ' "$e38p/gateway/Containerfile" | grep -oE 'sha256:[0-9a-f]{64}' | head -1)"
e203short="${e203dig#sha256:}"; e203short="${e203short:0:12}"   # the row prints the short digest
e203share="$STATE/e203/share"
mkdir -p "$e203share/gateway"

# 1. Label matches the deployed pin: the row shows the base (short
#    digest) + built date, no staleness line, doctor rc stays 0.
printf '%s 2026-09-01T00:00:00.000000000Z\n' "$e203dig" > "$e203fix"
e203o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e203rc=$?
[[ "$e203rc" == 0 && "$e203o" == *"OK: gateway image: present ($e203img) — base $e203short"* \
    && "$e203o" == *", built 2026-09-01"* && "$e203o" != *"stale:"* ]] \
    && e203 pass || e203 fail "D203-3 match row: base + built, rc-neutral (rc=$e203rc, out: $e203o)"
rm -f "$e203fix"

# 2. Divergent-pin round trip (R-EGL-222-3 F2): the share override does
#    NOT feed the doctor's pin. Share carries pin B (all-zero digest),
#    the engine neighbor carries pin A, the image is A-labelled: the
#    doctor must report NO stale row (its pin source = the remedy's
#    context), and the doctor's recommended remedy must agree — the
#    alias execs the engine verb, which reports up-to-date and builds
#    nothing.
printf 'FROM docker.io/library/debian:13-slim@sha256:%064d\n' 0 > "$e203share/gateway/Containerfile"
printf '%s 2026-09-01T00:00:00.000000000Z\n' "$e203dig" > "$e203fix"
e203o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" EGRESSLOCK_SHARE="$e203share" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e203rc=$?
[[ "$e203rc" == 0 && "$e203o" == *"OK: gateway image: present ($e203img) — base $e203short"* \
    && "$e203o" != *"stale:"* ]] \
    && e203 pass || e203 fail "D203-3 F2: share pin ignored, neighbor pin matches (rc=$e203rc, out: $e203o)"
: > "$STATE/buildlog"
e203o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_SHARE="$e203share" \
    $SKIT --prefix "$e38p" --build-gateway 2>&1)"; e203rc=$?
[[ "$e203rc" == 0 && "$e203o" == *"already built from deployed pin $e203short"* && ! -s "$STATE/buildlog" ]] \
    && e203 pass || e203 fail "D203-3 F2: the doctor's remedy agrees with the doctor (rc=$e203rc, out: $e203o)"

# 2b. Pin moved in the NEIGHBOR (the canonical pin source): the stale
#     row still fires with both sides named and the account-shell
#     rebuild pointer; still advisory (rc 0).
printf 'FROM docker.io/library/debian:13-slim@sha256:%064d\n' 0 > "$e38p/gateway/Containerfile"
e203o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e203rc=$?
[[ "$e203rc" == 0 && "$e203o" == *"stale: base pin moved (image base $e203short != deployed pin 000000000000)"* \
    && "$e203o" == *"rebuild in the account shell: egresslock build-gateway && egresslock ensure --replace-gateway <profile> per affected profile (see \"The gateway image\" reference page)"* ]] \
    && e203 pass || e203 fail "D203-3 neighbor-pin-moved stale row with pointer, rc-neutral (rc=$e203rc, out: $e203o)"
cp -f "$TREE_ROOT/gateway/Containerfile" "$e38p/gateway/Containerfile"   # restore the fixture prefix
rm -f "$e203fix" "$e203share/gateway/Containerfile"

# 3. Pre-label image (inspect succeeds, label empty): "base unknown
#    (pre-label image)" + the same rebuild pointer, rc-neutral.
printf ' 2026-08-01T00:00:00.000000000Z\n' > "$e203fix"
e203o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e203rc=$?
[[ "$e203rc" == 0 && "$e203o" == *"OK: gateway image: present ($e203img) — base unknown (pre-label image), built 2026-08-01"* \
    && "$e203o" == *"stale: base unknown (pre-label image) — rebuild in the account shell: egresslock build-gateway && egresslock ensure --replace-gateway <profile> per affected profile (see \"The gateway image\" reference page)"* ]] \
    && e203 pass || e203 fail "D203-3 pre-label row with pointer, rc-neutral (rc=$e203rc, out: $e203o)"
rm -f "$e203fix"

# 3b. EGL-254: Podman's literal "<no value>" marker for a missing label
#     key (a space inside) must classify exactly like the empty label —
#     pre-label row + pre-label stale pointer, never a "base <no" or
#     "base pin moved" claim.
printf '<no value> 2026-08-01T00:00:00.000000000Z\n' > "$e203fix"
e203o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e203rc=$?
[[ "$e203rc" == 0 \
    && "$e203o" == *"OK: gateway image: present ($e203img) — base unknown (pre-label image), built 2026-08-01"* \
    && "$e203o" == *"stale: base unknown (pre-label image)"* \
    && "$e203o" != *"base pin moved"* && "$e203o" != *"<no value>"* ]] \
    && e203 pass || e203 fail "D203-3 literal <no value> pre-label row, rc-neutral (rc=$e203rc, out: $e203o)"
rm -f "$e203fix"

# 4. Inspect fails (no session/old podman): degrades to a bare "base
#    unknown" — no staleness claim, no pre-label guess, doctor rc 0.
mkdir -p "$STATE/e203/bin"
cat > "$STATE/e203/bin/podman" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == image && "\$2" == inspect ]]; then echo "mock: inspect denied" >&2; exit 1; fi
exec "$TESTROOT/bin/podman" "\$@"
EOF
chmod +x "$STATE/e203/bin/podman"
e203o="$(env PATH="$STATE/e203/bin:$PATH" EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 \
    EGRESSLOCK_ACCOUNT_HOME="$e38h" EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e203rc=$?
[[ "$e203rc" == 0 && "$e203o" == *"OK: gateway image: present ($e203img) — base unknown"* \
    && "$e203o" != *"pre-label"* && "$e203o" != *"stale:"* ]] \
    && e203 pass || e203 fail "D203-3 inspect failure degrades to base unknown, rc-neutral (rc=$e203rc, out: $e203o)"
rm -f "$STATE/e203/bin/podman"

section_end egl203

# --- EGL-59: kit --help is operator UI — no ticket/process citations -----
# Same rule as the engine (EGL-59-D1/D2/D3): kit help headers must not leak
# ticket/decision IDs or paths. The snapshot gate's `docs/tickets` DIRECTORY
# name is allowed (matched only as a trailing component, D3 regex
# `docs/tickets/[A-Za-z0-9]`). R-EGL-69-1 finding 3: build-gateway joins.
section_begin egl59 "EGL-59 kit help operator-UI"
e59() { assert "$@"; }
k59_id_re='ARC-[0-9]|EGL-[0-9]|docs/tickets/[A-Za-z0-9]'
entries59=("egresslock-setup:-h" "egresslock-verify:-h" \
           "install-kit.sh:-h" "uninstall-kit.sh:-h" \
           "build-gateway:-h" "egresslock-setup:help")
# EGL-74-D1: the private publisher is not on the public tree — skip its
# -h entry there.
if [[ "$HAVE_SNAPSHOT" == 1 ]]; then
    entries59+=("packaging/snapshot-public.sh:-h")
else
    skip "snapshot-public.sh absent" "packaging/snapshot-public.sh -h — not on the public tree (EGL-74-D1)"
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

section_end egl59

# --- EGL-60: unlabeled-not-required matrix + out-of-scope guards ----------
# D60-1: on a KNOWN-unlabeled host with the pasta profile found, the verdict
# is `not required on this host (podman unlabeled)` and the check ends
# `Summary: CHECK OK (AppArmor patch not needed)`, rc 0, for every
# extension/rule combination; detail lines stay as evidence.
# D60-2 amends D39-4: missing extension is rc 1 only when `required` or
# `condition unknown` (labeled hosts keep FAILED — e50 #4/#5, 4t, EGL-14 #4).
section_begin egl60 "EGL-60 unlabeled-not-required doctor verdict"
e60() { assert "$@"; }

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

section_end egl60

# --- EGL-68/EGL-69: install-kit foreign-prefix guard; build-gateway
#     context follows the script; apparmor/ ships with the prefix -----
section_begin egl68 "EGL-68/69 install-kit guard + build-gateway + apparmor prefix"
e68() { assert "$@"; }

# EGL-68-D1: a non-kit prefix with a foreign gateway/ is refused rc 1,
# and the guard runs BEFORE any write: no engine binary smeared into
# the tree, the foreign gateway/ byte-identical.
e68p="$STATE/e68/foreign"; rm -rf "$STATE/e68"; mkdir -p "$e68p/gateway"
printf 'not a kit\n' > "$e68p/gateway/Makefile"
e68o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    EGRESSLOCK_PATH_BINDIR="$e68p/wbin" EGRESSLOCK_PATH_SBINDIR="$e68p/wsbin" \
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
    EGRESSLOCK_PATH_BINDIR="$e68r/wbin" EGRESSLOCK_PATH_SBINDIR="$e68r/wsbin" \
    "$KIT" --prefix "$e68r" 2>&1)"; e68_rc=$?
[[ "$e68_rc" == 1 && -f "$e68r/examples/recipes/keep.txt" && ! -e "$e68r/egresslock" ]] \
    && e68 pass || e68 fail "foreign recipes/ refused, untouched (rc=$e68_rc, out: $e68o)"
# EGL-232: the same guard covers examples/egl-base (foreign tree refused
# rc 1, never deleted).
e68b="$STATE/e68/foreign-egl-base"; mkdir -p "$e68b/examples/egl-base"
printf 'keep\n' > "$e68b/examples/egl-base/keep.txt"
e68o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    EGRESSLOCK_PATH_BINDIR="$e68b/wbin" EGRESSLOCK_PATH_SBINDIR="$e68b/wsbin" \
    "$KIT" --prefix "$e68b" 2>&1)"; e68_rc=$?
[[ "$e68_rc" == 1 && -f "$e68b/examples/egl-base/keep.txt" && ! -e "$e68b/egresslock" ]] \
    && e68 pass || e68 fail "foreign egl-base/ refused, untouched (rc=$e68_rc, out: $e68o)"
# Kit-shaped tree (gateway/Containerfile present, no other markers):
# the rm paths are kit-shaped, the install proceeds.
e68k="$STATE/e68/kitshaped"; mkdir -p "$e68k/gateway"
: > "$e68k/gateway/Containerfile"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    EGRESSLOCK_PATH_BINDIR="$e68k/wbin" EGRESSLOCK_PATH_SBINDIR="$e68k/wsbin" \
    "$KIT" --prefix "$e68k" >/dev/null 2>&1; e68_rc=$?
[[ "$e68_rc" == 0 && -f "$e68k/egresslock" && -f "$e68k/gateway/Containerfile" ]] \
    && e68 pass || e68 fail "kit-shaped tree (gateway/Containerfile) installs (rc=$e68_rc)"
# A marked prefix reinstalls and still replaces gateway/ wholesale
# (the rm path is taken; stale files do not survive an upgrade).
e68m="$STATE/e68/marked"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    EGRESSLOCK_PATH_BINDIR="$e68m/wbin" EGRESSLOCK_PATH_SBINDIR="$e68m/wsbin" \
    "$KIT" --prefix "$e68m" >/dev/null 2>&1
[[ -f "$e68m/VERSION" ]] \
    && e68 pass || e68 fail "marked prefix fixture (VERSION present)"
printf 'stale\n' > "$e68m/gateway/Containerfile.stale"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    EGRESSLOCK_PATH_BINDIR="$e68m/wbin" EGRESSLOCK_PATH_SBINDIR="$e68m/wsbin" \
    "$KIT" --prefix "$e68m" >/dev/null 2>&1; e68_rc=$?
[[ "$e68_rc" == 0 && -f "$e68m/gateway/Containerfile" \
    && ! -e "$e68m/gateway/Containerfile.stale" ]] \
    && e68 pass || e68 fail "reinstall on marked prefix replaces gateway/ (rc=$e68_rc)"
# EGL-69-D2: a fresh prefix ships apparmor/usr.bin.pasta.local.
e68a="$STATE/e68/aaprefix"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    EGRESSLOCK_PATH_BINDIR="$e68a/wbin" EGRESSLOCK_PATH_SBINDIR="$e68a/wsbin" \
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
grep -q 'build it: egresslock build-gateway' "$TREE_ROOT/egresslock" \
    && e68 pass || e68 fail "engine gateway-image hint names build-gateway"

section_end egl68

# --- EGL-90: strict --prefix charset (audit I-02/I-03), quoted PATH
#     wrapper exec, EGL-68 guard extended to apparmor/ -------------------
section_begin egl90 "EGL-90 prefix charset + quoted wrapper + apparmor guard"
e90() { assert "$@"; }
e90d="$STATE/e90"; rm -rf "$e90d"; mkdir -p "$e90d/units" "$e90d/wbin" "$e90d/wsbin"
# e90run: install-kit with the mock dirs; captures output, leaves rc.
e90run() {
    env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$e90d/units" \
        EGRESSLOCK_PATH_BINDIR="$e90d/wbin" EGRESSLOCK_PATH_SBINDIR="$e90d/wsbin" \
        "$KIT" --prefix "$1" 2>&1
}
# 1. (D2.1) '/tmp/eg;id' -> rc 2; NOTHING written: no wrapper, no unit
#    template, no prefix dir (the check runs at parse).
e90o="$(e90run '/tmp/eg;id')"; e90_rc=$?
[[ "$e90_rc" == 2 && "$e90o" == *"must be an absolute kit path"* \
    && ! -e "$e90d/wbin/egresslock" && ! -e "$e90d/wsbin/egresslock-setup" \
    && ! -e "$e90d/units/egresslock-verify@.service" && ! -e "/tmp/eg;id" ]] \
    && e90 pass || e90 fail "metachar --prefix rejected rc 2, nothing written (rc=$e90_rc, out: $e90o)"
# 2. (D2.2) |, $( ), and whitespace -> rc 2 (the sed-delimiter and
#    shell-metachar classes).
for e90_p in '/tmp/a|b' '/tmp/$(id)' '/tmp/a b'; do
    e90o="$(e90run "$e90_p")"; e90_rc=$?
    if [[ "$e90_rc" == 2 && "$e90o" == *"must be an absolute kit path"* ]]; then
        e90 pass
    else
        e90 fail "illegal --prefix '$e90_p' rejected rc 2 (rc=$e90_rc, out: $e90o)"
    fi
done
# 3. (D2.3) a legal absolute prefix (dots allowed) still installs; the
#    wrapper exec is QUOTED, the marker comment stays unquoted, and the
#    unit template carries the substituted ExecStart.
e90ok="$e90d/ok.prefix"
e90o="$(e90run "$e90ok")"; e90_rc=$?
[[ "$e90_rc" == 0 && -f "$e90ok/egresslock" ]] \
    && e90 pass || e90 fail "legal dotted prefix installs (rc=$e90_rc, out: $e90o)"
[[ "$(sed -n '2p' "$e90d/wbin/egresslock")" == "# egresslock-path-wrapper prefix=$e90ok" ]] \
    && e90 pass || e90 fail "wrapper marker line 2 stays unquoted (EGL-43 matching)"
grep -qF "exec \"$e90ok/egresslock\" \"\$@\"" "$e90d/wbin/egresslock" \
    && e90 pass || e90 fail "wrapper exec is quoted (I-03 defense in depth)"
grep -qF "exec \"$e90ok/egresslock-setup\" \"\$@\"" "$e90d/wsbin/egresslock-setup" \
    && e90 pass || e90 fail "setup wrapper exec is quoted"
grep -qF "ExecStart=$e90ok/egresslock-verify" "$e90d/units/egresslock-verify@.service" \
    && e90 pass || e90 fail "unit template ExecStart carries the legal prefix"
# 4. (EGL-90-D3) the EGL-68 guard now also covers $prefix/apparmor: a
#    foreign apparmor/ tree with no kit markers anywhere is refused rc 1
#    and left byte-identical, BEFORE any copy.
e90aa="$e90d/foreign-aa"; mkdir -p "$e90aa/apparmor"
printf 'keep\n' > "$e90aa/apparmor/keep.conf"
e90o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$e90d/units" \
    EGRESSLOCK_PATH_BINDIR="$e90aa/wbin" EGRESSLOCK_PATH_SBINDIR="$e90aa/wsbin" \
    "$KIT" --prefix "$e90aa" 2>&1)"; e90_rc=$?
[[ "$e90_rc" == 1 && -f "$e90aa/apparmor/keep.conf" \
    && "$e90o" == *"refusing to delete $e90aa/apparmor"* && ! -e "$e90aa/egresslock" ]] \
    && e90 pass || e90 fail "foreign apparmor/ refused rc 1, untouched (rc=$e90_rc, out: $e90o)"

section_end egl90

# --- EGL-83: co-install guard — postinst /etc shadow handling (D1) +
#     install-kit deb-libdir refuse (D2) ---------------------------------
section_begin egl83 "EGL-83 co-install guard: postinst /etc shadow + deb-libdir refuse"
e83() { assert "$@"; }
e83="$STATE/e83"; rm -rf "$e83"; mkdir -p "$e83"

# D3: the staged (not built) postinst carries the shadow guard.
# EGL-107-D1: staging + the staged-text asserts skip with the producer
# on the extracted kit; the deb-libdir refusal assert below is
# packaging-independent and still runs.
if [[ "$HAVE_BUILD_DEB" == 1 ]]; then
s_out="$(env EGRESSLOCK_DEB_KEEP_STAGE="$e83/stage" \
    EGRESSLOCK_DEB_OUT="$e83/deb" "$DEBSH" 2>&1)"; s_rc=$?
[[ "$s_rc" == 0 && -f "$e83/stage/DEBIAN/postinst" ]] \
    && e83 pass || e83 fail "deb staging run (rc=$s_rc, out: $s_out)"
e83pi="$e83/stage/DEBIAN/postinst"
grep -q '/etc/systemd/system/egresslock-verify@.service' "$e83pi" \
    && e83 pass || e83 fail "postinst checks the /etc shadow template (D1)"
grep -qF 'uninstall-kit.sh --prefix $live_prefix' "$e83pi" \
    && e83 pass || e83 fail "postinst fail-branch names the uninstall remediation (D1)"
grep -q 'dpkg --configure egresslock' "$e83pi" \
    && e83 pass || e83 fail "postinst fail-branch names the configure finisher (D1)"
grep -q 'removed stale prefix-install unit shadowing' "$e83pi" \
    && e83 pass || e83 fail "postinst remove-stale branch named (D1)"
# EGL-102-D6-R5: the /etc classification (R5 table on the postinst card)
# is staged-text asserted; the mock battery cannot run dpkg/postinst.
grep -q 'cmp -s' "$e83pi" \
    && e83 pass || e83 fail "postinst classifies the /etc timer against the package copy (R5)"
grep -q 'stale-product' "$e83pi" \
    && e83 pass || e83 fail "postinst product-shaped stale class (R5)"
grep -q 'kept $etc_svc — not recognizable' "$e83pi" \
    && e83 pass || e83 fail "unknown-shape service kept with disclosure (R5)"
grep -q 'kept $etc_tmr' "$e83pi" \
    && e83 pass || e83 fail "unknown-shape timer kept with disclosure (R5)"
grep -q 'prefix-live' "$e83pi" \
    && e83 pass || e83 fail "live custom-prefix detection via ExecStart markers (R1/R5)"
grep -q 'reset-failed' "$e83pi" \
    && e83 pass || e83 fail "postinst resets failed instances (D1)"
if grep -vE '^\s*(#|$)' "$e83pi" | grep -qE 'systemctl enable|apparmor_parser'; then
    e83 fail "postinst enables a timer or applies AppArmor (D1 boundary)"
else
    e83 pass
fi
# EGL-270 P3 (candidate 6): egl103 folded into this block. It consumed this
# staged deb tree and re-grepped boundaries already pinned above; the folded
# asserts are the ones with no home here — one postinst/postrm disclosure
# line per unit mutate (R2 bounded to unit mutates; the mock cannot run
# dpkg/postinst). The duplicate stale-prefix-unit re-grep was dropped.
e83prm="$e83/stage/DEBIAN/postrm"
# The always-run reload discloses exactly once (dedupe: the shadow-rm
# branch must not print a second daemon-reload line).
[[ "$(grep -cF 'postinst: systemd daemon-reload' "$e83pi")" == 1 ]] \
    && e83 pass || e83 fail "postinst prints the daemon-reload line exactly once"
grep -qF 'postrm: systemd daemon-reload' "$e83prm" \
    && e83 pass || e83 fail "postrm prints the daemon-reload line"
# postrm stays a reload-only script (ARC-22-D2 boundary re-check).
if grep -vE '^\s*(#|$)' "$e83prm" | grep -qE 'rm -rf|rm -f|podman|config/egresslock|apparmor_parser'; then
    e83 fail "postrm deletes state or touches podman/AppArmor"
else
    e83 pass
fi
else
    skip "$PKG_SKIP_TAG" "EGL-83 staged-postinst asserts — packaging/build-deb.sh is not on this tree (extracted kit)"
fi

# D3: install-kit refuses a deb-libdir kit (EGRESSLOCK_DEB_LIBDIR/VERSION
# present, no dpkg-query needed) rc 1, and writes NO units and NO PATH
# wrappers (the refusal sits in the wrapper stage, before section 2).
e83d="$e83/libdir"; mkdir -p "$e83d/libdir" "$e83d/units" "$e83d/wbin" "$e83d/wsbin"
: > "$e83d/libdir/VERSION"
e83o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$e83d/units" \
    EGRESSLOCK_PATH_BINDIR="$e83d/wbin" EGRESSLOCK_PATH_SBINDIR="$e83d/wsbin" \
    EGRESSLOCK_DEB_LIBDIR="$e83d/libdir" \
    "$KIT" --prefix "$e83d/opt" 2>&1)"; e83_rc=$?
[[ "$e83_rc" == 1 && "$e83o" == *'apt remove egresslock'* \
    && "$e83o" == *'rm -r'* \
    && ! -e "$e83d/units/egresslock-verify@.service" \
    && ! -e "$e83d/wbin/egresslock" && ! -e "$e83d/wsbin/egresslock-setup" ]] \
    && e83 pass || e83 fail "deb-libdir kit refuses install-kit rc 1 (rc=$e83_rc, out: $e83o)"

section_end egl83

# --- EGL-103-D3: postinst/postrm print one line per unit mutate ---------
# Removed per EGL-270 P3 (candidate 6): the section consumed the EGL-83
# staged deb tree and re-grepped boundaries pinned at stage-build time;
# its unique disclosure-time asserts now run inside egl83's staged block
# (same fixture, one skip cover — the EGL-107-D1 skip reason stands).

# --- EGL-102-D6-R2: install-kit source-completeness preflight -----------
# An incomplete kit tree fails closed BEFORE any copy (nothing written,
# named missing files + next action) instead of a mid-deploy
# `install: cannot stat` partial prefix.
section_begin egl102r2 "EGL-102-R2 install-kit source-completeness preflight (excluded-silent — no RESULTS line, not in TOTAL; declared gap, EGL-184-D2)" excluded-silent
e102r2() { assert "$@"; }
e102d="$STATE/e102r2"; rm -rf "$e102d"; mkdir -p "$e102d/sparse" "$e102d/dest"
cp "$TREE_ROOT/install-kit.sh" "$e102d/sparse/"
printf '0.2.0\n' > "$e102d/sparse/VERSION_BASE"
e102o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$e102d/units" \
    EGRESSLOCK_PATH_BINDIR="$e102d/wbin" EGRESSLOCK_PATH_SBINDIR="$e102d/wsbin" \
    "$e102d/sparse/install-kit.sh" --prefix "$e102d/dest" 2>&1)"; e102_rc=$?
[[ "$e102_rc" == 1 && "$e102o" == *"incomplete kit tree at $e102d/sparse"* \
    && "$e102o" == *"missing: "* && "$e102o" == *"restore the full checkout"* \
    && ! -e "$e102d/dest/egresslock" && ! -e "$e102d/units/egresslock-verify@.service" ]] \
    && e102r2 pass || e102r2 fail "incomplete tree fails closed, nothing written (rc=$e102_rc, out: $e102o)"

# EGL-270 P3 (candidate 12, generated-glue refactor — excluded-silent, no
# counted delta): the kit manifest is enumerated once; each partial case
# stages the full tree minus its own exclusion instead of three
# hand-maintained copies that grew one entry per release.
e102_manifest=(
    install-kit.sh egresslock egresslock-start egresslock-verify egresslock-setup
    gateway/Containerfile gateway/entrypoint.sh gateway/squid.conf
    apparmor/usr.bin.pasta.local apparmor/README.md
    examples/main.conf examples/main-allowlist examples/recipes
    examples/egl-base/Containerfile
    systemd/egresslock-verify@.service systemd/egresslock-verify@.timer
)
e102_stage_tree() { # e102_stage_tree <dest> [missing...] — manifest minus exclusions, VERSION_BASE seeded
    local d="$1"; shift
    local f skip
    for f in "${e102_manifest[@]}"; do
        for skip in "$@"; do
            [[ "$f" == "$skip" ]] && continue 2
        done
        mkdir -p "$d/$(dirname "$f")"
        cp -R "$TREE_ROOT/$f" "$d/$f"
    done
    printf '0.2.0\n' > "$d/VERSION_BASE"
}

# Partial case (EGL-102-D6-F3): every enumerated item present EXCEPT
# examples/recipes — the preflight must still fail closed BEFORE any
# copy (the copy list copies recipes unconditionally; without this, the
# gate passes and a bare `cp: cannot stat ... recipes` kills a partial
# deploy mid-way).
e102p="$e102d/partial"; mkdir -p "$e102p"
e102_stage_tree "$e102p" examples/recipes
e102d2="$e102d/dest2"; mkdir -p "$e102d2"
e102o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$e102d/units" \
    EGRESSLOCK_PATH_BINDIR="$e102d/wbin" EGRESSLOCK_PATH_SBINDIR="$e102d/wsbin" \
    "$e102p/install-kit.sh" --prefix "$e102d2" 2>&1)"; e102_rc=$?
[[ "$e102_rc" == 1 && "$e102o" == *"incomplete kit tree at $e102p"* \
    && "$e102o" == *"missing: examples/recipes"* \
    && ! -e "$e102d2/egresslock" && ! -e "$e102d2/gateway" && ! -e "$e102d2/examples" ]] \
    && e102r2 pass || e102r2 fail "recipes-only gap fails closed pre-copy (rc=$e102_rc, out: $e102o)"

# EGL-232: the enumeration covers egl-base too — everything present EXCEPT
# examples/egl-base/Containerfile must fail closed BEFORE any copy.
e102b="$e102d/partial-eglbase"; mkdir -p "$e102b"
e102_stage_tree "$e102b" examples/egl-base/Containerfile
e102d3="$e102d/dest3"; mkdir -p "$e102d3"
e102o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$e102d/units" \
    EGRESSLOCK_PATH_BINDIR="$e102d/wbin" EGRESSLOCK_PATH_SBINDIR="$e102d/wsbin" \
    "$e102b/install-kit.sh" --prefix "$e102d3" 2>&1)"; e102_rc=$?
[[ "$e102_rc" == 1 && "$e102o" == *"incomplete kit tree at $e102b"* \
    && "$e102o" == *"missing: examples/egl-base/Containerfile"* \
    && ! -e "$e102d3/egresslock" && ! -e "$e102d3/gateway" && ! -e "$e102d3/examples" ]] \
    && e102r2 pass || e102r2 fail "egl-base-only gap fails closed pre-copy (rc=$e102_rc, out: $e102o)"

# EGL-240: everything current (incl. examples/egl-base/Containerfile)
# EXCEPT the build helper → rc 1, the missing list names the helper,
# nothing copied.
e102h="$e102d/partial-helper"; mkdir -p "$e102h"
e102_stage_tree "$e102h" examples/egl-base/build-egl-base
e102d4="$e102d/dest4"; mkdir -p "$e102d4"
e102o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$e102d/units" \
    EGRESSLOCK_PATH_BINDIR="$e102d/wbin" EGRESSLOCK_PATH_SBINDIR="$e102d/wsbin" \
    "$e102h/install-kit.sh" --prefix "$e102d4" 2>&1)"; e102_rc=$?
[[ "$e102_rc" == 1 && "$e102o" == *"incomplete kit tree at $e102h"* \
    && "$e102o" == *"missing: "*examples/egl-base/build-egl-base* \
    && ! -e "$e102d4/egresslock" && ! -e "$e102d4/gateway" && ! -e "$e102d4/examples" ]] \
    && e102r2 pass || e102r2 fail "helper-absent gap fails closed pre-copy (rc=$e102_rc, out: $e102o)"
section_end egl102r2

# --- EGL-240: build-egl-base helper (mock podman) ------------------------
# The example-image helper checks/builds localhost/egl-base:latest next
# to its Containerfile. Fixture: helper + Containerfile in a temp dir;
# the shared mock (lib.sh) answers podman image exists/inspect via
# $STATE/image-inspect-… (catted verbatim) and records `podman build`
# into $STATE/buildlog (build -t also makes the image exist). Never
# runs a container; never calls egresslock.
section_begin egl240 "EGL-240 build-egl-base"
e240() { assert "$@"; }
EGLIMG="localhost/egl-base:latest"
EGLSTATE_KEY="$(echo "$EGLIMG" | tr '/:' '__')"
EGLINS="$STATE/image-inspect-$EGLSTATE_KEY"
EGLSRV="$STATE/egl240-srv"
rm -rf "$EGLSRV"; mkdir -p "$EGLSRV"
cp "$TREE_ROOT/examples/egl-base/build-egl-base" "$EGLSRV/build-egl-base"
cp "$TREE_ROOT/examples/egl-base/Containerfile" "$EGLSRV/Containerfile"
chmod +x "$EGLSRV/build-egl-base"
EGLPIN="$(grep -oE 'sha256:[0-9a-f]{64}' "$EGLSRV/Containerfile" | head -1)"
EGLPIN12="${EGLPIN#sha256:}"; EGLPIN12="${EGLPIN12:0:12}"
egl_saved_wd="$(pwd)"

# 1. Foreign cwd: invoke by path; context/flag from the helper's OWN dir.
cd /tmp
: > "$STATE/buildlog"
e_out="$(PATH="$TESTROOT/bin:$PATH" "$EGLSRV/build-egl-base" 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 \
      && "$(cat "$STATE/buildlog")" == "build -t localhost/egl-base:latest -f $EGLSRV/Containerfile $EGLSRV" ]]; then
    e240 pass
else
    e240 fail "case 1 foreign cwd: helper-dir context, not caller cwd (rc=$e_rc, out: $e_out, bl: $(cat "$STATE/buildlog" 2>/dev/null))"
fi
cd "$egl_saved_wd"

# 2. Missing image → builds.
: > "$STATE/buildlog"
rm -f "$STATE/images/$EGLSTATE_KEY"
e_out="$(PATH="$TESTROOT/bin:$PATH" "$EGLSRV/build-egl-base" 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 \
      && "$e_out" == *"egl-base image: missing (localhost/egl-base:latest)"* \
      && "$e_out" == *">> Building localhost/egl-base:latest FROM $EGLPIN12"* \
      && "$e_out" == *">> Done: localhost/egl-base:latest"* \
      && -s "$STATE/buildlog" && "$(cat "$STATE/buildlog")" != *'--no-cache'* ]]; then
    e240 pass
else
    e240 fail "case 2 missing → build (rc=$e_rc, out: $e_out, bl: $(cat "$STATE/buildlog" 2>/dev/null))"
fi

# 3. Current image (label pin == deployed pin) → exact up-to-date line.
printf '%s\n' "$EGLPIN" > "$EGLINS"
: > "$STATE/buildlog"
e_out="$(PATH="$TESTROOT/bin:$PATH" "$EGLSRV/build-egl-base" 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 \
      && "$e_out" == "already built from deployed pin $EGLPIN12 — use --force to rebuild" \
      && ! -s "$STATE/buildlog" ]]; then
    e240 pass
else
    e240 fail "case 3 current → exact up-to-date line, no build (rc=$e_rc, out: $e_out)"
fi

# 4. Stale (label pin != deployed pin) → stale + rebuild.
printf 'sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$EGLINS"
: > "$STATE/buildlog"
e_out="$(PATH="$TESTROOT/bin:$PATH" "$EGLSRV/build-egl-base" 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 \
      && "$e_out" == *"egl-base image: stale: base pin moved (image deadbeefdead != deployed pin $EGLPIN12)"* \
      && -s "$STATE/buildlog" ]]; then
    e240 pass
else
    e240 fail "case 4 stale pin → rebuild (rc=$e_rc, out: $e_out)"
fi

# 5a. Pre-label: empty inspect fixture.
: > "$EGLINS"
: > "$STATE/buildlog"
e_out="$(PATH="$TESTROOT/bin:$PATH" "$EGLSRV/build-egl-base" 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 \
      && "$e_out" == *"egl-base image: stale: base unknown (pre-label image)"* \
      && -s "$STATE/buildlog" ]]; then
    e240 pass
else
    e240 fail "case 5a pre-label empty fixture → rebuild (rc=$e_rc, out: $e_out)"
fi
# 5b. Pre-label: the literal <no value> (missing Go-template key).
printf '<no value>\n' > "$EGLINS"
e_out="$(PATH="$TESTROOT/bin:$PATH" "$EGLSRV/build-egl-base" 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 \
      && "$e_out" == *"egl-base image: stale: base unknown (pre-label image)"* \
      && -s "$STATE/buildlog" ]]; then
    e240 pass
else
    e240 fail "case 5b pre-label <no value> → rebuild (rc=$e_rc, out: $e_out)"
fi

# 6. --force on a current image → rebuild with --no-cache, no state line.
printf '%s\n' "$EGLPIN" > "$EGLINS"
: > "$STATE/buildlog"
e_out="$(PATH="$TESTROOT/bin:$PATH" "$EGLSRV/build-egl-base" --force 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 \
      && "$e_out" == *">> Building"* && "$e_out" != *"egl-base image:"* \
      && "$(cat "$STATE/buildlog")" == *'--no-cache'* ]]; then
    e240 pass
else
    e240 fail "case 6 --force rebuilds (rc=$e_rc, out: $e_out, bl: $(cat "$STATE/buildlog" 2>/dev/null))"
fi

# 7. Podman absent → rc 1, exact error, no build attempted.
egl_emptybin="$STATE/egl240-emptybin"; rm -rf "$egl_emptybin"; mkdir -p "$egl_emptybin"
ln -s "$(command -v bash || echo /usr/bin/bash)" "$egl_emptybin/bash"
ln -s "$(command -v dirname || echo "$(command -v dirname)")" "$egl_emptybin/dirname"
: > "$STATE/buildlog"
e_out="$(PATH="$egl_emptybin" "$EGLSRV/build-egl-base" 2>&1)" && e_rc=0 || e_rc=$?
if [[ "$e_rc" == 1 \
      && "$e_out" == *"Error: podman not found on PATH (required to build localhost/egl-base:latest)"* \
      && ! -s "$STATE/buildlog" ]]; then
    e240 pass
else
    e240 fail "case 7 podman absent (rc=$e_rc, out: $e_out)"
fi

# 8. Bad argument → rc 2 usage.
e_out="$(PATH="$TESTROOT/bin:$PATH" "$EGLSRV/build-egl-base" foo 2>&1)" && e_rc=0 || e_rc=$?
if [[ "$e_rc" == 2 \
      && "$e_out" == *"Error: build-egl-base takes no arguments other than --force."* ]]; then
    e240 pass
else
    e240 fail "case 8 bad arg rc 2 (rc=$e_rc, out: $e_out)"
fi

# 9. --help prints the header; nothing runs.
: > "$STATE/buildlog"
e_out="$(PATH="$TESTROOT/bin:$PATH" "$EGLSRV/build-egl-base" --help 2>&1)"; e_rc=$?
if [[ "$e_rc" == 0 \
      && "$e_out" == *"build-egl-base — build the shared example image"* \
      && ! -s "$STATE/buildlog" ]]; then
    e240 pass
else
    e240 fail "case 9 --help (rc=$e_rc, out: $e_out)"
fi

# 10. Build failure → rc 1, exact retry line, no --force when plain.
rm -f "$STATE/images/$EGLSTATE_KEY" "$EGLINS"
: > "$STATE/build-fails"
: > "$STATE/buildlog"
egl_noP="$(PATH="$TESTROOT/bin:$PATH" "$EGLSRV/build-egl-base" 2>&1)" && e_rc=0 || e_rc=$?
egl_q="$(printf '%q' "$EGLSRV/build-egl-base")"
if [[ "$e_rc" == 1 \
      && "$egl_noP" == *"Error: egl-base image build failed for localhost/egl-base:latest (build output above); fix the cause and re-run: $egl_q"* \
      && "$egl_noP" != *"--force"* ]]; then
    e240 pass
else
    e240 fail "case 10 build failure retry (rc=$e_rc, out: $egl_noP, expect retry: $egl_q)"
fi
rm -f "$STATE/build-fails"

# 11. Missing Containerfile → rc 1 exact error.
egl_nocf="$STATE/egl240-nocf"; rm -rf "$egl_nocf"; mkdir -p "$egl_nocf"
cp "$TREE_ROOT/examples/egl-base/build-egl-base" "$egl_nocf/build-egl-base"
chmod +x "$egl_nocf/build-egl-base"
e_out="$(PATH="$TESTROOT/bin:$PATH" "$egl_nocf/build-egl-base" 2>&1)" && e_rc=0 || e_rc=$?
if [[ "$e_rc" == 1 \
      && "$e_out" == *"Error: no Containerfile at $egl_nocf/Containerfile"* ]]; then
    e240 pass
else
    e240 fail "case 11 missing Containerfile (rc=$e_rc, out: $e_out)"
fi
rm -f "$EGLINS"
section_end egl240

# --- EGL-84: --doctor verify-unit health rows (hermetic systemctl) ----
section_begin egl84 "EGL-84 doctor verify-unit health"
e84() { assert "$@"; }
e84d="$STATE/e84"; rm -rf "$e84d"; mkdir -p "$e84d/units" "$e84d/prefix"
: > "$e84d/prefix/egresslock"
# Mock unit templates for the doctor rows (ExecStart present, target exec).
sed "s|__EGRESSLOCK_PREFIX__|$e84d/prefix|g" "$TREE_ROOT/systemd/egresslock-verify@.service" \
    > "$e84d/units/egresslock-verify@.service"
: > "$e84d/units/egresslock-verify@.timer"
chmod +x "$e84d/prefix/egresslock"
# e84run: account-less doctor (host slice) unless --account given.
e84run() {
    env EGRESSLOCK_UNIT_DIR="$e84d/units" "$SKIT" --prefix "$e84d/prefix" "$@" 2>&1
}
# e84clean: remove the systemctl mock fixtures between cases.
e84clean() {
    rm -f "$STATE/systemctl-fragpath" "$STATE/systemctl-fragpath-timer" \
          "$STATE/systemctl-mainstatus" "$STATE/systemctl-is-enabled" \
          "$STATE"/systemctl-show-* \
          "$STATE/systemctl-list-units" "$STATE/systemctl-list-units-failed" \
          "$STATE/systemctl-health-failed"
}

# 1. Healthy default (no fixtures): rc 0; the fragment is not resolved
#    by the mock (no fixture) and that is a NAMED neutral row, not a
#    failure, with a next check (reload) — no PROBLEM rows. R1: the
#    host slice names what it did not examine (account wiring pointer).
#    EGL-201: no fixtures = no enumerated accounts -> the M8 NOTE row
#    (no M7 inventory, no M9 summary).
e84o="$(e84run --doctor)"; e84_rc=$?
[[ "$e84_rc" == 0 && "$e84o" == *"NOTE: verify unit fragment: not resolved by systemctl"* \
    && "$e84o" == *"daemon-reload"* \
    && "$e84o" == *"not examined (no --account)"* \
    && "$e84o" == *"sudo egresslock-setup doctor --account <acct>"* \
    && "$e84o" == *"NOTE: no accounts have egresslock-verify services on this host"* \
    && "$e84o" != *"services healthy"* && "$e84o" != *"egresslock-verify services:"* \
    && "$e84o" != *"are set up for"* \
    && "$e84o" != *"FAILED"* && "$e84o" != *"SHADOWED"* && "$e84o" != *"DANGLING"* \
    && "$e84o" != *"PROBLEM: "* ]] \
    && e84 pass || e84 fail "healthy doctor stays rc 0 (rc=$e84_rc, out: $e84o)"

# 1b. EGL-201 P4/P5 healthy multi-account host: --all lists two
#     accounts' instances (alice service+timer pair, svc service), the
#     split --failed fixture is EMPTY -> M9 healthy row (2/2, the
#     service+timer pair counted once), M7 plural inventory, rc 0, no
#     PROBLEM. Both fixture files are set explicitly.
printf 'egresslock-verify@alice.service loaded active running\negresslock-verify@alice.timer loaded active waiting\negresslock-verify@svc.service loaded active running\n' > "$STATE/systemctl-list-units"
: > "$STATE/systemctl-list-units-failed"
e84o="$(e84run --doctor)"; e84_rc=$?
[[ "$e84_rc" == 0 && "$e84o" == *"OK: all egresslock-verify services healthy (2/2)"* \
    && "$e84o" == *"NOTE: egresslock-verify services are set up for 2 accounts: alice, svc — to check an account: sudo egresslock-setup doctor --account <acct>"* \
    && "$e84o" != *"PROBLEM: "* ]] \
    && e84 pass || e84 fail "healthy 2-account host: M9 (2/2) + M7 plural (rc=$e84_rc, out: $e84o)"

# 1c. EGL-201 partial + ghost: alice active + a dangling ghost
#     (`not-found` — excluded from M7/M9) + a failed svc timer
#     (timer shape: ExecMainStatus 0 -> the M3 timer copy, never
#     "exit status"); M9 partial row with the ghost out of both counts.
printf 'egresslock-verify@alice.service loaded active running\negresslock-verify@ghost.timer not-found not-found not-found\negresslock-verify@svc.timer loaded failed failed Periodic network policy verification for svc (drift signal)\n' > "$STATE/systemctl-list-units"
printf '● egresslock-verify@svc.timer loaded failed failed Periodic network policy verification for svc (drift signal)\n' > "$STATE/systemctl-list-units-failed"
printf '0\n' > "$STATE/systemctl-mainstatus"
e84o="$(e84run --doctor)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: egresslock-verify@svc.timer: FAILED — the timer is enabled but not running (the start result is unknown); the verify service did not run"* \
    && "$e84o" != *"exit status"* \
    && "$e84o" == *"PROBLEM: egresslock-verify services: 1 of 2 failed"* \
    && "$e84o" == *"NOTE: egresslock-verify services are set up for 2 accounts: alice, svc"* \
    && "$e84o" != *"ghost"* \
    && "$e84o" == *"inspect: sudo journalctl -u egresslock-verify@svc.timer -n 20"* \
    && "$e84o" != *"last:"* && "$e84o" != *"next:"* ]] \
    && e84 pass || e84 fail "failed timer: armed-state row + M9 partial 1 of 2, ghost excluded, no recency (rc=$e84_rc, out: $e84o)"
e84clean

# 2. Failed-instance sweep: 203/EXEC start failure classified. The fixture
#    carries the REAL systemd column shape (a `●` state-marker glyph
#    `--no-legend` does not strip — EGL-201-P1): the unit name is field 2.
#    EGL-345: no verify-unit row names the cause (no fragment resolved
#    here), so the row stays a PROBLEM with the service journal as the
#    lead evidence and carries last/next (never / not scheduled).
printf '● egresslock-verify@uacct.service loaded failed running\n' > "$STATE/systemctl-list-units"
printf '203\n' > "$STATE/systemctl-mainstatus"
e84o="$(e84run --doctor)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@uacct.service: FAILED — the verify program could not start (203/EXEC); systemd never ran it"* \
    && "$e84o" == *"  last: never"* && "$e84o" == *"  next: not scheduled"* \
    && "$e84o" == *"  inspect: sudo journalctl -u egresslock-verify@uacct.service -n 20"* \
    && "$e84o" != *"NOTE: egresslock-verify@uacct.service: failed (203/EXEC)"* \
    && "$e84o" != *"●"* \
    && "$e84o" == *"NOTE: egresslock-verify services are set up for 1 account: uacct"* ]] \
    && e84 pass || e84 fail "203 start failure row rc 1 (rc=$e84_rc, out: $e84o)"
# 2b. EGL-201-P1: the newer-systemd marker shape (`×`, v253+) parses to
#     the same row + inspect line — the token scan is marker-agnostic.
printf '× egresslock-verify@uacct.service loaded failed running\n' > "$STATE/systemctl-list-units"
e84o="$(e84run --doctor)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@uacct.service: FAILED — the verify program could not start (203/EXEC); systemd never ran it"* \
    && "$e84o" == *"inspect: sudo journalctl -u egresslock-verify@uacct.service -n 20"* \
    && "$e84o" != *"×"* ]] \
    && e84 pass || e84 fail "×-marked failed row parses to the real unit (rc=$e84_rc, out: $e84o)"
# 3. Exit-1 instance: the row names the verify-run failure, shows the
#    never/not-scheduled recency, and prints the runnable manual re-run
#    (ExecStart is unresolved in this fixture, so the named-unknown form
#    is printed), with the service journal secondary.
printf '1\n' > "$STATE/systemctl-mainstatus"
e84o="$(e84run --doctor)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: egresslock-verify@uacct.service: FAILED — the verify run failed (exit 1)"* \
    && "$e84o" == *"  last: never"* && "$e84o" == *"  next: not scheduled"* \
    && "$e84o" == *"  fix: run the verify program manually as uacct with the unit environment"* \
    && "$e84o" == *"inspect: sudo journalctl -u egresslock-verify@uacct.service -n 20"* \
    && "$e84o" == *"check: sudo egresslock-setup doctor --account uacct"* ]] \
    && e84 pass || e84 fail "exit-1 row text + recency + manual re-run rc 1 (rc=$e84_rc, out: $e84o)"
e84clean

# 3a. EGL-345: disabled + failed timer (the live-repro shape) — the state
#     names the cause, so no journal dead end; the row prints the clear +
#     re-arm + check, and kit_check_timer never contradicts it with an OK.
printf 'disabled\n' > "$STATE/systemctl-is-enabled"
printf 'resources\n' > "$STATE/systemctl-show-Result"
printf 'egresslock-verify@dtmr.timer\n' > "$STATE/systemctl-health-failed"
: > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account dtmr --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@dtmr.timer: FAILED and not enabled — the drift-check timer is disarmed; no verify run is scheduled"* \
    && "$e84o" == *"  fix: sudo systemctl reset-failed egresslock-verify@dtmr.timer"* \
    && "$e84o" == *"  fix: sudo egresslock-setup init --account dtmr --enable"* \
    && "$e84o" == *"  check: sudo egresslock-setup doctor --account dtmr"* \
    && "$e84o" != *"inspect:"* \
    && "$e84o" != *"OK: timer: enabled"* ]] \
    && e84 pass || e84 fail "disabled+failed timer: state row, no inspect, no OK (rc=$e84_rc, out: $e84o)"
e84clean

# 3b. EGL-345: enabled + failed timer with Result=resources — timer-start
#     language (not the enum), the bounded timer journal secondary with
#     the rotated-out caveat, reset-failed -> restart -> is-active check.
printf 'enabled\n' > "$STATE/systemctl-is-enabled"
printf 'resources\n' > "$STATE/systemctl-show-Result"
printf 'egresslock-verify@etmr.timer\n' > "$STATE/systemctl-health-failed"
: > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account etmr --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@etmr.timer: FAILED — the timer is enabled but not running (systemd reported a resource failure); the verify service did not run"* \
    && "$e84o" == *"  fix: sudo systemctl reset-failed egresslock-verify@etmr.timer"* \
    && "$e84o" == *"  fix: sudo systemctl restart egresslock-verify@etmr.timer"* \
    && "$e84o" == *"  inspect: sudo journalctl -u egresslock-verify@etmr.timer -n 20"* \
    && "$e84o" == *"an empty journal means the start error was rotated out"* \
    && "$e84o" == *"  check: sudo systemctl is-active egresslock-verify@etmr.timer"* \
    && "$e84o" != *"Result=resources"* && "$e84o" != *"OK: timer: enabled"* ]] \
    && e84 pass || e84 fail "enabled+failed timer: timer-start row + inspect + clear (rc=$e84_rc, out: $e84o)"
e84clean

# 3c. EGL-345: armed + failed service (exit 1) — service last/next (next
#     is the timer's NextElapse), the manual re-run with unit.env sourced,
#     and the bounded service journal secondary.
printf '#!/usr/bin/env bash\nExecStart=%s/prefix/egresslock-verify\n' "$e84d" > "$e84d/faketmpl-svc"
: > "$e84d/prefix/egresslock-verify"; chmod +x "$e84d/prefix/egresslock-verify"
printf '%s\n' "$e84d/faketmpl-svc" > "$STATE/systemctl-fragpath"
printf 'enabled\n' > "$STATE/systemctl-is-enabled"
printf '1\n' > "$STATE/systemctl-mainstatus"
printf 'Thu 2026-10-22 05:59:00 UTC\n' > "$STATE/systemctl-show-ExecMainStartTimestamp"
printf 'Thu 2026-10-22 06:00:00 UTC\n' > "$STATE/systemctl-show-ExecMainExitTimestamp"
printf 'Thu 2026-10-22 06:15:00 UTC\n' > "$STATE/systemctl-show-NextElapseUSecRealtime"
printf 'egresslock-verify@svcrun.service\n' > "$STATE/systemctl-health-failed"
: > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account svcrun --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@svcrun.service: FAILED — the verify run failed (exit 1)"* \
    && "$e84o" == *"  last: Thu 2026-10-22 06:00:00 UTC"* \
    && "$e84o" == *"  next: Thu 2026-10-22 06:15:00 UTC"* \
    && "$e84o" == *"  fix: sudo -iu svcrun bash -c 'set -a; . ~/.config/egresslock/unit.env 2>/dev/null || true; set +a; exec $e84d/prefix/egresslock-verify'"* \
    && "$e84o" == *"  inspect: sudo journalctl -u egresslock-verify@svcrun.service -n 20"* \
    && "$e84o" == *"  check: sudo egresslock-setup doctor --account svcrun"* \
    && "$e84o" != *"journalctl -u egresslock-verify@svcrun.timer"* ]] \
    && e84 pass || e84 fail "armed+failed service: last/next + env re-run + service journal (rc=$e84_rc, out: $e84o)"
e84clean

# 3d. EGL-345: 203/EXEC already explained by the verify-unit
#     ExecStart/target row -> a NOTE (no second PROBLEM, no inspect, no
#     repeated target/reinstall text). The actionable row above keeps
#     rc/grep intact.
printf '#!/usr/bin/env bash\nExecStart=/opt/egresslock/egresslock-verify\n' > "$e84d/faketmpl-203"
printf '%s\n' "$e84d/faketmpl-203" > "$STATE/systemctl-fragpath"
printf '203\n' > "$STATE/systemctl-mainstatus"
printf 'enabled\n' > "$STATE/systemctl-is-enabled"
printf 'egresslock-verify@noteacct.service\n' > "$STATE/systemctl-health-failed"
: > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account noteacct --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: verify unit: ExecStart target missing/not executable: /opt/egresslock/egresslock-verify"* \
    && "$e84o" == *"NOTE: egresslock-verify@noteacct.service: failed (203/EXEC) — explained by the verify-unit row above"* \
    && "$e84o" != *"PROBLEM: egresslock-verify@noteacct.service: FAILED"* \
    && "$e84o" != *"inspect:"* \
    && "$(grep -c 'the unit points at an uninstalled/renamed kit' <<<"$e84o")" == 1 ]] \
    && e84 pass || e84 fail "203 explained: NOTE, no problem/inspect/duplicate (rc=$e84_rc, out: $e84o)"
e84clean

# 3e. EGL-345: 203/EXEC the verify-unit row does NOT explain (target
#     present/executable, e.g. a missing ELF interpreter) -> stays a
#     PROBLEM with the service journal as the lead evidence.
printf '#!/usr/bin/env bash\nExecStart=%s/prefix/egresslock-verify\n' "$e84d" > "$e84d/faketmpl-203b"
printf '%s\n' "$e84d/faketmpl-203b" > "$STATE/systemctl-fragpath"
printf '203\n' > "$STATE/systemctl-mainstatus"
printf 'enabled\n' > "$STATE/systemctl-is-enabled"
printf 'egresslock-verify@noteacct2.service\n' > "$STATE/systemctl-health-failed"
: > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account noteacct2 --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@noteacct2.service: FAILED — the verify program could not start (203/EXEC); systemd never ran it"* \
    && "$e84o" == *"  inspect: sudo journalctl -u egresslock-verify@noteacct2.service -n 20"* \
    && "$e84o" != *"NOTE: egresslock-verify@noteacct2.service: failed"* \
    && "$e84o" != *"ExecStart target missing"* ]] \
    && e84 pass || e84 fail "unexplained 203: PROBLEM + service journal (rc=$e84_rc, out: $e84o)"
e84clean

# 3f. EGL-345: masked / static / not-found timers — the state names the
#     cause, the remedy is state-specific, and there is no timer journal
#     line (no dead end, and not-found has no journal stream at all).
printf 'masked\n' > "$STATE/systemctl-is-enabled"
printf 'egresslock-verify@mtmr.timer\n' > "$STATE/systemctl-health-failed"
: > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account mtmr --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@mtmr.timer: FAILED and masked — systemd will not start it until it is unmasked"* \
    && "$e84o" == *"  fix: sudo systemctl unmask egresslock-verify@mtmr.timer"* \
    && "$e84o" == *"  fix: sudo egresslock-setup init --account mtmr --enable"* \
    && "$e84o" != *"inspect:"* ]] \
    && e84 pass || e84 fail "masked timer: state remedy, no inspect (rc=$e84_rc, out: $e84o)"
e84clean
printf 'static\n' > "$STATE/systemctl-is-enabled"
printf 'egresslock-verify@stmr.timer\n' > "$STATE/systemctl-health-failed"
: > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account stmr --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@stmr.timer: FAILED and not enableable (static) — the unit template is missing or corrupt"* \
    && "$e84o" == *"  fix: reinstall the channel that owns the verify unit templates"* \
    && "$e84o" == *"  fix: sudo systemctl daemon-reload"* \
    && "$e84o" != *"inspect:"* ]] \
    && e84 pass || e84 fail "static timer: reinstall remedy, no inspect (rc=$e84_rc, out: $e84o)"
e84clean
printf 'not-found\n' > "$STATE/systemctl-is-enabled"
printf 'egresslock-verify@ntmr.timer\n' > "$STATE/systemctl-health-failed"
: > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account ntmr --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@ntmr.timer: FAILED and not found — the unit template is missing or corrupt"* \
    && "$e84o" == *"  fix: reinstall the channel that owns the verify unit templates"* \
    && "$e84o" != *"inspect:"* ]] \
    && e84 pass || e84 fail "not-found timer: reinstall remedy, no inspect (rc=$e84_rc, out: $e84o)"
e84clean

# 3g. EGL-345: service failed + timer disabled — both rows reconcile, the
#     timer row owns the re-arm (one copy), and the service row keeps the
#     verify journal (useful regardless of timer state).
printf 'disabled\n' > "$STATE/systemctl-is-enabled"
printf '1\n' > "$STATE/systemctl-mainstatus"
printf 'egresslock-verify@rectmr.service\negresslock-verify@rectmr.timer\n' > "$STATE/systemctl-health-failed"
: > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account rectmr --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
e84_svcblock="$(printf '%s\n' "$e84o" | sed -n '/PROBLEM: egresslock-verify@rectmr.service: FAILED/,/^[^ ]/p')"
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@rectmr.timer: FAILED and not enabled"* \
    && "$e84o" == *"PROBLEM: egresslock-verify@rectmr.service: FAILED — the verify run failed (exit 1); the timer is not enabled, so no further checks are scheduled"* \
    && "$e84o" == *"  fix: re-arm the timer — see its FAILED row above for the exact command"* \
    && "$e84o" == *"  inspect: sudo journalctl -u egresslock-verify@rectmr.service -n 20"* \
    && "$e84_svcblock" != *"egresslock-setup init --account rectmr"* \
    && "$e84o" != *"OK: timer: enabled"* ]] \
    && e84 pass || e84 fail "service+timer reconcile: one re-arm, service journal (rc=$e84_rc, out: $e84o)"
e84clean

# 3h. EGL-345 (R2): the armed-state probe did not answer (empty
#     is-enabled) -> the service row must NOT assert "the timer is not
#     enabled"; it names the unknown and the re-arm is conditional on
#     the operator's own state read. kit_check_timer names the same
#     unknown instead of a false "not enabled".
: > "$STATE/systemctl-is-enabled"
printf '1\n' > "$STATE/systemctl-mainstatus"
printf 'egresslock-verify@unkacct.service\n' > "$STATE/systemctl-health-failed"
: > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account unkacct --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@unkacct.service: FAILED — the verify run failed (exit 1); the timer's armed state could not be determined, so whether further checks are scheduled is unknown"* \
    && "$e84o" == *"  fix: check whether the timer is enabled: systemctl is-enabled egresslock-verify@unkacct.timer"* \
    && "$e84o" == *"  fix: if it is not enabled, re-arm: sudo egresslock-setup init --account unkacct --enable"* \
    && "$e84o" == *"PROBLEM: timer: armed state unknown (egresslock-verify@unkacct.timer)"* \
    && "$e84o" != *"the timer is not enabled"* \
    && "$e84o" != *"timer: not enabled"* ]] \
    && e84 pass || e84 fail "unanswered armed-state probe is a named unknown, never not-enabled (rc=$e84_rc, out: $e84o)"
e84clean

# 3i. EGL-345 (R2): is-enabled answers `enabled` but the ActiveState
#     lookup fails -> never the armed OK; the row names the unknown
#     running state and gives the status/check path.
printf 'enabled\n' > "$STATE/systemctl-is-enabled"
: > "$STATE/systemctl-show-fail-ActiveState"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$SKIT" --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: timer: enabled but its running state is unknown (egresslock-verify@uctx.timer)"* \
    && "$e84o" == *"  fix: sudo systemctl status egresslock-verify@uctx.timer"* \
    && "$e84o" == *"  check: sudo egresslock-setup doctor --account uctx"* \
    && "$e84o" != *"OK: timer: enabled"* ]] \
    && e84 pass || e84 fail "failed ActiveState probe is a named unknown, never armed OK (rc=$e84_rc, out: $e84o)"
rm -f "$STATE/systemctl-is-enabled" "$STATE/systemctl-show-fail-ActiveState"

# 3i-b. EGL-345 (R4): the ActiveState lookup ANSWERS but prints nothing.
#     ActiveState has no valid empty value, so rc 0 + empty output is a
#     probe that did not establish the state — never the armed OK. The
#     mock defaults ActiveState to `active`; this fixture is explicitly
#     empty to pin the empty-answer degrade.
printf 'enabled\n' > "$STATE/systemctl-is-enabled"
: > "$STATE/systemctl-show-ActiveState.egresslock-verify@uctx.timer"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$SKIT" --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: timer: enabled but its running state is unknown (egresslock-verify@uctx.timer)"* \
    && "$e84o" == *"  fix: sudo systemctl status egresslock-verify@uctx.timer"* \
    && "$e84o" == *"  check: sudo egresslock-setup doctor --account uctx"* \
    && "$e84o" != *"OK: timer: enabled"* ]] \
    && e84 pass || e84 fail "empty ActiveState answer is a named unknown, never armed OK (rc=$e84_rc, out: $e84o)"
rm -f "$STATE/systemctl-is-enabled" "$STATE/systemctl-show-ActiveState.egresslock-verify@uctx.timer"

# 3j. EGL-345 (R2 minor, R4): an `indirect` timer (enabled only
#     through another unit's Also=/alias) is deliberately NOT the
#     not-enableable template-missing class — the template is present.
#     It is a named unknown armed state (the raw state is shown) with
#     the clear/restart path, no journal, never a template claim.
printf 'indirect\n' > "$STATE/systemctl-is-enabled"
printf 'egresslock-verify@itmr.timer\n' > "$STATE/systemctl-health-failed"
: > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account itmr --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@itmr.timer: FAILED — the timer is in a failed state (armed state unknown: indirect)"* \
    && "$e84o" == *"  fix: sudo systemctl reset-failed egresslock-verify@itmr.timer"* \
    && "$e84o" == *"  fix: sudo systemctl restart egresslock-verify@itmr.timer"* \
    && "$e84o" != *"the unit template is missing or corrupt"* \
    && "$e84o" != *"reinstall the channel that owns the verify unit templates"* \
    && "$e84o" != *"inspect:"* && "$e84o" != *"OK: timer: enabled"* ]] \
    && e84 pass || e84 fail "indirect timer: named unknown, never a template claim (rc=$e84_rc, out: $e84o)"
e84clean

# 3j-b. EGL-345 (R4): a failed service whose timer is `indirect` must
#     not assert "the timer is not enabled" — the armed state was not
#     established. Same named-unknown service row as the empty answer;
#     the timer's failed row owns the re-arm.
printf 'indirect\n' > "$STATE/systemctl-is-enabled"
printf '1\n' > "$STATE/systemctl-mainstatus"
printf 'egresslock-verify@itmr2.service\negresslock-verify@itmr2.timer\n' > "$STATE/systemctl-health-failed"
: > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account itmr2 --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@itmr2.timer: FAILED — the timer is in a failed state (armed state unknown: indirect)"* \
    && "$e84o" == *"PROBLEM: egresslock-verify@itmr2.service: FAILED — the verify run failed (exit 1); the timer's armed state could not be determined, so whether further checks are scheduled is unknown"* \
    && "$e84o" == *"  fix: re-arm the timer — see its FAILED row above for the exact command"* \
    && "$e84o" == *"  inspect: sudo journalctl -u egresslock-verify@itmr2.service -n 20"* \
    && "$e84o" != *"the timer is not enabled"* \
    && "$e84o" != *"OK: timer: enabled"* ]] \
    && e84 pass || e84 fail "service + indirect timer: named unknown, never not-enabled (rc=$e84_rc, out: $e84o)"
e84clean

# 3j-c. EGL-345 (R4): kit_check_timer for an `indirect` timer names the
#     unknown armed state with a check — never "not enabled", never the
#     armed OK, and no reinstall claim.
printf 'indirect\n' > "$STATE/systemctl-is-enabled"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account itmr3 --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: timer: armed state unknown (egresslock-verify@itmr3.timer)"* \
    && "$e84o" == *"  fix: check the timer state: systemctl is-enabled egresslock-verify@itmr3.timer"* \
    && "$e84o" != *"PROBLEM: timer: not enabled"* \
    && "$e84o" != *"reinstall the channel that owns the verify unit templates"* \
    && "$e84o" != *"OK: timer: enabled"* ]] \
    && e84 pass || e84 fail "kit_check_timer indirect: named unknown, never not-enabled/OK (rc=$e84_rc, out: $e84o)"
e84clean

# 3k. EGL-345 (R2): a failed timer whose armed-state probe did not
#     answer names the unknown state, not enabled/disabled, and prints
#     only the generic clear/restart path (no journal claim).
: > "$STATE/systemctl-is-enabled"
printf 'egresslock-verify@unktmr.timer\n' > "$STATE/systemctl-health-failed"
: > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account unktmr --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 \
    && "$e84o" == *"PROBLEM: egresslock-verify@unktmr.timer: FAILED — the timer is in a failed state (armed state unknown)"* \
    && "$e84o" == *"  fix: sudo systemctl reset-failed egresslock-verify@unktmr.timer"* \
    && "$e84o" == *"  fix: sudo systemctl restart egresslock-verify@unktmr.timer"* \
    && "$e84o" != *"FAILED and not enabled"* && "$e84o" != *"FAILED and masked"* ]] \
    && e84 pass || e84 fail "unanswered timer armed state is a named unknown (rc=$e84_rc, out: $e84o)"
e84clean

# 4. Shadow: an /etc fragment overriding the deb's /usr/lib unit — both
#    paths named, rc 1 (EGL-83 incident shape; the deb copy is a fixture
#    via EGRESSLOCK_DEB_UNIT_DIR, the /etc path is only a mock answer).
mkdir -p "$e84d/debunits"
: > "$e84d/debunits/egresslock-verify@.service"
printf '/etc/systemd/system/egresslock-verify@.service\n' > "$STATE/systemctl-fragpath"
e84o="$(env EGRESSLOCK_UNIT_DIR="$e84d/units" EGRESSLOCK_DEB_UNIT_DIR="$e84d/debunits" \
    "$SKIT" --prefix "$e84d/prefix" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: verify unit: SHADOWED — systemd loads /etc/systemd/system/egresslock-verify@.service, not the deb's $e84d/debunits/egresslock-verify@.service"* \
    && "$e84o" != *"ExecStart missing"* ]] \
    && e84 pass || e84 fail "shadow row names both paths rc 1 (rc=$e84_rc, out: $e84o)"
rm -f "$STATE/systemctl-fragpath"

# 4a. Shadow fix, state-aware (prefix kit LIVE): the /etc fragment's
#     ExecStart dir carries kit markers and is not the deb libdir -> the
#     fix names removing the prefix kit (no .deb reinstall), not a
#     blanket "uninstall + reinstall". EGRESSLOCK_ETC_UNIT_DIR mocks the
#     /etc load-precedence path so the shadow gate is reachable
#     hermetically (no real /etc write).
mkdir -p "$e84d/etcmock"
printf '#!/usr/bin/env bash\nExecStart=%s/egresslock-verify\n' "$e84d/prefix" > "$e84d/etcmock/egresslock-verify@.service"
printf '%s\n' "$e84d/etcmock/egresslock-verify@.service" > "$STATE/systemctl-fragpath"
e84o="$(env EGRESSLOCK_UNIT_DIR="$e84d/units" EGRESSLOCK_DEB_UNIT_DIR="$e84d/debunits" \
    EGRESSLOCK_ETC_UNIT_DIR="$e84d/etcmock" \
    "$SKIT" --prefix "$e84d/prefix" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: verify unit: SHADOWED"* \
    && "$e84o" == *"uninstall-kit.sh --prefix $e84d/prefix"* \
    && "$e84o" == *"no reinstall"* ]] \
    && e84 pass || e84 fail "shadow fix (prefix kit live) names uninstall-kit, no reinstall (rc=$e84_rc, out: $e84o)"
# 4b. Shadow fix, deb-copy edge: the /etc fragment's ExecStart lives in
#     the deb libdir itself (an /etc copy of the deb unit). Markers
#     exist there, but it IS the deb libdir -> must take the stale-rm
#     branch, never "remove the prefix kit at <deb libdir>".
mkdir -p "$e84d/egresslock"; : > "$e84d/egresslock/VERSION"
printf '#!/usr/bin/env bash\nExecStart=%s/egresslock/egresslock-verify\n' "$e84d" > "$e84d/etcmock/egresslock-verify@.service"
e84o="$(env EGRESSLOCK_UNIT_DIR="$e84d/units" EGRESSLOCK_DEB_UNIT_DIR="$e84d/debunits" \
    EGRESSLOCK_ETC_UNIT_DIR="$e84d/etcmock" \
    "$SKIT" --prefix "$e84d/prefix" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: verify unit: SHADOWED"* \
    && "$e84o" == *"stale /etc templates"* \
    && "$e84o" != *"uninstall-kit.sh --prefix $e84d/egresslock"* ]] \
    && e84 pass || e84 fail "shadow fix (deb-libdir ExecStart) takes the stale-rm branch (rc=$e84_rc, out: $e84o)"
rm -f "$STATE/systemctl-fragpath"

# 5. ExecStart target missing/not executable (the uninstalled-prefix
#    case): the mock resolves the fragment to a fixture file whose
#    ExecStart points at a nonexistent binary.
printf '#!/usr/bin/env bash\nExecStart=/opt/egresslock/egresslock-verify\n' > "$e84d/faketmpl"
printf '%s\n' "$e84d/faketmpl" > "$STATE/systemctl-fragpath"
e84o="$(e84run --doctor)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: verify unit: ExecStart target missing/not executable: /opt/egresslock/egresslock-verify"* ]] \
    && e84 pass || e84 fail "missing ExecStart target row rc 1 (rc=$e84_rc, out: $e84o)"
# ... and a template with no ExecStart at all: the fix is channel-aware
#     (R4: names the reinstall for the channel that owns the file).
printf '#!/usr/bin/env bash\nDescription=no exec\n' > "$e84d/faketmpl2"
printf '%s\n' "$e84d/faketmpl2" > "$STATE/systemctl-fragpath"
e84o="$(e84run --doctor)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: verify unit: ExecStart missing in $e84d/faketmpl2"* \
    && "$e84o" == *"reinstall the channel that owns it"* ]] \
    && e84 pass || e84 fail "ExecStart-less template row rc 1 (rc=$e84_rc, out: $e84o)"
e84clean

# 6. Account instance probed even when the listing is empty: the
#    is-failed fixture marks every probed unit failed (203 status).
#    EGL-201: the sweep is empty -> M8 speaks (no accounts enumerated);
#    the probe row drops the `verify unit` head (M1).
printf '203\n' > "$STATE/systemctl-mainstatus"
printf 'failed\n' > /dev/null   # (marker below drives is-failed)
: > "$STATE/systemctl-health-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account e84acct --conf "$e84d/nosuch.conf" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: egresslock-verify@e84acct.service: FAILED"* \
    && "$e84o" != *"PROBLEM: verify unit"* \
    && "$e84o" == *"inspect: sudo journalctl -u egresslock-verify@e84acct.service -n 20"* ]] \
    && e84 pass || e84 fail "account instance is-failed row rc 1 (rc=$e84_rc, out: $e84o)"
# 6b. Dedup: a unit already reported by the sweep is not reported twice
#     by the account probe.
printf 'egresslock-verify@e84acct.service loaded failed running\n' > "$STATE/systemctl-list-units"
printf '● egresslock-verify@e84acct.service loaded failed running\n' > "$STATE/systemctl-list-units-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e84d/home" \
    EGRESSLOCK_UNIT_DIR="$e84d/units" \
    "$SKIT" --prefix "$e84d/prefix" --account e84acct --conf "$e84d/nosuch.conf" --doctor 2>&1)"
[[ "$(grep -c 'PROBLEM: egresslock-verify@e84acct.service: FAILED' <<<"$e84o")" == 1 ]] \
    && e84 pass || e84 fail "sweep+account dedup (out: $e84o)"
e84clean

# 7. Dangling timer enablement: a wants symlink whose template is gone
#    -> rc 1.
mkdir -p "$e84d/units/timers.target.wants"
ln -s "$e84d/units/egresslock-verify@ghost.timer" "$e84d/units/timers.target.wants/egresslock-verify@ghost.timer"
e84o="$(e84run --doctor)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: verify timer: DANGLING enablement — $e84d/units/timers.target.wants/egresslock-verify@ghost.timer"* ]] \
    && e84 pass || e84 fail "dangling wants row rc 1 (rc=$e84_rc, out: $e84o)"
rm -rf "$e84d/units/timers.target.wants"

# 7b. EGL-314: a leftover PRE-RENAME dangling enablement (the rc-neutral
#     pre-rename arm is gone) is the same named PROBLEM at rc 1. Clean
#     sweep fixture -> the run must produce EXACTLY one PROBLEM row, and
#     the row must name the pre-rename path: an unrelated failure cannot
#     satisfy this check for the wrong reason.
mkdir -p "$e84d/units/timers.target.wants"
ln -s "$e84d/units/agent-network-verify@legacy.timer" "$e84d/units/timers.target.wants/agent-network-verify@legacy.timer"
e84o="$(e84run --doctor)"; e84_rc=$?
e84prob="$(printf '%s\n' "$e84o" | grep -c '^PROBLEM: ' || :)"
[[ "$e84_rc" == 1 && "$e84prob" == 1 \
    && "$e84o" == *"PROBLEM: verify timer: DANGLING enablement — $e84d/units/timers.target.wants/agent-network-verify@legacy.timer"* ]] \
    && e84 pass || e84 fail "pre-rename dangling wants row rc 1, exactly one PROBLEM (rc=$e84_rc, problems=$e84prob, out: $e84o)"
rm -rf "$e84d/units/timers.target.wants"

# 8. No usable systemctl -> named skip, rc-neutral (D5). EGL-201:
#    the enumeration/summary are silent too (the named skip spoke; no
#    M7 inventory, no M9 summary).
e84o="$(env EGRESSLOCK_SYSTEMCTL=/nonexistent/systemctl \
    EGRESSLOCK_UNIT_DIR="$e84d/units" "$SKIT" --prefix "$e84d/prefix" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 0 && "$e84o" == *"NOTE: verify units: skipped (systemctl not found)"* \
    && "$e84o" != *"no accounts have"* && "$e84o" != *"are set up for"* \
    && "$e84o" != *"services healthy"* ]] \
    && e84 pass || e84 fail "no-systemctl named skip rc-neutral (rc=$e84_rc, out: $e84o)"

# 9. Templates missing from BOTH unit dirs (explicit empty hooks): the
#    fix line must name both channels — a deb-only host must not be
#    sent to install-kit.sh alone, which refuses on a co-installed deb.
e84nounits="$e84d/nounits"; mkdir -p "$e84nounits/deb"
e84o="$(env EGRESSLOCK_UNIT_DIR="$e84nounits" EGRESSLOCK_DEB_UNIT_DIR="$e84nounits/deb" \
    "$SKIT" --prefix "$e84d/prefix" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: unit templates: MISSING"* \
    && "$e84o" == *".deb hosts: reinstall the package"* \
    && "$e84o" == *"re-run install-kit.sh"* ]] \
    && e84 pass || e84 fail "missing templates fix names both channels (rc=$e84_rc, out: $e84o)"

# 9b. (R3 partial shape) only the service template present: a PARTIAL
#     row naming both names, rc 1 — not the blanket MISSING text.
e84partial="$e84d/partial"; mkdir -p "$e84partial"
sed "s|__EGRESSLOCK_PREFIX__|$e84d/prefix|g" "$TREE_ROOT/systemd/egresslock-verify@.service" \
    > "$e84partial/egresslock-verify@.service"
e84o="$(env EGRESSLOCK_UNIT_DIR="$e84partial" "$SKIT" --prefix "$e84d/prefix" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: unit templates: PARTIAL"* \
    && "$e84o" == *"service: $e84partial"* && "$e84o" == *"timer: MISSING"* \
    && "$e84o" == *"installs both"* ]] \
    && e84 pass || e84 fail "partial template row rc 1 (rc=$e84_rc, out: $e84o)"

# 10. (EGL-302-D2) healthy account slice + ANOTHER account's failed unit:
#     the unit is NOT printed — out-of-slice units are suppressed under
#     --account and rc stays neutral (driven only by the invoked slice).
#     Fixtures come from the e38/e55 block ($e38p engine, $UNITS). The plain
#     host sweep is the reporting surface for these units.
printf '● egresslock-verify@otheracct.service loaded failed running\n' > "$STATE/systemctl-list-units"
printf '203\n' > "$STATE/systemctl-mainstatus"
printf 'egresslock-verify@other*\n' > "$STATE/systemctl-health-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$SKIT" --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 0 && "$e84o" != *"out-of-account"* \
    && "$e84o" != *"egresslock-verify@otheracct"* \
    && "$e84o" != *"rc unaffected"* ]] \
    && e84 pass || e84 fail "out-of-slice unit suppressed under --account, rc-neutral (rc=$e84_rc, out: $e84o)"
# 10b. The account's OWN failed unit still drives rc 1 (its row is the
#      plain in-slice M1 form, not the out-of-account label).
printf 'egresslock-verify@uctx*\n' > "$STATE/systemctl-health-failed"
e84o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$SKIT" --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e84_rc=$?
own_row="$(grep 'PROBLEM: egresslock-verify@uctx.service: FAILED' <<<"$e84o" | head -1)"
[[ "$e84_rc" == 1 && "$own_row" == *"egresslock-verify@uctx.service: FAILED"* \
    && "$own_row" != *"out-of-account"* ]] \
    && e84 pass || e84 fail "own-account failed unit keeps rc 1 (rc=$e84_rc, out: $e84o)"
e84clean

# 11. (R3 sibling + R5) timer-template shadow: an /etc timer template
#     whose content differs from the deb's timer is a SHADOWED row, rc 1,
#     disclosed inspect-first (never a blind rm); an IDENTICAL copy is
#     benign — no row, rc 0 (postinst cleans identical copies).
: > "$e84d/debunits/egresslock-verify@.timer"
printf 'OnCalendar=hourly\n' > "$e84d/etcmock/egresslock-verify@.timer"
printf '%s\n' "$e84d/etcmock/egresslock-verify@.timer" > "$STATE/systemctl-fragpath-timer"
e84o="$(env EGRESSLOCK_UNIT_DIR="$e84d/units" EGRESSLOCK_DEB_UNIT_DIR="$e84d/debunits" \
    EGRESSLOCK_ETC_UNIT_DIR="$e84d/etcmock" \
    "$SKIT" --prefix "$e84d/prefix" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: verify timer template: SHADOWED — systemd loads $e84d/etcmock/egresslock-verify@.timer"* \
    && "$e84o" == *"inspect it before removing anything"* ]] \
    && e84 pass || e84 fail "timer-template shadow row rc 1 (rc=$e84_rc, out: $e84o)"
# 11b. Identical copy of the deb timer: stale product copy — benign, no row.
: > "$e84d/etcmock/egresslock-verify@.timer"
e84o="$(env EGRESSLOCK_UNIT_DIR="$e84d/units" EGRESSLOCK_DEB_UNIT_DIR="$e84d/debunits" \
    EGRESSLOCK_ETC_UNIT_DIR="$e84d/etcmock" \
    "$SKIT" --prefix "$e84d/prefix" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 0 && "$e84o" != *"timer template: SHADOWED"* ]] \
    && e84 pass || e84 fail "identical /etc timer copy is benign (rc=$e84_rc, out: $e84o)"
rm -f "$STATE/systemctl-fragpath-timer"

# 12. (R5) unknown-shape /etc service shadow: ExecStart outside any kit
#     dir, no markers -> the fix discloses and has the operator inspect;
#     it must NOT prescribe the marker-shaped routes (no prefix-kit
#     removal, no blanket stale-rm).
printf '#!/usr/bin/env bash\nExecStart=/usr/local/bin/not-ours-verify\n' > "$e84d/etcmock/egresslock-verify@foreign.service"
printf '%s\n' "$e84d/etcmock/egresslock-verify@foreign.service" > "$STATE/systemctl-fragpath"
e84o="$(env EGRESSLOCK_UNIT_DIR="$e84d/units" EGRESSLOCK_DEB_UNIT_DIR="$e84d/debunits" \
    EGRESSLOCK_ETC_UNIT_DIR="$e84d/etcmock" \
    "$SKIT" --prefix "$e84d/prefix" --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: verify unit: SHADOWED — systemd loads $e84d/etcmock/egresslock-verify@foreign.service"* \
    && "$e84o" == *"does not look like an egresslock product template"* \
    && "$e84o" != *"uninstall-kit.sh --prefix"* && "$e84o" != *"stale /etc templates only"* ]] \
    && e84 pass || e84 fail "unknown-shape shadow keeps the file, discloses (rc=$e84_rc, out: $e84o)"
e84clean

# 12b. (R2 armed-but-stopped) is-enabled says `enabled` but the timer is
#      not active: that is not an armed timer — PROBLEM + the one start
#      command, never a contradicting OK row.
printf 'enabled\n' > "$STATE/systemctl-is-enabled"
printf 'inactive\n' > "$STATE/systemctl-show-ActiveState.egresslock-verify@uctx.timer"
e84o="$(env ARCMOCK_LINGER_ANSWER=no EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$SKIT" --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: timer: enabled but not running (egresslock-verify@uctx.timer)"* \
    && "$e84o" == *"fix: sudo systemctl start egresslock-verify@uctx.timer"* \
    && "$e84o" != *"OK: timer: enabled"* ]] \
    && e84 pass || e84 fail "enabled-but-stopped timer is a PROBLEM, not OK (rc=$e84_rc, out: $e84o)"
rm -f "$STATE/systemctl-is-enabled" "$STATE/systemctl-show-ActiveState.egresslock-verify@uctx.timer"

# 13. (R4 runnable fix) the timer-not-enabled arm command carries the
#     conf/profile the reporting invocation already holds — a bare
#     --enable re-run would exit 2 on the missing --conf. EGL-201: the
#     timer/linger PROBLEM rows name the unit/account (M10/M11).
: > "$STATE/systemctl-timer-off"
e84o="$(env ARCMOCK_LINGER_ANSWER=no EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e38h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    "$SKIT" --prefix "$e38p" --account uctx --conf "$STATE/e38/site.conf" --profile p1 --doctor 2>&1)"; e84_rc=$?
[[ "$e84_rc" == 1 && "$e84o" == *"PROBLEM: timer: not enabled (egresslock-verify@uctx.timer)"* \
    && "$e84o" == *"fix: sudo egresslock-setup init --account uctx --profile p1 --enable"* \
    && "$e84o" == *"PROBLEM: linger: off (account uctx)"* ]] \
    && e84 pass || e84 fail "timer fix line is runnable (--conf/--profile); M10/M11 rows (rc=$e84_rc, out: $e84o)"
rm -f "$STATE/systemctl-timer-off"

# 14. (R1 named skip) DELETED per EGL-270 P3 (candidate 1): the
#     conf-parse-failed named-skip row was verbatim-duplicated by
#     egl55 #5 (same bad.conf fixture shape, same rc/message asserts) —
#     egl55 owns the row; no count-enabled property was unique here.

section_end egl84

# --- EGL-65: artifact hygiene — tarball excludes the internal
#     bug-report drafts; the fleet grep catches the widened names; the
#     private publisher never joins its own stage; the product tree is
#     scrubbed. ----------------------------------------------------------
section_begin egl65 "EGL-65 artifact hygiene"
e65() { assert "$@"; }
p65="$STATE/egl65"; rm -rf "$p65"; mkdir -p "$p65/kit"
(cd "$TREE_ROOT" && tar -cf - --exclude=./.git --exclude='./packaging/*.deb' --exclude='./packaging/*.tar.gz' .) \
    | tar -xf - -C "$p65/kit"
printf '# security policy (staged fixture for the snapshot gate)\n' > "$p65/kit/SECURITY.md"

# 1. (D1) the tarball excludes the internal bug-report drafts; docs
#    otherwise ship. EGL-107-D1: skips with the producer on the
#    extracted kit.
if [[ "$HAVE_BUILD_TARBALL" == 1 ]]; then
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
else
    skip "$PKG_SKIP_TAG" "EGL-65 tarball listing asserts — packaging/build-tarball.sh is not on this tree (extracted kit)"
fi

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
    skip "snapshot-public.sh absent" "EGL-65 widened-fleet-grep dry-runs — packaging/snapshot-public.sh not on the public tree (EGL-74-D1)"
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

section_end egl65

# --- EGL-287: setup verb grammar — summary/pages, aliases, conflicts -----
# P1/P2: the four summary surfaces (-h, --help, bare, help) are byte-equal,
# rc 0, <= 40 lines, ID-free, and bare of unadorned --apparmor (EGL-39);
# every help topic renders rc 0 and equals `<verb> --help` (apparmor too —
# help wins); error edges (unknown topic, extra token, help help, bare
# apparmor) are rc 2 with the named message + summary on stderr; help is
# rootless/config-free. D2 aliases are the legacy code: --doctor == doctor,
# legacy flag bundle == init (same rc/output/unit.env); a legacy mode flag
# beside a verb is a named rc 2 usage error.
section_begin egl287 "EGL-287 setup verb grammar"
eg287() { assert "$@"; }

# 1. Summary surfaces.
s287_summary="$("$SKIT" -h 2>/dev/null)"; s287_rc=$?
[[ "$s287_rc" == 0 ]] \
    && eg287 pass || eg287 fail "-h rc 0 (rc=$s287_rc)"
[[ "$(wc -l <<<"$s287_summary")" -le 40 ]] \
    && eg287 pass || eg287 fail "summary <= 40 lines (got $(wc -l <<<"$s287_summary"))"
for s287_a in --help help; do
    o="$("$SKIT" "$s287_a" 2>/dev/null)"; rc=$?
    [[ "$rc" == 0 && "$o" == "$s287_summary" ]] \
        && eg287 pass || eg287 fail "$s287_a == -h byte-equal rc 0 (rc=$rc)"
done
o="$("$SKIT" 2>/dev/null)"; rc=$?
[[ "$rc" == 0 && "$o" == "$s287_summary" ]] \
    && eg287 pass || eg287 fail "bare invocation = the summary, rc 0 (rc=$rc)"
if grep -qE "$k59_id_re" <<<"$s287_summary"; then
    eg287 fail "summary leaks ticket/process refs"
else
    eg287 pass
fi
if grep -qE '(^|[ (])--apparmor([^a-z-]|$)' <<<"$s287_summary"; then
    eg287 fail "summary carries a bare --apparmor"
else
    eg287 pass
fi

# 2. Verb/topic pages.
for t287 in init doctor build-gateway apparmor env; do
    o="$("$SKIT" help "$t287" 2>/dev/null)"; rc=$?
    [[ "$rc" == 0 && -n "$o" ]] \
        && eg287 pass || eg287 fail "help $t287 rc 0 non-empty (rc=$rc)"
    if grep -qE "$k59_id_re" <<<"$o"; then
        eg287 fail "help $t287 leaks ticket/process refs"
    else
        eg287 pass
    fi
    if grep -qE '(^|[ (])--apparmor([^a-z-]|$)' <<<"$o"; then
        eg287 fail "help $t287 carries a bare --apparmor"
    else
        eg287 pass
    fi
done
for t287 in init doctor build-gateway apparmor; do
    o="$("$SKIT" "$t287" --help 2>/dev/null)"; rc=$?
    [[ "$rc" == 0 && "$o" == "$("$SKIT" help "$t287" 2>/dev/null)" ]] \
        && eg287 pass || eg287 fail "$t287 --help == help $t287 (rc=$rc)"
done
o="$(env -u EGRESSLOCK_KIT_ALLOW_NON_ROOT "$SKIT" apparmor --help 2>/dev/null)"; rc=$?
[[ "$rc" == 0 && "$o" == "$("$SKIT" help apparmor 2>/dev/null)" ]] \
    && eg287 pass || eg287 fail "apparmor --help = the apparmor page, rc 0, rootless (rc=$rc)"

# 3. Typed edges: summary on stderr, named messages, rc 2.
o="$("$SKIT" help bogus 2>/dev/null)"; rc=$?
o2="$("$SKIT" help bogus 2>&1 1>/dev/null)"
[[ "$rc" == 2 && -z "$o" && "$o2" == *"Error: unknown help topic 'bogus'."* && "$o2" == *"Usage:"* ]] \
    && eg287 pass || eg287 fail "help bogus rc 2 named + summary on stderr (rc=$rc, out: $o2)"
o="$("$SKIT" help a b 2>/dev/null)"; rc=$?
o2="$("$SKIT" help a b 2>&1 1>/dev/null)"
[[ "$rc" == 2 && "$o2" == *"Error: egresslock-setup help takes at most one topic."* && "$o2" == *"Usage:"* ]] \
    && eg287 pass || eg287 fail "help a b rc 2 takes-at-most-one (rc=$rc, out: $o2)"
o="$("$SKIT" help help 2>/dev/null)"; rc=$?
o2="$("$SKIT" help help 2>&1 1>/dev/null)"
[[ "$rc" == 2 && "$o2" == *"Error: unknown help topic 'help'."* ]] \
    && eg287 pass || eg287 fail "help help rc 2 unknown topic (rc=$rc, out: $o2)"
o="$("$SKIT" help --help 2>/dev/null)"; rc=$?
o2="$("$SKIT" help --help 2>&1 1>/dev/null)"
[[ "$rc" == 2 && "$o2" == *"Error: unknown help topic '--help'."* ]] \
    && eg287 pass || eg287 fail "help --help rc 2 unknown topic (rc=$rc, out: $o2)"
o="$("$SKIT" apparmor 2>/dev/null)"; rc=$?
o2="$("$SKIT" apparmor 2>&1 1>/dev/null)"
[[ "$rc" == 2 && "$o2" == *"apparmor needs a sub-verb: add, remove, or check"* && "$o2" == *"Usage:"* ]] \
    && eg287 pass || eg287 fail "bare apparmor rc 2 named sub-verb list (rc=$rc, out: $o2)"

# 4. Alias equivalence (D2): the verbs run the same code path.
# 4a. doctor: same rc + output on a fixed fixture (host slice, mock
#     unit dir).
s287_doc="$STATE/egl287/docx"; rm -rf "$s287_doc"; mkdir -p "$s287_doc/units"
o1="$(env EGRESSLOCK_UNIT_DIR="$s287_doc/units" "$SKIT" --doctor --prefix "$SKITP" 2>&1)"; r1=$?
o2="$(env EGRESSLOCK_UNIT_DIR="$s287_doc/units" "$SKIT" doctor --prefix "$SKITP" 2>&1)"; r2=$?
[[ "$r1" == "$r2" && "$o1" == "$o2" ]] \
    && eg287 pass || eg287 fail "--doctor == doctor (rc $r1/$r2)"
# 4b. build-gateway (no engine at prefix): byte-equal failure shape.
s287_neng="$STATE/egl287/noeng"; mkdir -p "$s287_neng"
o1="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 "$SKIT" --build-gateway --prefix "$s287_neng" 2>&1)"; r1=$?
o2="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 "$SKIT" build-gateway --prefix "$s287_neng" 2>&1)"; r2=$?
[[ "$r1" == "$r2" && "$o1" == "$o2" ]] \
    && eg287 pass || eg287 fail "--build-gateway == build-gateway (rc $r1/$r2)"
# 4c. apparmor check (read-only host probe on the real container): the
#     verb form runs the same checker.
o1="$("$SKIT" --apparmor-check 2>&1)"; r1=$?
o2="$("$SKIT" apparmor check 2>&1)"; r2=$?
[[ "$r1" == "$r2" && "$o1" == "$o2" ]] \
    && eg287 pass || eg287 fail "--apparmor-check == apparmor check (rc $r1/$r2)"
# 4d. init: the verb wires the same account state (unit.env) as the
#     legacy bundle, byte-equal output.
s287_i="$STATE/egl287/init"; rm -rf "$s287_i"
mkdir -p "$s287_i/prefix" "$s287_i/home/u287/.config/egresslock"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    EGRESSLOCK_PATH_BINDIR="$s287_i/prefix/wbin" EGRESSLOCK_PATH_SBINDIR="$s287_i/prefix/wsbin" \
    "$KIT" --prefix "$s287_i/prefix" >/dev/null 2>&1
printf 'profile p1 10.99.0.0/24\n    rule gateway-only\n    gateway 10.99.0.2 3128 p1-allowlist\n' > "$s287_i/site.conf"
printf '# starter\n' > "$s287_i/p1-allowlist"
s287_legen() { # <legacy|verb> <image-tag>
    local form="$1" tag="$2"
    if [[ "$form" == legacy ]]; then
        env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$s287_i/home/u287" \
            EGRESSLOCK_UNIT_DIR="$UNITS" EGRESSLOCK_GW_IMAGE="localhost/egresslock-gateway:$tag" \
            "$SKIT" --prefix "$s287_i/prefix" --account u287 --conf "$s287_i/site.conf" --profile p1 2>&1
    else
        env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$s287_i/home/u287" \
            EGRESSLOCK_UNIT_DIR="$UNITS" EGRESSLOCK_GW_IMAGE="localhost/egresslock-gateway:$tag" \
            "$SKIT" init --prefix "$s287_i/prefix" --account u287 --conf "$s287_i/site.conf" --profile p1 2>&1
    fi
}
: > "$STATE/systemctl.log"; : > "$STATE/loginctl.log"; : > "$STATE/buildlog"
o1="$(s287_legen legacy e287a)"; r1=$?
rm -f "$s287_i/home/u287/.config/egresslock/unit.env" \
      "$s287_i/home/u287/.config/egresslock/p1.conf" \
      "$s287_i/home/u287/.config/egresslock/p1-allowlist"
: > "$STATE/systemctl.log"; : > "$STATE/loginctl.log"; : > "$STATE/buildlog"
o2="$(s287_legen verb e287b)"; r2=$?
[[ "$(cat "$s287_i/home/u287/.config/egresslock/unit.env")" == "EGRESSLOCK_PROFILE=p1" ]] \
    && eg287 pass || eg287 fail "init verb wires unit.env (got: $(cat "$s287_i/home/u287/.config/egresslock/unit.env" 2>/dev/null))"
[[ "$r1" == "$r2" && "$o1" == "$o2" ]] \
    && eg287 pass || eg287 fail "init verb == legacy bundle (rc $r1/$r2; diff: $(diff <(printf '%s' "$o1") <(printf '%s' "$o2") >/dev/null 2>&1 || diff <(printf '%s' "$o1") <(printf '%s' "$o2") 2>&1 | head -3))"

# 5. Conflict refusal: a legacy mode flag beside a verb (rc 2, named).
o="$("$SKIT" init --doctor 2>/dev/null)"; rc=$?
o2="$("$SKIT" init --doctor 2>&1 1>/dev/null)"
[[ "$rc" == 2 && "$o2" == *"egresslock-setup: --doctor is a verb: run 'egresslock-setup doctor'"* ]] \
    && eg287 pass || eg287 fail "init --doctor rc 2 named (rc=$rc, out: $o2)"
o="$("$SKIT" doctor --apparmor-check 2>/dev/null)"; rc=$?
o2="$("$SKIT" doctor --apparmor-check 2>&1 1>/dev/null)"
[[ "$rc" == 2 && "$o2" == *"egresslock-setup: --apparmor-check is a verb: run 'egresslock-setup apparmor check'"* ]] \
    && eg287 pass || eg287 fail "doctor --apparmor-check rc 2 named (rc=$rc, out: $o2)"
o="$("$SKIT" apparmor add --apparmor-check 2>/dev/null)"; rc=$?
[[ "$rc" == 2 ]] \
    && eg287 pass || eg287 fail "apparmor add + legacy --apparmor-check refused (rc=$rc)"
o="$("$SKIT" build-gateway --build-gateway 2>/dev/null)"; rc=$?
o2="$("$SKIT" build-gateway --build-gateway 2>&1 1>/dev/null)"
[[ "$rc" == 2 && "$o2" == *"egresslock-setup: --build-gateway is a verb: run 'egresslock-setup build-gateway'"* ]] \
    && eg287 pass || eg287 fail "build-gateway + legacy flag refused (rc=$rc, out: $o2)"
o="$("$SKIT" init --build-gateway 2>/dev/null)"; rc=$?
o2="$("$SKIT" init --build-gateway 2>&1 1>/dev/null)"
[[ "$rc" == 2 && "$o2" == *"egresslock-setup: --build-gateway is a verb: run 'egresslock-setup build-gateway'"* ]] \
    && eg287 pass || eg287 fail "init --build-gateway refused (rc=$rc, out: $o2)"

section_end egl287

# --- EGL-200: setup console output ------------------------------------------
section_begin egl200 "EGL-200 setup console output"
e200() { assert "$@"; }
# Self-contained fixture: deployed prefix, gateway conf + allowlist,
# single-profile no-gateway conf, one account home (e38 shape).
e200p="$STATE/egl200/prefix"
rm -rf "$STATE/egl200"; mkdir -p "$e200p"
env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_UNIT_DIR="$UNITS" \
    EGRESSLOCK_PATH_BINDIR="$e200p/wbin" EGRESSLOCK_PATH_SBINDIR="$e200p/wsbin" \
    "$KIT" --prefix "$e200p" >/dev/null 2>&1
[[ -f "$e200p/egresslock" && -f "$e200p/gateway/Containerfile" && -f "$e200p/examples/main.conf" ]] \
    && e200 pass || e200 fail "egl200 fixture: kit deployed to $e200p"
e200h="$STATE/egl200/home/actx"
mkdir -p "$e200h/.config/egresslock"
printf 'profile p1 10.99.7.0/24\n    rule gateway-only\n    gateway 10.99.7.2 3128 p1-allowlist\n' \
    > "$STATE/egl200/gw.conf"
printf '# starter\n' > "$STATE/egl200/p1-allowlist"
printf 'profile pa 10.99.8.0/24\n' > "$STATE/egl200/pa.conf"
e200_map() { grep -E '^[0-9]\) .* … (OK|SKIP|FAIL)$' <<<"$1"; }

# 1. First run, image missing, noisy stream enabled: the terminal shows
#    M8 and never the build stream; the stream lands in the build log.
: > "$STATE/build-noisy"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e200h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e200gw \
    $SKIT --prefix "$e200p" --account actx --conf "$STATE/egl200/gw.conf" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"egresslock-setup: building the gateway image — first run downloads the base image and packages; a few minutes. Build log: $e200h/.config/egresslock/gateway-build.log"* \
    && "$o" != *"MOCK-BUILD-OUTPUT"* ]] \
    && e200 pass || e200 fail "EGL-200 P3-C quiet build: M8 only, stream not on terminal (rc=$rc, out: $o)"
grep -q "MOCK-BUILD-OUTPUT" "$e200h/.config/egresslock/gateway-build.log" \
    && e200 pass || e200 fail "EGL-200 P3-C build stream captured in gateway-build.log (log: $(cat "$e200h/.config/egresslock/gateway-build.log" 2>/dev/null))"
# EGL-328 D8: --from imports p1 but does NOT choose named mode; a pathless
# init wires aggregate and names the first conf profile in the next block.
[[ "$o" == *"next steps (as the account):"* \
    && "$o" == *"  sudo -iu actx"* \
    && "$o" == *"  egresslock ensure p1"* \
    && "$o" == *"the scheduled check will verify every profile"* ]] \
    && e200 pass || e200 fail "EGL-200 M1(c)/M3: block + derived-profile wording (out: $o)"
rm -f "$STATE/build-noisy"

# 2. Image present re-run: the quiet path is skipped entirely.
: > "$STATE/buildlog"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e200h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e200gw \
    $SKIT --prefix "$e200p" --account actx --conf "$STATE/egl200/gw.conf" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"gateway image present"* && "$o" != *"building the gateway image"* ]] \
    && e200 pass || e200 fail "EGL-200 P3-C re-run: image present, no build line (rc=$rc, out: $o)"

# 3. Failing build: rc 1, step 5 FAIL, M9 names the log and its last
#    lines are shown (noisy marker feeds the log the tail prints).
: > "$STATE/build-noisy"; : > "$STATE/build-fails"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e200h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e200gw2 \
    $SKIT --prefix "$e200p" --account actx --conf "$STATE/egl200/gw.conf" 2>&1)"; rc=$?
rm -f "$STATE/build-fails"; rm -f "$STATE/build-noisy"
[[ "$rc" == 1 && "$(e200_map "$o" | tail -1)" == "5) gateway image … FAIL" \
    && "$o" == *"egresslock-setup: gateway image build failed; last lines of the build log ($e200h/.config/egresslock/gateway-build.log):"* \
    && "$o" == *"MOCK-BUILD-OUTPUT"* ]] \
    && e200 pass || e200 fail "EGL-200 P3-C build failure: M9 + tail shown (rc=$rc, map: $(e200_map "$o" | tr '\n' '|'))"

# 4. EGL-200 M2: named --profile keeps the operator wording, no
#    'verify mode:' label; single-profile conf (EGL-323: one profile
#    per conf), no gateway, no build.
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e200h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e200p" --account actx --conf "$STATE/egl200/pa.conf" --profile pa 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"egresslock-setup: the scheduled check will verify only profile 'pa'"* \
    && "$o" != *"verify mode:"* && "$o" == *"  egresslock ensure pa"* ]] \
    && e200 pass || e200 fail "EGL-200 M2: named scheduled-check wording (rc=$rc, out: $o)"

# 5. EGL-200 M1(c): a sweep-mode setup (--init-conf only: no --conf, so
#    no profile is derived) names the first profile from the step-1
#    list capture for the ensure hint.
e200h5="$STATE/egl200/home/sweep"
rm -rf "$e200h5"; mkdir -p "$e200h5"
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e200h5" \
    EGRESSLOCK_UNIT_DIR="$UNITS" EGRESSLOCK_GW_IMAGE=localhost/egresslock-gateway:e200gw \
    $SKIT --prefix "$e200p" --account actx --init-conf 2>&1)"; rc=$?
[[ "$rc" == 0 && "$o" == *"  egresslock ensure main"* \
    && "$o" == *"the scheduled check will verify every profile"* ]] \
    && e200 pass || e200 fail "EGL-200 M1(c): first-profile fallback from the list capture (rc=$rc, out: $o)"

# 6. EGL-325: --profile must match the source conf's profile; the
#    refusal is named before anything is installed (no stray conf).
o="$(env EGRESSLOCK_KIT_ALLOW_NON_ROOT=1 EGRESSLOCK_ACCOUNT_HOME="$e200h" \
    EGRESSLOCK_UNIT_DIR="$UNITS" \
    $SKIT --prefix "$e200p" --account actx --conf "$STATE/egl200/pa.conf" --profile nope 2>&1)"; rc=$?
[[ "$rc" == 2 && "$o" == *"--profile 'nope' does not match the source conf's profile 'pa'"* \
    && ! -e "$e200h/.config/egresslock/nope.conf" ]] \
    && e200 pass || e200 fail "EGL-325: --profile/source-profile mismatch refused (rc=$rc, out: $o)"

section_end egl200

echo
results_emit arc16
results_emit egl85
results_emit arc17
results_emit egl43
results_emit egl12
results_emit egl47
results_emit egl49
results_emit arc18
results_emit egl328
results_emit egl51
results_emit arc19
results_emit egl38
results_emit arc22
results_emit a39
results_emit arc72
results_emit arc14
results_emit arc20
results_emit arc23
results_emit arc70
results_emit arc69s
results_emit egl50
results_emit egl55
results_emit egl59
results_emit egl60
results_emit egl68
results_emit egl90
results_emit egl83
results_emit egl115
results_emit egl84
results_emit egl65
results_emit egl203
results_emit egl240
results_emit egl287
results_emit egl200
# EGL-184: the hand-maintained 31-term sums are replaced by the register
# (counted snapshots; no externals — every kit increment runs the funnels).
# Fail-closed completeness per EGL-184-D4; the TOTAL line keeps the
# EGL-99 skip count + tree-shape tag.
results_total
[[ "$total_fail" -eq 0 ]]
