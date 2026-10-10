# How to: install the kit

Install the kit on a host, set up a runner account, and verify the
install. One flow below — the `.deb` install is recommended; the
tarball alternative appears inline where it differs.

**On this page:** [Requirements](#requirements) · [Install the kit](#install-the-kit) ·
[Files installed](#files-installed)

Commands run as **root via `sudo` from your own shell** (no separate
admin account — root's prompt looks like your own) unless a block is
tagged otherwise (`account`, `your own user`); every block carries
its world tag and prompt on separate comment lines. Root for the kit
is **interactive only** — do **not** grant `install-kit.sh`,
`uninstall-kit.sh`, or `egresslock-setup` passwordless sudo
(`NOPASSWD`); why:
[who runs what](../reference/who-runs-what.md#root-sudo-and-nopasswd-no-passwordless-root).

## Requirements

1. **Linux with systemd and unprivileged user namespaces enabled** —
   the kit drives rootless Podman; both are required.

2. **Debian packages** (install as root):

   ```sh
   # root — via sudo from your own shell
   # prompt: $ (your own prompt)

   sudo apt-get install -y podman netavark nftables conntrack
   ```

   <details><summary>Expected output:</summary>
   standard apt resolution; package versions vary by distro — the four
   names are what matters.

   <pre>
   $ sudo apt-get install -y podman netavark nftables conntrack
   Reading package lists... Done
   Building dependency tree... Done
   Reading state information... Done
   The following NEW packages will be installed:
     conntrack netavark nftables podman
   0 upgraded, 4 newly installed, 0 to remove and 0 not upgraded.
   ...
   Setting up podman (5.4.2) ...
   </pre>
   </details>

   <details><summary>Why each dependency</summary>

   | Package | What it is / why |
   |---|---|
   | **podman** | runs the workload containers, the anchor, and the Squid gateway (validated on 5.4.2) |
   | **netavark** | Podman's rootless network backend; creates the profile bridge networks (validated on 1.14.0) |
   | **nftables** | the enforcement engine — the kit installs a fail-closed policy in the account's rootless netns (1.0+; `nft` at `/usr/sbin/nft` or set `NFT_BIN`) |
   | **conntrack** | required by `disallow-host`'s revocation flush (the kit's `Depends:`) |

   </details>

3. **One or more dedicated unprivileged `<account>`s** to own the
   policies — the kit never runs policy jobs as root. **Create a new
   account specifically for this**, not your user account:

   ```sh
   # root — via sudo from your own shell
   # prompt: $ (your own prompt)

   sudo adduser --disabled-password --gecos "egresslock runner" <account>
   ```

   <details><summary>Expected output:</summary>
   no password prompt — `--disabled-password` leaves login locked;
   uid/gid numbers vary.

   <pre>
   $ sudo adduser --disabled-password --gecos "egresslock runner" <account>
   Adding user `<account>' ...
   Adding new group `<account>' (1001) ...
   Adding new user `<account>' (1001) with group `<account>' ...
   Creating home directory `/home/<account>' ...
   Copying files from `/etc/skel' ...
   </pre>
   </details>

   - `--disabled-password` gives the account no password login —
     it is a service account, reached with `sudo -iu <account>` or
     SSH keys.
   - Linger (required by the verify timer) is armed by
     `egresslock-setup --enable` in install step 4 — no manual
     `loginctl` needed.
   - `egresslock-setup` does **not** create the account — this step
     is the only account-creation step.

## Install the kit

The `.deb` install is recommended. Alternative methods (the tarball
prefix deploy) appear inline in collapsed blocks where they differ.
To switch install methods later, uninstall the current one first
([Uninstall](uninstall.md)) — never install both: the `.deb` postinst
warns if `/opt/egresslock/egresslock` exists.

### 1. Get the kit

The kit ships as source — there is **no hosted `.deb` or tarball** to
download. In your own shell (building needs no root), get the
checkout (cloned only if missing; `git pull` updates a re-run) and
build the `.deb` ([Packaging](../../packaging/README.md) has the
build details):

```sh
# your own user — no sudo needed to build
# prompt: $ (your own prompt)

[ -d ~/egresslock ] || git clone https://github.com/egresslock/egresslock ~/egresslock
cd ~/egresslock
git pull
rm -f ./packaging/egresslock_*_all.deb
./packaging/build-deb.sh        # → packaging/egresslock_<VERSION>_all.deb
```

<details><summary>Expected output:</summary>
first run: clone noise, then the build's last line names the built
`.deb`; re-runs skip the clone and show a `git pull` summary instead.

<pre>
$ [ -d ~/egresslock ] || git clone https://github.com/egresslock/egresslock ~/egresslock
Cloning into 'egresslock'...
remote: Enumerating objects: 9124, done.
Receiving objects: 100% (9124/9124), 2.10 MiB | 8.20 MiB/s, done.
Resolving deltas: 100% (6410/6410), done.
$ cd ~/egresslock
$ git pull
Already up to date.
$ ./packaging/build-deb.sh
build-deb: built packaging/egresslock_<VERSION>_all.deb (version <VERSION>)
</pre>
</details>

<details><summary>Alternative: build the tarball instead</summary>
Same clone; or, from the checkout, build the self-contained tarball
and unpack it (no repo needed afterwards); expectations as above.

<pre>
$ ./packaging/build-tarball.sh
build-tarball: built packaging/egresslock_<VERSION>.tar.gz
$ tar -xzf packaging/egresslock_<VERSION>.tar.gz && cd egresslock
</pre>
</details>

### 2. Install the package

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo dpkg -i ./packaging/egresslock_<VERSION>_all.deb
```

<details><summary>Expected output:</summary>

<pre>
$ sudo dpkg -i ./packaging/egresslock_<VERSION>_all.deb
Selecting previously unselected package egresslock.
(Reading database ... 118294 files and directories currently installed.)
Preparing to unpack .../packaging/egresslock_<VERSION>_all.deb ...
Unpacking egresslock (<VERSION>) ...
Setting up egresslock (<VERSION>) ...
</pre>

Troubleshooting:
- a warning about an existing `/opt/egresslock/egresslock` means the
  tarball install is present — uninstall it first (one install
  method per host).
</details>

<details><summary>Alternative: tarball (manual prefix) install</summary>
Deploys the kit to a shared, root-owned prefix and the unit templates
to `/etc/systemd/system/` (changing the prefix later means re-running
`install-kit.sh`; re-running is a safe idempotent upgrade). PATH
wrappers are installed so the bare commands in the rest of this page
work identically; if `/usr/local/…` is unwritable the install warns
and skips them — call the full path (`$PREFIX/egresslock`) instead.

<pre>
$ PREFIX=/opt/egresslock
$ sudo ./install-kit.sh --prefix "$PREFIX"
install-kit: deployed kit to /opt/egresslock
install-kit: unit templates -> /etc/systemd/system
install-kit: PATH wrappers -> /usr/local/bin/egresslock, /usr/local/sbin/egresslock-setup

next step — per-account setup (from the installed kit):
  sudo /opt/egresslock/egresslock-setup --account <acct> --init-conf --enable
</pre>

Set `PREFIX` to the chosen absolute path; `/opt/egresslock` above is
the default. Keep that same path for upgrades and uninstall.
</details>

### 3. Check the pasta policy (only some hosts need it)

A few hosts (pasta enforced **and** podman under an AppArmor label —
Ubuntu >= 25.10 by default) need a one-rule AppArmor amendment before
the first `ensure`. Check; act only if the verdict says so
(why: the
[pasta/AppArmor blocker](../troubleshooting/pasta-apparmor.md) —
decision tree and affected-OS matrix;
[apparmor/README.md](../../apparmor/README.md) has the
apply/verify/unapply steps):

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo egresslock-setup --apparmor-check | grep Summary
```

<details><summary>Expected output (not needed):</summary>
most hosts; nothing to do — continue with step 4.

<pre>
$ sudo egresslock-setup --apparmor-check | grep Summary
Summary: CHECK OK (AppArmor patch not needed)
</pre>
</details>

<details><summary>Expected output (needed):</summary>
affected host — apply the amendment before step 4 (the first
`ensure` fails without it):

<pre>
$ sudo egresslock-setup --apparmor-check | grep Summary
Summary: CHECK FAILED (AppArmor patch needed)
</pre>
</details>

<details><summary>If affected: apply the amendment</summary>
One command, idempotent; the full apply/verify/unapply steps live in
[apparmor/README.md](../../apparmor/README.md).

<pre>
$ sudo egresslock-setup --apparmor-add
AppArmor: pasta profile reloaded (/etc/apparmor.d/usr.bin.pasta). Confirm with: sudo egresslock-setup --apparmor-check
</pre>
</details>

### 4. Set up and enable the account

`egresslock-setup` (root) is the one-command per-account bootstrap. It:

- ships the starter conf (`profile main` + empty allowlist) when
  missing; on a fresh account it denies application connections,
- writes the account's `unit.env`,
- builds the gateway image,
- arms the 15-minute verify timer and enables linger (`--enable`).

Existing confs and allowlists are preserved, not reset. DNS queries
to the bridge resolver remain allowed even with an empty allowlist
and can carry data out — see the [threat model](../reference/threat-model.md).

Every flag and the step-by-step run map: the
[scripts and environment reference](../reference/scripts-and-environment.md#egresslock-setup--per-account-bootstrap).

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo egresslock-setup --init-conf --enable --account <account> > ~/egresslock-setup.log 2>&1
grep -E '^[0-9]\) |hint|FAIL' ~/egresslock-setup.log
```

<details><summary>Expected output:</summary>
the six-step run map — each step `OK` (the full stream goes to
~/egresslock-setup.log; details below):

<pre>
$ sudo egresslock-setup --init-conf --enable --account <account> > ~/egresslock-setup.log 2>&1
$ grep -E '^[0-9]\) |hint|FAIL' ~/egresslock-setup.log
1) validate conf … OK
2) write unit.env … OK
3) linger … OK
4) user manager … OK
5) gateway image … OK
6) timer … OK
</pre>

- `FAIL` is always the last printed step (the run stops there,
  nothing after it executed).
- re-runs are quieter still: steps not needed print `SKIP`.

Troubleshooting:
- `hint: pasta is AppArmor-enforced` on a host whose check said
  "not needed": the label can return; re-run
  [step 3](#3-check-the-pasta-policy-only-some-hosts-need-it).
</details>

<details><summary>Prefer to watch the run instead?</summary>
Drop the redirect — but expect the raw stream to be **~300 lines of
build noise**: the AppArmor hint (affected hosts), the image pull,
`debconf` frontend-fallback lines, and `HEALTHCHECK` warnings. It
looks like it is installing things; it is building the gateway image,
and every line shown is normal. The excerpts:

<pre>
$ sudo egresslock-setup --init-conf --enable --account <account>
egresslock-setup: hint: pasta is AppArmor-enforced; if the netns probe fails, apply the shipped rule with --apparmor-add (snippet: /usr/share/egresslock/apparmor/usr.bin.pasta.local)
1) validate conf … OK
2) write unit.env … OK
3) linger … OK
4) user manager … OK
5) gateway image … OK
Trying to pull docker.io/library/debian@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f...
Getting image source signatures
Copying blob ecc510c1e359 done   |
Copying config 567e3c17b1 done   |
Writing manifest to image destination
debconf: falling back to frontend: Noninteractive
WARN[0011] HEALTHCHECK is not supported for OCI image format and will be ignored. Must use `docker` format
6) timer … OK
Created symlink '/etc/systemd/system/timers.target.wants/egresslock-verify@<account>.timer' → '/usr/lib/systemd/system/egresslock-verify@.timer'.
</pre>
</details>

<details><summary>Restricted accounts (runner-style): bring your own conf</summary>
Accounts that must not edit their conf get a pre-made conf
distributed by deploy tooling — same bundle, no starter shipped:

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo egresslock-setup --account <account> --conf <pinned-conf> --profile <profile> --enable
```

The same six-step map (the conf is validated as the account instead
of shipped). The form to use for service accounts (CI runners,
per-service daemons) — see
[the CI runner recipe](../../examples/recipes/ci-runner.md).
</details>

### 5. Confirm what was installed (root)

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

dpkg -L egresslock                          # the .deb layout
systemctl list-timers 'egresslock-verify@*' # templates + timers present
egresslock --version                        # the deployed commit stamp
```

<details><summary>Expected output:</summary>
three checks; the timer line appears per account once `--enable` ran
(system scope — before that, only the unloaded templates show).

<pre>
$ dpkg -L egresslock
/usr
/usr/bin
/usr/bin/egresslock
/usr/sbin
/usr/sbin/egresslock-setup
/usr/lib/systemd/system/egresslock-verify@.service
/usr/lib/systemd/system/egresslock-verify@.timer
/usr/share/egresslock
/usr/share/egresslock/doc/README.md
...
$ systemctl list-timers 'egresslock-verify@*'
NEXT                       LEFT     LAST PASSED UNIT                                  ACTIVATES
Tue 2026-10-09 14:00:00 UTC  14min  -    -      egresslock-verify@<account>.timer      egresslock-verify@<account>.service

1 timers listed.
$ egresslock --version
version: <VERSION>
commit: <commit>
deployed: 2026-10-09T12:00:00Z
</pre>

Troubleshooting:
- `--version` prints `dev` when run from a checkout instead of an
  installed kit — that is the checkout's stamp, not a failure.
</details>

<details><summary>Alternative: tarball install — confirm what was installed</summary>
Same checks, different listing: `ls "$PREFIX"` (`egresslock`,
`gateway/`, `examples/`, `VERSION`) instead of `dpkg -L`. The bare
`egresslock`/`egresslock-setup` commands work via the PATH wrappers
(`/usr/local/...`) — full path (`$PREFIX/egresslock`) if the
wrappers were skipped.
</details>

> [!NOTE]
> **The verify timer is a system unit**
>
> Installed by the kit and enabled per-account by `egresslock-setup
> --enable` — it appears under `systemctl list-timers`, NOT
> `systemctl --user list-timers`.

### 6. Become the account

The kit never runs policy jobs as root — everything from here runs
in the account's own shell (`sudo -iu` = "substitute user, login
shell": a complete login as that account, home directory and all;
you stay in it until you type `exit`):

```sh
# root — via sudo from your own shell
# prompt: $ (your own prompt)

sudo -iu <account>
```

<details><summary>Expected output:</summary>
the prompt changes — you are now the account, in its home directory:

<pre>
$ sudo -iu <account>
<account>@host:~$
</pre>

You are in a different world here: everything until you type `exit`
runs as `<account>`, and its prompt (`<account>@host:~$`) is how you
tell.
</details>

### 7. Build the policy

`ensure` creates the profile network, starts the anchor (and
gateway), installs the nftables policy, and verifies the result:

```sh
# account — you are now in the account shell
# prompt: <account>@host:~$

egresslock ensure main                # or your profile name
```

<details><summary>Expected output:</summary>
the first `ensure` creates the network, starts the anchor and
gateway, and installs the policy; re-runs are idempotent and report
`already converged`.

<pre>
<account>@host:~$ egresslock ensure main
created network egresslock-main (10.199.0.0/24)
started anchor egresslock-anchor-main
gateway 'egresslock-gateway-main' ready (allowlist applied, health verified)
profile 'main' ready (network egresslock-main, policy verified)
</pre>

Troubleshooting:
- `rootless netns: kill network process: permission denied` — the
  AppArmor step 3 was skipped on an affected host; apply the
  amendment (see
  [pasta/AppArmor blocker](../troubleshooting/pasta-apparmor.md)).
</details>

### 8. Confirm the policy is up

```sh
# account — you are still in the account shell
# prompt: <account>@host:~$

podman network ls                     # egresslock-main
podman ps -a                          # egresslock-anchor-main, egresslock-gateway-main
egresslock list                       # profiles: name, network, subnet
egresslock verify main                # read-only drift check
```

<details><summary>Expected output:</summary>

<pre>
<account>@host:~$ podman network ls
NETWORK ID    NAME              DRIVER
<id>          egresslock-main   bridge
<account>@host:~$ podman ps -a
CONTAINER ID  IMAGE                                STATUS        NAMES
<id>          localhost/egresslock-anchor:latest   Up 2 minutes  egresslock-anchor-main
<id>          localhost/egresslock-gateway:latest  Up 2 minutes  egresslock-gateway-main
<account>@host:~$ egresslock list
NAME           NETWORK                SUBNET
main           egresslock-main        10.199.0.0/24
<account>@host:~$ egresslock verify main
profile 'main' policy and gateway verified
</pre>
</details>

### 9. (Optional) Look at the conf files

```sh
# account — you are still in the account shell
# prompt: <account>@host:~$

ls -la ~/.config/egresslock/          # main.conf, main-allowlist, unit.env
cat ~/.config/egresslock/unit.env     # EGRESSLOCK_CONF=...
```

<details><summary>Expected output:</summary>

<pre>
<account>@host:~$ ls -la ~/.config/egresslock/
total 16
drwx------ 2 <account> <account> 4096 Oct  9 12:00 .
drwx------ 4 <account> <account> 4096 Oct  9 12:00 ..
-rw------- 1 <account> <account>  137 Oct  9 12:00 main.conf
-rw-r--r-- 1 <account> <account>    0 Oct  9 12:00 main-allowlist
-rw------- 1 <account> <account>   62 Oct  9 12:00 unit.env
<account>@host:~$ cat ~/.config/egresslock/unit.env
EGRESSLOCK_CONF=/home/<account>/.config/egresslock/main.conf
</pre>
</details>

What these files mean and the profile conf grammar: the
[scripts and environment reference](../reference/scripts-and-environment.md)
and the [Policy reference](../reference/policy-reference.md).

## Files installed

What the kit puts on the host (`.deb` layout, prefix layout, unit
templates) and what a checkout contains: the
[files-installed reference](../reference/files-installed.md).

## Next

- [Quick start guides](../../README.md#quick-start-guides) — the
  first tasks on the installed kit.
