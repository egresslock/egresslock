# Inspecting the shared rootless netns (and the engine-ran-as-root trap)

## The model

The engine (`egresslock`) applies its nftables policy inside the
user's **shared rootless netns**. Podman gives each user exactly ONE
shared rootless netns, held open by a helper process (`pasta` on
podman >= 4.6, `slirp4netns` on older). All of the user's podman
networks live inside it; the nftables chains apply to every network
in it at once — that is the single enforcement point.

Per-container `--network=slirp4netns` (used by the agent containers)
creates a SEPARATE private netns per container and does not touch the
shared one. That is why those containers keep working when the shared
netns breaks.

## Inspection

```sh
# The probe: does the shared netns work at all?
podman unshare --rootless-netns true; echo "rc=$?"

# The netns mount points (owned by the account; one shared netns):
ls -la /run/user/$(id -u)/netns/

# Live counters and rules (see paths-and-signatures for reading them):
podman unshare --rootless-netns nft list ruleset

# Enter it as root (nsenter needs a PID, not the netns filename):
pid="$(pgrep -f 'netns-type=path' | head -1)"
sudo nsenter -t "$pid" -n ip addr        # view interfaces inside the netns
sudo nsenter -t "$pid" -n nft list ruleset 2>/dev/null   # the live policy
```

Note: `nsenter --target` takes a **PID** (e.g. pasta's), not a netns
filename. `cat` on a netns file just shows an empty bind-mount point.

## Symptom: a root run leaked into the account's netns

Root-owned files under `/run/user/<uid>/netns/` mean a root/sudo run
of the engine leaked into the account's netns; clean them as
root.

## Cause

`egresslock` profile commands build policy in the RUNNING USER's
rootless store/netns. Running them as root builds it in ROOT's store —
a separate world nothing else uses. Always:

```sh
sudo -iu <account>
```

## Related

- [paths-and-signatures](../reference/paths-and-signatures.md) —
  reading the live counters and rules you just listed.
- [pasta-apparmor](pasta-apparmor.md) — when the probe itself fails
  with `kill network process: permission denied`.
- [who-runs-what](../reference/who-runs-what.md) — the three levels
  and why root must never run the engine.
