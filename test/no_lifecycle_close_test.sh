#!/usr/bin/env bash
# The repository never closes the device life cycle (owner ruling 1234: the life
# cycle closes only at the provisioning station, never on a development board).
# This test fails if any script, make target or workflow runs an OEM-close or
# life-cycle-change command, the enclave's forward-life-cycle message, or a fuse
# write. It reads files only; it runs none of them and touches no device.
# Families: forward-lifecycle and OEM close/lock messages; ahab_close,
# ahab_return_lifecycle, ahab_lock; fuse burns (nxpele commit -i <fuse group>,
# ahab_commit, ahab_sec_fuse_prog, nxpele signed-message (the signed secure-fuse path),
# write-fuse verbs, fuse prog/override, blhost efuse); any nxpfuses use (SPSDK
# whole-configuration fuse programming); a write (>, >>, tee, dd of=) to an nvmem or
# ocotp node under /sys. A subcommand may be wrapped in single or double quotes.
# Commands split by backslash continuations are joined before matching.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Allow-list: path<TAB>reason. A listed file is not scanned.
ALLOW=$'scripts/ahab/key-exchange-test.sh\tfixture: builds a key-exchange message on test keys, sends nothing
scripts/ahab/key-import-test.sh\tfixture: builds a wrapped-key blob on test keys, sends nothing
test/okp_host_only_test.sh\tthe host-only guard: its tool list and fixtures name the device tools it rejects
test/okp_guard_coverage_test.sh\tthe coverage check: its tool-name filter and fixtures name the spellings it feeds to this guard, and run none of them
test/no_lifecycle_close_test.sh\tthis guard: it holds the patterns it searches for'

# Commands that change the life cycle or write a fuse. Matched per line, case
# insensitive, on lines that are not comments.
# Q is an optional single or double quote around a subcommand word.
Q="[\"']?"
PATTERNS=(
  'forward[-_ ]?life[-_ ]?cycle'
  'oem[-_ ]?clos(e|ed|ing)'
  'ahab_close'
  'close[-_ ]?life[-_ ]?cycle'
  'lc[-_ ]?(close|forward|change|transition)'
  # The enclave library's life-cycle-changing call and its types, as named in the
  # decommission and failure surveys: hsm_lc_update, hsm_lc_update.h, HsmLcUpdate,
  # hsm_lc_new_state_t, and a wrapper's lc_update (not "calc update").
  'hsm[-_ ]?lc[-_ ]?(update|new[-_ ]?state|change)'
  '(^|[^[:alpha:]])lc[-_ ]?update'
  'life[-_ ]?cycle[-_ ](close|change|forward|set|write|advance)'
  'efuse-program-once'
  "blhost[^#]*[[:space:]]${Q}efuse"
  "nxpele[^#]*[[:space:]]${Q}(write-fuse|write-shadow-fuse|fuse-write|burn-fuse|fuse-program)"
  "(^|[[:space:];&|(])${Q}fuse${Q}[[:space:]]+${Q}(prog|program|override|sense_write)"
  'ele[_-]?write[_-]?fuse'
  'write[-_]fuse'
  'fuse[-_]burn'
  "nxpele[^#]*[[:space:],[]${Q}commit${Q}([],)[:space:]]|\$)"
  "nxpele[^#]*[[:space:]]${Q}signed[-_ ]?message${Q}([[:space:]]|\$)"
  'ahab_commit'
  'ahab_sec_fuse_prog'
  'ahab_lock'
  'ahab_return_lifecycle'
  'oem[-_ ]?lock'
  # Found by test/okp_guard_coverage_test.sh (slice 176-okp-s6): the enclave's
  # write-fuse service (fuse-map-survey.md), the signed field-return request
  # (public-flow-survey.md) and U-Boot's ele_message console command, which sends
  # any enclave message (public-flow-survey.md).
  '(^|[^[:alpha:]])fuse_prog'
  'return[-_ ]?life[-_ ]?cycle'
  "(^|[[:space:];&|(])ele_message([[:space:]]|\$)"
  # SPSDK nxpfuses programs a whole fuse configuration (fuse-map-survey.md, sources
  # table: whole-configuration fuse programming); the survey shows no read-only
  # subcommand that cannot write, so any use is flagged (sudo, path, env prefix,
  # python -m spsdk.apps.nxpfuses, continuations all contain the word).
  'nxpfuses'
  # Device transports: fastboot flashing and the SDPS and EdgeLock 2GO host tools
  # (matched anywhere on the line, so after if/while/then/do/&&/$( too).
  # A Python or JSON argument list too: ["fastboot", "flash", ...] (comma or bracket
  # before the subcommand, comma, bracket or paren after it).
  "fastboot[^#]*[[:space:],[]${Q}(flash|flashall|flashing|erase|format|oem|boot|update|stage)${Q}([],)[:space:]]|\\$)"
  'sdpshost'
  'el2go[-_]host'
  # A write (redirect, tee, dd of=) to an nvmem or ocotp node under /sys.
  "(>|tee[[:space:]]+(-[[:alnum:]-]+[[:space:]]+)*|of=)[[:space:]]*${Q}[^[:space:]]*/sys/[^[:space:]]*(nvmem|ocotp)"
)

# scan <root>: print "<relative path>:<line>:<text>" for every hit, rc 0 when none.
scan() {
  local root=$1 rel hits=0 re f
  re=$(IFS='|'; echo "${PATTERNS[*]}")
  while IFS= read -r -d '' f; do
    rel=${f#"$root"/}
    case "$rel" in docs/* | *.md | .git/* | .serena/*) continue ;; esac
    if [[ $'\n'$ALLOW == *$'\n'"$rel"$'\t'* ]]; then continue; fi
    # A file with a NUL byte is binary: skip it, as grep -I did.
    if [ "$(tr -d '\000' <"$f" | wc -c)" != "$(wc -c <"$f")" ]; then continue; fi
    scan_file "$f" "$rel" "$re" || hits=1
  done < <(find "$root" -type f -not -path '*/.git/*' -print0 | sort -z)
  return $hits
}

# scan_file <path> <relative path> <regex>: join each backslash-continued command
# into one logical line, then match the regex case-insensitively on every logical
# line that does not start with a comment. Prints "<rel>:<first line>:<text>" per
# hit; rc 1 when there is any.
scan_file() {
  local f=$1 rel=$2 re=$3 line acc="" n=0 start=0 cont=0 rc=0
  shopt -s nocasematch
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if ((cont == 0)); then
      acc=""
      start=$n
      if [[ $line =~ ^[[:space:]]*(#|//) ]]; then continue; fi
    fi
    if [[ $line == *\\ ]]; then
      acc+="${line%\\} "
      cont=1
      continue
    fi
    acc+=$line
    cont=0
    if [[ $acc =~ $re ]]; then
      echo "$rel:$start:$acc"
      rc=1
    fi
  done <"$f"
  if ((cont == 1)) && [[ $acc =~ $re ]]; then
    echo "$rel:$start:$acc"
    rc=1
  fi
  shopt -u nocasematch
  return $rc
}

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=1; }

# Every allow-list entry names a file that exists.
while IFS=$'\t' read -r path reason; do
  [ -f "$here/$path" ] || bad "allow-list names a missing file: $path"
  [ -n "$reason" ] || bad "allow-list entry has no reason: $path"
done <<<"$ALLOW"

# The tree passes.
if out=$(scan "$here" 2>&1); then
  ok "no life-cycle close or fuse write in the repository"
else
  bad "life-cycle close or fuse write found:"
  echo "$out"
fi

# A scratch copy of a script with a close command added fails the scan and names the file.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/scripts"
cp "$here/scripts/secret-scan.sh" "$scratch/scripts/copy.sh"
if scan "$scratch" >/dev/null 2>&1; then ok "scratch copy without a close command passes"
else bad "scratch copy without a close command was flagged"; fi

echo 'nxpele -p x forward-lifecycle --target oem-closed' >>"$scratch/scripts/copy.sh"
if out=$(scan "$scratch" 2>&1); then
  bad "scratch copy with a life-cycle close command was not flagged"
elif [[ $out == *scripts/copy.sh:* ]]; then
  ok "scratch copy with a life-cycle close command fails and names scripts/copy.sh"
else
  bad "scan failed but did not name the file: $out"
fi

# A commented mention is not a command.
printf '# never run forward-lifecycle here\n' >"$scratch/scripts/note.sh"
rm "$scratch/scripts/copy.sh"
if scan "$scratch" >/dev/null 2>&1; then ok "a comment naming the message passes"
else bad "a comment naming the message was flagged"; fi

# One independent fixture per family: each alone in its own scratch tree, so no
# family passes on another family's pattern.
rm -f "$scratch"/scripts/*
i=0
for fx in \
  'forward-lifecycle|nxpele -p x forward-lifecycle --target oem-closed' \
  'nxpele commit|nxpele -p x commit -i OEM_FW_FUSE' \
  'ahab_commit|ahab_commit' \
  'ahab_sec_fuse_prog|ahab_sec_fuse_prog' \
  'ahab_lock|ahab_lock' \
  'ahab_return_lifecycle|ahab_return_lifecycle'; do
  name=${fx%%|*}
  cmd=${fx#*|}
  i=$((i + 1))
  rm -f "$scratch"/scripts/*
  printf '%s\n' "$cmd" >"$scratch/scripts/fx$i.sh"
  if out=$(scan "$scratch" 2>&1); then
    bad "fixture $name was not flagged"
  elif [[ $out == *scripts/fx$i.sh:* ]]; then
    ok "fixture $name fails and names scripts/fx$i.sh"
  else
    bad "fixture $name failed but did not name the file: $out"
  fi
done

# A command split across physical lines by backslash continuations is one command.
rm -f "$scratch"/scripts/*
bs=$'\\'
printf '%s\n' "nxpele -p x $bs" 'commit -i OEM_FW_FUSE' >"$scratch/scripts/split2.sh"
if out=$(scan "$scratch" 2>&1); then
  bad "two-line continued nxpele commit was not flagged"
elif [[ $out == *scripts/split2.sh:1:* ]]; then
  ok "two-line continued nxpele commit fails and names scripts/split2.sh:1"
else
  bad "two-line continued commit failed but did not name file and line: $out"
fi
rm -f "$scratch"/scripts/*
printf '%s\n' 'echo start' "nxpele $bs" "    -p x $bs" "      --verbose $bs" "    commit $bs" '    -i OEM_FW_FUSE' >"$scratch/scripts/split5.sh"
if out=$(scan "$scratch" 2>&1); then
  bad "indented multi-line continued nxpele commit was not flagged"
elif [[ $out == *scripts/split5.sh:2:* ]]; then
  ok "indented multi-line continued nxpele commit fails and names scripts/split5.sh:2"
else
  bad "multi-line continued commit failed but did not name file and line: $out"
fi
rm -f "$scratch"/scripts/*
printf '%s\n' "nxpele -p x $bs" 'info' >"$scratch/scripts/benign.sh"
if scan "$scratch" >/dev/null 2>&1; then ok "a continued nxpele command without a fuse write passes"
else bad "a continued benign nxpele command was flagged"; fi

# Signed-message submission is a device-bound secure-fuse path.
rm -f "$scratch"/scripts/*
printf '%s\n' 'nxpele -p x signed-message -i fuse.bin' >"$scratch/scripts/sm1.sh"
if out=$(scan "$scratch" 2>&1); then
  bad "nxpele signed-message was not flagged"
elif [[ $out == *scripts/sm1.sh:1:* ]]; then
  ok "nxpele signed-message fails and names scripts/sm1.sh:1"
else
  bad "nxpele signed-message failed but did not name file and line: $out"
fi
rm -f "$scratch"/scripts/*
printf '%s\n' "nxpele -p x $bs" "  signed-message $bs" '  -i fuse.bin' >"$scratch/scripts/sm3.sh"
if out=$(scan "$scratch" 2>&1); then
  bad "continued nxpele signed-message was not flagged"
elif [[ $out == *scripts/sm3.sh:1:* ]]; then
  ok "continued nxpele signed-message fails and names scripts/sm3.sh:1"
else
  bad "continued signed-message failed but did not name file and line: $out"
fi
rm -f "$scratch"/scripts/*
printf '%s\n' '# nxpele -p x signed-message -i fuse.bin' 'echo "signed-message is documented elsewhere"' >"$scratch/scripts/sm-note.sh"
if scan "$scratch" >/dev/null 2>&1; then ok "signed-message named only in a comment or an echo passes"
else bad "signed-message named only in a comment or an echo was flagged"; fi

# Round 3 fixtures: nxpfuses, quoted subcommands, nvmem/ocotp writes. Each alone in
# its own scratch tree; the command is on line 2 so the line number is checked too.
i=0
for fx in \
  'nxpfuses write|nxpfuses write -c fuses.yaml' \
  'nxpfuses write-single|nxpfuses -p x write-single -i fuse1' \
  'nxpfuses sudo path|sudo /usr/local/bin/nxpfuses write -c f.yaml' \
  'nxpfuses env prefix|SPSDK_X=1 nxpfuses write -c f.yaml' \
  'nxpfuses python -m|python3 -m spsdk.apps.nxpfuses write -c f.yaml' \
  'nxpele double-quoted signed-message|nxpele -p x "signed-message" -i fuse.bin' \
  'nxpele single-quoted commit|nxpele -p x '"'commit'"' -i OEM_FW_FUSE' \
  'nxpele quoted fuse-write|nxpele -p x "fuse-write" -i f' \
  'quoted fuse prog|"fuse" prog 0 1' \
  'fastboot flash|fastboot flash boot image.bin' \
  'fastboot flash after if|if fastboot flash boot image.bin; then :; fi' \
  'fastboot flash after while|while ! fastboot flash boot x.bin; do :; done' \
  "fastboot flash in substitution|x=\$(fastboot erase userdata)" \
  'fastboot list form|subprocess.run(["fastboot", "flash", "boot", image], check=True)' \
  'fastboot list form tight|run(["fastboot","erase","userdata"])' \
  'fastboot list form single quotes|subprocess.call(['"'fastboot', 'oem', 'unlock'"'])' \
  'nxpele list form commit|subprocess.check_call(['"'nxpele', '-p', 'usb', 'commit'"'])' \
  'sdpshost direct|sdpshost -p usb write-file 0x0 x.bin' \
  'el2go-host direct|el2go-host dev -h' \
  'el2go-host module|python3 -m spsdk.apps.el2go_host dev' \
  'nxpele write-shadow-fuse|nxpele -p x write-shadow-fuse --index 1 --data 0' \
  'nvmem redirect|echo 1 > /sys/bus/nvmem/devices/imx-ocotp0/nvmem' \
  'nvmem append quoted|printf x >> "/sys/devices/platform/ocotp/nvmem"' \
  'nvmem tee|printf x | tee -a /sys/bus/nvmem/devices/imx-ocotp0/nvmem' \
  'ocotp dd of|dd if=blob of=/sys/devices/platform/soc/47510000.ocotp/imx-ocotp0/nvmem bs=4'; do
  name=${fx%%|*}
  cmd=${fx#*|}
  i=$((i + 1))
  rm -f "$scratch"/scripts/*
  printf '%s\n' 'echo start' "$cmd" >"$scratch/scripts/r3fx$i.sh"
  if out=$(scan "$scratch" 2>&1); then
    bad "round-3 fixture $name was not flagged"
  elif [[ $out == *scripts/r3fx$i.sh:2:* ]]; then
    ok "round-3 fixture $name fails and names scripts/r3fx$i.sh:2"
  else
    bad "round-3 fixture $name failed but did not name file and line: $out"
  fi
done
# A continued nxpfuses command is one command; the report names its first line.
rm -f "$scratch"/scripts/*
printf '%s\n' 'echo start' "nxpfuses -p x $bs" '  write -c f.yaml' >"$scratch/scripts/r3split.sh"
if out=$(scan "$scratch" 2>&1); then
  bad "continued nxpfuses write was not flagged"
elif [[ $out == *scripts/r3split.sh:2:* ]]; then
  ok "continued nxpfuses write fails and names scripts/r3split.sh:2"
else
  bad "continued nxpfuses write failed but did not name file and line: $out"
fi
# Benign: reads of the nvmem node, redirects elsewhere, an unquoted-word lookalike.
for fx in \
  'read of the nvmem node|cat /sys/bus/nvmem/devices/imx-ocotp0/nvmem' \
  'nvmem read into a file|cat /sys/bus/nvmem/devices/imx-ocotp0/nvmem > /tmp/ocotp.bin' \
  'dd reads nvmem|dd if=/sys/bus/nvmem/devices/imx-ocotp0/nvmem of=/tmp/ocotp.bin bs=4' \
  'nvmem read piped to tee elsewhere|xxd /sys/bus/nvmem/devices/imx-ocotp0/nvmem | tee /tmp/x.txt' \
  'nxpele info with quoted word|nxpele -p x "get-info"' \
  'quoted word that is not a subcommand|echo "commit message" > /tmp/m.txt' \
  'list naming fastboot-docs|names = ["fastboot-docs", "flash-notes"]' \
  'prose naming fastboot|print("use fastboot later")' \
  'list form fastboot getvar|run(["fastboot", "getvar", "all"])'; do
  name=${fx%%|*}
  cmd=${fx#*|}
  rm -f "$scratch"/scripts/*
  printf '%s\n' "$cmd" >"$scratch/scripts/benign3.sh"
  if scan "$scratch" >/dev/null 2>&1; then ok "benign fixture passes: $name"
  else bad "benign fixture was flagged: $name"; fi
done

# Slice 176-okp-s5 fixtures: the enclave library's life-cycle-changing call in its
# documented spellings, each alone in its own scratch tree, command on line 2.
i=0
for fx in \
  'hsm_lc_update call|err = hsm_lc_update(hdl, &args);' \
  'hsm_lc_update.h include|cc -include hsm/internal/hsm_lc_update.h -c x.c' \
  'HsmLcUpdate python wrapper|HsmLcUpdate(session, new_lc=3)' \
  'lc_update go binding|err := enclave.lc_update(ctx, target)' \
  'hsm_lc_new_state_t|hsm_lc_new_state_t target = 3;'; do
  name=${fx%%|*}
  cmd=${fx#*|}
  i=$((i + 1))
  rm -f "$scratch"/scripts/*
  printf '%s\n' 'echo start' "$cmd" >"$scratch/scripts/s5fx$i.sh"
  if out=$(scan "$scratch" 2>&1); then
    bad "enclave fixture $name was not flagged"
  elif [[ $out == *scripts/s5fx$i.sh:2:* ]]; then
    ok "enclave fixture $name fails and names scripts/s5fx$i.sh:2"
  else
    bad "enclave fixture $name failed but did not name file and line: $out"
  fi
done
# Benign: read-only enclave calls and a lookalike word stay allowed.
for fx in \
  'hsm_get_info read-only|err = hsm_get_info(hdl, &info);' \
  'read life cycle state|state = read_lifecycle_state(hdl)' \
  'calc update lookalike|calc_update_total 3'; do
  name=${fx%%|*}
  cmd=${fx#*|}
  rm -f "$scratch"/scripts/*
  printf '%s\n' "$cmd" >"$scratch/scripts/benign4.sh"
  if scan "$scratch" >/dev/null 2>&1; then ok "benign enclave fixture passes: $name"
  else bad "benign enclave fixture was flagged: $name"; fi
done

# Slice 176-okp-s6 fixtures: spellings the survey-to-guard coverage check found.
i=0
for fx in \
  'fuse_prog call|err = fuse_prog(bank, word, val);' \
  'return_lifecycle_update_req|msg=return_lifecycle_update_req' \
  'ele_message console command|ele_message 0x17 0x1'; do
  name=${fx%%|*}
  cmd=${fx#*|}
  i=$((i + 1))
  rm -f "$scratch"/scripts/*
  printf '%s\n' 'echo start' "$cmd" >"$scratch/scripts/s6fx$i.sh"
  if out=$(scan "$scratch" 2>&1); then
    bad "coverage fixture $name was not flagged"
  elif [[ $out == *scripts/s6fx$i.sh:2:* ]]; then
    ok "coverage fixture $name fails and names scripts/s6fx$i.sh:2"
  else
    bad "coverage fixture $name failed but did not name file and line: $out"
  fi
done
rm -f "$scratch"/scripts/*
printf '%s\n' 'cat /usr/share/ele_message.py.txt' >"$scratch/scripts/benign5.sh"
if scan "$scratch" >/dev/null 2>&1; then ok "ele_message inside a file name passes"
else bad "ele_message inside a file name was flagged"; fi

# Positive control: every command named only on comment lines passes.
rm -f "$scratch"/scripts/*
{
  echo '# nxpele -p x forward-lifecycle --target oem-closed'
  echo '# nxpele -p x commit -i OEM_FW_FUSE'
  echo '# ahab_commit'
  echo '# ahab_sec_fuse_prog'
  echo '# ahab_lock'
  echo '# ahab_return_lifecycle'
} >"$scratch/scripts/comments.sh"
if scan "$scratch" >/dev/null 2>&1; then ok "every family named only in comments passes"
else bad "a comment naming a family was flagged"; fi

exit $fails
