#!/usr/bin/env bash
# The hsm-self-defence row end to end through make: the row is blocked (owner
# rulings 1243 and 1244, #26), so make hsm-self-defence-check passes on this
# tree, which keeps it as docs/SPEC.md writes it, and fails on copies that
# ship it, unblock it, drop what it names or start building it. Runs offline
# on a read-only root (make integration-test, make
# integration-test-hsm-self-defence); writes only under $TMP_ROOT.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# tree <name>: a copy of the files the check reads, under $TMP_ROOT/<name>.
tree() {
	local t="$TMP_ROOT/$1"
	mkdir -p "$t/docs/references" "$t/scripts"
	cp "$ROOT/docs/SPEC.md" "$t/docs/SPEC.md"
	cp "$ROOT/docs/references/README.md" "$t/docs/references/README.md"
	cp "$ROOT/ROADMAP.md" "$ROOT/Makefile" "$t/"
	cp "$ROOT/scripts/hsm-self-defence-check.py" "$ROOT/scripts/tool-pins.sh" "$t/scripts/"
	cp -r "$ROOT/hsm-self-defence" "$t/"
	echo "$t"
}

# edit <file> <old> <new>: replace the one occurrence of <old>; fails if absent.
edit() {
	python3 - "$@" <<'EOF'
import sys
f, old, new = sys.argv[1:4]
s = open(f, encoding="utf-8").read()
assert s.count(old) == 1, f"{old!r} occurs {s.count(old)} times in {f}"
open(f, "w", encoding="utf-8").write(s.replace(old, new))
EOF
}

run make -s -C "$ROOT" hsm-self-defence-check
check "make hsm-self-defence-check: this tree keeps the row blocked as written" 0 \
	"ok 2 SPEC.md: the row stays planned" "ok 3 SPEC.md: the row stays blocked" \
	"no target builds hsm-self-defence" "hsm-self-defence-check: OK (blocked as written"

t=$(tree same)
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: an unchanged copy passes" 0 "hsm-self-defence-check: OK"

t=$(tree shipped)
edit "$t/docs/SPEC.md" "| hsm-self-defence | planned |" "| hsm-self-defence | shipped |"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a shipped row fails" nonzero "status is 'shipped'"

t=$(tree unblocked)
edit "$t/docs/SPEC.md" "#26): it stays blocked. The HSM" "#26). The HSM"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a row that no longer stays blocked fails" nonzero \
	"FAIL 3 SPEC.md: the row stays blocked"

t=$(tree decided)
edit "$t/docs/SPEC.md" "is not decided, and is an open question for the owner" "is decided"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: deciding the owner's open A55 question fails" nonzero \
	"the Cortex-A55 tamper detector" "phrase missing"

t=$(tree pins)
edit "$t/docs/SPEC.md" "gives the EdgeLock tamper pins; the one that does is missing" "gives the EdgeLock tamper pins"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: dropping the missing tamper-pin document fails" nonzero \
	"the one that does is missing" "phrase missing"

t=$(tree roadmap)
edit "$t/ROADMAP.md" "blocked: owner approval; A55 side proposed, pending owner approval" "in progress"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a ROADMAP line no longer blocked fails" nonzero \
	"ROADMAP.md: blocked on owner approval: not marked blocked" \
	"ROADMAP.md: the A55 side is proposed, pending owner approval"

t=$(tree a55roadmap)
edit "$t/ROADMAP.md" "A55 side proposed, pending owner approval" "A55 side open"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: any other wording of the A55 side fails" nonzero \
	"FAIL 14 ROADMAP.md: the A55 side is proposed, pending owner approval" \
	"does not say 'A55 side proposed, pending owner approval'"

t=$(tree refs)
edit "$t/docs/references/README.md" "secure-world, hsm-self-defence | Not on the public" "secure-world | Not on the public"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a missing document no longer listed for the row fails" nonzero \
	"'i.MX 95 Security Reference Manual' is missing for hsm-self-defence"

t=$(tree built)
printf '\nhsm-self-defence-image: ## build it\n\t@true\n' >>"$t/Makefile"
: >"$t/scripts/hsm-self-defence-build.sh"
: >"$t/hsm-self-defence/build.sh"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a target, script or source file that builds the row fails" nonzero \
	"targets hsm-self-defence-image" "found hsm-self-defence-build.sh" "found build.sh"

t=$(tree nofile)
rm "$t/hsm-self-defence/a55/quarantine.c"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a file of the #183 tree gone fails" nonzero \
	"the files #183 introduced are present" "missing a55/quarantine.c"

t=$(tree notree)
rm -r "$t/hsm-self-defence"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a tree without hsm-self-defence/ fails" nonzero \
	"the files #183 introduced are present" "missing a55/quarantine.c, a55/quarantine.h" "a55/tamper_event_test.c"

t=$(tree nospec)
rm "$t/docs/SPEC.md"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t"
check "make hsm-self-defence-check: a tree without docs/SPEC.md fails" nonzero "docs/SPEC.md: unreadable"

run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$TMP_ROOT/absent"
check "make hsm-self-defence-check: a root that is not a directory is a usage error" nonzero "usage:"

# HSD_ROOT is a path, never shell source: a directory whose name holds a
# backtick command, a $( ) command and a space reaches the check literally and
# no command runs. The directory lives under $TMP_ROOT, never in the clone.
HSD_MARK="$TMP_ROOT/hsd-mark-backtick"
HSD_MARK2="$TMP_ROOT/hsd-mark-dollar"
export HSD_MARK HSD_MARK2
rm -f "$HSD_MARK" "$HSD_MARK2"
t=$(tree "inj/a \`touch \"\$HSD_MARK\"\` \$(touch \"\$HSD_MARK2\") b")
run env HSD_ROOT="$t" make -s -C "$ROOT" hsm-self-defence-check
check "make hsm-self-defence-check: a root path with a backtick, \$( ) and a space reaches the check literally" 0 \
	"hsm-self-defence-check: OK"
expect "make hsm-self-defence-check: no command in the root path ran" \
	test ! -e "$HSD_MARK" -a ! -e "$HSD_MARK2"
run make -s -C "$ROOT" hsm-self-defence-check HSD_ROOT="$t/none \`touch \"\$HSD_MARK\"\`"
check "make hsm-self-defence-check: a command-line path with a backtick and a dollar sign is refused, not run" 2 \
	"hsm-self-defence-check: a command-line HSD_ROOT holding a dollar sign is refused"
expect "make hsm-self-defence-check: the command-line backtick did not run" test ! -e "$HSD_MARK"

# Make runs a function in a command-line variable while it builds the recipe
# environment: a literal $(shell ...) on the command line is refused before it
# runs, and the same text in the environment reaches the check as a path that
# does not exist (usage error) with no command run.
HSD_MARK3="$TMP_ROOT/hsd-mark-shell-cmdline"
HSD_MARK4="$TMP_ROOT/hsd-mark-shell-env"
rm -f "$HSD_MARK3" "$HSD_MARK4"
run make -s -C "$ROOT" hsm-self-defence-check "HSD_ROOT=$TMP_ROOT/\$(shell touch $HSD_MARK3)"
check "make hsm-self-defence-check: a command-line \$(shell ...) HSD_ROOT is refused" 2 \
	"a command-line HSD_ROOT holding a dollar sign is refused"
expect "make hsm-self-defence-check: the command-line \$(shell ...) did not run" test ! -e "$HSD_MARK3"
run env HSD_ROOT="$TMP_ROOT/\$(shell touch $HSD_MARK4)" make -s -C "$ROOT" hsm-self-defence-check
check "make hsm-self-defence-check: an environment \$(shell ...) HSD_ROOT reaches the check literally, unreadable" nonzero \
	"usage:"
expect "make hsm-self-defence-check: the environment \$(shell ...) did not run" test ! -e "$HSD_MARK4"

finish
