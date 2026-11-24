#!/usr/bin/env bash
# The recipe text holds a literal ${PN}; the single quotes are meant.
# shellcheck disable=SC2016
# Static check of the enclave-access recipe (R6, proposed, pending owner approval):
# the udev rule, the group-only recipe and that no image recipe installs it. No bitbake.
set -u
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FAILS=0

recipe_rel=platform-image/recipes-security/enclave-access/enclave-access.bb
rules_rel=platform-image/recipes-security/enclave-access/files/90-enclave-access.rules

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# rule_ok FILE: exactly one active rule line; exact kernel name, OWNER root,
# the xkmsd group, MODE 0660 (so no world bit).
rule_ok() {
	local f=$1 rules n
	rules=$(while IFS= read -r l; do
		case $l in '' | '#'*) ;; *) printf '%s\n' "$l" ;; esac
	done <"$f")
	n=$(printf '%s\n' "$rules" | wc -l)
	[ -n "$rules" ] && [ "$n" -eq 1 ] || {
		echo "want one active rule, got $n"
		return 1
	}
	case $rules in *'KERNEL=="hsm0_ch0"'*) ;; *)
		echo "kernel name is not exactly hsm0_ch0"
		return 1
		;;
	esac
	case $rules in *'OWNER="root"'*) ;; *)
		echo "OWNER is not root"
		return 1
		;;
	esac
	case $rules in *'GROUP="xkmsd"'*) ;; *)
		echo "GROUP is not xkmsd"
		return 1
		;;
	esac
	case $rules in *'MODE="0660"'*) ;; *)
		echo "MODE is not 0660"
		return 1
		;;
	esac
	m=${rules#*MODE=\"}
	m=${m%%\"*}
	[ $((8#$m & 8#007)) -eq 0 ] || {
		echo "MODE has a world bit"
		return 1
	}
	return 0
}

# recipe_ok FILE: inherits useradd, adds only a group, no user or unit.
recipe_ok() {
	local f=$1 t
	t=$(<"$f")
	case $t in *'inherit useradd'*) ;; *)
		echo "no inherit useradd"
		return 1
		;;
	esac
	case $t in *'GROUPADD_PARAM:${PN} = "--system xkmsd"'*) ;; *)
		echo "group xkmsd is not added"
		return 1
		;;
	esac
	case $t in *USERADD_PARAM* | *SYSTEMD_SERVICE* | *'inherit systemd'*)
		echo "recipe adds a user or a unit"
		return 1
		;;
	esac
	return 0
}

# image_ok FILE...: no image recipe installs enclave-access (R6 is pending owner
# approval; the recipe is a proposal and stays out of the image).
image_ok() {
	local f l
	for f in "$@"; do
		while IFS= read -r l; do
			case $l in '#'*) continue ;; esac
			case $l in *enclave-access*)
				echo "$f installs enclave-access"
				return 1
				;;
			esac
		done <"$f"
	done
	return 0
}

t() {
	local name=$1 out
	shift
	if out=$("$@" 2>&1); then pass "$name"; else fail "$name" "$out"; fi
}
neg() {
	local name=$1 out
	shift
	if out=$("$@" 2>&1); then fail "$name" "expected a failure"; else pass "$name ($out)"; fi
}

t "rule: kernel, owner, group, mode 0660" rule_ok "$ROOT/$rules_rel"
t "recipe: useradd, group only" recipe_ok "$ROOT/$recipe_rel"
t "image recipes do not install enclave-access" image_ok "$ROOT"/platform-image/recipes-core/images/*.bb
printf '%s\n' 'IMAGE_INSTALL = "packagegroup-core-boot enclave-access"' >"$scratch/image.bb"
neg "negative: image installs enclave-access" image_ok "$scratch/image.bb"

# negative cases on scratch copies
sed_copy() { # FROM TO NEWFILE (literal replace on a copy of the rules)
	local t
	t=$(<"$ROOT/$rules_rel")
	printf '%s\n' "${t//$1/$2}" >"$3"
}
sed_copy 'MODE="0660"' 'MODE="0666"' "$scratch/mode.rules"
neg "negative: mode 0666" rule_ok "$scratch/mode.rules"
sed_copy 'KERNEL=="hsm0_ch0"' 'KERNEL=="hsm0_ch1"' "$scratch/kernel.rules"
neg "negative: wrong kernel name" rule_ok "$scratch/kernel.rules"
sed_copy 'OWNER="root"' 'OWNER="xkmsd"' "$scratch/owner.rules"
neg "negative: owner not root" rule_ok "$scratch/owner.rules"
t0=$(<"$ROOT/$recipe_rel")
printf '%s\n' "${t0//--system xkmsd/--system other}" >"$scratch/nogroup.bb"
neg "negative: missing group" recipe_ok "$scratch/nogroup.bb"
printf '%s\n' "$t0" 'USERADD_PARAM:${PN} = "-r xkmsd"' >"$scratch/user.bb"
neg "negative: recipe adds a user" recipe_ok "$scratch/user.bb"

finish
