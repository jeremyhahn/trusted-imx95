# shellcheck shell=bash
# Sourced by platform-image-parse.sh and platform-image-build.sh (not run on
# its own): the effective-value checks of one target, read from `bitbake -e`
# in the build directory bitbake runs in, so a conf/auto.conf or site.conf the
# templates do not know is caught. The caller sets effective_who (its name, for
# messages) and has bitbake on PATH.

# bbval ENV KEY: the value of KEY in `bitbake -e` output (a value may span lines).
bbval() {
	printf '%s\n' "$1" | sed -n "/^$2=\"/{/\"\$/!{:a;N;/\"\$/!ba;};p;}" | sed -e "1s/^$2=\"//" -e '$s/"$//'
}
# must_equal TARGET KEY GOT WANT WHAT
must_equal() {
	[ "$3" = "$4" ] || {
		echo "${effective_who:-platform-image}: $1: $2 is '$3', $5 '$4'" >&2
		exit 1
	}
}
# effective_check TARGET WANT_MACHINE WANT_DISTRO WANT_INIT: MACHINE, DISTRO and
# INIT_MANAGER equal the pins, and neither IMAGE_FEATURES nor
# EXTRA_IMAGE_FEATURES holds a prohibited feature. Sets effective_machine and
# effective_distro to the values bitbake uses.
effective_check() {
	local t=$1 benv feats extra bad
	benv=$(bitbake -e "$t")
	effective_machine=$(bbval "$benv" MACHINE)
	effective_distro=$(bbval "$benv" DISTRO)
	must_equal "$t" MACHINE "$effective_machine" "$2" "the lock pins"
	must_equal "$t" DISTRO "$effective_distro" "$3" "local.conf.template sets"
	must_equal "$t" INIT_MANAGER "$(bbval "$benv" INIT_MANAGER)" "$4" "the distro sets"
	feats=$(bbval "$benv" IMAGE_FEATURES)
	[ -n "$feats" ] || {
		echo "${effective_who:-platform-image}: $t: no IMAGE_FEATURES in bitbake -e" >&2
		exit 1
	}
	extra=$(bbval "$benv" EXTRA_IMAGE_FEATURES)
	for bad in debug-tweaks empty-root-password allow-empty-password allow-root-login; do
		case " $feats " in
		*[[:space:]]"$bad"[[:space:]]*)
			echo "${effective_who:-platform-image}: $t: IMAGE_FEATURES holds $bad" >&2
			exit 1
			;;
		esac
		case " $extra " in
		*[[:space:]]"$bad"[[:space:]]*)
			echo "${effective_who:-platform-image}: $t: EXTRA_IMAGE_FEATURES holds $bad" >&2
			exit 1
			;;
		esac
	done
}
