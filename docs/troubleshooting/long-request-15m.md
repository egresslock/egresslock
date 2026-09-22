# Long request dies at exactly 15 minutes (15m00)

## Symptom

A long, non-streaming request through the proxy dies at almost exactly
15 minutes (15m00 ±1s): the client sees a dead connection or an aborted
transfer, while the origin server may still log a completed 2xx for the
same request. Requests shorter than 15 minutes to the same host succeed.
Repeating long requests therefore look like egresslock "breaks my
connection every 15 minutes" — but the interval is each request's own
duration, not a wall-clock cadence, and it has nothing to do with the
verify timer.

## Cause

The gateway's Squid inherits the stock **`read_timeout`** (15 minutes)
unless the profile overrides it. For a **non-streaming** POST, the origin
sends zero response bytes while it works; Squid counts 15:00 of idle on
the server connection and closes it. Streaming responses keep bytes
flowing, so they never trip the timer — which is why short requests and
streamed calls never show this signature.

Two things this is NOT:

- Not an `ensure`-time break: a gateway replacement severs proxied
  sessions at the moment you run `ensure`, not at a request's 15-minute
  mark (and since the converged-ensure gate, a redundant `ensure` of a
  healthy, unchanged profile does not restart anything).
- Not the verify timer: `verify` is read-only and never restarts
  containers.

## Fix

Set a per-profile timeout in that profile's conf block, then re-ensure:

```text
# in main.conf, inside the profile block
    read-timeout 3600
```

```sh
egresslock ensure <profile>
```

- Units are seconds: a positive integer, no suffixes (`15m` is
  rejected). Omitted means the default **900** (Squid's stock 15
  minutes).
- LLM/completion profiles that need long silent non-streaming waits opt
  in with a larger integer (`read-timeout 3600`). CI-class profiles that
  want tight failure timing can go the other way (`read-timeout 60`).
  There is deliberately no blanket generous default.
- The generated gateway config always carries an explicit
  `read_timeout <N> seconds` line, so you can confirm the live value:

  ```sh
  podman exec egresslock-gateway-<profile> \
      grep read_timeout /etc/squid/agent/squid.conf
  ```

- Only `read_timeout` is overridden. Squid's `request_timeout`,
  `connect_timeout`, and `client_lifetime` keep their stock values —
  none of them matches this hazard.
- Streaming the request also avoids the idle window, but the profile
  knob is the supported fix: the kit must not depend on client behavior.
