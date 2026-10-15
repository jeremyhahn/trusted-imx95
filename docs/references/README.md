# References

Vendor documents every agent reads before designing, building or debugging on this device. A design, ADR, issue or
PR about the hardware, boot, security, signing or connectors cites the document and section it rests on. A fact the
documents do not give is reported as missing, never guessed.

## The device

The device is the CompuLab UCM-iMX95 system-on-module on its SB-UCMIMX95 carrier board, built on the NXP i.MX 95
(six Cortex-A55, one Cortex-M33, one Cortex-M7, the EdgeLock secure enclave, the NPU). The NXP FRDM-IMX95-PRO manual
is kept for the reference design of the same processor.

## Documents

| File | Document | Read it for |
|---|---|---|
| [imx95/ucm-imx95_reference-guide_2026-08-13.pdf](imx95/ucm-imx95_reference-guide_2026-08-13.pdf) | CompuLab UCM-iMX95 Reference Guide | The module: pinout, interfaces, boot, power, the carrier connectors |
| [imx95/IMX95CEC.pdf](imx95/IMX95CEC.pdf) | NXP IMX95CEC, i.MX 95 Applications Processors Data Sheet for Commercial Products, Rev. 8 | Electrical, pin and package facts of the processor; it refers to IMX95RM for the programming model |
| [imx95/UM12527-FRDM-IMX95-PRO-board-user-manual.pdf](imx95/UM12527-FRDM-IMX95-PRO-board-user-manual.pdf) | NXP UM12527, FRDM-IMX95-PRO Board User Manual, Rev. 1.0 | NXP's reference board for the same processor: block diagram, boot modes, per-core debug ports |
| [imx95/EB-EVCAMRPI-datasheet.pdf](imx95/EB-EVCAMRPI-datasheet.pdf) | CompuLab EB-EVCAMRPI camera evaluation board datasheet | The camera board's interface when it is attached |
| [edgelock/RM00284.pdf](edgelock/RM00284.pdf) | NXP RM00284, EdgeLock Enclave Hardware Security Module API, Rev. 4.5 | The enclave's HSM API on the i.MX 95: key store, signing, secure storage, counters, attestation; the source for every secure-element seam and for the anti-rollback floor |
| [edgelock/AN14861.pdf](edgelock/AN14861.pdf) | NXP AN14861, Secure OEM Key Provisioning with EdgeLock Secure Enclave, Rev. 1.0 | The vendor's OEM key-provisioning flow (written for the RT1180; the enclave flow is the same family) |
| [code-signing/AN14471.pdf](code-signing/AN14471.pdf) | NXP AN14471, Using Hardware Security Module for Code Signing, Rev. 1.0 | Signing AHAB containers with keys held in an HSM; the model for go-xkms custody |
| [code-signing/HSM Code-Signing Journey_07JUN2024.pdf](code-signing/HSM%20Code-Signing%20Journey_07JUN2024.pdf) | NXP presentation, HSM Code-Signing Journey | The overview of the HSM-backed signing flow |
| [cst-3.1.0.tgz](cst-3.1.0.tgz) | NXP Code Signing Tool 3.1.0 (sources, PKI scripts, HSM back end) with its documents inside: release/docs/CST_UG.pdf, release/docs/HAB4_API.pdf, release/code/back_end-hsm/doc/CST-HSM_UG.pdf, HSM-CST_UG.pdf, HSM-CST-Architecture.pdf, HSM-CST_QuickStart.pdf | How containers are signed, the PKI tree, the HSM back end; extract it outside the repository to read or build |

## Vendor SDKs and documentation online

| Where | What |
|---|---|
| https://github.com/nxp-mcuxpresso/spsdk | NXP Secure Provisioning SDK: AHAB container signing, fuse programming, the enclave provisioning tools |
| https://github.com/nxp-mcuxpresso/mcuxsdk-doc | MCUXpresso SDK documentation sources |
| https://mcuxpresso.nxp.com/mcuxsdk/latest/introduction/README.html | MCUXpresso SDK documentation, the M7 and M33 drivers and boot flow |

## Still missing

The i.MX 95 Applications Processor Reference Manual (IMX95RM) and the i.MX 95 Security Reference Manual (NDA): the
fuse map, the AHAB version field and the boot ROM behaviour come from them.
