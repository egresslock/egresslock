# Recipe: local LLM (Ollama, etc.) from a container

Goal: let a container on a profile network talk to an LLM server that
is **not a cloud API** — one running on the host itself or on the
LAN — without the gateway cutting off slow requests. Assumes the kit
is installed and the profile exists; run commands as the dedicated
`<account>` (`sudo -iu <account>`) and ensure the profile first
(`egresslock ensure <profile>`).

The gateway speaks hostnames, so where the server lives decides which
pattern you need:

## Server on the host (localhost)

The container cannot reach the host's own addresses directly (pasta
hairpin). Two supported patterns — proxied by name, or direct by
literal — are worked out in [reach a service on the host from a
container](../../docs/quickstart/reach-a-host-service.md). Example,
proxied HTTP server on the host:

```sh
egresslock allow main host.containers.internal:11434
```

## Server on the LAN (by IP)

`allow-host` pins a raw IP literal as a direct rule — e.g. a LAN
Ollama:

```sh
egresslock allow-host main 192.0.2.24:11434
```

The full walkthrough, including why IP literals bypass the proxy
automatically, is [allow non-HTTP
egress](../../docs/quickstart/allow-non-http.md).

## Slow requests time out

The gateway cuts a non-streaming request whose origin stays silent for
the profile's `read-timeout` (default 900 s) — a slow local model that
thinks for longer will be cut. Add it to the profile's conf block,
then re-ensure:

```text
profile main 10.199.3.0/24
    rule gateway-only
    gateway 10.199.3.2 3128 main-allowlist
    rule allow-host 192.0.2.24:11434
    read-timeout 3600
```

```sh
egresslock ensure <profile>
```

Details and the other things this is not: [long request dies at
exactly 15 minutes](../../docs/troubleshooting/long-request-15m.md).

## Run your program

Allow changes are baked into the proxy env at container start, so
start (or restart) the container after the `allow` above:

```sh
podman run --rm -it \
    --network="$(egresslock network <profile>)" \
    --env-file=<(egresslock proxy-env <profile>) \
    docker.io/library/debian:13-slim \
    sh
```

Then point the client at the address from the pattern you used
(`host.containers.internal` for a host server, the server's LAN IP for
an IP rule). A full end-to-end setup for a specific program (e.g. an
agentic tool) is in the [Recipes section](../../README.md#recipes) of
the README.