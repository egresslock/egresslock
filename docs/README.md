# egresslock docs — organization and map

Four tiers. Every doc belongs to exactly one.

## The tiers

| Tier | Answers | Lives in |
|---|---|---|
| **Quick start guides** | "How do I do X?" — brief, task-oriented recipes | `docs/quickstart/` |
| **Setup** | "How do I install/upgrade/uninstall the kit and accounts?" | `docs/setup/` |
| **Reference** | "How does it work? What are the details?" — explanations, tables, catalogs | `docs/reference/` |
| **Troubleshooting** | "I'm facing X — what now?" | `docs/troubleshooting.md` (symptom index) + `docs/troubleshooting/` (one page per issue) |

Recipes (worked end-to-end examples) live in `examples/recipes/` and
keep their own tier.

## The map

```
docs/
  README.md              this file
  quickstart/
    allow-a-domain.md        the 403 -> allow -> confirm loop
    allow-non-http.md        allow-host recipes (git-over-SSH example,
                             raw IPs) + the fail-closed proofs
    first-run-checks.md      brief checks right after initial setup
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
    container-hardening.md   podman run hardening baseline for example
                             launchers: always-on flags, keep-id /
                             read-only layers, stated exceptions
    gateway-image.md         kit-built gateway: when to rebuild,
                             stale:, recipe
    policy-reference.md      conf grammar, allowlist format,
                             destination -> mechanism decision table,
                             profile lifecycle (create / verify /
                             teardown / delete)
    paths-and-signatures.md  two-path model, failure signatures,
                             counters, same-host pasta patterns
    proxy-clients.md         pointing proxy-unaware tools at the gateway;
                             what the six proxy vars are for
    check-everything.md      full per-layer health/inspection catalog
    scripts-and-environment.md  engine env overrides, config resolution,
                             unit.env, script defaults
    files-installed.md       what the kit installs (.deb / prefix layout,
                             unit templates) + what a checkout contains
    threat-model.md          assets, boundaries, threats, accepted risks
  troubleshooting.md         symptom index (ONLY entry point)
  troubleshooting/           one page per issue:
    which-check.md               which doctor/check command answers which
                                 question (four commands, four layers)
    pasta-apparmor.md            kill network process: permission denied
    session-tangles.md           pause process / migrate / degraded session
    proxied-or-direct.md         403 vs hang vs instant refusal
    cannot-reach-host-service.md container can't reach a service on
                                 the host / localhost (pasta hairpin)
    netns-inspection.md          shared netns inspection; root-run leak
    gateway-logs.md              Squid access.log / cache.log / denied
    verify-timer-signals.md      verified / FAILED / drift lines
    network-not-found.md         unable to find network ... network not found
    after-a-reboot.md            network looks fine after a reboot but
                                 workloads are unprotected (no policy)
```

Component-local docs stay beside their component (`apparmor/README.md`,
`packaging/README.md`, `gateway/`). The root [README](../README.md) is
the front door: Quick start guides, Recipes, Reference, and the
troubleshooting entrance.
