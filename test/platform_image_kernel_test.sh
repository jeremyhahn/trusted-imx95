#!/usr/bin/env bash
# Offline checks of the kernel hardening fragment (proposed, pending owner
# approval, issue #14; hardening-survey section 10, Q1 (c) and Q5 (b)).
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kdir=$ROOT/platform-image/recipes-kernel/linux
bbappend=$kdir/linux-imx_%.bbappend
frag=$kdir/files/hardening.cfg
survey=$ROOT/docs/platform-image/hardening-survey.md
layer=$ROOT/platform-image/conf/layer.conf

# Symbols the fragment must not name (survey sections 3, 4, 6, 9, Q2 to Q4).
out_re='^(MODULES|MODULE_SIG[A-Z0-9_]*|SECURITY_LOCKDOWN_LSM[A-Z0-9_]*|LOCK_DOWN_KERNEL_FORCE_[A-Z0-9_]*|COMPAT|SHADOW_CALL_STACK|CFI_CLANG|ARM64_BTI_KERNEL|ARM64_MTE|KASAN_HW_TAGS|UNWIND_PATCH_PAC_INTO_SCS|DEBUG_RODATA|DEBUG_CREDENTIALS|REFCOUNT_FULL|RANDOM_TRUST_CPU|RANDOM_TRUST_BOOTLOADER|DEBUG_SET_MODULE_RONX|PAGE_POISONING_ZERO)$'
val_re='^(y|n|-?[0-9]+|0x[0-9a-fA-F]+)$'

# The complete required symbol=value set: every assignment the fragment makes,
# read from the table scripts/platform-image-kernel-config.sh checks the
# generated .config against, so the two cannot drift apart.
reqfile=$ROOT/platform-image/kernel-required.txt
REQUIRED=()
FTPM_REQ=()
ftpmfrag=$kdir/files/ftpm.cfg
while IFS= read -r l || [ -n "$l" ]; do
	case $l in '' | '#'*) continue ;; esac
	# The firmware TPM symbols belong to ftpm.cfg, the rest to hardening.cfg.
	case $l in
	TCG_TPM=* | TCG_FTPM_TEE=*) FTPM_REQ+=("$l") ;;
	*) REQUIRED+=("$l") ;;
	esac
done <"$reqfile"
expect "the shared required table has entries" test "${#REQUIRED[@]}" -gt 20
expect "the required table names both firmware TPM symbols" test "${#FTPM_REQ[@]}" -eq 2

# symbols FILE: prints "SYMBOL VALUE" per non-comment, non-blank line (VALUE n
# for "# CONFIG_X is not set"), or "BAD <line>" for a malformed one.
symbols() {
	local l sym val
	while IFS= read -r l || [ -n "$l" ]; do
		if [[ $l =~ ^#\ CONFIG_([A-Z0-9_]+)\ is\ not\ set$ ]]; then
			echo "${BASH_REMATCH[1]} n"
		elif [[ $l =~ ^CONFIG_([A-Z0-9_]+)=(.+)$ ]]; then
			sym=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
			if [[ $val =~ $val_re ]]; then echo "$sym $val"; else echo "BAD $l"; fi
		elif [[ -z $l || $l == '#'* && ! $l =~ ^#\ CONFIG_ ]]; then
			continue
		else
			echo "BAD $l"
		fi
	done <"$1"
}

# value_of FILE SYM: the value the fragment gives SYM.
value_of() {
	local s v
	while read -r s v; do
		[ "$s" = "$2" ] && { echo "$v"; return 0; }
	done < <(symbols "$1")
	return 1
}

# checker FILE: the whole fragment check; prints the reasons and fails on any.
checker() {
	local f=$1 s v rc=0 n=0
	local -A seen=()
	while read -r s v; do
		if [ "$s" = BAD ]; then echo "malformed line: $v"; rc=1; continue; fi
		n=$((n + 1))
		if [ -n "${seen[$s]+x}" ]; then echo "duplicate symbol: $s"; rc=1; fi
		seen[$s]=$v
		if ! named "$s"; then echo "not named in the survey: $s"; rc=1; fi
		if [[ $s =~ $out_re ]]; then echo "out-of-scope symbol: $s"; rc=1; fi
	done < <(symbols "$f")
	[ "$n" -gt 0 ] || { echo "no symbols"; rc=1; }
	local kv got
	for kv in "${REQUIRED[@]}"; do
		got=$(value_of "$f" "${kv%%=*}" || true)
		[ "$got" = "${kv#*=}" ] || { echo "required ${kv%%=*}: want ${kv#*=}, got ${got:-missing}"; rc=1; }
	done
	return "$rc"
}

survey_text=$(<"$survey")
# named SYM: the survey names SYM (without the CONFIG_ prefix).
named() { [[ $survey_text == *"$1"* ]]; }

# live FILE ERE: true when a non-comment line matches.
live() {
	local l
	while IFS= read -r l || [ -n "$l" ]; do
		case $l in '#'*) continue ;; esac
		[[ $l =~ $2 ]] && return 0
	done <"$1"
	return 1
}

expect "the bbappend exists" test -f "$bbappend"
expect "the bbappend names hardening.cfg" live "$bbappend" 'SRC_URI[[:space:]]*\+=.*file://hardening\.cfg'
expect "the bbappend prepends the files directory" live "$bbappend" 'FILESEXTRAPATHS:prepend'
expect "the fragment exists" test -f "$frag"
expect "the fragment is non-empty" test -s "$frag"

run symbols "$frag"
expect "every non-comment line is a valid Kconfig assignment" test "${OUT##*BAD *}" = "$OUT" -a -n "$OUT"

dups=$(symbols "$frag" | while read -r s _; do echo "$s"; done | sort | uniq -d)
expect "no symbol appears twice or with two values" test -z "$dups"

unnamed=
while read -r s _; do
	[ "$s" = BAD ] || named "$s" || unnamed="$unnamed $s"
done < <(symbols "$frag")
expect "every symbol is named in the survey" test -z "$unnamed"

banned=
while read -r s _; do
	if [[ $s =~ $out_re ]]; then banned="$banned $s"; fi
done < <(symbols "$frag")
expect "no out-of-scope symbol (modules, signing, lockdown, compat, toolchain, removed)" test -z "$banned"

q5ok=1
for kv in "${REQUIRED[@]}"; do
	[ "$(value_of "$frag" "${kv%%=*}" || true)" = "${kv#*=}" ] || { q5ok=0; echo "wrong: $kv"; }
done
expect "every required hardening symbol has its required value (SysRq mask is hex 0xb0)" test "$q5ok" -eq 1

ftok=1
for kv in "${FTPM_REQ[@]}"; do
	[ "$(value_of "$ftpmfrag" "${kv%%=*}" || true)" = "${kv#*=}" ] || { ftok=0; echo "wrong: $kv"; }
done
expect "ftpm.cfg sets the firmware TPM symbols the required table names" test "$ftok" -eq 1
expect "the bbappend names ftpm.cfg" live "$bbappend" 'SRC_URI[[:space:]]*\+=.*file://ftpm\.cfg'
expect "layer.conf BBFILES line covers the bbappend" live "$layer" 'BBFILES[[:space:]]*\+=.*recipes-\*/\*/\*\.bbappend'

# The checker passes the real fragment and fails on a copy with an out-of-scope symbol.
run checker "$frag"
check "checker passes the fragment" 0
tmp=$TMP_ROOT
cp "$frag" "$tmp/bad.cfg"
echo 'CONFIG_MODULE_SIG_FORCE=y' >>"$tmp/bad.cfg"
run checker "$tmp/bad.cfg"
check "negative: checker rejects an added out-of-scope symbol" nonzero "out-of-scope symbol: MODULE_SIG_FORCE"

# Each case edits a copy: a missing, flipped or wrong-base value must fail.
run checker "$frag"
check "positive: the unmodified fragment passes the full set" 0
mut() { # mut NAME SED-FREE-FILTER: copy frag lines through a bash filter
	local l
	while IFS= read -r l || [ -n "$l" ]; do "$2" "$l"; done <"$frag" >"$tmp/$1.cfg"
}
del_fortify() { [ "$1" = CONFIG_FORTIFY_SOURCE=y ] || printf '%s\n' "$1"; }
flip_usercopy() { if [ "$1" = CONFIG_HARDENED_USERCOPY=y ]; then echo '# CONFIG_HARDENED_USERCOPY is not set'; else printf '%s\n' "$1"; fi; }
flip_freelist() { if [ "$1" = CONFIG_SLAB_FREELIST_HARDENED=y ]; then echo 'CONFIG_SLAB_FREELIST_HARDENED=n'; else printf '%s\n' "$1"; fi; }
dec_sysrq() { if [[ $1 == CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=* ]]; then echo 'CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=176'; else printf '%s\n' "$1"; fi; }
mut del del_fortify
run checker "$tmp/del.cfg"
check "negative: a deleted required protection fails" nonzero "required FORTIFY_SOURCE: want y, got missing"
mut flip flip_usercopy
run checker "$tmp/flip.cfg"
check "negative: a required protection set to not-set fails" nonzero "required HARDENED_USERCOPY: want y, got n"
mut flipn flip_freelist
run checker "$tmp/flipn.cfg"
check "negative: a required protection set to n fails" nonzero "required SLAB_FREELIST_HARDENED: want y, got n"
mut dec dec_sysrq
run checker "$tmp/dec.cfg"
check "negative: the SysRq mask as decimal 176 fails" nonzero "required MAGIC_SYSRQ_DEFAULT_ENABLE: want 0xb0, got 176"

finish
