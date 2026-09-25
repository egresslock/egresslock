# Long request dies at exactly 15 minutes (15m00)

## Symptom

Long requests can time out. A slow, non-streaming request through the
proxy is cut when the origin sends no response bytes for longer than
the profile's `read-timeout` (default 900 s, i.e. 15 minutes): the
client sees a dead connection or an aborted transfer, while the origin
may still log a completed 2xx. Slow local inference is the classic
case; requests shorter than the timeout to the same host succeed.

## Cause

The gateway closes the server connection after `read-timeout` seconds
of idle — no bytes from the origin — and a non-streaming request sends
zero bytes while the origin works. The value comes from the profile's
`read-timeout` knob (default 900 s); the generated config always
carries an explicit `read_timeout <N> seconds` line. Streaming
responses keep bytes flowing, so they never trip the timer — which is
why short requests and streamed calls never show this signature.

Two things this is NOT:

- Not an `ensure`-time break: a gateway replacement severs proxied
  sessions at the moment you run `ensure`, not at a request's
  15-minute mark (and since the converged-ensure gate, a redundant
  `ensure` of a healthy, unchanged profile does not restart anything).
- Not the verify timer: `verify` is read-only and never restarts
  containers.

## Fix

Set a per-profile timeout in that profile's conf block, then re-ensure:

```text
profile main 10.199.3.0/24
    rule gateway-only
    gateway 10.199.3.2 3128 main-allowlist
    read-timeout 3600
```

```sh
egresslock ensure <profile>
```

- Units are seconds: a positive integer. The default is **900**
  (Squid's stock 15 minutes); omitted means the default.
- LLM/completion profiles that need long silent non-streaming waits
  opt in with a larger integer (`read-timeout 3600`). CI-class
  profiles that want tight failure timing can go the other way
  (`read-timeout 60`).
- Confirm the live value — the generated gateway config always
  carries an explicit `read_timeout <N> seconds` line:

  ```sh
  podman exec egresslock-gateway-<profile> \
      grep read_timeout /etc/squid/agent/squid.conf
  ```

- Only `read_timeout` is overridden. Squid's `request_timeout`,
  `connect_timeout`, and `client_lifetime` keep their stock values —
  none of them matches this hazard.
- Streaming the request also avoids the idle window, but the profile
  knob is the supported fix.