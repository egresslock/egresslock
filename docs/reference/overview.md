# Overview — how egresslock works

This page answers: **"how does it work, what does it enforce, and
what does it not do?"** The normative security source of truth is the
[threat model](threat-model.md); this page summarizes and explains.

## The problem it addresses

Untrusted workloads need to fetch code, packages, and APIs, but giving them
ordinary network access also gives them a way to scan private services,
contact arbitrary destinations, or bypass an operator's intended policy.
Proxy environment variables are not an enforcement boundary: a workload can
unset them and attempt a direct connection. The boundary must therefore sit
outside the workload, in the network namespace through which its packets are
forwarded.

With a `gateway-only` profile, egresslock makes that boundary explicit: the
workload can reach the gateway's intended proxy port, while the profile's
terminal drop rejects direct internet and LAN traffic. Omitting or changing
`HTTP_PROXY` does not create an alternate egress path. HTTP/HTTPS traffic must
use the configured gateway unless the profile explicitly permits a direct
connection. Profiles may also define explicit direct-access rules, such as
`allow-host`, for protocols that are not routed through the HTTP gateway,
including SSH. These rules are part of the profile policy, are visible to the
operator, and are enforced independently of proxy environment variables.

## Egress containment, not complete workload containment

> Given these deployment assumptions, egresslock controls outbound network
> reachability.

The claim is about egress containment, not arbitrary workload behavior. The
operator must ensure that:

- the workload runs in a rootless container under the dedicated account;
- it has no Podman socket or equivalent control socket mounted into it;
- it does not use host networking or a second network namespace, and it has
  one policy network only: the intended egresslock profile (see
  [network modes](who-runs-what.md#network-modes-the-kit-assumes));
- no unapproved additional network attachment is present;
- it does not receive added capabilities such as `CAP_NET_ADMIN` (the
  operator's launcher drops all capabilities and sets `no-new-privileges`;
  the kit ships no workload launcher, so this is an operator obligation);
- bind mounts are controlled so the workload cannot read or modify the
  account's policy, kit files, credentials, or other host-sensitive data;
- IPv4 and IPv6 are both considered: this release governs IPv4 policy and
  drops forwarded IPv6 rather than providing IPv6 egress;
- the gateway exposes only its intended proxy interface and port, and the
  host's network path is not independently granting a bypass.

Under these assumptions, a `gateway-only` workload has no direct route around
the gateway. This is not a sandbox, host isolation, or a general-purpose
multi-tenant boundary. Same-profile peers share L2, and an explicit
`allow-host` direct-access rule authorizes a separate nftables-enforced path
for protocols the HTTP gateway does not handle. The full list is in the
[Non-goals section of the threat model](threat-model.md#non-goals--accepted-risks).

## Architecture

```
workload container
                          (agent / CI / build)
                                   │
                                   ▼
                         rootless profile network
                              DEFAULT: DENY
                                   │
                       ┌───────────┴───────────┐
                       │                       │
                       ▼                       ▼
                explicit direct          Squid gateway
                    allows                 HTTP / HTTPS
                e.g. Git SSH                   │
                       │                       │
                       ▼                       ▼
                 allowed service         allowed hosts
                                               │
                                               ▼
                                            Internet
```

EgressLock runs outside the workload container. The workload cannot gain
network access merely by ignoring proxy settings; its rootless Podman network
is fail-closed, and only explicitly configured paths are available.

For a gateway-only profile, the right-hand path is the only outbound path for
destinations not covered by an explicitly configured direct rule. The workload
may connect to the gateway's proxy port, but the nftables chain drops direct
connections. The gateway's own egress is separately permitted so it can
resolve and connect to an allowlisted destination. `allow-host` is an explicit
non-HTTP/direct-access rule; `public-only` is a separate profile mode, not a
gateway bypass accidentally created by proxy configuration.

## Where enforcement happens

```
Linux host
┌───────────────────────────────────────────────────────────────┐
│                                                               │
│  user account                                                 │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ workload container network namespace                    │  │
│  │                                                         │  │
│  │                  untrusted workload                     │  │
│  └───────────────────────────┬─────────────────────────────┘  │
│                              │ veth                           │
│                              ▼                                │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ account's rootless network namespace                    │  │
│  │                                                         │  │
│  │  ┌───────────────────────────────────────────────────┐  │  │
│  │  │ profile bridge                                    │  │  │
│  │  └─────────────────────────┬─────────────────────────┘  │  │
│  │                            │                            │  │
│  │               ┌────────────┴────────────┐               │  │
│  │               │                         │               │  │
│  │               ▼                         ▼               │  │
│  │  ┌────────────────────────┐  ┌────────────────────────┐ │  │
│  │  │ explicit direct path   │  │ Squid gateway path     │ │  │
│  │  │                        │  │                        │ │  │
│  │  │ e.g. allowed Git SSH   │  │ allowed HTTP/HTTPS     │ │  │
│  │  └────────────┬───────────┘  └────────────┬───────────┘ │  │
│  │               │                           │             │  │
│  │               └─────────────┬─────────────┘             │  │
│  │                             ▼                           │  │
│  │  ┌───────────────────────────────────────────────────┐  │  │
│  │  │ nftables enforcement                              │  │  │
│  │  │                                                   │  │  │
│  │  │ fail closed · profile policy · IPv6 denied        │  │  │
│  │  └─────────────────────────┬─────────────────────────┘  │  │
│  │                            ▼                            │  │
│  │  ┌───────────────────────────────────────────────────┐  │  │
│  │  │ rootless network exit                             │  │  │
│  │  └─────────────────────────┬─────────────────────────┘  │  │
│  └────────────────────────────┼────────────────────────────┘  │
│                               │ pasta                         │
│                               ▼                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ host network namespace                                  │  │
│  └───────────────────────────┬─────────────────────────────┘  │
│                              │                                │
└──────────────────────────────┼────────────────────────────────┘
                               ▼
                       external networks
```

Enforcement happens in nftables inside the account's rootless network
namespace, not inside the workload and not in proxy environment variables.
The profile chain is scoped to that profile's subnet and ends in a drop. A
separate shared chain drops all forwarded IPv6. The gateway is started inside
the same profile network; workload addresses can reach only the intended
bridge DNS service and gateway proxy port, while the gateway's own source
address is permitted to reach its upstream destinations.

`ensure` creates or validates the bridge network, starts the anchor (and the
gateway when configured), installs the policy, and verifies the result. The
shipped daemon launcher (`egresslock-start`) refuses to start the daemon
unless `ensure` succeeds. `verify` compares the live nftables chain with the
expected policy;
the timer repeats that check for drift.

## Fail-open vs fail-closed

The safety default is no usable egress, not best-effort connectivity:

- missing, unreadable, invalid, or contradictory profile policy is rejected;
- an unhealthy rootless network, gateway, or nftables installation makes
  `ensure` fail, the shipped daemon launcher does not start, and the
  operator's launcher must not start workloads;
- the profile's terminal IPv4 drop rejects direct traffic not covered by an
  explicit rule;
- forwarded IPv6 is dropped because this release does not provide IPv6
  egress;
- an empty gateway allowlist denies every HTTP(S) destination at the proxy;
- proxy variables are convenience wiring only. Removing them does not bypass
  nftables, and setting them does not grant access outside the policy;
- DNS drift is reported by `verify` rather than silently repaired. Re-run
  `ensure` to resolve and install fresh direct-address pins.

The gateway allowlist controls HTTP(S) requests by hostname. Direct
`allow-host` rules are intentionally outside that proxy path and are enforced
as pinned IPv4 address-and-port rules by nftables.

## Security model summary

The operator-facing threat model — the asset, the attackers, the
trusted computing base, the invariants, the non-goals, and the attacks
table — is the [threat model](threat-model.md) and is the single
source of truth for security claims. The subsections below only
summarize it.

### Trust assumptions

The kit assumes the host kernel's unprivileged user/network namespaces
work (podman, pasta, nftables present), the account is dedicated and
unprivileged, and the root-owned kit binaries are what root says they
are (tool integrity, not a policy boundary). Workloads must be launched
with capabilities dropped — the kit ships no workload launcher, so this is
the operator's launcher's job (`--cap-drop=all
--security-opt=no-new-privileges`; plain `podman run` does not). The kit
enforces that pair only on the gateway container it builds. Details:
[threat model](threat-model.md).

### Root/rootless expectations

- One or more dedicated unprivileged `<account>` to own the policies
  (the kit never runs policy jobs as root).
- No root daemon; the engine drives `podman`/`nft` inside the
  account's rootless netns.
- Root only distributes the kit and creates the per-account verify
  timers (the 15-minute drift checks).

### Namespace / network boundary

- Each account runs its own rootless Podman store and its own netns;
  accounts cannot see or affect each other's networks.
- An `egresslock-anchor-<profile>` container keeps the netns (and therefore
  the policy) alive between workloads.
- Policy config and allowlists live in the account's home and are
  never mounted into workload containers.

### DNS handling

DNS drift is a *signal*, never an auto-fix: `ensure` re-resolves and
re-installs; `verify` only warns. On the wire, the gateway resolves
allowlisted destinations itself (the profile pins the static gateway
IP inside the subnet).

### Limitations

Scoped to the dated dogfood captures in the
[threat model](threat-model.md#version-matrix) — not a claim about
"any rootless Podman". The big ones:

- same-profile L2 stays open (peers on one profile network can reach
  each other and the gateway's proxy port directly);
- IPv4-only — forwarded IPv6 is dropped, not proxied;
- `public-only` drops exactly RFC1918, link-local, multicast, and
  broadcast — not loopback, CGNAT, or other special-use ranges;
- an allowlisted hostname that re-resolves to a private address is
  connected *through the proxy* (open by design), and
  `allow-host` pins drift with DNS until the next `ensure`.
