# Inspecting the shared rootless netns (and the engine-ran-as-root trap)

## The model

The engine (`egresslock`) applies its nftables policy inside the
user's **shared rootless netns**. Podman gives each user exactly ONE
shared rootless netns, held open by a helper process (`pasta` on
podman >= 5.0 — the rootless default since 5.0, per the [podman 5.0
release notes](https://github.com/containers/podman/blob/v5.0.0/RELEASE_NOTES.md) —
`slirp4netns` on older). All of the user's podman
networks live inside it; the nftables chains apply to every network
in it at once — that is the single enforcement point.

Per-container `--network=slirp4netns` (a per-container network-mode
override a container starter can set — not one of the kit's profile
bridge networks) creates a SEPARATE private netns per container and
does not touch the shared one. That is why those containers keep
working when the shared netns breaks.

## Inspection

```sh
# The probe: does the shared netns work at all?
podman unshare --rootless-netns true; echo "rc=$?"

# These files are per-container netns on podman 5.x, not the shared
# rootless netns (that lives elsewhere, e.g.
# /tmp/storage-run-<uid>/containers/networks/rootless-netns/):
ls -la /run/user/$(id -u)/netns/

# Live counters and rules (see paths-and-signatures for reading them).
# nft is /usr/sbin/nft — a non-root PATH often omits /usr/sbin:
podman unshare --rootless-netns /usr/sbin/nft list ruleset
```

The unprivileged `podman unshare --rootless-netns` form enters the
shared netns directly — no root step and no PID to find. `pasta` only
holds that netns open (its `--netns` argument names the file); the
pasta process itself stays in the host netns, so `nsenter` into one of
its pids shows the host, not the policy — and `nsenter` takes a PID in
any case, never the netns file.

A bare `podman unshare` inherits the caller's working directory, so run
it as the account from a directory the account can traverse; the engine
and the timer wrapper run their own probes from `/` and are not affected.

## Symptom: a root run leaked into the account's netns

Root-owned files under `/run/user/<uid>/netns/` mean a root/sudo run
of the engine leaked into the account's netns; clean them as
root.

## Cause

`egresslock` profile commands build policy in the RUNNING USER's
rootless store/netns. Running them as root builds it in ROOT's store —
a separate world nothing else uses. Always:

```sh
sudo -iu ACCOUNT
```

## Related

- [paths-and-signatures](../reference/paths-and-signatures.md) —
  reading the live counters and rules you just listed.
- [pasta-apparmor](pasta-apparmor.md) — when the probe itself fails
  with `kill network process: permission denied`.
- [who-runs-what](../reference/who-runs-what.md) — the three levels
  and why root must never run the engine.

## Links

- Back to the [symptom index](../troubleshooting.md).
- [paths-and-signatures](../reference/paths-and-signatures.md) —
  reading the live counters and rules you just listed.
- [pasta-apparmor](pasta-apparmor.md) — when the probe itself fails
  with `kill network process: permission denied`.
- [who-runs-what](../reference/who-runs-what.md) — the three levels
  and why root must never run the engine.
