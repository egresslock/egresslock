# Operator obligations — the do / do-not list

This page answers one question: **what must you do — and not do — so
that egresslock actually protects your workload traffic?** Every line
below traces to the [threat model](threat-model.md) — an obligation, an
invariant, or a live-confirmed finding; nothing here is a new claim.
The [container hardening baseline](container-hardening.md) holds the
launch flags in full. The kit enforces the network policy — the items
below are yours to keep.

## Do

- **Launch workloads with the hardening baseline** — at minimum
  `--cap-drop=all --security-opt=no-new-privileges`; the
  [hardening page](container-hardening.md) holds the full layer set.
  The kit ships no workload launcher — its
  [`egresslock-start`](scripts-and-environment.md#egresslock-start--the-daemon-start-wrapper)
  wrapper starts a site daemon, it does not launch workloads (the
  [threat model](threat-model.md) owns why); plain `podman run` keeps
  the default capability set.
- **Run `egresslock ensure` and `egresslock verify` before workloads
  start — including after a reboot.** The network object can outlive
  its policy; no live chain means unprotected, not safe. The
  15-minute verify timer signals a missing policy but never repairs
  it — `ensure` does. See
  [after a reboot](../troubleshooting/after-a-reboot.md).
- **Keep the host OS and kernel security-patched.** Every container
  runs on the host kernel.

## Do not

- **Do not launch a workload with `--network=host`, with
  `--network=container:<gateway>`, or dual-homed onto a second
  network** — each takes it outside the profile policy, with raw
  egress and no Squid enforcement.
- **Do not bind-mount the account home or `~/.config/egresslock/`
  into a workload — the policy files must never enter the workload
  filesystem.** A workspace directory under your home is not this
  ban.
- **Do not give a workload write access to the host resolver inputs
  (`/etc/hosts`, `/etc/resolv.conf`)** — whoever controls them
  controls the policy; `ensure` pins the resolver's answer as-is.
  (The container's own `/etc/hosts` is not a policy input.)

The normative wording lives in the [threat model](threat-model.md);
this page is the one-screen index. [Who runs
what](who-runs-what.md) maps the worlds these items span.
