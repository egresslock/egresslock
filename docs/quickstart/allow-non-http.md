# How to: allow non-HTTP egress (git-over-SSH example)

`allow-host` permits direct egress for anything the HTTP gateway
cannot proxy — ssh, git-over-SSH, rsync, databases — and for raw IP
addresses; HTTP(S) by domain uses [allow-a-domain](allow-a-domain.md)
instead.

> **Before you start**
>
> 1. an account set up with a name of your choosing — the examples
>    use `egl-runner`; enter its shell with `sudo -iu egl-runner`
>    (see [who-runs-what](../reference/who-runs-what.md) for the
>    three worlds)
> 2. the profile is up — `egresslock ensure main` (the examples use
>    profile `main`; full health check:
>    [check-everything](../reference/check-everything.md))
> 3. the shared example image `localhost/egl-base:latest` —
>    built once per account
>    ([egl-base](../../examples/egl-base/README.md#build))

## The loop — worked example: git over SSH

1. **Start the container** — on the host, as the account, on the
   profile network. Image: `localhost/egl-base:latest`:
   ```sh
   # TERMINAL 2 — the host, account shell: sudo -iu egl-runner
   # prompt: egl-runner@host:~$

   egresslock proxy-env main > /run/user/$(id -u)/egresslock-proxy-main.env
   podman run --rm -it --name ssh-probe \
       --cap-drop=all --security-opt=no-new-privileges \
       --network="$(egresslock network main)" \
       --env-file=/run/user/$(id -u)/egresslock-proxy-main.env \
       localhost/egl-base:latest \
       sh
   ```

   <details>
   <summary>Expected output:</summary>
   you land at the container's shell prompt:

   <pre>
   root@9badc0ffee67:/#
   </pre>

   Troubleshooting: `localhost/egl-base:latest` not found? Build it:
   [egl-base](../../examples/egl-base/README.md#build).
   </details>

2. **(Optional) Try it from the workload** — you are inside the
   container now; this is TERMINAL 1 (the container shell runs as
   in-container root — not the host account):
   ```sh
   # TERMINAL 1 — the workload container
   # prompt: root@9badc0ffee67:/#

   ssh -o ConnectTimeout=5 -T git@github.com
   ```

   <details>
   <summary>Expected output (timeout):</summary>
   after 5 second delay…

   <pre>
   root@9badc0ffee67:/# ssh -o ConnectTimeout=5 -T git@github.com
   ssh: connect to host github.com port 22: Connection timed out
   </pre>

   That hang is the signature of a missing `allow-host` rule, so next
   we add it.
   </details>

3. **Allow it.** In a second terminal — TERMINAL 2, the host — as the
   account. Grammar: `allow-host <profile> <host:port>` — a hostname
   or an IPv4 literal (`allow` rejects IP literals; CIDR ranges are
   not yet supported). `github.com` resolves at ensure time and is
   tied to its current IP. Why egress has two paths:
   [paths-and-signatures](../reference/paths-and-signatures.md).
   ```sh
   # TERMINAL 2 — the host, account shell: sudo -iu egl-runner
   # prompt: egl-runner@host:~$

   egresslock allow-host main github.com:22
   ```

   <details>
   <summary>Expected output:</summary>

   <pre>
   egl-runner@host:~$ egresslock allow-host main github.com:22
   using config /home/egl-runner/.config/egresslock/main.conf
   added: rule allow-host github.com:22 -> /home/egl-runner/.config/egresslock/main.conf
   re-ensuring profile 'main' ...
   gateway 'egresslock-gateway-main' ready (already converged, not restarted)
   profile 'main' ready (network egresslock-main, policy verified)
   </pre>
   </details>

4. **Confirm.** Back in TERMINAL 1 — the container is still running:
   ```sh
   # TERMINAL 1 — the workload container
   # prompt: root@9badc0ffee67:/#

   ssh -o ConnectTimeout=5 -T git@github.com
   ```

   <details>
   <summary>Expected output:</summary>
   first connect from a fresh container: ssh shows the host key.
   Compare the presented `SHA256:…` fingerprint with GitHub's
   published SSH key fingerprints
   (https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
   before typing `yes`. Do not disable host-key checking.

   <pre>
   The authenticity of host 'github.com (140.82.113.4)' can't be established.
   ED25519 key fingerprint is SHA256:+<SHA>.
   This key is not known by any other names.
   Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
   </pre>

   after `yes` — either response shows the TCP path opened to a
   host at that name:port. It does not by itself prove GitHub
   identity; the fingerprint check above is what does.
   Without GitHub SSH keys set up:

   <pre>
   git@github.com: Permission denied (publickey).
   </pre>

   with SSH keys — the greeting:

   <pre>
   Hi <you>! You've successfully authenticated, but GitHub does not provide shell access.
   </pre>

   Troubleshooting: still hanging after step 3 reported `policy
   verified`? Check the entry for typos (`egresslock allowlist main`),
   then [paths-and-signatures](../reference/paths-and-signatures.md)
   and [proxied-or-direct](../troubleshooting/proxied-or-direct.md).
   </details>

5. **Prove the proxy path still fails closed** — a not-allowed DOMAIN
   gets the fast 403 from Squid; opening the direct pin opened
   nothing else (fresh one-shot container, TERMINAL 2):

   ```sh
   # TERMINAL 2 — the host, account shell: sudo -iu egl-runner
   # prompt: egl-runner@host:~$

   egresslock proxy-env main > /run/user/$(id -u)/egresslock-proxy-main.env
   podman run --rm \
       --cap-drop=all --security-opt=no-new-privileges \
       --network="$(egresslock network main)" \
       --env-file=/run/user/$(id -u)/egresslock-proxy-main.env \
       localhost/egl-base:latest \
       sh -c 'curl -sS -o /dev/null -w "http_code=%{http_code}\n" --max-time 10 https://blocked.example.test 2>&1'
   ```

   <details>
   <summary>Expected output (denied):</summary>
   immediately:

   <pre>
   egl-runner@host:~$ egresslock proxy-env main > /run/user/$(id -u)/egresslock-proxy-main.env
   podman run --rm \
       --cap-drop=all --security-opt=no-new-privileges \
       --network="$(egresslock network main)" \
       --env-file=/run/user/$(id -u)/egresslock-proxy-main.env \
       localhost/egl-base:latest \
       sh -c 'curl -sS -o /dev/null -w "http_code=%{http_code}\n" --max-time 10 https://blocked.example.test 2>&1'
   curl: (56) CONNECT tunnel failed, response 403
   http_code=000
   </pre>

   A 200 here means something is allowlisted that shouldn't be —
   `egresslock disallow`.
   </details>

6. **Observe the direct path on a not-allowed IP — expect a timeout**
   Back in TERMINAL 1 — the ssh-probe is still
   running. `--noproxy '*'` takes the direct path a
   proxy-ignoring tool would take (plain curl would 403 through the
   proxy — that is the previous check):

   ```sh
   # TERMINAL 1 — the workload container
   # prompt: root@9badc0ffee67:/#

   curl --noproxy '*' -sS -o /dev/null --max-time 5 http://203.0.113.1:8000
   ```

   <details>
   <summary>Expected output (timeout):</summary>
   after ~5 second delay:

   <pre>
   root@9badc0ffee67:/# curl --noproxy '*' -sS -o /dev/null --max-time 5 http://203.0.113.1:8000
   curl: (28) Connection timed out after 5000 milliseconds
   root@9badc0ffee67:/#
   </pre>

   The timeout is the expected observation on the direct path — not
   proof that egresslock dropped the packet (an unreachable or
   upstream-filtered endpoint looks the same). To check whether the
   live policy recorded drops during your probe, see
   [the counter check](../reference/paths-and-signatures.md#proving-a-drop-with-the-counter).
   Instant refusal is a different signature —
   [proxied-or-direct](../troubleshooting/proxied-or-direct.md).
   </details>

> [!TIP]
> **Reading the results**
>
> | Check | Good | If wrong |
> |---|---|---|
> | direct pin works (step 4) | the direct path opened exactly what you pinned | still hanging? — the step 4 Troubleshooting line |
> | not-allowed domain → 403 (step 5) | fail-closed at the proxy | 200? something is allowlisted that shouldn't be — `egresslock disallow` |
> | not-allowed IP → timeout (step 6) | expected observation on the direct path, not standalone proof | instant refusal (0 ms)? a different signature — [proxied-or-direct](../troubleshooting/proxied-or-direct.md) |

## (Optional) Remove the direct rule

Back on the host — exit the probe first (`exit`; it was `--rm`, it
goes away):

```sh
# TERMINAL 2 — the host, account shell: sudo -iu egl-runner
# prompt: egl-runner@host:~$

egresslock disallow-host main github.com:22
```

<details>
<summary>Expected output:</summary>
the `removed:` line comes last — it prints only after the re-ensure
and the revoked rule's conntrack teardown:

<pre>
egl-runner@host:~$ egresslock disallow-host main github.com:22
using config /home/egl-runner/.config/egresslock/main.conf
re-ensuring profile 'main' ...
gateway 'egresslock-gateway-main' ready (already converged, not restarted)
profile 'main' ready (network egresslock-main, policy verified)
removed: rule allow-host github.com:22 -> /home/egl-runner/.config/egresslock/main.conf
</pre>

Troubleshooting: rule not present? It fails closed — exit 1, nothing
changed.
</details>

## Next

- [First-run checks](first-run-checks.md) — the post-setup sanity pass.
