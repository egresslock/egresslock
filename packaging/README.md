# How to: build and install the packaged kit

The packaging is a thin, optional convenience: clone +
`install-kit.sh --prefix /opt/egresslock` stays the primary deploy and
is what the harnesses test. Both channels below are built from a
checkout; build artifacts are **not** committed.

Do **not** install the .deb and the prefix deploy on the same host —
never run both at once. Cutover from the prefix deploy to the .deb:
`uninstall-kit.sh` first, then `dpkg -i`.

## .deb (apt)

Build (no root needed — `dpkg-deb --root-owner-group` records root
ownership in the archive):

```sh
./packaging/build-deb.sh
# -> packaging/egresslock_<VERSION>_all.deb
#    (redirect with EGRESSLOCK_DEB_OUT=<path>)
```

Requires `dpkg-deb` (any Debian with dpkg ≥ 1.19); no debhelper, no
`debian/` project — the script stages an FHS tree and runs
`dpkg-deb --root-owner-group --build`.

Package facts: name `egresslock`, `Architecture: all`,
version `<VERSION_BASE>+git<YYYYMMDDHHMMSS>.<12-char-sha>` (`-dirty` on
a dirty tree; the UTC second-resolution timestamp is the dpkg ordering
key so rebuilds never compare as a downgrade),
`Depends: bash, podman, netavark, nftables`, `Recommends: apparmor`.
Layout: `/usr/bin/egresslock` and `/usr/sbin/egresslock-setup` are
wrappers around `/usr/lib/egresslock/` (engine, helpers, `gateway/`,
`VERSION`); data under `/usr/share/egresslock/{examples,doc,apparmor}`;
unit templates in `/usr/lib/systemd/system/`. A site-name screen keeps
fleet-fact docs/recipes out of the package.

Install + first run on the target host:

```sh
sudo dpkg -i ./egresslock_<VERSION>_all.deb
sudo egresslock-setup --account <acct> --init-conf --enable
sudo egresslock-setup --apparmor-check   # confirm pasta AppArmor compatibility on this host
```

The account setup needs no repo and no `--prefix` on a .deb-only host
(the prefix is derived from the installed unit template).

## Version stamp

One release base lives in `VERSION_BASE` at the repo root (a single
line, e.g. `0.1.0`; no quotes, trailing newline is fine). `build-deb.sh`,
`build-tarball.sh`, and `install-kit.sh` all read it and **fail closed**
if it is missing or empty — bumping the release base is that one edit;
the `+git<YYYYMMDDHHMMSS>.<short12>[-dirty]` suffix is
unchanged.

Every `VERSION` stamp written by `install-kit.sh` or the .deb build
starts with the full version string:

```text
version: <VERSION_BASE>+git<YYYYMMDDHHMMSS>.<commit>
commit:  <full sha or unknown>
deployed: <UTC ISO>
```

`egresslock --version` prints that file (or `dev` when no stamp is
deployed). The tarball additionally ships a stage-only `KIT_VERSION`
containing the build version string; `install-kit.sh` uses it as the
`version:` value when present, so a tarball install does not re-stamp
as `+git<install-time>.unknown`. `KIT_VERSION` is never committed.

Uninstall: `sudo apt remove egresslock`. Podman state, account data
(`~/.config/egresslock`), and the pasta local snippet are never touched
by dpkg — run `egresslock teardown --runtime` as the account
first, while the engine still exists (and
`egresslock-setup --apparmor-remove` if you applied the pasta
amendment); then see the post-remove verification checklist in
[Uninstall](../docs/setup/uninstall.md) → Verify it's fully gone.

## tar.gz (manual, self-contained)

```sh
./packaging/build-tarball.sh
# -> packaging/egresslock_<VERSION>.tar.gz
#    (redirect with EGRESSLOCK_TARBALL_OUT=<path>)

tar -xzf egresslock_<VERSION>.tar.gz && cd egresslock
sudo ./install-kit.sh --prefix /opt/egresslock
sudo /opt/egresslock/egresslock-setup --account <acct> --init-conf --enable
```

The tarball is the full kit tree (engine, helpers, gateway, examples,
docs, apparmor, `install-kit.sh` **and** `uninstall-kit.sh`) plus the
`systemd/` unit templates, so on-box uninstall needs no repo clone:

```sh
sudo ./uninstall-kit.sh --prefix /opt/egresslock
```

(account teardown first: `egresslock teardown --runtime` as the
account, while the engine still exists.)

## Test hooks

| Variable | Purpose |
|---|---|
| `EGRESSLOCK_DEB_OUT` / `EGRESSLOCK_TARBALL_OUT` | redirect the artifact path |
| `EGRESSLOCK_DEB_KEEP_STAGE=<dir>` | keep the staged .deb tree instead of building (file-set asserts without dpkg) |
| `EGRESSLOCK_UNIT_SRC=<dir>` | unit-template source override |

(The root-gated kit scripts are `install-kit.sh`/`uninstall-kit.sh`
and `egresslock-setup`; the packaging builds themselves run as any
user.)

Both scripts are exercised by the kit harness
(`tests/test-kit.sh`; run all egresslock
tests with `tests/run.sh`).
