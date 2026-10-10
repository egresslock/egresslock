# Files the kit installs (and what a checkout contains)

This page answers: **"what did the kit put on my host, and what is in
the source tree?"** The install procedure that produces these files:
[Install the kit](../setup/install.md).

## The `.deb` layout

The `.deb` installs FHS-layout, engine on `PATH` — `dpkg -L
egresslock` lists the real thing:

- `/usr/bin/egresslock` — wrapper → `/usr/lib/egresslock/egresslock`
- `/usr/sbin/egresslock-setup` — wrapper → `/usr/lib/egresslock/egresslock-setup`
- `/usr/lib/egresslock/` — the engine, `egresslock-setup`,
  `egresslock-start`, `egresslock-verify`, `gateway/`, and `VERSION`
- `/usr/lib/systemd/system/egresslock-verify@.{service,timer}` — the
  verify unit templates
- `/usr/share/egresslock/` — shipped support files, incl. the docs
  tree under `doc/`

## Deployed kit (manual prefix install)

The kit is deployed ROOT-owned to `--prefix` (default
`/opt/egresslock`):

| File / dir | What it is |
|---|---|
| `egresslock` | the engine CLI (`ensure`, `verify`, `list`, `network`, `rules`, `allowlist`, `denied`, `allow`/`disallow`, `allow-host`/`disallow-host`, `init`, `doctor`, `teardown`, ...) |
| `egresslock-start` | daemon-start wrapper: `ensure` the profile, then exec the daemon |
| `egresslock-verify` | entry point for the verify timer (named or `--ensured`) |
| `egresslock-setup` | per-account bootstrap: ship starter conf, validate, write `unit.env`, build gateway, enable timer |
| `gateway/` | build context for the Squid gateway image (`Containerfile`, `squid.conf`, entrypoint) |
| `apparmor/` | pasta AppArmor snippet + profiles shipped root-owned with the prefix (distribution only — applying stays the explicit `egresslock-setup --apparmor-add`; see `apparmor/README.md`) |
| `examples/` | starter conf + empty allowlist for `egresslock-setup --init-conf`; `recipes/` deployed so accounts build from the prefix; `egl-base/` so accounts build the shared example image from the prefix (includes the `build-egl-base` helper) |
| `VERSION` | `commit:` SHA + `deployed:` UTC date (+ `-dirty` marker) of what is installed |

Unit templates installed to `/etc/systemd/system/` (overridable via
`EGRESSLOCK_UNIT_DIR`):

| Unit | What it is |
|---|---|
| `egresslock-verify@.service` | runs `egresslock-verify` as the account (instance = account) |
| `egresslock-verify@.timer` | 15-min drift signal, `Persistent=true` |

## Source tree (what a checkout contains)

The **deployed** kit is a subset of this. Paths are relative to the
repository root:

| Path | What it is |
|---|---|
| `egresslock` | The engine CLI: `ensure`, `verify` (incl. `--ensured`), `list`, `network`, `proxy-env` (tokens: `proxyip`/`proxyport`/`noproxy`), `rules`, `allowlist`, `denied` (`--all`, `--days N`), `allow`/`disallow`, `allow-host`/`disallow-host`, `init`, `doctor`, `build-gateway` (incl. `--force`), `teardown` (incl. `--runtime`), `--version` |
| `install-kit.sh` | (root) Deploy the kit to a prefix and install the instanced verify unit templates (no account changes) |
| `egresslock-setup` | (root) One-command per-account setup: ship the starter conf with `--init-conf`, validate conf, write `unit.env`, build the gateway image, optionally enable the timer |
| `uninstall-kit.sh` | (root) Remove the kit; account data is preserved unless `--purge-account-data` |
| `egresslock-start` | Wrapper for daemon services: `ensure $EGRESSLOCK_PROFILE` (fail closed), then exec the daemon |
| `egresslock-verify` | Entry point for the verify timer: named profile or `--ensured` mode |
| `gateway/` | Build context for the Squid gateway image (`Containerfile`, `squid.conf`, entrypoint) |
| `examples/` | Starter conf + empty allowlist shipped by `install-kit.sh` for `egresslock-setup --init-conf`; recipes under `recipes/`; `egl-base/` (shared example image) (includes `build-egl-base`) |
| `build-gateway` | Build the gateway image into the current user's store (checkout use) |
| `tests/` | Mock battery: `bash tests/run.sh` runs every `tests/test-*.sh` harness (`test-engine.sh`, `test-kit.sh`, `test-docs.sh`, …; no root/Podman needed) |
| `packaging/` | `build-deb.sh` (FHS `.deb`, thin `dpkg-deb` build) and `build-tarball.sh` (self-contained manual-install tar.gz incl. `uninstall-kit.sh`); `README.md` (the packaging guide) |
| `docs/` | the shipped docs tree (quickstart / setup / reference / troubleshooting; see the [docs map](../README.md)) |
