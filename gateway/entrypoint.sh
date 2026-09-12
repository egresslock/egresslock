#!/bin/sh
# egresslock-gateway entrypoint: initialize dirs, create a fail-closed empty
# allowlist if none was mounted, then exec squid in the foreground.
# The container runs as the proxy user with --cap-drop=all (no chown or
# privilege drops possible or needed).
#
# Config selection: egresslock generates a complete config at
# /etc/squid/agent/squid.conf; on first boot only, fall back to the
# image's bootstrap config (empty allowlist => fail closed).
set -eu

ALLOWLIST=/etc/squid/agent/allowlist.conf
CFG=/etc/squid/agent/squid.conf
if [ ! -f "$CFG" ]; then
    CFG=/etc/squid/squid.conf
fi

# Fail closed: no allowlist file -> empty allowlist (Squid treats a
# missing quoted file as an error, so create an empty one; an empty
# dstdomain file matches nothing => all http_access denied).
if [ ! -f "$ALLOWLIST" ]; then
    : > "$ALLOWLIST"
    chmod 640 "$ALLOWLIST"
fi

# Initialize swap dirs if needed, then run squid in the foreground.
# The instance PID file must be removed BOTH before and after squid -z:
# -z writes it as a side effect, and after a SIGKILLed container restart
# a stale file (with a PID-reused number) makes -z or -N abort with
# "Squid is already running" — causing a restart=always crash loop
# (on-host finding, ARC-5).
rm -f /tmp/squid.pid
if ! squid -z -f "$CFG" >/dev/null 2>&1; then
    echo "egresslock-gateway: squid -z failed" >&2
    exit 1
fi
rm -f /tmp/squid.pid

exec squid -N -f "$CFG" -d 0
