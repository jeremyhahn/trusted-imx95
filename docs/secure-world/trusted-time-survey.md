# Secure-world trusted time source survey (RTC, secure clock, certificate validity)

> **Status: DRAFT SURVEY** · Row: `secure-world` · Issue #77 · Surveyed: 2026-11-12

## 1. Scope and method

This survey answers issue #77 for the `secure-world` row of [SPEC.md](../SPEC.md): what the board offers for time, how the device should judge certificate validity and token expiry when its clock can be set back, and what go-xkms and go-trusted-platform need from the clock.
It is documentation only: nothing here configures the board, and no fuse, life-cycle or provisioning step is described as a procedure.
It is written from public sources only, read on 2026-11-12, each cited as [Sn] with its version or tag in §7.
Vendor text is summarised, not quoted. Anything the sources did not settle is in §6.

## 2. What the i.MX 95 and the FRDM-IMX95-PRO offer for time

### 2.1 Two real-time clocks, both behind the System Manager

On the i.MX 95 neither real-time clock is reached by Linux directly. Both are owned by NXP's System Manager (SM) on the Cortex-M33 and offered to the other cores through the SM's NXP-specific SCMI Battery-Backed Module (BBM) protocol, protocol 0x81 [S1][S4].

| RTC | Where | SM name and id | Width | Source |
|---|---|---|---|---|
| On-chip BBNSM RTC | In the SoC's battery-backed non-secure module (BBNSM) | `bbnsm`, RTC id 0 | 32-bit seconds, 47-bit ticks | [S1] `devices/MIMX95/sm/dev_sm_bbm.c` |
| Board RTC | NXP PCA2131 on the FRDM board, driven by the SM over I2C | `pca2131`, the first board RTC id after the device RTCs | seconds, calendar fields | [S1] `boards/mcimx95frdm/sm/brd_sm_bbm.c` |

- The SM's FRDM board code switches the PCA2131 into its battery switch-over power mode when the time is set or read, and reads back its time-valid and battery status [S1]. The PCA2131 therefore can keep time on a backup supply. Whether the FRDM-IMX95-PRO is shipped with a coin cell or backup capacitor fitted for it, and what supplies the BBNSM domain when the board is off, are **not confirmed** (§6).
- The BBNSM is, by its name, the *non-secure* part of the battery-backed module [S1]. No public source surveyed describes a separate secure RTC on the i.MX 95 that the A55 secure world can read; the i.MX 95 Security Reference Manual, which would say, is not public (§6).
- The upstream Linux driver `rtc-imx-sm-bbm` registers one RTC and reads, sets and arms an alarm on RTC id 0 only, the BBNSM [S4]. Linux does not see the PCA2131 through it. Both `imx95.dtsi` trees surveyed declare the BBM protocol node under the SCMI firmware node [S2][S3]; neither FRDM device tree declares an I2C RTC node of its own [S2][S3].

### 2.2 Who may set which clock

The SM grants each SCMI agent a permission per RTC in the board configuration file. Setting an RTC's time needs the highest permission (`ALL`, which equals exclusive); arming an alarm needs `PRIV`; notifications need `NOTIFY` [S1] `sm/rpc/scmi/rpc_scmi_bbm.c`, `sm/doc/config.md`. In the surveyed source the time-get and state calls carry no per-agent permission check, unlike set, alarm and notify [S1].

NXP's default FRDM configuration, `configs/mx95frdm.cfg` [S1], grants:

| SCMI agent | Runs | BBNSM RTC | PCA2131 |
|---|---|---|---|
| `M7` (logical machine 1) | Cortex-M7 | `PRIV` (alarm, no set) | `ALL` (may set time) |
| `AP-S` (logical machine 2, secure) | A55 secure world (TF-A, a TEE) | none | none |
| `AP-NS` (logical machine 2, non-secure) | A55 Linux | `ALL` (may set time) | `PRIV` (alarm, no set) |

Consequences for this row:

- With NXP's default configuration, **Linux, the normal world, can set the only RTC Linux reads**, and the A55 secure world has no RTC permission at all. Any root process on Linux can therefore move the device's wall clock backwards.
- The M7, where trusted-firmware's `imx95` row runs, owns the PCA2131 and can set it; Linux can read it but not set it.
- The permissions are configuration, not silicon: this repository owns the SM configuration (`system-manager-config` row), so it can move set permission off `AP-NS`, or give `AP-S` the BBNSM RTC. Whether the SM enforces the grant against a compromised Linux depends on the SM's agent isolation (separate messaging units per agent, [S1] `mx95frdm.cfg`), which this survey takes from the configuration and did not test.

## 3. The enclave's view of time

### 3.1 EdgeLock secure enclave

- NXP's public user-space library for the enclave, `imx-secure-enclave` [S5], exposes no clock, time or timestamp service in its HSM, SHE or common headers. Nothing in it lets a caller ask the enclave for the time, and nothing in it lets a caller hand the enclave a time to bind into a key, certificate or attestation.
- What it does expose is a **device monotonic counter** operation, `hsm_dev_mono_counter` [S5] `include/hsm/internal/hsm_dev_mono_counter.h`. Per its header, it partitions the device's monotonic-counter fuse words between the enclave's HSM and the V2X HSM and SHE; the partition can be written only once per device, and without it no rollback protection is applied. The counter is fuse-backed and is used for key-store rollback protection (SPEC.md `secure-key-handling`). Because each advance burns fuse, it is a small, finite resource: it is **not** suitable as a time ratchet that advances on every boot or every clock check. Configuring it is a provisioning step and is out of this document's scope.
- So the enclave has **no view of wall-clock time** that the public sources show. Whether the enclave firmware itself uses a time internally (for example in attestation evidence) is **not confirmed**; the enclave firmware API reference for the i.MX 95 is not among the public sources reached (§6).

### 3.2 A55 secure world (TF-A, OP-TEE)

The secure world's scope is still the owner's open question (SPEC.md `secure-world`). If it is OP-TEE, its upstream source [S6] gives two kinds of time:

- **System time** (`TEE_GetSystemTime`): read from the Arm generic counter (`core/arch/arm/kernel/tee_time_arm_cntpct.c`). It is monotonic while the A55 cluster runs and restarts from zero at each reset. It cannot be set back by the normal world, but it says nothing about the calendar date.
- **REE time** (`TEE_GetREETime`): fetched from the normal world over the OP-TEE RPC `OPTEE_RPC_CMD_GET_TIME` (`core/kernel/tee_time.c`). It is whatever Linux says, so it can be set back exactly as §2.2 describes.
- OP-TEE has a generic RTC driver framework and an RTC pseudo-TA (`CFG_DRIVERS_RTC`, `CFG_RTC_PTA`), enabled upstream on STM32MP and Microchip SAM platforms; no i.MX platform in the surveyed tree enables an RTC driver [S6]. An OP-TEE on the i.MX 95 has no trusted wall-clock source today, and a driver for the SM's BBM protocol from the secure world (`AP-S`) would have to be written. That also needs the SM configuration change in §2.2.

### 3.3 Cortex-M7

The M7 holds set permission on the PCA2131 in NXP's default configuration (§2.2). If trusted-firmware's `imx95` row keeps a clock, the M7 is the only core that can both own an RTC's set permission and sit outside Linux by default. This is a fact about the default configuration, not a recommendation; the firmware split is the owner's (SPEC.md Release criteria).

## 4. Checking validity when the clock can be set back

### 4.1 The threat

X.509 validity is a window, `notBefore` to `notAfter`, checked against the relying party's current time [S7] (RFC 5280 §4.1.2.5, §6.1.3). JWT `exp` and `nbf` are the same kind of check (go-trusted-platform lists them with ACME windows and DNSSEC signature windows as the things a wrong clock silently breaks [S10] `docs/ntp/architecture.md` §1). A device whose clock an attacker can set back accepts an expired certificate, a revoked certificate whose CRL has not yet "expired", or a replayed token. On this board, with NXP's default SM configuration, the normal world can do this (§2.2). A clock that is simply wrong after a long power-off, with no backup supply, has the same effect without an attacker (§2.1).

### 4.2 Options

| Option | What it gives | What it does not give | Fit on this board |
|---|---|---|---|
| **A. Trust the RTC** | Calendar time at boot, offline | Any protection: Linux can set the BBNSM RTC (§2.2) | Rejected by go-trusted-platform for its own nodes after a node booted two years slow [S10] §2 |
| **B. Monotonic floor (time ratchet)** | The clock is never accepted below the latest trusted time seen: a "not earlier than" floor kept in rollback-protected storage and raised on each authenticated time sample, each verified timestamp token, and the `notBefore` of each certificate verified | Rejecting an *expired* credential still needs a current time, not just a floor; the floor stops the clock going back, not it standing still | The enclave's fuse-backed counter is too scarce to tick per sample (§3.1). The floor would live in a store the enclave protects (its key store or sealed data, whose own rollback protection uses the counter once per strict update, SPEC.md `secure-key-handling`) and be raised rarely, for example once per day or on each enrollment |
| **C. NTS (RFC 8915)** | Authenticated NTPv4: the server is authenticated by TLS 1.3 in NTS-KE, then each NTP packet is integrity-protected with cookies [S8] | Bootstrapping: TLS needs a clock to check the NTS-KE server's certificate; a device with no time cannot check `notAfter`. The usual answer is to skip the time check on that one certificate and pin it, or to accept any time within the floor of option B | go-trusted-platform already runs chrony with NTS on its nodes and issues its NTS-KE server certificate from the platform CA [S10] §3. A device chrony could use it as an NTS client (§5.2) |
| **D. Roughtime** | Signed time from several servers, with a nonce so the answer is fresh; a server that lies can be caught and proven to have lied by chaining requests to several servers [S9] | It is an Internet-Draft, not an RFC (revision 19 at survey date) [S9]; few public servers; precision of seconds, which is enough for validity checks | Needs a Roughtime client on the device and servers it trusts; the server key is a public key the device pins, so no clock is needed to check it. That fixes the NTS bootstrap problem. No Roughtime support was found in go-xkms or go-trusted-platform (§5) |
| **E. Time from the control plane** | The device takes a signed time, or a nonce-bound freshness proof, from go-trusted-platform during attestation or from xkmsd over `hsm-device-protocol` | Makes the device's clock depend on the control plane being reachable; the signer key becomes a time authority | Freshness of attestation is better done with a verifier nonce, which needs no device clock at all (RFC 9334 §10 lists nonces, timestamps and epoch handles as the three freshness models [S11]). Only option E needs no new public server |
| **F. RFC 3161 timestamp tokens** | Proof that data existed at a time, signed by a TSA; validity is judged at the token's time, not now [S12] | Does not give the device a current time; tells it when something was signed | go-xkms already verifies image signatures at the RFC 3161 token's `genTime` rather than at `time.Now()` [S13] `pkg/image/timestamp.go`. This is the right model for checking boot-image and code signatures on a device whose clock is not trusted |

### 4.3 What the sources support

- The two checks have different needs. **"Was this signature made while the certificate was valid?"** does not need a trusted current time: an RFC 3161 token, or a monotonic floor, answers it (options B, F). **"Has this certificate or token expired now?"** needs a trusted current time; only an authenticated time source (options C, D, E) gives it.
- A floor (B) is cheap and stops set-back attacks for both checks. It needs no network and no new server, and it composes with any of C, D or E.
- No hardware source on the board gives the secure world a time the normal world cannot set, with NXP's default SM configuration (§2.2, §3.2). The SM configuration is this repository's; giving the RTC's set permission to the secure world or the M7 alone makes the RTC at least as trustworthy as the agent that sets it, but it still loses time without a backup supply.

## 5. What go-xkms and go-trusted-platform need from the clock

### 5.1 go-xkms (surveyed at `main` commit `d55b1b7`, 2026-11-11 [S13])

- It verifies certificate chains with `x509.VerifyOptions.CurrentTime` set to the host's `time.Now()` in its CA, certificate store and attestation-evidence paths (for example `pkg/ca/verification.go`, `pkg/certstore/composite_certstore.go`, `pkg/attestation/verifier.go`) [S13]. On the board, xkmsd runs on the Linux side (SPEC.md Purpose), so these checks read the Linux clock, which §2.2 shows the normal world can set.
- It verifies signed images at the RFC 3161 token's `genTime` (`pkg/image/timestamp.go`, `pkg/image/verifier.go`) [S13]: this needs no trusted current time, only a trusted TSA root.
- Its OIDC client validates JWTs with one minute of leeway (`pkg/oidc/client.go`) [S13]: it needs a current time within about a minute.
- Its CA backdates `notBefore` to absorb clock skew between issuer and relying party (`docs/certificate-authority/engineering.md`) [S13], so a device clock a little slow does not reject a fresh certificate.
- Its CRL numbers are monotonic per issuer and not derived from wall-clock time (same document) [S13]; a device can use the CRL number to refuse an older CRL without a clock.
- go-xkms's `hsm-device-protocol` is not yet written: it is the owner's open question (SPEC.md `hsm-device-protocol`, go-xkms #1521). Whether it carries time or a freshness nonce to the device is therefore **not confirmed**.

### 5.2 go-trusted-platform (surveyed at `main` commit `641fd51`, 2026-11-11, latest tag `v0.1.0-alpha` [S10])

- It treats time as a trust primitive: it runs chrony (not its own NTP code), configures it from its `ntp:` section, and can serve NTS with an NTS-KE certificate it issues from its own platform CA (`docs/ntp/architecture.md` §2, §3) [S10].
- It gates TPM and CA initialisation on clock sync at startup, warns by default and fails only by policy; it allows clock steps only for the first three updates and flags later large steps as anomalies (§2) [S10].
- Its attestation report records `time_synced` per device, with an absent value when the device's clock could not be read; it reads node clock state from `GET /api/v1/attestation/clock` (§2, §3) [S10].
- Read together, what it would need from this device: (a) a clock that is NTP- or NTS-disciplined before trust decisions run; (b) a readable sync state, so the attestation collector can fill `time_synced`; (c) no silent large steps after sync. Whether the device side of `hsm-device-lifecycle` must expose the same clock endpoint is not stated in the surveyed sources and is **not confirmed**.

## 6. Not confirmed

- Whether the FRDM-IMX95-PRO ships with a coin cell or backup capacitor for the PCA2131, and what powers the BBNSM domain when the board is off. The board user manual (UM12527) and schematic would say; they were not read for this survey.
- Whether the i.MX 95 has a secure RTC (in the secure part of the battery-backed module, or in the enclave) that the A55 secure world can read. The i.MX 95 Reference Manual (IMX95RM) and Security Reference Manual are not public (SPEC.md lists both as missing).
- Whether the EdgeLock enclave firmware keeps or uses time internally, for example in attestation evidence. The enclave firmware API for the i.MX 95 was not among the public sources reached; the public user-space library shows no time interface (§3.1).
- How many monotonic-counter fuse words the i.MX 95 has, and so how many rollback updates are possible over the device's life.
- Whether the SM's agent isolation holds against a compromised Linux, so that removing `AP-NS` set permission really prevents set-back. Taken from the configuration, not tested.
- Whether NXP's 2026 BSP enables an OP-TEE RTC driver for the i.MX 95 in its own `imx-optee-os` fork; only upstream OP-TEE was surveyed.
- The content of go-xkms's `hsm-device-protocol` and of go-trusted-platform's `hsm-device-lifecycle` device side: not yet written.
- Public Roughtime servers' availability and keys: not surveyed.

## 7. Sources

All read on 2026-11-12. Repository sources give the branch, tag or commit surveyed.

| Id | Title | Version | URL |
|---|---|---|---|
| S1 | NXP System Manager (imx-sm): `configs/mx95frdm.cfg`, `devices/MIMX95/sm/dev_sm_bbm.c`, `boards/mcimx95frdm/sm/brd_sm_bbm.c`, `sm/rpc/scmi/rpc_scmi_bbm.c`, `sm/doc/config.md` | default branch commit `eec2328` (2026-09-03, tag `android-17.0.0_1.0.0`); latest release tag `rel_imx_sm_2026q3` | https://github.com/nxp-imx/imx-sm |
| S2 | NXP Linux kernel: `arch/arm64/boot/dts/freescale/imx95.dtsi`, `imx95-15x15-frdm.dts` | branch `lf-6.12.y` | https://github.com/nxp-imx/linux-imx |
| S3 | Linux kernel: `arch/arm64/boot/dts/freescale/imx95.dtsi`, `imx95-15x15-frdm.dts` | `master` after tag `v7.3` | https://github.com/torvalds/linux |
| S4 | Linux kernel: `drivers/rtc/rtc-imx-sm-bbm.c` | `master` after tag `v7.3` | https://github.com/torvalds/linux/blob/master/drivers/rtc/rtc-imx-sm-bbm.c |
| S5 | NXP EdgeLock secure enclave library (imx-secure-enclave): `include/` | default branch commit `d7e1180` (2026-06-09) | https://github.com/nxp-imx/imx-secure-enclave |
| S6 | OP-TEE OS: `core/kernel/tee_time.c`, `core/arch/arm/kernel/tee_time_arm_cntpct.c`, `core/drivers/rtc/`, `core/arch/arm/plat-*/conf.mk` | `master` commit `3a19c71` (2026-11-11), after tag `4.9.0-rc1` | https://github.com/OP-TEE/optee_os |
| S7 | RFC 5280, Internet X.509 PKI Certificate and CRL Profile | May 2008 | https://www.rfc-editor.org/rfc/rfc5280 |
| S8 | RFC 8915, Network Time Security for the Network Time Protocol | September 2020 | https://www.rfc-editor.org/rfc/rfc8915 |
| S9 | Roughtime, draft-ietf-ntp-roughtime | revision 19 (2026-10-05) | https://datatracker.ietf.org/doc/draft-ietf-ntp-roughtime/ |
| S10 | go-trusted-platform: `docs/ntp/architecture.md` (Last verified 2026-08-18), `pkg/ntp`, `pkg/app/nts_provision.go` | `main` commit `641fd51` (2026-11-11); tag `v0.1.0-alpha` | https://github.com/jeremyhahn/go-trusted-platform |
| S11 | RFC 9334, Remote ATtestation procedureS (RATS) Architecture, §10 Freshness | January 2023 | https://www.rfc-editor.org/rfc/rfc9334 |
| S12 | RFC 3161, Internet X.509 PKI Time-Stamp Protocol (TSP) | August 2001 | https://www.rfc-editor.org/rfc/rfc3161 |
| S13 | go-xkms: `pkg/image/timestamp.go`, `pkg/image/verifier.go`, `pkg/ca/verification.go`, `pkg/certstore/composite_certstore.go`, `pkg/attestation/verifier.go`, `pkg/oidc/client.go`, `docs/certificate-authority/engineering.md` | `main` commit `d55b1b7` (2026-11-11) | https://github.com/jeremyhahn/go-xkms |

Unreachable or not read: the i.MX 95 Reference Manual and Security Reference Manual (not public); the EdgeLock enclave firmware API reference for the i.MX 95 (not found publicly); the FRDM-IMX95 board user manual and schematic (not read for this survey); NXP's `imx-optee-os` fork (not surveyed).

## 8. Questions for the owner

1. **Who may set the board's RTCs?** Options: (a) keep NXP's default, Linux (`AP-NS`) sets the BBNSM RTC and the M7 sets the PCA2131; (b) give BBNSM set permission to the A55 secure world (`AP-S`) only, Linux read-only; (c) give set permission to the M7 only, for both RTCs. *Recommendation:* (b) if the secure world is OP-TEE on the A55, (c) if trusted-firmware's M7 firmware is the trusted core; either way not (a), because under (a) any root process can set the clock back (§2.2). This depends on the open `secure-world` scope question.
2. **What is the device's trusted time source?** Options: (a) the RTC alone; (b) NTS from go-trusted-platform's chrony NTS server; (c) Roughtime from servers the device pins; (d) a signed time or nonce from the control plane over `hsm-device-protocol` or `hsm-device-lifecycle`. *Recommendation:* (b), since go-trusted-platform already serves NTS and issues its NTS-KE certificate (§5.2), with the NTS-KE certificate checked against the floor of question 3 at boot; (c) as an alternative if the device must not depend on the control plane. Not (a) (§4.2 A).
3. **Should the device keep a rollback-protected time floor?** Options: (a) no floor; (b) a floor in enclave-protected storage, raised at enrollment and periodically, never per sample; (c) a floor ticked on the fuse-backed monotonic counter. *Recommendation:* (b): it stops set-back attacks offline and bootstraps NTS. Not (c), because the counter is fuse-backed and finite (§3.1).
4. **How should signature checks that need no current time be made?** Options: (a) check every certificate at the device's current time; (b) check code and image signatures at an RFC 3161 token's time, and CRLs by CRL number, and keep current-time checks for expiry only. *Recommendation:* (b), as go-xkms already does for images (§5.1).
5. **Attestation freshness:** Options: (a) the device timestamps its evidence; (b) the verifier sends a nonce. *Recommendation:* (b): it needs no device clock (RFC 9334 §10, [S11]). go-trusted-platform's `time_synced` field still reports the clock's state beside the verdict (§5.2).
6. **What happens when the clock is unsynced?** Options: (a) warn and continue, as go-trusted-platform's default; (b) refuse expiry-dependent operations (issuing, verifying expiry) until synced, but keep serving key operations; (c) refuse to start. *Recommendation:* none from the sources for an HSM device; (b) is the reversible middle and the one this survey would propose.
7. **Battery backup:** should the product require a fitted backup supply for the PCA2131? Options: (a) yes; (b) no, the device always takes time from the network at boot. *Recommendation:* none until the board's power design is confirmed (§6).
