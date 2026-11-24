# The gateway image (rebuilds and maintenance)

This page answers: what the kit-built gateway image is, when to rebuild
it, how to rebuild and replace a running gateway, and what the doctor's
`gateway image:`, `stale:`, `rebuild:`, and `running gateway:` lines
mean.

## What the gateway image is

The gateway image (`localhost/egresslock-gateway:latest` by default) is
built once — at account setup (quiet; the stream goes to the account's
`~/.config/egresslock/gateway-build.log`), or later by
`egresslock build-gateway`
(or the `egresslock-setup build-gateway` alias) — from the deployed
`gateway/Containerfile`. Its base is a single Debian digest pin; the
image never updates itself, and a kit upgrade alone does not touch an
existing image. What the pin does and does not guarantee is in
[Where the base pin and labels live](#where-the-base-pin-and-labels-live).

## When to rebuild the gateway image

**Nothing rebuilds the image automatically, and you do not need to
check it every day.** Rebuild when one of these is true:

- **The doctor prints a `rebuild:` line.** The kit records a security
  rebuild floor when an advisory requires a same-pin refresh; the date
  and the advisory that set it are recorded in `gateway/security-floor`
  (see
  [Where the base pin and labels live](#where-the-base-pin-and-labels-live)).
  An image created before that floor, or one more than 30 days old,
  gets an advisory line naming the date and the exact rebuild command.
  The floor is the specific signal; the 30-day age is an offline
  backstop for a kit that has not been upgraded — and age alone never
  triggers the no-cache build (only the floor does).
- **The release notes say so.** When you install a kit update, its
  release notes say whether the gateway base changed. That note is a
  trigger.
- **You decide to refresh the unpinned packages yourself**, for
  example after a security advisory about the squid proxy. Rebuild the
  image from the deployed pin (`egresslock build-gateway --force` when
  the pin did not change — see
  [Where the base pin and labels live](#where-the-base-pin-and-labels-live)).
  A same-pin rebuild refreshes **only the unpinned packages** (the
  squid apt package): it does not refresh the Debian base. The base
  moves only when a kit release refreshes the pin (see the section
  below).

## Rebuild and replace the gateway

Rebuild **once per account**, then replace **every profile** in
that account; repeat per account if you run more than one.
`egresslock ensure` on a healthy gateway does not compare image
identity, so a rebuild reaches a profile only when you rebuild the
image **and then replace** that profile's container with
`egresslock ensure --replace-gateway PROFILE`. As the account:

- **The release notes say the base moved, or the doctor printed the
  floor `rebuild:` line:**

  ```sh
  egresslock build-gateway && egresslock ensure --replace-gateway PROFILE
  ```

- **The doctor printed the age `rebuild:` line, or you are refreshing
  the unpinned packages yourself** (for example after a squid
  advisory) **and the pin did not move** — add `--force`:

  ```sh
  egresslock build-gateway --force && egresslock ensure --replace-gateway PROFILE
  ```

Without `--force`, `build-gateway` prints
`already built from deployed pin … use --force to rebuild` and exits 0
— the `&&` would then go on to replace the container with the
**un-refreshed** image, severing the profile's sessions without
applying anything. The `&&` runs the replace **only if the build
succeeded**: with the old image still tagged, a replace after a failed
build would succeed against it, drop the profile's proxied sessions,
and put the **same old base** back on the profile. Never replace on a
failed build.

What the two commands do:

- `build-gateway` (`egresslock-setup build-gateway` is an alias of the
  same verb) rebuilds the image into the account's store from the
  deployed `gateway/Containerfile`. It needs the account's systemd user
  manager active; if it is not, it exits 1 and names the fix. If the
  build itself fails, stop: it exits 1 and prints the exact command to
  re-run once you have fixed the cause — the replacement only happens
  after a successful build.
- `ensure --replace-gateway <profile>` replaces that profile's running
  gateway container with one from the rebuilt image — replacing the
  container severs that profile's proxied sessions until the new
  gateway answers, and the command prints a notice first. It refuses a
  missing or unsafe target image **before** removing the running
  gateway, and there is no need to remove the container or image by
  hand first: the replacement happens in one step. Plain
  `egresslock ensure PROFILE` does not replace a healthy gateway; the
  `--replace-gateway` flag is the explicit replace step.

If the replacement itself fails, stop and fix the profile before moving
on: the next `--replace-gateway` is still available. A replacement that
failed **after** the removal left the profile without a running
gateway; a refusal at the preflight (missing or unsafe target image)
did not — the old gateway keeps running. Check which happened before
retrying.

**Every profile in the account needs its own replace** — build
once, replace each:

- A profile whose container is not replaced keeps running the old image
  (and the old base's vulnerabilities) even though the rebuilt image is
  in the store; the engine doctor's `running gateway:` row names that
  profile.
- List the account's profiles with `egresslock list`, and replace each
  profile's gateway in turn — the profiles'
  `gateway <ip> <port> <allowlist>` lines are defined in the
  [policy reference](policy-reference.md).
- A rebuilt image lives in **one account's store**. Build again in each
  other account's shell and replace that account's profiles —
  rebuilding as one account does not deploy the image elsewhere.

## What the doctor prints

Both doctors print a `gateway image:` row, which shows which base your
image was built from and when: `egresslock doctor` (run as the account,
no root; it takes no account name) and `sudo egresslock-setup doctor
ACCOUNT`. The engine doctor also prints the `running
gateway:` rollout row (below); the setup doctor keeps the image row
only and prefixes its top-level rows with `OK:`/`PROBLEM:`.

The rows are advisory — the gateway keeps working on the old base until
you rebuild, and the doctor exit code stays 0 — with one exception: the
setup doctor treats a missing image as a PROBLEM and exits 1.

| Row | Meaning | What to do |
|---|---|---|
| `gateway image: missing (<tag>)` | No image in the account's store. | Build it: `egresslock build-gateway` (the setup doctor's fix line also offers re-running `init`, whose bundle builds it). |
| `gateway image: present (<tag>) — base <digest>, built <date>` | Clean: the image matches the deployed pin and is not due a refresh. | Nothing. |
| `stale: base pin moved (image base … != deployed pin …)` | The image was built from an older pin than the deployed `Containerfile` expects — in practice, right after a kit update whose notes said the base changed, and until you rebuild. | Rebuild, then replace (recipe above). A plain build is enough: the moved pin already invalidates the old cached layers. |
| `stale: base unknown (pre-label image)` | The image predates the base label, so its base cannot be read. | Rebuild, then replace. When the kit records a floor, this build passes `--no-cache` on its own, so a pre-floor apt layer cannot be reused. |
| `rebuild: … older than the kit's security rebuild floor <date> …` | The image matches its kit but predates the recorded security rebuild floor. | Rebuild, then replace. A plain build already passes `--no-cache`; the doctor's printed command also includes `--force`, which is harmless. |
| `rebuild: … is more than 30 days old …` | Age backstop for a kit that has not been upgraded. When both apply, the floor line wins so the specific reason stays legible. | Rebuild with `--force`, then replace; also check for a newer egresslock release. |
| `running gateway: <profiles> run(s) a different image — …` | Rollout check (engine doctor only): a running gateway container's image ID differs from the tagged image's. | Clean image row → replace only. Image row showed `stale:`/`rebuild:` → rebuild first, then replace. |
| `running gateway: UNKNOWN — cannot compare to the built image (<cause>)` | The running list, a container's image ID, or the tagged image ID could not be read. | Fix the named cause and run the doctor again. |

If the image itself could not be inspected, the row reads `base
unknown` without `stale:` — rebuild when the release notes or the age
line say to.

The `rebuild:` floor is a date proxy: an image built after the floor
can still carry an old package if its apt layer was cached by a manual
build, and a rebuild between the fix and the floor can warn although it
already has the fix.

**The image row is about the image; the `running gateway:` row is the
rollout check.** It compares each running
`egresslock-gateway-<profile>` container's image ID to the tagged
image's ID and prints one advisory line when they differ, naming the
profiles. It is silent when no gateway runs, when every running gateway
matches, and when the tagged image is absent. The row proves an
image-ID difference at doctor time only: not why it differs, not since
when, and not that a stopped or unstarted profile is affected.
Absence of `stale:`/`rebuild:` is still not a rollout check on its own
— use the `running gateway:` row and the recipe above.

## Where the base pin and labels live

The pin is the `FROM …@sha256:…` line in the deployed
`gateway/Containerfile`. The security rebuild floor is the ISO date in
the deployed `gateway/security-floor` next to it (a comment names the
advisory that set it); the kit bumps it in the same change that issues
a gateway rebuild note. The built image carries matching OCI labels
(`org.opencontainers.image.base.name`,
`org.opencontainers.image.base.digest`) so `podman image inspect` and
the doctor can read which base an image was built from. Refreshing the
pin is a deliberate kit decision, recorded in that release's notes —
you do not hand-edit the deployed Containerfile. A rebuild with the
same pin (`--force`) refreshes only the unpinned packages (the squid
apt package takes distro security updates this way); the frozen
Debian base itself moves only when a kit release refreshes the pin.
The pin freezes what the kit **asks for** — the base reference the
build pulls — and the digest match is only as strong as the host's
digest checking: on some Podman versions a digest can resolve to
different layers/config than the one the kit pinned, so the pin is
build-input identity, not an absolute content guarantee. The exact
version ranges and the advisory behind this are in the threat model's
[trusted computing base](threat-model.md#trusted-computing-base).

What the gateway does at runtime is in the threat model's
[trusted computing base](threat-model.md#trusted-computing-base)
(caps asserted, checkpoint annotation refused).
To remove the kit entirely, see [uninstall](../setup/uninstall.md).
