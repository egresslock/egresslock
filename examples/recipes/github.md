# Recipe: GitHub from a container

Goal: clone and push to GitHub from a workload container on a profile
network, with the profile's fail-closed policy intact. `github.com` answers
with **one rotating address per query**, so a plain `allow-host
github.com:22` can never hold. The easiest path is HTTPS through the
gateway — the name is resolved per request, so nothing is pinned and
nothing drifts; SSH (deploy keys, agent forwarding) still works via a name
tunnel or a pinned pool. The mechanism, the address-discovery methods, and
the tradeoffs: [Rotating names](../../docs/reference/rotating-names.md).

Run every command as the dedicated account (`sudo -iu egl-runner`) unless a
block says otherwise.

The shared `egl-base` image ships the tools this recipe uses (`git` for
HTTPS clones, `ncat` for the SSH tunnel); if you built the image before the
current release, rebuild it once
([egl-base](../../examples/egl-base/README.md#after-a-kit-upgrade)).

## Path 1 (recommended) — HTTPS through the gateway

HTTPS sidesteps the rotating-name problem entirely: the gateway resolves
`github.com` at request time — no pin, no `drift:`, nothing to maintain.

### 1. Allow the name

```sh
# account — run as the dedicated account: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock allow main github.com
```

`allow main github.com` appends the name to the gateway
allowlist (the bare host is the port-443 group); the gateway resolves it
per request, so there is no address to drift. If an earlier
`allow-host github.com:22` is still in the profile's conf, remove it as
well (`egresslock disallow-host main github.com:22`) so its `drift:`
warnings stop — [Rotating
names](../../docs/reference/rotating-names.md) shows the replace flow.

### 2. Run a container with the proxy env

```sh
# account — run as the dedicated account: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock ensure main \
 && podman run --rm -it \
    --network="$(egresslock network main)" \
    --env-file="$(egresslock proxy-env main --out)" \
    --cap-drop=all --security-opt=no-new-privileges \
    localhost/egl-base:latest \
    sh
```
Error launching due to missing image? Build it: 
[egl-base](../../examples/egl-base/README.md#build)

This example is an exception to the [container hardening
baseline](../../docs/reference/container-hardening.md) for 
demonstration purposes: no `--userns=keep-id` (no host bind mount
to serve), and no `--read-only`. This is a working shell (clones
and pushes write the container rootfs), not a locked-down service
container.

### 3. Clone

```sh
# workload — the container shell
# prompt: root@9badc0ffee67:/#

cd ~/
git clone https://github.com/<org>/<repo>.git
```

`git` reads the lowercase `https_proxy` ([proxy
clients](../../docs/reference/proxy-clients.md)) — the env-file carries it,
nothing else to configure. 

> [!NOTE]
> **credential caveat to this path**
> 
> Public clones are credential-free; *push and private repos need a personal
> access token* in a credential helper (deploy keys and agent forwarding do 
> not map to HTTPS). Some operations touch other GitHub hosts 
> (`objects.githubusercontent.com` for LFS, `codeload.github.com` for
> release downloads) — `allow` those the same way if you need them.

## Path 2 — SSH through the gateway (tunnel by name)

If you need SSH (deploy keys, agent forwarding), a CONNECT-capable client
can tunnel by name — `ncat` comes with the shared `egl-base` image: the
gateway resolves `ssh.github.com` (GitHub's port-443 SSH endpoint) at
connection time; nothing is pinned.

### 1. Allow the destination

```sh
# account — run as the dedicated account: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock allow main ssh.github.com
```

`ssh.github.com` is GitHub's port-443 SSH endpoint.

### 2. Run a container with the proxy env

```sh
# account — run as the dedicated account: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock ensure main \
 && podman run --rm -it \
    --network="$(egresslock network main)" \
    --env-file="$(egresslock proxy-env main --out)" \
    --cap-drop=all --security-opt=no-new-privileges \
    localhost/egl-base:latest \
    sh
```

*(Same stated exception as Path 1 step 2.)*

### 3. Point ssh at the gateway

Get the gateway address in the **account** shell first — the container has
no `egresslock`:

```sh
# account — run as the dedicated account: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock proxy-env main proxyip
egresslock proxy-env main proxyport
```

Those two outputs are `<gw-ip>` and `<gw-port>`. Then write the ssh config
in the container — one `printf` so the whole file is a single paste:

```sh
# workload — the container shell
# prompt: root@9badc0ffee67:/#

mkdir -p ~/.ssh
printf 'Host github.com\n    HostName ssh.github.com\n    Port 443\n    ProxyCommand ncat --proxy <gw-ip>:<gw-port> --proxy-type http --proxy-dns=remote %%h %%p\n' > ~/.ssh/config
```

### 4. Test

```sh
# workload — the container shell
# prompt: root@9badc0ffee67:/#

ssh -o ConnectTimeout=10 -T git@github.com
```

> [!TIP]
> gateway port and IP are static and defined in the conf file for that profile.

First connect shows the host key — compare the `SHA256:…` fingerprint with
[GitHub's published
fingerprints](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
before typing `yes`. Then either `Permission denied (publickey).` (no keys) or
`Hi <you>! You've successfully authenticated…` — both prove the path.

Caveats: an idle tunnel can be cut at the profile's `read-timeout` (default
900 s) — [long request dies at exactly
15m](../../docs/troubleshooting/long-request-15m.md); the name-at-connect-time
identity of a tunneled non-HTTP connection is a known, accepted tradeoff —
see the [threat model](../../docs/reference/threat-model.md).

## Path 3 — SSH with pinned literals (direct, no client changes)

No proxy config, no helper; the cost is a line whenever GitHub adds a
member. While `allow-host github.com:22` is still in place, find the members
with the methods in [Finding the pool
members](../../docs/reference/rotating-names.md#finding-the-pool-members),
then replace the name (skip `disallow-host` if the pin is not in the conf):

> [!NOTE]
> it may take some time to identify all member IPs using this method.

```sh
# account — run as the dedicated account: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock disallow-host main github.com:22
egresslock allow-host main <member-ip-1>:22
egresslock allow-host main <member-ip-2>:22
```

A plain container — no proxy env needed:

```sh
# account — run as the dedicated account: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock ensure main \
 && podman run --rm -it \
    --network="$(egresslock network main)" \
    --cap-drop=all --security-opt=no-new-privileges \
    localhost/egl-base:latest \
    sh
```

```sh
# workload — the container shell
# prompt: root@9badc0ffee67:/#

ssh -o ConnectTimeout=10 -T git@github.com
```

The literals are the only permitted addresses and the profile's fail-closed
policy still holds. No address list ships here — the discovery methods give
you *your* resolver's current members.

## Reading more

- [Rotating names](../../docs/reference/rotating-names.md) — the mechanism,
  the options, and how to find the addresses.
- [Proxy clients](../../docs/reference/proxy-clients.md) — the client list,
  including the ssh row.
- [Allow a domain](../../docs/quickstart/allow-a-domain.md) — the 403 → allow
  → confirm loop for HTTP(S) destinations.
