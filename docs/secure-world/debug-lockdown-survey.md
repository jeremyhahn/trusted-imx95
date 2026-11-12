# Secure-world debug access lockdown: a survey (#61)

Status: draft survey for the owner. Documentation only: nothing here runs, scripts or
recommends running a fuse, life-cycle or provisioning step.

Row: `secure-world` ([SPEC.md](../SPEC.md)). Sources: public only.

## 1. Scope and question

Issue #61 asks how debug access to the board's secure world is to be locked down on the
FRDM-IMX95-PRO, and what must be decided before that can happen. Here "debug access"
means the ways someone holding the board can see or change secure-world state without
going through the authenticated boot chain:

- the SoC's JTAG/SWD debug port (the board's debug connector, UM12527, cited in SPEC.md);
- the debug UARTs and the consoles they carry (System Manager monitor, TF-A, OP-TEE,
  U-Boot, Linux);
- the boot-time paths that load unsigned code (the USB serial downloader, an unsigned
  image in an open part).

This file surveys what public sources say about each path, and ends with questions for
the owner. It does not choose a life cycle, fuse value or debug-credential policy: those
are the owner's decisions (SPEC.md lists the life-cycle close as an open question).

## 2. Sources surveyed

Each source is public. "Reached" means this lane read it; the version is the one read.

| # | Source | Version read | URL | Reached |
|---|---|---|---|---|
| S1 | U-Boot (NXP fork), *i.MX 8ULP / i.MX 9x AHAB secure boot guide* (`doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt`) | branch `lf_v2024.04`, commit `e3219a5` (2025-02-18) | <https://github.com/nxp-imx/uboot-imx/blob/lf_v2024.04/doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt> | yes |
| S2 | SPSDK, *Secure debug enablement on AHABv2 based devices* (Jupyter example `examples/dat/imx9/ahabv2_debug_authentication.ipynb`) | tag `v3.13.0` | <https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/examples/dat/imx9/ahabv2_debug_authentication.ipynb> | yes |
| S3 | SPSDK, *Debug authentication on i.MX9* (`examples/dat/imx9/imx9_debug_auth.rst`), a pointer page to S4 | tag `v3.13.0` | <https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/examples/dat/imx9/imx9_debug_auth.rst> | yes |
| S4 | NXP AN14579, *Secure Debug Enablement on ELE-based Platforms* | not known | <https://docs.nxp.com/bundle/AN14579/page/topics/introduction.html> | **no**: the portal renders the text with JavaScript and the lane got only the page shell; the PDF URL answered 404 |
| S5 | SPSDK, i.MX 95 DC example and its field comments (`examples/dat/imx9/inputs/dc_config_95.yaml`, `dc_config_95.diffc`) | tag `v3.13.0` | <https://github.com/nxp-mcuxpresso/spsdk/tree/v3.13.0/examples/dat/imx9/inputs> | yes |
| S6 | SPSDK, i.MX 95 DAT example configuration (`examples/dat/imx9/inputs/dat_config_95.yaml`) | tag `v3.13.0` | same directory as S5 | yes |
| S7 | NXP imx-sm, *Monitor* (`sm/doc/monitor.md`) | tag `rel_imx_sm_2026q3` (also `lf-6.18.37-2.1.0`), commit `eec2328` (2026-09-03) | <https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/monitor.md> | yes |
| S8 | NXP imx-sm, *Debug* (`sm/doc/debug.md`) | same as S7 | <https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/debug.md> | yes |
| S9 | SPSDK, *User Guide - nxpele* (the source page `docs/apps/nxpele.rst` and its rendered command reference) | tag `v3.13.0` | <https://spsdk.readthedocs.io/en/v3.13.0/apps/nxpele.html> | yes |
| S10 | SPSDK, *i.MX93 Field Return Lifecycle Update* (Jupyter example `examples/signed_message/imx93_field_return_LC/`, with its input comments) | tag `v3.13.0` | <https://github.com/nxp-mcuxpresso/spsdk/tree/v3.13.0/examples/signed_message/imx93_field_return_LC> | yes |
| S11 | SPSDK, *User Guide - nxpdebugmbox* (`docs/apps/nxpdebugmbox.rst`). It holds only the generated command reference, which the lane used S2 for. | tag `v3.13.0` | <https://spsdk.readthedocs.io/en/v3.13.0/apps/nxpdebugmbox.html> | yes |

The project's threat model (issue #48) asks how debug access is handled on a production
board. §5.3 and §6 answer that question. The threat model is not on main yet, so this
file cites it by issue number and does not link to it.

## 3. Debug paths on the i.MX 95

| Path | What it reaches | Where it is controlled (per the sources) |
|---|---|---|
| JTAG/SWD debug port | Every core's debug access port and the bus behind it: the SPSDK example (S2) reads and writes SoC memory over it once debug is open | EdgeLock Enclave (ELE) life cycle and debug authentication (§4, §5); debug-disable fuses (S2 names them, gives no detail) |
| Debug UARTs (consoles) | Whatever the software on each core exposes on its console | Software build options (§6) |
| USB serial downloader / unsigned images | Loading code before any OEM signature check | ELE life cycle: in OEM Open the ROM does not enforce signatures (S1, §4) |

## 4. Life cycle and what it does to debug

- An i.MX 9x part leaves NXP in the **OEM Open** life cycle. In that state the ELE checks
  signatures and logs failures as events, but does not refuse an image; U-Boot's
  `ahab_status` shows the life cycle and the events (S1 §1.7).
- The guide's sequence to close a part is: fuse the SRK hash, boot a signed image with no
  ELE events, then move the life cycle to **OEM Closed** (U-Boot's `ahab_close`). The guide
  warns that the step is irreversible and that a part closed on a bad SRK hash or a bad
  image will not boot again (S1 §1.6, §1.8). This survey records the sequence only; the
  lane ran nothing.
- In OEM Closed, the SPSDK example says, debug is **only** available through debug
  authentication, and debug can be turned off altogether by fuse programming; it sends
  the reader to the i.MX 95 Security Reference Manual for that (S2 §2). The lane could
  not read that manual (it is not public), so which fuses do this, and whether the
  disable is per core or global, is unconfirmed.
- In OEM Open the debug port is, by implication of S2, open without authentication. The
  lane found no public source that states this outright for the i.MX 95: unconfirmed.
- **Past OEM Closed.** SPSDK's `nxpele forward-lifecycle-update` command moves an ELE
  part forward to **OEM Closed** or **OEM Locked** (S9). Its page describes ELE parts in
  general and gives the i.MX 93 and the i.MX RT1180 as examples. It does not say what
  OEM Locked does to debug. The lane found no public i.MX 95 source on that:
  unconfirmed.
- **Field return.** For the i.MX 93, SPSDK shows a part going from OEM Closed to an
  **OEM field-return** life cycle (`FR_OEM`) (S10):
  - The request is a signed message signed with an OEM SRK private key, and it can name
    one part's UUID.
  - SPSDK's `nxpele` sends it to the ELE.
  - S10 says this is a one-time step: once in field return, the part cannot go back to
    OEM Closed.

  S10 does not say what field return opens. Whether the i.MX 95 has the same request,
  and what debug or key access field return gives, is unconfirmed (§7).

| Life cycle (as the sources name it) | Signatures enforced | Debug port | Source | Confirmed for the i.MX 95 |
|---|---|---|---|---|
| OEM Open | no (events only) | open (implied) | S1, S2 | events: yes (S1 names the i.MX 95); debug: no |
| OEM Closed | yes | authenticated debug only, or off by fuse | S1, S2 | yes (S2 was tested on an i.MX 95 EVK) |
| OEM Locked | not stated | not stated | S9 | no |
| OEM field return (`FR_OEM`) | not stated | not stated | S10 (i.MX 93) | no |

## 5. Authenticated debug: NXP's public software and the keys it needs

### 5.1 The flow on a closed part

The SPSDK example (S2), tested by NXP on an i.MX 95 EVK over the 4-pin JTAG connector,
shows the flow for a part in OEM Closed:

1. A **debug credential key** (DCK) pair is made. S2 shows an ECC P-384 pair, and an
   ML-DSA-65 pair for parts that need a post-quantum second signature.
2. The part's **UUID** is read over the debug port (`nxpdebugmbox tool get-uuid`).
3. A **debug credential** (DC) is built from a configuration and exported
   (`nxpdebugmbox dat dc export`). The comments in SPSDK's i.MX 95 DC example (S5) say
   that the DC carries the developer's DCK public key, is signed with an OEM **SRK
   private key** (with a second, post-quantum SRK signature when double signing is on),
   names the part's UUID, and holds a `cc_socu` field that selects the debug domains and
   the trace and debug enables. S5 gives one value that opens every OEM debug domain with
   trace and debug, and sends the reader to the ELE user guide for the bit meanings.
4. The probe runs the **debug authentication** with the ELE (`nxpdebugmbox dat auth`,
   using the DAT configuration S6). Once it succeeds, S2 reads and writes SoC memory over
   the port; without it, S2 notes that the connection test fails on an OEM Closed part
   (S2 §2.8 and §2.9).

What follows from this for a lockdown policy:

- Whoever holds an SRK private key can issue a DC (S5), so SRK custody, which the code
  signing work (issue #9, the `oem-key-provisioning` row) decides, is also debug custody.
  The DCK is a separate pair that the person debugging holds (S2 §2.3, S5).
- **A DC with an all-zero UUID opens debug on every part of the chip family** (S5, the
  `uuid` comment). Only a DC that names one part's UUID is scoped to that part. Any DC
  this project issues therefore needs a UUID rule.
- `cc_socu` lets a DC open fewer than all debug domains (S5). Which bit is which domain
  (A55 cluster, M33, M7, secure or non-secure debug, trace) is in the ELE user guide,
  which the lane could not read: unconfirmed.
- How long an authenticated session lasts (until reset, until power-off) is not stated in
  the sources the lane read: unconfirmed.

### 5.2 Tools and keys

The public NXP software for authenticated debug on the i.MX 95 is SPSDK. The lane found
no other public NXP tool for it. A probe vendor's own tooling (S2 uses a Lauterbach probe
through an SPSDK plugin) was not surveyed.

| Tool (SPSDK v3.13.0) | Role in authenticated debug | Source |
|---|---|---|
| `nxpcrypto key generate` | makes the DCK pair (ECC P-384 in the example; ML-DSA-65 as well for double signing) | S2 §2.3 |
| `nxpdebugmbox tool get-uuid` | reads the part's UUID over the debug port | S2 §2.4 |
| `nxpdebugmbox dat dc get-template` / `dat dc export` | writes and signs the debug credential | S2 §2.5–2.6, S5 |
| `nxpdebugmbox dat get-template` / `dat auth` | runs the authentication with the ELE through the probe | S2 §2.7–2.8, S6 |
| `nxpdebugmbox mem-tool` | reads and writes memory once debug is open | S2 §2.9 |
| `nxpele` | sends ELE messages (life-cycle forward, signed messages such as a field-return request). It reaches the ELE through U-Boot's `ele_message` console command or fastboot; on other parts it uses a flashloader | S9, S10 |
| `spsdk-lauterbach`, `spsdk-pqc` plugins | probe support, and the post-quantum keys for double signing | S2 §1 |

| Key | Who holds it | What it does | Source |
|---|---|---|---|
| OEM SRK private key (classic) | the SRK custodian | signs every DC; signs life-cycle and field-return signed messages | S5, S10 |
| OEM SRK private key (post-quantum), if double signing is on | the SRK custodian | second signature on the DC | S5 |
| DCK private key (and a post-quantum DCK for double signing) | the person debugging | answers the ELE's challenge during `dat auth`; its public half is inside the DC | S2 §2.3, S5 |
| SRK hash in fuses | the part | the anchor that the ELE checks DC and message signatures against (inference from S1 §1.6 and S5; the DC-check detail is unconfirmed) | S1, S5 |

S2 says a technician who does not use the SRKs can make a separate DCK pair. The DC
itself is still signed by an SRK key (S5). So any authenticated-debug policy depends on
the SRK custody that issue #9 and the `oem-key-provisioning` row decide.

### 5.3 Options for a production board, and what each costs at field return

This answers the threat model's (#48) debug-access question with the options the sources
support. All of them assume OEM Closed: in OEM Open, signatures are not enforced (S1), so
the debug question does not arise.

| Option | What an attacker with the board gets at the debug port | What NXP's public flow gives for a field return | Cost and risk | Sources |
|---|---|---|---|---|
| A. OEM Closed, authenticated debug only, single-UUID DCs | nothing without a DC signed by our SRK and the matching DCK | the OEM issues a DC for that one returned part's UUID, opens only the domains needed (`cc_socu`), and debugs it. No life-cycle change. | SRK signing is needed for every DC. A DCK leak opens only the parts named in DCs made for that DCK. A zero-UUID DC must never be issued. | S2, S5 |
| B. OEM Closed plus the debug-disable fuses | nothing at the port | the port cannot help. Diagnosis is only through what the signed software reports (consoles, logs, SM reset records, S8). Whether field return (`FR_OEM`) re-opens debug on a fused part is unconfirmed. | Irreversible. Returned parts may be undiagnosable, so in practice a returned board is replaced, not analysed. | S2 §2, S10 |
| C. A, then move a returned part to field return (`FR_OEM`) | same as A while in the field | a signed, UUID-bound request moves that part to field return, one way (shown for the i.MX 93) | The part never returns to OEM Closed, so it is scrapped or kept as a lab part after analysis. What field return unlocks (debug, keys) is unconfirmed for the i.MX 95. | S10, S9 |
| D. OEM Locked | not stated in public sources | not stated | Unknown until the Security Reference Manual is read | S9 |

Whichever option is chosen, the signed software must not reopen debug itself. The SM debug
monitor and any U-Boot shell are reachable in every life cycle (§6).

## 6. Software-side controls (System Manager, TF-A, OP-TEE, U-Boot, Linux)

The life cycle controls the debug *port*. It does nothing about a console that the signed
software itself offers. A signed image with a debug shell in it is a debug path that an
OEM Closed part will boot without complaint.

### 6.1 System Manager (Cortex-M33) debug monitor

NXP's System Manager (SM) runs on the M33. It owns the TRDC set-up, power, clocks and
resets of the whole SoC. The public imx-sm repository has a board port for the 15x15
FRDM-IMX95 board (`boards/mcimx95frdm`, `configs/mx95frdm.cfg`), not for the FRDM-IMX95-PRO
(machine `imx95-19x19-lpddr5-frdm-pro`); the PRO's configuration `mx95frdm-pro` has no
confirmed source ([upstream-survey.md](upstream-survey.md)), so which monitor setting the
PRO's SM build uses is **unconfirmed**. The monitor document (S7) is generic to the SM and
says:

- The SM build option `M` selects a **debug monitor** on the SM debug UART. `M=1` drops
  into the monitor at boot and `M=2` enters it when a character arrives on the UART.
  **The default is `M=1`.** `M=0` builds no monitor.
- The document says `M=0` is the only valid option for production and the monitor must
  never ship in a product. The reason it gives is timing.
- Its commands include reading and writing any address (`md`, `mm`), reading and
  **writing fuses** (`fuse.w`), starting, holding and re-vectoring CPUs (`cpu.w`),
  changing the boot stage, and dumping the TRDC set-up and ELE information (S7, the
  command tables).

So a default SM build gives anyone at the SM debug UART a shell on the core that sets up
the SoC's isolation (the TRDC), with memory and fuse write. That is a secure-world debug path, and it is
open in every life cycle. Whether the TRDC set-up limits what the M33's `mm` can reach is
not stated in S7 and is not confirmed. The SM debug UART is one of the per-core UARTs on
the board (SPEC.md cites UM12527 §2.19, whose port mapping is not fixed).

The SM's debug document (S8) also shows that the SM records JTAG-caused resets
(`jtag`, `jtag_sw` reset reasons) and reports them to agents over SCMI. A product could
use that as a sign that someone attached a debugger. S8 does not say how JTAG causes
these resets, so this is unconfirmed.

### 6.2 U-Boot

U-Boot's i.MX 9x guide (S1) uses the U-Boot shell to read life-cycle state and events
(`ahab_status`), program fuses (`fuse prog`) and close the part (`ahab_close`). The same
shell has the generic memory commands. If the production U-Boot keeps an interactive
shell on its console, those commands stay reachable on an OEM Closed part. The guide
does not say how to turn the shell off for production. U-Boot's own options for this
(for example a keyed or disabled autoboot interrupt, or leaving the `fuse` and `ahab`
commands out of the build) are listed in §8 as options but were not surveyed here in
detail.

SPSDK's `nxpele` can also talk to the ELE through U-Boot's `ele_message` console command,
or through fastboot, when U-Boot is built with AHAB support (S9). So a production U-Boot
with an interactive console, or with fastboot, is also a path to the ELE's message
interface. Life-cycle and field-return messages are signed (S9, S10). Which other ELE
messages work without a signature on a closed part is unconfirmed.

### 6.3 TF-A, OP-TEE and Linux

The lane did not survey TF-A, OP-TEE or the Linux console for i.MX 95 debug controls
within this slice. They are listed in §7 as not confirmed. The owner's question in §8 on
consoles covers them as a class.

## 7. What could not be confirmed

1. **AN14579** (S4), NXP's application note on secure debug for ELE-based parts, could
   not be read: the documentation portal needs JavaScript and the PDF URL answered 404.
   Everything below that "S4 would say" stays open until someone reads it.
2. The **i.MX 95 Security Reference Manual** and the **ELE API reference / user guide**
   are not public (S2 and S5 refer to them). Not confirmed without them:
   - which fuses disable debug, and whether per domain or for the whole SoC;
   - the bit layout of `cc_socu` (which debug domains and enables exist);
   - what OEM Locked (S9) and OEM field return (S10, shown for the i.MX 93) do to
     debug and keys on the i.MX 95, and whether the i.MX 95 accepts the field-return
     request at all. The lane tried to confirm the last point by asking SPSDK for an
     i.MX 95 template, but could not install SPSDK in this container;
   - whether field return reopens debug on a part whose debug-disable fuses are burnt;
   - whether OEM Open allows debug without authentication (S2 implies it, but does not say so).
3. How long an authenticated debug session lasts (S2 does not say).
4. Whether NXP's released SM binaries (BSP or Yocto builds) are built with `M=0`. S7 gives
   only the source default (`M=1`). The lane did not read the Yocto recipes.
5. Whether the TRDC set-up limits the SM monitor's `mm` command; how JTAG causes the
   `jtag` reset reasons that the SM records (S8).
6. Debug and console controls in **TF-A**, **OP-TEE** and **Linux** for the i.MX 95: not
   surveyed in this slice.
7. The FRDM-IMX95-PRO's debug connector pinout and which UART carries the SM console:
   these are in UM12527, which is in the private reference set, not a public source.
   SPEC.md says the port mapping is not fixed.
8. Issue #61's own text: the lane could not read it from the forge. This file works
   from the scope the coordinator relayed and from the `secure-world` row in SPEC.md.
9. Public NXP tools for authenticated debug other than SPSDK, and probe vendors' own
   flows: not found in public sources the lane searched.

## 8. Questions for the owner

1. **Which life cycle do shipped boards end in?**
   - (a) OEM Open: the debug port is open and signatures are not enforced (S1 §1.7).
   - (b) OEM Closed: signatures are enforced; debug only with a valid DC (S1 §1.8, S2 §2).
   - (c) OEM Closed plus the debug-disable fuses: no debug at all, even for the OEM (S2 §2).
   - (d) OEM Locked (S9): its effect on debug is not confirmed for the i.MX 95 (§7 item 2).

   The field-return cost of each is set out in §5.3. Recommendation: (b) for the product,
   with (c) left open until AN14579 and the Security Reference Manual say what the fuses
   cover and whether field return is still possible.
   Development boards stay in (a). This is irreversible, so it waits for #9 (signing
   tool) and the SRK custody decision. The lane recommends no step and runs none.

2. **Who may issue debug credentials, and with which key?** The DC is signed with an SRK
   private key (S5).
   - (a) The SRK holder signs each DC by hand, offline.
   - (b) A signing service with the SRK, run to a written policy.
   - (c) No DC is ever issued (that is option 1(c) in practice, without fusing).

   Recommendation: (a) until the `oem-key-provisioning` row settles SRK custody. Sources
   support no more than that.

3. **What scope may a DC have?**
   - (a) A single part: the UUID is set, and `cc_socu` holds only the domains needed.
   - (b) A single part with all domains.
   - (c) A zero UUID, which S5 says opens debug on **every part of the chip family**. In
     practice (by inference, not confirmed) that means every part fused with the SRK hash
     that signed it, so the whole fleet.

   Recommendation: (a), and a written rule that the project never issues a zero-UUID DC.
   The `cc_socu` values cannot be chosen until the ELE user guide is read (§7 item 2).

4. **Does the production System Manager build carry the debug monitor?**
   - (a) `M=0`: no monitor (S7 says this is the only valid production option).
   - (b) `M=2`: monitor on UART input.
   - (c) `M=1`: the source default, monitor at boot.

   Recommendation: (a) for every image that will run on a closed part. The build system
   (issue #14) should set it explicitly instead of trusting the default. Development
   images may keep (b).

5. **What stays on the consoles of the signed images (U-Boot, TF-A, OP-TEE, Linux)?**
   - (a) Output only: no interactive U-Boot shell, and no `fuse` or `ahab_close` commands
     in the production U-Boot.
   - (b) A U-Boot shell behind a keyed autoboot interrupt.
   - (c) As the BSP ships.

   Recommendation: (a) for production. The lane did not survey the exact U-Boot, TF-A
   and OP-TEE options (§7 item 6), so the next survey should list them.

6. **Should the product treat a debugger attach as a security event?** The SM records
   JTAG-caused resets and reports them over SCMI (S8).
   - (a) Yes: report the SM reset reason to the `hsm-self-defence` row as a tamper input.
   - (b) No.

   No recommendation: S8 does not say what produces those resets (§7 item 5).

7. **How is a returned board handled?** (§5.3)
   - (a) Debug it in OEM Closed with a single-UUID DC (option A), with no life-cycle
     change.
   - (b) Move it to OEM field return with a signed, UUID-bound request (option C). This
     is one-way, so the board does not go back into service.
   - (c) Do not analyse it: replace the board (the only choice under option B).

   Recommendation: (a), keeping (b) for failures that (a) cannot diagnose once the
   i.MX 95 field-return behaviour is confirmed (§7 item 2). A returned board's DC is
   issued under question 2's custody rule.

8. **Should someone with portal access fetch AN14579 and the i.MX 95 Security Reference
   Manual into the private reference set?** Questions 1, 3 and 6 depend on them.
   Recommendation: yes, before any decision on question 1.
