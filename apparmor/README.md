# AppArmor amendment: let podman SIGTERM its pasta helper

Podman reclaims the shared rootless netns by
signaling its holder (`pasta`) with SIGTERM. On **affected** hosts —
pasta enforced **and** podman running under an AppArmor label (any
profile mode; Ubuntu >= 25.10 by default — see the
[affected-OS matrix](../docs/troubleshooting/pasta-apparmor.md#affected-os--stack-matrix-snapshot-verified-2026-09-10))
— the enforce-mode pasta profile denies
`signal (receive) signal=term peer=podman`, so every shared-netns
operation (`ensure`/`verify`, or a bare `podman unshare
--rootless-netns true`) fails with podman's cryptic:

```
Error: rootless netns: kill network process: permission denied
```

On unaffected hosts (stock Debian, noble, Fedora/RHEL, ...) the
denial cannot fire; the amendment is harmless there and applied
anyway as future-proofing — a label can return (Debian removed its
stub podman profile once; the upstream stub still exists).
`egresslock-setup --apparmor-check` tells you which case your host
is in.

## Why this file

It is the one-rule amendment (`usr.bin.pasta.local`). It keeps the
profile **enforced** — only the signal is widened, nothing else. Do
NOT `aa-complain /usr/bin/pasta` unless you accept logging every
pasta denial (whole profile becomes log-only).

`install-kit.sh` deliberately does NOT touch `/etc/apparmor.d` (root,
distro-owned policy). This directory is shipped with the kit as the
provided artifact; you apply it once per host, as root.

## Apply — use egresslock-setup (preferred)

Confirm the blocker is really this denial first (as root):

```sh
sudo journalctl -k -b | grep -i "apparmor.*pasta"
# apparmor="DENIED" operation="signal" profile="pasta"
#   requested_mask="receive" denied_mask="receive" signal=term peer="podman"
sudo aa-status | awk '/profiles are in enforce mode/{s=1} /profiles are in complain mode/{s=0} s && /pasta/'   # profile is ENFORCED
```

```sh
sudo /opt/egresslock/egresslock-setup --apparmor-add
#   (.deb hosts: sudo egresslock-setup --apparmor-add)
```

The profile file is **distro-dependent**: it may be
`/etc/apparmor.d/usr.bin.pasta` (older apparmor packaging) or
`/etc/apparmor.d/pasta` — never assume the path exists. The setup
**resolves** the profile file (first existing candidate that mentions
`/usr/bin/pasta`), determines **which local include that profile
names** (`local/usr.bin.pasta` or `local/pasta`), and writes the rule
into that. It refuses (rc 1, nothing written) only if no profile file
exists. It **never appends the rule to the distro profile directly**.

A stock host whose profile file has **no** local include
(`#include <local/...>`) is handled automatically: setup adds a
marked `egresslock compatibility patch` include into the profile (the
profile file is backed up to a **leading-dot** `.usr.bin.pasta.
egresslock-bak` beside it first — directory load skips dot files, so
the backup can never be compiled as a second pasta profile)
so the rule actually loads, then reloads. `--apparmor-remove` strips
exactly that patch and drops the backup. This is the difference from
the older behavior, which refused on include-less profiles and
silently wrote a rule that never loaded (an unreferenced
local fragment loads nothing, yet `apparmor_parser -r` exits 0).

**dpkg prompt / upgrades:** the compatibility patch edits
the pasta profile conffile, so the next `pasta` package upgrade will
flag `/etc/apparmor.d/usr.bin.pasta` (or `pasta`) as locally modified
and prompt you (or, with unattended-upgrades / `force-confnew`, may
silently take the new file and drop the include). Keep the local
include when prompted, or re-run `sudo egresslock-setup --apparmor-add`
after the upgrade; `egresslock-setup --apparmor-check` reports the gap.

The rule is applied **append-only** and **marker-scoped**:
it lands between `# begin egresslock-setup --apparmor` and
`# end egresslock-setup --apparmor` markers inside the resolved local
include, so it can later be removed without touching operator lines.
Idempotent; reloads the profile with `apparmor_parser -r`, then
verifies the rule is actually present in the **loaded** profile
(`apparmor_parser -p`) — parser rc
alone proves nothing. On success the setup prints a confirm line:

```
AppArmor: pasta profile reloaded (<path>); as the account, confirm:
podman unshare --rootless-netns true
```

Diagnose the amendment state (read-only, no root needed) with
`egresslock-setup --apparmor-check`; it reports
`AppArmor: enabled|not enabled` and `pasta enforcement:
enforced|NOT enforced|unknown|n/a` on two lines, then the podman
label tri-state and the amendment verdict (`podman label:
labeled|unlabeled|unknown` — any mode counts as labeled, the label
not the mode is the discriminator — and `pasta amendment: needed|
not needed on this host (...)|condition unknown (verify: podman
unshare --rootless-netns true as the account)`; an UNKNOWN listing
never produces a "not needed" claim), then `pasta profile: found`,
`pasta local extension: present (stock) / present (egresslock) /
MISSING` (the wiring line carries ownership — the old
separate `egresslock compatibility patch:` line is dropped), and
`egresslock rule in local file: absent / present (stock) /
present (egresslock)`
(absent is healthy — rc 0 — only on a KNOWN not-needed host),
exiting nonzero when a required element is missing. (The enforce
state is read from the kernel `/sys/kernel/security/apparmor/
profiles` listing, which is root-only on some hosts — non-root there
reports `pasta enforcement: unknown`, never a false `NOT enforced`.)

If the resolved profile file is missing (e.g. an admin-deleted
conffile), plain `apt install --reinstall pasta` does NOT restore it;
reinstall with force-confmiss:

```sh
sudo apt-get install --reinstall -o Dpkg::Options::="--force-confmiss" pasta
```

Manual apply (no setup available) — **append, never overwrite** the
local file (it is an apparmor conffile that may hold other rules).
Find the profile file first (often `usr.bin.pasta`, may be `pasta`),
then the local include it references:

```sh
ls /etc/apparmor.d | grep -i pasta                         # which profile file exists?
grep -l 'local/pasta\|local/usr.bin.pasta' /etc/apparmor.d/usr.bin.pasta /etc/apparmor.d/pasta 2>/dev/null
# then append to THAT local file, e.g.:
{ echo ""; echo "# begin egresslock-setup --apparmor (manual)"; cat usr.bin.pasta.local; echo "# end egresslock-setup --apparmor (manual)"; } \
    | sudo tee -a /etc/apparmor.d/local/usr.bin.pasta >/dev/null   # or .../pasta
sudo apparmor_parser -r /etc/apparmor.d/usr.bin.pasta   # reload the PROFILE FILE (or .../pasta)
# (marker-scoped: `egresslock-setup --apparmor-remove` strips any
#  block between the begin/end markers, manual ones included)
```

## Unapply / revert

Preferred — marker-scoped, keeps operator lines, never deletes the
file:

```sh
sudo /opt/egresslock/egresslock-setup --apparmor-remove
#   (.deb hosts: sudo egresslock-setup --apparmor-remove)
```

`--apparmor-remove` strips the marker block from the **resolved local include**
(either `local/usr.bin.pasta` or `local/pasta` — whichever the profile
names) plus the legacy `local/usr.bin.pasta` path, and stays rc 0 with
a `NOT reloaded` warning when the profile file is missing (unapply is
file cleanup; it must not fail closed on a missing distro
profile).

Run this BEFORE uninstalling (or from any checkout copy afterwards —
it needs no shipped snippet). An unmarked
`signal (receive) ... peer=podman` rule (no egresslock markers) is never
removed automatically; edit the file by hand in that case. **Never
`rm` the local file** — it is a distro conffile and may hold other
rules.

After removal the profile is still **enforced** — only the widened
signal is gone, so a shared-netns `ensure` will fail again until the
rule is back (that is the point of unapply).

Alternate but less secure workaround for a quick unblock: `sudo
aa-complain /usr/bin/pasta` (logs every pasta denial; the whole
profile becomes log-only). The amendment above is the primary fix. The
box workaround before this ticket was exactly that; reverse it with
`sudo aa-enforce /usr/bin/pasta` once the amendment is in place.
