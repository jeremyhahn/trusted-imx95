#!/usr/bin/env bash
# key_import_test.sh: scripts/ahab/key-import-test.sh end to end, then check
# that it left no key, blob or yaml file in the clone. No board, no fuse.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/.." && pwd -P)

before=$(cd "$root" && git status --porcelain --ignored)
"$root/scripts/ahab/key-import-test.sh"
after=$(cd "$root" && git status --porcelain --ignored)
if [ "$before" != "$after" ]; then
	echo "FAIL: key-import-test.sh changed the clone" >&2
	exit 1
fi
echo "ok: the clone is unchanged"
echo "key_import_test: OK"
