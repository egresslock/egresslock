# How to: test your container (is the policy doing what I expect?)

A five-minute sanity pass that proves the policy allows and blocks
exactly what you configured. Run it after setting up a profile, after
growing the policy, or any time something "feels wrong".

**Get into the container first** (as the account, on the profile
network, proxy wired in — full recipes:
[allow-a-domain](allow-a-domain.md) step 1 or
[create-a-profile](create-a-profile.md) step 4):

```sh
podman run --rm -it \
    --network="$(egresslock network main)" \
    --env-file=<(egresslock proxy-env main) \
    docker.io/curlimages/curl:latest sh
```

All the checks below run INSIDE that shell. The examples assume
profile `main` and one allowlisted domain (`example.com`) — substitute
yours.

## The checks

```sh
# 1. ALLOWED domain -> 200 (via the proxy)
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 https://example.com
# expect: 200

# 2. NOT-allowed domain -> fast 403 from Squid (proxy path denies)
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 https://blocked.example.test
# expect: 403  (curl: (7) CONNECT tunnel failed if you drop -w)

# 3. NOT-allowed direct IP -> silent drop (hang until the timeout)
curl -sS -o /dev/null --max-time 5 http://192.0.2.1:8000
# expect: curl error 28 (timed out) -- NO error page: the nft drop,
# not Squid, refused this

# 4. The gateway saw #2 (and only #2 -- #3 never reached it)
```

For #4, run as the account (not in the container):

```sh
egresslock denied main           # lists still-blocked destinations (expect #2)
podman exec egresslock-gateway-main tail -5 /var/log/squid/access.log
# expect: a TCP_DENIED/403 line for #2; NOTHING for #3
```

Reading the results:

| Check | Good | If wrong |
|---|---|---|
| 1 allowed -> 200 | proxy path works | 403? the allow didn't land — `egresslock allowlist main`, re-run `ensure` |
| 2 blocked -> 403 | fail-closed at the proxy | 200? something is allowlisted that shouldn't be — `egresslock disallow` |
| 3 blocked IP -> timeout | direct path fail-closed | instant refusal? that signature means something else entirely — [proxied-or-direct](../troubleshooting/proxied-or-direct.md) |
| 4 denied list matches | the detect-and-allow loop has data | empty? stale engine/env — [proxied-or-direct](../troubleshooting/proxied-or-direct.md) |

The full signature model (why each check fails the way it does):
[paths-and-signatures](../reference/paths-and-signatures.md).

## Next

Pick a [recipe](../../README.md#recipes) for your use case, or
[run your real workload](../../README.md#setup).
