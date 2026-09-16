# Release checklist

egresslock is a security-sensitive networking tool. A release is a
**file-allowlist snapshot** of product files (no git history, no
process tickets). Review it against the primary invariant:

> A workload on a profile network must not reach destinations outside
> that profile's nftables policy and (on a gateway profile, for HTTP(S))
> the Squid allowlist.

Read the [threat model](reference/threat-model.md) first. Documented
accepted risks (same-profile L2, `public-only` drop set, allowlisted
name rebind through the gateway, not a sandbox) are **not** release
blockers unless the behavior is worse than documented.

This page is the public gates list. It is not a pentest claim.

## Review depth

Review depth is chosen from the **product delta since the last full
review** (the last published snapshot's review), not from the version
number alone:

* **Full review** — the initial public release; any later cut whose
  product delta touches core enforcement, parsing, privilege
  boundaries, gateway policy, DNS behavior, packaging security, or
  other trust-boundary code; or a major version. Instrument:
  `internal_docs/PRE_RELEASE_REVIEW_INSTRUCTIONS.md` (private; the
  brief below under "Review areas" summarizes its shape).
* **Focused review** — point/patch releases **and** 0.x snapshot
  refreshes whose product delta does **not** hit that list. Inspect
  the diff and the security boundaries it touches; re-run the publish
  gates; do not re-execute the full 17-section brief unless a finding
  forces escalation. A focused cut may rely on the last full review
  for untouched surfaces, and says so on its release ticket.
* **Escalate to full** whenever the change set hits the list above,
  regardless of version number.

This tree does **not** ship a workload launcher. Missing
`--cap-drop=all` on an operator's `podman run` is an operator
obligation; the kit-built **gateway** must drop capabilities.

## Publish gates

All of these must hold on the snapshot tree (not the private
development history):

- [ ] `bash tests/run.sh` is green on the snapshot sources.
- [ ] `LICENSE` is Apache-2.0; README License section points at it.
- [ ] `SECURITY.md` exists and names a private reporting channel;
      README links it. Public issues are not the security path.
- [ ] Threat model matches the tree: no site launchers, accepted
      risks stated, no claim of sandbox or “any rootless Podman”.
- [ ] README and setup docs match CLI names:
      `egresslock-setup --apparmor-check` (AppArmor),
      `egresslock-setup --doctor` (kit/account state),
      `egresslock doctor` (host environment), if those commands exist
      at this tag.
- [ ] Snapshot contains no process tickets, no internal maintainer
      briefs, no fleet hostnames/IPs/accounts. Fleet-fact grep on the
      staged tree is empty.
- [ ] Examples use only publishable names (RFC 5737 / `example.test`
      / public registries), never site destinations.
- [ ] `.deb` / prefix / tarball do not co-install; uninstall does
      not delete `~/.config/egresslock`; AppArmor is not applied in
      `postinst`.
- [ ] Full or focused review (below) ended **READY** or **READY WITH
      MINOR FIXES**, with blockers fixed or explicitly deferred in
      the threat model.

## Review areas (full review)

Confirm fail-closed policy. Ordinary workloads must not obtain
general egress by ignoring proxy env, using raw sockets, talking
direct IPs the profile did not allow, using another DNS resolver,
using IPv6, attaching another network, hitting extra gateway ports,
or changing nft/routes with capabilities the kit leaves available.
Same-bridge L2 to siblings is accepted (threat model), not a bypass.

Also cover: nftables generation and lifecycle (failed install must
not open traffic); profile/allowlist parsing as hostile input
(injection into shell/nft/Squid); privilege split (root distributes,
account executes; no NOPASSWD); gateway cap-drop and CONNECT policy;
DNS pin vs `verify` drift-warn; AppArmor pasta amendment (narrow,
conditional, removable, `--apparmor-check`); both install channels;
ShellCheck plus a manual pass on profile-fed commands; docs vs
implementation; secrets/hygiene on the **snapshot file set**.

Gateway and install failures should preserve or reduce connectivity,
never silently broaden it.

## Finding classes

* **BLOCKER** — undocumented path around the invariant, unsafe
  install/remove, secrets in the snapshot, or a security-model lie.
* **HIGH** — fix before announcing unless the threat model already
  accepts it.
* **MEDIUM** — acceptable for an early `0.x` if documented.
* **LOW** — polish.
* **FUTURE** — enhancement; not a delay.

Do not turn feature requests into blockers.

## Release decision

* **READY**
* **READY WITH MINOR FIXES**
* **NOT READY**
