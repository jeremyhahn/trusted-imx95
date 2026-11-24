#!/usr/bin/env bash
# Shared helpers of the xkmsd burn-in scripts (sourced, never run).
#
# The scripts run on a host on the board's LAN. They drive xkmsd through the
# go-xkms client `xkmsctl` (a native build of the same go-xkms commit: see
# docs/xkms-board/burn-in.md) and, where a test needs the board's own view
# (RSS, descriptors, restarts, disk), through ssh to root on the board.
#
# Environment, overridden by the common options:
#   XKMS_CTL        xkmsctl binary                     (--ctl)
#   XKMS_CTL_ARGS   extra xkmsctl arguments, split on spaces, such as
#                   "--transport rest --tls-ca ca.pem --tls-cert c.pem --tls-key c.key"
#                                                      (--ctl-args)
#   XKMS_SERVER     xkmsd URL                          (--server)
#   XKMS_BOARD      ssh target of the board            (the one positional argument)
#   XKMS_WORK       scratch directory (default: a new temp dir; never inside the repo)
#
# Nothing here prints key material: only key ids, hashes and verdicts.

BI_CTL=${XKMS_CTL:-xkmsctl}
BI_SERVER=${XKMS_SERVER:-}
BI_BOARD=${XKMS_BOARD:-}
BI_WORK=${XKMS_WORK:-}
BI_UNIT=xkmsd
BI_DRY=0
BI_N=0
BI_CHECKS=0
BI_FAILED=0
BI_CRIT=0
read -r -a BI_CTL_ARGS <<<"${XKMS_CTL_ARGS:-}"

bi_die() {
	echo "$(basename "$0"): $*" >&2
	exit 2
}

# bi_common_opt "$@": consume one common option; BI_N is the words used (0: not ours).
bi_common_opt() {
	BI_N=0
	case ${1:-} in
	--dry-run) BI_DRY=1; BI_N=1 ;;
	--server | --ctl | --ctl-args | --work)
		[ $# -ge 2 ] || bi_die "$1 needs a value"
		case $1 in
		--server) BI_SERVER=$2 ;;
		--ctl) BI_CTL=$2 ;;
		--ctl-args) read -r -a BI_CTL_ARGS <<<"$2" ;;
		--work) BI_WORK=$2 ;;
		esac
		BI_N=2
		;;
	-*) ;;
	?*) BI_BOARD=$1; BI_N=1 ;;
	esac
}

bi_common_usage() {
	cat <<'EOF'

Common options:
  --server <url>      xkmsd URL (or XKMS_SERVER)
  --ctl <path>        the xkmsctl binary (or XKMS_CTL; default xkmsctl)
  --ctl-args "<..>"   extra xkmsctl arguments: transport, TLS files (XKMS_CTL_ARGS)
  --work <dir>        scratch directory (XKMS_WORK; default a new temp dir)
  --dry-run           print the plan; touch neither the board nor the server
  --help              this text
<board>              ssh target of the board, as root (or XKMS_BOARD)
Exit status: 0 PASS, 1 FAIL or any CRITICAL finding, 2 usage.
EOF
}

bi_plan() { echo "plan: $*"; }

bi_ctl() {
	local a=("${BI_CTL_ARGS[@]}")
	[ -z "$BI_SERVER" ] || a+=(--server "$BI_SERVER")
	timeout "${BI_CTL_TIMEOUT:-60}" "$BI_CTL" "${a[@]}" "$@"
}

bi_board() {
	ssh -o BatchMode=yes -o ConnectTimeout=10 "$BI_BOARD" "$@"
}

bi_need() { # bi_need ctl|board|work
	local what
	for what in "$@"; do
		case $what in
		ctl) command -v "$BI_CTL" >/dev/null 2>&1 || bi_die "xkmsctl not found ($BI_CTL); see docs/xkms-board/burn-in.md" ;;
		board) [ -n "$BI_BOARD" ] || bi_die "this test needs the board's ssh target as an argument" ;;
		work)
			if [ -z "$BI_WORK" ]; then BI_WORK=$(mktemp -d "${TMPDIR:-/tmp}/xkms-burnin.XXXXXX"); fi
			mkdir -p "$BI_WORK"
			;;
		esac
	done
}

bi_check() { # bi_check <name> <command...>: record PASS or FAIL
	local name=$1
	shift
	BI_CHECKS=$((BI_CHECKS + 1))
	if "$@" >"${BI_WORK:-/tmp}/.last.out" 2>&1; then
		echo "PASS $name"
	else
		BI_FAILED=$((BI_FAILED + 1))
		echo "FAIL $name: $(head -c 300 "${BI_WORK:-/tmp}/.last.out" | tr '\n' ' ')"
	fi
}

bi_fail() { # a failure found by the script's own logic
	BI_CHECKS=$((BI_CHECKS + 1))
	BI_FAILED=$((BI_FAILED + 1))
	echo "FAIL $*"
}

# bi_wfail: a write that was refused. BI_WRITE_FAIL_OK=1 (disk-full, load) makes it a note:
# a refused write was never acknowledged, so it is not in the ledger and nothing is owed for it.
bi_wfail() {
	BI_REFUSED=$((${BI_REFUSED:-0} + 1))
	if [ "${BI_WRITE_FAIL_OK:-0}" = 1 ]; then return 0; fi
	bi_fail "$@"
}

bi_crit() { # an acknowledged write lost or corrupted
	BI_CRIT=$((BI_CRIT + 1))
	echo "CRITICAL: $*"
}

bi_summary() { # bi_summary <name>: the PASS/FAIL line and the exit status
	local v=PASS
	if [ "$BI_FAILED" -ne 0 ] || [ "$BI_CRIT" -ne 0 ]; then v=FAIL; fi
	echo "SUMMARY $1: $v checks=$BI_CHECKS failed=$BI_FAILED critical=$BI_CRIT"
	[ "$v" = PASS ]
}

# bi_jget <json> <field>: a string or number field of flat JSON, no jq needed.
bi_jget() {
	local re="\"$2\"[[:space:]]*:[[:space:]]*(\"([^\"]*)\"|([0-9.]+))"
	[[ $1 =~ $re ]] || return 1
	printf '%s' "${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
}

bi_sha() { sha256sum | cut -d' ' -f1; }

# bi_ready [<seconds>]: xkmsd answers a key list.
bi_ready() {
	local i=0 max=${1:-90}
	while [ "$i" -lt "$max" ]; do
		if BI_CTL_TIMEOUT=5 bi_ctl key list >/dev/null 2>&1; then return 0; fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

# bi_restart graceful|kill9|hard: restart xkmsd on the board the named way and wait for it.
bi_restart() {
	case $1 in
	graceful) bi_board "systemctl restart $BI_UNIT" ;;
	kill9)
		bi_board "systemctl kill -s KILL --kill-whom=main $BI_UNIT"
		sleep 3
		bi_board "systemctl is-active --quiet $BI_UNIT || systemctl start $BI_UNIT" || true
		;;
	hard)
		bi_board "echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger" || true
		sleep 15
		local i=0
		while [ "$i" -lt 60 ]; do
			if bi_board true 2>/dev/null; then break; fi
			i=$((i + 1))
			sleep 5
		done
		[ "$i" -lt 60 ] || return 1
		;;
	esac
	bi_ready 120
}

# --- the durability ledger: every acknowledged write is recorded, then re-checked ----------
# A ledger line is: kind|id|a|b|c|d, written only after xkmsctl reported success.
# kinds: sym (key id, ciphertext, nonce, tag, plaintext), sig (key id, signature, message),
#        meta (key id, sha256 of the key's metadata), cert (cert id, PEM sha256).

bi_ledger() { echo "$BI_WORK/ledger.${1:-main}"; }

# bi_write_set <name> <count> <prefix>: write count keys, a signature or ciphertext each, and a certificate.
bi_write_set() {
	local name=$1 n=$2 pfx=$3 i id j ct nonce tag sig L
	L=$(bi_ledger "$name")
	for ((i = 0; i < n; i++)); do
		id="$pfx-$i"
		if [ $((i % 2)) -eq 0 ]; then
			bi_ctl key generate "$id" --key-type symmetric --algorithm aes-256-gcm --key-size 256 >/dev/null 2>&1 || {
				bi_wfail "write $id: generate"
				continue
			}
			j=$(bi_ctl -o json key encrypt "$id" "plain-$id" 2>/dev/null) || { bi_wfail "write $id: encrypt"; continue; }
			ct=$(bi_jget "$j" ciphertext) nonce=$(bi_jget "$j" nonce) tag=$(bi_jget "$j" tag)
			echo "sym|$id|$ct|$nonce|$tag|plain-$id" >>"$L"
		else
			bi_ctl key generate "$id" --key-algorithm ecdsa --curve P-256 --key-type signing >/dev/null 2>&1 || {
				bi_wfail "write $id: generate"
				continue
			}
			j=$(bi_ctl -o json key sign "$id" "msg-$id" 2>/dev/null) || { bi_wfail "write $id: sign"; continue; }
			sig=$(bi_jget "$j" signature)
			echo "sig|$id|$sig|msg-$id||" >>"$L"
		fi
		j=$(bi_ctl -o json key get "$id" 2>/dev/null) || { bi_wfail "write $id: get"; continue; }
		echo "meta|$id|$(printf '%s' "$j" | bi_sha)|||" >>"$L"
	done
	[ "${BI_WRITE_CERT:-1}" = 1 ] || return 0
	# one certificate object per set
	if [ ! -f "$BI_WORK/$name.ca.crt" ]; then
		bi_ctl cert generate-ca --cn "burnin-$name" --output "$BI_WORK/$name.ca.crt" --key-output "$BI_WORK/$name.ca.key" >/dev/null 2>&1 ||
			{ bi_wfail "write $name: generate-ca"; return 0; }
	fi
	if bi_ctl cert save "$pfx-cert" "$BI_WORK/$name.ca.crt" >/dev/null 2>&1; then
		echo "cert|$pfx-cert|$(bi_sha <"$BI_WORK/$name.ca.crt")|$BI_WORK/$name.ca.crt||" >>"$L"
	else
		bi_wfail "write $pfx-cert: cert save"
	fi
}

# bi_verify_set <name>: every ledger entry must still hold; a miss is CRITICAL.
bi_verify_set() {
	local name=$1 L kind id a b c d j n=0 bad=0 out
	L=$(bi_ledger "$name")
	[ -s "$L" ] || { bi_fail "verify $name: empty ledger"; return 0; }
	while IFS='|' read -r kind id a b c d; do
		n=$((n + 1))
		case $kind in
		meta)
			if ! j=$(bi_ctl -o json key get "$id" 2>/dev/null); then
				bi_crit "acknowledged key $id is gone"
				bad=$((bad + 1))
			elif [ "$(printf '%s' "$j" | bi_sha)" != "$a" ]; then
				bi_crit "key $id changed: metadata fingerprint differs"
				bad=$((bad + 1))
			fi
			;;
		sym)
			out=$(bi_ctl key decrypt "$id" "$a" --nonce "$b" --tag "$c" 2>&1) || out="error: $out"
			case $out in
			*"$d"*) ;;
			*) bi_crit "key $id: acknowledged ciphertext no longer decrypts to its plaintext"; bad=$((bad + 1)) ;;
			esac
			;;
		sig)
			if ! bi_ctl key verify "$id" "$b" "$a" >/dev/null 2>&1; then
				bi_crit "key $id: acknowledged signature no longer verifies (key lost or changed)"
				bad=$((bad + 1))
			fi
			;;
		cert)
			out=$(bi_ctl cert get "$id" 2>/dev/null) || out=""
			if [ "$(printf '%s\n' "$out" | bi_sha)" != "$(cat "$b" | bi_sha)" ] &&
				[ "$(printf '%s' "$out" | bi_sha)" != "$(printf '%s' "$(cat "$b")" | bi_sha)" ]; then
				bi_crit "certificate $id lost or changed"
				bad=$((bad + 1))
			fi
			;;
		esac
	done <"$L"
	BI_CHECKS=$((BI_CHECKS + 1))
	if [ "$bad" -eq 0 ]; then
		echo "PASS verify $name: $n ledger entries intact"
	else
		BI_FAILED=$((BI_FAILED + 1))
		echo "FAIL verify $name: $bad of $n ledger entries lost or changed"
	fi
}

# bi_proc_sample: the daemon's RSS in KiB and open descriptors, "rss fds", from the board.
bi_proc_sample() {
	bi_board "p=\$(systemctl show -p MainPID --value $BI_UNIT); [ \"\$p\" != 0 ] && echo \"\$(awk '/^VmRSS/{print \$2}' /proc/\$p/status) \$(ls /proc/\$p/fd | wc -l)\"" 2>/dev/null
}
