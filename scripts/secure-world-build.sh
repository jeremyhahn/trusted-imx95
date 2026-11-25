#!/usr/bin/env bash
# secure-world-build.sh [--lock FILE] [--work DIR] [--out DIR] [--cache DIR]
#                       [--jobs N] [--check-lock]
#
# `make secure-world`: builds the Cortex-A secure world from the pins in
# secure-world/bsp.lock (docs/secure-world/build.md): TF-A BL31 for i.MX 95
# with the OP-TEE dispatcher, and OP-TEE OS with the fTPM TA and the PKCS#11
# TA linked in as early TAs, secure storage as TRUSTED_IMX95_FTPM_NV selects
# (reefs by default; the flag sets are the platform image's
# optee-ftpm-flags.inc, owner ruling 1234). It writes
# bl31.bin, tee.bin, SHA256SUMS and build-info.txt to the output directory.
#
# The build runs twice, each in its own clean directory under the work
# directory, and the artefacts are published only if bl31.bin and tee.bin are
# byte-identical (SHA-256) between the two; otherwise it fails naming the
# artefact and both hashes. SHA256SUMS holds the agreed hashes.
#
# Every source is fetched at its pinned commit and checked; the toolchain
# tarball and the Python wheels are checked against their pinned SHA-256.
# The work directory is created fresh on each run, so each build starts from
# a clean tree. SOURCE_DATE_EPOCH, when unset, is the pinned OP-TEE commit's
# committer time.
#
# --check-lock parses and checks the lock file and exits: offline, no build.
#
# The TAs are signed with the upstream OP-TEE default test key that the
# fetched optee_os tree carries (keys/default_ta.pem). No key is read from
# or written to this repository. Nothing is flashed; RPMB and fuses are not
# touched.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
lock=$root/secure-world/bsp.lock
# The sources and build trees stay outside the checkout: the tree secret scan
# reads every file under it, and the fetched trees carry test keys.
base=${XDG_CACHE_HOME:-${HOME:?HOME is unset}/.cache}/trusted-imx95/secure-world
work=$base/work
out=$root/.secure-world/out
cache=$base/cache
jobs=$(nproc 2>/dev/null || echo 4)
check_only=0
single=0 # internal: one build, run by the two-build driver below

die() {
	echo "secure-world-build: $*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--lock) lock=${2:?--lock needs a file} && shift 2 ;;
	--work) work=${2:?--work needs a directory} && shift 2 ;;
	--out) out=${2:?--out needs a directory} && shift 2 ;;
	--cache) cache=${2:?--cache needs a directory} && shift 2 ;;
	--jobs) jobs=${2:?--jobs needs a number} && shift 2 ;;
	--check-lock) check_only=1 && shift ;;
	--single) single=1 && shift ;;
	-h | --help)
		echo "usage: secure-world-build.sh [--lock FILE] [--work DIR] [--out DIR] [--cache DIR] [--jobs N] [--check-lock]"
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive number, not $jobs"

# --- The lock file -----------------------------------------------------------

declare -A pin=()
wheels=()
names=" LF_RELEASE MANIFEST_REPO MANIFEST_COMMIT META_IMX_REPO META_IMX_COMMIT TFA_REPO TFA_TAG TFA_COMMIT TFA_PLAT OPTEE_REPO OPTEE_COMMIT OPTEE_PLATFORM FTPM_REPO FTPM_COMMIT MSTPM_REPO MSTPM_COMMIT TOOLCHAIN_VERSION TOOLCHAIN_URL TOOLCHAIN_SHA256 "

[ -f "$lock" ] || die "$lock: no such lock file"
n=0
while IFS= read -r line || [ -n "$line" ]; do
	n=$((n + 1))
	case "$line" in '' | '#'*) continue ;; esac
	[[ "$line" =~ ^([A-Z0-9_]+)=(.+)$ ]] || die "$lock:$n: not NAME=value: $line"
	name=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
	[ "$value" != UNREAD ] || die "$lock:$n: $name is marked UNREAD; read it from its source before building"
	if [ "$name" = PYWHEEL ]; then
		[[ "$value" =~ ^[A-Za-z0-9_.-]+==[A-Za-z0-9_.+-]+@sha256:[0-9a-f]{64}$ ]] ||
			die "$lock:$n: PYWHEEL must be <name>==<version>@sha256:<64 hex>, not $value"
		wheels+=("$value")
		continue
	fi
	case "$names" in *" $name "*) ;; *) die "$lock:$n: unknown name $name" ;; esac
	[ -z "${pin[$name]+set}" ] || die "$lock:$n: $name is set twice"
	case "$name" in
	*_COMMIT) [[ "$value" =~ ^[0-9a-f]{40}$ ]] || die "$lock:$n: $name must be a 40-hex commit, not $value" ;;
	*_SHA256) [[ "$value" =~ ^[0-9a-f]{64}$ ]] || die "$lock:$n: $name must be a 64-hex SHA-256, not $value" ;;
	*_REPO | *_URL) [[ "$value" =~ ^https://[A-Za-z0-9./_-]+$ ]] || die "$lock:$n: $name must be an https URL, not $value" ;;
	*) [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || die "$lock:$n: $name has characters outside [A-Za-z0-9._-]: $value" ;;
	esac
	pin[$name]=$value
done <"$lock"
for name in $names; do
	[ -n "${pin[$name]+set}" ] || die "$lock: $name is missing"
done
[ "${#wheels[@]}" -gt 0 ] || die "$lock: no PYWHEEL line"

# Owner ruling 771 (docs/SPEC.md, secure-world row): BL31 is upstream Arm
# TF-A at a tagged release, never NXP's imx-atf fork; OP-TEE OS is NXP's BSP
# OP-TEE. The lock may name nothing else.
case "${pin[TFA_REPO]}" in
https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git | https://github.com/ARM-software/arm-trusted-firmware.git) ;;
*) die "$lock: TFA_REPO ${pin[TFA_REPO]} is not upstream Arm TF-A (owner ruling 771: upstream TF-A, not NXP's imx-atf)" ;;
esac
[[ "${pin[TFA_TAG]}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
	die "$lock: TFA_TAG ${pin[TFA_TAG]} is not an upstream release tag vX.Y.Z (owner ruling 771)"
[ "${pin[OPTEE_REPO]}" = https://github.com/nxp-imx/imx-optee-os.git ] ||
	die "$lock: OPTEE_REPO ${pin[OPTEE_REPO]} is not NXP's BSP OP-TEE, https://github.com/nxp-imx/imx-optee-os.git (owner ruling 771)"

# --- The fTPM NV storage -------------------------------------------------------
# One selector for the platform image and this build (owner ruling 1234):
# TRUSTED_IMX95_FTPM_NV, reefs or rpmb, its default the platform image's. The
# OP-TEE flag set of each value is read from optee-ftpm-flags.inc and the fTPM
# TA's storage ID from the optee-ftpm recipe, so the tee.bin the boot container
# ships selects the same storage as the image's OP-TEE.
nv_inc=$root/platform-image/recipes-security/optee/optee-ftpm-flags.inc
nv_bb=$root/platform-image/recipes-security/optee/optee-ftpm_4.10.0.bb
# nv_value <file> <name>: the quoted value of the line `name = "..."` or
# `name ?= "..."`.
nv_value() {
	local l
	[ -f "$1" ] || die "$1: no such file"
	while IFS= read -r l || [ -n "$l" ]; do
		if [[ "$l" == "$2 = \""*\" || "$l" == "$2 ?= \""*\" ]]; then
			l=${l#*\"}
			printf '%s\n' "${l%\"}"
			return 0
		fi
	done <"$1"
	return 1
}
# conf_nv <file>: the last TRUSTED_IMX95_FTPM_NV assignment of a BitBake conf
# file that overrides the recipe default (=, := or ?=), or nothing.
conf_nv() {
	local l v='' re='^[[:space:]]*(export[[:space:]]+)?TRUSTED_IMX95_FTPM_NV[[:space:]]*(:=|\?=|=)[[:space:]]*"([^"]*)"'
	[ -f "$1" ] || return 0
	while IFS= read -r l || [ -n "$l" ]; do
		if [[ "$l" =~ $re ]]; then v=${BASH_REMATCH[3]}; fi
	done <"$1"
	printf '%s' "$v"
}
# The image build's own configuration is a second place the selection can be
# made: the local.conf template and the conf/*.conf of the build directory
# (platform-image-build.sh passes the same environment variable to bitbake and
# refuses a bitbake that uses another value). A selection there that differs from
# the environment's, or from another file's, fails here: the tee.bin of the boot
# container and the image's OP-TEE must use the same storage.
nv_env=${TRUSTED_IMX95_FTPM_NV:-}
nv_conf=
nv_conf_src=
pi_build_conf=${PLATFORM_IMAGE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/trusted-imx95/platform-image}/build/conf
for f in "$root/platform-image/conf/local.conf.template" "$pi_build_conf"/*.conf; do
	[ -f "$f" ] || continue
	v=$(conf_nv "$f")
	[ -n "$v" ] || continue
	if [ -n "$nv_conf" ] && [ "$v" != "$nv_conf" ]; then
		die "the fTPM NV backends disagree: TRUSTED_IMX95_FTPM_NV is '$v' in $f but '$nv_conf' in $nv_conf_src; make them equal"
	fi
	nv_conf=$v
	nv_conf_src=$f
done
if [ -n "$nv_env" ] && [ -n "$nv_conf" ] && [ "$nv_env" != "$nv_conf" ]; then
	die "the fTPM NV backends disagree: TRUSTED_IMX95_FTPM_NV is '$nv_env' in the environment (this build) but '$nv_conf' in $nv_conf_src (bitbake's image build); make them equal"
fi
nv=${nv_env:-${nv_conf:-$(nv_value "$nv_inc" TRUSTED_IMX95_FTPM_NV || true)}}
{ [[ "$nv" =~ ^[a-z]+$ ]] &&
	nv_set=$(nv_value "$nv_inc" "TRUSTED_IMX95_FTPM_NV_FLAGS[$nv]") &&
	nv_sid=$(nv_value "$nv_bb" "FTPM_TA_STORAGE_ID[$nv]"); } ||
	die "TRUSTED_IMX95_FTPM_NV must be reefs or rpmb, not $nv (the sets of $nv_inc and $nv_bb)"
[[ "$nv_set" =~ ^[A-Z0-9_]+=[a-z0-9]+(\ [A-Z0-9_]+=[a-z0-9]+)*$ ]] ||
	die "$nv_inc: the $nv flag set is not NAME=value words: $nv_set"
[[ "$nv_sid" =~ ^TEE_STORAGE_PRIVATE_[A-Z]+$ ]] ||
	die "$nv_bb: the $nv storage ID is not TEE_STORAGE_PRIVATE_*: $nv_sid"
read -ra nv_flags <<<"$nv_set"

if [ "$check_only" = 1 ]; then
	echo "secure-world-build: $lock OK (${pin[LF_RELEASE]}, TF-A ${pin[TFA_TAG]} ${pin[TFA_COMMIT]:0:12}, OP-TEE ${pin[OPTEE_COMMIT]:0:12}, fTPM ${pin[FTPM_COMMIT]:0:12}, toolchain ${pin[TOOLCHAIN_VERSION]})"
	exit 0
fi

# --- The host ----------------------------------------------------------------

[ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] ||
	die "the pinned toolchain is an x86_64 Linux build, this host is $(uname -s)-$(uname -m)"
for tool in git curl make tar xz sha256sum python3 uv; do
	command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done

# A fresh work directory each run: one this script made earlier (it holds the
# marker) is removed; any other non-empty directory is refused.
marker=.secure-world-build-work
if [ -e "$work" ]; then
	[ -d "$work" ] || die "--work $work is not a directory"
	if [ -e "$work/$marker" ]; then
		rm -rf "$work"
	elif [ -n "$(ls -A "$work")" ]; then
		die "--work $work is not empty and was not made by this script; name an empty or new directory"
	fi
fi
mkdir -p "$work" "$out" "$cache"
work=$(cd "$work" && pwd -P)
out=$(cd "$out" && pwd -P)
cache=$(cd "$cache" && pwd -P)
: >"$work/$marker"

# --- Twice, and compared ------------------------------------------------------
# Without --single this run is the driver: it runs this script twice in
# separate, clean build directories (work/build-1, work/build-2), compares
# bl31.bin and tee.bin byte for byte by SHA-256 and publishes only when both
# builds agree. A difference fails naming the artefact and both SHA-256s.
if [ "$single" = 0 ]; then
	for i in 1 2; do
		echo "secure-world-build: clean build $i of 2"
		bash "${BASH_SOURCE[0]}" --single --lock "$lock" --work "$work/build-$i" \
			--out "$work/out-$i" --cache "$cache" --jobs "$jobs" || die "build $i of 2 failed; nothing published"
	done
	differ=0
	for f in bl31.bin tee.bin; do
		h1=$(sha256sum <"$work/out-1/$f" | cut -d' ' -f1)
		h2=$(sha256sum <"$work/out-2/$f" | cut -d' ' -f1)
		echo "secure-world-build: $f build 1 $h1, build 2 $h2"
		if [ "$h1" != "$h2" ]; then
			echo "secure-world-build: $f differs: build 1 $h1, build 2 $h2" >&2
			differ=1
		fi
	done
	[ "$differ" = 0 ] || die "not reproducible: the two clean builds differ; nothing published"
	cp "$work/out-1/bl31.bin" "$work/out-1/tee.bin" "$work/out-1/SHA256SUMS" "$work/out-1/build-info.txt" "$out/"
	(cd "$out" && sha256sum -c --quiet SHA256SUMS) || die "SHA256SUMS does not verify in $out"
	{
		echo "reproducible: yes, two clean builds byte-identical (docs/secure-world/build.md#reproducibility)"
		echo "bl31.bin sha256 (both builds): $(sha256sum <"$out/bl31.bin" | cut -d' ' -f1)"
		echo "tee.bin sha256 (both builds): $(sha256sum <"$out/tee.bin" | cut -d' ' -f1)"
	} >>"$out/build-info.txt"
	echo "secure-world-build: reproducible, two clean builds identical, $out:"
	cat "$out/SHA256SUMS"
	exit 0
fi

logs=$work/logs
mkdir -p "$logs"

start=$(date +%s)
# step <name> <command...>: runs the command with its output in logs/<name>.log;
# on failure prints the log's tail and stops.
step() {
	local name=$1 t0
	shift
	t0=$(date +%s)
	echo "secure-world-build: $name"
	if ! "$@" >"$logs/$name.log" 2>&1; then
		tail -n 30 "$logs/$name.log" >&2
		die "$name failed; full log: $logs/$name.log"
	fi
	echo "secure-world-build: $name done ($(($(date +%s) - t0)) s)"
}

# --- The pinned inputs -------------------------------------------------------

tarball=$cache/${pin[TOOLCHAIN_URL]##*/}
fetch_toolchain() {
	if [ -f "$tarball" ] && [ "$(sha256sum "$tarball" | cut -d' ' -f1)" = "${pin[TOOLCHAIN_SHA256]}" ]; then
		echo "cached $tarball"
	else
		curl -fsSL --retry 3 -o "$tarball.part" "${pin[TOOLCHAIN_URL]}"
		got=$(sha256sum "$tarball.part" | cut -d' ' -f1)
		[ "$got" = "${pin[TOOLCHAIN_SHA256]}" ] || {
			rm -f "$tarball.part"
			echo "toolchain SHA-256 $got, pinned ${pin[TOOLCHAIN_SHA256]}"
			return 1
		}
		mv "$tarball.part" "$tarball"
	fi
	mkdir -p "$work/toolchain"
	tar -xJf "$tarball" -C "$work/toolchain" --strip-components=1
}
step toolchain fetch_toolchain
cross=$work/toolchain/bin/aarch64-none-linux-gnu-
[ -x "${cross}gcc" ] || die "the toolchain tarball has no bin/aarch64-none-linux-gnu-gcc"

python_env() {
	local w
	: >"$work/requirements.txt"
	for w in "${wheels[@]}"; do
		printf '%s --hash=sha256:%s\n' "${w%@sha256:*}" "${w##*@sha256:}" >>"$work/requirements.txt"
	done
	UV_CACHE_DIR=$cache/uv uv venv -q -p "$(command -v python3)" "$work/venv"
	VIRTUAL_ENV=$work/venv UV_CACHE_DIR=$cache/uv uv pip install -q --require-hashes --only-binary :all: \
		-r "$work/requirements.txt"
}
step python python_env

# fetch_src <dir> <repo> <commit>: the one commit, nothing else, checked.
fetch_src() {
	local dir=$work/src/$1
	git init -q "$dir"
	git -C "$dir" fetch -q --depth 1 "$2" "$3"
	git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
	[ "$(git -C "$dir" rev-parse HEAD)" = "$3" ] || {
		echo "$1: fetched $(git -C "$dir" rev-parse HEAD), pinned $3"
		return 1
	}
}
step src-tfa fetch_src tfa "${pin[TFA_REPO]}" "${pin[TFA_COMMIT]}"
# tfa_tag: the release tag, fetched from the same upstream, peels to the pin.
tfa_tag() {
	local dir=$work/src/tfa got
	git -C "$dir" fetch -q --depth 1 "${pin[TFA_REPO]}" "refs/tags/${pin[TFA_TAG]}"
	got=$(git -C "$dir" rev-parse "FETCH_HEAD^{commit}")
	[ "$got" = "${pin[TFA_COMMIT]}" ] || {
		echo "tag ${pin[TFA_TAG]} peels to $got, pinned TFA_COMMIT ${pin[TFA_COMMIT]}"
		return 1
	}
}
step tfa-tag tfa_tag
step src-optee fetch_src optee "${pin[OPTEE_REPO]}" "${pin[OPTEE_COMMIT]}"
step src-ftpm fetch_src ftpm "${pin[FTPM_REPO]}" "${pin[FTPM_COMMIT]}"
step src-mstpm fetch_src mstpm "${pin[MSTPM_REPO]}" "${pin[MSTPM_COMMIT]}"

# --- The build ---------------------------------------------------------------

export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$work/src/optee" log -1 --format=%ct)}
export PATH=$work/venv/bin:$PATH
export LC_ALL=C TZ=UTC
src=$work/src
bld=$work/build
ftpm_uuid=bc50d971-d4c9-42c4-82cb-343fb7f37896
pkcs11_uuid=fd02c9da-306c-48c7-a49c-bbd827ae86ee

# TF-A BL31, release build, with the OP-TEE dispatcher (SPD=opteed), as the
# upstream platform imx95 (plat/imx/imx9/imx95) builds it with OP-TEE.
step bl31 make -C "$src/tfa" -j"$jobs" BUILD_BASE="$bld/tfa" CROSS_COMPILE="$cross" \
	PLAT="${pin[TFA_PLAT]}" SPD=opteed bl31

# OP-TEE's flags: the release recipe's log levels, the secure storage of the
# TRUSTED_IMX95_FTPM_NV selection (above), the PKCS#11 TA, and both TAs early. Both
# required TAs are early TAs, so loading TAs from the REE file system is off
# (CFG_REE_FS_TA=n): the public default TA key then trusts nothing.
optee_flags=(
	PLATFORM="${pin[OPTEE_PLATFORM]}" CFG_ARM64_core=y
	CROSS_COMPILE="$cross" CROSS_COMPILE64="$cross"
	CFG_TEE_CORE_LOG_LEVEL=0 CFG_TEE_TA_LOG_LEVEL=0
	"${nv_flags[@]}"
	CFG_REE_FS_TA=n CFG_SECSTOR_TA_MGMT_PTA=n
	CFG_PKCS11_TA=y
)
# The TA dev kit the fTPM TA builds against.
step optee-devkit make -C "$src/optee" -j"$jobs" O="$bld/optee-devkit" "${optee_flags[@]}" ta_dev_kit
# The fTPM TA, its NV in the storage of the TRUSTED_IMX95_FTPM_NV selection.
step ftpm make -C "$src/ftpm" -j"$jobs" O="$bld/ftpm" CROSS_COMPILE="$cross" \
	TA_DEV_KIT_DIR="$bld/optee-devkit/export-ta_arm64" CFG_MS_TPM_20_REF="$src/mstpm" \
	CFG_FTPM_TA_TEE_STORAGE_ID="$nv_sid" CFG_TEE_TA_LOG_LEVEL=0
# OP-TEE OS with the fTPM TA and the in-tree PKCS#11 TA linked in as early TAs.
step optee make -C "$src/optee" -j"$jobs" O="$bld/optee" "${optee_flags[@]}" \
	CFG_EARLY_TA=y EARLY_TA_PATHS="$bld/ftpm/$ftpm_uuid.stripped.elf" \
	CFG_IN_TREE_EARLY_TAS="pkcs11/$pkcs11_uuid" all

# --- The artefacts -----------------------------------------------------------

# Staged and checked first: nothing reaches $out unless every copy hashes the
# same as its build output.
stage=$work/stage
mkdir -p "$stage"
cp "$bld/tfa/${pin[TFA_PLAT]}/release/bl31.bin" "$stage/bl31.bin"
cp "$bld/optee/core/tee-raw.bin" "$stage/tee.bin"
[ "$(sha256sum <"$stage/bl31.bin")" = "$(sha256sum <"$bld/tfa/${pin[TFA_PLAT]}/release/bl31.bin")" ] ||
	die "bl31.bin: the staged artefact's SHA-256 differs from the build output; nothing published"
[ "$(sha256sum <"$stage/tee.bin")" = "$(sha256sum <"$bld/optee/core/tee-raw.bin")" ] ||
	die "tee.bin: the staged artefact's SHA-256 differs from the build output; nothing published"
(cd "$stage" && sha256sum bl31.bin tee.bin >SHA256SUMS)
(cd "$stage" && sha256sum -c --quiet SHA256SUMS) || die "SHA256SUMS does not verify; nothing published"
cp "$stage/bl31.bin" "$stage/tee.bin" "$stage/SHA256SUMS" "$out/"
{
	echo "lock: $(sha256sum "$lock" | cut -d' ' -f1)"
	echo "release: ${pin[LF_RELEASE]} (provisional, #14 Q2)"
	echo "tfa: ${pin[TFA_COMMIT]} tag ${pin[TFA_TAG]} PLAT=${pin[TFA_PLAT]} SPD=opteed"
	echo "optee: ${pin[OPTEE_COMMIT]} ${optee_flags[*]//CROSS_COMPILE*=*/} CFG_EARLY_TA=y early TAs $ftpm_uuid (fTPM) $pkcs11_uuid (PKCS#11)"
	echo "ftpm: ${pin[FTPM_COMMIT]} ms-tpm-20-ref ${pin[MSTPM_COMMIT]} storage $nv_sid"
	echo "ftpm-nv: $nv (TRUSTED_IMX95_FTPM_NV; ${nv_flags[*]})"
	echo "toolchain: $("${cross}gcc" --version | head -n 1)"
	echo "ta-signing: upstream OP-TEE default test key (keys/default_ta.pem in the fetched optee_os); REE FS TAs are rejected (CFG_REE_FS_TA=n)"
	echo "SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH"
} >"$out/build-info.txt"
echo "secure-world-build: OK in $(($(date +%s) - start)) s, $out:"
cat "$out/SHA256SUMS"
