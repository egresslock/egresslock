# Recipe: hermes (Nous Research) in a debian:13-slim container

Goal: run the hermes agent inside a `debian:13-slim` workload with
egress to exactly the hosts its install chain needs — `deb.debian.org`
(apt), `hermes-agent.nousresearch.com` (agent + install script), the
Astral/uv hosts (`astral.sh`, `releases.astral.sh`), `github.com`
(VCS), and the Python package hosts (`pypi.org`,
`files.pythonhosted.org`) — everything else denied by the profile's
fail-closed policy. This is the tested-2026-09-05 version of the
hermes code-install path from
[agentic-tool-opencode.md](agentic-tool-opencode.md).

Run every command **as the account** (`sudo -iu <account>`).

## Note: this recipe accumulates on `main`

Like the opencode recipe, this runs on the **same** `main` profile, so
the allowlist is cumulative. It assumes `deb.debian.org:80` and
`deb.debian.org:443` are already in the allowlist (from the opencode
recipe). On a fresh profile, add them first — apt fetches `InRelease`
over plain HTTP (port 80), then redirects to HTTPS, so both ports are
required (see the opencode recipe for the full explanation).

## What you end up with

The only file this recipe changes is the allowlist:

> ```
> # ~/.config/egresslock/main-allowlist
> deb.debian.org:80            # (from the opencode recipe; needed for apt)
> deb.debian.org:443           # (from the opencode recipe; needed for apt)
> hermes-agent.nousresearch.com
> astral.sh
> releases.astral.sh
> github.com
> pypi.org
> files.pythonhosted.org
> ```

## 1. Allow the destinations

Run as the dedicated `<account>` (never root):

```sh
sudo -iu <account>
```

```sh
egresslock allow main \
    hermes-agent.nousresearch.com astral.sh releases.astral.sh \
    github.com pypi.org files.pythonhosted.org
```

Bare hostnames are enough — the gateway resolves them and matches any
port. Why each host (the install chain, not the agent, drives most of
them):

- `hermes-agent.nousresearch.com` — the agent's own host: the
  `install.sh` script and the agent's API endpoint.
- `astral.sh` + `releases.astral.sh` — uv (Astral's Python tool).
  hermes uses uv to provision its Python environment; the installer
  and the release downloads live on these two hosts.
- `github.com` — VCS (the agent clones/fetches repos).
- `pypi.org` + `files.pythonhosted.org` — both are needed: PyPI's
  metadata lives on `pypi.org`, but pip always downloads the actual
  wheels/sdists from `files.pythonhosted.org` (PyPI's CDN). Allowing
  only `pypi.org` leaves pip stuck.

## 2. Run the container (proxy env as one file)

The env file carries both cases of the proxy pair (apt reads the
**lowercase** `http_proxy`/`https_proxy`):

```sh
podman run --rm -it \
    --network="$(egresslock network main)" \
    --env-file=<(egresslock proxy-env main) \
    docker.io/library/debian:13-slim \
    sh
```

After a host reboot, re-run `egresslock ensure main` (or
`egresslock-start`) before this `podman run` — the network object
survives reboot without its policy
([after-a-reboot](../../docs/troubleshooting/after-a-reboot.md)).

## 3. Inside the container

```sh
apt update
apt install -y git curl xz-utils build-essential

curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

hermes
```

The `curl | bash` install is a mini supply chain of its own: the
script fetches uv (the Astral hosts), Python packages (the PyPI
hosts), and git (github.com) — the hosts pre-allowed in step 1 are
exactly that chain. Anything the script still reaches that is **not**
in that list shows up in `egresslock denied main`.

## Persistence caveat (and the durable alternative)

That `podman run --rm` container is ephemeral — exit the shell and the
apt/uv/hermes install is gone. For a reusable setup, bake the install
into an image and run that (the same pattern as the
[opencode recipe](opencode-npm-install.md)):

```sh
# Containerfile
FROM docker.io/library/debian:13-slim
RUN apt-get update && apt-get install -y git curl xz-utils build-essential \
 && curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

Build it (in the account's store so the profile can use it) and run
the built image with the same `--network` + proxy env.

## Verify

- `egresslock denied main` lists anything hermes still tried and
  was blocked — that is the feed for the next `allow`.
- Redirect rule (same as the opencode recipe): a 403 may not be the
  host you asked for — the redirect target needs its own allowlist
  entry. `denied main` shows the real hostname.