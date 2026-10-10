# Engine, scripts, and environment — configuration reference

This page answers: **"which environment variables, config-resolution
rules, and script defaults govern the engine and its entry scripts?"**
The conf grammar itself is the
[policy reference](policy-reference.md).

## Engine environment overrides

See `egresslock --help` for the full list:

| Variable | What it does |
|---|---|
| `EGRESSLOCK_CONF` | required for every profile subcommand — the engine has no compiled-in profiles; unset or empty fails closed with `no profile config` |
| `NFT_BIN` | path to the `nft` binary (default `/usr/sbin/nft`, else `$PATH`) |
| `EGRESSLOCK_ANCHOR_IMAGE` | anchor image (default: base image or alpine) |
| `EGRESSLOCK_GW_IMAGE` | gateway image (default `localhost/egresslock-gateway:latest`) |
| `EGRESSLOCK_ALLOW_ROOT=1` | allow running as root (NOT recommended — root's Podman store/netns is not an account) |
| `EGRESSLOCK_SKIP_NETNS_PROBE=1` | skip the podman rootless-netns preflight probe (test harness only) |
| `EGRESSLOCK_GW_LOG_MAX_BYTES` | gateway log rotation cap in bytes (default 32 MiB; `0` = no cap) |
| `EGRESSLOCK_DENIED_MAX_BYTES` | `denied` log-read cap in bytes (default 8 MiB; `0` = uncapped) |

## Config resolution

When neither `--config` nor `EGRESSLOCK_CONF` is given, the engine
probes the running user's default folder `~/.config/egresslock/`.
Named commands (ensure, verify <name>, network, proxy-env, rules,
allowlist, denied, allow, disallow, allow-host, disallow-host,
teardown <name>) use `<profile>.conf` if present, else `main.conf`
(the `--init-conf` dest). Every conf-resolving invocation prints
exactly one stderr line naming the winning source, every time,
TTY-independent: `using config <path>` on a named hit, or
`using config <path> (named fallback: no <profile>.conf)` when the
named file was missing and `main.conf` was used. Bare `list` and
bare `verify --ensured` aggregate every `*.conf` in that folder
(`using configs in <dir>`); bare `teardown all` stays
`main.conf`-only. Without any file it fails closed exactly as
above. Explicit always beats the probe.

## The account's `unit.env`

`~/.config/egresslock/unit.env` (0600, written by `egresslock-setup` —
see [The two files that matter](#the-two-files-that-matter) below):

| Line | Meaning |
|---|---|
| `EGRESSLOCK_CONF=<conf path>` | required — where the account's profile conf is |
| `EGRESSLOCK_PROFILE=<name>` | optional — named verify mode; omit for `--ensured` |

## `egresslock-setup` — per-account bootstrap

One-command per-account bootstrap; run as **root**, from the installed
kit or a checkout. It ships the deny-all starter conf with
`--init-conf`, validates the conf, writes the account's `unit.env`,
builds the gateway image (if the conf has one), and optionally enables
the verify timer. The install flow that invokes it:
[Install the kit](../setup/install.md).

### Flags

| Flag | What it does |
|---|---|
| `--account <name>` | target account (required unless `--apparmor-add` is used alone) |
| `--init-conf` | ship the deny-all starter conf pair (`profile main` + empty allowlist) when the dest conf is missing — never overwrites; without `--conf`, the dest is `~/.config/egresslock/main.conf` |
| `--conf <path>` | bring your own conf: validate + wire it into `unit.env`, skip the starter (required unless `--init-conf`) |
| `--profile <name>` | write `EGRESSLOCK_PROFILE=<name>` (named verify mode); omit for `--ensured` mode |
| `--prefix <path>` | deployed kit prefix (default: derived from the installed unit template, else `/opt/egresslock`) — usually unnecessary: setup retries the `.deb` unit dir when a stale prefix unit points at a missing engine |
| `--enable` | enable+start `egresslock-verify@<account>.timer` AND enable linger for the account (fails closed if linger does not stick) |
| `--apparmor-add` / `--apparmor-remove` | apply/unapply the pasta AppArmor rule (idempotent; `--apparmor-add` may be used alone) |
| `--apparmor-check` | report AppArmor/pasta amendment health (read-only, no root; prints a `Summary:` verdict line) |
| `--doctor` | read-only kit/account state check with the fix command for each missing item (distinct from the engine's `egresslock doctor`) |
| `-h`, `--help` | print the full help (the script is the source of truth) |

### The run map (numbered progress)

Every account-bundle run prints one line per step, in execution
order, so you can see what a run changed and where it stopped:

```text
1) validate conf … OK
2) write unit.env … OK
3) linger … OK          # SKIP without --enable
4) user manager … OK    # SKIP without a `gateway` line in the conf
5) gateway image … OK   # SKIP without a `gateway` line
6) timer … OK           # SKIP without --enable
```

`FAIL` is always the last printed step (the run stops there, nothing
after it executed).

### Root vs account steps

| Step | Runs as | Why |
|---|---|---|
| validate conf | account (`runuser`) | the conf must parse under the account's engine/store |
| write unit.env | account (`runuser`) | kit-generated state lives in the account's confdir |
| linger | **root** | `loginctl enable-linger` is a system logind change (`--enable` only) |
| user manager | **root** | `systemctl start user@<uid>.service` (gateway confs; start, never restart) |
| gateway image | account (`runuser`) | must land in the account's rootless Podman store |
| timer | **root** | `systemctl enable --now egresslock-verify@<account>.timer` (`--enable` only) |

### What setup does

- **`--init-conf`** ships the deny-all starter (`profile main` + empty
  allowlist) from `examples/`, only if no conf exists yet (never
  overwrites; never heals an existing conf's missing allowlist).
- **Validates** the conf: exists AND readable by the account, parses
  cleanly under the deployed engine, and (with `--profile`) that the
  named profile exists in it.
- **Writes `~/.config/egresslock/unit.env`** (0600): exactly one
  `EGRESSLOCK_CONF=<conf>` line, plus `EGRESSLOCK_PROFILE=<name>` only
  when `--profile` is given. Re-runs overwrite the file wholesale.
- **Builds the gateway image** into the account's Podman store from
  the deployed prefix (for gateway profiles) if the image is missing.
  Lifecycle and rebuilds: [The gateway image](gateway-image.md).
- **`--enable`** enables+starts `egresslock-verify@<account>.timer`
  and enables linger for the account, so `/run/user/<uid>` persists
  outside login sessions for the timer's `egresslock-verify`.

### `--doctor` and `--build-gateway`

- `--doctor` without `--account` checks the host slice (engine at the
  derived prefix, unit templates installed); with `--account` it adds
  conf parse, `unit.env` match, timer, linger, and (for gateway confs)
  the user manager and gateway image. AppArmor is pointed at
  `--apparmor-check`, not duplicated. This is distinct from the
  engine's `egresslock doctor` (the host environment probe: podman,
  netavark, nft, unprivileged userns, plus labeled account-side
  advisories — backend, netns, gateway image base).
- `--build-gateway` (also `egresslock build-gateway`) builds the
  gateway image in the **invoking user's own shell** from the deployed
  `gateway/` directory next to the engine — no root, no `--account`.
  It never starts `user@` and never enables linger: the user manager
  must already be active (an active session or linger), otherwise it
  fails closed and tells you the fix. `--force` rebuilds even when the
  image already matches the deployed base pin.

### Linger and the drift timer

`--enable` enables **linger** for the account, which keeps
`/run/user/<uid>` alive outside login sessions (required for the
verify timer). Without `--enable`, the **15-minute drift timer will
not run** — the kit works fine without it, but you lose automatic
drift detection. Drift is when a domain's IP changes (DNS
re-resolution): the pinned `allow-host` rules point at stale
addresses, and `verify` reports a `drift:` line; re-run `ensure` to
re-resolve and re-pin. The timer catches this every 15 minutes;
without it you only see drift when you run `verify` by hand.

### The two files that matter

- **The profile conf** (engine input): profiles, subnets, rules,
  allowlist references. Account-owned site data. Gateway profiles need
  an allowlist file **next to the conf** (conf-relative path in the
  `gateway` directive); missing/invalid allowlists fail `ensure`
  closed. Grammar: the [policy reference](policy-reference.md).
- **`~/.config/egresslock/unit.env`** (0600) — *pure systemd wiring*
  (see [the table above](#the-accounts-unitenv)): exactly one
  `EGRESSLOCK_CONF` line, plus `EGRESSLOCK_PROFILE` only when
  `--profile` was given.

`egresslock-setup --help` (`-h`) is the script's source of truth.

## Script parameters & defaults

Every script's `-h`/`--help` is the reference for its options and
environment overrides (including the defaults that are not
parameter-changeable, e.g. `XDG_RUNTIME_DIR=/run/user/$(id -u)` for
the entry scripts and `egresslock`' nft table `egresslock`).
`egresslock-start` deliberately has no `-h` — every argument is
passed through to the daemon unchanged; its header is the reference.
