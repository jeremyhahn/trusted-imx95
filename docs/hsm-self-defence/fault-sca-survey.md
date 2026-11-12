# hsm-self-defence: public survey of fault-injection and side-channel defences on the i.MX 95

Status: survey for the owner's decision (issue #67). Documentation only.

## Scope

What public sources say about how the FRDM-IMX95-PRO resists physical fault
injection (voltage, clock, electromagnetic or laser glitches) and side-channel
analysis (timing, power, EM), and which of those defences this repository can
configure or must write. It complements the tamper survey of issue #44
(`docs/hsm-self-defence/tamper-survey.md`, on its own branch, not yet on `main`),
which covers tamper inputs and zeroisation. This is the device side of the
`hsm-self-defence` row in [SPEC.md](../SPEC.md).

Nothing here was run on a board. No fuse, life-cycle or provisioning step is
described as a procedure. All text is a summary in my own words; no vendor text is
quoted. Each finding names the sources it rests on by id (S1, S2, ...).

## Sources

| Id | Source | Version surveyed | URL | Reached |
|----|--------|------------------|-----|---------|
| S1 | NXP System Manager (`imx-sm`) documentation: `sm/doc/debug.md`, `sm/doc/arch.md`, `sm/doc/config.md`, `sm/doc/imp.md` | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/tree/rel_imx_sm_2026q3/sm/doc | yes (git clone) |
| S2 | NXP System Manager i.MX 95 fault and sensor lists: `devices/MIMX95/sm/dev_sm_fault.h`, `dev_sm_sensor.h` | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/tree/rel_imx_sm_2026q3/devices/MIMX95/sm | yes |
| S3 | NXP System Manager FRDM-IMX95-PRO board config, `configs/other/mx95frdm-pro.cfg` | tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/configs/other/mx95frdm-pro.cfg | yes |
| S4 | NXP EdgeLock secure enclave user library (`imx-secure-enclave`): `README`, `include/`, `doc/` | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-secure-enclave/tree/lf-6.18.37-2.1.0 | yes (git clone) |
| S5 | NXP U-Boot fork (`uboot-imx`): `arch/arm/mach-imx/ele_ahab.c`, `drivers/misc/imx_ele/` | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/uboot-imx/tree/lf-6.18.37-2.1.0 | yes (git clone) |
| S6 | NXP TF-A fork (`imx-atf`): `docs/` | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-atf/tree/lf-6.18.37-2.1.0 | yes (git clone) |

Sources S7 to S24 are listed under "Additional sources" after F5.

## Findings

### F1. Hardware fault monitors the System Manager exposes

- The i.MX 95 fault list that the System Manager (on the Cortex-M33) handles
  through the fault collection unit has clock-monitor faults: for each of the
  ANAMIX, always-on, wake-up, Cortex-M7, DDR and NoC clock domains there is one
  fault for a lost or too-slow clock and one for a too-fast clock, raised by that
  domain's clock monitoring unit (CMU) (S2, `dev_sm_fault.h`). The FRDM-IMX95-PRO
  config gives the CMU instances to the System Manager itself (S3).
- The same list has over-temperature faults from two temperature sensors (analog
  and Cortex-A55), uncorrected-ECC faults for several memories (DRAM, always-on
  OCRAM, NPU SRAM, M33 and M7 TCM and cache), parity faults on interconnect,
  lock-step errors, watchdog timeouts, and faults for unintended debug, test-mode
  and self-test activation (S2). ECC, parity and lock-step checks are safety
  features, but they also catch some injected faults in memory and buses.
- The temperature sensors can raise threshold events in either direction (S2,
  `dev_sm_sensor.h`), so a low-temperature (cold-boot style) threshold is
  configurable in software.
- The fault list has **no voltage-monitor fault**. In the System Manager's
  reset-reason table, voltage and glitch detection appear only inside the
  EdgeLock enclave: the enclave can force a reset for "no clock", "clock too slow"
  or a general fault, and the docs say these can come from the enclave's own
  glitch, voltage and frequency detectors; the captured syndrome does not tell
  them apart (S1, `debug.md`).
- How the reaction to each fault is configured (immediate and delayed reactions,
  logical-machine or system reset) is in the tamper survey of #44 and in S1
  (`imp.md`, `config.md`); I do not repeat it here.

**Unconfirmed**: the detector thresholds, whether the enclave's glitch and voltage
detectors cover the Cortex-M7 and A55 supply rails or only the enclave's own, and
whether any of them can be tuned or enabled by software or fuses. These would be in
the i.MX 95 Reference Manual (IMX95RM) and the Security Reference Manual, which I
could not reach (see S20, S21).

### F2. The EdgeLock secure enclave

- The public enclave user library (S4) says nothing about fault-injection or
  side-channel countermeasures: a search of its README, headers and API
  documents for fault, glitch, side-channel, constant-time or countermeasure found
  only unrelated uses of "default". The library is a message-unit client; the
  crypto runs in the enclave firmware, which is a signed NXP binary and not open
  source (S4, `README`).
- So any resistance of the enclave's key operations to timing, power or EM
  analysis is a property of NXP's hardware and firmware that this repository can
  only take on NXP's word, through a certification or a datasheet claim.

**Unconfirmed**: which certification (if any) the i.MX 95 EdgeLock enclave holds
and at what attack-potential level; see F5.

### F3. Fault-injection hardening of boot software

- On the i.MX 95 the signature check of each boot image is done by the enclave:
  NXP's U-Boot asks the enclave to verify a container image and branches once on
  the returned status, with no repeated or redundant check of the result (S5,
  `ele_ahab.c`, `ahab_verify_cntr_image`). A single skipped or corrupted branch
  there is the kind of target that glitch attacks aim at.
- Upstream TF-A's own threat model lists bypassing signature verification by
  glitching as a high risk for IoT and mobile platforms, says the best
  mitigation is hardware glitch detection, names redundant checks on
  security-sensitive branches as the software option, and states that TF-A does
  not implement them (S8, threat 04). I found no i.MX 95-specific hardening in
  NXP's TF-A platform code either (S6, `plat/imx/imx9/imx95`, searched for fault,
  glitch and FIH).
- OP-TEE ships a best-effort fault-mitigation option, `CFG_FAULT_MITIGATION`,
  enabled by default, that hardens selected checks against injected faults (S9,
  `mk/config.mk`). Whether OP-TEE runs on this board is the open `secure-world`
  question in SPEC.md.
- MCUboot has a fault-injection hardening (FIH) feature with selectable profiles,
  tested in its CI by scripted instruction skipping under QEMU; its docs note that
  the degree of hardening depends on the compiler and optimisation level (S7,
  `docs/design.md`, "Testing Fault Injection Hardening"; `docs/release-notes.md`).
  MCUboot is not in the i.MX 95 boot path (the boot ROM and the enclave load the
  M7 image), so it is a pattern, not a component.

So the only software this repository writes that can add fault hardening is its
own code that acts on a verification result: the Cortex-M7 firmware's checks (in
trusted-firmware's row) and any check this repository adds to the boot path.

### F4. Side-channel resistance of the software crypto

- TF-PSA-Crypto (the crypto core of Mbed TLS 4) states that it gives limited,
  best-effort protection against software timing attacks, aims for constant-time
  code but has not fully reached it, and makes no guarantee against non-timing
  side channels, local fault injection or physical attacks; those must be
  mitigated by the platform (S10, `SECURITY.md`). Block ciphers in software are
  called out as not yet fully protected.
- The same document warns that compilers can break constant-time code and
  recommends common optimisation levels (S10).
- Therefore any key operation done in software on the Cortex-M7 or A55, rather
  than in the enclave, has no claimed resistance to power or EM analysis. This
  supports SPEC.md's rule that keys stay in the enclave's key store.

### F5. Certification of the EdgeLock enclave

- I looked for a public certificate or claim for the i.MX 95 EdgeLock enclave on
  the PSA Certified product list (S11) and the SESIP site (S12). Neither page's
  static content names the i.MX 95 or EdgeLock (the PSA list is rendered by
  script, so absence there proves nothing). The Common Criteria portal refused the
  request (S13). NXP's product pages could not be reached (S20 to S23).

**Unconfirmed**: any certification, its level, and whether it covers physical
attacks (for example a SESIP level with a physical-attack extension, or a Common
Criteria AVA_VAN level).

### Additional sources

| Id | Source | Version surveyed | URL | Reached |
|----|--------|------------------|-----|---------|
| S7 | MCUboot: `docs/design.md`, `docs/release-notes.md` | tag `v2.5.0` | https://github.com/mcu-tools/mcuboot/tree/v2.5.0/docs | yes (git clone) |
| S8 | Trusted Firmware-A: `docs/threat_model/firmware_threat_model/threat_model.rst` | tag `v2.15.0` | https://github.com/ARM-software/arm-trusted-firmware/blob/v2.15.0/docs/threat_model/firmware_threat_model/threat_model.rst | yes (git clone) |
| S9 | OP-TEE OS: `mk/config.mk` (`CFG_FAULT_MITIGATION`) | tag `4.11.0` | https://github.com/OP-TEE/optee_os/blob/4.11.0/mk/config.mk | yes (git clone) |
| S10 | TF-PSA-Crypto: `SECURITY.md` | tag `v1.2.0` | https://github.com/Mbed-TLS/TF-PSA-Crypto/blob/v1.2.0/SECURITY.md | yes (git clone) |
| S11 | PSA Certified product list | page fetched 2026-11-12 | https://products.psacertified.org/ | yes, but script-rendered; no i.MX 95 entry in the static page |
| S12 | SESIP site | page fetched 2026-11-12 | https://www.sesip.org/ | yes; no i.MX 95 or EdgeLock entry found |
| S13 | Common Criteria certified products | n/a | https://www.commoncriteriaportal.org/products/ | **no**: HTTP 403 |
| S20 | NXP i.MX 95 Applications Processor Reference Manual (IMX95RM) | n/a | https://www.nxp.com/docs/en/reference-manual/IMX95RM.pdf | **no**: HTTP 404 (NXP answers 404 to this lane for every page) |
| S21 | NXP i.MX 95 Security Reference Manual | n/a | no public URL found | **no** |
| S22 | NXP i.MX 95 data sheet and fact sheet | n/a | https://www.nxp.com/docs/en/data-sheet/IMX95AEC.pdf, https://www.nxp.com/docs/en/fact-sheet/IMX95FS.pdf | **no**: HTTP 404 |
| S23 | NXP i.MX 95 and EdgeLock secure enclave product pages | n/a | https://www.nxp.com/products/i.MX95 | **no**: HTTP 404 |
| S24 | Issue #67 text on the forge | n/a | (forge issue #67) | **no**: the lane has no forge credentials; I worked from the brief and SPEC.md |

## What could not be confirmed

1. Whether the i.MX 95 has a voltage-glitch or brown-out detector outside the
   enclave, and what the enclave's own glitch, voltage and frequency detectors
   cover, their thresholds, and whether software or fuses can tune them (F1;
   needs S20, S21).
2. The enclave's side-channel and fault-injection countermeasures and any
   certification of them (F2, F5; needs S21, S23 or a certificate).
3. Whether the boot ROM hardens its own container verification against glitches
   (not in any public source I reached).
4. Whether the CMU thresholds and the reaction to each clock fault on the
   FRDM-IMX95-PRO are set to reset or only to log (S3 assigns the CMUs to the
   System Manager; the per-fault reactions need a closer read of S1 and S3, and
   the tamper survey of #44 covers the mechanism).
5. Whether the Cortex-A55 side has a crypto accelerator with side-channel claims
   (no public source reached names one for the i.MX 95).

## Questions for the owner

1. **Which attacker does `hsm-self-defence` defend against?**
   (a) remote and local software only; (b) also a casual physical attacker
   (probing, debug ports, cold boot); (c) also a lab attacker with fault-injection
   and power/EM analysis equipment.
   Recommendation: (b) as the target, with (c) stated as out of scope until the
   enclave's certification is known (F5). Public sources give no claim for (c)
   and the open crypto libraries disclaim it (S10).
2. **Where may key operations run?**
   (a) only in the enclave; (b) the enclave for long-term keys, software for
   session keys; (c) software allowed where the enclave lacks an algorithm.
   Recommendation: (a) or (b). Software crypto has no power or EM claim (F4,
   S10), and SPEC.md already keeps keys in the enclave.
3. **Should this repository's own security checks (the M7 firmware's, and any it
   adds to the boot path) be hardened against fault injection?**
   (a) no; (b) redundant checks and hardened return values on security-critical
   branches, in the style of MCUboot FIH or OP-TEE's fault mitigation;
   (c) (b) plus a CI fault-simulation test like MCUboot's.
   Recommendation: (b), with (c) later. TF-A and NXP's U-Boot add none (F3, S5,
   S8), so the project's own code is the only place it can be added.
4. **How should the System Manager react to clock-monitor, over- and
   under-temperature, unintended debug or test-mode, and enclave glitch resets?**
   (a) keep NXP's board defaults; (b) treat them as tamper events: reset the
   logical machine or system and record the fault; (c) (b) plus key zeroisation in
   the enclave.
   Recommendation: (b) for `system-manager-config`, and decide (c) with the tamper
   survey of #44, since zeroisation on a false alarm (for example a cold start)
   loses keys.
5. **Should the project get the NXP security documents under NDA?**
   (a) yes, IMX95RM and the Security Reference Manual, so the gaps above can be
   closed; (b) no, stay on public sources and keep the gaps as stated risks.
   Recommendation: (a). Every open point in "What could not be confirmed" needs
   S20 or S21, and SPEC.md already lists both as missing.
6. **Does the project need a certified enclave?**
   (a) yes, and the certificate (scheme and level) is a release criterion;
   (b) no, NXP's description is enough.
   No recommendation: no public source I reached says what NXP holds (F5).
