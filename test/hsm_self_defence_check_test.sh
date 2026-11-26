#!/usr/bin/env bash
# Unit test of scripts/hsm-self-defence-check.py: its exit codes (0 when the
# row holds, 1 when a check fails, 2 on a usage error) and its row parsing.
# The make target and the broken trees are test/integration/hsm_self_defence_test.sh's.
set -uo pipefail
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/scripts/hsm-self-defence-check.py"

run python3 "$CHECK" "$ROOT"
check "hsm-self-defence-check: this tree passes" 0 "hsm-self-defence-check: OK"

run python3 "$CHECK"
check "hsm-self-defence-check: no root is a usage error" 2 "usage: hsm-self-defence-check.py <root>"

# A minimal tree: the row, its ROADMAP line and its missing documents.
t="$TMP_ROOT/min"
mkdir -p "$t/docs/references"
spec="| hsm-self-defence | planned | Later (owner rulings 1243 and 1244, #26): it stays blocked. The HSM device side of the tamper response that trusted-firmware's \`hsm-self-defence\` row enforces on the Cortex-M7 and go-xkms's \`hsm-self-defence\` row names. The M7 acts through NXP's System Manager, whose configuration is this repository's (\`system-manager-config\`), and the EdgeLock secure enclave: power domains, PHYs, key zeroisation and shutdown. Whether the Cortex-A55 tamper detector, the NPU model and the IMA log are built in this repository is not decided, and is an open question for the owner. No document gives the EdgeLock tamper pins; the one that does is missing. | none |"
printf '%s\n' "| Row | Status | Requirements | Folder |" "|---|---|---|---|" "$spec" >"$t/docs/SPEC.md"
printf '%s\n' "- **hsm-self-defence** — x — blocked: owner approval; A55 side proposed, pending owner approval" >"$t/ROADMAP.md"
printf '%s\n' "| IMX95RM, i.MX 95 Applications Processor Reference Manual | hsm-self-defence | x | x |" \
	"| i.MX 95 Security Reference Manual | secure-world, hsm-self-defence | x | x |" >"$t/docs/references/README.md"
printf 'build:\n\t@true\n' >"$t/Makefile"
# The A55 service files #183 put in hsm-self-defence/: the checker wants exactly these.
mkdir -p "$t/hsm-self-defence/a55"
for f in quarantine.c quarantine.h quarantine_test.c tamper_event.c tamper_event.h tamper_event_test.c; do
	: >"$t/hsm-self-defence/a55/$f"
done

run python3 "$CHECK" "$t"
check "hsm-self-defence-check: a minimal tree that keeps the row passes" 0 "hsm-self-defence-check: OK"

printf '%s\n' "$spec" >>"$t/docs/SPEC.md"
run python3 "$CHECK" "$t"
check "hsm-self-defence-check: two rows fail" 1 "FAIL 1 SPEC.md: one hsm-self-defence row: found 2"

printf '%s\n' "| hsm-self-defence | planned | x |" >"$t/docs/SPEC.md"
run python3 "$CHECK" "$t"
check "hsm-self-defence-check: a row without four cells fails" 1 "the row has four cells: found 3"

# The no-build guard reads the build integration, not target names: a minimal
# tree that passes, then a copy per way of compiling an A55 source.
printf '%s\n' "| Row | Status | Requirements | Folder |" "|---|---|---|---|" "$spec" >"$t/docs/SPEC.md"
MSG="build files: nothing compiles the hsm-self-defence A55 sources"
fixture() { rm -rf "${TMP_ROOT:?}/$1"; cp -r "$t" "$TMP_ROOT/$1"; echo "$TMP_ROOT/$1"; }

b=$(fixture recipe)
printf 'build:\n\tcc -o /tmp/q hsm-self-defence/a55/quarantine.c\n' >"$b/Makefile"
run python3 "$CHECK" "$b"
check "hsm-self-defence-check: a non-hsd target recipe compiling an A55 source fails" 1 "$MSG" "named by Makefile"

b=$(fixture included)
mkdir -p "$b/mk"
printf 'build:\n\t@true\ninclude mk/extra.mk\n' >"$b/Makefile"
printf 'extra:\n\tcc -c hsm-self-defence/a55/tamper_event.c\n' >"$b/mk/extra.mk"
run python3 "$CHECK" "$b"
check "hsm-self-defence-check: an included makefile compiling an A55 source fails" 1 "$MSG" "named by mk/extra.mk"

b=$(fixture script)
mkdir -p "$b/scripts"
printf 'build:\n\t@bash scripts/pack.sh\n' >"$b/Makefile"
printf '#!/bin/sh\ncc -o /tmp/q hsm-self-defence/a55/quarantine.c\n' >"$b/scripts/pack.sh"
run python3 "$CHECK" "$b"
check "hsm-self-defence-check: an unrelated script that compiles an A55 source fails" 1 "$MSG" "named by scripts/pack.sh"

b=$(fixture bbappend)
mkdir -p "$b/platform-image/meta/recipes"
printf 'SRC_URI += "file://hsm-self-defence/a55/tamper_event.c"\n' >"$b/platform-image/meta/recipes/x.bbappend"
run python3 "$CHECK" "$b"
check "hsm-self-defence-check: a bbappend adding an A55 source fails" 1 "$MSG" "named by platform-image/meta/recipes/x.bbappend"

# An include operand is expanded from the literal variables set before it; one
# still holding a Make expression fails closed.
b=$(fixture incvar)
mkdir -p "$b/mk"
printf "MKDIR := mk\nbuild:\n\t@true\ninclude \$(MKDIR)/extra.mk\n" >"$b/Makefile"
printf 'extra:\n\tcc -c hsm-self-defence/a55/quarantine.c\n' >"$b/mk/extra.mk"
run python3 "$CHECK" "$b"
check "hsm-self-defence-check: an include through a plain variable is followed and fails" 1 "$MSG" "named by mk/extra.mk"

b=$(fixture incshell)
mkdir -p "$b/mk"
printf "build:\n\t@true\ninclude \$(shell echo mk)/extra.mk\n" >"$b/Makefile"
printf 'extra:\n\t@true\n' >"$b/mk/extra.mk"
run python3 "$CHECK" "$b"
check "hsm-self-defence-check: an include the checker cannot resolve fails" 1 \
	"build files: an include the checker cannot resolve" "Makefile includes '\$(shell"

finish
