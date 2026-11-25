# Platform image: eMMC layout

> **Status: proposed, pending owner approval.** Provisional, pending the owner's answer on the image build system
> (#14). This document decides nothing: it puts, region by region, what is known about where each piece of the image
> sits on the FRDM-IMX95-PRO's eMMC, with the source of each fact. A fact without a source is marked
> **unconfirmed**. Refs #160.

## Scope

The four regions of the eMMC device (the two hardware boot partitions, the RPMB partition and the user area): what
sits in each, at what offset, and who writes it. Not covered: the update and rollback path (still
[Missing](architecture.md#missing)), the production boot medium decision (the owner's), and any procedure for
writing the device. Board steps are named only to say what they do; they are **board steps outside this lane**, and
nothing here runs, scripts or authorises one.

## Sources

| ID | Source | Used for |
|----|--------|----------|
| S-rows | [boot-media-survey.md](boot-media-survey.md), section 1 (S1 to S11) and the sections cited per row | `flash.bin` offsets, the U-Boot environment, `uuu` behaviour |
| F | [docs/ftpm/README.md](../ftpm/README.md) | RPMB and the REE file system as the fTPM's NV |
| R | [rpmb-survey.md](../secure-key-handling/rpmb-survey.md) | The RPMB key: one-time, irreversible |
| W | `platform-image/files/wic/trusted-imx95.wks` as proposed in #140 (PR #158, branch `row/140-ftpm-image`), **not on this branch** | The user-area partitions |
| O | Owner ruling 1234, as stated in the brief of this lane; not recorded in a document of this repository | Who writes the production RPMB NV |

## Regions

Columns: what sits there, where, who writes it, source. "Unconfirmed" is the answer where no source gives it.

### boot0 (hardware boot partition 1)

| What | Offset | Written by | Source |
|------|--------|------------|--------|
| `flash.bin` (the boot container set) when the eMMC boot partition is the boot medium | 0 of the partition | NXP's fastboot code through `uuu` (a board step), or the boot-container flow of the image | boot-media-survey §3.5 (S6, S8) |
| Which partition the boot ROM reads (the boot-partition configuration, `mmc partconf`) | a setting on the eMMC device, not data in the partition | `uuu`'s eMMC scripts set it; it can be changed back | boot-media-survey §4 (S8) |
| Whether the boot ROM falls back to the user area at 32 KiB when booting from eMMC, and whether a secondary container set exists | unconfirmed | unconfirmed | boot-media-survey §3.5 (U4, unconfirmed there) |

### boot1 (hardware boot partition 2)

| What | Offset | Written by | Source |
|------|--------|------------|--------|
| Nothing is proposed or sourced for it. Unconfirmed whether it holds a second copy of `flash.bin` | unconfirmed | unconfirmed | no source in boot-media-survey §3.5 or §4 |

### RPMB

| What | Offset | Written by | Source |
|------|--------|------------|--------|
| The fTPM's NV, only if RPMB is chosen over the REE file system | addressed by RPMB block, not by byte offset; layout unconfirmed | OP-TEE through `tee-supplicant`; the production NV is written after OEM close by the provisioning station (owner ruling 1234) | F (storage table), O |
| The RPMB authentication key | the device's key register | Nothing in this repository writes it. Programming it is one-time and irreversible, and is the owner's decision | F §open questions, R §5, O |

### User area

| What | Offset | Written by | Source |
|------|--------|------------|--------|
| The U-Boot environment (16 KiB) | 7 MiB (`0x700000`) | U-Boot at run time; **unconfirmed:** which MMC device and hardware partition it uses | boot-media-survey §2.3 (S7) |
| `flash.bin`, when the user area is the boot medium instead of boot0 | 32 KiB (`0x8000`) | the boot-container flow, a board step | boot-media-survey §3.5 (S4, S5, S6) |
| Partition table | GPT, from the start of the device | wic, when the image is built | W |
| `/boot` (vfat, label `boot`, 256 MiB, aligned to 8192 KiB) | first partition; start offset unconfirmed | wic | W |
| `/` (ext4, label `root`, 1024 MiB fixed, 4096-byte blocks) | second partition; start offset unconfirmed | wic | W |
| `tee-data` (ext4, 64 MiB, the fTPM NV under REE FS storage) | third partition; start offset unconfirmed | wic; recreated empty by every full-image flash | W, F (REE FS row) |

The user-area partition rows are the layout **as proposed in #140 (PR #158), not on this branch**. The `/boot` start
and the two sizes the wks file marks as provisional (the root and `tee-data` sizes are "MISSING: no survey sizes
it" there) are not decided. The `flash.bin` at 32 KiB and the first partition must not overlap: whether the
alignment keeps them apart is **unconfirmed** (the partition start offsets are not given by any source).

## What is still missing

- The update and rollback path, and how the image is written to each boot device (architecture.md, Missing).
- Offsets of the user-area partitions, and whether any partition sits in front of `/boot`.
- boot1's use, the boot ROM's fallback behaviour, and the RPMB block layout of the fTPM's NV.
- The SW4 switch positions and the UM12527 sections (boot-media-survey §2.2; UM12527 was not reachable).

## Questions for the owner

1. The production boot medium, and with it whether `flash.bin` sits in boot0 or at 32 KiB of the user area:
   boot-media-survey §6, question 1. Not repeated here.
2. Whether boot1 holds anything, and whether the user-area layout of #140 is accepted: both wait on question 1 and on
   PR #158.

## Board steps outside this lane

`uuu` (serial download of `flash.bin`, writing the eMMC boot partition and the user area) and `mmc partconf` (the
boot-partition setting) are described in boot-media-survey §4 only. This lane runs neither, programs no RPMB key,
touches no fuse and no life-cycle state, and flashes nothing.
