# system-manager-config — architecture

> **Status: NORMATIVE** · Scope: trusted-imx95 `system-manager-config` · Last verified: 2026-11-12
> The detail of the `system-manager-config` row of [SPEC.md](../SPEC.md). Conflicts with SPEC.md are defects in this file.

Every statement below cites a document and section listed in [references/README.md](../references/README.md).
A fact the documents do not give is under [Missing](#missing); a choice the owner has not made is under
[Open questions](#open-questions). No configuration value appears here that the references do not give.

## Problem

NXP's System Manager runs on the Cortex-M33 and stays NXP's code; this repository holds only its configuration
([SPEC.md](../SPEC.md), Boundaries). The configuration must give the Cortex-M7 firmware of trusted-firmware's
`imx95` row its clocks, power and resources through SCMI, and the power domains and PHYs that the
`hsm-self-defence` row acts on ([SPEC.md](../SPEC.md), `system-manager-config` row). That firmware, its board
profile and its use of these resources are trusted-firmware's `imx95` row and are not restated here.

## The cores and the System Manager

- The i.MX 95 on the FRDM-IMX95-PRO has six Cortex-A55, one Cortex-M33, one Cortex-M7, the EdgeLock secure
  enclave and the NPU (UM12527 §1.2, §2.1).
- The board boots on the Cortex-M33 (UM12527 §2.3 Table 7), the core the System Manager runs on
  ([SPEC.md](../SPEC.md), Boundaries).
- The per-core debug UARTs are on J22, and their port mapping is not fixed (UM12527 §2.19).
- The processor data sheet gives electrical, pin and package facts and refers to IMX95RM for the programming
  model (IMX95CEC; [references/README.md](../references/README.md), "NXP documents"). The clocks, power domains
  and resources the System Manager controls are therefore not given by any document in the references (see
  [Missing](#missing)).

## What the Cortex-M7 needs from it

- Clocks, power and resources, requested through SCMI ([SPEC.md](../SPEC.md), `system-manager-config` row). Which
  SCMI protocols, agents, channels and resource assignments the System Manager exposes, and their names and
  identifiers, are in the System Manager documentation and IMX95RM, both missing (see [Missing](#missing)). No
  value is configured here until they are obtained.
- The precise set of resources the Cortex-M7 firmware requests is trusted-firmware's `imx95` row
  ([SPEC.md](../SPEC.md), Boundaries); this file links to it and does not restate it.

## Power domains and PHYs

- The board's network interfaces are its two 1 GbE ports and a 10 GbE expansion card on the Slim-SAS connector
  (UM12527 §1.2 Table 1, §2.18). Which PHYs serve them, as the System Manager sees them, is not given (see
  [Missing](#missing)). The 10 GbE card is not in the board kit and its documentation is
  missing ([SPEC.md](../SPEC.md), `hsm-device-protocol` row).
- The `hsm-self-defence` response acts through the System Manager on power domains and PHYs, and through the
  enclave on key zeroisation and shutdown ([SPEC.md](../SPEC.md), `hsm-self-defence` row). Which power domain
  feeds which PHY or block, and how the System Manager switches it off, are not given (see [Missing](#missing)).

## Boundaries

- The System Manager is never replaced; only its configuration lives here ([SPEC.md](../SPEC.md), Boundaries).
- The Cortex-M7 firmware and its `frdm-imx95-m7` board profile are trusted-firmware's `imx95` row
  ([SPEC.md](../SPEC.md), Boundaries); the firmware split is open for the owner ([SPEC.md](../SPEC.md), Release
  criteria).
- The `hsm-self-defence` row is blocked on go-xkms and go-quicbaas and is only named here
  ([SPEC.md](../SPEC.md), Features).
- The CompuLab UCM-iMX95 material is reference only and is not cited for this device
  ([references/README.md](../references/README.md), "The device").

## M7 grant delta (patch 0002)

> **Proposed, pending owner approval (#13).** This section is the requirement and the acceptance criteria of
> [`system-manager/patches/0002-m7-no-test-grants.patch`](../../system-manager/patches/0002-m7-no-test-grants.patch).
> It belongs to the same `system-manager-config` row as the fault reactions; it is not a separate change.

### Requirement

In the shipped configuration the M7 logical machine (`SCMI_AGENT0 name="M7"`, LM1) holds no test-only grant. Patch 0002
removes exactly these, and nothing outside the M7 block:

- the `test=8` key of the M7 `MAILBOX` line (`type=mu, mu=9, priority=high` stays);
- the `BRD_SM_CTRL_TEST` grant;
- the `BRD_SM_CTRL_TEST_A` grant;
- the `test` key of `LPUART3`; the `OWNER` grant on `LPUART3` is kept, so the M7 keeps the UART;
- the `PD_M7 test` grant.

Kept: `CHANNEL db=0 ... type=a2p, test=default`. The configuration tool needs a default test channel, so it stays; it
is the one `test` key allowed in the M7 block. The reasons for removing the others, and for what the M7 keeps, are in
[scmi-permissions-survey.md](scmi-permissions-survey.md) §3.1 (production builds carry no `test` keys or test-only
APIs) and §3.2 (the M7's own grants table). The survey's §3.2 names the `test` keys as an S1 reference; the patched
file is the PRO file, and the allowlist below is what was checked against it.

### Acceptance criteria

1. The M7 block of the patched `mx95frdm-pro.cfg` equals the reviewed allowlist
   [`system-manager/m7-grants.txt`](../../system-manager/m7-grants.txt), line for line, checked by
   `scripts/sm-grants-check.sh` in every `scripts/sm-build.sh` build. A widened grant fails the build.
2. The M7 block holds no `test` key other than `CHANNEL test=default` and no `BRD_SM_CTRL_TEST*` grant: the allowlist
   has none, and the same script and `sm-build.sh` refuse to build otherwise.
3. `LPUART3 OWNER` is in the allowlist, so the M7 keeps its UART.
4. Patch 0002 touches only M7 block lines, each removed line carries `test` or `BRD_SM_CTRL_TEST`, each added line is a
   removed one without the key, and no `Faults`, `SYS` or `LMM_2` line changes: asserted offline by
   `test/sm_build_test.sh`, which also checks that the grants check fails on a fake M7 block that widens a grant.
5. The patch is pinned: `sm.lock` carries its hash in `sm_patch_sha256` (0001 then 0002) and the patched file's hash in
   `sm_patched_config_sha256`; `scripts/sm-build.sh` refuses to build on a mismatch.
6. Two `make system-manager` builds produce a byte-identical `m33_image.bin`.

### Revert

If the owner rejects this delta: drop patch 0002, its entry in `sm.lock`, and the grants check
(`scripts/sm-grants-check.sh` with `system-manager/m7-grants.txt`); the build then runs on 0001 alone.

## Missing

- The System Manager documentation: its configuration format, its SCMI protocols, agents and channels, and how a
  resource is assigned to the Cortex-M7 ([SPEC.md](../SPEC.md), `system-manager-config` row).
- IMX95RM: the clock tree, the power domains, and which domain feeds each PHY and block
  ([references/README.md](../references/README.md), "Still missing").
- The NXP Linux BSP documentation: how the Cortex-A55 side shares System Manager resources with the Cortex-M7.
- The EdgeLock tamper pins ([SPEC.md](../SPEC.md), `hsm-self-defence` row).
- The 10 GbE expansion card documentation ([SPEC.md](../SPEC.md), `hsm-device-protocol` row).
- This digest was written from the citations already in [SPEC.md](../SPEC.md) and
  [references/README.md](../references/README.md), without read access to the private vendor context
  repository. A reader with access deepens each section from UM12527, citing the section.

## Open questions

- The firmware split between this repository and trusted-firmware's `imx95` row: the owner's decision
  ([SPEC.md](../SPEC.md), Release criteria).
- Whether the Cortex-A55 side of `hsm-self-defence` is built here: the owner's decision
  ([SPEC.md](../SPEC.md), `hsm-self-defence` row).
