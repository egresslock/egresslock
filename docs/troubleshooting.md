# egresslock troubleshooting

I'm facing X → here is what it means and where the fix lives. This
index is the ONLY entry point: every issue below links to one page
under `troubleshooting/` (symptom / cause / fix / links). For the
routine health check see
[first-run-checks](quickstart/first-run-checks.md) (brief) and
[check-everything](reference/check-everything.md) (full).

| I'm facing... | It means | Page |
|---|---|---|
| which doctor/check to run | four commands, four questions | [which-check](troubleshooting/which-check.md) |
| Squid 403 error page | proxy path — not allowlisted, or a proxied IP literal | [proxied-or-direct](troubleshooting/proxied-or-direct.md) |
| curl hangs, nothing in access.log | direct path, nft drop | [proxied-or-direct](troubleshooting/proxied-or-direct.md) |
| instant `Connection refused` (0 ms), counters dead | host-local service — pasta hairpin | [proxied-or-direct](troubleshooting/proxied-or-direct.md) |
| my container can't reach a service on the host / localhost | same-host service — pasta hairpin (host-addressed traffic never leaves the netns) | [paths-and-signatures](reference/paths-and-signatures.md) |
| `denied` shows nothing but clients still 403 | stale engine or stale container env | [proxied-or-direct](troubleshooting/proxied-or-direct.md) |
| `kill network process: permission denied` | pasta/AppArmor blocker | [pasta-apparmor](troubleshooting/pasta-apparmor.md) |
| `invalid internal status ... podman system migrate` / degraded user session | session/pause-process tangle | [session-tangles](troubleshooting/session-tangles.md) |
| `verify: FAILED` / `drift:` lines in the timer journal | policy drift or DNS move | [verify-timer-signals](troubleshooting/verify-timer-signals.md) |
| weird policy/containers after running the engine as root | root run built policy in ROOT's store | [netns-inspection](troubleshooting/netns-inspection.md) |
| where are the gateway logs / what do they mean | Squid access.log + cache.log reading | [gateway-logs](troubleshooting/gateway-logs.md) |
| `pinger| FATAL` noise in cache.log | benign (no ICMP in the gateway container) | [gateway-logs](troubleshooting/gateway-logs.md) |
| `unable to find network ... network not found` (podman) | the profile's network is not in this user's podman store — never ensured, torn down, or wrong user | [network-not-found](troubleshooting/network-not-found.md) |
| long request dies at exactly 15m00 | squid `read_timeout` — non-streaming origin idle, not a periodic breaker | [long-request-15m](troubleshooting/long-request-15m.md) |

The failure-signature model behind the first three rows (two-path
model, env × destination matrix, counter proof):
[paths-and-signatures](reference/paths-and-signatures.md).
