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
./packaging/build-deb.sh        # → packaging/egresslock_<VERSION>_all.deb
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

sudo dpkg -i ./packaging/egresslock_<VERSION>_all.deb
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
install-kit: deployed kit to /opt/egresslock
install-kit: unit templates -> /etc/systemd/system
install-kit: PATH wrappers -> /usr/local/bin/egresslock, /usr/local/sbin/egresslock-setup
</pre>
</details>

### 5. Rebuild the images if the base moved

The gateway and example images are built from one Debian base pin.
When that pin moves, both images need a rebuild, and each running
gateway profile needs an explicit replace. If you have multiple
accounts it needs to be done for each one.  As the account —
switch into the account's shell:

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo -iu <account>
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

egresslock doctor | grep -E 'gateway image|stale:'    # does the installed kit expect a different base?
```

<details><summary>Expected output:</summary>
a current image — nothing to rebuild:

<pre>
<account>@host:~$ egresslock doctor | grep -E 'gateway image|stale:'
gateway image: present (localhost/egresslock-gateway:latest) — base <pin>, built 2026-10-09
</pre>

a `stale:` line — rebuild (below):

<pre>
<account>@host:~$ egresslock doctor | grep -E 'gateway image|stale:'
gateway image: present (localhost/egresslock-gateway:latest) — base <old-pin>, built 2026-09-01
  stale: base pin moved (image base <old-pin> != deployed pin <pin>) — rebuild in the account shell: egresslock build-gateway && egresslock ensure --replace-gateway <profile> per affected profile (see "The gateway image" reference page)
</pre>
</details>

**If the check said `stale:` (or `missing`) — rebuild both images:**

```sh
# account — you are in the account shell
# prompt: <account>@host:~$

egresslock build-gateway
/usr/share/egresslock/examples/egl-base/build-egl-base
```

<details><summary>Expected output:</summary>
each command rebuilds and streams its podman build log (STEP lines,
apt output, layer commits) between the `>> Building …` line and the
end; `build-gateway` prints no separate success line, `build-egl-base`
ends with `>> Done: …`. A re-run on an already-current image prints
`already built from deployed pin <pin> — use --force to rebuild`
instead.

<pre>
<account>@host:~$ egresslock build-gateway
>> Building localhost/egresslock-gateway:latest FROM <pin>
...
<account>@host:~$ /usr/share/egresslock/examples/egl-base/build-egl-base
egl-base image: stale: base pin moved (image <old-pin> != deployed pin <pin>)
>> Building localhost/egl-base:latest FROM <pin>
...
>> Done: localhost/egl-base:latest
</pre>
</details>

**If the base moved, replace every affected gateway profile in this
account — even if doctor now reports a current image.** Doctor checks
the tagged image, not running gateways. If an upgrade was interrupted
after the rebuild, finish replacing the remaining profiles; plain
`ensure` in step 6 does not replace a healthy old gateway.

Only proceed after a successful image build. The replace restarts the
gateway container, so that profile's proxied sessions drop briefly:

```sh
# account — you are in the account shell
# prompt: <account>@host:~$

egresslock ensure --replace-gateway main    # each gateway profile, by name
```

<details><summary>Expected output:</summary>

<pre>
<account>@host:~$ egresslock ensure --replace-gateway main
gateway 'egresslock-gateway-main' --replace-gateway — replacing the running container (profile sessions will drop)
gateway 'egresslock-gateway-main' ready (allowlist applied, health verified)
profile 'main' ready (network egresslock-main, policy verified)
</pre>

Background: [The gateway image](../reference/gateway-image.md).
</details>

### 6. Re-ensure each profile

Profiles replaced in step 5 are already converged; for every profile
these commands are a no-op unless the profile's policy or allowlist
changed:

```sh
# account — you are in the account shell
# prompt: <account>@host:~$

egresslock ensure main                # each profile, by name
egresslock verify main
```

<details><summary>Expected output:</summary>
an unchanged profile re-ensures as a no-op — no disruption; when the
profile's allowlist changed, this run applies it and restarts the
gateway to pick it up:

<pre>
<account>@host:~$ egresslock ensure main
gateway 'egresslock-gateway-main' ready (already converged, not restarted)
profile 'main' ready (network egresslock-main, policy verified)
<account>@host:~$ egresslock verify main
profile 'main' policy and gateway verified
</pre>

Troubleshooting:
- full per-layer health checks:
  [check-everything](../reference/check-everything.md).
</details>

## Next

- [Check everything is working](../reference/check-everything.md) —
  the post-upgrade health check.
