#!/usr/bin/env bash
# The recipe text holds literal ${...} expressions; the single quotes are meant.
# shellcheck disable=SC2016
# Static check of the xkmsd recipe (docs/SPEC.md, `platform-image`: "It runs
# xkmsd from go-xkms on its Linux side") and of the production image that
# installs it. No bitbake, no network.
set -u
# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

recipe_rel=platform-image/recipes-security/xkmsd/xkmsd_git.bb
image_rel=platform-image/recipes-core/images/trusted-imx95-image.bb
unit_rel=platform-image/recipes-security/xkmsd/files/xkmsd.service
conf_rel=platform-image/recipes-security/xkmsd/files/xkmsd.yaml

scratch=$(mktemp -d)
trap 'rm -rf "$scratch" "$TMP_ROOT"' EXIT

# val FILE NAME: the value of the first active `NAME = "value"` line.
val() {
	local f=$1 name=$2 l v
	while IFS= read -r l; do
		case $l in "$name = \""*'"')
			v=${l#"$name = \""}
			printf '%s' "${v%\"}"
			return 0
			;;
		esac
	done <"$f"
	return 1
}

# has FILE TEXT: an active (not comment) line holds TEXT.
has() {
	local l s
	while IFS= read -r l; do
		s=${l#"${l%%[![:space:]]*}"}
		case $s in '#'*) continue ;; esac
		case $l in *"$2"*) return 0 ;; esac
	done <"$1"
	return 1
}

# recipe_ok FILE: a tagged go-xkms release, its commit, the PV of the tag,
# AGPL-3.0-only, a sha256-checked Go archive, the pinned toolchain only,
# modules verified against go.sum, aarch64 only, the binary packaged.
recipe_ok() {
	local f=$1 tag pv rev sha
	tag=$(val "$f" XKMS_TAG) || { echo "no XKMS_TAG"; return 1; }
	[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "XKMS_TAG '$tag' is not a release tag"; return 1; }
	pv=$(val "$f" PV) || { echo "no PV"; return 1; }
	[ "$pv" = "${tag#v}" ] || { echo "PV '$pv' is not the tag '$tag' without its v"; return 1; }
	rev=$(val "$f" SRCREV) || { echo "no SRCREV"; return 1; }
	[[ $rev =~ ^[0-9a-f]{40}$ ]] || { echo "SRCREV '$rev' is not a full commit"; return 1; }
	[ "$(val "$f" LICENSE)" = AGPL-3.0-only ] || { echo "LICENSE is not AGPL-3.0-only"; return 1; }
	has "$f" 'git://github.com/jeremyhahn/go-xkms;' || { echo "SRC_URI is not go-xkms"; return 1; }
	has "$f" 'nobranch=1;tag=${XKMS_TAG}' || { echo "SRC_URI does not pin the tag"; return 1; }
	if has "$f" 'branch=' && ! has "$f" 'nobranch=1'; then echo "SRC_URI follows a branch"; return 1; fi
	sha=$(val "$f" 'SRC_URI[go.sha256sum]') || { echo "no Go archive sha256"; return 1; }
	[[ $sha =~ ^[0-9a-f]{64}$ ]] || { echo "Go archive sha256 '$sha' is malformed"; return 1; }
	has "$f" 'export GOTOOLCHAIN=local' || { echo "go may fetch another toolchain"; return 1; }
	has "$f" 'go mod verify' || { echo "modules are not verified"; return 1; }
	has "$f" '-mod=readonly' || { echo "go.mod may be rewritten"; return 1; }
	[ "$(val "$f" COMPATIBLE_HOST)" = 'aarch64.*-linux' ] || { echo "COMPATIBLE_HOST is not aarch64 Linux"; return 1; }
	[ "$(val "$f" 'FILES:${PN}')" = '${bindir}/xkmsd ${systemd_system_unitdir}/xkmsd.service ${sysconfdir}/xkms' ] ||
		{ echo "the package does not hold the binary, the unit and /etc/xkms"; return 1; }
	return 0
}

# user_ok FILE: the recipe adds the xkmsd system user and group, no login shell.
user_ok() {
	local f=$1 u
	has "$f" 'inherit pkgconfig useradd systemd' || { echo "no inherit useradd"; return 1; }
	[ "$(val "$f" USERADD_PACKAGES)" = '${PN}' ] || { echo "USERADD_PACKAGES is not \${PN}"; return 1; }
	[ "$(val "$f" 'GROUPADD_PARAM:${PN}')" = '--system xkmsd' ] || { echo "group xkmsd is not added"; return 1; }
	u=$(val "$f" 'USERADD_PARAM:${PN}') || { echo "no USERADD_PARAM"; return 1; }
	case " $u " in *' --system '*) ;; *) echo "user is not a system user"; return 1 ;; esac
	case " $u " in *' --shell /sbin/nologin '*) ;; *) echo "user has a login shell"; return 1 ;; esac
	case " $u " in *' --gid xkmsd '*) ;; *) echo "user is not in group xkmsd"; return 1 ;; esac
	case $u in *' xkmsd') ;; *) echo "the user is not named xkmsd"; return 1 ;; esac
	return 0
}

# install_ok FILE: the recipe enables the unit and installs it and the config.
install_ok() {
	local f=$1
	[ "$(val "$f" 'SYSTEMD_SERVICE:${PN}')" = xkmsd.service ] || { echo "no SYSTEMD_SERVICE xkmsd.service"; return 1; }
	[ "$(val "$f" 'SYSTEMD_AUTO_ENABLE:${PN}')" = enable ] || { echo "the unit is not enabled"; return 1; }
	has "$f" 'file://xkmsd.service' || { echo "the unit is not in SRC_URI"; return 1; }
	has "$f" 'file://xkmsd.yaml' || { echo "the config is not in SRC_URI"; return 1; }
	has "$f" '${UNPACKDIR}/xkmsd.service ${D}${systemd_system_unitdir}/xkmsd.service' || { echo "the unit is not installed"; return 1; }
	has "$f" 'install -m 0640 -g xkmsd ${UNPACKDIR}/xkmsd.yaml ${D}${sysconfdir}/xkms/xkmsd.yaml' ||
		{ echo "the config is not installed 0640 root:xkmsd"; return 1; }
	[ "$(val "$f" 'CONFFILES:${PN}')" = '${sysconfdir}/xkms/xkmsd.yaml' ] || { echo "the config is not a conffile"; return 1; }
	return 0
}

# unit_ok FILE: the unit runs xkmsd as xkmsd with the shipped config, starts at
# boot, restarts on failure and carries the sandbox lines.
unit_ok() {
	local f=$1 want
	for want in 'User=xkmsd' 'Group=xkmsd' 'ExecStart=/usr/bin/xkmsd --config /etc/xkms/xkmsd.yaml' \
		'Restart=on-failure' 'StateDirectory=xkms' 'NoNewPrivileges=yes' 'PrivateTmp=yes' \
		'ProtectSystem=strict' 'ProtectHome=yes' 'CapabilityBoundingSet=' 'SystemCallFilter=@system-service' \
		'UMask=0077' 'WantedBy=multi-user.target'; do
		grep_line "$f" "$want" || { echo "the unit lacks '$want'"; return 1; }
	done
	return 0
}

# grep_line FILE LINE: FILE holds LINE exactly.
grep_line() {
	local l
	while IFS= read -r l; do [ "$l" != "$2" ] || return 0; done <"$1"
	return 1
}

# config_ok FILE: the config sets the state path of the unit and holds no
# secret-looking key.
config_ok() {
	local f=$1 l
	grep_line "$f" 'storage:' || { echo "no storage section"; return 1; }
	grep_line "$f" '  path: /var/lib/xkms' || { echo "storage.path is not the unit's StateDirectory"; return 1; }
	while IFS= read -r l; do
		case $l in '#'*) continue ;; esac
		case $l in *password* | *secret* | *token* | *private_key* | *PRIVATE*) echo "the config holds '$l'"; return 1 ;; esac
	done <"$f"
	return 0
}

# image_ok FILE: an active IMAGE_INSTALL line installs xkmsd (a word, not a
# substring of another package name).
image_ok() {
	local l v w
	while IFS= read -r l; do
		case $l in '#'*) continue ;; esac
		[[ $l =~ ^IMAGE_INSTALL(:append)?\ *[+]?=\ *\"([^\"]*)\" ]] || continue
		v=${BASH_REMATCH[2]}
		for w in $v; do [ "$w" != xkmsd ] || return 0; done
	done <"$1"
	echo "$1 does not install xkmsd"
	return 1
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

t "the xkmsd recipe" recipe_ok "$ROOT/$recipe_rel"
t "the production image installs xkmsd" image_ok "$ROOT/$image_rel"
t "the xkmsd recipe adds the xkmsd system user" user_ok "$ROOT/$recipe_rel"
t "the xkmsd recipe installs and enables the unit and the config" install_ok "$ROOT/$recipe_rel"
t "the xkmsd unit" unit_ok "$ROOT/$unit_rel"
t "the xkmsd default config" config_ok "$ROOT/$conf_rel"

r0=$(<"$ROOT/$recipe_rel")
rcopy() { # FROM TO NAME: a copy of the recipe with FROM replaced by TO
	printf '%s\n' "${r0//"$1"/"$2"}" >"$scratch/$3.bb"
	printf '%s' "$scratch/$3.bb"
}
neg "negative: PV is not the tag" recipe_ok "$(rcopy 'PV = "0.64.2-alpha"' 'PV = "0.64.1"' pv)"
neg "negative: short SRCREV" recipe_ok "$(rcopy 'SRCREV = "9f040cea0e06a2afd3233d0e669885249f49c4c2"' 'SRCREV = "9f040cea"' rev)"
neg "negative: branch tag" recipe_ok "$(rcopy 'XKMS_TAG = "v0.64.2-alpha"' 'XKMS_TAG = "main"' tag)"
neg "negative: other license" recipe_ok "$(rcopy 'LICENSE = "AGPL-3.0-only"' 'LICENSE = "MIT"' lic)"
neg "negative: no tag in SRC_URI" recipe_ok "$(rcopy 'nobranch=1;tag=${XKMS_TAG}' 'branch=main' src)"
neg "negative: malformed Go sha256" recipe_ok "$(rcopy '65efbc80' 'zz' sha)"
neg "negative: GOTOOLCHAIN not local" recipe_ok "$(rcopy 'export GOTOOLCHAIN=local' 'export GOTOOLCHAIN=auto' tc)"
neg "negative: no go mod verify" recipe_ok "$(rcopy 'go mod verify' 'true' verify)"
neg "negative: any host" recipe_ok "$(rcopy 'COMPATIBLE_HOST = "aarch64.*-linux"' 'COMPATIBLE_HOST = ".*-linux"' host)"
neg "negative: verify only in a comment" recipe_ok "$(rcopy '    go mod verify' '    # go mod verify' cverify)"

neg "negative: no USERADD_PARAM" user_ok "$(rcopy 'USERADD_PARAM:${PN}' 'X_PARAM:${PN}' nouser)"
neg "negative: user with a login shell" user_ok "$(rcopy '/sbin/nologin' '/bin/sh' shell)"
neg "negative: no useradd class" user_ok "$(rcopy 'inherit pkgconfig useradd systemd' 'inherit pkgconfig systemd' noua)"
neg "negative: unit not enabled" install_ok "$(rcopy 'SYSTEMD_AUTO_ENABLE:${PN} = "enable"' 'SYSTEMD_AUTO_ENABLE:${PN} = "disable"' noenable)"
neg "negative: no SYSTEMD_SERVICE" install_ok "$(rcopy 'SYSTEMD_SERVICE:${PN}' 'X_SERVICE:${PN}' nosvc)"
neg "negative: config world-readable" install_ok "$(rcopy 'install -m 0640 -g xkmsd' 'install -m 0644' confmode)"
neg "negative: config not in SRC_URI" install_ok "$(rcopy 'file://xkmsd.yaml' 'file://other.yaml' confsrc)"

u0=$(<"$ROOT/$unit_rel")
ucopy() { # FROM TO NAME: a copy of the unit with FROM replaced by TO
	printf '%s\n' "${u0//"$1"/"$2"}" >"$scratch/$3.service"
	printf '%s' "$scratch/$3.service"
}
neg "negative: unit runs as root" unit_ok "$(ucopy 'User=xkmsd' 'User=root' root)"
neg "negative: unit allows new privileges" unit_ok "$(ucopy 'NoNewPrivileges=yes' 'NoNewPrivileges=no' nnp)"
neg "negative: unit without a private /tmp" unit_ok "$(ucopy 'PrivateTmp=yes' '#PrivateTmp=yes' tmp)"
neg "negative: unit without a state directory" unit_ok "$(ucopy 'StateDirectory=xkms' '' state)"
neg "negative: unit restarts always" unit_ok "$(ucopy 'Restart=on-failure' 'Restart=no' restart)"
neg "negative: unit with another config" unit_ok "$(ucopy '--config /etc/xkms/xkmsd.yaml' '--config /tmp/x.yaml' exec)"
neg "negative: unit not wanted at boot" unit_ok "$(ucopy 'WantedBy=multi-user.target' '' install)"

c0=$(<"$ROOT/$conf_rel")
printf '%s\n' "${c0//\/var\/lib\/xkms/\/tmp\/xkms}" >"$scratch/path.yaml"
neg "negative: config state path elsewhere" config_ok "$scratch/path.yaml"
printf '%s\n' "$c0" 'auth:' '  password: x' >"$scratch/secret.yaml"
neg "negative: config holds a password" config_ok "$scratch/secret.yaml"

printf '%s\n' 'IMAGE_INSTALL = "packagegroup-core-boot ${CORE_IMAGE_EXTRA_INSTALL}"' >"$scratch/noxkmsd.bb"
neg "negative: image without xkmsd" image_ok "$scratch/noxkmsd.bb"
printf '%s\n' '# IMAGE_INSTALL = "packagegroup-core-boot xkmsd"' 'IMAGE_INSTALL = "packagegroup-core-boot"' >"$scratch/comment.bb"
neg "negative: xkmsd only in a comment" image_ok "$scratch/comment.bb"
printf '%s\n' 'IMAGE_INSTALL = "packagegroup-core-boot xkmsd-tools"' >"$scratch/prefix.bb"
neg "negative: another package named xkmsd-*" image_ok "$scratch/prefix.bb"
printf '%s\n' 'IMAGE_INSTALL:append = " xkmsd"' >"$scratch/append.bb"
t "an IMAGE_INSTALL:append installs xkmsd" image_ok "$scratch/append.bb"

finish
