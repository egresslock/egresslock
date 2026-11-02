# A concurrent command is in progress ("another egresslock command is running")

## Symptom

An `egresslock` command prints:

    Error: another egresslock command is running for this account (waited 30s for the account lock; /home/<account>/.local/state/egresslock/engine.lock; holder: pid=… mode=write started=…); re-run when it finishes

…or a scripted command takes noticeably longer right after another `egresslock` command started.

## What it means

Every command that changes a profile (`ensure`, `allow`, `disallow` (either path), `drop-unauthorized`, `teardown`, `init`) takes one account-wide lock for its whole critical section — reading the conf/allowlist through applying and verifying the new policy. Two such commands on the same account can therefore no longer run at once: the second waits up to 30 seconds, then fails closed with the line above and changes nothing. This is what prevents two commands from undoing each other or racing the gateway container.

`verify` shares the lock when it can (so it does not inspect a profile mid-change) but never blocks the 15-minute timer: after a short wait it proceeds without the lock.

The lock lives in the account's home directory as the system account database records it, not the `HOME` variable: starting a command with a different `HOME` still takes the same lock, so it cannot run beside another command on the account.

If the filesystem holding the account home is full, the holder's one-line record write can fail while the lock itself is still held; the command prints this warning and continues:

    warning: the account lock could not record who holds it (<lockf>): the lock is held for this run; a later "another egresslock command is running" message may show "holder: unknown" or a stale record

The holder record may then show `holder: unknown` or an older `pid=…` — a stale diagnostic, not an unheld lock: re-run when the holder finishes, and free space on the account home — see [disk-full](disk-full.md) — rather than deleting the lock file.

The lock needs `flock(1)` from util-linux; every profile command also needs the account's home directory from the system account database (`getent(1)`) to find the config directory. Both are part of the Debian/Ubuntu baseline the kit installs on.

The two failures differ. A missing `flock` fails every command that takes the lock — the profile-changing commands and `verify` — with a named error; the commands that take no lock (`list`, `network`, `proxy-env`, `rules`, `allowlist`/`allowlist-direct`, `denied`, `doctor`, `build-gateway`) keep working. A missing account entry is broader: the config directory is also found from that home, so the lock-taking commands and the no-lock commands that read a profile fail closed with a named `cannot resolve the account home …` error. Install `util-linux` for the lock half; restore the account entry in the account database for the home half.

## Fix

- Re-run the command when the other one finishes — the line names the holder's `pid` and `started`, so `ps` tells you what it was.
- If you scripted concurrent `egresslock` calls: run them in sequence. Concurrent use is not supported on one account.
- The wait is tunable with `EGRESSLOCK_LOCK_WAIT=<seconds>` (`0` fails immediately); the default is 30 s.
- A wait that looks long is normally a long `ensure` (up to ~60 s of gateway health waiting) or a `disallow --direct` conntrack flush, not a hang.

## Links

- [scripts-and-environment](../reference/scripts-and-environment.md) — `EGRESSLOCK_LOCK_WAIT`
- [policy-reference](../reference/policy-reference.md) — concurrent-command rules
- [verify-timer-signals](verify-timer-signals.md) — raced verify messages
- [disk-full](disk-full.md) — a full account home and the holder-record warning
- [file-locations](../reference/file-locations.md) — the lock file itself: path, contents, and why you leave it in place
