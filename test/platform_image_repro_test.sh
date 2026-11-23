#!/usr/bin/env bash
# Offline tests of scripts/platform-image-repro-check.sh and its make target, on synthetic deploy
# directories (no bitbake, no board). sfdisk is a stand-in that prints a fixed GPT as JSON.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

chk=$ROOT/scripts/platform-image-repro-check.sh
wt=$(mktemp -d)
trap 'rm -rf "$wt"' EXIT
mkdir -p "$wt/bin"
# 512-byte sectors: boot 2048+2048, root 4096+2048, tee-data 6144+2048
cat >"$wt/geom.json" <<'JSON'
{"partitiontable": {"label": "gpt", "id": "X", "device": "x", "unit": "sectors", "sectorsize": 512,
 "partitions": [
  {"node": "x1", "start": 2048, "size": 2048, "type": "T", "uuid": "U1", "name": "boot"},
  {"node": "x2", "start": 4096, "size": 2048, "type": "T", "uuid": "U2", "name": "root"},
  {"node": "x3", "start": 6144, "size": 2048, "type": "T", "uuid": "U3", "name": "tee-data"}]}}
JSON
# shellcheck disable=SC2016 # the stand-in's own $ words
printf '#!/bin/sh\n[ "$1" = --json ] && [ -f "$2" ] && cat "%s"\n' "$wt/geom.json" >"$wt/bin/sfdisk"
chmod +x "$wt/bin/sfdisk"

has() { grep -qF -- "$2" "$1"; }

# mk DIR [VAR=value ...]: one synthetic deploy directory. Knobs: TEE TA IMG DTB BOOT DATA MEMBER MODE ID ROOT
# (the content of each; ID and ROOT are the allowed differences), WICZ=gz|plain, NOTEE=1 (omit tee.bin).
mk() {
	local d=$1 k v
	shift
	local TEE=tee TA=ta IMG=img DTB=dtb BOOT=boot DATA=data MEMBER=hello MODE=644 ID=id-A ROOT=root-A WICZ=plain NOTEE=0
	for kv in "$@"; do k=${kv%%=*}; v=${kv#*=}; printf -v "$k" '%s' "$v"; done
	rm -rf "$d"
	mkdir -p "$d/optee-ftpm" "$wt/stage"
	printf '%s' "$TA" >"$d/optee-ftpm/bc50d971-d4c9-42c4-82cb-343fb7f37896.stripped.elf"
	[ "$NOTEE" = 1 ] || printf '%s' "$TEE" >"$d/tee.bin"
	printf '%s' "$IMG" >"$d/Image"
	printf '%s' "$DTB" >"$d/imx95-19x19-frdm-pro.dtb"
	local w=$d/img.rootfs-20250101.wic
	truncate -s 5M "$w"
	printf 'EFI PART' | dd of="$w" bs=1 seek=512 conv=notrunc 2>/dev/null
	printf '%s' "$BOOT" | dd of="$w" bs=1 seek=$((2048 * 512)) conv=notrunc 2>/dev/null
	printf '%s' "$ROOT" | dd of="$w" bs=1 seek=$((4096 * 512)) conv=notrunc 2>/dev/null
	printf '%s' "$DATA" | dd of="$w" bs=1 seek=$((6144 * 512)) conv=notrunc 2>/dev/null
	if [ "$WICZ" = gz ]; then gzip -n "$w"; fi
	rm -rf "$wt/stage"
	mkdir -p "$wt/stage/etc" "$wt/stage/usr/bin"
	printf '%s' "$ID" >"$wt/stage/etc/trusted-imx95-rootfs-id"
	printf '%s' "$MEMBER" >"$wt/stage/usr/bin/tool"
	chmod "$MODE" "$wt/stage/usr/bin/tool"
	ln -s tool "$wt/stage/usr/bin/link"
	tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$wt/stage" -cf - . | gzip -n >"$d/img.rootfs-20250101.tar.gz"
}
# run DIR_A DIR_B: sets rc and the output file
run() { rc=0; PATH="$wt/bin:$PATH" bash "$chk" "$1" "$2" >"$wt/out" 2>&1 || rc=$?; [ -z "${REPRO_TEST_DEBUG:-}" ] || cp "$wt/out" "/tmp/repro-out.$((++nrun))"; }
nrun=0

mk "$wt/a"
mk "$wt/b"
run "$wt/a" "$wt/b"
expect "identical inputs: exit 0" test "$rc" -eq 0
expect "identical inputs: one line per artefact" test "$(grep -c '^OK ' "$wt/out")" -ge 7
mk "$wt/b" ID=id-B ROOT=root-B
run "$wt/a" "$wt/b"
expect "only the rootfs id and the root marker differ: exit 0" test "$rc" -eq 0
mk "$wt/b" WICZ=gz
run "$wt/a" "$wt/b"
expect "a compressed wic on one side still matches" test "$rc" -eq 0

# diffcase NAME VAR=value NEEDLE: B differs from A in one knob; must fail and name NEEDLE with both digests.
diffcase() {
	mk "$wt/b" "$2"
	run "$wt/a" "$wt/b"
	expect "$1: exit nonzero" test "$rc" -ne 0
	expect "$1: names the artefact" has "$wt/out" "$3"
	expect "$1: prints both digests" grep -Eq 'A=[0-9a-f]{64} B=[0-9a-f]{64}' "$wt/out"
}
diffcase "tee.bin" TEE=other "DIFF  tee.bin"
diffcase "TA ELF" TA=other "bc50d971-d4c9-42c4-82cb-343fb7f37896.stripped.elf"
diffcase "Image" IMG=other "DIFF  Image"
diffcase "dtb" DTB=other "imx95-19x19-frdm-pro.dtb"
diffcase "boot partition byte" BOOT=bXot "wic partition boot"
diffcase "tee-data partition byte" DATA=dXta "wic partition tee-data"
mk "$wt/b" MEMBER=other
run "$wt/a" "$wt/b"
expect "rootfs member content: exit nonzero" test "$rc" -ne 0
expect "rootfs member content: names the member" has "$wt/out" "first differing member: usr/bin/tool"
mk "$wt/b" MODE=755
run "$wt/a" "$wt/b"
expect "rootfs member mode: exit nonzero" test "$rc" -ne 0
expect "rootfs member mode: names the member" has "$wt/out" "first differing member: usr/bin/tool"
mk "$wt/b" NOTEE=1
run "$wt/a" "$wt/b"
expect "missing artefact: exit nonzero" test "$rc" -ne 0
expect "missing artefact: named" has "$wt/out" "tee.bin: missing in B"
run "$wt/b" "$wt/a"
expect "missing artefact on side A: named" has "$wt/out" "tee.bin: missing in A"

# a corrupt compressed archive: the gzip trailer CRC is wrong
mk "$wt/b"
f=$wt/b/img.rootfs-20250101.tar.gz
sz=$(stat -c %s "$f")
printf '\377\377\377\377' | dd of="$f" bs=1 seek=$((sz - 8)) conv=notrunc 2>/dev/null
run "$wt/a" "$wt/b"
expect "corrupt archive: exit nonzero" test "$rc" -ne 0
expect "corrupt archive: refused by name" has "$wt/out" "img.rootfs-20250101.tar.gz) cannot be decompressed"

# the checker writes nothing to either directory
mk "$wt/b"
before=$(cd "$wt/a" && find . | sort | xargs -d '\n' ls -ld --time-style=+ | md5sum)
run "$wt/a" "$wt/b"
after=$(cd "$wt/a" && find . | sort | xargs -d '\n' ls -ld --time-style=+ | md5sum)
expect "the checker leaves the deploy directory untouched" test "$before" = "$after"

# the make target
mrun() { rc=0; PATH="$wt/bin:$PATH" make -s -C "$ROOT" platform-image-repro-check "$@" >"$wt/out" 2>&1 || rc=$?; }
mrun REPRO_A="$wt/a" REPRO_B="$wt/b"
expect "make target: a match exits 0" test "$rc" -eq 0
mk "$wt/b" TEE=other
mrun REPRO_A="$wt/a" REPRO_B="$wt/b"
expect "make target: a mismatch exits nonzero" test "$rc" -ne 0
mrun REPRO_A="$wt/a"
expect "make target: a missing REPRO_B fails" test "$rc" -ne 0
expect "make target: ... with a usage line" has "$wt/out" "usage:"
mrun REPRO_B="$wt/a"
expect "make target: a missing REPRO_A fails" test "$rc" -ne 0
expect "make target: ... with a usage line (A)" has "$wt/out" "usage:"

finish
