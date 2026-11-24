#!/usr/bin/env bash
# The repository never closes the device life cycle (owner ruling 1234: the life
# cycle closes only at the provisioning station, never on a development board).
# This test fails if any script, make target or workflow runs an OEM-close or
# life-cycle-change command, the enclave's forward-life-cycle message, or a fuse
# write. It reads files only; it runs none of them and touches no device.
# Families: forward-lifecycle and OEM close/lock messages; ahab_close,
# ahab_return_lifecycle, ahab_lock; fuse burns (nxpele commit -i <fuse group>,
# ahab_commit, ahab_sec_fuse_prog, nxpele signed-message (the signed secure-fuse path),
# write-fuse verbs, fuse prog/override, blhost efuse). Commands split by backslash
# continuations are joined before matching.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Allow-list: path<TAB>reason. A listed file is not scanned.
ALLOW=$'scripts/ahab/key-exchange-test.sh\tfixture: builds a key-exchange message on test keys, sends nothing
scripts/ahab/key-import-test.sh\tfixture: builds a wrapped-key blob on test keys, sends nothing
test/no_lifecycle_close_test.sh\tthis guard: it holds the patterns it searches for'

# Commands that change the life cycle or write a fuse. Matched per line, case
# insensitive, on lines that are not comments.
PATTERNS=(
  'forward[-_ ]?life[-_ ]?cycle'
  'oem[-_ ]?clos(e|ed|ing)'
  'ahab_close'
  'close[-_ ]?life[-_ ]?cycle'
  'lc[-_ ]?(close|forward|change|transition)'
  'life[-_ ]?cycle[-_ ](close|change|forward|set|write|advance)'
  'efuse-program-once'
  'blhost[^#]*[[:space:]]efuse'
  'nxpele[^#]*[[:space:]](write-fuse|fuse-write|burn-fuse|fuse-program)'
  '(^|[[:space:];&|(])fuse[[:space:]]+(prog|program|override|sense_write)'
  'ele[_-]?write[_-]?fuse'
  'write[-_]fuse'
  'fuse[-_]burn'
  'nxpele[^#]*[[:space:]]commit([[:space:]]|$)'
  'nxpele[^#]*[[:space:]]signed[-_ ]?message([[:space:]]|$)'
  'ahab_commit'
  'ahab_sec_fuse_prog'
  'ahab_lock'
  'ahab_return_lifecycle'
  'oem[-_ ]?lock'
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
