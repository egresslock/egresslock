# Paths and signatures — why a request does what it does

This page answers: **"why did my request 403 / hang / get refused when
the destination is allowed?"** — the runtime model behind the
quickstart recipes ([allow-non-http](../quickstart/allow-non-http.md),
[allow-a-domain](../quickstart/allow-a-domain.md)).

## The two paths

A request from the workload takes ONE path, chosen by the proxy
environment baked in at container start:

- **Proxy path** (HTTP(S)_PROXY set, destination not in NO_PROXY):
  the only wire destination is the gateway's port — which the policy
  always allows. Squid decides, and Squid speaks **names** (dstdomain
  allowlist). Your nft allow-host rule is never consulted here.
- **Direct path** (destination in NO_PROXY, or the container has no
  proxy vars at all): a real socket to the destination. nft decides —
  this is the path `allow-host` guards.

| Workload env at container start | Domain destination | `allow-host` IP:port destination |
|---|---|---|
| proxy env injected (default recipe) | via Squid allowlist — works | **403 from Squid** unless the IP is in NO_PROXY |
| no proxy env (bare `podman run`) | **hang** on the nft drop | works (direct) |

Each row is the SAME policy state — only the workload env differs.

## The three failure signatures

| Signature | Layer | Meaning |
|---|---|---|
| Squid error page; `TCP_DENIED/403` in access.log; `denied <profile>` lists the destination | Squid (proxy path) | Reached the gateway, not allowlisted — or a proxied request to an IP literal (never allowlistable). |
| Hang, no error page, absent from access.log | nft (direct path) | Went direct with no direct allow — the profile's terminal drop, silently. |
| Instant `Connection refused` (0 ms), direct-pin counters stay 0 | netns itself | Destination is the HOST machine's own address — the pasta hairpin (below). The policy never sees the packet. |

`denied <profile>` lists IPv4 destinations too, but it only sees
traffic that REACHED the gateway. An IPv4 literal is not an allowlist
hostname: put it on the direct path (`allow main 192.0.2.24:11434
--direct`), or add it to `NO_PROXY` and recreate the workload. A host
absent from access.log was never proxied.

Not every failure is one of these three: a request cut at exactly 15m00
is the profile's `read-timeout`
([long-request-15m](../troubleshooting/long-request-15m.md)); a torn
conf pair is the missing allowlist half
([torn-conf-pair](../troubleshooting/torn-conf-pair.md)); a lock
timeout is
[concurrent-commands](../troubleshooting/concurrent-commands.md); a
full disk makes the atomic writes fail
([disk-full](../troubleshooting/disk-full.md)).

## The pasta hairpin — why the host's own LAN IP can never work

pasta copies the host's address into the shared rootless netns, so the
host's own LAN IP is *local* to the netns. A container connecting to
it never leaves the netns — the profile policy never sees the packet,
and the netns kernel refuses the connection (nothing listens there).
Confirm with `podman unshare --rootless-netns tcpdump -ni any host
IP`: silence. The gateway-address trick (`198.51.100.1`) does NOT
work either — the gateway address is not a host alias on current
podman/pasta.

Same-host services therefore use one of:

- **HTTP/HTTPS, proxied by name**:
  `allow <profile> host.containers.internal:<port>` — podman injects
  that name into every container's `/etc/hosts` (it maps to pasta's
  host-loopback address); Squid's dstdomain matches it, and the
  GATEWAY container resolves it and reaches the host through pasta.
  The gateway's egress exemption (`ip saddr <GW_IP> iifname
  "<bridge>" ether saddr <GW_MAC> accept`, the MAC kit-derived and
  pinned) covers the upstream leg. The standard `denied`/`allow` loop
  applies.
- **Non-HTTP, direct by IP literal**:
  `allow <profile> 169.254.1.2:<port> --direct` — `169.254.1.2` is
  podman's pasta map-guest-addr address; traffic to it is translated
  to the host's loopback (verify inside any container: `getent hosts
  host.containers.internal`). The packet IS forwarded, so the profile
  policy governs it, and the literal lands in NO_PROXY automatically.
  The NAME cannot be pinned: the direct path resolves on the
  host, where this name does not exist — ensure fails closed.
- Run the service itself as a container on the profile network —
  same-bridge traffic reaches it directly (this is how the Squid
  gateway is reached).

## Why an /etc/hosts entry does not fix the proxied 403

A tempting workaround — map the LAN IP to a name in the WORKLOAD's
`/etc/hosts` (`podman run --add-host ollama.lan:192.0.2.24`) and
request `http://ollama.lan:11434` — does not rescue the proxied 403:

- Name not in the allowlist → still `TCP_DENIED/403`.
- `allow main ollama.lan:11434` → the dstdomain ACL matches the name,
  but Squid must then open the upstream connection and resolves the
  name in the GATEWAY container's DNS context — the workload's hosts
  file never reaches Squid. Unless site DNS actually serves the name
  (in which case /etc/hosts is unnecessary: just
  `allow main <dns-name>:port`), the proxied request fails at gateway
  DNS resolution instead of the 403.
- The hosts-file trick does not create a bypass: `NO_PROXY` is derived
  and carries no hostname, and the proxied request still fails as
  above — the fix stays the direct-path IP literal (above), whose pin
  lands in `NO_PROXY` automatically.

## Listing recent direct-path drops

The direct path's first-line record is the profile's bounded nft set,
readable as the account without host privileges:

```sh
egresslock denied main --direct
```

It prints one `IP:PORT` per line (sorted) for IPv4 **TCP** destinations
that hit the profile's terminal drop, so the lines paste into
`egresslock allow main IP:PORT --direct`; a repeat drop refreshes an
entry. Every successful `denied` view prints one shared stderr caveat
before the entries: the view covers one lane and a short or empty list
is not proof that nothing was denied. `--all`/`--days` apply to the
gateway log only; the record's bounds and its full-record behavior are
in the `--direct` limitations below. Empty stdout with the shared
caveat and the empty-record sentence on stderr means the set is empty
or its entries expired.

Limitations of the two views (`egresslock help denied` is the canonical
list):

Gateway (proxy) view:
- Squid access log only; no direct-lane entries.
- Parsed and de-duplicated `TCP_DENIED/403` destinations.
- Default 14-day window; allow-covered entries omitted unless `--all`.
- 32 MiB tail-biased read cap (`EGRESSLOCK_DENIED_MAX_BYTES`).
- A stopped gateway or rotated log can look like no denials.
- IPv4 literals are not allowlist hostnames: use
  `egresslock allow PROFILE IP:PORT --direct`, or add the IP to
  `NO_PROXY` (`proxy-env` includes direct IPv4 pins; recreate the
  workload).

`--direct` view:
- Terminal direct-path drops only, IPv4 TCP `IP:PORT`.
- Other protocols are not permitted for workload egress (DNS `:53` to
  the bridge gateway excepted), so UDP/ICMP to other destinations are
  dropped, not merely unlisted.
- No gateway/proxy, anti-spoof, IPv6, or pre-terminal drops.
- Bounded to 16384 entries with a 24h idle expiry.
- Later denials are not recorded once the record is full.
- A short or empty list is not proof nothing was denied.

To inspect the raw set (for example to see expiry times), use the
resolved nft path in the rootless netns (stock PATH may lack it):

```sh
podman unshare --rootless-netns /usr/sbin/nft list set inet egresslock d_main
```

The set name is `d_` followed by the profile name with hyphens replaced
by underscores (same mangling as the `p_` chain).

## Proving a drop with the counter

Run as the container-owner account on the host. Counters are in
the live netns ruleset, not `egresslock rules` output. For `main`:

```sh
# account — enter its host shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

podman unshare --rootless-netns nft list chain inet egresslock p_main
```

Find the subnet-scoped rule ending in `counter packets N bytes M
drop`. Read its packet count, run the direct probe, and read it
again. An increase shows that packets hit that drop rule; an
increase on an `accept` rule shows acceptance, not a drop.

The drop counter covers the profile subnet, not one destination
or container. Other traffic can increment it too: stop unrelated
workload traffic before attributing an increase to your probe.
A timeout or an unchanged counter alone does not prove that the
intended traffic was blocked by this rule. A failed ruleset read
is an inspection failure, not evidence of enforcement.

Do not edit rules or reset counters for this check. For a profile
other than `main`, use its chain name: `p_` followed by the profile
name with hyphens replaced by underscores.

## Scope notes

- Every profile has a gateway (the directive is required), so the proxy
  path exists for every profile — the 403 row of the matrix can arise on
  any of them, and direct pins are additional to it.
- IPv4-literal pins never emit `drift:` (there is no DNS to move);
  hostname pins do on a set change (T13) — re-run `ensure` on a
  `drift:` warning.
- Rule order is safe by construction: allow-host accepts compile
  before the terminal drop.
