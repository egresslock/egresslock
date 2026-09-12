# Inspecting the gateway (Squid) logs

## Symptom

A workload hangs or 403s and you want to know what the gateway
actually saw — and what it did not.

## The logs

All as the account:

```sh
# The summary command (de-duplicated denied entries, most recent last):
/opt/egresslock/egresslock denied <profile>

# Raw access log — one line per request the gateway processed:
podman exec egresslock-gateway-<profile> cat /var/log/squid/access.log

# Startup / config / DNS errors:
podman exec egresslock-gateway-<profile> cat /var/log/squid/cache.log
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

By default `denied` omits entries the allowlist already covers **on
that same port**, so it shows only still-blocked destinations; `denied
<profile> --all` prints the raw de-duplicated list. Both views only
look at the last **14 days** by default —
`denied <profile> --days 0` is the full log.

## Reading the raw access log

Native Squid fields: `ts elapsed client code bytes method url ...`

- `TCP_DENIED/403 ... GET http://host/...` — an **HTTP (port 80)**
  request denied; `denied` reports it as `host:80`.
- `TCP_DENIED/403 ... CONNECT host:443` — an **HTTPS** request denied;
  `denied` reports it as `host`.
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

## Benign noise

The `cache.log` `pinger| FATAL: Unable to open any ICMP sockets` noise
at boot is benign — the gateway container runs with `--cap-drop=all`
(no ICMP), so Squid's pinger can never start; Squid serves fine.
