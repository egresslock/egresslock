# Changelog

All notable changes between egresslock releases. The public repository
ships without history (each release is a fresh snapshot tree), so this
file is the record of what changed since the previous release.

## 0.10.0 - 2026-11-02

> **Operator-important changes:**
>
> **Action required:**
> 1. **Keep your host OS and kernel security-patched.** egresslock's
>    Podman containers share the **host's kernel**; the kit cannot patch
>    the host's OS or kernel.
> 2. **Likely no action is needed. Only if you hand-edited a `.conf`
>    file to point to a different allowlist.** The `gateway` line must
>    now name exactly `<profile>-allowlist`, the file next to the conf.
>    Any other basename, a path component, or an absolute path fails
>    every load (exit 2, naming the conf line and the expected file);
>    `egresslock-setup import` refuses such a source (rc 1, nothing
>    written). `egresslock init` and the starter already write the pair.
>    For a conf that needs migrating, see
>    [migrating an older hand-written pair](docs/reference/policy-reference.md#file-names-the-convention).
> 3. **Likely no action is needed. Only if you launch podman with an
>    explicit `--out=<path>` whose directory other users can write to.**
>    The shipped examples use the bare `--out`
>    (`--env-file="$(egresslock proxy-env <profile> --out)"`), which is
>    unaffected — as is the default runtime dir. An explicit path like
>    that is now refused with a named error (exit 1, nothing written)
>    instead of a warning. See
>    [Proxy clients](docs/reference/proxy-clients.md) for a private
>    directory, the bare `--out`, and the `podman run --env KEY=value`
>    alternative.
> 4. **Likely no action is needed. Only if you named a profile
>    `all`.** `all` is now reserved for the `teardown all` keyword, so a
>    profile of that name no longer works: its `all.conf` fails to load
>    (exit 2, named `reserved`; `list` and `verify --ensured` fail
>    closed until it is migrated), and `teardown all` refuses (exit 2)
>    while the file exists instead of tearing down `main`. Rename the
>    conf, allowlist, and `all.pins`, then remove the old profile's
>    runtime objects — the steps are in
>    [Reserved profile name](docs/reference/policy-reference.md#reserved-profile-name).
>    No other profile name is affected; `teardown all` keeps its
>    main.conf-only meaning once no `all.conf` exists.
>
> **Important but no action required:**
> 1. **One verb for allowing and disallowing.** `allow`/`disallow` now
>    accepts the `--direct` flag for the direct firewall path (direct
>    path is for 1) non-HTTP(s) traffic and 2) bare IP destinations);
>    e.g.
>    ```
>    egresslock allow <profile> self-hosted-git.example:22 --direct
>    ```
>    without `--direct`, the command acts normally (proxy path).
>    `allow-direct`/`disallow-direct` are new
>    shortcuts; `allow-host`/`disallow-host` still work as compatibility
>    aliases but are no longer shown in `usage` and are planned for
>    removal in a later release. Every successful mutation now prints one
>    `path:` line naming the store it changed; a proxy allow on a port
>    other than 80/443 shows a hint. Since those are likely to require a
>    --direct rule, it will print a two-line stderr note with the command
>    to add the direct rule.
> 2. **One verb for viewing allowlists.** You can see normal allowlist
>    (proxy) and direct with
>    ```
>    egresslock allowlist <profile>
>    egresslock allowlist <profile> --direct
>    ```
> 3. **The gateway's in-container config path moved.** `/etc/squid/agent/`
>    is now `/etc/squid/egresslock/`. Gateways you have not yet replaced
>    keep working unchanged with the new engine. The new gateway image
>    keeps the old path available through a temporary `/etc/squid/agent`
>    symlink for backwards compatibility (which will be in place at least
>    through v0.12), so older engines and scripts that
>    still name it keep working. Nothing is required; the first `ensure`
>    after the upgrade rewrites the generated config and restarts each
>    gateway once. Optional: to adopt the new gateway image, run
>    `egresslock build-gateway --force && egresslock ensure --replace-gateway <profile>`
>    per gateway profile — a vocabulary-only rebuild leaves the base pin
>    unchanged, so plain `build-gateway` no-ops.
> 4. **Gateway allowlists are now deployed as immutable, content-addressed
>    group files, and the running gateway's activation is recorded.** The
>    published `squid.conf` references files such as
>    `allowlist.domains.<sha256>`; a failed apply no longer overwrites the
>    files the running configuration uses. The first `ensure` after this
>    upgrade, after a reboot, or after a crash may restart each gateway
>    once to record which deployed generation the current container
>    loaded. Nothing is required: later redundant ensures return to
>    `already converged, not restarted`. Unreferenced old group files are
>    removed only after a grace window (default 3600 s) and a successful
>    verification; an apply that cannot prove whether publication
>    happened tells you to run `egresslock ensure` and does not claim the
>    old policy is still live.
> 5. **A leftover `EGRESSLOCK_CONF` now warns and is ignored.** The
>    variable was already not read; setting it (including an empty
>    assignment) now prints
>    `Warning: EGRESSLOCK_CONF is retired and is no longer read.` on
>    stderr, and the command continues as if it were unset. You do not
>    need to unset it before upgrading. If it comes from a stale
>    `unit.env`, `egresslock-setup doctor` still reports
>    `PROBLEM: unit.env: STALE` and the pathless setup re-run that
>    cleans it.

### Security

- **Four test-harness environment overrides no longer steer a
  privileged command.** They are ignored unless the harness's test-mode
  flag is set; without it each command uses its production default.
  Nothing in a normal deployment sets that flag. No action is needed;
  the overrides are listed in
  [scripts and environment](docs/reference/scripts-and-environment.md).
- **Conf `${VAR}` values come only from the invoking environment.** A
  `rule allow-host` / `no-proxy` host field's `${VAR}` (or
  `${VAR:-default}`) is expanded from the environment of the `egresslock`
  command that parses it — never from the engine's own variables. An
  exported name takes its exported value, even when it collides with an
  engine variable; an unset or empty name takes its `:-default`, or
  fails the load closed.
- **Out-of-range ports are rejected, not wrapped.** A port token such as
  `18446744073709551617` now fails closed with the named `invalid port`
  error (exit 2) instead of passing 64-bit arithmetic.
- **Leading-zero ports are emitted and compared in decimal.** An accepted
  spelling such as `:0443` is normalized to `443` before it reaches a pin
  record, nft chain, or conntrack comparison, so nft never reads it as
  octal 291 and `drop-unauthorized`/revocation name the same rule as the
  canonical listing.
- **`proxy-env --out` refuses a directory another user can write to.**
  An explicit `--out=<path>` whose directory is group-writable now
  exits 1 with a named error instead of being accepted with a
  warning (world-writable directories were already refused): a group
  member could replace the env file and point the container's
  proxied traffic at a proxy they control. The path printed is the
  real file path, so the consumer opens the directory we checked. A
  runtime dir writable only by your account is unaffected; an
  operator who needs a shared location can pass them to `podman run`
  with `--env KEY=value` instead.

### New features

- **Unified `allow`/`disallow` with an explicit direct path.** The two
  pairs of commands are now one verb per direction: `allow`/`disallow`
  handle both stores, with `--direct` selecting the direct firewall rule
  (today's `allow-host`/`disallow-host` operation) and the default
  staying the proxy allowlist. A name with or without a port is a
  proxied destination (a bare name is the 443 group); the direct path
  takes exactly one `host:port`; an IPv4 literal on the proxy path is
  refused with the exact `--direct` retry. `disallow` is path-scoped —
  the same destination can exist in both stores, and each removal names
  its path.
- **You can now easily see a profile's direct-path entries.**
  `egresslock allowlist <profile> --direct` lists the configured
  rules for allow-host (direct) entries in a readable format
  (one `host:port` per line, in conf order) from the profile conf. It
  does not resolve names, read the pin record, or change anything;
  `egresslock allowlist-direct <profile>` is a new alias for
  `egresslock allowlist <profile> --direct`.

### Command syntax changes

- **(new)** `egresslock allow-direct <profile> <host:port>` and
  `egresslock disallow-direct <profile> <host:port>` are shortcuts for
  `allow`/`disallow … --direct` (the path is already selected, so they
  take no flags).
- **(new)** `egresslock allow --direct <profile> <host:port>` /
  `disallow --direct`: `--direct` is accepted before or after the
  profile, at most once.
- **(renamed)** `allow-host`/`disallow-host` are now `allow-direct`/
  `disallow-direct`. The old names remain accepted compatibility
  aliases, hidden from `usage`/`--help` but fully gated, and are planned
  for removal in a later release.
- **(removed)** `EGRESSLOCK_CONF` — a set variable (including an empty
  assignment) now prints a warning and is not read, instead of being
  silently ignored; a profile's config is at
  `<account-home>/.config/egresslock/<profile>.conf`. No operator action
  is required; see *Important but no action required*.

### Changed

- **`egresslock allowlist <profile>` lists the configured proxy entries,
  not the allowlist file's raw bytes.** Comments and blank lines are no
  longer printed; each stored entry prints once, in file order, under a
  header naming the lane, the entry count, the source, and how names are
  resolved. An empty allowlist prints `0 proxy entries`. An invalid
  allowlist line now fails the command closed (rc 1) and names the
  entry. `egresslock allowlist <profile> --direct` keeps its rows and
  uses the same header shape. There is no `--raw` flag; use the file
  itself if you need the comments.
- **`egresslock-setup import` and `init` refuse an invalid allowlist
  entry before commit.** They validate a staged or live pair with the
  deployed engine, which now checks every allowlist entry; an invalid
  entry fails the import (rc 1, the error names the entry) and leaves
  the destination untouched. Identical halves are still validated, so
  re-importing an already-installed invalid pair is refused rather than
  reported `unchanged`, and `--force` has improved validation. The
  files-in-place refusal now also prints the engine's error.
- **Gateway config deployment is atomic and activation is proved.** Each
  non-empty allowlist group is generated as an immutable
  `allowlist.domains.<sha256>` / `allowlist.p<port>.<sha256>` file whose
  name is the hash of its exact bytes; a same-filesystem `mv -T` of the
  generated `squid.conf` is the single publication boundary. A run that
  finds an existing same-name group reuses it only when it is a regular,
  non-symlink file with identical bytes, and otherwise fails closed
  without clobbering it. The engine invalidates `.egresslock-activated`
  before publication and records it only after the restart, health probe,
  deployed-byte read-back and a PID 1 argv check
  (`squid -N -f <cfgdir>/squid.conf`); the converged skip now requires
  that witness to match the deployed generation, current container ID and
  `StartedAt`. If a rename reports failure or loses its result, the engine
  reads back and, when needed, removes the per-run container stage to
  quiesce a delayed rename. Only a non-zero rename result whose read-back
  equals the pre-publication config is a proven pre-publication failure;
  a zero result with any other read-back, a read/probe error, or an
  ambiguous sweep is disclosed as unknown instead of restoring the source
  or claiming the old config. A missing config is proved absent only when
  the probes explicitly report not found. Cleanup runs only after
  verification, keeps `squid.conf`,
  `allowlist.conf`, the witness and every deployed reference, and removes
  only unreferenced regular `allowlist.*`/`check.conf` files and private
  stage directories older than `EGRESSLOCK_GW_CLEANUP_GRACE` (default
  3600 s); an unreadable reference set skips cleanup. The EGL-389
  rollback and source-restore disclosures remain in place.
- **The `EGRESSLOCK_APPARMOR_PROFILES` listing override is ignored on a
  production root run.** A root `egresslock-setup apparmor add|check`
  (and the installer's advisory) reads the kernel profiles listing
  unless `EGRESSLOCK_KIT_ALLOW_NON_ROOT=1` is set, the same rule as the
  other test-harness hooks. A non-root `apparmor check` may still point
  it at a copied listing, since the kernel listing is root-only on many
  kernels. No operator action is needed.
- **Proxy `allow` rewrites only a regular 0600 allowlist.** A proxy
  `allow` that needs to add an entry or repair the final newline now
  refuses a symlink or any source mode other than exactly 0600: named
  error, source unchanged, no entry lines, no `ensure`. The refusal
  names `chmod 600 -- <path>` and says to retry the same `egresslock
  allow` command — an allowlist left at `0644` by a default umask is
  fixed that way; `allow` never changes the mode itself, and group or
  other access on the allowlist is not a supported sharing model. A
  clean no-op still works for a readable 0444/0644 or symlinked source.
  The rewrite preserves the source uid/gid and exact 0600 and needs a
  writable source parent with room for a full copy; replacing a hard
  link leaves its peers unchanged. POSIX ACL identity and other
  security metadata (including SELinux labels, capabilities and other
  xattrs) are not preserved; inherited dormant ACL entries can differ
  from the source and become effective after a later `chmod`. A signal
  around the rename can leave the commit outcome unknown — inspect the
  file before retrying. Operators must serialize editors,
  `egresslock-setup import` and other accounts sharing the source with
  engine commands; the engine lock covers this account's engine verbs
  only. If you rely on ACLs or security labels, make a
  metadata-preserving external edit while serialized, then run
  `egresslock ensure <profile>`; do not `chmod` a file whose access
  other users rely on.
- **Every profile must have a `gateway` line.** A conf whose profile
  block has no `gateway` directive is rejected at load (exit 2) with one
  named error pointing at the `profile` line; it names the gateway line
  to add, the allowlist file to create, and the `egresslock ensure` to
  run. Only a hand-written or hand-edited conf can lack the line —
  `egresslock init` always writes one — and a conf whose line was
  deleted now fails to load with the exact line to restore. Direct
  `rule allow-host` entries still work, but the profile needs a gateway
  beside them.
- **Path disclosure and the port hint.** Every successful `allow`/
  `disallow` mutation prints exactly one `path: proxy — gateway
  allowlist <path>` or `path: direct — firewall rule in <conf> (does
  not change client proxy settings)` line before `added:`/`removed:`.
  A proxy `allow` of an explicit port other than 80/443 prints a
  two-line stderr note offering an additional direct rule (the
  allowlist entry stays); it never changes the chosen path or port.
- **Canonical direct-path messages.** Failure and recovery text for the
  direct path now prints `allow … --direct`/`disallow … --direct`, even
  when an older compatibility name was used. An IPv4 literal on the
  proxy path likewise names that retry instead of `allow-host`.
- **Verify-failure guidance.** The engine's verify hints now say to run
  `ensure` as the account, e.g. `run: egresslock ensure <profile> (as
  <account>)`. The doctor's failed-verify rows re-run the check with
  `sudo systemctl start egresslock-verify@<account>.service` (output in
  the service journal) and, when the named profile is known, print the
  scoped repair `sudo -iu <account> -- egresslock ensure <profile>`. No
  rc or policy behavior change.
- **Help and usage-error text refreshed.** `egresslock help <command>`
  pages use plainer wording, the summary index says what each command
  does, and a usage error points at the command index or the command's
  help page instead of dumping a generic screen. No command behavior
  changed; no action needed.

### Fixed

- **`import --force` can no longer replace a directory or a symbolic
  link.** It replaces only a regular-file pair: a destination half that
  is a directory, symbolic link, or special file is refused (rc 1) with
  the path and kind, and nothing is moved or deleted. The import path no
  longer deletes recursively; a refused or failed import leaves the
  destination bytes untouched. Normal re-pin use is unchanged: a
  differing or torn pair of regular files is still replaced allowlist-
  first, conf last.
- **An unreadable profile conf now exits 2.** It prints the named
  `Error: config file cannot be read: <path> (check the file's
  permissions)` instead of exit 1 with a raw `Permission denied` line;
  only a conf with broken permissions is affected.
- **A full disk now fails named and applies no partial policy.** An
  incomplete nftables candidate is never installed; a failed conf or
  pin-record write exits 1 with a named line instead of a false
  `already present`/`removed:` claim; a pin write that fails after a
  successful apply says what is known about the live firewall; and
  `verify` refuses to report a match when its expected ruleset could
  not be written (including the forward-hook header). The lock's
  holder record is diagnostic only — `verify` warns and keeps the lock.
  See [a full disk breaks an egresslock write](docs/troubleshooting/disk-full.md).
- **Proxy `allow` replaces the allowlist atomically.** A proxy-path
  `allow` now builds the complete new allowlist — existing bytes, the
  one-newline repair when a nonempty file lacks a final newline, and the
  missing entries in argument order — in a private 0700 directory beside
  the source, then commits it with a same-filesystem rename. A detected
  read, write or metadata failure before the commit exits 1 with a
  named error, leaves the source bytes/mode/owner unchanged, prints no
  `added:`/`entry already present:` lines, and does not run `ensure`.
  Entry lines are printed only after the source commit (or a clean
  no-op), still in argument order and before the hints and
  `re_ensuring`. A clean no-op still performs a full read check but does
  not write or need source/parent write permission. A failed or
  interrupted rename reports that the outcome may be unknown, so
  inspect the source before retrying. `added:` reports the source
  change, not successful gateway activation; a later apply failure does
  not roll the source back.
- **A failed proxy `disallow` puts the allowlist back and never claims a
  removal.** If the reinstall fails before the gateway applies the new
  allowlist, the source file is restored byte-identically (same-directory
  hard-link/rename, one retry), the staged `allowlist.*` set inside the
  gateway is rolled back, the running gateway is left untouched, and the
  command exits 1 with a phase-aware `nothing was revoked` disclosure and
  the exact retry. A failure after the config swap keeps the removal and
  names `ensure` instead; if the source cannot be put back, the disclosure
  states the file/live divergence without stopping a healthy pre-existing
  gateway. `removed:` is printed only after a successful reinstall (now
  after the ready lines, matching the direct path), so a failed attempt
  cannot claim the entry was removed, and the ordinary retry re-attempts
  instead of failing `entry not present`.
- **`init` names the real cause when Podman cannot list networks.** If
  `egresslock init` cannot run `podman network ls`, it now exits 1 with
  the same diagnosis `ensure` gives — `cannot list Podman networks; the
  subnet-overlap pre-check cannot run (fail closed): <podman output>` —
  instead of the misleading `no free /24 …` (auto-pick) or
  `overlaps an existing profile/network` (`--subnet`) message. It still
  refuses to write a conf/allowlist pair, a real overlap still reports
  the overlap, and a successful init is unchanged. No action.
- **`all` is reserved as a profile name.** `egresslock init all` and
  named commands with `all` now fail with exit 2 and a named `reserved`
  error instead of creating an unreachable profile or resolving
  `main.conf`; the config loader refuses a legacy `all.conf`, and
  `teardown all` refuses (exit 2) while one exists instead of tearing
  down `main`. `egresslock-setup --profile all` and an imported source
  whose `profile` line names `all` refuse too. `main` and every other
  valid name are unchanged; `teardown all` keeps its main.conf-only
  meaning once no `all.conf` exists. Migrating a legacy `all` profile
  is covered in
  [Reserved profile name](docs/reference/policy-reference.md#reserved-profile-name).
- **The gateway allowlist is always the profile's pair half.** The
  parser accepts only `<profile>-allowlist` for the `gateway` line:
  another profile's file, an absolute path, or a path component now
  exits 2 at load (naming the conf line and the expected file).
  `egresslock-setup import` likewise refuses a source whose gateway
  line names anything else (rc 1, nothing written). A conforming pair
  loads and imports byte-identically.
- **Extra arguments are rejected by `verify`/`rules`/`list`/`teardown`.**
  A stray token now fails with `Error: <command> takes no extra
  arguments.` plus the usage line (rc 2) before any config is read,
  instead of being silently ignored; `teardown all --runtime` in
  particular no longer silently runs the main-conf teardown (the runtime
  sweep stays `teardown --runtime`). Valid forms are unchanged; no
  action required.
- **Netns-probe failures and inherited working directories.** A
  `sudo -u <account> egresslock …` run from a directory the account
  cannot traverse no longer fails: the engine, `egresslock-verify`, and
  the `build-gateway` / `build-egl-base` helpers run their
  container-runtime commands from `/`, and relative paths
  such as `proxy-env --out` still resolve against the directory you
  ran the command from. Relative Podman settings (`CONTAINERS_CONF`,
  the registries/storage configs, `TMPDIR`, `XDG_*`) keep that same
  invocation-directory meaning too. Before this release, that failure
  — and any other failed rootless-netns probe — led with a fixed
  AppArmor diagnosis (an AppArmor label and the pasta profile, with
  AppArmor fixes to try) even though AppArmor was often not the cause. A failed
  probe now prints podman's actual error and routes on it: an
  AppArmor-shaped error (`rc 126` / `permission denied`) leads with
  `sudo egresslock-setup apparmor check` (apply the amendment only
  when the check says it is required); any other error points at the
  netns-inspection page. No rc or policy behavior change; no action
  required.

### Internal

- **`bash tests/run.sh` takes a per-harness timeout override** —
  `EGRESSLOCK_HARNESS_TIMEOUT=<seconds>` (positive integer, default 600)
  lets a slow or loaded host finish the engine battery; CI keeps 600.
- **The engine battery's `egl139` section runs faster** — setup-only
  legs now restore a green fixture snapshot instead of re-running
  `ensure`, and the shared mocks fork fewer helper processes; its 142
  passing assertions are unchanged.
- **The `egl139` conntrack fixtures are fidelity-checked** — the mock
  keeps the old awk's numeric port comparison (so a leading-zero
  `:0443` still matches `dport=443`), snapshot/restore preserves the
  real `$STATE/opslog` and `callorder.log`, and a failed snapshot or
  copy fails the section by name instead of being masked by cleanup.
  Eleven new `egl362` assertions cover those paths, including an
  end-to-end `:0443` revocation and a survivor that must fail closed.

## 0.9.0 - 2026-10-23

> **Operator-important changes:**
>
> **Action required:**
> 1. **Rebuild the gateway image to pick up the openssl and xz-utils
>    security fixes (DSA-6531-1, DSA-6549-1, October 2026).** A kit
>    upgrade alone does **not** patch a running gateway. Run the
>    commands **as each workload account** (not root — the image is
>    per-account), then replace every gateway profile in that account:
>    ```sh
>    sudo -iu <workload-account>
>    ```
>    then
>    ```sh
>    egresslock build-gateway --force && egresslock ensure --replace-gateway <profile>
>    ```
>    Rebuild once per account, and repeat `--replace-gateway` for every
>    gateway profile in it. Until then, running gateways keep the old
>    base; see
>    [The gateway image](docs/reference/gateway-image.md#rebuild-and-replace-the-gateway).
> 2. **Security — if you built the `egl-base` example image before
>    2026-10-14, rebuild it in each `workload account` (account with
>    egresslock profiles) to get the latest security patches.**
>    Versions of curl in the image build prior
>    to that have a security vulnerability (CVE-2026-92392; Debian
>    DSA-6558-1). Run the image building helper **as the workload
>    account** (not root — the image is per-account):
>    ```sh
>    sudo -iu <workload-account>
>    ```
>    then
>    ```sh
>    /usr/share/egresslock/examples/egl-base/build-egl-base --force
>    ```
>    If you are using the `egl-base` image, you should run this command,
>    even if you don't upgrade to v0.9.0. You can skip this if you never built
>    `egl-base`.
> 3. **Config path option has been removed**
>    - The `egresslock --config <file>` option and the `EGRESSLOCK_CONF`
>    environment variable have been removed to simplify commands and
>    improve security; `egresslock` now always expects a profile's config at 
>    `<account-home>/.config/egresslock/<profile>.conf`, account home from
>    `getent passwd`.
>    - **If you used a custom path for `--config or EGRESSLOCK_CONF`** you must
>    move the files to `<account-home>/.config/egresslock/` and no longer
>    use those options.
>    - **If you used the standard path but still specified `--config or
>    EGRESSLOCK_CONF`**, simply don't use the options any more.
> 4. **.conf files no longer allow multiple `profile` blocks.** It is
>    unlikely you did so, but if you hand-edited a .conf to add added
>    multiple profiles into one file, split them into one `<name>.conf`
>    per profile.
>
> **Important but no action required:**
> 1. **Drift warnings from `allow-host` entries can now be resolved.**
>   The fix depends on the shape of the name's DNS answer:
>    - **(a) several A records in one answer, the order rotating:**
>   `egresslock verify` used to warn `drift:` every cycle because only the
>   first address was pinned; it now pins the whole answer, so the warning
>   stops once you run `egresslock ensure <profile>`.
>    - **(b) one A record drawn from a rotating pool, the value changing
>   over time** (e.g. `github.com` over SSH): a single-address answer has
>   no stable set to pin, so it stays a documented workaround — see
>   [Rotating names](docs/reference/rotating-names.md).
> 2. Setup commands have been changed and new ones added to simplify
>   install steps. Updated/changed steps can be found on readme, install
>   guides, and help text. `sudo egresslock-setup init`, 
>   `sudo egresslock-setup import`, and `sudo egresslock-setup help`
> 3. New `egresslock` commands: `egresslock help <command>`,
>    `egresslock drop-unauthorized`, and `egresslock proxy-env --out`;
> 4. Other important changes are listed below.

### Security

- **`egresslock disallow-host` ends every revoked flow it can observe, and
  proves it** — old DNS addresses, the peer-direction conntrack entry, and
  half-closed or still-starting flows — keeps connections another remaining
  rule still authorizes, and refuses with a named error instead of a bare
  `removed:` when it cannot prove severance. One accepted gap behind a green
  `removed:` (0.9.0): a packet accepted just before the swap but recorded in
  conntrack only after the check runs is invisible to the check — in that
  sub-second window one flow can still finish behind a green `removed:`.
- **A failed `egresslock disallow-host` recovers.** It puts the rule
  back when it can, or names the state and prints `egresslock
  drop-unauthorized <profile> <port>` — one idempotent command that ends
  the leftover revoked flows and keeps the still-allowed ones.
- **`egresslock` serializes profile-mutating commands** under one
  account-wide lock (`ensure`, `allow`, `disallow`, `allow-host`,
  `disallow-host`, `teardown`, `init`), so two can no longer race or undo
  each other; tune the wait with `EGRESSLOCK_LOCK_WAIT`.
- **Gateway base refreshed for DSA-6531-1 (openssl) and DSA-6549-1
  (xz-utils / liblzma5).** The pinned `debian:13-slim` digest now
  carries `libssl3t64 3.5.7-1~deb13u3` and
  `liblzma5 5.8.1-1+deb13u2`.
  A kit upgrade alone does not patch a running gateway — see the
  action-required item 1 above.

### New features

- **`allow-host` pins up to 16 addresses, not just one.** A profile that
  allows a name resolving to several addresses now pins the whole answer
  (deduplicated, sorted) instead of only the first record — so
  `egresslock verify` stops warning `drift:` when the resolver merely
  reorders the records, and every pinned member is reachable. A larger
  answer truncates to 16 with a named `note:`. Existing profiles pick
  this up on their next `egresslock ensure <profile>`.

### Command syntax changes

- **(new)** `egresslock-setup import --account <acct> --from <conf>`
  copies a profile pair (conf + allowlist) into an account without
  clobbering: it stages the files as the account, validates them with the
  deployed engine, commits allowlist-first, and never touches
  `unit.env`, linger, or the timer.
- **(new)** `egresslock drop-unauthorized <profile> <port>` ends the
  leftover connections a revocation could not clear and checks none
  remain; safe to re-run.
- **(new)** `egresslock help <command>` (plus `egresslock help config`
  and `egresslock help env`) prints one command's flags and examples;
  `egresslock --help` is now a short command index.
- **(new)** `egresslock proxy-env <profile> --out` writes the proxy env
  file (mode 0600) under your runtime dir and prints its path, so
  `podman run --env-file="$(egresslock proxy-env <profile> --out)"`
  replaces the `egresslock proxy-env <profile> > <file>` redirect you had
  to write yourself; `--out=<path>` writes elsewhere and is refused if
  the directory is world-writable.
- **(changed)** `egresslock-setup init` is now pathless: it wires the
  conf(s) already in the fixed confdir and, with `--enable`, arms linger
  + the verify timer. Use `--from <conf>` (or `import` first) when the
  conf is not in place yet.
- **(changed)** `egresslock-setup` now takes verbs (`init`, `doctor`,
  `build-gateway`, `apparmor add|remove|check`, `help`); the legacy flag
  forms (`--doctor`, `--build-gateway`, `--apparmor-*`) keep working.
- **(removed)** `egresslock --config <file>` and `EGRESSLOCK_CONF` — see
  *Action required*.

### Changed

- **`egresslock-setup` ends with a next-step block** (become the account,
  build the profile, verify) and the gateway build is quiet by default —
  one line, with the full output in
  `~/.config/egresslock/gateway-build.log` (last lines shown on failure).
- **Removed the one-time pre-rename compatibility code** carried since
  the product rename: the config-directory migration and its
  both-directories refusal, the legacy unit/prefix sweeps in
  `install-kit.sh`/`uninstall-kit.sh` and the `.deb` postinst, the
  leftover-kit warning, `EGRESSLOCK_LEGACY_PREFIX`, and stale
  `agent_policy` table handling. `/tmp` scratch files are now
  `egresslock-*`. Current installs need no action; a host still on the
  old config directory gets the normal missing-config error (move the
  files by hand), and a leftover pre-rename timer enablement shows as a
  doctor problem.

### Fixed

- **`egresslock-setup doctor` diagnoses a failed verify unit instead of
  sending you to an empty journal.** It checks whether the account's
  verify timer is armed first, names the real cause (a timer that could
  not start versus a verify run that failed), shows a failed verify
  service's last and next run, and prints a runnable clear/re-arm
  command plus the check that proves the fix. A disabled, masked, or
  static timer is named as such; the timer journal is shown only when
  an enabled timer fails to start, and the service journal on service
  failures. A 203/EXEC already explained by the verify-unit row is a
  note, not a second problem. No configuration change or action is
  needed.
- **`egresslock denied <profile>` showed only the oldest 8 MB of the
  gateway access log.** It now reads the newest bytes with a 32 MB
  default, so the most recent denials are the ones shown; change the cap
  with `EGRESSLOCK_DENIED_MAX_BYTES` (smaller reads less, `0` reads the
  whole log).
- **`egresslock denied <profile>` now also lists Squid
  `TCP_DENIED_ABORTED/403`** CONNECT denies that were previously
  invisible.
- **`egresslock-setup doctor` output is actionable as printed:** real
  unit names, runnable `journalctl` hints (bounded with `-n 20`), a
  one-line health summary, and `--account` scoping.
- **`egresslock doctor` no longer misreads Podman's `<no value>` base
  label** — `base unknown (pre-label image)` replaces a false `stale:`
  row.
- **`egresslock verify` prints the real cause** of a gateway exec
  failure instead of claiming an invalid Squid config.
- **The `egresslock-setup` AppArmor hint is shorter** and prints only
  when wiring an account.
- **A torn starter conf pair is refused** with the missing path and fix,
  never silently healed.
- **One `egresslock ensure <profile>` recovers from an unclean
  rootless-runtime stop** (retries the wedged container removal).
- **`egresslock-setup doctor` rows carry `OK:`/`PROBLEM:`/`NOTE:`
  tokens.**
- **First-run gateway builds use docker image format** — the HEALTHCHECK
  warning is gone and the healthcheck is honored.

### Docs

- **Threat model:** states what live testing confirmed for `allow-host`
  pins and profile isolation, and names bash `/dev/tcp` / `/dev/udp` as
  proxy-ignoring clients.
- **Corrections:** install-walk file modes, the delete-profile `.pins`
  move, and the `allow`/`disallow` pages now state the gateway-restart
  session severance.
- **New [Rotating names](docs/reference/rotating-names.md) reference**
  and worked [GitHub recipe](examples/recipes/github.md) for names whose
  DNS rotates a single address; the `drift:` troubleshooting guidance
  names the case.
- **Recipes:** the opencode/hermes in-container `apt` steps now carry the
  capabilities they need under `--cap-drop=all`.
- **New reference page: [File
  locations](docs/reference/file-locations.md)** — where egresslock keeps
  its files, with the mode and what removes or regenerates each.
- **New troubleshooting page: [Revoking an allow-host rule whose name no
  longer resolves](docs/troubleshooting/revocation-name-gone.md).**
- **New recipe: [deploy one conf+allowlist pair across multiple servers
  with `egresslock-setup import`](examples/recipes/fleet-deploy.md)** —
  stage one pair, run root `import`/`init` per host, then the
  account-side `ensure` that applies a re-pin.

### Internal

- **Code comments in the shipped scripts were corrected and tightened**
  for accuracy and brevity; no behavior change.
- **`bash tests/run.sh --track fast`** skips registered slow sections
  (the default battery and the pre-release gate still run everything);
  low-value tests pruned; per-section timings recorded.
- **Test mocks no longer fork `basename`/`mkdir` on hot paths** — the
  engine battery runs ~33% faster.

## 0.8.0 - 2026-10-10

> **Operator-important changes:**
>
> **Action required:**
> - **Rebuild the gateway image to pick up the openssl security
>   fix (DSA-6531-1, October 2026).** A kit upgrade alone does
>   **not** patch a running gateway. Rebuild and replace per
>   [The gateway image](docs/reference/gateway-image.md#rebuild-and-replace-the-gateway);
>   until then, running gateways keep the old base.
> - **Make sure your workload launchers use the hardened flags.**
>   Every production `podman run` should carry `--cap-drop=all` and
>   `--security-opt=no-new-privileges` (add `--userns=keep-id` and
>   `--read-only` where compatible). Egresslock's policy confines
>   network egress; it does not harden the workload's capabilities or
>   filesystem — a workload with extra capabilities can act outside the
>   policy. The threat model's launcher obligation assumes these flags
>   are in place; the shipped recipes now model it. Update any launcher
>   you built from an earlier recipe, and confirm your own. See
>   [container hardening](docs/reference/container-hardening.md). The
>   minimal `podman run` in the quickstarts teaches the policy loop, not
>   a production launcher.

### Added

- **New shared example image `egl-base` ships with the kit.** The
  quickstarts now use one local example image, built from the same
  pinned Debian base as the gateway, with ssh, curl, dig, ping and
  rsync included. The README builds it as a numbered step, via a helper at
  `examples/egl-base/build-egl-base` that reports whether
  `localhost/egl-base:latest` is missing, current, or built from an
  older Debian base, and rebuilds it when needed (re-run it after a kit
  upgrade whose notes move the base pin). Build it once per account:
  `podman build -t localhost/egl-base:latest
  /usr/share/egresslock/examples/egl-base` (prefix installs:
  `/opt/egresslock/examples/egl-base`). No action required unless you
  follow the quickstarts.

- **New `egresslock build-gateway` — rebuild the gateway image without
  root.** Run it in your account's own shell (no root, no `--account`)
  and it builds from the deployed gateway context next to the engine.
  If the image is missing or was built from an older base pin, it
  builds; if it already matches the deployed pin it prints an explicit
  up-to-date line (`--force` rebuilds anyway — the squid package is
  deliberately unpinned, so a same-pin rebuild can take squid security
  updates). `egresslock-setup --build-gateway` keeps working and now
  delegates to the same command. No user action needed — additive; the
  old command now rebuilds a stale image instead of silently skipping
  it. A running gateway is not replaced: after a rebuild, run
  `egresslock ensure --replace-gateway <profile>` (below).

- **New `egresslock ensure --replace-gateway <profile>` — easily
  replace a running gateway.** After `egresslock build-gateway` (or
  `build-gateway --force`), run `egresslock ensure --replace-gateway
  <profile>` to start a new gateway container from the current image.
  That replacement drops the profile's proxied sessions until the new
  gateway answers; ensure prints a stderr notice. A missing or unsafe
  target image is refused **before** removing the running gateway
  container (earlier ensure steps — network / anchor / nft / pins —
  are not undone). Duplicate `--replace-gateway` is a usage error.
  Plain `egresslock ensure <profile>` is unchanged: a healthy gateway is
  not replaced. `allow` / `disallow` / starting an agent never pass
  this flag. Action required only when a release note tells you to
  rebuild the gateway: after upgrading the kit, run the two commands.
  Custom `EGRESSLOCK_GW_IMAGE` remains per-invocation — set it on the
  `--replace-gateway` ensure if you use a non-default image.

- **`egresslock doctor` now shows the gateway image's base and flags a
  stale image.** The `gateway image:` row reports the base digest the
  image was built from (and its build date), and prints `stale: base
  pin moved` when the installed kit's deployed pin expects a different
  base — the same check `sudo egresslock-setup --doctor --account
  <acct>` already showed, now available in the account shell with no
  root. Advisory only: exit codes are unchanged, and a missing image is
  information, not an error. No action on install; when the release
  notes say the base moved, rebuild with `egresslock build-gateway` and
  replace the running gateway — see [The gateway
  image](docs/reference/gateway-image.md#rebuild-and-replace-the-gateway).

### Security

- **A failed `ensure` now removes the bad kit container instead of
  leaving it running.** When the live-hardening assertion on the
  gateway or the anchor detects a wrong or unreadable capability state,
  `ensure` force-removes that container (`podman rm -f`) before failing
  closed. Previously it reported the failure but left the
  `--restart=always` container alive — including the gateway sitting on
  the policy's egress-exemption path. If the removal itself fails, the
  error names the runtime error and the exact manual
  `podman rm -f <name>` command; the exit code is unchanged (1).
  `verify` stays read-only and only reports the bad state.
- **Gateway base refreshed for DSA-6531-1 (openssl).** The pinned
  `debian:13-slim` digest now carries `libssl3t64 3.5.7-1~deb13u3`.
  A kit upgrade alone does not patch a running gateway — see the
  action-required item above.

### Docs

- **Recipe launches are gated on the preflight.** Every recipe now
  chains `egresslock ensure <profile> && egresslock verify <profile>
  && podman run …`, so a failed check stops the launch instead of
  continuing unprotected. Re-copy the block if you kept an earlier
  copy. The rule is stated in [container
  hardening](docs/reference/container-hardening.md).

- **Shipped examples use consistent baseline hardening.** The recipe
  set recommends `--cap-drop=all`,
  `--security-opt=no-new-privileges`, and `--userns=keep-id`
  (read-only where compatible), plus a single hardening-defaults
  reference.
- **Threat model: the T9-neighbor clause is hedged.** The clause now
  carries the "flags passed are not flags honored" caveat for the
  CVE-2026-94603 discard class.
- **The gateway image's maintenance story is now documented in one
  place.** When to rebuild, what the doctor's `stale:` means, and the
  rebuild/replace steps live on
  [The gateway image](docs/reference/gateway-image.md); install,
  upgrade, uninstall, container hardening, and the doctor output link
  it. No behavior change; no action needed.
- **Threat model T9 wording is honest about capabilities.** The T9
  row and the cap-drop guidance now name the capability each
  technique needs: adding an interface address needs
  `CAP_NET_ADMIN`, absent from the tested default set; creating the
  tested `AF_PACKET`/`SOCK_RAW` socket under plain defaults returned
  `EPERM` in the tested lane. The cap-drop guidance is precise:
  `--cap-drop=all` drops defaults without neutralizing an explicit
  `--cap-add`. No operator action; the cap-drop obligation is
  unchanged.
- **Quickstart and setup docs were revised for readers.** Several pages
  were simplified and focused on the task at hand. No action required.
- **Uninstall guide now leads with the `.deb` path.** For a `.deb`
  install, disable the account's verify timer
  (`sudo systemctl disable --now egresslock-verify@<account>.timer`)
  then `sudo apt remove egresslock`; the checkout `uninstall-kit.sh`
  path is the manual/prefix variant. The recipes now state the two
  safety prerequisites: stop and remove every workload attached to a
  kit network before runtime teardown (teardown deletes the kit's nft
  enforcement and does not remove non-kit-named workloads), and run
  teardown for EVERY account with kit runtime — not only the timer
  accounts — before the host-global AppArmor unapply and package or
  prefix removal. Account examples now create a password-disabled
  service account (`adduser --disabled-password`). No action
  required — existing installs are unchanged until you next
  uninstall.

### Fixed

- **`disallow-host` no longer false-fails when the rootless netns
  lacks `/proc/net/nf_conntrack`.** The severance proof now reads
  the conntrack table over ctnetlink (`conntrack -L`) — the same
  interface as the revocation probe and flush — so the command
  completes with `removed:` instead of `ct unproven`. When the
  flush deletes nothing, there is no `warn: ... failed`. No action
  required.

- **Command usage errors now surface before config errors.** An
  invalid invocation (unknown or duplicate flag, missing/extra
  argument, bad destination) reports its usage error and exits 2
  even when the profile config is missing, malformed, or
  unreadable. Valid invocations are unchanged; a missing config
  still exits 2 with `no profile config`, and a broken config still
  fails closed. No action required.

## 0.7.0 - 2026-10-01

> **Operator-important changes:**
>
> **Action required:**
> - **None for a default install** — the kit-built gateway and the
>   digest-pinned anchor fallback do not carry a checkpoint
>   annotation. Stop reading here unless you override the kit
>   images (`EGRESSLOCK_GW_IMAGE`, `EGRESSLOCK_ANCHOR_IMAGE`, or
>   an unpinned `localhost/base:latest` in the account store). A
>   checkpoint-annotated override now fails `ensure` closed with
>   a named error — replace the image. Optional check:
>   `egresslock ensure <profile>`.

> **Behavior changes:**
> - **Kit containers now refuse checkpoint-annotated images and
>   assert their live hardening** (CVE-2026-94603 /
>   GHSA-2cvf-wqm6-wr9g). `ensure` and both `verify` verbs fail
>   closed, named, when a kit image — gateway or anchor, including
>   `EGRESSLOCK_GW_IMAGE` / `EGRESSLOCK_ANCHOR_IMAGE` overrides —
>   carries the annotation
>   `io.podman.annotations.checkpoint.runtime.name`, or when the
>   live capability state of a kit container reads wrong or
>   unreadable (in-container `CapEff` / `NoNewPrivs`, read from the
>   container's PID 1). A running kit container whose live hardening
>   is wrong is replaced by the next `ensure`, not blessed. Override
>   images must provide `cat` for the live read — a missing `cat`
>   is a named failure, never a skip.
> - **Fresh-account first `ensure` now pulls the anchor's resolved
>   image before inspecting it** (the same pull `podman run` already
>   performed, moved ahead of the new annotation check); a failed
>   pull fails closed with a named manual-pull instruction.

### Security

- **CVE-2026-94603 / GHSA-2cvf-wqm6-wr9g — checkpoint-annotation
  images and discarded sandbox flags.** The kit now refuses to run
  its own gateway/anchor images when they carry the
  container-checkpoint annotation, and asserts the launch-time
  hardening pair (`--cap-drop=all`,
  `--security-opt=no-new-privileges`) live on both kit containers at
  `ensure` and on both `verify` verbs — the assertion reads the
  container's own PID 1, not `podman inspect`, which this CVE
  invalidates as an oracle. The annotation-triggered checkpoint
  interpretation is live-observed in the kit's VM lane (guest Podman
  5.4.2, in the advisory range: a benign annotated image was treated
  as a checkpoint and failed at the restore import); the silent
  flag-discard end state and the affected range / fixed floor
  (≥ 5.8.8 / 6.1.3) are per the advisory — not observed or confirmed
  from this tree. Workload launchers remain the operator's
  obligation; the kit ships no workload preflight.

### Docs

- Threat model: the cap-drop operator obligation now records that
  **flags passed are not flags honored**, with the same
  live-observed / advisory split as above; the T9 row notes that a
  silently discarded workload cap-drop (not observed from this tree)
  would make the recorded residual reachable with no operator-cap
  violation. Overview and release checklist mirror the hedge; the
  stale claim that the kit enforces the pair "only on the gateway"
  is fixed (the anchor is covered too).

### Internal

- Test scripts derive the release base from `VERSION_BASE` instead
  of hardcoding it.
- Docs ship-gate path containment hardened: normalized link targets
  outside the tree root are rejected.
- Real-host smoke matrix for the runtime seam (live Podman / pasta
  spine; operator live pass green; private tree only).

## 0.6.0 - 2026-09-28

> **Operator-important changes:**
>
> **Action required:**
> - **`rule public-only` is removed.** Most confs need no action —
>   the kit never created this rule; if you didn't add
>   `rule public-only` to your conf by hand, you can stop reading
>   here. If you did, delete the line and run
>   `egresslock ensure <profile>` (until then, every engine
>   command fails closed at parse: `unknown rule kind
>   'public-only'`). There is no like-for-like replacement for
>   "accept all public IPv4" — build a similar policy by adding
>   each destination individually with `allow` (allowlist) /
>   `allow-host` (direct).
>
> **Behavior changes:**
> - **Clearer error messages.** Engine messages now say what went
>   wrong in plain words, instead of citing inscrutable codes.
> - **Better error message when `disallow-host` cannot confirm the
>   old connection is really dead.** It now tells you the exact
>   state and prints the command that finishes the job by hand,
>   instead of the old dead "retry disallow-host" hint.
> - **The threat model's T14 accepted risk (the `public-only` drop
>   set is narrower than all special-use ranges) is retired:** the
>   mode is gone, so the risk no longer exists to accept.

### Internal

- **Runtime seam.** Every Podman invocation now goes through a small
  adapter layer in the engine instead of being scattered across
  command paths. Podman-only today; the seam exists so a second
  container runtime can be added later without touching policy
  logic.
- **In-file decomposition.** The engine, setup, and doctor paths
  were split into smaller per-step helpers (config loading, ensure,
  teardown, denied listing, doctor kit checks). No behavior change —
  outputs are byte-identical, and the test battery
  (`bash tests/run.sh`) pins the order.

## 0.5.0 - 2026-09-24

> **Operator-important changes:**
>
> **Action required:**
> - **New dependency: `conntrack`.** The kit now requires the
>   `conntrack` package (used by `disallow-host` to sever revoked
>   direct flows immediately). Install it with the other requirements:
>   `sudo apt-get install -y podman netavark nftables conntrack`.
> - **Do NOT run workloads with `--network=container:<gateway>` or
>   `--network=host`.** Those network modes bypass the profile policy
>   (the container shares the gateway's netns or the host network and
>   can reach outside the allowlist). The threat model now names these
>   as operator obligations — attach workloads to the profile network
>   only.
> - **Run `egresslock ensure <profile>` once per profile that uses
>   `allow-host` after this upgrade.** `verify` now checks allow-host
>   pins against an ensure-time record; the record is written on the
>   first `ensure` after upgrading. Until then, `verify` fails closed
>   with a re-ensure hint. Profiles with no allow-host pins are
>   exempt — no record is needed and `verify` stays silent.
> - **Trailing-dot allowlist entries are rejected** (`name.` no longer
>   silently accepted). If you have such an entry, `allow`/`ensure`
>   will now fail closed with a named error — remove the trailing dot.
> - **IP-literal proxy requests are now denied, even when the IP's
>   reverse-DNS name is allowlisted.** The gateway no longer adopts
>   rDNS for IP-literal CONNECTs — the name allowlist only ever
>   matches hostnames, never IPs. Example: if you had
>   `curl -x http://gateway http://192.0.2.1:8080/` working because
>   `192.0.2.1` reverse-resolves to an allowlisted name, it is now
>   denied (403). To pin an address, use the address-pin mechanism:
>   `egresslock allow-host <profile> 192.0.2.1:8080`.
>
> **Behavior changes:**
> - **`disallow-host` now severs established direct flows at once.**
>   Revoking a pin previously left flows alive until conntrack expiry
>   (~5 days); now the mutator kills them immediately (and fails
>   loudly if it cannot prove severance). If you rely on a grace
>   window after revoking pins, note this change.
> - **After a reboot**, `verify` (and the drift timer) now report the
>   unpolicied state by name ("network exists but policy does not —
>   run: `egresslock ensure <profile>`") instead of failing
>   generically.

### Security

All items below are findings from the adversarial live-testing
program (tier-2 batteries), confirmed live, with the fix shipped in
this release. Severity per the finding record:

- **HIGH — cross-profile source spoof.** A co-located privileged
  sibling could no longer be used to route cross-profile traffic:
  saddr-keyed accepts are now scoped to the profile's own bridge (a
  packet arriving on another profile's bridge no longer matches), and
  a counted anti-spoof drop closes the cross-profile source-spoof
  path.
- **HIGH — rDNS relay through the gateway.** An attacker-controlled
  PTR record could relay TCP through the gateway when the
  IP-literal's reverse-DNS name matched an allowlisted entry; the
  generated `dstdomain` ACLs now carry `-n`, so the proxy never
  adopts rDNS for IP-literal requests.
- **HIGH — revoked pins kept serving established flows.**
  `disallow-host` left flows alive after revocation — a fail-open on
  the documented kill-switch: revoked pins kept serving existing
  flows until conntrack expiry (~5 days), invisible to a green
  `verify`. Revocation is now a real kill-switch: the mutator deletes
  the revoked destination's conntrack entries after the atomic
  ruleset swap and proves the data-path state is gone before printing
  `removed:`. Missing `conntrack` tooling aborts with nothing changed
  — never a silent lie.
- **HIGH — tampered allow-host pins passed verify.** An in-place
  chain edit rekeying a live pin's address went undetected (drift-warn
  only). `ensure` now records installed pin addresses, and `verify`
  fails closed with a named error when the live chain diverges from
  the record.
- **MEDIUM — policy silently absent after reboot.** A persisted
  profile network could carry no policy after reboot while `verify`
  failed generically. `verify` (and the drift timer) now name the
  stale-unpolicied state and point at `egresslock ensure <profile>`.

### Fixes

- **Trailing-dot allowlist entries** (e.g. `example.test.`) were
  accepted by the grammar but could never match — a silently dead
  allowlist line. They are now rejected with a named error.

### Added

- Documented as a first-class troubleshooting path: the `read-timeout`
  knob for long non-streaming calls (slow local inference), with a
  dedicated recipe and a rewritten, simpler troubleshooting page.

### Docs

- Threat model now names operator obligations for network modes
  (`--network=container:<gateway>`, `--network=host`) and narrows
  several earlier claims.
- Added local-LLM setup tips, including the `read-timeout` knob for
  long silent inference calls.

## 0.4.0 - 2026-09-21

### Security

- A co-located container holding elevated capabilities could bypass
  the egress policy by spoofing the gateway's source IP address. The
  gateway exemption is now bound to the gateway's MAC address as well,
  so the gateway IP alone no longer satisfies it.

### Fixes

- `ensure` on an already-converged profile no longer restarts gateways
  or severs proxied sessions — an unchanged profile is a no-op.
- First-time policy creation is now a single atomic nft transaction:
  no unprotected window between creating the policy and installing its
  rules.
- The drift-check timer now verifies all profiles in the account
  confdir, not just the wired one.
- `allow-host` with an unresolvable name fails with one clean error
  plus a remediation hint instead of raw nft output.

### Added

- New per-profile conf knob `read-timeout <seconds>` (default 900,
  always emitted) for long silent non-streaming calls through the
  proxy.
- Commands now disclose which config and profiles they resolved to on
  stderr — every time, including piped output.

### Kit

- Shipped systemd units carry generated-file/do-not-modify comments,
  and the deb installer discloses every systemd unit mutation it
  performs.

### Docs

- Threat-model updated with live adversarial-probe evidence; new
  host-service connectivity page.

## 0.3.0 - 2026-09-19

### Security

- First-create ordering hardening: starts the anchor before
  installing policy, creates the profile chain with its rules in one
  transaction, and installs policy before gateway startup. This
  removes the previous empty-chain and gateway-start exposure; the
  remaining bootstrap race before policy installation is tracked
  separately.
- Threat-model honesty pass: the docs now state plainly what the
  gateway does and does not defend against (DNS/egress enforcement
  is not host-compromise protection), instead of implying stronger
  isolation than is delivered.

### Fixes

- Uninstall hardening: the removal paths are constrained and the
  `--prefix` value is charset-validated, so a malformed prefix can
  no longer widen what gets deleted.
- Co-install guard: installing the `.deb` where an explicit-prefix
  deploy already owns the shared tree now fails closed with an
  explanation instead of silently shadowing it.

### Tests / packaging

- `egresslock-setup --doctor` gained verify-unit health rows: shadow
  detection for stray `/etc` unit fragments, ExecStart-target
  mismatch, failed instances, and timer wiring for the periodic
  re-verify service.
- Test-battery growth across the engine and kit suites; on the
  public tree the cases that need private-tree fixtures skip with a
  named `SKIP` line by design.

## 0.2.0 - 2026-09-16

### Tests / packaging

- Hermetic test battery: the suites no longer hang or read the real
  host (package database, `/usr/bin` guard, nftables, pasta,
  AppArmor status, user-namespace probes). The public tree runs the
  same harness, skipping private-tree fixtures by name.
- Bounded network-namespace probes: a wedged rootless-netns call is
  a named 5-second failure instead of an indefinite hang during
  ensure / verify / doctor; `timeout(1)` (coreutils) is required and
  named when missing.
- Explicit-prefix deploys fail closed instead of silently consuming
  a co-installed `.deb`'s shared tree.
- `EGRESSLOCK_UB_BIN` / `EGRESSLOCK_USERNS_SYSCTL` environment hooks
  for test harnesses — no-ops when unset.

## 0.1.1 - 2026-09-12

Tests-only hotfix: the shipped test suite invoked packaging and
internal files that are deliberately not published with the snapshot;
the affected cases now skip cleanly when those files are absent, so
`bash tests/run.sh` is green on the public tree. The version base
stayed `0.1.0` — this release exists as the corresponding public
snapshot commit only (no tag was minted).

## 0.1.0 - 2026-09-12

Initial release: the egresslock engine (per-profile nftables egress
policy, allowlist-driven, fail-closed by default), rootless Podman
gateway/anchor runtime, install/uninstall kit (`.deb` and
explicit-prefix paths), gateway container image, AppArmor profile,
systemd verify units and timer, and the mock test battery.
