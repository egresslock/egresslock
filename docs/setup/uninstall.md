# How to: uninstall the kit

Order matters: account teardown first, optional AppArmor
unapply second, kit removal last:

```sh
# 1. Teardown ALL kit runtime state (as the account, while the engine
#    still exists). --runtime loads no conf and sweeps the CURRENT
#    generation's kit containers, networks (egresslock-*), and the kit
#    nft tables (`inet egresslock`, leftover `inet agent_policy`).
#    It does NOT need a working rootless netns (no
#    netns probe); containers/networks are removed first, nft
#    deletes are best-effort. Pre-rename agent-* leftovers are NOT
#    swept — remove them by hand:
sudo -iu <account> -- /opt/egresslock/egresslock teardown --runtime

# 2. OPTIONAL — unapply the AppArmor pasta amendment (root). Only if
#    you applied it; marker-scoped, keeps operator lines, never deletes
#    the local file:
sudo /opt/egresslock/egresslock-setup --apparmor-remove

#    ORDER NOTE: teardown --runtime works WITHOUT a working rootless
#    netns (conf-scoped `teardown <name>` / `teardown all` DO need one —
#    they fail closed if the netns probe fails). Still run this
#    AFTER step 1, never before: the sweep stops the containers that
#    keep pasta alive, and the engine must still exist for step 1.

# 3. Remove the kit and the timers; account data and Podman state
#    survive. [--purge-account-data]  # also delete BOTH confdirs
#                                     # (current + pre-rename
#                                     # ~/.config/agent-network)
sudo ./uninstall-kit.sh --account <account> [--purge-account-data]
```

(`uninstall-kit.sh` defaults to the standard kit prefix
`/opt/egresslock`; pass `--prefix` only if you installed elsewhere.
`--help` lists every option. The uninstaller lives in this repository —
it is not deployed with the kit, so run it from a clone/checkout of the
repo — or from a `build-tarball.sh` extraction, which ships it. It
never runs podman or nft itself — step 1 must run BEFORE the
uninstall; if the engine is already gone, reinstall the kit (or install
the .deb) and run step 1 to recover the leftover runtime.)

For the .deb: step 3 is `sudo apt remove egresslock` instead, and step
2 must run before it (the setup wrapper disappears with the package).

### Optional: remove the dedicated account

If you created the dedicated `<account>` during install (the
`sudo adduser <account>` requirement) and no longer need it, the kit
does **not** delete it for you. To remove it, disable linger first (if
you used `--enable`), then delete the account:

```sh
# Disable linger for the account, if it was enabled:
sudo loginctl disable-linger <account>

# Remove the account (read the pins before running: warns if any of
# the account's processes are still running, incl. a leftover pasta/
# podman holder — run `teardown --runtime` first):
sudo userdel -r <account>    # -r also removes the home and mail spool
```

Only do this once the kit teardown (steps above) is complete and you
have confirmed nothing of the account still runs (`sudo -iu <account>
-- podman ps -a` first). If the account also owns non-kit containers,
delete it only after cleaning those up too.

## Verify it's fully gone

Root commands where noted, otherwise as the account
(`sudo -iu <account> --`):

1. **Timers/templates, both generations** (root):
   `systemctl list-unit-files 'egresslock-verify@*'
   'agent-network-verify@*'` — no enabled instances; templates gone
   from the unit dir.
2. **Prefixes gone** (root): `/opt/egresslock` and
   `/opt/agent-network` do not exist. `.deb` hosts: no
   `/usr/lib/egresslock` and `dpkg -l egresslock` says uninstalled.
3. **Kit containers/networks** (as the account): `podman ps -a` and
   `podman network ls` have no `^egresslock-(gateway|anchor)-`
   containers and no `^egresslock-` networks (non-kit names like
   `agent-opencode` or the default `podman` network may remain).
   Pre-rename `agent-*` kit objects are NOT swept by `--runtime`;
   if any are still present, remove them by hand
   (`podman rm -f` / `podman network rm`).
4. **nft tables** (as the account):
   `podman unshare --rootless-netns nft list tables` shows neither
   `inet egresslock` nor `inet agent_policy` — or the unshare fails
   because the netns is already gone (also fine). If teardown was
   skipped and the engine is already gone, delete manually:
   `podman unshare --rootless-netns nft delete table inet egresslock`
   (and the same for `agent_policy` if present).
5. **Account data** (expected residue, not a leak):
   `~/.config/egresslock` and `~/.config/agent-network` remain unless
   `--purge-account-data` was used.
6. **AppArmor** (root): `aa-status` still shows pasta **enforced** if
   it was before (we never `aa-complain`). The applied amendment in the
   **resolved local include** — `/etc/apparmor.d/local/usr.bin.pasta`
   or `/etc/apparmor.d/local/pasta`, whichever the profile names —
   remains unless you ran `--apparmor-remove`;
   confirm unapply by checking the
   `# begin egresslock-setup --apparmor` marker is absent from both.
   To check whether pasta is enforced at all, match the enforce
   section, not a fixed line window:
   `sudo aa-status | awk '/profiles are in enforce mode/{s=1} /profiles are in complain mode/{s=0} s && /pasta/'`

If you used `aa-complain` as a workaround, re-enforce with
`sudo aa-enforce /usr/bin/pasta`.

## Optional cleanup

The kit builds a **gateway image** into the account's Podman store at
setup time. It is left in place after uninstall (account data and
Podman state survive by design). If you want to reclaim that storage,
remove the unused image manually as the account — for example:

```sh
sudo -iu alice -- podman rmi localhost/egresslock-gateway:latest
```

(Replace `alice` with your account name, and the image tag if
you overrode `EGRESSLOCK_GW_IMAGE`.) You can list what is present first
with `sudo -iu <account> -- podman images`. Only unused images can be
removed this way; anything else still in use will be reported and left
alone.
