#!/usr/bin/env bash
# platform-image-layer-check.sh [DIR]: do the layers platform-image/conf/
# bblayers.conf.template lists satisfy each other? DIR is the tree
# scripts/platform-image-fetch.sh checked out (default as in
# scripts/platform-image-kernel-config.sh). Reads the BBLAYERS paths of the
# template, expanded under DIR (##REPO_DIR## is this clone), and fails when
#   - a listed layer has no conf/layer.conf,
#   - a LAYERDEPENDS_<collection> entry names a collection that no listed
#     layer's BBFILE_COLLECTIONS provides,
#   - a layer's LAYERSERIES_COMPAT_<collection> is missing or shares no series
#     with LAYERSERIES_CORENAMES of openembedded-core (the oe-core layer
#     meta/conf/layer.conf).
# Version constraints (name:N in LAYERDEPENDS) are reported as a note, not
# enforced. The files are parsed as text (plain assignments of one quoted
# string; continuation lines joined): no bitbake runs and no network is
# needed, so the check is weaker than bitbake's own parse
# (scripts/platform-image-parse.sh). Not in CI: it needs a fetched tree.
# Test hooks: PLATFORM_IMAGE_BBLAYERS_TEMPLATE, PLATFORM_IMAGE_REPO_DIR.
# Provisional default, pending the owner's answer on #14.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
dir=${1:-${PLATFORM_IMAGE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/trusted-imx95/platform-image}}
tpl=${PLATFORM_IMAGE_BBLAYERS_TEMPLATE:-$root/platform-image/conf/bblayers.conf.template}
repo=${PLATFORM_IMAGE_REPO_DIR:-$root}
me=platform-image-layer-check

[ -f "$tpl" ] || { echo "$me: $tpl is missing" >&2; exit 1; }
[ -d "$dir/sources" ] || { echo "$me: no fetched tree in $dir (no sources/ directory); run make platform-image-fetch first" >&2; exit 1; }
dir=$(cd "$dir" && pwd -P)

# The BBLAYERS paths: every non-comment token with a ##FETCH_DIR## or
# ##REPO_DIR## prefix.
layers=()
while IFS= read -r l || [ -n "$l" ]; do
	l=${l#"${l%%[![:space:]]*}"}
	case $l in '' | '# '* | '#') continue ;; esac
	for t in $l; do
		case $t in
		'##FETCH_DIR##'/*) layers+=("$dir/${t#'##FETCH_DIR##'/}") ;;
		'##REPO_DIR##'/*) layers+=("$repo/${t#'##REPO_DIR##'/}") ;;
		esac
	done
done <"$tpl"
[ "${#layers[@]}" -gt 0 ] || { echo "$me: no BBLAYERS paths in $tpl" >&2; exit 1; }

declare -A vars=()
bs="\\"
# parse_conf FILE: fills vars from the plain assignments of a layer.conf.
parse_conf() {
	local line cur n op val re
	vars=()
	re='^([A-Za-z0-9_-]+)[[:space:]]*(\?\?=|\?=|\+=|=\+|\.=|=\.|:=|=)[[:space:]]*"(.*)"[[:space:]]*$'
	while IFS= read -r line || [ -n "$line" ]; do
		while [[ $line == *"$bs" ]]; do
			line=${line%"$bs"}
			IFS= read -r cur || cur=
			line+=$cur
		done
		if [[ $line =~ $re ]]; then
			n=${BASH_REMATCH[1]} op=${BASH_REMATCH[2]} val=${BASH_REMATCH[3]}
			case $op in
			'?=' | '??=') if [ -z "${vars[$n]+x}" ]; then vars[$n]=$val; fi ;;
			'=' | ':=') vars[$n]=$val ;;
			*) vars[$n]="${vars[$n]:-} $val" ;;
			esac
		fi
	done <"$1"
}

rc=0
declare -A provided=()
declare -a recs=()
declare -A dep_of=() compat_of=()
corenames=

for p in "${layers[@]}"; do
	rel=${p#"$dir"/}
	rel=${rel#"$repo"/}
	f=$p/conf/layer.conf
	if [ ! -f "$f" ]; then
		echo "$me: layer $rel has no conf/layer.conf ($f)" >&2
		rc=1
		continue
	fi
	parse_conf "$f"
	if [[ $p == */openembedded-core/meta ]]; then
		corenames=${vars[LAYERSERIES_CORENAMES]:-}
	fi
	for c in ${vars[BBFILE_COLLECTIONS]:-}; do
		provided[$c]=1
		recs+=("$rel|$c")
		dep_of["$rel|$c"]=${vars[LAYERDEPENDS_$c]:-}
		compat_of["$rel|$c"]=${vars[LAYERSERIES_COMPAT_$c]:-}
	done
done

if [ -z "$corenames" ]; then
	echo "$me: no LAYERSERIES_CORENAMES in the openembedded-core layer (sources/openembedded-core/meta/conf/layer.conf)" >&2
	rc=1
fi

for r in "${recs[@]}"; do
	rel=${r%%|*} c=${r#*|}
	# "name (>= N)" is the other spelling of "name:N".
	deps=${dep_of[$r]}
	cre='^(.*[^[:space:]])[[:space:]]*\(([<>=]+)[[:space:]]*([0-9]+)\)(.*)$'
	while [[ $deps =~ $cre ]]; do
		deps="${BASH_REMATCH[1]}:${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
	done
	for d in $deps; do
		name=${d%%:*}
		[ "$name" = "$d" ] || echo "$me: note: $rel (collection $c) depends on $d; the version constraint is not enforced"
		if [ -z "${provided[$name]:-}" ]; then
			echo "$me: layer $rel (collection $c): LAYERDEPENDS names collection $name, which no listed layer provides" >&2
			rc=1
		fi
	done
	if [ -z "${compat_of[$r]}" ]; then
		echo "$me: layer $rel (collection $c): no LAYERSERIES_COMPAT_$c" >&2
		rc=1
	elif [ -n "$corenames" ]; then
		ok=0
		for s in $corenames; do
			for have in ${compat_of[$r]}; do
				[ "$have" != "$s" ] || ok=1
			done
		done
		if [ "$ok" -eq 0 ]; then
			echo "$me: layer $rel (collection $c): LAYERSERIES_COMPAT_$c (${compat_of[$r]# }) does not include series ${corenames# }" >&2
			rc=1
		fi
	fi
done

[ "$rc" -eq 0 ] || exit 1
echo "$me: OK (${#layers[@]} layers, ${#provided[@]} collections, series ${corenames# })"
