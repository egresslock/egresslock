# Policy reference

The profile-conf grammar, the allowlist format, and the fail-closed
rules that govern them. This page answers: **"what can I configure,
and which mechanism allows which destination?"** For the practical
"how do I allow X" walkthroughs see
[grow-the-policy](../quickstart/grow-the-policy.md).

**On this page:** [Destination → mechanism decision table](#destination--mechanism-decision-table) ·
[Profile conf](#profile-conf) · [`rule public-only` in detail](#rule-public-only-in-detail) ·
[Concepts](#concepts) · [Runtime and verification](#runtime-and-verification) ·
[Account ownership](#account-ownership) · [File names (the convention)](#file-names-the-convention) ·
[Rules to keep straight](#rules-to-keep-straight) · [Profile lifecycle](#profile-lifecycle) ·
[The allowlist file](#the-allowlist-file) · [`allow-host` in detail](#allow-host-in-detail)

## Destination → mechanism decision table

| If the destination is... | Use | Command | Special considerations |
|---|---|---|---|
| domain, HTTP(S), standard port | Squid allowlist | `allow main example.com` (bare = 443 group) | Squid resolves at request time — no pin drift; apt/wget/git/pip read only the LOWERCASE proxy vars |
| domain, HTTP(S), non-standard port | Squid allowlist, explicit port | `allow main example.com:8443` | becomes its own per-port dstdomain group; a plain-HTTP GET denial needs an explicit `:80` entry (a bare 443 entry does NOT cover port 80) |
| domain, non-HTTP protocol (ssh, git-over-SSH, rsync) | nft allow-host (direct) | `allow-host main git.example.test:2222` | bypasses the gateway; ssh ignores HTTP(S)_PROXY so no no-proxy needed; DNS pin drift until next `ensure` (T13) |
| IPv4 literal, any port/protocol | nft allow-host (direct) | `allow-host main 192.0.2.24:11434` | literals are REJECTED by `allow`; never drifts; `proxy-env` unions the pin into NO_PROXY — check `proxy-env main noproxy`, and **recreate** the workload; see [allow-non-http](../quickstart/allow-non-http.md) |
| HTTP(S) service on the SAME host | Squid allowlist | `allow main host.containers.internal:8000` | proxied; the gateway resolves the podman-injected name; the host's LAN IP itself can never work (pasta hairpin — [paths-and-signatures](paths-and-signatures.md)) |
| non-HTTP service on the SAME host | nft allow-host, IP literal | `allow-host main 169.254.1.2:8000` | `169.254.1.2` is pasta's host address (podman map-guest-addr); the NAME cannot be pinned — [paths-and-signatures](paths-and-signatures.md) |
| domain that must NOT go through the proxy | nft allow-host + `no-proxy` | `allow-host` + `no-proxy <host>` in the conf | for gateway profiles whose clients honor proxy env |
| IP/CIDR range | not yet supported | — | (planned: conf rule, nft-only — dstdomain cannot express CIDRs) |
| all public IPv4 | `rule public-only` | conf | still drops RFC1918/link-local/etc.; CGNAT/bogon gap remains |

## Profile conf

Each profile is a `<profile>.conf` + `<profile>-allowlist` pair under
`~/.config/egresslock/` (see
[Create a profile](../quickstart/create-a-profile.md)). `#`
comments and blank lines are ignored; any unparseable or contradictory
content fails closed with exit 2. Host fields may use `${VAR}` /
`${VAR:-default}` (parsed manually, never eval'd).

| Directive | Meaning |
|---|---|
| `profile <name> <cidr>` | starts a profile block; IPv4 CIDR, prefixlen 8-29, canonical network address |
| `rule allow-host <host>:<port>` | direct host:port allow (repeatable; resolved at ensure time) |
| `rule public-only` | accept all public IPv4 (cannot combine with allow-host/gateway) |
| `rule gateway-only` | egress only through the profile's gateway (requires a `gateway` directive) |
| `gateway <ip> <port> <file>` | static gateway IP inside the subnet + Squid port + allowlist file (conf-relative unless absolute) |
| `no-proxy <host,...>` | extra NO_PROXY entries (hosts the profile may reach directly) |

## `rule public-only` in detail

`rule public-only` accepts all public IPv4 egress while still dropping
RFC1918 (private), link-local, multicast, and broadcast. The emitted
drop set is exactly `10/8`, `172.16/12`, `192.168/16`, `169.254/16`,
`224/4`, and `255.255.255.255` — other special-use ranges are **not**
dropped: loopback (`127/8`), CGNAT (`100.64/10`), `0/8`, benchmark
(`198.18/15`), reserved (`240/4`). It
cannot be combined with `allow-host` or a gateway — the engine rejects
the contradiction with exit 2.

```
# in main.conf
profile public 10.199.5.0/24
    rule public-only
```

To remove: delete the rule line from the conf, then `ensure <profile>`.

## Concepts

| Concept | What it is | Per profile? |
|---|---|---|
| profile | a class in a config file: subnet + rules (+ optional gateway) | one conf block |
| conf file | the declarative config; one profile per file recommended | one file per profile: `~/.config/egresslock/<name>.conf` |
| allowlist file | the gateway's allowed destinations (`dstdomain`) | one per gateway profile |
| Podman network | `egresslock-<profile>` | created by `ensure` |
| anchor | `egresslock-anchor-<profile>` keeps the netns/policy alive | created by `ensure` |
| gateway | `egresslock-gateway-<profile>` Squid container (gateway profiles); explicit direct-access rules use a separate path | created by `ensure` |
| verify | compares the live nftables policy with the expected profile rules | run per profile or by the verify timer |

## Runtime and verification

`ensure <profile>` creates or validates the profile network, starts the
anchor, starts or refreshes the gateway when configured, installs the
nftables policy, and verifies the result before a workload should start. The
anchor keeps the account's rootless network namespace and policy alive between
workloads.

`verify <profile>` compares the live nftables chain with the rules expected
from the profile. Structural drift or a missing healthy runtime fails
verification. DNS drift for direct `allow-host` pins is a signal only:
`verify` warns and does not re-pin the address; re-run `ensure` to resolve and
install fresh pins. The systemd verify timer repeats this check for the
account.

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
directive's file argument is that allowlist (conf-relative), so the
pair must stay siblings with the same base name. Do **not** invent
`*-profile.conf` names — the `<profile>.conf` + `<profile>-allowlist`
pairing is the convention. (The gateway container's runtime
file `/etc/squid/agent/allowlist.conf` is a generated engine-side
artifact inside the container, not one of these profile pairs —
different directory, never user-edited.)

A conf file can also hold several `profile` blocks, but separate files
are clearer (each `ensure <profile>` targets one conf).

## Rules to keep straight

- **Subnets must not collide** — the engine rejects overlaps.
  Pick a distinct range per profile.
- **Gateway IP must be inside the subnet's usable range**: not the
  network address, not the bridge gateway (first usable = `.1`), not
  the anchor (last usable). `.2` is valid for a `/24`.
- **Each gateway profile needs its own allowlist file** (referenced
  from its `gateway` directive).
- **Run every command as the account** (`sudo -iu <account>`), never
  root.

## Profile lifecycle

- `verify <profile>` checks one profile; `verify --ensured` checks
  every profile with a live anchor (bare `verify --ensured` also
  scans the default folder).
- `teardown <profile>` stops the anchor (and gateway) and removes the
  network; `teardown all` does every profile in the **explicit** conf —
  bare `teardown all` only ever touches `main.conf`, never sibling
  confs.
- `teardown --runtime` is the no-conf recovery sweep: it
  name-scans this store for kit containers and networks of the
  **current** naming generation (`egresslock-*`) only and removes
  them — for leftovers whose conf is already gone. Pre-rename
  `agent-*` kit objects are NOT swept; remove any by hand
  (`podman rm -f` / `podman network rm` — see
  `docs/setup/uninstall.md`). `all` stays main.conf /
  explicit-conf only.

### Delete a profile

There is no `egresslock remove` — teardown does the
runtime half; archiving the files is a filesystem step:

1. **As the account**, teardown the profile's runtime state (keeps
   other profiles):
   ```sh
   /opt/egresslock/egresslock --config ~/.config/egresslock/<name>.conf teardown <name>
   ```
   This stops `egresslock-gateway-<name>` / `egresslock-anchor-<name>` and
   removes the `egresslock-<name>` network.
2. **Archive the files** (safer than rm — reversible):
   ```sh
   mkdir -p ~/.config/egresslock/.bak
   mv ~/.config/egresslock/<name>.conf ~/.config/egresslock/<name>-allowlist ~/.config/egresslock/.bak/
   ```
3. **If `unit.env` had `EGRESSLOCK_PROFILE=<name>`**, re-run
   `egresslock-setup` without `--profile` (or with another name) to
   re-point the verify timer.
4. **Confirm nothing is left**: `list` on the remaining confs; no
   `egresslock-<name>` in `podman network ls`; no `egresslock-anchor-<name>` /
   `egresslock-gateway-<name>` in `podman ps -a`.

## The allowlist file

The `gateway` directive names the profile's allowlist file
(conf-relative unless absolute). One `host[:port]` per line, matched by
Squid `dstdomain`; entries without a port form the 443 group, `host:port`
entries get their own port group. Entries are **hostnames only** — a
literal IPv4 is rejected by `allow`/`disallow` and fails `ensure` closed
(use `allow-host` for address pins). Missing or invalid allowlists fail
`ensure` closed.

## `allow-host` in detail

`allow-host` compiles to a direct `ip daddr <ip> tcp dport <port>
accept` rule enforced independently of the HTTP gateway.

- **Hostname or IPv4 literal** — `allow-host` accepts a hostname or a
  literal IPv4 address (`host:port` always required). CIDR ranges are
  not accepted here (a whole-subnet allow is not expressible yet).
- **DNS drift** — the rule pins the host's first A record at `ensure`
  time. A later DNS change does NOT update it; the 15-minute verify
  timer only **warns** (`drift: host ... policy pins ...`), it never
  re-pins. Re-run `ensure` to refresh. Stale DNS looks like a hang to
  the new IP while the old IP still works.
- **`public-only` conflict** — a `public-only` profile cannot take
  `allow-host` (contradictory; exit 2).
- **What "direct" changes (and what it does not)** — an allow-host rule
  bypasses the Squid gateway but does NOT widen egress: the terminal
  scoped drop still applies and fail-closed is unchanged. What moves is
  the enforcement point and its visibility: identity is the pinned IP
  rather than a per-request hostname, there is no access log (`denied`
  never sees direct-path traffic, and a denied direct connection is a
  hang, not a 403), and DNS drift is a verify warning until you re-run
  `ensure`. It exists because it is the only way to allow non-HTTP
  egress (e.g. git-over-SSH), which the HTTP(S) gateway cannot proxy —
  everything else should pass the gateway's allowlist or a
  `public-only` rule. The failure signatures:
  [paths-and-signatures](paths-and-signatures.md).

### HTTP vs non-HTTP: gateway vs direct

| | gateway allowlist | `allow-host` |
|---|---|---|
| protocols | HTTP(S) CONNECT via Squid | any TCP port the rule names |
| identity | hostname at request time | first-A IP pinned at `ensure` |
| log / `denied` | Squid access.log | none |
| failure mode | 403 (visible in `denied`) | silent hang / timeout |

Non-HTTP denials therefore look like a **hang**, not a 403, and never
show up in `denied` (the gateway never saw the packet). Confirm a
direct allow with `rules` and a real client (e.g. `ssh -T
git@<forgejo-host>`). This is a deliberate trade: Squid is the
HTTP(S) gateway; non-HTTP stays a direct nftables rule.

### Combining with a gateway

- `gateway-only` profiles: egress goes through the Squid gateway
  (allowlist-controlled); the nftables chain only permits the gateway
  IP. Use the allowlist / `allow` to grow it.
- `allow-host` in a gateway profile coexists with the gateway (direct
  destinations use the separate nftables-enforced path).
