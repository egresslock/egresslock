# Proxied or direct? (403 vs hang vs instant refusal)

## Symptom

A destination is allowed (or you believe it is) but the client fails —
with a 403, a hang, or an instant refusal. Which layer answers tells
you where the request went. Workload env is baked at container start;
policy state is live.

## The three signatures

| Signature | Layer | Meaning |
|---|---|---|
| Squid error page; `TCP_DENIED/403` in access.log; `denied <profile>` lists it | Squid (proxy path) | Reached the gateway, not allowlisted — or a proxied request to an IP literal (never allowlistable). |
| Hang, no error page, absent from access.log | nft (direct path) | Went direct with no direct allow — the profile's terminal drop, silently. |
| Instant `Connection refused` (0 ms), allow-host counters stay 0 | netns itself | Destination is the HOST machine's own address (pasta hairpin — the netns owns a copy of it; the packet is never forwarded). |

## Fix / quickcheck

An `allow-host` IP that 403s means the client took the proxy path:

```sh
egresslock proxy-env <profile> noproxy   # allow-host IPv4 pins are unioned in
```

If the IP is listed, **recreate** the container (env is baked at
start) and the direct path takes over. Full recipes:
[allow-non-http](../quickstart/allow-non-http.md). The deep model — two-path
matrix, same-host patterns, the /etc/hosts dead end, counter proof:
[paths-and-signatures](../reference/paths-and-signatures.md). Tools
that hang because they ignore proxy env entirely:
[proxy-clients](../reference/proxy-clients.md). If `denied` shows
nothing but clients 403: check the engine actually running is recent
enough to union allow-host IPv4 pins (`egresslock --version`; older
engines silently omitted IPv4
from `denied`), and see [gateway-logs](gateway-logs.md).
