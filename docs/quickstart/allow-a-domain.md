# How to: allow a domain (and see what's blocked)

The loop: probe the deny-all policy → see what's blocked → allow a
domain → confirm.

> **Before you start**
>
> 1. an account set up with a name of your choosing — the examples
>    use `egl-runner`; enter its shell with `sudo -iu egl-runner`
>    (see [who-runs-what](../reference/who-runs-what.md) for the
>    three worlds). Nothing installed yet? Start at
>    [install](../setup/install.md).
> 2. the profile is up — `egresslock ensure main` (the examples use
>    profile `main`; full health check:
>    [check-everything](../reference/check-everything.md))
> 3. the shared example image `localhost/egl-base:latest` —
>    built once per account
>    ([egl-base](../../examples/egl-base/README.md#build))

## 1. Probe the deny-all policy — expect a denied CONNECT

The starter allowlist is **EMPTY** (fail-closed): the gateway
denies application connections; DNS queries to the bridge
resolver are still allowed and can carry data out
([threat model](../reference/threat-model.md)). Probe with
`localhost/egl-base:latest`.

From the account shell on the host — each probe is a throwaway
container that runs one command and exits (`--rm`), so there is no
shell to leave behind:

```sh
# the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

podman run --rm \
    --cap-drop=all --security-opt=no-new-privileges \
    --network="$(egresslock network main)" \
    --env-file="$(egresslock proxy-env main --out)" \
    localhost/egl-base:latest \
    sh -c 'curl --max-time 10 -sS -o /dev/null -w "http_code=%{http_code}\n" https://example.com 2>&1'
```

<details>
<summary>Expected output (denied):</summary>
fast — the 403 comes back quickly; the 10 s figure is only the
`--max-time` ceiling of the probe command, not how long the denial
takes:

<pre>
egl-runner@host:~$ podman run --rm \
    --cap-drop=all --security-opt=no-new-privileges \
    --network="$(egresslock network main)" \
    --env-file="$(egresslock proxy-env main --out)" \
    localhost/egl-base:latest \
    sh -c 'curl --max-time 10 -sS -o /dev/null -w "http_code=%{http_code}\n" https://example.com 2>&1'
curl: (56) CONNECT tunnel failed, response 403
http_code=000
</pre>

The CONNECT `403` (`curl: (56) CONNECT tunnel failed, response 403`)
is the gateway denial. `http_code=000` only means no origin HTTP
response — a connection failure prints it too. See
[paths-and-signatures](../reference/paths-and-signatures.md).
Already `http_code=200`? The host is already allowed — skip to
[step 4](#4-re-run-the-probe--expect-200).

Troubleshooting: `localhost/egl-base:latest` not found? Build it:
[egl-base](../../examples/egl-base/README.md#build).
</details>

## 2. See what's blocked

```sh
# the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock denied main
```

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ egresslock denied main
note: this view covers one lane and may be incomplete — a short or empty list is not proof nothing was denied. See: egresslock help denied.
example.com
</pre>

One line per still-blocked destination (de-duplicated, hosts you
already allowed omitted — `--all` shows the proxy view without the
allow-covered filter, still parsed and de-duplicated, not the raw
log); it is the feed for the next `allow`.

Troubleshooting: empty when you expected a hit? Stale engine/env —
[proxied-or-direct](../troubleshooting/proxied-or-direct.md).
</details>

## 3. Allow the domain

```sh
# the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock allow main example.com:443
```

> [!WARNING]
> Allowlist changes and re-running `ensure` reload the gateway in
> place when the reload can be confirmed, so established proxied
> sessions keep running — a new connection can briefly fail while the
> gateway reopens its listener. When the engine cannot confirm the
> reload it warns and restarts the gateway instead, which drops proxied
> connections. Disallowing a domain always restarts the gateway, so
> proxied connections drop — including those of other containers on the
> same profile network.

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ egresslock allow main example.com:443
using config /home/egl-runner/.config/egresslock/main.conf
path: proxy — gateway allowlist /home/egl-runner/.config/egresslock/main-allowlist
added: example.com:443 to /home/egl-runner/.config/egresslock/main-allowlist
re-ensuring profile 'main' ...
gateway 'egresslock-gateway-main' ready (allowlist applied, health verified)
profile 'main' ready (network egresslock-main, policy verified)
</pre>

`allow` defaults to the proxy path (a bare name means HTTPS/443); the
`path:` line names the store every successful mutation changed. It
adds the entries to the allowlist with a same-directory atomic
replacement (not an in-place append) and applies the change (the
gateway now permits `example.com`); batch as many entries as you like —
multiple arguments, one re-ensure. A rewrite needs the allowlist to be
a regular `0600` file — see
[how proxy allow writes the allowlist](../reference/file-locations.md#how-proxy-allow-writes-the-allowlist).
</details>

### A proxy allow on a non-standard port

A port other than 80/443 on the proxy path is still a gateway
allowlist entry, but the command prints a two-line stderr note
suggesting an additional direct rule. It is advice, not a switch: the
allowlist entry stays.

```sh
# the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock allow main dev.example.com:8080
```

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ egresslock allow main dev.example.com:8080
using config /home/egl-runner/.config/egresslock/main.conf
path: proxy — gateway allowlist /home/egl-runner/.config/egresslock/main-allowlist
added: dev.example.com:8080 to /home/egl-runner/.config/egresslock/main-allowlist
note: port 8080 is not the usual HTTP(S) port. If dev.example.com:8080 is a non-HTTP service, add a direct rule as well (this does not remove the allowlist entry):
  egresslock allow main dev.example.com:8080 --direct
re-ensuring profile 'main' ...
gateway 'egresslock-gateway-main' ready (allowlist applied, health verified)
profile 'main' ready (network egresslock-main, policy verified)
</pre>
</details>

For a non-HTTP service (ssh, git-over-SSH, databases), use the
direct path instead: [allow-non-http](allow-non-http.md).

## 4. Re-run the probe — expect 200

Same `podman run` as step 1:

```sh
# the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

podman run --rm \
    --cap-drop=all --security-opt=no-new-privileges \
    --network="$(egresslock network main)" \
    --env-file="$(egresslock proxy-env main --out)" \
    localhost/egl-base:latest \
    sh -c 'curl --max-time 10 -sS -o /dev/null -w "http_code=%{http_code}\n" https://example.com 2>&1'
```

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ podman run --rm \
    --cap-drop=all --security-opt=no-new-privileges \
    --network="$(egresslock network main)" \
    --env-file="$(egresslock proxy-env main --out)" \
    localhost/egl-base:latest \
    sh -c 'curl --max-time 10 -sS -o /dev/null -w "http_code=%{http_code}\n" https://example.com 2>&1'
http_code=200
</pre>

Troubleshooting: still `000` with a `CONNECT tunnel failed` line? The
allow didn't land — check `denied main` and the allowlist
(`egresslock allowlist main`).
</details>

## Remove an allowed domain

```sh
# the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock disallow main example.com:443
```

<details>
<summary>Expected output:</summary>

<pre>
egl-runner@host:~$ egresslock disallow main example.com:443
using config /home/egl-runner/.config/egresslock/main.conf
path: proxy — gateway allowlist /home/egl-runner/.config/egresslock/main-allowlist
re-ensuring profile 'main' ...
gateway 'egresslock-gateway-main' ready (allowlist applied, health verified)
profile 'main' ready (network egresslock-main, policy verified)
removed: example.com:443 from /home/egl-runner/.config/egresslock/main-allowlist
</pre>

Removes the exact line and applies the change — by a full gateway
restart, not a reload (revocation must sever established tunnels).
Every proxied session on the profile drops, not only sessions to the
removed destination. Re-run the
probe — denied again. Entry not present? It fails closed — exit 1,
nothing changed:

<pre>
egl-runner@host:~$ egresslock disallow main example.com:443
Error: entry not present: example.com:443 (proxy path)
</pre>
</details>

## Next

- [Allow non-HTTP egress](allow-non-http.md) — `allow … --direct` for
  git-over-SSH and raw IPs, and the fail-closed proofs.
