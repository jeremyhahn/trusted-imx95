#!/usr/bin/env bash
# Tamper matrix for a signed AHAB container (docs/boot-container/secure-boot-test-plan.md
# section 4: C2b, C5b, C6, plus a changed SRK table). One good container is built
# with the test PKI (scripts/ahab/sign-test.sh, AHAB_OUT_DIR in TMP_ROOT); each case
# is a copy with a minimal change, checked with `sign-test.sh verify`
# (nxpimage ahab verify, SPSDK 3.13.0). C1 and the payload byte are in
# test/ahab_sign_test.sh. No key, container or policy is written inside the clone.
#
# Offsets come from the container itself: the signature block offset is the u16
# at byte 12; the SRK table array starts at that offset + 16 and holds a table
# (length u16 at +1) followed by the SRK data record whose first body byte is
# the used SRK index; the image entry starts at byte 16 (payload offset u32 at
# +0, size u32 at +4) and its SHA-384 hash is found by searching for the hash of
# the payload (sha384sum), then cross-checked against the parse output layout.
set -euo pipefail

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SIGN="$ROOT/scripts/ahab/sign-test.sh"
out="$TMP_ROOT/out"
mkdir -p "$TMP_ROOT/t"

u8() { od -An -tu1 -j"$2" -N1 "$1" | tr -d ' '; }
u16() { echo $(($(u8 "$1" "$2") + 256 * $(u8 "$1" $(($2 + 1))))); }
u32() { echo $(($(u16 "$1" "$2") + 65536 * $(u16 "$1" $(($2 + 2))))); }

# setbyte FILE OFFSET VALUE: overwrite one byte in place.
setbyte() {
	# shellcheck disable=SC2059 # the format is the byte itself, as an octal escape
	printf "$(printf '\\%03o' "$3")" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none
}
# flip SRC DST OFFSET: copy, then invert one byte.
flip() {
	cp "$1" "$2"
	setbyte "$2" "$3" $(($(u8 "$2" "$3") ^ 0xff))
}
# trunc SRC DST BYTES: copy of the first BYTES bytes.
trunc() { head -c "$3" "$1" >"$2"; }
# sethash FILE OFFSET HEXDIGEST: write a hex digest as raw bytes.
sethash() {
	local i
	for ((i = 0; i < ${#3}; i += 2)); do setbyte "$1" $(($2 + i / 2)) $((16#${3:i:2})); done
}
# nonotrace NAME FILE: nxpimage's full output on FILE must hold no Python traceback.
nonotrace() {
	local v o
	v=$("$ROOT/scripts/ahab/spsdk-venv.sh")
	o=$(cd "$TMP_ROOT/t" && "$v/bin/nxpimage" ahab verify -f mimx9596 -r b0 -b "$2" 2>&1) || true
	case "$o" in
	*Traceback*) fail "$1: nxpimage printed a Python traceback" ;;
	*) pass "$1: no Python traceback" ;;
	esac
}
# rejects NAME FILE: verify must exit 1 with "verify: FAILED", no traceback.
rejects() {
	run "$SIGN" verify "$2"
	check "$1: tampered container is rejected" 1 "verify: FAILED"
	case "$OUT" in *Traceback*) fail "$1: traceback in verify output" ;; esac
}

payload="$TMP_ROOT/payload.bin"
head -c 4096 /dev/urandom >"$payload"
run env AHAB_OUT_DIR="$out" M7_PAYLOAD="$payload" "$SIGN" m7 "$payload"
check "control: good M7 container is built and verified" 0 "verify: OK"
good="$out/m7-container.bin"
[ -f "$good" ] || { fail "control: no container handed back"; finish; exit 1; }
run "$SIGN" verify "$good"
check "control: the good container passes verify" 0 "verify: OK"

size=$(wc -c <"$good")
hdrlen=$(u16 "$good" 1)
sb=$(u16 "$good" 12)
t=$TMP_ROOT/t/c.bin

# C6: truncation.
trunc "$good" "$t" $((size / 2))
rejects "C6a (half size)" "$t"
nonotrace "C6a" "$t"
trunc "$good" "$t" $((size - 1))
rejects "C6b (one byte short)" "$t"
nonotrace "C6b" "$t"
trunc "$good" "$t" 0
rejects "C6c (0 bytes)" "$t"
nonotrace "C6c (0 bytes)" "$t"
trunc "$good" "$t" "$hdrlen"
rejects "C6c (header only)" "$t"
nonotrace "C6c (header only)" "$t"

# C5b: image entry hash. The entry is at byte 16; find the payload's SHA-384
# inside the file's entry (first 128 bytes after 16).
poff=$(u32 "$good" 16)
psize=$(u32 "$good" 20)
digest=$(dd if="$good" bs=1 skip="$poff" count="$psize" status=none | sha384sum | cut -d' ' -f1)
hoff=-1
for ((o = 16; o < 16 + 128 - 48 + 1; o++)); do
	if [ "$(dd if="$good" bs=1 skip="$o" count=48 status=none | od -An -tx1 | tr -d ' \n')" = "$digest" ]; then
		hoff=$o
		break
	fi
done
if [ "$hoff" -lt 0 ]; then
	fail "C5b: the payload's SHA-384 is not in the image entry"
else
	flip "$good" "$t" "$hoff"
	rejects "C5b (entry hash byte changed)" "$t"

	# C5b-ii: payload changed, hash recomputed to match, signature untouched.
	cp "$good" "$t"
	setbyte "$t" "$poff" $(($(u8 "$t" "$poff") ^ 0xff))
	nd=$(dd if="$t" bs=1 skip="$poff" count="$psize" status=none | sha384sum | cut -d' ' -f1)
	sethash "$t" "$hoff" "$nd"
	rejects "C5b-ii (payload and hash both changed)" "$t"
fi

# C2b: used SRK index, in the SRK data record after the SRK table.
tab=$((sb + 16 + 8))
sd=$((tab + $(u16 "$good" $((tab + 1)))))
want=$(u8 "$good" $((sd + 3)))
if [ "$want" -ne 93 ]; then
	fail "C2b: no SRK data record (tag 0x5d) at the offset derived from the container"
else
	cp "$good" "$t"
	setbyte "$t" $((sd + 4)) 1
	rejects "C2b (used_srk_id 0 -> 1)" "$t"
fi

# SRK table: one byte inside the first SRK record's key material.
flip "$good" "$t" $((tab + 32))
rejects "SRK table (one byte changed)" "$t"

finish
