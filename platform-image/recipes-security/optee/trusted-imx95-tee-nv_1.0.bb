SUMMARY = "Persistent storage and start-up of tee-supplicant for the fTPM NV (provisional)"
# SPEC row ftpm, issue #140. Provisional, pending the owner's answers in
# docs/ftpm/README.md. The fTPM's NV lives in OP-TEE's REE file system, which
# tee-supplicant keeps under /data/tee. The root file system is read-only, so
# /data is its own partition (platform-image/files/wic/trusted-imx95.wks, GPT name
# tee-data), mounted before tee-supplicant starts. No key is stored here.
# The NV is kept on tee-data when the root partition is rewritten; a full-image
# flash recreates tee-data empty and so erases it (owner, 2026-11-25).
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

SRC_URI = "file://tee-data-mount \
           file://tee-data-mount.service \
           file://10-nv.conf \
           file://tee-supplicant \
           file://trusted-imx95-tpm.target \
          "

inherit systemd

RDEPENDS:${PN} = "optee-client"

do_install() {
    # Mountpoint of /data; the root file system is read-only. The tee-data partition of
    # the disk holding / is mounted there by tee-data-mount.service (not by a global
    # by-partlabel path, which can name another medium's partition).
    install -d ${D}/data
    install -d ${D}${systemd_system_unitdir}
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/tee-data-mount ${D}${sbindir}/tee-data-mount
    install -m 0644 ${UNPACKDIR}/tee-data-mount.service ${D}${systemd_system_unitdir}/tee-data-mount.service
    install -d ${D}${systemd_system_unitdir}/tee-supplicant@.service.d
    install -m 0644 ${UNPACKDIR}/10-nv.conf ${D}${systemd_system_unitdir}/tee-supplicant@.service.d/10-nv.conf
    install -d ${D}${sysconfdir}/default
    install -m 0644 ${UNPACKDIR}/tee-supplicant ${D}${sysconfdir}/default/tee-supplicant
    # Enable the supplicant (one instance, name unused by the unit) at boot.
    install -d ${D}${sysconfdir}/systemd/system/basic.target.wants
    ln -sf ${systemd_system_unitdir}/tee-supplicant@.service \
        ${D}${sysconfdir}/systemd/system/basic.target.wants/tee-supplicant@teepriv0.service
    # The ordering point for TPM users: waits for dev-tpmrm0.device, after the supplicant.
    install -m 0644 ${UNPACKDIR}/trusted-imx95-tpm.target ${D}${systemd_system_unitdir}/trusted-imx95-tpm.target
    install -d ${D}${sysconfdir}/systemd/system/multi-user.target.wants
    ln -sf ${systemd_system_unitdir}/trusted-imx95-tpm.target \
        ${D}${sysconfdir}/systemd/system/multi-user.target.wants/trusted-imx95-tpm.target
}

FILES:${PN} += "/data ${sbindir}/tee-data-mount ${systemd_system_unitdir} ${sysconfdir}/systemd/system ${sysconfdir}/default"
