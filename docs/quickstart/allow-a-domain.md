# How to: allow a domain (and see what's blocked)

The loop: probe the deny-all policy → see what's blocked → allow a
domain → confirm.

Run every command **as the account** (`sudo -iu <account>`), not root.
In that shell `~` is the account's home and `podman` is the account's
rootless Podman.

Before you start, make sure the profile is up:
`egresslock ensure main` (see
[check-everything](../reference/check-everything.md) for the full health check).

## 1. Probe the deny-all policy — expect a denied CONNECT

Run as the dedicated `<account>`:

```sh
sudo -iu <account>
```

The starter allowlist is **EMPTY** (fail-closed), so the gateway denies
everything. Probe with an image that HAS a client tool:
`docker.io/curlimages/curl:latest` is the smallest (curl only;
`debian:13-slim` has no curl/wget/ping). The `docker.io/` prefix is
required on hosts with no unqualified-search registries.

```sh
# Workload with the empty starter allowlist — the gateway denies everything.
# Proxy env comes in as one env file (the profile's six vars, no hardcoded
# addresses). `2>&1` merges curl's stderr into stdout so the error and
# code print in order.
podman run --rm \
    --network="$(egresslock network main)" \
    --env-file=<(egresslock proxy-env main) \
    docker.io/curlimages/curl:latest \
    sh -c 'curl --max-time 10 -sS -o /dev/null -w "http_code=%{http_code}\n" https://example.com 2>&1'
```

Denied, expect:

> curl: (7) CONNECT tunnel failed, response 403
> http_code=000

That `000` is the deny-all policy working (no HTTP response — the
gateway rejected the CONNECT). Already seeing `http_code=200`? The
host is already allowed — skip to
[step 4](#4-rerun-the-probe--expect-200).

Proxy env: curl reads the uppercase forms, but apt, wget, git, and pip
only honor the lowercase — the env file injects both cases; non-gateway
profiles (direct `allow-host`
rules) have no proxy. Tools with their own proxy configuration (Gradle,
Maven, npm) or that ignore the env entirely:
[proxy-clients](../reference/proxy-clients.md).

## 2. See what's blocked

```sh
egresslock denied main
```

`denied main` lists what the gateway is STILL blocking (de-duplicated,
omitting hosts you already allowed — `denied main --all` shows the raw
list, and `denied main --days 0` the full log beyond the default
14-day window). It is the feed for the next `allow`.

## 3. Allow the domain

```sh
egresslock allow main example.com:443
```

`allow` appends to the allowlist and re-ensures the profile (the gateway
now permits `example.com`).

## 4. Re-run the probe — expect 200

Same `podman run` as step 1:

```sh
podman run --rm \
    --network="$(egresslock network main)" \
    --env-file=<(egresslock proxy-env main) \
    docker.io/curlimages/curl:latest \
    sh -c 'curl --max-time 10 -sS -o /dev/null -w "http_code=%{http_code}\n" https://example.com 2>&1'
```

Expect `http_code=200`. Still `000` with a `CONNECT tunnel failed`
line? The allow didn't land — check `denied main` and the allowlist.

## Remove an allowed domain

```sh
egresslock disallow main example.com:443
```

Removes the exact line and re-ensures; absent entry fails closed (exit
1, nothing changed). Re-run the probe — denied again.

> HTTP `allow` does not cover SSH or other non-HTTP traffic — ssh
> ignores HTTP(S)_PROXY and never reaches the gateway. For git-over-SSH
> use `allow-host <profile> <host:port>` (see
> [grow-the-policy](grow-the-policy.md)). IP:port destinations (LAN
> services, same-host services) have their own page:
> [allow-non-http](allow-non-http.md).

Next: [Grow the policy](grow-the-policy.md) — the allow/allow-host
flows and the destination → mechanism table.