#!/usr/bin/env bash
# (c) Durability: every acknowledged write survives a graceful restart and a kill -9.
# shellcheck disable=SC1091,SC2034
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib.sh"

usage() {
	cat <<'EOF'
usage: durability.sh [options] <board ssh target>

Writes a set of keys (AES-256-GCM and ECDSA P-256) and a certificate, each
with an artefact made by the key (a ciphertext or a signature) and a
fingerprint, recorded only after xkmsd acknowledged the write. Then:
  1. verify the set
  2. graceful restart (systemctl restart), verify
  3. write a second set, kill -9 xkmsd, verify both sets
  4. a second kill -9 straight after more writes, verify all
A key that is gone, changed, or whose old ciphertext or signature no longer
checks is a CRITICAL finding.

  --keys <n>   keys per set (default 20)
EOF
	bi_common_usage
}

n=20
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help) usage; exit 0 ;;
	--keys) n=${2:?}; shift 2 ;;
	*)
		bi_common_opt "$@"
		[ "$BI_N" -gt 0 ] || bi_die "unknown option $1"
		shift "$BI_N"
		;;
	esac
done

if [ "$BI_DRY" = 1 ]; then
	bi_plan "write set A: $n keys and a certificate; record fingerprints and artefacts of acknowledged writes only"
	bi_plan "verify A; graceful restart of xkmsd on the board; verify A"
	bi_plan "write set B; kill -9 xkmsd; verify A and B"
	bi_plan "write set C; kill -9 xkmsd again; verify A, B and C"
	bi_plan "a lost or changed acknowledged write prints CRITICAL; the keys stay on the server (ids bi-dur-*)"
	exit 0
fi

bi_need ctl board work
stamp=$(date -u +%H%M%S)-$$
bi_ready 30 || { bi_fail "xkmsd does not answer"; bi_summary durability; exit 1; }

bi_write_set A "$n" "bi-dur-$stamp-a"
bi_verify_set A

bi_check "graceful restart" bi_restart graceful
bi_verify_set A

bi_write_set B "$n" "bi-dur-$stamp-b"
bi_check "kill -9 after set B" bi_restart kill9
bi_verify_set A
bi_verify_set B

bi_write_set C "$n" "bi-dur-$stamp-c"
bi_check "second kill -9 straight after set C" bi_restart kill9
bi_verify_set A
bi_verify_set B
bi_verify_set C

echo "work dir (ledgers, no key material): $BI_WORK"
bi_summary durability
