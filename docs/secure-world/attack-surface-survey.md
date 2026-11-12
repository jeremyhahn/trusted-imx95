# Secure-world attack surface survey (i.MX 95, FRDM-IMX95-PRO)

Status: draft survey for the owner (issue #115, row `secure-world` in [SPEC.md](../SPEC.md)).
Public sources only; every claim cites one. Nothing here was run on a board.

## 1. Scope and method

The question is every way the non-secure Linux kernel (and, through it,
user space) on the Cortex-A55 can send input to secure software on the
i.MX 95: EL3 firmware (TF-A), the trusted OS (OP-TEE), the EdgeLock Enclave
(ELE), and the System Manager (SM) on the Cortex-M33. For each path the
survey asks what Linux needs on this board, what could be closed, and what
public advisories exist.

Method: shallow clones of NXP's public GitHub repositories at the tags in
§2, read through their documentation, configuration files and commit
history; public CVE records from NVD. The lane's tooling did not allow
reading C source in those clones, so statements about code are drawn from
commit messages and file names and say so. Nothing was built or run.

## 2. Sources surveyed

| Id | Title | Version | URL |
|---|---|---|---|
| S1 | NXP i.MX System Manager (`imx-sm`), FRDM-IMX95 configuration `configs/mx95frdm.cfg` and `sm/doc` | tag `rel_imx_sm_2026q3` (commit `eec2328`) | https://github.com/nxp-imx/imx-sm |
| S2 | NXP TF-A (`imx-atf`), i.MX 95 platform and SiP service history | branch `lf_v2.14`, commit `af9eb2c` | https://github.com/nxp-imx/imx-atf |
| S3 | NXP OP-TEE OS (`imx-optee-os`), i.MX and ELE driver history | tag `lf-6.18.37-2.1.0` (commit `99f4089`, upstream base 4.10.0) | https://github.com/nxp-imx/imx-optee-os |
| S4 | NXP Linux kernel (`linux-imx`), `drivers/firmware/imx` file list | branch `lf-6.18.y`, read 2026-11-12 | https://github.com/nxp-imx/linux-imx/tree/lf-6.18.y/drivers/firmware/imx |
| S5 | Upstream Linux, `drivers/firmware/imx` file list | `master`, read 2026-11-12 | https://github.com/torvalds/linux/tree/master/drivers/firmware/imx |
| S7 | Linux OP-TEE driver and OP-TEE documentation | not read in this lane | https://optee.readthedocs.io/ |
| S8 | NIST National Vulnerability Database, CVE API 2.0 | queried 2026-11-12 | https://services.nvd.nist.gov/rest/json/cves/2.0 |
| S9 | TF-A security advisories TFV-1 to TFV-13 (copy in the NXP tree) | `imx-atf` `lf_v2.14` `docs/security_advisories` | https://trustedfirmware-a.readthedocs.io/en/latest/security_advisories/ |

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
extensions for the i.MX 95; the upstream and NXP trees both carry `sm-cpu`,
`sm-lmm` and `sm-misc` client files [S4][S5] (a BBM extension is also
expected, not confirmed in this lane). Each SCMI message
Linux can send is an input the SM firmware parses.

## 4. What Linux needs on this board, and what can be closed or restricted

This section is the survey's reading of §3 against the board's use in
[SPEC.md](../SPEC.md); the recommendations are the author's, not NXP's.

| Path | Does Linux need it? | How it can be narrowed |
|---|---|---|
| PSCI (TF-A) | Yes: CPU bring-up, idle, reset and power-off. | Standard; keep. |
| NXP SiP: M7 start/stop/reset address, LM boot/shutdown (TF-A) | Only if Linux manages the M7 (remoteproc). SPEC leaves the M7's role open. | Leave the M7 SiP calls out of the TF-A build, or have TF-A refuse them, if the M7 is started by the SM and Linux does not control it. Whether the i.MX 95 build has a switch for this is not confirmed [S2]. |
| Other NXP SiP calls (SoC info and older families' calls) | SoC info is used for identification; the rest is not known to be needed. | Audit which handlers the i.MX 95 build compiles in (not confirmed, §6). |
| SDEI (TF-A) | Not known to be needed. | Leave disabled; this also removes the TFV-11 class [S9]. |
| OP-TEE SMC and TA sessions | Only if a secure-side service is wanted (secure storage, PKCS#11 TA, ELE-backed keys through OP-TEE). SPEC's key rows put keys in the ELE and leave the caller open. | If OP-TEE is not needed, do not load it (TF-A then has no SPD). If it is: build only the TAs needed, and rebase to OP-TEE 4.11.0 or carry the §5.2 fixes. |
| ELE MUs `MU_ELE3`/`MU_ELE4` (Linux) | Yes if Linux calls the ELE HSM API directly, which is one of SPEC's open options. | Remove them from the "AP-NS" resources in the SM configuration if only the secure side (OP-TEE) or the M7 calls the ELE; the TRDC then blocks Linux from the MUs in hardware [S1]. |
| SCMI "AP-NS" agent (SM) | Yes: clocks, performance, sensors, RTC, power domains of Linux's peripherals. | Already narrowed: no `SYS` control and only `LMM` notifications [S1]. Further narrowing is possible per item (for example the `BRD_SM_CTRL_TEST_A` and `BUTTON ... test` grants) by editing the board configuration and rebuilding the SM. |
| TRDC resource isolation (SM) | Defines what memory and peripherals the non-secure A55 can touch. | The FRDM file gives the non-secure A55 broad ownership of display, camera, NETC, eDMA1 and others [S1]. DMA-capable peripherals owned by Linux can reach memory the TRDC lets them; the memory ranges for secure DDR (TF-A, OP-TEE) must be outside what those masters may write. The secure A55 DDR range in the file is `0x8A000000` to `0x8DFFFFFF` [S1]; that its exclusion from non-secure masters is complete is not confirmed. |

The configuration file is the one control point for SCMI and TRDC: both
change only when the SM is rebuilt and the boot image re-signed [S1].

## 5. Known public vulnerabilities and advisories

Searched: the NVD CVE API by keyword (`OP-TEE`, `Trusted Firmware-A`,
`NXP i.MX`, `i.MX 8`, `i.MX 93`, `i.MX 95`, `EdgeLock`, `SCMI`, `imx-sm`),
queried 2026-11-12 [S8]; TF-A's own advisory list TFV-1 to TFV-13 in the
`lf_v2.14` tree [S9]. NXP's PSIRT page did not answer (§6). "Applies"
below is a reading of the CVE text against the versions in §2, not a test.

### 5.1 TF-A

| Advisory | Summary (own words) | Applies here? |
|---|---|---|
| TFV-11, CVE-2023-49100 | A non-secure SDEI bind call with a bad interrupt number reads out of bounds in EL3; fixed upstream for v2.10 [S9]. | Only if SDEI is built in. NXP's tree has an i.MX SDEI file; whether the i.MX 95 build enables it is not confirmed. The branch is based on v2.14, after the fix, if NXP carried the upstream fix (not confirmed). |
| TFV-12, CVE-2024-5660 | Hardware page aggregation can mistranslate memory on some Arm CPUs; affects v2.2 to v2.12 [S9]. | Probably not: the issue concerns specific newer CPUs; whether the Cortex-A55 is on Arm's list is not confirmed. |
| TFV-13, CVE-2024-7881 | A data-dependent prefetcher can leak privileged data; affects v2.2 to v2.12 [S9]. | Probably not, for the same reason; not confirmed for the A55. |
| CVE-2022-47630 | Out-of-bounds read in TF-A's X.509 parser, through v2.8 [S8]. | Boot-time only (trusted board boot). The i.MX 95 boots through the ELE's container authentication, so TF-A's parser is likely unused; not confirmed. |
| TFV-1 to TFV-10 | Older issues (boot image parsing, Spectre-class mitigations and others), all fixed well before v2.14 [S9]. | Fixed in the base version, if NXP's tree carries the fixes. |

NXP-specific TF-A: no CVE found. The one memory-safety fix seen in the
i.MX 95 code is the SCMI agent-name overrun in §3.1 [S2].

### 5.2 OP-TEE

The NXP tree at `lf-6.18.37-2.1.0` is based on upstream OP-TEE 4.10.0
(its history has the 4.10.0 changelog commit and no later one) [S3].
Upstream published a batch of advisories fixed in **4.11.0** in mid-2026
[S8]. Against the NXP tree:

| CVE | Summary (own words) | In the NXP tree? |
|---|---|---|
| CVE-2026-45614 | ECDH did not check that a peer public key lies on the curve, so a normal-world caller could recover a private key [S8]. | A commit "validate ECC public keys are on the curve" is present [S3]; likely fixed. |
| CVE-2026-41515 | RSA-OAEP padding oracle in the CAAM driver [S8]. | CAAM OAEP timing and hardening commits are present [S3]. Whether the i.MX 95 uses CAAM at all is not confirmed. |
| CVE-2026-33317 | Out-of-bounds read in the PKCS#11 TA's get-attribute path, 3.13 to 4.10 [S8]. | No matching commit subject found; **treat as open**. Other PKCS#11 TA fixes are present (an RSA-AES unwrap stack overflow, key-use separation) [S3]. |
| CVE-2026-41434 | Unbounded recursion crashes the PKCS#11 TA [S8]. | No matching commit found; treat as open. |
| CVE-2026-33662 | RSA PKCS#1 v1.5 signature encoding underflows with a small modulus [S8]. | A commit "reject keys with oversized parameters" is present; whether it covers this case is not confirmed. |
| CVE-2026-42546 | Shared-memory reference leak on non-contiguous parameters from the normal world [S8]. | No matching commit found; treat as open. |
| CVE-2026-44362 | TA subkey rollback protection can be bypassed when loading TAs [S8]. | A "check against REE FS TA downgrade" commit is present; whether it is this fix is not confirmed. |
| CVE-2026-53763 | AES-GCM tag wrong after more than 512 MiB of data [S8]. | No matching commit found; treat as open. |
| CVE-2026-40257 | SHA-3 overflow with the Armv8.2 crypto-extension build [S8]. | The A55 is Armv8.2; applies only if `CFG_CRYPTO_WITH_CE82` is on for the i.MX 95, not confirmed. |
| CVE-2026-40290, CVE-2026-45702 | FF-A shared-memory bugs when OP-TEE is an SPMC for secure partitions [S8]. | Only with secure partitions configured; not the default i.MX layout, not confirmed. |
| CVE-2026-41514, CVE-2026-41516 | HiSilicon crypto driver [S8]. | No (other vendor's hardware). |
| CVE-2025-46733 | A crafted `tee-supplicant` can make TAs that use secure storage panic (4.5.0) [S8]. | Design consequence of the supplicant being in Linux; a root attacker can do this. |

Older OP-TEE CVEs (2016 to 2023: LibTomCrypt and libMPA side channels,
TA-loader and shared-memory bounds bugs, a signature double free) are all
fixed long before 4.10 [S8].

### 5.3 NXP i.MX 8 and i.MX 9 family

| CVE | Summary (own words) | Applies here? |
|---|---|---|
| CVE-2023-39902 | U-Boot SPL on i.MX 8M parts could be made to run unauthenticated code through a crafted FIT image (before U-Boot 2023.07) [S8]. | The i.MX 95 is not listed; its boot chain authenticates through the ELE. Not confirmed; belongs to the U-Boot row rather than this one. |
| CVE-2021-36133, CVE-2021-44149 | OP-TEE's CSU driver left some i.MX 6/7 peripherals unprotected, so DMA from the normal world could reach secure memory [S8]. | No: the i.MX 95 has no CSU; its isolation is the TRDC programmed by the SM (§3.4). The **class** of bug (a missed resource in the isolation table) does apply, see §4. |
| CVE-2022-45163 | Information disclosure in serial-download (SDP) boot mode on some NXP parts [S8]. | The listed parts are i.MX RT and older i.MX; the i.MX 95 is not named in the part of the text read. Not confirmed. |
| CVE-2017-7932, CVE-2017-7936 | HAB boot-ROM certificate and buffer flaws on i.MX 6/7 and older [S8]. | No: older ROM, older boot scheme. |

No CVE was found for the EdgeLock Enclave firmware, the i.MX 95 System
Manager, or for the i.MX 93 or i.MX 95 by name [S8]. That is an absence in
one public database, not proof of no issues.

The Linux kernel's own SCMI client has had a run of 2026 CVEs (out-of-bounds
on domain numbers from firmware, teardown races) [S8]. These are bugs where
the firmware side is the attacker; they matter only if the SM itself were
compromised, and are listed for completeness.

## 6. Not confirmed

- **C source not read.** The SiP call table, the list of handlers compiled
  into the i.MX 95 TF-A build, whether SDEI is enabled, OP-TEE's i.MX 95
  `conf.mk` (TAs, crypto-extension flag, CAAM use), and the Linux ELE and
  OP-TEE drivers were not read: the lane's tools refused to open C source
  outside the repository. Statements about them come from commit messages
  and file names.
- **Device-tree use.** Which ELE MU and SCMI channel Linux's device tree
  binds to on the FRDM board was not read; §3.3 relies on the SM
  configuration only.
- **ELE command policy per MU.** Which ELE commands a non-secure MU may
  send is defined by ELE firmware and the i.MX 95 Security Reference Manual,
  neither public; SPEC already lists that manual as missing.
- **SM permission semantics.** That the SM refuses any SCMI request not
  granted in the configuration is the survey's reading of the configuration
  format and the `sm/doc` file names, not a tested claim.
- **NXP PSIRT.** The NXP product security page
  (https://www.nxp.com/company/about-nxp/product-security-incident-response-team:PSIRT)
  returned HTTP 404 to the lane on 2026-11-12. NXP security bulletins that
  are only published there, or only to registered customers, are not
  covered.
- **GitHub advisory database.** The OP-TEE GitHub security-advisory API
  was rate-limited; OP-TEE advisories were taken from NVD instead.
- **Fix presence.** "Present" in §5.2 means a commit subject in the NXP
  history matches; the code was not compared with the upstream fix.
- **Cortex-A55 and TFV-12/TFV-13.** Arm's affected-CPU lists were not read.

## 7. Questions for the owner

1. **Is OP-TEE part of the board's secure world?**
   Options: (a) no trusted OS, TF-A only; (b) OP-TEE with a minimal TA set;
   (c) OP-TEE with NXP's default TA set.
   Recommendation: (a) unless a row needs a secure-side service; it removes
   the whole §3.2 surface and the open §5.2 items. If one is needed, (b),
   with OP-TEE at 4.11.0 or the §5.2 fixes carried [S3][S8].
2. **Who calls the ELE HSM API: Linux, OP-TEE or the M7?**
   (SPEC's `secure-key-handling` row asks the same.)
   Options: (a) Linux, through `MU_ELE3`/`MU_ELE4`; (b) the secure side only,
   with the Linux MUs removed from "AP-NS"; (c) the M7.
   Recommendation: none from sources alone; the per-MU command policy in the
   ELE is not public (§6). If (b) or (c), remove the Linux MUs in the SM
   configuration [S1].
3. **Does Linux control the M7?**
   Options: (a) yes, through remoteproc and the TF-A SiP calls; (b) no, the
   SM boots the M7 and the SiP M7/LM calls are left out of TF-A.
   Recommendation: (b) if the M7 runs fixed firmware; the SiP calls let
   non-secure Linux do what the SM denies its own SCMI agent [S1][S2].
4. **Should the board keep NXP's FRDM SM configuration or carry its own?**
   Options: (a) NXP's `mx95frdm.cfg` as is; (b) a board copy with test
   grants and unused resources removed from "AP-NS".
   Recommendation: (b); the file is the single control point for SCMI and
   TRDC, and it changes only with an SM rebuild [S1].
5. **Which NXP release line is the baseline?**
   Options: (a) `lf-6.18.37-2.1.0` / `lf_v2.14` / `rel_imx_sm_2026q3` as
   surveyed; (b) a later release once NXP rebases OP-TEE past 4.11.0.
   Recommendation: (a) for now, with the open §5.2 CVEs tracked, moving to
   (b) when it exists [S3][S8].
6. **May a later lane read the C source (TF-A SiP table, OP-TEE `conf.mk`,
   Linux device tree) to close §6?**
   Options: (a) yes, in a lane allowed to read external code; (b) obtain the
   i.MX 95 Security Reference Manual instead; (c) both.
   Recommendation: (c); the source closes the build questions, and only the
   manual can answer the ELE per-MU policy.
