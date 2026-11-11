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
| my container can't reach a service on the host / localhost | same-host service — pasta hairpin (host-addressed traffic never leaves the netns) | [cannot-reach-host-service](troubleshooting/cannot-reach-host-service.md) |
| `denied` shows nothing but clients still 403 | stale engine or stale container env | [proxied-or-direct](troubleshooting/proxied-or-direct.md) |
| `denied` prints a "newest … bytes" note / misses older denials | the log-read cap keeps only the newest bytes of access.log | [denied-log-cap](troubleshooting/denied-log-cap.md) |
| `kill network process: permission denied` | pasta/AppArmor blocker — check whether this host needs the amendment first | [pasta-apparmor](troubleshooting/pasta-apparmor.md) |
| `invalid internal status ... podman system migrate` / degraded user session | session/pause-process tangle | [session-tangles](troubleshooting/session-tangles.md) |
| `verify: FAILED` / `drift:` lines in the timer journal | policy drift or DNS move | [verify-timer-signals](troubleshooting/verify-timer-signals.md) |
| `verify: anchor <name> not running` in the timer journal | the anchor container is gone (killed, rebooted, removed) — re-run `ensure <profile>` as the account | [verify-timer-signals](troubleshooting/verify-timer-signals.md) |
| `verify: policy chain '<chain>' does not match the expected ruleset` or `verify: shared v6-deny chain missing or does not match` in the timer journal | policy drift (often after an upgrade or a conf change) — heal with `ensure <profile>` as the account; verify never repairs | [verify-timer-signals](troubleshooting/verify-timer-signals.md) |
| `verify: unexpected chain '<name>'` in the timer journal | the firewall table holds a chain no profile config defines (often a profile deleted with `teardown` whose files were archived) — `ensure` of a remaining profile removes the leftover chain | [verify-timer-signals](troubleshooting/verify-timer-signals.md) |
| `verify: cannot read the egresslock firewall table` in the timer journal | the table could not be read — retry `verify` (per the line's own hint); do not re-ensure for this line alone | [verify-timer-signals](troubleshooting/verify-timer-signals.md) |
| `verify: unfinished revocation` in the timer journal | an interrupted `disallow --direct` left a pending revocation; the flow may still be up until the next `ensure` | [verify-timer-signals](troubleshooting/verify-timer-signals.md) |
| the doctor prints a `stale:` / `rebuild:` line about the gateway image | the deployed gateway image is older than the kit's security floor or older than 30 days — rebuild and replace | [The gateway image](reference/gateway-image.md) |
| `disallow --direct` refuses a drifted profile and the recommended `ensure` says `cannot resolve` | the revoked name no longer resolves — the automatic recovery cannot run | [revocation-name-gone](troubleshooting/revocation-name-gone.md) |
| weird policy/containers after running the engine as root | root run built policy in ROOT's store | [netns-inspection](troubleshooting/netns-inspection.md) |
| where are the gateway logs / what do they mean | Squid access.log + cache.log reading | [gateway-logs](troubleshooting/gateway-logs.md) |
| `pinger\| FATAL` noise in cache.log | benign (no ICMP in the gateway container) | [gateway-logs](troubleshooting/gateway-logs.md) |
| `unable to find network ... network not found` (podman) | the profile's network is not in this user's podman store — never ensured, torn down, or wrong user | [network-not-found](troubleshooting/network-not-found.md) |
| after a reboot, network looks fine but workloads are unprotected / verify says `network exists but policy does not` | the network object survives reboot without its volatile netns policy | [after-a-reboot](troubleshooting/after-a-reboot.md) |
| `torn conf pair` / `allowlist file missing` when the allowlist half is missing | the starter pair lost its allowlist half and is never auto-healed | [torn-conf-pair](troubleshooting/torn-conf-pair.md) |
| long request dies at exactly 15m00 | squid `read_timeout` — non-streaming origin idle, not a periodic breaker | [long-request-15m](troubleshooting/long-request-15m.md) |
| a command says `another egresslock command is running` | a concurrent command holds the account lock | [concurrent-commands](troubleshooting/concurrent-commands.md) |
| `No space left on device` / a lock, policy, pin-record, verify-temp, or conf write failure | the account home or `/tmp` is full — the named line says what changed and what did not | [disk-full](troubleshooting/disk-full.md) |

The failure-signature model behind the first three rows (two-path
model, env × destination matrix, counter proof):
[paths-and-signatures](reference/paths-and-signatures.md).
