#!/usr/bin/env bash
# Run in the devcontainer image (make sm-toolchain-check, the CI job
# system-manager-build): build the pinned System Manager with the real pinned
# Arm toolchain, then check the toolchain starts and the artefacts are there.
# A script, not a Make recipe: no `$` passes through Make twice.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=${SM_OUT:-out/system-manager}

make system-manager

gcc=$(find "$out" -type f -name arm-none-eabi-gcc | head -n 1)
[ -n "$gcc" ] || { echo "sm-toolchain-check: no arm-none-eabi-gcc under $out" >&2; exit 1; }
"$gcc" --version | head -n 1

bin="$out/m33_image.bin"
[ -s "$bin" ] || { echo "sm-toolchain-check: $bin is missing or empty" >&2; exit 1; }
[ -s "$out/sm-manifest.txt" ] || { echo "sm-toolchain-check: $out/sm-manifest.txt is missing or empty" >&2; exit 1; }

# The linked System Manager ELF must be an ARM ELF: the magic, then e_machine
# 0x28 (EM_ARM) at offset 18.
elf=$(find "$out/tree-1/build" -type f -name '*.elf' | head -n 1)
[ -n "$elf" ] || { echo "sm-toolchain-check: no linked .elf under $out/tree-1/build" >&2; exit 1; }
magic=$(od -An -tx1 -N4 "$elf" | tr -d ' \n')
machine=$(od -An -tx1 -j18 -N1 "$elf" | tr -d ' \n')
[ "$magic" = 7f454c46 ] && [ "$machine" = 28 ] || {
	echo "sm-toolchain-check: $elf is not an ARM ELF (magic $magic, e_machine $machine)" >&2
	exit 1
}
echo "sm-toolchain-check: OK ($bin, $elf)"
