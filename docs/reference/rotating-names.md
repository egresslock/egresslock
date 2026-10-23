# Rotating names: when an `allow-host` pin never stabilizes

**Why does `verify` warn `drift:` again and again for a name like `github.com`,
and why does re-running `ensure` not fix it?** Because such a name serves **one
address per query from a rotating pool**: every `ensure` sees a single pool
member, pins that one, and the next query returns a different member — the pin
can never be stable. This page explains the mechanism and the ways around it;
if the service speaks HTTP(S), the simplest fix is to stop pinning it —
the gateway resolves the name per request.

## The mechanism

`allow-host` resolves the name once per `ensure` and permits the addresses of
that one answer (the pin — [`allow-host` in
detail](policy-reference.md#allow-host-in-detail)). Two name shapes behave
differently:

- **Several A records in one answer** — the whole set is pinned, and a later
  reorder of the same addresses is not a change.
- **One A record drawn from a rotating pool** — every query is a one-address
  answer, so the pin stays a single stale address:
  - `verify` warns `drift: host <name> resolved to <new> but the policy pins
    <old>` whenever a cycle resolves another member (a cycle that returns the
    pinned member is silent; exit code stays 0 — [verify timer
    signals](../troubleshooting/verify-timer-signals.md));
  - only the pinned member is reachable; connections to the other members are
    dropped until the next `ensure`, which swaps which single member is pinned.
    The warning then returns.

This is a known, accepted limitation of `allow-host` pins — see the
[threat model](threat-model.md). `github.com` over SSH is the common
case. **If the service speaks HTTP(S), none of this applies** — the first
choice below is to stop pinning it; for a genuinely non-HTTP protocol, either
option below replaces the rotating name with something stable.

## First choice — if the service speaks HTTP(S), don't pin it

The gateway matches HTTP(S) requests by name **at request time**: no
pin, no `drift:`, nothing to maintain ([destination → mechanism
table](policy-reference.md#destination--mechanism-decision-table)). If
a rotating name is only used over HTTP(S), replace `allow-host` with
the name on the `allow` list:

```sh
# account — run as the dedicated account: sudo -iu <account>
# prompt: <account>@host:~$

egresslock disallow-host main github.com:22
egresslock allow main github.com
```

`disallow-host` exits with `rule not present` and changes nothing when
the name is not pinned — skip it if you never pinned the name. The
bare host adds the port-443 group (add an explicit `:80` for plain
HTTP). Run the workload with the proxy
environment (`--env-file="$(egresslock proxy-env main --out)"`); clients
that honor the proxy variables — `git`, `apt`, `curl` — then reach the
name through the gateway ([proxy clients](proxy-clients.md)). For
GitHub this is [Path 1 of the
recipe](../../examples/recipes/github.md).

## Option A — pin the pool as IPv4 literals

IPv4 literals never resolve, so they never drift, and every listed member is
reachable. Find the pool's members first (below), then replace the name
with one `allow-host` line per member.

### Finding the pool members

No address list is included here (don't copy one from anywhere) — the
members change over time, so this page teaches the method instead. The set
to replace the name with is every address you observe **plus** the
address(es) the current pin holds — the pin was an answer too, and your
observations need not return it again. Both methods read the pin record
(`~/.config/egresslock/<profile>.pins`; one `<host>|<port> <addresses>`
line per `allow-host` entry — [File locations](file-locations.md)), so pin
the name first (`egresslock allow-host <profile> <name>:<port>`) and keep
it pinned while you discover — a method that cannot read a pin (no record,
or no entry for the name) stops with a message instead of printing a set
that is missing the current pin. Both methods read the host resolver as
the account — the same resolver `ensure` and `verify` use; run these as
the account.

**Harvest the verify timer's own findings.** Pin the name
`egresslock allow-host <profile> <name>:<port>` and wait. In its default
sweep mode the timer verifies every ensured profile, so the journal
carries other hosts' `drift:` lines too; the filter keeps only the host
you are replacing. Only the `resolved to` value is an observation — the
fresh answer of that cycle; a `pins` value records what the pin was at
that moment, not what the resolver returns, so the harvest leaves it out
(a pin an earlier `ensure` moved past is a historical candidate, not
evidence). The one pin the set keeps is the current one, read from the
pin record at the account's real home — the command resolves that home
and stops, printing nothing, if the record or its entry for the name
cannot be read:

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

rec="$(getent passwd <account> | cut -d: -f6)/.config/egresslock/<profile>.pins"
pin="$(sudo sed -n 's/^github\.com|22 //p' "$rec" 2>/dev/null)"
if [ -n "$pin" ]; then
    { sudo journalctl -u egresslock-verify@<account>.service --since "7 days ago" \
        | sed -n 's/.*host github\.com resolved to \([^ ]*\) but the policy pins .*/\1/p'
      printf '%s\n' "$pin"
    } | tr ', ' '\n\n' | sort -u
else
    echo "no pin found for the name you are replacing ($rec) — pin the name first (egresslock allow-host), wait, then re-run" >&2
    false
fi
```

Run it with your own name in place of `github\.com` (escape the dot) and
your own port in place of `22`; `<account>` names the account whose home
holds the pin record — the first line resolves that home from the account
database, so a home outside `/home` works the same. When the message
appears, the name is not pinned: run `egresslock allow-host <profile>
<name>:<port>`, wait, and re-run — no address list is printed, so a set
missing the current pin cannot be mistaken for a result. Lines that say
`no longer resolves` are skipped — there is no pool to replace until the
name answers again. The pipeline prints each address once, one per line
(the shape below is a placeholder — a real run shows your own pool's
addresses):

```text
203.0.113.10
203.0.113.11
203.0.113.12
```

**Sample the resolver yourself.** No timer history needed; the resolver
serves a different member at different times (it caches one answer for
its TTL, so space the queries). The first lines are the current pin, read
from the pin record — normalized, so identical duplicate record lines
print once — and the run stops, printing no samples, if the record or its
entry for the name cannot be read; after that each address prints the
first time the resolver returns it — a repeat is silent:

```sh
# account — run as the dedicated account: sudo -iu <account>
# prompt: <account>@host:~$

seen="$(sed -n 's/^github\.com|22 //p' ~/.config/egresslock/<profile>.pins 2>/dev/null | tr ' ' '\n' | sort -u | tr '\n' ' ')"
if [ -n "$seen" ]; then
  for addr in $seen; do echo "$addr"; done
  for i in $(seq 1 30); do getent ahostsv4 github.com; sleep 60; done \
    | while read -r addr rest; do
        case " $seen " in
          *" $addr "*) : ;;
          *) seen="$seen $addr"; echo "$addr" ;;
        esac
      done
else
  echo "no pin found for the name you are replacing — pin the name first (egresslock allow-host), wait, then re-run" >&2
  false
fi
```

Run it with your own name and port in place of `github\.com` and `22`.
When the message appears, the name is not pinned: run `egresslock
allow-host <profile> <name>:<port>`, wait, and re-run. Stop with Ctrl-C
once no new address has appeared for a while; ten minutes of samples is a
starting window. A longer run samples more of the pool,
but no amount of sampling proves it complete. Ctrl-C is safe: everything
printed stays on screen. A member the resolver never returns stays
unreachable until you add its line. If the list keeps growing or changes
often, or you need every member reachable without maintenance, prefer
Option B — the tunnel resolves the name at connection time and keeps no
list.

### Replace the pin

With the members known, replace the name line. `disallow-host` exits with
`rule not present` and changes nothing when the name was never pinned
(skip it); each `allow-host` line re-ensures:

```sh
# account — run as the dedicated account: sudo -iu <account>
# prompt: <account>@host:~$

egresslock disallow-host main github.com:22
egresslock allow-host main <member-ip-1>:22
egresslock allow-host main <member-ip-2>:22
# …one line per member you observed
```

Add a line when you observe a new member, and remove a member's line when
a fresh discovery pass no longer shows it (`egresslock disallow-host main
<member-ip-1>:22` removes one) — nothing expires on its own, so re-running
the method is what re-checks the set. A pass covers your observation
window (the harvest's `--since`, or one sampling run), and an address the
window no longer shows is your removal candidate; a rarely returned
member can look the same, so the trade is reachability (keep it) against a
tight set (remove it). Either way a literal line is a standing
authorization of that `address:port`: the name is out of the loop, so a
line you keep permits its address after the provider retires it, and if
the address is later reassigned, the permission stays.

## Option B — tunnel by name through the gateway

A client that speaks HTTP CONNECT can send the connection through the gateway
instead: the gateway resolves the name **at connection time**, so there is no
pin to go stale. For GitHub, use its port-443 SSH endpoint:

```sh
# account — run as the dedicated account: sudo -iu <account>
# prompt: <account>@host:~$

egresslock allow main ssh.github.com
```

Then point the SSH client at the gateway. The gateway address for your profile
comes from `egresslock proxy-env <profile>` — never hardcode it. On the client
side (the workload container, or any machine that can reach the gateway):

```sshconfig
# ~/.ssh/config — the client side
Host github.com
    HostName ssh.github.com
    Port 443
    ProxyCommand ncat --proxy <gw-ip>:<gw-port> --proxy-type http --proxy-dns=remote %h %p
```

Plain `ssh git@github.com` and git-over-SSH then reach GitHub through the
gateway: the CONNECT request carries `ssh.github.com:443`, which the
gateway matches by name ([proxy clients](proxy-clients.md) has the client
list). Notes:

- The CONNECT helper is `ncat` — included in the shared `egl-base` example
  image; on your own image, install the `ncat` package.
- An idle tunnel can be cut at the profile's `read-timeout` (default 900 s) —
  see [long request dies at exactly
  15m](../troubleshooting/long-request-15m.md).
- Identity here is the name at connection time (see the
  [threat model](threat-model.md)); for SSH, the host-key check remains
  what proves the server (verify the fingerprint before accepting it).

## Which option?

| | `allow` by name (HTTP(S)) | Option A — literals | Option B — gateway tunnel |
|---|---|---|---|
| Client changes | none — run with the proxy env | none | `ProxyCommand` + a CONNECT helper |
| Maintenance | none | add a line when a member appears; remove it when a fresh pass no longer shows it | none |
| Authorizes | the name's answer at request time | exactly the members you listed, until you remove a line | the name's current answer at connection time |
| Coverage | every answer — resolved per request | the members you observed — one you never saw stays blocked | every answer — resolved per connection |
| Works for | services that speak HTTP(S) | any client | clients that speak HTTP CONNECT |

A worked walkthrough for the GitHub case:
[GitHub from a container](../../examples/recipes/github.md).
