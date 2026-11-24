#!/usr/bin/env bash
# platform-image-repro-compare.sh OUT_A OUT_B: compare two
# platform-image output directories (scripts/platform-image-build.sh --repro
# writes them). Each directory's own SHA256SUMS must match the files in it (a
# file missing, an extra file not listed, or a hash mismatch fails, naming the
# file). Then every artefact must be in both SHA256SUMS with the same hash,
# (a differing or missing artefact always fails; there is no exception option).
# Then build-info.txt must be readable, carry SOURCE_DATE_EPOCH and a layer
# revision, and match line by line, ignoring only build_seconds= (it differs
# every run).
# Exit 0: "platform-image-repro: OK, N artefacts identical"; 1: each difference
# named with both values; 2: usage error. No network, no bitbake.
# Provisional, pending the owner's answer on #14.
set -uo pipefail

say() { echo "platform-image-repro: $*" >&2; }
usage() {
	say "$*"
	echo "usage: platform-image-repro-compare.sh OUT_A OUT_B" >&2
	exit 2
}

dirs=()
while [ $# -gt 0 ]; do
	case $1 in
	-*) usage "unknown option $1" ;;
	*) dirs+=("$1") ;;
	esac
	shift
done
[ "${#dirs[@]}" -eq 2 ] || usage "need exactly two output directories"
for d in "${dirs[@]}"; do
	[ -d "$d" ] || usage "$d is not a directory"
done

bad=0
fail() {
	say "$*"
	bad=1
}

# load SUMS-ARRAY-PREFIX DIR LABEL: read DIR/SHA256SUMS into names_$p (order)
# and a map hash_$p, verifying the files in DIR against it.
# shellcheck disable=SC2034 # read through namerefs in load
declare -A hash_a hash_b listed_a listed_b
# norm NAME: the artefact name without Yocto's build timestamp (IMAGE_VERSION_SUFFIX
# in IMAGE_NAME: "<image>-<machine>.rootfs-<14 digits>.<ext>"), so two builds made
# at different times compare member by member. A name without one stays as is.
norm() {
	if [[ $1 =~ ^(.*\.rootfs)-[0-9]{14}(\..*)$ ]]; then
		printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
	elif [[ $1 =~ ^(.*)-[0-9]{14}(\..*)$ ]]; then
		printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
	else
		printf '%s\n' "$1"
	fi
}
names_a=()
names_b=()
load() {
	local p=$1 dir=$2 line h n k f got
	local -n names=names_$p hashes=hash_$p listed=listed_$p
	if [ ! -f "$dir/SHA256SUMS" ]; then
		fail "$dir has no SHA256SUMS"
		return
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		h=${line%% *}
		n=${line#*[ ]}
		n=${n#[ *]}
		k=$(norm "$n")
		listed["$n"]=1
		if [ -n "${hashes[$k]+x}" ]; then
			fail "$k: two files in $dir normalise to the same name ($n)"
		else
			names+=("$k")
			hashes["$k"]=$h
		fi
		if [ ! -f "$dir/$n" ]; then
			fail "$n: listed in $dir/SHA256SUMS but missing from $dir"
			continue
		fi
		got=$(sha256sum <"$dir/$n")
		got=${got%% *}
		[ "$got" = "$h" ] || fail "$n: bytes do not match $dir/SHA256SUMS (listed $h, actual $got)"
	done <"$dir/SHA256SUMS"
	for f in "$dir"/*; do
		[ -e "$f" ] || [ -L "$f" ] || continue
		n=${f##*/}
		case $n in SHA256SUMS | build-info.txt) continue ;; esac
		[ -n "${listed[$n]+x}" ] || fail "$n: in $dir but not listed in its SHA256SUMS"
	done
}
load a "${dirs[0]}"
load b "${dirs[1]}"

same=0
n=
for n in "${names_a[@]+"${names_a[@]}"}"; do
	if [ -z "${hash_b[$n]+x}" ]; then
		fail "$n: only in ${dirs[0]} (hash ${hash_a[$n]})"
	elif [ "${hash_a[$n]}" = "${hash_b[$n]}" ]; then
		same=$((same + 1))
	else
		fail "$n differs: ${hash_a[$n]} (${dirs[0]}) vs ${hash_b[$n]} (${dirs[1]})"
	fi
done
for n in "${names_b[@]+"${names_b[@]}"}"; do
	[ -z "${hash_a[$n]+x}" ] || continue
	fail "$n: only in ${dirs[1]} (hash ${hash_b[$n]})"
done

# build-info.txt: every line but build_seconds= must match.
info_a=()
info_b=()
readinfo() {
	local -n arr=$1
	local line
	local f=$2/build-info.txt sde=0 layer=0
	if [ ! -e "$f" ]; then
		fail "$f: missing"
		return 1
	fi
	if [ ! -f "$f" ]; then
		fail "$f: not a regular file, cannot be read"
		return 1
	fi
	if ! { exec 3<"$f"; } 2>/dev/null; then
		fail "$f: cannot be read"
		return 1
	fi
	while IFS= read -r line <&3 || [ -n "$line" ]; do
		case $line in
		build_seconds=*) continue ;;
		SOURCE_DATE_EPOCH=?*) sde=1 ;;
		layer_*_commit=?*) layer=1 ;;
		esac
		arr+=("$line")
	done
	exec 3<&-
	if [ "${#arr[@]}" -eq 0 ]; then
		fail "$f: empty"
		return 1
	fi
	if [ "$sde" -eq 0 ]; then
		fail "$f: no SOURCE_DATE_EPOCH= line with a value"
		return 1
	fi
	if [ "$layer" -eq 0 ]; then
		fail "$f: no layer_<name>_commit= line with a value"
		return 1
	fi
}
# Both are read even when the first fails, so each bad file is named; a failed
# read can never skip the comparison and still print OK.
ok_a=0
ok_b=0
readinfo info_a "${dirs[0]}" && ok_a=1
readinfo info_b "${dirs[1]}" && ok_b=1
if [ "$ok_a$ok_b" != 11 ]; then
	[ "$bad" -ne 0 ] || fail "build-info.txt could not be read"
else
	total=${#info_a[@]}
	[ "${#info_b[@]}" -ge "$total" ] || total=${#info_b[@]}
	i=0
	while [ "$i" -lt "$total" ]; do
		la=${info_a[$i]}
		lb=${info_b[$i]}
		if [ "$la" != "$lb" ]; then
			ka=${la%%=*}
			kb=${lb%%=*}
			if [ "$ka" = "$kb" ]; then
				fail "build-info $ka differs: ${la#*=} (${dirs[0]}) vs ${lb#*=} (${dirs[1]})"
			else
				fail "build-info line $((i + 1)) differs: '$la' (${dirs[0]}) vs '$lb' (${dirs[1]})"
			fi
		fi
		i=$((i + 1))
	done
	[ "${#info_a[@]}" -eq "${#info_b[@]}" ] ||
		fail "build-info.txt has ${#info_a[@]} lines in ${dirs[0]} and ${#info_b[@]} in ${dirs[1]}"
fi

[ "$bad" -eq 0 ] || exit 1
echo "platform-image-repro: OK, $same artefacts identical"
