# `torn conf pair` / `allowlist file missing` when the allowlist half is missing

## Symptom

Setup or ensure fails closed over a starter conf whose allowlist is
missing:

    egresslock-setup: torn conf pair; refusing (not repaired; the account cannot be used until the allowlist exists):
      present: /home/<account>/.config/egresslock/main.conf
      missing: /home/<account>/.config/egresslock/main-allowlist
      fix: create the allowlist as the account — an empty file is the valid deny-all starter:
           sudo -u <account> touch /home/<account>/.config/egresslock/main-allowlist
      or start over: if this confdir holds nothing else, move the conf aside and re-run (only this conf moves):
           sudo -u <account> mv /home/<account>/.config/egresslock/main.conf /home/<account>/.config/egresslock/main.conf.bak

    Error: allowlist file missing: /home/<account>/.config/egresslock/main-allowlist (check the profile's 'gateway' directive)

The `touch` hint in that message creates the file under your umask
(0644 on a typical host), while the starter pair is documented 0600.
Use the `install -m 600` command in [Fix](#fix) instead.

## Cause

The `--init-conf` starter is a pair: `main.conf` plus the
`main-allowlist` it names. Current setup stages both under `umask 077`
and renames the allowlist into place first, then the conf; if the conf
rename fails it removes the newly-created allowlist. A crash can
therefore leave an allowlist alone or no half at all, not a conf alone.
This symptom comes from deleting or renaming the allowlist after setup,
or from a confdir first written by an older kit whose pair write was
interrupted.

Setup never creates an allowlist beside an existing conf (it must not
overwrite or silently re-create an operator's allowlist). `verify` and
`ensure` fail closed until an allowlist exists; the tool does not heal
the pair.

## Fix

Add the missing allowlist as the account, with mode 0600. An empty file
is a valid, deny-all allowlist (the shipped starter is empty):

    sudo -u <account> install -m 600 /dev/null /home/<account>/.config/egresslock/main-allowlist

Then re-run setup and ensure:

    sudo egresslock-setup init --init-conf --enable --account <account>
    # as the account:
    egresslock ensure main

If the conf holds nothing you want to keep, start over instead: move
the conf aside and re-run setup — `--init-conf` writes the complete
starter pair again (only this conf moves; the rest of the confdir is
untouched):

    sudo -u <account> mv /home/<account>/.config/egresslock/main.conf \
        /home/<account>/.config/egresslock/main.conf.bak

## Links

- [first-run-checks](../quickstart/first-run-checks.md) — the checks
  right after initial setup, including the first `ensure`.
- [scripts-and-environment](../reference/scripts-and-environment.md) —
  what setup does, flag by flag.
- [which-check](which-check.md) — which doctor/check command answers
  which question.
