# Engine, scripts, and environment — configuration reference

This page answers: **"which environment variables, config-resolution
rules, and script defaults govern the engine and its entry scripts?"**
The conf grammar itself is the
[policy reference](policy-reference.md).

## Engine environment overrides

(see `egresslock --help`): `EGRESSLOCK_CONF` (required for every
profile subcommand — the engine has no compiled-in profiles; unset or
empty fails closed with `no profile config`), `NFT_BIN`,
`EGRESSLOCK_ANCHOR_IMAGE`, `EGRESSLOCK_GW_IMAGE`.

## Config resolution

When neither `--config` nor `EGRESSLOCK_CONF` is given, the engine
probes the running user's default folder `~/.config/egresslock/`.
Named commands (ensure, verify <name>, network, proxy-env, rules,
allowlist, denied, allow, disallow, allow-host, disallow-host,
teardown <name>) use `<profile>.conf` if present, else `main.conf`
(the `--init-conf` dest), printing `using config <path>` on stderr
(only when stdout is a terminal — under `$(...)` substitution the hint
is suppressed). Bare `list` and bare `verify --ensured` aggregate
every `*.conf` in that folder (`using configs in <dir>`); bare
`teardown all` stays `main.conf`-only. Without any file it fails
closed exactly as above. Explicit always beats the probe.

## The account's `unit.env`

`~/.config/egresslock/unit.env` (0600, written by `egresslock-setup` —
see [Install the kit](../setup/install.md) → Account setup → The two
files that matter):

| Line | Meaning |
|---|---|
| `EGRESSLOCK_CONF=<conf path>` | required — where the account's profile conf is |
| `EGRESSLOCK_PROFILE=<name>` | optional — named verify mode; omit for `--ensured` |

## Script parameters & defaults

Every script's `-h`/`--help` is the reference for its options and
environment overrides (including the defaults that are not
parameter-changeable, e.g. `XDG_RUNTIME_DIR=/run/user/$(id -u)` for
the entry scripts and `egresslock`' nft table `egresslock`).
`egresslock-start` deliberately has no `-h` — every argument is
passed through to the daemon unchanged; its header is the reference.
