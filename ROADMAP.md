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

- **boot-container** — the AHAB-signed boot container, signed with keys in HSM custody — issue #12 — blocked: owner approval; IMX95RM and the Security Reference Manual missing
- **system-manager-config** — NXP's System Manager configured for the Cortex-M7 over SCMI — issue #13 — pinned, reproducible System Manager build exists (`make system-manager`, [build record](docs/system-manager-config/build.md)); imx-sm revision provisional until #14 Q2; board configuration unchanged, not flashed or signed — approved after the survey of #167 (owner rulings 1243 and 1244)
- **maintenance** — the standing row for dependency updates and CI-configuration changes, worked on `row/178-maintenance`; it never closes and gates no release, so it sits outside every release-gating milestone (owner ruling 1234) — issue #178 — standing; the next `ci.yml` template adoption lands from it

## Next

None yet.

## Later

Planned, undated. No issue is filed yet; each line gets its issue once the owner approves this file.

- **platform-image** — the board's Linux image, booting from the eMMC and running xkmsd — no issue yet — blocked: owner approval; image build open
- **secure-world** — the Cortex-A55 secure world of owner ruling 771, with BL31 per ruling 1234: NXP's `imx-atf` from the BSP release and the NXP BSP's OP-TEE with the PKCS#11 TA, hosting the `ftpm` entry's firmware TPM TA, configured and built here — no issue yet — blocked: owner approval; needs platform-image, and boot-container to sign the BL31 and OP-TEE images; go-xkms's PKCS#11 backend and go-trusted-platform consume it
  - (a) Pin the BSP: the NXP Linux BSP release tag, and the OP-TEE and `imx-optee-os` revisions it carries; BL31 is NXP's `imx-atf` at the BSP's revision (owner ruling 1234, which counts `imx-atf` as upstream TF-A and drops ruling 771's upstream v2.15.0 pin). State: sources pinned in `secure-world/bsp.lock`, with the BSP release `lf-6.18.37-2.1.0` PROVISIONAL until the owner chooses the baseline (#14 Q2); not complete.
  - (b) Reproducible build: pinned sources, toolchain and build command; a byte-for-byte rebuild check; the OP-TEE configuration flags that enable the PKCS#11 TA (the fTPM TA's flags are the `ftpm` entry's). State: `make secure-world` builds both artefacts with a SHA-256 manifest; `scripts/secure-world-build.sh` builds twice in clean directories and fails unless both outputs are identical, and the `secure-world-build` CI job runs it. Nothing has run on the board.
  - (c) Verification on the board: TF-A and OP-TEE banners in the boot log; `/dev/tee0` present; `pkcs11-tool --list-slots` against the OP-TEE PKCS#11 TA; `xtest` if the BSP ships it. Hardware runs happen on the lab's board host, one lane at a time, with any boot-media change announced first.
- **ftpm** — the board's firmware TPM 2.0 of owner ruling 927: the OP-TEE fTPM TA, the Linux `tpm_ftpm_tee` driver and `/dev/tpmrm0`, the TPM's NV storage, a first-boot EK certified by go-xkms, and measured boot — issue #140 — approved with the REE FS on development boards, no rollback protection, NV lost when the root file system is reflashed, RPMB key NOT programmed (owner rulings 1243 and 1244); needs secure-world, platform-image, boot-container, and go-xkms's endorse-01, enroll-01 and device-attest-01; the redeploy is coordinated with Infra
  - (a) Build configuration: the OP-TEE `CFG_` flags that build the fTPM TA as an early TA, and the TA's source revision (to be pinned); the kernel's `CONFIG_TCG_FTPM_TEE`; the secure-storage selection, RPMB or REE FS (RPMB only with the owner's approval of programming its key). State: OP-TEE side built: `optee_ftpm` 4.10.0 on the pinned `ms-tpm-20-ref`, an early TA, NV in REE FS. The kernel's `CONFIG_TCG_FTPM_TEE` remains, with the image build.
  - (b) Reproducible image build: the (a) configuration in the pinned image build, with a byte-for-byte rebuild check.
  - (c) Board test on the lab's board host: `tpm2_getcap`; `tpm2_createek`, or a read of the EK at its persistent handle; the same EK after a reboot. One lane at a time, the boot media unchanged (owner ruling 769), the redeploy coordinated with Infra together with the xkmsd web-console build and the barrier re-init.
  - (d) Provisioning: go-xkms endorse-01 issues the EK certificate, then enroll-01, then device-attest-01 in the `tpm` format.
  - (e) Measured boot: each stage that can extend the fTPM PCRs does, and each gap in [docs/ftpm/](docs/ftpm/README.md#measured-boot) is closed or accepted by the owner.
- **secure-key-handling** — keys held in the EdgeLock key store, never in the clear — no issue yet — blocked: owner approval; calling side and SE051 role open
- **oem-key-provisioning** — OEM keys imported and the life cycle closed through the enclave — no issue yet — blocked: owner approval; IMX95RM and the Security Reference Manual missing
- **hsm-device-protocol** — the device side of go-xkms's xkmsd-to-device protocol over 1 GbE and 10 GbE — issue #24 — the HSM is an xkmsd node (owner rulings 1243 and 1244); needs go-xkms's wire protocol (`go-xkms#1521`)
- **device-lifecycle** — the device side of go-trusted-platform's provisioning, enrollment and attestation — no issue yet — blocked: owner approval; per owner ruling 1234 the device first presents an EdgeLock enclave attestation (RM00284 §3.12, requested by the Cortex-A55), then go-xkms endorse-01 certifies the fTPM EK, then enroll-01 and device-attest-01 in the `tpm` format (ruling 927); the root, the EK binding and the wire format are open for go-xkms and go-trusted-platform
- **hsm-self-defence** — the HSM device side of the Cortex-M7 tamper response — issue #26 — later (owner rulings 1243 and 1244); blocked: owner approval; A55 side open

## Future

None.

## Dependencies

Upstream:

- go-xkms defines the wire protocol, `hsm-device-protocol` — `go-xkms#1521`.
- go-trusted-platform provisions and attests the device, `hsm-device-lifecycle` — `go-trusted-platform#884`.
- trusted-firmware's Cortex-M7 firmware on the board: its `imx95` row (`trusted-firmware#49`, closed 2026-10-25, the `frdm-imx95-m7` board) and its `hsm-self-defence` row (`trusted-firmware#50`, closed 2026-10-27); both sit on its open Cortex-M port, `trusted-firmware#161`, and its Phase 5 epic, `trusted-firmware#22`.
- The vendor documents listed as missing in [docs/references/](docs/references/README.md).
- NXP's Linux BSP release, which carries the `imx-atf` BL31 (owner ruling 1234) and the OP-TEE OS (owner ruling 771) the `secure-world` row builds; the release is provisional (#14).
- OP-TEE's `optee_ftpm` TA and Microsoft's `ms-tpm-20-ref`, at a revision to be pinned (`ftpm` row, owner ruling 927).
- go-xkms's endorse-01, enroll-01 and device-attest-01 workflows, which provision the board through its firmware TPM (`ftpm` row).

Downstream:

- go-xkms's `hsm-device-protocol` and go-trusted-platform's `hsm-device-lifecycle` need this repository's device side.
- go-xkms's PKCS#11 backend uses the OP-TEE PKCS#11 TA, and go-trusted-platform uses the firmware TPM through `/dev/tpmrm0` (`secure-world` and `ftpm` rows).
