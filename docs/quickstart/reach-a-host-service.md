# How to: reach a service on the host (localhost) from a container

Your container needs a service that runs on the HOST itself — the
"localhost" case. Two supported patterns cover it; both take under a
minute. First, why the obvious attempts fail — this is the most common
same-host trap:

| You try from the container | What happens |
|---|---|
| `curl http://127.0.0.1:8000` | that is the CONTAINER's own loopback — nothing listens there |
| `curl http://<the host's LAN IP>:8000` | instant `Connection refused` at 0 ms — the host's own address is *local* to the netns (pasta hairpin); the policy never even sees the packet |

The why (pasta copies the host's address into the netns, so
host-addressed connections never leave it) lives in
[paths-and-signatures](../reference/paths-and-signatures.md#the-pasta-hairpin--why-the-hosts-own-lan-ip-can-never-work).

## Pattern 1 — HTTP(S) service: allow it proxied, by name

```sh
egresslock allow main host.containers.internal:8000
```

`host.containers.internal` is a name podman injects into every
container's `/etc/hosts`. The allowlist speaks names, the GATEWAY
container resolves this one and reaches the host through pasta; the
standard [allow → confirm loop](allow-a-domain.md) applies. Test from
the container:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 http://host.containers.internal:8000
# expect: 200 (or the service's own status code)
```

## Pattern 2 — non-HTTP service: allow it direct, by IP literal

```sh
egresslock allow-host main 169.254.1.2:8000
```

`169.254.1.2` is pasta's host address (podman map-guest-addr): traffic
to it is translated to the host's loopback and IS forwarded, so the
profile policy governs it — the `allow-host` direct path, where the
literal lands in NO_PROXY automatically. The NAME cannot be pinned
(allow-host resolves on the host, where that name does not exist):
only the literal works, and you must **recreate** the workload after
the pin change. Full walkthrough: [allow-non-http](allow-non-http.md).

## If it still fails

- Wrong pattern for the protocol — HTTP(S) → pattern 1; ssh, git-over-SSH,
  databases and other non-HTTP → pattern 2.
- Symptoms (403 vs hang vs instant refusal) and the failure
  signatures: [paths-and-signatures](../reference/paths-and-signatures.md).
- Symptom-driven diagnosis: the
  [troubleshooting index](../troubleshooting.md) — instant refusal at
  0 ms is the pasta-hairpin row.
