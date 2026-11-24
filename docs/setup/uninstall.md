# How to: uninstall the kit

Remove the kit from a host: per-account teardown first, kit removal
last. Account data and Podman state survive unless you purge them.

> **Before you start**
>
> 1. the engine must still exist for teardown — if the package or
>    prefix is already gone, reinstall ([Install](install.md)) first so
>    the engine exists again, then run the teardown step

### 1. Stop every account's verify timer

Stop each account's verify timer first: stopping the timer also stops a
verify run it already started, so no verify runs while the runtime is
removed. Run the line once per account you enabled — an account without
an enabled timer skips it.

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo systemctl disable --now egresslock-verify@ACCOUNT.timer
```

<details><summary>Expected output:</summary>

<pre>
$ sudo systemctl disable --now egresslock-verify@<account>.timer
Removed '/etc/systemd/system/timers.target.wants/egresslock-verify@<account>.timer'.
</pre>
</details>

### 2. Teardown every account's runtime

For every account that has kit runtime — including accounts without an
enabled verify timer — remove the workloads, then run the teardown. The
workloads run on the profile's `egresslock-<name>` network, and
teardown removes only kit-named objects.

The sweep matches the `egresslock-` name prefix, not who created an
object: an `egresslock-*` container or network you created by hand is
treated as a kit object and removed when nothing owns it (an in-use
network is kept and named; containers are force-removed). Rename such
objects before the sweep if they must survive it.

`teardown all --yes` removes the profiles it finds; `teardown
--orphans` sweeps the kit objects their configs left behind and never
touches a live profile.

```sh
# account (one-off) — from your own shell: sudo -iu <account> -- <cmd>
# prompt: $ (your own prompt)

sudo -iu ACCOUNT -- podman ps     # anything on an egresslock-* network
sudo -iu ACCOUNT -- podman rm -f WORKLOAD-NAME ...
sudo -iu ACCOUNT -- egresslock teardown all --yes
sudo -iu ACCOUNT -- egresslock teardown --orphans
```

<details><summary>Expected output:</summary>
`teardown all` names the resolved profiles first (e.g.
`teardown all: 2 profiles: main, staging`), then the per-profile
objects; the sweep names what it removes. `no kit leftovers` means
every listing succeeded and nothing kit-owned remained. A failed
removal or kept network still exits 0 with its own note; a failed or
blind listing keeps the table and exits 1 (`incomplete sweep`, or
`incomplete teardown` during `all`). The remedies are in the
troubleshooting notes below.

<pre>
$ sudo -iu <account> -- egresslock teardown all --yes
teardown all: 2 profiles: main, staging
removed gateway egresslock-gateway-main
removed anchor egresslock-anchor-main
removed network egresslock-main
removed nft chain inet egresslock p_main
removed gateway egresslock-gateway-staging
removed anchor egresslock-anchor-staging
removed network egresslock-staging
removed nft chain inet egresslock p_staging
removed nft table inet egresslock
$ sudo -iu <account> -- egresslock teardown --orphans
no kit leftovers
</pre>

Notes:
- `teardown all --yes` reads the conf directory's file names only (a
  malformed conf cannot block it), prints the profiles it selected,
  and tears down every one.
- If no profile configs remain, `teardown all` exits 2 with a pointer
  and only the sweep is needed.
- State lives in each account's own store, so teardown touches only
  the invoking account's.

Troubleshooting:
- `kept network <name> (in use)` — a workload is still attached; it
  stays policed while the network is kept. Remove it (and disable
  whatever relaunched it), then re-run `teardown all --yes` (or
  `teardown PROFILE`). Do not force-remove the network.
- `note: could not delete nft table inet …` — teardown found the
  table but could not remove it; the removal command is in the message.
- `incomplete sweep` — the sweep could not list part of the runtime
  and exits 1; the note above it names what to check and remove by
  hand, then re-run to confirm. `incomplete teardown` is the same
  disclosure for a named profile or `all`.
- `teardown all found no profile configs …` — the configs are already
  archived; run `teardown --orphans` to remove what they left behind.
</details>

<details><summary>Applied the AppArmor pasta amendment? Unapply it</summary>
Only if you ran `egresslock-setup apparmor add` during install
(marker-scoped:
operator lines in the local include are kept). Runs once, host-wide,
after every account's teardown and never before it — stopping a
rootless container is what needs the amendment (podman signals its
pasta helper when it reclaims the netns), so unapplying while a
workload still runs would block stopping it:

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo egresslock-setup apparmor remove
```

<details><summary>Expected output:</summary>

<pre>
$ sudo egresslock-setup apparmor remove
AppArmor: removed the egresslock pasta amendment from /etc/apparmor.d/local/usr.bin.pasta
</pre>
</details>
</details>

### 3. Remove the kit

`.deb` install (recommended): remove the package. Step 1 already stopped
each account's verify timer — `apt remove` deletes the templates but does
not stop an enabled timer:

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo apt remove egresslock
```

<details><summary>Expected output:</summary>

<pre>
$ sudo apt remove egresslock
The following packages will be REMOVED:
  egresslock
Removing egresslock ...
</pre>

Account data and Podman state survive.
</details>

<details><summary>Tarball (prefix) install: remove with uninstall-kit.sh</summary>
The uninstaller lives in the repository (or a tarball extraction). Set
`PREFIX` to the existing install's absolute path: `/opt/egresslock` only
if you installed there; the PATH wrapper's
`# egresslock-path-wrapper prefix=…` line records it, or use your
recorded path. It stops timers and removes that prefix, PATH wrappers,
and dangling enablements; account data and Podman state survive unless
`--purge-account-data`:

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

PREFIX=/opt/egresslock                 # edit to match your existing prefix
sudo ./uninstall-kit.sh --prefix "$PREFIX" --account ACCOUNT
```

<details><summary>Expected output:</summary>

<pre>
$ sudo ./uninstall-kit.sh --prefix "$PREFIX" --account <account>
uninstall-kit: removed dangling timer enablement: egresslock-verify@<account>.timer
uninstall-kit: removed PATH wrapper /usr/local/bin/egresslock
uninstall-kit: kit removed from /opt/egresslock; instanced templates removed; timers stopped
</pre>

The final line names your chosen prefix; do not continue if the
uninstaller reports that it kept the prefix or could not remove it.
</details>

`--purge-account-data` also deletes the account's confdir
(`~/.config/egresslock`); `--help` lists every option.
</details>

### 4. (Optional) Remove the account

The kit does not delete the `<account>` you created
(`adduser --disabled-password` — see [install](install.md#requirements)).
Once nothing of the account still runs (kit teardown done, non-kit
containers cleaned up), disable linger and delete it:

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo -iu ACCOUNT -- podman ps -a    # confirm nothing still runs
sudo loginctl disable-linger ACCOUNT
sudo userdel -r ACCOUNT             # -r also removes home and mail spool
```

<details><summary>Expected output:</summary>

<pre>
$ sudo loginctl disable-linger <account>
$ sudo userdel -r <account>
</pre>

`userdel` warns and refuses when any of the account's processes
still run (a leftover pasta/podman holder included) — run the
teardown step first.
</details>

### 5. Verify it's gone

Root checks (1–2, 6) and account checks (3–5, for every account that
had runtime):

1. **Timers/templates** (root): `systemctl list-timers --all
   'egresslock-verify@*.timer'` lists no armed instance; per account the
   enablement is gone (`test ! -e .../timers.target.wants/egresslock-verify@<account>.timer`)
   and so are both templates (`test ! -e ...@.service && test ! -e
   ...@.timer`). Do not use `list-unit-files` for the instance check —
   some systemd versions omit an enabled instance.
2. **Prefix** (root): `test ! -e "$PREFIX"` succeeds for the prefix
   chosen in step 3, and its PATH wrappers are gone; `.deb` hosts: no
   `/usr/lib/egresslock`, and `dpkg -l egresslock` says uninstalled.
3. **Containers/networks** (account): `podman ps -a` and
   `podman network ls` have no kit `egresslock-*` objects; no workload
   may remain on a kit network without enforcement.
4. **nft tables** (account): `podman unshare --rootless-netns nft list
   tables` shows no `inet egresslock` — or fails because the netns is
   gone (also fine). A kept table means a workload still uses a kit
   network: remove it and re-run teardown. If teardown was skipped:
   delete manually with the command in step 2's troubleshooting.
5. **Account data** (expected residue, not a leak):
   `~/.config/egresslock` remains unless you purged it.
6. **AppArmor** (root): the amendment is gone from the local include
   (`/etc/apparmor.d/local/usr.bin.pasta` or `.../local/pasta`) —
   the `# begin egresslock-setup --apparmor` marker absent; pasta
   itself stays enforced if it was before.

<details><summary>Reclaim the kit-built image storage (optional)</summary>
The kit-built images (gateway, `egl-base` example base) stay in the
account's Podman store; remove them as the account (only unused
images can be removed this way):

```sh
# account (one-off) — from your own shell: sudo -iu <account> -- <cmd>
# prompt: $ (your own prompt)

sudo -iu ACCOUNT -- podman rmi localhost/egresslock-gateway:latest
sudo -iu ACCOUNT -- podman rmi localhost/egl-base:latest
```

<details><summary>Expected output:</summary>

<pre>
$ sudo -iu <account> -- podman rmi localhost/egresslock-gateway:latest
Untagged: localhost/egresslock-gateway:latest
Deleted: <layer-id>
$ sudo -iu <account> -- podman rmi localhost/egl-base:latest
Untagged: localhost/egl-base:latest
Deleted: <layer-id>
</pre>

(Lifecycle: [The gateway image](../reference/gateway-image.md).)
</details>
</details>

## Next

- [Install the kit](install.md) — for a fresh install on this host.
