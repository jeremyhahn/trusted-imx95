# EdgeLock enclave event log: survey (#131)

Row: `boot-container` ([SPEC.md](../SPEC.md)). Documentation only: nothing here
runs, or scripts, a fuse, life-cycle or provisioning step.

## 1. Scope and method

This survey covers how the i.MX 95 EdgeLock secure enclave (ELE) keeps a log
of secure boot events, how U-Boot and Linux read it, how an OEM-open board is
used to check a signed image before anything is fused, and which events this
repository's tooling should decode (input to #9 and #118).

Only public sources were used: upstream and NXP source trees on GitHub, read at
the tags given in §2. Where a fact comes only from source code, it is what the
code does at that tag, not a statement from NXP's reference manuals; the
manuals that would confirm it (IMX95RM, the i.MX 95 Security Reference Manual,
the ELE API reference) are not public and were not read. Every
"unconfirmed" mark is collected in §7. Tables in this file list identifiers and
numeric codes (facts needed for interoperability), with descriptions written
here in this survey's own words.

## 2. Sources surveyed

| Id | Title | Version | URL |
|---|---|---|---|
| S1 | U-Boot, `arch/arm/mach-imx/ele_ahab.c` (AHAB commands, event decoding) | tag `v2026.01` | https://github.com/u-boot/u-boot/blob/v2026.01/arch/arm/mach-imx/ele_ahab.c |
| S2 | U-Boot, `drivers/misc/imx_ele/ele_api.c` (ELE message calls) | tag `v2026.01` (identical at `v2025.10`) | https://github.com/u-boot/u-boot/blob/v2026.01/drivers/misc/imx_ele/ele_api.c |
| S3 | U-Boot, `arch/arm/include/asm/mach-imx/ele_api.h` (command ids) | tag `v2026.01` (identical at `v2025.10`) | https://github.com/u-boot/u-boot/blob/v2026.01/arch/arm/include/asm/mach-imx/ele_api.h |
| S4 | U-Boot, `arch/arm/mach-imx/ele_ahab.c` | tag `v2025.10` (for comparison with S1) | https://github.com/u-boot/u-boot/blob/v2025.10/arch/arm/mach-imx/ele_ahab.c |
| S5 | U-Boot, `common/spl/spl_imx_container.c` (SPL container loading) | tag `v2026.01` | https://github.com/u-boot/u-boot/blob/v2026.01/common/spl/spl_imx_container.c |
| S6 | NXP U-Boot fork, `doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt` (AHAB secure boot guide for i.MX 8ULP and i.MX 9) | branch `lf_v2025.04`, head `99518e6b6f20` on 2026-11-12 | https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt |
| S7 | NXP U-Boot fork, `arch/arm/mach-imx/ele_ahab.c` | branch `lf_v2025.04`, head `99518e6b6f20` | https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/arch/arm/mach-imx/ele_ahab.c |
| S8 | Linux, `drivers/firmware/imx/` directory listing | tag `v6.18` | https://github.com/torvalds/linux/tree/v6.18/drivers/firmware/imx |
| S9 | NXP Linux fork, `drivers/firmware/imx/ele_base_msg.c` and `se_ctrl.c` (secure enclave driver) | branch `lf-6.18.y`, head `6e694eda40aa` on 2026-11-12; `lf-6.12.y` head `df24f9428e38` also read | https://github.com/nxp-imx/linux-imx/tree/lf-6.18.y/drivers/firmware/imx |
| S10 | NXP `imx-secure-enclave` library: `include/hsm/internal/hsm_get_event.h`, `src/common/hsm_api/hsm_get_event.c`, `src/common/sab_msg/include/sab_get_event.h`, `include/common/get_info.h` | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-secure-enclave/tree/lf-6.18.37-2.1.0 |

Not reached or not public: the i.MX 95 Reference Manual (IMX95RM), the i.MX 95
Security Reference Manual and the EdgeLock enclave API reference manual for the
i.MX 95 (all behind NXP's secure-files access, not read); an i.MX 95-specific
AHAB guide in either U-Boot tree (none exists at the tags above; S6 is the
nearest, covering i.MX 8ULP and i.MX 9 together); an ELE driver in mainline
Linux (S8 lists none at `v6.18`).

## 3. How the enclave records secure boot events

**What the log is.** The enclave firmware keeps a short list of 32-bit event
words. U-Boot asks for it with the `ELE_GET_EVENTS_REQ` message, command id
`0xA2` (S3). The reply carries a status word, then a word whose low 16 bits
are the number of events, then the event words themselves (S2,
`ele_get_events`). U-Boot asks for at most 8 (`AHAB_MAX_EVENTS`, S1). NXP's user-space
library describes the same reply as a count, a maximum, up to 8 event words
and a CRC, and its comments say the events are those reported since the last
power cycle (S10, `sab_get_event.h`, `hsm_get_event.h`). So the log is small,
lives in the enclave's volatile state, and is lost at power-off; whether a
warm reset clears it, and whether events beyond the eighth are dropped or
overwrite older ones, is **unconfirmed**.

**What an event word contains.** U-Boot splits each word into four bytes (S1,
`display_event`):

| Bits | Field | Values decoded by U-Boot (S1) |
|---|---|---|
| 31..24 | Messaging unit (MU) the request came through | `0x1` the real-time domain MU, `0x2` the application domain MU |
| 23..16 | The command that produced the event | any ELE command id, e.g. `0x02` firmware authenticate, `0x87` OEM container authenticate, `0x88` verify image, `0x89` release container, `0xA2` get events (full list in S3) |
| 15..8 | Indication: why the command failed | see the table below |
| 7..0 | Status | `0xD6` success, `0x29` failure |

The layout above is the one U-Boot uses; that the boot ROM writes events in
the same layout as the firmware's own command replies is inferred from U-Boot
decoding both with one table, and is **unconfirmed** against an NXP manual.

**Indication codes relevant to secure boot.** S1 names about 55 indication
codes. Those that concern authenticating a signed boot container are below,
with this survey's reading of each name:

| Code | Name in S1 | Meaning (this survey's reading) |
|---|---|---|
| `0xF0` | `ELE_BAD_SIGNATURE_FAILURE_IND` | a container or image signature did not verify |
| `0xF1` | `ELE_BAD_HASH_FAILURE_IND` | an image's hash does not match its entry in the container |
| `0xF2` | `ELE_INVALID_LIFECYCLE_IND` | the operation is not allowed in the current life cycle |
| `0xF3` | `ELE_PERMISSION_DENIED_FAILURE_IND` | the requester may not perform the operation |
| `0xF7` | `ELE_BAD_CONTAINER_FAILURE_IND` | the container header is malformed |
| `0xF8` | `ELE_BAD_VERSION_FAILURE_IND` | a version field is not accepted |
| `0xF9` | `ELE_INVALID_KEY_FAILURE_IND` | a key in the container is not usable |
| `0xFA` | `ELE_BAD_KEY_HASH_FAILURE_IND` | the SRK table does not hash to the fused SRK hash |
| `0xFB` | `ELE_NO_VALID_CONTAINER_FAILURE_IND` | no valid container was found |
| `0xFC` | `ELE_BAD_CERTIFICATE_FAILURE_IND` | the signing certificate is rejected |
| `0xFD` | `ELE_BAD_UID_FAILURE_IND` | the device UID bound into a certificate or message does not match |
| `0xFE` | `ELE_BAD_MONOTONIC_COUNTER_FAILURE_IND` | the anti-rollback counter check failed |
| `0xE0` | `ELE_MUST_SIGNED_FAILURE_IND` | an unsigned item was given where a signed one is required |
| `0xEE` | `ELE_NO_AUTHENTICATION_FAILURE_IND` | authentication was not performed |
| `0xEF` | `ELE_BAD_SRK_SET_FAILURE_IND` | the SRK set selected is wrong |
| `0xD0` | `ELE_CORRUPTED_SRK_FAILURE_IND` | the SRK table is corrupted |
| `0xCE` | `ELE_OLD_VERSION_FAILURE_IND` | the image version is below the rollback floor |
| `0xBB` | `ELE_AUTH_SKIPPED_OR_FAILED_FAILURE_IND` | an authentication step was skipped or failed |
| `0xC3`..`0xC6` | `ELE_BAD_IMAGE_{NUM,ADDR,PARAM,TYPE}_FAILURE_IND` | an image entry in the container has a bad index, address, parameter or type |
| `0xCD` | `ELE_WRONG_BOOT_MODE_FAILURE_IND` | the operation is not allowed in this boot mode |
| `0xB9` | `ELE_CRC_ERROR_IND` | a CRC check failed |

The others in S1 concern the messaging unit, fuses (`0xAA`, `0xAB`, `0xAD`,
`0xF6`), memory and DMA, the RNG and power features. The meaning column is
inferred from the identifiers only; NXP's own definitions are in the ELE API
reference, which is **not public** and was not read.

**The life cycle.** U-Boot reads the life cycle from the fuse shadow block
(FSB). From `v2026.01` it has an i.MX 95 and i.MX 94 specific table: offset
`0x414`, `0x10` is OEM open, `0x20` OEM secure world closed, `0x40` OEM
closed, `0x80` OEM locked, then field return and bricked states (S1,
`display_life_cycle`). At `v2025.10` U-Boot used one table for all ELE parts,
at offset `0x41c`, in which `0x8` is OEM open (S4); on an i.MX 95 that release
therefore shows the wrong life cycle. A point for the tooling: S1 masks the
value with `0x3ff`, so the i.MX 95 "bricked" value `0x400` cannot be shown and
is printed as unknown.

## 4. How U-Boot and Linux read the log

### U-Boot

With `CONFIG_AHAB_BOOT` set (S6, §1.2), U-Boot has these console commands
(S1, S7):

- `ahab_status` reads the life cycle from the fuse shadow block, sends the
  get-events message and prints each event word, raw and split into the four
  fields of §3, or a line saying no events were found.
- `auth_cntr` asks the enclave to authenticate a container at an address in
  memory, which adds an event if it fails.
- `ahab_close`, `ahab_return_lifecycle` and the secure fuse commands change
  fuses or the life cycle. They are named here only so that a reader knows
  what not to run; this repository does not use or script them.

U-Boot's SPL also uses the enclave while loading a container: it asks for the
container header to be authenticated, then each image to be verified, then
the container released (S5). When the enclave's reply is a failure, SPL
prints the indication by name and stops loading that container (S1
`ahab_verify_cntr_image`, S5).

Which release to use matters for the i.MX 95: the i.MX 95 life-cycle table is
in NXP's `lf_v2025.04` (S7) and in mainline from `v2026.01` (S1), but not in
mainline `v2025.10` (S4). The event decoding is the same in all three.

### Linux

Mainline Linux has no EdgeLock enclave driver at `v6.18` (S8). NXP's fork has
one (S9): its kernel-side messages cover get-info, ping, firmware
authentication, debug dump, fuse read and write, RNG start, voltage change and
firmware version, but **no get-events message** at `lf-6.18.y` or
`lf-6.12.y`. The driver exposes a character device whose ioctl
`SE_IOCTL_CMD_SEND_RCV_RSP` passes a message from user space to the enclave and
returns the reply (S9, `se_ctrl.c`), and sysfs counters for timeouts and
recovery, not for events.

The user-space reader is NXP's `imx-secure-enclave` library: `hsm_get_event()`
returns up to 8 events, each split into a 16-bit response code (the
indication and status bytes), the command id and the messaging unit, the same
fields U-Boot decodes (S10). Its get-info call also returns the chip life
cycle (S10, `get_info.h`). Whether `hsm_get_event()` is built and works for
the i.MX 95 enclave, rather than only for the parts with a V2X HSM, is
**unconfirmed**: the source has no SoC check, but no public NXP page says it
is supported on the i.MX 95.

## 5. Open life cycle: checking a signed image before any fuse is written

In the OEM-open life cycle the enclave still checks the signed containers it
is given, records what it would have refused, and lets the board boot; in the
OEM-closed life cycle the same failure stops the boot. Neither part of that
sentence is stated in a public NXP document read for this survey. It is
inferred from NXP's own procedure (S6, §1.4 to §1.8): build and sign the
image, fuse the SRK hash while the part is still open, boot the signed image,
run `ahab_status` and expect the life cycle "OEM Open" with no events, and
only then move to OEM closed. U-Boot's close command prints the same
condition as a warning, that the board must boot a signed image without any
events reported first (S1, `confirm_close`). That procedure only makes sense
if an open part boots despite failures and logs them. Note that S6's sample
output shows life cycle `0x8` as "OEM Open", which is the i.MX 8ULP / i.MX 93
encoding; on an i.MX 95 the value is `0x10` (S1, S7).

What this means for this repository:

1. **Before any fuse.** On a board whose SRK hash is not fused, the signature
   checks can still be exercised, but the enclave has no fused hash to match
   the container's SRK table against. What it reports then, whether a
   bad-key-hash indication (`0xFA`), no event at all, or something else, is
   **unconfirmed**: no public source shows the output. Until it is seen on
   the board, a pre-fuse run proves only that the board reports no failure
   other than the expected one; that expected event must be recorded from
   the board itself, not assumed.
2. **After the SRK hash is fused, still open.** S6's criterion applies: zero
   events after booting the signed image. Fusing is the owner's step and is
   out of scope here.
3. **Host-side checks** (a container's layout, its SRK table hash, the
   signature) do not depend on the board's life cycle and catch most of the
   failures in §3 before the image is ever loaded. Which host tool does this
   for the i.MX 95 (SPSDK or CST) is for #9, not decided here.

## 6. Events this repository's tooling should decode (input to #9 and #118)

1. **The event word**, split into the four fields of §3, and printed raw as
   well, because the tables come from U-Boot and not from an NXP manual.
2. **The life cycle**, with the i.MX 95 encoding (S1, S7), read with a mask
   wide enough for `0x400` (bricked), unlike U-Boot's `0x3ff` (§3).
3. **The secure boot indications** of §3's table, grouped as:
   - signature and key: `0xF0`, `0xF9`, `0xFA`, `0xFC`, `0xEF`, `0xD0`;
   - image and container content: `0xF1`, `0xF7`, `0xFB`, `0xC3`..`0xC6`,
     `0xE0`, `0xB9`;
   - rollback: `0xF8`, `0xCE`, `0xFE` (the input to the anti-rollback floor
     in [SPEC.md](../SPEC.md)'s `boot-container` row);
   - policy: `0xF2`, `0xF3`, `0xFD`, `0xCD`, `0xEE`, `0xBB`.
4. **The command byte** for at least `0x02`, `0x87`, `0x88`, `0x89`, so that
   a failure can be tied to the stage (enclave firmware, container header,
   image, release) that produced it.
5. **Any other code** printed as unknown with its raw value, never dropped.
6. **The empty log**: the decoder should say explicitly when there were no
   events, since that is the pass criterion in §5.

The code tables should be kept as data with the U-Boot tag they were taken
from, so that a newer U-Boot or an NXP manual can update them.

## 7. What could not be confirmed

- That the ROM's boot events and the firmware's command replies share the
  layout in §3 (inferred from U-Boot decoding both with one table).
- NXP's own definition of each indication code; the meanings in §3 are read
  from the identifiers.
- The log's capacity beyond 8 entries, its behaviour when full, and whether a
  warm reset clears it.
- That an OEM-open i.MX 95 boots past an authentication failure and logs it
  (inferred from S6's procedure and S1's warning, §5).
- What an i.MX 95 with no SRK hash fused reports for a signed image (§5).
- That `imx-secure-enclave`'s `hsm_get_event()` is supported on the i.MX 95.
- Anything in IMX95RM, the i.MX 95 Security Reference Manual or the ELE API
  reference manual, none of which is public.

## 8. Questions for the owner

1. **Where does the tooling read the event log?**
   (a) U-Boot's `ahab_status` output, captured from the console;
   (b) Linux, through `imx-secure-enclave`'s `hsm_get_event()`;
   (c) both.
   Recommendation: (a) first. It is in mainline U-Boot at a pinned tag
   (S1) and is the path NXP's own procedure uses (S6); (b) depends on NXP's
   kernel fork and on support for the i.MX 95 that is unconfirmed (§4).
2. **Which U-Boot release do we pin?**
   (a) mainline `v2026.01` or later; (b) NXP `lf_v2025.04`; (c) whatever the
   board's BSP ships.
   Recommendation: (a) or (b), not older mainline: before `v2026.01`
   mainline decodes the i.MX 95 life cycle wrongly (S4). Between (a) and (b)
   the sources do not decide; it follows the platform image's choice.
3. **What is the source of truth for the code tables?**
   (a) U-Boot's tables (S1), as data with the tag; (b) the ELE API reference
   manual, obtained from NXP; (c) (a) now, checked against (b) when it is
   obtained.
   Recommendation: (c).
4. **What is the pass criterion before the SRK hash is fused?**
   (a) none: rely on host-side checks only until the hash is fused;
   (b) boot the signed image on the unfused open board, record the events it
   reports, and accept exactly that recorded set; (c) both.
   Recommendation: (c), with the expected set taken from the board, because
   no public source gives it (§5, §7).
5. **What is the pass criterion after the SRK hash is fused, before closing?**
   (a) zero events, as S6 requires; (b) zero events of the secure boot groups
   in §6, others allowed.
   Recommendation: (a), the vendor's own criterion (S6); the close itself
   stays the owner's manual step and is not scripted here.
6. **Should the decoder fail on an unknown code or only report it?**
   (a) fail; (b) report and continue.
   Recommendation: (a) for the pass/fail check of §5, (b) for display,
   because an unknown code means the tables are out of date.
7. **Do we obtain the non-public manuals?** IMX95RM, the i.MX 95 Security
   Reference Manual and the ELE API reference would settle every item in §7.
   (a) request them from NXP; (b) proceed on the public sources and the
   board's own output.
   Recommendation: (a), as SPEC.md already lists the first two as missing.
