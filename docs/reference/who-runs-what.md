# Who runs what — root, the container-owner account, the workload

This page answers: **"who is supposed to run which command?"** Three
levels, three separate worlds.

## 1. root — install and forget

Root does exactly two things, once per host / once per account. It
never runs the engine, never starts workloads, never edits policy:

```sh
sudo dpkg -i ./egresslock_<VERSION>_all.deb          # once per host
sudo egresslock-setup --init-conf --enable --account <account>   # once per account
```

## 2. the container-owner account — everything else

The dedicated unprivileged account (`<account>`) owns the policies
and the containers. Every `egresslock` command and every workload
container start runs here:

```sh
sudo -iu <account>      # ... then: egresslock ensure main
```

The engine refuses to run as root — a root run builds policy in
ROOT's store, a separate world nothing else uses
([netns-inspection](../troubleshooting/netns-inspection.md)).

## 3. the workload — inside the container

The workload itself (`curl`, `git`, your app) runs inside the
container. It has no policy knowledge and needs none: egress is
enforced by nftables and the gateway regardless of what the workload
does (removing proxy env does not bypass anything).

### Network modes the kit assumes

Workloads must run on the profile network only. Launching a workload
with `--network=host`, with `--network=container:<gateway>` (sharing
the gateway's network namespace), or dual-homed onto a second network
takes it outside the profile's guarantees: host networking and
shared-gateway-netns both grant raw direct egress past the policy (no
Squid), and a dual-homed container keys as an ordinary profile workload
on its profile leg. The kit does not reject these launch modes — they
are operator obligations, listed with the others in the [threat
model's operator obligations](threat-model.md#operator-obligations-the-kit-does-not-enforce).

## The tilde trap (one gotcha worth knowing)

For a one-off from your own shell, `sudo -iu` switches to the
account's home — but a bare `~` in an argument is expanded by YOUR
shell first, pointing at the wrong home:

```sh
sudo -iu <account> -- egresslock --config '$HOME/.config/egresslock/main.conf' ensure main
#                                             ^ quoted: expanded by the account's shell
```

## Next

- [Create a profile](../quickstart/create-a-profile.md) — the first
  real task at level 2.
