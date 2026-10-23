# A concurrent command is in progress ("another egresslock command is running")

## Symptom

An `egresslock` command prints:

    Error: another egresslock command is running for this account (waited 30s for the account lock; /home/<account>/.local/state/egresslock/engine.lock; holder: pid=… mode=write started=…); re-run when it finishes

…or a scripted command takes noticeably longer right after another `egresslock` command started.

## What it means

Every command that changes a profile (`ensure`, `allow`, `disallow`, `allow-host`, `disallow-host`, `drop-unauthorized`, `teardown`, `init`) takes one account-wide lock for its whole critical section — reading the conf/allowlist through applying and verifying the new policy. Two such commands on the same account can therefore no longer run at once: the second waits up to 30 seconds, then fails closed with the line above and changes nothing. This is what prevents two commands from undoing each other or racing the gateway container.

`verify` shares the lock when it can (so it does not inspect a profile mid-change) but never blocks the 15-minute timer: after a short wait it proceeds without the lock.

The lock lives in the account's home directory as the system account database records it, not the `HOME` variable: starting a command with a different `HOME` still takes the same lock, so it cannot run beside another command on the account.

The lock needs `flock(1)` from util-linux and the account's home directory from the system account database (`getent(1)`) — both part of the Debian/Ubuntu baseline the kit installs on. When either cannot be found, the commands that take the lock — the profile-changing commands and `verify` — fail closed with a named error; the commands that take no lock (`list`, `network`, `proxy-env`, `rules`, `allowlist`, `denied`, `doctor`, `build-gateway`) keep working. Install `util-linux` (or restore the account entry in the account database) to fix.

## Fix

- Re-run the command when the other one finishes — the line names the holder's `pid` and `started`, so `ps` tells you what it was.
- If you scripted concurrent `egresslock` calls: run them in sequence. Concurrent use is not supported on one account.
- The wait is tunable with `EGRESSLOCK_LOCK_WAIT=<seconds>` (`0` fails immediately); the default is 30 s.
- A wait that looks long is normally a long `ensure` (up to ~60 s of gateway health waiting) or a `disallow-host` conntrack flush, not a hang.

## Links

- [scripts-and-environment](../reference/scripts-and-environment.md) — `EGRESSLOCK_LOCK_WAIT`
- [policy-reference](../reference/policy-reference.md) — concurrent-command rules
- [verify-timer-signals](verify-timer-signals.md) — raced verify messages
- [file-locations](../reference/file-locations.md) — the lock file itself: path, contents, and why you leave it in place
