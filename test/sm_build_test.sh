#!/usr/bin/env bash
# test/sm_build_test.sh: scripts/sm-build.sh, `make system-manager`
# (docs/system-manager-config/build.md). Offline: a fake imx-sm repository and
# a fake Arm toolchain tarball stand in for NXP's and Arm's.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sm="$ROOT/scripts/sm-build.sh"
unset FAKE_NONDET FAKE_FAIL FAKE_PERF SM_OUT

run bash "$sm" --check "$ROOT/system-manager/sm.lock"
check "the committed lock validates" 0 "lf-6.18.37-2.1.0" "mx95frdm-pro" "15.2.rel1"

# A fake toolchain: a tarball with one top directory holding bin/arm-none-eabi-gcc.
tc="$TMP_ROOT/tc/arm-gnu-toolchain-9.9.rel1-x86_64-arm-none-eabi/bin"
mkdir -p "$tc"
printf '#!/bin/sh\necho fake-gcc\n' >"$tc/arm-none-eabi-gcc"
chmod +x "$tc/arm-none-eabi-gcc"
tar -C "$TMP_ROOT/tc" -cJf "$TMP_ROOT/tc.tar.xz" .
tc_sha=$(sha256sum "$TMP_ROOT/tc.tar.xz" | cut -d' ' -f1)

# A fake imx-sm: `make cfg` copies the .cfg, `make all` writes an image from
# the compiler, M and SOURCE_DATE_EPOCH; FAKE_NONDET adds the tree's path,
# FAKE_FAIL fails the build. `make cfg` also writes a synthetic
# config_scmi.h (written here, not NXP's): FAKE_PERF picks the fixture
# configs/other/perf-<FAKE_PERF>.h (default "good"); FAKE_PERF=missing writes none.
repo="$TMP_ROOT/imx-sm"
mkdir -p "$repo/configs/other"
printf 'LM1 name="M7"\nboard=fake\nLM2 name="AP"\nSCMI_AGENT1 name="AP-S"\nSYS ALL\n' >"$repo/configs/other/fakepro.cfg"
perf_fixture() { # <name> <M7 record's perf line> [other record's perf line]
	{
		printf '/* SCMI AGENT0 Config (M7) */\n#define A0 \\\n    { \\\n        .name = "M7", \\\n%s\n    }\n' "$2"
		printf '/* SCMI Instance 0 Config (M7) */\n#define I0 \\\n    { \\\n    }\n'
		printf '/* SCMI AGENT1 Config (AP-NS) */\n#define A1 \\\n    { \\\n        .name = "AP-NS", \\\n%s\n    }\n' "${3:-        .sysPerms = SM_SCMI_PERM_ALL, \\}"
	} >"$repo/configs/other/perf-$1.h"
}
bs=$'\\'
perf_all="        .perfPerms[DEV_SM_PERF_M7] = SM_SCMI_PERM_ALL, $bs"
perf_fixture good "$perf_all"
perf_fixture priv "        .perfPerms[DEV_SM_PERF_M7] = SM_SCMI_PERM_PRIV, $bs"
perf_fixture second "$perf_all" "$perf_all"
perf_fixture none "        .sysPerms = SM_SCMI_PERM_ALL, $bs"
printf '/* SCMI AGENT1 Config (AP-NS) */\n#define A1 \\\n    { \\\n        .name = "AP-NS", \\\n        .perfPerms[DEV_SM_PERF_M7] = SM_SCMI_PERM_ALL, \\\n    }\n' >"$repo/configs/other/perf-norec.h"
# shellcheck disable=SC2016 # make's $(...), not the shell's
printf '%s\n' 'cfg:' \
	'	mkdir -p configs/$(config) && cp configs/other/$(config).cfg configs/$(config)/config.h' \
	'	[ "$(FAKE_PERF)" = missing ] || cp configs/other/perf-$(or $(FAKE_PERF),good).h configs/$(config)/config_scmi.h' \
	'all:' \
	'	[ -z "$(FAKE_FAIL)" ]' \
	'	mkdir -p build/$(config)' \
	'	{ $(SM_CROSS_COMPILE)gcc; echo $(M) $(SOURCE_DATE_EPOCH); date +%FT%T; [ -z "$(FAKE_NONDET)" ] || pwd; } >build/$(config)/m33_image.bin' \
	>"$repo/Makefile"
g() { git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
git -C "$repo" init -q
g add -A
GIT_COMMITTER_DATE=@1700000000 g commit -q -m fake
g tag -a v1 -m v1
commit=$(git -C "$repo" rev-parse HEAD)
cfg_sha=$(sha256sum "$repo/configs/other/fakepro.cfg" | cut -d' ' -f1)

# The repository's patch, faked: one patch beside the lock, changing the fake
# configuration. patched_sha is the configuration after it applies.
mkdir -p "$TMP_ROOT/patches" "$TMP_ROOT/pa/configs/other" "$TMP_ROOT/pb/configs/other"
printf 'LM1 name="M7"\nboard=fake\nLM2 name="AP"\nSCMI_AGENT1 name="AP-S"\nSYS ALL\n' >"$TMP_ROOT/pa/configs/other/fakepro.cfg"
printf 'LM1 name="M7"\nboard=fake-closed\nLM2 name="AP"\nSCMI_AGENT1 name="AP-S"\nSYS ALL\n' >"$TMP_ROOT/pb/configs/other/fakepro.cfg"
(cd "$TMP_ROOT" && diff -u pa/configs/other/fakepro.cfg pb/configs/other/fakepro.cfg |
	{ read -r _; read -r _; echo "--- a/configs/other/fakepro.cfg"; echo "+++ b/configs/other/fakepro.cfg"; cat; }) \
	>"$TMP_ROOT/patches/0001-fake.patch" || true
patch_sha=$(sha256sum "$TMP_ROOT/patches/0001-fake.patch" | cut -d' ' -f1)
patched_sha=$(sha256sum "$TMP_ROOT/pb/configs/other/fakepro.cfg" | cut -d' ' -f1)

# lock [key=value...]: a good lock in $TMP_ROOT/lock, with the overrides.
lock() {
	local f="$TMP_ROOT/lock"
	{
		echo "# fake"
		echo "sm_repo=file://$repo"
		echo "sm_tag=v1"
		echo "sm_commit=$commit"
		echo "sm_config=fakepro"
		echo "sm_config_file=configs/other/fakepro.cfg"
		echo "sm_config_sha256=$cfg_sha"
		echo "sm_patch_sha256=$patch_sha"
		echo "sm_patched_config_sha256=$patched_sha"
		echo "sm_monitor_mode=2"
		echo "toolchain_version=9.9.rel1"
		echo "toolchain_url=file://$TMP_ROOT/tc.tar.xz"
		echo "toolchain_sha256=$tc_sha"
	} >"$f"
	local kv
	for kv in "$@"; do
		python3 -I -c 'import sys; f, kv = sys.argv[1:]; k = kv.split("=")[0]
lines = [l for l in open(f) if not l.startswith(k + "=")]
open(f, "w").write("".join(lines) + (kv + "\n" if "=" in kv else ""))' "$f" "$kv"
	done
}

# has_line <line> <file>: the file holds the line.
has_line() {
	local l
	while IFS= read -r l; do [ "$l" != "$1" ] || return 0; done <"$2"
	return 1
}

# The M7 grants allowlist sits beside the lock; the fake patched block is one line.
printf '# fake\nboard=fake-closed\n' >"$TMP_ROOT/m7-grants.txt"
printf '# fake\nSYS ALL\n' >"$TMP_ROOT/ap-s-grants.txt"
lock
out="$TMP_ROOT/out"
run env SM_OUT="$out" bash "$sm" "$TMP_ROOT/lock"
check "two identical builds pass" 0 "fetching" "reproducible, m33_image.bin"
expect "the manifest says reproducible" has_line "reproducible=yes" "$out/sm-manifest.txt"
expect "the image's date stamp is the commit's" has_line "2023-11-14T22:13:20" "$out/m33_image.bin"
expect "the manifest has the commit's time" has_line "source_date_epoch=1700000000" "$out/sm-manifest.txt"
# shellcheck disable=SC2016 # expands in the child shell
expect "SHA256SUMS checks the image" bash -c 'cd "$1" && sha256sum -c --quiet SHA256SUMS' _ "$out"
run env SM_OUT="$out" bash "$sm" "$TMP_ROOT/lock"
check "a second run uses the cache" 0 "reproducible"
if [[ $OUT == *fetching* ]]; then fail "a second run fetches nothing" "$OUT"; else pass "a second run fetches nothing"; fi

run env SM_OUT="$out" FAKE_NONDET=1 bash "$sm" "$TMP_ROOT/lock"
check "differing builds fail" nonzero "not reproducible"
expect "the manifest says not reproducible" has_line "reproducible=no" "$out/sm-manifest.txt"

run env SM_OUT="$out" FAKE_FAIL=1 bash "$sm" "$TMP_ROOT/lock"
check "a failing build fails by name" nonzero "build 1 failed"

lock sm_commit=0123456789abcdef0123456789abcdef01234567
run env SM_OUT="$out" bash "$sm" "$TMP_ROOT/lock"
check "a tag on another commit fails" nonzero "v1 is commit $commit"

# A patched file that widens the M7 block (the allowlist lacks its line) stops the build.
printf 'board=fake\n' >"$TMP_ROOT/m7-grants.txt"
lock
run env SM_OUT="$TMP_ROOT/out4" bash "$sm" "$TMP_ROOT/lock"
check "sm-build.sh stops a build whose patched file widens the M7 block" nonzero "grants: UNLISTED board=fake-closed" "differ from system-manager/m7-grants.txt"
printf '# fake\nboard=fake-closed\n' >"$TMP_ROOT/m7-grants.txt"
# The same for the AP-S agent: an allowlist that lacks a granted line stops the build.
printf '# fake\nPERF_A55 ALL\n' >"$TMP_ROOT/ap-s-grants.txt"
lock
run env SM_OUT="$TMP_ROOT/out4b" bash "$sm" "$TMP_ROOT/lock"
check "sm-build.sh stops a build whose AP-S block is not on the allowlist" nonzero "grants: UNLISTED SYS ALL" "the AP-S grants differ from system-manager/ap-s-grants.txt"
printf '# fake\nSYS ALL\n' >"$TMP_ROOT/ap-s-grants.txt"

# The generated SCMI table: the M7 agent holds PERF_M7 at ALL, no other agent.
lock
run env SM_OUT="$TMP_ROOT/out5" bash "$sm" "$TMP_ROOT/lock"
check "perf: the good table passes in the build" 0 "sm-perf-check: M7 PERF_M7=ALL, no other agent" "reproducible, m33_image.bin"
expect "perf: the manifest names the checked grant" has_line "m7_perf_m7=ALL" "$TMP_ROOT/out5/sm-manifest.txt"
run env SM_OUT="$TMP_ROOT/out5" FAKE_PERF=priv bash "$sm" "$TMP_ROOT/lock"
check "perf: the M7 grant at PRIV fails the build" nonzero "the M7 agent's PERF_M7 grant is not ALL: .perfPerms[DEV_SM_PERF_M7] = SM_SCMI_PERM_PRIV," "fails scripts/sm-perf-check.sh"
run env SM_OUT="$TMP_ROOT/out5" FAKE_PERF=second bash "$sm" "$TMP_ROOT/lock"
check "perf: a second agent holding PERF_M7 fails the build" nonzero "2 perfPerms[DEV_SM_PERF_M7] lines" "want exactly 1"
run env SM_OUT="$TMP_ROOT/out5" FAKE_PERF=none bash "$sm" "$TMP_ROOT/lock"
check "perf: a table with no PERF_M7 line fails the build" nonzero "no perfPerms[DEV_SM_PERF_M7] line"
run env SM_OUT="$TMP_ROOT/out5" FAKE_PERF=norec bash "$sm" "$TMP_ROOT/lock"
check "perf: a table with no M7 record fails the build" nonzero "no M7 agent record"
run env SM_OUT="$TMP_ROOT/out5" FAKE_PERF=missing bash "$sm" "$TMP_ROOT/lock"
check "perf: a missing config_scmi.h fails the build" nonzero "cannot read config_scmi.h"
# The line outside the M7 record (header present, line only in the other agent).
printf '/* SCMI AGENT0 Config (M7) */\n#define A0 \\\n    { \\\n    }\n/* SCMI AGENT1 Config (AP-NS) */\n    .perfPerms[DEV_SM_PERF_M7] = SM_SCMI_PERM_ALL, \\\n' >"$TMP_ROOT/outside.h"
run "$ROOT/scripts/sm-perf-check.sh" "$TMP_ROOT/outside.h"
check "perf: the only PERF_M7 line in another agent's record fails" 1 "is not in the M7 agent's record"
run "$ROOT/scripts/sm-perf-check.sh"
check "perf: no argument fails with usage" 1 "usage: sm-perf-check.sh"

# sm-perf-placement-check.sh: a PERF_M7 PRIV line in the M7 API list, or right
# after `M7P OWNER`, on scratch copies of a built tree. The fake tree's `make
# cfg` writes the M7 record's PERF_M7 line from the .cfg: the last PERF_M7 or
# M7P line wins, as the survey says the real tool does.
pt="$TMP_ROOT/pt"
mkdir -p "$pt/tree/configs/other"
printf 'LM0 name="SM"\nM7P OWNER\nLM1 name="M7"\n# API\n\nSYS ALL\n\n# Resources\n\nM7P                 OWNER  # CPUs first\nLPIT1 OWNER\nLM2 name="AP"\n' >"$pt/tree/configs/other/fakepro.cfg"
# shellcheck disable=SC2016 # make's $(...) and the shell's, in the fake
printf '%s\n' 'cfg:' \
	'	mkdir -p configs/$(config) && p=ALL; while read -r a b _; do [ "$$a" != PERF_M7 ] || p=$$b; [ "$$a" != M7P ] || p=ALL; done < configs/other/$(config).cfg; printf "/* SCMI AGENT0 Config (M7) */\n    .perfPerms[DEV_SM_PERF_M7] = SM_SCMI_PERM_$$p,\n" > configs/$(config)/config_scmi.h' \
	>"$pt/tree/Makefile"
printf 'sm_config=fakepro\nsm_config_file=configs/other/fakepro.cfg\n' >"$pt/lock"
pc="$ROOT/scripts/sm-perf-placement-check.sh"
cfg_before=$(sha256sum "$pt/tree/configs/other/fakepro.cfg" | cut -d' ' -f1)
run env SM_LOCK="$pt/lock" bash "$pc" "$pt/tree"
check "placement: the API line leaves ALL, the line after M7P OWNER gives PRIV" 0 "api variant: M7 PERF_M7=ALL" "res variant: M7 PERF_M7=PRIV" "sm-perf-placement-check: OK"
expect "placement: the input tree's .cfg is unchanged" has_line "$cfg_before  $pt/tree/configs/other/fakepro.cfg" <(sha256sum "$pt/tree/configs/other/fakepro.cfg")
expect "placement: the input tree has no config_scmi.h" [ ! -e "$pt/tree/configs/fakepro/config_scmi.h" ]
expect "placement: the scratch copies are removed" [ -z "$(find "$pt" -maxdepth 1 -name 'placement-*')" ]
printf 'LM1 name="M7"\n# API\nSYS ALL\n\n# Resources\n\nLPIT1 OWNER\n' >"$pt/tree/configs/other/fakepro.cfg"
run env SM_LOCK="$pt/lock" bash "$pc" "$pt/tree"
check "placement: a missing M7P OWNER anchor fails closed" nonzero "anchor for the res variant missing"
printf 'LM1 name="M7"\nSYS ALL\nM7P OWNER\n' >"$pt/tree/configs/other/fakepro.cfg"
run env SM_LOCK="$pt/lock" bash "$pc" "$pt/tree"
check "placement: a missing Resources header fails closed" nonzero "no API header in the M7 block"
printf 'LM2 name="AP"\n' >"$pt/tree/configs/other/fakepro.cfg"
run env SM_LOCK="$pt/lock" bash "$pc" "$pt/tree"
check "placement: no M7 block fails closed" nonzero "no M7 LM block"
run bash "$pc"
check "placement: no argument fails with usage" 1 "usage: sm-perf-placement-check.sh"
run "$ROOT/scripts/sm-perf-check.sh" --want PRIV "$repo/configs/other/perf-good.h"
check "placement: sm-perf-check.sh --want PRIV rejects an ALL table" 1 "is not PRIV"
run "$ROOT/scripts/sm-perf-check.sh" --want ALL "$repo/configs/other/perf-good.h"
check "placement: sm-perf-check.sh --want ALL is the default" 0 "M7 PERF_M7=ALL"

lock sm_config_sha256=0000000000000000000000000000000000000000000000000000000000000000
run env SM_OUT="$out" bash "$sm" "$TMP_ROOT/lock"
check "a changed configuration fails" nonzero "configs/other/fakepro.cfg SHA-256 is $cfg_sha"

lock sm_patch_sha256=0000000000000000000000000000000000000000000000000000000000000000
run env SM_OUT="$TMP_ROOT/out3" bash "$sm" "$TMP_ROOT/lock"
check "a patch of another digest fails" nonzero "patches SHA-256 is $patch_sha"
lock sm_patched_config_sha256=0000000000000000000000000000000000000000000000000000000000000000
run env SM_OUT="$out" bash "$sm" "$TMP_ROOT/lock"
check "a patched configuration of another digest fails" nonzero "patched configs/other/fakepro.cfg SHA-256 is $patched_sha"
expect "the patch reached the fake build" has_line "board=fake-closed" "$out/tree-1/configs/other/fakepro.cfg"
lock
printf '+x\n' >>"$TMP_ROOT/patches/0001-fake.patch"
run env SM_OUT="$out" bash "$sm" "$TMP_ROOT/lock"
check "an edited patch fails" nonzero "patches SHA-256 is"
head -n -1 "$TMP_ROOT/patches/0001-fake.patch" >"$TMP_ROOT/patches/x" && mv "$TMP_ROOT/patches/x" "$TMP_ROOT/patches/0001-fake.patch"

# The committed patch, offline: it changes only the M7 LM's fault reactions
# (build.md section 5), each lm_reset to sys_reset or sys_shutdown, and
# matches the lock.
patch_file="$ROOT/system-manager/patches/0001-m7-faults-fail-closed.patch"
expect "the committed patch matches the lock's patch digest" \
	has_line "sm_patch_sha256=$(cat "$ROOT"/system-manager/patches/*.patch | sha256sum | cut -d' ' -f1)" "$ROOT/system-manager/sm.lock"
run python3 -I -c '
import re, sys
want = {"FAULT_M7_LOCKUP", "FAULT_M7_RESET", "FAULT_SW1", "FAULT_WDOG5"}
old, new = {}, {}
for l in open(sys.argv[1]).read().split("\n"):
    if l.startswith(("---", "+++", "@@", " ")) or not l:
        continue
    m = re.match(r"^([-+])(FAULT_[A-Z0-9_]+) +OWNER, reaction=([a-z_]+)$", l)
    if not m:
        sys.exit("changed line is not a fault reaction: " + l)
    (old if m[1] == "-" else new)[m[2]] = m[3]
if set(old) != want or set(new) != want:
    sys.exit("changed faults %s, want %s" % (sorted(old), sorted(want)))
if any(v != "lm_reset" for v in old.values()):
    sys.exit("a changed reaction was not lm_reset")
if any(v not in ("sys_reset", "sys_shutdown") for v in new.values()):
    sys.exit("a new reaction is not sys_reset or sys_shutdown")
print("patch touches only M7 faults")
' "$patch_file"
check "the committed patch changes only the M7 LM's fault reactions" 0 "patch touches only M7 faults"

# 0002: only test keys and BRD_SM_CTRL_TEST* grants of the M7 LM leave.
patch2="$ROOT/system-manager/patches/0002-m7-no-test-grants.patch"
run python3 -I -c '
import re, sys
def norm(s):
    return re.sub(r"\s+", " ", s.replace("\\", " ")).strip().rstrip(",")
def untest(s):
    return re.sub(r",? ?\btest(=\w+)?\b,?", lambda m: "," if m[0].startswith(",") and m[0].endswith(",") else "", s)
rem, add = [], []
for l in open(sys.argv[1]).read().split("\n"):
    if l.startswith(("---", "+++", "@@", " ")) or not l:
        continue
    (rem if l[0] == "-" else add).append(l[1:])
for l in rem + add:
    if re.match(r"(FAULT_|SYS\b|LMM_2\b)", l):
        sys.exit("touches a Faults, SYS or LMM_2 line: " + l)
for l in rem:
    if not re.search(r"\btest\b|BRD_SM_CTRL_TEST", l) and not l.rstrip().endswith("\\"):
        sys.exit("removed line carries no test grant: " + l)
want = norm(" ".join(untest(l) for l in rem if "BRD_SM_CTRL_TEST" not in l and not re.match(r"PD_M7\s", l)))
got = norm(" ".join(add))
if not any(re.fullmatch(r"LPUART3\s+OWNER", l) for l in add) or not any(re.fullmatch(r"LPUART3\s+OWNER, test", l) for l in rem):
    sys.exit("LPUART3 must keep OWNER and lose only its test key")
if norm(untest(want)) != norm(got):
    sys.exit("added lines are not the removed lines without the test key: %r vs %r" % (want, got))
hunks = [l for l in open(sys.argv[1]).read().split("\n") if l.startswith("@@")]
for h in hunks:
    s = int(re.match(r"@@ -(\d+)", h)[1])
    if s < 366 or s > 410:
        sys.exit("hunk outside the M7 LM block: " + h)
print("patch 0002 touches only M7 test grants")
' "$patch2"
check "0002 takes only test keys and test grants out of the M7 LM" 0 "patch 0002 touches only M7 test grants"

# The M7 block check of sm-build.sh, on a fake patched configuration.
mkdir -p "$TMP_ROOT/m7"
printf 'LM0 name="SM"\ntest\nLM1 name="M7"\nX OWNER\n# test\nLM2 name="AP"\nY OWNER, test\n' >"$TMP_ROOT/m7/ok.cfg"
printf 'LM1 name="M7"\nX OWNER, test\n' >"$TMP_ROOT/m7/bad1.cfg"
printf 'LM1 name="M7"\nBRD_SM_CTRL_TEST_A ALL\n' >"$TMP_ROOT/m7/bad2.cfg"
printf 'LM1 name="M7"\nMAILBOX type=mu, test=8\n' >"$TMP_ROOT/m7/bad3.cfg"
printf 'LM1 name="M7"\nCHANNEL a, \\\n   test=default\n' >"$TMP_ROOT/m7/ok2.cfg"
printf 'LM2 name="AP"\n' >"$TMP_ROOT/m7/none.cfg"
python3 -I -c '
import re, sys
s = open(sys.argv[1]).read()
sys.stdout.write(re.search(r"^m7_clean\(\) \{.*?^\}\n", s, re.S | re.M)[0])
' "$sm" >"$TMP_ROOT/m7/fn.sh"
m7run() { bash -c 'die() { echo "$*" >&2; exit 1; }; . "$1"; m7_clean "$2"' _ "$TMP_ROOT/m7/fn.sh" "$TMP_ROOT/m7/$1.cfg"; }
run m7run ok
check "sm-build.sh accepts an M7 block without a test grant" 0 ""
run m7run ok2
check "sm-build.sh keeps the default test channel key the tool needs" 0 ""
for c in bad1 bad2 bad3; do
	run m7run "$c"
	check "sm-build.sh refuses an M7 block with a test grant ($c)" nonzero "still holds a test grant"
done
run m7run none
check "sm-build.sh refuses a configuration with no M7 block" nonzero "no M7 LM block"

# sm-grants-check.sh: the M7 block's grants equal the reviewed list.
gc="$ROOT/scripts/sm-grants-check.sh"
g="$TMP_ROOT/g"
mkdir -p "$g"
printf 'LM0 name="SM"\nSYS ALL\nLM1 name="M7"\n# c\nB OWNER\n\nA ALL, \\\n   x=1\nC  READONLY # t\nLM2 name="AP"\nZ ALL\n' >"$g/cfg"
printf '# list\nA ALL, x=1\nB OWNER\nC READONLY\n' >"$g/ok.txt"
printf 'C READONLY\nB OWNER\nA ALL, x=1\n' >"$g/reorder.txt"
printf 'A ALL, x=1\nB OWNER\nC READONLY\nD ALL\n' >"$g/stale.txt"
printf 'A ALL, x=1\nB OWNER\n' >"$g/unlisted.txt"
printf '# only a comment\n\n' >"$g/empty.txt"
printf 'LM2 name="AP"\nZ ALL\n' >"$g/nom7.cfg"
run "$gc" "$g/cfg" "$g/ok.txt"
check "grants: a block matching the allowlist passes" 0 "grants: OK (3 lines)"
run "$gc" "$g/cfg" "$g/reorder.txt"
check "grants: a reordered list passes" 0 "grants: OK (3 lines)"
run "$gc" "$g/cfg" "$g/unlisted.txt"
check "grants: an extra grant line fails with UNLISTED" 1 "grants: UNLISTED C READONLY" "grants: FAILED"
run "$gc" "$g/cfg" "$g/stale.txt"
check "grants: a missing line fails with STALE" 1 "grants: STALE D ALL" "grants: FAILED"
run "$gc" "$g/nom7.cfg" "$g/ok.txt"
check "grants: a missing M7 block fails" 1 "no M7 LM block"
run "$gc" "$g/cfg" "$g/empty.txt"
check "grants: an empty allowlist fails" 1 "is empty"
run "$gc" "$g/cfg" "$g/none.txt"
check "grants: a missing allowlist fails" 1 "no allowlist"
run "$gc" "$g/none.cfg" "$g/ok.txt"
check "grants: an unreadable cfg fails" 1 "cannot read"
run "$gc" --print "$g/cfg"
check "grants: --print shows the normalised sorted grants" 0 "A ALL, x=1"
# shellcheck disable=SC2016 # expands in the child shell
expect "grants: --print output is the allowlist's lines" \
	bash -c '[ "$("$1" --print "$2")" = "$(tail -n 3 "$3")" ]' _ "$gc" "$g/cfg" "$g/ok.txt"
expect "grants: the committed allowlist is non-empty" \
	[ -s "$ROOT/system-manager/m7-grants.txt" ]

# --ap-s: the AP-S agent's section of LM "AP" equals the reviewed list.
printf 'LM1 name="M7"\nSCMI_AGENT0 name="M7"\nLMM_2 ALL\nLM2 name="AP"\nSCMI_AGENT1 name="AP-S", secure\n# c\nSYS ALL\nPERF_A55 ALL, \\\n  x=1\nSCMI_AGENT2 name="AP-NS"\nLMM_1 NOTIFY\n' >"$g/aps.cfg"
printf '# list\nSYS ALL\nPERF_A55 ALL, x=1\n' >"$g/aps-ok.txt"
printf 'SYS ALL\n' >"$g/aps-stale.txt"
printf 'SYS ALL\nPERF_A55 ALL, x=1\nCPU_M7P ALL\n' >"$g/aps-stale2.txt"
printf 'LM2 name="AP"\nSCMI_AGENT1 name="AP-S", secure\nSYS ALL\nPERF_A55 ALL, x=1\nLMM_M7 ALL\n' >"$g/aps-lmm.cfg"
printf 'LM2 name="AP"\nSCMI_AGENT1 name="AP-S", secure\nSYS ALL\nPERF_A55 ALL, x=1\nCPU_M7P ALL\nPD_M7 ALL\n' >"$g/aps-cpu.cfg"
printf 'LM2 name="AP"\nSCMI_AGENT2 name="AP-NS"\nSYS ALL\n' >"$g/aps-none.cfg"
printf 'LM1 name="M7"\nSCMI_AGENT1 name="AP-S"\nSYS ALL\nLM2 name="AP"\nSCMI_AGENT2 name="AP-NS"\n' >"$g/aps-wronglm.cfg"
run "$gc" --ap-s "$g/aps.cfg" "$g/aps-ok.txt"
check "grants --ap-s: a block matching the allowlist passes (other agents and LMs ignored)" 0 "grants: OK (2 lines)"
run "$gc" --ap-s "$g/aps-lmm.cfg" "$g/aps-ok.txt"
check "grants --ap-s: an extra LMM_M7 line is UNLISTED" 1 "grants: UNLISTED LMM_M7 ALL" "grants: FAILED"
run "$gc" --ap-s "$g/aps-cpu.cfg" "$g/aps-ok.txt"
check "grants --ap-s: extra CPU_M7P and PD_M7 lines are UNLISTED" 1 "grants: UNLISTED CPU_M7P ALL" "grants: UNLISTED PD_M7 ALL"
run "$gc" --ap-s "$g/aps.cfg" "$g/aps-stale2.txt"
check "grants --ap-s: a listed line the file lacks is STALE" 1 "grants: STALE CPU_M7P ALL" "grants: FAILED"
run "$gc" --ap-s "$g/aps.cfg" "$g/aps-stale.txt"
check "grants --ap-s: a removed listed line is UNLISTED the other way" 1 "grants: UNLISTED PERF_A55 ALL, x=1"
# Define lines (DFMT0:, OWNER: ...): the AP-S agent's own sit before its header and
# are grants; the ones that end its section belong to the next agent (AP-NS).
printf 'LM2 name="AP"\nDFMT0: sa=bypass\nOWNER: perm=sec_rw, api=all\nSCMI_AGENT1 name="AP-S", secure\nSYS ALL\nDFMT0: sa=nonsecure\nOWNER: perm=rw, api=all\nSCMI_AGENT2 name="AP-NS"\nLMM_1 NOTIFY\n' >"$g/aps-def.cfg"
printf 'SYS ALL\nDFMT0: sa=bypass\nOWNER: perm=sec_rw, api=all\n' >"$g/aps-def-ok.txt"
run "$gc" --ap-s "$g/aps-def.cfg" "$g/aps-def-ok.txt"
check "grants --ap-s: the AP-S defines before its header are grants, the next agent's are not" 0 "grants: OK (3 lines)"
run "$gc" --ap-s "$g/aps-def.cfg" "$g/aps-ok.txt"
check "grants --ap-s: a define before the AP-S header that the list lacks is UNLISTED" 1 "grants: UNLISTED DFMT0: sa=bypass" "grants: UNLISTED OWNER: perm=sec_rw, api=all"
printf 'LM2 name="AP"\nSCMI_AGENT1 name="AP-S", secure\nSYS ALL\nOWNER: perm=rw, api=all\nPERF_A55 ALL\nSCMI_AGENT2 name="AP-NS"\n' >"$g/aps-mid.cfg"
printf 'SYS ALL\n' >"$g/aps-mid-no.txt"
run "$gc" --ap-s "$g/aps-mid.cfg" "$g/aps-mid-no.txt"
check "grants --ap-s: a define in the middle of the section is a grant and hides no line after it" 1 "grants: UNLISTED OWNER: perm=rw, api=all" "grants: UNLISTED PERF_A55 ALL"
run "$gc" --ap-s "$g/aps-none.cfg" "$g/aps-ok.txt"
check "grants --ap-s: an absent AP-S block fails by name" 1 "no AP-S agent block in LM AP"
run "$gc" --ap-s "$g/aps-wronglm.cfg" "$g/aps-ok.txt"
check "grants --ap-s: an AP-S agent outside LM AP is not taken" 1 "no AP-S agent block in LM AP"
printf 'SCMI_AGENT0 name="M7"\nLMM_2 ALL\n' >"$g/aps-m7.txt"
run "$gc" "$g/aps.cfg" "$g/aps-m7.txt"
check "grants: the M7 mode ignores the AP-S block" 0 "grants: OK (2 lines)"
run "$gc" --ap-s --print "$g/aps.cfg"
check "grants --ap-s --print shows the AP-S grants" 0 "PERF_A55 ALL, x=1"
# shellcheck disable=SC2016 # expands in the child shell
expect "grants: the committed AP-S allowlist is non-empty and lists no M7 right" \
	bash -c '[ -s "$1" ] && ! grep -Eq "^(LMM_|CPU_M7P|PD_M7)" "$1"' _ "$ROOT/system-manager/ap-s-grants.txt"

lock toolchain_sha256=0000000000000000000000000000000000000000000000000000000000000000
run env SM_OUT="$TMP_ROOT/out2" bash "$sm" "$TMP_ROOT/lock"
check "a toolchain of another digest fails" nonzero "toolchain SHA-256 is $tc_sha"

# The lock's form, offline.
lock
echo "sm_extra=1" >>"$TMP_ROOT/lock"
run bash "$sm" --check "$TMP_ROOT/lock"
check "an unknown key fails" nonzero "unknown key sm_extra"
lock
echo "sm_tag=v2" >>"$TMP_ROOT/lock"
run bash "$sm" --check "$TMP_ROOT/lock"
check "a key set twice fails" nonzero "sm_tag set twice"
lock sm_tag
run bash "$sm" --check "$TMP_ROOT/lock"
check "a missing key fails" nonzero "sm_tag is missing"
lock
echo "sm_tag v1" >>"$TMP_ROOT/lock"
run bash "$sm" --check "$TMP_ROOT/lock"
check "a line not key=value fails" nonzero "not key=value"
lock sm_commit=eec2328
run bash "$sm" --check "$TMP_ROOT/lock"
check "a short commit fails" nonzero "sm_commit must be a full 40-hex commit"
lock sm_monitor_mode=3
run bash "$sm" --check "$TMP_ROOT/lock"
check "a bad monitor mode fails" nonzero "sm_monitor_mode must be 0, 1 or 2"
lock sm_config=other
run bash "$sm" --check "$TMP_ROOT/lock"
check "a config file of another name fails" nonzero "is not other.cfg"
lock sm_repo=http://example.invalid/imx-sm
run bash "$sm" --check "$TMP_ROOT/lock"
check "a plain-http repository fails" nonzero "sm_repo must be an https:// or file:// URL"
run bash "$sm" --check "$TMP_ROOT/no-such.lock"
check "a missing lock fails" nonzero "no lock file"

# The pinned Arm toolchain is glibc-hosted, and the devcontainer image is musl:
# the toolchain stage must add a glibc loader (gcompat), or the real compiler
# cannot start there. The fake compiler above cannot see this; `make
# sm-toolchain-check` runs the real one in the image.
run bash -c "awk '/^FROM base AS toolchain/{t=1;next} /^FROM /{t=0} t' '$ROOT/build/docker/devcontainer/Dockerfile' | grep -E '^RUN apk add .*[[:space:]]gcompat([[:space:]]|\$)'"
check "the toolchain image provides a glibc loader (gcompat)" 0 "gcompat"

# make sm-toolchain-check must hand the image one script, with no shell `$`
# crossing Make twice (the inline find/$g form expanded to an empty check).
run bash -c "make -n -C '$ROOT' sm-toolchain-check 2>&1 | grep -F 'bash -c '"
check "sm-toolchain-check: the image runs scripts/sm-toolchain-check.sh" 0 "bash -c 'scripts/sm-toolchain-check.sh'"
run bash -c "make -n -C '$ROOT' sm-toolchain-check 2>&1 | grep -c -F 'find out/system-manager' || true"
expect "sm-toolchain-check: no inline find passes through Make" [ "$OUT" = 0 ]
mkdir -p "$TMP_ROOT/fakebin" "$TMP_ROOT/smout"
printf '#!/bin/sh\nexit 0\n' >"$TMP_ROOT/fakebin/make"
chmod +x "$TMP_ROOT/fakebin/make"
run env PATH="$TMP_ROOT/fakebin:$PATH" SM_OUT="$TMP_ROOT/smout" "$ROOT/scripts/sm-toolchain-check.sh"
check "sm-toolchain-check.sh: a build with no compiler fails" 1 "no arm-none-eabi-gcc"
expect "sm-toolchain-check.sh is executable" [ -x "$ROOT/scripts/sm-toolchain-check.sh" ]

# The CI job must not bind-mount the checkout (the daemon may not see it): it
# runs the script through in-toolchain-image.sh, which copies the checkout in.
job=$(awk '/^  system-manager-build:/{f=1;next} f&&/^  [a-z][a-z-]*:/{exit} f&&!/^ *#/' "$ROOT/.github/workflows/ci.yml")
expect "ci: system-manager-build job exists" [ -n "$job" ]
expect "ci: system-manager-build runs sm-toolchain-check.sh through in-toolchain-image.sh" \
	grep -Eq 'scripts/in-toolchain-image\.sh .*scripts/sm-toolchain-check\.sh' <<<"$job"
expect "ci: system-manager-build uses IN_IMAGE_NETWORK=bridge" \
	grep -Eq 'IN_IMAGE_NETWORK: bridge' <<<"$job"
# shellcheck disable=SC2016 # expands in the child shell
expect "ci: system-manager-build does not call make sm-toolchain-check" \
	bash -c '! grep -Eq "make +sm-toolchain-check" <<<"$1"' _ "$job"
# shellcheck disable=SC2016 # expands in the child shell
expect "ci: system-manager-build does not call docker-run" \
	bash -c '! grep -Eq "docker-run" <<<"$1"' _ "$job"
# The container's /src is root-owned (only the copied files are the image
# user's), so the job must point SM_OUT under the container's $TMPDIR, and the
# container's shell, not the runner's, must expand it. Behavioural: take the
# arguments the step hands in-toolchain-image.sh, compose them as the wrapper
# does (`sh -c "$guard; $*"`), and run them where sm-toolchain-check.sh is a
# stub that records SM_OUT and fails. The old `sh -c 'SM_OUT=...' script` form
# ran only the assignment, exited 0 and never ran the script.
step_line=$(grep -F 'scripts/in-toolchain-image.sh' <<<"$job" | head -n1)
expect "ci: system-manager-build has one in-toolchain-image.sh call" [ -n "$step_line" ]
wrapper_guard=$(awk '/^guard=/' "$ROOT/scripts/in-toolchain-image.sh")
# shellcheck disable=SC2016 # the literal text of the wrapper
expect "in-toolchain-image.sh composes sh -c \"\$guard; \$*\"" \
	grep -Fq 'sh -c "$guard; $*"' "$ROOT/scripts/in-toolchain-image.sh"
cap="$TMP_ROOT/cap"
croot="$TMP_ROOT/croot"
mkdir -p "$cap/scripts" "$croot/scripts" "$TMP_ROOT/ctmp"
# shellcheck disable=SC2016 # the stub's own text
printf '#!/bin/bash\nprintf "%%s\\0" "$@" >"$ARGS_OUT"\n' >"$cap/scripts/in-toolchain-image.sh"
# shellcheck disable=SC2016 # the stub's own text
printf '#!/bin/sh\necho "stub sm-toolchain-check ran SM_OUT=$SM_OUT"\nexit 1\n' >"$croot/scripts/sm-toolchain-check.sh"
chmod +x "$cap/scripts/in-toolchain-image.sh" "$croot/scripts/sm-toolchain-check.sh"
# shellcheck disable=SC2016 # expands in the child shell
run bash -c 'cd "$1" && ARGS_OUT="$2" TOOLCHAIN_IMAGE=img bash -c "$3"' _ "$cap" "$TMP_ROOT/args" "$step_line"
check "ci: the system-manager-build step line runs" 0 ""
# shellcheck disable=SC2016 # expands in the child shell
run bash -c '
	mapfile -d "" -t a <"$1"
	eval "$2"
	shift_args=("${a[@]:1}")
	cd "$3" && TMPDIR="$4" sh -c "$guard; ${shift_args[*]}"
' _ "$TMP_ROOT/args" "$wrapper_guard" "$croot" "$TMP_ROOT/ctmp"
check "ci: system-manager-build runs sm-toolchain-check.sh and its failure reaches the step" nonzero "stub sm-toolchain-check ran SM_OUT=$TMP_ROOT/ctmp/system-manager"

finish
