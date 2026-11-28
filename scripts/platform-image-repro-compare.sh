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
# The one exception to byte-for-byte: a *.spdx.json SBOM is compared after a
# normalisation (python3, stdlib only): blank-node ids (CreationInfo numbering)
# renumbered by their content, every list sorted by SPDX id or name. BitBake
# emits the same graph in a different order and numbering on each run; nothing
# else is dropped, so a changed version, licence, hash or relationship still
# differs. The bytes of each SBOM are still checked against its SHA256SUMS.
# At least one artefact must be compared: two empty SHA256SUMS fail.
# Exit 0: "platform-image-repro: OK, N artefacts identical" (N >= 1); 1: each
# difference named with both values; 2: usage error. No network, no bitbake.
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

# The image suffixes (the same list as platform-image-verify.sh; a test keeps
# them equal). Metadata (.testdata.json, .manifest, .spdx.json, .wic.bmap) is
# never an image.
IMAGE_SUFFIXES=".wic .wic.zst .wic.gz .wic.xz .wic.bz2 .ext4 .tar.zst .tar.gz .tar.xz .tar.bz2"
is_image() {
	local s
	for s in $IMAGE_SUFFIXES; do
		[[ $1 == *"$s" ]] && return 0
	done
	return 1
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
# spdx_hash FILE: the sha256 of FILE's SPDX JSON in a canonical form: blank-node
# ids ("_:...", the CreationInfo numbering) renumbered by the content of the
# node they name, every list sorted by SPDX id or name (then by content), keys
# sorted. In every id and id reference the per-build task hash is replaced by the
# constant UNIHASH: OE-core's SPDX 3.0 writer builds an id as
# "<SPDX_NAMESPACE_PREFIX>/<PN>-<uuid5>/<BB_UNIHASH>/<suffix>..." (meta/lib/oe/
# sbom30.py new_spdxid, l.358-364 at OE-core 5d1aa5c8; its alias ids already
# carry the literal UNIHASH), so the hash is the 64-hex segment directly after
# the "<PN>-<uuid>" segment. The same graph built twice keeps ids that differ
# only there. The replacement applies only to a value under an id key ("@id",
# "spdxId", "SPDXID") and to a string that equals such an id elsewhere in the
# document (a reference); any other string, a download location for one, is left
# untouched, so a digest differing there still shows. Also constants: the owner
# segment of a licence id and a CreationInfo "created" time (see LICOWNER and
# unihash below). The hash ending a relationship id is replaced by a sha256 of
# that relationship's own normalised content, and every reference to the old id
# is rewritten through that mapping, so relationships with different content
# (from, to, type) keep different ids and a changed reference still shows. A
# relationship that references another relationship is refused (exit 1,
# "unsupported: relationship references relationship <id>"): canonical ids of
# such a graph, a cycle above all, need graph canonicalisation (see relids
# below). The image build
# stamp (".rootfs-<14 digits>") is replaced only in such an id and in the value
# of a "name" key, never in another field (a download location, a version; see
# STAMP and unihash below). Nothing else is removed. Fails (exit 1) when FILE is
# not a JSON document.
read -r -d '' SPDX_NORMALISE_PY <<'PYEOF' || true
import hashlib, json, re, sys

IDK = ("@id", "spdxId", "SPDXID")

# "/<PN>-<uuid 8-4-4-4-12>/<64 hex>" followed by "/" or the end of the string.
UNIHASH = re.compile(
    r"(/[^/]+-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
    r"/[0-9a-f]{64}(?=/|$)"
)


# A licence-expression element is shared between recipe documents: its id sits
# under the namespace of whichever recipe's task ran first, which changes from
# run to run, so the owner segment is replaced by a constant. A relationship id
# ends in a hash that varies from run to run; it is NOT replaced by one
# constant (that would give every relationship of a namespace the same id and
# collapse the references to them). Instead each relationship gets an id
# derived from its own normalised content (see relids below), and every
# reference to the old id is rewritten through that old -> new mapping. A
# relationship that references another relationship is refused (see relids).
LICOWNER = re.compile(r"/spdxdocs/[^/]+/UNIHASH/license/")
RELHASH = re.compile(r"(/UNIHASH/relationship/)[^/]+$")
STAMP = re.compile(r"([._]rootfs)-[0-9]{14}(?![0-9])")


def fixid(s):
    s = UNIHASH.sub(r"\1/UNIHASH", s)
    return LICOWNER.sub("/spdxdocs/OWNER/UNIHASH/license/", s)


def collect(o, ids):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in IDK and isinstance(v, str):
                ids.add(v)
            collect(v, ids)
    elif isinstance(o, list):
        for v in o:
            collect(v, ids)


def unihash(o, ids, key=None):
    # Only a value under an id key, or a string equal to a collected id (a
    # reference), is rewritten; every other string is left as it is. The
    # image build stamp is replaced only in such an id and in the value of a
    # "name" key, never in any other field (a download location, a version).
    if isinstance(o, dict):
        r = {k: unihash(v, ids, k) for k, v in o.items()}
        # An element that several recipe documents write (a recipe, a CVE, a
        # licence) keeps the CreationInfo of whichever document the SBOM merge
        # saw first, so the "created" time of a CreationInfo node varies with
        # task order; it is replaced by a constant (SOURCE_DATE_EPOCH is
        # compared through build-info.txt).
        if r.get("type") == "CreationInfo" and "created" in r:
            r["created"] = "CREATED"
        return r
    if isinstance(o, list):
        return [unihash(v, ids, key) for v in o]
    if isinstance(o, str):
        isid = key in IDK or o in ids
        if isid or key == "name":
            # The image's build stamp (IMAGE_VERSION_SUFFIX, 14 digits after
            # ".rootfs-" or "_rootfs-") is in its file names and their ids.
            o = STAMP.sub(r"\1-STAMP", o)
        return fixid(o) if isid else o
    return o


def canon(o):
    return json.dumps(o, sort_keys=True, separators=(",", ":"))


def blank(s):
    return isinstance(s, str) and s.startswith("_:")


def strip(o):
    # Content with every blank id replaced by one constant, so a node's rank
    # does not depend on the numbering of any node.
    if isinstance(o, dict):
        return {k: strip(v) for k, v in o.items()}
    if isinstance(o, list):
        return [strip(v) for v in o]
    return "_:" if blank(o) else o


defs = {}


def walk(o):
    if isinstance(o, dict):
        for k in IDK:
            if blank(o.get(k)) and o[k] not in defs:
                defs[o[k]] = canon(strip({a: b for a, b in o.items() if a != k}))
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)


def sortkey(x):
    ident = ""
    if isinstance(x, dict):
        for k in IDK + ("name",):
            if isinstance(x.get(k), str):
                ident = x[k]
                break
    return (ident, canon(x))


try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = json.load(fh)
except (OSError, ValueError) as e:
    print("not a readable JSON document: %s" % e, file=sys.stderr)
    sys.exit(1)
allids = set()
collect(doc, allids)
doc = unihash(doc, allids)
walk(doc)
rank = {c: i for i, c in enumerate(sorted(set(defs.values())))}
new = {old: "_:n%d" % rank[c] for old, c in defs.items()}


def rewrite(o, m):
    if isinstance(o, dict):
        return {k: rewrite(v, m) for k, v in o.items()}
    if isinstance(o, list):
        return sorted((rewrite(v, m) for v in o), key=sortkey)
    if isinstance(o, str):
        return m.get(o, o)
    return o


def reldefs(o, defs):
    # Old relationship id -> the relationship's content without its id. If an
    # id is defined twice, the smaller content wins, whatever the order.
    if isinstance(o, dict):
        for k in IDK:
            v = o.get(k)
            if isinstance(v, str) and RELHASH.search(v):
                c = {a: b for a, b in o.items() if a != k}
                if v not in defs or canon(c) < canon(defs[v]):
                    defs[v] = c
        for v in o.values():
            reldefs(v, defs)
    elif isinstance(o, list):
        for v in o:
            reldefs(v, defs)


def strs(o):
    if isinstance(o, dict):
        for v in o.values():
            yield from strs(v)
    elif isinstance(o, list):
        for v in o:
            yield from strs(v)
    elif isinstance(o, str):
        yield o


def relids(o):
    # Old relationship id -> a canonical id: the sha256 of the relationship's
    # normalised content (its own id removed). That is only well defined when a
    # relationship refers to elements, never to another relationship: ids of
    # relationships that refer to one another (a chain, and above all a cycle)
    # would need a canonical labelling of the whole graph, and an id derived
    # round by round collapses distinct cycles or depends on the order of the
    # old ids. Such a document is refused, which is the safe answer for a gate
    # that publishes on a pass. (The SBOMs this build writes have no such
    # reference.)
    defs = {}
    reldefs(o, defs)
    for old, c in sorted(defs.items()):
        for s in strs(c):
            if s in defs or RELHASH.search(s):
                print("unsupported: relationship references relationship %s" % s,
                      file=sys.stderr)
                sys.exit(1)
    m = {}
    for old, c in defs.items():
        h = hashlib.sha256(canon(c).encode("utf-8")).hexdigest()
        m[old] = RELHASH.sub(lambda g: g.group(1) + h, old)
    return m


doc = rewrite(doc, new)
relmap = relids(doc)
print(hashlib.sha256(canon(rewrite(doc, relmap)).encode("utf-8")).hexdigest())
PYEOF
spdx_hash() {
	command -v python3 >/dev/null 2>&1 || {
		say "python3 is needed to compare an SBOM"
		return 1
	}
	python3 -I -c "$SPDX_NORMALISE_PY" "$1"
}
names_a=()
names_b=()
load() {
	local p=$1 dir=$2 line h n k f got nh
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
		case $n in
		*.spdx.json)
			if nh=$(spdx_hash "$dir/$n"); then
				hashes["$k"]=$nh
			else
				fail "$n: cannot normalise the SBOM in $dir"
			fi
			;;
		esac
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
# Nothing compared is not a match: a build that published no artefact must not
# print OK.
if [ "$same" -eq 0 ] && [ "$bad" -eq 0 ]; then
	fail "no artefact to compare: both SHA256SUMS are empty (${dirs[0]}, ${dirs[1]})"
fi

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

# Every target in build-info.txt must have a real wic or rootfs image listed (a
# bmap, manifest or SBOM alone is not an image), in each directory.
need_images() {
	local -n info=$1
	# shellcheck disable=SC2178 # a nameref to an array
	local -n names=$2
	local dir=$3 line tg="" mach="" t k found
	local -a tlist
	for line in "${info[@]}"; do
		case $line in
		targets=*) tg=${line#targets=} ;;
		machine=*) mach=${line#machine=} ;;
		esac
	done
	read -r -a tlist <<<"$tg"
	[ "${#tlist[@]}" -gt 0 ] || { fail "$dir/build-info.txt: targets= is empty or missing"; return; }
	[ -n "$mach" ] || { fail "$dir/build-info.txt: machine= is empty or missing"; return; }
	for t in "${tlist[@]}"; do
		found=0
		for k in "${names[@]+"${names[@]}"}"; do
			case $k in
			"$t-$mach"*) is_image "$k" && found=1 ;;
			esac
		done
		[ "$found" -eq 1 ] || fail "$dir: no wic or rootfs image listed for target $t"
	done
}
[ "$ok_a" -eq 0 ] || need_images info_a names_a "${dirs[0]}"
[ "$ok_b" -eq 0 ] || need_images info_b names_b "${dirs[1]}"

[ "$bad" -eq 0 ] || exit 1
echo "platform-image-repro: OK, $same artefacts identical"
