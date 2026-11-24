# Recipe: CI runner under a restricted profile

Goal: a CI runner container (e.g.
[Forgejo runner](https://codeberg.org/forgejo/runner) or a GitHub
Actions runner) whose job containers can reach the VCS host and
package registries they need — nothing else.

## What you end up with

```
# ~/.config/egresslock/runner.conf
profile runner 10.199.3.0/24
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

A service account can get the pair from deploy tooling without editing
its conf; `init --from` imports it first, then validates and wires the
timer in one command:

```sh
sudo egresslock-setup init runner \
    --from /srv/runner/runner.conf --enable
```

This validates the pair, builds the gateway image if missing, enables
the verify timer, and enables linger (required so `/run/user/<uid>`
exists at boot for a runner started before login). The timer checks
every profile with a running anchor, which for this
single-profile account is just `runner`. To re-pin a changed conf
later, use `import --force` and then `init runner --enable`;
split the installation from wiring with
`import runner --from <path>` then
`init runner --enable`.

Or, as the account, write the pair above under
`~/.config/egresslock/`, then ensure and (re)allow the three entries:

```sh
sudo -iu runner
egresslock ensure runner
egresslock allow runner vcs.example.test:443
egresslock allow runner git.example.test:443
egresslock allow runner registry-1.docker.io:443
```

See [Install the kit](../../docs/setup/install.md) for both forms.

(You may prefer a dedicated account for the runner — profiles are
per-account.)

## 2. Point the runner's containers at the profile

Two settings in the runner software's own container configuration —
not egresslock flags — make job containers run under the profile. And
one obligation before any setting: the network policy is the egress
boundary, but container-level hardening (cap-drop,
no-new-privileges, read-only rootfs where the runner image allows it)
is the launcher's — the same baseline as every other recipe: the
[container hardening baseline](../../docs/reference/container-hardening.md).

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
   (`egresslock proxy-env runner` prints the exact values). Take
   `NO_PROXY` from the same output (`egresslock proxy-env runner
   noproxy`): it is derived — the loopback pair plus any IPv4 direct
   pins — so there is no hand-written bypass list, and a hostname
   cannot be added to it. The exact mechanism varies by runner
   software — an env section in the runner's container config is the
   usual shape.

The runner daemon itself runs as a systemd service started by
`egresslock-start`, which `ensure`s the profile (fail-closed) and then
execs the daemon. The wrapper adds no proxy environment — job
containers get theirs from the runner config in step 2 — and the
daemon's own arguments pass through unchanged. The unit looks like
this:

```ini
[Service]
User=runner
Environment=EGRESSLOCK_PROFILE=runner
Environment=RUNNER_BIN=/usr/local/bin/<daemon>
ExecStart=/opt/egresslock/egresslock-start <daemon args>
```

(From a `.deb` install, the wrapper is
`/usr/lib/egresslock/egresslock-start`; see
[the wrapper reference](../../docs/reference/scripts-and-environment.md#egresslock-start--the-daemon-start-wrapper).)

`egresslock-setup init --enable` above wired the verify timer; the
timer checks every profile with a running anchor (here just
`runner`). It reads no per-account environment file, and it never
carries `RUNNER_BIN` — the daemon unit sets its own `Environment=`
lines as above.

## 3. Watch it work

- `egresslock denied runner` shows what the gateway blocked during a
  job run; jobs that need an extra host → `egresslock allow runner
  <host>` and re-run.
- The verify timer re-checks the live policy every 15 minutes; see
  [troubleshooting](../../docs/troubleshooting.md) if a check fails.
