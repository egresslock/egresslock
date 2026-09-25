# Changelog

All notable changes between egresslock releases. The public repository
ships without history (each release is a fresh snapshot tree), so this
file is the record of what changed since the previous release.

## 0.5.0 - 2026-09-24

> **Operator-important changes:**
>
> **Action required:**
> - **New dependency: `conntrack`.** The kit now requires the
>   `conntrack` package (used by `disallow-host` to sever revoked
>   direct flows immediately). Install it with the other requirements:
>   `sudo apt-get install -y podman netavark nftables conntrack`.
> - **Do NOT run workloads with `--network=container:<gateway>` or
>   `--network=host`.** Those network modes bypass the profile policy
>   (the container shares the gateway's netns or the host network and
>   can reach outside the allowlist). The threat model now names these
>   as operator obligations — attach workloads to the profile network
>   only.
> - **Run `egresslock ensure <profile>` once per profile that uses
>   `allow-host` after this upgrade.** `verify` now checks allow-host
>   pins against an ensure-time record; the record is written on the
>   first `ensure` after upgrading. Until then, `verify` fails closed
>   with a re-ensure hint. Profiles with no allow-host pins are
>   exempt — no record is needed and `verify` stays silent.
> - **Trailing-dot allowlist entries are rejected** (`name.` no longer
>   silently accepted). If you have such an entry, `allow`/`ensure`
>   will now fail closed with a named error — remove the trailing dot.
> - **IP-literal proxy requests are now denied, even when the IP's
>   reverse-DNS name is allowlisted.** The gateway no longer adopts
>   rDNS for IP-literal CONNECTs — the name allowlist only ever
>   matches hostnames, never IPs. Example: if you had
>   `curl -x http://gateway http://192.0.2.1:8080/` working because
>   `192.0.2.1` reverse-resolves to an allowlisted name, it is now
>   denied (403). To pin an address, use the address-pin mechanism:
>   `egresslock allow-host <profile> 192.0.2.1:8080`.
>
> **Behavior changes:**
> - **`disallow-host` now severs established direct flows at once.**
>   Revoking a pin previously left flows alive until conntrack expiry
>   (~5 days); now the mutator kills them immediately (and fails
>   loudly if it cannot prove severance). If you rely on a grace
>   window after revoking pins, note this change.
> - **After a reboot**, `verify` (and the drift timer) now report the
>   unpolicied state by name ("network exists but policy does not —
>   run: `egresslock ensure <profile>`") instead of failing
>   generically.

### Security

All items below are findings from the adversarial live-testing
program (tier-2 batteries), confirmed live, with the fix shipped in
this release. Severity per the finding record:

- **HIGH — cross-profile source spoof.** A co-located privileged
  sibling could no longer be used to route cross-profile traffic:
  saddr-keyed accepts are now scoped to the profile's own bridge (a
  packet arriving on another profile's bridge no longer matches), and
  a counted anti-spoof drop closes the cross-profile source-spoof
  path.
- **HIGH — rDNS relay through the gateway.** An attacker-controlled
  PTR record could relay TCP through the gateway when the
  IP-literal's reverse-DNS name matched an allowlisted entry; the
  generated `dstdomain` ACLs now carry `-n`, so the proxy never
  adopts rDNS for IP-literal requests.
- **HIGH — revoked pins kept serving established flows.**
  `disallow-host` left flows alive after revocation — a fail-open on
  the documented kill-switch: revoked pins kept serving existing
  flows until conntrack expiry (~5 days), invisible to a green
  `verify`. Revocation is now a real kill-switch: the mutator deletes
  the revoked destination's conntrack entries after the atomic
  ruleset swap and proves the data-path state is gone before printing
  `removed:`. Missing `conntrack` tooling aborts with nothing changed
  — never a silent lie.
- **HIGH — tampered allow-host pins passed verify.** An in-place
  chain edit rekeying a live pin's address went undetected (drift-warn
  only). `ensure` now records installed pin addresses, and `verify`
  fails closed with a named error when the live chain diverges from
  the record.
- **MEDIUM — policy silently absent after reboot.** A persisted
  profile network could carry no policy after reboot while `verify`
  failed generically. `verify` (and the drift timer) now name the
  stale-unpolicied state and point at `egresslock ensure <profile>`.

### Fixes

- **Trailing-dot allowlist entries** (e.g. `example.test.`) were
  accepted by the grammar but could never match — a silently dead
  allowlist line. They are now rejected with a named error.

### Added

- Documented as a first-class troubleshooting path: the `read-timeout`
  knob for long non-streaming calls (slow local inference), with a
  dedicated recipe and a rewritten, simpler troubleshooting page.

### Docs

- Threat model now names operator obligations for network modes
  (`--network=container:<gateway>`, `--network=host`) and narrows
  several earlier claims.
- Added local-LLM setup tips, including the `read-timeout` knob for
  long silent inference calls.

## 0.4.0 - 2026-09-21

### Security

- A co-located container holding elevated capabilities could bypass
  the egress policy by spoofing the gateway's source IP address. The
  gateway exemption is now bound to the gateway's MAC address as well,
  so the gateway IP alone no longer satisfies it.

### Fixes

- `ensure` on an already-converged profile no longer restarts gateways
  or severs proxied sessions — an unchanged profile is a no-op.
- First-time policy creation is now a single atomic nft transaction:
  no unprotected window between creating the policy and installing its
  rules.
- The drift-check timer now verifies all profiles in the account
  confdir, not just the wired one.
- `allow-host` with an unresolvable name fails with one clean error
  plus a remediation hint instead of raw nft output.

### Added

- New per-profile conf knob `read-timeout <seconds>` (default 900,
  always emitted) for long silent non-streaming calls through the
  proxy.
- Commands now disclose which config and profiles they resolved to on
  stderr — every time, including piped output.

### Kit

- Shipped systemd units carry generated-file/do-not-modify comments,
  and the deb installer discloses every systemd unit mutation it
  performs.

### Docs

- Threat-model updated with live adversarial-probe evidence; new
  host-service connectivity page.

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
