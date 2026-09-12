# Recipe: opencode in a debian:13-slim container (npm install)

Goal: run the opencode agent inside a `debian:13-slim` workload with
egress to exactly the four hosts it needs — `deb.debian.org` (apt),
`registry.npmjs.org` (npm), `github.com` (VCS), and `openrouter.ai`
(LLM API) — everything else denied by the profile's fail-closed
policy. This is the tested-2026-09-05 version of the code-install path
from [agentic-tool-opencode.md](agentic-tool-opencode.md), and the
successor to the older debian-github-openrouter walkthrough, which it
absorbs.

Run every command **as the account** (`sudo -iu <account>`).

## What you end up with

The only file this recipe changes is the allowlist (the starter
`main.conf` already exists from `egresslock-setup --init-conf`):

> ```
> # ~/.config/egresslock/main-allowlist
> deb.debian.org:80
> deb.debian.org:443
> registry.npmjs.org
> github.com
> openrouter.ai
> ```

## 1. Allow the destinations

Run as the dedicated `<account>` (never root):

```sh
sudo -iu <account>
```

```sh
egresslock allow main \
    deb.debian.org:80 deb.debian.org:443 \
    registry.npmjs.org github.com openrouter.ai
```

Ports matter here:
- `deb.debian.org` needs BOTH `:80` and `:443`: apt fetches the
  `InRelease` files over plain HTTP (port 80), then deb.debian.org
  redirects to HTTPS. The no-port allowlist group only matches port
  443, so the plain-HTTP fetch 403s without an explicit `:80` entry.
- Bare hostnames (`registry.npmjs.org`, `github.com`,
  `openrouter.ai`) are enough — the gateway resolves them and matches
  any port. (In the absorbed debian-github-openrouter walkthrough the
  bare `github.com` allowed apt to reach it; opencode uses it for VCS
  clone/fetch.)

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

## 3. Inside the container

```sh
apt update
apt install npm -y
npm install -g opencode-ai
opencode
```

## Persistence caveat (and the durable alternative)

That `podman run --rm` container is ephemeral — exit the shell and the
apt/npm installs are gone. The `opencode` you just installed is gone
with it. For a reusable setup, bake the install into an image and run
that:

```sh
# Containerfile
FROM docker.io/library/debian:13-slim
RUN apt-get update && apt-get install -y npm \
 && npm install -g opencode-ai
```

Build it (in the account's store so the profile can use it) and run
the built image with the same `--network` + proxy env. This is the
path that resolves the "how does the code get onto the machine" open
question in [agentic-tool-opencode.md](agentic-tool-opencode.md).

## Verify

- `egresslock denied main` lists anything opencode still tried and
  was blocked — that is the feed for the next `allow`.
- Note the redirect rule: a host that returns 403 may not be the host
  you asked for. `opencode.ai/install`, for example, 307-redirects to
  `raw.githubusercontent.com` — the redirect target needs its own
  allowlist entry.