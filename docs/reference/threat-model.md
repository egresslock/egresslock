# Threat model

What this kit protects, from whom, what it assumes, and what an attacker
should expect when it fails. This page is the single source of truth for
the security claims; the
[security model summary](overview.md#security-model-summary) is the
short version (the README links both).

Every row in the [attacks table](#attacks-table) carries an honest
status: `lab-verified` (probed on a dogfood host), `code-verified`
(read in the shipped code, not probed live), `design-intent` (intended
behavior, not yet probed), `open-by-design` (a known, accepted gap),
or `retired` (the T-number is kept so lookups resolve; the attack no
longer exists because its mode was removed).
Nothing here is a pentest claim. The input paths this model assumes
(allowlist grammar, log parsing) have had a completed hardening review
and a completed input→sink review. Two live adversarial exercises have
run on throwaway accounts: the original egress-bypass exercise (no
undocumented general egress found), and the 2026-09-19 adversarial VM
probe (a co-located privileged-sibling attacker), which live-confirmed
one bypass — the source-address-keyed gateway exemption — closed on
2026-09-21 by keying that exemption on the gateway's source address
*and* its pinned MAC. The surviving residuals are recorded in the
[attacks table](#attacks-table) and
[accepted risks](#non-goals--accepted-risks). Neither exercise was a
pentest.

Last reviewed: 2026-11-19. The claims below are scoped to the dogfood
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

    explicit exceptions (every profile):
      * established / related
      * DNS -> bridge-ip:53
      * allow-host destination pins
      * daddr gateway-ip:proxy-port
      * saddr gateway-ip + ether saddr gateway-MAC
        (the gateway's own egress; saddr+MAC since the 2026-09-21
        anti-spoof fix — the address alone no longer matches)
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

Picture is the **gateway** forward path. A1↔A2 on the
bridge is L2 (T7), not this hook.

Two consequences follow from where the chain sits:

- The host netns only sees post-NAT traffic from the account IP, so a
  host firewall cannot tell profile subnets apart and cannot police
  profile egress; it is defense-in-depth only.
- Inside the shared rootless netns, an nft `accept` is **not** final:
  any other forward-hook chain at the same or earlier priority still
  sees the packet and can drop it. `verify` fails closed on foreign
  early forward hooks (observed on-host with a stale leftover policy
  table) — but an operator-installed early drop chain remains a real
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
| A4 | a destination the operator allowlisted (a malicious or compromised SaaS/CDN), or its DNS — including a co-tenant vhost behind an allowlisted shared IP | inside the policy, not outside it; the name layer authorizes the CONNECT host, the tunnel bytes choose the SNI/Host the origin sees (T17) |
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
  kit always starts with `--cap-drop=all --security-opt=no-new-privileges`,
  refuses to start when the image carries the container-checkpoint
  annotation (CVE-2026-94603), and asserts the pair live
  (in-container `CapEff`/`NoNewPrivs`,
  read from the container's PID 1) on both kit containers at start and
  at verify;
- the engine and the account's conf/allowlist under
  `~/.config/egresslock/`: whoever controls those controls the policy;
- root-owned `/opt/egresslock` as **tool integrity** only — it stops a
  workload from rewriting the kit, but it is not a policy boundary: the
  policy is what the conf says, not where the script lives;
- the kernel's pathname resolution for the kit's own fail-closed path
  checks: when a decision depends on what a path leads to, the kernel
  decides it (`stat(2)` via `test -d`/`-ef`), not a host utility's
  interpretation; `realpath` only produces the canonical path
  `proxy-env --out` writes and prints, and a disagreement refuses
  before writing (a legitimate host-tool difference, not a hostile
  PATH — A5);

Convenience-only, **not** trusted: the `HTTP_PROXY`/`HTTPS_PROXY`
environment the operator wires into workloads. Removing it does not
open egress (the chain still drops), and setting it does not create
any (see I2).

Operator obligations the kit does not enforce:

The one-screen do / do-not index is the
[operator obligations checklist](operator-obligations.md); this list
stays the normative wording.

- launch workloads through a launcher that passes `--cap-drop=all
  --security-opt=no-new-privileges`. The kit ships no workload
  launcher (its only shipped start wrapper, `egresslock-start`, is an
  ensure-then-exec gate that starts a site daemon after `ensure`; it
  does not launch workloads): this is the operator's launcher's job,
  and examples or recipes showing a `podman run` line are
  operator-owned, not a kit guarantee. Plain `podman run` keeps the
  default capability set,
  which in the tested rootless lane (Podman 5.4.2 configured
  defaults) included neither `CAP_NET_ADMIN` nor `CAP_NET_RAW`. The
  T9 add-address technique needs `CAP_NET_ADMIN`; creating the
  tested `AF_PACKET`/`SOCK_RAW` socket under those defaults returned
  `EPERM` — version-scoped observations, not a claim about every
  Podman configuration (see the version matrix). **Flags passed are
  not flags honored**:
  (CVE-2026-94603 / GHSA-2cvf-wqm6-wr9g):
  - The hazard: on a Podman in the advisory range, restoring a
    container checkpoint restores the **dumped** configuration, not
    the launcher's — `podman run` of a checkpoint image with the
    requested `--cap-drop=all --security-opt=no-new-privileges` comes
    up with the dumped capability set (`CapEff 800405fb`,
    `NoNewPrivs 0`); the requested flags are silently discarded —
    `restore` accepts neither. Dropping capabilities is what keeps a
    workload away from `CAP_NET_ADMIN`/`CAP_NET_RAW` and the
    rootless-netns boundary (see T9), so a silently discarded drop
    makes that residual reachable with no operator-cap violation at
    all.
  - What to do: launch the workload with the pair, then `podman
    container checkpoint` it — the dump, not the launcher line, is
    the restored configuration; a container already running
    unhardened must be recreated hardened and checkpointed. Prefer a
    fixed Podman (≥ 5.8.10 / 6.2.0, or your distribution's backport —
    the newest floor covering the advisories recorded here, not a
    claim that it is the last fix for every advisory) and reject
    images carrying the checkpoint annotation — Podman provides no
    automatic rejection, so that refusal is the upstream workaround.
  - Scope of the evidence: the trigger is live-observed in the kit's
    VM lane (guest Podman 5.4.2, in the advisory range) — `podman
    run` on a benign image carrying the annotation
    `io.podman.annotations.checkpoint.runtime.name` is interpreted as
    a container checkpoint and fails at the restore import; the
    end state above is measured in the same lab on a rootful podman
    5.4.2. The tested rootless lane refuses checkpointing
    (`checkpointing a container requires root`), and a 5.4.2
    `image save`/`load` round trip strips the checkpoint annotations —
    the kit's rootless context could not produce or receive a payload
    in the lab, so the discard is a rootful-podman workload surface.
    How far the checkpoint's own configuration reaches beyond
    capabilities and `NoNewPrivs` (e.g. network mode) remains
    unmeasured. The affected range is per the advisory
    (4.4.0–5.8.7, and 6.x before 6.1.3 — figures from the advisory;
    the fixed floor is not confirmed from this tree).
  - The kit side — the refusal on its own gateway/anchor images and
    the live pair assertion on both at `ensure` and `verify` — is a
    TCB fact, not an operator obligation (see the TCB list above); a
    workload launcher remains your obligation;
- do not bind-mount the account's home (or `~/.config/egresslock/`)
  into workloads — a launcher that does changes I5. Policy files are
  not in the workload unless the operator mounts them there;
- on **labeled-podman** hosts (podman running under an AppArmor label,
  the default on Ubuntu >= 25.10), apply the pasta AppArmor amendment
  or `ensure` fails closed: the pasta SIGTERM denial blocks the netns
  setup, so no policy is installed — a fail-closed setup error, not a
  policy bypass. Stock Debian (unlabeled podman) is unaffected. See
  [the pasta AppArmor page](../troubleshooting/pasta-apparmor.md).
- launch workloads on the **profile network only** — not with
  `--network=host`, not with `--network=container:<gateway>` (sharing
  the gateway's network namespace), and not dual-homed onto a second
  network. `--network=host` puts the workload in the account's own
  network namespace, where the profile chain's subnet-scoped rules do
  not match its packets. `--network=container:<gateway>` presents the
  gateway's own source address and pinned MAC, so the gateway-egress
  exemption matches. Either mode grants the workload raw direct egress
  past the policy with no Squid enforcement. A dual-homed container
  carries a genuine profile-subnet address on one leg, so every layer
  keys it as an ordinary workload of that profile. The kit does not
  reject these launch modes — they are operator obligations.

- **keep the host OS and kernel security-patched.** Every container —
  workload, gateway, and anchor — runs on the **host's kernel**, which
  is part of the trusted computing base above; a host may be a
  physical machine or a VM. egresslock enforces egress *inside* the
  host and cannot patch the host's OS or kernel;
  vulnerabilities in either are outside its control.

## Invariants

What `ensure`/`verify` are supposed to keep. Each maps to a row in the
attacks table or an explicit non-goal.

| ID | Invariant | If broken |
|---|---|---|
| I1 | Default drop for the profile subnet, except established/related flows, DNS to the bridge gateway `:53`, explicit `allow-host` pins, the gateway's own port, and the gateway's own egress — keyed on the gateway's source address **and** its pinned MAC since 2026-09-21 (the address alone no longer satisfies it). The gateway exemption is unscoped by destination, port, and protocol (live-confirmed 2026-11-06): the gateway's own direct TCP and UDP:53 match it — a min-privilege acceptance, not a workload path (see the gateway-egress bullet below). DNS has two paths by design: (a) workload DNS to the bridge gateway `:53`; (b) the **gateway process's own DNS**, which pasta forwards to `169.254.1.1` — i.e. the **host resolver, for any name** | direct internet or LAN reach from the workload. (b) is not a workload bypass — Squid still allowlists the proxy requests it handles — but its DNS egress is host-resolver-wide by design |
| I2 | The proxy env is not the boundary: nftables is | an operator believes unsetting the proxy stops egress, or setting it grants egress |
| I3 | On a profile with no direct rules, the gateway being down means no direct internet (nothing else is accepted) | fail-open when Squid dies |
| I4 | Forwarded IPv6 is dropped (`p_v6deny`, before Netavark) | IPv6 bypass of an IPv4-only policy |
| I5 | The conf/allowlist never enter the workload filesystem (the kit never mounts them; the operator's launcher must not bind-mount the account home or confdir) | the workload reads or edits its own policy |
| I6 | The site must `ensure`/`verify` before workloads start; a missing or stale chain means unprotected, not safe — including after reboot, when the network object survives but the netns policy does not (since 0.5.0, `verify` names this state, the timer signals it, nothing auto-repairs) | empty/stale chains, or a profile with no `p_<name>` chain at all, silently pass traffic |

## Non-goals / accepted risks

- **Not a sandbox.** A1 is assumed to escape nothing but is also not
  trusted; the kit constrains its *network*, not its code.
- **Not host isolation**, not multi-tenant hardening.
- **Same-profile L2 is open (T7):** siblings on one profile network can
  reach each other's ports and the gateway's proxy port directly.
  The same netns-internal reach crosses profiles at the bridge resolver:
  a workload on another profile can query this profile's bridge resolver
  (the subnet's `.1:53`) and read its answers — an input-path delivery
  that moves no profile-chain counter and grants no egress (accepted; the
  profile chain hooks the forward path only).
- **Single rootless account (A3/A5):** another account on the host is
  outside the model; the kit neither protects nor attacks it.
- **IPv4-only:** forwarded IPv6 is dropped, never proxied.
- **`allow-host` DNS pin drift (T13):** a pin keeps the effective
  ensure-time A set (the first 16 sorted distinct addresses —
  `DNS_SET_MAX`; a larger answer truncates with a named stderr note)
  from `ensure` time; if DNS changes (a member address appears or
  disappears), traffic still goes to the old addresses
  (and `verify` warns) until `ensure` re-pins. An established connection
  to the old address does not move with the re-pin: it keeps working
  until the connection ends (live-confirmed 2026-10-12; `verify` stays
  green — its `drift:` warning tracks the pinned address set, not live
  connections). The pin is the A set the host resolver returns for the
  name at `ensure` time, trusted with no range validation — a poisoned
  answer is pinned like any other (accepted; the account owns the
  resolver's answer and the confdir). A name that serves one
  rotating A per query (`github.com` SSH) can be pinned to one member
  at a time — never stable (a `drift:` warning whenever a cycle
  resolves another member; only the pinned member reachable); the
  literal-pool recipe replaces the pin
  ([Rotating names](rotating-names.md)).
- **Kit path is distribution, not isolation:** a root-owned install
  prefix protects the tool's integrity, nothing more.
- **Kit replacement is bound to the directory it checked, not the
  name.** `install-kit.sh`/`uninstall-kit.sh` act relative to the
  probed prefix and refuse a swap before the open; `--init-conf` never
  replaces an existing destination, and the deb builder copies into the
  keep-stage leaf it created after the same check. The actor is a
  process in the invoking account, not another account (A3/A5, above).
  What remains: capture and comparison are two syscalls, so a swap plus
  `dev:ino` reuse after delete-and-recreate is not closed; a prefix
  directory itself writable by the invoking account still lets a writer
  race the predictable `.tmp` stage names or pre-plant a link at a file
  target and receive a write; and on a filesystem without hard links
  `--init-conf` falls back to `mv -T`, keeping its check-then-rename
  window. No wider claim is made.
- **A symlink at a path we would replace is not a supported layout.**
  A command that replaces or deletes a named destination classifies it
  with `-L` first: the destination must be absent or a regular
  non-symlink file, and a directory the tool owns must be a real
  directory reached without a symlinked prefix. A symbolic link is
  refused by name, leaving the link and the file it points to untouched.
  The replacement does not follow the link, does not write the file it
  points to, and never replaces the link with a regular file. Edit the
  referent by hand while no egresslock command is running, then
  `ensure <profile>`. Only the last named path is classified:
  a symlinked *parent* directory is resolved and followed as usual (a
  confdir kept as a link still works), and reads of runtime config may
  follow a link. A hard-linked regular file is unaffected.
- **Kit root tools are interactive-root only:** no
  sudoers file is shipped and `NOPASSWD` on `install-kit.sh`,
  `uninstall-kit.sh`, or `egresslock-setup` is unsupported — their
  arguments are free-form (`--prefix`, `--account` + `runuser`,
  `--from`), so passwordless sudo on them without exact argv is
  equivalent to root. The engine itself refuses root by default (T16).
- **Gateway base is frozen by digest:** the kit-built gateway image
  pins its base and never updates in place — base-package fixes reach
  a running gateway only through a deliberate rebuild with a refreshed
  pin, and a stale image keeps the old base's vulnerabilities until
  that rebuild and replace. The pin freezes what the kit **asks for**
  — the base reference the build pulls — and the digest match is only
  as strong as the host's digest checking: on a Podman in the
  CVE-2026-111361 range (every Podman before 5.8.10, and 6.0.0–6.1.x
  before 6.2.0 — figures from the advisory) a digest can resolve to
  different layers/config, so the pin is build-input identity, not an
  absolute content guarantee. What the doctors' `gateway image:` /
  `running gateway:` rows prove (image staleness vs. running container
  identity, and why a row can still look stale after a rebuild) is in
  [What the doctor prints](gateway-image.md#what-the-doctor-prints);
  the rebuild-and-replace steps are in
  [When to rebuild the gateway image](gateway-image.md#when-to-rebuild-the-gateway-image).
- **Name rebind through the proxy (T17) is open by design:**
  the allowlist is name-based (dstdomain), names resolve at request
  time, and the gateway's own egress is exempt from the profile chain —
  so an allowlisted name that starts resolving to a private address is
  connected from the gateway's position. Live probes narrow the reach
  but do not close it: cloud metadata (`169.254.169.254`) is not
  delivered on this pasta, hosts-file rebind is not injectable from the
  gateway (non-root gateway, internal DNS), and LAN reach was
  demonstrated only through an explicit IP-literal `allow-host` pin
  (operator-intentional, nft-direct). A hostile container on the
  profile network can answer the rebind at L2 (ARP/proxy-MITM,
  demonstrated end-to-end). LAN hosts the operator meant
  to allow directly stay on the direct path; `disallow` closes the hole.
  A direct `allow-host <ip>:<port>` pin is explicit address intent — it
  authorizes that address and port on the wire, so co-tenant vhosts
  behind the pinned address and port are reachable by design. The proxy
  lane authorizes by name; when the allow decision must name the host,
  use the proxy lane.
- **Profile rules are source-scoped; cap-drop is what makes them bite
  (T9 neighbor):** the profile chain matches `ip saddr <profile subnet>`
  over a base accept policy. The probe's controls confirmed the drop
  side: an in-subnet spoof that is *not* the gateway's address is
  silently dropped by the terminal rule, and the gateway's address
  alone no longer opens anything (the exemption also requires the
  gateway's pinned MAC). What still rides the base accept is an
  **out-of-subnet source** — next bullet. Dropping capabilities on
  workloads remains the operator obligation — when the launcher's
  flags are honored, the spoof attempts above are not reachable at
  all. **Flags passed are not flags honored** (CVE-2026-94603 class;
  see the launcher obligation above and the T9 row).
- **Out-of-profile sources ride the chain's base accept (C-5/E-01
  neighbor; ruled an accepted boundary 2026-09-21):** profile chains
  are `policy accept` with `ip saddr <subnet>`-scoped rules — required
  for multi-profile coexistence in one rootless netns (every profile
  chain hooks the same forward point; a `policy drop` on one profile's
  chain would drop the other profiles' traffic too). Probed live: an
  out-of-subnet source on the profile bridge, and a workload on a
  non-profile network in the same account, both get answered
  round-trips with no profile rule involved (the out-of-subnet return
  path is typically unroutable, so this is not a working bypass).
  The ruling: **"not our traffic"** — the kit locks profile networks;
  it does not lock every network the account can create. Fencing
  unknown sources on a profile bridge would be a different design.
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
  proxy requests it handles; the queries themselves are not gated.
- **Gateway egress is unscoped by design (min-privilege acceptance):**
  the gateway's exemption from the profile chain matches its source
  address and pinned MAC on the profile bridge, with no destination,
  port, or protocol predicate — so the rule itself does not restrict
  the gateway's own traffic. Direct gateway-originated TCP and UDP:53
  matched it on 2026-11-06 (live-confirmed to a local listener); how
  far that traffic actually gets still depends on routing, pasta, and
  the host's own firewall. This is defense-in-depth, not a workload
  path: the gateway is the trusted enforcement position. Squid
  allowlists the proxy requests it handles; traffic the gateway
  originates outside Squid is not subject to that allowlist. Narrowing
  the exemption to the proxy's needs was considered and deferred: a
  too-narrow exemption fails the proxy lane closed, and per-ensure
  destination sets churn while the chain is hot.
- **Two paths, one destination, different verdicts (T18 neighbor):**
  an `allow-host` IP is an nft-direct rule, but a
  proxied HTTP(S) request to that same literal IP never reaches it —
  the only wire destination is the gateway port, and the names-only
  dstdomain allowlist denies it — unless the client's `NO_PROXY`
  carries that literal IP (derived from the IPv4 direct pin) and
  steers the request off the proxy. This is the documented two-path
  behavior, not a bypass.

- **Non-IP channels are outside the profile chain (CVE-2026-123876
  class):** the enforcement chain is IP-scoped; socket families that
  are not IP traffic — `AF_VSOCK` (VM sockets, not
  network-namespace-scoped) and `NETLINK_AUDIT` (kernel audit) — never
  traverse it. Their only layer is the container runtime's seccomp
  profile: the kit sets no `--security-opt seccomp` in any launch path
  and ships no workload launcher, so on a workload that profile is
  whatever the operator's launcher requests — `no-new-privileges` does
  not cover this layer. On the tested Debian lane, the stock profile
  (containers-common 0.62.2) has no `AF_VSOCK` deny rule: plain and
  high-bits `socket(2)` calls both succeed, so seccomp does not block
  vsock there. Its `NETLINK_AUDIT` deny was not bypassed by the
  high-bits argument in lane verification — plain and high-bits calls
  were rejected identically. Newer profiles (forky's 0.67.1) add an
  `AF_VSOCK` deny for container-escape prevention, outside this model
  (see [Scope](#scope)); on the same lane that rule rejected the
  high-bits call exactly as the plain one, so that bypass did not
  manifest in lane verification. Upstream fixed the
  family comparison in containers-common 0.70.0.
  Accepted: the kit's promise is the workload's **IP egress** surface;
  where you rely on the seccomp layer, prefer a fixed containers-common
  / Podman (or your distribution's backport).

## Attacks table

Hang = nft drop, no Squid log line. 403 = Squid policy denial
(`denied` can list it). A direct-path IPv4 TCP drop is also recorded in
a bounded, expiring per-profile set that `denied PROFILE --direct`
lists as IP:port — plain `denied` still reads only the Squid log.
Other protocols are not permitted for workload egress (DNS `:53` to
the bridge gateway excepted), so UDP/ICMP are dropped, not merely
unlisted; anti-spoof and IPv6 drops are not recorded. 503 = allowed
but destination dead. CONNECT deny may show as curl `000` with 403 in
the error line.

| # | Attacker action | Expected behavior | Operator sees | Status |
|---|---|---|---|---|
| T1 | `curl https://evil.test` with proxy env, host not allowlisted | Squid CONNECT deny | `denied` lists `evil.test`; 403 | lab-verified |
| T2 | Same without proxy env (direct SYN to 443) — any proxy-ignoring client, e.g. `curl --noproxy '*'` or bash `exec 3<>/dev/tcp/<host>/<port>`; `/dev/tcp` is a bash socket, not a device | nft drop | hang; **not** in the proxy `denied` list — `denied --direct` lists the IPv4 TCP destination when the bounded, expiring record holds it | lab-verified |
| T3 | `curl http://deb.example/` (port 80) not allowlisted | Squid GET deny | `denied` lists `deb.example:80`; 403 | lab-verified |
| T4 | `allow` of T3's host **without** `:80` | still denied on 80 (no-port group is 443) | `denied` still shows `:80` | design-intent |
| T5 | UDP/TCP to 8.8.8.8:53; DoT 853; direct DoH 443 — bash `exec 3<>/dev/udp/<host>/<port>` is the same direct UDP path (ordinary UDP socket) | drop (DNS only to bridge gw) | hang; no gateway log (UDP/ICMP are dropped, not merely unrecorded) | lab-verified |
| T6 | IPv6 destination | `p_v6deny` | fail; IPv4-only kit | lab-verified |
| T7 | Sibling on same profile: connect to peer:22 | **allowed** (L2) | n/a — accepted risk | lab-verified (open L2; still accepted — 2026-09-21 ruling; the probe confirmed the strongest form: sibling↔sibling traffic never touches the IP-forward hook, it is pure L2 bridging, so *every* profile-internal port is open at L2) |
| T8 | Sibling: gateway:3128; other gateway ports; cache manager | 3128 allowed + Squid ACL; other ports: nothing listens on them — **L2 does not filter them** (a service bound on one would be sibling-reachable); mgr 403 | can probe Squid; cannot widen nft | lab-verified (framing corrected by the probe: "other ports nft-dropped" was inaccurate — see T7) |
| T9 | Co-located sibling holding `CAP_NET_ADMIN` (the live bypass also added `CAP_NET_RAW`) spoofs source IP = gateway IP (adds the gateway's address to its interface) | the kit forces cap-drop on the **gateway**; workloads are launcher policy — a sibling that holds `CAP_NET_ADMIN` can add the gateway's address and attempt the spoof, and the profile chain still sees the packet | if a spoofed `saddr GW_IP` packet is forwarded past the terminal drop, I1 is broken | lab-verified both ways. Bypass confirmed live 2026-09-19: the spoofed SYN matched the then-address-only gateway-exemption rule, `established,related` grew a full bidirectional flow, the terminal drop never moved, and the outer endpoint answered — a complete bypass. Closed for the IP-only spoof on 2026-09-21 (exemption now also requires the gateway's pinned MAC); re-probed at the fix commit: exemption counter stays 0, no new established flow, the terminal drop counts the SYN+retries, outer endpoint unreachable. **Residual (recorded, accepted):** a sibling that clones *both* the gateway's MAC and IP still matches the exemption — same cap set, same obligation; closing it needs a non-spoofable bridge-port match (out of scope). A default-caps workload cannot add the gateway's address, and the tested `AF_PACKET`/`SOCK_RAW` socket creation returned `EPERM` (version-scoped; see the launcher obligation and the version matrix). Raw packet crafting is a different technique. Cap-drop on workloads remains the operator obligation: a checkpoint annotation that discards the launcher's cap-drop on a *successful* restore (CVE-2026-94603; mechanics, range, and the recreation step above) would make this residual reachable with no operator-cap violation |
| T10 | Workload reads `~/.config/egresslock/` | not mounted by the kit; the operator's launcher is the only path in | empty of policy files unless the operator bind-mounts `$HOME` or the confdir | code-verified (kit paths) |
| T11 | `allow 'foo; rm -rf /'` | reject, exit 2, file unchanged | usage / invalid entry | code-verified |
| T12 | Gateway container stopped | no useful exemption for the workload; default drop | connect fail; `denied` may be empty | design-intent |
| T13 | `allow-host` then DNS changes | traffic still to the **old** effective A set (first 16 sorted distinct) until `ensure`; `verify` warns `drift:` on a set change | hang to new IP; `verify` rc=0 with warning | lab-verified (drift loop). E2E pin: lab-verified. A rotating single-A name (`github.com` SSH) is pinned to one member at a time — never stable; a warning whenever a cycle resolves another member, only the pinned member reachable; the literal-pool recipe replaces the pin |
| T14 | `rule public-only` (drop-set narrower than all special-use ranges) | **retired** as of 0.6.0: the mode is gone, so the risk no longer exists to accept | n/a — see CHANGELOG | retired |
| T15 | Another account's `podman network ls` | cannot see this account's nets | empty / other store | design-intent |
| T16 | Engine run as root | refuse by default | error; root's store unused | design-intent |
| T17 | CONNECT to allowlisted name that now resolves to RFC1918 | **open by design** (A4): name-based dstdomain + request-time DNS + the gateway's own egress exemption — an allowlisted **name** that starts resolving to a private address is connected from the gateway's position. Live facts narrow the reach without closing it: cloud metadata (`169.254.169.254`) is not delivered on this pasta (connection times out), hosts-file rebind is not injectable from the gateway, and LAN reach was demonstrated only via an **explicit IP-literal `allow-host` pin** — operator-intentional, not the name-rebind path (detail in the accepted-risks bullet above). The L2-attacker half is **demonstrated**: a hostile container on the profile network answered a hijacked flow via ARP/proxy-MITM (fresh-overlay re-run, 2026-09-23). LAN IPs the operator meant stay `allow-host`. **Shared-IP co-tenancy (live-confirmed 2026-11-06):** a CONNECT to an allowlisted name on a shared IP completes TLS with a co-tenant SNI, and an HTTP request with a mismatched Host is carried through the same tunnel — Squid's blind CONNECT authorizes the CONNECT name only, so the tunnel bytes choose what the origin sees (the same accepted class as the opaque-body risk, not a way past the name layer). Which vhost the origin serves for that SNI/Host is the origin's choice: the live observation covers the tunnel carrying the co-tenant SNI and mismatched Host, not a distinct tenant-vhost response. The same name-at-request-time semantics cover **gateway-tunneled non-HTTP** (e.g. SSH via a client `ProxyCommand` CONNECT — optional recipe, docs only): the SSH host-key check remains the mitigation for SSH, and `denied` does see **denied** CONNECT-tunneled traffic (an allowed tunnel shows in the gateway access.log as `TCP_TUNNEL/200`). | proxy returns the private service's body; `disallow` restores deny | open-by-design (lab-verified gap) |
| T18 | Literal `http://127.0.0.1` (or other IPv4 URL) via proxy | Squid 403 (dstdomain is names). `allow` of an IPv4 literal is rejected. Use `allow <profile> <ip>:<port> --direct` for addresses. | 403; `allow` exit 2 | lab-verified (unlisted literals); grammar: literals rejected. Since 0.5.0: 403 holds **including when the IP's PTR equals an allowlisted name** (generated dstdomain ACLs carry `-n`) |

Rows read as "what should happen", not a pentest report:
`design-intent` rows are untested; `open-by-design` rows are gaps the
model accepts on purpose; `retired` rows keep the T-number so lookups
resolve — the attack no longer exists. Nothing here is fuzz-tested.
The hardening
review of the input paths and the input→sink review are complete. Live
adversarial work has run on throwaway accounts: the original
egress-bypass exercise (no undocumented general egress found), and the
2026-09-19 adversarial VM probe, which live-confirmed the T9 spoof
bypass — closed on 2026-09-21 (see T9). The probe's T17 cases are now
live-recorded on both halves: the no-L2-attacker side (cloud metadata
not delivered on this pasta; hosts-file rebind not injectable; LAN
reach only via an explicit IP-literal `allow-host` pin —
operator-intentional, not the name-rebind path) and the L2-attacker
side (ARP/proxy-MITM demonstrated end-to-end, fresh-overlay re-run
2026-09-23). The name-rebind path itself — an allowlisted name that
starts resolving to a private address — was not live-closed; T17
remains `open-by-design` as recorded.

## Version matrix

Claims in this document were checked on these dogfood hosts. Do not
generalize them to "any rootless Podman"; re-verify after a major
podman/pasta/netavark/nftables upgrade.

| Host | Date | OS | kernel | Podman | Netavark | nftables | Squid |
|---|---|---|---|---|---|---|---|
| 1 | 2026-09-02 | Debian 13.6 | 6.12.101 | 5.4.2 | 1.14.0 | 1.1.3 | 6.x (banner 6.13) |
| 2 | 2026-09-07 | Kubuntu 26.04 | 7.0.0-31 | 5.7.0 | 1.16.1 | live nft | 6.13 (image) |
| 3 | 2026-09-11 | Debian (unlabeled podman) | not recorded | not recorded | not recorded | not recorded | not recorded |
| 4 (VM harness) | 2026-09-19 + 2026-09-21 | Debian 13 (VM) | not recorded | 5.4.2 (2026-09-21 re-run) | not recorded | 1.1.3 | image |

pasta is the rootless netns holder on all four. Host 4 is the
provisioned VM harness: the 2026-09-19 adversarial probe and the
2026-09-21 post-fix re-run ran there; the T7/T8/T9 evidence and the
C-5/E-01 characterization above are host-4-scoped.

Host 2 runs podman under an AppArmor label (AppArmor 5.0), so the pasta
amendment is required there; host 3 is stock Debian with unlabeled
podman — no podman label profile ships with Debian's apparmor package,
so the amendment does not apply and was not installed. The pasta
AppArmor amendment is not part of the accepted-risk set: where it is
missing but needed, `ensure` fails closed (see
[the pasta AppArmor page](../troubleshooting/pasta-apparmor.md)).

**nftables cross-version check (2026-11-17).** nftables 1.1.3 and 1.0.6
rendered the same ruleset with one harmless difference: the NAT
output-hook priority prints as `dstnat` on 1.0.6 and as `-100` on
1.1.3. `verify` and `doctor` stayed clean under both, a foreign chain
was still named as drift under both, and rules written by one version
read cleanly under the other. One tamper shape — an accept rule
inserted above the profile chain's final drop — went unmeasured on
both versions in that round: the handle extraction ran against the
system nft's listing and did not parse the handle there, so neither
binary was exercised against the shape. That is a probe limit, not a
missed detection.

Claims are host-scoped: `egresslock doctor` (engine subcommand) is the
per-host runtime evidence for podman/netavark/nft/unprivileged-userns —
it is not a license to generalize the matrix to "any rootless Podman".

**The Squid package and the access-log format are separate from the
image pin.** The image base is digest-pinned, but the `squid` package
is not: a rebuild can take a Squid security update. The gateway config
written by `ensure` sets `access_log` with no format option, so Squid
writes its built-in `squid` format and `denied` parses that field
order. The doctor's rebuild floor tracks the Squid security date, not
the format. A Squid update that changes the default format can make
`denied` stop recognizing new denials while enforcement is unaffected;
the raw access log still shows them. After a rebuild or kit upgrade
that changes the Squid version, confirm one known denial in the raw
log before trusting an empty `denied`.

## Related

- [Allow a domain](../quickstart/allow-a-domain.md) and
  [allow non-HTTP egress](../quickstart/allow-non-http.md) — the two
  allow mechanisms (allowlist file vs `allow-host`) this model talks
  about.
- [Troubleshooting](../troubleshooting.md) — what a miss looks like in
  practice (hang vs 403 vs 503); not duplicated here.
- Hardening — **completed**: the adversarial review of the
  input paths this model assumes (allowlist grammar under adversarial
  entries, log parsing).
- Input→sink review — **completed**: the separate input→sink review of
  the engine scripts.
- Live egress-bypass adversarial exercise — **completed**: it has run;
  no undocumented general egress found (not a pentest claim).
- Adversarial VM probe (2026-09-19) and post-fix re-run (2026-09-21) —
  **completed**: a co-located privileged sibling was live-confirmed to
  bypass the profile chain by spoofing the gateway's source address;
  the fix keys the exemption on the source address *and* the gateway's
  pinned MAC, and the re-run proves the IP-only spoof fails closed
  while the deny baseline holds.
- T17 live evidence (2026-09-19 through 2026-09-23) — **recorded**:
  the no-L2-attacker side (cloud metadata not delivered on this pasta;
  hosts-file rebind not injectable; LAN reach only via an explicit
  IP-literal `allow-host` pin) and the L2-attacker side (ARP/proxy-MITM
  demonstrated end-to-end) narrow the T17 reach without closing the
  name-rebind path; see the T17 row and the accepted-risks bullet.
- Leftover early forward-hook chains: the
  competing-chain hazard described under
  [Trust boundaries](#trust-boundaries).
