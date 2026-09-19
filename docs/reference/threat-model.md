# Threat model

What this kit protects, from whom, what it assumes, and what an attacker
should expect when it fails. This is the single source of truth for the
security claims; the README's Security model section only points here.

Every row in the [attacks table](#attacks-table) carries an honest
status: `lab-verified` (probed on a dogfood host), `code-verified`
(read in the shipped code, not probed live), `design-intent` (intended
behavior, not yet probed), or `open-by-design` (a known, accepted gap).
Nothing here is a pentest claim. The input paths this model assumes
(allowlist grammar, log parsing) have had a completed hardening review
and a completed input→sink review; the live
egress-bypass exercise has run on a throwaway account. It was
not a pentest, and it found no undocumented general egress.

Last reviewed: 2026-09-11. The claims below are scoped to the dogfood
hosts in the [version matrix](#version-matrix), not to "any rootless
Podman" install.

## Scope

This threat model is about the workload's egress surface, not complete
workload security. egresslock reduces the permitted egress surface under its
documented deployment assumptions; it is not a general container-escape
prevention mechanism.

The asset is the **egress of untrusted workloads** running on **one**
rootless Podman account: workloads on a profile network should reach
only the destinations the account's policy allows, the allowlist is
enforced in nftables inside the account's rootless netns, and a
workload must not be able to bypass it with ordinary container
capabilities.

Explicitly **not** in scope — this kit does not claim to provide:

- host isolation or a sandbox: the workload runs in the same kernel,
  under the same account, on the same host;
- multi-tenant isolation between accounts beyond what rootless Podman
  stores already give (each account sees only its own networks);
- protection of secrets that the operator puts *inside* the workload
  (env, mounts, image layers);
- the supply-chain of images the operator pulls and runs;
- a host firewall replacement (see [Trust boundaries](#trust-boundaries)).

## Trust boundaries

Enforcement lives in the **account's rootless netns** — not in the
workload container, not in the host netns, not in the proxy env:

```
workload container (A1)      sibling container on same profile network (A2)
          |                                   |
          +----------------+------------------+
                           v
              profile bridge / subnet
              e.g. 10.199.0.0/24
              aardvark DNS: 10.199.0.1:53
                           |
                           v
  ============================================================
   account-owned rootless network namespace
   PRIMARY EGRESS ENFORCEMENT POINT
  ============================================================

  inet egresslock p_v6deny
    forward hook priority -160
    -> drop all forwarded IPv6

  inet egresslock p_<profile>
    forward hook priority -150
    default drop for the profile subnet

    explicit exceptions (gateway-only shape):
      * established / related
      * DNS -> bridge-ip:53
      * allow-host destination pins
      * daddr gateway-ip:proxy-port
      * saddr gateway-ip (gateway's own egress)
                           |
            +--------------+--------------+
            |                             |
            v                             v
   Squid gateway                    allow-host / DNS
   <gateway-ip>:3128                skip Squid
   cap-drop=all
   no-new-privileges
            |                             |
            +--------------+--------------+
                           v
                pasta / rootless plumbing
                           |
                           v
                    host network namespace
              post-NAT source = account IP
                           |
                           v
                host nftables / firewall
                defense in depth only
```

Picture is the **gateway-only** forward path. `public-only` terminals in
scoped accept after the RFC1918/link-local/multicast drops (leftover
ranges unchanged). A1↔A2 on the bridge is L2 (T7), not this hook.

Two consequences follow from where the chain sits:

- The host netns only sees post-NAT traffic from the account IP, so a
  host firewall cannot tell profile subnets apart and cannot police
  profile egress; it is defense-in-depth only.
- Inside the shared rootless netns, an nft `accept` is **not** final:
  any other forward-hook chain at the same or earlier priority still
  sees the packet and can drop it. `verify` fails closed on leftover
  legacy tables and foreign early forward hooks (observed on-host with
  the pre-rename `agent_policy` table), and `ensure` deletes the legacy
  table — but an operator-installed early drop chain remains a real
  hazard: it silently blocks traffic this kit believes it allowed,
  with no `denied` log entry (see T2 and T13).

The kit's own files split across the boundary as follows: the policy
(conf + allowlists) lives in the account's `~/.config/egresslock/` and
is never mounted into workload containers by the kit — the operator's
launcher must not bind-mount it in (see I5); the
kit binaries under `/opt/egresslock` are root-owned (see the TCB for
what that does and does not mean).

## Attackers

| ID | Attacker | Position |
|---|---|---|
| A1 | a process inside a workload container | may be container root, typically with no capabilities when launched by a cap-dropping launcher |
| A2 | another container on the same profile network | same L2, same subnet, kit policy applies to it identically |
| A3 | another account on the same host | separate rootless store/netns; unprivileged |
| A4 | a destination the operator allowlisted (a malicious or compromised SaaS/CDN), or its DNS | inside the policy, not outside it |
| A5 | a local unprivileged user holding the kit binaries | uninteresting: if they already own the account, the kit adds nothing for them |

A1 is the primary attacker. A2 matters because the profile network is
shared. A3 is out of scope beyond Podman's own per-account store
isolation (T15). A4 is partly accepted by design (T17); A5 is noted for
completeness.

## Trusted computing base

What the kit's claims rest on:

- the Linux kernel's unprivileged user/network namespace support, and
  pasta/netavark as the rootless network plumbing (masquerade in the
  rootless netns, DNS via aardvark);
- nftables in the account's netns (`inet egresslock`): the enforcement
  point everything above hangs off;
- the Squid gateway image **as built** (Debian slim + Squid), which the
  kit always starts with `--cap-drop=all --security-opt=no-new-privileges`;
- the engine and the account's conf/allowlist under
  `~/.config/egresslock/`: whoever controls those controls the policy;
- root-owned `/opt/egresslock` as **tool integrity** only — it stops a
  workload from rewriting the kit, but it is not a policy boundary: the
  policy is what the conf says, not where the script lives.

Convenience-only, **not** trusted: the `HTTP_PROXY`/`HTTPS_PROXY`
environment the operator wires into workloads. Removing it does not
open egress (the chain still drops), and setting it does not create
any (see I2).

Operator obligations the kit does not enforce:

- launch workloads through a launcher that passes `--cap-drop=all
  --security-opt=no-new-privileges`. The kit ships no workload
  launcher: this is the operator's launcher's job, and examples or
  recipes showing a `podman run` line are operator-owned, not a kit
  guarantee. Plain `podman run` keeps the default capability set,
  including `CAP_NET_RAW`;
- do not bind-mount the account's home (or `~/.config/egresslock/`)
  into workloads — a launcher that does changes I5. Policy files are
  not in the workload unless the operator mounts them there;
- on **labeled-podman** hosts (podman running under an AppArmor label,
  the default on Ubuntu >= 25.10), apply the pasta AppArmor amendment
  or `ensure` fails closed: the pasta SIGTERM denial blocks the netns
  setup, so no policy is installed — a fail-closed setup error, not a
  policy bypass. Stock Debian (unlabeled podman) is unaffected. See
  [the pasta AppArmor page](../troubleshooting/pasta-apparmor.md).

## Invariants

What `ensure`/`verify` are supposed to keep. Each maps to a row in the
attacks table or an explicit non-goal.

| ID | Invariant | If broken |
|---|---|---|
| I1 | Default drop for the profile subnet, except established/related flows, DNS to the bridge gateway `:53`, explicit `allow-host` pins, the gateway's own port, and the gateway's source address going out. DNS has two paths by design: (a) workload DNS to the bridge gateway `:53`; (b) the **gateway process's own DNS**, which pasta forwards to `169.254.1.1` — i.e. the **host resolver, for any name** | direct internet or LAN reach from the workload. (b) is not a workload bypass — the gateway's connects are still Squid-allowlisted — but its DNS egress is host-resolver-wide by design |
| I2 | The proxy env is not the boundary: nftables is | an operator believes unsetting the proxy stops egress, or setting it grants egress |
| I3 | On a gateway-only profile the gateway being down means no direct internet (nothing else is accepted) | fail-open when Squid dies |
| I4 | Forwarded IPv6 is dropped (`p_v6deny`, before Netavark) | IPv6 bypass of an IPv4-only policy |
| I5 | The conf/allowlist never enter the workload filesystem (the kit never mounts them; the operator's launcher must not bind-mount the account home or confdir) | the workload reads or edits its own policy |
| I6 | The site must `ensure`/`verify` before workloads start; a missing or stale chain means unprotected, not safe | empty/stale chains, or a profile with no `p_<name>` chain at all, silently pass traffic |

## Non-goals / accepted risks

- **Not a sandbox.** A1 is assumed to escape nothing but is also not
  trusted; the kit constrains its *network*, not its code.
- **Not host isolation**, not multi-tenant hardening.
- **Same-profile L2 is open (T7):** siblings on one profile network can
  reach each other's ports and the gateway's proxy port directly.
- **Single rootless account (A3/A5):** another account on the host is
  outside the model; the kit neither protects nor attacks it.
- **IPv4-only:** forwarded IPv6 is dropped, never proxied.
- **`allow-host` DNS pin drift (T13):** a pin keeps the first-A IP from
  `ensure` time; if DNS moves, traffic still goes to the old address
  (and `verify` warns) until `ensure` re-pins.
- **`public-only` is wide of some ranges (T14):** the emitted
  drop set is exactly RFC1918 (10/8, 172.16/12, 192.168/16),
  link-local (169.254/16), multicast (224/4), and broadcast
  (255.255.255.255). Loopback, CGNAT (100.64/10), 0/8, benchmark
  (198.18/15), and reserved (240/4) destinations are *not* dropped on a
  `public-only` profile.
- **Kit path is distribution, not isolation:** a root-owned install
  prefix protects the tool's integrity, nothing more.
- **Kit root tools are interactive-root only:** no
  sudoers file is shipped and `NOPASSWD` on `install-kit.sh`,
  `uninstall-kit.sh`, or `egresslock-setup` is unsupported — their
  arguments are free-form (`--prefix`, `--account` + `runuser`,
  `--conf`), so passwordless sudo on them without exact argv is
  equivalent to root. The engine itself refuses root (T16).
- **Name rebind through the proxy (T17) is open by design:**
  the allowlist is name-based (dstdomain), names resolve at request
  time, and the gateway's own egress is exempt from the profile chain —
  so an allowlisted name that starts resolving to a private address is
  connected from the gateway's position. LAN hosts the operator meant
  to allow directly stay on `allow-host`; `disallow` closes the hole.
- **Profile rules are source-scoped; cap-drop is what makes them bite
  (T9 neighbor):** the profile chain matches `ip saddr <profile subnet>`
  over a base accept policy, so a workload that retains `CAP_NET_RAW` can
  emit packets with a source address outside that subnet (e.g. the
  gateway's) that never match those rules. Dropping capabilities on
  workloads is the same operator obligation as T9 — when the operator's
  launcher drops caps, this is not a bypass.
- **DoH through an allowlisted host is allowlist granularity, not a
  bypass:** the chain only ever permits DNS to the bridge resolver, but
  if the operator allowlists a host that serves DoH, arbitrary name
  resolution returns *through the proxy* — the allowlist speaks
  hostnames, not functions.
- **DNS queries to the bridge resolver are an exfil channel:** the chain
  permits DNS only to the bridge resolver, so query names leave the
  netns unimpeded — allowlist granularity, same family as
  DoH-through-an-allowlisted-host above.
- **Gateway DNS through pasta is a second exfil/leak surface (I1b):**
  the gateway's own resolver is pasta's forwarder at `169.254.1.1`,
  which ends at the host resolver for **any name** — so DNS names
  queried from the gateway's position (while resolving allowlisted
  dstdomains, for instance) also leave unimpeded, without a profile
  chain in between. Not a workload bypass: Squid still allowlists the
  gateway's connects; the queries themselves are not gated.
- **Two paths, one destination, different verdicts (T18 neighbor):**
  on a gateway profile an `allow-host` IP is an nft-direct rule, but a
  proxied HTTP(S) request to that same literal IP never reaches it —
  the only wire destination is the gateway port, and the names-only
  dstdomain allowlist denies it — unless `no-proxy` (conf) or the
  client's `NO_PROXY` steers the request off the proxy. This is the
  documented two-path behavior, not a bypass.

## Attacks table

Hang = nft drop, no Squid log line. 403 = Squid policy denial
(`denied` can list it). 503 = allowed but destination dead.
CONNECT deny may show as curl `000` with 403 in the error line.

| # | Attacker action | Expected behavior | Operator sees | Status |
|---|---|---|---|---|
| T1 | `curl https://evil.test` with proxy env, host not allowlisted | Squid CONNECT deny | `denied` lists `evil.test`; 403 | lab-verified |
| T2 | Same without proxy env (direct SYN to 443) | nft drop | hang; **not** in `denied` | lab-verified |
| T3 | `curl http://deb.example/` (port 80) not allowlisted | Squid GET deny | `denied` lists `deb.example:80`; 403 | lab-verified |
| T4 | `allow` of T3's host **without** `:80` | still denied on 80 (no-port group is 443) | `denied` still shows `:80` | design-intent |
| T5 | UDP/TCP to 8.8.8.8:53; DoT 853; direct DoH 443 | drop (DNS only to bridge gw) | hang; no gateway log | lab-verified |
| T6 | IPv6 destination | `p_v6deny` | fail; IPv4-only kit | lab-verified |
| T7 | Sibling on same profile: connect to peer:22 | **allowed** (L2) | n/a — accepted risk | lab-verified (open L2; still accepted) |
| T8 | Sibling: gateway:3128; other gateway ports; cache manager | 3128 allowed + Squid ACL; other ports nft-dropped; mgr 403 | can probe Squid; cannot widen nft | lab-verified |
| T9 | Spoof source IP = gateway IP | fails without `CAP_NET_RAW`. Kit forces cap-drop on the **gateway**. Workloads: launcher policy. Profile nft still applied to a default-caps container. | if spoofed `saddr GW_IP` is forwarded, I1 is broken | code-verified (flags); spoof itself untested; live exercise: a default-caps `debian:13-slim` workload got `SOCK_RAW` `EPERM` — the forwarded-spoof path was **not** demonstrated; not closed |
| T10 | Workload reads `~/.config/egresslock/` | not mounted by the kit; the operator's launcher is the only path in | empty of policy files unless the operator bind-mounts `$HOME` or the confdir | code-verified (kit paths) |
| T11 | `allow 'foo; rm -rf /'` | reject, exit 2, file unchanged | usage / invalid entry | code-verified |
| T12 | Gateway container stopped | no useful exemption for the workload; default drop | connect fail; `denied` may be empty | design-intent |
| T13 | `allow-host` then DNS changes | traffic still to **old** A until `ensure`; `verify` warns `drift:` | hang to new IP; `verify` rc=0 with warning | lab-verified (drift loop). E2E pin: lab-verified after leftover `agent_policy` removed |
| T14 | `public-only` profile | public IPv4; RFC1918 + 169.254/16 + 224/4 + broadcast dropped | LAN RFC1918 blocked. Not CGNAT/loopback | lab-verified (RFC1918) |
| T15 | Another account's `podman network ls` | cannot see this account's nets | empty / other store | design-intent |
| T16 | Engine run as root | refuse | error; root's store unused | design-intent |
| T17 | CONNECT to allowlisted name that now resolves to RFC1918 | **open by design** (A4): name-based dstdomain + request-time DNS + `saddr GW_IP` accept. A rebind can reach **cloud metadata (`169.254.169.254`)** and **LAN services**, not only a generic private address. LAN IPs the operator meant stay `allow-host`. | proxy returns the private service's body; `disallow` restores deny | open-by-design (lab-verified gap) |
| T18 | Literal `http://127.0.0.1` (or other IPv4 URL) via proxy | Squid 403 (dstdomain is names). `allow` of an IPv4 literal is rejected. Use `allow-host` for addresses. | 403; `allow` exit 2 | lab-verified (unlisted literals); grammar: literals rejected |

Rows read as "what should happen", not a pentest report:
`design-intent` rows are untested; `open-by-design` rows are gaps the
model accepts on purpose. Nothing here is fuzz-tested. The hardening
review of the input paths and the input→sink review are complete; the
live adversarial exercise has run on a
throwaway account, with no undocumented general egress found.

## Version matrix

Claims in this document were checked on these dogfood hosts. Do not
generalize them to "any rootless Podman"; re-verify after a major
podman/pasta/netavark upgrade.

| Host | Date | OS | kernel | Podman | Netavark | nftables | Squid |
|---|---|---|---|---|---|---|---|
| 1 | 2026-09-02 | Debian 13.6 | 6.12.101 | 5.4.2 | 1.14.0 | 1.1.3 | 6.x (banner 6.13) |
| 2 | 2026-09-07 | Kubuntu 26.04 | 7.0.0-31 | 5.7.0 | 1.16.1 | live nft | 6.13 (image) |
| 3 | 2026-09-11 | Debian (unlabeled podman) | | | | | |

pasta is the rootless netns holder on all three.

Host 2 runs podman under an AppArmor label (AppArmor 5.0), so the pasta
amendment is required there; host 3 is stock Debian with unlabeled
podman — no podman label profile ships with Debian's apparmor package,
so the amendment does not apply and was not installed. The pasta
AppArmor amendment is not part of the accepted-risk set: where it is
missing but needed, `ensure` fails closed (see
[the pasta AppArmor page](../troubleshooting/pasta-apparmor.md)).

Claims are host-scoped: `egresslock doctor` (engine subcommand) is the
per-host runtime evidence for podman/netavark/nft/unprivileged-userns —
it is not a license to generalize the matrix to "any rootless Podman".

## Related

- [Grow the policy](../quickstart/grow-the-policy.md) — the two allow
  mechanisms (allowlist file vs `allow-host`) this model talks about.
- [Troubleshooting](../troubleshooting.md) — what a miss looks like in
  practice (hang vs 403 vs 503); not duplicated here.
- Hardening — **completed**: the adversarial review of the
  input paths this model assumes (allowlist grammar under adversarial
  entries, log parsing).
- Input→sink review — **completed**: the separate input→sink review of
  the engine scripts.
- Live egress-bypass adversarial exercise — **completed**: it has run;
  no undocumented general egress found (not a pentest claim).
- Leftover early forward-hook chains: the
  competing-chain hazard described under
  [Trust boundaries](#trust-boundaries).
