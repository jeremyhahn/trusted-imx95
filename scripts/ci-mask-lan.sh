#!/usr/bin/env bash
# scripts/ci-mask-lan.sh: mask the LAN addresses a pool runner's environment
# names (Tenant Agent ruling 887: internal addresses stay out of public
# repositories, and their CI logs count). The pool sets the DEVCACHE_*
# package caches, GOPROXY's LAN module proxy and the LAN CI registry; on a
# forge, the release registry (RELEASE_REGISTRY) and the forge's own host
# (GITHUB_SERVER_URL), which the image publishing and resolving name. A
# BuildKit build echoes its build arguments and `go env` prints GOPROXY.
# Run before any step that builds: for each entry of those variables whose
# host is internal, it prints ::add-mask:: for the entry, its host:port and
# its host, so the runner masks the address in every later line. A host is
# internal when it is a private IPv4 address, or (ci-template v1.53, Tenant
# Agent on trusted-firmware #821) a host name: a single label with no dot
# (a LAN host name) or a name under .internal, .lan, .local, .localdomain,
# .home.arpa, .corp or .intranet (the list of scripts/docs-check.py). Public hosts and keywords (proxy.golang.org, direct,
# off) are left.
# v1.53 (Tenant Agent on go-quicbaas #2667): every variable whose name ends
# in _REGISTRY is scanned (CI_REGISTRY, CI_IMAGE_REGISTRY, RELEASE_REGISTRY,
# a copy's IT_REGISTRY). The template's mask step sets CI_IMAGE_REGISTRY from
# the Actions secret of that name, which the runner already masks whole; this
# script adds the bare host name. The registry is never a `vars` value: Actions
# prints a step's env in its log header before the run body, so no add-mask
# can cover a variable in time. A _REGISTRY_OWNER or other non-host name is
# not scanned.
#
#   usage: scripts/ci-mask-lan.sh
set -euo pipefail

# LOCAL CHANGE to the template file (#159, Codex security P1 at verify 15): the host
# is classified in its canonical form (lower case, one trailing root dot removed),
# since DNS ignores both and `https://FORGE.CORP:3000` or `https://forge.corp.:3000`
# is the same internal host; and a host this script cannot classify (empty, a
# bracketed IPv6 literal, a character outside a-z 0-9 . _ -) fails closed: it is
# treated as internal and masked, and an entry with userinfo before an @ is masked
# whatever its host. Every spelling that can appear later is masked:
# the entry, its authority (userinfo and port included), the host as written and the
# canonical host, with and without the port. For the handbook to take back.
private() {
	local h=${1,,}
	h=${h%.}
	case $h in
	'' | \[*) return 0 ;;
	*[!a-z0-9._-]*) return 0 ;;
	10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;;
	direct | off) return 1 ;;
	*.internal | *.lan | *.local | *.localdomain | *.home.arpa | *.corp | *.intranet) return 0 ;;
	*.*) return 1 ;;
	esac
	return 0
}

declare -A seen=()
mask() {
	if [ -n "$1" ] && [ -z "${seen[$1]:-}" ]; then
		seen[$1]=1
		echo "::add-mask::$1"
	fi
	return 0
}

for v in $(compgen -e); do
	case $v in
	DEVCACHE_* | GOPROXY | *_REGISTRY | GITHUB_SERVER_URL) ;;
	*) continue ;;
	esac
	IFS='|, ' read -ra entries <<<"${!v}"
	for entry in "${entries[@]}"; do
		[ -n "$entry" ] || continue
		authority=${entry#*://}
		authority=${authority%%[/?#]*}
		userinfo=
		hostport=$authority
		case $authority in
		*@*)
			userinfo=${authority%@*}
			hostport=${authority##*@}
			;;
		esac
		case $hostport in
		\[*)
			host=${hostport%%]*}]
			port=${hostport#"$host"}
			;;
		*)
			host=${hostport%%:*}
			port=${hostport#"$host"}
			;;
		esac
		# userinfo before an @ is a credential: masked whatever the host
		case $authority in
		*@*) ;;
		*) private "$host" || continue ;;
		esac
		chost=${host,,}
		chost=${chost%.}
		mask "$entry"
		mask "$authority"
		mask "$userinfo"
		mask "$hostport"
		mask "$host"
		mask "$chost"
		mask "$chost$port"
	done
done
