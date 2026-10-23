# Recipe: deploy one conf+allowlist pair across multiple servers

Goal: build one egresslock profile pair — a `<profile>.conf` plus its
allowlist — deploy the same pair to N matching hosts with root
`egresslock-setup import`, wire each host with `egresslock-setup init`,
and apply it as the service account with `egresslock ensure`; then
re-pin every host from the same staged pair when the policy changes.

There is no egresslock "push" or remote command: "multiple servers"
means your existing config-management tool or SSH loop runs these local
root commands on each host. The recipe documents that loop and its
constraints; it does not add a feature.

## Before you start

- **One pair, matching hosts.** The account name is a command flag, not
  part of the files, so one pair fits every host that uses the same
  `profile` name, profile subnet, and gateway IP. Hosts that need
  different values need different pairs — that is a config-management
  templating concern and is out of scope here.
- **The subnet must be free on every host.** `ensure` rejects a profile
  whose subnet overlaps an existing Podman network, and the gateway IP
  must sit inside the subnet — not the network address, not `.1` (the
  bridge gateway), not the last usable address (the anchor). `.2` is
  valid for a `/24`; see
  [the policy reference](../../docs/reference/policy-reference.md#rules-to-keep-straight).
- **Real host root, with mount namespaces.** `import` and `init --from`
  run as actual host root — not container-mapped root — and validate
  the staged pair in a private mount namespace. A host or wrapper that
  denies `unshare -m` makes the import refuse before it touches the
  destination (it fails closed). Pathless `init` and `doctor` do not
  need a mount namespace.
- **The source must be readable by the account.** Before any write,
  `import` checks that the target account can read the source conf and
  its sibling allowlist. Stage the pair at an absolute path the service
  account can read on each host.
- **No passwordless sudo.** `egresslock-setup` takes free-form
  arguments (`--account`, `--from`, `--prefix`), so a `NOPASSWD` rule
  without an exact-argv restriction is equivalent to full root. The kit
  ships no sudoers snippet; run these commands through your existing
  root channel instead. See
  [who runs what](../../docs/reference/who-runs-what.md#root-sudo-and-nopasswd-no-passwordless-root).

## What you end up with

```
# staged once, then copied to every host at the same path
/srv/egress/svc.conf
/srv/egress/svc-allowlist

# on each host after the root step
/home/svc/.config/egresslock/svc.conf
/home/svc/.config/egresslock/svc-allowlist
/home/svc/.config/egresslock/unit.env        (written by init)
```

## 1. Stage the pair

Write the pair once — on your control host or in your config repo —
then distribute those two files to `/srv/egress/` on every host:

```sh
# /srv/egress/svc.conf — one profile, one gateway
profile svc 10.199.8.0/24
    rule gateway-only
    gateway 10.199.8.2 3128 svc-allowlist

# /srv/egress/svc-allowlist — the basename the gateway line names
svc.example.test:443
packages.example.test:443
```

The destination conf name comes from the pair's `profile` line
(`svc.conf` here), and the allowlist is copied from the source
directory by the basename in the `gateway` line. Keep the allowlist
next to the conf and name it by basename — an absolute allowlist path
is left as-is, and the account is warned when it cannot read it.

`import` takes the account from `--account`; it is never in the files.
Check the exact flags on the host with `egresslock-setup help import`.

## 2. First deploy on each host

As root on the host (via `sudo` from your own shell, or your
config-management tool's root channel):

```sh
sudo egresslock-setup init --account svc \
    --from /srv/egress/svc.conf --enable
```

This imports the pair, validates it as the account, writes `unit.env`,
builds the gateway image if missing, and enables linger plus the verify
timer. It stops at wiring — the runtime policy is applied by the
account step below.

```sh
sudo -iu svc -- egresslock ensure svc
sudo -iu svc -- egresslock verify svc
```

No `--force` on a first deploy: `import` installs into an absent
destination, and `init --from` refuses a differing destination with rc
1, leaving it untouched. A pre-existing starter (for example the
shipped `main.conf` when your pair is also `main`) must be inspected
first, then replaced with the re-pin form in step 3. `init` has no
pair force — `--force` is an `import` flag only.

Pathless `init` validates every `*.conf` in the account's config
directory and writes an empty `unit.env`, so the timer verifies all
profiles. That is the right form for a dedicated single-profile
account. If the account holds several profiles and you want the timer
to verify just this one, add `--profile svc` to `init` (the conf name
still comes from the pair's `profile` line).

If you prefer copy and wiring as separate steps, split it — same
result, still no `--force`:

```sh
sudo egresslock-setup import --account svc --from /srv/egress/svc.conf
sudo egresslock-setup init --account svc --enable
```

## 3. Re-pin every host

When the staged pair changes — an allowlist entry most often, the conf
rarely — replace it on each host and re-apply:

```sh
sudo egresslock-setup import --account svc \
    --from /srv/egress/svc.conf --force
sudo egresslock-setup init --account svc --enable
sudo -iu svc -- egresslock ensure svc
sudo -iu svc -- egresslock verify svc
```

- `--force` replaces the whole pair (allowlist first, conf last) and
  exists only on `import`. Never put it on `init`; `init --from`
  refuses a differing destination instead.
- The account-side `ensure` is the step that applies the new policy.
  `import` never runs `ensure`, and `init` only wires — without
  `ensure`, a host keeps serving the old runtime policy even though its
  files changed.
- Re-running the loop is idempotent: an identical pair succeeds with rc
  0 — with `--force` it is rewritten with the same bytes; without it
  `import` reports `unchanged`.

## 4. Loop over the hosts

Every host runs the same four steps in order: root `import` → root
`init` → account `ensure` → account `verify`. A placeholder SSH loop:

```sh
#!/bin/sh
# run on your control host; hosts.txt holds one host name per line
set -u
status=0
while IFS= read -r host; do
    [ -n "$host" ] || continue
    if ssh "root@$host" 'set -e
        egresslock-setup import --account svc --from /srv/egress/svc.conf --force
        egresslock-setup init --account svc --enable
        sudo -iu svc -- egresslock ensure svc
        sudo -iu svc -- egresslock verify svc
    '; then
        echo "ok   $host"
    else
        echo "FAIL $host — fix the named cause, then re-run this host" >&2
        status=1
    fi
done < hosts.txt
exit "$status"
```

The loop assumes the pair is already at the same absolute path on every
host. Put it there with your config-management tool (or `scp`) before
the loop runs; `import` reads it on the host, as root, and checks the
account can read it too.

If the kit is installed at a non-default prefix, add `--prefix <path>`
to both `egresslock-setup` commands.

## 5. Per-host outcomes

| rc | Meaning | Next |
|---|---|---|
| 0 | Imported and wired (an identical pair also returns 0) | Run the account `ensure` / `verify`; check `egresslock denied svc` after a workload. |
| 1 | Refused or validation failed; the destination was not touched | Read the named cause — source not readable by the account, subnet collision, differing pair without `--force`, failed staged validation — fix it, then re-run that host. |
| 2 | Usage error (missing or unknown flag, `--profile` mismatch) | Fix the command or loop; the host was not changed. |

`import` is atomic: the pair is staged and validated as the account
before anything is committed, a refusal or failed validation leaves the
destination bytes untouched, and the conf moves last. On `init --from`,
an import refusal stops `init` before anything is wired. A failed
`init` prints the `FAIL` step last — the steps before it ran, and
re-running the same host is safe.

## 6. Check one host by hand

```sh
sudo -iu svc -- egresslock verify svc
sudo -iu svc -- egresslock denied svc
```

`verify` checks the live policy; `denied` shows what the gateway
blocked, which is the fastest way to tell whether a host is running the
policy you just deployed. The verify timer re-checks every 15 minutes
once `--enable` ran.
