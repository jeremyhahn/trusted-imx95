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

## Still missing

Two NXP manuals are missing: the i.MX 95 Applications Processor Reference Manual (IMX95RM) and the i.MX 95 Security
Reference Manual (NDA). The fuse map, the AHAB version field and the boot ROM behaviour come from them. When they
are obtained, they go into `jeremyhahn/vendor-nxp`, not here.
