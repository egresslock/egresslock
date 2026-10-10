# Container hardening baseline

This page answers one question: **what flags should a `podman run`
launcher carry when it starts a workload on an egresslock profile?**
The shipped recipes (the README's
[Recipes section](../../README.md#recipes)) apply this baseline; a
launcher you write should too.

Everything here is **operator-owned guidance, not kit enforcement**:
the kit ships no workload launcher, and the profile's nftables policy
is the egress boundary regardless. The flags below harden the
*workload* — capabilities, filesystem, identity — which the network
policy alone does not. The obligation list and its boundaries are
recorded in the [threat model](threat-model.md) (operator obligations,
invariant I5, threats T9 and T10).

## Layer 1 — always on, every workload

Every container on a profile network carries both of these, no
exceptions:

```
--cap-drop=all --security-opt=no-new-privileges
```

- `--cap-drop=all` drops the default capability set — in the tested
  rootless lane (Podman 5.4.2 configured defaults), a set that
  included neither `CAP_NET_ADMIN` nor `CAP_NET_RAW`. It drops
  defaults only: an explicit `--cap-add` passed alongside it is not
  neutralized, so do not rely on `--cap-drop=all` alone to deny a
  capability your launcher adds. The T9 add-address spoof needs
  `CAP_NET_ADMIN`, which that default set does not include; creating
  the tested `AF_PACKET`/`SOCK_RAW` socket under plain defaults
  returned `EPERM` in the tested lane (threat-model T9 row and
  launcher obligation).
- `--security-opt=no-new-privileges` prevents privilege escalation via
  setuid binaries inside the container.

## Layer 2 — when the recipe bind-mounts a host directory

If the launcher mounts a host directory into the container (for
example a persistent workspace), the workload's uid should be the
account's own uid, so files it writes on the mount stay owned by you —
and its `HOME` should live somewhere writable. The canonical shape:

```
--userns=keep-id \
--passwd-entry="$USER:x:$(id -u):$(id -g)::/tmp/home:/bin/sh" \
--env HOME=/tmp/home
```

- `--userns=keep-id` maps the container's user to your host uid: the
  bind mount needs no ownership dance, and the workload has no
  root-uid powers over host files.
- `--passwd-entry` puts that user in the container's passwd with home
  `/tmp/home`, so login-style tools (and anything that reads `getent`)
  see a real account.
- `--env HOME=/tmp/home` points `HOME` at the `/tmp` tmpfs added in
  layer 3, so login state (dotfiles, `~/.config`) is written there and
  dies with the container. A tool that requires its home directory to
  pre-exist gets `mkdir -p /tmp/home` before it starts.

If the deployed podman rejects `--passwd-entry` (older builds),
keep `--userns=keep-id --env HOME=/tmp/home` without the entry and say
so — a flag that does not exist is never shipped.

On recipes without a host bind mount this layer is **not** applied —
the workload stays image-root on purpose. See the exception rule
below.

## Layer 3 — when the rootfs is disposable

If nothing in the workload needs to write the container's own
filesystem (the interesting files go to the bind-mounted workspace or
a tmpfs), make the rootfs read-only:

```
--read-only --tmpfs /tmp --tmpfs /run
```

- `--read-only` turns the rootfs immutable: a compromised workload
  cannot plant a persistent file in it. `/tmp` and `/run` get tmpfs
  scratch space (writable, gone with the container).
- The bind-mounted workspace (layer 2) stays writable — `:rw` mounts
  are unaffected by `--read-only`.

**The exception rule — state it, never omit silently.** Some
workloads must write the container rootfs: the install/eval shells
(apt/npm installation paths, for example) write to image paths as uid
0. For those, `--read-only` and layer 2's keep-id are deliberately
**not** shipped — and the recipe says so, with the reason. An
unexplained missing flag looks like an oversight; a stated exception
is a decision. (keep-id specifically would fight these workloads:
uid-remapped package managers cannot write the image root paths they
expect to own.)

## Fail closed: `ensure` + `verify` before `podman run`

A launcher that starts workloads against a profile that is not live
runs them **unprotected, not safe** — the network object can outlive
its policy. Every recipe therefore **gates the launch on the pair** —
one `&&` chain, so a failed check stops the `podman run` instead of an
ordinary shell continuing to the next line:

```sh
# converge network + policy (or repair), then assert the live policy
# (exit 1 = fail closed); the launch runs only if both succeed:
egresslock ensure <profile> \
 && egresslock verify <profile> \
 && podman run ...
```

The `&&` matters: a plain line sequence continues after a failed
`verify` — the workload would start unprotected. Never paste the
`podman run` line alone; the gate is the first two links.

After a host reboot, re-run `ensure` before attaching workloads — the
network object survives reboot without its policy
([after a reboot](../troubleshooting/after-a-reboot.md)).

## The egresslock launcher flags (already in every recipe)

Not hardening, but part of the same block, defined once here:

- `--network="$(egresslock network <profile>)"` — attach to the
  profile network; **only** there does the fail-closed policy apply
  (never `--network=host` or a second network).
- `--env-file=/run/user/$(id -u)/egresslock-proxy-<profile>.env` —
  wire the proxy env in as one file (`egresslock proxy-env <profile>
  > /run/user/$(id -u)/egresslock-proxy-<profile>.env` immediately
  before `podman run`; the account's private runtime dir — not a
  world-writable tmp; regenerate after a policy change).
- **Never** bind-mount the account's home (or
  `~/.config/egresslock/`) into a workload — policy files must not
  enter the workload filesystem (I5/T10 in the threat model).

## Flags passed are not flags honored

**Flags passed are not flags honored**: on affected Podman versions, a
container image can be built so that a successful restore silently
discards the sandbox flags you passed — the caveat, its live-observed
trigger, and the fixed versions are recorded in the
[threat model](threat-model.md)
(launcher obligations; T9). Run a fixed Podman and reject images
carrying the checkpoint annotation — the baseline above is the
*requested* configuration, and the runtime is part of what you are
trusting.

## Scope: workload launchers only

This baseline is about the containers **you** launch on a profile
network. The kit-built gateway image is different — its rebuild and
maintenance story lives in
[The gateway image](gateway-image.md).
