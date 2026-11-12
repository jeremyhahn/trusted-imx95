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
- Life cycles past OEM Closed (for example a locked or field-return state) are named in
  NXP's ELE documents for other parts, but the lane found no public i.MX 95 source that
  defines them: unconfirmed.

## 5. Authenticated debug in a closed part

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

## 6. Software-side controls (System Manager, TF-A, OP-TEE, U-Boot, Linux)

TODO

## 7. What could not be confirmed

TODO

## 8. Questions for the owner

TODO
