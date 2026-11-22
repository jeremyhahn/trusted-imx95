#!/usr/bin/env bash
# policy-check.sh: host policy check of a signed AHAB container against
# recorded values (issue #12; docs/boot-container/secure-boot-test-plan.md
# cases C2, C3, C4; docs/boot-container/signing-pipeline.md "Policy check").
#
#   policy-check.sh <container.bin> <policy file> [<manifest>]
#
# The manifest (default scripts/ahab/container-manifest.yaml) lists the image's
# containers in order, each with a role (nxp or oem): an oem position names the
# image entries (core_id, image_type) its container must carry exactly; an nxp
# position carries the sha256 pin of the vendor container. A missing, empty or
# malformed manifest, or a container count, order or entry list that differs
# from it, FAILS.
#
# Parses the image with the pinned SPSDK (nxpimage ahab parse and SPSDK's own
# AHAB parser). Each OEM container is checked against the policy file: the hash
# of its own SRK table, used_srk_id, srk_revoke_mask and fuse_version. The nxp
# container is checked against its pinned digest and the complete vendor
# record (NXP_* keys below, all mandatory, all exact). Each OEM image entry
# is checked for core_id, image_type, the sha256 of the image bytes its header
# references, load_address and (if listed) entry_point. A missing, empty or unreadable
# policy file, or a missing field in either input, FAILS: nothing is skipped.
# Every non-zero byte of the image and of each nxp binary container must lie
# inside a parsed container's header, signature block or referenced image;
# otherwise it FAILS naming the offset.
#
# The policy file is plain KEY=VALUE lines, parsed here and never sourced:
#   SRK_TABLE_HASH=<hex>        compared as a case-insensitive hex string
#   USED_SRK_ID=<integer>       compared numerically
#   SRK_REVOKE_MASK=<hex|int>   compared numerically
#   FUSE_VERSION_MIN=<integer>  every OEM container's fuse_version must be >= this
#   NXP_CONTAINER_SHA256=<hex>  the pin an nxp manifest position says "policy"
#                               for (else the environment variable of that name)
#   NXP_SRK_TABLE_HASH, NXP_USED_SRK_ID, NXP_SRK_REVOKE_MASK,
#   NXP_FUSE_VERSION            the vendor record, mandatory; every value is
#                               compared exactly (no floor for the vendor)
#   <NAME>_IMAGE_SHA256, <NAME>_LOAD_ADDRESS, <NAME>_ENTRY_POINT
#                               values a manifest image entry names as
#                               policy:<KEY> (else the environment)
# Comments (#) and blank lines are allowed; an unknown, repeated or missing
# key is an error.
#
# Never touches a board, a fuse or a key. The .bcf fuse scripts nxpimage
# writes are deleted unread. Exit 0 ("policy: OK") or 1 ("policy: FAILED").
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
FAMILY=mimx9596
REVISION=b0

fail() {
	echo "policy-check: $*" >&2
	echo "policy: FAILED"
	exit 1
}

{ [ $# -eq 2 ] || [ $# -eq 3 ]; } || fail "usage: policy-check.sh <container.bin> <policy file> [<manifest>]"
bin=$1
policy=$2
manifest=${3:-$here/container-manifest.yaml}
[ -f "$bin" ] && [ -r "$bin" ] || fail "no such container: $bin"
[ -f "$policy" ] && [ -r "$policy" ] || fail "no such (or unreadable) policy file: $policy"
[ -s "$policy" ] || fail "empty policy file: $policy"
bin=$(realpath "$bin")

# num <text>: prints the numeric value of 0x<hex> or <decimal>, else fails.
num() { # <text> <max>
	local d
	# Bash arithmetic is signed 64-bit, so range is settled on the string
	# first: leading zeros are stripped and anything longer than 4 digits
	# (far above every field maximum) is rejected before any $(( )).
	if [[ "$1" =~ ^0[xX]([0-9a-fA-F]+)$ ]]; then
		d=${BASH_REMATCH[1]}
		d=${d#"${d%%[!0]*}"}
		[ ${#d} -le 4 ] || return 1
		d=$((16#${d:-0}))
	elif [[ "$1" =~ ^[0-9]+$ ]]; then
		d=$1
		d=${d#"${d%%[!0]*}"}
		[ ${#d} -le 4 ] || return 1
		d=$((10#${d:-0}))
	else
		return 1
	fi
	[ "$d" -le "$2" ] || return 1
	echo "$d"
}

# Field widths. The script states none, so each is the narrowest width the
# container header holds as nxpimage ahab parse reports it: used_srk_id is a
# 2-bit selector (0..3), srk_revoke_mask a 4-bit mask (0..0xF), fuse_version
# one byte (0..255). The policy and the container are held to the same range.
MAX_ID=3
MAX_MASK=15
MAX_FUSE=255

# trim <text>: prints <text> without leading and trailing whitespace.
trim() {
	local s=$1
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s' "$s"
}

# --- The policy file: keys, no sourcing.
declare -A pol=()
while IFS= read -r line || [ -n "$line" ]; do
	line=$(trim "${line%$'\r'}")
	case "$line" in "" | "#"*) continue ;; esac
	[[ "$line" == *=* ]] || fail "policy line is not KEY=VALUE: $line"
	k=$(trim "${line%%=*}")
	v=$(trim "${line#*=}")
	case "$k" in
	SRK_TABLE_HASH | USED_SRK_ID | SRK_REVOKE_MASK | FUSE_VERSION_MIN) ;;
	NXP_CONTAINER_SHA256 | NXP_SRK_TABLE_HASH | NXP_USED_SRK_ID | NXP_SRK_REVOKE_MASK | NXP_FUSE_VERSION) ;;
	[A-Z0-9_]*_IMAGE_SHA256 | [A-Z0-9_]*_LOAD_ADDRESS | [A-Z0-9_]*_ENTRY_POINT) ;;
	*) fail "unknown policy key: $k" ;;
	esac
	[ -z "${pol[$k]+x}" ] || fail "repeated policy key: $k"
	[ -n "$v" ] || fail "empty value for policy key: $k"
	pol[$k]=$v
done <"$policy"
for k in SRK_TABLE_HASH USED_SRK_ID SRK_REVOKE_MASK FUSE_VERSION_MIN; do
	[ -n "${pol[$k]+x}" ] || fail "missing policy key: $k"
done
[[ "${pol[SRK_TABLE_HASH]}" =~ ^[0-9a-fA-F]+$ ]] || fail "SRK_TABLE_HASH is not hex"
num "${pol[USED_SRK_ID]}" "$MAX_ID" >/dev/null || fail "USED_SRK_ID is not an integer in 0..$MAX_ID"
num "${pol[SRK_REVOKE_MASK]}" "$MAX_MASK" >/dev/null || fail "SRK_REVOKE_MASK is not hex or an integer in 0..$MAX_MASK (0xF)"
num "${pol[FUSE_VERSION_MIN]}" "$MAX_FUSE" >/dev/null || fail "FUSE_VERSION_MIN is not an integer in 0..$MAX_FUSE"
# The vendor record for the nxp container: mandatory and compared exactly.
for k in NXP_SRK_TABLE_HASH NXP_USED_SRK_ID NXP_SRK_REVOKE_MASK NXP_FUSE_VERSION; do
	[ -n "${pol[$k]+x}" ] || fail "missing policy key: $k"
done
[[ "${pol[NXP_SRK_TABLE_HASH]}" =~ ^[0-9a-fA-F]+$ ]] || fail "NXP_SRK_TABLE_HASH is not hex"
num "${pol[NXP_USED_SRK_ID]}" "$MAX_ID" >/dev/null || fail "NXP_USED_SRK_ID is not an integer in 0..$MAX_ID"
num "${pol[NXP_SRK_REVOKE_MASK]}" "$MAX_MASK" >/dev/null || fail "NXP_SRK_REVOKE_MASK is not hex or an integer in 0..$MAX_MASK (0xF)"
num "${pol[NXP_FUSE_VERSION]}" "$MAX_FUSE" >/dev/null || fail "NXP_FUSE_VERSION is not an integer in 0..$MAX_FUSE"
nxp_pin=${pol[NXP_CONTAINER_SHA256]:-${NXP_CONTAINER_SHA256:-}}

# --- The container, through the pinned SPSDK.
venv=$("$here/spsdk-venv.sh")
nxpimage=$venv/bin/nxpimage
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
case "$(cd "$work" && pwd -P)/" in "$root"/*) fail "the work directory $work is inside the clone; set TMPDIR outside it" ;; esac

mkdir "$work/parsed"
"$nxpimage" ahab parse -f "$FAMILY" -r "$REVISION" -b "$bin" -o "$work/parsed" >"$work/parse.log" 2>&1 ||
	{ tail -n 5 "$work/parse.log" >&2; fail "nxpimage ahab parse failed for $bin"; }
rm -f "$work"/parsed/*.bcf
# The image-binding values the manifest may name (policy:<KEY>), for the parser.
: >"$work/extras"
for k in "${!pol[@]}"; do
	case "$k" in *_IMAGE_SHA256 | *_LOAD_ADDRESS | *_ENTRY_POINT) printf '%s=%s\n' "$k" "${pol[$k]}" >>"$work/extras" ;; esac
done

# Every container the image holds is accounted for, and none is skipped. SPSDK's
# own parser reads the whole image: the containers in file order, grouped by
# role (a run of nxp containers is one position: SPSDK merges them into one
# binary container), checked against the manifest for count, order, image
# entries, the nxp digest pin and byte coverage. srk_set none, or anything not
# nxp or oem, FAILS. Output: "I <text>" info lines and one
# "R <index> <role> <used_srk_id> <revoke mask> <fuse_version> <srk table hash>"
# record per AHAB container.
pcfg=$work/parsed/parsed_config.yaml
[ -f "$pcfg" ] || fail "nxpimage ahab parse wrote no parsed_config.yaml"
records=$("$venv/bin/python" -I -c '
import glob, hashlib, os, re, sys
import yaml
from spsdk.image.ahab.ahab_image import AHABImage
from spsdk.utils.family import FamilyRevision

family, revision, image_path, manifest_path, parsed_dir, pin, extras_path = sys.argv[1:8]
fam = FamilyRevision(family, revision)
extras = {}
for l in open(extras_path).read().splitlines():
    k, _, v = l.partition("=")
    extras[k] = v


def resolve(v, n, j, k):
    # "policy:<KEY>" takes the value at release from the policy file, else
    # the environment; anything else is a literal.
    if not v.startswith("policy:"):
        return v
    key = v[7:]
    if not re.fullmatch(r"[A-Z0-9_]+_(IMAGE_SHA256|LOAD_ADDRESS|ENTRY_POINT)", key):
        sys.exit("manifest position %d image %d: %s names an unusable policy key %r" % (n, j, k, key))
    got = extras.get(key) or os.environ.get(key, "")
    if not got:
        sys.exit("manifest position %d image %d: %s: no value for %s in the policy file or environment" % (n, j, k, key))
    return got.strip()


def norm(s):
    return s.strip().lower().replace("_", "-")


try:
    with open(manifest_path) as f:
        man = yaml.safe_load(f)
except Exception as e:
    sys.exit("manifest %s: cannot be read: %s" % (manifest_path, e))
if not isinstance(man, dict) or set(man) != {"containers"} or not isinstance(man["containers"], list) or not man["containers"]:
    sys.exit("manifest %s: empty or malformed (want a non-empty containers: list)" % manifest_path)
want = []
for n, e in enumerate(man["containers"]):
    if not isinstance(e, dict) or e.get("role") not in ("nxp", "oem"):
        sys.exit("manifest position %d: role must be nxp or oem" % n)
    if e["role"] == "nxp":
        if set(e) != {"role", "sha256"} or not isinstance(e["sha256"], str):
            sys.exit("manifest position %d: an nxp position takes exactly role and sha256" % n)
        p = pin if e["sha256"] == "policy" else e["sha256"]
        if not re.fullmatch(r"[0-9a-fA-F]{64}", p):
            sys.exit("manifest position %d: no 64-hex sha256 pin (NXP_CONTAINER_SHA256 in the policy file or environment)" % n)
        want.append(("nxp", p.lower()))
    else:
        if set(e) != {"role", "images"} or not isinstance(e["images"], list) or not e["images"]:
            sys.exit("manifest position %d: an oem position takes exactly role and a non-empty images list" % n)
        imgs = []
        for j, m in enumerate(e["images"]):
            ok = isinstance(m, dict) and {"core_id", "image_type", "sha256", "load_address"} <= set(m) <= {"core_id", "image_type", "sha256", "load_address", "entry_point"}
            if not ok or not all(isinstance(v, str) for v in m.values()):
                sys.exit("manifest position %d image %d: an image entry takes core_id, image_type, sha256, load_address and optionally entry_point, all strings" % (n, j))
            vals = {k: resolve(m[k], n, j, k) for k in m if k in ("sha256", "load_address", "entry_point")}
            if not re.fullmatch(r"[0-9a-fA-F]{64}", vals["sha256"]):
                sys.exit("manifest position %d image %d: sha256 is not 64 hex digits" % (n, j))
            for k in ("load_address", "entry_point"):
                if k in vals and not re.fullmatch(r"0[xX][0-9a-fA-F]{1,16}", vals[k]):
                    sys.exit("manifest position %d image %d: %s is not a hex address (0x...)" % (n, j, k))
            imgs.append((norm(m["core_id"]), norm(m["image_type"]), vals["sha256"].lower(),
                         int(vals["load_address"], 16), int(vals["entry_point"], 16) if "entry_point" in vals else None))
        want.append(("oem", imgs))


def parse(data, what):
    try:
        off = AHABImage.find_offset_of_ahab(data, True)
        return off, AHABImage.parse(data[off:], fam)
    except Exception as e:
        sys.exit("%s: cannot be parsed: %s" % (what, e))


def cover(data, off, img, what):
    # Every non-zero byte lies in a container header + signature block, or in
    # an image a container references.
    ok = bytearray(len(data))
    for k, c in enumerate(img.ahab_containers):
        s = off + c.get_container_offset(k)
        spans = [(s, s + c.length)] + [(off + i.image_offset, off + i.image_offset + i.image_size) for i in c.image_array]
        for a, b in spans:
            if b > len(data):
                sys.exit("%s: container %d reaches offset 0x%x, past the end (0x%x): truncated" % (what, k, b, len(data)))
            ok[a:b] = b"\x01" * (b - a)
    for i, v in enumerate(data):
        if v and not ok[i]:
            sys.exit("%s: non-zero byte at offset 0x%x lies outside every container" % (what, i))


data = open(image_path, "rb").read()
off, img = parse(data, "image")
cover(data, off, img, "image")
groups = []
for k, c in enumerate(img.ahab_containers):
    st = c.flag_srk_set.name.lower()
    if st not in ("nxp", "oem"):
        sys.exit("container %d: srk_set %s (an unsigned or unrecognised container)" % (k, st))
    if st == "nxp" and groups and groups[-1][0] == "nxp":
        groups[-1][1].append((k, c))
    else:
        groups.append((st, [(k, c)]))
got_roles = [g[0] for g in groups]
want_roles = [w[0] for w in want]
if got_roles != want_roles:
    sys.exit("the image holds %s containers (in order) but the manifest lists %s" % (got_roles, want_roles))
bins = sorted(glob.glob(os.path.join(parsed_dir, "ahab_nxp_containers_*.bin")))
if len(bins) != want_roles.count("nxp"):
    sys.exit("%d nxp binary container(s) written, the manifest lists %d" % (len(bins), want_roles.count("nxp")))
nb = 0
for pos, ((role, members), w) in enumerate(zip(groups, want)):
    if role == "nxp":
        raw = open(bins[nb], "rb").read()
        nb += 1
        o2, i2 = parse(raw, "nxp container (position %d)" % pos)
        cover(raw, o2, i2, "nxp container (position %d)" % pos)
        dg = hashlib.sha256(raw).hexdigest()
        if dg != w[1]:
            sys.exit("position %d: nxp container sha256 %s differs from the pin %s" % (pos, dg, w[1]))
        print("I position %d nxp container sha256 OK" % pos)
    else:
        c = members[0][1]
        have = []
        for i in c.image_array:
            seg = data[off + i.image_offset:off + i.image_offset + i.image_size]
            have.append((norm(i.flags_core_id_name), norm(i.flags_image_type_name), hashlib.sha256(seg).hexdigest(),
                         int(i.load_address), int(i.entry_point)))
        if len(have) != len(w[1]):
            sys.exit("position %d (container %d): %d image entries, the manifest lists %d" % (pos, members[0][0], len(have), len(w[1])))
        for j, (hv, wv) in enumerate(zip(have, w[1])):
            for what, a, b in zip(("core_id", "image_type", "sha256", "load_address"), hv, wv):
                if a != b:
                    sys.exit("position %d image %d: %s %s differs from the manifest %s" % (pos, j, what, a, b))
            if wv[4] is not None and hv[4] != wv[4]:
                sys.exit("position %d image %d: entry_point 0x%x differs from the manifest 0x%x" % (pos, j, hv[4], wv[4]))
        print("I position %d oem image entries OK" % pos)
    for k, c in members:
        h = c.signature_block.srk_assets.compute_srk_hash().hex().upper()
        print("R %d %s %d %d %d %s" % (k, role, int(str(c.flag_used_srk_id), 0), int(str(c.flag_srk_revoke_mask), 0), int(str(c.fuse_version), 0), h))
' "$FAMILY" "$REVISION" "$bin" "$manifest" "$work/parsed" "$nxp_pin" "$work/extras" 2>"$work/inspect.log") ||
	{ tail -n 3 "$work/inspect.log" >&2; fail "the image does not satisfy the container manifest $manifest"; }

declare -a r_role=() r_id=() r_mask=() r_fuse=() r_hash=()
count=0
n_oem=0
while IFS=' ' read -r t a b c d e f; do
	case "$t" in
	I) echo "policy: $a $b $c $d $e $f" ;;
	R)
		r_role[a]=$b r_id[a]=$c r_mask[a]=$d r_fuse[a]=$e r_hash[a]=$f
		count=$((count + 1))
		[ "$b" != oem ] || n_oem=$((n_oem + 1))
		;;
	esac
done <<<"$records"
[ "$count" -ge 1 ] || fail "the image holds no container"
[ "$n_oem" -ge 1 ] || fail "no OEM container: nothing in the image is signed with the OEM SRK table"

# Cross-check: SPSDK writes one ahab_<set>[<n>]_srk0_hash.txt per OEM container,
# or a single shared file when every OEM table is identical. Their number is
# the number of OEM containers, or one, and each must be a hash this check
# computed from an OEM container's own SRK table.
nf=0
for f in "$work"/parsed/ahab_*_hash.txt; do
	[ -f "$f" ] || continue
	[ -s "$f" ] || fail "an SRK table hash file is empty: $(basename "$f")"
	h=$(tr -d '[:space:]' <"$f")
	h=${h^^}
	[[ "$h" =~ ^[0-9A-F]+$ ]] || fail "the SRK table hash in $(basename "$f") is not hex"
	found=1
	for ((i = 0; i < count; i++)); do
		{ [ "${r_role[$i]}" = oem ] && [ "${r_hash[$i]}" = "$h" ]; } && found=0
	done
	[ "$found" = 0 ] || fail "the SRK table hash file $(basename "$f") matches no OEM container's own SRK table"
	nf=$((nf + 1))
done
[ "$nf" -ge 1 ] || fail "nxpimage ahab parse wrote no SRK table hash"
[ "$nf" -eq "$n_oem" ] || [ "$nf" -eq 1 ] || fail "$n_oem OEM container(s) but $nf SRK table hash file(s)"

# --- Compare, one line per field per container.
bad=0
report() { # <label> <ok 0|1> <container> <policy>
	if [ "$2" = 0 ]; then
		echo "policy: $1 OK"
	else
		echo "policy: $1 MISMATCH (container $3, policy $4)"
		bad=1
	fi
}
echo "policy: $count container(s) to check"
# cmp_role <index> <suffix> <hash> <id> <mask> <min> <label prefix>: the four values.
cmp_role() {
	local i=$1 sfx=$2 ph=${3^^} pid pmask pmin pre=$7 r
	[ "${r_hash[$i]}" = "$ph" ] && r=0 || r=1
	report "${pre}srk_table_hash$sfx" "$r" "${r_hash[$i]}" "$ph"
	pid=$(num "$4" "$MAX_ID")
	[ "${r_id[$i]}" -eq "$pid" ] && r=0 || r=1
	report "${pre}used_srk_id$sfx" "$r" "${r_id[$i]}" "$pid"
	pmask=$(num "$5" "$MAX_MASK")
	[ "${r_mask[$i]}" -eq "$pmask" ] && r=0 || r=1
	report "${pre}srk_revoke_mask$sfx" "$r" "${r_mask[$i]}" "$pmask"
	pmin=$(num "$6" "$MAX_FUSE")
	if [ "$7" = nxp_ ]; then
		[ "${r_fuse[$i]}" -eq "$pmin" ] && r=0 || r=1
		report "${pre}fuse_version$sfx" "$r" "${r_fuse[$i]}" "$pmin"
	else
		[ "${r_fuse[$i]}" -ge "$pmin" ] && r=0 || r=1
		report "${pre}fuse_version$sfx" "$r" "${r_fuse[$i]}" ">= $pmin"
	fi
}
for ((i = 0; i < count; i++)); do
	[ "$count" -eq 1 ] && sfx= || sfx=" [container $i]"
	if [ "${r_role[$i]}" = oem ]; then
		cmp_role "$i" "$sfx" "${pol[SRK_TABLE_HASH]}" "${pol[USED_SRK_ID]}" "${pol[SRK_REVOKE_MASK]}" "${pol[FUSE_VERSION_MIN]}" ""
	else
		cmp_role "$i" "$sfx" "${pol[NXP_SRK_TABLE_HASH]}" "${pol[NXP_USED_SRK_ID]}" "${pol[NXP_SRK_REVOKE_MASK]}" "${pol[NXP_FUSE_VERSION]}" "nxp_"
	fi
done

if [ "$bad" = 0 ]; then
	echo "policy: OK"
else
	echo "policy: FAILED"
	exit 1
fi
