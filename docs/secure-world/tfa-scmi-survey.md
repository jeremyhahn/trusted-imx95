# Secure world: TF-A BL31 and SCMI on the i.MX 95 (survey)

Status: draft survey for issue #96, row `secure-world` of [SPEC.md](../SPEC.md).
Public sources only; every claim cites a source from the [Sources](#sources) list.

## 1. Scope and method

## 2. What TF-A provides for the i.MX 95

### 2.1 Upstream TF-A

Upstream TF-A [S1] carries an i.MX 95 port at `plat/imx/imx9/imx95`, built with
`make PLAT=imx95 bl31`. It is present in tag `v2.15.0` and on `master` as surveyed
(2026-11-11); `master` also has sibling ports `imx94` and `imx952` sharing
`plat/imx/imx9/common` [S1, S2]. Facts below are from `v2.15.0` unless marked.

- **BL31 only, reset to BL31.** The port's `platform.mk` sets `RESET_TO_BL31 := 1`
  and builds no BL1 or BL2 [S2]. The upstream i.MX 9 platform page gives the boot
  chain as BootROM, then U-Boot SPL, then BL31, then U-Boot proper, then Linux; SPL,
  not TF-A, loads the next images [S3].
- **Cores.** One cluster of six Cortex-A55 cores (`PLATFORM_CORE_COUNT` 6), cold
  boot on a single CPU, hardware-assisted coherency, GIC-600 through the GICv3
  driver, Cortex-A55 erratum 1530923 workaround on [S2].
- **Memory.** BL31 links at `0x8A200000` with a 256 KiB limit (`0x8A240000`);
  the default BL32 window is `0x8C000000`, 32 MiB (`BL32_BASE`/`BL32_SIZE`,
  overridable on the make line) [S2].
- **Console.** LPUART at `0x44380000`; BL31 registers it with boot scope only,
  so it is not used at runtime after handing over to the normal world [S2].
- **Platform setup.** `bl31_platform_setup` queries the EdgeLock Enclave (ELE)
  for SoC information over the ELE messaging unit at `0x47540000`, releases the
  GMID, and then sets up the SCMI client [S2].
- **SiP services.** The port compiles NXP's i.MX SiP handler
  (`imx_sip_handler.c`, `imx_sip_svc.c`) [S2]; which SiP calls are enabled for
  the i.MX 95 was not traced function by function (see section 6).

The upstream TF-A documentation page for i.MX 9 still only names `imx93` as a
build target and does not describe the i.MX 95 port [S3]; the port is
documented by its source only.

### 2.2 NXP TF-A (imx-atf)

### 2.3 PSCI

The i.MX 95 PSCI back end [S2, `imx95_psci.c` and `imx9_psci_common.c`]
implements CPU on and off, CPU and cluster suspend with finish handlers, system
suspend (`get_sys_suspend_power_state`, with DRAM retention code in
`imx9_sys_sleep.c`), power-down, system reset and system off. None of these
touch power or clock hardware directly. Each is turned into SCMI requests to
the System Manager: setting a core's reset (entry) address, starting a core,
setting its low-power mode and sleep mode, setting wake sources, and, for
system reset and off, an SCMI system power state request [S2]. CPU entry
points from the normal world are checked by `imx_validate_ns_entrypoint`
before use [S2].

### 2.4 Reaching the System Manager over SCMI

BL31 is an SCMI *agent*; the System Manager (SM) firmware on the Cortex-M33 is
the SCMI *platform* [S2, S5, S6]. In the upstream port [S2]:

- **Transport.** A shared-memory mailbox: the SCMI payload area sits at
  `0x44221000`, and the doorbell is a write to the general control register of
  messaging unit MU1 at `0x44220000` (`MU_SECURE_BASE`, the secure-side MU).
  The generic Arm CSS SCMI driver (`drivers/arm/css/scmi`) does the framing,
  with a lock that serialises the cores.
- **Protocols used.** SCMI base, power domain and system power from the
  generic driver, plus an NXP vendor extension (`drivers/nxp/scmi/vendor/
  scmi_imx9.c`) for CPU control: start, reset address, low-power mode, sleep
  mode, wake masks. Power "mix" and memory slice indices for the i.MX 95 are
  listed in `imx95_scmi_def.h`.
- **Which agent BL31 is.** The SCMI channel BL31 uses, and the permissions it
  carries, are set by the SM configuration, not by TF-A. In NXP's SM, each
  SCMI agent is bound to a messaging-unit channel and a security state, and
  agents are grouped into logical machines (LM); the SM configuration tool
  decides which resources each agent may touch [S5, S6]. TF-A trusts that the
  channel it uses is the secure one; it does not verify it.
- **ELE.** Separately from SCMI, BL31 talks to the EdgeLock Enclave over its
  own MU for SoC information and the GMID release [S2].

## 3. Build options that matter for security

## 4. Resources that stay secure-only

## 5. Placement in the boot container and verification (input to #32, #55)

## 6. What could not be confirmed

## Sources

## Questions for the owner
