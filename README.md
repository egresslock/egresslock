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
2. Debian packages:

   - **podman** (rootless), **netavark**
   - **nftables** 1.0+ (`nft` at `/usr/sbin/nft` or `NFT_BIN`)
   - **conntrack** (`conntrack` at `/usr/sbin/conntrack` or
     `CONNTRACK_BIN` — required by `disallow-host`'s revocation flush)

   ```sh
   # example — dependency install with apt:
   sudo apt-get install -y podman netavark nftables conntrack
   ```

3. One or more dedicated unprivileged `<account>`s to own the policies
   (the kit never runs policy jobs as root) — **create a new account
   specifically for this**, not your user account. Any account name
   works; the examples use the placeholder `<account>`:

   ```sh
   # create a dedicated account to own the containers and container networks:
   sudo adduser <account>
   ```

### Setup

From a fresh host with a dedicated unprivileged `<account>` (see
Requirements above):

1. **Install the kit (.deb) and set up the account**:

   ```sh
   # Build the .deb from a checkout (no root needed; there is no
   # hosted .deb to download), then install it:
   git clone https://github.com/egresslock/egresslock
   cd egresslock
   ./packaging/build-deb.sh
   sudo dpkg -i packaging/egresslock_<VERSION>_all.deb

   # On Ubuntu >= 25.10 (podman under an AppArmor label), add the pasta policy — to read more details about why this is needed, see apparmor/README.md
   sudo egresslock-setup --apparmor-add
   # egresslock-setup --apparmor-check reports whether this host needs it.

   #set up and enable starter conf, linger, and 15-min drift check timer
   sudo egresslock-setup --init-conf --enable --account <account>
   ```

   What this does is:

      - build the gateway image
      - write the account's `unit.env` and ship a **deny-all** starter
        conf (`main.conf` to `/home/<account>/.config/egresslock/`)
      - with `--enable`: enable the 15-minute verify timer and linger
        (linger keeps the account's session alive so the timer can run
        outside logins; details in
        [Install the kit](docs/setup/install.md)) — without it, drift
        checks only run when `verify` is manually run

   To read more about the AppArmor pasta rule, see the
   [pasta policy rule](apparmor/README.md).

   (Not installing via the .deb? See [Install the kit](docs/setup/install.md).)

2. **Build the network policy**: now that the kit is installed, as the
   account, run `ensure` — this creates the profile network, starts the
   anchor (and gateway) that keeps it alive, installs the fail-closed
   nftables policy, and verifies the result. It is idempotent (safe to
   re-run) and is required before a workload can start:

   ```sh
   sudo -iu <account>
   ```

   ```sh
   egresslock ensure main
   ```

3. **(Optional) Examine from within the container** (still in the
   account's shell from step 2):

   Run a container on its network with the proxy wired in
   (IP/port pulled from the profile). On .deb hosts the engine is on
   `PATH` as `egresslock` (prefix installs: use
   `/opt/egresslock/egresslock`):

   ```sh
   # Run a shell on the profile network, proxy wired in with one env file
   # (bash process substitution; --env-file=<(...) needs bash or zsh):
   podman run --rm -it \
       --network="$(egresslock network main)" \
       --env-file=<(egresslock proxy-env main) \
       docker.io/library/debian:13-slim \
       sh
   ```

   This drops you into a `debian:13-slim` shell on the profile's network —
   **no curl/wget/ping inside**, so there is no egress until you allow
   destinations.

4. **Go through the quick start guides**: now that the kit is installed,
   work through the [Quick start guides](#quick-start-guides) below.

## Quick start guides

Brief, task-oriented guides (as the account, unless noted). Profile
name `main` in the examples is just that — an example; use your
profile's name. The [Reference](#reference) section holds the
detailed material; [troubleshooting](docs/troubleshooting.md) is the
"I'm facing X" index.

1. [Create a profile](docs/quickstart/create-a-profile.md) <span style="color:#6a737d">(<1 minute)</span> — the `init`/`ensure` walkthrough for a new profile.
2. [Allow a domain (and see what's blocked)](docs/quickstart/allow-a-domain.md) <span style="color:#6a737d">(<1 minute)</span> — run a workload, 403 → `allow example.com` → re-run → `denied` → remove an entry.
3. [Grow the policy](docs/quickstart/grow-the-policy.md) <span style="color:#6a737d">(<1 minute)</span> — the allow/allow-host flows and removing entries.
4. [Allow non-HTTP egress](docs/quickstart/allow-non-http.md) <span style="color:#6a737d">(<1 minute)</span> — `allow-host` for git-over-SSH, raw IPs, and same-host services (recipes; the why lives in the reference).
5. [Reach a service on the host (localhost) from a container](docs/quickstart/reach-a-host-service.md) <span style="color:#6a737d">(<1 minute)</span> — the two supported patterns (proxied name, direct literal) and the pasta-hairpin trap.
6. [First-run checks](docs/quickstart/first-run-checks.md) <span style="color:#6a737d">(<1 minute)</span> — the things that commonly go wrong right after initial setup.
7. [Test your container](docs/quickstart/test-your-container.md) — a five-minute pass proving the policy allows and blocks what you expect.

## Recipes

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
  setting, both channels (`.deb` and manual prefix), AppArmor
  prerequisite, verify, files installed, host validation. The quick
  start above is the condensed `.deb` version.
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
- **[Overview](docs/reference/overview.md)** — how it works: the
  problem it addresses, the enforcement architecture, fail-closed
  behavior, and the security model summary.
- **[Policy reference](docs/reference/policy-reference.md)** — the full
  profile-conf grammar, the allowlist format, the destination →
  mechanism decision table, `rule public-only`, and `allow-host`
  details.
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
  [docs/README.md](docs/README.md) for the organization rules.

### License

Apache-2.0 — see [`LICENSE`](LICENSE) (`Copyright 2026 the egresslock
authors`).
