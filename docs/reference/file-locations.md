# File locations — where egresslock keeps its files

This page answers: **"where does X live?"** — the profile conf and
allowlist, the pin record, `unit.env`, the engine lock, the proxy env
file, the build log, and the temp files a killed run can leave
behind. Everything here is owned by the container-owner account
(`egl-runner` in the guides); run the listed commands as that
account. The files the kit installs for the whole host (prefix,
units, PATH wrappers) are on
[Files the kit installs](files-installed.md); the gateway's own logs
live inside the gateway container — [Inspecting the gateway (Squid)
logs](../troubleshooting/gateway-logs.md).

## Config and policy data — `~/.config/egresslock/`

The confdir is created on first write (`egresslock init`,
`egresslock-setup`) under your umask. It holds one small file family
per profile, plus the account's wiring:

| File | What it is | Mode | Written by | Removed by |
|---|---|---|---|---|
| `<profile>.conf` | the profile conf — profiles, subnets, rules, `allow-host` entries; the engine's input | 0600 from `egresslock init`; `egresslock-setup import` stages the source as 0600; `--init-conf` stages the starter with umask 077 and renames it into place (0600) | `egresslock init`; `egresslock-setup import --from`; `egresslock-setup init --init-conf` (first create); `allow-host` / `disallow-host` (rewrite in place, keeping the mode); your editor | archiving it ([Delete a profile](policy-reference.md#delete-a-profile)); `uninstall-kit.sh --purge-account-data`; `rm` by hand |
| `<profile>-allowlist` | the gateway allowlist — one `host[:port]` per line, matched by Squid's `dstdomain` | 0600 from `egresslock init`; `egresslock-setup import` stages a basename allowlist as 0600; `--init-conf` stages a missing starter sibling with umask 077 (0600; no entries, `EMPTY by design`) and leaves a pre-existing allowlist untouched, keeping its mode | `egresslock allow` / `disallow` (in place, keeping the mode); `egresslock init` (empty); `egresslock-setup import`; the kit starter | same as the conf |
| `<profile>.pins` | the pin record — the addresses `ensure` installed for the profile's `allow-host` entries; `verify` compares the live chain against it and fails closed on divergence | 0600 | `egresslock ensure <profile>` | `ensure` also removes it when the profile has no `allow-host` entries; remove it with the conf pair when archiving; `--purge-account-data`. To regenerate: re-run `ensure` |
| `unit.env` | the verify timer's wiring: `EGRESSLOCK_PROFILE=…` in named mode; empty for the `--ensured` sweep (no conf path — the confdir is fixed) | 0600 | `egresslock-setup` (rewritten wholesale on re-run) | `--purge-account-data`; `rm` by hand. To regenerate: re-run `egresslock-setup init` |
| `gateway-build.log` | the full output of the last gateway image build (the terminal shows one line; on failure, the last 20 lines) | 0644 (created by the build's output redirect) | `egresslock-setup` when it builds the gateway image | the next build overwrites it; `--purge-account-data`; safe to delete any time |

## Runtime and state

| File | What it is | Mode | Written by | Removed by |
|---|---|---|---|---|
| `~/.local/state/egresslock/engine.lock` | the account-wide lock that serializes `ensure`, `allow`, `disallow`, `allow-host`, `disallow-host`, `drop-unauthorized`, `teardown`, and `init`; the file records the current holder (`pid=… mode=… started=…`); a writer truncates it on acquire, so it stays tiny. The path is anchored to the account's home directory as the system account database records it, not the `HOME` variable. | directory 0700; file under your umask (0644 typical — the directory is what keeps it private) | the writer commands; `verify` shares the lock when it can | nothing — leave it in place. The kernel releases the lock when the holder exits; deleting the file while commands run would let two writers past the lock. The full story: [A concurrent command is in progress](../troubleshooting/concurrent-commands.md) |
| `egresslock-proxy-<profile>.env` | the six proxy assignments (`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`, both cases) for a profile's gateway | 0600 | `egresslock proxy-env <profile> --out` (prints the path; `--out=<path>` writes elsewhere) | nothing automatic. The default lives under the account's runtime directory (`${XDG_RUNTIME_DIR:-/run/user/<uid>}`), which goes away at reboot — and at logout without linger; regenerate with `--out` after any policy or env change, then recreate the container — [Proxy clients](proxy-clients.md) |

## Logs

`gateway-build.log` (above) is the one log egresslock keeps in the
confdir. The gateway's request and error logs (Squid `access.log` /
`cache.log`) live inside the gateway container — read them with
`egresslock denied` or `podman exec`:
[Inspecting the gateway (Squid) logs](../troubleshooting/gateway-logs.md).

## Transients — temp files a killed run can leave behind

Little here is meant to survive a run: every command removes its temp
files on success and on failure. A leftover means the process was
killed mid-run (SIGKILL, power loss). Leftovers are inert — no
command reads an old temp file, and the next run makes a fresh one —
so deleting them is safe, as long as no egresslock command is
running.

| File | What it is |
|---|---|
| `/tmp/egresslock-policy.*.nft` | the ruleset file a policy install hands to `nft -f` |
| `/tmp/egresslock-verify.*` | the working file `verify` builds the expected ruleset in |
| `/tmp/egresslock-allowlist.*/` | the staging directory for the generated gateway allowlist files |
| `<file>.XXXXXX` beside a file being replaced | atomic-write temps beside the conf, allowlist, pin record, and proxy env file (`XXXXXX` is mktemp's random suffix) |

## Backing up, moving, or removing these files

To back up an account's policy, copy `~/.config/egresslock/` — the
confs, allowlists, pin records, and `unit.env` are all small;
`gateway-build.log` is a log, skip it. Regenerable (no backup
needed): the pin records (re-run `ensure`), `unit.env` (re-run
`egresslock-setup init`), the lock, and every transient above.

Removal follows the account's own lifecycle: one profile —
[Delete a profile](policy-reference.md#delete-a-profile) (teardown,
then archive the files); the whole kit —
[Uninstall the kit](../setup/uninstall.md)
(`--purge-account-data` deletes the confdir; the state directory and
the account's Podman state stay behind).

Not listed here: Podman's own state — the account's container and
image store, networks, and the netns under
`/run/user/<uid>/netns/`. Those belong to Podman;
[Uninstall the kit](../setup/uninstall.md) covers reclaiming them.

