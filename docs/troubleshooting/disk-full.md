# A full disk breaks an egresslock write

## Symptom

The filesystem that holds the account home or `/tmp` is full (or out of
inodes), and an `egresslock` command prints one of the named lines below
— or a raw `No space left on device` on a named path. A full disk is not
a policy fault.

## What it means

### The account lock: the holder record is diagnostic

Every locked command writes a one-line holder record into
`~/.local/state/egresslock/engine.lock`; a full filesystem can fail that
write after the lock is held:

    warning: the account lock could not record who holds it (<lockf>): the lock is held for this run; a later "another egresslock command is running" message may show "holder: unknown" or a stale record

The command **keeps running with the lock held**; the warning alone does
not change its exit code. A later timed-out command may show
`holder: unknown` or an older `pid=…` — the lock is still held, so re-run
when the holder finishes rather than deleting the lock file. A lock file
that cannot be created or opened, or a writer record that cannot be
truncated, still stops the command named.

### Policy generation: no partial nftables input is applied

`ensure` writes the candidate nftables file in `/tmp`; if it cannot be
created:

    Error: cannot create a temporary policy file in /tmp: the firewall is unchanged

If any line cannot be written, even after earlier lines succeeded:

    Error: cannot write the temporary policy file for profile '<p>' in /tmp: the firewall is unchanged

Both exit 1 and **`nft -f` is not run**; the live firewall is unchanged
and a partial candidate is never installed.

### The pin record: what is known after a successful apply

The pin record (`<confdir>/<p>.pins`) stores the allowed addresses.
`ensure` checks the target before swapping the firewall; a directory or
symbolic link is refused before the apply:

    Error: the pin record path <rec> is not a regular file; refusing to replace it (the firewall was not changed; move it aside and re-run: egresslock ensure <p>)

Move that path aside (only that path moves) and re-run `ensure`. In a
direct or proxy `disallow`, use its own restore/retry line — before the
apply it ends at `(the firewall was not changed)`, and after a post-apply
pin failure it drops the `next action` tail — not a plain `ensure`.

After a successful `nft -f`, the pin write can still fail; `ensure`
exits 1 and says what this run established:

    Error: cannot write the pin record <rec> for profile '<p>': the stored list of allowed addresses was not updated by this run

    ensure: this run applied new firewall rules for profile '<p>' but did not update the pin record (the stored list of allowed addresses) — state: <state>; the pin record may not match — note: a later "egresslock verify <p>" names a pin-record mismatch if the stored list differs, and can pass if the stored pins already match or the profile has no allow-hosts — next action: fix the underlying failure, then inspect and re-run: egresslock ensure <p>

`<state>` is one of `firewall rules are present (holder container
running)`, `firewall chain absent (holder container running)` (a clean
absence, not a claim the rules are live), `firewall not proved live
(holder container not running)`, `firewall presence could not be read
(holder container state unknown)`, or `firewall presence could not be
read (holder container running)`.

A later `verify` may pass or fail — it is not guaranteed to fail. Fix the
failure, free space, then inspect with `egresslock verify <p>` and re-run
`egresslock ensure <p>` as the account.

If the profile changed to **no allow-hosts**, `ensure` removes the stale
pin record and still exits 0 if that fails:

    warning: could not remove the stale pin record <rec> after the policy changed to no allow-hosts; the policy and gateway are as installed, and verify does not use the pin record for a profile with no allow-hosts

`verify` ignores the record for a profile with no allow-hosts; the policy
and gateway are as installed.

### `verify`'s temporary expected ruleset

`verify` builds its expected ruleset in a temporary file under `/tmp`; if
that file cannot be created, written, rewritten, or read:

    verify: cannot write the temporary expected-ruleset file in /tmp; the policy could not be checked (exit 1)

`verify` exits 1. The policy was **not checked**: this is not a drift
signal, and no `policy chain … does not match` line follows. A named
pin-record failure keeps its own line.

### Direct conf writes: the config is not replaced

A direct `allow` / `disallow` writes the new conf beside the old one and
renames it into place. If the temporary file cannot be written:

    Error: cannot write the new config next to <conf>: the temporary file could not be written; the config was not replaced by this run

It exits 1, the conf is byte-identical, and no `added:`, `removed:`,
`already present:`, or `ensure` follows. Re-run after freeing space.

## Fix

1. **Free space on the right filesystem.** The account home holds the
   lock and the pin record (`~/.config/egresslock/<p>.pins`); `/tmp`
   holds the policy candidate and verify's temp. Check both space and
   inodes: `df -h /tmp ~` and `df -i /tmp ~`.
2. **Re-run the command that failed.** A lock-record warning needs no
   action; a policy-generation or conf-write failure changed nothing.
3. **After a post-apply pin failure**, free space, then
   `egresslock verify <p>` and `egresslock ensure <p>` as the account.
4. **After a verify temp failure**, free `/tmp` and re-run `verify`; no
   drift conclusion can be drawn.
5. **For a pin path that is a directory or symlink**, move it aside and
   re-run `ensure`; the refused run did not change the firewall.

## Links

- [concurrent-commands](concurrent-commands.md) — the lock and `holder: unknown`.
- [verify-timer-signals](verify-timer-signals.md) — the same lines as timer signals.
- [file-locations](../reference/file-locations.md) — lock, confdir, pin record, `/tmp`.
- [policy-reference](../reference/policy-reference.md) — the pin record.
