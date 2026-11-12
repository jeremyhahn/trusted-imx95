# System Manager monitor and log output: survey

Row: `system-manager-config` ([SPEC.md](../SPEC.md)). Issue #127. Documentation only.

Status: draft survey from public sources. No keys, fuses, life-cycle or
provisioning steps are run or scripted here.

## 1. Sources

All sources are public. Paths are inside the source tree of the tag named.

| Id | Title | Version | URL |
|----|-------|---------|-----|
| S1 | NXP i.MX System Manager source (`nxp-imx/imx-sm`) | tag `rel_imx_sm_2026q3`, commit `eec23287`, committed 2026-09-03 | https://github.com/nxp-imx/imx-sm |
| S2 | SM user guide chapter "Monitor" (`sm/doc/monitor.md` in S1) | as S1 | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/monitor.md |
| S3 | SM user guide chapter "Debug" (`sm/doc/debug.md` in S1) | as S1 | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/sm/doc/debug.md |

| S4 | SM user guide chapters "Development" (`sm/doc/dev.md`), "Additional Notes" (`sm/doc/rn_add.md`), "Change log" (`sm/doc/rn_cl.md`, item SM-399), "Porting" (`sm/doc/port.md`), "Implementation" (`sm/doc/imp.md`), "Configuration" (`sm/doc/config.md`) | as S1 | https://github.com/nxp-imx/imx-sm/tree/rel_imx_sm_2026q3/sm/doc |
| S5 | SM build files: top-level `Makefile`, `sm/makefiles/gcc_cross.mak`, `sm/makefiles/configtool.mak`, `sm/utilities/monitor/Makefile`, `configs/mx95frdm/config.mak` | as S1 | https://github.com/nxp-imx/imx-sm/tree/rel_imx_sm_2026q3 |
| S6 | SM configuration `configs/other/mx95frdm-pro.cfg` | as S1 | https://github.com/nxp-imx/imx-sm/blob/rel_imx_sm_2026q3/configs/other/mx95frdm-pro.cfg |
| S7 | NXP Yocto BSP layer `meta-imx`, recipe `meta-imx-bsp/recipes-bsp/imx-system-manager/` (`imx-system-manager.inc`, `imx-system-manager_2026q3.bb`) | branch `wrynose-6.18.37-2.1.0`, commit `2eb758f4`, committed 2026-11-10; the recipe pins imx-sm `eec23287` (the S1 commit) | https://github.com/nxp-imx/meta-imx/tree/wrynose-6.18.37-2.1.0/meta-imx-bsp/recipes-bsp/imx-system-manager |
| S8 | `meta-imx` machine configuration `meta-imx-bsp/conf/machine/imx95-19x19-lpddr5-frdm-pro.conf` | as S7 | https://github.com/nxp-imx/meta-imx/blob/wrynose-6.18.37-2.1.0/meta-imx-bsp/conf/machine/imx95-19x19-lpddr5-frdm-pro.conf |

Line numbers quoted below are at these versions. The C sources of S1 were
not read for this survey (the lane could read build files and documentation
only); claims about code behaviour rest on the SM's own documentation and
build files and are marked where they are inference.

## 2. What the debug monitor exposes

The System Manager (SM) runs on the Cortex-M33. When it is built with the
monitor, it offers a command line on the SM debug UART (S2). The commands fall
into these groups (S2, summarised; the command names are the SM's own):

| Group | What it lets the person at the UART do |
|-------|----------------------------------------|
| General | list commands, leave the monitor, busy-wait with interrupts optionally off |
| Info | print SoC and SM identity (including the unique ID), DDR regions, EdgeLock (ELE) firmware version and life cycle, ELE extended info and a raw ELE debug dump, V2X status, the logged SCMI and TRDC errors, boot timing, raw and decoded TRDC (access-controller) dumps, the syslog, GCOV data |
| System | read the reset reason; shut down or reset the whole system; set the next boot stage (primary, secondary, recovery, serial download) and reset; suspend and wake all logical machines (LMs); set the system sleep mode; reconfigure, disable or trigger the watchdog; inject a fault; force an assert |
| Logical machine | list LMs, change the default LM, boot, shut down, reset, suspend, wake or power any LM, read its reset reason |
| Group | boot, shut down or reset a configured group of LMs |
| Resource (power and clock control) | read and set power domain states, performance (DVFS) levels, clock enable, parent, rate and extended settings, reset clocks; read and enable sensors; assert or release reset lines; read and set voltages; read and set the battery-backed RTCs and general-purpose registers; read CPU state and start, hold, stop any CPU or change its boot vector; read and write SM "controls" |
| Data read/write (register access) | read and write any 8-, 16- or 32-bit address the M33 can reach |
| Fuse | read fuse words; write (burn) fuse words; read and write fuse shadow registers |
| Board | read and write PMIC registers over I2C; call a board-defined custom hook |

In short, the monitor is an unauthenticated root console for the whole SoC: it
runs with the SM's own privilege on the M33, so the TRDC access policy the SM
imposes on the other cores does not restrict it (inference from S2 and S3:
the SM programs the TRDC, S3 "Hardware Access Issues"). Through `mm`, `cpu.w
... vector`, `fuse.w`, `stage serial` and `wdog off` it can rewrite memory,
redirect another core's boot, burn fuses, force serial download and disable
the watchdog. Through `md`, `info`, `ele info`, `ele dump`, `trdc` and `fuse.r`
it discloses the unique ID, life cycle, fuse contents, the isolation policy and
any memory the M33 can read.

The SM's own documentation says that the monitor changes SM timing, must never
be deployed in a product, and that "no monitor" is the only valid production
setting (S2).

## 3. How the monitor and logs are enabled or compiled out

### 3.1 The `M` make variable

The monitor is chosen at build time by the make variable `M` (or `m`) in the
top-level `Makefile` of S1 (lines 67-79 and 150-153 at the tag):

| `M` | Effect (S1 `Makefile`, S2) |
|-----|-----------------------------|
| `0` | No monitor. `monitor.o`, `monitor_cmds.o` and `monitor_trdc.o` (S1 `sm/utilities/monitor/Makefile`) are not added to the link, and `MONITOR` is not defined. |
| `1` | **The default when `M` is not given.** Monitor compiled in; the SM enters it straight after boot. |
| `2` | Monitor compiled in; entered when a character arrives on the debug UART. |

Any non-zero `M` also has side effects in the same `Makefile` (S1, lines
72-76 and 160-164): it defines `MONITOR`, turns on `INC_LIBC` (the C library
is linked) and `TEST_MODE`, and `TEST_MODE` pulls in the test wrappers from
`sm/test/wrap`. So `M=0` removes more than the console: it also removes the
test-mode wrappers and the libc link, unless those are asked for separately
(`T=<test>` sets them again, lines 51-59).

The SM boot flow calls the monitor last, after the LMs are started, only when
it is included (S1 `sm/doc/imp.md`, "Boot flow"). The SM then idles in WFI.

Because `M` defaults to 1, **a build that does not name `M=0` ships the
monitor.** This is the single most important finding of this survey.

### 3.2 Other build switches that matter for production

From the same top-level `Makefile` (S1):

- `T=<test>` builds a unit test into the image, defines `DEBUG`, `INC_LIBC`
  and `TEST_MODE`. A production build must leave `T` unset (`T=NONE`).
- `DEBUG=1` defines `DEBUG`. Default 0.
- `GCOV`: the gcov dump utility (`sm/utilities/gcov_dump`) and the
  `--coverage` compile flags are used whenever `GCOV` is not `0`. The cross
  toolchain makefile sets `GCOV ?= 0` (S1 `sm/makefiles/gcc_cross.mak`
  line 90), so by the time the top-level `Makefile` tests it (line 144) an
  unset `GCOV` means "off". One test in `gcc_cross.mak` (line 47, which adds
  `-lgcov --coverage` to the link flags) is parsed before line 90, so with
  `GCOV` unset it appears to add those link flags anyway. That is a reading of
  the parse order only, not confirmed by a build; it adds no `-DGCOV` code,
  and the linker's `--gc-sections` should drop unused library code. A
  production build should pass `GCOV=0` explicitly so the question does not
  arise.
- `INC_LIBC=0` (the default when `M=0` and no test) defines `NDEBUG` and
  links only minimal `memset`/`memcpy` instead of newlib (S1
  `gcc_cross.mak` lines 53-62).
- `R=1` (default) defines `RDC`, so the SM programs the TRDC. A production
  build keeps the default.
- `V=1` only makes the build verbose; it does not change the image.

### 3.3 Debug UART and printed output

The SM's debug UART and its baud rate are set per board configuration
(`BOARD_DEBUG_UART_INSTANCE`, `BOARD_DEBUG_UART_BAUDRATE`; S1
`sm/doc/config.md`). On the i.MX 95 FRDM port the SM owns LPUART2, which goes
to an FTDI USB-serial bridge (S1 `sm/doc/port.md`, "NXP i.MX95 FRDM"). The
FRDM board configuration is `mx95frdm`, board `mcimx95frdm`, and its
`config.mak` sets `USES_FUSA ?= 1` (S1 `configs/mx95frdm/config.mak`).

Output the SM prints on that UART independent of the monitor, per S1 docs:

- a "Hello" banner with build number, commit and build date at boot (S3,
  "Boot Debug"; S1 `sm/doc/imp.md`);
- boot errors (`Init error: <code>`) (S3);
- reset and shutdown records, printed when the event happens, by the board
  port's `BRD_SM_FaultReactionGet()` and `BRD_SM_ResetRecordPrint()` (S1
  `sm/doc/port.md`, "Reset Record Output"). For an M33 exception these carry
  the M33 program counter, fault status registers and faulting address (S3,
  "Reset Debug");
- fault and exception messages "asynchronously" (S2).

### 3.4 What NXP's BSP builds by default

NXP's Yocto recipe passes `M=${SYSTEM_MANAGER_MONITOR_MODE}` and sets that
variable with a weak default of `2` (`??= "2"`) (S7 `imx-system-manager.inc`).
It also passes `V=1`, so the full compiler command lines are in the build log.
So **the stock NXP BSP image ships the monitor**, entered when a character
arrives on the SM debug UART. Any assignment of
`SYSTEM_MANAGER_MONITOR_MODE` in a machine, distro or local configuration
overrides the weak default.

For the FRDM-IMX95-PRO, the BSP machine file selects the SM configuration
`mx95frdm-pro` (S8). At S1 that configuration exists only as
`configs/other/mx95frdm-pro.cfg` (S6), not as `configs/mx95frdm-pro.cfg`,
while the SM's `cfg` target reads `./configs/$(CONFIG).cfg` (S5
`configtool.mak`). How the BSP build finds it was not confirmed (see 6). The
file sets the SM debug UART to instance 2 at 115200 baud (S6, "Board"); its
header comment and its `MAKE` line still name the i.MX95 EVK and board
`mcimx95evk` (S6), which suggests it was derived from the EVK configuration.

## 4. What a production build must remove, and how the build proves it

### 4.1 What must go

| Item | Why | Source |
|------|-----|--------|
| The debug monitor (`M=0`) | Unauthenticated control of power, clocks, resets, CPUs, memory and fuses (section 2); NXP says `M=0` is the only valid production setting | S2, S4 `dev.md`, S4 `rn_add.md` |
| Test code and function wrappers (`TEST_MODE`) | NXP's change log says non-production builds, the default, carry test code and function wrappers, which must be disabled with `M=0` | S4 `rn_cl.md` SM-399; S5 `Makefile` lines 72-76, 160-164 |
| Unit tests (`T` unset) | `T=<test>` replaces the normal boot with a test run and re-enables `TEST_MODE`, `DEBUG` and libc | S5 `Makefile` lines 47-65 |
| Coverage (`GCOV=0`) | NXP documents gcov as simulation only | S4 `dev.md`; S5 `gcc_cross.mak` |
| The C library (`INC_LIBC=0`, follows from `M=0`) | NXP says turning the monitor off removes the C library link | S4 `rn_add.md`; S5 `gcc_cross.mak` lines 53-62 |
| `DEBUG` unset | Defines `DEBUG`; production should not | S5 `Makefile` lines 78-83 |

What stays: the reset-record printing and boot banner are not tied to `M`
in the build files read (S5), so they are expected to remain in an `M=0`
build (see section 5). Whether any other UART input path exists with
`M=0` was not confirmed (section 6).

### 4.2 How the build can prove it

These are checks this repository can add to its SM build. None is provided
by NXP as a production gate; they follow from S5 and S7.

1. **Pin the variables.** Set `SYSTEM_MANAGER_MONITOR_MODE = "0"` (hard
   assignment, not `?=`) in the product's distro or machine layer, and pass
   `GCOV=0`, no `T`, no `DEBUG`. A Yocto sanity check (an anonymous Python
   function or `do_compile:prepend`) can fail the build if the value is not
   `0`.
2. **Check the compile lines.** With `V=1` (S7) the log shows the flags.
   It must contain `-DMONITOR_MODE=0` and `-DNDEBUG`, and must not contain
   `-DMONITOR `, `-DTEST_MODE`, `-DRUN_TEST`, `-DDEBUG`, `-DGCOV` or `-lc`.
3. **Check the link map.** `gcc_cross.mak` always writes
   `build/<config>/m33_image.map` (S5, line 155). It must not list
   `monitor.o`, `monitor_cmds.o`, `monitor_trdc.o`, `gcov_dump.o` or any
   object from `sm/test/`.
4. **Check the ELF symbols.** `arm-none-eabi-nm` on `m33_image.elf` must
   show no `MONITOR_` symbols and no test-wrapper or `TEST_` symbols. (The
   symbol prefixes are taken from S4 `imp.md`, which names
   `MONITOR_Cmd()`, `TEST_Config()` and `TEST()`; other names were not
   confirmed.)
5. **Check the binary strings.** The monitor prompt banner and the command
   names (`fuse.w`, `mm.l`, `cpu.w`) should not appear in `m33_image.bin`.
   The banner text shown in S3 ("Boot Debug") is the one to search for.
6. **Record it.** Keep the map file, the `nm` listing and the flag check
   with the release, next to the hash of the signed boot container, so the
   claim "no monitor" can be checked later against the image that shipped.

Checks 2 to 5 have not been run here: this lane builds nothing.

## 5. Where System Manager logs go in production, and what they reveal

### 5.1 Destinations

- **The SM debug UART.** On the FRDM-IMX95-PRO configuration this is
  LPUART2 at 115200 baud (S6), which NXP's FRDM port routes to an on-board
  USB-serial bridge (S4 `port.md`, "NXP i.MX95 FRDM"; that text is for the
  FRDM, and is assumed, not confirmed, to hold for the PRO board). The SM
  owns this UART exclusively in NXP's ports. With `M=0`, the boot banner,
  boot errors and reset and fault records are still printed here (S3,
  S4 `port.md` "Reset Record Output"), as far as the documentation and
  build files show.
- **Persistent storage.** Shutdown records are saved by
  `BRD_SM_ShutdownRecordSave()` in the battery-backed BBNSM general-purpose
  registers GPR0-3 on the FRDM port, and NXP says other agents must not be
  given access to them (S4 `port.md`, "NXP i.MX95 FRDM").
- **SCMI, to the other cores.** Any agent the configuration permits can read
  the reset reasons (`SCMI_MiscResetReason()`, `SCMI_LmmResetReason()`), the
  syslog (`SCMI_MiscSyslog()`) and LM status (`SCMI_LmmAttributes()`) (S3).
  So in production the logs reach Linux on the A55 and the M7 firmware, not
  just the UART.
- **In-RAM error log.** The SM keeps the first SCMI error per agent and the
  TRDC keeps the first bus error per domain until cleared (S3,
  "Configuration Debug"). With `M=0` the monitor's `err` command that shows
  them is gone; whether another path reads them was not confirmed.

### 5.2 What they may reveal

- Build number, source commit and build date of the SM (banner, S3).
- On an M33 exception: the M33 program counter, fault status registers and
  faulting address (S3, "Reset Debug"). With the public map file of a known
  build this locates the fault in the code, which helps an attacker who is
  glitching or fuzzing the SM to see where it went.
- ELE group resets with their status registers. NXP says these come from
  ELE aborts and glitch, voltage or frequency detectors (S3). A printed or
  readable ELE reset tells an attacker that a fault-injection attempt was
  detected, which is feedback for tuning the attempt.
- Which agent asked for a reset or shutdown, watchdog and FCCU fault ids,
  PMIC fault flags, temperature faults (S3).
- The syslog's power and sleep state and the device init error word (S3).
- The denied SCMI calls and TRDC violations, which map out the isolation
  policy (S3).

No key material or fuse values are listed among the logged fields in S3; but
the C sources were not read, so that is not confirmed beyond the
documentation.

## 6. Not confirmed

1. **C-level behaviour with `M=0`.** The SM C sources (S1) were not read.
   Whether every print path survives `M=0`, whether any UART input is read
   with `M=0`, and whether `MONITOR_MODE=0` leaves any monitor code in other
   objects, rest on S2-S5 only.
2. **How the BSP finds `mx95frdm-pro`.** S8 sets `SYSTEM_MANAGER_CONFIG =
   "mx95frdm-pro"`, but at S1 the file is under `configs/other/` and the
   `cfg` target reads `configs/<config>.cfg` (S5). A step that copies or
   points to it was not found in the parts of S7 read.
3. **The `GCOV` parse-order effect** in `gcc_cross.mak` (3.2) is a reading of
   the makefile, not a build result.
4. **Whether the FRDM port text applies to the FRDM-IMX95-PRO** (LPUART2 to
   USB-serial, BBNSM GPR0-3 records). S6 names board `mcimx95evk`; the
   PRO board's own SM board port was not identified.
5. **Whether the SM debug UART can be turned off entirely** (no output) by
   configuration. No such option was found in S4 or S5.
6. **The SCMI permissions in `mx95frdm-pro.cfg`** for the misc protocol
   (syslog, reset reason) per agent were not audited.
7. **NXP's i.MX 95 reference manual and security reference manual** were not
   consulted (not public, and listed as missing in SPEC.md); anything they
   say about the M33 debug UART or production lock-down is not covered here.

## 7. Questions for the owner

1. **Monitor mode for the product image.**
   Options: (a) `M=0` in every image that leaves the bench; (b) `M=2` in
   development images only, `M=0` in release, with separate build
   configurations; (c) keep `M=2` and rely on the UART not being reachable.
   Recommendation: (b), with release images forced to `M=0` by a hard
   assignment and a build check. NXP says `M=0` is the only valid production
   setting (S2, S4) and the BSP default is `M=2` (S7); (c) leaves an
   unauthenticated fuse-writing console one header away.

2. **How the build proves the monitor is gone.**
   Options: (a) trust the make variable; (b) a build-time check of the
   compile flags and link map (4.2, checks 1-3); (c) (b) plus ELF symbol and
   string checks and the evidence kept with the release (4.2, checks 4-6).
   Recommendation: (c). The checks are cheap and the map file is already
   produced (S5).

3. **Where the SM build lives.**
   Options: (a) NXP's `meta-imx` recipe with a bbappend that pins
   `SYSTEM_MANAGER_MONITOR_MODE = "0"` and adds the checks; (b) this
   repository builds the SM itself from a pinned imx-sm tag with `make
   CONFIG=... M=0 GCOV=0` and hands the binary to the boot-image step;
   (c) both, (b) for CI evidence and (a) for the Yocto image.
   Recommendation: none from sources; (a) is the smaller change if the
   product image is built with `meta-imx`. Depends on the owner's build
   system choice.

4. **SM UART output in production.**
   Options: (a) leave the banner and reset records on the UART (NXP
   default); (b) keep them but leave the UART pins unconnected or unpopulated
   on the product carrier; (c) change the board port so release builds do
   not print, keeping the records in BBNSM and SCMI only.
   Recommendation: (b) as a minimum, because the records carry M33 PCs and
   ELE glitch-detector resets (5.2). (c) means carrying a patch to NXP's
   board port; no NXP option for it was found (6, item 5).

5. **Which agents may read SM logs over SCMI.**
   Options: (a) keep NXP's `mx95frdm-pro.cfg` permissions; (b) allow reset
   reason and syslog only to the agent that handles tamper response (the M7
   in the `hsm-self-defence` row); (c) allow them to the A55 Linux agent too
   for field diagnostics.
   Recommendation: (b), with (c) only if field diagnostics need it; to be
   settled once the permissions are audited (6, item 6).

6. **The SM configuration for the FRDM-IMX95-PRO.**
   Options: (a) use NXP's `configs/other/mx95frdm-pro.cfg` as is;
   (b) copy it into this repository as the product configuration and own
   its changes (permissions, UART, LMs).
   Recommendation: (b). S6 still carries the EVK's name and board, and the
   SPEC row already says the configuration is this repository's.

7. **Persistent shutdown records in BBNSM GPR0-3.**
   Options: (a) keep them (needed for reset-reason diagnosis, S3);
   (b) keep them and confirm in the configuration that no other agent can
   read or write GPR0-3, as NXP advises (S4 `port.md`).
   Recommendation: (b).
