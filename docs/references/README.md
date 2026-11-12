# References

Every agent reads these vendor documents before designing, building or debugging on this device. A design, ADR,
issue or PR about the hardware, boot, security, signing or connectors cites the document and section it rests on.
A fact the documents do not give is reported as missing, never guessed.

## The device

The device is the NXP FRDM-IMX95-PRO board (UM12527). It is built on the i.MX 95: six Cortex-A55, one Cortex-M33,
one Cortex-M7, the EdgeLock secure enclave and the NPU. The CompuLab UCM-iMX95 documents and design files are
reference material for another i.MX 95 board, not for our device.

## NXP documents and the Code Signing Tool (private context repository)

NXP's documents and its Code Signing Tool are under NXP's click-through terms, and this public repository has no
permission to redistribute them. They live in the private context repository `jeremyhahn/vendor-nxp`. Agents with
read access read them there by path. Nothing from that repository is copied here.

| Path in `jeremyhahn/vendor-nxp` | Document | Read it for |
|---|---|---|
| `docs/imx95/UM12527-FRDM-IMX95-PRO-board-user-manual.pdf` | NXP UM12527, FRDM-IMX95-PRO Board User Manual, Rev. 1.0 | Our board. The first document for any hardware, boot or debug work: block diagram, features, memories, boot modes (eMMC, SD, FlexSPI NOR), the per-core debug ports, connectors, power, jumpers |
| `docs/imx95/IMX95CEC.pdf` | NXP IMX95CEC, i.MX 95 Applications Processors Data Sheet for Commercial Products, Rev. 8 | Electrical, pin and package facts of the processor. It refers to IMX95RM for the programming model |
| `docs/edgelock/RM00284.pdf` | NXP RM00284, EdgeLock Enclave Hardware Security Module API, Rev. 4.5 | The enclave's HSM API on the i.MX 95: key store, signing, secure storage, counters, attestation. The source for every secure-element seam and for the anti-rollback floor |
| `docs/edgelock/AN14861.pdf` | NXP AN14861, Secure OEM Key Provisioning with EdgeLock Secure Enclave, Rev. 1.0 | The vendor's OEM key-provisioning flow. It is written for the RT1180; the enclave flow is the same family |
| `docs/code-signing/AN14471.pdf` | NXP AN14471, Using Hardware Security Module for Code Signing, Rev. 1.0 | Signing AHAB containers with keys held in an HSM; the model for go-xkms custody |
| `docs/code-signing/HSM Code-Signing Journey_07JUN2024.pdf` | NXP presentation, HSM Code-Signing Journey | An overview of the HSM-backed signing flow |
| `tools/cst/cst-3.1.0.tgz` | NXP Code Signing Tool 3.1.0: sources, PKI scripts, HSM back end. Its documents are inside: `release/docs/CST_UG.pdf`, `release/docs/HAB4_API.pdf`, `release/code/back_end-hsm/doc/CST-HSM_UG.pdf`, `HSM-CST_UG.pdf`, `HSM-CST-Architecture.pdf`, `HSM-CST_QuickStart.pdf` | How containers are signed, the PKI tree, the HSM back end |

### The Code Signing Tool in the build

The build never reads the Code Signing Tool from this tree. It takes the tool's directory from `CST_PATH`, which
points at one of two places:

- `tools/cst/cst-3.1.0.tgz` from `jeremyhahn/vendor-nxp`, extracted outside this repository;
- NXP's own CST 3.1.0 download, accepted under its licence (LA_OPT36) and extracted outside this repository.

A build that needs the tool and finds `CST_PATH` unset stops and names the variable. `.gitignore` keeps a CST
archive or extracted tree out of the repository.

## CompuLab reference material (private context repository)

The company has no recorded permission to redistribute CompuLab's documents and design files, so they live in the
private context repository `jeremyhahn/vendor-compulab`. They are reference material only: they describe another
i.MX 95 board, not our device.

| Path in `jeremyhahn/vendor-compulab` | Document | Read it for |
|---|---|---|
| `docs/ucm-imx95/ucm-imx95_reference-guide_2026-08-13.pdf` | CompuLab UCM-iMX95 Reference Guide | How a module vendor exposes the same processor |
| `docs/ucm-imx95/EB-EVCAMRPI-datasheet.pdf` | CompuLab EB-EVCAMRPI camera evaluation board datasheet | Reference only |
| `design/ucm-imx95/` | SB-UCMIMX95 carrier design files, UCM-iMX95 mechanical drawings and 3D model | Reference only (see [resources/README.md](../../resources/README.md)) |

## Vendor SDKs and documentation online

| Where | What |
|---|---|
| https://github.com/nxp-mcuxpresso/spsdk | NXP Secure Provisioning SDK: AHAB container signing, fuse programming, the enclave provisioning tools |
| https://github.com/nxp-mcuxpresso/mcuxsdk-doc | MCUXpresso SDK documentation sources |
| https://mcuxpresso.nxp.com/mcuxsdk/latest/introduction/README.html | MCUXpresso SDK documentation, the M7 and M33 drivers and boot flow |

## Missing documents

The SPEC's release criteria need six document sets that are not in this file's tables ([SPEC.md](../SPEC.md),
Release criteria). For each one, this section gives the SPEC rows that need it, what it would answer, how it can be
obtained, and the public sources that answer part of it. Public sources were checked on 2026-11-12. Where this
section says *not confirmed*, the fact could not be checked from a public source and must not be relied on. When a
missing document is obtained, it goes into `jeremyhahn/vendor-nxp` (or a new private context repository for a
non-NXP vendor), never into this repository, and its row moves into the tables above.

### Summary

| Document | SPEC rows that need it | Access | Public substitute (partial) |
|---|---|---|---|
| IMX95RM, i.MX 95 Applications Processor Reference Manual | boot-container, system-manager-config, oem-key-provisioning, secure-world, hsm-self-defence | NXP account login | U-Boot i.MX 95 EVK and AHAB documentation; the System Manager sources |
| i.MX 95 Security Reference Manual | boot-container, oem-key-provisioning, secure-key-handling, secure-world, hsm-self-defence | Not on the public product page; NDA (not confirmed) | U-Boot AHAB documentation; RM00284 (held) |
| System Manager documentation | system-manager-config, hsm-self-defence, boot-container | Open (built from public sources) | It is its own substitute: the SM Reference Manual builds from `nxp-imx/imx-sm` |
| NXP Linux BSP documentation | platform-image, device-lifecycle | Open | UG10163 and UG10164 are the documents themselves; `nxp-imx/meta-imx` |
| SE051 documentation | secure-key-handling, device-lifecycle | Open (data sheet, application notes); some items via NXP's download service (not confirmed) | The SE051 data sheet, AN12973 |
| 10 GbE expansion card documentation | hsm-device-protocol | Unknown: the card is not named | None found. Open, owner |

### IMX95RM, i.MX 95 Applications Processor Reference Manual

- **Rows.** `boot-container` (the AHAB version field, the fuse map for the key hashes, the boot ROM behaviour),
  `system-manager-config` (clocks, power domains, resources the System Manager hands out), `oem-key-provisioning`
  (the i.MX 95 fuse map and life-cycle effects), `secure-world` and `hsm-self-defence` (the SPEC says the TrustZone
  configuration and the EdgeLock tamper pins are in a missing document; whether that document is IMX95RM or the
  Security Reference Manual is not confirmed).
- **Would answer.** The programming model of the processor, which the data sheet IMX95CEC refers to IMX95RM for (see
  the table above).
- **Access.** NXP lists it on the i.MX 95 product page as *i.MX 95 Applications Processor Reference Manual
  [IMX95RM]*, Rev 7.0, Nov 9, 2026, served through NXP's download service; the page marks it as needing an NXP
  account. Source: NXP, i.MX 95 Applications Processor Family product page, https://www.nxp.com/products/IMX95.
  Whether an NDA is needed beyond the account is not confirmed.
- **Public substitutes (partial).**
  - Das U-Boot documentation, *imx95_evk*, latest, https://docs.u-boot.org/en/latest/board/nxp/imx95_evk.html: how
    a boot image for the i.MX 95 EVK is assembled (ELE firmware container, System Manager, imx-mkimage), per silicon
    revision. It describes the EVK, not our board.
  - NXP, *imx-sm* README, master, https://github.com/nxp-imx/imx-sm: the boot core (the Cortex-M) runs the boot ROM,
    which loads the System Manager. It does not give the boot ROM's own behaviour.
  - None found for the fuse map or the AHAB version field. Open.

### i.MX 95 Security Reference Manual

- **Rows.** `boot-container` and `oem-key-provisioning` (the AHAB boot flow, the key-hash fuses, the life cycle),
  `secure-key-handling` (the enclave beyond its HSM API), `secure-world` (TrustZone configuration, not confirmed),
  `hsm-self-defence` (the tamper pins, not confirmed).
- **Would answer.** The secure boot flow, the security fuses and the life-cycle states of the i.MX 95. Das U-Boot's
  AHAB introduction sends the reader to each processor's Security Reference Manual for the boot flow (below).
- **Access.** It is not listed among the documents on the public i.MX 95 product page (checked 2026-11-12,
  https://www.nxp.com/products/IMX95). This file has recorded it as NDA; that is not confirmed from a public source.
- **Public substitutes (partial).**
  - Das U-Boot documentation, *i.MX AHAB secure boot* introduction, latest,
    https://docs.u-boot.org/en/latest/imx/ahab/introduction_ahab.html: the AHAB container, the SRK table and the
    SRK hash the SoC checks it against, and the CST tools that build them. It is generic to i.MX 8 and i.MX 9, not
    i.MX 95 specific.
  - Das U-Boot documentation, *i.MX93 Secure boot guide using AHAB*, latest,
    https://docs.u-boot.org/en/latest/imx/ahab/guides/mx93_secure_boot.html: a worked AHAB signing flow for the
    i.MX 93 (another processor), with U-Boot's binman `nxp-imx93cst` etype. Whether the same flow holds on the
    i.MX 95 is not confirmed.
  - NXP RM00284 (held, table above) answers the enclave's HSM API, the monotonic counter and the life-cycle
    commands, not the fuse map.

### System Manager documentation

- **Rows.** `system-manager-config` (the configuration this repository owns), `hsm-self-defence` (the power domains
  and PHYs the M7 acts on through the System Manager), `boot-container` (the System Manager image the container
  carries).
- **Would answer.** The configuration format, the logical machines and their access rights, and the SCMI API the
  Cortex-M7 calls.
- **Access.** Open. NXP's *imx-sm* README says a full *SM Reference Manual* (architecture, developer's, porting and
  configuration guides, protocol description) builds from the sources with doxygen, and that release notes build
  the same way. Source: NXP, *imx-sm*, master, https://github.com/nxp-imx/imx-sm. A configuration tool is at
  https://github.com/nxp-imx/imx-smct. Which release tag the platform image uses is not decided: open, owner.
- **Also needed.** Arm, *System Control and Management Interface (SCMI)*, DEN0056, latest,
  https://developer.arm.com/documentation/den0056/latest/ (the README cites it for the RPC API).

### NXP Linux BSP documentation

- **Rows.** `platform-image` (the SPEC lists the BSP documentation the build needs as missing), `device-lifecycle`
  (the image that is attested).
- **Would answer.** How NXP's Linux BSP is built, booted and configured for the i.MX 95.
- **Access.** Open:
  - NXP UG10163, *i.MX Linux User's Guide*, https://nxp.com/docs/en/user-guide/UG10163.pdf;
  - NXP UG10164, *i.MX Yocto Project User's Guide*, https://nxp.com/docs/en/user-guide/UG10164.pdf;
  - NXP, *meta-imx*, the i.MX Yocto layers, https://github.com/nxp-imx/meta-imx.

  The revision of each guide and the BSP release it matches are not confirmed (the PDFs' revision pages were not
  read). Whether they cover the FRDM-IMX95-PRO, and not only the i.MX 95 EVK, is not confirmed. Which BSP release
  the image follows is the owner's build decision (Release criteria).

### SE051 documentation

- **Rows.** `secure-key-handling` (whether the SE051 on U28 holds any key; open, owner), `device-lifecycle` (if the
  SE051 takes part in attestation; open, owner).
- **Would answer.** The SE051's commands, key types, configurations and attestation, and which variant is fitted.
- **Access.** Open on the EdgeLock SE051 product page, https://www.nxp.com/products/SE051:
  - NXP, *SE051 data sheet*, titled *Plug & Trust Secure Element*, https://www.nxp.com/docs/en/data-sheet/SE051.pdf;
  - NXP AN12973, *SE051 configurations*, https://www.nxp.com/docs/en/application-note/AN12973.pdf;
  - NXP AN13030, *Plug & Trust Middleware Documentation*, and the SE051 errata sheet, both through NXP's download
    service; whether they need a login is not confirmed;
  - NXP AN13254, *Secure attestation with EdgeLock SE05x*, listed on the same page.

  Revisions are not confirmed. Which SE051 variant and configuration U28 carries is not confirmed: UM12527 gives
  the part, address and header (SPEC `secure-key-handling`), and the variant must be read from the board.

### 10 GbE expansion card documentation

- **Rows.** `hsm-device-protocol` (the 10 GbE transport on the Slim-SAS connector, UM12527 §2.18).
- **Would answer.** The card's PHY or controller, its Linux driver, and how it attaches to the Slim-SAS connector.
- **Access.** Unknown. The SPEC says the card is not in the board kit; no public source found names the card.
  Open, owner: which card.
- **Public substitutes.** None found.

### The CST executable under CST_PATH

The build runs CST's `cst` executable as `$CST_PATH/linux64/bin/cst`, where `CST_PATH` is the top of an extracted
CST release (the directory that holds `linux64/`; in `tools/cst/cst-3.1.0.tgz` that is `release/`). Beside it in
`linux64/bin/` are `srktool`, which builds the SRK table and SRK hash, and `ahab_pki_tree`, which builds the AHAB
PKI tree. Das U-Boot's AHAB introduction (above) places `srktool` and `ahab_pki_tree` in `linux64/bin/` of the CST
package; that `cst` sits in the same directory of CST 3.1.0 is not confirmed from a public source and must be checked
against the archive in `jeremyhahn/vendor-nxp` when the build is written. No build target uses `CST_PATH` yet. The
same introduction shows `ahab_pki_tree` features "starting from v4.0.0", so CST 4.x exists; whether CST 3.1.0 is
enough for the i.MX 95's AHAB containers is not confirmed. Open, owner.
