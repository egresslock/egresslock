# The gateway image (rebuilds and maintenance)

This page answers: what the kit-built gateway image is, when to rebuild
it, what the doctor's `stale:` line means, and how to rebuild and
replace a running gateway.

## What the gateway image is

The gateway image (`localhost/egresslock-gateway:latest` by default) is
built once — at account setup, or later by `egresslock build-gateway`
(or the `egresslock-setup --build-gateway` alias) — from the deployed
`gateway/Containerfile`. Its base is a single Debian digest pin; the
image never updates itself, and nothing rebuilds it automatically. A
kit upgrade alone does not touch an existing image, and `egresslock
ensure` on a healthy gateway does not compare image identity — so a
rebuild only reaches a profile when you rebuild the image **and then
replace** that profile's container with
`egresslock ensure --replace-gateway <profile>` (see the recipe below).

## When to rebuild the gateway image

**There is no schedule.** You do not need to check the image every day,
or before installing an update. Rebuild only when one of these is true:

- **The release notes say so.** When you install a kit update, its
  release notes say whether the gateway base changed. That note is the
  trigger; nothing else is.
- **You decide to refresh the unpinned packages yourself**, for
  example after a security advisory about the squid proxy. Rebuild the
  image from the deployed pin (`egresslock build-gateway --force` when
  the pin did not change — see
  [Where the base pin and labels live](#where-the-base-pin-and-labels-live)).
  A same-pin rebuild refreshes **only the unpinned packages** (the
  squid apt package): it does not refresh the Debian base. The base
  moves only when a kit release refreshes the pin (see the section
  below).

### When does the doctor say the image is stale?

`egresslock doctor` (account shell, no root) and `sudo
egresslock-setup --doctor --account <acct>` both print the
`gateway image:` row. The engine doctor is the same check without
root or an account name. The row shows which base your
image was built from and when. It reads `stale:` in two cases: (1)
the kit you have installed expects a different base than the image
was built from — in practice, right after you installed a kit update
whose notes said the base changed, and until you rebuild; (2) an
image built before the base record existed, which reads
`stale: base unknown (pre-label image)`. It does **not** go stale
with age: the built date is for information, and an old image that
matches its kit is not stale.

A `stale:` row is advisory, not an error — the gateway keeps working
on the old base until you rebuild. If the image could not be
inspected, the row reads `base unknown` (not `stale:`) — rebuild
when the notes say to.

**The row is about the image only.** It says nothing about running
containers: after a rebuild the image matches the pin and `stale:`
disappears, even on profiles still running the old image. Absence of
`stale:` is not a rollout check — check the profiles themselves (see
the recipe below).

### Rebuild and replace the gateway

Rebuild **once per account**, then replace
**every gateway profile** in that account; repeat per account if you
run more than one. As the account:

- **The release notes say the base moved:**

  ```sh
  egresslock build-gateway && egresslock ensure --replace-gateway <profile>
  ```

- **You are refreshing the unpinned packages** (for example after a
  squid advisory) **and the pin did not move:** add `--force`. Without
  it, `build-gateway` prints
  `already built from deployed pin … use --force to rebuild` and
  exits 0 — the `&&` would then go on to replace the container with
  the **un-refreshed** image, severing the profile's sessions without
  applying anything.

  ```sh
  egresslock build-gateway --force && egresslock ensure --replace-gateway <profile>
  ```

The `&&` matters in both lines: it runs the replace **only if the
build succeeded**.
A failed build does not stop an ordinary second command in a plain
sequence — with the old image still tagged, the replace would succeed
against it, drop the profile's proxied sessions, and put the **same
old base** back on the profile. Never replace on a failed build.

If the build fails, stop: fix the cause and rebuild successfully
first — the replacement only happens after a successful build. If the
replacement itself fails, stop there too and fix the profile before
moving on: the next `--replace-gateway` is still available. A
replacement that failed **after** the removal left the profile without
a running gateway; a refusal at the preflight (missing or unsafe
target image) did not — the old gateway keeps running. Check which
happened before retrying.

The build (`egresslock-setup --build-gateway` is an alias of the same
verb) rebuilds the image into the account's store from the deployed
`gateway/Containerfile`. `ensure --replace-gateway <profile>` replaces
that profile's running gateway container with one from the rebuilt
image — replacing the container severs that profile's proxied
sessions until the new gateway answers, and the command prints a
notice first. Plain `egresslock ensure <profile>` does not replace a
healthy gateway; the `--replace-gateway` flag is the explicit replace
step — it refuses a missing or unsafe target image **before** removing
the running gateway. (There is no need to remove the container or
image by hand first: `ensure --replace-gateway` does the replacement
in one step.)

**Every gateway profile in the account needs its own replace** —
build once, replace each. A profile whose container is not replaced
keeps running the old image (and the old base's vulnerabilities) even
though the rebuilt image is in the store and the doctor's `stale:` has
cleared, which compares the image, not the running containers. Walk
the account's profile configs for their `gateway <ip> <port>
<allowlist>` lines — the directive is defined in the
[policy reference](policy-reference.md), and a profile whose conf
carries no `gateway` line is not a gateway profile — and replace each
gateway profile in turn.

A rebuilt image lives in **one account's store**. Build again in each
other account's shell and replace that account's gateway profiles —
rebuilding as one account does not deploy the image elsewhere.

If you run the gateway on a non-default image (a custom
`EGRESSLOCK_GW_IMAGE`) or select config explicitly (`--config`, or
`EGRESSLOCK_CONF`), set the same values on **both** commands — the
build and every `ensure --replace-gateway` — the same way you already
set them on plain `ensure`. The commands above assume the default
image and the deployed conf.

## Where the base pin and labels live

The pin is the `FROM …@sha256:…` line in the deployed
`gateway/Containerfile`. The built image carries matching OCI labels
(`org.opencontainers.image.base.name`,
`org.opencontainers.image.base.digest`) so `podman image inspect` and
the doctor can read which base an image was built from. Refreshing the
pin is a deliberate kit decision, recorded in that release's notes —
you do not hand-edit the deployed Containerfile. A rebuild with the
same pin (`--force`) refreshes only the unpinned packages (the squid
apt package takes distro security updates this way); the frozen
Debian base itself moves only when a kit release refreshes the pin.

What the gateway does at runtime is in the threat model's
[trusted computing base](threat-model.md#trusted-computing-base)
(caps asserted, checkpoint annotation refused).
To remove the kit entirely, see [uninstall](../setup/uninstall.md).
