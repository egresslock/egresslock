# File locations — where egresslock keeps its files

This page answers: **"where does X live?"** — the profile conf and
allowlist, the pin record, the engine lock, the proxy env file, the
build log, and the temp files a killed run can leave behind. Everything
here is owned by the container-owner account
(`egl-runner` in the guides); run the listed commands as that
account. The files the kit installs for the whole host (prefix,
units, PATH wrappers) are on
[Files the kit installs](files-installed.md); the gateway's own logs
live inside the gateway container — [Inspecting the gateway (Squid)
logs](../troubleshooting/gateway-logs.md).

## Config and policy data — `~/.config/egresslock/`

The confdir is created `0700` on first write (`egresslock init`,
`egresslock-setup --init-conf`, or `egresslock-setup import`); a
missing `~/.config` is created under your umask, and an existing
confdir keeps its mode. It holds one small file family per profile.
The policy files (`<profile>.conf`, `<profile>-allowlist`) are produced
`0600`; `gateway-build.log` is `0644` by design. `0600` is the policy:
`egresslock-setup doctor ACCOUNT` reports any policy file that is not
`0600` and any confdir writable by other users (the fix runs as the
account). One deliberate exception: a proxy-path `disallow` rewrite
preserves an existing regular file whose group class equals its other
class (e.g.
`0600`, `0444`, `0644`) rather than tightening it — see
[How proxy disallow writes the allowlist](#how-proxy-disallow-writes-the-allowlist);
such a file remains a doctor finding until you `chmod 600` it.

| File | What it is | Mode | Written by | Removed by |
|---|---|---|---|---|
| `<profile>.conf` | the profile conf — profiles, subnets, rules, `allow-host` entries; the engine's input. The configured direct-path entries are listed by `egresslock allowlist PROFILE --direct` | 0600 from `egresslock init`; `egresslock-setup import` stages the source as 0600; `--init-conf` stages the starter with umask 077 and renames it into place (0600) | `egresslock init`; `egresslock-setup import --from`; `egresslock-setup init --init-conf` (first create); `allow … --direct` / `disallow … --direct` (atomic rewrite of a regular file, keeping the mode; a symbolic link is refused — edit the file it points to by hand while no egresslock command is running, then `ensure <profile>`); your editor | archiving it ([Delete a profile](policy-reference.md#delete-a-profile)); `uninstall-kit.sh --purge-account-data`; `rm` by hand |
| `<profile>-allowlist` | the gateway allowlist — one `host[:port]` per line, matched by Squid's `dstdomain`; the profile's `gateway` line must name exactly this file | 0600 from `egresslock init`; `egresslock-setup import` stages the `<profile>-allowlist` half as 0600; `--init-conf` stages a missing starter sibling with umask 077 (0600; no entries, `EMPTY by design`) and leaves a pre-existing allowlist untouched, keeping its mode | `egresslock allow` (atomic replacement, only for a regular 0600 source; keeps 0600 and uid/gid) / `disallow` (atomic rewrite of a regular file whose group permissions equal its other permissions; keeps the exact mode and uid/gid); `egresslock init` (empty); `egresslock-setup import`; the kit starter | same as the conf |
| `<profile>.pins` | the pin record — the addresses `ensure` installed for the profile's `allow-host` entries; `verify` compares the live chain against it and fails closed on divergence. It is the ensure-time witness, not the configured-entry list (`egresslock allowlist PROFILE --direct`) | 0600 | `egresslock ensure PROFILE` | `ensure` also removes it when the profile has no `allow-host` entries; remove it with the conf pair when archiving; `--purge-account-data`. To regenerate: re-run `ensure` |
| `<profile>.revoke-pending` | the pending-revocation record — `host\|port <addresses>` entries for `disallow … --direct` runs that did not prove severance (interrupted mid-command, or a committed partial state). `ensure` finishes the recorded revocations and removes the record; `verify` fails closed with `unfinished revocation` (rc 1) while a committed entry is reported | 0600 | `egresslock disallow PROFILE HOST:PORT --direct` (atomic write, before the conf line is removed) | the same `disallow` run after a clean confirmation; `egresslock ensure PROFILE` (after the revocation is proven); `--purge-account-data`; archive it with the conf pair. It is not regenerable — the captured addresses may no longer be recomputable |
| `gateway-build.log` | the full output of the last gateway image build (the terminal shows one line; on failure, the last 20 lines) | 0644 (created by the build's output redirect) | `egresslock-setup` when it builds the gateway image | the next build overwrites it; `--purge-account-data`; safe to delete any time |

### How proxy allow writes the allowlist

`egresslock allow PROFILE ENTRY` on the proxy path builds the
complete replacement allowlist — every existing byte, exactly one
newline when a nonempty file lacks a final newline, then the missing
entries in argument order — in a private 0700 staging directory beside
the source, and commits it with a same-filesystem rename. Entry lines
(`added:` / `entry already present:`) are printed only after that
source commit or a clean no-op. The later `ensure` is a separate step:
a failed apply does not roll the source back, and `added:` does not mean
Squid has loaded the entry.

- **No-op:** when every requested entry already matches and the final
  newline is present, `allow` reads the whole source, prints the
  `entry already present:` lines, and leaves the file (inode included)
  untouched. It needs no write permission on either the source or its
  parent. A readable 0444/0644 or symlinked source still works for a
  no-op.
- **Rewrite eligibility:** to add an entry or repair the newline, the
  source must be a regular file with exact numeric mode `0600`.
  Symlinks and every other mode are refused before any commit with a
  named error and no entry lines or `ensure`; the source bytes, mode,
  owner and ACLs stay as they were. The rewrite keeps the source uid/gid
  and exact `0600`. Replacing a hard link leaves its other names
  unchanged. It needs write permission on the source, a writable source
  parent, and room for a full copy. An allowlist left at `0644` by a
  default umask is fixed by running the command the refusal names,
  `chmod 600 -- <path>`, and then retrying the same `egresslock allow`
  command. `allow` never changes the mode itself, and group or other
  access on the allowlist is not a supported sharing model.
- **Metadata limits:** POSIX ACL identity is not preserved, and SELinux
  labels, capabilities and other xattrs are not guaranteed preserved.
  The private 0700 stage and the candidate's `0600` bound current POSIX
  DAC access, but inherited dormant ACL entries can differ from the
  source and become effective after a later `chmod`. If you rely on ACLs
  or security labels, make a metadata-preserving external edit while no
  egresslock command is running, then run `egresslock ensure PROFILE`;
  do not `chmod` a file whose access other users rely on.
- **Concurrency:** the account-wide engine lock serializes this
  account's engine commands, but not your editor,
  `egresslock-setup import`, or another account sharing the file.
  Serialize those writers with engine commands yourself; an external
  edit between the copy and the rename can be lost. This is not a
  compare-and-swap or a defense against a hostile writer.
- **Interruptions:** a pre-commit failure removes the stage when it can
  and reports a cleanup failure otherwise. A signal around the rename
  can leave the commit outcome unknown, so inspect the allowlist before
  retrying. An interrupted run may leave an inert private stage
  directory (see [Transients](#transients--temp-files-a-killed-run-can-leave-behind));
  it is safe to delete once no command is running. There is no `fsync`
  power-loss durability promise.

### How proxy disallow writes the allowlist

`egresslock disallow PROFILE ENTRY` on the proxy path removes every
requested entry that is present and commits the replacement allowlist
with a same-filesystem rename. The replacement is built in a private
0700 staging directory beside the source; the staged snapshot and
candidate stay 0600 for the whole content window, and only the file that
will be renamed is given the source metadata. The `removed:` lines print
only after the source commit and the apply both succeed. A failed apply
never prints `removed:`. When the failure is proven to be before
publication, the engine tries to restore the pre-image by rename. The
outcome is decided by the state after the rename, not by the rename's
exit status: when the backup is gone and a file or symlink is at the
allowlist path, the pre-image is back — a rename that landed and then
reported an error is included — and the failure text says the allowlist
was put back and names the retry. A retained backup means the rewritten
file is still in place, and the failure text stays the
could-not-put-back recovery. When publication is unknown or already
committed, no restore is attempted; the allowlist stays the rewritten
file and the backup is retained.

- **Read-only refusals first:** a missing allowlist file and an entry
  not present in the chosen path refuse before any write. An absent
  entry looked up through a symlink still reports `entry not present`,
  and a dangling link takes the missing-file refusal.
- **Rewrite eligibility:** the source must be a regular file. A symlink
  is refused before the mode stat, staging, backup or rename; edit the
  file the link points to by hand while no egresslock command is
  running, then run `egresslock ensure PROFILE` (a plain `ensure`
  reloads; `ensure --replace-gateway` drops every proxied session on the
  profile). The rewrite also
  needs the source to be writable by this account or owned by it (an
  owned 0400/0444 file is still replaceable by the rename), a writable
  source parent, and room for a full copy. A foreign read-only file is
  refused named.
- **Mode:** the exact numeric source mode and uid/gid are preserved.
  A source whose group class is not exactly equal to its other class —
  `0640`, `0660`, `0664`, `0750`, and also a narrower-group mode such as
  `0604` — is refused before staging. The dangerous case is a wider
  group class: the final `chmod` sets the POSIX ACL mask to the group
  class and could activate a named entry inherited from the parent
  directory's default ACL (an extra access list that new files there
  inherit). That would give another account access the allowlist does
  not allow; this command does not read ACLs and cannot rule it out.
  Accepted examples are `0600`, `0400`, `0444`, `0644`, and `0755`;
  equal group and other classes (even `0666`/`0777`) are preserved
  rather than tightened. The refusal names `chmod 600 -- <path>` and
  the retry. A `0644` source whose access ACL denies a named account is
  still rewritten; that denial is not preserved, and the account gets
  the file's "other" access (read only at `0644`).
- **Staging and metadata limits:** the stage directory is verified as an
  owner-only 0700 directory, both staged files are kept at 0600, and the
  rewrite filters a snapshot rather than re-reading the live source.
  Owner, group and mode are set on the candidate and verified before the
  rename. POSIX ACL identity is not preserved, and SELinux labels,
  capabilities and other xattrs are not guaranteed preserved; inherited
  dormant ACL entries can differ from the source and become effective
  after a later `chmod`. The group-vs-other gate keeps an inherited
  entry from gaining more than "other" already had. A named ACL entry
  that denied an account on a `0644` source is not preserved: after the
  rewrite that account gets the same read access as "other". Security
  labels (SELinux and similar) are likewise not preserved. If you rely
  on a named ACL entry or a security label, make a metadata-preserving
  external edit while no egresslock command is running, then run
  `egresslock ensure PROFILE`.
- **Hard links:** replacing the named path leaves its other names
  unchanged.
- **Concurrency:** the engine lock serializes this account's engine
  commands, but not your editor, `egresslock-setup import`, or another
  account sharing the file. An external edit between the snapshot and
  the rename can be lost. This is not a compare-and-swap or a defense
  against a hostile writer.
- **Interruptions and a failed rename:** a pre-commit failure removes
  the stage when it can and leaves the source unchanged; a cleanup
  failure is a neutral warning about the inert stage directory. If the
  final rename returns nonzero, the old file is kept as a hard link
  named `<allowlist>.egresslock-disallow-backup.<pid>` and the error
  says the allowlist may be unchanged or already replaced: inspect the
  file and retry the same command if the revoked entry is still there;
  if it is gone, apply the removal with
  `egresslock ensure --replace-gateway PROFILE`, which drops every
  proxied session on the profile. A plain `egresslock ensure PROFILE`
  only reloads the running gateway, so established proxied sessions to
  those destinations may keep running until they close. Delete the
  backup once you no longer need it. A run killed by a signal around
  the rename is not that error: it may leave the same backup path with
  no message naming it, and no apply or `removed:` line. Inspect the
  source: if the revoked entry is still there, retry the same command;
  if it is gone, apply the removal with
  `egresslock ensure --replace-gateway PROFILE` (this drops every
  proxied session on the profile; a plain `ensure` only reloads and
  leaves established sessions up) before deleting the backup. Delete
  the backup once no egresslock command is running. A killed run can
  also leave an inert private stage directory (see
  [Transients](#transients--temp-files-a-killed-run-can-leave-behind)).

## Runtime and state

| File | What it is | Mode | Written by | Removed by |
|---|---|---|---|---|
| `~/.local/state/egresslock/engine.lock` | the account-wide lock that serializes `ensure`, `allow`, `disallow` (either path), `drop-unauthorized`, `teardown`, and `init`; the file records the current holder (`pid=… mode=… started=…`); a writer truncates it on acquire, so it stays tiny. The path is anchored to the account's home directory as the system account database records it, not the `HOME` variable. | directory 0700; file under your umask (0644 typical — the directory is what keeps it private) | the writer commands; `verify` shares the lock when it can | nothing — leave it in place. The kernel releases the lock when the holder exits; deleting the file while commands run would let two writers past the lock. The full story: [A concurrent command is in progress](../troubleshooting/concurrent-commands.md) |
| `egresslock-proxy-<profile>.env` | the six proxy assignments (`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`, both cases) for a profile's gateway | 0600 | `egresslock proxy-env PROFILE --out` (the recommended form; prints the path; `--out=<path>` is a backup that writes elsewhere) | nothing automatic. The default lives under the account's runtime directory (`${XDG_RUNTIME_DIR:-/run/user/<uid>}`), which goes away at reboot — and at logout without linger; regenerate with `--out` after any policy or env change, then recreate the container — [Proxy clients](proxy-clients.md) |

## Logs

`gateway-build.log` (above) is the one log egresslock keeps in the
confdir. The gateway's request and error logs (Squid `access.log` /
`cache.log`) live inside the gateway container — read them with
`egresslock denied` or `podman exec`:
[Inspecting the gateway (Squid) logs](../troubleshooting/gateway-logs.md).
The direct-path denial record is not a file: it is the bounded per-profile
nft set in the rootless network namespace, read with
`egresslock denied PROFILE --direct`.

## Transients — temp files a killed run can leave behind

Little here is meant to survive a run: every command removes its temp
files on success and on failure. A leftover means the process was
killed mid-run (SIGKILL, power loss). Leftovers are inert — no
command reads an old temp file, and the next run makes a fresh one —
so deleting them is safe, as long as no egresslock command is
running.

| File | What it is |
|---|---|
| `/tmp/egresslock-policy.*.nft` | the ruleset file a policy install hands to `nft -f` |
| `/tmp/egresslock-verify.*` | the working file `verify` builds the expected ruleset in |
| `/tmp/egresslock-allowlist.*/` | the staging directory for the generated gateway allowlist files |
| `<allowlist>.egresslock-stage.*/` | the private staging directory beside a proxy-path allowlist while `allow` or `disallow` builds its replacement; contains the staged `candidate` (and, for `disallow`, the `snapshot` it filters from). If a run is killed before the commit, the source is unchanged and this directory is inert |
| `<allowlist>.egresslock-disallow-backup.<pid>` | the hard-link pre-image proxy `disallow` keeps when the final rename returns nonzero (the S4 error names it) or a run is killed around it (no message may name it). Inspect the allowlist: if the revoked entry is still there, retry the same command; if it is gone, apply the removal with `egresslock ensure --replace-gateway PROFILE` (it drops every proxied session on the profile) before deleting the backup. Delete the backup once no egresslock command is running |
| `<file>.XXXXXX` beside a file being replaced | atomic-write temps beside the conf, pin record, pending-revocation record, and proxy env file (`XXXXXX` is mktemp's random suffix) |

## Backing up, moving, or removing these files

To back up an account's policy, copy `~/.config/egresslock/` — the
confs, allowlists, pin records, and pending-revocation records are all
small; `gateway-build.log` is a log, skip it.
Regenerable (no backup needed): the pin records (re-run `ensure`), the
lock, and every transient above. The pending-revocation record is not
regenerable — the
addresses captured by the interrupted revocation may no longer be
recomputable — so archive it with the conf pair.

Removal follows the account's own lifecycle: one profile —
[Delete a profile](policy-reference.md#delete-a-profile) (teardown,
then archive the files); the whole kit —
[Uninstall the kit](../setup/uninstall.md)
(`--purge-account-data` deletes the confdir; the state directory and
the account's Podman state stay behind).

Not listed here: Podman's own state — the account's container and
image store, networks, and the netns under
`/run/user/<uid>/netns/`. Those belong to Podman;
[Uninstall the kit](../setup/uninstall.md) covers reclaiming them.

