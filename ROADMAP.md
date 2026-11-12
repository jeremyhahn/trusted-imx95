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
- **system-manager-config** — NXP's System Manager configured for the Cortex-M7 over SCMI — issue #13 — blocked: owner approval; System Manager documentation missing

## Next

None yet.

## Later

Planned, undated. No issue is filed yet; each line gets its issue once the owner approves this file.

- **platform-image** — the board's Linux image, booting from the eMMC and running xkmsd — no issue yet — blocked: owner approval; image build open
- **secure-world** — the board's secure world — no issue yet — blocked: owner approval; scope open
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

Downstream:

- go-xkms's `hsm-device-protocol` and go-trusted-platform's `hsm-device-lifecycle` need this repository's device side.
