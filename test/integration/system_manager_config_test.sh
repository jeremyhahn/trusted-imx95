#!/usr/bin/env bash
# test/integration/system_manager_config_test.sh: the system-manager-config row
# of docs/SPEC.md end to end (make integration-test-system-manager-config).
#
# 1. `make system-manager` in a fixture copy of the repository, on a fake
#    imx-sm whose M7 LM block, after the fake patch, is the committed
#    allowlist system-manager/m7-grants.txt: the build passes, reproducible,
#    with the grants check OK, and fails on a widened grant or a test grant.
# 2. The committed allowlist gives the M7 its SCMI agent, channels and mailbox,
#    its core and its power domain, and no test grant.
# 3. The row's documents hold as SPEC.md writes the row: the approval after the
#    survey of #167, the power domains and PHYs of hsm-self-defence, and the
#    System Manager documentation and IMX95RM listed as missing.
#
# Offline. The integration image has neither curl nor perl: the fake imx-sm
# needs no perl, and its toolchain is a file:// URL, so a shim stands in for
# each one that is missing (the curl shim copies file:// URLs only).
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
unset FAKE_NONDET FAKE_FAIL SM_OUT

GRANTS="$ROOT/system-manager/m7-grants.txt"
SPEC="$ROOT/docs/SPEC.md"
ARCH="$ROOT/docs/system-manager-config/architecture.md"
REFS="$ROOT/docs/references/README.md"

# --- shims for the tools sm-build.sh checks and the fake build never runs ---
shim="$TMP_ROOT/shim"
mkdir -p "$shim"
if ! command -v perl >/dev/null 2>&1; then
	printf '%s\n' '#!/bin/sh' 'echo "perl shim: the fake imx-sm runs no perl" >&2' 'exit 1' >"$shim/perl"
	chmod +x "$shim/perl"
fi
if ! command -v curl >/dev/null 2>&1; then
	# shellcheck disable=SC2016 # the shim's own variables
	printf '%s\n' '#!/bin/sh' 'o=; u=' \
		'while [ $# -gt 0 ]; do case $1 in -o) o=$2; shift 2 ;; file://*) u=${1#file://}; shift ;; *) shift ;; esac; done' \
		'[ -n "$o" ] && [ -n "$u" ] || { echo "curl shim: file:// URLs with -o only" >&2; exit 1; }' \
		'cp "$u" "$o"' >"$shim/curl"
	chmod +x "$shim/curl"
fi
export PATH="$shim:$PATH"

# allowlist: the committed grants, comments and blank lines dropped.
allowlist() {
	local l
	while IFS= read -r l || [ -n "$l" ]; do
		l=${l%%#*}
		[ -z "${l// /}" ] || printf '%s\n' "$l"
	done <"$GRANTS"
}

# --- 1. make system-manager on a fake imx-sm ---

# A fake toolchain: a tarball with one top directory holding bin/arm-none-eabi-gcc.
tc="$TMP_ROOT/tc/arm-gnu-toolchain-9.9.rel1-x86_64-arm-none-eabi/bin"
mkdir -p "$tc"
printf '#!/bin/sh\necho fake-gcc\n' >"$tc/arm-none-eabi-gcc"
chmod +x "$tc/arm-none-eabi-gcc"
tar -C "$TMP_ROOT/tc" -cJf "$TMP_ROOT/tc.tar.xz" .
tc_sha=$(sha256sum "$TMP_ROOT/tc.tar.xz" | cut -d' ' -f1)

# cfg <file> <extra M7 line...>: a fake board configuration, an AP LM, then
# the M7 LM holding the committed allowlist and the extra lines.
cfg() {
	local f=$1
	shift
	mkdir -p "$(dirname "$f")"
	{
		echo '# fake mx95frdm-pro'
		echo 'LM0 name="AP"'
		echo 'SCMI_AGENT1 name="AP-S"'
		echo 'SYS ALL'
		echo 'PD_HSIO OWNER'
		echo 'LM1 name="M7"'
		allowlist
		[ $# -eq 0 ] || printf '%s\n' "$@"
	} >"$f"
}

# The fake imx-sm ships the M7 block with two test grants; patch 0001 takes
# them out, so the patched block is the allowlist.
repo="$TMP_ROOT/imx-sm"
cfg "$repo/configs/other/fakepro.cfg" 'BRD_SM_CTRL_TEST ALL' 'PD_M7 test'
# shellcheck disable=SC2016 # make's $(...), not the shell's
printf '%s\n' 'cfg:' \
	'	mkdir -p configs/$(config) && cp configs/other/$(config).cfg configs/$(config)/config.h && cp configs/other/scmi.h configs/$(config)/config_scmi.h' \
	'all:' \
	'	mkdir -p build/$(config)' \
	'	{ $(SM_CROSS_COMPILE)gcc; echo $(M) $(SOURCE_DATE_EPOCH); cat configs/$(config)/config.h; } >build/$(config)/m33_image.bin' \
	>"$repo/Makefile"
# What `make cfg` generates for scripts/sm-perf-check.sh: the M7 agent's record
# holds the one PERF_M7 line, ALL, and no other agent holds that domain.
printf '%s\n' \
	'/* SCMI AGENT0 Config (AP) */' \
	'	.perfPerms[DEV_SM_PERF_A55] = SM_SCMI_PERM_ALL,' \
	'/* SCMI AGENT1 Config (M7) */' \
	'	.perfPerms[DEV_SM_PERF_M7] = SM_SCMI_PERM_ALL,' \
	>"$repo/configs/other/scmi.h"
g() { git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
git -C "$repo" init -q
g add -A
GIT_COMMITTER_DATE=@1700000000 g commit -q -m fake
g tag -a v1 -m v1
commit=$(git -C "$repo" rev-parse HEAD)
cfg_sha=$(sha256sum "$repo/configs/other/fakepro.cfg" | cut -d' ' -f1)

# fixture <dir> <patched cfg>: a fixture repository whose system-manager/
# holds the allowlist, one patch from the fake configuration to <patched cfg>
# and a lock pinning all of it.
fixture() {
	local d=$1 patched=$2 sm
	fixture_repo "$d"
	sm="$d/system-manager"
	mkdir -p "$sm/patches" "$TMP_ROOT/pa/configs/other"
	cp "$GRANTS" "$sm/m7-grants.txt"
	# The fake AP-S block's two lines (see cfg): the allowlist sm-build.sh checks it against.
	printf '# fake\nSYS ALL\nPD_HSIO OWNER\n' >"$sm/ap-s-grants.txt"
	cp "$repo/configs/other/fakepro.cfg" "$TMP_ROOT/pa/configs/other/fakepro.cfg"
	mkdir -p "$TMP_ROOT/pb/configs/other"
	cp "$patched" "$TMP_ROOT/pb/configs/other/fakepro.cfg"
	(cd "$TMP_ROOT" && diff -u pa/configs/other/fakepro.cfg pb/configs/other/fakepro.cfg |
		{ read -r _; read -r _; echo "--- a/configs/other/fakepro.cfg"; echo "+++ b/configs/other/fakepro.cfg"; cat; }) \
		>"$sm/patches/0001-fake.patch" || true
	{
		echo "# fake"
		echo "sm_repo=file://$repo"
		echo "sm_tag=v1"
		echo "sm_commit=$commit"
		echo "sm_config=fakepro"
		echo "sm_config_file=configs/other/fakepro.cfg"
		echo "sm_config_sha256=$cfg_sha"
		echo "sm_patch_sha256=$(sha256sum "$sm/patches/0001-fake.patch" | cut -d' ' -f1)"
		echo "sm_patched_config_sha256=$(sha256sum "$patched" | cut -d' ' -f1)"
		echo "sm_monitor_mode=2"
		echo "toolchain_version=9.9.rel1"
		echo "toolchain_url=file://$TMP_ROOT/tc.tar.xz"
		echo "toolchain_sha256=$tc_sha"
	} >"$sm/sm.lock"
}

n=$(allowlist | wc -l | tr -d ' ')
cfg "$TMP_ROOT/good.cfg"
fixture "$TMP_ROOT/good" "$TMP_ROOT/good.cfg"
run make -s -C "$TMP_ROOT/good" system-manager
check "make system-manager: the patched M7 block equals the committed allowlist" 0 \
	"grants: OK ($n lines)" "reproducible, m33_image.bin"
expect "make system-manager: the image is in out/system-manager" \
	test -s "$TMP_ROOT/good/out/system-manager/m33_image.bin"

cfg "$TMP_ROOT/wide.cfg" 'PD_HSIO OWNER'
fixture "$TMP_ROOT/wide" "$TMP_ROOT/wide.cfg"
run make -s -C "$TMP_ROOT/wide" system-manager
check "make system-manager: a grant the allowlist lacks stops the build" nonzero \
	"grants: UNLISTED PD_HSIO OWNER" "differ from system-manager/m7-grants.txt"

cfg "$TMP_ROOT/test.cfg" 'PD_M7 test'
fixture "$TMP_ROOT/test" "$TMP_ROOT/test.cfg"
run make -s -C "$TMP_ROOT/test" system-manager
check "make system-manager: a test grant left in the M7 block stops the build" nonzero \
	"still holds a test grant"

# --- 2. what the committed allowlist gives the Cortex-M7 ---

ALLOW=$(allowlist)
# has <line>: the allowlist holds the line.
has() { [[ $'\n'"$ALLOW"$'\n' == *$'\n'"$1"$'\n'* ]]; }
# has_prefix <prefix>: an allowlist line starts with the prefix.
has_prefix() { [[ $'\n'"$ALLOW" == *$'\n'"$1"* ]]; }

expect "grants: the M7 is an SCMI agent of its own" has 'SCMI_AGENT0 name="M7"'
expect "grants: the M7's agent-to-platform SCMI channel" has_prefix 'CHANNEL db=0, xport=smt, check=crc32, rpc=scmi, type=a2p'
expect "grants: the M7's SCMI notification channel" has_prefix 'CHANNEL db=1, xport=smt, check=crc32, rpc=scmi, type=p2a_notify'
expect "grants: the M7's messaging unit" has 'MAILBOX type=mu, mu=9, priority=high'
expect "grants: the M7 owns its resources with the full API" has 'OWNER: perm=rw, api=all'
expect "grants: the M7 owns its core" has 'M7P OWNER'
expect "grants: the M7's core starts and stops" has 'CPU_M7P start=2, stop=1'
expect "grants: the M7's power domain" has 'PD_M7 start=1, stop=2'
expect "grants: the M7 keeps its UART" has 'LPUART3 OWNER'
no_test_grant() {
	local l
	while IFS= read -r l; do
		[[ $l == CHANNEL* ]] && continue
		[[ $l == *test* || $l == *TEST* ]] && return 1
	done <<<"$ALLOW"
	return 0
}
expect "grants: no test key or test grant but the default test channel" no_test_grant

# --- 3. the row's documents ---

# holds <file> <text>: the file holds the text.
holds() { [[ $(<"$1") == *"$2"* ]]; }

ROW='| system-manager-config | '
expect "SPEC.md: the row is there" holds "$SPEC" "$ROW"
for s in "The configuration of NXP's System Manager on the Cortex-M33, which stays NXP's code." \
	"The configuration change is approved after the survey of #167 (owner rulings 1243 and 1244): it follows that survey." \
	"It gives the Cortex-M7 firmware of trusted-firmware's \`imx95\` row its clocks, power and resources through SCMI, and the power domains and PHYs that \`hsm-self-defence\` acts on." \
	"The System Manager's documentation and IMX95RM are not in [references/](references/README.md) and are listed as missing." \
	"[system-manager-config/architecture.md](system-manager-config/architecture.md)"; do
	expect "SPEC.md: the row says: ${s:0:60}" holds "$SPEC" "$s"
done

expect "architecture.md: the System Manager stays NXP's code" holds "$ARCH" \
	"NXP's System Manager runs on the Cortex-M33 and stays NXP's code"
expect "architecture.md: approved after the survey of #167" holds "$ARCH" \
	"approved after the survey of #167 (owner rulings 1243 and 1244) and follows that survey"
expect "architecture.md: what the rulings leave open stays proposed" holds "$ARCH" \
	"What rulings 1243 and 1244 do not decide stays proposed, pending owner approval"
expect "architecture.md: the M7's clocks, power and resources through SCMI" holds "$ARCH" \
	"its clocks, power and resources through SCMI"
expect "architecture.md: the power domains and PHYs hsm-self-defence acts on" holds "$ARCH" \
	"acts through the System Manager on power domains and PHYs"
expect "architecture.md: the grants are the committed allowlist" holds "$ARCH" \
	"[\`system-manager/m7-grants.txt\`](../../system-manager/m7-grants.txt)"
expect "architecture.md: the System Manager documentation is missing" holds "$ARCH" \
	"- The System Manager documentation:"
expect "architecture.md: IMX95RM is missing" holds "$ARCH" "- IMX95RM:"
expect "references/README.md: IMX95RM is listed" holds "$REFS" "| IMX95RM, i.MX 95 Applications Processor Reference Manual |"
expect "references/README.md: the System Manager documentation is listed" holds "$REFS" "| System Manager documentation |"

# Negative: the document check sees a dropped Missing entry.
cp "$ARCH" "$TMP_ROOT/arch.md"
body=$(<"$TMP_ROOT/arch.md")
printf '%s\n' "${body//- IMX95RM:/- (dropped):}" >"$TMP_ROOT/arch.md"
run holds "$TMP_ROOT/arch.md" "- IMX95RM:"
check "negative: an architecture.md without IMX95RM under Missing fails the check" 1

finish
