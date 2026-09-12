# `unable to find network ... network not found` (podman)

## Symptom

Starting a workload on a profile fails with podman's own error:

```text
Error: unable to find network with name or ID egresslock-main: network not found
```

(The network name is `egresslock-<profile>` — `egresslock-main` for a
profile named `main`.)

## Cause

The named podman network does not exist in **this user's** podman
store. The network is created by `egresslock ensure <profile>` and
lives in the container-owner account's rootless store — so this
happens when:

- the profile was never ensured (first run: you started a workload
  before running `egresslock ensure <profile>` — the canonical
  trigger), or
- the network was torn down (`egresslock teardown`) and not re-ensured, or
- you are running podman as a different user than the account that
  ensured the profile — each user has a separate rootless store, so
  the network exists but not in *your* store.

## Fix

As the container-owner account, ensure the profile:

```sh
egresslock ensure main
```

This is idempotent: it recreates the network, the anchor, and the
policy. Confirm the network is back:

```sh
podman network ls
# egresslock-main should be listed
```

Then start your workload again. If you were running podman as another
user, switch to the container-owner account instead
(`sudo -iu <account>` — see
[who-runs-what](../reference/who-runs-what.md)).

## Links

- [who-runs-what](../reference/who-runs-what.md) — who runs the
  engine and the workloads (root never does).
- [first-run-checks](../quickstart/first-run-checks.md) — the checks
  right after initial setup, including the first `ensure`.
- [which-check](which-check.md) — which doctor/check command answers
  which question.
