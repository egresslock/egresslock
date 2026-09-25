# Recipe: CI runner under a restricted profile

Goal: a CI runner container (e.g.
[Forgejo runner](https://codeberg.org/forgejo/runner) or a GitHub
Actions runner) whose job containers can reach the VCS host and
package registries they need — nothing else.

## What you end up with

```
# ~/.config/egresslock/runner.conf
profile runner 10.199.3.0/24
    rule gateway-only
    gateway 10.199.3.2 3128 runner-allowlist

# ~/.config/egresslock/runner-allowlist
vcs.example.test
git.example.test:443
registry-1.docker.io:443
```

---

## 1. Set up the runner account

As root (the kit is on PATH from the .deb, or under the prefix for
install-kit deploys):

```sh
sudo egresslock-setup --account runner --init-conf --enable
```

This validates the conf, writes `unit.env`, builds the gateway image
if missing, enables the verify timer, and enables linger (required so
`/run/user/<uid>` exists at boot for a runner started before login).

Then replace the shipped starter conf with the runner conf above (or
add the runner profile to it) and allow the VCS host and any
registries the runner needs, as the account:

```sh
sudo -iu runner
egresslock ensure runner
egresslock allow runner vcs.example.test:443
egresslock allow runner registry-1.docker.io:443
```

If you would rather pin the conf path up front, the same bundle
accepts `--conf <path> --profile <name>` — see
[Install the kit](../../docs/setup/install.md) for that form.

(You may prefer a dedicated account for the runner — profiles are
per-account.)

## 2. Point the runner's containers at the profile

Two settings in the runner software's own container configuration —
not egresslock flags — make job containers run under the profile:

1. **Attach job containers to the profile's network.** Set the
   container network to the profile's network name (e.g. on a
   `main`-style profile that is `egresslock-runner`; get the exact
   name with `egresslock network runner`). In a Forgejo runner
   `config.yml`, that is the `container: network:` field. Do **not**
   leave it on auto-created networks — the profile's fail-closed
   policy only applies on the profile network. After a host reboot,
   re-run `egresslock ensure runner` (or `egresslock-start`) before
   job containers attach — the network object survives reboot without
   its policy ([after-a-reboot](../../docs/troubleshooting/after-a-reboot.md)).

2. **Give job containers the proxy env.** Proxy-honoring tools inside
   the job must point at the profile's Squid gateway: the runner
   config's env block sets
   `HTTP(S)_PROXY`/`http(s)_PROXY` to `http://<gateway-ip>:3128`
   (`egresslock proxy-env runner` prints the exact values), and
   `no_proxy` for anything that must bypass it. The exact mechanism
   varies by runner software — an env section in the runner's
   container config is the usual shape.

The runner daemon itself runs as a systemd service via
`egresslock-start`, which `ensure`s the profile (fail-closed) and then
execs the daemon with the proxy env; `--enable` above wrote
`unit.env` from the account's conf:

```
# unit.env for the runner service
EGRESSLOCK_CONF=/home/runner/.config/egresslock/runner.conf
EGRESSLOCK_PROFILE=runner
```

## 3. Watch it work

- `egresslock denied runner` shows what the gateway blocked during a
  job run; jobs that need an extra host → `egresslock allow runner
  <host>` and re-run.
- The verify timer re-checks the live policy every 15 minutes; see
  [troubleshooting](../../docs/troubleshooting.md) if a check fails.
