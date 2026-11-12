# Threat model: the FRDM-IMX95-PRO device (draft)

> **Status: DRAFT** for the owner's review. It does not change [SPEC.md](SPEC.md); where they conflict, SPEC wins.

Scope: the device that [SPEC.md](SPEC.md) describes, the NXP FRDM-IMX95-PRO. Its rows are `platform-image`,
`boot-container`, `system-manager-config`, `secure-world`, `secure-key-handling`, `oem-key-provisioning`,
`hsm-device-protocol`, `device-lifecycle` and `hsm-self-defence`. For each threat, this document names the SPEC row
that mitigates it, or marks it **open, owner** when no row does or when the row leaves the decision to the owner.

Rules this document keeps: it contains no keys, no fuse steps and no life-cycle steps. The life-cycle and fuse
behaviour is described only as far as SPEC states it. It copies no vendor text. A vendor fact is cited through the
SPEC row that states it, together with the section that row cites. The vendor documents themselves are in the
private context repository (see [references/README.md](references/README.md)), and this document does not cite them
directly. A point that neither SPEC nor a public source settles is marked **unconfirmed**.

## Sources

| Id | Title | Version | URL | Used for |
|---|---|---|---|---|
| P1 | trusted-imx95 specification, `docs/SPEC.md` | Last verified 2026-11-06 | [SPEC.md](SPEC.md) | Every row cited below |
| P2 | trusted-imx95 references, `docs/references/README.md` | As of the current `main` | [references/README.md](references/README.md) | CST_PATH, the missing documents |
| P3 | NXP Secure Provisioning SDK (SPSDK) | Repository head, version not pinned (**unconfirmed**) | https://github.com/nxp-mcuxpresso/spsdk | That a public tool exists for AHAB container signing and enclave provisioning (P2) |
| P4 | MCUXpresso SDK documentation | "latest", version not pinned (**unconfirmed**) | https://mcuxpresso.nxp.com/mcuxsdk/latest/introduction/README.html | The M7 and M33 boot flow (P2) |

The NXP documents that SPEC cites (UM12527, RM00284, AN14471, AN14861, the CST 3.1.0 guides) are accessed under
NXP's click-through terms (P2). Whether each one is also publicly downloadable without a login was not checked:
**unconfirmed**.

## Assets

| Id | Asset | Row |
|---|---|---|
| A1 | The signed boot container and the images it carries, including the Cortex-M7 image of trusted-firmware's `imx95` row | `boot-container` |
| A2 | The container signing keys. The HSM holds them (AN14471 §3.1, §3.6, via `boot-container`) | `boot-container` |
| A3 | The anti-rollback floor: the monotonic counter and the AHAB version field (RM00284 §3.24, via `boot-container`) | `boot-container`, `secure-key-handling` |
| A4 | The keys in the EdgeLock enclave's key store, which never leave it in the clear (RM00284 §2.4, §3.2, via `secure-key-handling`) | `secure-key-handling` |
| A5 | The integrity of the key store against rollback (RM00284 §2.4.2, via `secure-key-handling`) | `secure-key-handling` |
| A6 | The OEM keys, while they are provisioned (AN14861 §2, §5.2, §5.3, via `oem-key-provisioning`) | `oem-key-provisioning` |
| A7 | The device's life-cycle state, OEM open or OEM closed (RM00284 §3.23, via `oem-key-provisioning`) | `oem-key-provisioning` |
| A8 | The Linux platform image and the xkmsd process running on it | `platform-image` |
| A9 | The System Manager configuration: clocks, power, resources, power domains, PHYs | `system-manager-config` |
| A10 | Device and image attestation evidence (RM00284 §3.12, via `device-lifecycle`) | `device-lifecycle` |
| A11 | Traffic of the device protocol between xkmsd and the board | `hsm-device-protocol` |
| A12 | The SE051 secure element on I2C2 and any key it might hold (UM12527 §1.1, §2.5, via `secure-key-handling`) | `secure-key-handling`, open, owner |

## Trust boundaries

| Id | Boundary | Source |
|---|---|---|
| B1 | Signing HSM to build: containers are signed with keys held in the HSM, and the CST is taken from `CST_PATH` and never from this tree | `boot-container`, P2 |
| B2 | Boot media to SoC: eMMC on uSDHC1 by default, microSD or FlexSPI NOR set by SW4 | `platform-image` (UM12527 §2.3, §2.6, §2.9, §2.10) |
| B3 | Cortex-A55 Linux to the EdgeLock enclave, through the HSM API | `secure-key-handling` (RM00284 §3.4, §3.8, §3.12) |
| B4 | Cortex-M7 firmware to the enclave. Which side calls the HSM API, A55 or M7, is **open, owner** | `secure-key-handling` |
| B5 | Cortex-M7 to the System Manager on the Cortex-M33, over SCMI | `system-manager-config` |
| B6 | Normal world to secure world. Its scope is **open, owner** | `secure-world` |
| B7 | SoC to the SE051 on I2C2, address 0x48 | `secure-key-handling` (UM12527 §1.5, §2.5) |
| B8 | Device to network: two 1 GbE ports and a 10 GbE card on Slim-SAS, carrying the go-xkms protocol | `hsm-device-protocol` (UM12527 §1.2, §2.18) |
| B9 | Device to go-trusted-platform's control plane: provisioning, enrolment, attestation | `device-lifecycle` |
| B10 | Physical access to the board: SW4 boot modes, the USB serial downloader, the debug UARTs on J22, the J4 header | SPEC Interfaces (UM12527 §2.3, §2.19), `secure-key-handling` |

## Attacker classes

| Id | Attacker | Assumed capability |
|---|---|---|
| T-NET | Remote attacker | Reads, injects, drops and replays traffic on B8 and B9 |
| T-SW | Local software attacker | Runs code in Linux on the A55, up to root after an exploit |
| T-PHY | Physical attacker, low cost | Holds the board: rewrites boot media, sets SW4, uses the serial downloader, J22 and J4, probes I2C2 |
| T-LAB | Physical attacker, lab grade | Fault injection, side channels, invasive attacks |
| T-SUP | Build and supply chain attacker | Tampers with sources, the toolchain or the CST tree under `CST_PATH`, or with the board before provisioning |
| T-INS | Insider | Can ask the signing HSM to sign, or runs provisioning |

## Threats

| Id | Threat | Attacker | Assets | Mitigated by |
|---|---|---|---|---|
| TH1 | A modified container or M7 image is written to boot media | T-PHY, T-SW | A1 | `boot-container`: AHAB secure boot verifies the M7 image as a signed container before it runs. Which other images the container covers (Linux, the A55 boot chain) is not stated: **open, owner** |
| TH2 | A boot mode or the serial downloader is used to load an unsigned image | T-PHY | A1, A8 | **Unconfirmed**: the boot ROM behaviour in each SW4 mode comes from IMX95RM and the Security Reference Manual, both missing (`boot-container`) |
| TH3 | The signing keys are stolen | T-SUP, T-SW on the build host | A2 | `boot-container`: keys held in an HSM, after AN14471 §3.1, §3.6 |
| TH4 | An insider has the HSM sign a malicious container | T-INS | A2, A1 | **Open, owner**: no row requires signing approval or an audit trail |
| TH5 | A tampered CST, or one in the wrong version, under `CST_PATH` | T-SUP | A1, A2 | Partly: `boot-container` names CST 3.1.0 or SPSDK, and P2 keeps the tool out of the tree. Pinning a checksum of the tool is **open, owner** |
| TH6 | An older, validly signed, vulnerable container is booted | T-PHY, T-NET | A3, A1 | `boot-container`: the anti-rollback floor (RM00284 §3.24 and the AHAB version field). The version field's format is **unconfirmed** (IMX95RM, missing). The one public i.MX 95 source found says a too-old container still boots in OEM open and is refused only in OEM closed or locked ([verified-boot survey §3.8](platform-image/verified-boot-survey.md)); this is **unverified** on the target, and the floor covers the containers only, not the OS |
| TH7 | The key store is rolled back to an earlier state | T-PHY | A5, A4 | `secure-key-handling`: an update counts only after a strict-operation acknowledgement, which advances the monotonic counter (RM00284 §2.4.2). The surveys propose a refinement, **pending owner approval**: in the ELE library headers the counter is advanced by a separate monotonic flag, so both flags would be required ([decommission survey §4.1](device-lifecycle/decommission-survey.md)). Whether a restored earlier store is rejected after a reset is **to be validated** on the target |
| TH8 | A key is extracted from the enclave in the clear | T-SW, T-PHY | A4 | `secure-key-handling`: keys are generated and held in the key store and never leave it in the clear (RM00284 §2.4, §3.2) |
| TH9 | Root on Linux uses the enclave as a signing oracle | T-SW | A4 | **Open, owner**: no row binds key use to an attested state. Which side calls the HSM API is also open (`secure-key-handling`) |
| TH10 | The OEM keys are intercepted while they are provisioned | T-INS, T-SUP, T-NET | A6 | `oem-key-provisioning`: key exchange, then the import of a wrapped key (AN14861 §2, §5.2, §5.3; RM00284 §3.20). AN14861 is written for the RT1180, so whether it applies to the i.MX 95 is **unconfirmed**. Where provisioning runs is **open, owner** |
| TH11 | A board left in OEM open, or closed too late, is reprovisioned | T-PHY, T-SUP | A7, A6 | `oem-key-provisioning` names the move to OEM closed (RM00284 §3.23). When the life cycle is closed is **open, owner**. Its i.MX 95 effects are **unconfirmed** (IMX95RM and the Security Reference Manual, both missing) |
| TH12 | The System Manager configuration is changed to cut power, clocks or PHYs, or to reassign resources | T-SUP, T-SW | A9 | `system-manager-config` holds the configuration. How it is authenticated at boot is **unconfirmed** (the System Manager documentation is missing) |
| TH13 | The normal world reads secure-world memory or calls into it | T-SW | A4, A8 | **Open, owner**: the scope of `secure-world` is undecided, and no reference gives the TrustZone configuration |
| TH14 | An interposer on I2C2 reads or alters SE051 traffic | T-PHY | A12 | **Open, owner**: the SE051's role is undecided and its documentation is missing (`secure-key-handling`) |
| TH15 | The device protocol is spoofed, replayed or altered on the network | T-NET | A11 | **Open, owner**: no device-side requirement exists until go-xkms #1521 is answered (`hsm-device-protocol`) |
| TH16 | Attestation evidence is forged or replayed, or chains to the wrong root | T-SW, T-NET | A10 | `device-lifecycle`: enclave attestation (RM00284 §3.12). The evidence and its root are **open, owner** |
| TH17 | Linux or xkmsd is compromised at runtime, after a clean boot | T-NET, T-SW | A8, A11 | **Open, owner**: `platform-image` sets no runtime integrity or hardening requirement, and the IMA log is undecided (`hsm-self-defence`) |
| TH18 | Debug access through J22 or other debug ports | T-PHY | A4, A8 | **Open, owner**: no row covers debug access in production. The port mapping is not fixed (UM12527 §2.19, via SPEC Interfaces) |
| TH19 | Physical tampering with the board or enclosure is not detected or answered | T-PHY | A4, A9 | `hsm-self-defence`: power domains, PHYs, key zeroisation and shutdown through the System Manager and the enclave. The EdgeLock tamper pins are **unconfirmed** (document missing). A durable key zeroisation path that stays available during the response is **unresolved** ([tamper survey](hsm-self-defence/tamper-survey.md), question 3). The A55 side is **open, owner** |
| TH20 | Fault injection or side channels bypass verification or leak keys | T-LAB | A1, A4 | **Open, owner**: no row. How resistant the enclave and SE051 are was not checked: **unconfirmed** |
| TH21 | DRAM is read by probing or a cold boot | T-PHY, T-LAB | A4, A8 | **Open, owner**: no row covers memory encryption. Whether the i.MX 95 offers it is **unconfirmed** (IMX95RM, missing) |
| TH22 | The 10 GbE card, which is not in the kit, is malicious or reaches memory by DMA | T-SUP, T-PHY | A8, A11 | **Open, owner**: its documentation is missing (`hsm-device-protocol`), and no row covers DMA isolation |
| TH23 | A flood on the network or control plane blocks the protocol or attestation | T-NET | A10, A11 | **Open, owner**: availability has no row |
| TH24 | The build is compromised before signing (sources, toolchain, the Yocto layers) | T-SUP | A1, A8 | **Open, owner**: how the platform image is built is undecided (SPEC Release criteria) |

## Open items for the owner

1. What the boot container covers beyond the M7 image (TH1), and the boot ROM behaviour in each boot mode (TH2;
   IMX95RM and the Security Reference Manual, #47).
2. Signing governance (TH4), and pinning the CST executable under `CST_PATH` by version and checksum (TH5).
3. Where provisioning runs, and when the life cycle is closed (TH10, TH11). These are SPEC's own open questions.
4. Which side calls the HSM API, and binding key use to an attested state (TH9).
5. The scope of the secure world (TH13), the role of the SE051 (TH14), and the attestation evidence and its root (TH16).
6. The device-side protocol security, once go-xkms #1521 is answered (TH15).
7. Runtime integrity of Linux and xkmsd, and the IMA log (TH17). Debug access in production (TH18). The A55 side of
   tamper response (TH19).
8. Decisions to make or defer: fault and side-channel resistance, memory encryption, DMA isolation for the 10 GbE
   card, availability, and how the build is secured (TH20 to TH24).

## Not confirmed

- The AHAB version field, the fuse map for the key hashes and the boot ROM behaviour: IMX95RM and the Security
  Reference Manual, both missing (`boot-container`).
- How the System Manager configuration is authenticated (TH12): the System Manager documentation is missing.
- Whether AN14861, written for the RT1180, matches the i.MX 95 flow (TH10).
- The EdgeLock tamper pins (TH19), the SE051 interface (TH14) and the 10 GbE card (TH22): their documents are missing.
- Whether the NXP documents that SPEC cites are publicly downloadable without a login.
- The versions of P3 and P4: neither is pinned.
