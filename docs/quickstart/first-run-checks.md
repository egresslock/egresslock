# First-run checks (right after initial setup)

Not sure which check command answers which question? Start at
[which-check](../troubleshooting/which-check.md) — four commands,
four questions.

The things that commonly go wrong immediately after installing, in
the order to check them. Each item: one command, what good looks
like, and where to go if it's wrong. The full per-layer catalog:
[check-everything](../reference/check-everything.md).

Run as the dedicated account (`sudo -iu <account>`), never root — a
root run builds policy in ROOT's store and nothing sees it
([netns-inspection](../troubleshooting/netns-inspection.md)).

For the host environment (podman/netavark/nft/unprivileged userns),
`egresslock doctor` reports each check as a `key: value` line —
required tools missing exit 1, advisory lines never do.

## 1. Is the engine installed, and which build?

```sh
egresslock --version
```

Good: the engine answers with the version you deployed. Command not
found → the install didn't land where you think (.deb hosts:
`/usr/bin/egresslock` on PATH; prefix installs: `/opt/egresslock`,
added to PATH or used by full path).

## 2. Did the profile ensure cleanly?

```sh
egresslock ensure main
egresslock verify main
```

Good: exit 0, `profile 'main' policy and gateway verified`.
`verify: FAILED` → policy drift or gateway container down —
[verify-timer-signals](../troubleshooting/verify-timer-signals.md).

## 3. Is the shared netns healthy?

```sh
podman unshare --rootless-netns true; echo "rc=$?"
```

Good: rc=0. rc!=0 with `kill network process: permission denied` →
the pasta/AppArmor blocker:
[pasta-apparmor](../troubleshooting/pasta-apparmor.md) (fix:
`egresslock-setup --apparmor-add`, health: `egresslock-setup
--apparmor-check`).

## 4. Are the anchor and gateway containers up?

```sh
podman ps -a --filter name=^egresslock --format '{{.Names}}  {{.Status}}'
```

Good: `egresslock-anchor-main` Up, `egresslock-gateway-main` Up.
Exited → re-run `ensure main`; if they keep dying,
[verify-timer-signals](../troubleshooting/verify-timer-signals.md).

## Next

- [Test your container](test-your-container.md) — prove the policy
  allows and blocks what you expect.
