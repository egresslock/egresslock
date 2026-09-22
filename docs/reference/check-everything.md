# Check everything — full per-layer catalog

This page answers: **"what do I inspect, per layer?"** — the full
health-check and inspection command catalog. Not sure which check
command answers which question? [which-check](../troubleshooting/which-check.md)
maps the four. The brief post-setup version is
[first-run-checks](../quickstart/first-run-checks.md);
when something is actually wrong, start at the
[symptom index](../troubleshooting.md). Run every command **as the
account** (`sudo -iu <account>`), not root — the three levels and
the tilde trap: [who-runs-what](who-runs-what.md).
Service commands run in **system** scope (no `--user`).

## The commands

Run as the dedicated `<account>` (never root):

```sh
sudo -iu <account>
```

`<account>` = your account name; `<name>` = a profile name (the per-profile
commands below use `main` as the example).

### 1. Account-wide (no profile name needed)

Run as the `<account>` (you are already in its shell):

```sh
# The egresslock networks
podman network ls
# The egresslock-anchor-<p> / egresslock-gateway-<p> containers
podman ps -a
# The anchor container (running state, name filter anchored at start):
podman ps -a --filter name=^egresslock-anchor --format '{{.Names}}  {{.Status}}'
# Shared rootless netns probe — rc=0 = healthy
podman unshare --rootless-netns true; echo "rc=$?"
# The kit nft table (in the account's shared rootless netns):
podman unshare --rootless-netns /usr/sbin/nft list tables | grep egresslock
# or scan everything:
#podman unshare --rootless-netns /usr/sbin/nft list ruleset | grep '^table'
# Verify, for every profile with a live anchor
/opt/egresslock/egresslock verify --ensured
# All profiles: name, network, subnet
/opt/egresslock/egresslock list
```

Want a one-off from your own shell? Prefix them with
`sudo -iu <account> --` (see [The tilde trap](who-runs-what.md#the-tilde-trap)
in the reference for why the tilde must stay unexpanded).

### 2. Per profile (needs the profile name — `main` below; one set per profile)

```sh
# Build + verify the policy (fail closed; re-resolves allow-host pins, heals DNS drift)
/opt/egresslock/egresslock ensure main
# Read-only drift check — a `drift:` line means "re-run ensure", not an error
/opt/egresslock/egresslock verify main
# The nftables rules the engine installs
/opt/egresslock/egresslock rules main
# What the gateway allows (raw allowlist file — comments included)
/opt/egresslock/egresslock allowlist main
# Hosts the gateway blocked (feed for `allow`; last 14 days by default — --days 0 for the full log)
/opt/egresslock/egresslock denied main
# Every request, one line each (last 5)
podman exec egresslock-gateway-main cat /var/log/squid/access.log | tail -5
# Startup / DNS errors (last 5)
podman exec egresslock-gateway-main cat /var/log/squid/cache.log | tail -5
# Container stdout/stderr (last 5)
podman logs egresslock-gateway-main --tail 5
```

### 3. The 15-minute verify timer (system service)

```sh
# The 15-minute verify timer
systemctl list-timers 'egresslock-verify@*' --no-pager
# Last verify run (exit 0 + 'verified (ensured)' = healthy; FAILED = drift, heal with ensure)
systemctl status egresslock-verify@<account>.service --no-pager -n 10
# Recent verify log lines
journalctl -u egresslock-verify@<account>.service --no-pager -n 10
```

## What "healthy" looks like

- `ensure` / `verify` exit 0 and print `profile 'main' policy and
  gateway verified`.
- `list` shows your profiles; one anchor (and one gateway per gateway
  profile) per ensured profile.
- The timer is `active (waiting)` with a recent `last run`; the service
  journal shows `verified (ensured)` lines. A `verify: ... FAILED` line
  means policy drift or a half-dead profile — heal with `ensure
  <profile>` as the account.
- `podman unshare --rootless-netns true` returns rc=0.
- One-liner: `podman unshare --rootless-netns true && egresslock
  ensure main && egresslock verify main` — all three exit 0.

## Reading the access log

`TCP_DENIED/403` = blocked (feed to `denied`/`allow`), `TCP_TUNNEL/200`
= an allowed HTTPS tunnel. A host **absent** from the log means the
packet never reached the gateway — check the profile's nftables chain
(scoped drop) or the client's proxy env (uppercase-only `HTTP_PROXY` is
a silent culprit: apt, wget, git, and pip read the lowercase forms and
connect directly, then hang on the drop).

## If something fails

Start at the [symptom index](../troubleshooting.md) (fastest
first): `podman unshare` probe → AppArmor journal → user session →
netns ownership → gateway logs.