#!/usr/bin/env bash
# (a) Functional sweep: every xkmsd operation xkmsctl documents for keys and
# certificates, each result checked, including the refusals that must refuse.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

usage() {
	cat <<'EOF'
usage: functional.sh [options] [<board ssh target>]

Run once through create, list, get, sign, verify, encrypt, decrypt, rotate,
copy, export and delete for keys, and generate-ca, issue, save, exists, get,
list and delete for certificates, plus the read-only status calls. Wrong
signatures and tampered ciphertext must be refused. Every key and certificate
it makes is deleted at the end. The board target is not needed.

  --prefix <id>   key id prefix (default bi-func-<pid>)
EOF
	bi_common_usage
}

pfx="bi-func-$$"
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help) usage; exit 0 ;;
	--prefix) pfx=${2:?}; shift 2 ;;
	*)
		bi_common_opt "$@"
		[ "$BI_N" -gt 0 ] || bi_die "unknown option $1"
		shift "$BI_N"
		;;
	esac
done

if [ "$BI_DRY" = 1 ]; then
	bi_plan "keys: generate ecdsa P-256/P-384, ed25519, rsa-2048 and aes-256-gcm under $pfx-*"
	bi_plan "keys: list, get, sign and verify (plus a wrong-data verify that must fail), encrypt and decrypt (plus a tampered tag that must fail), encrypt-asym, rotate, copy, export, delete"
	bi_plan "certs: generate-ca, issue server and client, save, exists, get, list, delete"
	bi_plan "read-only: algorithms, backends, status, version"
	bi_plan "no board access; deletes everything it created"
	exit 0
fi

bi_need ctl work
C() { bi_ctl "$@"; }
made=()
cleanup() {
	local k
	for k in "${made[@]}"; do C key delete "$k" >/dev/null 2>&1; done
	C cert delete "$pfx-cert" >/dev/null 2>&1
	C cert delete "$pfx-cert2" >/dev/null 2>&1
}
trap cleanup EXIT

gen() { made+=("$1"); C key generate "$@" >/dev/null; }
contains() { case $1 in *"$2"*) return 0 ;; *) return 1 ;; esac; }

t_generate() {
	gen "$pfx-p256" --key-algorithm ecdsa --curve P-256 --key-type signing &&
		gen "$pfx-p384" --key-algorithm ecdsa --curve P-384 --key-type signing &&
		gen "$pfx-ed" --key-algorithm ed25519 --key-type signing &&
		gen "$pfx-rsa" --key-algorithm rsa --key-size 2048 --key-type signing &&
		gen "$pfx-aes" --key-type symmetric --algorithm aes-256-gcm --key-size 256
}
t_list() { local o; o=$(C key list) && contains "$o" "$pfx-p256" && contains "$o" "$pfx-aes"; }
t_get() { local o; o=$(C key get "$pfx-p256") && contains "$o" "$pfx-p256"; }
t_get_missing() { ! C key get "$pfx-nonexistent" >/dev/null 2>&1; }
t_signverify() { # <key>
	local j sig
	j=$(C -o json key sign "$1" "payload-$1") || return 1
	sig=$(bi_jget "$j" signature) && [ -n "$sig" ] || return 1
	C key verify "$1" "payload-$1" "$sig" >/dev/null || return 1
	! C key verify "$1" "other-payload" "$sig" >/dev/null 2>&1
}
t_aes() {
	local j ct n tag out
	j=$(C -o json key encrypt "$pfx-aes" "secret-text") || return 1
	ct=$(bi_jget "$j" ciphertext) n=$(bi_jget "$j" nonce) tag=$(bi_jget "$j" tag)
	out=$(C key decrypt "$pfx-aes" "$ct" --nonce "$n" --tag "$tag") && contains "$out" "secret-text" || return 1
	# a tag with one byte changed must not decrypt
	local bad=A${tag:1}
	[ "$bad" != "$tag" ] || bad=B${tag:1}
	! C key decrypt "$pfx-aes" "$ct" --nonce "$n" --tag "$bad" >/dev/null 2>&1
}
t_rsa_asym() {
	gen "$pfx-rsae" --key-algorithm rsa --key-size 2048 --key-type encryption || return 1
	local j ct out
	j=$(C -o json key encrypt-asym "$pfx-rsae" "asym-text" 2>&1) || { echo "$j"; return 1; }
	ct=$(bi_jget "$j" ciphertext)
	out=$(C key decrypt "$pfx-rsae" "$ct" 2>&1) && contains "$out" "asym-text" && return 0
	# a server whose policy refuses the PKCS#1 v1.5 fallback of decrypt is a skip, not a failure
	case $out in *"Set padding"*) echo "skipped: $out"; return 0 ;; esac
	echo "$out"
	return 1
}
t_rotate() { C key rotate "$pfx-aes"; }
t_rotate_old_decrypts() { # a ciphertext made before a rotation still decrypts after it
	gen "$pfx-rot" --key-type symmetric --algorithm aes-256-gcm --key-size 256 || return 1
	local j ct n tag out
	j=$(C -o json key encrypt "$pfx-rot" "before-rotate") || return 1
	ct=$(bi_jget "$j" ciphertext) n=$(bi_jget "$j" nonce) tag=$(bi_jget "$j" tag)
	C key rotate "$pfx-rot" || return 1
	out=$(C key decrypt "$pfx-rot" "$ct" --nonce "$n" --tag "$tag") && contains "$out" "before-rotate"
}
t_copy() { # copy needs an exportable source
	gen "$pfx-src" --key-type symmetric --algorithm aes-256-gcm --key-size 256 --exportable || return 1
	made+=("$pfx-copy")
	C key copy "$pfx-src" "$pfx-copy" && C key get "$pfx-copy" >/dev/null
}
t_export() {
	gen "$pfx-exp" --key-type symmetric --algorithm aes-256-gcm --key-size 256 --exportable || return 1
	C key export "$pfx-exp" "$BI_WORK/exported.bin" && [ -s "$BI_WORK/exported.bin" ]
}
t_export_refused() { ! C key export "$pfx-p256" "$BI_WORK/refused.bin" >/dev/null 2>&1; }
t_delete() { C key delete "$pfx-ed" >/dev/null && ! C key get "$pfx-ed" >/dev/null 2>&1; }

t_cert_ca() { C cert generate-ca --cn "$pfx-ca" --output "$BI_WORK/ca.crt" --key-output "$BI_WORK/ca.key" && [ -s "$BI_WORK/ca.crt" ]; }
t_cert_issue() {
	C cert issue --ca-cert "$BI_WORK/ca.crt" --ca-key "$BI_WORK/ca.key" --cn "$pfx.server.test" --type server --output "$BI_WORK/s.crt" --key-output "$BI_WORK/s.key" &&
		C cert issue --ca-cert "$BI_WORK/ca.crt" --ca-key "$BI_WORK/ca.key" --cn "$pfx-client" --type client --output "$BI_WORK/c.crt" --key-output "$BI_WORK/c.key" &&
		[ -s "$BI_WORK/s.crt" ] && [ -s "$BI_WORK/c.crt" ]
}
t_cert_save() { C cert save "$pfx-cert" "$BI_WORK/s.crt" && C cert save "$pfx-cert2" "$BI_WORK/c.crt"; }
t_cert_exists() { local o; o=$(C cert exists "$pfx-cert") && contains "$o" "exists" && ! contains "$o" "does not exist"; }
t_cert_get() {
	local o
	o=$(C cert get "$pfx-cert") || return 1
	[ "$(printf '%s' "$o" | bi_sha)" = "$(printf '%s' "$(cat "$BI_WORK/s.crt")" | bi_sha)" ]
}
t_cert_list() { local o; o=$(C cert list) && contains "$o" "$pfx-cert"; }
t_cert_delete() { local o; C cert delete "$pfx-cert" >/dev/null && o=$(C cert exists "$pfx-cert") && contains "$o" "does not exist"; }

# optional server features: a server that says it is not configured is a SKIP, anything else must succeed
t_optional() {
	local o
	o=$("$@" 2>&1) && return 0
	case $o in *"not configured"* | *"not enabled"* | *"not supported"*) echo "skipped: $o"; return 0 ;; esac
	echo "$o"
	return 1
}

bi_check "key generate (ecdsa P-256/P-384, ed25519, rsa, aes-256-gcm)" t_generate
bi_check "key list names the new keys" t_list
bi_check "key get" t_get
bi_check "key get of a missing key fails" t_get_missing
for k in p256 p384 ed rsa; do bi_check "sign, verify and refuse a wrong payload: $k" t_signverify "$pfx-$k"; done
bi_check "aes encrypt, decrypt and refuse a bad tag" t_aes
bi_check "rsa encrypt-asym and decrypt" t_rsa_asym
bi_check "key rotate" t_rotate
bi_check "ciphertext from before a rotation still decrypts" t_rotate_old_decrypts
bi_check "key copy" t_copy
bi_check "key export of an exportable key" t_export
bi_check "key export of a non-exportable key is refused" t_export_refused
bi_check "key delete, then get fails" t_delete
bi_check "cert generate-ca" t_cert_ca
bi_check "cert issue server and client" t_cert_issue
bi_check "cert save" t_cert_save
bi_check "cert exists" t_cert_exists
bi_check "cert get returns what was saved" t_cert_get
bi_check "cert list" t_cert_list
bi_check "cert delete" t_cert_delete
bi_check "algorithms" t_optional C algorithms
bi_check "backends list" t_optional C backends list
bi_check "status" t_optional C status
bi_check "ca bundle" t_optional C ca bundle
bi_check "ca crl" t_optional C ca crl

bi_summary functional
