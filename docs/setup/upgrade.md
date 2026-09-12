# How to: upgrade the kit

## Same-install upgrade (idempotent re-deploy)

Upgrading a host already running **egresslock** (any prefix, including
`/opt/egresslock`):

```sh
sudo ./install-kit.sh --prefix "$PREFIX"   # same prefix as the current install
```

The re-run deploys the new kit files and reinstalls the verify unit
templates (rewriting `ExecStart` with the prefix). It does **not** touch
accounts — account data, allowlists, and enabled timers survive.

After upgrading:

1. Confirm the deployed commit: `/opt/egresslock/egresslock --version`
2. Run one `ensure` + `verify` cycle as the account before relying on
   the new build (see [check-everything](../reference/check-everything.md)).

## Cutover from the pre-rename kit (agent-network / agent-profiles → egresslock)

The rename moved the kit: prefix `/opt/agent-network` →
`/opt/egresslock`, engine `agent-profiles` → `egresslock`, units
`agent-network-verify@.*` → `egresslock-verify@.*`, confdir
`~/.config/agent-network` → `~/.config/egresslock`. This is a **cutover,
not a same-prefix re-deploy** — old and new must never run at once
(dual-run is silently dangerous: old-periodic timers would keep
invoking the old engine under the new prefix).

### One-time cutover procedure

```sh
# 1. As the account, tear down runtime state. If the NEW engine is
#    already installed, prefer its no-conf sweep — it sees BOTH name
#    generations and needs no conf, so it also retires a sibling
#    profile (dev.conf) whose runtime the old binary's conf-scoped
#    teardown would leave running:
sudo -iu <account> -- /opt/egresslock/egresslock teardown --runtime
#    Only when the new engine is NOT there yet, tear down with the old
#    binary — per profile, NEVER `teardown all` (it is conf-scoped:
#    sibling confs' containers survive it). No --config: under
#    `sudo -iu <account>` the old binary's default probe finds
#    ~/.config/agent-network/main.conf (a quoted $HOME would reach the
#    engine as a literal path and the teardown would never run).
sudo -iu <account> -- /opt/agent-network/agent-profiles list
sudo -iu <account> -- /opt/agent-network/agent-profiles teardown <name>   # EACH listed profile

# 2. As root, remove the old kit and prep the new one:
sudo /opt/agent-network/agent-profiles --version   # (sanity: it is the old engine)
sudo rm -rf /opt/agent-network                     # remove the old prefix
sudo systemctl disable --now 'agent-network-verify@*.timer' 2>/dev/null || true
sudo rm -f /etc/systemd/system/agent-network-verify@.service \
           /etc/systemd/system/agent-network-verify@.timer
sudo systemctl daemon-reload

# 3. Move the account config to the new confdir (or start fresh):
sudo mv /home/<acct>/.config/agent-network /home/<acct>/.config/egresslock
#   (or skip: egresslock-setup migrates it — when the new confdir does
#   not exist yet, setup moves the old one and prints what moved; when
#   BOTH exist, setup refuses and you pick. Do NOT rm the old confdir
#   until step 1's --runtime has run — a sibling profile's runtime may
#   still be up.)

# 4. Install + re-wire the account:
sudo ./install-kit.sh                       # default prefix /opt/egresslock
sudo /opt/egresslock/egresslock-setup --init-conf --enable --account <account>

# 5. As the account, re-ensure:
sudo -iu <account> -- /opt/egresslock/egresslock ensure main
```

`install-kit.sh` retires any leftover `agent-network-verify@.*` templates
each run, so step 2's `rm` is belt-and-braces.

After the cutover, `ensure` every profile that should be enforced — any
leftover `inet agent_policy` nft table from the old engine is deleted
automatically by `ensure`/`teardown all`.

## Fail-closed notes

- The old env names (`AGENT_PROFILES_CONF`, …), the old confdir
  `~/.config/agent-network`, and the old CLI `agent-profiles` are
  **not** consulted — a host with only the old kit left behind fails
  closed until the cutover completes. When the new confdir has no
  usable conf and the old one still exists, the engine says so
  explicitly (`cutover incomplete: found ~/.config/agent-network; mv it
  to ~/.config/egresslock or see docs/setup/upgrade.md`) instead
  of the generic `no profile config` line alone.
- Do **not** leave `/opt/agent-network` in place: its verify timers
  would keep running the old engine against the new prefix.

To remove the kit entirely, see [uninstall](uninstall.md).
