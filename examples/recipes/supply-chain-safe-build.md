# Recipe: mitigating supply-chain risk by shackling code compilation

Goal: build/compile untrusted (or supply-chain-attacked) code on a dev
machine while constraining it to a tiny, reviewable egress — a
malicious dependency can't phone home, and every denied attempt shows
up in `denied`.

## What you end up with

```
# ~/.config/egresslock/build.conf            (created by `init build`)
profile build 10.199.<auto>.0/24
    rule gateway-only
    gateway 10.199.<auto>.2 3128 build-allowlist

# ~/.config/egresslock/build-allowlist       (example below)

# ~/work/build/                              persistent folder on the host;
#                                            you deliver the code here
```

## 1. Create the profile and allow only what the build needs

Run as the dedicated `<account>` (a dedicated account for builds is
worth the isolation — profiles are per-account):

```sh
sudo -iu <account>
```

```sh
egresslock init build
```

Allow only the registries/mirrors the build actually needs — the
example below is a Node/Python build; adjust to your toolchain.
Everything else stays denied: no telemetry, no callbacks, no exfil.

```sh
egresslock allow build registry.npmjs.org:443
egresslock allow build pypi.org:443
egresslock allow build api.github.com:443
```

Then build the network + policy:

```sh
egresslock ensure build
```

`egresslock denied build` after a failed step tells you exactly which
host the build tried to reach — the "learn what it needs, then pin"
loop.

## 2. Deliver the code through the persistent folder

The container is disposable; the code arrives via a persistent folder
on the host (your checkout/workdir, where build outputs survive too):

```sh
mkdir -p "$HOME/work/build"
# put the source tree you want to build into ~/work/build now
```

## 3. Run the build container

```sh
# do the build
podman run --rm -it --name safe-build \
    --network="$(egresslock network build)" \
    --env-file=<(egresslock proxy-env build) \
    -v "$HOME/work/build:/workspace:rw" \
    <build image> \
    sh -c 'cd /workspace && make'
```

Replace `<build image>` / `make` with your toolchain (e.g.
`debian:13-slim` + `npm ci && npm run build`). The profile's policy
applies at runtime — the build can reach only the allowlisted
registries, nothing else. After a host reboot, re-run
`egresslock ensure build` (or `egresslock-start`) before this
`podman run` — the network object survives reboot without its policy
([after-a-reboot](../../docs/troubleshooting/after-a-reboot.md)).
