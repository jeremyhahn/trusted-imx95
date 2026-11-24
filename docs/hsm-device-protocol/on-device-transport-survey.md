# hsm-device-protocol: public survey of the on-device transport paths on the i.MX 95

> **Status: SURVEY, PROVISIONAL, pending owner-queue item 160 (go-xkms #1521); not a requirement (Software Department ruling 195)** · Row: hsm-device-protocol · Issue: #24 · Surveyed: 2026-11-22
>
> The owner has since decided that the HSM is an xkmsd node (rulings 1243 and 1244). The device-side design is in [xkmsd-node.md](xkmsd-node.md). This record stays a survey: it adds no requirement and its unconfirmed cells stay unconfirmed.
>
> This record uses public sources only. Each claim cites a source from the [Sources](#sources) table as **[Sn]**. Vendor text is summarised, never copied. Anything the sources did not show is marked **unconfirmed**. The record builds nothing, writes no requirement for the device, and runs or scripts no fuse, life-cycle or provisioning step.

## Question

[docs/SPEC.md](../SPEC.md) (row `hsm-device-protocol`) leaves the direct-attach transport and the network protocol surface to go-xkms (go-xkms #1521, owner-queue item 160). Whatever protocol is chosen has to sit on a path inside the board, between the Cortex-A55 Linux side, the EdgeLock enclave (ELE) and the Cortex-M7. No existing document in this repository compares those paths. This survey sets out what the public sources show about:

- the A55 Linux to enclave path (section 1);
- the A55 Linux to Cortex-M7 path (section 2);
- the A55 normal world to OP-TEE path (section 3);
- a local-socket front for a daemon (section 4);
- a comparison table of the properties a later network protocol cares about (section 5).

It does not repeat [ele-hsm-api-survey.md](../secure-key-handling/ele-hsm-api-survey.md) (which side calls the HSM API), [attestation-survey.md](../device-lifecycle/attestation-survey.md) (carrying evidence to a remote verifier), [memory-protection-survey.md](../secure-world/memory-protection-survey.md) (NETC ports and 10 GbE DMA), [cortex-m7-isolation-survey.md](../secure-world/cortex-m7-isolation-survey.md) or [m7-resource-map-survey.md](../system-manager-config/m7-resource-map-survey.md) (M7 resources).

**Limit of this reading.** The lane's read guard refused reading C sources and headers, so every claim here rests on Kconfig files, kernel documentation pages, directory listings and file names. Where a claim needs the code (ioctl set, concurrency, message limits of the enclave interface), it is marked **unconfirmed**.

## 1. A55 Linux to the enclave

- **NXP's tree has a driver.** The NXP kernel tree [S1] has the secure-enclave driver set in `drivers/firmware/imx/` (`se_ctrl.c`, `ele_base_msg.c`, `ele_common.c`, `ele_fw_api.c`, `ele_trng.c`, `ele_bbsm.c`, `se_msg_sqfl_ctrl.c`, among others) and a user-space header `include/uapi/linux/se_ioctl.h` [S1 listings].
- **What the Kconfig says [S1 `drivers/firmware/imx/Kconfig`].** The option `IMX_SEC_ENCLAVE` is a tristate that depends on the i.MX mailbox driver, `ARCH_MXC` and arm64, selects the firmware loader, and defaults to `m` on `ARCH_MXC`. Its help text names the EdgeLock enclave on the i.MX 95 and says the driver talks to the enclave over the shared messaging unit (MU) and exposes its interfaces as a set of file descriptors for configuring shared memory and sending and receiving messages. A separate option, `IMX_ELE_TRNG`, adds the kernel-side random-number support.
- **Mainline has none of it.** Linux mainline at the commit read [S2] has no `se_ctrl.c`, no `ele_*` files and no `se_ioctl.h` in `drivers/firmware/imx/`. That directory lists the SCU, DSP and System Manager (`sm-*`) drivers only. Mainline does have the i.MX mailbox driver `drivers/mailbox/imx-mailbox.c` [S2 listing]. Lacking: a mainline driver that gives user space a path to the enclave's HSM services. A Linux-side caller therefore depends on NXP's tree or on carried patches (the same dependency the [ele-hsm-api-survey.md](../secure-key-handling/ele-hsm-api-survey.md) survey records).
- **How the user-space library opens it: unconfirmed.** The library `imx-secure-enclave` [S8] reaches the driver through the file descriptors the Kconfig describes. The device node names, the ioctl set and the open and close sequence were not read.
- **Single or multiple contexts: unconfirmed.** Whether several processes can open the interface at once, and how the driver separates their sessions, needs `se_ctrl.c` and `se_ioctl.h`, which were not read. The library's own session and key-store model is in the ELE survey linked above.
- **Message size limits: unconfirmed** for this path.
- **Survives a reset of the enclave: unconfirmed.** The library's NVM daemon keeps key-store blobs on the Linux filesystem (see the ELE survey); what a client sees when the enclave restarts was not read.
- **On the i.MX 95: shown** for the driver's intent (Kconfig help names the i.MX 95) [S1]. A working run on the FRDM-IMX95-PRO is **unconfirmed**.

## 2. A55 Linux to the Cortex-M7

- **Generic Linux pieces, in mainline [S2, S3, S4].**
  - `rpmsg` is a virtio-based messaging bus; each channel has a textual name and 32-bit source and destination addresses [S3].
  - `RPMSG_CHAR` exports endpoints as device files for user space, and `RPMSG_CTRL` adds `/dev/rpmsg_ctrlX` for creating endpoints with a given service name and addresses [S2 Kconfig]. `RPMSG_NS` handles name-service announcements and `RPMSG_VIRTIO` is the virtio bus [S2 Kconfig].
  - `remoteproc` loads firmware, powers the core on and off, and registers the rpmsg virtio devices the firmware announces [S4]. An optional `REMOTEPROC_CDEV` lets user space boot and shut down remote processors [S1 `drivers/remoteproc/Kconfig`].
- **What the rpmsg documentation says about limits [S3].**
  - Each buffer is 512 bytes by default, the same for both directions; a remote processor can advertise other sizes through a virtio feature bit. The header size inside the 512 bytes was not read, so the usable payload is **unconfirmed**.
  - A send with no free transmit buffer blocks for up to 15 seconds and then returns an error; the try-send forms return an error at once.
  - Channels appear only through name-service announcements from the remote side. Static channel creation is described as not implemented.
  - The page warns that remote cores may reach physical memory, and recommends limiting user space to specific channels and limiting its control over message content.
- **What a user-space daemon sees.** An rpmsg endpoint device (through `RPMSG_CHAR`) and, if the build enables it, the remoteproc character device [S2, S1 Kconfig]. The `rpmsg-tty` form is named in the brief; its Kconfig lives in the tty tree and was **not read**.
- **What the NXP tree adds [S1 listings].** `drivers/rpmsg/` has `imx_rpmsg.c`, `imx_rpmsg_pingpong.c` and `imx_rpmsg_tty.c`, which mainline does not have [S2 listing]. `IMX_REMOTEPROC` depends on the i.MX SCMI CPU and Logical Machine Manager drivers where those are enabled, and selects the mailbox framework [S1 `drivers/remoteproc/Kconfig`].
- **What the NXP device trees show for the i.MX 95 [S1 listing].** `imx95-19x19-evk-rpmsg.dts`, `imx95-15x15-evk-rpmsg.dts` and `imx95-15x15-frdm-rpmsg.dts` exist. The listing has **no** `-rpmsg` variant for `imx95-19x19-frdm-pro` (the FRDM-IMX95-PRO name in the tree), only the base board file and overlays. Whether the Cortex-M7 rpmsg path is set up for this board by the public BSP is therefore **unconfirmed**, and the listing suggests it is not shipped as a ready variant. Mainline has the base `imx95-19x19-frdm-pro.dts` and no rpmsg variant [S2 listing].
- **Survives a reset of the other side.** The remoteproc framework has a crash-report call and a shutdown-and-boot cycle that re-creates the rpmsg devices when the firmware announces them again [S4]. What the i.MX remoteproc driver does after an M7 crash was not read: **unconfirmed**.
- **Does the M7 have a path to the enclave?** Out of scope here; see the M7 surveys linked above.

## 3. A55 normal world to OP-TEE

- **Client side [S6].** `optee_client` provides `libteec.so`, the GlobalPlatform TEE Client API, and `tee-supplicant`, a daemon that serves the secure-world OS with services such as file-system access.
- **Kernel side [S1, S5].** The generic TEE subsystem is a kernel option (`TEE`) with the OP-TEE driver beneath it [S1 `drivers/tee/Kconfig`]. The kernel's own TEE page describes the in-kernel client-driver bus, where a Trusted Application is a device identified by UUID [S5]. The uapi header `include/uapi/linux/tee.h` exists in the NXP tree [S1 listing]. The device node names, session limits and shared-memory limits were not read: **unconfirmed**.
- **What bears on moving requests to a key service.** A user-space daemon can open a session to a Trusted Application by its UUID through the client library, and the secure world can call back to the normal world through `tee-supplicant` [S6]. How many clients may hold sessions at once, and the request size limit, are **unconfirmed** here.
- **Survives a reset.** A secure-world restart restarts the whole device; no separate-reset case exists for this path. Whether `tee-supplicant` loss is survivable was not read: **unconfirmed**.
- **On the i.MX 95.** OP-TEE's messaging-unit support for the i.MX 95 enclave is recorded in [ele-hsm-api-survey.md](../secure-key-handling/ele-hsm-api-survey.md). A PKCS#11 or key-service Trusted Application working on the i.MX 95 is **unconfirmed** by this lane.

## 4. A local-socket front for a daemon

The pages for `unix(7)` and `systemd.socket` were fetched but not read in this lane (see [Sources not reached or not read](#sources-not-reached-or-not-read-unconfirmed)). The table names the mechanisms only; their details are **unconfirmed** here.

| Mechanism | Role as the host-side seam | Status |
|---|---|---|
| Unix domain socket | A local stream endpoint between a network-facing listener and a daemon that holds one of the paths in sections 1 to 3 | details unconfirmed |
| `SO_PEERCRED` | Lets the daemon ask the kernel for the peer process's credentials | details unconfirmed |
| systemd socket activation | systemd opens the socket and passes it to the daemon at start | details unconfirmed |

## 5. Properties that matter to a later network protocol

| Property | Enclave through the MU driver (section 1) | rpmsg to the Cortex-M7 (section 2) | OP-TEE client path (section 3) |
|---|---|---|---|
| Who can open the path | Whoever can open the driver's device nodes: **unconfirmed** | Whoever can open the rpmsg endpoint device nodes (`RPMSG_CHAR`) [S2]; the kernel page advises limiting user space to named channels [S3] | Whoever can open the TEE device nodes: **unconfirmed** |
| Concurrency | **unconfirmed** | Many endpoints, each with its own address [S3]; per-channel limits **unconfirmed** | **unconfirmed** |
| Message size limit in the public sources | **unconfirmed** | 512-byte buffers by default, changeable by the remote [S3] | **unconfirmed** |
| Survives a reset of the other side | **unconfirmed** | Framework re-creates devices on a new announcement [S4]; i.MX driver behaviour **unconfirmed** | **unconfirmed** |
| Kernel configuration | `IMX_SEC_ENCLAVE` (tristate, default `m`), `IMX_MBOX`, `FW_LOADER`; NXP tree only [S1, S2] | `RPMSG`, `RPMSG_CHAR`, optionally `RPMSG_CTRL`, `RPMSG_VIRTIO`, `RPMSG_NS`, `REMOTEPROC`, `IMX_REMOTEPROC` (mainline Kconfig for the i.MX option **unconfirmed**) [S1, S2] | `TEE` and the OP-TEE driver [S1] |
| Shown working on the i.MX 95 in the public sources | Driver intent only; run **unconfirmed** [S1] | Device-tree variants for other i.MX 95 boards; none listed for the FRDM-IMX95-PRO name [S1] | **unconfirmed** |

## Network side, named and not chosen

go-xkms has not chosen the network transport. The candidates the SPEC names are the board's two 1 GbE ports and a 10 GbE expansion card on the Slim-SAS connector (UM12527 section 2.18). The card is not in the kit and its documentation is missing ([docs/references/README.md](../references/README.md)). This survey chooses none of them and says nothing on the wire protocol.

## What this survey does not decide

- the wire protocol, the network transport or the 10 GbE card (go-xkms #1521, item 160);
- which side calls the HSM API (the existing SPEC open question);
- any device-side requirement for `hsm-device-protocol` (ruling 195);
- whether the platform image builds on NXP's kernel tree or on carried patches.

## Sources

| # | Title | Version surveyed | URL |
|---|---|---|---|
| S1 | NXP `linux-imx`: `drivers/firmware/imx/Kconfig`, `drivers/remoteproc/Kconfig`, `drivers/tee/Kconfig`, directory listings of `drivers/firmware/imx`, `drivers/rpmsg`, `drivers/mailbox`, `include/uapi/linux`, `arch/arm64/boot/dts/freescale` | branch `lf-6.18.y`, commit 6e694ed (2026-09-08) | https://github.com/nxp-imx/linux-imx |
| S2 | Linux mainline: `drivers/rpmsg/Kconfig`, directory listings of `drivers/firmware/imx`, `drivers/rpmsg`, `drivers/mailbox`, `arch/arm64/boot/dts/freescale` | default branch, commit 4843f68 (2026-11-22); latest tag v7.4-rc3 | https://github.com/torvalds/linux |
| S3 | Linux kernel documentation, Remote Processor Messaging (rpmsg) Framework | page for 7.4.0-rc3 | https://docs.kernel.org/staging/rpmsg.html |
| S4 | Linux kernel documentation, Remote Processor Framework | page for 7.4.0-rc3 | https://docs.kernel.org/staging/remoteproc.html |
| S5 | Linux kernel documentation, TEE driver API | page for 7.4.0-rc3 | https://docs.kernel.org/driver-api/tee.html |
| S6 | OP-TEE documentation, optee_client | latest | https://optee.readthedocs.io/en/latest/building/gits/optee_client.html |
| S7 | OpenAMP documentation, RPMsg protocol | main | https://openamp.readthedocs.io/en/latest/protocol_details/rpmsg.html |
| S8 | NXP `imx-secure-enclave`: top-level file listing | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-secure-enclave |

S7 was read only at heading level; no claim above rests on it.

### Sources not reached or not read (unconfirmed)

- The C sources and headers of S1 (`se_ctrl.c`, `se_ioctl.h`, `rpmsg_char.c`, `rpmsg_tty.c`, `imx_rproc.c`, the enclave devicetree binding): fetched in part, not read, because the lane's read guard refused code. Each claim that needs them is marked unconfirmed.
- The `imx-secure-enclave` README at S8: fetched, not read.
- The kernel tty Kconfig (`RPMSG_TTY`) and the mainline `drivers/remoteproc/Kconfig`: fetched, not read.
- `unix(7)` (https://man7.org/linux/man-pages/man7/unix.7.html), `systemd.socket` and `sd_listen_fds` (https://www.freedesktop.org/software/systemd/man/latest/systemd.socket.html): fetched, not read.
- OP-TEE architecture and porting pages on the tee-supplicant, `/dev/tee*` and `/dev/teepriv0` nodes: fetched, not read.
- i.MX 95 Reference Manual and NXP i.MX Linux release notes: not public or not read.

## Questions for the owner

1. **Is a read of the C sources of NXP's driver and the public libraries permitted for the next slice?** Options: (a) yes, to settle the unconfirmed cells of section 5; (b) no, keep the survey at documentation level; (c) have a lane with code access do it. *Provisional default:* (a), since the unconfirmed cells are all in code.
2. **Should the survey be extended to the board's M7 rpmsg setup once a board test exists?** Options: (a) wait for a board test; (b) extend from the NXP device-tree variants only. *Provisional default:* (a), because the public tree shows no rpmsg variant for the FRDM-IMX95-PRO name.
3. **Proposed, pending owner approval (text only; this lane edits neither SPEC.md nor ROADMAP.md):** add to the `hsm-device-protocol` row a line pointing to this survey as provisional input. Options: (a) add the pointer; (b) leave the row as is until go-xkms #1521 answers. *Provisional default:* (b), in line with ruling 195.
