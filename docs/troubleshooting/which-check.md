# Which doctor/check do I run? (four commands, four questions)

## Symptom

You want to check that egresslock is healthy — but there are four
check commands (`egresslock doctor`, `egresslock-setup --doctor`,
`egresslock-setup --apparmor-check`, `egresslock verify`) and it is
not obvious which one answers your question.

## Cause

The four commands probe four different layers, and none of them
subsumes another:

1. **Host env** — can this machine run rootless Podman + nft at all?
2. **Kit / account wiring** — is the kit installed and this account
   wired up (conf, unit.env, timer, linger)?
3. **Pasta AppArmor** — does this host need (and have) the pasta
   signal patch?
4. **Profile runtime** — is this account's policy actually live?

Running the wrong one gives a green result that says nothing about
the layer you were worried about (or a red one that was never your
problem).

## Fix

Pick the row that matches the question you actually have:

| Layer | Question | Command | Missing → |
|---|---|---|---|
| Host env | Can this machine run rootless Podman + nft? | `egresslock doctor` | rc 1 |
| Kit / account wiring | Is the kit installed and this account wired? | `egresslock-setup --doctor [--account]` | rc 1 |
| Pasta AppArmor | Need/have the pasta signal patch? | `egresslock-setup --apparmor-check` | rc 1 |
| Profile runtime | Is this account's policy live? | `egresslock ensure` / `verify` | rc 1 (fail-closed) |

All four exit nonzero when something is missing, so "rc 0" is the
shared green signal. For the runtime layer, `verify <profile>` is the
read-only check — if it reports a missing network, that profile was
never ensured: run `egresslock ensure <profile>` as the account.

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