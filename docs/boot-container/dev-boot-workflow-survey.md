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

- uuu recognises the i.MX 95 ROM as a USB HID device. Its ROM entry for the MX95 (S5) uses the stream-mode serial
  download protocol (SDPS: no command phase, the image is streamed), reports a UID string, uses endpoint 1 and
  1020-byte packets, and does **not** use the ROM API path that uuu uses for the i.MX 8ULP. Support first shipped in
  `uuu_1.5.139`; a second USB product id for the i.MX 95 was added in `uuu_1.5.181` (S6). The USB VID:PID values and
  which one the FRDM board's silicon presents are not restated here: they need the board or IMX95RM.
- After the ROM has run the streamed container, the U-Boot SPL in it can carry on as a serial download target itself
  (uuu's `SDPV` stage), then U-Boot proper serves fastboot (`FB`) for writes to storage (S4,
  `emmc_burn_loader.lst`).

## 4. Host tools and their i.MX 95 support

| | uuu (mfgtools) | SPSDK `nxpuuu` | SPSDK `nxpimage` | SPSDK `nxpele` | SPSDK `sdpshost` |
|---|---|---|---|---|---|
| Version surveyed | `uuu_1.5.243` (S4) | 3.13.0, embeds libuuu 1.5.243 (S8) | 3.13.0 (S8) | 3.13.0 (S8) | 3.13.0 (S7) |
| i.MX 95 support | since `uuu_1.5.139` (S5) | yes: families `mimx9596` and the other `mimx95*` parts, revisions a0, a1, b0 (S8) | yes: AHAB and bootable-image features list the `mimx95*` families (S8) | yes: `ele` feature lists the `mimx95*` families (S8) | no `mimx95*` family under the `sdps` feature (S8); marked prototype and untested by NXP (S7) |
| Transport | USB HID to the ROM (SDPS), then SPL (SDPV), then U-Boot fastboot over USB (S4) | same as uuu, through libuuu (S7, S8) | none: host-side image tool | mboot (blhost), U-Boot serial console, or U-Boot fastboot (S8, `--device`) | USB HID, SDPS |
| What it can write | RAM (boot a container without storing it), eMMC boot partition (`-b emmc`), whole eMMC image (`-b emmc_all`), SD, QSPI, NAND, NVMe (S4) | the same uuu built-in scripts: `write -b emmc`, `emmc_all`, and raw uuu commands (S7) | builds and parses AHAB containers and whole bootable images (writes files, not devices) | nothing to storage, but it exchanges ELE messages, and its command set includes fuse writes and life-cycle forwarding (`write-fuse`, `forward-lifecycle-update`) beside the reads (`get-info`, `get-events`, `read-common-fuse`) (S8) | RAM only |
| Checks signatures | no: it streams whatever it is given; the check is the ROM's and the enclave's on the board | no, as uuu | `nxpimage ahab` has `export`, `sign`, `re-sign`, `parse` and `verify` (S8): it builds signed containers and checks them on the host; whether `verify` checks everything the ROM checks is **unconfirmed** | it reads the enclave's state and events on the board, the place where the real check is reported | no |
| Licence | BSD (S4 LICENSE, README); the prebuilt Windows binary links LGPL-2.1 libusb | BSD-3-Clause (S7 LICENSE) | BSD-3-Clause | BSD-3-Clause | BSD-3-Clause |

Notes:

- The rows above come from documentation, commit history, script text and `--help` at the pinned versions, not from a
  run. Every statement about what a tool checks or writes is **unverified** until the negative tests of §8 pass and
  the eMMC write has been read back (§5).
- `nxpuuu` and uuu are the same engine at the surveyed versions (S8 bundles libuuu 1.5.243, the uuu tag of S4).
  Choosing between them is about how the project pins and drives the tool, not about capability (question 1).
- SPSDK's "blhost" is the MCU boot-loader host. The i.MX 95 ROM speaks SDPS, not the MCU boot loader, so blhost is
  not the loading tool for this board; `nxpele` names `mboot` as one of its transports, but which i.MX 95 firmware
  answers on it is **unconfirmed**. The practical `nxpele` transports here are U-Boot's serial console and fastboot.
- The FRDM-IMX95-PRO's exact part number and silicon revision, which SPSDK's family and revision options need, are
  **unconfirmed**: they need UM12527 (S1) or the board's marking (question 2).

## 5. Writing the eMMC boot partitions

The uuu built-in script `emmc_burn_loader.lst` (S4), used by `uuu -b emmc <flash.bin>` and `nxpuuu write -b emmc`,
reads as follows, in our words. This is from the script text at `uuu_1.5.243` only. It was not run, so its
behaviour on the i.MX 95 is **unverified**:

1. Streams the container to the ROM over the serial downloader; the ROM authenticates and runs it.
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
  void.

The offset of the container inside the boot partition, which fastboot target maps to which partition,
and the partition the i.MX 95 ROM reads are set by U-Boot's configuration and the ROM: they belong to the boot media
and layout survey (#42) and need IMX95RM (S10), which is missing.

`uuu -b emmc_all <image.wic>` writes a whole disk image to the user area instead; it does not touch the boot
partitions' boot configuration in the same way and is not the boot-container loop.

## 6. Recovering a board that does not boot

The recovery path rests on one property: the serial downloader is in the boot ROM, so a bad container in eMMC cannot
remove it while the device is in OEM open and no fuse that disables it has been blown. Which fuses can disable the
serial downloader or change boot-mode selection is in IMX95RM or the Security Reference Manual (S10, S11), both
missing: **unconfirmed**. This survey proposes no fuse step.

The developer loop, in order of preference:

1. **Serial downloader.** Set SW4 to serial download (positions from UM12527 §2.3, S1, not confirmed here), connect
   the download USB port, and run uuu with a known-good container: the board runs it from RAM without touching
   eMMC. Then rewrite the boot partition with `uuu -b emmc <known-good flash.bin>` and set SW4 back to eMMC. While
   that recovery U-Boot runs, a later `uuu -b emmc` with any other file writes it without booting it (§5). Only
   the known-good file, checked by its SHA-256, is written in this state.
2. **SD card.** Set SW4 to SD boot with a card holding a known-good image, and repair eMMC from U-Boot. This needs
   no host tool but needs a prepared card.
3. **Second boot partition.** eMMC has two boot partitions and `mmc partconf` chooses which one boots (S4). Keeping
   the last known-good container in the other partition would give a recovery that needs no switch change. Whether
   the i.MX 95 ROM falls back between boot partitions by itself is **unconfirmed** (needs IMX95RM); without that,
   this is a manual switch done from U-Boot or over uuu (question 4).

A container the ROM rejects in OEM open still matters less than in closed: in the open life cycle the enclave
records authentication failures as events rather than refusing to run. That is the general AHAB OEM-open model; no
source in this survey states it for the i.MX 95, and the exact rule needs the Security Reference Manual (S11,
missing): **unconfirmed**. If that model holds, a bad *unsigned or mis-signed* image may run and show up only as
events; an image signed with the *wrong* SRK may run too, because nothing on an OEM-open board holds the intended
SRK hash yet. So a board that boots, with or without events, says nothing about which signing root was used (§8).
A *malformed* container that the ROM cannot parse does not boot and needs the recovery above.

## 7. What OEM open lets a developer check before any fuse

Everything below reads state; none of it writes a fuse or changes the life cycle.

- **Offline, on the host:** build the container with `nxpimage ahab export` and parse it back with `nxpimage` to check
  its structure, signature block and the SRK table hash it carries (S8). What these commands actually check at
  3.13.0 is **unverified** until the negative tests of §8 pass. `nxpimage ahab export` also emits fuse
  scripts next to the image unless `--no-fuse-scripts` is given (S8): the pipeline should pass that flag, or keep
  those scripts out of every artefact and never run them (#118 owns the negative tests).
- **On the board, after loading over USB:** read the enclave's events and status with `nxpele get-events` and
  `nxpele get-info` over U-Boot's serial console or fastboot (S8), or with U-Boot's own AHAB status command (not
  surveyed here: **unconfirmed** at a named U-Boot version). `nxpele` can also write fuses and forward a life-cycle
  change, so any script that drives it must allow the read commands only (question 6). These reads are
  **diagnostic only**. An OEM-open board has no SRK hash fused, so it cannot tell the intended signing root from any
  other, and the i.MX 95 rule for logging authentication failures in OEM open is unconfirmed (§6). An empty event
  list therefore does not show that the container was signed by the approved key. The event log design is #131.
- **Negative checks:** loading a deliberately mis-signed container in OEM open and seeing the expected event is
  possible without any risk to the board, but the plan for it is #118.
- **The key hash to be fused:** SPSDK's `fuses` feature lists the `mimx95*` families (S8), so the SRK hash words can
  be computed and compared on the host. Writing them is out of scope and is not described.

What OEM open cannot show: how the ROM behaves once closed (refusal instead of event), the anti-rollback version
check against fuses, and the boot ROM's exact rules; these need IMX95RM and the Security Reference Manual (S10,
S11), both missing.

## 8. Link to the host-side signing pipeline (#9)

The loop gives #9 a fixed hand-off. Acceptance rests on host-side checks against an independently approved SRK hash.
The board run comes after them and is diagnostic only.

**Not usable on a real device yet.** Nothing below about the tools' checks or writes has been verified. That covers
SPSDK 3.13.0's `nxpimage ahab verify` and `nxpimage ahab parse`, and uuu 1.5.243's built-in eMMC script. The
statements come from `--help` text and script text at those pinned versions (S4, S8), not from a run. They are not
established:

- that `verify` checks each container's signature cryptographically;
- that `parse` extracts the SRK table the ROM hashes;
- what the uuu script writes, and where.

The procedure must not be used to accept a container for a real device until all the required negative tests below
pass at the pinned versions.

| Test | Input | Tool step | Expected result |
|---|---|---|---|
| N1 | an unsigned container | §8 step 2 (`nxpimage ahab verify` and the SRK hash check) | **rejected** |
| N2 | a container signed with a key outside the approved SRK set | §8 step 2 | **rejected** |
| N3 | a container signed with an approved key whose payload was altered after signing | §8 step 2 | **rejected** |
| N4 | a known-good signed container (control) | §8 step 2 | accepted |

Each run records the tool version, the exact command, and output that shows the rejection. If any of N1 to N3 is not
rejected by `nxpimage ahab verify`, the procedure needs the independent signature check of owner question 7 (b).
That check is then put through the same tests. The test plan itself belongs to #118.

1. #9 builds `flash.bin` and signs its containers with the tool #30 chooses (CST 3.1.0 or SPSDK, keys in an HSM after
   AN14471, per S2). Output: the signed `flash.bin`, with fuse scripts suppressed.
2. **Acceptance, on the host, before any load or write** (tool behaviour **unverified** until N1 to N4 pass):
   1. *Signature check:* `nxpimage ahab verify -f <family> -r <revision> -b flash.bin` (SPSDK 3.13.0, S8) must
      report no problems. Its help says only "Verify AHAB Image". Whether it checks each container's signature
      cryptographically against the SRK table in the image is **unverified** at 3.13.0 (N1 to N3).
   2. *SRK hash check:* extract the SRK table with `nxpimage ahab parse -f <family> -r <revision> -b flash.bin -o
      <dir>` (S8). Compute its hash on the host and compare it, byte for byte, with the **approved SRK hash**. That
      hash is recorded by the owner from the HSM's SRK public keys, outside the build that produced the image. The
      build's own output is never the reference. Three points are **unverified**: whether `parse` extracts the SRK
      table at all, which output file carries it, and the hash rule for the i.MX 95 SRK table. They need the AHAB
      chapter of IMX95RM or the Security Reference Manual (S10, S11, missing), a check of SPSDK's source, or test N2.
   A container that fails either check is rejected and is not loaded.
3. **Board run in OEM open (diagnostic):** reset the board into SW4 serial download, load the accepted container over
   the ROM serial downloader with uuu or `nxpuuu` at the pinned version (S4/S8), boot it from RAM, and record
   `nxpele get-events` / `get-info` (S8) for #131. Record the SHA-256 of the file that was booted. The run shows
   that the container boots on this silicon, and its events help find faults. It is **not** evidence about the
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
recorded outside the build (question 7), and one known-good container kept beside every candidate for recovery.

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
   checks the same things as the ROM (§8 step 2). This is **unverified**; the negative tests N1 to N3 of §8 must pass
   first.
7. What uuu 1.5.243's built-in eMMC script writes, and where, and how uuu picks a stage when a U-Boot fastboot
   target is already running (§5). This is **unverified**: taken from the script text, not from a run. A write is
   bound to a booted candidate only by the §5 conditions (same SHA-256, same session or a fresh ROM download).
8. Which `nxpimage ahab parse` output carries the SRK table, and the i.MX 95 rule for hashing it into the fused
   value: needs IMX95RM or the Security Reference Manual (both missing), or SPSDK's source.
9. Board-side confirmation of the signing root: an OEM-open board has no SRK hash fused, so a board run in OEM open
   cannot confirm which key signed the container. Event results are diagnostic only until IMX95RM and the Security
   Reference Manual are available (§7, §8).
10. Which firmware answers `nxpele`'s `mboot` transport on the i.MX 95.
11. U-Boot's AHAB status command at a named U-Boot version (not surveyed; U-Boot belongs to #42 and #9).
12. The i.MX Linux User's Guide's i.MX 95 uuu instructions (S12, not in docs/references/).
13. Nothing here was run against a board: tool behaviour is from documentation, source history and `--help` only.

## 10. Owner questions

1. **Which host tool is pinned for loading and writing?**
   (a) standalone uuu at `uuu_1.5.243`; (b) SPSDK 3.13.0's `nxpuuu` (same libuuu 1.5.243); (c) both, uuu as
   fallback. Recommendation: **(b)**. One Python pin then covers loading, `nxpimage` checks and `nxpele` event reads in
   the #9 pipeline, and the engine is identical (S8). Keep standalone uuu as an unpinned manual fallback.
2. **Which part and silicon revision is the board?** (a) read UM12527 and the board marking and record it in SPEC.md;
   (b) query it at first power-up with `nxpele` in OEM open. Recommendation: **(a)**, confirmed by (b); SPSDK needs it
   for every family option.
3. **Obtain the missing manuals?** (a) request IMX95RM and the i.MX 95 Security Reference Manual under NDA now;
   (b) proceed with OEM-open testing only and defer every fuse question. Recommendation: **(a)**: §6 and §7 cannot be
   closed without them; (b) is safe in the meantime because nothing here fuses.
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
7. **Where does the approved SRK hash come from, and how is a container's signature checked?** (a) the owner
   records the SRK hash, computed from the HSM's SRK public keys, in a reviewed file outside the build. The pipeline
   compares each image's SRK table hash against it and runs `nxpimage ahab verify`, once the negative tests N1 to N3 of §8
   (unsigned, wrong key, tampered payload) have each been shown rejected at the pinned version. (b) as (a), with a second, independent signature check (for example CST's or
   OpenSSL's verification of each signature block against the SRK public key) whether or not `verify` passes that
   test. (c) rely on the board run in OEM open. Recommendation: **(a)**, moving to **(b)** if `verify` fails #118's
   tests. Never **(c)**: an OEM-open board holds no SRK hash, so it cannot confirm the signing root (§7).
