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
build_rel=platform-image/recipes-security/xkmsd/files/xkmsd-build.sh
mount_rel=platform-image/recipes-security/xkmsd/files/var-lib-xkms.mount
wks_rel=platform-image/wic/trusted-imx95.wks.in

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
	has "$f" 'file://xkmsd-build.sh' || { echo "the build script is not in SRC_URI"; return 1; }
	has "$f" 'sh "${UNPACKDIR}/xkmsd-build.sh" "${S}" "${B}/xkmsd" "${PV}" "${SRCREV}"' ||
		{ echo "do_compile does not run the build script (the go build command is gone)"; return 1; }
	[ "$(val "$f" COMPATIBLE_HOST)" = 'aarch64.*-linux' ] || { echo "COMPATIBLE_HOST is not aarch64 Linux"; return 1; }
	[ "$(val "$f" 'FILES:${PN}')" = '${bindir}/xkmsd ${systemd_system_unitdir}/xkmsd.service ${systemd_system_unitdir}/var-lib-xkms.mount ${localstatedir}/lib/xkms ${sysconfdir}/xkms' ] ||
		{ echo "the package does not hold the binary, the units, /var/lib/xkms and /etc/xkms"; return 1; }
	return 0
}

# build_ok FILE: the build script the recipe and the smoke test share keeps the
# local toolchain only, verifies modules, never rewrites go.mod, and runs
# go build with go-xkms's server tags for ./cmd/xkmsd.
build_ok() {
	local f=$1
	has "$f" 'export GOTOOLCHAIN=local' || { echo "go may fetch another toolchain"; return 1; }
	has "$f" 'go mod verify' || { echo "modules are not verified"; return 1; }
	has "$f" '-mod=readonly' || { echo "go.mod may be rewritten"; return 1; }
	has "$f" 'go mod download' || { echo "modules are not downloaded"; return 1; }
	has "$f" 'go build -tags "$XKMS_TAGS"' || { echo "there is no go build command"; return 1; }
	has "$f" '-o "$out" ./cmd/xkmsd' || { echo "go build does not build ./cmd/xkmsd"; return 1; }
	has "$f" 'XKMS_TAGS="pkcs8,tpm2,awskms,gcpkms,azurekv,vault,pkcs11"' || { echo "the build tags are not go-xkms's server tags"; return 1; }
	return 0
}

# state_ok UNIT MOUNT WKS RECIPE IMAGE: xkmsd's state is on the persistent
# partition: the unit needs the mount and fails closed without it, the mount
# unit mounts the layout's xkms-state partition, the recipe ships the mount
# unit, and the image builds that layout.
state_ok() {
	local unit=$1 mnt=$2 wks=$3 rec=$4 img=$5 want
	for want in 'RequiresMountsFor=/var/lib/xkms' 'After=var-lib-xkms.mount' \
		'AssertPathIsMountPoint=/var/lib/xkms' 'AssertPathIsReadWrite=/var/lib/xkms'; do
		grep_line "$unit" "$want" || { echo "the unit lacks '$want'"; return 1; }
	done
	for want in 'What=/dev/disk/by-label/xkms-state' 'Where=/var/lib/xkms' 'Type=ext4'; do
		grep_line "$mnt" "$want" || { echo "the mount unit lacks '$want'"; return 1; }
	done
	has "$mnt" 'Options=rw,' || { echo "the state mount is not read-write"; return 1; }
	has "$wks" '--label xkms-state' || { echo "the layout has no xkms-state partition"; return 1; }
	has "$wks" 'part /var/lib/xkms ' || { echo "the xkms-state partition is not for /var/lib/xkms"; return 1; }
	has "$wks" 'part /boot ' || { echo "the layout has no /boot partition"; return 1; }
	has "$wks" 'part / ' || { echo "the layout has no root partition"; return 1; }
	local pl
	while IFS= read -r pl; do
		case $pl in
		'part /'*)
			case $pl in
			*'--label xkms-state'*) ;;
			*'--use-uuid'* | *'--use-label'*) ;;
			*) echo "the mounted partition '$pl' is not mounted by uuid or label"; return 1 ;;
			esac
			;;
		esac
	done <"$wks"
	has "$rec" 'file://var-lib-xkms.mount' || { echo "the mount unit is not in SRC_URI"; return 1; }
	has "$rec" '${UNPACKDIR}/var-lib-xkms.mount ${D}${systemd_system_unitdir}/var-lib-xkms.mount' || { echo "the mount unit is not installed"; return 1; }
	has "$rec" 'install -d -m 0750 ${D}${localstatedir}/lib/xkms' || { echo "the mount point is not created"; return 1; }
	has "$img" 'WKS_FILE = "trusted-imx95.wks.in"' || { echo "the image does not use the layout"; return 1; }
	has "$img" 'IMAGE_FSTYPES += "wic"' || { echo "the image does not build the layout"; return 1; }
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

# config_ok FILE: every top-level key is one of the sections of go-xkms's own
# minimal configuration at the pinned tag (a key the daemon does not know is
# not set: the old `storage:` section was one, and the daemon refused the file
# for lack of datastore.path), the state and socket paths are the unit's, and
# no secret-looking key is set. The smoke test starts the real daemon on it.
config_ok() {
	local f=$1 l k
	while IFS= read -r l; do
		case $l in '#'* | ' '* | '') continue ;; esac
		k=${l%%:*}
		case $k in
		server | protocols | unix | logging | tls | auth | barrier | ratelimit | metrics | health | datastore | rng | default_backend | backends | ca) ;;
		*) echo "the config sets '$k', which go-xkms's configuration does not take"; return 1 ;;
		esac
	done <"$f"
	grep_line "$f" 'datastore:' || { echo "no datastore section"; return 1; }
	grep_line "$f" '  path: "/var/lib/xkms/storage"' || { echo "datastore.path is not under the state mount"; return 1; }
	grep_line "$f" '  socket_path: "/run/xkms/xkms.sock"' || { echo "unix.socket_path is not in the unit's RuntimeDirectory"; return 1; }
	while IFS= read -r l; do
		case $l in '#'*) continue ;; esac
		case $l in *password* | *secret* | *token* | *private_key* | *PRIVATE*) echo "the config holds '$l'"; return 1 ;; esac
		case $l in *'path: '*) case $l in *'"/var/lib/xkms/'* | *'"/run/xkms/'* | *'"/health"'*) ;; *) echo "'$l' is a path outside the state mount and the run directory"; return 1 ;; esac ;; esac
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
t "the xkmsd build script" build_ok "$ROOT/$build_rel"
# smoke_ok SCRIPT MAKEFILE: the smoke test reads the pin from the recipe, builds
# with the recipe's script, starts the packaged config, checks the read-only
# state dir, and the integration target runs it.
smoke_ok() {
	local s=$1 mk=$2 want
	for want in 'rev=$(val SRCREV)' 'build=$root/platform-image/recipes-security/xkmsd/files/xkmsd-build.sh' \
		'sh "$build" "$src" "$bin" "$pv" "$rev"' 'conf=$root/platform-image/recipes-security/xkmsd/files/xkmsd.yaml' \
		'"$bin" --config "$work/xkmsd.yaml"' 'chmod 0555 "$work/ro/state"' "refuses to start on a read-only state directory"; do
		has "$s" "$want" || { echo "the smoke test lacks '$want'"; return 1; }
	done
	has "$mk" '$(MAKE) --no-print-directory platform-image-xkmsd-smoke' || { echo "integration-test-platform-image does not run the smoke test"; return 1; }
	has "$mk" '@scripts/platform-image-xkmsd-smoke.sh' || { echo "no platform-image-xkmsd-smoke target"; return 1; }
	return 0
}
t "the xkmsd smoke test is wired into the integration target" smoke_ok "$ROOT/scripts/platform-image-xkmsd-smoke.sh" "$ROOT/Makefile"
neg "negative: the smoke test with a pin of its own" smoke_ok "$(printf '%s\n' 'rev=abc' >"$scratch/s1.sh"; printf '%s' "$scratch/s1.sh")" "$ROOT/Makefile"
printf '%s\n' 'x:' '	@scripts/platform-image-xkmsd-smoke.sh' >"$scratch/mk"
neg "negative: the integration target does not run the smoke test" smoke_ok "$ROOT/scripts/platform-image-xkmsd-smoke.sh" "$scratch/mk"

t "the xkmsd state is on the persistent partition and the unit fails closed without it" \
	state_ok "$ROOT/$unit_rel" "$ROOT/$mount_rel" "$ROOT/$wks_rel" "$ROOT/$recipe_rel" "$ROOT/$image_rel"

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
neg "negative: any host" recipe_ok "$(rcopy 'COMPATIBLE_HOST = "aarch64.*-linux"' 'COMPATIBLE_HOST = ".*-linux"' host)"
neg "negative: the recipe's go build command removed" recipe_ok "$(rcopy '    sh "${UNPACKDIR}/xkmsd-build.sh" "${S}" "${B}/xkmsd" "${PV}" "${SRCREV}"' '    true' nobuild)"
neg "negative: the build call only in a comment" recipe_ok "$(rcopy '    sh "${UNPACKDIR}/xkmsd-build.sh"' '    # sh "${UNPACKDIR}/xkmsd-build.sh"' cbuild)"
neg "negative: the build script not in SRC_URI" recipe_ok "$(rcopy 'file://xkmsd-build.sh' 'file://other.sh' nobsrc)"

b0=$(<"$ROOT/$build_rel")
bcopy() { # FROM TO NAME: a copy of the build script with FROM replaced by TO
	printf '%s\n' "${b0//"$1"/"$2"}" >"$scratch/$3.sh"
	printf '%s' "$scratch/$3.sh"
}
neg "negative: GOTOOLCHAIN not local" build_ok "$(bcopy 'export GOTOOLCHAIN=local' 'export GOTOOLCHAIN=auto' tc)"
neg "negative: no go mod verify" build_ok "$(bcopy 'go mod verify' 'true' verify)"
neg "negative: verify only in a comment" build_ok "$(bcopy 'go mod verify' '# go mod verify' cverify)"
neg "negative: the script's go build command removed" build_ok "$(bcopy 'go build -tags' 'true -tags' nogobuild)"
neg "negative: go build of another package" build_ok "$(bcopy './cmd/xkmsd' './cmd/xkms' otherpkg)"
neg "negative: other build tags" build_ok "$(bcopy 'XKMS_TAGS="pkcs8,tpm2,' 'XKMS_TAGS="' tags)"

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

neg "negative: unit without RequiresMountsFor" state_ok "$(ucopy 'RequiresMountsFor=/var/lib/xkms' '' norm)" \
	"$ROOT/$mount_rel" "$ROOT/$wks_rel" "$ROOT/$recipe_rel" "$ROOT/$image_rel"
neg "negative: unit without the mount-point check" state_ok "$(ucopy 'AssertPathIsMountPoint=/var/lib/xkms' '' nomp)" \
	"$ROOT/$mount_rel" "$ROOT/$wks_rel" "$ROOT/$recipe_rel" "$ROOT/$image_rel"
neg "negative: unit without the read-write check" state_ok "$(ucopy 'AssertPathIsReadWrite=/var/lib/xkms' '' norw)" \
	"$ROOT/$mount_rel" "$ROOT/$wks_rel" "$ROOT/$recipe_rel" "$ROOT/$image_rel"
neg "negative: the mount-point check only in a comment" state_ok "$(ucopy 'AssertPathIsMountPoint=/var/lib/xkms' '#AssertPathIsMountPoint=/var/lib/xkms' cmp)" \
	"$ROOT/$mount_rel" "$ROOT/$wks_rel" "$ROOT/$recipe_rel" "$ROOT/$image_rel"
neg "negative: unit not ordered after the mount" state_ok "$(ucopy 'After=var-lib-xkms.mount' '' noafter)" \
	"$ROOT/$mount_rel" "$ROOT/$wks_rel" "$ROOT/$recipe_rel" "$ROOT/$image_rel"
m0=$(<"$ROOT/$mount_rel")
printf '%s\n' "${m0//Options=rw,/Options=ro,}" >"$scratch/ro.mount"
neg "negative: state mounted read-only" state_ok "$ROOT/$unit_rel" "$scratch/ro.mount" "$ROOT/$wks_rel" "$ROOT/$recipe_rel" "$ROOT/$image_rel"
printf '%s\n' "${m0//xkms-state/other}" >"$scratch/label.mount"
neg "negative: state mount of another label" state_ok "$ROOT/$unit_rel" "$scratch/label.mount" "$ROOT/$wks_rel" "$ROOT/$recipe_rel" "$ROOT/$image_rel"
w0=$(<"$ROOT/$wks_rel")
printf '%s\n' "${w0//--label xkms-state/--label data}" >"$scratch/nolabel.wks"
neg "negative: layout without the xkms-state partition" state_ok "$ROOT/$unit_rel" "$ROOT/$mount_rel" "$scratch/nolabel.wks" "$ROOT/$recipe_rel" "$ROOT/$image_rel"
printf '%s\n' "${w0//--label boot --use-uuid/--label boot}" >"$scratch/noboot-uuid.wks"
neg "negative: a mounted /boot partition without a uuid or label mount" state_ok "$ROOT/$unit_rel" "$ROOT/$mount_rel" "$scratch/noboot-uuid.wks" "$ROOT/$recipe_rel" "$ROOT/$image_rel"
printf '%s\n' "${w0//--label root --use-uuid/--label root}" >"$scratch/noroot-uuid.wks"
neg "negative: a mounted / partition without a uuid or label mount" state_ok "$ROOT/$unit_rel" "$ROOT/$mount_rel" "$scratch/noroot-uuid.wks" "$ROOT/$recipe_rel" "$ROOT/$image_rel"
neg "negative: recipe without the mount unit" state_ok "$ROOT/$unit_rel" "$ROOT/$mount_rel" "$ROOT/$wks_rel" "$(rcopy 'file://var-lib-xkms.mount' 'file://x.mount' nomount)" "$ROOT/$image_rel"
i0=$(<"$ROOT/$image_rel")
printf '%s\n' "${i0//WKS_FILE = /X_FILE = }" >"$scratch/nowks.bb"
neg "negative: image without the layout" state_ok "$ROOT/$unit_rel" "$ROOT/$mount_rel" "$ROOT/$wks_rel" "$ROOT/$recipe_rel" "$scratch/nowks.bb"

c0=$(<"$ROOT/$conf_rel")
printf '%s\n' "${c0//\/var\/lib\/xkms/\/tmp\/xkms}" >"$scratch/path.yaml"
neg "negative: config state path elsewhere" config_ok "$scratch/path.yaml"
printf '%s\n' "$c0" 'storage:' '  path: /var/lib/xkms' >"$scratch/unsupported.yaml"
neg "negative: config names a key go-xkms does not take (storage:)" config_ok "$scratch/unsupported.yaml"
printf '%s\n' "${c0//datastore:/datastor:}" >"$scratch/nods.yaml"
neg "negative: config without its datastore section" config_ok "$scratch/nods.yaml"
printf '%s\n' "${c0//\"\/run\/xkms\/xkms.sock\"/\"\/tmp\/xkms.sock\"}" >"$scratch/sock.yaml"
neg "negative: config socket outside /run/xkms" config_ok "$scratch/sock.yaml"
printf '%s\n' "${c0//\"\/var\/lib\/xkms\/keys\/pkcs8\"/\"\/etc\/keys\"}" >"$scratch/keys.yaml"
neg "negative: config key path off the state mount" config_ok "$scratch/keys.yaml"
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

# The smoke script itself (scripts/platform-image-xkmsd-smoke.sh), run on a copy
# of its tree with the fetch, the build and the daemon stubbed: git, go, gcc and
# pkg-config are stubs on PATH, the tree's build script copies a stub daemon, and
# the stub daemon serves a socket, stops on SIGTERM and refuses a read-only state
# directory. The real fetch and build are the integration target's job (make
# platform-image-xkmsd-smoke). A stubbed failure must fail the script, never skip.
smk=$scratch/smk
sx=$smk/platform-image/recipes-security/xkmsd
mkdir -p "$smk/scripts" "$smk/bin" "$sx/files"
cp "$ROOT/scripts/platform-image-xkmsd-smoke.sh" "$smk/scripts/"
cp "$ROOT/$recipe_rel" "$sx/"
cp "$ROOT/$conf_rel" "$sx/files/"
cat >"$smk/bin/git" <<'EOF'
#!/bin/sh
d=.
if [ "$1" = -C ]; then d=$2; shift 2; fi
case $1 in
init) mkdir -p "$d/.git" ;;
fetch) if [ "${FAKE_FETCH:-}" = fail ]; then echo "stub: fetch refused" >&2; exit 128; fi ;;
rev-parse) echo "$FAKE_REV" ;;
esac
EOF
for tool in go gcc pkg-config; do printf '#!/bin/sh\nexit 0\n' >"$smk/bin/$tool"; done
cat >"$sx/files/xkmsd-build.sh" <<'EOF'
#!/bin/sh
if [ "${FAKE_BUILD:-}" = fail ]; then echo "stub: build failed" >&2; exit 1; fi
cp "$FAKE_DAEMON_SRC" "$2"
chmod +x "$2"
EOF
cat >"$smk/fake-xkmsd.py" <<'EOF'
#!/usr/bin/env python3
import os, re, socket, sys, time
if "-version" in sys.argv:
    print("xkmsd " + os.environ["FAKE_PV"])
    sys.exit(0)
cfg = open(sys.argv[sys.argv.index("--config") + 1]).read()
state = os.path.dirname(re.search(r'datastore:.*?path: "([^"]+)"', cfg, re.S).group(1))
sock = re.search(r'socket_path: "([^"]+)"', cfg).group(1)
mode = os.environ.get("FAKE_DAEMON", "")
if mode == "noready":
    print("stub: never ready")
    sys.exit(1)
if not os.access(state, os.W_OK):
    if mode == "ignore-ro":
        sys.exit(0)
    print("stub: the state directory is read-only")
    sys.exit(1)
s = socket.socket(socket.AF_UNIX)
s.bind(sock)
s.listen(1)
print("Unix socket server started", flush=True)
while True:
    time.sleep(1)
EOF
chmod +x "$smk/bin/"* "$sx/files/xkmsd-build.sh" "$smk/fake-xkmsd.py"
spv=$(val "$ROOT/$recipe_rel" PV)
srev=$(val "$ROOT/$recipe_rel" SRCREV)
# smoke_run NAME [VAR=value...]: the copied script with a cache of its own.
smoke_run() {
	local name=$1
	shift
	run env PATH="$smk/bin:$PATH" XKMSD_SMOKE_REPO=file:///stub \
		XKMSD_SMOKE_CACHE="$scratch/cache-$name" FAKE_REV="$srev" FAKE_PV="$spv" \
		FAKE_DAEMON_SRC="$smk/fake-xkmsd.py" "$@" \
		bash "$smk/scripts/platform-image-xkmsd-smoke.sh"
}
if [ "$(id -u)" = 0 ]; then
	fail "the smoke script runs under stubs" "run as a non-root user: the script refuses root"
else
	smoke_run clean
	check "smoke: a stubbed clean build-and-start passes" 0 "xkmsd-smoke: all passed" \
		"ok   xkmsd reaches its ready state" "ok   xkmsd stops on SIGTERM" \
		"ok   xkmsd refuses to start on a read-only state directory"
	smoke_run fetch FAKE_FETCH=fail
	check "smoke: a failed fetch fails, it does not skip" nonzero "FAIL: cannot fetch go-xkms $srev"
	smoke_run build FAKE_BUILD=fail
	check "smoke: a failed build fails, it does not skip" nonzero "FAIL: the recipe's build script failed"
	smoke_run noready FAKE_DAEMON=noready
	check "smoke: a daemon that never gets ready fails" nonzero "FAIL: xkmsd did not reach its ready state"
	smoke_run ro FAKE_DAEMON=ignore-ro
	check "smoke: a daemon that starts on a read-only state directory fails" nonzero \
		"FAIL: xkmsd exited 0 on a read-only state directory"
fi

finish
