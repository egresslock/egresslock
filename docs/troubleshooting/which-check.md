# Which doctor/check do I run? (four commands, four questions)

## Symptom

You want to check that egresslock is healthy — but there are four
check commands (`egresslock doctor`, `egresslock-setup doctor`,
`egresslock-setup apparmor check`, `egresslock verify`) and it is
not obvious which one answers your question.

## Cause

The four commands probe four different layers, and none of them
subsumes another:

1. **Host env** — can this machine run rootless Podman + nft at all?
2. **Kit / account wiring** — is the kit installed and this account
   wired up (conf, timer, linger)?
3. **Pasta AppArmor** — does this host need (and have) the pasta
   signal patch?
4. **Profile runtime** — is this account's policy actually live?

Running the wrong one gives a green result that says nothing about
the layer you were worried about (or a red one that was never your
problem).

## Fix

Pick the row that matches the question you actually have:

| Layer | Question | Command | Verdict / exit |
|---|---|---|---|
| Host env | Can this machine run rootless Podman + nft? | `egresslock doctor` | rc 1 |
| Kit / account wiring | Is the kit installed and this account wired? | `egresslock-setup doctor [ACCOUNT]` | rc 1 |
| Pasta AppArmor | Need/have the pasta signal patch? | `egresslock-setup apparmor check` | `CHECK OK` → rc 0; `CHECK FAILED`/`CHECK UNKNOWN` → rc 1 |
| Profile runtime | Is this account's policy live? | `egresslock ensure` / `verify` | rc 1 (fail-closed) |

rc 1 = act or re-check: it never means "healthy with a warning".

`egresslock doctor` also carries labeled advisory lines; advisories
never change its exit code. The ones worth knowing by name:

- `rebuild:` — the gateway image predates the kit's security rebuild
  floor or is more than 30 days old. Remedy in
  [The gateway image](../reference/gateway-image.md).
- `running gateway:` — profiles whose running gateway container's
  image ID differs from the tagged image (silent when none do;
  `UNKNOWN` when the comparison cannot be read).
- `podman_cve:` — one line per advisory matching the installed Podman
  version; advisory only ("prefer a fixed release"). The threat
  model's CVE note owns the ranges and the current advisory set.
- `workloads:` — launch-obligation findings for this account's running
  containers; printed only with `egresslock doctor --workloads` (bare
  doctor prints `workloads: skipped (not requested; run: egresslock
  doctor --workloads)`). It is a best-effort read of what is running
  now, not a check of your next launch.
- `conf:` — one row per leftover retired `rule gateway-only` conf
  line, naming the file and line: the line is ignored at load and has
  no effect, so ignore it or delete it (no `ensure` is needed).

The remaining rows (network backend, rootless netns, egl-base image)
are self-describing.

All four exit nonzero when something is missing, so "rc 0" is the
shared green signal. For the runtime layer, `verify <profile>` is the
read-only check — if it reports a missing network, that profile was
never ensured: run `egresslock ensure PROFILE` as the account.

A healthy setup passes all four in order: host env first (nothing
else can run without it), then kit wiring, then AppArmor (only on
affected hosts), then runtime.

## Links

- [first-run-checks](../quickstart/first-run-checks.md) — brief
  post-setup run-through of the same layers.
- [check-everything](../reference/check-everything.md) — the full
  per-layer health/inspection catalog.
- When a check is green but clients still fail, it is a traffic
  problem, not a wiring problem: start at the
  [symptom index](../troubleshooting.md) (a common one:
  [proxied-or-direct](proxied-or-direct.md)).