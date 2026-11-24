# xkmsd, go-xkms's key management daemon, for the Linux side of the
# FRDM-IMX95-PRO (docs/SPEC.md, Features, `platform-image`: "It runs xkmsd
# from go-xkms on its Linux side"). Consumed as a tagged go-xkms release only:
# no copied code, no replace directive, no branch pin
# (docs/hsm-device-protocol/xkmsd-node.md, "How xkmsd is consumed"). The owner
# keeps the board on the latest go-xkms release (2026-11-24): raise the tag,
# SRCREV and PV together when go-xkms tags a newer one.
#
# This recipe installs the binary, the xkmsd system user, its systemd unit
# (enabled, sandboxed; files/xkmsd.service) and its default configuration
# (files/xkmsd.yaml, /etc/xkms/xkmsd.yaml, the path go-xkms's own unit reads).
# The xkmsd group is the one the enclave-access recipe (R6, proposed) names;
# useradd skips a group or user that already exists.
SUMMARY = "xkmsd from go-xkms ${XKMS_TAG}, built with the Go toolchain its go.mod asks for"
HOMEPAGE = "https://github.com/jeremyhahn/go-xkms"
# go-xkms is AGPL-3.0 (its LICENSE) with a commercial alternative
# (LICENSE-COMMERCIAL.md); the image takes it under the AGPL.
LICENSE = "AGPL-3.0-only"
LIC_FILES_CHKSUM = "file://LICENSE;md5=3db23ab95801691a1b98ff9ddb8dc98b"

# The release: the tag and the commit it peels to, read with git ls-remote on
# 2026-11-24. PV is the tag without its v.
XKMS_TAG = "v0.64.2-alpha"
SRCREV = "9f040cea0e06a2afd3233d0e669885249f49c4c2"
PV = "0.64.2-alpha"

# The Go toolchain. go-xkms's go.mod at the tag says `go 1.27.3`; the pinned
# OE-core (platform-image/manifest.lock) ships Go 1.26.4, too old to build it.
# The recipe takes go.dev's release archive for the build host instead, checked
# by the sha256 go.dev publishes (read 2026-11-24), and cross-compiles with it.
# The archive is for an x86_64 build host only.
XKMS_GO_VERSION = "1.27.3"

SRC_URI = "git://github.com/jeremyhahn/go-xkms;protocol=https;nobranch=1;tag=${XKMS_TAG};destsuffix=go-xkms \
           https://go.dev/dl/go${XKMS_GO_VERSION}.linux-amd64.tar.gz;name=go;subdir=go-toolchain \
           file://xkmsd.service \
           file://xkmsd.yaml"
SRC_URI[go.sha256sum] = "65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40"

S = "${UNPACKDIR}/go-xkms"

# The board's Cortex-A55 side is aarch64 Linux.
COMPATIBLE_HOST = "aarch64.*-linux"

# CGO links PKCS#11 (modules are dlopen()ed at run time) and gousb's libusb,
# as go-xkms's own server build does (its Dockerfile.server).
DEPENDS = "libusb1"
inherit pkgconfig useradd systemd

# The service account: a system user without a login shell or a home of its
# own; its state is the unit's StateDirectory.
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system xkmsd"
USERADD_PARAM:${PN} = "--system --gid xkmsd --home-dir /var/lib/xkms --no-create-home --shell /sbin/nologin xkmsd"

# The unit starts at boot.
SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "xkmsd.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# The build tags of go-xkms's own server build (Dockerfile.server).
XKMS_TAGS = "pkcs8,tpm2,awskms,gcpkms,azurekv,vault,pkcs11"

# Provisional: the Go modules are downloaded in do_compile and checked by
# `go mod verify` against go.sum at the pinned commit. A module list in
# SRC_URI, so the build runs with BB_NO_NETWORK, is open (docs/platform-image/build.md).
do_compile[network] = "1"

do_compile() {
    [ "${BUILD_ARCH}" = "x86_64" ] || bbfatal "xkmsd: the Go ${XKMS_GO_VERSION} archive in SRC_URI is for an x86_64 build host, not ${BUILD_ARCH}"
    export GOROOT="${UNPACKDIR}/go-toolchain/go"
    export PATH="${GOROOT}/bin:${PATH}"
    # Never let go fetch another toolchain than the pinned one.
    export GOTOOLCHAIN=local
    export GOPATH="${B}/gopath" GOCACHE="${B}/gocache" GOMODCACHE="${B}/gomodcache"
    export GOFLAGS="-mod=readonly -modcacherw -trimpath -buildvcs=false"
    export GOOS=linux GOARCH=arm64 CGO_ENABLED=1
    export CC="${CC}" CGO_CFLAGS="${CFLAGS}" CGO_LDFLAGS="${LDFLAGS}"
    cd "${S}"
    go mod download
    go mod verify
    go build -tags "${XKMS_TAGS}" \
        -ldflags "-X main.version=${PV} -X main.commit=${SRCREV}" \
        -o "${B}/xkmsd" ./cmd/xkmsd
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/xkmsd ${D}${bindir}/xkmsd
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/xkmsd.service ${D}${systemd_system_unitdir}/xkmsd.service
    # Root owns the configuration; the xkmsd group may read it, nobody else.
    install -d -m 0750 -g xkmsd ${D}${sysconfdir}/xkms
    install -m 0640 -g xkmsd ${UNPACKDIR}/xkmsd.yaml ${D}${sysconfdir}/xkms/xkmsd.yaml
}

FILES:${PN} = "${bindir}/xkmsd ${systemd_system_unitdir}/xkmsd.service ${sysconfdir}/xkms"
CONFFILES:${PN} = "${sysconfdir}/xkms/xkmsd.yaml"
# Go links its own runtime: no GNU_HASH in its ELF, and its build ID is Go's.
INSANE_SKIP:${PN} = "ldflags"
