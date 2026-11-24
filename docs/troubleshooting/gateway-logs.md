# Inspecting the gateway (Squid) logs

## Symptom

A workload hangs or 403s and you want to know what the gateway
actually saw — and what it did not.

## The logs

All as the account:

```sh
# The summary command (de-duplicated denied entries, most recent last):
/opt/egresslock/egresslock denied PROFILE

# Recent DIRECT-path TCP drops (IPv4:port; bounded record, entries expire):
/opt/egresslock/egresslock denied PROFILE --direct

# Raw access log — one line per request the gateway processed:
podman exec egresslock-gateway-PROFILE cat /var/log/squid/access.log

# Startup / config / DNS errors:
podman exec egresslock-gateway-PROFILE cat /var/log/squid/cache.log
```

## Reading `denied`

`denied <profile>` reports every `TCP_DENIED/403` the gateway saw —
both HTTPS `CONNECT` tunnels and plain-HTTP requests — as an
allow-grammar entry, de-duplicated, most recent last:

- `TCP_DENIED/403 ... CONNECT host:443` → printed as `host`
  (the no-port `:443` allowlist group).
- `TCP_DENIED/403 ... GET|HEAD|POST http://host/...` → printed as
  `host:80` — a plain-HTTP request, so the entry needs the explicit
  `:80` port. An explicit `:port` in the URL is preserved (`:443`
  collapses to bare `host`).

Denies Squid logged only after the client closed a `CONNECT` early
(`TCP_DENIED_ABORTED/403`) are listed the same way.

`denied PROFILE --direct` is the other lane: it reads the profile's
bounded nft drop-record set and prints one `IP:PORT` per line for IPv4
**TCP** destinations that hit the terminal direct-path drop. It is not
a hostname log and does not read Squid; `--all`/`--days` do not combine
with `--direct`, and a repeat drop refreshes an entry. What each view
covers — and what can make a short list misleading — is in the
per-lane limitations below.

By default `denied` omits entries the allowlist already covers **on
that same port**, so it shows only still-blocked destinations; `denied
<profile> --all` shows the proxy view without that allow-covered
filter (still parsed and de-duplicated — not the raw log). Both views
only look at the last **14 days** by default —
`denied <profile> --days 0` is the full log.

The per-lane limitations (`egresslock help denied` mirrors them):

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

The engine's own live-config check sends one request for the reserved
`egresslock-probe.invalid` name through the gateway. Its deny is logged
like any other 403, but `denied` omits that exact host (and only that
host) — a subdomain or a similarly spelled name still prints. Seeing
`egresslock-probe.invalid` in the raw access log is normal: it is not
workload traffic and needs no allowlist entry.

The read itself is byte-capped (`EGRESSLOCK_DENIED_MAX_BYTES`, default
32 MiB): when the log exceeds the cap, only the **newest** bytes are
read (a stderr note names the cap and the remedy; set
`EGRESSLOCK_DENIED_MAX_BYTES=0` for the full log). See
[denied-log-cap](denied-log-cap.md).

## Reading the raw access log

Native Squid fields: `ts elapsed client code bytes method url ...`

- `TCP_DENIED/403 ... GET http://host/...` — an **HTTP (port 80)**
  request denied; `denied` reports it as `host:80`.
- `TCP_DENIED/403 ... CONNECT host:443` — an **HTTPS** request denied;
  `denied` reports it as `host`.
- `TCP_DENIED_ABORTED/403 ...` — the same denial logged after the
  client closed the connection early; `denied` reports it too.
- `TCP_TUNNEL/200 ... CONNECT host:443` — an allowed HTTPS tunnel.

`GET` vs `CONNECT` matters: a plain-`GET` denial means the client used
plain HTTP (e.g. apt on port 80), so the no-port `:443` allowlist group
does NOT cover it — the entry needs `host:80` explicitly (and `denied`
already reports it that way).

A host **absent** from the access log means the packet never reached
the gateway — check the profile's nftables chain (scoped drop) or the
client's proxy env. Uppercase-only `HTTP_PROXY`/`HTTPS_PROXY` is a
silent culprit: apt, wget, git, and pip read the lowercase
`http_proxy`/`https_proxy` and will connect directly, then hang on the
nftables drop instead of failing fast at the gateway. See
[proxied-or-direct](proxied-or-direct.md) for the layer triage.

The field order above is Squid's built-in `squid` format: the gateway
config sets `access_log` with no explicit format, and `denied` parses
that same order. If an image rebuild or kit upgrade brings a Squid
whose default format differs, `denied` can stop recognizing new lines
while this raw log still shows them — enforcement is unaffected (the
request is still denied). A hand-edited gateway config is caught by
`verify`; a change to Squid's package default is not. After such an
upgrade, confirm one known denial in the raw log before treating an
empty `denied` view as no denials.

## Benign noise

The `cache.log` `pinger| FATAL: Unable to open any ICMP sockets` noise
at boot is benign — the gateway container runs with `--cap-drop=all`
(no ICMP), so Squid's pinger can never start; Squid serves fine.

## Links

- Back to the [symptom index](../troubleshooting.md).
- [proxied-or-direct](proxied-or-direct.md) — when the log is empty
  and clients still fail.
- [denied-log-cap](denied-log-cap.md) — the `denied` twin of this page.
