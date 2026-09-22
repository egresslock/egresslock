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
| Squid error page; `TCP_DENIED/403` in access.log; `denied <profile>` lists the destination (with a one-time stderr note for IPv4) | Squid (proxy path) | Reached the gateway, not allowlisted — or a proxied request to an IP literal (never allowlistable). |
| Hang, no error page, absent from access.log | nft (direct path) | Went direct with no direct allow — the profile's terminal drop, silently. |
| Instant `Connection refused` (0 ms), allow-host counters stay 0 | netns itself | Destination is the HOST machine's own address — the pasta hairpin (below). The policy never sees the packet. |

`denied <profile>` lists IPv4 destinations and prints a one-time hint
that they belong on allow-host, not allow — but it only sees traffic
that REACHED the gateway. A host absent from access.log was never
proxied.

## The pasta hairpin — why the host's own LAN IP can never work

pasta copies the host's address into the shared rootless netns, so the
host's own LAN IP is *local* to the netns. A container connecting to
it never leaves the netns — the profile policy never sees the packet,
and the netns kernel refuses the connection (nothing listens there).
Confirm with `podman unshare --rootless-netns tcpdump -ni any host
<ip>`: silence. The gateway-address trick (`192.168.0.1`) does NOT
work either — the gateway address is not a host alias on current
podman/pasta.

Same-host services therefore use one of:

- **HTTP/HTTPS, proxied by name**:
  `allow <profile> host.containers.internal:<port>` — podman injects
  that name into every container's `/etc/hosts` (it maps to pasta's
  host-loopback address); Squid's dstdomain matches it, and the
  GATEWAY container resolves it and reaches the host through pasta.
  The gateway's egress exemption (`ip saddr <GW_IP> ether saddr
  <GW_MAC> accept`, the MAC kit-derived and pinned) covers the
  upstream leg. The standard `denied`/`allow` loop applies.
- **Non-HTTP, direct by IP literal**:
  `allow-host <profile> 169.254.1.2:<port>` — `169.254.1.2` is
  podman's pasta map-guest-addr address; traffic to it is translated
  to the host's loopback (verify inside any container: `getent hosts
  host.containers.internal`). The packet IS forwarded, so the profile
  policy governs it, and the literal lands in NO_PROXY automatically.
  The NAME cannot be pinned: allow-host resolves on the
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
- The hosts-file trick only helps as naming on the DIRECT path (name
  in NO_PROXY + an allow-host pin to the IP) — cosmetic.

## Proving a drop with the counter

The nft chains log nothing; counters are the only trace — and they
are visible in the LIVE netns ruleset, not `rules` output:

```sh
podman unshare --rootless-netns nft list ruleset | grep 'daddr 192.0.2.24'
#     ... counter packets N bytes M accept
```

Repro the hang, re-read: an incrementing counter = confirmed drop.
Do not hand-edit the chain to add log rules — `verify` treats chain
edits as tamper and the next `ensure` rebuilds the chain; run
`ensure main` after any experiment to restore.

## Scope notes

- Non-gateway profiles have no proxy path at all — the 403 row of the
  matrix cannot arise there; everything is direct.
- IPv4-literal pins never emit `drift:` (there is no DNS to move);
  hostname pins do (T13) — re-run `ensure` on a `drift:` warning.
- Rule order is safe by construction: allow-host accepts compile
  before the terminal drop, and a gateway profile has no RFC1918
  scoped drops (those exist only for `public-only`).
