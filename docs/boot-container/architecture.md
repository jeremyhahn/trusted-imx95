# boot-container — architecture

> **Status: NORMATIVE** · Scope: trusted-imx95 `boot-container` · Last verified: 2026-11-12
> The detail of the `boot-container` row of [SPEC.md](../SPEC.md). Conflicts with SPEC.md are defects in this file.

Every statement below cites a document and section listed in [references/README.md](../references/README.md).
A fact the documents do not give is under [Missing](#missing); a choice the owner has not made is under
[Open questions](#open-questions). No configuration value appears here that the references do not give.

## Problem

The platform image's boot container must be signed, and AHAB secure boot must verify the Cortex-M7 image of
trusted-firmware's `imx95` row as a signed container before it runs ([SPEC.md](../SPEC.md), `boot-container`
row). AN14471 is NXP's application note on signing AHAB containers with keys held in a hardware security module,
and it is the model for the custody of the signing keys (AN14471 §3.1, §3.6). This file states what the cited
documents give for the boot flow, the container, its signing and the anti-rollback floor, and names what they do
not give.

## Boot flow

- The FRDM-IMX95-PRO boots on the Cortex-M33 (UM12527 §2.3 Table 7). The i.MX 95 on the board has six
  Cortex-A55, one Cortex-M33, one Cortex-M7, the EdgeLock secure enclave and the NPU (UM12527 §1.2, §2.1).
- The default boot device is the 32 GB eMMC on uSDHC1; the microSD and the FlexSPI NOR are the alternatives the
  SW4 switch selects (UM12527 §1.2 Table 1, §2.3 Table 7, §2.6, §2.9, §2.10). The signed boot container sits on
  the default boot device (UM12527 §2.3).
- SW4 also selects the USB serial downloader (UM12527 §2.3). The per-core debug UARTs are on J22, and their port
  mapping is not fixed (UM12527 §2.19).
- What the boot ROM does between reset and handing control to the first container, and in which order the
  Cortex-M33, Cortex-M7 and Cortex-A55 images are loaded and verified, the references do not give (see
  [Missing](#missing)).

## AHAB container

- The boot container is an AHAB container; AN14471 describes signing AHAB containers with keys held in an HSM
  (AN14471 §3.1, §3.6).
- The container's layout, its version field and the fuses that hold the hashes of its public keys come from
  IMX95RM and the i.MX 95 Security Reference Manual, both missing (see [Missing](#missing)). No field, offset or
  fuse is named here.

## Signing

- Containers are signed with keys held in an HSM, after AN14471's model for the custody of the signing keys
  (AN14471 §3.1, §3.6). Holding those keys is go-xkms's custody and is out of this file's scope.
- The signing tool is NXP's Code Signing Tool 3.1.0 (CST_UG; its HSM back end, CST-HSM_UG) or NXP's Secure
  Provisioning SDK (SPSDK), which also signs AHAB containers ([references/README.md](../references/README.md),
  "Vendor SDKs and documentation online"). Which of the two the build uses is an open question for the owner
  (see [Open questions](#open-questions)).
- The build never reads the Code Signing Tool from this repository: it takes the tool's directory from
  `CST_PATH`, and stops naming the variable when it is unset ([references/README.md](../references/README.md),
  "The Code Signing Tool in the build").
- The PKI tree the containers chain to, and the commands that sign a container, are in CST_UG and CST-HSM_UG;
  they are not restated here, and none is chosen until the tool is (see [Open questions](#open-questions)).

## Anti-rollback floor

- The anti-rollback floor follows the EdgeLock enclave's monotonic counter (RM00284 §3.24) and the AHAB version
  field ([SPEC.md](../SPEC.md), `boot-container` row). The version field is given by documents that are missing
  (see [Missing](#missing)).
- The monotonic counter fuses are configured once (RM00284 §3.24); configuring them belongs to the
  `oem-key-provisioning` row of [SPEC.md](../SPEC.md).
- A key store update counts only after an operation with the strict-operation flag is acknowledged, and that
  operation also advances the monotonic counter that protects the key store from rollback (RM00284 §2.4.2).
- The device's life cycle moves from OEM open to OEM closed through the enclave (RM00284 §3.23). What closing
  the life cycle changes for the verification of a container is not given (see [Missing](#missing)).

## Boundaries

- This repository builds the boot container of the platform image; go-trusted-platform's image pipeline never
  builds it ([SPEC.md](../SPEC.md), Boundaries).
- The Cortex-M7 image inside the container is trusted-firmware's `imx95` row; this file does not restate it
  ([SPEC.md](../SPEC.md), Boundaries).
- Signing-key custody (go-xkms), the `hsm-device-protocol`, the `device-lifecycle` and the `hsm-self-defence`
  rows are out of scope here ([SPEC.md](../SPEC.md), Features); `hsm-self-defence` is blocked on go-xkms and
  go-quicbaas and is only named.
- The CompuLab UCM-iMX95 material is reference only and is not cited for this device
  ([references/README.md](../references/README.md), "The device").

## Missing

- The i.MX 95 Applications Processor Reference Manual (IMX95RM): the AHAB container layout, the boot ROM
  behaviour, the fuse map ([references/README.md](../references/README.md), "Still missing").
- The i.MX 95 Security Reference Manual: the AHAB version field, the fuses for the key hashes, what the OEM closed
  life cycle enforces at boot ([references/README.md](../references/README.md), "Still missing").
- The System Manager documentation: how the Cortex-M33 boot hands over to the System Manager and to the
  Cortex-M7 image.
- The NXP Linux BSP documentation: how the Cortex-A55 images are placed in the container.
- The order in which the boot ROM loads and verifies the Cortex-M33, Cortex-M7 and Cortex-A55 images.
- What AN14471 §3.1 and §3.6, CST_UG and CST-HSM_UG give beyond the facts above: this digest was written from
  the citations already in [SPEC.md](../SPEC.md) and [references/README.md](../references/README.md), without
  read access to the private vendor context repository. A reader with access deepens each section from those
  documents, citing the section.

## Open questions

- CST 3.1.0 or SPSDK for signing AHAB containers: the owner's decision.
- Whether the anti-rollback floor uses the enclave's monotonic counter, the AHAB version field, or both, once the
  Security Reference Manual gives the version field: the owner's decision.
- When the life cycle is closed and where provisioning runs: the owner's, under `oem-key-provisioning`
  ([SPEC.md](../SPEC.md)).
