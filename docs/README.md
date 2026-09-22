# egresslock docs — organization and map

Four tiers. Every doc belongs to exactly one; when you add content,
use the placement decision list at the bottom.

## The tiers

| Tier | Answers | Lives in |
|---|---|---|
| **Quick start guides** | "How do I do X?" — brief, task-oriented recipes | `docs/quickstart/` |
| **Setup** | "How do I install/upgrade/uninstall the kit and accounts?" | `docs/setup/` |
| **Reference** | "How does it work? What are the details?" — explanations, tables, catalogs | `docs/reference/` |
| **Troubleshooting** | "I'm facing X — what now?" | `docs/troubleshooting.md` (symptom index) + `docs/troubleshooting/` (one page per issue) |

Recipes (worked end-to-end examples) live in `examples/recipes/` and
keep their own tier.

## Placement decision list

1. Is it a task completable in ~5 minutes, step by step? →
   **quickstart**. Keep it brief; link to reference for the why.
2. Is it install/upgrade/uninstall/account-bootstrap procedure? →
   **setup**.
3. Is it an explanation, a lookup table, a catalog, or a model? →
   **reference**. One page per question a reader asks; each page opens
   by stating the question it answers.
4. Is it a failure mode someone hits? → **troubleshooting**: add one
   row to the index (`docs/troubleshooting.md`) and one page under
   `docs/troubleshooting/` titled BY the symptom (Symptom / Cause /
   Fix / Links). The index is the only entry point — no duplicated
   prose there.
5. Is it a worked end-to-end example for a concrete use case? →
   **recipes** (`examples/recipes/`).
6. Is it maintainer publish/review gates (not a user how-to)? →
   `docs/RELEASE_CHECKLIST.md` (repo-root of `docs/`, not a tier).

## The map

```
docs/
  README.md              this file
  quickstart/
    create-a-profile.md      profile conf + allowlist pair, init/ensure
    allow-a-domain.md        the 403 -> allow -> confirm loop
    grow-the-policy.md       allow/allow-host flows, removal
    allow-non-http.md        allow-host recipes (git-over-SSH example,
                             raw IPs, same-host pointer)
    reach-a-host-service.md  reach a service on the host (localhost):
                             the two supported patterns + the
                             pasta-hairpin trap
    first-run-checks.md      brief checks right after initial setup
    test-your-container.md   prove the policy allows and blocks as expected
  setup/
    install.md               kit install, account setup, host validation
    upgrade.md               upgrade procedure + checks
    uninstall.md             teardown + kit removal
  RELEASE_CHECKLIST.md       maintainer publish gates + review depth
                             (not a how-to; not troubleshooting)
  reference/
    overview.md              how it works: problem, architecture,
                             fail-closed behavior, security summary
    who-runs-what.md         root / account / inside-container: who runs what
    policy-reference.md      conf grammar, allowlist format,
                             destination -> mechanism decision table
    paths-and-signatures.md  two-path model, failure signatures,
                             counters, same-host pasta patterns
    proxy-clients.md         pointing proxy-unaware tools at the gateway;
                             what the six proxy vars are for
    check-everything.md      full per-layer health/inspection catalog
    scripts-and-environment.md  engine env overrides, config resolution,
                             unit.env, script defaults
    threat-model.md          assets, boundaries, threats, accepted risks
  troubleshooting.md         symptom index (ONLY entry point)
  troubleshooting/           one page per issue:
    which-check.md               which doctor/check command answers which
                                 question (four commands, four layers)
    pasta-apparmor.md            kill network process: permission denied
    session-tangles.md           pause process / migrate / degraded session
    proxied-or-direct.md         403 vs hang vs instant refusal
    netns-inspection.md          shared netns inspection; root-run leak
    gateway-logs.md              Squid access.log / cache.log / denied
    verify-timer-signals.md      verified / FAILED / drift lines
    network-not-found.md         unable to find network ... network not found
```

Component-local docs stay beside their component (`apparmor/README.md`,
`packaging/README.md`, `gateway/`). The root [README](../README.md) is
the front door: Quick start guides, Recipes, Reference, and the
troubleshooting entrance.
