# egl-base — shared example image

A small Debian image with the clients the quickstarts use (curl, ssh,
git, dig, ping, rsync, ncat). Built from the same pinned Debian base as the
gateway. Build it once per account; later pages assume the tag exists.

## Build

The helper sits next to the Containerfile. It builds
`localhost/egl-base:latest` if the image is missing, was built from an
older Debian base, or predates the kit's recorded security rebuild
floor (`security-floor`, next to the script). A rebuild that cannot be
shown to be at or after the floor (missing, pre-label, no build date,
or below it) uses `--no-cache` so the apt packages are re-fetched; if
the image already matches the pin and the floor, it prints one
up-to-date line. It does not start a container.

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
Building localhost/egl-base:latest FROM a72b4433de1c
Done: localhost/egl-base:latest
```

(`a72b4433de1c` is the first 12 hex of the deployed Debian base pin
in this Containerfile. podman build output sits between the Building
and Done lines.)

Re-run when current:

```text
already built from deployed pin a72b4433de1c — use --force to rebuild
```

Below the recorded floor (for example after a `ca-certificates`
advisory), a plain run prints:

```text
egl-base image: built 2026-10-15 predates the recorded rebuild floor 2026-10-20 — rebuilding with --no-cache
Building localhost/egl-base:latest FROM a72b4433de1c
Done: localhost/egl-base:latest
```

`--force` rebuilds even when current (refreshes the apt packages in
the example image). Age alone does not trigger a build here: the
doctor's age warning names `--force`. `-h` prints help.

Manual fallback (same tag, same context):

```sh
podman build -t localhost/egl-base:latest \
    /usr/share/egresslock/examples/egl-base
```

(Prefix: `/opt/egresslock/examples/egl-base`. Checkout:
`examples/egl-base`.)

## What's inside

Debian 13 slim plus: `ca-certificates`, `curl`, `dnsutils` (`dig`),
`git`, `iputils-ping`, `ncat`, `openssh-client`, `rsync`. No compilers
or build toolchains.

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

Re-run the helper as the account. If this release moved the Debian
base, it reports stale and rebuilds; if the release recorded a
security rebuild floor for a same-pin package refresh, the helper
rebuilds with `--no-cache` even though the pin did not move. If the
pin and floor both pass, it prints the up-to-date line. A refresh the
kit did not record (for example a manual `podman build`) cannot be
detected by date — rebuild once with `--force`. See
[The gateway image](../../docs/reference/gateway-image.md).

## Doctor row

`egresslock doctor` (and `sudo egresslock-setup doctor --account
<acct>`) prints an `egl-base image:` row when the image exists,
mirroring the gateway row: the base digest and build date, a `stale:`
line for a moved pin or pre-label image, and a `rebuild:` line when
the image predates the kit's floor (specific signal) or is more than
30 days old (offline backstop). The row is advisory and rc-neutral;
the remedy names this helper. When the image is absent, the row is
skipped.
