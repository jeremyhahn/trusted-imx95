#!/usr/bin/env bash
# The repository never closes the device life cycle (owner ruling 1234: the life
# cycle closes only at the provisioning station, never on a development board).
# This test fails if any script, make target or workflow runs an OEM-close or
# life-cycle-change command, the enclave's forward-life-cycle message, or a fuse
# write. It reads files only; it runs none of them and touches no device.
# Families: forward-lifecycle and OEM close/lock messages; ahab_close,
# ahab_return_lifecycle, ahab_lock; fuse burns (nxpele commit -i <fuse group>,
# ahab_commit, ahab_sec_fuse_prog, write-fuse verbs, fuse prog/override, blhost efuse).
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
  'ahab_commit'
  'ahab_sec_fuse_prog'
  'ahab_lock'
  'ahab_return_lifecycle'
  'oem[-_ ]?lock'
)

# scan <root>: print "<relative path>:<line>:<text>" for every hit, rc 0 when none.
scan() {
  local root=$1 rel hits=0 line
  local re
  re=$(IFS='|'; echo "${PATTERNS[*]}")
  while IFS= read -r -d '' f; do
    rel=${f#"$root"/}
    case "$rel" in docs/* | *.md | .git/* | .serena/*) continue ;; esac
    if [[ $'\n'$ALLOW == *$'\n'"$rel"$'\t'* ]]; then continue; fi
    while IFS= read -r line; do
      echo "$rel:$line"
      hits=1
    done < <(grep -I -n -i -E -- "$re" "$f" | grep -v -E '^[0-9]+:[[:space:]]*(#|//)' || true)
  done < <(find "$root" -type f -not -path '*/.git/*' -print0 | sort -z)
  return $hits
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
