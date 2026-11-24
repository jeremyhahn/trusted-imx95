#!/usr/bin/env bash
# The oem-key-provisioning row's host-side tools talk to no device (issue #176,
# owner ruling 1234: key exchange, key import, counter fuses and the life-cycle
# close run only at the provisioning station). This test reads, and never runs,
# a fixed list of files and fails on any device-transport use:
#   - nxpele, blhost, sdphost, sdpshost, nxpuuu, uuu, fastboot, nxpdevhsm, el2go-host
#     as a command (also after sudo/env/VAR=, after a shell keyword such as if,
#     while, then or do, after ! && || or $(, behind a path, in a quoted bash -c, or as an
#     assignment of the tool's path), or spsdk.apps.<tool> run with python -m;
#   - a /dev/ path other than /dev/null and /dev/urandom;
#   - a Python import of spsdk.apps.nxpele, libuuu or serial.
# Comment lines are skipped; backslash continuations and lines that end inside an
# open ( or [ (a multi-line Python argument list) are joined, as
# test/no_lifecycle_close_test.sh does. The Makefile is read only in the
# recipes of okp-keyexchange-test, okp-import-tlv-test and srk-hash-check.
# OKP_HOST_ONLY_ROOT names another tree to scan (used by the self-checks).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=${OKP_HOST_ONLY_ROOT:-$here}

FILES=(
  scripts/ahab/key-exchange-test.sh
  scripts/ahab/key-import-test.sh
  scripts/ahab/key-import-check.py
  scripts/ahab/msg-sig-check.py
  scripts/ahab/srk-hash-check.sh
  scripts/ahab/srk-hash.py
  scripts/okp/station-preflight.sh
  scripts/okp/record-check.py
  test/okp_record_check_test.sh
  test/okp_record_drift_test.sh
  test/okp_pre_close_test.sh
  test/okp_spsdk_lock_test.sh
  test/key_exchange_test.sh
  test/key_import_test.sh
  test/srk_hash_check_test.sh
)
TARGETS=(okp-keyexchange-test okp-import-tlv-test srk-hash-check)

TOOLS='nxpele|blhost|sdphost|sdpshost|nxpuuu|uuu|fastboot|nxpdevhsm|el2go-host'
BT='`'
# A command starts at a line start, after a separator, after "$(" or "{" or "!", or
# after a shell keyword (if, elif, while, until, then, do, else).
KW='(if|elif|while|until|then|do|else)'
PRE="(^|[;&|(@{!${BT}]|\\\$\\(|(^|[[:space:]])${KW}[[:space:]])[[:space:]]*"
WRAP="((sudo|env|exec|command|time|nohup|xargs)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|-[-[:alnum:]=]+[[:space:]]+)*"
CMD="[\"']?([^[:space:]]*/)?(${TOOLS})[\"']?([[:space:]]|\$)"
RE_CMD="${PRE}${WRAP}${CMD}"
# bash -c 'nxpele ...' and sh -c "uuu ...": the quote opens the command.
RE_QUOTED="[\"'][[:space:]]*${WRAP}([^[:space:]]*/)?(${TOOLS})[[:space:]]"
# NXPELE=$venv/bin/nxpele (the tool's path held in a variable).
RE_ASSIGN="[A-Za-z_][A-Za-z0-9_]*=[\"']?([^[:space:]]*/)?(${TOOLS})[\"']?([[:space:]]|\$)"
# subprocess.run(["fastboot", "flash", ...]) and ['/usr/bin/uuu', x]: the tool is the
# first element of a Python or JSON argument list.
RE_LIST="[[(][[:space:]]*[\"'][[:space:]]*([^[:space:]\"']*/)?(${TOOLS})[\"']"
RE_MODULE="spsdk\\.apps\\.(${TOOLS}|el2go_host)"
RE_IMPORT="^[[:space:]]*(import|from)[[:space:]]+(spsdk\\.apps\\.nxpele|libuuu|serial)([[:space:].,]|\$)"
RE_IMPORT2="^[[:space:]]*from[[:space:]]+spsdk\\.apps[[:space:]]+import[[:space:]]+[^#]*nxpele"

# hit <text>: rc 0 when the logical line shows device-transport use.
hit() {
  local t=$1 rest
  if [[ $t =~ $RE_CMD || $t =~ $RE_QUOTED || $t =~ $RE_ASSIGN || $t =~ $RE_LIST || $t =~ $RE_MODULE ||
    $t =~ $RE_IMPORT || $t =~ $RE_IMPORT2 ]]; then return 0; fi
  rest=$t
  while [[ $rest =~ /dev/([A-Za-z0-9_.-]*) ]]; do
    case "${BASH_REMATCH[1]}" in null | urandom) ;; *) return 0 ;; esac
    rest=${rest#*"${BASH_REMATCH[0]}"}
  done
  return 1
}

# scan_file <path> <label>: join backslash continuations, skip comment lines, print
# "<label>:<first line>:<text>" per hit; rc 1 when there is any.
scan_file() {
  local f=$1 label=$2 line acc="" n=0 start=0 cont=0 rc=0 depth=0 o c
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if ((cont == 0)); then
      acc=""
      start=$n
      if [[ $line =~ ^[[:space:]]*(#|//) ]]; then continue; fi
    fi
    # Bracket depth: a line that ends inside an open ( or [ continues onto the next
    # line (Python and JSON argument lists, shell arrays). A simple count, not a
    # parser: brackets inside strings are counted too, depth never goes below 0, and
    # a join stops after 40 lines so an unbalanced bracket cannot swallow the file.
    if ((cont == 0)); then depth=0; fi
    o=${line//[^(\[]/}
    c=${line//[^)\]]/}
    depth=$((depth + ${#o} - ${#c}))
    if ((depth < 0)); then depth=0; fi
    if [[ $line == *\\ ]]; then
      acc+="${line%\\} "
      cont=1
      continue
    fi
    acc+=$line
    if ((depth > 0 && n - start < 40)); then
      acc+=" "
      cont=1
      continue
    fi
    cont=0
    if hit "$acc"; then
      echo "$label:$start:$acc"
      rc=1
    fi
  done <"$f"
  if ((cont == 1)) && hit "$acc"; then
    echo "$label:$start:$acc"
    rc=1
  fi
  return $rc
}

# make_recipes <Makefile> <out>: copy the recipe lines (tab-indented lines under the
# named targets) to <out>; every other line is blanked so line numbers are kept.
make_recipes() {
  local mk=$1 out=$2 line in=0 t first
  : >"$out"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line == $'\t'* ]]; then
      if ((in == 1)); then printf '%s\n' "$line" >>"$out"; else echo >>"$out"; fi
      continue
    fi
    in=0
    first=${line%%:*}
    for t in "${TARGETS[@]}"; do
      if [[ $first == "$t" && $line == *:* ]]; then in=1; fi
    done
    echo >>"$out"
  done <"$mk"
}

# scan <root>: scan the listed files and the Makefile recipes; rc 0 when clean.
scan() {
  local r=$1 f tmp rc=0
  for f in "${FILES[@]}"; do
    [ -f "$r/$f" ] || { echo "$f: missing"; rc=1; continue; }
    scan_file "$r/$f" "$f" || rc=1
  done
  if [ -f "$r/Makefile" ]; then
    tmp=$(mktemp)
    make_recipes "$r/Makefile" "$tmp"
    scan_file "$tmp" Makefile || rc=1
    rm -f "$tmp"
  else
    echo "Makefile: missing"
    rc=1
  fi
  return $rc
}

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=1; }

# The Makefile names each target the scan reads.
for t in "${TARGETS[@]}"; do
  [[ $'\n'$(<"$root/Makefile") == *$'\n'"$t:"* ]] || bad "Makefile has no target $t"
done

if out=$(scan "$root" 2>&1); then
  ok "the row's host-side tools use no device transport"
else
  bad "device-transport use or missing file:"
  echo "$out"
fi

# Self-checks, only on the real tree: fixtures in a scratch tree of the listed files.
if [ -z "${OKP_HOST_ONLY_ROOT:-}" ]; then
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  bs=$'\\'
  # fixture <name> <expect: hit|pass> <file lines...>: file lines go into the first listed
  # file, after a harmless first line, so the hit is on line 2.
  fixture() {
    local name=$1 expect=$2 f=$3 o
    shift 3
    rm -rf "${scratch:?}/t"
    mkdir -p "$scratch/t/scripts/ahab" "$scratch/t/scripts/okp" "$scratch/t/test"
    local g
    for g in "${FILES[@]}"; do : >"$scratch/t/$g"; done
    : >"$scratch/t/Makefile"
    for g in "${TARGETS[@]}"; do printf '%s:\n\t@echo ok\n' "$g" >>"$scratch/t/Makefile"; done
    { echo 'echo start'; printf '%s\n' "$@"; } >"$scratch/t/$f"
    if o=$(OKP_HOST_ONLY_ROOT="$scratch/t" bash "${BASH_SOURCE[0]}" 2>&1); then
      if [ "$expect" = pass ]; then ok "fixture passes: $name"; else bad "fixture was not flagged: $name"; fi
    elif [ "$expect" = hit ] && [[ $o == *"$f:2:"* ]]; then
      ok "fixture fails and names $f:2: $name"
    else
      bad "fixture ($expect) wrong result: $name: $o"
    fi
  }
  ks=scripts/ahab/key-exchange-test.sh
  fixture "nxpele on its own line" hit $ks 'nxpele -p usb get-info'
  fixture "fastboot continued" hit scripts/ahab/key-import-test.sh "fastboot $bs" 'devices'
  fixture "import serial" hit scripts/ahab/msg-sig-check.py 'import serial'
  fixture "libuuu import" hit scripts/ahab/srk-hash.py 'from libuuu import x'
  fixture "sudo blhost" hit $ks 'sudo blhost -u 0x1fc9 get-property 1'
  fixture "tool path in a variable" hit $ks "e=\$venv/bin/nxpele"
  fixture "bash -c uuu" hit $ks "bash -c 'uuu -b x'"
  fixture "a block device" hit $ks 'dd if=x of=/dev/mmcblk0'
  fixture "spsdk.apps module" hit $ks 'python -m spsdk.apps.nxpdevhsm -h'
  fixture "if fastboot flash" hit $ks 'if fastboot flash boot image.bin; then :; fi'
  fixture "elif fastboot" hit $ks 'elif fastboot devices; then :'
  fixture "while fastboot" hit $ks 'while fastboot devices; do :; done'
  fixture "until fastboot" hit $ks 'until fastboot devices; do :; done'
  fixture "bang fastboot" hit $ks '! fastboot getvar all'
  fixture "then fastboot" hit $ks 'then fastboot reboot'
  fixture "do fastboot" hit $ks 'do fastboot reboot'
  fixture "else fastboot" hit $ks 'else fastboot reboot'
  fixture "and-and fastboot" hit $ks 'true && fastboot reboot'
  fixture "or-or fastboot" hit $ks 'false || fastboot reboot'
  fixture "command substitution fastboot" hit $ks "x=\$(fastboot getvar all)"
  fixture "sdpshost direct" hit $ks 'sdpshost -p usb write-file 0x0 x.bin'
  fixture "el2go-host direct" hit $ks 'el2go-host dev -h'
  fixture "sdpshost after if" hit $ks 'if sdpshost -h; then :; fi'
  fixture "el2go-host module" hit $ks 'python -m spsdk.apps.el2go_host dev'
  fixture "sdpshost module" hit $ks 'python -m spsdk.apps.sdpshost -h'
  fixture "list form fastboot" hit scripts/ahab/key-import-check.py 'subprocess.run(["fastboot", "flash", "boot", image], check=True)'
  fixture "list form nxpele" hit scripts/ahab/key-import-check.py "subprocess.check_call(['nxpele', '-p', 'usb', 'commit'])"
  fixture "list form uuu path" hit scripts/ahab/key-import-check.py 'Popen(["/usr/bin/uuu", x])'
  fixture "list form sdpshost spaced" hit scripts/ahab/key-import-check.py 'run([ "sdpshost" , "-p", "usb"])'
  fixture "multi-line subprocess.run list" hit scripts/ahab/key-import-check.py 'subprocess.run([' '    "nxpele",' '    "commit", "-i", "OEM_FW_FUSE"' '])'
  fixture "multi-line Popen with uuu path" hit scripts/ahab/key-import-check.py 'Popen(' '    "/usr/bin/uuu",' '    x)'
  fixture "multi-line fastboot list" hit scripts/ahab/key-import-check.py '["fastboot",' '  "flash", "boot", image]'
  fixture "multi-line list of plain strings" pass scripts/ahab/key-import-check.py 'names = [' '    "alpha",' '    "beta",' ']'
  fixture "multi-line print of prose naming fastboot" pass scripts/ahab/key-import-check.py 'print(' '    "use fastboot later,"' '    "then stop")'
  fixture "list naming fastboot-docs" pass scripts/ahab/key-import-check.py 'names = ["fastboot-docs"]'
  fixture "prose naming fastboot" pass scripts/ahab/key-import-check.py 'print("use fastboot later")'
  fixture "keyword word in prose" pass $ks 'echo "if you want, do not run it"'
  fixture "comment naming the tools" pass scripts/ahab/srk-hash-check.sh '# no nxpele, no uuu, no /dev/sda'
  fixture "dev null and urandom" pass $ks 'head -c 4 /dev/urandom >/dev/null'
  fixture "serialization import" pass scripts/ahab/msg-sig-check.py 'from cryptography.hazmat.primitives import serialization'
  fixture "tool word inside a pattern" pass test/srk_hash_check_test.sh 'grep -qiE "fuse|blhost|bcf" x'
fi

exit $fails
