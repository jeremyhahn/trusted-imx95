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
           file://tee-nv-wipe \
           file://tee-nv-wipe.service \
          "

inherit systemd

RDEPENDS:${PN} = "optee-client"

do_install() {
    # Mountpoint of data.mount; the root file system is read-only.
    install -d ${D}/data
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/data.mount ${D}${systemd_system_unitdir}/data.mount
    install -d ${D}${systemd_system_unitdir}/tee-supplicant@.service.d
    install -m 0644 ${UNPACKDIR}/10-nv.conf ${D}${systemd_system_unitdir}/tee-supplicant@.service.d/10-nv.conf
    # NV erasure tied to the rootfs identity (/etc/trusted-imx95-rootfs-id, written
    # by the image); tee-supplicant requires this unit.
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/tee-nv-wipe ${D}${sbindir}/tee-nv-wipe
    install -m 0644 ${UNPACKDIR}/tee-nv-wipe.service ${D}${systemd_system_unitdir}/tee-nv-wipe.service
    install -d ${D}${sysconfdir}/systemd/system/tee-supplicant@teepriv0.service.requires
    ln -sf ${systemd_system_unitdir}/tee-nv-wipe.service \
        ${D}${sysconfdir}/systemd/system/tee-supplicant@teepriv0.service.requires/tee-nv-wipe.service
    install -d ${D}${sysconfdir}/default
    install -m 0644 ${UNPACKDIR}/tee-supplicant ${D}${sysconfdir}/default/tee-supplicant
    # Enable the supplicant (one instance, name unused by the unit) at boot.
    install -d ${D}${sysconfdir}/systemd/system/basic.target.wants
    ln -sf ${systemd_system_unitdir}/tee-supplicant@.service \
        ${D}${sysconfdir}/systemd/system/basic.target.wants/tee-supplicant@teepriv0.service
}

FILES:${PN} += "/data ${sbindir}/tee-nv-wipe ${systemd_system_unitdir} ${sysconfdir}/systemd/system ${sysconfdir}/default"
