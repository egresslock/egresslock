# Policy reference

The profile-conf grammar, the allowlist format, and the fail-closed
rules that govern them. This page answers: **"what can I configure,
and which mechanism allows which destination?"** The practical
"how do I allow X" walkthroughs:
[allow-a-domain](../quickstart/allow-a-domain.md) and
[allow-non-http](../quickstart/allow-non-http.md).

This page is the exhaustive reference for the conf grammar, files, and
lifecycle. The first-run path is [install](../setup/install.md) +
[first-run checks](../quickstart/first-run-checks.md); creating an
additional profile is optional — see
[Profile lifecycle](#profile-lifecycle).

**On this page:** [Destination → mechanism decision table](#destination--mechanism-decision-table) ·
[Profile conf](#profile-conf) ·
[Concepts](#concepts) · [Runtime and verification](#runtime-and-verification) ·
[Account ownership](#account-ownership) · [File names (the convention)](#file-names-the-convention) ·
[Rules to keep straight](#rules-to-keep-straight) · [Profile lifecycle](#profile-lifecycle) ·
[The allowlist file](#the-allowlist-file) · [Direct rules in detail](#direct-rules-in-detail)

## Destination → mechanism decision table

| If the destination is... | Use | Command | Special considerations |
|---|---|---|---|
| domain, HTTP(S), standard port | Squid allowlist | `allow main example.com` (bare = 443 group) | Squid resolves at request time — no pin drift; apt/wget/git/pip read only the LOWERCASE proxy vars |
| domain, HTTP(S), non-standard port | Squid allowlist, explicit port | `allow main example.com:8443` | becomes its own per-port dstdomain group; a plain-HTTP GET denial needs an explicit `:80` entry (a bare 443 entry does NOT cover port 80) |
| domain, non-HTTP protocol (ssh, git-over-SSH, rsync) | nft allow-host (direct) | `allow main git.example.test:2222 --direct` | bypasses the gateway; ssh ignores HTTP(S)_PROXY so no NO_PROXY entry is needed; pins the host's A set at `ensure` (up to the first 16 sorted distinct addresses; a larger answer truncates with a named stderr note) — drift only if a member address appears/disappears ([T13](threat-model.md#attacks-table)); a name that serves one rotating A per query (`github.com` SSH) can never be pinned stably — see [Direct rules in detail](#direct-rules-in-detail) |
| IPv4 literal, any port/protocol | nft allow-host (direct) | `allow main 192.0.2.24:11434 --direct` | literals are REJECTED on the proxy path and accepted here (the proxy-path error names this retry); never drifts; `proxy-env` unions the pin into NO_PROXY — check `proxy-env main noproxy`, and **recreate** the workload; see [allow-non-http](../quickstart/allow-non-http.md) |
| HTTP(S) service on the SAME host | Squid allowlist | `allow main host.containers.internal:8000` | proxied; the gateway resolves the podman-injected name; the host's LAN IP itself can never work (pasta hairpin — [paths-and-signatures](paths-and-signatures.md); fix: [cannot-reach-host-service](../troubleshooting/cannot-reach-host-service.md)) |
| non-HTTP service on the SAME host | nft allow-host, IP literal | `allow main 169.254.1.2:8000 --direct` | `169.254.1.2` is pasta's host address (podman map-guest-addr); the NAME cannot be pinned — [paths-and-signatures](paths-and-signatures.md); fix: [cannot-reach-host-service](../troubleshooting/cannot-reach-host-service.md) |
| IP/CIDR range | not yet supported | — | (planned: conf rule, nft-only — dstdomain cannot express CIDRs) |

**HTTP(S) by name is always proxied.** There is no name bypass: `NO_PROXY` is derived (`localhost,127.0.0.1` plus the profile's IPv4 direct pins), so a hostname cannot be added to it. Put the destination on the profile's Squid allowlist instead — it still uses the gateway. Only an IPv4 `--direct` pin also lands in the emitted `NO_PROXY`, which is what lets a proxy-honoring client take that literal down the direct path.

## Profile conf

Each profile is a `<profile>.conf` + `<profile>-allowlist` pair under
`~/.config/egresslock/` (see
[Profile lifecycle](#profile-lifecycle)). `#`
comments and blank lines are ignored; any unparseable or contradictory
content fails closed with exit 2. Rule identity follows that same view:
everything from the first `#` is a comment, so
`rule allow-host host:22 # ssh` is the same configured rule as
`rule allow-host host:22`, while a fully commented-out `# rule ...`
line is not a rule.

| Directive | Meaning |
|---|---|
| `profile <name> <cidr>` | starts the profile block. `<cidr>` is the private subnet for the profile's own bridge network (`egresslock-<name>`) — the range its containers get addresses from; it is internal plumbing, not a LAN or an access grant (egress is controlled by the rules and allowlist). IPv4 CIDR, prefixlen 8-29, canonical network address. Exactly one `profile` block per conf file — a second is rejected at load (exit 2). The names `all` and `v6deny` are reserved — see [Reserved profile name](#reserved-profile-name) |
| `rule allow-host <host>:<port>` | direct host:port allow (repeatable; resolved at ensure time) |
| `rule gateway-only` | **retired**: ignored at load, silently (it does not warn; exit code unchanged; on the canonical shape `init` writes — the line first among the rules — adding or removing the line does not change `egresslock rules` output). Every profile already allows the gateway's proxy port from its required `gateway` line, so this line has no effect — delete it when convenient. `egresslock doctor` lists each leftover line with one rc-neutral `conf: <conf>:<line>:` row naming the file, the line, and the plain status: the line has no effect, so ignore it or delete it (no `ensure` is needed) |
| `gateway <ip> <port> <file>` | **required in every profile**: static gateway IP inside the subnet + Squid port + the co-located allowlist, which the line must name exactly `<profile>-allowlist`. Any other basename, an absolute path, or a path with a directory component is rejected at load (exit 2, naming the line and the expected file), so the line can never name another profile's file. (The sibling rule and the symlink/hardlink rewrite behavior: [File names](#file-names-the-convention).) A profile without a `gateway` directive is rejected at load (exit 2) — there is no direct-only profile mode |
| `read-timeout <seconds>` | Squid `read_timeout` override, positive integer seconds (default 900 — Squid's stock 15 minutes). Raise it for long silent non-streaming calls (LLM completions); lower it for CI-style tight failure timing. The generated gateway config always carries the explicit `read_timeout <N> seconds` line. See [troubleshooting: long request dies at exactly 15m00](../troubleshooting/long-request-15m.md) |

## Concepts

| Concept | What it is | Per profile? |
|---|---|---|
| profile | a class in a config file: subnet + rules + gateway | one conf block |
| conf file | the declarative config; exactly one profile per file | one file per profile: `~/.config/egresslock/<name>.conf` |
| allowlist file | the gateway's allowed destinations (`dstdomain`) | one per profile |
| Podman network | `egresslock-<profile>` | created by `ensure` |
| anchor | `egresslock-anchor-<profile>` keeps the netns/policy alive | created by `ensure` |
| gateway | `egresslock-gateway-<profile>` Squid container; explicit direct-access rules use a separate path | created by `ensure` |
| verify | compares the live nftables policy with the expected profile rules | run per profile or by the verify timer |

## Runtime and verification

`ensure <profile>` creates or validates the profile network, starts the
anchor, starts or refreshes the gateway, installs the
nftables policy, and verifies the result before a workload should start. The
anchor keeps the account's rootless network namespace and policy alive between
workloads.

`ensure` on an already-converged profile is **non-disruptive on the
confirmed-reload path**: healthy containers are kept, and no established
session is severed when the running gateway reloads in place. The
generated gateway config and allowlist groups are still republished
(identical content-addressed names are reused), and the running gateway
is then reloaded in place (the engine signals the running daemon) when it
was started on the deployed config. The reload is confirmed only after
the gateway's own `cache.log` names the re-read config, the container's
start time is unchanged, and the proxy probe answers; otherwise the
engine warns and falls back to a restart, which **does** drop established
proxied sessions (the warning says so). On the confirmed reload path a
new connection can be refused during the sub-second listener close/reopen,
but established proxied sessions stay.
The first apply, and an apply that finds the running instance on the
bootstrap or an older config path, restarts that gateway once instead
(the bootstrap restart is silent; a fallback restart warns).
Every successful apply prints the same ready line,
`gateway '<name>' ready (allowlist applied, health verified)`; there is no
converged-skip or activation-witness file, and a redundant `ensure` now
reports the apply line rather than `already converged, not restarted`.
A post-apply health failure removes the gateway instead of leaving it
in place; the next `egresslock ensure PROFILE` recreates it.
The deployed allowlist groups are content-addressed and immutable, and the
single `squid.conf` rename publishes them; unreferenced old group files and
private stage directories are removed only after verification and a grace
window (default 3600 s), never a deployed reference or `allowlist.conf`.
The nftables policy refresh (atomic;
established/related keeps direct flows) and DNS-pin healing still run on
every ensure; those never sever sessions. `disallow --direct` is the
exception: it is the kill-switch, not a refresh — it ends every revoked
flow it can observe and proves severance. The full contract
(pending-revocation record, failure disclosures, accepted sub-second
gap): [Direct rules in detail](#direct-rules-in-detail).

A manual conf edit that removes a direct rule followed by `ensure` is a
policy refresh, not the kill-switch: it does not flush conntrack, so
any established flow to the address that rule had installed persists
until it expires naturally or until a later `disallow --direct` on that
port ends it. The one exception is an interrupted `disallow … --direct`
that left a pending-revocation record: the next `ensure` finishes that
revocation (it ends the recorded connections and clears the record),
and `verify` reports it as `unfinished revocation` until then. An
unhealthy container takes the replace path as before, and a warm
gateway takes the reload path even when its config changed; `disallow`
on the proxy path forces the restart so a revoked destination cannot
continue on an established CONNECT tunnel. `ensure` remains the
crash-recovery command.

`verify <profile>` compares the live nftables chain with the rules expected
from the profile. Structural drift or a missing healthy runtime fails
verification. For direct `allow-host` pins, `ensure` also writes a pin
record (`<profile>.pins`, beside the conf) of the addresses it installed;
`verify` fails closed with a named error when a live pin's address diverges
from that record (a post-ensure chain edit), when the record is missing
(re-run `ensure`), or when it is unreadable. DNS drift for direct
`allow-host` pins remains a signal only: `verify` warns when the fresh
A set differs from the pinned set (a resolver reorder is not a change)
and does not re-pin; re-run `ensure` to resolve and install fresh pins. A name
that serves one rotating address per query re-pins only the one member it
saw — a later cycle that resolves another member warns again. The systemd
verify timer repeats this check for the account. Where the pin record
and every other account-side file lives (mode, lifecycle, leftovers):
[File locations](file-locations.md).

## Account ownership

Run profile commands as the dedicated unprivileged account, never as root.
Each account has its own rootless Podman store and rootless network namespace;
accounts cannot see or affect one another's networks through this kit. Root
installs or distributes the kit, but does not run the account's policy jobs.

The profile configuration and allowlists remain in the account's
`~/.config/egresslock/` and are not mounted into workload containers by the
kit; the operator's launcher is the only path in. The broader trust
assumptions and limits are in the
[threat model](threat-model.md).

## File names (the convention)

Each profile is a **`<profile>.conf` + `<profile>-allowlist`** pair next
to each other under `~/.config/egresslock/` — e.g. `main.conf` +
`main-allowlist`, `dev.conf` + `dev-allowlist`. The `gateway`
directive's file argument must be exactly `<profile>-allowlist`: the
parser refuses any other basename, an absolute path, or a path with a
directory component (exit 2, naming the conf line and the expected
file), so a gateway line can never name another profile's file. A
symlink or hardlink placed at `<profile>-allowlist` inside the
account's own confdir is an explicit operator act; the conf loader does
not detect it. The proxy-path `allow`/`disallow` rewrites refuse a
symlink (edit the referent by hand while no egresslock command is
running, then `ensure <profile>`; a plain `ensure` reloads, while
`ensure --replace-gateway` drops every proxied session on the profile —
see [File locations](file-locations.md#how-proxy-disallow-writes-the-allowlist));
a hard link is allowed and the rewrite leaves its other names unchanged.
The `--direct` conf rewrites follow the same rule: a symbolic link at
`<profile>.conf` is refused, and the file it points to is never written —
edit the referent by hand while no egresslock command is running, then
`ensure <profile>`.
Do **not** invent `*-profile.conf` names — the `<profile>.conf` +
`<profile>-allowlist` pairing is the convention. (The gateway container's runtime
file `/etc/squid/egresslock/allowlist.conf` — still
`/etc/squid/agent/allowlist.conf` on a gateway not yet replaced from
an older image — is the image's empty bootstrap allowlist (the active
allowlist is the content-addressed group files the generated
`squid.conf` references), not one of these profile pairs — different
directory, never user-edited.)

A conf file holds exactly one `profile` block. A conf with a second
`profile` block is rejected when it loads (exit 2, naming the file, the
line, and the profile already defined); if you keep several profiles in
one conf, split each `profile` block into its own `<profile>.conf` file
in `~/.config/egresslock/`. The engine reads that fixed path directly.

**Migrating an older hand-written pair:** the refusal happens while the
conf loads, so it leaves an already-running gateway and its current
grants in place — and blocks `disallow <profile>` until the conf is
migrated. To stop enforcement urgently without a loadable conf,
`egresslock teardown all --yes` selects every `<profile>.conf` by file
name (their contents are not read, so a malformed conf cannot block
it), or `egresslock teardown PROFILE` removes one profile without
its conf. Their keep/`incomplete teardown` semantics are in
[Profile lifecycle](#profile-lifecycle); `egresslock teardown
--orphans` sweeps kit objects whose config is already gone. Confirm
the account is clean afterwards (`podman ps -a`, `podman network ls`,
and the nft-table check in [Checking everything](check-everything.md))
— `no kit leftovers` alone is not proof when a note says otherwise.
Stop automation and workloads first, because `all` also removes
enforcement for every other profile.

1. Compare the file the current `gateway` line names with
   `~/.config/egresslock/<profile>-allowlist` (if it exists): read both
   before changing either.
2. Copy the entries you intend into
   `~/.config/egresslock/<profile>-allowlist` (create it 0600). Leave
   the named file where it is — never move or overwrite it. If it is
   another profile's, outside the confdir, or still named by another
   conf, moving it would break that other profile or the external
   owner.
3. If `<profile>-allowlist` already exists, merge the intended entries
   into it instead of replacing it.
4. Edit the `gateway` line to name `<profile>-allowlist`, then re-run
   `egresslock list` and `egresslock ensure PROFILE`.

There is no auto-rename and no silent fallback. Until it is migrated,
every load of that conf fails closed (exit 2) — including `list` and
`verify --ensured`, so one legacy conf breaks the account-wide
aggregate, not only `ensure`/the timer. The different failure — a conf
whose allowlist half is missing — is
[torn conf pair](../troubleshooting/torn-conf-pair.md).

## Rules to keep straight

- **Subnets must not collide** — `ensure` rejects a profile whose
  subnet would overlap an existing Podman network (a pre-check before
  it creates the profile network). Pick a distinct range per profile.
- **Gateway IP must be inside the subnet's usable range**: not the
  network address, not the bridge gateway (first usable = `.1`), not
  the anchor (last usable). `.2` is valid for a `/24`.
- **Each profile needs its own allowlist file** — its `gateway`
  directive must name exactly `<profile>-allowlist`, the sibling of the
  conf. Another profile's file, an absolute path, or a path component
  is refused at load.
- **Run every command as the account** (`sudo -iu ACCOUNT`), never
  root.
- **Commands that change a profile serialize.** `ensure`, the four
  mutators, `teardown`, and `init` take one account-wide lock for the
  whole read → apply → verify critical section, so two commands can no
  longer undo each other or race the gateway container. A losing
  command waits 30 s (tunable: `EGRESSLOCK_LOCK_WAIT`) and then fails
  closed with a named message; `verify` shares the lock and proceeds
  without it rather than blocking the timer. See
  [concurrent-commands](../troubleshooting/concurrent-commands.md).
  The lock is keyed to the account's home directory as the system account
  database records it, not the `HOME` variable, so a command started with
  a different `HOME` cannot bypass another command's lock.

## Profile lifecycle

- `ensure <profile>` applies (or re-applies) one profile's policy; an
  already-converged profile is a no-op.
- `ensure all [--yes]` ensures every profile named by a `<profile>.conf`
  file in the default confdir, in conf-file order, and stops at the
  first failure. There is no rollback: earlier profiles stay ensured
  and a retry converges the rest. When more than one profile resolves,
  it prints the list and requires `--yes` or a terminal `y`; a
  non-terminal run without `--yes` refuses with exit 1 and changes
  nothing. A single profile runs without a prompt.
  `--replace-gateway` applies to every profile.
- `verify <profile>` checks one profile; `verify all` (no profile)
  checks every profile named by a `<profile>.conf` file, continues
  after each named failure, and ends with one tally. A never-ensured
  profile is a named failure (the same lines as `verify <profile>`),
  not a skip. `verify --ensured` (no profile) aggregates every `*.conf`
  in the default confdir — a profile with a live anchor is verified, a
  never-ensured one is skipped, and a post-reboot leftover (network up,
  policy gone) is a named failure.
- `teardown <profile>` stops the anchor (and gateway), removes the
  network, and removes the profile's own firewall chain from the kit's
  `inet egresslock` table. It works without the conf: object names
  derive from the profile name, so a name with nothing left prints the
  `not present` lines plus `nothing left for profile '<name>'` and
  exits 0. When it was the last profile and no kit network is in use,
  it removes the shared table (including the shared `p_v6deny` chain)
  too. A network still in use, an unreadable network or nft listing,
  or a failed removal keeps the firewall state; the run names why and
  the next step, and never points at an account-wide sweep. A blind
  container, network, or nft listing prints `incomplete teardown` and
  exits 1 (it never claims `not present` or `nothing left`).
  `teardown v6deny` exits 2: `v6deny` is reserved because it derives
  the shared `p_v6deny` chain (see
  [Reserved profile name](#reserved-profile-name)).
- `teardown all [--yes]` tears down every profile named by a
  `<profile>.conf` file in the confdir — not just `main`. It reads the
  files' names only, prints one `teardown all: N profiles: …` line,
  and when more than one profile resolves requires `--yes` or a
  terminal `y`; a non-terminal run without `--yes` refuses with exit 1
  and removes nothing. Zero configs is exit 2 with a pointer at
  `teardown --orphans`. While a legacy `all.conf` exists, `teardown
  all` refuses (exit 2) — see
  [Reserved profile name](#reserved-profile-name). A config directory
  that exists but cannot be listed is a named exit-2 refusal with
  nothing removed.
- `teardown --orphans` is the config-aware recovery sweep: it
  name-scans this store for kit containers, networks, and
  `p_<profile>` chains and removes those no remaining
  `<profile>.conf` owns, then deletes `inet egresslock` only when no
  config remains and no kit network or chain is left. Live-profile
  objects are kept silently; a legacy `all.conf` or an unreadable
  config is kept and named, never swept. Every listing is bounded at
  5s. When it cannot list containers, networks, or the firewall
  table, it prints `incomplete sweep` and exits 1; a failed removal or
  a kept network still exits 0 with its own note. A kept network also
  keeps the firewall table (the attached workload stays policed);
  remove the workload and re-run to delete it. `no kit leftovers`
  prints only when it saw nothing kit-owned at all. A config directory
  that exists but cannot be listed is a named exit-1 refusal with
  nothing removed. Confirm the store is clean (see
  [Checking everything](check-everything.md)).

### Reserved profile name

`all` is not a profile name. Every name boundary refuses it: `init`,
named commands (`ensure`, `verify`, `network`, `rules`, `allow`,
`disallow`, …), the config loader, and `egresslock-setup doctor --profile`
exit 2 with a named `reserved` error before a conf is read or a file
is written. `egresslock-setup import` refuses a source whose `profile`
line names `all` with exit 1, before any destination write. `main` and
every other `[a-z0-9][a-z0-9-]*` name are unchanged.

`v6deny` is reserved too: the name derives the shared IPv6-deny chain
`p_v6deny` (`chain_of` replaces `-` with `_`), so a profile named
`v6deny` would install into, verify against, or tear down the chain
every profile shares. The same boundaries refuse it: `init`, the named
commands, the config loader, and `egresslock-setup doctor --profile`
exit 2; `egresslock-setup import` refuses the source with exit 1.
`teardown v6deny` exits 2 as well: the token names the shared chain,
not a profile.

A profile named `all` written by an earlier release is not
auto-healed: its `all.conf` fails to load (so `list`,
`verify --ensured`, `ensure all`, and `verify all` fail closed), and
`teardown all` refuses while `all.conf` exists instead of guessing a
target. To migrate:

1. Rename `~/.config/egresslock/all.conf` and its allowlist to a valid
   name, and update the `profile` line inside the conf; rename
   `all.pins` too if present. Update the `gateway` line's allowlist
   basename to match.
2. If the old profile was ever ensured, its runtime objects keep the
   reserved name: `egresslock-all` (network),
   `egresslock-anchor-all`, and `egresslock-gateway-all`. With
   `all.conf` renamed or removed, `egresslock teardown --orphans`
   sweeps those now-unowned objects; while a workload still uses
   `egresslock-all`, the sweep keeps the network and firewall table
   too (remove the workload and re-run), and while `all.conf` still
   exists it keeps and names them. You can also delete those Podman
   objects by hand. The sweep prints `incomplete sweep` and exits 1
   when it cannot list the runtime, so confirm nothing remains.
3. `egresslock ensure NEW-NAME`.

A profile named `v6deny` written or imported before this release is not
auto-healed either: its conf fails to load (so `list`,
`verify --ensured`, `ensure all`, and `verify all` fail closed), the
named commands refuse the token, and `teardown v6deny` refuses. To
migrate:

1. Rename `~/.config/egresslock/v6deny.conf` and `v6deny-allowlist` to
   a valid name, update the `profile` line inside the conf and the
   gateway line's allowlist basename, then `egresslock ensure NEW-NAME`.
   (If the pair was never used, remove it instead.)
2. If it was ever ensured, its old runtime objects keep the reserved
   name: `egresslock-v6deny` (network), `egresslock-anchor-v6deny`, and
   `egresslock-gateway-v6deny`. Once no `<profile>.conf` owns them,
   `egresslock teardown --orphans` removes them; stop any workload
   attached to `egresslock-v6deny` first (an in-use network is kept and
   named). The sweep never removes the shared `p_v6deny` chain.
3. If it was the last profile, the sweep also deletes the shared table
   once no config remains.

With `all.conf` gone, `teardown all` selects every remaining
`<profile>.conf` as above; `all` itself remains a reserved name.

### Create a profile

Create an additional profile and bring up its network, policy, and
gateway live — the same commands create the second one or the fifth.
Normal install already created `main`.

Prerequisites: an account set up with a name of your choosing (the
examples use `egl-runner`; enter its shell with `sudo -iu egl-runner` —
[who-runs-what](who-runs-what.md)), the kit installed
([install](../setup/install.md)), and the shared example image
`localhost/egl-base:latest` built once per account
([egl-base](../../examples/egl-base/README.md#build)).

#### The steps

1. **Write the starter pair** — `init` writes the profile's config
   and an empty allowlist (denies application connections; DNS to the
   bridge resolver is still allowed). It auto-picks a free /24 for
   the profile's own bridge network; pass `--subnet` only to avoid a
   range the host already uses or to keep a stable per-profile range —
   it does not change what the profile can reach:

   ```sh
   # the host, account shell: sudo -iu egl-runner
   # prompt: egl-runner@host:~$

   egresslock init dev
   ```

   If `init` exits non-zero, stop. Nothing was overwritten; the
   existing conf/allowlist pair is preserved. Choose another name, or
   archive the pair first ([Delete a profile](#delete-a-profile)).
   Never delete or reset an existing policy to continue.

2. **Build it** — `ensure` creates the network, starts the anchor and
   gateway, installs the policy, and verifies the result:

   ```sh
   # the host, account shell: sudo -iu egl-runner
   # prompt: egl-runner@host:~$

   egresslock ensure dev
   ```

   `ensure` also prints a `note:` pointing at the
   [operator obligations checklist](operator-obligations.md) — review
   it before starting a workload.

   If `ensure` exits non-zero, stop — do not launch. A failed attempt
   can leave the network up without enforcement. Re-run `ensure` to
   recover; nothing is deleted.

3. **Run a shell on it** — the empty allowlist denies application
   connections; DNS queries to the bridge resolver are still allowed
   and can carry data out ([threat model](threat-model.md)). The proxy
   env comes in as one env file:

   ```sh
   # the host, account shell: sudo -iu egl-runner
   # prompt: egl-runner@host:~$

   egresslock ensure dev \
    && podman run --rm -it --name probe \
        --cap-drop=all --security-opt=no-new-privileges \
        --network="$(egresslock network dev)" \
        --env-file="$(egresslock proxy-env dev --out)" \
        localhost/egl-base:latest \
        sh
   ```

   You land at the container's shell prompt (in-container root — not
   the host account). The env file injects the profile's six proxy
   vars in one go (what they are and why there are six:
   [proxy-clients](proxy-clients.md)). The bare `--out` is the
   recommended form: it writes the env file mode 0600 under your
   private runtime dir and prints its path. Use `--out=<path>` only as
   a backup when you need the file at a specific location; its
   directory must be writable only by your account (a group- or
   world-writable directory is refused), otherwise pass them to
   `podman run` with `--env KEY=value`.

4. **Grow it** — `egresslock list` shows the profile, and
   `egresslock allow dev HOST[:PORT]` adds allowlist entries (see
   [allow-a-domain](../quickstart/allow-a-domain.md)). On disk you
   have one conf + allowlist pair per profile, and the profile is
   targetable by name: `egresslock network dev` and
   `egresslock proxy-env dev` need no extra arguments.

### Delete a profile

There is no `egresslock remove` — teardown does the
runtime half; archiving the files is a filesystem step:

1. **As the account**, teardown the profile's runtime state (keeps
   other profiles):
   ```sh
   /opt/egresslock/egresslock teardown NAME
   ```
   This stops `egresslock-gateway-<name>` / `egresslock-anchor-<name>`,
   removes the `egresslock-<name>` network, and removes the profile's
   `p_<name>` firewall chain (with `-` written as `_`). When it was the
   last profile and no kit network is in use, it also removes the
   shared `inet egresslock` table (`p_v6deny` included).
2. **Archive the files** (safer than rm — reversible):
   ```sh
   mkdir -p ~/.config/egresslock/.bak
   mv ~/.config/egresslock/NAME.conf ~/.config/egresslock/NAME-allowlist ~/.config/egresslock/.bak/
   mv ~/.config/egresslock/NAME.pins ~/.config/egresslock/.bak/ 2>/dev/null || true   # absent when the profile has no allow-host entries
   mv ~/.config/egresslock/NAME.revoke-pending ~/.config/egresslock/.bak/ 2>/dev/null || true   # absent unless an interrupted disallow --direct left one
   ```
3. **Confirm the firewall state is gone.** `teardown` already removed
   the profile's chain (and, as the last profile, the shared table).
   If it reported a network still in use, an unreadable listing, or a
   failed removal, fix that and re-run `egresslock teardown NAME` —
   it needs no conf, so archiving the files above does not block
   recovery. A leftover config-less chain reports `unexpected chain`
   (from `verify` and the 15-minute timer) until it is gone. `ensure`
   of any remaining profile removes it (it prints
   `ensure: removed unexpected chain '<name>'`):
   ```sh
   egresslock ensure REMAINING-PROFILE
   ```
   Or remove it by hand — flush first, because a rule-bearing chain
   cannot be deleted:
   ```sh
   podman unshare --rootless-netns nft list table inet egresslock
   podman unshare --rootless-netns nft flush chain inet egresslock p_NAME
   podman unshare --rootless-netns nft delete chain inet egresslock p_NAME
   ```
   Skip the last two commands when the listing does not show the chain.
   `verify` names the exact chain in its message if you are unsure of
   the spelling. If the teardown run reported a network still in use,
   an unreadable listing, or a failed removal, the firewall state is
   still there and the run's note carries the manual recipe.
4. **Confirm nothing is left**: `list` on the remaining confs; no
   `egresslock-<name>` in `podman network ls`; no `egresslock-anchor-<name>` /
   `egresslock-gateway-<name>` in `podman ps -a`.

## The allowlist file

The `gateway` directive names the profile's allowlist file: exactly
`<profile>-allowlist`, the conf's co-located sibling. One `host[:port]`
per line, matched by
Squid `dstdomain`; entries without a port form the 443 group, `host:port`
entries get their own port group. This file is the PROXY path: read it
with `egresslock allowlist PROFILE`, which renders the configured
entries one per line in file order (comments and blank lines are not
shown; an explicit `:443` and the entered spelling are preserved). An
empty file prints a header with `0 proxy entries`; an invalid entry
fails the command closed and names the line. The direct path's
configured `rule allow-host` entries are a separate view — see
[Direct rules in detail](#direct-rules-in-detail).

Entries are **hostnames only** — a literal IPv4 is rejected by
`allow`/`disallow` and fails `ensure` closed (use `allow … --direct`
for address pins). Missing or invalid allowlists fail `ensure` closed;
`egresslock-setup import`/`init` also refuse a pair with an invalid
entry before commit (rc 1, the engine error names the entry).

Entries are **bare names** — a trailing dot (`name.`) is rejected by
`allow`/`disallow` and fails `ensure` closed: the gateway's `dstdomain`
ACL compares host and entry from the string ends, so an entry carrying
the DNS root dot can never match. Request-side trailing dots
(`CONNECT name.:443`) are normalized by the gateway itself; the entry
does not need to carry one.

A **leading dot** makes the entry a dstdomain *suffix*: `.example.com`
(optionally `.example.com:8443`) matches the bare host **and every
subdomain**, within its port group only. Two consequences to weigh:

- a suffix entry is a wide grant — one line authorizes the whole
  subtree for that port group;
- a suffix entry has no single-pin equivalent on the direct path
  (there is no `--direct` rule that covers a name subtree), so the
  same width cannot be expressed there.

`denied` treats a suffix entry as covering the denials it matches:
hosts covered by a suffix entry stop appearing in the `denied`
output.

A numeric-host (IP-literal) CONNECT/GET through the proxy is denied even
when a PTR of that IP equals an allowlisted name: the generated
`dstdomain` ACLs carry `-n` (no reverse-DNS adoption), so the name
contract is exactly the allowlist. Address pins stay on the direct path.

The generated gateway config reserves `egresslock-probe.invalid`
(RFC 2606). A dest-only deny sits before every allow and answers with a
302 whose `Location` carries a token derived from the deployed config
and its allowlist groups; `verify` compares that token with the one the
running Squid serves. The deny wins over any allowlist entry, so do not
add the reserved name to an allowlist — it can never be forwarded. The
token is not a secret and grants no access. `egresslock denied` omits
the engine's own probe requests for this exact host.

A changed allowlist is applied by reloading the gateway in place when
the reload can be confirmed, so established proxied sessions survive.
A `disallow` apply always restarts the gateway, as do the other restart
paths (a fallback restart, a first apply or bootstrap, an older config
path, `ensure --replace-gateway`); a restart drops the profile's
proxied sessions briefly — including other containers' sessions on the
same profile network.

## Direct rules in detail

The direct path (`egresslock allow PROFILE HOST:PORT --direct`)
compiles to a direct `ip daddr <ip> tcp dport <port> accept` rule
enforced independently of the HTTP gateway.

- **Inventory** — `egresslock allowlist PROFILE --direct` lists the
  configured entries (one `host:port` per `rule allow-host` line, conf
  order), without resolving names and without reading the pin record;
  `egresslock allowlist-direct PROFILE` is the shortcut. This is the
  configured-entry view, not a witness of what is installed. Both views
  share the header shape:
  `profile '<name>' — <N> <lane> entries from the <source> (<resolution>)`;
  a profile with no direct entries prints `0 direct entries` and no
  rows. Inline comments are ignored for rule identity (the conf parser's
  view): `rule allow-host host:22 # ssh` is one entry, and a fully
  commented-out `# rule ...` line is not an entry. To see the
  compiled accept rules, use `egresslock rules PROFILE` (it
  re-resolves names fresh and fails closed if one no longer resolves);
  the pin record remains the ensure-time witness.
- **Hostname or IPv4 literal** — `allow … --direct` accepts a hostname
  or a literal IPv4 address (`host:port` always required; there is no
  default direct port). CIDR ranges are not accepted here (a
  whole-subnet allow is not expressible yet).
- **DNS drift** — the rule pins the host's A record set at
  `ensure` time (deduplicated, sorted; one accept per address; at most
  the first 16 distinct addresses — `DNS_SET_MAX` — with a named
  stderr note when a larger answer is truncated). A later
  DNS change does NOT update it; the 15-minute verify timer only
  **warns** (`drift: host ... policy pins ...`, on a set change — a
  resolver reorder of the same addresses is not a change), it never
  re-pins. Re-run `ensure` to refresh. Stale DNS looks like a hang to
  the new IP while the old IP still works.

  The pin is one `ensure` answer. A name whose DNS serves **one A per
  query from a rotating pool** (`github.com` over SSH is the common
  case) goes stale as soon as the answer moves on: a cycle that
  resolves another member fires `drift:`, and only the pinned member
  is reachable — accepted risk [T13](threat-model.md#attacks-table). The replacements are the
  literal pool (one `rule allow-host` line per observed member — never
  drifts) or the gateway name path when the client can tunnel
  ([Rotating names](rotating-names.md)).
- **Tamper detection** — `ensure` records every installed pin address in
  `<profile>.pins` beside the conf; `verify` compares the live chain's
  pin addresses against that record and fails closed (named error, rc 1)
  on divergence — an in-place chain edit cannot adopt its own addresses
  as the expected values. A missing record fails closed with a re-ensure
  hint (upgrade path: run `ensure` once after upgrading).
- **Revocation** — `disallow <profile> <host:port> --direct` is the
  kill-switch: it removes the conf line, re-ensures (atomic ruleset
  swap), then ends every revoked flow it can observe — first right after
  the swap, then a confirmation pass after the policy is verified — and
  proves it — old
  DNS addresses, the peer-direction conntrack entry, and half-closed or
  still-starting flows — keeps connections another remaining rule still
  authorizes, and refuses with a named error instead of a bare `removed:`
  when it cannot prove severance. An inline `#` comment does not hide
  the rule: the whole configured line is removed (comment included, plus
  every equivalent port spelling), and `allow --direct` reports such a
  line as already present instead of adding a duplicate. One accepted
  gap behind a green
  `removed:`: a packet accepted just before the swap but recorded
  in conntrack only after the check runs is invisible to the check — in
  that sub-second window one flow can still finish behind a green
  `removed:`.
  An interrupted `disallow <profile> <host:port> --direct` — a crash,
  kill, or abrupt stop after the conf rule is removed and the ruleset
  swapped but before the connections are proven ended — leaves a durable
  pending-revocation record (`<profile>.revoke-pending`, beside the
  conf). The flow may keep going until the next `egresslock ensure
  PROFILE`, which finishes the revocation and clears the record; until
  then `verify <profile>` and the 15-minute timer fail with `verify:
  unfinished revocation …` (rc 1). A completed revocation, an ordinary
  `ensure`/refresh run, and a reboot (which empties conntrack) are
  unchanged.
  A failure in that first pass keeps the existing `conntrack not
  proven clean` disclosure. After the first pass the gateway apply runs
  and the policy is verified; only the confirmation pass that follows
  it can claim the kill or print `removed:`. A later failure still
  fails the command (no `removed:`) and discloses only what the run
  proved: before policy verification, that the policy was not verified
  and the rule may still be in the firewall; after verification but
  before the confirmation, that the rule is out and the policy is
  verified but the connections this run could observe were not proven
  ended; after the confirmation, that the rule is out, the connections
  this run could observe were ended, and the check is clean. Each
  carries the gateway fact — `gateway verified`, `gateway verified,
  then removed by this run's cleanup`, or `gateway not verified` — and
  names `egresslock ensure PROFILE` next. If a connection is believed to
  have survived — for example, because something else changed the
  firewall during the run — run that `ensure` first, then
  `egresslock drop-unauthorized PROFILE PORT`: it ends the
  connections on that port the policy no longer allows and keeps the
  connections the policy still allows.
  A `disallow --direct` that cannot prove severance
  fails loudly with the state disclosed, and it requires the `conntrack`
  tool. When the profile's installed firewall rules cannot be read, or
  no longer match its pin record (a tampered or drifted profile),
  `disallow --direct` refuses before anything changes (exit code 1, nothing
  removed): run `egresslock ensure PROFILE`, then retry the command.
  That healing `ensure` re-resolves and re-installs every direct
  rule in the profile — the rule being revoked included, so it is
  enforced again (or stays enforced) until the retry removes it — and
  it keeps established direct flows; it is a separate run from the
  retry. If a name the profile uses no longer resolves, that `ensure`
  cannot heal the profile: use the manual recovery,
  [Revoking a rule whose name no longer resolves](../troubleshooting/revocation-name-gone.md).
- **What "direct" changes (and what it does not)** — a direct rule
  bypasses the Squid gateway but does NOT widen egress: the terminal
  scoped drop still applies and fail-closed is unchanged. What moves is
  the enforcement point and its visibility: identity is the pinned A
  set (at most the first 16 sorted distinct addresses — `DNS_SET_MAX`)
  rather than a per-request hostname, there is no hostname access log
  (`denied --direct` lists recent IPv4:port terminal TCP drops from a
  bounded in-kernel set — 24h idle expiry, 16384 entries; every
  successful `denied` view prints one shared caveat before the entries
  and a full record warns, so a short or empty list is not proof that
  nothing was denied), and DNS drift is a verify
  warning until you re-run
  `ensure` (a name that serves one rotating address per query re-pins
  only the one member it saw — see
  [Rotating names](rotating-names.md)).
  It exists because it is the only way to give proxy-unaware clients
  non-HTTP egress (e.g. git-over-SSH) — Squid carries HTTP(S) requests,
  and only a client that speaks HTTP CONNECT can tunnel another
  protocol through it — everything else should pass the gateway's
  allowlist. The failure
  signatures: [paths-and-signatures](paths-and-signatures.md).

### HTTP vs non-HTTP: gateway vs direct

| | gateway allowlist | `allow … --direct` |
|---|---|---|
| protocols | HTTP(S) CONNECT via Squid | any TCP port the rule names |
| identity | hostname at request time | A-set pinned at `ensure` (first 16 sorted distinct) |
| log / `denied` | Squid access.log; `denied` lists hostnames | no hostname log; `denied --direct` lists IPv4:port drops (bounded; a full record warns) |
| failure mode | 403 (visible in `denied`) | silent hang / timeout |

Non-HTTP denials therefore look like a **hang**, not a 403, and plain
`denied` never sees them (the gateway never saw the packet).
`denied PROFILE --direct` lists the IPv4 TCP destinations that hit the
profile's terminal drop, from a bounded set whose entries expire; it
prints the shared caveat before the entries, and a full record prints a
warning that later denials were dropped but are not listed. A short or
empty list does not prove that nothing else was denied. Other protocols
are not permitted for workload egress (DNS `:53` to the bridge gateway
excepted), so UDP/ICMP to other destinations are dropped, not merely
unlisted.
Confirm a direct allow with `rules` and a real client (e.g. `ssh -T
git@git.example.test`). This is a deliberate trade: Squid is the
HTTP(S) gateway; non-HTTP is *transparently* a direct nftables rule
(proxy-capable clients may instead tunnel a non-HTTP connection by
name through the gateway —
[Rotating names](rotating-names.md)).

### Combining with a gateway

- Gateway profiles: egress goes through the Squid gateway
  (allowlist-controlled); every profile's nftables chain permits the
  gateway IP:port. Use the allowlist / `allow` to grow it.
- A direct rule coexists with the gateway (direct
  destinations use the separate nftables-enforced path).

The same host:port may exist in both stores at once — the gateway
allowlist and a `rule allow-host` line. `disallow` removes from one
store only: without `--direct` it removes the allowlist entry; with
`--direct` it removes the firewall rule. Removing one does not
remove the other.
