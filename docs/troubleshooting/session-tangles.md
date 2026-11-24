# Session / pause-process tangles

## Symptom

After the user session was restarted (`sudo systemctl restart
user@UID`), the podman pause process (and any container that is a
child of the user systemd instance) dies with it. The next podman
command may say:

```
invalid internal status, try resetting the pause process with
"podman system migrate": could not find any running process
```

## Cause

The pause process and containers are children of the user systemd
instance; restarting that instance orphans them.

## Fix / recovery in order

> **Do not run `podman system reset`** — it deletes every container,
> image, and volume in the store, not just the wedged pause process.

```sh
podman ps -a          # what got stopped? (migrate stops containers)
podman start NAME   # restart anything that should be running
# prefer a REBOOT to clear a wedged pause-process state over repeated
# migrate calls.
```

`podman system migrate` can itself crash on podman 5.7.0 (SIGSEGV in
the Go storage layer).

## Related

`systemctl --user is-system-running` showing `degraded` is USUALLY
benign desktop noise (DrKonqi, xdg-desktop-portal, snap units) — the
only gate worth testing is the `podman unshare --rootless-netns true`
probe (see [netns-inspection](netns-inspection.md)).

## Links

- Back to the [symptom index](../troubleshooting.md).
- [netns-inspection](netns-inspection.md) — the netns probe this page
  points at.
- [concurrent-commands](concurrent-commands.md) — the other lock-style
  interference.
