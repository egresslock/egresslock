# `denied` misses older denials — the gateway log read cap

## Symptom

`egresslock denied PROFILE` prints a note like
`note: only the newest N bytes of the gateway log were read (EGRESSLOCK_DENIED_MAX_BYTES)`
on stderr, and very old denied destinations are missing from the
output. The command still exits 0 and the newest denials it shows are
correct.

## Cause

`denied` reads `/var/log/squid/access.log` inside the gateway through a
byte cap (`EGRESSLOCK_DENIED_MAX_BYTES`) so a runaway log cannot
exhaust the account's memory (the anti-OOM guard). When the log is
larger than the cap, only the **newest** N bytes are read; a partial
first line at the cut is dropped. Older entries beyond the cap were
not read and cannot be listed.

The default cap is 32 MiB — the same as the log-rotation cap
(`EGRESSLOCK_GW_LOG_MAX_BYTES`), which trims the log on `verify`/
`ensure`. An oversized log therefore usually means rotation has not
run since the log grew (or the cap was lowered below the log size).

If rotation keeps being skipped because `/var/log/squid/access.log`
and `/var/log/squid/access.log.1` are the same file (a warning says
`are now the same file` or `are the same file … skipping rotation`),
the next over-cap `verify`/`ensure` removes the extra name itself and
prints `repaired:` before rotating. If it cannot, the warning's `fix:`
line gives the exact `podman exec` command to remove the duplicate
name — run it only after checking that the two paths are still one
file (`stat -c '%d:%i'` prints the same device:inode for both; a `.1`
with a different identity is a real previous generation and must be
kept).

## Fix

- Read the full log, ignoring the cap:

  ```sh
  EGRESSLOCK_DENIED_MAX_BYTES=0 egresslock denied PROFILE
  ```

  (`0` = uncapped; any non-negative integer is accepted.)
- Raise `EGRESSLOCK_DENIED_MAX_BYTES` for more history in the default
  window.
- To search a wider **time** window instead of more bytes, use
  `denied <profile> --days 0` (the default window is 14 days) — this
  still applies within the byte cap.

## Links

- Back to the [symptom index](../troubleshooting.md).
- [scripts and environment](../reference/scripts-and-environment.md)
  (both cap variables).
- [gateway logs](gateway-logs.md) — how to read `access.log`.
