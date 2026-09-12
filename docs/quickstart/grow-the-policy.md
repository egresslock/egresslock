# How to: grow the policy

Two mechanisms control what a profile may reach. All are fail-closed:
anything not explicitly allowed is denied.

Run as the dedicated `<account>` (never root):

```sh
sudo -iu <account>
```

```sh
# HTTP(S) traffic — via the gateway allowlist (one or more entries, one re-ensure):
egresslock allow main example.com:443 another.example:443
# Non-HTTP egress (git-over-SSH, ssh, rsync...) — direct rule, bypasses the gateway:
egresslock allow-host main example.com:2222
```

## Which mechanism for which destination?

Short version: **HTTP(S) by domain → the allowlist; everything else →
`allow-host`.**

| Destination | Mechanism | How-to |
|---|---|---|
| HTTP(S) by domain | `allow` (gateway allowlist) | [allow-a-domain](allow-a-domain.md) |
| raw IPs, ssh/other non-HTTP, same-host non-HTTP | `allow-host` (direct rule) | [allow-non-http](allow-non-http.md) |
| HTTP(S) service on the SAME host | `allow` with `host.containers.internal` | [paths-and-signatures](../reference/paths-and-signatures.md) |

The full decision table — non-standard ports, same-host services,
CIDR and `public-only` status — lives in the
[policy reference](../reference/policy-reference.md). Why a request
behaves the way it does (proxy path vs direct path, failure
signatures): [paths-and-signatures](../reference/paths-and-signatures.md).

## See the current policy

```sh
egresslock rules main       # the nftables rules
egresslock allowlist main     # the gateway allowlist file
```

## (Optional) Remove rules

```sh
egresslock disallow <profile> <host[:port]>     # remove an allowlist entry
egresslock disallow-host <profile> <host:port>  # remove a direct rule
```

Each removes only the exact entry you name, then re-ensures.

## Next

- [Allow non-HTTP egress](allow-non-http.md) — the `allow-host`
  walkthrough (git-over-SSH example).
