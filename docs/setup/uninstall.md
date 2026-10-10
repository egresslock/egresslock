# How to: uninstall the kit

Remove the kit from a host: per-account teardown first, kit removal
last. Account data and Podman state survive unless you purge them.

> **Before you start**
>
> 1. the engine must still exist for teardown — if the package or
>    prefix is already gone, reinstall ([Install](install.md)) and
>    run the teardown step to recover the runtime first
> 2. the AppArmor unapply (below) runs after teardown, never
>    before — teardown stops the containers that keep pasta alive

### 1. Teardown every account's runtime

Every account that has kit runtime needs this — not just accounts
with an enabled verify timer (runtime state lives in each account's
own store; the sweep touches only the invoking account's). First
stop any automation that launches the workloads, then stop and remove
every workload launched through the kit — they run
on the profile's `egresslock-<name>` network, and the sweep removes
only kit-named objects: a still-running workload would survive while
its enforcement boundary is gone.

```sh
# account (one-off) — from your own shell: sudo -iu <account> -- <cmd>
# prompt: $ (your own prompt)

sudo -iu <account> -- podman ps     # stop/remove anything on an egresslock-* network
sudo -iu <account> -- egresslock teardown --runtime
```

<details><summary>Expected output:</summary>
the swept objects, named; "no kit runtime" when the account had
none (fine — still run it, for every account):

<pre>
$ sudo -iu <account> -- egresslock teardown --runtime
removed container egresslock-anchor-main
removed container egresslock-gateway-main
removed network egresslock-main
removed nft table inet egresslock
</pre>

Troubleshooting:
- `kept network <name> (in use)` — a workload is still attached;
  stop/remove it, re-run the sweep.
- `note: could not delete nft table inet …` — the netns is gone but
  a table lingered; the removal command is in the message.
</details>

<details><summary>Applied the AppArmor pasta amendment? Unapply it</summary>
Only if you ran `--apparmor-add` during install (marker-scoped:
operator lines in the local include are kept). Runs once, host-wide,
after every account's teardown:

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo egresslock-setup --apparmor-remove
```

<details><summary>Expected output:</summary>

<pre>
$ sudo egresslock-setup --apparmor-remove
AppArmor: removed the egresslock pasta amendment from /etc/apparmor.d/local/usr.bin.pasta
</pre>
</details>
</details>

### 2. Remove the kit

If you installed the `.deb` (recommended): disable each account's
verify timer first — `apt remove` deletes the unit templates but
does not stop or disable an enabled timer — then remove the
package:

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo systemctl disable --now egresslock-verify@<account>.timer   # each account
sudo apt remove egresslock
```

<details><summary>Expected output:</summary>

<pre>
$ sudo systemctl disable --now egresslock-verify@<account>.timer
Removed '/etc/systemd/system/timers.target.wants/egresslock-verify@<account>.timer'.
$ sudo apt remove egresslock
The following packages will be REMOVED:
  egresslock
Removing egresslock ...
</pre>

Account data and Podman state survive.
</details>

<details><summary>Tarball (prefix) install: remove with uninstall-kit.sh</summary>
The uninstaller lives in the repository (or a tarball extraction) —
run it from there. Set `PREFIX` to the existing install's absolute
path: `/opt/egresslock` only if that is where you installed it. The
PATH wrapper (`cat /usr/local/bin/egresslock`) records it in the
`# egresslock-path-wrapper prefix=…` line; without wrappers, use your
recorded install path. It stops timers and removes that prefix, PATH
wrappers, and dangling enablements; account data and Podman state
survive unless `--purge-account-data`:

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

PREFIX=/opt/egresslock                 # edit to match your existing prefix
sudo ./uninstall-kit.sh --prefix "$PREFIX" --account <account>
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

### 3. (Optional) Remove the account

The kit does not delete the `<account>` you created
(`adduser --disabled-password` — see
[install](install.md#requirements)). Disable linger, then delete it —
only once nothing of the account still runs (kit teardown done,
non-kit containers cleaned up too):

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo -iu <account> -- podman ps -a    # confirm nothing still runs
sudo loginctl disable-linger <account>
sudo userdel -r <account>             # -r also removes home and mail spool
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

### 4. Verify it's gone

Root checks (1–2, 6) and account checks (3–5, for every account that
had runtime):

1. **Timers/templates** (root): `systemctl list-unit-files
   'egresslock-verify@*'` — no enabled instances, templates gone.
2. **Prefix** (root): `test ! -e "$PREFIX"` succeeds for the prefix
   chosen in step 2, and its PATH wrappers are gone; `.deb` hosts: no
   `/usr/lib/egresslock`, and `dpkg -l egresslock` says uninstalled.
3. **Containers/networks** (account): `podman ps -a` and
   `podman network ls` have no kit `egresslock-*` objects; no workload
   may remain on a kit network without enforcement.
4. **nft tables** (account): `podman unshare --rootless-netns nft
   list tables` shows no `inet egresslock` — or fails because the
   netns is gone (also fine). If teardown was skipped: delete
   manually with the command in step 1's troubleshooting.
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

sudo -iu <account> -- podman rmi localhost/egresslock-gateway:latest
sudo -iu <account> -- podman rmi localhost/egl-base:latest
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

(`EGRESSLOCK_GW_IMAGE` overriders: your tag instead. Lifecycle:
[The gateway image](../reference/gateway-image.md).)
</details>
</details>

## Next

- [Install the kit](install.md) — for a fresh install on this host.
