SUMMARY = "Persistent storage and start-up of tee-supplicant for the fTPM NV (provisional)"
# SPEC row ftpm, issue #140. Provisional, pending the owner's answers in
# docs/ftpm/README.md. The fTPM's NV lives in OP-TEE's REE file system, which
# tee-supplicant keeps under /data/tee. The root file system is read-only, so
# /data is its own partition (platform-image/files/wic/trusted-imx95.wks, GPT name
# tee-data), mounted before tee-supplicant starts. No key is stored here.
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

SRC_URI = "file://data.mount \
           file://10-nv.conf \
           file://tee-supplicant \
          "

inherit systemd

RDEPENDS:${PN} = "optee-client"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/data.mount ${D}${systemd_system_unitdir}/data.mount
    install -d ${D}${systemd_system_unitdir}/tee-supplicant@.service.d
    install -m 0644 ${UNPACKDIR}/10-nv.conf ${D}${systemd_system_unitdir}/tee-supplicant@.service.d/10-nv.conf
    install -d ${D}${sysconfdir}/default
    install -m 0644 ${UNPACKDIR}/tee-supplicant ${D}${sysconfdir}/default/tee-supplicant
    # Enable the supplicant (one instance, name unused by the unit) at boot.
    install -d ${D}${sysconfdir}/systemd/system/basic.target.wants
    ln -sf ${systemd_system_unitdir}/tee-supplicant@.service \
        ${D}${sysconfdir}/systemd/system/basic.target.wants/tee-supplicant@teepriv0.service
}

FILES:${PN} += "${systemd_system_unitdir} ${sysconfdir}/systemd/system ${sysconfdir}/default"
