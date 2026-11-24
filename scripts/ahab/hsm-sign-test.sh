#!/usr/bin/env bash
# hsm-sign-test.sh: sign the Cortex-M7 AHAB container with a key the build never
# holds, after AN14471's model for the custody of the signing keys (AN14471
# §3.1, §3.6; docs/boot-container/signing-pipeline.md, "HSM custody test").
#
#   hsm-sign-test.sh [--hsm-key <0..3>] [--no-hsm]
#
# Four throwaway ECDSA P-384 test SRKs are generated in an "HSM" directory
# (mktemp -d, outside the clone). scripts/ahab/test-hsm.py, a TEST stand-in for
# the HSM, holds one private key (srk<--hsm-key>, default srk0) and serves
# SPSDK's `proxy` signature provider on 127.0.0.1. The build directory (another
# mktemp -d) receives only the four public SRKs and m7-container.yaml with its
# signer set to that proxy, pre-hashing with SHA-384: the HSM sees a digest,
# never the container. The run then requires that
#   - nxpimage ahab export signs the container through the HSM (its log holds
#     a sha384 sign request) and nxpimage ahab verify accepts it;
#   - no private key is in the build directory, before or after the export.
# --hsm-key 1 makes the HSM hold a key that is not the container's used SRK
# (used_srk_id 0); --no-hsm starts no HSM. Both must fail: there is no
# fallback to a key file. AHAB_OUT_DIR, if set, receives m7-container.bin.
# The SPSDK venv comes from spsdk-venv.sh (pinned 3.13.0). No real key, no real
# HSM, no fuse: the .bcf fuse script nxpimage writes is deleted unread.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
FAMILY=mimx9596
REVISION=b0

die() {
	echo "hsm-sign-test: $*" >&2
	exit 1
}

hsm_key=0
start_hsm=1
while [ $# -gt 0 ]; do
	case "$1" in
	--hsm-key)
		[ $# -ge 2 ] && [[ "$2" =~ ^[0-3]$ ]] || die "--hsm-key takes 0, 1, 2 or 3"
		hsm_key=$2
		shift 2
		;;
	--no-hsm)
		start_hsm=0
		shift
		;;
	*) die "usage: hsm-sign-test.sh [--hsm-key <0..3>] [--no-hsm]" ;;
	esac
done

venv=$("$here/spsdk-venv.sh")
nxpimage=$venv/bin/nxpimage
nxpcrypto=$venv/bin/nxpcrypto
"$nxpimage" --version 2>/dev/null

umask 077
work=$(mktemp -d)
hsm=$(mktemp -d)
hsm_pid=
cleanup() {
	[ -z "$hsm_pid" ] || kill "$hsm_pid" 2>/dev/null || true
	[ -z "$hsm_pid" ] || wait "$hsm_pid" 2>/dev/null || true
	rm -rf "$work" "$hsm"
}
trap cleanup EXIT
for d in "$work" "$hsm"; do
	case "$(cd "$d" && pwd -P)/" in "$root"/*) die "the work directory $d is inside the clone; set TMPDIR outside it" ;; esac
done

# no_private_key <dir> <when>: fail when any file under <dir> holds a PEM private key.
no_private_key() {
	local f
	for f in "$1"/* "$1"/.[!.]*; do
		[ -f "$f" ] || continue
		if grep -q -a -E 'BEGIN (EC |ENCRYPTED )?PRIVATE KEY' "$f"; then
			die "$2: the build directory holds a private key ($(basename "$f"))"
		fi
	done
	echo "custody: no private key in the build directory ($2)"
}

for i in 0 1 2 3; do
	"$nxpcrypto" key generate -k secp384r1 -o "$hsm/srk$i.pem" >/dev/null 2>"$hsm/keygen.log" ||
		{ cat "$hsm/keygen.log" >&2; die "nxpcrypto key generate failed for srk$i"; }
	[ -s "$hsm/srk$i.pub" ] || die "nxpcrypto wrote no srk$i.pub"
	mv "$hsm/srk$i.pub" "$work/srk$i.pub"
done

port=
if [ "$start_hsm" = 1 ]; then
	"$venv/bin/python" -I "$here/test-hsm.py" "$hsm/srk$hsm_key.pem" "$hsm/port" "$hsm/hsm.log" 2>"$hsm/hsm.err" &
	hsm_pid=$!
	for _ in $(seq 1 100); do
		[ -s "$hsm/port" ] && break
		kill -0 "$hsm_pid" 2>/dev/null || { cat "$hsm/hsm.err" >&2; die "the test HSM exited before it listened"; }
		sleep 0.1
	done
	[ -s "$hsm/port" ] || die "the test HSM did not listen within 10 s"
	port=$(tr -d '[:space:]' <"$hsm/port")
	echo "test HSM: 127.0.0.1:$port holds srk$hsm_key (the build holds public keys only)"
else
	# A port nothing listens on: bind an ephemeral port, then close it.
	port=$("$venv/bin/python" -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
	echo "test HSM: none started (127.0.0.1:$port is closed)"
fi
[[ "$port" =~ ^[0-9]+$ ]] || die "no port for the test HSM"

# m7-container.yaml with the file signer replaced by the HSM proxy.
signer="type=proxy;host=127.0.0.1;port=$port;url_prefix=api;prehash=sha384"
replaced=0
while IFS= read -r l; do
	if [[ "$l" =~ ^([[:space:]]+)signer:\ type=file\; ]]; then
		printf '%ssigner: %s\n' "${BASH_REMATCH[1]}" "$signer"
		replaced=$((replaced + 1))
	else
		printf '%s\n' "$l"
	fi
done <"$here/m7-container.yaml" >"$work/m7-container.yaml"
[ "$replaced" = 1 ] || die "m7-container.yaml has $replaced file signer lines, expected 1"
head -c 4096 /dev/urandom >"$work/payload.bin"

no_private_key "$work" "before export"
if ! (cd "$work" && "$nxpimage" ahab export -c m7-container.yaml) >"$work/export.log" 2>&1; then
	tail -n 3 "$work/export.log" >&2
	die "nxpimage ahab export failed: the container was not signed through the HSM"
fi
rm -f "$work"/*.bcf
[ -s "$work/m7-container.bin" ] || die "nxpimage ahab export wrote no m7-container.bin"
no_private_key "$work" "after export"
[ -s "$hsm/hsm.log" ] && grep -q '^sign sha384 [0-9a-f]\{96\}$' "$hsm/hsm.log" ||
	die "the test HSM received no SHA-384 sign request"
echo "test HSM: signed a SHA-384 digest ($(grep -c '^sign sha384' "$hsm/hsm.log") request(s))"

if ! (cd "$work" && "$nxpimage" ahab verify -f "$FAMILY" -r "$REVISION" -b m7-container.bin) >"$work/verify.log" 2>&1; then
	tail -n 3 "$work/verify.log" >&2
	echo "verify: FAILED"
	die "the HSM-signed container does not verify"
fi
echo "verify: OK (HSM-signed Cortex-M7 container)"

if [ -n "${AHAB_OUT_DIR:-}" ]; then
	mkdir -p "$AHAB_OUT_DIR"
	cp "$work/m7-container.bin" "$AHAB_OUT_DIR/m7-container.bin"
	echo "container: $AHAB_OUT_DIR/m7-container.bin"
fi
echo "ahab-hsm-test: OK"
