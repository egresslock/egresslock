# Policy reference

The profile-conf grammar, the allowlist format, and the fail-closed
rules that govern them. This page answers: **"what can I configure,
and which mechanism allows which destination?"** The practical
"how do I allow X" walkthroughs:
[allow-a-domain](../quickstart/allow-a-domain.md) and
[allow-non-http](../quickstart/allow-non-http.md).

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
| domain, non-HTTP protocol (ssh, git-over-SSH, rsync) | nft allow-host (direct) | `allow main git.example.test:2222 --direct` | bypasses the gateway; ssh ignores HTTP(S)_PROXY so no no-proxy needed; pins the host's A set at `ensure` (up to the first 16 sorted distinct addresses; a larger answer truncates with a named stderr note) — drift only if a member address appears/disappears (T13); a name that serves one rotating A per query (`github.com` SSH) can never be pinned stably — see [Direct rules in detail](#direct-rules-in-detail) |
| IPv4 literal, any port/protocol | nft allow-host (direct) | `allow main 192.0.2.24:11434 --direct` | literals are REJECTED on the proxy path and accepted here (the proxy-path error names this retry); never drifts; `proxy-env` unions the pin into NO_PROXY — check `proxy-env main noproxy`, and **recreate** the workload; see [allow-non-http](../quickstart/allow-non-http.md) |
| HTTP(S) service on the SAME host | Squid allowlist | `allow main host.containers.internal:8000` | proxied; the gateway resolves the podman-injected name; the host's LAN IP itself can never work (pasta hairpin — [paths-and-signatures](paths-and-signatures.md); fix: [cannot-reach-host-service](../troubleshooting/cannot-reach-host-service.md)) |
| non-HTTP service on the SAME host | nft allow-host, IP literal | `allow main 169.254.1.2:8000 --direct` | `169.254.1.2` is pasta's host address (podman map-guest-addr); the NAME cannot be pinned — [paths-and-signatures](paths-and-signatures.md); fix: [cannot-reach-host-service](../troubleshooting/cannot-reach-host-service.md) |
| domain that must NOT go through the proxy | nft allow-host + `no-proxy` | `allow … --direct` + `no-proxy <host>` in the conf | for gateway profiles whose clients honor proxy env |
| IP/CIDR range | not yet supported | — | (planned: conf rule, nft-only — dstdomain cannot express CIDRs) |

## Profile conf

Each profile is a `<profile>.conf` + `<profile>-allowlist` pair under
`~/.config/egresslock/` (see
[Profile lifecycle](#profile-lifecycle)). `#`
comments and blank lines are ignored; any unparseable or contradictory
content fails closed with exit 2. Host fields may use `${VAR}` /
`${VAR:-default}` (parsed manually, never eval'd); the value comes from
the environment `egresslock` was started with, and a `${VAR}` with no
default that is unset or empty there fails the load. An exported name
takes its exported value, even when it collides with an engine variable;
an unexported name takes its `:-default`, or fails the load when it has
none.

| Directive | Meaning |
|---|---|
| `profile <name> <cidr>` | starts the profile block. `<cidr>` is the private subnet for the profile's own bridge network (`egresslock-<name>`) — the range its containers get addresses from; it is internal plumbing, not a LAN or an access grant (egress is controlled by the rules and allowlist). IPv4 CIDR, prefixlen 8-29, canonical network address. Exactly one `profile` block per conf file — a second is rejected at load (exit 2). The name `all` is reserved — see [Reserved profile name](#reserved-profile-name) |
| `rule allow-host <host>:<port>` | direct host:port allow (repeatable; resolved at ensure time) |
| `rule gateway-only` | egress only through the profile's gateway |
| `gateway <ip> <port> <file>` | **required in every profile**: static gateway IP inside the subnet + Squid port + the co-located allowlist, which the line must name exactly `<profile>-allowlist`. Any other basename, an absolute path, or a path with a directory component is rejected at load (exit 2, naming the line and the expected file), so the line can never name another profile's file. A symlink or hardlink placed at `<profile>-allowlist` inside the account's own confdir is an explicit operator act and is not detected. A profile without a `gateway` directive is rejected at load (exit 2) — there is no direct-only profile mode |
| `no-proxy <host,...>` | extra NO_PROXY entries (hosts the profile may reach directly) |
| `read-timeout <seconds>` | gateway profiles: Squid `read_timeout` override, positive integer seconds (default 900 — Squid's stock 15 minutes). Raise it for long silent non-streaming calls (LLM completions); lower it for CI-style tight failure timing. The generated gateway config always carries the explicit `read_timeout <N> seconds` line. See [troubleshooting: long request dies at exactly 15m00](../troubleshooting/long-request-15m.md) |

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

`ensure` on an already-converged profile is **non-disruptive**: healthy
containers are kept and no session is severed. Converged means the anchor is
running, the gateway is running and answers its probe, the newly generated
gateway config and allowlist files are byte-identical to what is deployed,
and a durable activation record (`.egresslock-activated`) shows that the
current gateway instance started with and loaded that exact deployed config.
The record is written only after the restart, the health probe, a read-back
of the deployed bytes and a PID 1 argument check; byte equality alone is not
proof of the live ACL. A missing, stale or mismatched record takes the apply
path, so the first `ensure` after an upgrade, a reboot or a crash restarts
that gateway once to record the new instance. A converged ensure skips the
restart (the ready line says `already converged, not restarted`). The
deployed allowlist groups are content-addressed and immutable, and the
single `squid.conf` rename publishes them; unreferenced old group files and
private stage directories are removed only after verification and a grace
window (default 3600 s), never a deployed reference, `allowlist.conf` or the
activation record. The nftables policy refresh (atomic;
established/related keeps direct flows) and DNS-pin healing still run on
every ensure; those never sever sessions. `disallow --direct` is the exception:
it ends every revoked flow it can observe, and proves it — old DNS
addresses, the peer-direction conntrack entry, and half-closed or
still-starting flows — keeps connections another remaining rule still
authorizes, and refuses with a named error instead of a bare `removed:`
when it cannot prove severance. One accepted gap behind a green `removed:`
(0.9.0): a packet accepted just before the swap but recorded in conntrack
only after the check runs is invisible to the check — in that sub-second
window one flow can still finish behind a green `removed:`. Revocation is
the documented kill-switch, the opposite intent of a refresh. A
manual
conf edit that removes a direct rule followed by `ensure`
is a policy refresh, not the kill-switch: it does not flush conntrack, so
any established flow to the address that rule had installed persists until
it expires naturally or until a later `disallow --direct` on that port ends
it. An unhealthy container or a genuinely changed config takes the replace/restart
path as before — `ensure` remains the crash-recovery command.

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
account's own confdir is an explicit operator act and is not detected.
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
`egresslock teardown --runtime` sweeps the kit containers, networks,
and firewall table by name. That sweep is best-effort: it can skip a
failed listing, leave an object it could not remove, and still exit 0
(its `no kit runtime` summary alone is not proof), so confirm the
account is clean afterwards (`podman ps -a`, `podman network ls`, and
the nft-table check in [Checking everything](check-everything.md)).
Stop automation and workloads first, because it also removes
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
   `egresslock list` and `egresslock ensure <profile>`.

There is no auto-rename and no silent fallback. Until it is migrated,
every load of that conf fails closed (exit 2) — including `list` and
`verify --ensured`, so one legacy conf breaks the account-wide
aggregate, not only `ensure`/the timer.

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
- **Run every command as the account** (`sudo -iu <account>`), never
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

- `verify <profile>` checks one profile; `verify --ensured` checks
  every profile with a live anchor (bare `verify --ensured` also
  scans the default folder).
- `teardown <profile>` stops the anchor (and gateway) and removes the
  network; `teardown all` only ever touches `main.conf`, never sibling
  confs. While a legacy `all.conf` exists, `teardown all` refuses
  (exit 2) instead of reading `main.conf` — see
  [Reserved profile name](#reserved-profile-name).
- `teardown --runtime` is the no-conf recovery sweep: it
  name-scans this store for kit containers and networks
  (`egresslock-*`) and removes what it can — best-effort, so
  confirm the store is clean (see
  [Checking everything](check-everything.md)). `all` stays
  main.conf-only.

### Reserved profile name

`all` is not a profile name. Every name boundary refuses it: `init`,
named commands (`ensure`, `verify`, `network`, `rules`, `allow`,
`disallow`, …), the config loader, and `egresslock-setup --profile`
exit 2 with a named `reserved` error before a conf is read or a file
is written. `egresslock-setup import` refuses a source whose `profile`
line names `all` with exit 1, before any destination write. `main` and
every other `[a-z0-9][a-z0-9-]*` name are unchanged.

A profile named `all` written by an earlier release is not
auto-healed: its `all.conf` fails to load (so `list` and
`verify --ensured` fail closed), and `teardown all` refuses while
`all.conf` exists instead of tearing down `main` on your behalf. To
migrate:

1. Rename `~/.config/egresslock/all.conf` and its allowlist to a valid
   name, and update the `profile` line inside the conf; rename
   `all.pins` too if present. Update the `gateway` line's allowlist
   basename to match.
2. If the old profile was ever ensured, its runtime objects keep the
   reserved name: `egresslock-all` (network),
   `egresslock-anchor-all`, and `egresslock-gateway-all`. Remove them
   with the account-wide `egresslock teardown --runtime` (the only kit
   name sweep), or delete those Podman objects by hand; the sweep is
   best-effort, so confirm nothing remains.
3. `egresslock ensure <new-name>`.

After `all.conf` is gone, `teardown all` keeps its main.conf-only
meaning; `teardown main` is the explicit equivalent.

### Create a profile

Create an additional profile and bring up its network, policy, and
gateway live — the same three commands create the second one or the
fifth. Normal install already created `main`.

> **Before you start**
>
> 1. an account set up with a name of your choosing — the examples
>    use `egl-runner`; enter its shell with `sudo -iu egl-runner`
>    (see [who-runs-what](who-runs-what.md) for the three worlds)
> 2. the kit installed (see [install](../setup/install.md))
> 3. the shared example image `localhost/egl-base:latest` —
>    built once per account
>    ([egl-base](../../examples/egl-base/README.md#build))

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

   <details>
   <summary>Expected output:</summary>

   <pre>
   egl-runner@host:~$ egresslock init dev
   init: wrote /home/egl-runner/.config/egresslock/dev.conf
   init: wrote /home/egl-runner/.config/egresslock/dev-allowlist (empty allowlist — deny all)
   init: next: egresslock ensure dev
   </pre>

   `init` only writes files — the network, anchor, gateway, and policy
   all come from the next step.
   </details>

   If `init` exits non-zero, stop. Nothing was overwritten; the
   existing conf/allowlist pair is preserved. Choose another name, or
   archive the pair first ([Delete a profile](#delete-a-profile)).
   Never delete or reset an existing policy to continue.

2. **Build it:**

   ```sh
   # the host, account shell: sudo -iu egl-runner
   # prompt: egl-runner@host:~$

   egresslock ensure dev
   ```

   <details>
   <summary>Expected output:</summary>

   <pre>
   egl-runner@host:~$ egresslock ensure dev
   using config /home/egl-runner/.config/egresslock/dev.conf
   created network egresslock-dev (10.199.1.0/24)
   started anchor egresslock-anchor-dev
   gateway 'egresslock-gateway-dev' ready (allowlist applied, health verified)
   profile 'dev' ready (network egresslock-dev, policy verified)
   </pre>

   The first ensure builds everything live; run it again later and the
   same command verifies and reuses what's already there.
   </details>

   If `ensure` exits non-zero, stop — do not launch. A failed attempt
   can leave the network up without enforcement. Re-run `ensure` to
   recover; nothing is deleted.

3. **Run a shell on it** — the empty allowlist denies application
   connections; DNS queries to the bridge resolver are still
   allowed and can carry data out
   ([threat model](threat-model.md)). The proxy env comes in as
   one env file:

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

   <details>
   <summary>Expected output:</summary>
   you land at the container's shell prompt (in-container root — not
   the host account):

   <pre>
   egl-runner@host:~$ egresslock ensure dev \
    && podman run --rm -it --name probe \
        --cap-drop=all --security-opt=no-new-privileges \
        --network="$(egresslock network dev)" \
        --env-file="$(egresslock proxy-env dev --out)" \
        localhost/egl-base:latest \
        sh
   gateway 'egresslock-gateway-dev' ready (already converged, not restarted)
   profile 'dev' ready (network egresslock-dev, policy verified)
   root@9badc0ffee67:/#
   </pre>

   `--env-file="$(egresslock proxy-env dev --out)"` injects
   the profile's six proxy vars in one go (what they are and why
   there are six: [proxy-clients](proxy-clients.md)). The bare
   `--out` is the recommended form: it writes the env file mode 0600
   under your private runtime dir and prints its path. Use
   `--out=<path>` only as a backup when you need the file at a
   specific location; its directory must be writable only by your
   account (a group- or world-writable directory is refused),
   otherwise pass them to `podman run` with `--env KEY=value`.
   </details>

#### What you should have

Back on the host — exit the probe container first (`exit`; it was
`--rm`, it goes away):

```sh
# the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock list
```

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ egresslock list
using configs in /home/egl-runner/.config/egresslock (2 profiles)
NAME           NETWORK                SUBNET
dev            egresslock-dev          10.199.1.0/24
main           egresslock-main         10.199.0.0/24
</pre>
</details>

On disk — one conf + allowlist pair per profile:

```sh
# the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

ls ~/.config/egresslock/
```

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ ls ~/.config/egresslock/
dev-allowlist  dev.conf  main-allowlist  main.conf
</pre>
</details>

The profile is targetable: `egresslock network dev` and
`egresslock proxy-env dev` need no extra arguments. Grow its
allowlist with `egresslock allow dev <host[:port]>` (see
[allow-a-domain](../quickstart/allow-a-domain.md)).

### Delete a profile

There is no `egresslock remove` — teardown does the
runtime half; archiving the files is a filesystem step:

1. **As the account**, teardown the profile's runtime state (keeps
   other profiles):
   ```sh
   /opt/egresslock/egresslock teardown <name>
   ```
   This stops `egresslock-gateway-<name>` / `egresslock-anchor-<name>` and
   removes the `egresslock-<name>` network.
2. **Archive the files** (safer than rm — reversible):
   ```sh
   mkdir -p ~/.config/egresslock/.bak
   mv ~/.config/egresslock/<name>.conf ~/.config/egresslock/<name>-allowlist ~/.config/egresslock/.bak/
   mv ~/.config/egresslock/<name>.pins ~/.config/egresslock/.bak/ 2>/dev/null || true   # absent when the profile has no allow-host entries
   ```
3. **If `unit.env` had `EGRESSLOCK_PROFILE=<name>`**, re-run
   `egresslock-setup` without `--profile` (or with another name) to
   re-point the verify timer.
4. **Confirm nothing is left**: `list` on the remaining confs; no
   `egresslock-<name>` in `podman network ls`; no `egresslock-anchor-<name>` /
   `egresslock-gateway-<name>` in `podman ps -a`.

## The allowlist file

The `gateway` directive names the profile's allowlist file: exactly
`<profile>-allowlist`, the conf's co-located sibling. One `host[:port]`
per line, matched by
Squid `dstdomain`; entries without a port form the 443 group, `host:port`
entries get their own port group. This file is the PROXY path: read it
with `egresslock allowlist <profile>`, which renders the configured
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

A numeric-host (IP-literal) CONNECT/GET through the proxy is denied even
when a PTR of that IP equals an allowlisted name: the generated
`dstdomain` ACLs carry `-n` (no reverse-DNS adoption), so the name
contract is exactly the allowlist. Address pins stay on the direct path.

A changed allowlist is applied by restarting the gateway, so the
profile's proxied sessions drop briefly — including other containers'
sessions on the same profile network.

## Direct rules in detail

The direct path (`egresslock allow <profile> <host:port> --direct`)
compiles to a direct `ip daddr <ip> tcp dport <port> accept` rule
enforced independently of the HTTP gateway.

- **Inventory** — `egresslock allowlist <profile> --direct` lists the
  configured entries (one `host:port` per `rule allow-host` line, conf
  order), without resolving names and without reading the pin record;
  `egresslock allowlist-direct <profile>` is the shortcut. This is the
  configured-entry view, not a witness of what is installed. Both views
  share the header shape:
  `profile '<name>' — <N> <lane> entries from the <source> (<resolution>)`;
  a profile with no direct entries prints `0 direct entries` and no
  rows. To see the
  compiled accept rules, use `egresslock rules <profile>` (it
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
  is reachable — accepted risk T13. The replacements are the
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
  swap), then ends every revoked flow it can observe, and proves it — old
  DNS addresses, the peer-direction conntrack entry, and half-closed or
  still-starting flows — keeps connections another remaining rule still
  authorizes, and refuses with a named error instead of a bare `removed:`
  when it cannot prove severance. One accepted gap behind a green
  `removed:` (0.9.0): a packet accepted just before the swap but recorded
  in conntrack only after the check runs is invisible to the check — in
  that sub-second window one flow can still finish behind a green
  `removed:`.
  A `disallow --direct` that cannot prove severance
  fails loudly with the state disclosed, and it requires the `conntrack`
  tool. When the profile's installed firewall rules cannot be read, or
  no longer match its pin record (a tampered or drifted profile),
  `disallow --direct` refuses before anything changes (exit code 1, nothing
  removed): run `egresslock ensure <profile>`, then retry the command.
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
  rather than a per-request hostname, there is no access log (`denied`
  never sees direct-path traffic, and a denied direct connection is a
  hang, not a 403), and DNS drift is a verify warning until you re-run
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
| log / `denied` | Squid access.log | none |
| failure mode | 403 (visible in `denied`) | silent hang / timeout |

Non-HTTP denials therefore look like a **hang**, not a 403, and never
show up in `denied` (the gateway never saw the packet). Confirm a
direct allow with `rules` and a real client (e.g. `ssh -T
git@git.example.test`). This is a deliberate trade: Squid is the
HTTP(S) gateway; non-HTTP is *transparently* a direct nftables rule
(proxy-capable clients may instead tunnel a non-HTTP connection by
name through the gateway —
[Rotating names](rotating-names.md)).

### Combining with a gateway

- `gateway-only` profiles: egress goes through the Squid gateway
  (allowlist-controlled); the nftables chain only permits the gateway
  IP. Use the allowlist / `allow` to grow it.
- A direct rule in a gateway profile coexists with the gateway (direct
  destinations use the separate nftables-enforced path).

The same host:port may exist in both stores at once — the gateway
allowlist and a `rule allow-host` line. `disallow` removes from one
store only: without `--direct` it removes the allowlist entry; with
`--direct` it removes the firewall rule. Removing one does not
remove the other.
