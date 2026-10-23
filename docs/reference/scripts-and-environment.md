# Engine, scripts, and environment — configuration reference

This page answers: **"which environment variables, config-resolution
rules, and script defaults govern the engine and its entry scripts?"**
The conf grammar itself is the
[policy reference](policy-reference.md).

## Engine environment overrides

See `egresslock help env` for the full list:

| Variable | What it does |
|---|---|
| `NFT_BIN` | path to the `nft` binary (default `/usr/sbin/nft`, else `$PATH`) |
| `CONNTRACK_BIN` | absolute path to conntrack (default `/usr/sbin/conntrack`, then `$PATH`) — required by `disallow-host`'s revocation flush |
| `EGRESSLOCK_ANCHOR_IMAGE` | anchor image (default: base image or alpine) |
| `EGRESSLOCK_GW_IMAGE` | gateway image (default `localhost/egresslock-gateway:latest`) |
| `EGRESSLOCK_ALLOW_ROOT=1` | allow running as root (NOT recommended — root's Podman store/netns is not an account) |
| `EGRESSLOCK_SKIP_NETNS_PROBE=1` | skip the podman rootless-netns preflight probe (test harness only) |
| `EGRESSLOCK_GW_LOG_MAX_BYTES` | gateway log rotation cap in bytes (default 32 MiB; `0` = no cap) |
| `EGRESSLOCK_DENIED_MAX_BYTES` | `denied` log-read cap in bytes — the newest N bytes are read, partial first line dropped (default 32 MiB, same as the rotation cap; `0` = the full log) |
| `EGRESSLOCK_LOCK_WAIT` | seconds to wait for the account lock before a writer fails closed (default 30; `verify` waits 5 and then proceeds without it; `0` = don't wait) |

## Config resolution

The engine has no compiled-in profiles. The account's config directory
is always `<passwd-home>/.config/egresslock/` — resolved from the
account database, the same passwd-home identity as the account lock,
not the `$HOME` variable (so a command started with a different `HOME`
cannot move the config directory or bypass another command's lock). A
`getent` lookup failure fails closed.

Named commands (ensure, verify <name>, network, proxy-env, rules,
allowlist, denied, allow, disallow, allow-host, disallow-host,
drop-unauthorized, teardown <name>) load exactly
`<confdir>/<profile>.conf`. The file's basename must equal the single
`profile` name it defines; a mismatch fails closed. There is no
`main.conf` fallback for other profile names (`main.conf` is only the
starter's own file, defining `profile main`). Bare `list` and bare
`verify --ensured` aggregate every `*.conf` in that directory (each
file must still obey the basename rule); bare `teardown all` stays
`main.conf`-only.

Every conf-resolving invocation prints exactly one stderr line naming
the winning source, every time, TTY-independent: `using config <path>`
on a named load, or `using configs in <dir> (N profiles)` for an
aggregate. Missing files fail closed with `no profile config: '<path>'
not found` (named) or `no profile config: no *.conf in '<dir>'`
(aggregate).

`--config <file>` has been removed (v0.9.0): passing it is a usage error
(rc 2). `EGRESSLOCK_CONF` is no longer read; set neither.

Where each conf-side file lives and how it is managed (modes,
lifecycle, temp leftovers): [File locations](file-locations.md).

## The account's `unit.env`

`~/.config/egresslock/unit.env` (0600, written by `egresslock-setup init`;
`import` never writes it — see
[The two files that matter](#the-two-files-that-matter) below):

| Line | Meaning |
|---|---|
| `EGRESSLOCK_PROFILE=<name>` | optional — named verify mode; omit (empty file) for `--ensured` |

There is no conf-path line: the engine's confdir is fixed, so `unit.env`
is only the named-verify switch (and its presence is the wiring
witness).

## `egresslock-setup` — per-account bootstrap

One-command per-account bootstrap; run as **root**, from the installed
kit or a checkout. `import` copies one profile's conf+allowlist pair
into the account's fixed confdir (atomic, never clobbering); `init`
resolves and validates what is already there, writes the account's
`unit.env`, builds the gateway image (if a conf has one — one line on
the terminal; the full stream goes to the account's
`~/.config/egresslock/gateway-build.log`), and optionally enables
linger + the verify timer. `init` needs no conf path. The install flow
that invokes it: [Install the kit](../setup/install.md).

### Verbs

The setup tool takes a verb (the grammar + per-verb detail pages live
in its help: `egresslock-setup help <verb>`).

| Verb | What it does |
|---|---|
| `egresslock-setup import --account <name> --from <path> [--allowlist <path>] [--force] [--prefix <path>]` | copy one profile pair into `~/.config/egresslock/`: dest conf name from the source's `profile` line; a basename gateway allowlist is copied next to it. Never writes `unit.env`, never runs linger/timer/ensure. Multi-host form: [fleet deploy recipe](../../examples/recipes/fleet-deploy.md) |
| `egresslock-setup init --account <name> [--from <path>] [--profile <name>] [--init-conf] [--prefix <path>] [--enable]` | the account bundle: import with `--from` (or ship the starter with `--init-conf`), then validate the conf(s) already in the fixed confdir, wire `unit.env`, build the gateway image (one line on the terminal; the full stream goes to the account's `~/.config/egresslock/gateway-build.log`), optionally enable linger + the verify timer. No conf path required |
| `egresslock-setup doctor [--account <name>] [--prefix <path>]` | read-only kit/account state check with the fix command for each missing item (distinct from the engine's `egresslock doctor`) |
| `egresslock-setup build-gateway [--force] [--prefix <path>]` | build the gateway image in the invoking user's own shell (an `egresslock build-gateway` alias) |
| `egresslock-setup apparmor add\|remove\|check` | apply/unapply the pasta AppArmor rule (`add` idempotent; may be combined with the init bundle or used alone); `check` reports AppArmor/pasta amendment health (read-only, no root; prints a `Summary:` verdict line) |
| `egresslock-setup help [<verb>]` | the verb summary / one verb's topical page |

### Modifiers

| Flag | What it does |
|---|---|
| `--account <name>` | target account (required unless the `apparmor` verb is used alone) |
| `--from <path>` | import this profile pair first (same semantics as `import`), then wire; the dest is `<profile>.conf` from the source's `profile` line. Mutually exclusive with `--init-conf` |
| `--conf <path>` | legacy silent alias of `--from` for `init`; for `doctor`, only a display hint (it never selects a runtime conf) |
| `--init-conf` | ship the deny-all starter conf pair (`profile main` + empty allowlist) when `~/.config/egresslock/main.conf` is missing — never overwrites; refuses only a conf-present/allowlist-missing pair (an allowlist-present/conf-missing directory is completed without touching the allowlist); `--init-conf --profile <name>` other than `main` is a usage error |
| `--profile <name>` | write `EGRESSLOCK_PROFILE=<name>` (named verify mode) and validate exactly `<name>.conf`. Omit for aggregate/`--ensured` mode; a pathless re-run without `--profile` clears named mode. This is the only flag that chooses named mode (import never does) |
| `--allowlist <path>` | with `import`: override the source allowlist; the destination name still comes from the conf's gateway line |
| `--prefix <path>` | deployed kit prefix (default: derived from the installed unit template, else `/opt/egresslock`) — usually unnecessary: setup retries the `.deb` unit dir when a stale prefix unit points at a missing engine |
| `--enable` | enable+start `egresslock-verify@<account>.timer` AND enable linger for the account (fails closed if linger does not stick) |
| `--force` | with `build-gateway`: rebuild even when the image already matches the deployed pin; with `import`: replace a differing or torn destination pair |

The legacy flat flag forms — the flag-only account bundle
(`--account A --conf C [flags]` with no verb), plus `--doctor`,
`--build-gateway`, and `--apparmor-add/--apparmor-remove/--apparmor-check`
— keep working as silent aliases of the verbs. In the flat bundle
`--conf` is the same alias of `--from`; it still cannot overwrite an
existing differing pair (use `import --force` deliberately).

### The run map (numbered progress)

Every account-bundle run prints one line per step, in execution
order, so you can see what a run changed and where it stopped:

```text
1) validate conf … OK
2) write unit.env … OK
3) linger … OK          # SKIP without --enable
4) user manager … OK    # SKIP without any `gateway` line in the confdir
5) gateway image … OK   # SKIP without any `gateway` line
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
  overwrites; never heals an existing conf's missing allowlist); a torn
  pair (conf present, allowlist missing) is refused (rc 1) — create
  the allowlist by hand (empty is the deny-all starter) or move the
  conf aside and re-run.
- **Validates** the conf: exists AND readable by the account, parses
  cleanly under the deployed engine, and (with `--profile`) that the
  named profile exists in it.
- **Imports a pair** (`import`, or `init --from`/legacy `--conf`):
  copies the conf as `<home>/.config/egresslock/<profile>.conf` (0600)
  and a basename gateway allowlist next to it. Both halves are staged,
  validated as the account, then committed allowlist-first/conf-last;
  a refusal or failed validation leaves the destination bytes
  unchanged. Root-mode validation uses a private mount namespace
  (`unshare -m`); run setup on the target host as real root, not inside a
  restricted container. A host that denies `unshare -m` fails closed before
  touching the destination. Existing identical halves are a no-op;
  differing/torn halves are refused unless `--force` replaces the
  whole pair.
- **Writes `~/.config/egresslock/unit.env`** (0600): an
  `EGRESSLOCK_PROFILE=<name>` line only with `init --profile`, which
  also selects exactly `<name>.conf`. Every other `init` (including
  pathless re-runs and `init --from` without `--profile`) writes an
  empty file: aggregate mode. Import never writes `unit.env`, so it
  cannot narrow the timer. There is no conf-path line.
- **Builds the gateway image** into the account's Podman store from
  the deployed prefix (for gateway profiles) if the image is missing.
  The run prints one line, and the full build stream goes to
  `~/.config/egresslock/gateway-build.log` (the last 20 lines are shown
  on failure). Lifecycle and rebuilds: [The gateway image](gateway-image.md).
- **`--enable`** enables+starts `egresslock-verify@<account>.timer`
  and enables linger for the account, so `/run/user/<uid>` persists
  outside login sessions for the timer's `egresslock-verify`.

### The `doctor` and `build-gateway` verbs

- `doctor` without `--account` checks the host slice (engine at the
  derived prefix, unit templates installed); with `--account` it adds
  conf parse, `unit.env` match, timer, linger, and (for gateway confs)
  the user manager and gateway image. AppArmor is pointed at
  `apparmor check`, not duplicated. This is distinct from the
  engine's `egresslock doctor` (the host environment probe: podman,
  netavark, nft, unprivileged userns, plus labeled account-side
  advisories — backend, netns, gateway image base).
- `build-gateway` (also `egresslock build-gateway`) builds the
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
drift detection. Drift is when a domain's address set at `ensure` time
changes (DNS re-resolution — a member address appears or disappears;
a resolver reorder of the same addresses is not a change): the pinned
`allow-host` rules point at stale addresses, and `verify` reports a
`drift:` line; re-run `ensure` to
re-resolve and re-pin. The timer catches this every 15 minutes;
without it you only see drift when you run `verify` by hand.

The pinned set is capped at the first 16 sorted distinct addresses
(`DNS_SET_MAX`); a larger answer is truncated with a named `note:` on
stderr.

### The two files that matter

- **The profile conf** (engine input): profiles, subnets, rules,
  allowlist references. Account-owned site data. Gateway profiles need
  an allowlist file **next to the conf** (conf-relative path in the
  `gateway` directive); missing/invalid allowlists fail `ensure`
  closed. Grammar: the [policy reference](policy-reference.md).
- **`~/.config/egresslock/unit.env`** (0600) — *pure systemd wiring*
  (see [the table above](#the-accounts-unitenv)): no conf path, an
  `EGRESSLOCK_PROFILE` line only when `init --profile` was given.

`egresslock-setup --help` (`-h`) is the script's source of truth;
`egresslock-setup help <verb>` prints one verb's topical page.

## Script parameters & defaults

Every script's `-h`/`--help` is the reference for its options and
environment overrides (including the defaults that are not
parameter-changeable, e.g. `XDG_RUNTIME_DIR=/run/user/$(id -u)` for
the entry scripts and `egresslock`' nft table `egresslock`).
`egresslock-start` deliberately has no `-h` — every argument is
passed through to the daemon unchanged; its header is the reference.
