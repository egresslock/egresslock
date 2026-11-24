# First-run checks (right after initial setup)

The things that commonly go wrong right after installing, in the order
to check them.

> **Before you start**
>
> 1. an account set up with a name of your choosing — the examples
>    use `egl-runner`; enter its shell with `sudo -iu egl-runner`
>    (see [who-runs-what](../reference/who-runs-what.md) for the
>    three worlds) — a root run builds policy in ROOT's store, where
>    nothing sees it ([netns-inspection](../troubleshooting/netns-inspection.md))
> 2. the kit installed and set up (see
>    [install](../setup/install.md))

## 1. Is the engine installed, and which build?

```sh
# the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock --version
```

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ egresslock --version
version: 0.11.0+git20261108123456.a1b2c3d4e5f6
commit: a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0
deployed: 2026-11-08T12:34:56Z
</pre>

Yours will differ; the three-line shape is what matters.

Troubleshooting: command not found? The install didn't land where you
think (.deb hosts: `/usr/bin/egresslock` on PATH; prefix installs:
`/opt/egresslock`, added to PATH or used by full path).
</details>

## 2. Did the profile ensure cleanly?

```sh
# the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock ensure main
```

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ egresslock ensure main
using config /home/egl-runner/.config/egresslock/main.conf
gateway 'egresslock-gateway-main' ready (allowlist applied, health verified)
profile 'main' ready (network egresslock-main, policy verified)
note: egresslock protects the policy, not the workload's launch settings — before starting a workload, review the operator obligations checklist: /usr/share/egresslock/docs/reference/operator-obligations.md
</pre>
</details>

```sh
# the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock verify main
```

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ egresslock verify main
using config /home/egl-runner/.config/egresslock/main.conf
profile 'main' policy and gateway verified
</pre>

Troubleshooting: `verify: FAILED`? Policy drift or the gateway
container is down —
[verify-timer-signals](../troubleshooting/verify-timer-signals.md).
</details>

## 3. Is the shared netns healthy?

```sh
# the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

podman unshare --rootless-netns true; echo "rc=$?"
```

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ podman unshare --rootless-netns true; echo "rc=$?"
rc=0
</pre>

Troubleshooting: rc!=0 with `kill network process: permission
denied`? The pasta/AppArmor blocker —
[pasta-apparmor](../troubleshooting/pasta-apparmor.md). Check first
(`egresslock-setup apparmor check` runs without root); apply the
amendment only when the check reports
`pasta amendment: required on this host` — as root, and with the full
path on a prefix install:
`sudo /opt/egresslock/egresslock-setup apparmor add`
(`.deb hosts: sudo egresslock-setup apparmor add`).
</details>

## 4. Are the anchor and gateway containers up?

```sh
# the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

podman ps -a --filter name=^egresslock --format '{{.Names}}  {{.Status}}'
```

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ podman ps -a --filter name=^egresslock --format '{{.Names}}  {{.Status}}'
egresslock-anchor-main  Up 10 hours
egresslock-gateway-main  Up 5 hours
</pre>

Troubleshooting: Exited? Re-run `ensure main`; if they keep dying —
[verify-timer-signals](../troubleshooting/verify-timer-signals.md).
</details>

## Next

- [Choose a recipe](../../README.md#recipes) — you're ready to pick
  one for your use case.
- [Operator obligations](../reference/operator-obligations.md) — the
  do / do-not list for keeping workload traffic protected.
