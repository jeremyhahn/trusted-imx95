# Boot container: signed-image development and recovery in the OEM open life cycle (survey)

Row: boot-container ([SPEC.md](../SPEC.md)), tracking issue #12. Documentation only: nothing here was run against a
board, flashed or fused, and nothing here is a step to fuse, change the life cycle or provision a key.

## 1. Scope

How a developer loads and tests a signed boot container (`flash.bin`) on the NXP FRDM-IMX95-PRO while the device
stays in the OEM open life cycle:

- the SW4 boot modes and the USB serial downloader (UM12527 §2.3);
- the host tools that load a container over USB: NXP's uuu (mfgtools) and SPSDK's `nxpuuu`, with the SPSDK tools
  that build, check and query around it (`nxpimage`, `nxpele`);
- writing the container to the eMMC boot partitions;
- recovering a board whose container does not boot;
- what the open life cycle lets a developer check before any fuse is considered;
- how this loop feeds the host-side signing pipeline of #9.

Out of scope, cited only: the signing tool decision (#30), the negative test plan (#118), the enclave event log
(#131), the boot media and `flash.bin` layout survey (#42), and the Cortex-M7 load path (#71).

## 2. Sources

| Id | Title | Version or tag | URL or path |
|---|---|---|---|
| S1 | NXP UM12527, FRDM-IMX95-PRO Board User Manual, §2.3 (boot modes, Table 7) | Rev. 1.0 | `jeremyhahn/vendor-nxp`: `docs/imx95/UM12527-FRDM-IMX95-PRO-board-user-manual.pdf` (private; **not reachable from this lane**, see §9) |
| S2 | This repository's SPEC.md, boot-container row and board interfaces | base `4b753a7` | [docs/SPEC.md](../SPEC.md) |
| S3 | This repository's references index | base `4b753a7` | [docs/references/README.md](../references/README.md) |
| S4 | nxp-imx/mfgtools (uuu), README, LICENSE, built-in script `uuu/emmc_burn_loader.lst`, commit history | tag `uuu_1.5.243` (commit dated 2025-12-16) | https://github.com/nxp-imx/mfgtools/tree/uuu_1.5.243 |
| S5 | mfgtools commit "Add imx95 support without using ROMAPI" (adds the MX95 ROM entry) | commit `15d33ba`, first in `uuu_1.5.139` | https://github.com/nxp-imx/mfgtools/commit/15d33ba |
| S6 | mfgtools commit "Add PID 0x15C for imx95" | commit `b6ae918`, first in `uuu_1.5.181` | https://github.com/nxp-imx/mfgtools/commit/b6ae918 |
| S7 | nxp-mcuxpresso/spsdk, docs `docs/apps/nxpuuu.rst`, `docs/apps/sdpshost.rst`, LICENSE | tag `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/tree/v3.13.0 |
| S8 | SPSDK 3.13.0 as installed from PyPI: `--help` of `nxpimage`, `nxpuuu`, `nxpele`, and the family database queried per feature | `spsdk==3.13.0`, bundled `libuuu==1.5.243` | https://pypi.org/project/spsdk/3.13.0/ |
| S9 | NXP RM00284, EdgeLock Enclave Hardware Security Module API | Rev. 4.5 | `jeremyhahn/vendor-nxp`: `docs/edgelock/RM00284.pdf` (private; cited from S2 only) |
| S10 | i.MX 95 Applications Processor Reference Manual (IMX95RM) | — | **missing** (S3, "Still missing") |
| S11 | i.MX 95 Security Reference Manual | — | **missing** (S3, "Still missing"; NDA) |
| S12 | NXP i.MX Linux User's Guide (the BSP's own uuu and eMMC instructions for i.MX 95) | — | **missing**: not in docs/references/, not surveyed |

## 3. Boot modes and the USB serial downloader

What the repository records from UM12527 §2.3 (S1, through S2): the board boots on the Cortex-M33 (Table 7); SW4
selects the boot mode; the default boot device is the eMMC; SD and FlexSPI NOR are the other boot devices (S3); one
SW4 setting puts the boot ROM in the USB serial downloader.

This lane could not open UM12527 itself (S1 is in a private repository the lane has no access to). So the SW4
switch positions for each mode, the USB connector the serial downloader enumerates on, and whether the ROM falls
back to the serial downloader when the selected device holds no valid container are **not confirmed here**. The ROM
fallback behaviour also needs IMX95RM (S10), which is missing.

What the host tools say about the serial downloader (S4, S5, S6):

- uuu's device table says it treats the i.MX 95 ROM as a USB HID device. This comes from uuu's source history only
  and has not been tried against an FRDM-IMX95-PRO: **unverified** on this board. Its ROM entry for the MX95 (S5) uses the stream-mode serial
  download protocol (SDPS: no command phase, the image is streamed), reports a UID string, uses endpoint 1 and
  1020-byte packets, and does **not** use the ROM API path that uuu uses for the i.MX 8ULP. Support first shipped in
  `uuu_1.5.139`; a second USB product id for the i.MX 95 was added in `uuu_1.5.181` (S6). The USB VID:PID values and
  which one the FRDM board's silicon presents are not restated here: they need the board or IMX95RM.
- uuu's script expects the following order (S4, `emmc_burn_loader.lst`). After the ROM has run the streamed container,
  the U-Boot SPL in it can carry on as a serial download target itself (uuu's `SDPV` stage). Then U-Boot proper
  serves fastboot (`FB`) for writes to storage. This holds only if the container's SPL and U-Boot are built with
  those USB gadget functions enabled. The project's U-Boot configuration is not surveyed here (#42, #9), and the
  order has not been run: **unverified**.

## 4. Host tools and their i.MX 95 support

| | uuu (mfgtools) | SPSDK `nxpuuu` | SPSDK `nxpimage` | SPSDK `nxpele` | SPSDK `sdpshost` |
|---|---|---|---|---|---|
| Version surveyed | `uuu_1.5.243` (S4) | 3.13.0, embeds libuuu 1.5.243 (S8) | 3.13.0 (S8) | 3.13.0 (S8) | 3.13.0 (S7) |
| i.MX 95 support | since `uuu_1.5.139` (S5) | yes: families `mimx9596` and the other `mimx95*` parts, revisions a0, a1, b0 (S8) | yes: AHAB and bootable-image features list the `mimx95*` families (S8) | yes: `ele` feature lists the `mimx95*` families (S8) | no `mimx95*` family under the `sdps` feature (S8); marked prototype and untested by NXP (S7) |
| Transport | USB HID to the ROM (SDPS), then SPL (SDPV), then U-Boot fastboot over USB (S4) | same as uuu, through libuuu (S7, S8) | none: host-side image tool | mboot (blhost), U-Boot serial console, or U-Boot fastboot (S8, `--device`) | USB HID, SDPS |
| What it can write | RAM (boot a container without storing it), eMMC boot partition (`-b emmc`), whole eMMC image (`-b emmc_all`), SD, QSPI, NAND, NVMe (S4) | the same uuu built-in scripts: `write -b emmc`, `emmc_all`, and raw uuu commands (S7) | builds and parses AHAB containers and whole bootable images (writes files, not devices) | nothing to storage, but it exchanges ELE messages, and its command set includes fuse writes and life-cycle forwarding (`write-fuse`, `forward-lifecycle-update`) beside the reads (`get-info`, `get-events`, `read-common-fuse`) (S8) | RAM only |
| Checks signatures | not that this survey found: nothing in its README or eMMC script describes a signature check. On the board, the ROM and the enclave authenticate; what they enforce in OEM open is **unconfirmed** (§6) | not that this survey found, as uuu | `nxpimage ahab` has `export`, `sign`, `re-sign`, `parse` and `verify` (S8). Whether `verify` checks signatures cryptographically, and whether it checks what the ROM checks, is **unverified** (§8, N4 and N5) | it reads the enclave's state and events on the board. In OEM open, the reported events are diagnostic only and say nothing about the signing root (§7) | not that this survey found |
| Licence | BSD (S4 LICENSE, README); the prebuilt Windows binary links LGPL-2.1 libusb | BSD-3-Clause (S7 LICENSE) | BSD-3-Clause | BSD-3-Clause | BSD-3-Clause |

Notes:

- The rows above come from documentation, commit history, script text and `--help` at the pinned versions, not from a
  run. Every statement about what a tool checks or writes is **unverified** until the negative tests of §8 pass and
  the eMMC write has been read back (§5).
- At the surveyed versions, `nxpuuu` and uuu carry the same libuuu version number: S8 bundles libuuu 1.5.243, and S4
  is the uuu tag `uuu_1.5.243`. That the wheel's libuuu behaves the same as the standalone uuu binary is assumed from
  the version number, not tested: **unverified**. If it holds, the choice between them is about how the project pins
  and drives the tool, not about capability (question 1).
- SPSDK's "blhost" is the MCU boot-loader host. uuu's device table (S5) has the i.MX 95 ROM speaking SDPS, not the
  MCU boot loader, so blhost is not expected to be the loading tool for this board. This is not checked against
  IMX95RM, which is missing. `nxpele` names `mboot` as one of its transports, but which i.MX 95 firmware answers on it
  is **unconfirmed**. The likely `nxpele` transports here are U-Boot's serial console and fastboot. They work only if
  the project's U-Boot carries the enclave message support `nxpele` expects, which was not surveyed:
  **unverified**.
- The FRDM-IMX95-PRO's exact part number and silicon revision, which SPSDK's family and revision options need, are
  **unconfirmed**: they need UM12527 (S1) or the board's marking (question 2).

## 5. Writing the eMMC boot partitions

The uuu built-in script `emmc_burn_loader.lst` (S4), used by `uuu -b emmc <flash.bin>` and `nxpuuu write -b emmc`,
reads as follows, in our words. This is from the script text at `uuu_1.5.243` only. It was not run, so its
behaviour on the i.MX 95 is **unverified**:

1. Streams the container to the ROM over the serial downloader, and the ROM runs it. Whether the ROM authenticates it,
   and what it does on a failure in OEM open, is **unconfirmed** (§6; needs S10, S11).
2. If the SPL supports it, streams the rest of the image to the SPL, which jumps to U-Boot.
3. In U-Boot, over fastboot: selects the eMMC device, writes the image to the fastboot `bootloader` target, then sets
   the eMMC's boot configuration (`mmc partconf`) so that boot partition 1 is the one the card boots from, with the
   boot acknowledge setting taken from the environment.

**This script does not guarantee that only a container that has booted is written.** Each stage runs against
whatever device uuu finds. Suppose a U-Boot fastboot target is already running, for example a known-good U-Boot
loaded during recovery. uuu can then attach to it and run stage 3 with the supplied file, and that file has never
been booted. In that case `uuu -b emmc <flash.bin>` can write a container that does not boot. The script text does
not show how uuu 1.5.243 chooses between the stages when several kinds of device are present, so that is
**unverified** too.

The protection holds only under one of these conditions, made an explicit step in §8 (step 4):

- **Same file, same session:** the candidate was booted successfully from RAM in this session, and the file being
  written is byte-identical to the file that was booted. This is checked by comparing the SHA-256 of the booted file
  with the SHA-256 of the file passed to the write, and the check is recorded.
- **Fresh ROM download:** the write starts from a fresh ROM serial-download session, with the board reset into SW4
  serial download and no U-Boot already running. The log of that session must show the ROM (SDPS) stage loading the
  candidate itself before the fastboot stage runs. If the log shows uuu going straight to fastboot, the write is
  void. This condition assumes that uuu 1.5.243's log names the stage it runs (SDPS, SDPV, FB) and the file it
  sends. That has not been seen in a run (**unverified**). If the log does not show it, only the same-file condition
  can be used.

The offset of the container inside the boot partition, which fastboot target maps to which partition,
and the partition the i.MX 95 ROM reads are set by U-Boot's configuration and the ROM: they belong to the boot media
and layout survey (#42) and need IMX95RM (S10), which is missing.

`uuu -b emmc_all <image.wic>` writes a whole disk image instead (S4 README) and is not the boot-container loop.
Its script, `emmc_burn_all.lst`, was not read in this lane. What it writes to the boot partitions and their boot
configuration is therefore **unverified**, and it must not be assumed to leave them untouched.

## 6. Recovering a board that does not boot

The recovery path rests on an assumed property: the serial downloader is in the boot ROM, and the SW4
serial-download setting makes the ROM enter it whatever the eMMC holds. If so, a bad container in eMMC cannot remove
it while the device is in OEM open and no fuse that disables it has been blown. The SW4 behaviour is in UM12527 §2.3
(S1, not read in this lane) and the ROM behaviour in IMX95RM (S10, missing): **unconfirmed** on this board. Which fuses can disable the
serial downloader or change boot-mode selection is in IMX95RM or the Security Reference Manual (S10, S11), both
missing: **unconfirmed**. This survey proposes no fuse step.

The developer loop, in order of preference:

1. **Serial downloader.** Set SW4 to serial download (positions from UM12527 §2.3, S1, not confirmed here), connect
   the download USB port, and run uuu with a known-good container. The board should run it from RAM. The eMMC is
   left alone only if that container's U-Boot does not write storage by itself, which depends on its build and
   environment (not surveyed): a condition, not a guarantee. Then rewrite the boot partition with
   `uuu -b emmc <known-good flash.bin>` and set SW4 back to eMMC. While that recovery U-Boot runs, a later
   `uuu -b emmc` with any other file can write that file without booting it (§5). Only the known-good file, checked
   by its SHA-256, is written in this state.
2. **SD card.** Set SW4 to SD boot with a card holding a known-good image, and repair eMMC from U-Boot. This needs
   no host tool but needs a prepared card. SD is recorded as a boot device of this board (S3); its SW4 setting is in
   UM12527 §2.3 (S1, not read): **unconfirmed**.
3. **Second boot partition.** An eMMC device has two boot partitions. uuu's script uses `mmc partconf` to set which
   one the card offers for boot (S4). Whether the i.MX 95 ROM boots from the partition so selected is
   **unconfirmed** (IMX95RM, missing). Keeping
   the last known-good container in the other partition would give a recovery that needs no switch change. Whether
   the i.MX 95 ROM falls back between boot partitions by itself is **unconfirmed** (needs IMX95RM); without that,
   this is a manual switch done from U-Boot or over uuu (question 4).

A container the ROM rejects in OEM open still matters less than in closed: in the open life cycle the enclave
records authentication failures as events rather than refusing to run. That is the general AHAB OEM-open model; no
source in this survey states it for the i.MX 95, and the exact rule needs the Security Reference Manual (S11,
missing): **unconfirmed**. If that model holds, a bad *unsigned or mis-signed* image may run and show up only as
events; an image signed with the *wrong* SRK may run too, because nothing on an OEM-open board holds the intended
SRK hash yet. So a board that boots, with or without events, says nothing about which signing root was used (§8).
A *malformed* container that the ROM cannot parse is expected not to boot and to need the recovery above. That too is
the general model and is **unconfirmed** for the i.MX 95 ROM.

## 7. What OEM open lets a developer check before any fuse

Everything below reads state; none of it writes a fuse or changes the life cycle.

- **Offline, on the host:** build the container with `nxpimage ahab export` and parse it back with `nxpimage` to check
  its structure, signature block and the SRK table hash it carries (S8). What these commands actually check at
  3.13.0 is **unverified** until the negative tests of §8 pass. According to its help text (S8), `nxpimage ahab export` also emits
  fuse scripts next to the image unless `--no-fuse-scripts` is given. Not checked in a run, so the output directory
  must be inspected for them all the same: the pipeline should pass that flag, or keep
  those scripts out of every artefact and never run them (#118 owns the negative tests).
- **On the board, after loading over USB:** read the enclave's events and status with `nxpele get-events` and
  `nxpele get-info` over U-Boot's serial console or fastboot (S8), or with U-Boot's own AHAB status command (not
  surveyed here: **unconfirmed** at a named U-Boot version). `nxpele` can also write fuses and forward a life-cycle
  change, so any script that drives it must allow the read commands only (question 6). These reads are
  **diagnostic only**. An OEM-open board has no SRK hash fused, so it cannot tell the intended signing root from any
  other, and the i.MX 95 rule for logging authentication failures in OEM open is unconfirmed (§6). An empty event
  list therefore does not show that the container was signed by the approved key. The event log design is #131.
- **Negative checks:** a deliberately mis-signed container can be loaded in OEM open to look for an event. Whether an
  event appears, and whether such a run is free of risk to the board, depend on the unconfirmed OEM-open rule (§6)
  and on the recovery path of §6 working on this board. Neither is established. The plan for these checks is #118.
- **The key hash to be fused:** SPSDK's `fuses` feature lists the `mimx95*` families (S8). Whether SPSDK 3.13.0 can
  compute the SRK hash words for this part, and whether its rule matches the ROM's, is **unverified**. If it can,
  they can be computed and compared on the host. Writing them is out of scope and is not described.

What OEM open cannot show: how the ROM behaves once closed (refusal instead of event), the anti-rollback version
check against fuses, and the boot ROM's exact rules; these need IMX95RM and the Security Reference Manual (S10,
S11), both missing.

## 8. Link to the host-side signing pipeline (#9)

The loop gives #9 a fixed hand-off. Acceptance rests on host-side checks against an independently approved SRK hash
and an independently approved revocation and version policy.
The board run comes after them and is diagnostic only.

**Not usable on a real device yet.** Nothing below about the tools' checks or writes has been verified. That covers
SPSDK 3.13.0's `nxpimage ahab verify` and `nxpimage ahab parse`, and uuu 1.5.243's built-in eMMC script. The
statements come from `--help` text and script text at those pinned versions (S4, S8), not from a run. They are not
established:

- that `verify` checks each container's signature cryptographically;
- that `parse` extracts the SRK table the ROM hashes;
- what the uuu script writes, and where.

The procedure must not be used to accept a container for a real device until every required negative test below
shows "rejected" **at its named stage**, at the pinned versions.

**Container roles.** `flash.bin` is a sequence of AHAB containers with **different signers**, so no single trust
anchor or policy record applies to all of them. The expected roles are:

| Role | Contents | Signer | Trust anchor (2.2) | Revocation and version record (2.3) |
|---|---|---|---|---|
| V1, vendor | the EdgeLock enclave firmware, first in the image ([ele-firmware-survey.md](ele-firmware-survey.md) §1, §7) | NXP, with NXP's keys; this project cannot re-sign or change it | the **pinned vendor record**: the digest of the whole container as it appears in the firmware package this project pinned, recorded outside the build when the package was pinned and tested. The digest is required: an independently approved hash of NXP's SRK table (owner question 7) may be checked in addition, but alone it would accept any NXP-signed firmware, including an older one with the same `fuse_version` (N10) | the vendor record also lists the container's `used_srk_id`, `srk_revoke_mask` and `fuse_version` as read from the pinned package; any difference rejects it. NXP's floor is NXP's number, separate from this project's (ele-firmware-survey.md §7) |
| O1, OEM boot | OEI, System Manager, Cortex-M7 image, A55 SPL (all required; see the required image entries below) | the owner's HSM root | the approved SRK hash of step 2.2 | the OEM policy record of step 2.3 |
| O2, OEM application processor | the rest of the A55 boot chain (TF-A, U-Boot, OP-TEE if used) | the owner's HSM root | the approved SRK hash | the OEM policy record |

The number, order and contents of the containers in the PRO's `flash.bin` are **unverified** until the `nxpimage
ahab parse` output of a real build is recorded; the table is the expected layout. The **container manifest**, recorded
outside the build next to the two policy records, names each container position's role and, for each role, the
**required image entries**: for every image the container must carry, its type and target core (for O1 the OEI, the
System Manager on the Cortex-M33, the Cortex-M7 image and the A55 SPL; for O2 TF-A, U-Boot and OP-TEE if used), its
load address, and the digest of the approved build of that image. imx-mkimage's i.MX 95 `flash_all` puts OEI, SM,
M7 and SPL in one OEM container ([encrypted-boot-survey.md](encrypted-boot-survey.md), the bullet on the i.MX 95 OEM boot container
layout; the table above follows that), and its `flash_a55` target builds the same container without the M7 image; such an
image is correctly signed by the approved root but leaves the A55 running with no tamper responder (docs/SPEC.md,
`hsm-self-defence`), so signer checks alone cannot catch it. Every container is checked against the anchor and record
of its role, and only those. A container whose position has no role in the manifest, or an image with more or fewer
containers than the manifest names, is rejected. **Stage 2.2 also checks the contents of each OEM container**
against the required entries of the role its position names: a missing entry (above all the M7 image), an extra
entry, an entry of the wrong type or core, or an image digest that differs from the approved build rejects the
container. Because O1 and O2 share the OEM root and policy, these entries are what tells the two roles apart; the
signer checks cannot. Which image-type and core fields `nxpimage ahab parse` reports per entry is **unverified** at
3.13.0 (needs the AHAB chapter of IMX95RM or the Security Reference Manual, or SPSDK's source); until it is, the
entries are read by the independent parser of step 2.3. The OEM SRK hash is never compared with
the vendor container, and the vendor record never accepts an OEM container. Each record is reviewed apart from the
others, and a missing record rejects every container of its role.

Step 2 has three separate stages, and each fixture names the one that must reject it:

- **2.1, signature verifier:** checks each container's structure, its payload digests and its signature against the
  SRK table carried *inside the image*. This is `nxpimage ahab verify` (SPSDK 3.13.0, S8), or the independent check of
  owner question 7 (b). It is given no approved-root input, so it cannot tell an approved key from any other key.
- **2.2, trust-anchor check:** compares each container with the independently approved anchor of its role: the OEM
  containers' SRK table hash with the approved OEM SRK hash, the vendor container with the pinned vendor record (step
  2.2 below), and each OEM container's image entries with the required entries of its role (type, core, load address
  and approved image digest; a missing M7 image rejects O1). It checks no signature.
- **2.3, revocation and rollback policy check:** compares each container's `used_srk_id`, `srk_revoke_mask` and
  `fuse_version` with the independently approved record of its role (step 2.3 below; for the OEM containers): the list of revoked SRK indexes and
  the version floor. It is the host-side form of the policy checks C2, C3 and C4 of the test plan
  ([secure-boot-test-plan.md](secure-boot-test-plan.md) §7, item 2) and serves the anti-rollback requirement of the
  boot-container row ([SPEC.md](../SPEC.md)). It is needed because an unfused, OEM-open board enforces neither
  revocation nor the version floor: 2.1 and 2.2 alone accept a correctly signed container that uses a revoked key
  from the approved table, or that carries an older `fuse_version`.

A fixture counts as passed only if the run's report shows the rejection coming from the stage named below. If another
stage rejects it first, the fixture has not tested the stage it was built for. That stage must then be run on the
fixture alone, or the fixture rebuilt.

| Test | Input (everything not named is valid) | Stage that must reject it | What it isolates | Expected result |
|---|---|---|---|---|
| N1 | an unsigned container | 2.1 | that a missing signature is not accepted; it does **not** test the cryptography (it can fail on signature presence alone) | **rejected** at 2.1 |
| N2 | a container signed correctly with a key outside the approved SRK set, carrying that key's own SRK table | 2.2 | the trust anchor. 2.1 is expected to *accept* it, because the signature is valid against the image's own SRK table; the report must show 2.1 passing and 2.2 rejecting | **rejected** at 2.2 |
| N3 | an approved-key container whose payload was changed after signing, payload digest left as signed | 2.1 | payload integrity; it does **not** test the cryptography (a digest mismatch alone rejects it) | **rejected** at 2.1 |
| N4 | an approved-key container with bits flipped in the signature only; structure, payload digests and SRK table untouched | 2.1, as a *signature* failure | that the signature is checked cryptographically | **rejected** at 2.1, reported as a signature failure, not a structure or digest error |
| N5 | an approved-key container whose payload was changed and whose payload digest in the container header was recomputed to match; signature unchanged | 2.1, as a *signature* failure | that the signature covers the digests: digests consistent, signature over the old header | **rejected** at 2.1, reported as a signature failure |
| N6 | a known-good OEM container signed with an approved, unrevoked key, with `fuse_version` at or above the floor (control) | none | that the stages accept a valid image | accepted at 2.1, 2.2 and 2.3 |
| N7 | a container signed correctly with a key from the approved SRK table whose index the approved policy marks revoked (`used_srk_id` names it) | 2.3 | revocation. 2.1 and 2.2 are expected to *accept* it, because the signature is valid and the SRK table is the approved one; the report must show both passing and 2.3 rejecting | **rejected** at 2.3 |
| N8 | a container signed correctly with an approved, unrevoked key, whose `fuse_version` is below the approved floor | 2.3 | rollback. 2.1 and 2.2 are expected to *accept* it; the report must show both passing and 2.3 rejecting | **rejected** at 2.3 |
| N9 | as N6, but with a `srk_revoke_mask` that differs from the one the approved policy sets for this release | 2.3 | that a container carrying an unapproved revocation mask is caught on the host | **rejected** at 2.3 |
| P1 | a complete `flash.bin` as the release would ship it: the vendor container byte-identical to the pinned firmware package, then the OEM containers (O1, O2) signed with an approved, unrevoked HSM key at or above the OEM floor (control) | none | that per-role checking accepts a legitimate mixed-signer image: the vendor container passes against the vendor record and the OEM containers against the OEM hash and record. An implementation that applies the OEM hash to every container fails here | accepted at 2.1, 2.2 and 2.3 for every container |
| N10 | as P1, but the vendor container replaced by a different, genuinely NXP-signed enclave firmware that is not the pinned package (for example an older release) | 2.2 | that the vendor container is pinned by digest, not merely NXP-signed. 2.1 is expected to accept it | **rejected** at 2.2 |
| N11 | as P1, but with an OEM container added, removed or moved so that the image no longer matches the container manifest | 2.2 | that roles come from the manifest, not from the image | **rejected** at 2.2 |
| N12 | as P1, but built with `flash_a55`: the O1 container carries OEI, SM and SPL and no Cortex-M7 image, correctly signed with an approved, unrevoked HSM key; container count unchanged | 2.2, as a *contents* failure | that a required image entry, the M7 image, is checked for presence. 2.1 and 2.3 are expected to *accept* it | **rejected** at 2.2, reported as a missing M7 entry |
| N13 | as P1, but the two OEM containers swapped, so that the O2 container sits at the O1 position and the O1 container at the O2 position; both correctly signed with the approved key; container count unchanged | 2.2, as a *contents* failure | that O1 and O2, which share an anchor and a policy, are told apart by their required entries. 2.1 and 2.3 are expected to *accept* both | **rejected** at 2.2, reported as entries not matching the role |

Each run records the tool version, the exact command, the stage that rejected, and the output that shows that stage's
rejection. N4 and N5 are the only fixtures that isolate cryptographic verification. If `nxpimage ahab verify` does not
reject both as signature failures, it is not a signature verifier for this procedure. The independent check of owner
question 7 (b) then replaces it at 2.1, and that check is put through N1 and N3 to N6. Building N4 and N5 means editing
the signature and header fields of an AHAB container. Where those fields are on the i.MX 95 needs the AHAB chapter of
IMX95RM or the Security Reference Manual (S10, S11, missing), or SPSDK's source, which this lane did not read:
**unverified**. N7, N8 and N9 are built by signing, not by editing: they are valid containers whose key index,
revocation mask or version the policy forbids. N7 needs an approved SRK table with more than one key and a policy
record that marks one index revoked; N8 needs a recorded floor above the lowest version the build can set. The
test plan itself belongs to #118.

1. #9 builds `flash.bin` and signs its containers with the tool #30 chooses (CST 3.1.0 or SPSDK, keys in an HSM after
   AN14471, per S2). Output: the signed `flash.bin`, with fuse scripts suppressed.
2. **Acceptance, on the host, before any load or write** (tool behaviour **unverified** until N1 to N13 and P1 each give
   the expected result at the named stage):
   1. *Signature verifier (stage 2.1):* `nxpimage ahab verify -f <family> -r <revision> -b flash.bin` (SPSDK 3.13.0,
      S8) must report no problems. Its help says only "Verify AHAB Image". Whether it checks each container's
      signature cryptographically against the SRK table in the image is **unverified** at 3.13.0 (N4, N5). It
      receives no approved-root input, so it does not decide whether the signing key is approved: that is 2.2 (N2).
   2. *Trust-anchor check (stage 2.2):* extract the SRK table with `nxpimage ahab parse -f <family> -r <revision> -b flash.bin -o
      <dir>` (S8). For each OEM container (roles O1, O2), compute its SRK table hash on the host and compare it,
      byte for byte, with the **approved SRK hash**. That hash is recorded by the owner from the HSM's SRK public
      keys, outside the build that produced the image. For the vendor container (role V1), compare it with the
      **pinned vendor record** instead (the container digest, required; the independently approved NXP SRK hash
      only in addition), never with the OEM hash. The build's own output is never the reference. Three points are **unverified**: whether `parse` extracts the SRK
      table at all, which output file carries it, and the hash rule for the i.MX 95 SRK table. They need the AHAB
      chapter of IMX95RM or the Security Reference Manual (S10, S11, missing), a check of SPSDK's source, or test N2.
   3. *Revocation and rollback policy check (stage 2.3):* read each container's `used_srk_id`, `srk_revoke_mask`
      and `fuse_version` from the `nxpimage ahab parse` output (S8) and compare them with the record of its role:
      the vendor container with the pinned vendor record (exact match on all three), each OEM container with the
      **approved policy record** described here. That record holds the revoked SRK indexes, the expected `srk_revoke_mask` for the release, and the
      `fuse_version` floor. Like the approved SRK hash, the owner records and reviews it outside the build that
      produced the image, and the build's own output is never the reference. Reject the container if `used_srk_id`
      names a revoked index, if `srk_revoke_mask` differs from the approved mask, or if `fuse_version` is below
      the floor. The check runs on every candidate, also before any key has been revoked or any floor raised: the
      record then states "no index revoked" and the current floor explicitly, and a missing record is a rejection,
      not a pass. Whether `parse` reports these three fields, and in which output, is **unverified** at 3.13.0
      (N7, N8, N9); if it does not, they must be read from the container's signature block by an independent
      parser, whose field offsets need IMX95RM or the Security Reference Manual (S10, S11, missing).
   A container that fails any of the three stages is rejected and is not loaded or written. Passing 2.1 alone, or
   2.1 and 2.2 alone, never accepts a container.
3. **Board run in OEM open (diagnostic):** reset the board into SW4 serial download, load the accepted container over
   the ROM serial downloader with uuu or `nxpuuu` at the pinned version (S4/S8), boot it from RAM, and record
   `nxpele get-events` / `get-info` (S8) for #131. Record the SHA-256 of the file that was booted. The run shows
   only that the container boots from RAM over the serial downloader, on this FRDM-IMX95-PRO, at its silicon
   revision (question 2). It does not show that the same container boots from the eMMC boot partition: that is seen
   only after step 4, by a boot from eMMC. Its events help find faults. It is **not** evidence about the
   signing root (§7). Board-side confirmation of authentication stays **unconfirmed** until IMX95RM and the Security
   Reference Manual are available.
4. **Write to the eMMC boot partition (`-b emmc`, §5) only under a §5 condition.** Before the write, compute the
   SHA-256 of the file to be written and compare it with the SHA-256 recorded in step 3; any difference stops the
   write. The write must also come either from the same session as the step-3 boot, or from a fresh ROM-download
   session whose log shows the ROM stage loading this file. A write that attaches to a U-Boot already running
   (§5) with any other file is not allowed. What the uuu script writes, and where, stays **unverified** until it
   has been run and the boot partition read back and compared.
5. A failure at step 3 or 4 is recovered with §6 and reported back to #9 with the event output.

The pipeline therefore needs one pinned host-tool version for steps 2 to 4 (question 1), an approved SRK hash
and an approved revocation and version policy, both recorded outside the build (question 7), and one known-good container kept beside every candidate for recovery.

## 9. Unconfirmed items

1. UM12527 §2.3 was not read in this lane: the private context repository was not reachable. SW4 positions, the
   download USB connector and Table 7 are cited only through SPEC.md (S2).
2. ROM fallback to the serial downloader or between eMMC boot partitions: needs IMX95RM (missing).
3. Fuses that disable the serial downloader or fix the boot mode: needs IMX95RM or the Security Reference Manual
   (both missing).
4. The exact OEM-open rule for authentication failures on the i.MX 95 (event versus refusal): needs the Security
   Reference Manual (missing).
5. The board's part number and silicon revision (a0, a1 or b0 in SPSDK 3.13.0).
6. Whether `nxpimage ahab verify` (SPSDK 3.13.0) checks container signatures cryptographically, and whether it
   checks the same things as the ROM (§8 step 2.1). This is **unverified**. N4 and N5 of §8 are the tests that decide
   it; N1 and N3 do not, because they can be rejected without any signature check.
7. What uuu 1.5.243's built-in eMMC script writes, and where, and how uuu picks a stage when a U-Boot fastboot
   target is already running (§5). This is **unverified**: taken from the script text, not from a run. A write is
   bound to a booted candidate only by the §5 conditions (same SHA-256, same session or a fresh ROM download).
8. Which `nxpimage ahab parse` output carries the SRK table, and the i.MX 95 rule for hashing it into the fused
   value: needs IMX95RM or the Security Reference Manual (both missing), or SPSDK's source. Likewise, whether
   `parse` reports `used_srk_id`, `srk_revoke_mask` and `fuse_version` (§8 step 2.3), and where those fields sit
   in the i.MX 95 signature block: **unverified** (N7 to N9).
9. Board-side confirmation of the signing root: an OEM-open board has no SRK hash fused, so a board run in OEM open
   cannot confirm which key signed the container. Event results are diagnostic only until IMX95RM and the Security
   Reference Manual are available (§7, §8). The same holds for revocation and the version floor: an OEM-open,
   unfused board enforces neither, so a revoked key or a below-floor `fuse_version` is caught only by the host
   check of §8 step 2.3.
10. Which firmware answers `nxpele`'s `mboot` transport on the i.MX 95.
11. U-Boot's AHAB status command at a named U-Boot version (not surveyed; U-Boot belongs to #42 and #9).
12. The i.MX Linux User's Guide's i.MX 95 uuu instructions (S12, not in docs/references/).
13. Nothing here was run against a board: tool behaviour is from documentation, source history and `--help` only.

## 10. Owner questions

1. **Which host tool is pinned for loading and writing?**
   (a) standalone uuu at `uuu_1.5.243`; (b) SPSDK 3.13.0's `nxpuuu` (same libuuu 1.5.243); (c) both, uuu as
   fallback. Recommendation: **(b)**. One Python pin then covers loading, `nxpimage` checks and `nxpele` event reads in
   the #9 pipeline. The engine carries the same libuuu version (S8), but identical behaviour is **unverified** (§4). Keep standalone uuu as an unpinned manual fallback.
2. **Which part and silicon revision is the board?** (a) read UM12527 and the board marking and record it in SPEC.md;
   (b) query it at first power-up with `nxpele get-info` in OEM open. Whether `get-info` reports the revision on this
   board is **unverified**. Recommendation: **(a)**, confirmed by (b) if (b) works; SPSDK needs it
   for every family option.
3. **Obtain the missing manuals?** (a) request IMX95RM and the i.MX 95 Security Reference Manual under NDA now;
   (b) proceed with OEM-open testing only and defer every fuse question. Recommendation: **(a)**: §6 and §7 cannot be
   closed without them; (b) is safe in the meantime as far as fuses and the life cycle go, because nothing here fuses.
   Recovery from a bad container still rests on the unconfirmed ROM behaviour of §6.
4. **Recovery layout of the eMMC boot partitions?** (a) one boot partition, recovery by serial downloader only;
   (b) keep a known-good container in the second boot partition and switch with `mmc partconf`; (c) (a) plus a
   prepared SD card per board. Recommendation: **(c)** until IMX95RM confirms the ROM's partition behaviour; then
   reconsider (b) with #42.
5. **Should the diagnostic board run (§8 step 3) be automated in #9's pipeline on a lab board?** (a) yes, with the
   event output attached to every candidate as diagnostics; (b) manual for now. Recommendation: **(a)** once
   question 1 is settled, feeding #131. It needs a board on the lab host with SW4 in serial download mode. It never
   replaces the host-side acceptance of §8 step 2.
6. **Fuse-capable commands in the loop:** `nxpimage ahab export` emits fuse scripts unless told not to, and `nxpele`
   carries `write-fuse` and `forward-lifecycle-update`. (a) always pass `--no-fuse-scripts` and wrap `nxpele` so only
   `get-info`, `get-events` and the fuse reads can run; (b) keep the fuse scripts, quarantined, as review material.
   Recommendation: **(a)**: this row's rule is that no fuse step is scripted, and the approved SRK hash is recorded
   outside the build (question 7).
7. **Where do the approved SRK hash and the approved revocation and version policy come from, and how is a
   container's signature checked?** (a) the owner records the SRK hash, computed from the HSM's SRK public keys, and
   the policy record (revoked SRK indexes, the release's `srk_revoke_mask`, the `fuse_version` floor) in reviewed
   files outside the build. These OEM records apply to the OEM containers only. Next to them the owner records the
   container manifest and the pinned vendor record for the NXP enclave firmware container (its digest from the pinned
   package and its `used_srk_id`, `srk_revoke_mask` and `fuse_version`), and optionally an NXP SRK hash obtained from
   a source other than the image (§8, "Container roles"). The pipeline runs `nxpimage ahab verify` (stage 2.1),
   checks each container against the anchor and the required image entries of its role (stage 2.2), and checks
   `used_srk_id`, `srk_revoke_mask` and `fuse_version` against the record of its role (stage 2.3). This holds only
   once the §8 fixtures N1 to N13 and P1 have each given the expected result at their named stage at the pinned
   version: N2, N10 and N11 rejected at 2.2, N12 and N13 rejected at 2.2 as contents failures, N4 and N5 rejected at 2.1 as signature failures, N7, N8 and N9 rejected at 2.3, and P1 accepted. (b) as (a), with a second,
   independent signature check at 2.1, whether or not `verify` passes those tests. An example is CST's or OpenSSL's
   verification of each signature block against the SRK public key. Neither tool has been tried for this, so (b) is
   **unverified** too. (c) rely on the board run in OEM open. Recommendation: **(a)**, moving to **(b)** if `verify`
   does not reject N4 and N5 as signature failures. Never **(c)**: an OEM-open board holds no SRK hash, so it cannot confirm the signing root (§7).
