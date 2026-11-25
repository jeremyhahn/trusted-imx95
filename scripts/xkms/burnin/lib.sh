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
# shellcheck disable=SC2034

BI_CTL=${XKMS_CTL:-xkmsctl}
BI_SERVER=${XKMS_SERVER:-}
BI_BOARD=${XKMS_BOARD:-}
BI_WORK=${XKMS_WORK:-}
BI_UNIT=xkmsd
BI_ROOT=${XKMS_FAKE_ROOT:-}         # prefix of the board's /proc paths; tests only, empty on a board
BI_KILL_WAIT=${XKMS_KILL_WAIT:-3}   # seconds after a kill -9 before xkmsd is started if still down
BI_BOOT_WAIT=${XKMS_REBOOT_WAIT:-15} # seconds after sysrq b before the board is polled
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
	# --foreground keeps xkmsctl in the caller's process group, so stopping a
	# writer's group (bi_stop_writers) reaches it.
	timeout --foreground "${BI_CTL_TIMEOUT:-60}" "$BI_CTL" "${a[@]}" "$@"
}

# bi_key_absent <id>: succeed only when xkmsctl answers that the key does not
# exist. A key that is still there fails, and so does any other error
# (connection, auth, server, timeout): that is no answer about the key, so the
# error text is printed and the check fails closed.
bi_key_absent() {
	local out
	if out=$(bi_ctl key get "$1" 2>&1); then
		echo "key $1 still exists"
		return 1
	fi
	case $out in
	*[Cc]onnect* | *[Dd]ial* | *[Rr]efused* | *[Tt]imed\ out* | *[Uu]nauthori* | *[Dd]enied* | *[Tt][Ll][Ss]* | *[Cc]ertificate*) ;;
	*[Nn]ot\ [Ff]ound* | *"does not exist"* | *[Nn]o\ such\ key*) return 0 ;;
	esac
	echo "no not-found answer for $1 (an error is not proof the key is gone): ${out:-no output}"
	return 1
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

bi_mainpid() { bi_board "systemctl show -p MainPID --value $BI_UNIT"; } # 0 when xkmsd is down
bi_bootid() { bi_board "cat $BI_ROOT/proc/sys/kernel/random/boot_id"; }   # new on every boot

# bi_restart graceful|kill9|hard: restart the named way and prove it happened:
# a graceful or kill -9 restart must change xkmsd's MainPID, a hard reboot the
# board's boot_id. Any failed step, or no proof, fails; then xkmsd must answer.
bi_restart() {
	local pid0 pid1 boot0 boot1 i=0
	case $1 in
	graceful | kill9)
		pid0=$(bi_mainpid) || pid0=""
		case $pid0 in '' | 0 | *[!0-9]*) echo "$BI_UNIT is not running before the $1 restart (MainPID '$pid0')"; return 1 ;; esac
		if [ "$1" = graceful ]; then
			bi_board "systemctl restart $BI_UNIT" || { echo "systemctl restart $BI_UNIT failed"; return 1; }
		else
			bi_board "systemctl kill -s KILL --kill-whom=main $BI_UNIT" || { echo "systemctl kill -s KILL $BI_UNIT failed"; return 1; }
			sleep "$BI_KILL_WAIT"
			bi_board "systemctl is-active --quiet $BI_UNIT || systemctl start $BI_UNIT" ||
				{ echo "$BI_UNIT is not active after the kill -9 and a start"; return 1; }
		fi
		pid1=$(bi_mainpid) || pid1=""
		case $pid1 in '' | 0 | *[!0-9]*) echo "$BI_UNIT has no MainPID after the $1 restart ('$pid1')"; return 1 ;; esac
		[ "$pid1" != "$pid0" ] || { echo "$BI_UNIT MainPID is still $pid0: the $1 restart did not happen"; return 1; }
		echo "$BI_UNIT restarted ($1): MainPID $pid0 -> $pid1"
		;;
	hard)
		boot0=$(bi_bootid) || boot0=""
		[ -n "$boot0" ] || { echo "cannot read the board's boot_id before the reboot"; return 1; }
		# the connection drops with the board, so this exit status means nothing
		bi_board "echo 1 > $BI_ROOT/proc/sys/kernel/sysrq; echo b > $BI_ROOT/proc/sysrq-trigger" || true
		sleep "$BI_BOOT_WAIT"
		while [ "$i" -lt 60 ]; do
			if bi_board true 2>/dev/null; then break; fi
			i=$((i + 1))
			sleep 5
		done
		[ "$i" -lt 60 ] || { echo "the board did not come back within 5 minutes"; return 1; }
		boot1=$(bi_bootid) || boot1=""
		[ -n "$boot1" ] || { echo "cannot read the board's boot_id after the reboot"; return 1; }
		[ "$boot1" != "$boot0" ] || { echo "boot_id is still $boot0: the board did not reboot"; return 1; }
		echo "board rebooted: boot_id $boot0 -> $boot1"
		;;
	*)
		echo "bi_restart: unknown mode '$1'"
		return 1
		;;
	esac
	bi_ready 120 || { echo "xkmsd does not answer after the $1 restart"; return 1; }
}

# --- the durability ledger: every acknowledged write is recorded, then re-checked ----------
# A ledger line is: kind|id|a|b|c|d, written only after xkmsctl reported success.
# kinds: sym (key id, ciphertext, nonce, tag, plaintext), sig (key id, signature, message),
#        meta (key id, sha256 of the key's metadata), cert (cert id, PEM sha256).

bi_ledger() { echo "$BI_WORK/ledger.${1:-main}"; }

# bi_ack <ledger> <id>: xkmsd acknowledged the create of <id>; from now the key
# is owed. Record it before any follow-up call, so a failed or skipped read
# (BI_WRITE_FAIL_OK included) can never drop it from the verification.
bi_ack() { echo "ack|$2||||" >>"$1"; }

# bi_write_set <name> <count> <prefix>: write count keys, a signature or ciphertext each, and a certificate.
bi_write_set() {
	local name=$1 n=$2 pfx=$3 i id j ct nonce tag sig L
	L=$(bi_ledger "$name")
	for ((i = 0; i < n; i++)); do
		id="$pfx-$i"
		# A create that never got an answer (failed, or cut off) is unknown:
		# bi_verify_set reports it and owes it nothing.
		echo "try|$id||||" >>"$L"
		if [ $((i % 2)) -eq 0 ]; then
			bi_ctl key generate "$id" --key-type symmetric --algorithm aes-256-gcm --key-size 256 >/dev/null 2>&1 || {
				bi_wfail "write $id: generate"
				continue
			}
			bi_ack "$L" "$id"
			j=$(bi_ctl -o json key encrypt "$id" "plain-$id" 2>/dev/null) || { bi_wfail "write $id: encrypt after an acknowledged create"; continue; }
			ct=$(bi_jget "$j" ciphertext) nonce=$(bi_jget "$j" nonce) tag=$(bi_jget "$j" tag)
			echo "sym|$id|$ct|$nonce|$tag|plain-$id" >>"$L"
		else
			bi_ctl key generate "$id" --key-algorithm ecdsa --curve P-256 --key-type signing >/dev/null 2>&1 || {
				bi_wfail "write $id: generate"
				continue
			}
			bi_ack "$L" "$id"
			j=$(bi_ctl -o json key sign "$id" "msg-$id" 2>/dev/null) || { bi_wfail "write $id: sign after an acknowledged create"; continue; }
			sig=$(bi_jget "$j" signature)
			echo "sig|$id|$sig|msg-$id||" >>"$L"
		fi
		j=$(bi_ctl -o json key get "$id" 2>/dev/null) || { bi_wfail "write $id: get after an acknowledged create"; continue; }
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

# Background writers. Each creates keys into ledger <name>, one bi_write_set at
# a time, and looks at the stop flag only between those: a request it started
# runs to its answer, so a create xkmsctl acknowledged is always in the ledger
# before the writer exits. Each writer is its own process group (with its
# xkmsctl, see bi_ctl), which bi_stop_writers kills only as a last resort.
BI_WRITERS=()
BI_STOP_FLAG=""

# bi_spawn_writer <name> <id prefix>: starts one writer; appends its PID to BI_WRITERS.
bi_spawn_writer() {
	[ -n "$BI_STOP_FLAG" ] || {
		BI_STOP_FLAG=$BI_WORK/.stop-writers.$$
		rm -f "$BI_STOP_FLAG"
		trap 'bi_stop_writers 0' EXIT
		trap 'exit 130' INT TERM
	}
	set -m
	(
		set +m
		BI_WRITE_FAIL_OK=1 BI_WRITE_CERT=0
		i=0
		while [ ! -e "$BI_STOP_FLAG" ]; do
			bi_write_set "$1" 1 "$2-$i"
			i=$((i + 1))
		done
	) </dev/null >/dev/null 2>&1 &
	BI_WRITERS+=($!)
	set +m
}

# bi_stop_writers [<secs>]: sets the stop flag and waits up to <secs> (default
# BI_DRAIN_SECS, else three xkmsctl timeouts plus 10) for every writer to finish
# its request and exit. A writer still running then is killed with its whole
# process group; its last request stays unknown (a try with no ack), never absent.
bi_stop_writers() {
	local secs=${1:-${BI_DRAIN_SECS:-$((3 * ${BI_CTL_TIMEOUT:-60} + 10))}} p t=0 left running
	[ "${#BI_WRITERS[@]}" -gt 0 ] || return 0
	: >"$BI_STOP_FLAG"
	while :; do
		# jobs -r: the background jobs still running (an exited writer is
		# not, though kill -0 would still find its zombie)
		running=" $(jobs -rp | tr '\n' ' ') "
		left=()
		for p in "${BI_WRITERS[@]}"; do
			case $running in *" $p "*) left+=("$p") ;; esac
		done
		[ "${#left[@]}" -gt 0 ] && [ "$t" -lt "$secs" ] || break
		sleep 1
		t=$((t + 1))
	done
	for p in "${left[@]}"; do
		echo "writer $p still in a request after ${secs}s: killing its process group; that request is unknown"
		kill -KILL -- "-$p" 2>/dev/null
	done
	for p in "${BI_WRITERS[@]}"; do wait "$p" 2>/dev/null; done
	BI_WRITERS=()
	rm -f "$BI_STOP_FLAG"
}

# bi_verify_set <name>: every ledger entry must still hold; a miss is CRITICAL.
bi_verify_set() {
	local name=$1 L kind id a b c d j n=0 bad=0 out
	L=$(bi_ledger "$name")
	[ -s "$L" ] || { bi_fail "verify $name: empty ledger"; return 0; }
	local -A open=()
	while IFS='|' read -r kind id a b c d; do
		[ "$kind" != try ] || { open[$id]=1; continue; }
		n=$((n + 1))
		case $kind in
		ack)
			unset "open[$id]"
			if ! bi_ctl key get "$id" >/dev/null 2>&1; then
				bi_crit "acknowledged key $id does not exist"
				bad=$((bad + 1))
			fi
			;;
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
	# Never absent, never owed: the request failed or was cut off, so whether
	# xkmsd kept it is unknown.
	[ "${#open[@]}" -eq 0 ] || echo "verify $name: ${#open[@]} create(s) never acknowledged (failed or in flight at a stop or cut): unknown, not checked"
	[ "$n" -gt 0 ] || { bi_fail "verify $name: no acknowledged write in the ledger"; return 0; }
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
