# boot-container: how U-Boot authenticates the next stage (survey)

Row: `boot-container` ([SPEC.md](../SPEC.md)). Issue #102. Documentation only.

Status: survey, draft for the owner. Public sources only. Nothing here was run on
a board; no key, fuse, life-cycle or provisioning step is described as a
procedure, and none is scripted.

## 1. Scope

The boot container of the `boot-container` row is verified by the boot ROM and
the EdgeLock secure enclave (ELE). After it, U-Boot proper runs on the
Cortex-A55 and loads the next stage: a kernel, a device tree, and possibly an
initramfs, a hypervisor or a UEFI application. This survey answers three
questions:

1. How U-Boot on the i.MX 95 authenticates what it loads after the boot
   container: through the enclave (an AHAB container that U-Boot asks the ELE
   to verify), through a signed FIT image that U-Boot verifies itself, or both.
2. Which U-Boot options close the remaining gaps on a closed device
   (environment, command line, boot command, other boot paths).
3. Where the boot container's chain of trust ends and the platform image's
   begins, and what belongs to #14 rather than this row.

## 2. Sources surveyed

Every claim below cites one of these by its tag `[S<n>]`. All are public. Text
is summarised in this document's own words; nothing is quoted.

| Tag | Title | Version surveyed | URL |
|---|---|---|---|
| S1 | NXP U-Boot fork, `doc/imx/ahab/introduction_ahab.txt` ("i.MX Secure and Encrypted Boot using AHAB") | tag `lf-6.18.37-2.1.0` (branch `lf_v2026.04`) | https://github.com/nxp-imx/uboot-imx/blob/lf-6.18.37-2.1.0/doc/imx/ahab/introduction_ahab.txt |
| S2 | NXP U-Boot fork, `doc/imx/ahab/guides/sign_os_cntr.txt` ("Extend RoT guide using AHAB") | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/uboot-imx/blob/lf-6.18.37-2.1.0/doc/imx/ahab/guides/sign_os_cntr.txt |
| S3 | NXP U-Boot fork, `board/nxp/imx95_evk/imx95_evk.env` (i.MX 95 EVK default environment) | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/uboot-imx/blob/lf-6.18.37-2.1.0/board/nxp/imx95_evk/imx95_evk.env |
| S4 | NXP U-Boot fork, `configs/imx95_19x19_evk_defconfig` | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/uboot-imx/blob/lf-6.18.37-2.1.0/configs/imx95_19x19_evk_defconfig |
| S5 | U-Boot, `doc/usage/fit/signature.rst` ("U-Boot FIT Signature Verification") | tag `v2026.10` | https://github.com/u-boot/u-boot/blob/v2026.10/doc/usage/fit/signature.rst |
| S6 | NXP U-Boot fork, `doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt` ("i.MX 8ULP/9x Secure boot guide using AHAB") | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/uboot-imx/blob/lf-6.18.37-2.1.0/doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt |
| S7 | U-Boot, `env/Kconfig` (option help texts) | tag `v2026.10` | https://github.com/u-boot/u-boot/blob/v2026.10/env/Kconfig |
| S8 | U-Boot, `common/Kconfig` (autoboot and console options) | tag `v2026.10` | https://github.com/u-boot/u-boot/blob/v2026.10/common/Kconfig |
| S9 | U-Boot, `boot/Kconfig` (FIT, standard boot, legacy image options) | tag `v2026.10` | https://github.com/u-boot/u-boot/blob/v2026.10/boot/Kconfig |
| S10 | U-Boot, `cmd/Kconfig` (`CMDLINE`, `CMD_FUSE`) | tag `v2026.10` | https://github.com/u-boot/u-boot/blob/v2026.10/cmd/Kconfig |
| S11 | NXP U-Boot fork, `arch/arm/mach-imx/Kconfig` (`APPEND_BOOTARGS`, `FSL_MFGPROT`) | tag `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/uboot-imx/blob/lf-6.18.37-2.1.0/arch/arm/mach-imx/Kconfig |

## 3. Option A: AHAB authentication through the enclave

**Mechanism.** On i.MX 8ULP and i.MX 9x, the ELE authenticates every boot
image: its own firmware (signed by NXP and checked in both open and closed
life-cycle states), the Cortex-M image and the Cortex-A image, against the SRK
table carried in the container and the SRK hash held in fuses [S1 §1.1.3,
§1.4]. The same enclave stays available at run time as an image-authentication
service [S1 §1.1.3]. NXP's guide calls using that service from U-Boot to check
the OS "extending the root of trust" [S2 §1].

**What U-Boot loads.** The kernel (and, in NXP's flow, what imx-mkimage puts
beside it) is wrapped in an AHAB *OS container* by imx-mkimage and signed with
CST against the same PKI as the boot container [S2 §2.1–2.3]. U-Boot hands the
container to the ELE for verification, either through an explicit
`auth_cntr <address>` command or as part of booting it with `booti` on the
container address [S2 §2; S3 `auth_os`].

**How the EVK wires it.** The i.MX 95 EVK environment sets `sec_boot=yes`
when U-Boot is built with `CONFIG_AHAB_BOOT`, and `no` otherwise [S3]. With
`sec_boot=yes`, the board's own boot scripts (`bsp_bootcmd`, `mmcboot`,
`netboot`) load `os_cntr_signed.bin` to `cntr_addr` and boot it with
`booti ${cntr_addr}`; with `sec_boot=no` they load a bare `Image` and a
separate device tree, or a FIT through `bootm` when `boot_fit` is set [S3].

**Gaps visible in the sources.**

- *The switch is an environment variable.* NXP's guide says the OS check can
  be turned off by setting `sec_boot=no` [S2 §2]. Whether the AHAB check holds
  on a closed device therefore depends on the environment being immutable (see
  §5).
- *The EVK's boot command does not start with the AHAB path.* The defconfig's
  `CONFIG_BOOTCOMMAND` runs `bootflow scan -lb` (U-Boot standard boot) before
  `bsp_bootcmd` [S4]. Standard boot finds and boots extlinux, boot scripts and
  EFI applications on its own and does not consult `sec_boot`; the
  `sec_boot` test lives only in the board scripts [S3]. On a closed device the
  boot command must be reduced to the authenticated path.
- *The EVK defconfig does not enable `CONFIG_AHAB_BOOT`* [S4]; a product
  defconfig must.
- *The device tree is not separately authenticated in the EVK's
  `sec_boot=yes` path*: the scripts load only the container and boot it with
  `booti ${cntr_addr}` [S3]. Whether the DTB travels inside the OS container,
  or U-Boot passes its own control DTB, is not stated in S2 or S3
  (**not confirmed**, see §7).
- *AHAB version on the i.MX 95.* From i.MX 95 B0 on, i.MX 9x parts use
  AHAB 2.0; signing needs CST 4.0.1 or SPSDK, NXP names SPSDK as the
  recommended tool, and CST receives bug fixes only for AHAB devices [S1 §2.1].
  B0 also carries a second SRK hash fuse region for post-quantum keys beside
  the classic one [S1 §2.2]. SPEC.md's row names CST 3.1.0; that version does
  not cover AHAB 2.0 according to S1. This is a question for the owner (§8).

## 4. Option B: signed FIT images

**Mechanism.** A FIT image carries the kernel, device trees and ramdisks with a
hash per image. With FIT signatures, mkimage signs those hashes, and U-Boot
checks the signature on load against a public key kept in U-Boot's own control
device tree (the key cannot live in the image it checks) [S5 "Public Key
Storage"]. Verification runs automatically inside `bootm` once a FIT is
selected [S5 "Verification"]. The check is done by U-Boot's own code on the
Cortex-A55, not by the ELE.

**Sign the configuration, not the image.** Signing only individual images
lets an attacker build a new configuration that pairs a signed kernel with a
different signed device tree, or carries an older signed image into a newer
FIT. U-Boot's answer is the *signed configuration*: each image keeps a hash,
and the signature covers the configuration node, the images it references and
the FIT's root structure [S5 "Signed Configurations"]. A public key marked
`required` (with `conf`) in the control DTB makes the check mandatory rather
than advisory [S5 "Public Key Storage"]; with several required keys,
`required-mode` chooses whether any one or all must match [S5
"Verification"].

**Options.** `CONFIG_FIT_SIGNATURE` plus `CONFIG_RSA` and/or `CONFIG_ECDSA`
enable it. When the device relies on a required signature, the legacy
(unsigned uImage) format must stay disabled, that is
`CONFIG_LEGACY_IMAGE_FORMAT` not set [S5 "Enabling FIT Verification"].

**Key custody.** mkimage can sign through a PKCS#11 or OpenSSL-engine HSM, so
the FIT key can be held in an HSM like the AHAB keys [S5 "Hardware Signing
with PKCS#11 or with HSM"]. Whether go-xkms (SPEC.md's row) can serve as that
signer is **not confirmed**.

**Where the FIT key comes from.** The verifying public key sits in U-Boot's
control DTB, which on the i.MX 95 is part of U-Boot proper inside the fourth
container that SPL has the ELE authenticate [S6 §1.3]. The FIT key is
therefore anchored in the AHAB chain: AHAB proves U-Boot and its embedded key,
U-Boot proves the FIT. This is the usual pattern; that the NXP build places the
control DTB inside the authenticated container (and not in a separately loaded
file) is inferred from S6's layout, **not confirmed** from source.

**What the EVK does with FIT.** The EVK defconfig enables `CONFIG_FIT` but not
`CONFIG_FIT_SIGNATURE` [S4], and its `boot_fit` path calls `bootm` only when
`sec_boot=no` [S3]. NXP's i.MX 95 scripts treat FIT and AHAB OS containers as
alternatives, not as layers.

### Option C: both

Nothing in S1–S6 forbids carrying a signed FIT inside, or beside, an AHAB OS
container, but none of the sources describes doing both, and the EVK scripts
choose one [S3]. Doing both doubles the signing and the keys to hold without
an evident gain, since the FIT key is already anchored by AHAB (above).

### Comparison

| | A: AHAB OS container | B: signed FIT |
|---|---|---|
| Verifier | ELE firmware, via U-Boot's request [S1, S2] | U-Boot's own code [S5] |
| Root key | SRK hash in fuses, same PKI as the boot container [S1 §2.2] | Public key in U-Boot's control DTB, itself under AHAB [S5, S6] |
| Signing tool | CST 4.0.1 or SPSDK for AHAB 2.0 [S1 §2.1, S6 §1.1] | mkimage, optional PKCS#11/HSM [S5] |
| Kernel + DTB + initramfs bound together | Not stated for the i.MX 95 (§7) | Yes, by signed configuration [S5] |
| Upstream U-Boot support | NXP fork documents it; upstream status not confirmed (§7) | Upstream, generic, tested in U-Boot's test suite [S5 "Testing"] |
| Works with standard boot / extlinux | Not described [S3] | `bootm` path; FIT is a supported boot method format (§5) |
| Disabled by | `sec_boot=no` in the environment [S2 §2] | Missing `required` key or legacy format enabled [S5] |

## 5. Configuration that closes the gaps on a closed device

Authenticating the kernel is worth little if the environment, the command line
or another boot path can route around it. The options below are upstream
U-Boot `v2026.10` [S7–S10] unless marked NXP. Each row says what it closes and
what the EVK defconfig does today [S4]. None of this was built or tested.

### 5.1 Environment

| Option | Effect (own words) | EVK [S4] |
|---|---|---|
| `CONFIG_ENV_IS_NOWHERE` alone (no `ENV_IS_IN_*`) | U-Boot always starts from the built-in default environment, which is inside the authenticated U-Boot image [S7] | `ENV_IS_NOWHERE=y` **and** `ENV_IS_IN_MMC=y`, so a stored environment in eMMC/SD is loaded |
| `CONFIG_ENV_WRITEABLE_LIST` (selects `ENV_APPEND`) | Only variables flagged writeable in the static flags list may be set or imported; nothing else can be created or overwritten [S7] | not set |
| `CONFIG_ENV_FLAGS_LIST_STATIC` | The compile-time list of per-variable type and access flags (read-only, write-once, writeable, ...) that the item above relies on [S7] | not set |
| `CONFIG_ENV_APPEND` | An imported environment can add variables but never replace the existing table [S7] | not set |
| `CONFIG_ENV_ACCESS_IGNORE_FORCE` | `env set -f` cannot override access flags [S7] | not set |
| `CONFIG_ENV_OVERWRITE` | Lets protected variables such as the Ethernet address be overwritten; should be off [S7] | **set** |

The variables that steer authentication on the EVK are `sec_boot`,
`cntr_addr`, `cntr_file`, `boot_fit`, `bootcmd`, `bootargs`/`mmcargs` and
`script` [S3]. On a closed device none of them may be writable from storage.
The simplest rule supported by the sources is no stored environment at all
(`ENV_IS_NOWHERE` only). If a few variables must persist (for example an A/B
slot), `ENV_WRITEABLE_LIST` with an explicit list keeps the rest read-only
[S7]. Kernel command-line content is also a policy surface; NXP's
`CONFIG_APPEND_BOOTARGS` is described by NXP as debug only, never for
production [S11].

### 5.2 Command line and autoboot

| Option | Effect | EVK [S4] |
|---|---|---|
| `CONFIG_CMDLINE` off | Removes the command-line interface and script execution entirely; `AUTOBOOT`, `USE_BOOTCOMMAND` and `BOOTMETH_SCRIPT` depend on it, so the board must boot through standard boot or board code [S9, S10] | on (default) |
| `CONFIG_BOOTDELAY=-2` | Autoboot at once and never check for an abort key [S8] | default (2 s) |
| `CONFIG_AUTOBOOT_KEYED` + `CONFIG_AUTOBOOT_ENCRYPTION` | If a service prompt must exist, only a password whose SHA-256 (or crypt hash) matches can stop autoboot [S8] | not set |
| `CONFIG_SILENT_CONSOLE` / `CONFIG_DISABLE_CONSOLE` | Silence or disable the console [S8]. Note: silence is controlled by an environment variable, so it depends on §5.1 [S8] | not set |

A closed device can keep the command line (needed by NXP's script-based
`bsp_bootcmd` [S3]) only together with `BOOTDELAY=-2` or a keyed, hashed stop
string, and a locked environment. Removing `CMDLINE` is the stronger option
but forces the boot onto standard boot or board C code, which NXP's EVK
scripts do not use for the AHAB path [S3].

### 5.3 Boot command and other boot paths

| Item | Why it matters | EVK |
|---|---|---|
| `CONFIG_BOOTCOMMAND` | Must run only the authenticated path. The EVK runs `bootflow scan -lb` first, which can boot extlinux, scripts or EFI binaries found on any block device before `bsp_bootcmd` checks `sec_boot` [S3, S4, S9] | `run sr_ir_v2_cmd; bootflow scan -lb; run bsp_bootcmd` |
| `CONFIG_BOOTSTD`, `BOOTMETH_EXTLINUX`, `BOOTMETH_EFILOADER`, `BOOTMETH_SCRIPT` | Standard boot is on by default when block devices exist; the extlinux and EFI boot methods default on [S9]. Each is a boot path that does not go through AHAB container checks (not stated in NXP sources; inferred from S3, see §7) | standard boot on; `BOOTDEV_ETH=n` |
| `CONFIG_LEGACY_IMAGE_FORMAT` | Defaults off only when `FIT_SIGNATURE` is set; otherwise `bootm` accepts unsigned uImages [S9] | default (on, as `FIT_SIGNATURE` is not set) |
| `booti`/`bootz`/`bootm` on raw images | The non-`sec_boot` branch boots a bare `Image` and DTB with `booti` and no signature [S3]; reachable whenever the command line or environment is | present |
| `CONFIG_EFI_SECURE_BOOT`, `CONFIG_EFI_CAPSULE_AUTHENTICATE` | The EVK enables UEFI secure boot and authenticated capsule update, with a certificate built in as `CRT.crt` [S4]. UEFI secure boot is a third, separate verification scheme with its own key database; whether it is a third option for this row is a question (§8) | set |
| Fastboot, USB SDP, UMS, DFU (`CMD_FASTBOOT`, `CMD_USB_SDP`, `CMD_USB_MASS_STORAGE`, `CMD_DFU`) | Each lets a host write storage or load and run images over USB [S4, S10] | set |
| `CMD_FUSE`, NXP `ahab_close` | Fuse programming and life-cycle change from the U-Boot prompt [S6 §1.6, §1.8; S10] | `CMD_FUSE` set |
| Memory commands (`md`/`mw`), `go` | Read or write arbitrary memory, jump to arbitrary code (general U-Boot; not separately cited) | default |

On the i.MX 95 these are U-Boot settings, not ELE settings: the ELE checks
each container it is asked to check, but U-Boot decides whether to ask
[S1 §1.4, S2]. The closure therefore lives in the product defconfig, which is
inside the authenticated U-Boot container.

## 6. Where the boot container's chain of trust ends

## 7. Not confirmed

## 8. Questions for the owner
