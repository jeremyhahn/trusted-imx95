# System Manager SCMI agent permissions: survey (#107)

Status: draft survey for the owner. Documentation only.

## 1. Scope and sources

This survey covers how NXP's System Manager (SM), which runs on the
i.MX 95's Cortex-M33, grants SCMI agents access to protocols, clocks,
power domains, resets, sensors and other resources. It proposes a
least-privilege set for this board (NXP FRDM-IMX95-PRO) and describes
how that set could be checked at build time as input to #55. It does
not cover TRDC memory and peripheral access-control programming in
depth; that is #55's scope. Everything here comes from public
sources. Vendor text is summarised, not quoted.

Sources surveyed (all reached from the lane on 2026-11-12):

| Id | Title | Version or tag | URL |
|----|-------|----------------|-----|
| S1 | NXP `imx-sm` (System Manager source), board configuration `configs/mx95frdm.cfg` | tag `rel_imx_sm_2026q3` | <https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/configs/mx95frdm.cfg> |
| S2 | NXP `imx-sm`, configuration guide `sm/doc/config.md` | tag `rel_imx_sm_2026q3` | <https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/config.md> |
| S3 | NXP `imx-sm`, architecture notes `sm/doc/arch.md` | tag `rel_imx_sm_2026q3` | <https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/arch.md> |
| S4 | NXP `imx-sm`, SCMI protocol notes `sm/rpc/scmi/proto.md` | tag `rel_imx_sm_2026q3` | <https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/rpc/scmi/proto.md> |
| S5 | NXP `imx-sm`, configuration tool `configs/configtool.pl` | tag `rel_imx_sm_2026q3` | <https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/configs/configtool.pl> |
| S6 | Linux kernel, `arch/arm64/boot/dts/freescale/imx95.dtsi` | mainline 7.4-rc2, commit `9d66f26fefac` (2026-11-12) | <https://github.com/torvalds/linux/blob/9d66f26fefacebfeed15de31c1123451a17ff119/arch/arm64/boot/dts/freescale/imx95.dtsi> |
| S7 | NXP `imx-smct` (SM configuration tool) | tag `SMCT_26.09.00` (existence only) | <https://github.com/nxp-imx/imx-smct> |
| S8 | Tang, Sethumadhavan, Stolfo, "CLKSCREW: Exposing the Perils of Security-Oblivious Energy Management", USENIX Security 2017 | 2017 | <https://www.usenix.org/conference/usenixsecurity17/technical-sessions/presentation/tang> |
| S9 | Arm, System Control and Management Interface (SCMI), DEN0056 | "latest" page; version not recorded | <https://developer.arm.com/documentation/den0056/latest> |

The tag `rel_imx_sm_2026q3` was the newest tag on
<https://github.com/nxp-imx/imx-sm> when surveyed. S1, `mx95frdm.cfg`
(board port `mcimx95frdm`), is **not this device's configuration**: it
targets the 15x15 FRDM-IMX95. This device, the 19x19 NXP FRDM-IMX95-PRO,
uses `configs/other/mx95frdm-pro.cfg` at the same tag, which reuses the
19x19 EVK board port (`mcimx95evk`) and differs in its M7 UART and pins,
its sensors and its fault entries (`public-source-survey.md` items 11-16;
`sm-build-survey.md` section on the PRO configuration). This survey read
only S1. Every S1 value below is therefore **reference only**: it shows how
NXP grants SCMI rights on a sibling board, not what the PRO file grants.
The recommendations in sections 3 and 7 apply to the PRO file; where the
PRO value is not shown in the sibling surveys it is **unconfirmed** and
must be read from `mx95frdm-pro.cfg` before the proposal is adopted.

## 2. How the board configuration defines SCMI agents

### 2.1 From the `.cfg` file to the compiled tables

The SM's configuration is static: it is compiled into the SM image
from C header files in `configs/<CONFIG>/` (S2, "Configuration").
NXP recommends generating those headers with `configtool.pl` from a
single human-written `configs/<CONFIG>.cfg` file (S2; S5). For the
FRDM board the generated directory `configs/mx95frdm/` holds, among
others, `config_scmi.h` (agents and their permission arrays),
`config_lmm.h` (logical machines), `config_mb_mu.h` (mailboxes) and `config_trdc.h` (TRDC
access-control data) (S1, S2).

The chain is: a Messaging Unit (MU) doorbell is bound to a
shared-memory transport (SMT) channel, which is bound to an SCMI
channel, which belongs to an SCMI agent, which belongs to an SCMI
instance tied to one logical machine (LM) (S2, "SM Configuration
Structure", "SCMI", "SMT"). LM0 is always the SM itself (S2).

### 2.2 Per-agent permission arrays

Each SCMI agent record carries its RDC domain ID, a secure flag, and
one permission array per SCMI protocol object: base (other agents),
power domains, system, performance domains, clocks, sensors, reset
domains, voltage domains, LMs (LMM protocol), BBM GPRs, RTCs and
buttons, CPUs, peripheral low-power interfaces, pins and daisy
registers, board controls, FuSa faults and the FuSa protocol itself
(S2, "SCMI"). Anything not listed defaults to no access (S2).

Permission values are ordered and each implies the ones below it
(S2, "SCMI"):

| Level | Meaning (summarised from S2) |
|-------|------------------------------|
| none | no access (default) |
| get | read state |
| notify | subscribe to notifications |
| set | request a setting; the SM aggregates requests across agents and LMs (for example a clock stays on while any agent wants it) |
| priv | one setting per LM; aggregated across LMs but not across agents within an LM |
| exclusive | one setting for the whole system, no aggregation |
| all | full access; at this tag, equal to exclusive |

S2 states plainly that neither the config tool nor the SM stops a
configuration from giving the same object to several agents at a
level where no aggregation happens; isolation then depends on the
clients. This is the main reason a build-time check is worth having
(section 5). The level each SCMI message requires is listed in the
"Access Control" column of S4.

### 2.3 The `.cfg` syntax as used in `mx95frdm.cfg`

In S1, each LM block (`LMn name=..., rpc=..., did=..., safe=...`) is
followed by one or more `SCMI_AGENTn` blocks, each with a `MAILBOX`
and `CHANNEL` lines, then:

- an **API** list: a protocol object (clock, perf domain, sensor,
  RTC, button, LM, `SYS`, `FUSA`, board control) followed by a level
  macro (`NOTIFY`, `GET`, `SET`, `PRIV`, `ALL`, defined at the top of
  the file);
- a **Resources** list: a hardware block (peripheral) followed by
  `OWNER`, `ACCESS` or `READONLY`. The SoC include file
  `devices/MIMX95/configtool/device.cfg` defines each peripheral name
  as the bundle of its power domain, clocks, daisy inputs and TRDC
  block (S2, "Configuration Tool"). `api=all` on that line expands to
  full rights on every SCMI object in the bundle (power domain,
  clocks, CPU, pins, daisy), and `perm=` sets the TRDC access for
  the LM's domain ID (S2, "Configtool Resources"). In S1, `OWNER` is
  `perm=rw, api=all` for the M7 and AP-NS sections and
  `perm=sec_rw, api=all` for AP-S;
- **Pins**, **Memory** (TRDC memory regions, `EXEC`/`DATA`) and
  **Faults** (fault ownership and reaction).

A trailing `test` key marks a resource on which the SM's SCMI unit
tests run (S2, "Configtool Resources").

Two rules in S2 matter for least privilege:

- API rights are per agent. A resource that both TF-A and Linux
  call must be listed under both agents.
- TRDC rights are per domain ID, and every agent of one LM shares
  that ID. Within the AP LM, TRDC can only tell TF-A from Linux by
  the secure or non-secure attribute of the access. Anything
  readable by the non-secure side is also readable by the secure
  side (S2, notes under "Configtool Resources").

### 2.4 The agents in NXP's 15x15 FRDM file (S1, tag `rel_imx_sm_2026q3`; reference only)

This table is the 15x15 FRDM's (S1), kept as a reference. For this
device's `mx95frdm-pro.cfg`, the sibling surveys show the same LM and
agent layout: LM1 "M7" with agent "M7" on MU 9 over CRC32-checked
channels, LM2 "AP" with "AP-S" on MU 1 and "AP-NS" on MU 3, and the M7
holding `LMM_2` with full rights (`public-source-survey.md` items 14-15).
The PRO file gives the M7 LPUART7 and pins GPIO_IO36/37 rather than S1's
UART, has the PF5301 temperature sensor, and lacks the NoC fault entries
(`public-source-survey.md` item 16). Every other PRO grant in this table
is **unconfirmed**.

| LM | Agent | Domain ID | Secure | Mailbox | Notable API grants |
|----|-------|-----------|--------|---------|--------------------|
| LM0 `SM` (F-EENV) | none (`rpc=none`) | 2 | yes | none | owns the clock tree, PLLs, DDR controller, GPC, SRC, CCM, IOMUXC, all TRDC instances, WDOG1/2, JTAG/DAP block, ELE MU0 |
| LM1 `M7` (S-EENV) | `SCMI_AGENT0` "M7" | 4 | yes | MU9, CRC32-checked SMT, priority channel | `SYS` all, `LMM_2` all (the AP LM), `FUSA` all, ANA temperature sensor all, RTC priv, board RTC and test controls all, button notify |
| LM2 `AP` (default LM) | `SCMI_AGENT1` "AP-S" | 3 | yes | MU1 | `SYS` all, `PERF_A55` all, low-power interface (PERLPI) all for CAN2-5, GPIO2-5, LPUART1/4-8, WDOG3/4; owns A55 cores, `ARM_PLL`, ELE MU1/MU2 |
| LM2 `AP` | `SCMI_AGENT2` "AP-NS" | 3 | no | MU3 | `SYS` notify only, `LMM_1` notify only (the M7 LM), `PERF_A55` all, RTC all, A55 temperature sensor all, ANA sensor set, audio/HSIO/LDB PLLs all, external and output clocks all, wake-up button notifications; owns most application peripherals (display, camera, VPU, GPU, NPU, NETC, PCIe, USB, uSDHC, LPSPI, LPI2C2-8, EDMA1/3 and most of EDMA2, SAI, FlexSPI, V2X APP/HSM/SHE0, ELE MU3/MU4, DAP pins) |

What the 15x15 FRDM file already does well, as read from S1 (reference
only; whether the PRO file does the same is unconfirmed except where the
previous paragraph says so):

- The non-secure agent cannot reset or power off the system or the
  M7 through SCMI: `SYS` and `LMM_1` are notify-only for AP-NS. A
  Linux reboot has to go through the secure agent (AP-S), normally
  via PSCI in TF-A.
- The M7 holds `LMM_2` all, so it can boot, stop or reset the AP LM.
  This matches the `hsm-self-defence` row in docs/SPEC.md, where the
  M7 acts on the rest of the board through the SM.
- The M7 channel uses CRC32 on its shared-memory transport; the AP
  channels do not.

### 2.5 Level each sensitive message needs (S4)

From the access-control column of S4 at `rel_imx_sm_2026q3`:

| Protocol | Message | Level needed |
|----------|---------|--------------|
| Base | reset another agent's configuration | priv |
| Power | set power-domain state | set |
| System | set system power state (reset, off, suspend) | set, priv or exclusive (depends on the kind of request; not broken down here) |
| Perf | set limits | set |
| Perf | set level | priv |
| Clock | set rate, set parent | exclusive |
| Sensor | configure trip point | exclusive |
| Sensor | enable or disable sensor | set |
| Voltage | set level | exclusive |
| Pin control | configure pin settings | exclusive |
| LMM | boot, reset, shut down an LM; set its reset vector | priv or exclusive |
| BBM | set RTC time | exclusive |

### 2.6 What upstream Linux asks for (S6)

Upstream Linux's `imx95.dtsi` (S6) declares one SCMI instance over an
MU with these protocols: power (0x11), system power (0x12), perf
(0x13, used by every A55 core for cpufreq), clock (0x14), sensor
(0x15, two thermal zones on sensors 0 and 1), pin control (0x19),
and NXP's LMM (0x80), BBM (0x81), CPU (0x82) and misc/control (0x84)
protocols. It does not declare the reset (0x16) or voltage (0x17)
protocols. Which `mx95frdm-pro.cfg` sensor IDs are sensors 0 and 1, and
whether the DT's `mu2` is the SM's `mu=3`, are not confirmed
(section 6).

## 3. Least-privilege set for this board's agents

The three agents named in #107 map onto the PRO file's agents (the
same names as S1, section 2.4) as follows:
Cortex-A55 non-secure = `AP-NS` (Linux); Cortex-A55 secure world =
`AP-S` (TF-A, and any secure OS); Cortex-M7 = `M7`. The proposal
keeps NXP's LM and agent layout and removes grants. It applies to
`mx95frdm-pro.cfg`. The "Grant in S1" columns give the 15x15 FRDM's
grant as a **reference only**; the matching PRO grant is
**unconfirmed** unless section 2.4 states it, and it must be read from
the PRO file before the proposal is applied. Where the PRO file names a
different resource (its M7 UART is LPUART7, and it has the PF5301
temperature sensor), the proposal applies to the PRO resource, not to
S1's.

### 3.1 All agents

- Production builds carry no `test` keys and no test-only APIs
  (`BRD_SM_CTRL_TEST`, `BRD_SM_CTRL_TEST_A`, the `CLK_*TEST*` clocks
  in LM0). Change from S1. The `test` keys select resources for the
  SM's SCMI unit tests (S2), so a production image does not need
  them. Whether they widen access in a release build is not
  confirmed (section 6).
- No `DEBUG did=` line, which would give the debug domain access to
  everything (S2, "Configtool Commands"). S1 has none. Keep.
- No base-protocol (`BASE_n`) grants on other agents. S1 has none
  (default none, S2). Keep.
- No object at exclusive or all for more than one agent, unless the
  owner accepts a hand-over by name (S2 says the tool does not stop
  this; section 5).

### 3.2 Cortex-M7 (`M7`, LM1)

The M7 is the board's tamper responder (docs/SPEC.md,
`hsm-self-defence`), so it keeps more than Linux.

| Grant in S1 | Proposal | Reason |
|-------------|----------|--------|
| `SYS` all | keep | system shutdown or reset as a tamper reaction |
| `LMM_2` all | keep | stop, reset or boot the AP LM as a tamper reaction |
| `FUSA` all, its faults | keep if FuSa is used, else drop (question 5) | S2 ties the FuSa reaction to an S-EENV, which the M7 LM is |
| `RTC` priv, `BRD_SM_RTC_PCA2131` all | keep; see question 3 on who sets time | |
| `SENSOR_TEMP_ANA` all, PMIC temperature sensors set | keep | thermal tamper detection |
| `BUTTON`, `BRD_SM_CTRL_BUTTON` notify | keep | |
| `BRD_SM_CTRL_TEST`, `BRD_SM_CTRL_TEST_A` all | drop | test only |
| `LPUART3 ... test`, `PD_M7 test` | drop any `test` key on the PRO file's M7 UART (LPUART7) and `PD_M7`; whether the PRO file carries `test` keys there is unconfirmed | test only |
| `BRD_SM_CTRL_PCA2131` all | keep only if the M7 drives the board RTC | not confirmed what it controls |

### 3.3 Cortex-A55 secure world (`AP-S`, LM2)

| Grant in S1 | Proposal | Reason |
|-------------|----------|--------|
| `SYS` all | keep | PSCI system reset and off go through TF-A |
| `PERLPI_*` all | keep | wake-up configuration for suspend (purpose of each PERLPI not confirmed) |
| `PERF_A55` all | lower to priv, or drop if TF-A does not set A55 levels (not confirmed) | level set needs priv (S4); Linux also holds it, and both share one LM, so priv calls from the two overwrite each other (S2) |
| A55 cores, `ARM_PLL`, `MU1_A`, `MU_ELE1/2` owned | keep | |

### 3.4 Cortex-A55 non-secure (`AP-NS`, Linux, LM2)

| Grant in S1 | Proposal | Reason |
|-------------|----------|--------|
| `SYS` notify | keep | Linux cannot reset the system except through PSCI |
| `LMM_1` notify | keep (or none) | Linux must never boot, stop or re-vector the M7 |
| `PERF_A55` all | priv | cpufreq needs level set (priv) and limits (set), not exclusive (S4, S6) |
| `RTC` all | get and notify, if a secure agent or the M7 owns time (question 3) | RTC set needs exclusive (S4); in S1 Linux is the only agent that can set the SoC RTC |
| `SENSOR_TEMP_ANA` set | notify, or get (question 4) | set lets Linux enable or disable the sensor the M7 watches (S4); whether the SM aggregates that request is not confirmed |
| `BRD_SM_SENSOR_TEMP_PF09` all | get and notify (question 4) on whichever board temperature sensors the PRO file grants AP-NS (it has the PF5301 sensor; its grant names and levels are unconfirmed) | all lets Linux move the sensor's trip points (S4) |
| `SENSOR_TEMP_A55` all | keep | Linux's own thermal zone |
| PLLs (`AUDIO_PLL1/2`, `HSIO_PLL`, `LDB_PLL`, `VIDEO_PLL1`) and `CLOCK_*` all | keep only those used by peripherals this product enables (question 2) | rate and parent set need exclusive (S4) |
| `BRD_SM_CTRL_TEST_A`, `BUTTON ... test`, `RTC ... test` | drop the test items | test only |
| Owned peripherals | keep only those this product enables or a boot stage needs; remove the rest from AP-NS (question 2) | each owned peripheral carries api=all on its power domain, clocks, pins and daisy (S2) |
| `PIN_DAP_*` owned | move to LM0, or leave unowned, if JTAG is not used in the field (question 6) | Linux can remux the debug pins |
| `V2X_*`, `MU_ELE3/4` owned | decided with `secure-key-handling` (question 7) | Linux's path to the EdgeLock enclave and V2X HSM |
| `GPR4`-`GPR7` owned | keep pending confirmation | what these GPRs hold is not confirmed |

## 4. What an over-broad grant would let a compromised Linux do

A compromised Linux kernel can send any SCMI message on its own MU
channel; the SM's permission check is the only barrier. The table
lists what each grant, if given to `AP-NS`, would allow. Every row
follows from the message levels in S4 and the semantics in S2; none
was tried on hardware.

| Over-broad grant to AP-NS | Effect |
|---------------------------|--------|
| `SYS` set, priv or all (S1 gives notify) | reset or power off the whole system, M7 included: the tamper responder can be switched off at will |
| `LMM_1` priv or all (S1 gives notify) | shut down or reset the M7 LM, or set its reset vector and boot it; with a writable region that the M7 executes from, that is code execution on the M7 |
| Power, clock, CPU or reset rights on M7 or SM resources (`PD_M7`, `CLK_M7`, `CPU_M7P`, WDOG5's clock) | gate or power off the M7 or its watchdog: the same effect as the row above, without a log entry from the LMM |
| `VOLT_ARM` or clock rate on shared clocks at exclusive | under-volt or over-clock to inject faults into code running on the A55 secure world; this class of attack is shown in S8 |
| Sensor trip points (exclusive) on sensors the M7 watches | move or remove thermal alarms, hiding a heat-based attack |
| Pin control (exclusive) on SM or M7 pins (`PIN_I2C1_*` to the PMIC; the M7's pins, `PIN_GPIO_IO36/37` in the PRO file, `PIN_GPIO_IO14/15` in the 15x15 S1 for reference) | cut the SM from the PMIC, or take the M7's inputs |
| `RTC` all (S1 already grants it) | roll the SoC RTC back or forward, which affects any check that trusts that clock |
| Base-protocol priv on another agent | reset another agent's SCMI configuration |
| `FUSA` or fault rights | clear or raise FuSa faults owned by the M7 |

Two structural limits stay even with a correct SCMI set:

- AP-S and AP-NS share LM2 and its TRDC domain ID 3 (S1), so their
  TRDC separation rests only on the secure attribute (S2).
- S1 gives AP-NS read-write access to DDR `0x88000000`-`0x89FFFFFF`,
  inside the M7's `EXEC` range `0x80000000`-`0x89FFFFFF`. This is
  likely the shared RPMsg area, which is not confirmed. If the M7
  ever executes from that window, Linux can change its code. That is
  a TRDC question and belongs to #55; it is noted here because it
  turns the `LMM_1` row above from theory into practice.

## 4. What an over-broad grant would let a compromised Linux do

## 5. Build-time checking (input to #55)

### 5.1 What exists upstream

- `configtool.pl` (S5) turns the `.cfg` into headers and can write a
  log (`-l`) with a section per stage, including "SCMI agent info"
  and the TRDC data (S2, "Configuration Tool"). On the lane, running
  it on `mx95frdm.cfg` at `rel_imx_sm_2026q3` with Perl 5.40 gave a
  `config_scmi.h` byte-identical to the one NXP commits. The
  generation is reproducible, so a check can regenerate and compare.
- The generated `config_scmi.h` lists each agent's rights as one
  designated initialiser per object, for example a `sysPerms` line
  and one `lmmPerms[n]`, `perfPerms[...]`, `clkPerms[...]` line per
  object, each set to an `SM_SCMI_PERM_*` value. That form is easy to
  parse with a short script, without a C compiler.
- In the generated file, no agent holds voltage, reset or base
  protocol rights; AP-NS holds no CPU rights; AP-NS `sysPerms` is
  notify and `lmmPerms[1]` is notify. Through its owned peripherals,
  AP-NS also gets all on the CAM, DISP, GPU, NPU and VPU perf
  domains, and the M7 gets all on the M7 perf domain.
- Neither the tool nor the SM rejects conflicting exclusive grants
  (S2). There is no NXP-provided policy check.
- NXP also publishes an alternative configuration tool, SMCT (S7,
  newest tag `SMCT_26.09.00`). This survey did not assess it.

### 5.2 Proposed check

This is a proposal for #55 to adopt or reject, not a design:

1. Keep this board's `.cfg` in this repository and pin the `imx-sm`
   tag it is built with.
2. In the build, run `configtool.pl` on that `.cfg` and fail if the
   output differs from the headers the SM image is built from.
3. Parse `config_scmi.h` into (agent, protocol, object, level) rows
   and compare them with a policy file in this repository that
   lists every allowed grant. Anything not on the list fails the
   build (deny by default).
4. Independent of the policy file, fail on these invariants:
   - AP-NS above notify on `SYS` or on any LM other than its own;
   - any agent other than the owner of the M7 or SM resources
     holding power, clock, CPU, pin or perf rights on them;
   - any voltage-protocol grant to AP-NS;
   - any base-protocol grant;
   - two agents at exclusive or all on the same object, unless the
     policy file names it as a hand-over;
   - any `test` key or `BRD_SM_CTRL_TEST*` grant in a production
     configuration;
   - any `DEBUG did=` line.
5. TRDC is out of scope here: memory regions, domain IDs, the
   secure attribute and the DDR overlap in section 4 are #55's. The
   two checks can share the same configtool run and log.

## 6. What could not be confirmed

- The PRO file's grants. `mx95frdm.cfg` / board `mcimx95frdm` (S1) is
  the 15x15 FRDM, not this device; the device's `mx95frdm-pro.cfg` was
  not read in this survey. Beyond what section 2.4 takes from the
  sibling surveys, every PRO grant, sensor ID, owned peripheral and
  test key is unconfirmed.
- Which SM release the board's shipped image uses. The S1 baseline
  is `rel_imx_sm_2026q3`; the shipped version was not checked.
- Whether a `test` key changes anything in a release build beyond
  selecting unit-test resources.
- Which SCMI sensor IDs Linux's thermal zones use (S6) compared with
  the S1 sensor names, and whether Linux sets trip points on them.
- Whether the Linux DT's `mu2` is the SM's MU index 3.
- What `GPR4`-`GPR7`, `BRD_SM_CTRL_PCA2131` and each `PERLPI_*` grant
  control. The SoC reference manual (IMX95RM) is not public in full
  and is listed as missing in docs/SPEC.md.
- Whether the DDR window shared by AP-NS and the M7 in S1 is the
  RPMsg area and whether the M7 executes from it.
- Whether TF-A uses `PERF_A55`. The i.MX 95 platform in NXP's TF-A
  fork could not be found at the path tried
  (<https://github.com/nxp-imx/imx-atf/tree/lf_v2.12/plat/imx/imx95>,
  HTTP 404); TF-A was not surveyed.
- How the SM handles a set-level sensor enable or disable from
  several agents.
- The version of the Arm SCMI specification (S9). The lane reached
  the "latest" page but did not record its version.
- No claim here was tested on hardware.

## 7. Questions for the owner

Where a question below cites S1, the value is the 15x15 FRDM's and is
reference only; the PRO file's value is unconfirmed unless section 2.4
states it.

1. **Baseline.** Start from NXP's `configs/other/mx95frdm-pro.cfg`, the
   configuration for this device, or write the board's `.cfg` from
   scratch?
   Options: (a) copy `mx95frdm-pro.cfg` at a pinned tag and remove
   grants; (b) write from scratch. `mx95frdm.cfg` (S1) is not an
   option: it is the 15x15 FRDM, with a different board port.
   Recommendation: (a), since S2 advises starting from NXP's board file
   and the PRO file is NXP's file for this board. Before adopting it,
   read its grants and confirm what S1 shows for the 15x15 FRDM, that
   `SYS` and `LMM_1` are notify-only for Linux; that is unconfirmed for
   the PRO file. The PRO file reuses the EVK board port and lacks the
   NoC fault entries the newer FRDM file has (`public-source-survey.md`
   item 16), which the owner must review with
   `fault-recovery-survey.md`.
2. **Which peripherals Linux owns.** S1 gives AP-NS almost every
   application peripheral, each with full rights on its power domain,
   clocks, pins and perf domain.
   Options: (a) keep S1's list; (b) keep only what the product
   enables (list to come from the owner).
   Recommendation: (b), since each unused peripheral is a power,
   clock and pin surface Linux does not need. The list must also keep
   every resource an A55 boot stage uses after the SM has applied this
   configuration: the boot device's controller (uSDHC or FlexSPI, per
   `sm-build-survey.md` question 7), the boot console, and the ELE
   messaging units SPL and U-Boot use for authentication
   (`resource-isolation-survey.md` item 25). Which of these SPL and
   U-Boot reach through the AP-NS grants is **unconfirmed**; until it is,
   none of them is removed.
3. **Who sets the time.** S1 lets only Linux set the SoC RTC; the M7
   holds the board RTC (PCA2131) at all.
   Options: (a) Linux keeps all on the RTC; (b) Linux gets get and
   notify, and the M7 or secure world sets time; (c) Linux keeps the
   SoC RTC, and nothing security-relevant trusts it.
   Recommendation: (b) if the M7 uses time for any security
   decision; otherwise (c). The sources do not decide this.
4. **Linux's access to sensors the M7 watches.**
   Options: (a) keep S1 (ANA set, PF09 all); (b) get and notify
   only.
   Recommendation: (b). Set and exclusive let Linux disable a sensor
   or move its trip points (S4). Confirm first that Linux's thermal
   driver works with get and notify (section 6).
5. **FuSa.** Is the FuSa (F-EENV/S-EENV) machinery used on this
   board?
   Options: (a) yes, the M7 keeps `FUSA` and its faults; (b) no,
   drop the grants.
   Recommendation: none; the sources do not say whether this
   product needs it.
6. **Debug pins.** Should Linux own the `PIN_DAP_*` pins in the
   field?
   Options: (a) keep as in S1; (b) give them to LM0 (SM); (c) leave
   them unowned in production.
   Recommendation: (b) or (c) for production builds, keeping (a) for
   development builds.
7. **Enclave and V2X access from Linux.** S1 gives AP-NS `MU_ELE3/4`
   and the V2X HSM and SHE blocks.
   Options: (a) keep; (b) remove from AP-NS and give to the M7 or the
   secure world.
   Recommendation: decide together with `secure-key-handling`'s open
   question on which side calls the HSM API (docs/SPEC.md). Before (b),
   confirm that no non-secure boot stage uses `MU_ELE3/4`: U-Boot proper
   asks the ELE to authenticate the kernel container
   ([uboot-auth-survey.md](../boot-container/uboot-auth-survey.md)), and
   which MU it uses is **unconfirmed**. A MU a boot stage needs is kept
   whichever side calls the HSM API (resource-isolation-survey.md
   item 25).
8. **`PERF_A55` level.**
   Options: (a) keep all for both AP agents; (b) priv for AP-NS, and
   priv or none for AP-S.
   Recommendation: (b). Level set needs only priv (S4).
9. **Build-time check.**
   Options: (a) the policy file and invariants in section 5.2,
   delivered with #55; (b) a separate check in this row; (c) manual
   review only.
   Recommendation: (a), which shares one configtool run with #55's
   TRDC check and leaves TRDC rules to #55.
