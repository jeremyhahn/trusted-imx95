# Secure-world attack surface survey (i.MX 95, FRDM-IMX95-PRO)

Status: draft survey for the owner (issue #115, row `secure-world` in [SPEC.md](../SPEC.md)).
Public sources only; every claim cites one. Nothing here was run on a board.

## 1. Scope and method

TODO

## 2. Sources surveyed

TODO

## 3. Paths from the Cortex-A55 Linux into the secure side

### 3.1 TF-A SMC calls (EL3)

Source: NXP `imx-atf`, branch `lf_v2.14` at commit `af9eb2c` (2026-09-01),
platform `plat/imx/imx9/imx95`, read through its commit history [S2].
The lane could not read the C source itself (see §6), so the list below is
built from commit subjects, commit messages and the files each commit
touches, not from the SMC dispatcher.

TF-A BL31 is the only EL3 firmware on the A55. Linux reaches it through:

- **PSCI** (standard Arm service): CPU on/off, idle, system off, system
  reset and `SYSTEM_RESET2`. On the i.MX 95 these calls are carried out by
  TF-A sending SCMI to the SM over the secure "AP-S" agent (§3.4). NXP added
  warm, cold and board reset kinds to `SYSTEM_RESET2` and A55 cluster
  power-off from cpuidle [S2].
- **NXP SiP calls** (`imx_sip_svc`), the vendor's own SMC range. The
  i.MX 95 additions seen in the history are:
  - M7 life-cycle management from the A55: start and stop the M7, and set
    its reset address (boot, start or resume) from a value Linux passes in
    a register [S2];
  - logical-machine boot and shutdown through the SM's LMM protocol, later
    changed to a forceful shutdown [S2];
  - SoC information (shared i.MX 9 code; the i.MX 93 variant reads it from
    the ELE) [S2].
  The common SiP handler also carries older families' calls (GPC, DDR
  DVFS, SRC, HAB, NOC, wakeup, OTP, watchdog); which of these the i.MX 95
  build compiles in is **not confirmed**.
- **SPD dispatch to the trusted OS**: the i.MX 95 port supports both OP-TEE
  (`opteed`) and Trusty, and has FF-A shared-memory ("lend") support [S2].
  This is the path of §3.2.

Security-relevant fix seen: an out-of-bounds copy in the i.MX 95 M7 code
(`scmi_base_discover_agent` copied a 20-byte agent name into a 16-byte
buffer), found by static analysis and fixed in this branch [S2]. The input
there comes from the SM, not directly from Linux.

The M7 SiP calls are the most notable for this board: they let the
non-secure Linux kernel start, stop and re-point the M7 through EL3, even
though the SM denies the "AP-NS" agent the same control (§3.4). TF-A acts as
a privileged proxy for those requests.

### 3.2 OP-TEE driver and TA sessions (S-EL1)

Sources: NXP `imx-optee-os`, tag `lf-6.18.37-2.1.0` (commit `99f4089`,
2026-09-07), read through its commit history [S3]; TF-A i.MX 95 OP-TEE
support [S2]; Linux `drivers/tee/optee` (upstream, not read in this lane)
[S7].

The path is: a Linux user process opens the TEE device, the kernel's OP-TEE
driver turns each request into an SMC, TF-A's OP-TEE dispatcher forwards it
to OP-TEE at S-EL1, and OP-TEE routes it to a trusted application (TA) or a
pseudo-TA built into the OP-TEE core. A second device node serves
`tee-supplicant`, the normal-world helper that OP-TEE calls back for
storage and TA loading. Every TA command and every shared-memory buffer is
attacker-reachable input from a compromised Linux.

What the NXP history shows for the i.MX 9 family [S3]:

- OP-TEE talks to the EdgeLock Enclave itself, through a "trusted" MU, for
  the hardware unique key, random numbers, fuse reads, the device life
  cycle, and (recently) ELE-backed RSA and ECC keys.
- Fuse reads through OP-TEE are refused once the life cycle is closed.
- Two robustness fixes in the ELE MU driver: a stale-response race after a
  timeout, which could let one request read another's answer (fixed with a
  "circuit breaker"), and oversized commands that hung the ELE on the
  trusted MU (now sent through RAM).
- The PKCS#11 TA now separates data-encryption from key-encryption use
  (the tag's head commit).

Which TAs and pseudo-TAs the i.MX 95 build enables by default is **not
confirmed**; the lane could not read the platform's `conf.mk` (§6).

### 3.3 EdgeLock Enclave messaging unit

Sources: `imx-sm` `rel_imx_sm_2026q3` `configs/mx95frdm.cfg` [S1]; NXP
`linux-imx` branch `lf-6.18.y`, directory `drivers/firmware/imx` (file list
only) [S4]; upstream Linux `master` the same directory (file list only)
[S5].

The ELE is reached only through messaging units (MUs), and each MU is a
resource the SM assigns to one domain and one security state. In the FRDM
configuration [S1]:

| MU | Assigned to | Security |
|---|---|---|
| `MU_ELE0` | SM (M33) | secure |
| `MU_ELE1`, `MU_ELE2` | A55, secure side (TF-A / OP-TEE) | secure |
| `MU_ELE3`, `MU_ELE4` | A55, non-secure side (Linux) | non-secure |

So Linux has its own ELE MUs, separate from OP-TEE's. On the Linux side
the NXP kernel carries an ELE driver set (`se_ctrl`, `ele_base_msg`,
`ele_fw_api`, `ele_trng`, `ele_bbsm`, plus V2X files) that the upstream
kernel does not have [S4][S5]. In the NXP BSP the `se_ctrl` driver exposes
the MU to user space as a character device used by NXP's `imx-secure-enclave`
library; this is from the file names and public BSP practice and is
**not confirmed** from source in this lane.

The ELE firmware decides what a given MU may ask for (for example, which
HSM commands are allowed from a non-secure MU); that policy is in the ELE
firmware and the security reference manual, neither of which is public, so
it is **not confirmed** here.

### 3.4 SCMI to the System Manager (Cortex-M33)

Source: NXP `imx-sm`, tag `rel_imx_sm_2026q3`, file `configs/mx95frdm.cfg`
(the board's own SM configuration) [S1].

The System Manager (SM) on the Cortex-M33 splits the SoC into logical
machines (LMs). In the FRDM configuration [S1]:

- **LM0 "SM"** is the M33 itself and owns the security-relevant blocks: the
  TRDC instances (resource domain controllers), the clock controller, the
  system reset controller, the GPC, the IOMUX, the DDR controller, JTAG/DAP,
  the BBNSM and the M33 side of the ELE messaging unit (`MU_ELE0`). It
  exposes no RPC interface of its own (`rpc=none`).
- **LM1 "M7"** is the Cortex-M7, reached as SCMI agent 0 over MU 9.
- **LM2 "AP"** is the Cortex-A55 cluster, the default LM. It has **two SCMI
  agents**:
  - **agent 1 "AP-S"** (secure, MU 1) is meant for TF-A. Its API grants
    include full `SYS` control (system reset and power state), the A55
    performance domain, and a set of "PERLPI" low-power-interface controls
    for peripherals. Its resources are the A55 cores, the ARM PLL, `MU1_A`
    and two ELE messaging units, `MU_ELE1` and `MU_ELE2`, all with
    secure-only permission.
  - **agent 2 "AP-NS"** (non-secure, MU 3) is what Linux uses. It gets
    clocks and PLLs for audio, display, PCIe and USB, the A55 performance
    domain, temperature sensors, the RTC, board controls, and only
    notifications for `SYS` (so Linux cannot reset or suspend the system
    through SCMI directly; it must go through PSCI in TF-A) and for `LMM_1`
    (it is told about the M7 but cannot start, stop or reset it).

So the SCMI surface Linux holds is set per agent, at SM build time, by this
configuration file; anything not listed is refused by the SM. The A55's
memory and peripheral access is enforced in hardware by the TRDC that the SM
programs from the same file [S1].

Linux's side is the upstream `arm_scmi` driver plus NXP's vendor protocol
extensions for the i.MX 95 (BBM, MISC, LMM, CPU) [S6]; each SCMI message
Linux can send is an input the SM firmware parses.

## 4. What Linux needs on this board, and what can be closed or restricted

TODO

## 5. Known public vulnerabilities and advisories

TODO

## 6. Not confirmed

TODO

## 7. Questions for the owner

TODO
