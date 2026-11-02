# Container can't reach a service on the host (localhost fails)

## Symptom

From a container, connections to a service that runs on the HOST
itself fail:

| You try from the container | What happens |
|---|---|
| `curl http://127.0.0.1:8000` | that is the CONTAINER's own loopback — nothing listens there |
| `curl http://198.51.100.x:8000` (the host's LAN IP) | instant `Connection refused` (0 ms) — the host's own address is *local* to the netns; the policy never even sees the packet |

## Cause

pasta copies the host's addresses into the rootless netns, so
host-addressed connections never leave it (the pasta hairpin) — the
deep model (address copies, 0 ms refusal, the `/etc/hosts` dead end)
lives in
[paths-and-signatures](../reference/paths-and-signatures.md#the-pasta-hairpin--why-the-hosts-own-lan-ip-can-never-work).

## Fix

Two patterns, by protocol.

**HTTP(S) service — allow it proxied, by name:**

```sh
# TERMINAL 2 — the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock allow main host.containers.internal:8000
```

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ egresslock allow main host.containers.internal:8000
using config /home/egl-runner/.config/egresslock/main.conf
path: proxy — gateway allowlist /home/egl-runner/.config/egresslock/main-allowlist
added: host.containers.internal:8000 -> /home/egl-runner/.config/egresslock/main-allowlist
note: port 8000 is not the usual HTTP(S) port. If host.containers.internal:8000 is a non-HTTP service, add a direct rule as well (this does not remove the allowlist entry):
  egresslock allow main host.containers.internal:8000 --direct
re-ensuring profile 'main' ...
gateway 'egresslock-gateway-main' ready (allowlist applied, health verified)
profile 'main' ready (network egresslock-main, policy verified)
</pre>

`host.containers.internal` is a name podman injects into every
container's `/etc/hosts`; the gateway container resolves it and
reaches the host through pasta.
</details>

Test from the container:

```sh
# TERMINAL 1 — the workload container: podman exec -it <container-name> sh
# prompt: root@9badc0ffee67:/#

curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 http://host.containers.internal:8000
```

<details>
<summary>Expected output:</summary>

<pre>
root@9badc0ffee67:/# curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 http://host.containers.internal:8000
200
</pre>

or the service's own status code — the point is it answered.
</details>

**Non-HTTP service — allow it direct, by IP literal:**

```sh
# TERMINAL 2 — the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock allow main 169.254.1.2:8000 --direct
```

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ egresslock allow main 169.254.1.2:8000 --direct
using config /home/egl-runner/.config/egresslock/main.conf
path: direct — firewall rule in /home/egl-runner/.config/egresslock/main.conf (does not change client proxy settings)
added: rule allow-host 169.254.1.2:8000 -> /home/egl-runner/.config/egresslock/main.conf
note: IPv4 direct pins are included in proxy-env NO_PROXY; recreate running workloads to pick up the new env.
re-ensuring profile 'main' ...
gateway 'egresslock-gateway-main' ready (already converged, not restarted)
profile 'main' ready (network egresslock-main, policy verified)
</pre>

`169.254.1.2` is pasta's host address (podman map-guest-addr):
traffic to it is translated to the host's loopback, so the profile
policy governs it — the direct firewall path. The NAME cannot be
pinned (the direct path resolves on the host, where that name does not
exist) — only the literal works, and running workloads need a
recreate to pick up the NO_PROXY change.
</details>

Test from the container with the service's own client (a database
client, ssh, nc) against `169.254.1.2:8000`.

## Links

- The destination → mechanism decision table:
  [policy reference](../reference/policy-reference.md).
- Wrong pattern for the protocol — HTTP(S) → proxied-by-name; ssh,
  git-over-SSH, databases and other non-HTTP → direct-by-literal;
  the direct-path walkthrough:
  [allow-non-http](../quickstart/allow-non-http.md).
- Symptom-driven diagnosis: the
  [troubleshooting index](../troubleshooting.md) — instant refusal at
  0 ms is also the pasta-hairpin row in
  [proxied-or-direct](proxied-or-direct.md).
