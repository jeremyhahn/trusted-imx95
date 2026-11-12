# System Manager resource map for the Cortex-M7: a public-source survey

Row: `system-manager-config` (issue #13). Documentation only.

## 1. Scope

The `system-manager-config` row of [SPEC.md](../SPEC.md) says NXP's System Manager (SM), running on the Cortex-M33,
gives the Cortex-M7 firmware of trusted-firmware's `imx95` row its clocks, power and resources through SCMI, and
that the `hsm-self-defence` row acts through the SM on power domains and PHYs. This survey answers, from public
sources only:

- which SCMI power domains, clocks, reset domains and performance domains the M7 needs to run;
- which power domains and Ethernet PHYs the `hsm-self-defence` response would switch off, and how a shutdown is
  asked for;
- the identifier each has in NXP's public imx-sm sources at a named tag, and the SCMI protocol and message each
  action uses;
- which board configuration file grants them.

Nothing is configured or built. Out of scope, cited only: the imx-sm source survey (#33), TRDC isolation (#55), the
SM build (#87), fault recovery (#98), SCMI agent permissions (#107) and low-power modes (#114).

## 2. Sources

All imx-sm paths below are at tag `rel_imx_sm_2026q3`, the newest tag on the public repository when surveyed
(2026-11-12).

| Id | Title | Version or tag | URL |
|---|---|---|---|
| S1 | nxp-imx/imx-sm, `configs/mx95frdm.cfg` (SM configuration for the **15x15** i.MX 95 FRDM board; **reference only**, not this device's file) | `rel_imx_sm_2026q3` (commit `eec2328`, 2026-09-03) | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/configs/mx95frdm.cfg |
| S10 | nxp-imx/imx-sm, `configs/other/mx95frdm-pro.cfg` (SM configuration for the 19x19 FRDM-IMX95-PRO, **this device**); not read line by line in this lane, its contents are taken from [public-source-survey.md](public-source-survey.md) items 12-16 | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/configs/other/mx95frdm-pro.cfg |
| S2 | nxp-imx/imx-sm, `devices/MIMX95/configtool/m7mix.cfg` (M7MIX resources) | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/devices/MIMX95/configtool/m7mix.cfg |
| S3 | nxp-imx/imx-sm, `devices/MIMX95/configtool/netcmix.cfg` (NETCMIX resources) | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/devices/MIMX95/configtool/netcmix.cfg |
| S4 | nxp-imx/imx-sm, `sm/doc/imp.md` (Implementation details: the POWER_STATE_SET flow and aggregation) | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/imp.md |
| S5 | nxp-imx/imx-sm, `sm/rpc/scmi/proto.md` (supported SCMI protocols, messages and access controls) | `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/rpc/scmi/proto.md |
| S6 | Arm, System Control and Management Interface (SCMI) Platform Design Document, DEN0056 | 3.2, the version imx-sm's `sm/doc/intro.md` names; not read in this lane | https://developer.arm.com/documentation/den0056/latest/ |
| S7 | zephyrproject-rtos/zephyr, `dts/arm/nxp/nxp_imx95_m7.dtsi` (the M7's SCMI node) | `v4.3.0` | https://github.com/zephyrproject-rtos/zephyr/blob/v4.3.0/dts/arm/nxp/nxp_imx95_m7.dtsi |
| S8 | torvalds/linux, `arch/arm64/boot/dts/freescale/imx95.dtsi`, `imx95-power.h`, `imx95-clock.h` | `v6.18`; fetched, **not read** (see §8) | https://github.com/torvalds/linux/tree/v6.18/arch/arm64/boot/dts/freescale |
| S9 | NXP UM12527, FRDM-IMX95-PRO Board User Manual, §1.2 Table 1, §2.18 | Rev. 1.0; in `jeremyhahn/vendor-nxp`, **not reachable** from this lane | private context repository (see [references](../references/README.md)) |

Missing, as [references/](../references/README.md) records: IMX95RM and the System Manager documentation as NXP
publishes it for the BSP release. The imx-sm repository's own Doxygen sources (S4, S5) stand in for the latter
here; they are not the released manual.

**Which board file this map rests on.** The FRDM-IMX95-PRO is the 19x19 LPDDR5 board. Its SM configuration is
`configs/other/mx95frdm-pro.cfg` (S10), which uses the EVK board port `mcimx95evk`; the `configs/mx95frdm.cfg` at
the top of `configs/` (S1) is the 15x15 FRDM's, a different board ([public-source-survey.md](public-source-survey.md)
items 12-13, [sm-build-survey.md](sm-build-survey.md) §3). This map and its owner options are for S10. What the
repository records of S10 is: LM1 "M7" with SCMI agent "M7" on MU 9 over CRC32-checked channels, LM2 "AP" with
agents "AP-S" (MU 1) and "AP-NS" (MU 3), the M7 holding `LMM_2` with full rights, the M7 fault reactions (lock-up,
M7 reset, WDOG5; SW0 to the FuSa reaction), the M7 console on **LPUART7**, M7 pins **GPIO_IO36** and **GPIO_IO37**,
the PF5301 temperature sensor, and no NoC fault entries (public-source-survey.md items 14-16). Every other grant or
ownership below was read in S1 only: it is **reference material from the 15x15 file** and is **unconfirmed** for
S10 until S10 is read for it (§8 item 1). Where S1 and S10 are known to differ (the M7 UART, LPUART3 in S1 against
LPUART7 in S10; the M7 pins, GPIO_IO14/15 in S1 against GPIO_IO36/37 in S10), S10's value is used.

## 3. The M7's run-time resources

The SM grants a resource's power domain, clocks and performance domain to the agent that owns the resource. The
per-mix device files list them: in `devices/MIMX95/configtool/m7mix.cfg` (S2) the M7 CPU resource `M7P` carries
`PD_M7`, `CLK_M7SYSTICK`, `PERF_M7` and `CPU_M7P`, and the M7MIX memory sits in `PD_WAKEUP`. S1 (15x15, reference)
makes the M7 agent the owner of `M7P`, so those come with it there. That S10 does the same is expected from its
LM1 layout but is **unconfirmed** (§8 item 1).

### 3.1 Power domains

- `PD_M7`: in S1 (reference) switched on by the SM at LM1 start (step 1) and off at stop (step 2), in every
  `msel`, so the M7 firmware does not need to ask for it; S1 lists it on the M7 agent only as a `test` resource.
  S10's start and stop steps and any `test` key are **unconfirmed**.
- `PD_WAKEUP`: holds the M7MIX TCM memory (S2). Who may switch it, and whether it is always on while the M7 runs,
  is **unconfirmed** (needs IMX95RM; see §8).
- Power domains of the M7's own peripherals (on S10, `LPUART7`, with `WDOG5` named in its M7 fault reactions;
  the rest of the list, `CAN_FD1`, `LPIT1`, `LPTMR*`, `LPTPM1`, `MU*`, is S1's and **unconfirmed** for S10): **not surveyed**; their mix files list
  them, and that check belongs to the imx-sm source survey (#33).

### 3.2 Clocks

- `CLK_M7`: the M7 core clock. In S1 it is listed under the SM's own LM0 among clocks "modified via PERF
  protocol", so the M7 does not set it directly; it asks for a performance level on `PERF_M7`.
- `CLK_BUSM7`: the M7 bus clock, same group in S1.
- `CLK_M7SYSTICK`: the M7 SysTick clock, granted with `M7P` (S2).
- Peripheral clocks of the M7's owned peripherals (for example `LPUART7`'s on S10): granted with those resources by their
  mix files; **not surveyed** here (#33).

### 3.3 Reset domains

No reset domain is named for the M7 in S1 or S2. The M7 CPU is started and stopped by the SM through `CPU_M7P`
(LM1 start step 2, stop step 1), and a fault on the M7 (lock-up, reset request, `WDOG5`, `SW1`) resets the M7 LM
(`lm_reset`). Whether the M7 firmware needs any SCMI reset domain (Reset domain protocol) for its own
peripherals is **unconfirmed**: the reset-domain identifiers are in imx-sm's generated headers, which this lane
could not read (§8).

### 3.4 Performance domains

- `PERF_M7`: granted with `M7P` (S2). The M7 sets its own operating level through the SCMI Performance domain
  management protocol on this domain. The levels and their frequencies come from imx-sm's device code and
  IMX95RM; **unconfirmed** here.

## 4. Tamper-response targets

UM12527 §1.2 Table 1 and §2.18 (Ethernet) are in the private repository `jeremyhahn/vendor-nxp`, which this lane
could not read; the board's PHY part numbers, their reset and power pins, and which ENET port each serves are
**unconfirmed** here and are not guessed.

### 4.1 Power domains

The SoC-side Ethernet controller of the i.MX 95 is NETC. In S3 every NETC resource (`NETC0`..`NETC2`,
`NETC_EMDIO0`, `NETC_IERB`, `NETC_TIMER0`, the `NETC_VSI*` and `NETC_LDID*` entries, `BLK_CTRL_NETCMIX`) sits in
**`PD_NETC`**, and the `NETC` resource carries the clocks **`CLK_ENETREF`** and **`CLK_ENETTIMER1`**. S1 also
lists **`CLK_ENET`** among the SM's PERF-managed clocks.

In S1 (15x15, reference) the owner of all of them is the A55 non-secure agent `AP-NS`, not the M7. Who owns them
in S10 is **unconfirmed**; the M7's known S10 resources (LPUART7, GPIO_IO36/37, `LMM_2`) do not include them, and
this map assumes the S1 ownership until S10 is read. On that assumption, an M7 `POWER_STATE_SET` on `PD_NETC` would be refused (the SM checks the caller's right to set
the domain; S4). Granting it to the M7 is a configuration change (owner question 1), and its permission model is
#107's.

The SM aggregates a power domain's state across agents and LMs and keeps the highest requested state (S4). An M7
"off" request on a shared domain does not switch it off while the A55 asks for it on. This is the main finding:
**the M7 cannot switch the NETC domain off on its own through the Power protocol while Linux holds it on**, even
if granted, unless it first stops the A55 LM (§4.3) or the SM is changed.

Other domains the response may want off (display, camera, HSIO for PCIe and USB, NPU, VPU, GPU) are owned in S1
by `AP-NS` in the same way (S10: **unconfirmed**). Their `PD_*` names are in the per-mix files of S3's directory and were not surveyed
one by one here (#33).

### 4.2 Ethernet PHYs

The PHYs are board parts outside the SoC. In S1 (reference) the M7 owns no ENET pin, no `NETC_EMDIO0` (the MDIO
master) and no GPIO that S1 ties to a PHY, and the SM has no SCMI resource named for an Ethernet PHY. In S10 the M7's
known pins are GPIO_IO36 and GPIO_IO37; what they are wired to on the PRO, and whether S10 gives the M7 any ENET pin
or `NETC_EMDIO0`, is **unconfirmed** (needs S10 and UM12527 §2.18). A PHY can be quietened in three ways, none of
which is known to be available to the M7 at this tag without a configuration change:

- power off `PD_NETC` (stops the MAC side; the PHY stays powered);
- drive the PHY's reset or power-enable GPIO, which needs the pin and GPIO ownership (and the pin numbers from
  UM12527 §2.18, unconfirmed);
- write the PHY's power-down bit over MDIO, which needs `NETC_EMDIO0`.

Whether the board routes a PHY's supply through a PMIC rail the SM controls (an SCMI voltage domain or a
`BRD_SM_CTRL_*` control) is **unconfirmed** and needs UM12527 §2.18 and the board schematic.

### 4.3 Shutdown

Two shutdown paths:

- **`LMM_2` (all), held by the M7 in S10** (public-source-survey.md item 15) and in S1: the M7 may shut down,
  reset, boot or power on the A55 LM through NXP's LMM vendor protocol (S5). Shutting the A55 LM down removes its
  votes on `PD_NETC` and the other domains it owns, so the SM can power them off. This is the one path known on this
  device by which the M7 can take the network side down. What each LMM operation does still needs the SM manual
  (public-source-survey.md item 15).
- **`SYS` (all), held by the M7 in S1 (reference); in S10 unconfirmed:** the M7 may set the system power state
  through the SCMI System power management protocol (S5, S6), for example a full system shutdown or reset.

Key zeroisation through the EdgeLock enclave (`MU_ELE5`, owned by the M7 in S1; in S10 unconfirmed) is the `hsm-self-defence` row's and is
not an SCMI action; it is out of scope here.

## 5. SCMI protocol and message per action

Protocol and message identifiers as listed by imx-sm's protocol table (S5). Access-control letters are S5's: SET,
PRIV, EXCLUSIVE, NOTIFY are the API rights an agent needs in its configuration. The last column is S1's (15x15,
reference). For this device (S10), only the LMM rows are confirmed (`LMM_2` with full rights); every other row is
**unconfirmed** for S10.

| Action | Protocol (id) | Message (id) | Right needed (S5) | M7 has it in S1 (reference)? |
|---|---|---|---|---|
| Set an M7 performance level | Performance domain management (0x13) | `PERFORMANCE_LEVEL_SET` (0x7) | PRIV | Through `M7P` ownership of `PERF_M7` (S2); the PRIV level is **unconfirmed** |
| Read M7 performance level | Performance (0x13) | `PERFORMANCE_LEVEL_GET` (0x8) | none | yes |
| Enable or gate a clock the M7 owns | Clock management (0x14) | `CLOCK_CONFIG_SET` (0x7) | SET | for clocks of owned resources |
| Set a clock rate | Clock management (0x14) | `CLOCK_RATE_SET` (0x5) | EXCLUSIVE | for clocks of owned resources |
| Reset a peripheral | Reset domain management (0x16) | `RESET` (0x4) | EXCLUSIVE | **unconfirmed** (§3.3) |
| Power a domain off | Power domain management (0x11) | `POWER_STATE_SET` (0x4) | SET | no, for `PD_NETC` and the other A55-owned domains |
| Read a domain's state | Power (0x11) | `POWER_STATE_GET` (0x5) | none | yes |
| Shut down the A55 LM | LMM, NXP vendor (0x80) | `LMM_SHUTDOWN` (0x6) | PRIV, EXCLUSIVE | yes (`LMM_2 ALL`) |
| Reset the A55 LM | LMM (0x80) | `LMM_RESET` (0x5) | PRIV, EXCLUSIVE | yes |
| Shut down or reset the whole system | System power management (0x12) | `SYSTEM_POWER_STATE_SET` (0x3) | SET, PRIV, EXCLUSIVE | yes (`SYS ALL`) |
| Learn of an A55 LM event | LMM (0x80) | `LMM_NOTIFY` (0x9), event `LMM_EVENT` | NOTIFY | yes |

## 6. The resource map

"In S10" is this device's file: **yes** only where the repository records it (public-source-survey.md items
14-16), otherwise **unconfirmed**. "In S1 (reference)" says whether the M7 agent (`SCMI_AGENT0`, LM1) of the 15x15
file holds the right at `rel_imx_sm_2026q3`; it is reference material, not a fact about this device. Numeric SCMI
domain and clock IDs are not given: they are in headers this lane could not read (§8).

| Resource | imx-sm identifier | SCMI protocol | Used by | In S10 (this device) | In S1 (reference) | Source |
|---|---|---|---|---|---|---|
| M7 power domain | `PD_M7` | Power (0x11); set by the SM at LM start and stop | M7 run time | **unconfirmed** | SM-managed; `test` on M7 | S1, S2 |
| M7MIX TCM power | `PD_WAKEUP` | Power (0x11) | M7 run time | **unconfirmed** | not to the M7 | S2 |
| M7 CPU | `CPU_M7P` | CPU, NXP vendor (0x82); SM starts it | M7 run time | **unconfirmed** (LM1 "M7" exists) | yes (`M7P` owner) | S1, S2, S7, S10 |
| M7 performance level | `PERF_M7` | Performance (0x13) | M7 run time | **unconfirmed** | yes (with `M7P`) | S2, S5 |
| M7 core clock | `CLK_M7` | via Performance (0x13), not Clock | M7 run time | **unconfirmed** | through `PERF_M7` | S1 |
| M7 bus clock | `CLK_BUSM7` | via Performance (0x13) | M7 run time | **unconfirmed** | through PERF (**unconfirmed** which domain) | S1 |
| M7 SysTick clock | `CLK_M7SYSTICK` | Clock (0x14) | M7 run time | **unconfirmed** | yes (with `M7P`) | S2 |
| M7 console UART | `LPUART7` on S10 (`LPUART3` on S1) | none (owned peripheral) | M7 run time | **yes** (`LPUART7`) | `LPUART3`, not this device's | S1, S10 |
| M7 pins | `GPIO_IO36`, `GPIO_IO37` on S10 (`GPIO_IO14`, `GPIO_IO15` on S1) | Pin control (0x19) | M7 run time; wiring on the PRO **unconfirmed** | **yes** (`GPIO_IO36/37`) | `GPIO_IO14/15`, not this device's | S1, S10 |
| M7 reset | LM1 reset (`lm_reset` fault reaction) | none from the M7; LMM (0x80) from another agent | M7 run time | **yes** (M7 lock-up, M7 reset, WDOG5 reactions) | n/a | S1, S10 |
| Peripheral reset domains | **unconfirmed** | Reset (0x16) | M7 run time | **unconfirmed** | **unconfirmed** | S5 |
| NETC power domain | `PD_NETC` | Power (0x11), `POWER_STATE_SET` | tamper response | **unconfirmed** | **no** (owner `AP-NS`) | S1, S3 |
| NETC reference clock | `CLK_ENETREF` | Clock (0x14), `CLOCK_CONFIG_SET` | tamper response | **unconfirmed** | **no** | S3 |
| NETC timer clock | `CLK_ENETTIMER1` | Clock (0x14) | tamper response | **unconfirmed** | **no** | S3 |
| ENET clock | `CLK_ENET` | via Performance (0x13) | tamper response | **unconfirmed** | **no** (SM-managed) | S1 |
| MDIO master | `NETC_EMDIO0` | none (register access, TRDC) | tamper response (PHY power-down over MDIO) | **unconfirmed** | **no** | S1, S3 |
| ENET pins | `PIN_ENET1_*`, `PIN_ENET2_*` | Pin control (0x19) | tamper response | **unconfirmed** | **no** | S1 |
| Ethernet PHYs | none in S1 | none; board GPIO or PMIC, **unconfirmed** | tamper response | **unconfirmed** | **no** | S9 (unreachable) |
| A55 logical machine | `LMM_2` (LM2 `AP`) | LMM, NXP vendor (0x80), `LMM_SHUTDOWN` / `LMM_RESET` | tamper response | **yes** (`ALL`) | **yes** (`ALL`) | S1, S5, S10 |
| System power | `SYS` | System power (0x12), `SYSTEM_POWER_STATE_SET` | tamper response (shutdown) | **unconfirmed** | **yes** (`ALL`) | S1, S5 |
| EdgeLock mailbox | `MU_ELE5` | none (ELE API, not SCMI) | tamper response (zeroisation, out of scope) | **unconfirmed** | yes (owner) | S1 |

## 7. The board configuration file that grants them

This device's configuration is `configs/other/mx95frdm-pro.cfg` (S10), NXP's file for the 19x19 FRDM-IMX95-PRO.
It names the EVK board port (`board=mcimx95evk`), and its header comment still says "MX95 EVK". It sits under
`configs/other/` with no pre-generated header directory; `make config=mx95frdm-pro cfg` finds it there and writes
the `configs/mx95frdm-pro/config_*.h` headers the SM is built with ([sm-build-survey.md](sm-build-survey.md) §3;
the build is #87's). What the repository records of S10 is listed in §2; the rest of S10 is **unconfirmed**.

`configs/mx95frdm.cfg` (S1), beside the EVK one (`configs/mx95evk.cfg`), is the **15x15** FRDM's file with its own
board port `mcimx95frdm`. It is **not** this device's. The rest of this section describes S1 as **reference
material only**; each S1 fact that differs on S10, or is unconfirmed there, is marked.

In S1 the logical machines (LMs) are (S10 has the same LM and agent layout, public-source-survey.md item 14):

| LM | Name | SCMI agent | Mailbox | Notes |
|---|---|---|---|---|
| LM0 | `SM` (M33) | none | none | Owns the power, clock, reset and safety blocks (GPC, CCM, SRC, TRDC, FCCU and so on) |
| LM1 | `M7` | `SCMI_AGENT0` `"M7"` | MU9 (test MU8), high priority; three SMT channels with CRC32: a2p, p2a notify, p2a priority | Booted second (`boot=2`); `safe=seenv` |
| LM2 | `AP` (A55) | `SCMI_AGENT1` `"AP-S"` (secure) and `SCMI_AGENT2` `"AP-NS"` | MU1 and MU3 | The default LM; the non-secure agent owns NETC, the ENET pins, HSIO, display, camera, VPU, NPU and GPU blocks |

What S1 (15x15, reference only) gives the M7 agent (LM1), in our words. For S10, only the `LMM_2` grant, the fault
reactions, LPUART7 and GPIO_IO36/37 are confirmed; the rest is **unconfirmed** for this device:

- **Start and stop:** in every boot mode select (`msel` 0, 1, 2) the SM powers `PD_M7` at start step 1 and
  releases `CPU_M7P` at step 2, and stops them in the reverse order. The M7 does not ask for its own power; the SM
  does it when it starts the LM.
- **API grants:** `SYS` (all), `LMM_2` (all, the A55 LM), `FUSA` (all), `RTC` (privileged), `SENSOR_TEMP_ANA`
  (all), `BUTTON` (notify), and board-specific controls (`BRD_SM_CTRL_*`, `BRD_SM_RTC_PCA2131`,
  `BRD_SM_SENSOR_TEMP_*`). No `PERF_*`, `CLOCK_*` or `PD_*` API grant is listed for the M7.
- **Resources owned:** the M7 CPU (`M7P`), `CAN_FD1`, `IRQSTEER_M7`, `LPIT1`, `LPTMR1`, `LPTMR2`, `LPTPM1`,
  `LPUART3` (its console; **LPUART7 on S10**), `MSGINTR1`, `MSGINTR2`, `MU5_A`, `MU7_B`, `MU8_B`, `MU_ELE5` (its
  EdgeLock enclave mailbox), `TSTMR2`, `V2X_SHE1`, `WDOG5`, pins `GPIO_IO14` and `GPIO_IO15` (**GPIO_IO36 and
  GPIO_IO37 on S10**), read access to `FSB` and `SYSCTR_RD`; `PD_M7` only as a test resource.
- **Memory:** its TCMs in M7MIX and DDR from 0x80000000 to 0x89FFFFFF, executable.
- **Faults:** M7 lock-up, M7 reset, WDOG5 and SW1 reset the M7 LM only; SW0 goes to the FuSa reaction. (S10 has
  the M7 lock-up, M7 reset and WDOG5 reactions and SW0 to FuSa; its SW1 reaction is unconfirmed. S10 also lacks the
  NoC fault entries S1 has.)

In S1 (reference; S10 **unconfirmed**), the A55 non-secure agent (`AP-NS`) owns `NETC`, `NETC0`..`NETC2`, `NETC_EMDIO0`, `BLK_CTRL_NETCMIX` and every
`PIN_ENET1_*` and `PIN_ENET2_*` pin. The M7 agent owns none of them.

## 8. Unconfirmed items

1. **S10's grants beyond what is recorded.** The board file is settled: this device uses
   `configs/other/mx95frdm-pro.cfg` (S10), not the 15x15 `mx95frdm.cfg` (S1). This lane did not read S10 itself.
   Its M7 ownership of `M7P`, `PERF_M7` and `MU_ELE5`, its `SYS` grant, the owners of `PD_NETC`, `NETC_EMDIO0` and
   the ENET pins, and what GPIO_IO36/37 are wired to on the PRO are **unconfirmed** until S10 is read for them.
2. **Ethernet PHYs.** Part numbers, which NETC port each serves, their reset and supply-enable pins, and whether a
   supply is SM-controlled. Needs UM12527 §1.2 Table 1 and §2.18 (S9, unreachable from this lane).
3. **Numeric identifiers.** The SCMI power-domain, clock, performance-domain and reset-domain IDs (for example the
   number behind `PD_NETC` or `PERF_M7`). They are in imx-sm's generated `configs/mx95frdm-pro/config_*.h` (generated from S10) and device
   headers, and in Linux's `imx95-power.h` and `imx95-clock.h` (S8). This lane's read guard does not allow reading
   C headers outside the repository, so they were not read.
4. **Reset domains.** Whether the M7 needs any SCMI reset domain, and which. Needs the device headers (item 3) and
   IMX95RM (missing).
5. **`PD_WAKEUP` and the M7.** Whether the WAKEUP domain that holds the M7MIX TCMs can go off while the M7 runs.
   Needs IMX95RM (missing).
6. **`PERFORMANCE_LEVEL_SET` rights.** S5 marks the message PRIV; whether owning `M7P` gives the M7 that right on
   `PERF_M7` without a `PERF_M7` API line is the permission model of #107.
7. **The M7's SCMI mailbox.** S1 and S10 bind the M7 agent to MU index 9 (S1 also names test MU index 8), while Zephyr's M7 device tree
   (S7) points its SCMI node at `mu5`; and S7 declares only the Power, Clock, Pin control and CPU protocols, not
   Performance, System or LMM. How S1's MU index maps to the MU names is **unconfirmed**; the imx-sm source survey
   (#33) owns it.
8. **SCMI 3.2 text.** S6 was not read in this lane; protocol and message IDs here are S5's.

## 9. Owner questions

1. **How does the M7 take the network down on tamper?**
   - (a) Shut down the A55 LM with `LMM_SHUTDOWN` (the M7 already holds `LMM_2`), which drops Linux's vote on
     `PD_NETC` and the other A55 domains; then the SM powers them off.
   - (b) Grant the M7 `PD_NETC` (and the other target domains) for `POWER_STATE_SET`. Because the SM keeps the
     highest vote across agents (S4), this does not switch the domain off while Linux holds it on.
   - (c) Change the SM (an NXP-code change the SPEC row rules out) so an M7 request overrides other votes.
   - (d) `SYSTEM_POWER_STATE_SET` to shut down the whole system.
   Recommendation: **(a), with (d) as the fallback**. (a) needs no new grant: S10 gives the M7 `LMM_2` with full
   rights. (d) needs no new grant only if S10 gives the M7 `SYS` as S1 does, which is **unconfirmed**; if it does
   not, (d) is a grant to add and review in #107. (b) does not achieve "off" on its own. Confirm (a)'s effect on
   `PD_NETC`, and that `AP-NS` owns it in S10, against S10 and IMX95RM.
2. **How are the PHYs themselves silenced?**
   - (a) Leave them powered; rely on `PD_NETC` off (MAC side down).
   - (b) Give the M7 the PHY reset or enable GPIOs in the SM configuration.
   - (c) Give the M7 `NETC_EMDIO0` and power the PHYs down over MDIO.
   Recommendation: none yet: it needs UM12527 §2.18 (unreachable here) and S10's pin list. (b) is the simplest if
   the PRO has such pins; the M7's existing S10 pins (GPIO_IO36/37) must not be assumed to be PHY controls.
3. **Which imx-sm tag and which board configuration does this repository pin?**
   - (a) `rel_imx_sm_2026q3` with `configs/other/mx95frdm-pro.cfg` (S10) as the starting point and a repository
     copy for our changes. The 15x15 `mx95frdm.cfg` (S1) is not an option: it is another board's file.
   - (b) The tag the NXP BSP release in use ships.
   Recommendation: **(b)**, with S10 as the board file at that tag (S10 is absent at `rel_imx_sm_2025q4`,
   public-source-survey.md), so the SM matches the ELE firmware and Linux it was tested with (imx-sm's release notes,
   `sm/doc/rn_intro.md`, record a tested ELE firmware and Linux per release); the pin itself belongs to the SM build row (#87).
4. **Should the M7 hold `SYS ALL`?** It lets the M7 shut down or reset the whole board. S1 (reference) grants it;
   whether S10 does is **unconfirmed**, so this is "keep" or "add" depending on S10.
   - (a) Hold it: the tamper response needs a whole-system shutdown.
   - (b) Restrict it to notify only and do shutdowns through LMM.
   Recommendation: **(a)** for `hsm-self-defence`, with the permission review in #107.
5. **Obtain the missing documents?** IMX95RM and NXP's System Manager documentation for the BSP release, and
   lane read access to UM12527, resolve §8 items 2 to 5; a full read of S10 resolves item 1. Options: obtain them now, or proceed on public sources
   and mark the gaps. Recommendation: obtain them before any configuration change is written.
