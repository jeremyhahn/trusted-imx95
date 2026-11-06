# trusted-imx95 — specification

> **Status: NORMATIVE** · Scope: trusted-imx95 · Last verified: 2026-11-06
> Conflicts with this document are defects. Fix them here first.

## Purpose

trusted-imx95 is the device repository for the NXP FRDM-IMX95-PRO, at Layer 0 as a device repository: the board's firmware, its Linux image, its secure world and its secure key handling live here.
The board is the i.MX 95 with six Cortex-A55, one Cortex-M33, one Cortex-M7, the EdgeLock secure enclave and the NPU (UM12527 §1.2, §2.1); it is the first HSM device of the portfolio.
go-xkms defines the device's wire protocol and runs xkmsd on its Linux side; go-trusted-platform provisions, enrolls and attests the device and its image.
It stays the platform image: there is no `trusted-firmware-imx95` repository, and other HSM devices live in trusted-firmware or a `trusted-firmware-<application>` repository.
Every design and change about the hardware cites a document and section in [references/](references/README.md); a fact the documents do not give is reported as missing, never guessed.

## Boundaries

- Owns the FRDM-IMX95-PRO platform image: the Linux image, its boot container and the System Manager configuration.
- Owns the device side of go-xkms's `hsm-device-protocol` and of go-trusted-platform's `hsm-device-lifecycle`.
- Never defines the wire protocol and never implements xkmsd: go-xkms owns both and runs xkmsd on the board's Linux side.
- Never owns device enrollment, the device registry, fleet policy or attestation verification: go-trusted-platform and go-xkms own them.
- The Cortex-M7 firmware: trusted-firmware's `imx95` row (trusted-firmware #49, closed 2026-10-25) holds the M7 firmware core and its `frdm-imx95-m7` board profile, on its `cortex-m` port; the split is open for the owner (Release criteria).
- Never replaces NXP's System Manager on the Cortex-M33: the System Manager stays NXP's, and this repository holds only its configuration.
- The board's image is built here, never by go-trusted-platform's image pipeline.
- The CompuLab UCM-iMX95 material in [references/](references/README.md) and `resources/` is reference only; it is not the device.

## Features

| Feature | Status | Requirements | Detail |
|---|---|---|---|
| platform-image | planned | The Linux image the FRDM-IMX95-PRO boots, built in this repository and provisioned and attested by go-trusted-platform. It boots from the default boot device, the 32 GB eMMC on uSDHC1, with the microSD and the FlexSPI NOR as the alternatives the SW4 switch selects (UM12527 §1.2 Table 1, §2.3 Table 7, §2.6, §2.9, §2.10). It runs xkmsd from go-xkms on its Linux side. The CompuLab Yocto image in `resources/` is reference only. The NXP Linux BSP documentation the build needs is not in [references/](references/README.md) and is listed as missing. | none |
| boot-container | planned | The signed boot container of the platform image: AHAB secure boot verifies the Cortex-M7 image of trusted-firmware's `imx95` row as a signed container before it runs. The board boots on the Cortex-M33 (UM12527 §2.3 Table 7). Containers are signed with keys held in an HSM, after AN14471's model for go-xkms custody (AN14471 §3.1, §3.6), with NXP's CST 3.1.0 (CST_UG, CST-HSM_UG) or SPSDK. The anti-rollback floor follows RM00284 (§3.24, the monotonic counter) and the AHAB version field; the version field, the fuse map for the key hashes and the boot ROM behaviour come from IMX95RM and the i.MX 95 Security Reference Manual, both missing. | none |
| system-manager-config | planned | The configuration of NXP's System Manager on the Cortex-M33, which stays NXP's code. It gives the Cortex-M7 firmware of trusted-firmware's `imx95` row its clocks, power and resources through SCMI, and the power domains and PHYs that `hsm-self-defence` acts on. The System Manager's documentation and IMX95RM are not in [references/](references/README.md) and are listed as missing. | none |
| secure-world | planned | The board's secure world lives in this repository. Which cores and which TrustZone software it covers is not decided in this repository's documents or in trusted-firmware's rows, and is an open question for the owner. No document in [references/](references/README.md) gives the i.MX 95's TrustZone configuration; the one that does is missing. | none |
| secure-key-handling | planned | The board's keys are generated and held in the EdgeLock secure enclave's key store and never leave it in the clear, as trusted-firmware's `imx95` row requires of the key tier (RM00284 §2.4, §3.2). A key store update counts only after an operation with the strict-operation flag is acknowledged, which also advances the monotonic counter that protects the store from rollback (RM00284 §2.4.2). Signing, data storage and attestation use the enclave's HSM API (RM00284 §3.4, §3.8, §3.12); the Generic Crypto APIs are not available on the i.MX 95 (RM00284 §3.45). Which side calls the HSM API, the Cortex-A55 Linux side or the Cortex-M7, is an open question for the owner. The board also carries an NXP SE051 secure element (U28, on I2C2 at 0x48, with the J4 control header; UM12527 §1.1, §1.5 Table 3, §2.5 Table 9). Whether it holds any key, and its role beside the enclave, is an open question for the owner; its documentation is not in [references/](references/README.md) and is listed as missing. | none |
| oem-key-provisioning | planned | Provisions the OEM keys into the enclave through the vendor's flow: key exchange, then the import of the wrapped key (AN14861 §2, §5.2, §5.3; RM00284 §3.20, §3.2.6.3). The device's life cycle moves from OEM open to OEM closed through the enclave (RM00284 §3.23), and the monotonic counter fuses are configured once (RM00284 §3.24). AN14861 is written for the RT1180; the i.MX 95 fuse map and life-cycle effects come from IMX95RM and the i.MX 95 Security Reference Manual, both missing. When the life cycle is closed, and where provisioning runs, are open questions for the owner. | none |
| hsm-device-protocol | planned | The device side of go-xkms's `hsm-device-protocol`, which go-xkms defines, between xkmsd and the board. The network transports are the board's two 1 GbE ports and a 10 GbE expansion card on the Slim-SAS connector (UM12527 §1.2 Table 1, §2.18). The 10 GbE expansion card is not in the board kit and its documentation is missing. The direct-attach transport and the network protocol surface are go-xkms's open questions (go-xkms #1521), in the owner queue as item 160; no device-side requirement is written here before the owner answers (Software Department ruling 195). | none |
| device-lifecycle | planned | The device side of go-trusted-platform's `hsm-device-lifecycle`: the board is provisioned, enrolled and attested, and its image attested, by go-trusted-platform's control plane, which builds no firmware for it. The enclave offers device attestation (RM00284 §3.12). What evidence the device presents, and the root it chains to, are not decided here, and are an open question for the owner. | none |
| hsm-self-defence | planned | The HSM device side of the tamper response that trusted-firmware's `hsm-self-defence` row enforces on the Cortex-M7 and go-xkms's `hsm-self-defence` row names. The M7 acts through NXP's System Manager, whose configuration is this repository's (`system-manager-config`), and the EdgeLock secure enclave: power domains, PHYs, key zeroisation and shutdown. Whether the Cortex-A55 tamper detector, the NPU model and the IMA log are built in this repository is not decided, and is an open question for the owner. No document in [references/](references/README.md) gives the EdgeLock tamper pins; the one that does is missing. | none |

## Interfaces

- No interface is built yet; nothing in this repository is code.
- The device side of go-xkms's `hsm-device-protocol`, over the board's 1 GbE ports and the 10 GbE Slim-SAS connector (UM12527 §2.18).
- The signed boot container on the default boot device, the eMMC (UM12527 §2.3).
- Board interfaces: the SW4 boot modes and the USB serial downloader (UM12527 §2.3); the per-core debug UARTs on J22, whose port mapping is not fixed (UM12527 §2.19).
- Vendor documents and what each is read for: [references/README.md](references/README.md).

## Release criteria

- `docs/SPEC.md` and `ROADMAP.md` exist in the handbook's shapes and agree.
- The owner approves the whole of both files.
- CI conforms to the handbook's `software/conventions/ci-standard.md`: build, unit tests, integration tests, security scans and the latest-version check, all in the project's devcontainer image.
- The owner decides the firmware split: this repository's documents say the board's firmware lives here, and trusted-firmware's `imx95` row owns the Cortex-M7 firmware and its board profile.
- The owner decides how the platform image is built; the CompuLab Yocto image is reference only.
- The open questions in the Features rows are answered: the secure world's scope, the side that calls the HSM API, the SE051's role, the provisioning place and life-cycle close, the attestation evidence, and the A55 side of `hsm-self-defence`.
- IMX95RM, the i.MX 95 Security Reference Manual, the System Manager documentation, the NXP Linux BSP documentation, the SE051 documentation and the 10 GbE expansion card documentation are in [references/](references/README.md).
- A milestone and one issue for each feature row exist in this repository.
