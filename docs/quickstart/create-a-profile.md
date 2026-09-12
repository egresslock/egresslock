# How to: create a profile

One account can run several **profiles**, each with its own Podman
network, nftables policy, and (optionally) gateway + allowlist — all in
the account's single shared rootless netns. Use multiple profiles in
one account when one tenant needs several policies; use separate
accounts only when workloads must not share anything OS-level.

## Create a profile (the steps)

Run as the dedicated `<account>` (never root):

```sh
sudo -iu <account>
```

```sh
# 1. Write the starter pair (auto-picks a free /24):
egresslock init dev
# ~/.config/egresslock/dev.conf
# profile dev 10.199.<auto>.0/24
#     rule gateway-only
#     gateway 10.199.<auto>.2 3128 dev-allowlist
```

```sh
# 2. Build network + anchor + gateway + policy (init only writes files):
egresslock ensure dev
```

```sh
# 3. Shell on the profile network (empty allowlist = allows nothing);
#    the proxy env comes in as one env file:
podman run --rm -it --name example-container-using-dev-profile \
    --network="$(egresslock network dev)" \
    --env-file=<(egresslock proxy-env dev) \
    docker.io/library/debian:13-slim \
    sh
```

`--env-file=<(egresslock proxy-env dev)` injects the profile's six
proxy vars in one go (what they are and why there are six:
[proxy-clients](../reference/proxy-clients.md)).

Explicit `--config <file>` still works everywhere (and always wins);
multi-block confs with several profiles keep using it the same way.

## What it looks like when you're done

One **conf + allowlist pair** on disk and a live profile on the
network:

```sh
egresslock list
# using configs in /home/<account>/.config/egresslock
# NAME           NETWORK                SUBNET
# dev            egresslock-dev          10.199.1.0/24
# main           egresslock-main         10.199.0.0/24
```

On disk:

```
~/.config/egresslock/
├── main.conf          # profile main    (10.199.0.0/24, gateway)
├── main-allowlist
├── dev.conf           # profile dev     (10.199.1.0/24, gateway)
└── dev-allowlist
```

And (as the account) `podman ps -a` shows the kit containers:

```
egresslock-anchor-dev    # keeps the netns + policy alive between workloads
egresslock-gateway-dev   # Squid proxy (gateway profiles only)
```

The profile is now targetable: `egresslock ensure dev`,
`egresslock network dev`, `egresslock proxy-env dev` all
work without `--config`. The allowlist is just entries — e.g.
`api.local:8080` lets that profile reach a local API, nothing else.
Grow it with `egresslock allow` (see
[grow-the-policy](grow-the-policy.md)).

For the conf grammar, naming conventions, the rules to keep straight,
and the verify/teardown/delete lifecycle, see the
[policy reference](../reference/policy-reference.md).

## Next

- [Allow a domain](allow-a-domain.md) — the 403 → allow → confirm loop.
- [Test your container](test-your-container.md) — prove the profile
  allows and blocks as expected.
