# Engine, scripts, and environment — configuration reference

This page answers: **"which environment variables, config-resolution
rules, and script defaults govern the engine and its entry scripts?"**
The conf grammar itself is the
[policy reference](policy-reference.md).

## Engine environment overrides

Operator overrides (see `egresslock help env`; the test-harness hooks
are not operator options and live in the hidden test topics — see the
pointer after the table):

| Variable | What it does |
|---|---|
| `NFT_BIN` | path to the `nft` binary; default resolution: `$PATH` first (`command -v nft`), then `/usr/sbin/nft` as a fallback for non-root PATHs that omit `/usr/sbin` |
| `CONNTRACK_BIN` | path to conntrack; default resolution: `$PATH`, then `/usr/sbin/conntrack` — required by `disallow --direct`'s revocation flush |
| `EGRESSLOCK_ALLOW_ROOT=1` | allow running as root (NOT recommended — root's Podman store/netns is not an account) |
| `EGRESSLOCK_GW_LOG_MAX_BYTES` | gateway log rotation cap in bytes (default 32 MiB; `0` = no cap) |
| `EGRESSLOCK_DENIED_MAX_BYTES` | `denied` log-read cap in bytes — the newest N bytes are read, partial first line dropped (default 32 MiB — the same default as `EGRESSLOCK_GW_LOG_MAX_BYTES`, but the two are independent; `0` = the full log) |
| `EGRESSLOCK_LOCK_WAIT` | seconds to wait for the account lock before a writer fails closed (default 30; `verify` waits 5 and then proceeds without it; `0` = don't wait) |
| `EGRESSLOCK_GW_CLEANUP_GRACE` | seconds an unreferenced gateway config file or private stage directory is kept before a later apply removes it (default 3600; `0` = eligible immediately). Host-side `/tmp/egresslock-allowlist.*` staging directories are kept until they are 10 s older than this window. That margin is age-based, not a liveness check: applies that share the account lock are serialized, but a stage older than the margin remains eligible while another lock domain under the same uid may still be using it |

Every `EGRESSLOCK_*` variable in the engine's process environment is
checked at startup: an unknown name is not read and prints one warning
on stderr, and a retired name prints the retired warning instead (see
[Config resolution](#config-resolution)). Commands keep their output
and exit codes, and variable values are never read or echoed. The
known-name list is internal; `egresslock help env` and
`egresslock help env test` are the operator-facing inventory.

The harness-only hooks (the engine and setup image overrides included)
are listed in `egresslock help env test` and
`egresslock-setup help env test`.

## Config resolution

The engine has no compiled-in profiles. The account's config directory
is always `<passwd-home>/.config/egresslock/` — resolved from the
account database, the same passwd-home identity as the account lock,
not the `$HOME` variable (so a command started with a different `HOME`
cannot move the config directory or bypass another command's lock). A
`getent` lookup failure fails closed.

Named commands (ensure, verify <name>, network, proxy-env, rules,
allowlist, denied, allow, disallow (either path),
drop-unauthorized) load exactly `<confdir>/<profile>.conf`. The file's
basename must equal the single `profile` name it defines; a mismatch
fails closed. There is no `main.conf` fallback for other profile
names (`main.conf` is only the starter's own file, defining
`profile main`). `list` and `verify --ensured` aggregate every
`*.conf` in that directory (each file must still obey the basename
rule); `ensure all` and `verify all` resolve the same set in names
mode, so the resolution line lists the profiles instead of the count.
Teardown is the exception: no form loads a conf —
`teardown <name>` derives object names from the token, `teardown all
[--yes]` selects every `*.conf` by file name and refuses (exit 2)
while a legacy `all.conf` exists, and `teardown --orphans` uses
conf-file presence only. `all` and `v6deny` are reserved as profile
names — named commands, `init`, the loader, and `egresslock-setup
doctor --profile` refuse them before probing (see the policy
reference's
[Reserved profile name](policy-reference.md#reserved-profile-name)).

Every conf-resolving invocation prints exactly one stderr line naming
the winning source, every time, TTY-independent: `using config <path>`
on a named load, or `using configs in <dir> (N profiles)` for an
aggregate. The two `all` forms print the same line in names mode —
`using configs in <dir> (3 profiles: a, b, main)`, or
`(1 profile: main)` — and fall back to the count form when any `*.conf`
basename is not a valid profile name (the load then fails closed).
Missing files fail closed with `no profile config: '<path>'
not found` (named) or `no profile config: no *.conf in '<dir>'`
(aggregate). No teardown form prints a resolution line.

`--config <file>` has been removed (v0.9.0); passing the flag exits 2.
A set `EGRESSLOCK_CONF` (including an empty assignment) is retired since
v0.10.0: the engine prints
`Warning: EGRESSLOCK_CONF is retired and is no longer read.` on stderr
and continues as if the variable were unset; `EGRESSLOCK_LEGACY_PREFIX`
(removed in 0.9.0) is the other retired name and gets the same line with
its name substituted. A profile's config is at
`<account-home>/.config/egresslock/<profile>.conf`.

Where each conf-side file lives and how it is managed (modes,
lifecycle, temp leftovers): [File locations](file-locations.md).

## `egresslock-setup` — per-account bootstrap

One-command per-account bootstrap; run as **root**, from the installed
kit or a checkout. `import` copies one profile's conf+allowlist pair
into the account's fixed confdir (staged and moved into place
conf-last, committed atomically — a re-run refuses a destination half
it did not observe, and existing pairs are untouched
without `--force`; the crash case is in
[torn-conf-pair](../troubleshooting/torn-conf-pair.md)); `init`
resolves and validates what is already there, builds the gateway
image (if not already present — one line on
the terminal; the full stream goes to the account's
`~/.config/egresslock/gateway-build.log`), and optionally enables
linger + the verify timer. `init` needs no conf path. The install flow
that invokes it: [Install the kit](../setup/install.md).

### Verbs

The setup tool takes a verb (the grammar + per-verb detail pages live
in its help: `egresslock-setup help VERB`).

| Verb | What it does |
|---|---|
| `egresslock-setup import NAME --from PATH [--allowlist PATH] [--force] [--prefix PATH]` | copy one profile pair into `~/.config/egresslock/`: dest conf name from the source's `profile` line; the source gateway line must name exactly `<profile>-allowlist`, copied next to it (any other name or an absolute path is refused, rc 1). Both destination halves must be absent or regular non-symlink files: a directory, symbolic link, or special file is refused by name (rc 1, nothing moved or deleted). The pair is validated with the deployed engine before commit: an allowlist with an invalid entry is refused (rc 1, the error names the entry), including identical/in-place pairs. Writes no file beyond the pair, never runs linger/timer/ensure. Multi-host form: [fleet deploy recipe](../../examples/recipes/fleet-deploy.md) |
| `egresslock-setup init NAME [--from PATH] [--init-conf] [--prefix PATH] [--enable]` | the account bundle: import with `--from` (or ship the starter with `--init-conf`), then validate every conf already in the fixed confdir (the same aggregate the verify timer checks), build the gateway image (one line on the terminal; the full stream goes to the account's `~/.config/egresslock/gateway-build.log`), optionally enable linger + the verify timer. No conf path required |
| `egresslock-setup doctor [NAME] [--profile NAME] [--prefix PATH]` | read-only kit/account state check with the fix command for each missing item (distinct from the engine's `egresslock doctor`); `--profile` narrows the account slice to that one conf |
| `egresslock-setup build-gateway [--force] [--prefix PATH]` | build the gateway image in the invoking user's own shell (an `egresslock build-gateway` alias) |
| `egresslock-setup apparmor add\|remove\|check` | apply/unapply the pasta AppArmor rule (`add` idempotent; may be combined with the init bundle or used alone); `check` reports AppArmor/pasta amendment health (read-only, no root; prints a `Summary:` verdict line) |
| `egresslock-setup help [VERB]` | the verb summary / one verb's topical page |

### Modifiers

| Flag / operand | What it does |
|---|---|
| `NAME` | target account — the positional operand of `init`, `import`, and `doctor` (required unless the `apparmor` verb is used alone) |
| `--account <name>` | legacy hidden alias of the positional `NAME`; still accepted on `init`, `import`, and `doctor`, and out of the synopses. Passing the same value in both forms is accepted; different values are rc 2 |
| `--from <path>` | import this profile pair first (same semantics as `import`), then wire; the dest is `<profile>.conf` from the source's `profile` line. Mutually exclusive with `--init-conf` |
| `--conf <path>` | with `doctor`, only a display hint (it never selects a runtime conf); `init` no longer accepts it (rc 2 naming `--from`) |
| `--init-conf` | ship the deny-all starter conf pair (`profile main` + empty allowlist) when `~/.config/egresslock/main.conf` is missing — never overwrites; refuses only a conf-present/allowlist-missing pair (an allowlist-present/conf-missing directory is completed without touching the allowlist) |
| `--profile <name>` | with `doctor`: inspect exactly `<name>.conf` instead of every conf. It selects no setup/verify mode: the verify timer always checks every profile with a running anchor, and every other form (`init`, `import`, the legacy flag-only bundle) rejects the flag with rc 2 |
| `--allowlist <path>` | with `import`: override the source allowlist; the destination is still `<profile>-allowlist` |
| `--prefix <path>` | deployed kit prefix (default: derived from the installed unit template, else `/opt/egresslock`) — usually unnecessary: setup retries the `.deb` unit dir when a stale prefix unit points at a missing engine |
| `--enable` | enable+start `egresslock-verify@<account>.timer` AND enable linger for the account (fails closed if linger does not stick) |
| `--force` | with `build-gateway`: rebuild even when the image already matches the deployed pin; with `import`: replace a differing or torn destination pair of regular files |

The legacy flat flag forms — the flag-only account bundle
(`--account A [--init-conf] [flags]` with no verb), plus `--doctor`,
`--build-gateway`, and `--apparmor-add/--apparmor-remove/--apparmor-check`
— keep working as silent aliases of the verbs. The flat bundle no
longer takes a source conf (`--conf` was retired in v0.12.0; use
`init A --from PATH`), and it still cannot overwrite an existing
differing pair (use `import --force` deliberately). The positional
`NAME` is the canonical spelling on `init`, `import`, and `doctor`;
`--account` is a hidden alias of it.

### The run map (numbered progress)

Every account-bundle run prints one line per step, in execution
order, so you can see what a run changed and where it stopped:

```text
1) validate conf … OK
2) linger … OK          # SKIP without --enable
3) user manager … OK
4) gateway image … OK
5) timer … OK           # SKIP without --enable
```

`FAIL` is always the last printed step (the run stops there, nothing
after it executed).

### Root vs account steps

| Step | Runs as | Why |
|---|---|---|
| validate conf | account (`runuser`) | the conf must parse under the account's engine/store |
| linger | **root** | `loginctl enable-linger` is a system logind change (`--enable` only) |
| user manager | **root** | `systemctl start user@UID.service` (gateway confs; start, never restart) |
| gateway image | account (`runuser`) | must land in the account's rootless Podman store |
| timer | **root** | `systemctl enable --now egresslock-verify@ACCOUNT.timer` (`--enable` only) |

### What setup does

- **`--init-conf`** ships the deny-all starter (`profile main` + empty
  allowlist) from `examples/`, only if no conf exists yet (never
  overwrites; never heals an existing conf's missing allowlist); a torn
  pair (conf present, allowlist missing) is refused (rc 1) — create
  the allowlist by hand (empty is the deny-all starter) or move the
  conf aside and re-run.
- **Validates** every `*.conf` in the fixed confdir (the aggregate the
  verify timer checks): each exists AND is readable by the account and
  parses cleanly under the deployed engine.
- **Imports a pair** (`import`, or `init --from`):
  copies the conf as `<home>/.config/egresslock/<profile>.conf` (0600)
  and its `<profile>-allowlist` sibling next to it; a source gateway
  line naming anything else (including an absolute path) is refused
  before staging. Both destination halves must be absent or regular
  non-symlink files: a directory, symbolic link (including dangling),
  or special file is refused by name (rc 1, nothing moved or deleted),
  and a forced replacement removes the regular files it replaces after
  the staged pair validates. Both halves are staged, validated as the
  account (including every allowlist entry — an invalid entry is
  refused and named), then committed allowlist-first/conf-last; a
  refusal or failed validation leaves the destination bytes unchanged.
  Identical destination halves are still validated, so an
  already-installed invalid pair is refused rather than reported
  unchanged; differing or torn halves are refused unless `--force`
  replaces the whole pair. Root-mode validation
  uses a private mount namespace (`unshare -m`); run setup on the
  target host as real root, not inside a restricted container. A host
  that denies `unshare -m` fails closed before touching the destination.
- **Builds the gateway image** into the account's Podman store from
  the deployed prefix if the image is missing.
  The run prints one line, and the full build stream goes to
  `~/.config/egresslock/gateway-build.log` (the last 20 lines are shown
  on failure). Lifecycle and rebuilds: [The gateway image](gateway-image.md).
- **`--enable`** enables+starts `egresslock-verify@<account>.timer`
  and enables linger for the account, so `/run/user/<uid>` persists
  outside login sessions for the timer's `egresslock-verify`.

### The `doctor` and `build-gateway` verbs

- `doctor` without an account operand checks the host slice (engine at
  the derived prefix, unit templates installed); with `NAME` it adds
  conf parse, policy file modes (`<profile>.conf` and
  `<profile>-allowlist` must be `0600`; a confdir writable by other users
  is reported), timer, linger, and (for gateway confs)
  the user manager and gateway image. The mode check is read-only and
  prints the `chmod` command to run as the account — `sudo -u`, no
  login shell needed, so it also works for `nologin` service accounts;
  it follows symlinks and never reports the engine's own records or
  `gateway-build.log`.
  AppArmor is pointed at
  `apparmor check`, not duplicated. This is distinct from the
  engine's `egresslock doctor` (the host environment probe: podman,
  netavark, nft, conntrack, unprivileged userns, plus labeled
  account-side advisories — backend, netns, bridge driver, gateway
  image base, and running gateway image identity). The engine doctor
  also carries three advisory groups: `podman_cve:` after the
  `podman:` row for each known-vulnerable advisory that matches the
  version — one line per matching advisory (the threat model's CVE
  note owns the ranges and the current advisory set, and each line
  names only its advisory), a `workloads:` section (only with
  `--workloads`) for running non-kit containers attached to a profile
  network, the host network, or another container's network namespace
  whose launch obligations it can see, and a `conf:` row per leftover
  retired `rule gateway-only` line in this account's conf files (the
  file and the line; the row is advisory — the line has no effect, so
  ignore it or delete it; it reads the conf files without loading
  them).
  The workload row reads capabilities and no-new-privileges by running
  `cat /proc/1/status` inside each listed container (bounded, best
  effort); an unreadable list or status read, or an inspect read that
  cannot be trusted (unreadable or malformed output), prints
  `UNKNOWN`. All three groups are rc-neutral; bare doctor prints a
  `workloads:` pointer line instead of scanning, and the flagged
  workload section is absent when no container is a candidate, is
  advisory only, and is not a check of
  your next launch. The doctor's
  `running gateway:` row names profiles whose running gateway
  container image ID differs from the tagged image; it is silent when
  no gateway runs or all IDs match, prints `UNKNOWN` when the
  comparison cannot be read, and is rc-neutral.
- `build-gateway` (also `egresslock build-gateway`) builds the
  gateway image in the **invoking user's own shell** from the deployed
  `gateway/` directory next to the engine — no root, no account operand.
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

### The account name 'all' is reserved

`all` is reserved as an account name in setup commands. Other commands
use a bare `all` as a scope word (`ensure all`, `verify all`,
`teardown all`), so `egresslock-setup` refuses `all` as an account on
every path that resolves one (`init`, `import`, `doctor`, and the
legacy flag forms) with exit 2, before the account is read or any file
is written. The engine still runs with an account named `all`; only the
setup paths refuse it. The check is case-sensitive: `ALL` is a
different OS name and is not reserved.

An install whose runner account is already named `all` must rename the
OS account before it can run setup again. The tool never renames an OS
account. The safe order is:

1. disable the account's old verify timer and its linger;
2. rename the OS user **and** its primary group (the home directory and
   the profile files move with the user);
3. run setup for the new name (`init NEW --enable`), which re-validates
   the confdir and re-arms the timer and linger;
4. re-ensure the profiles as the renamed account, so the runtime
   policy and its records are rebuilt under the new home.

Do the timer/linger step first: a running timer or an active user
manager keeps the old account's state live across the rename. Re-check
the result with `egresslock-setup doctor NEW` and
`egresslock verify`.

### The two files that matter

- **The profile conf** (engine input): profiles, subnets, rules,
  allowlist references. Account-owned site data. Every profile needs
  an allowlist file **next to the conf**, and the `gateway` directive
  must name it exactly `<profile>-allowlist`; missing/invalid
  allowlists and non-pair names fail `ensure` closed. Grammar: the
  [policy reference](policy-reference.md). The `*.conf` set in the
  fixed confdir is also the registry the verify timer checks.

`egresslock-setup --help` (`-h`) is the script's source of truth;
`egresslock-setup help VERB` prints one verb's topical page.

## `egresslock-start` — the daemon start wrapper

`egresslock-start` is the kit's daemon start wrapper — an
ensure-then-exec gate, not a workload launcher. It runs `egresslock
ensure PROFILE` and, only when that succeeds, `exec`s a site daemon (a
long-running service such as a CI runner) with the arguments you give
it; it never starts a job container. Workload launch stays with your
launcher, which is what the threat model's "the kit ships no workload
launcher" means. The wrapper covers the other case: a service that
spawns job containers on demand and has no per-job hook to run
`ensure` itself. For the workload-side obligation, see the threat
model's [launcher obligation](threat-model.md#trusted-computing-base).

The anchor container keeps the rootless netns (and therefore the
policy) alive across job churn, but `ensure` is the only thing that
creates or validates the policy. If `ensure` fails, the daemon does
not start (the wrapper exits non-zero).

### Environment

Explicit-only — there are no site defaults:

| Variable | Required | Meaning |
|---|---|---|
| `EGRESSLOCK_PROFILE` | yes | profile name to `ensure` before the daemon starts |
| `RUNNER_BIN` | yes | daemon executable to `exec`. The name is kept for compatibility with existing units; it names any daemon, not only a CI runner |
| `EGRESSLOCK_DIR` | no | directory holding the `egresslock` engine. Resolution order: this variable, then `/opt/egresslock`, then the wrapper's own directory. A set-but-wrong value wins and fails closed (`egresslock not found/executable`) |

The profile conf is not passed to the engine: it always reads
`<account-home>/.config/egresslock/<profile>.conf`.

The daemon's unit sets its own `Environment=` lines; nothing in the kit
writes or reads a per-account environment file.

### Unit shape and install paths

The wrapper is deployed root-owned as part of the kit:
`/opt/egresslock/egresslock-start` for a prefix install, and
`/usr/lib/egresslock/egresslock-start` from the `.deb`. There is no
`PATH` wrapper (unlike `egresslock` and `egresslock-setup`), so a unit
names the full path. A system unit runs it as the account:

```ini
[Service]
User=<account>
Environment=EGRESSLOCK_PROFILE=<profile>
Environment=RUNNER_BIN=/usr/local/bin/<daemon>
ExecStart=/opt/egresslock/egresslock-start <daemon args>
```

The arguments after the wrapper path are the daemon's own: no
argument is consumed, so `egresslock-start daemon -c /path/to/conf`
passes `daemon -c /path/to/conf` through unchanged. That is also why
the script has no `-h`/`--help`.

Use one `ExecStart` rather than an `ExecStartPre=` that runs
`ensure`: the wrapper sets `XDG_RUNTIME_DIR` from `id -u` (`%U`/`%h`
did not expand per-`User=` on the tested hosts, and rootless Podman
needs the account's own runtime dir), resolves the engine directory,
and keeps `ensure` and the daemon in one fail-closed command with the
same environment.

## Script parameters & defaults

Every script's `-h`/`--help` is the reference for its options and
environment overrides (including the defaults that are not
parameter-changeable, e.g. `XDG_RUNTIME_DIR=/run/user/$(id -u)` for
the entry scripts and the `egresslock` nft table).
`egresslock-start` deliberately has no `-h` — every argument is
passed through to the daemon unchanged; its header is the reference
for its flags and arguments, and the
[wrapper section above](#egresslock-start--the-daemon-start-wrapper) holds
its environment table and unit shape.

A few environment variables are test-harness hooks, not operator
knobs: `EGRESSLOCK_APPARMOR_D`, `EGRESSLOCK_SYSTEMCTL`,
`EGRESSLOCK_USERNS_SYSCTL`, `EGRESSLOCK_ACCOUNT_HOME`,
`EGRESSLOCK_UNIT_DIR`, `EGRESSLOCK_PATH_BINDIR`,
`EGRESSLOCK_PATH_SBINDIR`, `EGRESSLOCK_ANCHOR_IMAGE`,
`EGRESSLOCK_GW_IMAGE`, `EGRESSLOCK_SHARE`,
`EGRESSLOCK_DEFAULT_UNIT_DIR`,
`EGRESSLOCK_DEB_UNIT_DIR`, `EGRESSLOCK_ETC_UNIT_DIR`,
`EGRESSLOCK_UNIT_SRC`, `EGRESSLOCK_UB_BIN`, and
`EGRESSLOCK_DEB_LIBDIR` are honored only when
`EGRESSLOCK_KIT_ALLOW_NON_ROOT=1` is set; without it each command
ignores them, with a warning, and uses its production default
(`/etc/apparmor.d`, `systemctl` on `$PATH`, the kernel's
unprivileged-userns sysctl, the passwd home,
`/etc/systemd/system`, `/usr/local/bin`, `/usr/local/sbin`, the
digest-pinned alpine anchor, `localhost/egresslock-gateway:latest`,
the kit share tree, `/etc/systemd/system` for both the default `/etc`
probe and the doctor's `/etc` load-precedence path,
`/usr/lib/systemd/system`, the kit's own `systemd/`,
`/usr/bin/egresslock`, and `/usr/lib/egresslock`). That flag
is a harness-only bypass and is never meant to be set outside the test
harness. It is off by default: only the exact value `1` turns test
mode on, and any other value (e.g. `true`) warns and leaves test mode
off. It reaches a privileged run only by inheritance — `sudo -E`,
or a unit that carries a test environment — and any environment
carrying it makes these hooks live, including as root. Keep it out of
shells and units that run privileged commands.
`EGRESSLOCK_APPARMOR_PROFILES` follows a wider rule: a root run reads
the kernel listing unless `EGRESSLOCK_KIT_ALLOW_NON_ROOT=1` is set,
while a non-root run may point it at a copied listing (the kernel
listing is root-only on many kernels). The installer's advisory read is
test-mode only.
`EGRESSLOCK_DIR` selects the engine directory for the entry scripts;
the default is `/opt/egresslock`, then the script's own directory.

`EGRESSLOCK_SKIP_NETNS_PROBE=1` is a test-harness hook too, and unlike
the list above it is **not** gated by `EGRESSLOCK_KIT_ALLOW_NON_ROOT`:
the engine and the verify timer entry script honor it unconditionally,
and it skips the rootless-network-namespace preflight that fails closed
on a broken netns. Keep it out of timer, service, and shell
environments.
