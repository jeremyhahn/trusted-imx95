# secure-world — architecture

> **Status: NORMATIVE** · Scope: trusted-imx95 `secure-world` · Last verified: 2026-11-12
> The detail of the `secure-world` row of [SPEC.md](../SPEC.md). Conflicts with SPEC.md are defects in this file.

Every statement below cites a document and section listed in [references/README.md](../references/README.md).
A fact the documents do not give is under [Missing](#missing); a choice the owner has not made is under
[Open questions](#open-questions). This file decides nothing: it gathers what the references give about the cores
and the enclave a secure world would run on, and names what they leave out.

## Problem

The board's secure world lives in this repository ([SPEC.md](../SPEC.md), Purpose, `secure-world` row). Which cores
and which TrustZone software it covers is not decided in this repository's documents or in trusted-firmware's
rows ([SPEC.md](../SPEC.md), `secure-world` row). No document in the references gives the i.MX 95's TrustZone
configuration; the one that does is missing ([SPEC.md](../SPEC.md), `secure-world` row;
[references/README.md](../references/README.md), "Still missing").

## The cores

- The i.MX 95 on the FRDM-IMX95-PRO has six Cortex-A55, one Cortex-M33, one Cortex-M7, the EdgeLock secure
  enclave and the NPU (UM12527 §1.2, §2.1).
- The board boots on the Cortex-M33 (UM12527 §2.3 Table 7). The Cortex-M33 runs NXP's System Manager, which stays
  NXP's code; this repository holds only its configuration ([SPEC.md](../SPEC.md), Boundaries,
  `system-manager-config` row).
- The Cortex-M7 runs the firmware of trusted-firmware's `imx95` row, with its `frdm-imx95-m7` board profile on
  that row's `cortex-m` port ([SPEC.md](../SPEC.md), Boundaries). AHAB secure boot verifies that image as a signed
  container before it runs ([SPEC.md](../SPEC.md), `boot-container` row).
- The Cortex-A55 cluster runs the platform image's Linux side, which runs xkmsd from go-xkms
  ([SPEC.md](../SPEC.md), `platform-image` row).
- Each core has its own debug UART on J22, and the port mapping is not fixed (UM12527 §2.19).
- The processor data sheet gives electrical, pin and package facts and refers to IMX95RM for the programming
  model (IMX95CEC; [references/README.md](../references/README.md), "NXP documents"). Which of these cores carry
  a TrustZone secure state, and how the processor partitions memory and peripherals between secure and non-secure
  masters, are therefore not given (see [Missing](#missing)).

## The EdgeLock secure enclave

The enclave is the one secure-world element the references document. What they give:

- The board's keys are generated and held in the enclave's key store and never leave it in the clear
  (RM00284 §2.4, §3.2).
- A key store update counts only after an operation with the strict-operation flag is acknowledged, which also
  advances the monotonic counter that protects the store from rollback (RM00284 §2.4.2).
- Signing, data storage and attestation are services of the enclave's HSM API (RM00284 §3.4, §3.8, §3.12).
- The Generic Crypto APIs are not available on the i.MX 95 (RM00284 §3.45).
- The device's life cycle moves from OEM open to OEM closed through the enclave (RM00284 §3.23).

Which core, and which security state on it, opens a session to the enclave is not given by RM00284 as cited here
and is an open question for the owner ([SPEC.md](../SPEC.md), `secure-key-handling` row).

## The SE051 secure element

The board also carries an NXP SE051 secure element: U28, on I2C2 at 0x48, with the J4 control header
(UM12527 §1.1, §1.5 Table 3, §2.5 Table 9). Its documentation is missing, and whether it holds any key, or which
world reaches it, is an open question for the owner ([SPEC.md](../SPEC.md), `secure-key-handling` row).

## What trusted-firmware's `imx95` row assumes

trusted-firmware's `imx95` row states what its Cortex-M7 firmware assumes of the board's secure world and of the
enclave key tier; that row is the authority and this file does not restate it. This repository records one
consequence of it: the board's keys stay in the enclave's key store as that row requires of the key tier
([SPEC.md](../SPEC.md), `secure-key-handling` row). The firmware split between this repository and that row is
open for the owner ([SPEC.md](../SPEC.md), Boundaries, Release criteria).

## Boundaries

- The System Manager on the Cortex-M33 is never replaced ([SPEC.md](../SPEC.md), Boundaries).
- The secure world never defines the wire protocol or implements xkmsd: go-xkms owns both
  ([SPEC.md](../SPEC.md), Boundaries).
- Device enrollment, the device registry and attestation verification are go-trusted-platform's and go-xkms's
  ([SPEC.md](../SPEC.md), Boundaries); the enclave's attestation service is the device side
  ([SPEC.md](../SPEC.md), `device-lifecycle` row; RM00284 §3.12).
- The CompuLab UCM-iMX95 material is reference only and is not cited for this device
  ([references/README.md](../references/README.md), "The device").

## Missing

- IMX95RM, the i.MX 95 Applications Processor Reference Manual: which cores implement a TrustZone secure state,
  the secure and non-secure memory map, the resource domain and access controllers, and how bus masters and
  peripherals are assigned to a security state ([references/README.md](../references/README.md),
  "Still missing").
- The i.MX 95 Security Reference Manual: the i.MX 95's TrustZone configuration, the boot ROM's hand-off to each
  core and its security state, and the fuses that lock the configuration ([SPEC.md](../SPEC.md),
  `secure-world` row; [references/README.md](../references/README.md), "Still missing").
- The System Manager documentation: whether the System Manager assigns cores, memory or peripherals to a security
  state, and how ([SPEC.md](../SPEC.md), `system-manager-config` row).
- The NXP Linux BSP documentation: what secure-world software NXP's Linux BSP runs on the Cortex-A55, and the
  interface between it and Linux ([SPEC.md](../SPEC.md), `platform-image` row).
- Which core and security state may open an enclave session, and whether the enclave distinguishes callers by
  core or security state: not in the RM00284 sections cited in [SPEC.md](../SPEC.md).
- The SE051 documentation ([SPEC.md](../SPEC.md), `secure-key-handling` row).
- This digest was written from the citations already in [SPEC.md](../SPEC.md) and
  [references/README.md](../references/README.md), without read access to the private vendor context repository.
  Every UM12527 and RM00284 citation above is carried from SPEC.md and was not checked against the documents.
  A reader with access checks each, and deepens the cores and enclave sections from UM12527 and RM00284, citing
  the section.

## Open questions

- Which cores the secure world covers, and which TrustZone software it runs on them
  ([SPEC.md](../SPEC.md), `secure-world` row, Release criteria).
- Which side calls the enclave's HSM API, the Cortex-A55 Linux side or the Cortex-M7
  ([SPEC.md](../SPEC.md), `secure-key-handling` row).
- The SE051's role beside the enclave, and whether it holds any key ([SPEC.md](../SPEC.md),
  `secure-key-handling` row).
- The firmware split between this repository and trusted-firmware's `imx95` row ([SPEC.md](../SPEC.md),
  Release criteria).
