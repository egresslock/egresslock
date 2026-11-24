# How to: upgrade the kit

Upgrade the installed kit to a new build. Accounts, allowlists, and
enabled timers are not touched — no re-setup needed.

### 1. Get the new source

In the checkout (your own shell):

```sh
# your own user — no sudo needed
# prompt: $ (your own prompt)

cd ~/egresslock
git pull
```

<details><summary>Expected output:</summary>

<pre>
$ git pull
Updating 5153b13..dd62602
Fast-forward
 docs/setup/install.md | 93 +++++++++++-------
 ...
 7 files changed, 252 insertions(+), 154 deletions(-)
</pre>
</details>

### 2. Check what is installed

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

dpkg -l egresslock      # the .deb channel's installed version
egresslock --version    # the deployed commit stamp
```

<details><summary>Expected output:</summary>
note the deployed commit — the next step reads the release notes
between this and the new build:

<pre>
$ dpkg -l egresslock
Desired=Unknown/Install/Remove/Purge/Hold
| Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst
|/ Err?=(none)/Reinst-required (Status,Err: uppercase=bad)
||/ Name           Version      Architecture Description
+++-==============-============-============-=================
ii  egresslock      <VERSION>    all          egress lock kit
$ egresslock --version
version: <VERSION>
commit: <commit>
deployed: 2026-10-09T12:00:00Z
</pre>

Troubleshooting:
- prints `dev`: the bare command resolved to a checkout copy, not the
  installed kit; check `command -v egresslock` — the installed PATH
  wrapper is `/usr/local/bin/egresslock`.
</details>

<details><summary>Tarball (prefix) install instead?</summary>
`dpkg -l` shows nothing for the tarball install. Set `PREFIX` to the
existing install's absolute path, not a new destination. If you use
the PATH wrapper, `cat /usr/local/bin/egresslock` shows that path in
its `# egresslock-path-wrapper prefix=…` line; if wrappers were
skipped, use the path you installed to.

<pre>
$ PREFIX=/opt/egresslock                 # edit to match your existing prefix
$ cat "$PREFIX/VERSION"
version: <VERSION>
commit: <commit>
deployed: 2026-10-09T12:00:00Z
</pre>

Use this same `PREFIX` in step 4.
</details>

### 3. Read the release notes between the two versions

Open [CHANGELOG.md](../../CHANGELOG.md) and read the entries between
your deployed commit (step 2) and the version you are upgrading to.
Most upgrades have nothing special — you are looking for
**action-required** items (e.g. a conf format change), which come
with their instructions. The image rebuilds in the next step are
plain commands: they no-op on their own when nothing changed.

### 4. Build and install the new `.deb`

Build in your own shell, install as root (full details:
[install step 1](install.md#1-get-the-kit) and
[step 2](install.md#2-install-the-package)):

```sh
# your own user — no sudo needed to build
# prompt: $ (your own prompt)

rm -f ./packaging/egresslock_*_all.deb
./packaging/build-deb.sh        # → packaging/egresslock_VERSION_all.deb
```

<details><summary>Expected output:</summary>

<pre>
$ ./packaging/build-deb.sh
build-deb: built packaging/egresslock_<VERSION>_all.deb (version <VERSION>)
</pre>
</details>

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo dpkg -i ./packaging/egresslock_VERSION_all.deb
```

<details><summary>Expected output:</summary>
an upgrade replaces the installed version ("preparing to replace");
account data, allowlists, and enabled timers survive.

<pre>
$ sudo dpkg -i ./packaging/egresslock_<VERSION>_all.deb
(Reading database ... 118294 files and directories currently installed.)
Preparing to unpack .../egresslock_<VERSION>_all.deb ...
Unpacking egresslock (<VERSION>) over (<OLD VERSION>) ...
Setting up egresslock (<VERSION>) ...
</pre>
</details>

<details><summary>Alternative: tarball (prefix) install</summary>
Re-run the install with the same prefix — idempotent, replaces the
deployed kit files; accounts are not touched:

<pre>
$ sudo ./install-kit.sh --prefix "$PREFIX"
PATH wrapper installed: /usr/local/bin/egresslock to /opt/egresslock/egresslock
PATH wrapper installed: /usr/local/sbin/egresslock-setup to /opt/egresslock/egresslock-setup

successfully installed! kit is at: /opt/egresslock
  0.11.0+git20261108123456.a1b2c3d4e5f6
</pre>

(The same AppArmor advisory and next-step block as a first install
follows; accounts are not touched.)
</details>

### 5. Rebuild the images if the base moved

The gateway and example images are built from one Debian base pin.
When that pin moves, both images need a rebuild, and each profile
with a running gateway needs an explicit replace. If you have multiple
accounts it needs to be done for each one.  As the account —
switch into the account's shell:

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo -iu ACCOUNT
```

<details><summary>Expected output:</summary>
the prompt changes — you are now the account:

<pre>
$ sudo -iu <account>
<account>@host:~$
</pre>
</details>

```sh
# account — you are in the account shell
# prompt: <account>@host:~$

egresslock doctor --workloads | grep -E 'gateway image|stale:|rebuild:|running gateway:|podman_cve:|workloads:|^  |egl-base image'    # does doctor flag an image rebuild, a podman advisory, or a workload?
```

<details><summary>Expected output:</summary>
a current image — nothing to rebuild:

<pre>
<account>@host:~$ egresslock doctor --workloads | grep -E 'gateway image|stale:|rebuild:|running gateway:|podman_cve:|workloads:|^  |egl-base image'
gateway image: present (localhost/egresslock-gateway:latest) — base <pin>, built 2026-11-05
egl-base image: present (localhost/egl-base:latest) — base <pin>, built 2026-11-05
</pre>

(The `egl-base image:` row appears only when that optional example
image exists.)

a `stale:` line — the base pin moved; rebuild (below):

<pre>
<account>@host:~$ egresslock doctor --workloads | grep -E 'gateway image|stale:|rebuild:|running gateway:|podman_cve:|workloads:|^  |egl-base image'
gateway image: present (localhost/egresslock-gateway:latest) — base <old-pin>, built 2026-09-01
  stale: base pin moved (image base <old-pin> != deployed pin <pin>) — rebuild in the account shell: egresslock build-gateway && egresslock ensure --replace-gateway <profile> per affected profile (see "The gateway image" reference page)
</pre>

a `rebuild:` line — the image predates the kit's security rebuild
floor or is more than 30 days old; rebuild (below). The age form says
`more than 30 days old` instead:

<pre>
<account>@host:~$ egresslock doctor --workloads | grep -E 'gateway image|stale:|rebuild:|running gateway:|podman_cve:|workloads:|^  |egl-base image'
gateway image: present (localhost/egresslock-gateway:latest) — base <pin>, built 2026-10-25
  rebuild: gateway image built 2026-10-25 is older than the kit's security rebuild floor 2026-11-04 — rebuild in the account shell: egresslock build-gateway --force && egresslock ensure --replace-gateway <profile> per affected profile (see "The gateway image" reference page)
</pre>

a `running gateway:` line — the image row is clean but a running
gateway still uses a different image (the forgotten replace); replace
that profile (below):

<pre>
<account>@host:~$ egresslock doctor --workloads | grep -E 'gateway image|stale:|rebuild:|running gateway:|podman_cve:|workloads:|^  |egl-base image'
gateway image: present (localhost/egresslock-gateway:latest) — base <pin>, built 2026-11-05
running gateway: work runs a different image — replace only, once per listed profile: run as <account>: egresslock ensure --replace-gateway <profile>
</pre>

When the image row also printed `stale:` or `rebuild:`, the
`running gateway:` remedy says `rebuild first (above), then replace
these profiles` instead. A `running gateway: UNKNOWN — …` line means
the comparison could not be read; it is not a clean verdict.

The check calls `egresslock doctor --workloads`, so the workload rows
are included; bare `egresslock doctor` prints only a `workloads:`
pointer line and does not scan running containers. The `|^  |`
alternative keeps the two-space-indented per-container lines (a
`workloads:` finding names its container on its own line), so a
flagged workload is not reduced to the section header.
</details>

**If the check said `stale:`, `rebuild:`, or `missing` — rebuild both images:**

```sh
# account — you are in the account shell
# prompt: <account>@host:~$

egresslock build-gateway
/usr/share/egresslock/examples/egl-base/build-egl-base
```

Prefix installs: `$PREFIX/examples/egl-base/build-egl-base`.

<details><summary>Expected output:</summary>
each command rebuilds and streams its podman build log (STEP lines,
apt output, layer commits) between the `Building …` line and the
end; `build-gateway` prints no separate success line, `build-egl-base`
ends with `Done: …`. A re-run on an already-current image prints
`already built from deployed pin <pin> — use --force to rebuild`
instead.

<pre>
<account>@host:~$ egresslock build-gateway
Building localhost/egresslock-gateway:latest FROM <pin>
...
<account>@host:~$ /usr/share/egresslock/examples/egl-base/build-egl-base
egl-base image: stale: base pin moved (image <old-pin> != deployed pin <pin>)
Building localhost/egl-base:latest FROM <pin>
...
Done: localhost/egl-base:latest
</pre>

A moved base and a floor `rebuild:` line are refreshed by these plain
builds (below the floor, both helpers pass `--no-cache`). If the only
line was the **age** `rebuild:` (more than 30 days old), age does not
trigger either helper — run the same two commands with `--force`:

<pre>
<account>@host:~$ egresslock build-gateway --force
Building localhost/egresslock-gateway:latest FROM <pin>
...
<account>@host:~$ /usr/share/egresslock/examples/egl-base/build-egl-base --force
Building localhost/egl-base:latest FROM <pin>
...
Done: localhost/egl-base:latest
</pre>
</details>

After a successful image build, replace the running gateways — a
rebuild does not replace them (doctor's `running gateway:` row names
any profile still on the old image), and the replace restarts each
gateway, so that profile's proxied sessions drop briefly:

```sh
# account — you are in the account shell
# prompt: <account>@host:~$

egresslock ensure --replace-gateway all
```

<details><summary>Expected output:</summary>

<pre>
<account>@host:~$ egresslock ensure --replace-gateway all
using configs in /home/<account>/.config/egresslock (2 profiles: main, staging)
ensure all will ensure every profile listed above; continue? [y/N] y
gateway 'egresslock-gateway-main' --replace-gateway — replacing the running container (profile sessions will drop)
gateway 'egresslock-gateway-main' ready (allowlist applied, health verified)
profile 'main' ready (network egresslock-main, policy verified)
note: egresslock protects the policy, not the workload's launch settings — before starting a workload, review the operator obligations checklist: /usr/share/egresslock/docs/reference/operator-obligations.md
gateway 'egresslock-gateway-staging' --replace-gateway — replacing the running container (profile sessions will drop)
gateway 'egresslock-gateway-staging' ready (allowlist applied, health verified)
profile 'staging' ready (network egresslock-staging, policy verified)
ensure all: 2 profiles ensured
</pre>

For a single named profile (doctor's row names it), run the named
form: `egresslock ensure --replace-gateway PROFILE`.

Background: [The gateway image](../reference/gateway-image.md).
</details>

### 6. Re-ensure every profile

Profiles replaced in step 5 are already running the new image. This
release's `ensure` rewrites every profile's firewall chain: the
direct-path denial record behind `denied PROFILE --direct` (New
features in the release notes) is new, so each chain gains one record
rule — observability only; it does not widen what the profile allows.
Run the re-ensure even when nothing else changed: until a profile is
re-ensured, every verify of it — `verify --ensured`, `verify all`, and
the verify timer — fails with `policy chain p_PROFILE does not match
the expected ruleset`. That failure is expected before the re-ensure
and clears once it runs; fail-closed enforcement is unchanged:

```sh
# account — you are in the account shell
# prompt: <account>@host:~$

egresslock ensure all
egresslock verify all
```

<details><summary>Expected output:</summary>
`ensure all` names the profiles it found and, for more than one, asks
before it starts. An unchanged profile re-ensures without a restart
when the in-place reload is confirmed — established proxied sessions
then stay; if the reload cannot be confirmed the engine prints one
warning and restarts the gateway, which drops established proxied
sessions. When a profile's allowlist changed, this run applies it the
same way. `ensure all` stops at the first failing profile (a retry
converges the rest); `verify all` continues past per-profile failures
and ends in one tally:

<pre>
<account>@host:~$ egresslock ensure all
using configs in /home/<account>/.config/egresslock (2 profiles: main, staging)
ensure all will ensure every profile listed above; continue? [y/N] y
gateway 'egresslock-gateway-main' ready (allowlist applied, health verified)
profile 'main' ready (network egresslock-main, policy verified)
note: egresslock protects the policy, not the workload's launch settings — before starting a workload, review the operator obligations checklist: /usr/share/egresslock/docs/reference/operator-obligations.md
gateway 'egresslock-gateway-staging' ready (allowlist applied, health verified)
profile 'staging' ready (network egresslock-staging, policy verified)
note: egresslock protects the policy, not the workload's launch settings — before starting a workload, review the operator obligations checklist: /usr/share/egresslock/docs/reference/operator-obligations.md
ensure all: 2 profiles ensured
<account>@host:~$ egresslock verify all
profile 'main' policy and gateway verified
profile 'staging' policy and gateway verified
verify all: 2 profiles verified
</pre>

Troubleshooting:
- full per-layer health checks:
  [check-everything](../reference/check-everything.md).
</details>

## Next

- [Check everything is working](../reference/check-everything.md) —
  the post-upgrade health check.
