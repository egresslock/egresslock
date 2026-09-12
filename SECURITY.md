# Security policy

How to report a security problem with egresslock privately. This file
is about reporting, not about the claims themselves — the
[threat model](docs/reference/threat-model.md) is the single source of
truth for what egresslock protects, what it does not, and which
behaviors are accepted risks.

## What to report

Please report privately:

- a bypass of an invariant stated in the
  [threat model](docs/reference/threat-model.md) (for example, direct
  egress that the profile's nftables policy should have dropped, or a
  workload reading or editing its own policy);
- behavior that is **worse than** an accepted risk the threat model
  already documents on purpose — for example beyond T7 (same-profile
  L2 is open), T14 (the `public-only` drop set is exactly the ranges
  listed there), or T17 (name rebind through the proxy). If you find
  one of those behaving exactly as documented, it is not a novel
  vulnerability — but a report explaining why a documented acceptance
  is unsafe in a way the model missed is still welcome.

If a finding only matches the documented behavior, say so in your
report; it helps the maintainer keep the threat model honest either
way.

## How to report

Use **GitHub Private Vulnerability Reporting** on this repository:

> Security and quality → Report a vulnerability

(Repository Security tab → Private vulnerability reporting.) This is
the only security channel; there is no security email address.

**Do not open a public issue or pull request that describes a
bypass.** A public report discloses the gap before the maintainer can
respond. Public issues are fine for ordinary bugs that do not weaken
the documented egress guarantees; if you are unsure which kind you
have, use the private channel.

## Supported versions

Security reports are accepted for the latest public snapshot /
current public HEAD only. There are no LTS branches and no
backport policy yet.

## Response expectations

Responses are best effort; there is no SLA. The maintainer will
acknowledge reports, investigate, and privately track a fix; you will
be credited in the eventual disclosure unless you ask otherwise.

## Safe harbor

Good-faith security research against systems you own or are
authorized to test is welcomed. Do not disrupt production systems,
access or exfiltrate data that is not yours, or test against systems
you do not have permission to probe. Reports that stay within these
bounds will be treated as lawful, good-faith research.
