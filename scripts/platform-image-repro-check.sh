#!/usr/bin/env bash
# Reproducible-build check of the image (ROADMAP ftpm (b), docs/ftpm/build.md "Reproducible build").
#
# usage: platform-image-repro-check.sh DEPLOY_A DEPLOY_B
#
# DEPLOY_A and DEPLOY_B are the deploy directories of two clean builds of the same inputs.
# The one documented difference is /etc/trusted-imx95-rootfs-id (random per do_rootfs run,
# docs/platform-image/build.md "Reproducible builds") and what follows from it: the root
# partition's marker sector, so the root partition and the .wic digest. Compared:
#   - the fTPM TA's stripped ELF, tee.bin, Image and the board's .dtb files, byte for byte;
#   - the .wic's boot and tee-data partitions, byte for byte (found by GPT name), and the GPT
#     entries' names, starts and sizes (not the GUIDs: unconfirmed whether wic draws them per build);
#   - the root file system from the rootfs archive: member names, types, modes, owners, link
#     targets and content hashes, less the id file; the first differing member is named.
# A differing artefact prints both SHA-256s; the exit status is nonzero. A match prints one line
# per artefact and exits 0. A missing artefact on either side fails. Nothing is written to either
# directory (scratch in mktemp -d, removed on exit). bitbake is never run.
set -euo pipefail

TA_UUID=bc50d971-d4c9-42c4-82cb-343fb7f37896
ID_FILE=etc/trusted-imx95-rootfs-id

usage() { echo "usage: $0 DEPLOY_A DEPLOY_B" >&2; exit 2; }
[ $# -eq 2 ] || usage
A=$1
B=$2
for d in "$A" "$B"; do
	[ -d "$d" ] || { echo "platform-image-repro-check: $d is not a directory" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "platform-image-repro-check: python3 is required" >&2; exit 2; }
command -v sfdisk >/dev/null 2>&1 || { echo "platform-image-repro-check: sfdisk is required" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
bad() { echo "DIFF  $*"; fails=$((fails + 1)); }
ok() { echo "OK    $*"; }

cat >"$tmp/h.py" <<'PY'
import hashlib, json, sys, tarfile

def sha(f, off=0, size=None):
    h = hashlib.sha256()
    f.seek(off)
    left = size
    while left is None or left > 0:
        buf = f.read(1 << 20 if left is None else min(1 << 20, left))
        if not buf:
            break
        h.update(buf)
        if left is not None:
            left -= len(buf)
    return h.hexdigest()

cmd = sys.argv[1]
if cmd == "gpt":      # gpt DUMP.json -> name start size sectorsize
    t = json.load(open(sys.argv[2]))["partitiontable"]
    if t.get("label") != "gpt":
        sys.exit("not a GPT")
    for p in t["partitions"]:
        print(p.get("name", ""), p["start"], p["size"], t.get("sectorsize", 512))
elif cmd == "range":  # range IMG START SIZE SECTORSIZE -> sha256
    with open(sys.argv[2], "rb") as f:
        print(sha(f, int(sys.argv[3]) * int(sys.argv[5]), int(sys.argv[4]) * int(sys.argv[5])))
elif cmd == "tar":    # tar ARCHIVE IDFILE -> one line per member
    with tarfile.open(sys.argv[2], "r:") as t:
        for m in t:
            n = m.name
            while n.startswith("./"):
                n = n[2:]
            n = n.rstrip("/")
            if n == sys.argv[3]:
                continue
            d = "-"
            if m.isreg():
                d = sha(t.extractfile(m))
            print("%s\t%s\t%o\t%d:%d\t%s:%s\t%s\t%s" % (n, m.type.decode("latin1"), m.mode, m.uid, m.gid,
                  m.uname, m.gname, m.linkname if (m.issym() or m.islnk()) else "-", d))
PY

# deco FILE OUT: print the path of a plain copy (FILE itself when not compressed), the status of
# the decompressor tested (a pipeline would report the last command's status).
deco() {
	local f=$1 out=$2 dec
	case $f in
	*.gz) dec="gzip -dc" ;;
	*.bz2) dec="bzip2 -dc" ;;
	*.xz) dec="xz -dc" ;;
	*.zst) dec="zstd -dc" ;;
	*) printf '%s\n' "$f"; return 0 ;;
	esac
	# shellcheck disable=SC2086 # a word list chosen above
	$dec <"$f" >"$out" 2>/dev/null || { rm -f "$out"; return 1; }
	printf '%s\n' "$out"
}

sha_of() { local s; s=$(sha256sum "$1") || return 1; printf '%s\n' "${s%% *}"; }

# cmp_file NAME PATH_A PATH_B
cmp_file() {
	local n=$1 pa=$2 pb=$3 sa sb miss=0
	[ -f "$pa" ] || { bad "$n: missing in A ($pa)"; miss=1; }
	[ -f "$pb" ] || { bad "$n: missing in B ($pb)"; miss=1; }
	[ "$miss" -eq 0 ] || return 0
	sa=$(sha_of "$pa") || { bad "$n: cannot be read"; return 0; }
	sb=$(sha_of "$pb") || { bad "$n: cannot be read"; return 0; }
	if [ "$sa" = "$sb" ]; then ok "$n $sa"; else bad "$n: A=$sa B=$sb"; fi
}

for rel in "optee-ftpm/$TA_UUID.stripped.elf" tee.bin Image; do
	cmp_file "$rel" "$A/$rel" "$B/$rel"
done

# The board's .dtb files: the names found on either side.
shopt -s nullglob
dtbs=()
for f in "$A"/imx95-19x19-frdm-pro*.dtb "$B"/imx95-19x19-frdm-pro*.dtb; do dtbs+=("${f##*/}"); done
if [ "${#dtbs[@]}" -eq 0 ]; then
	bad "imx95-19x19-frdm-pro*.dtb: none on either side"
else
	while IFS= read -r n; do cmp_file "$n" "$A/$n" "$B/$n"; done < <(printf '%s\n' "${dtbs[@]}" | sort -u)
fi

# one_file DIR GLOB...: the one distinct regular file the globs name (links followed), else fail.
pick() {
	local dir=$1 f r seen="" cnt=0 first=""
	shift
	for g in "$@"; do
		for f in "$dir"/$g; do
			case $f in *.bmap) continue ;; esac
			[ -e "$f" ] || continue
			r=$(readlink -f "$f")
			case " $seen " in *" $r "*) continue ;; esac
			seen="$seen $r"
			cnt=$((cnt + 1))
			first=$r
		done
	done
	[ "$cnt" -eq 1 ] || return 1
	printf '%s\n' "$first"
}

# --- the .wic ---
wa=
wb=
wic_ok=1
wa=$(pick "$A" '*.wic' '*.wic.gz' '*.wic.bz2' '*.wic.xz' '*.wic.zst') || { bad "wic: not exactly one image in $A"; wic_ok=0; }
wb=$(pick "$B" '*.wic' '*.wic.gz' '*.wic.bz2' '*.wic.xz' '*.wic.zst') || { bad "wic: not exactly one image in $B"; wic_ok=0; }
if [ "$wic_ok" -eq 1 ]; then
	pa=$(deco "$wa" "$tmp/a.wic") || { bad "wic: A ($wa) cannot be decompressed (corrupt or truncated)"; wic_ok=0; }
fi
if [ "$wic_ok" -eq 1 ]; then
	pb=$(deco "$wb" "$tmp/b.wic") || { bad "wic: B ($wb) cannot be decompressed (corrupt or truncated)"; wic_ok=0; }
fi
if [ "$wic_ok" -eq 1 ]; then
	for s in a b; do
		img=$pa
		[ "$s" = b ] && img=$pb
		sfdisk --json "$img" >"$tmp/$s.json" 2>/dev/null || { bad "wic: sfdisk cannot read the partition table of $s"; wic_ok=0; break; }
		python3 -I "$tmp/h.py" gpt "$tmp/$s.json" >"$tmp/$s.gpt" || { bad "wic: $s has no usable GPT"; wic_ok=0; break; }
	done
fi
if [ "$wic_ok" -eq 1 ]; then
	# names, starts and sizes (sector counts); GUIDs are not compared
	if cmp -s "$tmp/a.gpt" "$tmp/b.gpt"; then
		ok "wic GPT entries (names, starts, sizes)"
	else
		bad "wic GPT entries differ: A=[$(tr '\n' ';' <"$tmp/a.gpt")] B=[$(tr '\n' ';' <"$tmp/b.gpt")]"
	fi
	for part in boot tee-data; do
		la=$(while read -r n st sz ss; do if [ "$n" = "$part" ]; then echo "$st $sz $ss"; fi; done <"$tmp/a.gpt")
		lb=$(while read -r n st sz ss; do if [ "$n" = "$part" ]; then echo "$st $sz $ss"; fi; done <"$tmp/b.gpt")
		if [ -z "$la" ] || [ -z "$lb" ]; then bad "wic partition $part: not in the GPT of both images"; continue; fi
		# shellcheck disable=SC2086 # "start size sectorsize"
		ha=$(python3 -I "$tmp/h.py" range "$pa" $la) || { bad "wic partition $part: A unreadable"; continue; }
		# shellcheck disable=SC2086
		hb=$(python3 -I "$tmp/h.py" range "$pb" $lb) || { bad "wic partition $part: B unreadable"; continue; }
		if [ "$ha" = "$hb" ]; then ok "wic partition $part $ha"; else bad "wic partition $part: A=$ha B=$hb"; fi
	done
	echo "NOTE  wic root partition and .wic digest not compared: they carry /$ID_FILE"
fi

# --- the root file system ---
ra=
rb=
rt_ok=1
ra=$(pick "$A" '*.rootfs*.tar' '*.rootfs*.tar.gz' '*.rootfs*.tar.bz2' '*.rootfs*.tar.xz' '*.rootfs*.tar.zst') || { bad "rootfs archive: not exactly one in $A"; rt_ok=0; }
rb=$(pick "$B" '*.rootfs*.tar' '*.rootfs*.tar.gz' '*.rootfs*.tar.bz2' '*.rootfs*.tar.xz' '*.rootfs*.tar.zst') || { bad "rootfs archive: not exactly one in $B"; rt_ok=0; }
if [ "$rt_ok" -eq 1 ]; then
	ta=$(deco "$ra" "$tmp/a.tar") || { bad "rootfs archive: A ($ra) cannot be decompressed (corrupt or truncated)"; rt_ok=0; }
fi
if [ "$rt_ok" -eq 1 ]; then
	tb=$(deco "$rb" "$tmp/b.tar") || { bad "rootfs archive: B ($rb) cannot be decompressed (corrupt or truncated)"; rt_ok=0; }
fi
if [ "$rt_ok" -eq 1 ]; then
	python3 -I "$tmp/h.py" tar "$ta" "$ID_FILE" >"$tmp/a.members" 2>"$tmp/a.err" || { bad "rootfs archive: A cannot be read: $(tr '\n' ' ' <"$tmp/a.err")"; rt_ok=0; }
	python3 -I "$tmp/h.py" tar "$tb" "$ID_FILE" >"$tmp/b.members" 2>"$tmp/b.err" || { bad "rootfs archive: B cannot be read: $(tr '\n' ' ' <"$tmp/b.err")"; rt_ok=0; }
fi
if [ "$rt_ok" -eq 1 ]; then
	if cmp -s "$tmp/a.members" "$tmp/b.members"; then
		ok "rootfs members (less /$ID_FILE) $(sha_of "$tmp/a.members")"
	else
		diff "$tmp/a.members" "$tmp/b.members" >"$tmp/members.diff" || true
		first=
		while IFS= read -r l; do
			case $l in '<'*|'>'*) first=$l; break ;; esac
		done <"$tmp/members.diff"
		first=${first%%$'\t'*}
		bad "rootfs members differ; first differing member: ${first#[<>] }"
	fi
fi

if [ "$fails" -ne 0 ]; then
	echo "platform-image-repro-check: $fails artefact(s) differ or are missing" >&2
	exit 1
fi
echo "platform-image-repro-check: all artefacts match"
