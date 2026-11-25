#!/usr/bin/env bash
# The on-target check (scripts/platform-image-xkmsd-target-check.sh), run with a
# fake ssh on PATH: every remote command is answered from a fixture directory.
# The good fixture is what a booted image with a healthy xkmsd.service prints;
# each failure fixture changes one thing and must fail the script, never skip.
# No board, no network, no bitbake.
set -u
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch" "$TMP_ROOT"' EXIT

script=$ROOT/scripts/platform-image-xkmsd-target-check.sh
bin=$scratch/bin
mkdir -p "$bin"
cat >"$bin/ssh" <<'EOF'
#!/usr/bin/env bash
# Fake ssh: logs its arguments, reads the remote script from stdin and answers
# from the files of $FAKE_FIX.
printf 'ssh %s\n' "$*" >>"$FAKE_SSH_LOG"
if [ "${FAKE_SSH_DOWN:-}" = 1 ]; then
	echo "ssh: connect to host: Connection refused" >&2
	exit 255
fi
s=$(cat)
f=$FAKE_FIX
case $s in
*"remount,ro"*)
	echo "REMOTE remount-ro" >>"$FAKE_SSH_LOG"
	cat "$f/rotest"
	;;
*"systemctl show xkmsd.service"*)
	echo "REMOTE show-unit" >>"$FAKE_SSH_LOG"
	cat "$f/show"
	;;
*"systemctl show var-lib-xkms.mount"*)
	echo "REMOTE show-mount" >>"$FAKE_SSH_LOG"
	cat "$f/mountunit"
	;;
*"/status"*)
	echo "REMOTE proc-status" >>"$FAKE_SSH_LOG"
	cat "$f/status"
	;;
*"id -u xkmsd"*)
	echo "REMOTE ids" >>"$FAKE_SSH_LOG"
	cat "$f/ids"
	;;
*findmnt*)
	echo "REMOTE findmnt" >>"$FAKE_SSH_LOG"
	cat "$f/mount"
	exit "$(cat "$f/mount.rc")"
	;;
*"stat -c"*)
	echo "REMOTE stat" >>"$FAKE_SSH_LOG"
	cat "$f/stat"
	;;
*)
	echo "fake ssh: unexpected remote command: $s" >&2
	exit 99
	;;
esac
EOF
chmod +x "$bin/ssh"

# The good fixture: unit active, sandboxed, running as uid 995, state on its own
# mount, the read-only start refused and everything restored.
good=$scratch/good
mkdir -p "$good"
cat >"$good/show" <<'EOF'
ActiveState=active
SubState=running
MainPID=412
User=xkmsd
Group=xkmsd
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectProc=invisible
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectClock=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
CapabilityBoundingSet=
UMask=0077
EOF
printf '995\n994\n' >"$good/ids"
printf 'Name:\txkmsd\nUmask:\t0077\nState:\tS (sleeping)\nUid:\t995\t995\t995\t995\nGid:\t994\t994\t994\t994\nGroups:\t\nCapInh:\t0000000000000000\nCapPrm:\t0000000000000000\nCapEff:\t0000000000000000\nCapBnd:\t0000000000000000\nCapAmb:\t0000000000000000\nNoNewPrivs:\t1\nSeccomp:\t2\n' >"$good/status"
printf 'TARGET="/var/lib/xkms" FSTYPE="ext4" LABEL="xkms-state" OPTIONS="rw,nosuid,nodev,noexec,noatime"\n' >"$good/mount"
echo 0 >"$good/mount.rc"
printf 'ActiveState=active\nWhere=/var/lib/xkms\nWhat=/dev/disk/by-label/xkms-state\n' >"$good/mountunit"
printf '995 994 750\n' >"$good/stat"
cat >"$good/rotest" <<'EOF'
STOP=ok
REMOUNT_RO=ok
RO_OPTS=ro,nosuid,nodev,noexec,noatime
START_RC=1
START_STATE=inactive
RESTORE_RW=ok
RESTORE_START=ok
EOF

# variant NAME FILE FROM TO: a copy of the good fixture whose FILE has FROM
# replaced by TO (the whole file when FROM is empty); prints the directory.
variant() {
	local d=$scratch/v-$1 c
	rm -rf "$d"
	cp -R "$good" "$d"
	if [ -z "$3" ]; then
		printf '%s' "$4" >"$d/$2"
	else
		c=$(<"$d/$2")
		printf '%s\n' "${c//"$3"/"$4"}" >"$d/$2"
	fi
	printf '%s' "$d"
}

tc() { # FIXTURE_DIR [VAR=value...]: the script against a fixture
	local fix=$1
	shift
	: >"$scratch/ssh.log"
	run env PATH="$bin:$PATH" XKMSD_TARGET_HOST=board.invalid FAKE_FIX="$fix" \
		FAKE_SSH_LOG="$scratch/ssh.log" "$@" bash "$script"
}
logged() { # PATTERN: the ssh log holds PATTERN
	local l
	while IFS= read -r l; do case $l in *"$1"*) return 0 ;; esac; done <"$scratch/ssh.log"
	return 1
}
not_logged() { ! logged "$1"; }
log_check() { # NAME CMD...: pass when the command succeeds
	local name=$1
	shift
	if "$@"; then pass "$name"; else fail "$name" "ssh log: $(<"$scratch/ssh.log")"; fi
}

# The script and the make target exist.
if [ -f "$script" ]; then pass "the target-check script exists"; else fail "the target-check script exists" "missing $script"; fi

# Good: every property holds.
tc "$good"
check "target: a healthy booted image passes" 0 "xkmsd-target-check: all passed" \
	"ok   xkmsd.service is active" "ok   the main process runs as xkmsd under the unit's sandbox" \
	"ok   /var/lib/xkms is the persistent xkms-state mount" \
	"ok   xkmsd refuses to start on a read-only state mount"
log_check "target: the read-only step ran" logged "REMOTE remount-ro"

# No host: refused before any ssh.
: >"$scratch/ssh.log"
run env -u XKMSD_TARGET_HOST PATH="$bin:$PATH" FAKE_FIX="$good" FAKE_SSH_LOG="$scratch/ssh.log" bash "$script"
check "target: without XKMSD_TARGET_HOST it refuses" nonzero "XKMSD_TARGET_HOST"
log_check "target: without a host nothing was run over ssh" not_logged "ssh "
run env PATH="$bin:$PATH" XKMSD_TARGET_HOST= FAKE_FIX="$good" FAKE_SSH_LOG="$scratch/ssh.log" bash "$script"
check "target: an empty XKMSD_TARGET_HOST refuses" nonzero "XKMSD_TARGET_HOST"
run env PATH="$bin:$PATH" XKMSD_TARGET_HOST=-oProxyCommand=x FAKE_FIX="$good" FAKE_SSH_LOG="$scratch/ssh.log" bash "$script"
check "target: a host that looks like an ssh option refuses" nonzero "XKMSD_TARGET_HOST"

# The host is not reachable.
tc "$good" FAKE_SSH_DOWN=1
check "target: an unreachable host fails" nonzero "FAIL:" "cannot read"

# 1. The unit and its sandbox.
tc "$(variant inactive show 'ActiveState=active' 'ActiveState=failed')"
check "target: an inactive unit fails" nonzero "FAIL: xkmsd.service is not active"
tc "$(variant notrunning show 'SubState=running' 'SubState=exited')"
check "target: a unit that is not running fails" nonzero "FAIL: xkmsd.service SubState is 'exited'"
tc "$(variant nopid show 'MainPID=412' 'MainPID=0')"
check "target: no main process fails" nonzero "FAIL: xkmsd.service has no main process"
tc "$(variant user show 'User=xkmsd' 'User=root')"
check "target: a unit whose User is root fails" nonzero "FAIL: xkmsd.service User is 'root'"
tc "$(variant nouser show 'User=xkmsd' '')"
check "target: a unit with no User property fails" nonzero "FAIL: xkmsd.service User is ''"
tc "$(variant nnp show 'NoNewPrivileges=yes' 'NoNewPrivileges=no')"
check "target: a unit that allows new privileges fails" nonzero "FAIL: xkmsd.service sandbox: NoNewPrivileges is 'no'"
tc "$(variant tmp show 'PrivateTmp=yes' 'PrivateTmp=no')"
check "target: a unit without a private /tmp fails" nonzero "FAIL: xkmsd.service sandbox: PrivateTmp is 'no'"
tc "$(variant strict show 'ProtectSystem=strict' 'ProtectSystem=full')"
check "target: ProtectSystem not strict fails" nonzero "FAIL: xkmsd.service sandbox: ProtectSystem is 'full'"
tc "$(variant home show 'ProtectHome=yes' 'ProtectHome=no')"
check "target: ProtectHome off fails" nonzero "FAIL: xkmsd.service sandbox: ProtectHome is 'no'"
tc "$(variant suid show 'RestrictSUIDSGID=yes' 'RestrictSUIDSGID=no')"
check "target: RestrictSUIDSGID off fails" nonzero "FAIL: xkmsd.service sandbox: RestrictSUIDSGID is 'no'"
tc "$(variant missing show 'ProtectClock=yes' '')"
check "target: a sandbox property systemctl does not print fails" nonzero "FAIL: xkmsd.service sandbox: ProtectClock is ''"
tc "$(variant caps show 'CapabilityBoundingSet=' 'CapabilityBoundingSet=cap_net_bind_service')"
check "target: a non-empty capability bounding set fails" nonzero "FAIL: xkmsd.service sandbox: CapabilityBoundingSet is 'cap_net_bind_service'"
tc "$(variant umask show 'UMask=0077' 'UMask=0022')"
check "target: a UMask other than 0077 fails" nonzero "FAIL: xkmsd.service sandbox: UMask is '0022'"

# 2. The main process as the kernel sees it.
tc "$(variant rootproc status 'Uid:	995	995	995	995' 'Uid:	0	0	0	0')"
check "target: a main process that runs as root fails" nonzero "FAIL: the main process Uid is 0 0 0 0"
tc "$(variant euid status 'Uid:	995	995	995	995' 'Uid:	995	0	995	995')"
check "target: a main process with effective uid 0 fails" nonzero "FAIL: the main process Uid is 995 0 995 995"
tc "$(variant rootgid status 'Gid:	994	994	994	994' 'Gid:	0	0	0	0')"
check "target: a main process of group root fails" nonzero "FAIL: the main process Gid is 0 0 0 0"
tc "$(variant wronguid ids '995' '1000')"
check "target: a main process of another uid than the xkmsd user fails" nonzero "FAIL: the main process Uid is 995 995 995 995, not the xkmsd user's 1000"
tc "$(variant nouid ids '' '')"
check "target: no xkmsd user on the image fails" nonzero "FAIL: the image has no xkmsd user"
tc "$(variant rootuser ids '995' '0')"
check "target: an xkmsd user with uid 0 fails" nonzero "FAIL: the xkmsd user has uid 0"
tc "$(variant capeff status 'CapEff:	0000000000000000' 'CapEff:	0000000000003000')"
check "target: a main process with effective capabilities fails" nonzero "FAIL: the main process CapEff is 0000000000003000"
tc "$(variant capbnd status 'CapBnd:	0000000000000000' 'CapBnd:	000001ffffffffff')"
check "target: a main process with a full bounding set fails" nonzero "FAIL: the main process CapBnd is 000001ffffffffff"
tc "$(variant capamb status 'CapAmb:	0000000000000000' 'CapAmb:	0000000000000400')"
check "target: a main process with ambient capabilities fails" nonzero "FAIL: the main process CapAmb is 0000000000000400"
tc "$(variant nnpproc status 'NoNewPrivs:	1' 'NoNewPrivs:	0')"
check "target: a main process without no_new_privs fails" nonzero "FAIL: the main process NoNewPrivs is 0"
tc "$(variant seccomp status 'Seccomp:	2' 'Seccomp:	0')"
check "target: a main process without a seccomp filter fails" nonzero "FAIL: the main process Seccomp is 0"
tc "$(variant nostatus status '' '')"
check "target: an unreadable /proc status fails" nonzero "FAIL: the main process Uid is ''"

# 3. The state directory is the persistent state mount.
tc "$(variant nomp mount '' '')" # an empty mount answer
check "target: an empty findmnt answer fails" nonzero "FAIL: /var/lib/xkms is not a mount point"
d=$(variant notmp mount.rc '' '1')
tc "$d"
check "target: a state directory that is not a mount point fails" nonzero "FAIL: /var/lib/xkms is not a mount point"
tc "$(variant label mount 'LABEL="xkms-state"' 'LABEL="data"')"
check "target: a state mount of another label fails" nonzero "FAIL: /var/lib/xkms is not the xkms-state partition"
tc "$(variant fstype mount 'FSTYPE="ext4"' 'FSTYPE="tmpfs"')"
check "target: a volatile (tmpfs) state mount fails" nonzero "FAIL: /var/lib/xkms is a tmpfs mount, not ext4"
tc "$(variant rw mount 'OPTIONS="rw,' 'OPTIONS="ro,')"
check "target: a state mount that is read-only fails" nonzero "FAIL: /var/lib/xkms is mounted read-only"
tc "$(variant noexec mount ',noexec' '')"
check "target: a state mount without noexec fails" nonzero "FAIL: /var/lib/xkms is mounted without noexec"
tc "$(variant nosuid mount ',nosuid' '')"
check "target: a state mount without nosuid fails" nonzero "FAIL: /var/lib/xkms is mounted without nosuid"
tc "$(variant nodev mount ',nodev' '')"
check "target: a state mount without nodev fails" nonzero "FAIL: /var/lib/xkms is mounted without nodev"
tc "$(variant unitinactive mountunit 'ActiveState=active' 'ActiveState=inactive')"
check "target: an inactive state mount unit fails" nonzero "FAIL: var-lib-xkms.mount is not active"
tc "$(variant unitwhat mountunit 'What=/dev/disk/by-label/xkms-state' 'What=/dev/disk/by-label/other')"
check "target: a state mount unit of another device fails" nonzero "FAIL: var-lib-xkms.mount What is '/dev/disk/by-label/other'"
tc "$(variant unitwhere mountunit 'Where=/var/lib/xkms' 'Where=/var/lib/other')"
check "target: a state mount unit of another path fails" nonzero "FAIL: var-lib-xkms.mount Where is '/var/lib/other'"
tc "$(variant owner stat '995 994 750' '0 0 755')"
check "target: a state directory owned by root fails" nonzero "FAIL: /var/lib/xkms is owned by 0:0 mode 755, want 995:994 mode 750"

# 4. The read-only start refusal.
tc "$(variant rostart rotest 'START_RC=1' 'START_RC=0')"
check "target: a unit that starts on a read-only state mount fails" nonzero "FAIL: xkmsd.service started on a read-only state mount"
tc "$(variant roactive rotest 'START_STATE=inactive' 'START_STATE=active')"
check "target: a unit active on a read-only state mount fails" nonzero "FAIL: xkmsd.service is active on a read-only state mount"
tc "$(variant noremount rotest 'REMOUNT_RO=ok' 'REMOUNT_RO=fail')"
check "target: a read-only remount that was refused fails (the check did not run)" nonzero "FAIL: the state mount could not be remounted read-only"
tc "$(variant remountrw rotest 'RO_OPTS=ro,' 'RO_OPTS=rw,')"
check "target: a remount that left the mount read-write fails" nonzero "FAIL: the state mount is not read-only after the remount"
tc "$(variant nostop rotest 'STOP=ok' 'STOP=fail')"
check "target: a unit that does not stop fails" nonzero "FAIL: xkmsd.service did not stop before the read-only check"
tc "$(variant restorerw rotest 'RESTORE_RW=ok' 'RESTORE_RW=fail')"
check "target: a state mount left read-only fails" nonzero "FAIL: the state mount was not remounted read-write"
tc "$(variant restorestart rotest 'RESTORE_START=ok' 'RESTORE_START=fail')"
check "target: a unit that does not start again fails" nonzero "FAIL: xkmsd.service did not start again after the read-only check"
tc "$(variant emptyro rotest '' '')"
check "target: an empty answer from the read-only step fails" nonzero "FAIL: the state mount could not be remounted read-only"

# The read-only step changes the board: it must not run after a failed check.
tc "$(variant skip show 'User=xkmsd' 'User=root')"
check "target: a failed property check says the read-only step did not run" nonzero "FAIL: the read-only start check did not run"
log_check "target: no remount was sent after a failed check" not_logged "REMOTE remount-ro"

# The make target: it refuses without the host variable, and with it runs the script.
: >"$scratch/ssh.log"
run env -u XKMSD_TARGET_HOST -u MAKEFLAGS -u MAKELEVEL PATH="$bin:$PATH" FAKE_FIX="$good" FAKE_SSH_LOG="$scratch/ssh.log" \
	make -C "$ROOT" --no-print-directory platform-image-xkmsd-target-check
check "make: platform-image-xkmsd-target-check refuses without XKMSD_TARGET_HOST" nonzero "XKMSD_TARGET_HOST"
log_check "make: the refused target ran nothing over ssh" not_logged "ssh "
run env -u MAKEFLAGS -u MAKELEVEL PATH="$bin:$PATH" XKMSD_TARGET_HOST=board.invalid FAKE_FIX="$good" FAKE_SSH_LOG="$scratch/ssh.log" \
	make -C "$ROOT" --no-print-directory platform-image-xkmsd-target-check
check "make: platform-image-xkmsd-target-check runs the script when the host is set" 0 "xkmsd-target-check: all passed"

# ssh runs non-interactively, with the host and nothing else from the repo.
tc "$good"
log_check "target: ssh runs with BatchMode" logged "BatchMode=yes"
log_check "target: ssh goes to the host of XKMSD_TARGET_HOST" logged "board.invalid"

finish
