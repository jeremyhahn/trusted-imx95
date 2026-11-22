# Cortex-M7 isolation on the i.MX 95: a survey

Row: `secure-world` ([SPEC.md](../SPEC.md)). Issue #123. Input to #55.

Status: survey, draft for the owner. Written from public sources only; every
claim cites a source listed in [section 2](#2-sources). Nothing in this file has
been tried on the board.

## 1. Scope

The i.MX 95 on the FRDM-IMX95-PRO runs three kinds of software that matter here:

- NXP's System Manager (SM) on the Cortex-M33, which stays NXP's code and whose
  configuration is the `system-manager-config` row of [SPEC.md](../SPEC.md);
- the Cortex-M7 firmware of trusted-firmware's `imx95` row;
- Linux, with whatever secure-world software runs under it, on the Cortex-A55
  cluster.

This survey answers three questions from issue #123: how the M7 and the A55
share memory and exchange messages; what keeps Linux and the DMA masters it
drives out of the M7's memory, and where that is configured (input to #55);
and which shared interfaces the board needs and how each one checks what
crosses it. It decides nothing. It ends with questions for the owner.

The survey names the source and version behind each claim as `[Sn]`, with the
list in section 2. Where a claim rests on reading configuration or source code
rather than on a document that states it, the text says so.

## 2. Sources

All were reached from the lane on 2026-11-12 unless marked unreachable.

| Id | Title | Version or tag | URL |
|---|---|---|---|
| S1 | NXP i.MX System Manager, configuration for the i.MX 95 FRDM board, `configs/mx95frdm.cfg` | tag `rel_imx_sm_2026q3` (commit `eec2328`) | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/configs/mx95frdm.cfg |
| S2 | NXP i.MX System Manager documentation, "Configuration" (`sm/doc/config.md`) | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/config.md |
| S3 | NXP i.MX System Manager documentation, "Architecture" (`sm/doc/arch.md`) | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/arch.md |
| S4 | NXP Linux for i.MX, device tree of the FRDM-IMX95 board (`arch/arm64/boot/dts/freescale/imx95-15x15-frdm.dts`) | tag `lf-6.12.49-2.2.0` | https://github.com/nxp-imx/linux-imx/blob/lf-6.12.49-2.2.0/arch/arm64/boot/dts/freescale/imx95-15x15-frdm.dts |
| S5 | NXP RPMsg-Lite, "RPMSG-Lite Design Considerations" (`doxygen/rpmsg_lite_design_considerations.md`) | tag `v5.5.0` | https://github.com/nxp-mcuxpresso/rpmsg-lite/blob/v5.5.0/doxygen/rpmsg_lite_design_considerations.md |
| S6 | NXP RPMsg-Lite, README | tag `v5.5.0` | https://github.com/nxp-mcuxpresso/rpmsg-lite/blob/v5.5.0/README.md |
| S7 | Linux kernel documentation, "Remote Processor Framework" (`Documentation/staging/remoteproc.rst`), as carried in NXP's tree | tag `lf-6.12.49-2.2.0` | https://github.com/nxp-imx/linux-imx/blob/lf-6.12.49-2.2.0/Documentation/staging/remoteproc.rst |
| S8 | [SPEC.md](../SPEC.md) of this repository, rows `secure-key-handling` and `system-manager-config` (cites NXP RM00284 for the EdgeLock HSM API) | `main` at the time of writing | (this repository) |

Fetched but not read, because the lane's tooling does not open source or
YAML files outside the repository: the Linux `imx_rproc.c` remoteproc
driver, the `imx-mailbox.c` driver, the `fsl,imx-rproc.yaml` and `fsl,mu.yaml`
bindings and `Documentation/staging/rpmsg.rst`, all at `lf-6.12.49-2.2.0`. Claims
that would rest on them are in section 6.

Not found: a device tree named for the FRDM-IMX95-PRO at `lf-6.12.49-2.2.0`.
This survey uses the FRDM-IMX95 tree (S4); whether the PRO board uses it
unchanged is in section 6.

Board caveat: S1 (`mx95frdm.cfg`) and S4 (`imx95-15x15-frdm.dts`) describe
the 15x15 FRDM-IMX95 board, not the FRDM-IMX95-PRO (machine
`imx95-19x19-lpddr5-frdm-pro`). The PRO names an SM configuration
`mx95frdm-pro` whose source is unconfirmed
([upstream-survey.md](upstream-survey.md)). Every MU assignment, memory
range and right in sections 3, 4 and 5 that cites S1 or S4 is therefore
**unverified for the PRO** until its own configuration and device tree are
read.

## 3. How the Cortex-M7 and the Cortex-A55 share memory and exchange messages

NXP's public sources show three paths between the M7 and the rest of the
chip. None of them is a direct A55-to-M7 call; each is a doorbell in a
messaging unit (MU) plus a buffer in memory both sides can reach.

### 3.1 Messaging units

An MU is the hardware doorbell between two cores: each side, A and B, has
its own register block, and a write on one side raises an interrupt on the
other. The SM gives every SCMI agent its own MU channel [S3]; the payloads
live in shared memory, not in the MU [S1, S3]. The SM configuration assigns each MU side to one LM,
so the TRDC lets only that LM's masters touch it [S1].

In NXP's FRDM configuration [S1] (15x15 board; unverified for the PRO, see
the board caveat in section 2):

- MU9, M7 to SM: the M7 is SCMI agent 0 of the SM, with three channels
  (requests, notifications, priority notifications). The shared-memory
  transport (SMT) on all three is configured with a CRC-32 check.
- MU5 side A, MU7 side B and MU8 side B belong to the M7. Linux's device tree
  for the FRDM board points its remoteproc driver at MU7 (transmit, receive
  and a receive doorbell), so MU7 is the A55-to-M7 mailbox [S1, S4].
- MU_ELE5 belongs to the M7: the M7 has its own MU to the EdgeLock enclave.
  The A55 secure environment holds MU_ELE1 and MU_ELE2 [S1].
- The A55 secure environment is SCMI agent 1 (MU1) and Linux is SCMI agent 2
  (MU3) [S1]. Linux therefore reaches the M7's lifecycle only through the SM,
  not through the M7.

### 3.2 RPMsg between Linux and the M7

NXP's Linux device tree for the FRDM-IMX95 (tag `lf-6.12.49-2.2.0`) declares
the M7 as a remote processor (`fsl,imx95-cm7`) with the SM's LM 1 and CPU 1
as its identity, and reserves, with `no-map`, the RPMsg memory
[S4]:

| Region | Address | Size |
|---|---|---|
| Two vring pairs (vdev0, vdev1) | `0x8800_0000`-`0x8801_FFFF` | 4 × 32 KiB |
| RPMsg buffer pool (`shared-dma-pool`) | `0x8802_0000` | 1 MiB |
| Resource table | `0x8822_0000` | 4 KiB |

All of it lies in the 32 MiB DDR window that the SM grants to both the M7 and
Linux (section 4.2). The device-tree comment says the CPU and LM identities
must match the SM firmware [S4]; Linux starts, stops and attaches to the M7
through the SM's LMM and CPU protocols over its own SCMI channel, by our
reading of the device tree and the SM configuration, which grants Linux
`LMM_1` notifications only and grants the A55 secure environment no `LMM_1`
rights at all [S1, S4]. Whether Linux can therefore start or stop the M7 under
NXP's configuration could not be confirmed from the documents alone (section 6).

Linux's own SCMI rights are not the only path. NXP's TF-A fork adds
normal-world SiP calls that set the M7's reset address and start, stop and
query it, and an LMM SiP call that boots or force-shuts down a logical machine
chosen by the caller, with no allow-list in TF-A
([tfa-scmi-survey.md](tfa-scmi-survey.md) §2.2;
[attack-surface-survey.md](attack-surface-survey.md) §3.1). TF-A makes those
calls with the secure agent's (`AP-S`) rights, not Linux's. A compromised
Linux can therefore reach M7 lifecycle control through TF-A even where its
own SCMI agent holds notifications only. Whether the SM configuration
refuses those calls from `AP-S` (for example because the SYS, CPU or LMM
rights it holds do not cover the M7) was not established and is
**unverified**; it has not been tested on the PRO (interface I6, section 6
item 9).

On the M7, NXP's RPMsg-Lite (tag `v5.5.0`) is the usual peer. Its README
states that the shared memory must be reachable by both cores, non-cacheable
(or managed with its cache option), and kept away from the rest of the
application. It carries 496-byte payloads by default, runs receive callbacks
in interrupt context, and offers zero-copy send and receive in which the
application reads the message straight from shared memory [S6]. Two of its
options matter for this survey: clearing of used buffers is off by default,
and the check on buffer pointers passed back to the zero-copy calls is off
by default and documented as not for use with a Linux peer [S6].

### 3.3 The resource table

At M7 start-up Linux's remoteproc framework reads the firmware's resource
table to learn the vrings and buffers [S7]. On the FRDM device tree the
table sits in the shared window [S4], so it is writable by Linux once the M7
runs. Anything the M7 firmware reads back from it after start-up is input
from Linux.

## 4. What keeps Linux and its DMA masters out of the Cortex-M7's memory

### 4.1 The mechanism: SM logical machines programming the TRDC

On the i.MX 95 the access control between cores and bus masters is the
TRDC (Trusted Resource Domain Controller). Linux does not program it. The
System Manager does, from a static configuration compiled into the SM image:
the SM documentation lists a `config_trdc.h` per configuration, and says the
SM writes that TRDC data when the mix that holds each TRDC instance powers
up; the write that switches the TRDC on is conditional, and the documentation
notes that on silicon the EdgeLock enclave enables it by default [S2].

The SM groups cores and masters into logical machines (LMs). Each LM has a
domain ID (DID); the configuration then gives each LM ownership of
peripherals, clocks, MUs and memory ranges, and the SM tool turns that into
TRDC master-domain assignments and memory region checks [S1, S2]. LM0 is
always the SM itself and owns resources exclusively [S2].

### 4.2 What NXP's FRDM configuration gives the M7 and Linux

Read from NXP's FRDM configuration [S1]; the addresses are NXP's defaults
for the 15x15 FRDM-IMX95 board, not this board's decision, and are
**unverified for the FRDM-IMX95-PRO** (section 2 board caveat):

| Logical machine | DID | Memory it is given |
|---|---|---|
| LM0, the SM (M33) | 2 | its own memory; that part of the file was not surveyed |
| LM1, the M7 | 4 | M7 TCM windows `0x2038_0000`-`0x2047_FFFF` and `0x4A06_0000`-`0x4A09_FFFF`; DDR `0x8000_0000`-`0x89FF_FFFF` |
| LM2, the A55, secure environment | 3 | OCRAM 256 KiB at `0x2048_0000`; DDR `0x8A00_0000`-`0x8DFF_FFFF`, secure only |
| LM2, the A55, non-secure environment (Linux) | 3 | DDR `0x8800_0000`-`0x89FF_FFFF` and `0x8E00_0000` upward, plus OCRAM, GPU and FlexSPI windows |

What follows from that table, by our reading:

- The DDR range `0x8000_0000`-`0x87FF_FFFF` (128 MiB) is reachable by the M7
  and not by Linux. The 32 MiB at `0x8800_0000`-`0x89FF_FFFF` is granted to
  both: that is the shared window. The DDR rows of the ELE and V2X domains
  also cover the whole of DDR, so the M7's DDR is not exclusive against
  those two NXP-firmware domains [S1].
- The A55 secure and non-secure environments are one LM with one DID; the
  TRDC tells them apart by the bus secure attribute, not by domain. Linux's
  DMA masters are assigned to LM2's non-secure environment as owners (for
  example eDMA1 and its channels, the display, camera and NETC blocks), so
  their accesses carry DID 3 non-secure and fall under the same memory
  checks as Linux [S1].
- The M7's ownership list carries the M7 core, its own MUs (MU5 side A,
  MU7 and MU8 side B, the ELE MU5), its watchdog, timers, one CAN-FD and one
  UART [S1].

What this means for #55: the M7's private memory is protected only if the
SM configuration this repository builds (row `system-manager-config`) keeps
the M7's DDR range out of every non-secure A55 memory entry and keeps every
Linux-owned DMA master in the A55 non-secure domain. NXP describes the SM's
access rights and RDC policies as static, compiled into the SM binary, and
says the SM loads the RDC configuration before it starts any other core
[S3]; Linux has no run-time path to change them other than the SCMI calls
the configuration grants it. That the SM image itself is verified at boot is
the `boot-container` row's subject in [SPEC.md](../SPEC.md), not this survey's.

## 5. Shared interfaces this board needs and how each validates its input

"Decides" names who owns the choice: **TF** is trusted-firmware's `imx95`
row (the M7 firmware), **this repo** is this repository's
`system-manager-config` or `secure-world` row, **NXP** is code that stays
NXP's.

| # | Interface | Carrier | What the sources say checks it | Decides |
|---|---|---|---|---|
| I1 | M7 to SM (SCMI) | MU9, SMT shared memory, three channels | The SM checks every call against the agent's per-protocol, per-resource rights compiled into its configuration [S3]; the FRDM configuration adds a CRC-32 on the M7's channels [S1]. A CRC detects corruption; it does not authenticate. | Rights: this repo. Which calls the M7 makes: TF. SM code: NXP. |
| I2 | Linux to M7 (RPMsg) | MU7 doorbells, vrings, buffer pool and resource table in the shared DDR window | No transport-level check against a hostile peer is described. The master side, which is Linux, sets up the shared memory and vrings [S5]; RPMsg-Lite's pointer check is off by default and documented as unsuitable for a Linux peer, and buffer clearing is off by default [S6]. | TF, entirely: see below. Window placement and size: this repo (SM configuration and device tree). |
| I3 | M7 to EdgeLock enclave | MU_ELE5, owned by the M7 [S1] | The enclave validates its own commands; the HSM API and its strict-operation rule are in RM00284, as cited in SPEC.md [S8]. | Whether the M7 or Linux calls the HSM API: owner (SPEC.md open question) [S8]. Key policy: TF. |
| I4 | Linux to SM, M7 lifecycle | Linux's SCMI agent (MU3), LMM protocol | The SM checks Linux's rights; in NXP's FRDM configuration Linux holds only notifications on the M7's LM [S1]. This bounds the direct path only; see I6 for the path through TF-A. | this repo. |
| I5 | A55 secure world to M7 | none in NXP's FRDM configuration [S1] | n/a | this repo (`secure-world` row) and owner. |
| I6 | Linux to TF-A to SM, M7 lifecycle (indirect) | SMC into NXP TF-A's SRC (M7) and LMM SiP services, which call the SM over the secure agent's channel (`AP-S`, MU1) ([tfa-scmi-survey.md](tfa-scmi-survey.md) §2.2) | TF-A checks nothing: any normal-world caller may set the M7 reset address, start or stop it, or boot or shut down a logical machine it names. The SM checks only `AP-S`'s rights, not Linux's. Whether those rights refuse M7 control is **unverified**, not tested on the PRO. | this repo (`secure-world` row: remove the services from TF-A or restrict them) and the SM configuration. |

### 5.1 What the M7 firmware has to check on I2

Because Linux is the RPMsg master, writes the vrings and can write the whole
shared window at any time [S1, S4, S5], every field the M7 reads there is
untrusted input. From the sources above, the M7 side of I2 has to, at least:

1. Treat each descriptor address and length from a vring as hostile: accept
   only buffers wholly inside the reserved buffer pool, and only the sizes
   the configuration fixes (496-byte payload by default [S6]).
2. Copy each message into M7-private memory before parsing it, so Linux cannot
   change it between check and use. This rules out RPMsg-Lite's zero-copy
   receive for anything security-relevant [S6].
3. Bound vring indices and the count of buffers handed back, so a misbehaving
   master cannot make the M7 loop or overrun [S5].
4. Never read configuration back from the resource table after start-up
   (section 3.3).
5. Never place a secret in the shared window; if a reply carries sensitive
   data, clear the buffer on release (RPMsg-Lite's clear-used-buffers option,
   off by default) [S6].
6. Parse an application-level message format with explicit lengths and a
   version, and reject anything else. That format is not defined by any source
   surveyed; it is TF's to define.

These are derived from the sources' description of who controls what, not
quoted from a vendor security guide; no NXP document reached here states a
threat model for RPMsg.

## 6. What could not be confirmed

1. The TRDC registers the SM tool generates for `mx95frdm` were not read;
   section 4.2 is our reading of the configuration file, not of the generated
   `config_trdc.h` or of the TRDC chapter of the reference manual (IMX95RM,
   listed as missing in SPEC.md).
2. Whether NXP's FRDM configuration lets Linux start or stop the M7. The
   configuration grants Linux only LMM notifications on LM1 [S1], but the
   Linux driver `imx_rproc.c` could not be read from the lane.
3. How Linux avoids the M7-private DDR range. NXP's FRDM device tree
   declares memory from `0x8000_0000` and lets the default CMA pool allocate
   from `0x8000_0000` upward, while reserving only the shared window [S4]; the
   SM configuration denies Linux `0x8000_0000`-`0x87FF_FFFF` [S1]. Whether the
   boot loader rewrites the memory node, or Linux would fault on first use,
   was not found.
4. The meaning of the FlexSPI memory entry in Linux's non-secure environment,
   which as written spans `0x0000_0000`-`0xFFFF_FFFF` [S1]. If the tool applies
   it to the whole address map rather than to the FlexSPI window, it would
   cover the M7's memory. Not confirmed either way.
5. Whether the i.MX 95 has an IOMMU in front of Linux's DMA masters, and who
   programs it. If Linux programs it, it is no defence against Linux.
6. Whether the FRDM-IMX95-PRO uses the FRDM-IMX95 device tree and SM
   configuration unchanged. S1 and S4 are the 15x15 board's files; the PRO's
   `mx95frdm-pro` configuration has no confirmed source, so sections 3 to 5
   are unverified for the PRO.
7. The MU register model (side A and side B semantics) is described from the
   SM documentation's summary [S3]; the MU binding and the reference manual
   were not read.
8. Whether the ELE and V2X domains' whole-DDR access [S1] is a fixed property
   of NXP's firmware or a configuration choice.
9. Whether the SM refuses NXP TF-A's M7 and LMM SiP calls (interface I6)
   when they are made under `AP-S` rights, and which TF-A build the PRO ships
   with. Until the services are removed from TF-A, or a restriction is tested
   on the PRO, Linux's notification-only SCMI rights do not establish that
   Linux cannot stop or restart the M7.

## 7. Questions for the owner

1. **Where does the M7's private memory live?**
   (a) NXP's default: 128 MiB of DDR at `0x8000_0000` plus the M7 TCMs [S1];
   (b) TCM and OCRAM only, with no private DDR;
   (c) a different DDR range sized to trusted-firmware's image.
   Recommendation: (a) as a starting point, because it is what NXP's
   configuration and device tree already agree on [S1, S4], with question 6
   answered before it is relied on.

2. **How large is the shared window and what goes in it?**
   (a) NXP's 32 MiB at `0x8800_0000`, of which RPMsg uses about 1.2 MiB [S1, S4];
   (b) shrink the window to the RPMsg regions only.
   Recommendation: (b): the rest of the 32 MiB is memory both sides can
   write and nothing in the sources needs it.

3. **Who may start, stop and reload the M7?**
   (a) only the SM at boot, Linux attaches (NXP's FRDM rights [S1]);
   (b) Linux through LMM, so it can reload the M7 firmware;
   (c) the A55 secure world only.
   Recommendation: (a), because any other choice lets the less trusted side
   restart the M7 with firmware of its choosing unless boot-container
   verification covers reloads, which no source reached here confirms.
   Precondition: NXP's notification-only rights for Linux do not by themselves
   give (a). NXP's TF-A exposes M7 and LMM SiP calls to the normal world that
   act with the secure agent's rights (I6). Policy (a) holds only once those
   services are removed from TF-A, or restricted in TF-A or the SM
   configuration and that restriction is tested on the PRO. Until then the
   restriction is **unverified** and (a) is not in effect.

4. **Which side calls the EdgeLock HSM API?** (SPEC.md `secure-key-handling`.)
   (a) the M7 over its own enclave MU, MU_ELE5 [S1];
   (b) Linux over the A55's enclave MUs;
   (c) both, for different keys.
   Recommendation: (a): the M7 already owns an enclave MU in NXP's
   configuration, and it keeps key operations off the RPMsg path.

5. **Does the A55 secure world talk to the M7?**
   (a) no channel (NXP's FRDM configuration [S1]);
   (b) a dedicated MU and a secure-only shared region.
   No recommendation: the sources do not say what the A55 secure world on this
   board will run (SPEC.md `secure-world`).

6. **Check the open points of section 6 before #55 relies on them?**
   (a) yes, on the board, read-only: dump the generated TRDC configuration and
   confirm Linux faults on the M7 range, with no fuse or life-cycle change;
   (b) accept the configuration reading as is.
   Recommendation: (a), for items 3, 4 and 5 at least.

7. **RPMsg library on the M7.**
   (a) RPMsg-Lite with zero-copy receive disabled and buffer clearing enabled
   [S6]; (b) OpenAMP; (c) a smaller purpose-built vring reader.
   No recommendation from the sources; this is trusted-firmware's choice,
   and section 5.1 applies to whichever is taken.
