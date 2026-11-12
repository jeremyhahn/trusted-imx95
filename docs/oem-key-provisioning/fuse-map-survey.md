# i.MX 95 fuse map and OEM programming plan: a survey

Row: oem-key-provisioning ([SPEC](../SPEC.md)). Issue #99. Status: draft, for the owner's review.

This is documentation only. Nothing here writes a fuse, changes the life cycle or
scripts a provisioning step. Every statement is a summary, in this repository's
own words, of a public source listed in [Sources](#sources). Where a source could
not be read or a point could not be confirmed, the text says so.

## 1. Scope and method

Issue #99 asks which i.MX 95 fuse words the OEM provisioning flow writes (SRK
hash, life cycle, debug, boot configuration, anti-rollback), in what order, which
writes cannot be undone, and which tools perform them. It also asks for a plan the
owner approves before any fuse is touched.

Method: NXP's public GitHub repositories and the upstream SPSDK documentation and
source were read at the tags or branches listed in section 2. The i.MX 95
Reference Manual (IMX95RM), the i.MX 95 Security Reference Manual and the i.MX 95
fuse map spreadsheet are not public (they sit behind an NXP account and NDA), so
every bit position below is taken from public source code or guides, never from
those manuals, and is marked unconfirmed where only one source gives it.

## 2. Sources

| # | Title | Version surveyed | URL |
|---|-------|------------------|-----|
| S1 | U-Boot (NXP fork), *AHAB secure boot guide for i.MX 8ULP and i.MX 9x*, `doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt` | branch `lf_v2025.04`, commit `99518e6b6f20` (2026-02-02) | https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt |
| S2 | U-Boot (NXP fork), ELE AHAB commands, `arch/arm/mach-imx/ele_ahab.c` | same as S1 | https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/arch/arm/mach-imx/ele_ahab.c |
| S3 | U-Boot (NXP fork), ELE fuse driver, `drivers/misc/imx_ele/fuse.c` | same as S1 | https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/drivers/misc/imx_ele/fuse.c |

## 3. Fuse words the OEM flow writes

U-Boot addresses an i.MX 9 fuse as *bank* and *word*, eight 32-bit words per bank;
the driver turns that into the enclave's flat fuse index `bank * 8 + word` before
calling the enclave's write-fuse service (S3, `fuse_prog`).

### 3.1 SRK hash

- **Where:** bank 16, words 0 to 7 (flat index 128 to 135), the 256-bit
  `SRK_HASH` field. The guide gives the same bank for i.MX 93 and i.MX 95 and a
  different bank for i.MX 8ULP (S1 §1.6). The driver lists bank 16 (8 words) and
  bank 17 (8 words) among the banks it reads through the enclave rather than the
  fuse shadow block (S3, `ele_api_mapping_table`); what bank 17 holds is not
  stated in any public source read, so it is **unconfirmed** (one candidate is a
  second SRK hash for the secure world, which the life cycle `OEM secure world
  closed` in S2 suggests, but no source says so).
- **Value source:** the SHA-256 fuse table that NXP's signing tool writes when it
  generates the SRK table, read as eight little-endian 32-bit words (S1 §1.6).
- **Effect of an error:** the guide warns that a wrong SRK hash leaves a part that
  no longer boots once it is closed (S1 §1.6).

### 3.2 Life cycle

- **Where:** the life cycle is not written as a raw fuse word by the OEM. U-Boot's
  `ahab_close` asks the enclave to move the life cycle forward
  (`ele_forward_lifecycle`), and the enclave burns the fuses itself (S2,
  `do_ahab_close`). The current state is read back from the fuse shadow block at
  offset `0x414` on i.MX 95 and i.MX 94, `0x41c` on the other i.MX 9 parts (S2).
- **States on i.MX 95** (S2, `display_life_cycle`, i.MX 95/94 branch): BLANK,
  FAB default, FAB, NXP provisioned, OEM open (`0x10`), OEM secure world closed
  (`0x20`), OEM closed (`0x40`), OEM locked (`0x80`), field return OEM, field
  return NXP, bricked. These encodings differ from i.MX 93, where OEM open reads
  `0x8` and OEM closed `0x20`; the guide (S1 §1.7, §1.8) shows the i.MX 93 values,
  so its example output does not match an i.MX 95.
- **Transitions U-Boot offers:** OEM open to OEM closed (`ahab_close`, request
  value 8), OEM closed to OEM locked (`ahab_lock`, request value 128), and a
  return to field-return OEM through a message block signed by the OEM SRK
  (`ahab_return_lifecycle`) (S2). U-Boot refuses `ahab_close` unless the state
  read back is OEM open (S2).
- **OEM secure world closed:** S2 decodes the state but offers no command that
  enters it. How it is entered, and what it closes, is **unconfirmed**.

### 3.3 Anti-rollback and SRK revocation

- U-Boot's `ahab_commit` asks the enclave to burn into fuses any new SRK
  revocation bits and firmware version numbers it found in the NXP (ELE firmware)
  and OEM containers that booted (S2). The OEM does not choose a fuse word: the
  enclave takes the values from the signed containers.
- The bank and word of the version and revocation fields on i.MX 95 are not in
  any public source read, and are **unconfirmed**.

### 3.4 Secure fuses through a signed message

- `ahab_sec_fuse_prog` hands the enclave a message block signed by the OEM SRK,
  which programs a "secure" fuse (S2). Which i.MX 95 fuses require this path
  rather than plain `fuse prog` is **unconfirmed** (see section 6).

## 4. Order, irreversibility and tools

TODO

## 5. Programming plan for the owner's approval

TODO

## 6. What could not be confirmed

TODO

## 7. Questions for the owner

TODO
