#!/bin/sh
# Emit the resolver directive from the container's own DNS configuration.
#
# default.conf uses a variable in proxy_pass, which nginx resolves per request
# rather than at startup — that needs an explicit `resolver`. The address is
# assigned when the network is created (podman's aardvark-dns sits on the network
# gateway), so it changes whenever the network is recreated and cannot be
# hardcoded. Pinning a stale address gives 502s on every upstream while nginx
# itself looks perfectly healthy.
#
# Runs via /docker-entrypoint.d before nginx starts.
set -e

ns="$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf 2>/dev/null || true)"

if [ -z "$ns" ]; then
    # Docker's embedded DNS; a reasonable last resort if resolv.conf is unreadable.
    ns=127.0.0.11
    echo "10-resolver.sh: no nameserver in /etc/resolv.conf, falling back to $ns" >&2
fi

printf 'resolver %s valid=10s ipv6=off;\n' "$ns" > /etc/nginx/resolver.conf
echo "10-resolver.sh: using resolver $ns"
