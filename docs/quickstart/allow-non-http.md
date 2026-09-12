# How to: allow non-HTTP egress (git-over-SSH example)

`allow-host` is the direct-path mechanism: it works for anything the
HTTP gateway cannot proxy — ssh, git-over-SSH, rsync, databases — and
for raw IP addresses. HTTP(S) by domain uses the
[allowlist](allow-a-domain.md) instead. For the WHY (two-path model,
failure signatures, the pasta hairpin), see
[paths-and-signatures](../reference/paths-and-signatures.md).

Run as the dedicated account (`sudo -iu <account>` — see
[who-runs-what](../reference/who-runs-what.md)); ensure the profile first
(`egresslock ensure main`). Profile name is `main` in the examples —
use your profile's name. Grammar:
`allow-host <profile> <host:port>` (hostname or IPv4 literal; IP
literals are deliberately rejected by `allow`; CIDR ranges
are not yet supported).

## The loop — worked example: git over SSH

1. **Try it from the workload.** Start a container on the profile
   network ([allow-a-domain](allow-a-domain.md) step 1 or
   [create-a-profile](create-a-profile.md) step 4), then inside it:
   ```sh
   ssh -o ConnectTimeout=5 -T git@github.com
   ```
   Expect a **timeout/hang** — a direct connection with no direct
   allow is silently dropped. That hang (not a 403 error page) is the
   signature of a missing `allow-host` rule. (A 403 instead? The
   request went through the proxy — see
   [proxied-or-direct](../troubleshooting/proxied-or-direct.md).)

2. **Confirm it was the drop** — back in the account shell, the nft
   chains log nothing, but the counters are the trace (live netns
   ruleset):
   ```sh
   podman unshare --rootless-netns nft list ruleset | grep 'counter drop'
   ```
   Repro step 1 once, re-read: the terminal drop's counter
   incremented = confirmed. Expect the last line to grow:
   ```sh
   ip saddr 10.199.0.0/24 counter packets 3 bytes 180 drop
   #                                ^ was 2 before the repro
   ```

3. **Allow it** (direct rule; `github.com` resolves at ensure time
   and pins its current IP — or use an IPv4 literal):
   ```sh
   egresslock allow-host main github.com:22
   ```

4. **(Informational) Check the env the engine will inject** — no
   action needed for ssh (it ignores proxy env entirely), but this is
   what workload HTTP clients will see:
   ```sh
   egresslock proxy-env main noproxy
   ```

5. **Recreate the workload container** — proxy env is baked at
   container start (six-var recipe: [allow-a-domain](allow-a-domain.md)).

6. **Confirm**:
   ```sh
   ssh -o ConnectTimeout=5 -T git@github.com
   ```
   Works → done (GitHub greets you and closes the unauthenticated
   session — that IS success). Still hangs →
   [paths-and-signatures](../reference/paths-and-signatures.md)
   (counter proof, tamper warning, scope notes).

## Raw-IP variant

The same command with an IPv4 literal instead of a hostname — e.g.
`egresslock allow-host main 192.0.2.24:11434` for a LAN Ollama.
One difference matters for HTTP clients: `proxy-env` unions IP
**literals** into NO_PROXY automatically (hostname pins are not
unioned) — check with `egresslock proxy-env main noproxy`, and
**recreate** the container after any pin change.

## A service on the SAME host

The host's own LAN IP can never work from a container (pasta
hairpin) — that case has its own patterns (proxied
`host.containers.internal`, direct `169.254.1.2`), documented in
[paths-and-signatures](../reference/paths-and-signatures.md).

## Next

- [First-run checks](first-run-checks.md) — the post-setup sanity pass.
