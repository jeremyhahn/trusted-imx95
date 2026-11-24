# Enclave interface trace: what NXP's driver and library show about the A55 path to the enclave

> **Status: TRACE, facts only; no requirement (rulings 1243, 1244; R3-R12 of xkmsd-node.md are proposed, pending owner approval)** · Row: hsm-device-protocol · Issue: #24 · Read: 2026-11-24

This record answers six questions that [xkmsd-node.md](xkmsd-node.md) (§4 question 5) and the
[survey](on-device-transport-survey.md) left **unconfirmed**. It reads two NXP repositories at the tag of the pinned BSP
release. It copies no vendor code or text; it cites repository, commit and file:line only. Line numbers are 1-based.
No go-xkms code was read, and no wire-protocol detail is named here.

## Sources

| # | Title | Version read | URL |
|---|-------|--------------|-----|
| 1 | NXP linux-imx, the kernel tree (secure-enclave driver under drivers/firmware/imx) | tag lf-6.18.37-2.1.0, peeled to commit 6e694eda40aabd6671fca82b5416dbd76beeebb9 | https://github.com/nxp-imx/linux-imx |
| 2 | NXP imx-secure-enclave, the user-space library and NVM daemon | tag lf-6.18.37-2.1.0, peeled to commit 463845060a79dd9a6d39db3b3d8dff60225b9dfd | https://github.com/nxp-imx/imx-secure-enclave |
| 3 | NXP meta-imx, the Yocto layer holding the kernel recipe (pinned by `platform-image/manifest.lock`, ref rel_imx_6.18.37_2.1.0) | commit 2eb758f42cfb96042344815b7dd7755b06ba1e3b | https://github.com/nxp-imx/meta-imx |

Both tags are annotated; the commits above are what each tag peels to. The release name is the one pinned by
`secure-world/bsp.lock` (LF_RELEASE) and `platform-image/manifest.lock` (manifest_tag). **Confirmed equal:** the kernel
recipe at the pinned meta-imx commit (source 3) sets its source revision to exactly commit 1 (S3
`meta-imx-bsp/recipes-kernel/linux/linux-imx_6.18.bb:24`), on branch `lf-6.18.y` (`:22`); the revision is a literal, not a
variable. The recipe's local version suffix is `-2.1.0` (`:35`). This assumes the image builds that recipe; no
bbappend in other layers was read. In the tables below, "S1" is source 1 and "S2" is source 2.

## (a) Device nodes on the i.MX 95

- The driver matches the compatible `fsl,imx95-se` (S1 `drivers/firmware/imx/se_ctrl.c:568`). The i.MX 95 table has six
  interfaces (`se_ctrl.c:178-179`): one of type HSM, instance 0 (`se_ctrl.c:188-189`), then four V2X types (`se_ctrl.c:206`,
  `224`, `242`, `260`, `278`).
- `imx95.dtsi` defines six nodes `secure-enclave-0` to `secure-enclave-5`, each with the compatible, `mbox-names` and
  `mboxes` (S1 `arch/arm64/boot/dts/freescale/imx95.dtsi:3274-3308`). The node-name index picks the table entry
  (`se_ctrl.c:2483-2496`). The first node uses the `elemu3` messaging unit (`imx95.dtsi:3277`).
- Name: the device name is built from the type string, the instance and `_ch<n>` (`se_ctrl.c:1483-1492`; the HSM type
  string is in S1 `include/uapi/linux/se_ioctl.h:16`). Only channel 0 is registered as a node: a miscdevice with a dynamic
  minor (`se_ctrl.c:1520-1535`). The HSM node on i.MX 95 is therefore `hsm0_ch0`, under `/dev`. The library builds the same
  path (S2 `src/plat/ele/ele_os_abs_linux.c:52-53`).
- Owner and mode: the driver fills in name, minor, fops and parent only (`se_ctrl.c:1531-1534`); it sets no mode or
  owner. The mode and owner the node gets on a running system come from devtmpfs and udev, which were not read.
  **Unconfirmed** for the image. A file-name search of S2 found no udev rules file.
- Does a devicetree property or module parameter change the names or modes? None found: `se_ctrl.c` has no `module_param`
  and the only property read it makes outside the matching is the board model string (`se_ctrl.c:1032`). The binding file
  found for this driver family, `Documentation/devicetree/bindings/firmware/fsl,imx-se-fw.yaml`, lists compatibles for
  other SoCs and no `fsl,imx95-se` entry (`:23-27`). **Unconfirmed:** whether another binding file documents
  `fsl,imx95-se`; only a file-name search was made.
- Runtime knobs exist under `/sys/kernel/se` (log switch, receive timeout; `se_ctrl.c:647-654`); they do not change node
  names or modes.

## (b) The ioctl set

All in S1 `include/uapi/linux/se_ioctl.h`, dispatched at `se_ctrl.c:2300-2358`. Names and purpose only:

| Name | Purpose | Header line |
|------|---------|-------------|
| SE_IOCTL_ENABLE_CMD_RCV | mark this descriptor as the receiver of enclave-initiated commands (the NVM daemon uses it) | 112 |
| SE_IOCTL_SHARED_BUF_CFG | configure the shared buffer; refused unless the SoC flag allows it | 117 |
| SE_IOCTL_SETUP_IOBUF | map a user buffer for a request, with direction and memory-kind flags | 129 |
| SE_IOCTL_GET_MU_INFO | return interface details the user space needs (identifiers, message tags, API versions) | 136 |
| SE_IOCTL_SIGNED_MESSAGE | send a signed message; refused unless the SoC flag allows it | 142 |
| SE_IOCTL_GET_SOC_INFO | return SoC identity | 148 |
| SE_IOCTL_CMD_SEND_RCV_RSP | send one command and receive its response in one call | 154 |
| SE_IOCTL_GET_TIMER | return the request and response timestamps of the last operation | 161 |
| SE_IOCTL_GET_V2X_VERSION | return the V2X firmware version | 166 |

Any other code returns an invalid-argument error (`se_ctrl.c:2352-2357`). Besides the ioctls, the node supports
`read` and `write` (`se_ctrl.c:2366-2372`), which the driver restricts to the descriptor registered as command receiver
(`se_ctrl.c:2123`, `2173`).

## (c) Several processes or descriptors at once

- Yes, per descriptor. Each `open` makes a new per-descriptor context with its own name and shared-memory area
  (`se_ctrl.c:2220-2251`, context creation `se_ctrl.c:1463-1517`). Opens are serialised by one lock (`se_ctrl.c:2228`);
  each context has its own lock for its calls (`se_ctrl.c:2297`). **Unconfirmed:** any cap on the number of open
  descriptors; none was seen in the code read.
- How messages are kept apart: command and response exchange goes through one interface-wide mutex (`ele_common.c:158`),
  so there is one command in flight per interface. The pending-response record is a single slot that holds the waiting
  context and buffer (`ele_common.c:171-176`), and the receive callback routes a response to that slot by its message tag
  (`ele_common.c:281-286`). Responses are therefore matched by arrival order under the mutex, not by descriptor.
- Command receiver: one descriptor at a time; a second enable call returns busy (`se_ctrl.c:2302-2320`).
- The user-buffer area of the shared memory has an owner lock, taken by the first context that maps a buffer and released
  on reset of its buffer accounting or on close (`se_ctrl.c:1807-1826`, `1414-1418`).
- A message-sequence control hook is called before the lock (`ele_common.c:156`); its file `se_msg_sqfl_ctrl.c` was not
  read. **Unconfirmed** what it enforces.
- Library side: client callers and the NVM daemon open the node through the same function (S2
  `ele_os_abs_linux.c:37-64`). The client-side session code was not traced.

## (d) The message size limit

- Request, by the ioctl path: a length below the header size is refused (`se_ctrl.c:1584`), and a size field in the
  header, in words, that differs from the byte length given is refused (`ele_common.c:123`). No upper bound on the request or response
  buffer length was seen in the handler (`se_ctrl.c:1565-1640`): both are allocated from the user-supplied lengths
  (`se_ctrl.c:1594`, `1600`). **Unconfirmed** whether a check exists later in the call chain.
- Enclave-initiated commands: a receive buffer of 256 bytes is allocated (`se_ctrl.h:20`, `se_ctrl.c:2304-2312`). The
  receive callback has a branch for a larger command that sets the size to 256 (`ele_common.c:269-276`), and then sets
  the size from the received header and copies that many bytes (`ele_common.c:278-279`). The effect on an oversize
  command is not settled by the code read; recorded here as a question for the owner or NXP, not a finding about
  behaviour.
- Per-descriptor data buffer: 128 KiB (`se_ctrl.h:19`, used at `se_ctrl.c:1292`, `1307`).
- Hardware message length of the messaging unit: **unconfirmed**; the mailbox driver was not read. Reason
  (2026-11-24, lane s4): the driver tree was fetched, but the lane's read guard refused every read of vendor code files, so
  this cell, the reset cell (e) and the session-flag cell (f) were not changed.
- Timeouts: the receive wait defaults to 5000 ms and the ioctl path raises it to a long value (`se_ctrl.c:48-49`, `61`,
  `1623-1625`).

## (e) What a caller sees when the enclave or the messaging unit resets

- No reset notification or recovery code was found in `se_ctrl.c` or `ele_common.c`: the only matches for reset are the
  circuit-breaker control and the buffer accounting. **Unconfirmed** whether a reset of the enclave, or of the messaging
  unit, is handled elsewhere (for example in the mailbox driver, not read).
- What is visible is a hang. If no response arrives within the wait, the call returns a timeout error, an interface-wide
  "busy" flag is set, and a counter increments (`ele_common.c:67-93`). While the flag is set, later commands return busy
  without being sent (`ele_common.c:160-166`). A late response clears the flag and counts a recovery
  (`ele_common.c:288-297`). A manual clear exists in sysfs (`se_ctrl.c:606-617`). No close and reopen is needed for these
  steps in the code read.
- A signal during the wait returns an interrupted error (`ele_common.c:59-66`, `184-189`).
- A fatal-abort code from the enclave is logged on receive (`ele_common.c:242-246`); no distinct error to the caller was
  seen.
- System suspend and resume save and restore enclave state and re-initialise the random-number block; open descriptors
  are not touched in the code read (`se_ctrl.c:2708-2764`). **Unconfirmed** whether descriptors and sessions remain valid
  after an enclave reset or a resume. A close ends the session held by that descriptor (`se_ctrl.c:2263`).

## (f) Where the NVM daemon keeps key-store blobs, and who opens which node

- Process: a systemd unit runs the daemon as root, with three arguments from an environment file (S2
  `src/common/nvm/nvm_daemon.service:7-12`; `nvm_daemon.c:98-116`).
- Defaults in the sample environment file: storage directory `/etc/ele/`, master file `/etc/ele/ele_nvm_master`, session
  flag `0x80` (S2 `src/common/nvm/nvmd.conf:1-2`, `4`). The unit starts before the root file system targets finish
  (`nvm_daemon.service:4`).
- Files: the master blob and the per-chunk blob files are created with owner read and write only, synchronous writes (S2
  `src/plat/ele/nvm_os_abs_linux.c:45`, `163`; path built per blob id at `:96-136`; reads at `:81`, `198`).
- Node: the daemon opens the interface node through the common open function, by type, which gives the `hsm0_ch0`-form
  path (S2 `nvm_manager.c:126`; `ele_os_abs_linux.c:45-60`), then opens a session (`nvm_manager.c:141-146`) and enables
  command receive on that descriptor (`ele_os_abs_linux.c:93-99`). The command receiver is the daemon's descriptor; a
  client opens its own descriptor on the same node (see c).
- **Unconfirmed:** which node and instance the session flag value `0x80` selects (its header was not read), and the blob
  conversion format (`nvm_blob_conversion.c` not read).

## What this trace does not decide

- R6, R8 and R11 of [xkmsd-node.md](xkmsd-node.md) stay proposed, pending owner approval. Nothing here adds, changes or
  removes a requirement.
- Findings that may bear on their wording, listed for the owner: the node's mode and owner come from the image's device
  manager, not the driver (a; R6); one command in flight per interface (c; R8); no reset handling found in the driver
  (e; R11); no upper bound seen on the ioctl buffer lengths (d); blob files under a root-owned directory (f). Each is
  proposed input, pending owner approval.
- It names no wire-protocol detail; go-xkms owns it (go-xkms #1521, ruling 1243).

## Open vendor checks

**Status: proposed, pending owner approval.** A checklist, not a finding. It adds no requirement and changes none.

The four cells below stay **unconfirmed**. Reason for each: the lane read guard blocked every read of vendor code files
(2026-11-24, lanes s4 and s5), and no slice reads vendor trees. Action for each: read at the tag and cite file:line, or
ask NXP. The tag is lf-6.18.37-2.1.0 of the repository named; the peeled commits are in the Sources table (S1, S2).

| Id | Cell | Requirement | Repository | Tag or commit | Path to check | Action |
|----|------|-------------|------------|---------------|---------------|--------|
| V1 | Messaging-unit message length (section d) | R3 | NXP linux-imx, S1 (https://github.com/nxp-imx/linux-imx) | tag lf-6.18.37-2.1.0, commit 6e694eda40aabd6671fca82b5416dbd76beeebb9 | the messaging-unit mailbox driver in linux-imx | read at the tag and cite file:line, or ask NXP |
| V2 | Reset handling outside the secure-enclave driver (section e) | R11 | NXP linux-imx, S1 (https://github.com/nxp-imx/linux-imx) | tag lf-6.18.37-2.1.0, commit 6e694eda40aabd6671fca82b5416dbd76beeebb9 | the messaging-unit mailbox driver in linux-imx, and drivers/firmware/imx | read at the tag and cite file:line, or ask NXP |
| V3 | Meaning of session flag 0x80 (section f) | R4 | NXP imx-secure-enclave, S2 (https://github.com/nxp-imx/imx-secure-enclave) | tag lf-6.18.37-2.1.0, commit 463845060a79dd9a6d39db3b3d8dff60225b9dfd | src/common/nvm/nvmd.conf and src/common/nvm/nvm_daemon.c, as cited in section f | read at the tag and cite file:line, or ask NXP |
| V4 | Sequence-control file (section c) | R3 | NXP linux-imx, S1 (https://github.com/nxp-imx/linux-imx) | tag lf-6.18.37-2.1.0, commit 6e694eda40aabd6671fca82b5416dbd76beeebb9 | se_msg_sqfl_ctrl.c, under drivers/firmware/imx | read at the tag and cite file:line, or ask NXP |

The requirement column names the proposed requirement of [xkmsd-node.md](xkmsd-node.md) each cell bears on: R3 (the image
carries the enclave driver), R4 (the user-space library is pinned with the kernel) and R11 (fail closed on reset or loss
of the interface). Each is proposed, pending owner approval.
