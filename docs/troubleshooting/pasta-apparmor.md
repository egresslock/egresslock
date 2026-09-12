# "kill network process: permission denied" (pasta/AppArmor blocker)

## Is it this problem? (decision tree)

```text
podman unshare --rootless-netns true                # as the account
 ├─ rc 0 → not this page (see ../troubleshooting.md index)
 └─ rc != 0 ('kill network process: permission denied')?
      ├─ sudo egresslock-setup --apparmor-check
      │    ├─ "podman label: labeled" + "pasta amendment: required on
      │    │      this host"
      │    │      → apply the amendment (Fix below), then re-probe
      │    ├─ "podman label: unlabeled" / "pasta amendment: not
      │    │      required…" → NOT AppArmor — go to the session path
      │    │      (bottom)
      │    └─ "condition unknown" → re-run as root, or confirm via the
      │          journal DENIED line (Diagnosis below)
      └─ no pasta profile on the system → pasta runs unconfined; the
            SIGTERM is never mediated — session path (bottom)
```

## Symptom

`ensure`/`verify` (or a bare probe) fails with podman's cryptic:

```
Error: rootless netns: kill network process: permission denied
```

The engine's preflight message emits the one-line fix itself
(`sudo egresslock-setup --apparmor-add`); this page is the deep
diagnosis.

## Diagnosis

```sh
# 1. Reproduce with no egresslock involved:
podman unshare --rootless-netns true; echo "rc=$?"     # rc != 0 = broken

# 2. Look for the denial in the journal (as root):
sudo journalctl -k -b | grep -i "apparmor.*pasta"     # or: journalctl | grep apparmor

# Expect:
# apparmor="DENIED" operation="signal" profile="pasta" ...
#   requested_mask="receive" denied_mask="receive" signal=term peer="podman"

# 3. Confirm the profile is enforced:
sudo aa-status | grep -i pasta
```

## Cause (conditional — most hosts are NOT affected)

Podman reclaims the shared netns by signaling its holder (pasta) with
SIGTERM. The denial fires only when **both** hold:

1. **pasta is enforced** — a distro-shipped `/etc/apparmor.d/usr.bin.pasta`
   profile in enforce mode whose signal rules predate the podman
   handoff. Debian >= trixie ships it; on Ubuntu only >= 25.10 does
   (24.04 noble ships no pasta profile at all — pasta ran unconfined
   there, the SIGTERM was never mediated).
2. **podman is running under an AppArmor label (any profile mode)** —
   the sender's *label*, not the profile mode, is the discriminator: a
   `flags=(unconfined)` label profile is sufficient (confirmed on a
   labeled-podman host). Ubuntu >= 25.10 ships a podman label profile in the
   `apparmor` package; stock Debian ships none — podman is unconfined
   there, covered by the stock `signal (receive) peer=unconfined` rule.

The netns is healthy; podman just cannot talk to its holder. A
long-lived stale holder masks the bug (podman reuses the netns without
signaling) — fresh boots, `sudo -u`, systemd user timers, and CI
typically have no holder.

`egresslock-setup --apparmor-check` reports the actual state on your
host; the matrix below explains why it differs between hosts.

## Affected OS / stack matrix (snapshot, verified 2026-09-10)

| OS / stack | podman profile | pasta profile | podman default netns helper | Affected |
|---|---|---|---|---|
| Ubuntu 26.04 resolute (podman 5.7.0, apparmor 5.0) | `flags=(unconfined)` label profile (apparmor pkg) | `usr.bin.pasta` (passt pkg) | pasta (podman >= 5.0) | **yes** |
| Ubuntu 25.10 questing (podman 5.4.2, apparmor 5.0~alpha1) | same | same | pasta | **yes** |
| Ubuntu 24.04 noble (podman 4.9.3, apparmor 4.0) | same (apparmor pkg) | none (no `usr.bin.pasta` shipped) | slirp4netns (podman < 5.0) | no |
| Debian trixie (podman 5.4.2, apparmor 4.1.0) / sid (podman 5.8.6, apparmor 4.1.8) | none | `usr.bin.pasta` | pasta | no (stock) |
| Fedora / RHEL | n/a (SELinux) | n/a | pasta | no |
| openSUSE | no default label path (unverified) | ? | pasta | likely no |

The openSUSE row is **unverified** — "likely no" is a guess, not a
finding. Verification method: distro package filelists via
packages.debian.org / packages.ubuntu.com (re-verify if suites
changed since 2026-09-10).

## Upstream status — currently the only working workaround

On Ubuntu >= 25.10 the pasta-profile-side amendment is the **only
working fix** today: the promised upstream patch never landed (all
~2200 apparmor MRs searched, 2026-09-10). Track the real fix here —
this project files nothing new:

- **[LP #2154379](https://bugs.launchpad.net/bugs/2154379)** — the
  live Ubuntu bug (Confirmed): pasta SIGTERM denied from labeled
  podman. The promised apparmor-upstream pasta hat inside the podman
  label profile (2026-05-28) was never submitted. The
  `flags=(unconfined)` podman stub profile is **upstream apparmor**
  (`profiles/apparmor.d/podman`, added 2023-11 "profiles for
  applications in unconfined mode", updated 2025-10 to abi 5.0) —
  byte-identical on every distro that ships upstream profiles, not an
  Ubuntu delta.
- **[LP #2165739](https://bugs.launchpad.net/bugs/2165739)** — the
  missing `#include <local/usr.bin.pasta>` (local fragments are
  silently inert without it).
- **[LP #2077158](https://bugs.launchpad.net/bugs/2077158)** — Ubuntu
  shipped no `usr.bin.pasta` until 2026-05-28; that is why the denial
  only recently started firing on 26.04.
- **[Debian #1100135](https://bugs.debian.org/1100135)** (historical)
  — fixed 2025-03 by **removing** the stub podman profile from
  Debian's apparmor package. That is why Debian is unaffected today —
  and why a label could return anywhere: the upstream stub profile
  still exists, which is why the kit keeps shipping the amendment.

## Fix (pick one — amendment primary)

The recommended fix is the kit's own one-command apply — it resolves
the pasta **profile file** for you (the file is distro-dependent:
often `/etc/apparmor.d/usr.bin.pasta`, but it may ship as
`/etc/apparmor.d/pasta` — never assume the path exists):

```sh
sudo /opt/egresslock/egresslock-setup --apparmor-add
#   (.deb hosts: sudo egresslock-setup --apparmor-add)
# (apply notes: apparmor/README.md)
```

On a known-unlabeled host (stock Debian, Fedora/RHEL) the amendment
is a no-op — applied anyway as future-proofing; `--apparmor-check`
tells you which case you are in.

Manual (no setup available) — keep enforce but allow the signal (**the
fix**; profile stays enforced):

```sh
# Shipped snippet: apparmor/usr.bin.pasta.local
# Add "signal (receive) set=(term) peer=podman," to the profile, then reload
# THE PROFILE FILE that exists (often usr.bin.pasta; may be 'pasta'):
sudo apparmor_parser -r /etc/apparmor.d/usr.bin.pasta   # or .../pasta

# B. Alternate but less secure workaround — put pasta in complain mode
#    (denials logged, not blocked):
sudo aa-complain /usr/bin/pasta
```

If **no** pasta profile file exists (e.g. an admin-deleted conffile),
`apparmor_parser` refuses with `File ... not found, skipping...`. Plain
`apt install --reinstall pasta` does NOT restore admin-deleted
conffiles — reinstall with force-confmiss:

```sh
sudo apt-get install --reinstall -o Dpkg::Options::="--force-confmiss" pasta
```

Then re-test **as the account**: `sudo -iu <account> -- podman unshare
--rootless-netns true` must return rc=0.

Only if the AppArmor fix is not it: check the session
(`systemctl --user is-system-running`, `loginctl list-sessions`,
`/run/user/<uid>/netns/` ownership) — a
`sudo systemctl restart user@<uid>` may be needed, but WARNING: it
stops user-unit children (containers); expect `podman start
<container>` or a reboot as follow-ups (see
[session-tangles](session-tangles.md)).

## Why this matters for installs

The denial fires on the first shared-netns operation **on affected
hosts only** (matrix above): Ubuntu >= 25.10 by default. It is an
install prerequisite on those hosts, not a kit bug. The engine probes
before every netns-touching command and emits the `--apparmor-add`
guidance itself, so the first signal of a broken shared netns is
actionable; the setup check (`egresslock-setup --apparmor-check`, the
install-kit advisory line) reports whether this host needs the
amendment at all.

Report/tracking context: the original Debian-BTS report premise was
corrected — both defects were already tracked upstream (see
[Upstream status](#upstream-status--currently-the-only-working-workaround)).
