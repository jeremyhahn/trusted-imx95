# Secure-world memory protection on the i.MX 95: a public-source survey

Status: draft survey for the owner (issue #63, row `secure-world`, #16). Documentation only: nothing here
runs or scripts a fuse, life-cycle or provisioning step.

## 1. Scope and method

The question: on the FRDM-IMX95-PRO, which memory belongs to the secure world, which mechanism keeps the
other bus masters out of it, and which software sets that up. The `secure-world` row of
[SPEC.md](../SPEC.md) leaves the secure world's scope open and notes that no document in
[references/](../references/README.md) gives the i.MX 95's TrustZone configuration.

This survey reads only public NXP and upstream source trees, at the tags named in §2. It does not use the
i.MX 95 Reference Manual (IMX95RM) or the Security Reference Manual, which are not public and are listed as
missing in the references index. Every statement of behaviour is therefore a reading of source code and
configuration, not of a hardware manual; §8 lists what that leaves unconfirmed. All addresses below are
copied from the cited configuration files and are physical addresses.

## 2. Sources surveyed

| # | Source | Version surveyed | URL |
|---|--------|------------------|-----|
| S1 | NXP System Manager (imx-sm), FRDM i.MX 95 board configuration `configs/mx95frdm.cfg` | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm |
| S2 | NXP fork of Trusted Firmware-A (imx-atf), `plat/imx/imx9/imx95/` and `plat/imx/imx9/common/` | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-atf |
| S3 | Upstream Trusted Firmware-A, `plat/imx/imx9/` | tag `v2.15.0` | https://github.com/ARM-software/arm-trusted-firmware |
| S4 | NXP fork of OP-TEE OS (imx-optee-os), `core/arch/arm/plat-imx/` | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-optee-os |
| S5 | Upstream OP-TEE OS, `core/arch/arm/plat-imx/` | tag `4.11.0` | https://github.com/OP-TEE/optee_os |
| S6 | NXP Linux kernel (linux-imx), `arch/arm64/boot/dts/freescale/imx95-15x15-frdm.dts` | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/linux-imx |

S1-S5 were reached from the lane by `git clone` at the tags shown, S6 by fetching the one file at its tag.
The i.MX 95 Reference Manual, the Security Reference Manual and NXP's System Manager user guide were not
reached (not public, or not found as public pages) and are not used.

## 3. Hardware mechanisms

None of the surveyed A55 firmware programs a TrustZone Address Space Controller (TZC-380 or TZC-400) in
front of DRAM on the i.MX 95, as the i.MX 8M builds of the same trees do (S2-S5; §5, §6). Instead, the System Manager configuration (S1) describes every memory region
per *domain* (a domain ID, `did`, carried on each bus transaction) with a permission: `sec_rw` or
`sec_rwx` (secure accesses only), `rw` or `full` (secure and non-secure), or `ro`. The domain ID and the
secure/privileged attribute of each bus master are set by per-master formatting rules (`DFMT0`/`DFMT1`:
`sa=secure`, `sa=nonsecure` or `sa=bypass`, which passes the core's own TrustZone state through). The SM
programs these rules into the resource domain controller's memory region checkers, DDR among them
(`devices/MIMX95/sm/dev_sm_rdc.c` in S1); NXP calls this block the Trusted Resource Domain Controller (TRDC). The register-level behaviour of the TRDC is in IMX95RM,
which this lane could not read (§8).

So the secure world's DRAM on this part is "the DRAM regions whose rule for the A55's domain says
secure-only", and it is protected against the other cores and DMA masters only to the extent that their
domains have no rule granting that region.

## 4. Who programs the protection: System Manager on the Cortex-M33

In NXP's software the Cortex-M33 runs the System Manager, which boots first after the EdgeLock enclave
and writes the TRDC rules from the board configuration before it starts the A55 or the M7 (S1, `LM0` is
`name="SM", boot=1`). The A55 software never programs the memory checkers itself; it asks the SM for
services over SCMI. The FRDM configuration (S1, `configs/mx95frdm.cfg`) defines these logical machines and
domains, with these DRAM rules (DRAM starts at `0x8000_0000`):

| Domain (S1 name, `did`) | Secure attribute | DRAM rules in S1 |
|---|---|---|
| ELE (0) | n/a | all DRAM `0x8000_0000`-`0x8_7FFF_FFFF`, `rw`, no debug |
| V2X (12) | bypass | all DRAM read-only, except `0x8B00_0000`-`0x8BFF_FFFF` read-write |
| SM, M33 (`LM0`, 2) | secure | none (TCM and OCRAM only) |
| M7 (`LM1`, 4) | secure | `0x8000_0000`-`0x89FF_FFFF`, `full` (read, write, execute) |
| A55 secure (`LM2`, 3, SCMI agent "AP-S") | bypass, rules `sec_rwx` | `0x8A00_0000`-`0x8DFF_FFFF` (64 MiB) and OCRAM `0x2048_0000`, 256 KiB |
| A55 non-secure (same `LM2`, SCMI agent "AP-NS") | non-secure, rules `full`/`rw` | `0x8800_0000`-`0x89FF_FFFF` and `0x8E00_0000`-`0x8_7FFF_FFFF` |

Readings of this table, each from S1 alone:

- The A55's 64 MiB secure-only window at `0x8A00_0000` is the only DRAM that the configuration marks
  secure for the A55. TF-A and OP-TEE must sit inside it (§5, §6).
- The M7 domain may read, write and execute `0x8000_0000`-`0x89FF_FFFF`. That range overlaps the A55
  non-secure range at `0x8800_0000`-`0x89FF_FFFF` (32 MiB shared with Linux, presumably for RPMsg buffers and
  the M7 image), but not the A55 secure window.
- The V2X domain keeps read access to all DRAM, including the A55 secure window, and write access to
  `0x8B00_0000`-`0x8BFF_FFFF`, which lies inside that window. Why NXP grants this is not stated in S1.
- The ELE domain reaches all DRAM, as expected of the enclave.
- The A55 secure and non-secure environments are one logical machine (`LM2`) with one domain ID; the
  split between them is by the TrustZone state of the transaction, not by domain.

The other FRDM-family configurations in `configs/other/` (Jailhouse, RPMsg, Android variants for other
parts) were listed but not read.

## 5. Secure-world memory as TF-A lays it out

Both TF-A trees place BL31 and BL32 inside the A55 secure window of §4:

| Item | NXP imx-atf (S2) | Upstream TF-A (S3) |
|---|---|---|
| BL31 | `0x8A20_0000`-`0x8A24_0000` (256 KiB), `imx95/include/platform_def.h` | same values |
| BL32 (OP-TEE or Trusty) | `BL32_BASE` `0x8C00_0000`, `BL32_SIZE` 32 MiB, overridable, `imx95/platform.mk` | same defaults |
| Normal-world image | `PLAT_NS_IMAGE_OFFSET` `0x9020_0000` | same |
| Boot model | `RESET_TO_BL31`: BL31 is the first A55 image, no BL2 | same |
| Trusty | supported: `SPD=trusty` adds FF-A shared memory | not present |

Neither tree contains TRDC or TZC programming for the i.MX 95: a search of `plat/imx/imx9/` in S2 and S3
for `trdc` and `tzc` found nothing. Upstream TF-A maps the BL32 range into BL31's translation tables as secure
memory (`imx9/common/imx9_bl31_setup.c`). So on this part TF-A *assumes* that the System Manager has
already made `0x8A00_0000`-`0x8DFF_FFFF` secure-only; it does not set or check that itself. The two halves
must be kept in step by hand: a change of `BL32_BASE` or `BL32_SIZE` in TF-A without the matching change to
the SM's `LM2` memory rules would put OP-TEE in memory the normal world can reach.

## 6. OP-TEE's secure DRAM

- NXP imx-optee-os (S4) forces `CFG_TZC380=n` for the i.MX 95 (`plat-imx/conf.mk`), consistent with §3:
  OP-TEE does not program a TZASC on this part either.
- S4 sets, for i.MX 95, i.MX 943, i.MX 952 and i.MX 937, `CFG_TZDRAM_START` = DRAM base + `0x0C00_0000`
  = `0x8C00_0000`, `CFG_TZDRAM_SIZE` 32 MiB, then 2 MiB of non-secure shared memory directly after
  (`CFG_SHMEM_START` = `0x8E00_0000`). This matches TF-A's `BL32_BASE`/`BL32_SIZE` (§5), the SM secure
  window's upper end (`0x8DFF_FFFF`) and the start of the SM's A55 non-secure range (`0x8E00_0000`), §4.
- S4 has only an `mx95evk` flavour for the i.MX 95; there is no `mx95frdm` flavour. The FRDM board
  would build with the EVK flavour or a new one. The EVK flavour sets a 2 GiB first DRAM bank and a second
  non-secure bank at `0x1_0000_0000` of 14 GiB (`CFG_NSEC_DDR_1_*`).
- Upstream OP-TEE 4.11.0 (S5) has the same `mx95evk` flavour but no i.MX 95-specific `CFG_TZDRAM_START`.
  Its generic default places OP-TEE at the top of the first DRAM bank (`0xFE00_0000` for a 2 GiB bank,
  30 MiB, plus 2 MiB shared memory). That is neither TF-A's `BL32_BASE` nor inside the SM secure window in
  S1, where `0xFE00_0000` is A55 non-secure memory. An upstream OP-TEE build for this board therefore needs
  `CFG_TZDRAM_START=0x8C000000` (and the matching size) set by hand; this is a reading of the build
  files, not tested.

## 7. Linux side: reserved memory and what the normal world sees

NXP's Linux device tree for the board, `arch/arm64/boot/dts/freescale/imx95-15x15-frdm.dts` in
linux-imx at tag `lf-6.18.37-2.1.0` (S6, https://github.com/nxp-imx/linux-imx), has these
`reserved-memory` entries that bear on §4:

- The M7 RPMsg vrings, buffer and resource table at `0x8800_0000`-`0x8822_0FFF`, all `no-map`. This is
  inside the range S1 shares between the M7 and A55 non-secure, which supports the reading in §4.
- No node for `0x8A00_0000`-`0x8DFF_FFFF`. The default CMA pool may be allocated anywhere in
  `0x8000_0000`-`0xFEFF_FFFF`, which includes the secure window.

So the device tree on its own does not keep Linux off the secure window. In NXP's flow the reservation is
presumably added at boot (TF-A defines a `BL32_FDT_OVERLAY_ADDR`, and OP-TEE can add a reserved-memory node
to the DT it is handed); this lane did not trace where. If Linux did touch the window, the SM rules of §4
would block the access; the effect would be a bus fault rather than a leak, but the reservation is still
needed for a working system.

## 8. What could not be confirmed

- **TRDC hardware semantics.** The meaning of `sec_rw`, `full`, `nodbg` and `clr=` and the region granularity
  are read from the SM configuration names and `devices/MIMX95/sm/dev_sm_rdc.c` (S1), not from IMX95RM,
  which is not public. Whether the secure-only rule also blocks debug access, and how the checkers behave
  on a violation, is unconfirmed.
- **No TZASC on the i.MX 95.** Inferred from S2-S5 (no TZC code, `CFG_TZC380=n`), not from a hardware manual.
- **The V2X grant.** Why S1 gives the V2X domain read access to all DRAM and write access to
  `0x8B00_0000`-`0x8BFF_FFFF` inside the A55 secure window is not stated. That region lies between BL31 and
  BL32 and is not used by either in S2-S5; its purpose is unconfirmed.
- **Which SM configuration ships on the board.** S1 is NXP's FRDM configuration at the tag named; the
  configuration in the board's factory image, and whether it is `mx95frdm` or the EVK one, was not checked.
  The EVK configuration (`configs/mx95evk.cfg`) was not read.
- **Where the Linux reservation of the secure window is added** (§7).
- **The board's DRAM size.** OP-TEE's EVK flavour assumes 16 GiB in two banks; the FRDM-IMX95-PRO's size
  is in UM12527, not checked here.
- **The issue text of #63** could not be read from the lane (the forge API refused the request); this survey
  is written from the lane brief and the `secure-world` row of SPEC.md.
- **Upstream Linux** was not surveyed; only NXP's tree (S6).

## 9. Questions for the owner

1. **Who owns the TRDC configuration?**
   Options: (a) use NXP's System Manager with the stock `mx95frdm` configuration; (b) use NXP's System
   Manager with a configuration kept in this repository; (c) write our own M33 firmware.
   Recommendation: (b). On this part the TRDC rules are the only thing that makes the secure window secure
   (§3-§5), so they belong under this repository's review, not only in a vendor default.
2. **How big is the A55 secure window, and where?**
   Options: (a) keep NXP's 64 MiB at `0x8A00_0000` (BL31 256 KiB, OP-TEE 32 MiB); (b) grow or move it.
   Recommendation: (a) unless a trusted application needs more memory: S1, S2, S3 and S4 all agree on these
   addresses today, and moving them means changing three trees in step.
3. **Which secure-world OS?**
   Options: (a) OP-TEE; (b) Trusty (supported in imx-atf, S2, not upstream); (c) none, BL31 only.
   Recommendation: none from these sources. It depends on the `secure-key-handling` row's open question
   (whether the A55 calls the EdgeLock HSM API from Linux or from a TEE).
4. **Upstream or NXP trees?**
   Options: (a) NXP's `lf-*` trees for TF-A and OP-TEE; (b) upstream TF-A and OP-TEE with the i.MX 95
   settings pinned in this repository.
   Recommendation: (b) for TF-A, whose upstream i.MX 95 layout matches NXP's (§5). For OP-TEE, (b) only
   with `CFG_TZDRAM_START`/`CFG_TZDRAM_SIZE` set explicitly, because upstream's default does not land in the
   secure window (§6).
5. **Should the V2X domain keep read access to the A55 secure window and write access to
   `0x8B00_0000`-`0x8BFF_FFFF`?**
   Options: (a) keep NXP's rule; (b) remove the V2X grants over the secure window; (c) ask NXP first.
   Recommendation: (c), then (b) if the V2X block is unused on this device. The sources do not say what
   needs it (§8).
6. **Should the M7 share DRAM with Linux?**
   Options: (a) keep NXP's shared `0x8800_0000`-`0x89FF_FFFF` (RPMsg); (b) no M7 DRAM access if the M7 is
   unused. Recommendation: (b) if the `secure-key-handling` row does not put the HSM caller on the M7;
   otherwise (a). Either way the M7 has no rule over the A55 secure window in S1.
7. **Should the build check that the TF-A, OP-TEE, SM and device-tree addresses agree?**
   Options: (a) a build-time check in this repository; (b) review only.
   Recommendation: (a). Four sources must agree by hand on the same addresses (§5-§7), and a mismatch fails
   silently into an unprotected secure world.
