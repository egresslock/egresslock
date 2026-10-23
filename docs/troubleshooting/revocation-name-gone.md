# Revoking an allow-host rule whose name no longer resolves

## Symptom

`egresslock disallow-host <profile> <host>:<port>` refuses — exit code 1,
`nothing was changed` — saying the profile's installed firewall rules no
longer match its pin record; the `egresslock ensure <profile>` it
recommends then fails with `cannot resolve <host>`, and retrying
`disallow-host` refuses again. The revocation is stuck.

## Cause

`disallow-host` refuses while the live firewall rules disagree with the
profile's pin record (a tampered or drifted profile): it cannot prove which
installed rule belongs to the one you are revoking. The healing step,
`egresslock ensure <profile>`, rebuilds the rules from the profile conf and
resolves every `allow-host` name in it; when the name being revoked no
longer resolves, the rebuild cannot complete and the automatic recovery
cannot run.

## Fix — manual recovery (the account shell)

Run as the account (`sudo -iu <account>`; `egresslock` and `podman` from
there). You remove the rule from the conf by hand, then end its
connections with the engine's `drop-unauthorized` recovery command (the
per-address `conntrack -D` fallback is in step 5 if that command cannot
run). The procedure is **disruptive** — the profile's workloads stop,
and (only if the profile has a gateway) the gateway restarts — and it is
**not a `disallow-host` severance proof**: no `removed:` line is printed,
and you run and verify every step. Work in order; do not start workloads
again before step 5 passes.

1. **Stop everything that uses the profile.** List the containers on the
   profile's network:

   ```sh
   podman ps --filter network="$(egresslock network <profile>)" --format '{{.Names}}  {{.Status}}'
   ```

   Stop every container in the list except `egresslock-anchor-<profile>` —
   the anchor keeps the profile's firewall alive and sends no workload
   traffic. That includes the gateway `egresslock-gateway-<profile>` when
   the profile has one (a profile without a gateway has no such container):

   ```sh
   podman stop <workload-name> [...] egresslock-gateway-<profile>
   ```

   If the profile has no gateway, drop `egresslock-gateway-<profile>` from
   the command.

   Run the first command again and confirm only the anchor remains.

2. **Save the revoked rule's pinned addresses** from the pin record beside
   the conf (`~/.config/egresslock/<profile>.pins` by default):

   ```sh
   grep '^<host>|<port> ' ~/.config/egresslock/<profile>.pins
   ```

   The output is the rule's address set (for example
   `git.example.test|2222 192.0.2.10 192.0.2.11`). Keep it for step 5's
   fallback.

3. **Remove the rule from the conf** — edit
   `~/.config/egresslock/<profile>.conf` and delete that rule's
   `rule allow-host <host>:<port>` line. This is what makes the removal
   persistent: without it, the next `ensure` would re-install the rule.

4. **Rebuild and verify the rest of the profile.**

   ```sh
   egresslock ensure <profile>
   egresslock verify <profile>
   ```

   `ensure` now resolves only the remaining rules and rebuilds the firewall
   without the revoked rule; `verify` must exit 0. If `ensure` fails,
   another `allow-host` name in the profile no longer resolves: fix that
   name, then re-run both commands (or remove that rule too). Until step 5
   passes, do not run `ensure` again beyond step 4's own run: the rule's
   conf line is already gone (step 4 rebuilt the firewall without it), and
   a further `ensure` only refreshes policy — it does not end the
   connections (a plain conf edit plus `ensure` is a policy refresh, not
   the kill-switch).

5. **End the rule's remaining connections.**

   ```sh
   egresslock drop-unauthorized <profile> <port>
   ```

   This is the same recovery command a failed `disallow-host` prints. It
   reads the rebuilt firewall rules, ends the connections on `<port>` the
   policy no longer allows — including any earlier address the rule held
   after a DNS change — keeps the connections the policy still allows, and
   prints success only after a fresh check finds none left. It is safe to
   run again: if it reports leftovers, run it again.

   If that command cannot run (for example the profile's firewall rules
   are unreadable), end the connections one address at a time, using the
   addresses saved in step 2:

   ```sh
   podman unshare --rootless-netns conntrack -D -p tcp --dport <port> -d <address>
   podman unshare --rootless-netns conntrack -L -p tcp --dport <port> -d <address>
   ```

   The check must exit 0 and print no connection line; if a connection
   line remains, repeat the delete, then re-check. If you are using the
   fallback and the name's DNS changed earlier in the profile's life,
   earlier addresses may hold connections the rebuilt rules no longer
   accept — list the port and compare against the rebuilt rules, then end
   any leftover the same way:

   ```sh
   podman unshare --rootless-netns conntrack -L -p tcp --dport <port>
   egresslock rules <profile>
   ```

6. **Start the workloads again.** The rule is gone from the conf and the
   firewall, and step 5 showed no connection the rebuilt policy no longer
   allows remains; restarting a workload cannot reuse the revoked access.

If `conntrack` is not on your PATH, the tool is at `/usr/sbin/conntrack`.
Every `conntrack` check in step 5's fallback must exit 0 — an empty
result is the success case; a nonzero exit or an error message means the
check itself failed and is **not** proof that no connections remain.

## What this recovery does not cover

- It is not `disallow-host`: that command refused and printed no `removed:`;
  this page's steps removed the rule from the conf by hand and ended its
  connections with `drop-unauthorized` (or the checked per-address
  fallback).
- It removes the direct `allow-host` rule only. A `gateway` allowlist entry
  for the same host is separate policy (`egresslock disallow <profile>
  <host[:port]>`) and is unchanged.

## Links

- Revocation, the normal path: [the policy reference](../reference/policy-reference.md).
- Where the conf, allowlist and pin record live: [File locations](../reference/file-locations.md).
- Symptom index: [troubleshooting](../troubleshooting.md).
