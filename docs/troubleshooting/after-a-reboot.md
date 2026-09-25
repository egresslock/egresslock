# After a host reboot the network looks fine but workloads are unprotected

## Symptom

After the host reboots:

- `podman network ls` still lists the profile network (e.g.
  `egresslock-main`), and
- `egresslock network main` / `egresslock proxy-env main` still
  succeed,

but a workload started with
`podman run --network="$(egresslock network main)"` has **no
egresslock policy**: direct traffic is not dropped and IPv6 is not
denied. The verify timer (default sweep mode) now fails named within
≤15 minutes (`Persistent=true`):

```text
verify: network exists but policy does not — run: egresslock ensure main
```

## Cause

The podman network **object** is stored on disk, so it survives the
reboot. The rootless netns and its nftables policy are volatile:
nothing holds the netns open after a reboot, and the first container
start recreates it fresh — without the egresslock table. Until someone
runs `egresslock ensure <profile>` again, the persisted network
object is unpolicied: it looks healthy, it is not.

## Fix

As the container-owner account, re-ensure the profile before starting
any workload:

```sh
egresslock ensure main
```

or use the kit launcher `egresslock-start`, which always ensures first
(fail-closed: if ensure fails, the daemon does not start). `ensure` is
idempotent: it recreates the anchor, reinstalls the policy, and
restarts the gateway in one non-disruptive pass.

## What the timer does (and does not) do

- The 15-minute `egresslock-verify@<account>.timer` (default sweep
  mode) fails named with `verify: network exists but policy does not
  — run: egresslock ensure <profile>` — a drift **signal**, not a
  repair. It never re-ensures by design.
- A named-mode wiring (`egresslock-setup --profile` at setup) fails
  the same named way on `verify <profile>`.
- If no profile is ensured **and** nothing is stale, the sweep stays
  silently green (exit 0): silence means "no profiles ensured and no
  stale leftovers".

## Links

- [network-not-found](network-not-found.md) — the complementary case:
  the network object is missing entirely.
- [verify-timer-signals](verify-timer-signals.md) — every timer line,
  healthy and failing.
- [who-runs-what](../reference/who-runs-what.md) — who runs the
  engine and the workloads (root never does).
