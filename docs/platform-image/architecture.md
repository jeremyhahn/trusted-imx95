# platform-image — architecture

> **Status: NORMATIVE** · Scope: trusted-imx95 `platform-image` · Last verified: 2026-11-12
> A reference digest for the SPEC row [`platform-image`](../SPEC.md#features), which stays blocked on the owner's
> approval. Every statement cites a document and section; a fact the documents do not give is under
> [Missing](#missing), never guessed. Nothing here decides an open question: those are under
> [Open questions](#open-questions).

## Sources and how they were read

The vendor documents live in a private context repository ([references/README.md](../references/README.md), "NXP
documents and the Code Signing Tool"). This digest was written from a clone that could not reach that repository, so
its board facts are taken from the citations the SPEC row already carries (docs/SPEC.md, Features, `platform-image`):
UM12527 §1.2 Table 1, §2.3 Table 7, §2.6, §2.9 and §2.10. Each is cited below as the SPEC row cites it, and each is
listed under [Missing](#missing) as not yet checked against UM12527 itself.

## The problem

The FRDM-IMX95-PRO needs a Linux image built in this repository, which go-trusted-platform provisions and attests
(docs/SPEC.md, Features, `platform-image`; Boundaries). The board's image is built here, never by
go-trusted-platform's image pipeline (docs/SPEC.md, Boundaries).

## The device the image runs on

- The board is the NXP FRDM-IMX95-PRO, built on the i.MX 95: six Cortex-A55, one Cortex-M33, one Cortex-M7, the
  EdgeLock secure enclave and the NPU (UM12527 §1.2, §2.1, as cited in docs/SPEC.md, Purpose;
  [references/README.md](../references/README.md), "The device").
- The Linux image runs on the Cortex-A55 side; xkmsd from go-xkms runs on that Linux side (docs/SPEC.md, Purpose;
  Features, `platform-image`).
- The board boots on the Cortex-M33 (UM12527 §2.3 Table 7, as cited in docs/SPEC.md, Features, `boot-container`).
  The System Manager on the Cortex-M33 stays NXP's; this repository holds only its configuration (docs/SPEC.md,
  Boundaries; Features, `system-manager-config`).

## Boot devices

| Boot device | Role | Source |
|---|---|---|
| 32 GB eMMC on uSDHC1 | The default boot device | UM12527 §1.2 Table 1, §2.3 Table 7, §2.6, §2.9, §2.10 (as cited in docs/SPEC.md, Features, `platform-image`) |
| microSD | An alternative boot device, selected with SW4 | Same citations |
| FlexSPI NOR | An alternative boot device, selected with SW4 | Same citations |

- The SW4 switch selects the boot mode (UM12527 §2.3, as cited in docs/SPEC.md, Features, `platform-image`;
  Interfaces).
- The board also offers the USB serial downloader as a boot mode (UM12527 §2.3, as cited in docs/SPEC.md,
  Interfaces).
- The signed boot container sits on the default boot device, the eMMC (UM12527 §2.3, as cited in docs/SPEC.md,
  Interfaces). Its signing and verification are the `boot-container` row's, not this row's (docs/SPEC.md, Features,
  `boot-container`).
- The SPEC row cites its sections together; which of them describes which device is listed under
  [Missing](#missing).

## Component boundaries

| Piece | Owner | Source |
|---|---|---|
| The Linux image and its build | This repository; how it is built is the owner's decision | docs/SPEC.md, Boundaries; Release criteria |
| The boot container and its signing | This repository, row `boot-container` | docs/SPEC.md, Features, `boot-container` |
| The System Manager configuration on the Cortex-M33 | This repository, row `system-manager-config`; the System Manager itself is NXP's | docs/SPEC.md, Boundaries |
| xkmsd and the wire protocol | go-xkms, running xkmsd on the board's Linux side | docs/SPEC.md, Boundaries |
| Provisioning, enrollment and attestation of the device and its image | go-trusted-platform | docs/SPEC.md, Boundaries; Features, `device-lifecycle` |
| The Cortex-M7 firmware | trusted-firmware's `imx95` row; the split is open for the owner | docs/SPEC.md, Boundaries; Release criteria |

## Data flow

The image reaches the board on one of the boot devices above and boots from it, from the eMMC by default (UM12527
§2.3 Table 7, as cited in docs/SPEC.md, Features, `platform-image`). After boot, go-trusted-platform's control plane
provisions, enrolls and attests the device and its image (docs/SPEC.md, Features, `device-lifecycle`). How the image
is written to each device, its partition layout and the update path are not in any document in
[references/](../references/README.md): see [Missing](#missing).

## Trust boundaries

- The image's boot chain is verified by AHAB secure boot through the signed boot container (docs/SPEC.md, Features,
  `boot-container`).
- The image is attested by go-trusted-platform; the evidence the device presents is an open question for the owner
  (docs/SPEC.md, Features, `device-lifecycle`).
- Keys stay in the EdgeLock secure enclave's key store (RM00284 §2.4, §3.2, as cited in docs/SPEC.md, Features,
  `secure-key-handling`); the image holds no key in the clear.

## What this row does not do

- It does not build the image with go-trusted-platform's image pipeline (docs/SPEC.md, Boundaries).
- It does not implement xkmsd or define the wire protocol: go-xkms owns both (docs/SPEC.md, Boundaries). xkmsd on
  the image's Linux side is blocked on go-xkms.
- It does not use the CompuLab Yocto image in `resources/` as the device's image: that image is reference material
  for another i.MX 95 board ([references/README.md](../references/README.md), "CompuLab reference material";
  docs/SPEC.md, Boundaries).
- It does not choose a build system or reject alternatives: the build is the owner's decision (docs/SPEC.md,
  Release criteria) and is under [Open questions](#open-questions).

## Missing

- **UM12527 not checked in this lane.** The vendor context repository was not reachable from this clone. Every
  UM12527 fact above is taken from the SPEC row's citations and is not yet checked against UM12527 Rev. 1.0 itself:
  the eMMC's size and its uSDHC1 controller, the eMMC as the default boot device, the microSD and the FlexSPI NOR as
  the SW4 alternatives (§1.2 Table 1, §2.3 Table 7, §2.6, §2.9, §2.10), the USB serial downloader (§2.3), the boot on
  the Cortex-M33 (§2.3 Table 7), and the processor's cores (§1.2, §2.1).
- **Which UM12527 section describes which boot device**, and the SW4 positions for each boot mode, are not checked.
- **The FlexSPI NOR's size and part**, and the microSD slot's controller, are not given in any cited section this
  lane could read.
- **The NXP Linux BSP documentation** the build needs is not in [references/](../references/README.md)
  (docs/SPEC.md, Features, `platform-image`; Release criteria).
- **IMX95RM**, the i.MX 95 Applications Processor Reference Manual, and **the i.MX 95 Security Reference Manual** are
  missing ([references/README.md](../references/README.md), "Still missing"). The boot ROM behaviour, including how
  it reads each boot device, comes from them.
- **The System Manager documentation** is missing (docs/SPEC.md, Features, `system-manager-config`).
- **The image's partition layout, its update and rollback path, and how it is written to each boot device** are
  given by no document in [references/](../references/README.md).

## Open questions

These are the owner's. This document answers none of them.

1. How the platform image is built: the image build system (#14). The CompuLab Yocto image is reference only
   (docs/SPEC.md, Release criteria).
2. The firmware split between this repository and trusted-firmware's `imx95` row (docs/SPEC.md, Release criteria).
3. What evidence the device presents when go-trusted-platform attests the image, and the root it chains to
   (docs/SPEC.md, Features, `device-lifecycle`).
