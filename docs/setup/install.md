# How to: install the kit

Full reference for installing (and verifying) the kit on a host. This
page answers: **"how do I install, set up an account, and verify the
install?"** The README's [Install and first
run](../../README.md#install-and-first-run) is the condensed version;
this page has the details, explains every setting, and covers both
install channels (`.deb` and manual).

**On this page:** [Requirements](#requirements) · [Deb install](#deb-install) ·
[Manual install](#manual-install) · [Account setup (`egresslock-setup`)](#account-setup-egresslock-setup) ·
[Settings reference](#settings-reference) · [AppArmor prerequisite](#apparmor-prerequisite) ·
[Root & sudo](#root-sudo-interactive-only-no-nopasswd) · [Files installed](#files-installed) ·
[Validating a host](#validating-a-host-install-verification)

There are **two install channels** — same commands, different entry
points. Pick ONE per host, never both at once: the `.deb` postinst
warns if `/opt/egresslock/egresslock` exists. To switch from the
prefix deploy to the `.deb`: `uninstall-kit.sh` first, then `dpkg -i`.
See [Packaging](../../packaging/README.md) for the build/install/uninstall process.

## Requirements

1. **Linux with systemd and unprivileged user namespaces enabled** —
   the kit drives rootless Podman; both are required.

2. **Debian packages** (install as root):

   ```sh
   sudo apt-get install -y podman netavark nftables conntrack
   ```

   | Package | What it is / why |
   |---|---|
   | **podman** | runs the workload containers, the anchor, and the Squid gateway (validated on 5.4.2) |
   | **netavark** | Podman's rootless network backend; creates the profile bridge networks (validated on 1.14.0) |
   | **nftables** | the enforcement engine — the kit installs a fail-closed policy in the account's rootless netns (1.0+; `nft` at `/usr/sbin/nft` or set `NFT_BIN`) |
   | **conntrack** | required by `disallow-host`'s revocation flush (the kit's `Depends:`) |

3. **One or more dedicated unprivileged `<account>`s** to own the
   policies — the kit never runs policy jobs as root. **Create a new
   account specifically for this**, not your user account:

   ```sh
   sudo adduser <account>
   sudo loginctl enable-linger <account>
   ```

   `enable-linger` keeps `/run/user/<uid>` alive outside login sessions
   (required for the verify timer; `egresslock-setup --enable` does both
   steps automatically — see [Account setup](#account-setup-egresslock-setup)).

4. **AppArmor (pasta profile)** — on affected hosts only (pasta
   enforced **and** podman running under an AppArmor label, any
   profile mode — Ubuntu >= 25.10 by default; see the
   [AppArmor prerequisite](#apparmor-prerequisite)), the enforce-mode
   pasta profile denies the SIGTERM podman sends to its shared-netns
   holder, so the first `ensure` fails with `rootless netns: kill
   network process: permission denied`. If the host is affected,
   apply the shipped one-rule amendment before the first `ensure` —
   the full apply/verify/unapply steps are in the
   [AppArmor pasta rule](../../apparmor/README.md). The kit ships the
   snippet but does **not** auto-apply it; `egresslock-setup
   --apparmor-check` reports whether this host needs it.

## Deb install

The `.deb` is the FHS-layout channel: the engine lands on `PATH` as
`egresslock`, and uninstall is `apt remove egresslock`.

### 1. Get the kit

The kit ships as source: there is **no hosted `.deb` or tarball** to
download. Clone the checkout and build the channel you want
(both build scripts ship in the tree):

```sh
git clone https://github.com/egresslock/egresslock && cd egresslock

# .deb (FHS layout, engine on PATH):
./packaging/build-deb.sh        # → packaging/egresslock_<VERSION>_all.deb

# or tarball (self-contained, manual install):
./packaging/build-tarball.sh    # → packaging/egresslock_<VERSION>.tar.gz
```

### 2. Install the package

Build from a checkout (no root needed), then:

```sh
sudo dpkg -i ./egresslock_<VERSION>_all.deb
```

### 3. Add the pasta policy (affected hosts only)

On an **affected** host — pasta enforced **and** podman running under
an AppArmor label (any profile mode; Ubuntu >= 25.10 by default) — add
the pasta policy; on other hosts the step is a harmless no-op (a label
can return; `--apparmor-check` tells you which case you are in). For
more details about why this is needed, see the
[AppArmor prerequisite](#apparmor-prerequisite) below and the
[AppArmor pasta rule](../../apparmor/README.md):

```sh
sudo egresslock-setup --apparmor-add
```

### 4. Set up and enable the account

```sh
sudo egresslock-setup --init-conf --enable --account <account>
```

This ships a **deny-all** starter conf (`profile main` + empty
allowlist — the gateway denies everything), writes the account's
`unit.env`, builds the gateway image, and (with `--enable`) arms the
15-minute drift-check timer and enables linger. See
[Account setup](#account-setup-egresslock-setup) for what each flag
does.

**Required parameters:**

- `--account <name>` — the target account (required unless
  `--apparmor-add` is used alone).
- exactly one of `--init-conf` or `--conf <path>`:
  - `--init-conf` ships the deny-all starter (`profile main` + empty
    allowlist) from `examples/`, **only if no conf exists yet** (never
    overwrites). Without `--conf`, the dest is
    `~/.config/egresslock/main.conf`.
  - `--conf <path>` is the alternative — bring your own conf file
    (e.g. from a copy step). It validates + wires that conf into
    `unit.env` and skips the starter.

**Pinned conf / restricted accounts (runner-style):** the full bundle
also covers accounts that get a **pre-made conf** (deploy tooling
distributes a pinned conf + allowlist; the account must not edit it):

```sh
sudo egresslock-setup --account <acct> --conf <pinned-conf> --profile <profile> --enable
```

That is conf validation (as the account) + `unit.env` + gateway image
build + timer + linger in one command — the same bundle
`--init-conf` gives generic accounts, without shipping a starter.
Before building the gateway image, setup starts the account's systemd
user manager (`user@<uid>.service`), so a never-logged-in
account works on the first run. `--enable` still owns linger and the
verify timer.
`--prefix` is usually unnecessary: the prefix derives from the
installed unit templates, including the .deb layout
(`/usr/lib/egresslock`) — and when a stale prefix unit points at a
missing engine, setup retries the deb unit dir. This is
the form to use for service accounts (CI runners, per-service
daemons); see [the CI runner recipe](../../examples/recipes/ci-runner.md).

**Optional parameters you may also use:**

- `--profile <name>` — write `EGRESSLOCK_PROFILE=<name>` (named verify
  mode); omit for `--ensured` mode.
- `--prefix <path>` — deployed kit prefix (default: derived from the
  installed unit template, else `/opt/egresslock`).
- `--enable` — enable+start `egresslock-verify@<account>.timer` AND
  enable linger for the account (fails closed if linger does not
  stick).
- `--apparmor-add` / `--apparmor-remove` — apply/unapply the pasta rule (see step 3).

**The run map (numbered progress):**

Every account-bundle run prints one line per step, in execution order,
so you can see what a run changed and where it stopped:

```
1) validate conf … OK
2) write unit.env … OK
3) linger … OK          # SKIP without --enable
4) user manager … OK    # SKIP without a `gateway` line in the conf
5) gateway image … OK   # SKIP without a `gateway` line
6) timer … OK           # SKIP without --enable
```

`FAIL` is always the last printed step (the run stops there, nothing
after it executed).

**Root vs account steps (D38-4):**

| Step | Runs as | Why |
|---|---|---|
| validate conf | account (`runuser`) | the conf must parse under the account's engine/store |
| write unit.env | account (`runuser`) | kit-generated state lives in the account's confdir |
| linger | **root** | `loginctl enable-linger` is a system logind change (`--enable` only) |
| user manager | **root** | `systemctl start user@<uid>.service` (gateway confs; start, never restart) |
| gateway image | account (`runuser`) | must land in the account's rootless Podman store |
| timer | **root** | `systemctl enable --now egresslock-verify@<account>.timer` (`--enable` only) |

**Modular sub-actions:**

- `sudo egresslock-setup --doctor` — read-only kit/account state check
  with the fix command for each missing item. Without `--account` it
  checks the host slice (engine at the derived prefix, unit templates
  installed); with `--account` it adds conf parse, `unit.env` match,
  timer, linger, and (for gateway confs) the user manager and gateway
  image. AppArmor is pointed at `--apparmor-check`, not duplicated.
  This is distinct from the engine's `egresslock doctor` (the host
  environment probe: podman, netavark, nft, unprivileged userns).
- `egresslock-setup --build-gateway` — build the gateway image in the
  **invoking user's own shell** from the deployed/share prefix
  (`$prefix/gateway` or `$EGRESSLOCK_SHARE/gateway`), no root and no
  `--account`. It never starts `user@` and never enables linger: the
  user manager must already be active (an active session or linger),
  otherwise it fails closed and tells you the fix.

**About linger and the drift timer:**

`--enable` enables **linger** for the account, which keeps
`/run/user/<uid>` alive outside login sessions (required for the
verify timer). If you do **not** pass `--enable`, you must enable
linger yourself:

```sh
sudo loginctl enable-linger <account>
```

Without `--enable`, the **15-minute drift timer will not run**. The kit
works fine without it — but you lose automatic drift detection. Drift
is when a domain's IP changes (DNS re-resolution): the pinned
`allow-host` rules point at stale addresses, and `verify` reports a
`drift:` line. Re-run `ensure` to re-resolve and re-pin. The timer
catches this for you every 15 minutes; without it, you only see drift
when you run `verify` by hand.

### 5. Verify the install

First, confirm what was installed (as root):

```sh
dpkg -L egresslock                    # .deb layout: /usr/bin/egresslock, /usr/sbin/egresslock-setup, /usr/lib/egresslock/, /usr/share/egresslock/, /usr/lib/systemd/system/
systemctl list-timers 'egresslock-verify@*'   # templates + timers present
egresslock --version                          # the deployed commit stamp
```

Note: the verify timer is a **system** unit (installed by
`install-kit.sh`, enabled per-account by `egresslock-setup --enable`),
so it appears under `systemctl list-timers` — NOT
`systemctl --user list-timers`. Before `--enable`, the template shows
here with 0 loaded instances, which is expected.

Then, as the account, check the conf files that were shipped:

```sh
sudo -iu <account>
ls -la ~/.config/egresslock/          # main.conf, main-allowlist, unit.env
cat ~/.config/egresslock/unit.env     # EGRESSLOCK_CONF=...
```

Then **build the policy** — this is a required step. `ensure` creates
the profile network, starts the anchor (and gateway), installs the
nftables policy, and verifies the result:

```sh
egresslock ensure main                # or your profile name
```

Now confirm the podman networks are up:

```sh
podman network ls                     # egresslock-main
podman ps -a                          # egresslock-anchor-main, egresslock-gateway-main
egresslock list                       # profiles: name, network, subnet
egresslock verify main                # read-only drift check
```

### 6. (Optional) Examine from within the container

All management and container starts run as the dedicated `<account>`
(never root), so switch to it first:

```sh
sudo -iu <account>
```

Then the bare skeleton — ensure the profile, then run a container on
its network with the proxy env wired in with one env file (never
hardcoded IPs):

```sh
# Build/verify the network policy (idempotent — safe to re-run):
egresslock ensure main
# Then run a shell on the profile network, proxy wired in:
podman run --rm -it \
    --network="$(egresslock network main)" \
    --env-file=<(egresslock proxy-env main) \
    docker.io/library/debian:13-slim \
    sh
```

This drops you into a `debian:13-slim` shell on the profile's network —
**no curl/wget/ping inside**, so there is no egress until you allow
destinations.

### 7. Next steps

Now that the kit is installed, work through the
[Quick start guides](../../README.md#quick-start-guides) in the README.

## Manual install

The manual channel deploys the kit to a shared, root-owned prefix
(default `/opt/egresslock`) from a checkout or the self-contained
`tar.gz`. `install-kit.sh` also installs PATH wrappers
(`/usr/local/bin/egresslock`, `/usr/local/sbin/egresslock-setup`), so
the bare `egresslock` command works after install (like the `.deb`'s
`/usr/bin` wrapper; if `/usr/local/…` is unwritable the install
warns and skips — call the full path instead).

### 1. Get the kit

```sh
# Option A — clone the repo (primary, what the harness tests):
git clone https://github.com/egresslock/egresslock && cd egresslock

# Option B — build the tarball, then unpack it (self-contained, no
# repo needed afterwards):
./packaging/build-tarball.sh
tar -xzf packaging/egresslock_<VERSION>.tar.gz && cd egresslock
```

### 2. Install the kit (root)

```sh
# --- edit this line ---------------------------------------------------
PREFIX=/opt/egresslock          # where the shared kit is deployed
# ----------------------------------------------------------------------
sudo ./install-kit.sh --prefix "$PREFIX"
```

`install-kit.sh` deploys the kit to `--prefix` (one shared, root-owned
copy) and installs the `egresslock-verify@.service`/`@.timer`
templates. The installed unit's `ExecStart` is rewritten with the
deployed prefix at install time, so changing the prefix later means
re-running `install-kit.sh`. It does **not** touch accounts (no timers
enabled here — that is `egresslock-setup --enable`, after the account's
`unit.env` exists). Re-running is safe (idempotent upgrade).

### 3. Apply the AppArmor pasta policy (only if using AppArmor)

```sh
sudo /opt/egresslock/egresslock-setup --apparmor-add
```

### 4. Set up and enable the account

```sh
sudo /opt/egresslock/egresslock-setup --init-conf --enable --account <account>
```

**Required parameters:**

- `--account <name>` — the target account (required unless
  `--apparmor-add` is used alone).
- exactly one of `--init-conf` or `--conf <path>`:
  - `--init-conf` ships the deny-all starter (`profile main` + empty
    allowlist) from `examples/`, **only if no conf exists yet** (never
    overwrites). Without `--conf`, the dest is
    `~/.config/egresslock/main.conf`.
  - `--conf <path>` is the alternative — bring your own conf file
    (e.g. from a copy step). It validates + wires that conf into
    `unit.env` and skips the starter.

**Pinned conf / restricted accounts (runner-style):** the full bundle
also covers accounts that get a **pre-made conf** (deploy tooling
distributes a pinned conf + allowlist; the account must not edit it):

```sh
sudo egresslock-setup --account <acct> --conf <pinned-conf> --profile <profile> --enable
```

That is conf validation (as the account) + `unit.env` + gateway image
build + timer + linger in one command — the same bundle
`--init-conf` gives generic accounts, without shipping a starter.
`--prefix` is usually unnecessary: the prefix derives from the
installed unit templates, including the .deb layout
(`/usr/lib/egresslock`) — and when a stale prefix unit points at a
missing engine, setup retries the deb unit dir. This is
the form to use for service accounts (CI runners, per-service
daemons); see [the CI runner recipe](../../examples/recipes/ci-runner.md).

**Optional parameters you may also use:**

- `--profile <name>` — write `EGRESSLOCK_PROFILE=<name>` (named verify
  mode); omit for `--ensured` mode.
- `--prefix <path>` — deployed kit prefix (default: derived from the
  installed unit template, else `/opt/egresslock`).
- `--enable` — enable+start `egresslock-verify@<account>.timer` AND
  enable linger for the account (fails closed if linger does not
  stick).
- `--apparmor-add` / `--apparmor-remove` — apply/unapply the pasta rule (see step 3).

**About linger and the drift timer:**

`--enable` enables **linger** for the account, which keeps
`/run/user/<uid>` alive outside login sessions (required for the
verify timer). If you do **not** pass `--enable`, you must enable
linger yourself:

```sh
sudo loginctl enable-linger <account>
```

Without `--enable`, the **15-minute drift timer will not run**. The kit
works fine without it — but you lose automatic drift detection. Drift
is when a domain's IP changes (DNS re-resolution): the pinned
`allow-host` rules point at stale addresses, and `verify` reports a
`drift:` line. Re-run `ensure` to re-resolve and re-pin. The timer
catches this for you every 15 minutes; without it, you only see drift
when you run `verify` by hand.

### 5. Verify the install

First, confirm what was installed (as root):

```sh
ls "$PREFIX"                                     # egresslock, gateway/, examples/, VERSION
systemctl list-timers 'egresslock-verify@*'   # templates + timers present
"$PREFIX/egresslock" --version               # the deployed commit stamp
```

Then, as the account, check the conf files that were shipped:

```sh
sudo -iu <account>
ls -la ~/.config/egresslock/          # main.conf, main-allowlist, unit.env
cat ~/.config/egresslock/unit.env     # EGRESSLOCK_CONF=...
```

Then **build the policy** — this is a required step. `ensure` creates
the profile network, starts the anchor (and gateway), installs the
nftables policy, and verifies the result:

```sh
/opt/egresslock/egresslock ensure main          # or your profile name
```

Now confirm the podman networks are up:

```sh
podman network ls                     # egresslock-main
podman ps -a                          # egresslock-anchor-main, egresslock-gateway-main
/opt/egresslock/egresslock list       # profiles: name, network, subnet
/opt/egresslock/egresslock verify main  # read-only drift check
```

### 6. (Optional) Examine from within the container

Same as the [.deb step 6](#6-optional-examine-from-within-the-container),
but call the engine by full path (`/opt/egresslock/egresslock`); the
bare `egresslock` command also works via the installed PATH wrapper
(`/usr/local/bin/egresslock`).

### 7. Next steps

Now that the kit is installed, work through the
[Quick start guides](../../README.md#quick-start-guides) in the README.

## Account setup (`egresslock-setup`)

`egresslock-setup` is the one-command per-account bootstrap. Run as
**root**, from the installed kit or a checkout. It: ships the starter
conf with `--init-conf`, validates the conf, writes the account's
`unit.env`, builds the gateway image (if the conf has one), and
optionally enables the verify timer.

**Affected hosts only** (AppArmor-enforced pasta **and** podman under
an AppArmor label, any profile mode — Ubuntu >= 25.10 by default; see
the [pasta/AppArmor blocker](../troubleshooting/pasta-apparmor.md)
matrix): apply the amendment with
`sudo egresslock-setup --apparmor-add` BEFORE the account's first `ensure`
— the rule is not needed for setup itself (the `unit.env` write and
the gateway image build never touch the rootless netns), but the first
netns probe/creation fails without it, and a failed probe can leave
the pasta holder wedged. If setup runs without it on
such a host, it prints one stderr hint; nothing is auto-applied (see
[apparmor/README.md](../../apparmor/README.md)). On unaffected hosts
the rule is a harmless future-proofing no-op.

### Flags

| Flag | What it does |
|---|---|
| `--account <name>` | target account (required unless `--apparmor-add` is used alone) |
| `--conf <path>` | profile conf to validate + wire into `unit.env` (required unless `--init-conf`) |
| `--init-conf` | ship the starter conf pair from the deployed prefix when the dest conf is missing (never overwrites); without `--conf` the dest is `~/.config/egresslock/main.conf` |
| `--profile <name>` | write `EGRESSLOCK_PROFILE=<name>` (named verify mode); omit for `--ensured` mode |
| `--prefix <path>` | deployed kit prefix (default: derived from the installed unit template, else `/opt/egresslock`) |
| `--enable` | enable+start `egresslock-verify@<account>.timer` AND enable linger for the account (fails closed if linger does not stick) |
| `--apparmor-add` | apply the shipped pasta rule (root; may be combined with `--account` or used alone) — resolves the pasta profile file and writes the rule into the **local include it references** (`local/usr.bin.pasta` or `local/pasta`; idempotent) and reloads the resolved profile |
| `--apparmor-remove` | unapply the pasta rule (strips only the marker-scoped block; never removes operator lines) |
| `--apparmor-check` | report AppArmor/pasta amendment health (read-only, no root) |
| `-h`, `--help` | print the full help (the script is the source of truth) |

### What setup does

- **`--init-conf`** ships the deny-all starter (`profile main` + empty
  allowlist) from `examples/`, only if no conf exists yet (never
  overwrites; never heals an existing conf's missing allowlist).
- **Validates** the conf: exists AND readable by the account, parses
  cleanly under the deployed engine, and (with `--profile`) that the
  named profile exists in it.
- **Writes `~/.config/egresslock/unit.env`** (0600): exactly one
  `EGRESSLOCK_CONF=<conf>` line, plus `EGRESSLOCK_PROFILE=<name>` only
  when `--profile` is given. Re-runs overwrite the file wholesale.
- **Builds the gateway image** into the account's Podman store from the
  deployed prefix (for gateway profiles) if the image is missing.
- **`--enable`** enables+starts `egresslock-verify@<account>.timer`
  and enables linger for the account, so `/run/user/<uid>` persists
  outside login sessions for the timer's `egresslock-verify`.

### The two files that matter

- **The profile conf** (engine input): profiles, subnets, rules,
  allowlist references. Account-owned site data. Gateway profiles need
  an allowlist file **next to the conf** (conf-relative path in the
  `gateway` directive); missing/invalid allowlists fail `ensure`
  closed.
- **`~/.config/egresslock/unit.env`** (0600) — *pure systemd wiring*:
  tells the verify timer where the account's conf is. Exactly one
  required line + one optional:
  - `EGRESSLOCK_CONF=<conf path>` — required
  - `EGRESSLOCK_PROFILE=<name>` — optional; omit for `verify --ensured`

### Full reference

`egresslock-setup --help` (`-h`) documents every option, default, and
the manual fallback. This section is the quick orientation; the script
is the source of truth.

## Settings reference

### Profile conf (`<profile>.conf`)

Each profile is a `<profile>.conf` + `<profile>-allowlist` pair under
`~/.config/egresslock/`. The starter (`examples/main.conf`) is:

```conf
profile main 10.199.0.0/24
    rule gateway-only
    gateway 10.199.0.2 3128 main-allowlist
```

| Setting | What it does |
|---|---|
| `profile <name> <cidr>` | starts a profile block; IPv4 CIDR, prefixlen 8-29, canonical network address |
| `rule gateway-only` | egress only through the profile's gateway (requires a `gateway` directive) |
| `rule allow-host <host>:<port>` | direct host:port allow (repeatable; resolved at ensure time) — bypasses the gateway, pinned as an nftables rule |
| `rule public-only` | accept all public IPv4 (still drops RFC1918 etc.; cannot combine with allow-host/gateway) |
| `gateway <ip> <port> <file>` | static gateway IP inside the subnet + Squid port + allowlist file (conf-relative unless absolute) |
| `no-proxy <host,...>` | extra `NO_PROXY` entries (hosts the profile may reach directly) |

The full grammar, the allowlist format, and the rules to keep straight
are in the [Policy reference](../reference/policy-reference.md).

### `unit.env` (`~/.config/egresslock/unit.env`, 0600)

Pure systemd wiring — tells the verify timer where the account's conf
is. Written by `egresslock-setup`.

| Line | Meaning |
|---|---|
| `EGRESSLOCK_CONF=<conf path>` | required — where the account's profile conf is |
| `EGRESSLOCK_PROFILE=<name>` | optional — named verify mode; omit for `--ensured` |

### Engine environment overrides

See `egresslock --help` for the full list:

| Variable | What it does |
|---|---|
| `EGRESSLOCK_CONF` | required for every profile subcommand — the engine has no compiled-in profiles; unset or empty fails closed with `no profile config` |
| `NFT_BIN` | path to the `nft` binary (default `/usr/sbin/nft`, else `$PATH`) |
| `EGRESSLOCK_ANCHOR_IMAGE` | anchor image (default: base image or alpine) |
| `EGRESSLOCK_GW_IMAGE` | gateway image (default `localhost/egresslock-gateway:latest`) |
| `EGRESSLOCK_ALLOW_ROOT=1` | allow running as root (NOT recommended — root's Podman store/netns is not an account) |
| `EGRESSLOCK_SKIP_NETNS_PROBE=1` | skip the podman rootless-netns preflight probe (test harness only) |
| `EGRESSLOCK_GW_LOG_MAX_BYTES` | gateway log rotation cap in bytes (default 32 MiB; `0` = no cap) |
| `EGRESSLOCK_DENIED_MAX_BYTES` | `denied` log-read cap in bytes (default 8 MiB; `0` = uncapped) |

Config resolution: when neither `--config` nor
`EGRESSLOCK_CONF` is given, the engine probes the running user's default
folder `~/.config/egresslock/`. Named commands use `<profile>.conf` if
present, else `main.conf`; bare `list` and bare `verify --ensured`
aggregate every `*.conf` in that folder. Explicit always beats the
probe. Details in the README's
[Configuration options](../../README.md#configuration-options).

> **TBD:** any setting not listed above that you expect to see here is
> still being documented — check `egresslock --help` /
> `egresslock-setup --help` (the source of truth) and open an issue if
> something is missing.

## AppArmor prerequisite

On affected hosts, an **enforce-mode** AppArmor profile for `pasta`
denies the SIGTERM podman sends to its shared-netns holder, so the
first `ensure` fails with `rootless netns: kill network process:
permission denied`. **Affected** means pasta enforced **and**
podman running under an AppArmor label (any profile mode): Ubuntu
>= 25.10 by default (the label profile ships in the `apparmor`
package); stock Debian ships no podman label profile, noble ships no
pasta profile at all, Fedora/RHEL use SELinux — there the denial
cannot fire and the amendment is a harmless future-proofing no-op.
See the [affected-OS matrix](../../docs/troubleshooting/pasta-apparmor.md#affected-os--stack-matrix-snapshot-verified-2026-09-10)
for the full table. The kit does not touch AppArmor (distro-owned
policy, applied by you).

Check the actual state on your host, and apply if needed — the full
apply/verify/unapply steps are in the dedicated
[AppArmor pasta rule](../../apparmor/README.md):

```sh
sudo egresslock-setup --apparmor-check
sudo egresslock-setup --apparmor-add
```

## Root & sudo: interactive only, no NOPASSWD

The three root-running kit entry points — `install-kit.sh`,
`uninstall-kit.sh`, and `egresslock-setup` — are **interactive root**
tools. Do **not** grant them passwordless sudo (`NOPASSWD` in
sudoers): their arguments are deliberately free-form (`--prefix`,
`--account`, `--conf`), and `egresslock-setup` runs as the target
account via `runuser` — so a `NOPASSWD` rule on any of these binaries
without an exact-argv restriction is **equivalent to full root**.

The engine itself never runs as root (the root guard) and does
not need sudo at all; only distribution of the shared kit (install/
uninstall) and the per-account bootstrap touch root.

For the full picture — who runs which command where (root / the
container-owner account / the workload) and the `sudo -iu` tilde trap
— see [who-runs-what](../reference/who-runs-what.md).

## Files installed

### Deployed kit (manual prefix install)

The kit is deployed ROOT-owned to `--prefix` (default
`/opt/egresslock`):

| File / dir | What it is |
|---|---|
| `egresslock` | the engine CLI (`ensure`, `verify`, `list`, `network`, `rules`, `allowlist`, `denied`, `allow`/`disallow`, `allow-host`/`disallow-host`, `init`, `doctor`, `teardown`, ...) |
| `egresslock-start` | daemon-start wrapper: `ensure` the profile, then exec the daemon |
| `egresslock-verify` | entry point for the verify timer (named or `--ensured`) |
| `egresslock-setup` | per-account bootstrap: ship starter conf, validate, write `unit.env`, build gateway, enable timer |
| `gateway/` | build context for the Squid gateway image (`Containerfile`, `squid.conf`, entrypoint) |
| `apparmor/` | pasta AppArmor snippet + profiles shipped root-owned with the prefix (distribution only — applying stays the explicit `egresslock-setup --apparmor-add`; see `apparmor/README.md`) |
| `examples/` | starter conf + empty allowlist for `egresslock-setup --init-conf`; `recipes/` deployed so accounts build from the prefix |
| `VERSION` | `commit:` SHA + `deployed:` UTC date (+ `-dirty` marker) of what is installed |

Unit templates installed to `/etc/systemd/system/` (overridable via
`EGRESSLOCK_UNIT_DIR`):

| Unit | What it is |
|---|---|
| `egresslock-verify@.service` | runs `egresslock-verify` as the account (instance = account) |
| `egresslock-verify@.timer` | 15-min drift signal, `Persistent=true` |

### Source tree (what a checkout contains)

The **deployed** kit is a subset of this. Paths are relative to the
repository root:

| Path | What it is |
|---|---|
| `egresslock` | The engine CLI: `ensure`, `verify` (incl. `--ensured`), `list`, `network`, `proxy-env` (tokens: `proxyip`/`proxyport`/`noproxy`), `rules`, `allowlist`, `denied` (`--all`, `--days N`), `allow`/`disallow`, `allow-host`/`disallow-host`, `init`, `doctor`, `teardown` (incl. `--runtime`), `--version` |
| `install-kit.sh` | (root) Deploy the kit to a prefix and install the instanced verify unit templates (no account changes) |
| `egresslock-setup` | (root) One-command per-account setup: ship the starter conf with `--init-conf`, validate conf, write `unit.env`, build the gateway image, optionally enable the timer |
| `uninstall-kit.sh` | (root) Remove the kit; account data is preserved unless `--purge-account-data` |
| `egresslock-start` | Wrapper for daemon services: `ensure $EGRESSLOCK_PROFILE` (fail closed), then exec the daemon |
| `egresslock-verify` | Entry point for the verify timer: named profile or `--ensured` mode |
| `gateway/` | Build context for the Squid gateway image (`Containerfile`, `squid.conf`, entrypoint) |
| `examples/` | Starter conf + empty allowlist shipped by `install-kit.sh` for `egresslock-setup --init-conf`; recipes under `recipes/` |
| `build-gateway` | Build the gateway image into the current user's store (checkout use) |
| `tests/` | Mock battery: `bash tests/run.sh` runs `lib.sh` + `test-engine.sh` + `test-kit.sh` (engine and kit harnesses; no root/Podman needed) |
| `packaging/` | `build-deb.sh` (FHS `.deb`, thin `dpkg-deb` build) and `build-tarball.sh` (self-contained manual-install tar.gz incl. `uninstall-kit.sh`); `README.md` (the packaging guide) |
| `docs/quickstart/` | Post-install quickstart guides (allow a domain, allow non-HTTP, grow the policy, first-run checks, test your container) |
| `docs/setup/` | install / upgrade / uninstall references |
| `docs/reference/` | overview, who runs what, policy reference, paths-and-signatures, proxy clients, check-everything catalog, scripts-and-environment, threat model |
| `docs/troubleshooting.md` + `docs/troubleshooting/` | symptom index + one page per issue |
| `docs/README.md` | docs organization map |

### .deb doc location

The `.deb` ships the docs tree under
`/usr/share/egresslock/doc/` — structure-preserving (the same
`docs/quickstart|setup|reference|troubleshooting` layout as the repo)
plus `doc/README.md` (the repo front page). Process files
(`docs/tickets/`, `BOARD.md`) are never shipped.

## Validating a host (install verification)

After a fresh install, before relying on the host:

1. `install-kit.sh`; then `egresslock-setup --enable`; confirm
   `systemctl list-timers 'egresslock-verify@*'` (SYSTEM scope —
   NOT `--user`).
2. As the account: `ensure <profile>` then `verify <profile>` — both
   must pass with the gateway healthy.
3. Start the timer oneshot manually and expect the `verified
   (ensured)` lines in the journal.
4. Negative check: stop the gateway container, re-run the oneshot —
   it must FAIL (that is the drift signal working).

The shorter everyday version (and the commonly-wrong items) is
[first-run-checks](../quickstart/first-run-checks.md).

## Next steps

- [Check everything is working](../reference/check-everything.md) — the
  health check for a fresh setup.
- [Upgrade the kit](upgrade.md) — re-running install-kit.sh with the
  same prefix, the VERSION stamp, and the post-upgrade checks.
- [Uninstall the kit](uninstall.md) — account teardown first, kit
  removal, and the AppArmor revert.
- [Troubleshooting](../troubleshooting.md) — diagnosis checklist, service
  units & signal semantics, the pasta/AppArmor netns blocker, gateway
  (Squid) log reading, and host validation steps.