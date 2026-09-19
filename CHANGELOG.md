# Changelog

All notable changes between egresslock releases. The public repository
ships without history (each release is a fresh snapshot tree), so this
file is the record of what changed since the previous release.

## 0.3.0 - 2026-09-19

### Security

- First-create ordering hardening: starts the anchor before
  installing policy, creates the profile chain with its rules in one
  transaction, and installs policy before gateway startup. This
  removes the previous empty-chain and gateway-start exposure; the
  remaining bootstrap race before policy installation is tracked
  separately.
- Threat-model honesty pass: the docs now state plainly what the
  gateway does and does not defend against (DNS/egress enforcement
  is not host-compromise protection), instead of implying stronger
  isolation than is delivered.

### Fixes

- Uninstall hardening: the removal paths are constrained and the
  `--prefix` value is charset-validated, so a malformed prefix can
  no longer widen what gets deleted.
- Co-install guard: installing the `.deb` where an explicit-prefix
  deploy already owns the shared tree now fails closed with an
  explanation instead of silently shadowing it.

### Tests / packaging

- `egresslock-setup --doctor` gained verify-unit health rows: shadow
  detection for stray `/etc` unit fragments, ExecStart-target
  mismatch, failed instances, and timer wiring for the periodic
  re-verify service.
- Test-battery growth across the engine and kit suites; on the
  public tree the cases that need private-tree fixtures skip with a
  named `SKIP` line by design.

## 0.2.0 - 2026-09-16

### Tests / packaging

- Hermetic test battery: the suites no longer hang or read the real
  host (package database, `/usr/bin` guard, nftables, pasta,
  AppArmor status, user-namespace probes). The public tree runs the
  same harness, skipping private-tree fixtures by name.
- Bounded network-namespace probes: a wedged rootless-netns call is
  a named 5-second failure instead of an indefinite hang during
  ensure / verify / doctor; `timeout(1)` (coreutils) is required and
  named when missing.
- Explicit-prefix deploys fail closed instead of silently consuming
  a co-installed `.deb`'s shared tree.
- `EGRESSLOCK_UB_BIN` / `EGRESSLOCK_USERNS_SYSCTL` environment hooks
  for test harnesses — no-ops when unset.

## 0.1.1 - 2026-09-12

Tests-only hotfix: the shipped test suite invoked packaging and
internal files that are deliberately not published with the snapshot;
the affected cases now skip cleanly when those files are absent, so
`bash tests/run.sh` is green on the public tree. The version base
stayed `0.1.0` — this release exists as the corresponding public
snapshot commit only (no tag was minted).

## 0.1.0 - 2026-09-12

Initial release: the egresslock engine (per-profile nftables egress
policy, allowlist-driven, fail-closed by default), rootless Podman
gateway/anchor runtime, install/uninstall kit (`.deb` and
explicit-prefix paths), gateway container image, AppArmor profile,
systemd verify units and timer, and the mock test battery.
