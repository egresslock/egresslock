# egresslock — fail-closed network access for untrusted containers

## What it is

Assume the container is hostile. Give it no network. Then explicitly
construct the network it is allowed to have.

`egresslock` provides fail-closed egress control for rootless Podman
containers. A profile creates a private bridge network, installs an nftables
policy in the account's rootless network namespace, and drops traffic by
default. Profiles then grant only the destinations and services they declare.
For HTTP(S), a profile can require traffic to pass through a Squid gateway
whose hostname allowlist is refreshed from policy. No privileged runtime
daemon is required.

The policy is established and verified before a workload starts. A long-lived
anchor keeps the rootless network namespace and its policy alive between
workloads, and a systemd timer re-verifies the live ruleset every 15 minutes.

Designed for AI agents, CI runners, build environments, and other
semi-trusted workloads. See [CHANGELOG.md](CHANGELOG.md) for what
changed between releases — the public repository ships without
history, so the changelog is that record.

> **Alpha software:** egresslock is early and evolving — CLI flags,
> file layout, and behavior may change between releases.

> **No security guarantee:** egresslock is provided without a warranty or
> guarantee that a workload is secure, contained, or unable to escape. It
> reduces the permitted egress surface under its documented deployment
> assumptions; it is not a general container-escape prevention mechanism,
> sandbox, host-isolation boundary, or substitute for defense in depth. Read
> the [threat model](docs/reference/threat-model.md) before relying on it.
> Found a bypass or a behavior worse than a documented accepted risk?
> Report it privately — see [SECURITY.md](SECURITY.md).

It was extracted from a real multi-account deployment and is consumed
by two production accounts on the same host. This directory is the
relocatable engine tree; site-specific consumers live elsewhere.

```
workload container
                          (agent / CI / build)
                                   │
                                   ▼
                         rootless profile network
                              DEFAULT: DENY
                                   │
                       ┌───────────┴───────────┐
                       │                       │
                       ▼                       ▼
                explicit direct          Squid gateway
                    allows                 HTTP / HTTPS
                e.g. Git SSH                   │
                       │                       │
                       ▼                       ▼
                 allowed service         allowed hosts
                                               │
                                               ▼
                                            Internet
```

**More information:** [Overview — how egresslock
works](docs/reference/overview.md) (the problem it addresses,
enforcement architecture, fail-closed behavior, security model
summary) and the [threat model](docs/reference/threat-model.md) (the
normative security claims and their limits).

## Install and first run

### Requirements

1. Linux with **systemd** and unprivileged user namespaces enabled

### One-step install

One-step install in a paste-able block (idempotent). If you prefer one step at a time:
[Install the kit](docs/setup/install.md).

```sh
# your own user — sudo elevates where marked
# prompt: $ (your own prompt)

# --- install dependencies (root) ----------------------------------------
sudo apt-get install -y podman netavark nftables conntrack

# --- create a dedicated account (root) — edit the name if you like -----
# the quickstart examples use `egl-runner`; any dedicated unprivileged
# account name works
ACCOUNT=egl-runner
id "$ACCOUNT" >/dev/null 2>&1 || sudo adduser --disabled-password \
    --gecos "egresslock runner" "$ACCOUNT"

# --- build and install the kit ------------------------------------------
[ -d ~/egresslock ] || git clone https://github.com/egresslock/egresslock ~/egresslock
cd ~/egresslock
git pull
rm -f ./packaging/egresslock_*_all.deb
./packaging/build-deb.sh
sudo dpkg -i ./packaging/egresslock_*_all.deb

# --- apply the AppArmor pasta policy only if needed (root) --------------
sudo egresslock-setup --apparmor-check | grep Summary
sudo egresslock-setup --apparmor-check | grep -q "CHECK FAILED" && sudo egresslock-setup --apparmor-add

# --- set up the account: starter conf + drift timer + linger (root) ------
# quiet run: the full stream (incl. the gateway image build) goes to
# the log; the six-step map is what matters
sudo egresslock-setup --init-conf --enable --account "$ACCOUNT" > ~/egresslock-setup.log 2>&1
grep -E '^[0-9]\) |hint|FAIL' ~/egresslock-setup.log

# --- build the policy and the shared example image (as the account) -----
sudo -iu "$ACCOUNT" -- egresslock ensure main
sudo -iu "$ACCOUNT" -- /usr/share/egresslock/examples/egl-base/build-egl-base
```

<details><summary>Expected output (the lines that matter):</summary>

<pre>
$ grep -E '^[0-9]\) |hint|FAIL' ~/egresslock-setup.log
1) validate conf … OK
2) write unit.env … OK
3) linger … OK
4) user manager … OK
5) gateway image … OK
6) timer … OK
$ sudo -iu egl-runner -- egresslock ensure main
created network egresslock-main (10.199.0.0/24)
started anchor egresslock-anchor-main
gateway 'egresslock-gateway-main' ready (allowlist applied, health verified)
profile 'main' ready (network egresslock-main, policy verified)
$ sudo -iu egl-runner -- /usr/share/egresslock/examples/egl-base/build-egl-base
>> Building localhost/egl-base:latest FROM a29215f6a35e
>> Done: localhost/egl-base:latest
</pre>
</details>

What you now have:

- on a fresh account, a starter policy (`profile main`, empty
  allowlist) that denies application connections; DNS queries to the
  bridge resolver are still allowed and can carry data out
- the anchor and gateway containers running
- the 15-minute drift check timer enabled
- the `egl-base` example image, ready for the quickstarts

Re-running preserves existing confs and allowlists — it does not reset
your policy to deny-all. The [threat model](docs/reference/threat-model.md)
explains the DNS exception and other limits.

### (Optional) Launch a container on the locked network

```sh
# your own user — sudo elevates; edit ACCOUNT if you changed it above
# prompt: $ (your own prompt)

ACCOUNT=egl-runner
# the quoted command is one single line on purpose — a multi-line
# sh -c payload breaks if a paste collapses the newlines
sudo -iu "$ACCOUNT" -- sh -c 'egresslock ensure main && egresslock proxy-env main > /run/user/"$(id -u)"/egresslock-proxy-main.env && podman run --rm -it --cap-drop=all --security-opt=no-new-privileges --network="$(egresslock network main)" --env-file=/run/user/"$(id -u)"/egresslock-proxy-main.env localhost/egl-base:latest sh'
```

A shell in an `egl-base` container on the profile network. The launch
runs only if `ensure` succeeds; application connections follow your
existing policy (denied by the fresh starter, apart from DNS above).

<details><summary>Expected output:</summary>
the container's shell prompt — you are inside the locked network:

<pre>
$ sudo -iu egl-runner -- sh -c 'egresslock ensure main && egresslock proxy-env main > … && podman run … sh'
gateway 'egresslock-gateway-main' ready (already converged, not restarted)
profile 'main' ready (network egresslock-main, policy verified)
root@9badc0ffee67:/#
</pre>

`root@…` is the container's own root (rootless Podman maps it to the
account — NOT host root); the hostname is the container's. `exit`
returns to the account's one-off shell.
</details>

Next: [Allow a
domain](docs/quickstart/allow-a-domain.md) — probe the deny-all,
then allow one destination.

## Quick start guides

Brief, task-oriented guides (as the account, unless noted). Profile
name `main` in the examples is just that — an example; use your
profile's name. The [Reference](#reference) section holds the
detailed material; [troubleshooting](docs/troubleshooting.md) is the
"I'm facing X" index.

Creating an additional profile (beyond the starter `main`) is
optional — [Create a profile](docs/reference/policy-reference.md#profile-lifecycle).

1. [Allow a domain (and see what's blocked)](docs/quickstart/allow-a-domain.md) <span style="color:#6a737d">(<1 minute)</span> — run a workload, 403 → `allow example.com` → re-run → `denied` → remove an entry.
2. [Allow non-HTTP egress](docs/quickstart/allow-non-http.md) <span style="color:#6a737d">(<1 minute)</span> — `allow-host` for git-over-SSH and raw IPs, and the fail-closed proofs.
3. [First-run checks](docs/quickstart/first-run-checks.md) <span style="color:#6a737d">(<1 minute)</span> — the things that commonly go wrong right after initial setup.

## Recipes

Every recipe's `podman run` block carries the same hardening baseline
(cap-drop + no-new-privileges always; keep-id + a read-only rootfs
where the recipe bind-mounts a host dir and the rootfs is disposable;
exceptions stated, never silent):
[container hardening baseline](docs/reference/container-hardening.md).

### Archetypes

- [Agent in a custom container](examples/recipes/agentic-tool-opencode.md) <span style="color:#6a737d">(3 minutes)</span> — turn-key: opencode baked into a custom image, persistent workspace, built on the default network.
- [Supply-chain-safe build (compilation lockdown)](examples/recipes/supply-chain-safe-build.md) — constrain compilers/builders to a tiny allowlist.
- [Malware analysis](examples/recipes/malware-analysis.md) — detonate samples in an isolated container with a deny-all profile, allow only the C2/sinkhole hosts you choose.
- [CI runner (forgejo-runner)](examples/recipes/ci-runner.md) — restricted runner profile; job containers attached to the profile network with the gateway proxy.

### Specific program or configuration

- [Install opencode via npm](examples/recipes/opencode-npm-install.md) — tested path: apt + npm inside a `debian:13-slim` container reaching exactly deb.debian.org / registry.npmjs.org / github.com / openrouter.ai.
- [Install hermes via curl | bash](examples/recipes/hermes-curl-install.md) — tested path: hermes (Nous Research) inside a `debian:13-slim` container reaching its install chain (Astral/uv, PyPI CDN, github.com).
- [Local LLM (Ollama, etc.)](examples/recipes/local-llm.md) — reach an LLM server on the host or LAN from a container: the localhost patterns, raw-IP `allow-host`, and the long-request timeout knob.

## Reference

### Setup (install / upgrade / uninstall)

- **[Install the kit](docs/setup/install.md)** — full install steps, every
  setting, both install methods (`.deb` and tarball prefix), AppArmor
  prerequisite, verify, files installed. The quick start above is the
  condensed `.deb` version.
- **[Upgrade the kit](docs/setup/upgrade.md)** — re-running install-kit.sh
  with the same prefix, the VERSION stamp, and the post-upgrade checks.
- **[Uninstall the kit](docs/setup/uninstall.md)** — account teardown first,
  kit removal, the AppArmor revert, and the verify-it's-fully-gone
  checklist.
- **[Packaging](packaging/README.md)** — building the `.deb` and
  `tar.gz` artifacts, package layout, and the never-co-install rule.

### Reference docs

- **[Who runs what](docs/reference/who-runs-what.md)** — root, the
  container-owner account, and the workload: who runs which command
  where.
- **[Container hardening baseline](docs/reference/container-hardening.md)**
  — the `podman run` flag layers for example launchers: always-on
  cap-drop/no-new-privileges, keep-id + passwd-entry on bind-mount
  recipes, read-only where the rootfs is disposable, and the stated
  exceptions.
- **[The gateway image](docs/reference/gateway-image.md)** — when to
  rebuild the kit-built gateway, what the doctor's `stale:` means, and
  the rebuild/replace steps.
- **[Overview](docs/reference/overview.md)** — how it works: the
  problem it addresses, the enforcement architecture, fail-closed
  behavior, and the security model summary.
- **[Policy reference](docs/reference/policy-reference.md)** — the full
  profile-conf grammar, the allowlist format, the destination →
  mechanism decision table, `allow-host` details, and the profile
  lifecycle (create / verify / teardown / delete).
- **[Paths and signatures](docs/reference/paths-and-signatures.md)** —
  why a request 403s, hangs, or gets refused: the two-path model, the
  failure signatures, live counters, and the same-host pasta patterns.
- **[Check everything (full catalog)](docs/reference/check-everything.md)**
  — the per-layer health-check and inspection commands.
- **[Proxy clients](docs/reference/proxy-clients.md)** — pointing
  proxy-unaware tools (Gradle, Maven, npm, ...) at the gateway.
- **[Engine, scripts, and environment](docs/reference/scripts-and-environment.md)**
  — engine env overrides, config resolution, `unit.env`, and script
  defaults.

### Troubleshooting

See [`docs/troubleshooting.md`](docs/troubleshooting.md) — the
symptom index ("I'm facing X") linking one page per issue: the
pasta/AppArmor netns blocker, session tangles, proxied-vs-direct
triage (403 vs hang vs instant refusal), gateway (Squid) log reading,
the verify-timer signals, and the missing-profile-network podman
error.

### Development / contributing

- The test battery is `bash tests/run.sh`, run from the repository
  root; it runs every `tests/test-*.sh` suite with no root, Podman, or
  nftables required.
- Found a vulnerability or a bypass? Report it privately — see
  [SECURITY.md](SECURITY.md). Do not open a public issue for it.
- Other bug reports and changes go through public issues and pull
  requests on the project's public repository. For behavior or design
  changes, open an issue first so the security implications can be
  discussed against the [threat model](docs/reference/threat-model.md)
  before code lands.
- Docs layout: quickstart guides in `docs/quickstart/`; reference docs
  in `docs/reference/` and `docs/setup/`; troubleshooting in
  `docs/troubleshooting.md` + `docs/troubleshooting/`. See
  [docs/README.md](docs/README.md) for the docs map.

### License

Apache-2.0 — see [`LICENSE`](LICENSE) (`Copyright 2026 the egresslock
authors`).
