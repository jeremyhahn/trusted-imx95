# Access rule for the secure-enclave device node: one udev rule and one system
# group. Requirement R6 (docs/hsm-device-protocol/xkmsd-node.md section 3) is
# proposed, pending owner approval; this recipe is the lane's proposed default
# and changes if the owner decides otherwise. Sources:
# docs/hsm-device-protocol/enclave-interface-trace.md (a) (the driver sets no
# mode on the node) and docs/hsm-device-protocol/local-seam-trace.md (d).
#
# It creates the group only: no user, no login, no home and no service unit.
# xkmsd and its unit are go-xkms's recipe, which does not exist yet.
SUMMARY = "udev rule reserving the enclave node for the xkmsd group (proposed, pending owner approval)"
# MISSING: no survey names a license for image configuration; documentation only.
LICENSE = "CLOSED"

SRC_URI = "file://90-enclave-access.rules"
S = "${UNPACKDIR}"

inherit useradd allarch

USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system xkmsd"

do_install() {
    install -d ${D}${nonarch_base_libdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/90-enclave-access.rules ${D}${nonarch_base_libdir}/udev/rules.d/
}

FILES:${PN} = "${nonarch_base_libdir}/udev/rules.d/90-enclave-access.rules"
