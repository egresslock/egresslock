# egl-base — shared example image

A small Debian image with the clients the quickstarts use (curl, ssh,
dig, ping, rsync). Built from the same pinned Debian base as the
gateway. Build it once per account; later pages assume the tag exists.

## Build

The helper sits next to the Containerfile. It builds
`localhost/egl-base:latest` if the image is missing or was built
from an older Debian base; if the image already matches, it prints
one up-to-date line. It does not start a container.

`.deb` install:

```sh
/usr/share/egresslock/examples/egl-base/build-egl-base
```

Prefix install (`install-kit.sh`, default prefix):

```sh
/opt/egresslock/examples/egl-base/build-egl-base
```

From a checkout, at the repository root:

```sh
examples/egl-base/build-egl-base
```

First run (image missing) prints:

```text
egl-base image: missing (localhost/egl-base:latest)
>> Building localhost/egl-base:latest FROM a29215f6a35e
>> Done: localhost/egl-base:latest
```

(`a29215f6a35e` is the first 12 hex of the deployed Debian base pin
in this Containerfile. podman build output sits between the Building
and Done lines.)

Re-run when current:

```text
already built from deployed pin a29215f6a35e — use --force to rebuild
```

`--force` rebuilds even when current (refreshes the apt packages
in the example image). `-h` prints help.

Manual fallback (same tag, same context):

```sh
podman build -t localhost/egl-base:latest \
    /usr/share/egresslock/examples/egl-base
```

(Prefix: `/opt/egresslock/examples/egl-base`. Checkout:
`examples/egl-base`.)

## What's inside

Debian 13 slim plus: `ca-certificates`, `curl`, `dnsutils` (`dig`),
`iputils-ping`, `openssh-client`, `rsync`. No compilers or build
toolchains.

## Extend it

Write your own Containerfile:

```
FROM localhost/egl-base:latest
RUN apt-get update && apt-get install -y --no-install-recommends <pkg> \
    && rm -rf /var/lib/apt/lists/*
```

`podman build` runs on the host (the fail-closed policy applies to
workload containers, not to the build).

## After a kit upgrade

Re-run the helper as the account. If this release moved the
Debian base, it reports stale and rebuilds; if the pin did not
move, it prints the up-to-date line. See
[The gateway image](../../docs/reference/gateway-image.md).
