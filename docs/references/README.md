# References

Vendor documents every agent reads before designing, building or debugging on this board. A design, ADR, issue or
PR about board hardware, boot, debug or connectors cites the document and section it rests on.

| File | Document | Covers | Read it for |
|---|---|---|---|
| [UM12527-FRDM-IMX95-PRO-board-user-manual.pdf](UM12527-FRDM-IMX95-PRO-board-user-manual.pdf) | NXP UM12527, FRDM-IMX95-PRO Board User Manual, Rev. 1.0 | The board as a hardware system: block diagram; features (i.MX 95 with six Cortex-A55, one Cortex-M33, one Cortex-M7 and the NPU; 16 GB LPDDR5; 32 GB eMMC 5.1 and microSD; 512 Mbit QSPI NOR; USB; two RGMII Ethernet PHYs and the 10G SlimSAS; CAN; M.2 Key-E and two Key-M; MIPI; LVDS to HDMI; audio); boot configuration (eMMC default, SD, FlexSPI NOR); the CH9114F debug bridge with one COM port per core (A55, M33, M7); power (PF09, PF5301, PF5302); expansion and custom headers; jumpers and switches | Which interface and which core a feature uses, how the board boots and is debugged, what is wired to what, before any firmware or Linux-image work |

Missing and to be added when supplied by the owner: the i.MX 95 Applications Processor Reference Manual, the i.MX 95
data sheet, the i.MX 95 Security Reference Manual, the EdgeLock secure enclave API and firmware guide, the i.MX Code
Signing Tool (AHAB) user guide, and the MCUXpresso SDK documentation for the i.MX 95 M7 and M33.
