#!/usr/bin/env bash
# Offline checks of scripts/platform-image-kernel-config.sh with a stub bitbake and a fixture .config.
set -euo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export LC_ALL=C

script=$ROOT/scripts/platform-image-kernel-config.sh
req=$ROOT/platform-image/kernel-required.txt
tmp=$TMP_ROOT
real_bash=$(command -v bash)

tools=$tmp/tools
mkdir -p "$tools" "$tmp/stub" "$tmp/d/build/conf" "$tmp/d/sources/openembedded-core" "$tmp/kb"
for t in sed dirname; do
	ln -s "$(command -v "$t")" "$tools/$t"
done
: >"$tmp/d/sources/openembedded-core/oe-init-build-env"

# Stub bitbake: logs its arguments; `-e linux-imx` prints B="$BB_B".
cat >"$tmp/stub/bitbake" <<'EOF'
#!/bin/sh
case $1 in
-m) echo kill >>"$BB_KILL_LOG"; exit 0 ;;
esac
echo "$*" >>"$BB_LOG"
case $1 in
-e) echo "B=\"$BB_B\"" ;;
esac
EOF
chmod +x "$tmp/stub/bitbake"

# fixture OUT [SKIP-SYMBOL]: a .config that satisfies the required table.
fixture() {
	local l s w
	{
		echo '# Automatically generated file; DO NOT EDIT.'
		echo 'CONFIG_ARM64=y'
		while IFS= read -r l || [ -n "$l" ]; do
			case $l in '' | '#'*) continue ;; esac
			s=${l%%=*} w=${l#*=}
			[ "$s" != "${2:-}" ] || continue
			if [ "$w" = n ]; then echo "# CONFIG_$s is not set"; else echo "CONFIG_$s=$w"; fi
		done <"$req"
	} >"$1"
}

runk() { # sets rc and out; the stub's .config is $tmp/kb/.config
	rm -f "$tmp/log" "$tmp/kill"
	rc=0
	out=$(PATH=$tmp/stub:$tools BB_LOG=$tmp/log BB_KILL_LOG=$tmp/kill BB_B=$tmp/kb "$real_bash" "$script" "${1:-$tmp/d}" 2>&1) || rc=$?
}

expect "the shared required table exists" test -s "$req"

fixture "$tmp/kb/.config"
runk
expect "a satisfying .config passes" test "$rc" -eq 0
expect "a satisfying .config: it reports OK" test "${out##*kernel-config: OK*}" != "$out"
expect "bitbake configured linux-imx, then asked for its B" test "$(cat "$tmp/log")" = "linux-imx -c configure
-e linux-imx"

fixture "$tmp/kb/.config" FORTIFY_SOURCE
runk
expect "a .config without a required y symbol fails" test "$rc" -ne 0
expect "the failure names the symbol, want and missing" \
	test "${out##*"required FORTIFY_SOURCE: want y, got missing"*}" != "$out"

fixture "$tmp/kb/.config" HARDENED_USERCOPY
echo '# CONFIG_HARDENED_USERCOPY is not set' >>"$tmp/kb/.config"
runk
expect "a required y symbol that is not set fails" test "$rc" -ne 0
expect "the failure says want y, got n" test "${out##*"required HARDENED_USERCOPY: want y, got n"*}" != "$out"

fixture "$tmp/kb/.config" DEVMEM
echo 'CONFIG_DEVMEM=y' >>"$tmp/kb/.config"
runk
expect "a required n symbol set to y fails" test "$rc" -ne 0
expect "the failure says want n, got y" test "${out##*"required DEVMEM: want n, got y"*}" != "$out"

fixture "$tmp/kb/.config" MAGIC_SYSRQ_DEFAULT_ENABLE
echo 'CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=176' >>"$tmp/kb/.config"
runk
expect "the SysRq mask as decimal fails" test "$rc" -ne 0

fixture "$tmp/kb/.config" KEXEC
runk
expect "a required n symbol absent from .config passes (unmet dependencies)" test "$rc" -eq 0

rm -f "$tmp/kb/.config"
runk
expect "no generated .config fails" test "$rc" -ne 0
expect "no generated .config: it says it was not generated" test "${out##*was not generated*}" != "$out"

fixture "$tmp/kb/.config"
runk
expect "a good run stops its BitBake server once" test "$(cat "$tmp/kill")" = kill
rm -f "$tmp/kb/.config"
runk
expect "a failing run (no .config) still stops the server" test "$(cat "$tmp/kill")" = kill
fixture "$tmp/kb/.config"
: >"$tmp/d/build/bitbake.sock"
runk
expect "a stale server socket: the script passes" test "$rc" -eq 0
expect "a stale server socket: it says so" test "${out##*holds*bitbake.sock; stopping it*}" != "$out"
expect "a stale server socket: the stale server and the run's own are both stopped" test "$(cat "$tmp/kill")" = "kill
kill"
rm -f "$tmp/d/build/bitbake.sock"

runk "$tmp/no-such-dir"
expect "no build directory fails" test "$rc" -ne 0
expect "no build directory: it names the parse script" test "${out##*platform-image-parse.sh first*}" != "$out"

finish
