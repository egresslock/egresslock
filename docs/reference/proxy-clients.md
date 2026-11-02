# How to: make specific tools use the gateway (proxy-unaware clients)

Most tools honor the `HTTP(S)_PROXY` environment the launcher injects.
Some don't — and the failure signature tells you which kind you have:

- A **proxy-honoring** client that is denied fails FAST with a Squid
  403 error page (and shows up in `denied`).
- A tool that **ignores** the env connects DIRECT and hangs silently
  on the profile's nftables drop — no error page, nothing in
  `denied`.

So "some tool hangs" → check this table before anything else. (The
full path model: [allow-non-http](../quickstart/allow-non-http.md).)

Run every command **as the account**, and derive the gateway address
from the profile — never hardcode it (the profile's gateway IP and
port come from `egresslock proxy-env <profile>`; in the table below
`<gw-ip>`/`<gw-port>` are those two values for your profile):

| Tool | Reads HTTP(S)_PROXY env? | How to point it at the gateway |
|---|---|---|
| curl, wget, apt, pip, git (HTTP) | yes — apt/wget/git/pip read ONLY the lowercase spellings | nothing extra (the run recipes inject both cases) |
| Go programs | yes | nothing extra |
| Gradle | no | `-Dhttp.proxyHost=<gw-ip> -Dhttp.proxyPort=<gw-port> -Dhttps.proxyHost=<gw-ip> -Dhttps.proxyPort=<gw-port>`, or `gradle.properties` `systemProp.*`; mirror NO_PROXY in `http.nonProxyHosts`; `JAVA_TOOL_OPTIONS` injects the properties without touching the command line (prints a "Picked up" notice) |
| Maven | no | `~/.m2/settings.xml` `<proxies>` block |
| npm / yarn | partially (some operations) | `npm config set proxy "http://<gw-ip>:<gw-port>"` + `https-proxy`, or `.npmrc` |
| ssh / scp / rsync-over-ssh | never (not HTTP) | not natively — direct `allow <profile> <host:port> --direct`, or wrap in an HTTP CONNECT tunnel: `allow <profile> ssh.github.com` + a `ProxyCommand` (helper `ncat` — included in the shared example image) — see [Rotating names](rotating-names.md) |
| docker/podman pull INSIDE the workload | daemon-level, not workload env | point the daemon/containers.conf proxy settings at the gateway |

Exclusions mirror `NO_PROXY`: whatever the profile keeps off the proxy
(same-host services, direct-path destinations) must also appear in the
tool's own exclusion list (`http.nonProxyHosts` for Java tools,
`noproxy` for npm, ...). The engine's list:

```sh
egresslock proxy-env main noproxy
```

## Why the recipes inject SIX proxy vars

`egresslock proxy-env <profile>` prints six assignments — both cases
of the same pair:

- `HTTP_PROXY` / `HTTPS_PROXY` (uppercase) and `http_proxy` /
  `https_proxy` (lowercase) — the same gateway address. curl reads
  the uppercase forms for most URLs, but apt, wget, git, and pip
  honor ONLY the lowercase ones; tools that
  read either case get a consistent answer.
- `NO_PROXY` / `no_proxy` — destinations that must bypass the proxy
  and connect direct: `localhost,127.0.0.1`, the conf's `no-proxy`
  entries, and every direct-path IPv4 pin. NO_PROXY matching
  is host-only — port enforcement for bypassed destinations stays
  with the nftables policy.

The recommended way to give podman the six variables is the bare
`--out` form, read by podman in the same launch command:
`--env-file="$(egresslock proxy-env <profile> --out)"`.

One environment-change rule to remember: proxy env is baked at
container start — after any policy or env change, **regenerate**
the env file (`--out` writes it mode 0600 under the account's private
runtime dir on every run and prints the path) and **recreate** the
container (see [allow-non-http](../quickstart/allow-non-http.md)).

Use `--out=<path>` only as a backup when you need the file at a
specific location. Its directory must be writable only by your
account: a group- or world-writable directory is refused (exit 1,
nothing written). If the directory cannot be made private, choose
one of these instead:

- keep the file in the private runtime dir: use the bare `--out` form and
  read it in the same launch command;
- point `--out=<path>` at a directory only your account can write to;
- pass each value with `podman run --env KEY=value`.

Where the generated env file lives on disk (and the rest of the
account-side file catalog): [File locations](file-locations.md).
