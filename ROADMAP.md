# Roadmap

> **Status: REFERENCE** · Last verified: 2026-11-06
> What is complete and what remains, in milestone order. Features and requirements: [docs/SPEC.md](docs/SPEC.md).

## Mission

The device repository for the NXP FRDM-IMX95-PRO, the portfolio's first HSM device: its firmware, Linux image, secure world and secure key handling.
go-xkms defines its wire protocol and runs xkmsd on it; go-trusted-platform provisions, enrolls and attests it and its image.
Every hardware design cites the vendor documents in [docs/references/](docs/references/README.md).

## Milestones

None yet: a milestone opens once the owner approves this file and docs/SPEC.md.

## Complete

None yet.

## Now

None yet.

## Next

None yet.

## Later

Planned, undated. No issue is filed yet; each line gets its issue once the owner approves this file.

- **platform-image** — the board's Linux image, booting from the eMMC and running xkmsd — no issue yet — blocked: owner approval; image build open
- **boot-container** — the AHAB-signed boot container, signed with keys in HSM custody — no issue yet — blocked: owner approval; IMX95RM and the Security Reference Manual missing
- **system-manager-config** — NXP's System Manager configured for the Cortex-M7 over SCMI — no issue yet — blocked: owner approval; System Manager documentation missing
- **secure-world** — the Cortex-A55 secure world of owner ruling 771: upstream TF-A (BL31) and the NXP BSP's OP-TEE with the fTPM and PKCS#11 TAs, configured and built here — no issue yet — blocked: owner approval; needs platform-image, and boot-container to sign the BL31 and OP-TEE images; go-xkms's PKCS#11 backend and go-trusted-platform consume it
  - (a) Pin the BSP: the NXP Linux BSP release tag, and the TF-A, OP-TEE and `imx-optee-os` revisions it carries (to be pinned).
  - (b) Reproducible build: pinned sources, toolchain and build command; a byte-for-byte rebuild check; the OP-TEE configuration flags that enable the fTPM and PKCS#11 TAs.
  - (c) Verification on the board: TF-A and OP-TEE banners in the boot log; `/dev/tee0` and `/dev/tpmrm0` present; `tpm2_getcap` or an equivalent; `pkcs11-tool --list-slots` against the OP-TEE PKCS#11 TA; `xtest` if the BSP ships it. Hardware runs happen on the lab's board host, one lane at a time, with any boot-media change announced first.
- **secure-key-handling** — keys held in the EdgeLock key store, never in the clear — no issue yet — blocked: owner approval; calling side and SE051 role open
- **oem-key-provisioning** — OEM keys imported and the life cycle closed through the enclave — no issue yet — blocked: owner approval; IMX95RM and the Security Reference Manual missing
- **hsm-device-protocol** — the device side of go-xkms's xkmsd-to-device protocol over 1 GbE and 10 GbE — no issue yet — blocked: owner approval; owner-queue item 160 (`go-xkms#1521`)
- **device-lifecycle** — the device side of go-trusted-platform's provisioning, enrollment and attestation — no issue yet — blocked: owner approval; evidence open
- **hsm-self-defence** — the HSM device side of the Cortex-M7 tamper response — no issue yet — blocked: owner approval; A55 side open

## Future

None.

## Dependencies

Upstream:

- go-xkms defines the wire protocol, `hsm-device-protocol` — `go-xkms#1521`.
- go-trusted-platform provisions and attests the device, `hsm-device-lifecycle` — `go-trusted-platform#884`.
- trusted-firmware's Cortex-M7 firmware on the board: its `imx95` row (`trusted-firmware#49`, closed 2026-10-25, the `frdm-imx95-m7` board) and its `hsm-self-defence` row (`trusted-firmware#50`, closed 2026-10-27); both sit on its open Cortex-M port, `trusted-firmware#161`, and its Phase 5 epic, `trusted-firmware#22`.
- The vendor documents listed as missing in [docs/references/](docs/references/README.md).
- Upstream Arm TF-A and NXP's Linux BSP release, which carries the OP-TEE OS the `secure-world` row builds (owner ruling 771); the release is to be pinned.

Downstream:

- go-xkms's `hsm-device-protocol` and go-trusted-platform's `hsm-device-lifecycle` need this repository's device side.
- go-xkms's PKCS#11 backend uses the OP-TEE PKCS#11 TA, and go-trusted-platform uses the firmware TPM through `/dev/tpmrm0` (`secure-world` row).
