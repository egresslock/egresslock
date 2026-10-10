# Recipe: agentic tool (opencode) in a custom container under a restricted profile

Goal: a turn-key opencode agent inside a **custom image** on a
restricted profile — egress to exactly `openrouter.ai` (LLM API,
through the gateway) and `github.com` (VCS, git-over-SSH direct rule),
everything else denied. The container is ephemeral; the **workspace
folder persists** on the host, and the API key is never baked into the
image.

Uses the starter `main` profile (from `egresslock-setup --init-conf`);
adapt the profile name if you run on a different one.

## What you end up with

> ```
> # ~/.config/egresslock/main-allowlist      (gateway: HTTPS)
> openrouter.ai:443
> 
> # ~/.config/egresslock/main.conf           (direct rule: SSH)
> rule allow-host github.com:22
> 
> # ~/work/agent/            persistent workspace, mounted at /workspace
> # examples/recipes/agent-container-example/Containerfile   (deployed to /opt/egresslock by install-kit)
> ```

## 1. Set up the profile

Run as the dedicated `<account>`:

```sh
sudo -iu <account>
```

Ensure the starter profile is live, then allow the agent's destinations
— LLM API through the gateway, GitHub as a direct rule (git-over-SSH
bypasses the proxy):

```sh
egresslock ensure main
egresslock allow main openrouter.ai:443
egresslock allow-host main github.com:22   # git-over-SSH
```

## 2. Build the image

install-kit deploys the example to `/opt/egresslock/examples/recipes/agent-container-example`
(no checkout needed). The build runs on the **default rootless network**
— the profile's fail-closed policy applies at runtime, not build time,
so no `--network` or proxy args are needed (and rootless builds can't
join a named network anyway):

```sh
podman build -t localhost/agent-image-example \
    /opt/egresslock/examples/recipes/agent-container-example
```

## 3. Run the agent

```sh
mkdir -p "$HOME/work/agent"

# fail-closed preflight (the assert after the step-1 ensure):
# hardening baseline: layer 1 (always on) + layer 2 (bind mount)
# + layer 3 (disposable rootfs) — see the container hardening baseline
egresslock ensure main \
 && egresslock verify main \
 && egresslock proxy-env main > /run/user/$(id -u)/egresslock-proxy-main.env \
 && podman run --rm -it --name agent-opencode \
    --network="$(egresslock network main)" \
    --env-file=/run/user/$(id -u)/egresslock-proxy-main.env \
    --cap-drop=all --security-opt=no-new-privileges \
    --userns=keep-id \
    --passwd-entry="$USER:x:$(id -u):$(id -g)::/tmp/home:/bin/sh" \
    --env HOME=/tmp/home \
    --read-only --tmpfs /tmp --tmpfs /run \
    -v "$HOME/work/agent:/workspace:rw" \
    localhost/agent-image-example \
    sh -c 'cd /workspace && opencode'
```

The tool reaches exactly `openrouter.ai` (LLM API) + `github.com` (SSH).
The hardening flags are the
[container hardening baseline](../../docs/reference/container-hardening.md)
(why each layer, and the one exception rule). Your work persists in
`~/work/agent`; the container rootfs, `/tmp` and the agent's
`/tmp/home` are all disposable (`--rm`). opencode starts with a blank
config — log in / configure the LLM API inside the container; that
config is gone when the container exits. After a host reboot, re-run
`egresslock ensure main` (or `egresslock-start`) before this
`podman run` — the network object survives reboot without its policy
([after-a-reboot](../../docs/troubleshooting/after-a-reboot.md)).

## Notes

- **Build vs runtime**: the build runs on the default network (open);
  the profile's fail-closed policy applies only to `podman run`. That
  keeps the build simple and the runtime allowlist minimal.
- **The API key is never baked into the image** — configure it inside
  the container. Config/auth does **not** persist across runs
  (`--rm` + the ephemeral `/tmp` tmpfs); a persistent-state variant of
  this recipe is planned follow-up work. Mounting the host home (or a
  `~/.config` subtree) to get persistence is never the answer — see
  the never-mount rule in the
  [container hardening baseline](../../docs/reference/container-hardening.md).
- The redirect rule: a host that 403s may not be the host you asked for
  (e.g. `raw.githubusercontent.com` behind a github.com redirect) — add
  the redirect target to the allowlist.
- A local LLM (e.g. Ollama on the host/LAN) is not reachable through
  the gateway — that needs a direct/host route (the engine is
  hostnames-only today, no CIDR allow yet).