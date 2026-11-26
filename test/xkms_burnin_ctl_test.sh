#!/usr/bin/env bash
# Tests scripts/xkms/burnin/board-ctl.sh, the --ctl stand-in that runs the
# board's xkmsctl over ssh. A fake ssh on PATH records its argv and stdin and
# runs the remote command locally, against a fake su and a fake xkmsctl. No
# board, no network. The fake client key holds a marker that must never reach
# any captured output.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
bc=$here/scripts/xkms/burnin/board-ctl.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

FAILS=0
ok() {
	local name=$1
	shift
	if "$@"; then echo "ok   $name"; else echo "FAIL $name"; FAILS=$((FAILS + 1)); fi
}

MARKER=KEY-MARKER-9f3a61c2d7
fakebin=$tmp/bin
mkdir -p "$fakebin" "$tmp/work"

# ssh: log argv, skip "-o x" pairs and the host, tee stdin to a log, run the
# command in a local shell. FAKE_SSH_FAIL_ON: fail a command containing it.
cat >"$fakebin/ssh" <<'EOF'
#!/bin/sh
echo "ssh $*" >>"$FAKE_SSH_LOG"
while [ "$1" = -o ]; do shift 2; done
host=$1
shift
echo "host=$host" >>"$FAKE_SSH_LOG"
if [ -n "${FAKE_SSH_FAIL_ON:-}" ]; then
	case "$*" in *"$FAKE_SSH_FAIL_ON"*) cat >/dev/null; exit 1 ;; esac
fi
tee -a "$FAKE_SSH_STDIN" | sh -c "$*"
EOF
# su -s /bin/sh xkms -c CMD: run CMD as the (same) user, recording the call.
cat >"$fakebin/su" <<'EOF'
#!/bin/sh
echo "su $1 $2 $3 $4" >>"$FAKE_SSH_LOG"
[ "$1 $2 $3 $4" = "-s /bin/sh xkms -c" ] || exit 64
exec /bin/sh -c "$5"
EOF
cat >"$fakebin/chown" <<'EOF'
#!/bin/sh
exit 0
EOF
# The fake xkmsctl: records argv (one <arg> per line), reads the fake key by
# path only (never prints it), reads and writes the files it is given.
cat >"$tmp/xkmsctl" <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '<%s>\n' "$a"; done; } >>"$FAKE_ARGV"
key=
prev=
for a in "$@"; do
	[ "$prev" = --tls-key ] && key=$a
	prev=$a
done
[ -r "$key" ] || { echo "fake xkmsctl: no key at $key" >&2; exit 9; }
echo "fake-stderr-line" >&2
echo "fake-stdout-line"
prev=
sub=
for a in "$@"; do
	case "$prev" in
	--output | --key-output) echo "written-by-$prev" >"$a" ;;
	--ca-cert | --ca-key | --csr) cat "$a" >>"$FAKE_SEEN" ;;
	esac
	case "$a" in /tmp/xkms-burnin.*) echo "${a%/*}" >>"$FAKE_DIRS" ;; esac
	prev=$a
done
for a in "$@"; do
	last=$a
	case "$a" in --ca-cert=* | --ca-key=* | --csr=*) cat "${a#*=}" >>"$FAKE_SEEN" ;; esac
done
case "$*" in
*"cert save "*) cat "$last" >>"$FAKE_SEEN" ;;
*"key export "*) echo "exported-key-bytes" >"$last" ;;
esac
exit "${FAKE_CTL_RC:-0}"
EOF
chmod +x "$fakebin/ssh" "$fakebin/su" "$fakebin/chown" "$tmp/xkmsctl"

echo "$MARKER" >"$tmp/admin-key.pem"
echo cert >"$tmp/admin-cert.pem"
echo ca >"$tmp/ca.pem"

export PATH=$fakebin:$PATH
export FAKE_SSH_LOG=$tmp/ssh.log FAKE_SSH_STDIN=$tmp/ssh.stdin FAKE_ARGV=$tmp/argv.log
export FAKE_SEEN=$tmp/seen.log FAKE_DIRS=$tmp/dirs.log
export XKMS_BOARD=board.invalid
export XKMS_BOARD_CTL=$tmp/xkmsctl
export XKMS_BOARD_TLS_CA=$tmp/ca.pem XKMS_BOARD_TLS_CERT=$tmp/admin-cert.pem XKMS_BOARD_TLS_KEY=$tmp/admin-key.pem

reset() { : >"$FAKE_SSH_LOG"; : >"$FAKE_SSH_STDIN"; : >"$FAKE_ARGV"; : >"$FAKE_SEEN"; : >"$FAKE_DIRS"; unset FAKE_CTL_RC FAKE_SSH_FAIL_ON; }
run() { # run <args...>: RC, $tmp/out, $tmp/err
	"$bc" "$@" >"$tmp/out" 2>"$tmp/err" </dev/null
	RC=$?
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }
no_marker() {
	local f
	for f in "$FAKE_SSH_LOG" "$FAKE_SSH_STDIN" "$FAKE_ARGV" "$FAKE_SEEN" "$tmp/out" "$tmp/err"; do
		lacks "$f" "$MARKER" || return 1
	done
}
gone() { # every temp dir the fake xkmsctl saw is removed
	local d any=0
	while read -r d; do
		any=1
		[ ! -e "$d" ] || return 1
	done <"$FAKE_DIRS"
	[ "$any" = 1 ]
}

# --- no board ---------------------------------------------------------------
XKMS_BOARD='' "$bc" key list >"$tmp/out" 2>"$tmp/err"
ok "no XKMS_BOARD is a usage error" [ "$?" = 2 ]

# --- arguments, quoting, TLS flags -----------------------------------------
reset
run -o json key sign "my key" "it's \$HOME \"q\" \`x\` ; echo hi" --note 'a b*'
ok "plain call exits 0" [ "$RC" = 0 ]
ok "stdout is xkmsctl's" has "$tmp/out" fake-stdout-line
ok "stderr is xkmsctl's" has "$tmp/err" fake-stderr-line
want=$(printf '<%s>\n' --tls-ca "$tmp/ca.pem" --tls-cert "$tmp/admin-cert.pem" --tls-key "$tmp/admin-key.pem" \
	-o json key sign "my key" "it's \$HOME \"q\" \`x\` ; echo hi" --note 'a b*')
ok "TLS flags first, every argument intact (spaces, quotes, \$, backtick, glob)" [ "$(cat "$FAKE_ARGV")" = "$want" ]
ok "one ssh session for a call without files" [ "$(grep -c '^ssh ' "$FAKE_SSH_LOG")" = 1 ]
ok "ssh goes to XKMS_BOARD" has "$FAKE_SSH_LOG" "host=board.invalid"
ok "xkmsctl runs as the xkms user" has "$FAKE_SSH_LOG" "su -s /bin/sh xkms -c"
ok "the key is named by path" has "$FAKE_SSH_LOG" "$tmp/admin-key.pem"
ok "no marker in any capture" no_marker

reset
(unset XKMS_BOARD_CTL XKMS_BOARD_TLS_CA XKMS_BOARD_TLS_CERT XKMS_BOARD_TLS_KEY; XKMS_BOARD=b "$bc" key list >/dev/null 2>&1)
ok "defaults name the board paths" bash -c "grep -qF '/usr/local/bin/xkmsctl' '$FAKE_SSH_LOG' && grep -qF '/var/lib/xkms/storage/unified-tls/cert.pem' '$FAKE_SSH_LOG' && grep -qF '/var/lib/xkms/storage/admin-cert.pem' '$FAKE_SSH_LOG' && grep -qF '/var/lib/xkms/storage/admin-key.pem' '$FAKE_SSH_LOG'"

# --- exit status -------------------------------------------------------------
reset
FAKE_CTL_RC=7 run key get x
ok "exit status passes through" [ "$RC" = 7 ]
ok "stdout still xkmsctl's on failure" has "$tmp/out" fake-stdout-line

# --- file output and input round trip ---------------------------------------
reset
rm -f "$tmp/work/ca.crt" "$tmp/work/ca.key"
run cert generate-ca --cn burnin-x --output "$tmp/work/ca.crt" --key-output "$tmp/work/ca.key"
ok "generate-ca exits 0" [ "$RC" = 0 ]
ok "--output downloaded" has "$tmp/work/ca.crt" written-by---output
ok "--key-output downloaded" has "$tmp/work/ca.key" written-by---key-output
ok "board path replaces the local path" lacks "$FAKE_ARGV" "$tmp/work/ca.crt"
ok "temp dir removed" gone
ok "no marker (outputs)" no_marker

reset
echo "ca-cert-bytes" >"$tmp/work/in.crt"
echo "ca-key-bytes" >"$tmp/work/in.key"
rm -f "$tmp/work/s.crt"
run cert issue --ca-cert "$tmp/work/in.crt" --ca-key="$tmp/work/in.key" --cn s --output "$tmp/work/s.crt"
ok "issue exits 0" [ "$RC" = 0 ]
ok "--ca-cert uploaded" has "$FAKE_SEEN" ca-cert-bytes
ok "--ca-key=FILE uploaded" has "$FAKE_SEEN" ca-key-bytes
ok "issue output downloaded" has "$tmp/work/s.crt" written-by---output
ok "temp dir removed after issue" gone

reset
echo "cert-to-save" >"$tmp/work/save.crt"
run cert save my-id "$tmp/work/save.crt"
ok "cert save exits 0" [ "$RC" = 0 ]
ok "cert save file uploaded" has "$FAKE_SEEN" cert-to-save
ok "cert save id kept" has "$FAKE_ARGV" "<my-id>"
ok "cert save temp dir removed" gone

reset
rm -f "$tmp/work/exp.bin"
run key export my-id "$tmp/work/exp.bin"
ok "key export exits 0" [ "$RC" = 0 ]
ok "key export file downloaded" has "$tmp/work/exp.bin" exported-key-bytes
ok "key export temp dir removed" gone

# -o json before the command is a format, not a file
reset
run -o json key export my-id "$tmp/work/exp2.bin"
ok "-o json is not treated as a file" lacks "$FAKE_SSH_LOG" "-o' 'json"
ok "-o json export still downloads" [ -s "$tmp/work/exp2.bin" ]

# --- failure: cleanup, no download -------------------------------------------
reset
rm -f "$tmp/work/f.crt"
FAKE_CTL_RC=5 run cert generate-ca --cn x --output "$tmp/work/f.crt"
ok "failed call passes the status" [ "$RC" = 5 ]
ok "failed call downloads nothing" [ ! -e "$tmp/work/f.crt" ]
ok "temp dir removed after a failure" gone

reset
echo x >"$tmp/work/u.crt"
FAKE_SSH_FAIL_ON="cat >" run cert save id "$tmp/work/u.crt"
ok "failed upload exits non-zero" [ "$RC" != 0 ]
ok "failed upload says so" has "$tmp/err" "cannot upload"
ok "failed upload still sends the cleanup" has "$FAKE_SSH_LOG" "rm -rf '/tmp/xkms-burnin."
rd=$(grep -o "rm -rf '/tmp/xkms-burnin\.[A-Za-z0-9]*" "$FAKE_SSH_LOG" | head -n 1)
rd=${rd#"rm -rf '"}
# shellcheck disable=SC2016 # the inner script expands its own $1
ok "failed upload removes the temp dir" bash -c '[ -n "$1" ] && [ ! -e "$1" ]' _ "$rd"

reset
run cert save id "$tmp/work/does-not-exist.crt"
ok "missing local input is left to xkmsctl, no upload" [ "$(grep -c 'cat >' "$FAKE_SSH_LOG")" = 0 ]
ok "missing input still cleans up" gone

# --- every burn-in script plans with the stand-in ----------------------------
reset
for s in "$here"/scripts/xkms/burnin/*.sh; do
	n=$(basename "$s")
	[ "$n" != lib.sh ] && [ "$n" != board-ctl.sh ] || continue
	"$s" --dry-run --ctl "$bc" board.invalid >"$tmp/dr.log" 2>&1
	rc=$?
	ok "burn-in $n --dry-run with --ctl board-ctl.sh exits 0" [ "$rc" = 0 ]
	ok "burn-in $n --dry-run prints a plan" [ -s "$tmp/dr.log" ]
done
ok "dry runs never call ssh" [ ! -s "$FAKE_SSH_LOG" ]

if [ "$FAILS" -ne 0 ]; then
	echo "xkms_burnin_ctl_test: $FAILS FAILED"
	exit 1
fi
echo "xkms_burnin_ctl_test: OK"
