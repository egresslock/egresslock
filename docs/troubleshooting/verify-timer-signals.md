# Verify timer and daemon signals (verified / FAILED / drift)

## Symptom

The 15-minute verify timer or your workload's daemon unit reports
something unexpected in the journal — and you need to know which
lines are healthy.

## The services and their signals

| Unit | Runs as | Purpose | Log |
|---|---|---|---|
| `egresslock-verify@<account>.timer` | (timer) | 15-min drift signal, `Persistent=true` | `journalctl -t systemd` / `list-timers` |
| `egresslock-verify@<account>.service` | the account | `egresslock-verify`: named verify or `--ensured` | `journalctl -u egresslock-verify@<account>.service` |
| your workload's daemon unit (e.g. a runner service) | the account | `egresslock-start`: `ensure` (fail closed) then exec | `journalctl -u <daemon>.service` |

Signal semantics (learned the hard way — check for these):

- Healthy: `profile '<name>' verified (ensured)` lines, exit 0.
- `verify: ... FAILED` / exit 1: policy drift or a half-dead profile
  (e.g. gateway container down). Heal with `ensure <profile>` **as the
  account**; verify never auto-fixes.
- `drift: host <name> resolved to <new> but the policy pins <old>`:
  DNS moved; policy is unchanged; `ensure` heals on the next run.
- SILENT exit 0 from `--ensured` means "no profiles ensured" — if you
  expected anchors, that itself is the signal (e.g. wrong
  XDG_RUNTIME_DIR context; the kit entry scripts resolve it from the
  uid, so check how the unit was invoked).
- `egresslock denied <profile>` lists hosts the gateway blocked
  (de-duplicated) — feed candidates to `allow <profile> <host:port>`
  (see [gateway-logs](gateway-logs.md)).

## Quick status, as the account

- `podman images` shows the gateway image.
- `podman ps -a` shows the anchor/gateway containers.
- `systemctl status egresslock-verify@<account>.service` (system
  scope, NOT `--user`) shows the last verify run.

Routine full check: [check-everything](../reference/check-everything.md).
