# Verify timer and daemon signals (verified / FAILED / drift)

## Symptom

The 15-minute verify timer or your workload's daemon unit reports
something unexpected in the journal — and you need to know which
lines are healthy.

## The services and their signals

| Unit | Runs as | Purpose | Log |
|---|---|---|---|
| `egresslock-verify@<account>.timer` | (timer) | 15-min drift signal, `Persistent=true` | `journalctl -t systemd` / `list-timers` |
| `egresslock-verify@<account>.service` | the account | `egresslock-verify`: named verify or `--ensured` | `sudo journalctl -u egresslock-verify@<account>.service` |
| your workload's daemon unit (e.g. a runner service) | the account | `egresslock-start`: `ensure` (fail closed) then exec | `sudo journalctl -u <daemon>.service` |

Signal semantics (learned the hard way — check for these):

- Healthy: `profile '<name>' verified (ensured)` lines, exit 0.
- `verify: ... FAILED` / exit 1: policy drift or a half-dead profile
  (e.g. gateway container down). Heal with `ensure <profile>` **as the
  account**; verify never auto-fixes. The kit's `egresslock-setup
  doctor` reports the same exit-1 instance with its last and next run,
  a manual re-run command that sources the unit environment, and the
  service journal — the `sudo journalctl -u` line in the table above is
  where the details are.
- A failed verify **timer** (rather than the service) means the timer
  could not start and the verify service never ran: its journal, not
  the service log, is the evidence. Doctor checks the timer's armed
  state first and names it: a disabled timer is reported as disarmed
  (with the re-arm command), masked/static/not-found states get their
  own fix, and an enabled-but-failed timer prints `reset-failed` +
  `restart` plus the timer journal. A stale failure stays visible until
  it is cleared — `enable --now` does not clear it.
- `verify: gateway container '<name>' not exec-able (...)` / exit 1:
  the gateway was stopped or mid-restart when verify inspected it —
  commonly a concurrent `ensure`/`allow` restarting the same profile.
  Not a config fault. Re-run after the concurrent command finishes —
  or `egresslock ensure <profile>` **as the account** if the gateway
  stayed down. Only `verify: gateway squid config invalid: ...` means
  Squid itself rejected the deployed config.
- `status=203/EXEC` (systemd start failure, no verify output at all):
  the unit file itself is broken — e.g. a stale template left in
  `/etc/systemd/system` shadowing the package's unit after a
  prefix→deb switch. Run `sudo egresslock-setup doctor`: it names
  the shadowing file (or missing ExecStart target) and the exact fix.
  When that verify-unit row already explains the failed instance,
  doctor reports the instance as a note instead of a second problem
  (no repeated target/reinstall text); a 203/EXEC it cannot explain
  keeps the service journal as the lead evidence.
  If the shadow is the postinst co-install refusal (the `.deb` install
  FAILED because a prefix kit was still installed): remove the prefix
  kit with `uninstall-kit.sh`, then finish the install with
  `sudo dpkg -i <deb>` or `sudo apt-get install -f` — **not**
  `apt-get install --reinstall egresslock`, which cannot resolve the
  half-installed (`iF`) state ("No file name for egresslock").
- `drift: host <name> resolved to <new> but the policy pins <old>`:
  the host's address set changed at `ensure` time (a member address
  appeared or disappeared — a resolver reorder of the same addresses
  is not a change; multi-address values render comma-joined); policy
  is unchanged; `ensure` heals on the next run. The pinned set is
  capped at the first 16 sorted distinct addresses (`DNS_SET_MAX`); a
  larger answer truncates with a named `note:`.
- A name that serves **one address per query from a rotating pool**
  (e.g. `github.com` over SSH) is the exception: each `ensure` pins
  only the one answer it saw, so a later cycle that resolves another
  member warns again, and re-`ensure` only swaps which member is
  pinned. Replace the name with one IPv4-literal
  `allow-host` line per member (literals never resolve, so they never
  drift), or tunnel the connection through the gateway by name — see
  [Rotating names](../reference/rotating-names.md).
- `verify: network exists but policy does not — run: egresslock
  ensure <profile>` / exit 1: the post-reboot stale window — the
  profile's podman network object survived the reboot (on disk) but
  the netns policy is gone (volatile). Heal with `ensure <profile>`
  **as the account**; the timer never re-ensures. This is the
  default sweep-mode timer's post-reboot drift signal.
- SILENT exit 0 from `--ensured` means "no profiles ensured **and**
  no stale leftovers" — if you expected anchors, that itself is the
  signal (e.g. wrong XDG_RUNTIME_DIR context; the kit entry scripts
  resolve it from the uid, so check how the unit was invoked). A
  post-reboot stale profile is **not** silent: it fails named with
  the line above.
- `egresslock denied <profile>` lists hosts the gateway blocked
  (de-duplicated) — feed candidates to `allow <profile> <host:port>`
  (see [gateway-logs](gateway-logs.md)).

## Quick status, as the account

- `podman images` shows the gateway image.
- `podman ps -a` shows the anchor/gateway containers.
- `systemctl status egresslock-verify@<account>.service` (system
  scope, NOT `--user`) shows the last verify run.

Routine full check: [check-everything](../reference/check-everything.md).
