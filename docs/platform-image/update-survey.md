# platform-image: signed update survey

Status: survey for the owner's decision (issue #66). Documentation only: nothing here runs or scripts a fuse, life-cycle or provisioning step.

Scope: how the FRDM-IMX95-PRO platform image (docs/SPEC.md, row `platform-image`) can be updated in the field with signed updates, and how an update interacts with AHAB secure boot and the anti-rollback floor (row `boot-container`).

## 1. Sources and versions

Read from public sources only, at the versions given. [Sn] in the text refers to this list.

| Id | Title | Version | URL |
|----|-------|---------|-----|
| S1 | RAUC documentation: Advanced Topics (Security, Bundle Encryption) | tag v1.15.2 | https://github.com/rauc/rauc/blob/v1.15.2/docs/advanced.rst |
| S2 | RAUC documentation: Integration (U-Boot, signing keys, bundle formats) | tag v1.15.2 | https://github.com/rauc/rauc/blob/v1.15.2/docs/integration.rst |
| S3 | RAUC documentation: Reference (system.conf, manifest, slot types, hooks) | tag v1.15.2 | https://github.com/rauc/rauc/blob/v1.15.2/docs/reference.rst |
| S4 | RAUC documentation: Basic | tag v1.15.2 | https://github.com/rauc/rauc/blob/v1.15.2/docs/basic.rst |
| S5 | SWUpdate documentation: Update images from verified source | tag 2026.05.1 | https://github.com/sbabic/swupdate/blob/2026.05.1/doc/source/signed_images.rst |
| S6 | SWUpdate documentation: sw-description (transaction marker, update types) | tag 2026.05.1 | https://github.com/sbabic/swupdate/blob/2026.05.1/doc/source/sw-description.rst |
| S7 | SWUpdate documentation: Overview (single and double copy) | tag 2026.05.1 | https://github.com/sbabic/swupdate/blob/2026.05.1/doc/source/overview.rst |
| S8 | SWUpdate documentation: Bootloader Interface | tag 2026.05.1 | https://github.com/sbabic/swupdate/blob/2026.05.1/doc/source/bootloader_interface.rst |
| S9 | Mender documentation: Sign and verify (Artifact creation) | docs "latest" (Mender 3.7+), read 2026-11-12 | https://docs.mender.io/artifact-creation/sign-and-verify |
| S10 | FoundriesFactory documentation: Update Rollback | FoundriesFactory 97 docs ("latest") | https://docs.foundries.io/latest/reference-manual/ota/update-rollback.html |
| S11 | OSTree documentation: Introduction | tag v2026.6 | https://github.com/ostreedev/ostree/blob/v2026.6/docs/introduction.md |
| S12 | FoundriesFactory documentation: Offline Factory TUF Keys | FoundriesFactory 97 docs ("latest") | https://docs.foundries.io/latest/reference-manual/security/offline-keys.html |
| S13 | The Update Framework Specification | living standard dated 2026-10-08 | https://github.com/theupdateframework/specification/blob/master/tuf-spec.md |
| S14 | FoundriesFactory documentation: Anti-Rollback Protection | FoundriesFactory 97 docs ("latest") | https://docs.foundries.io/latest/reference-manual/security/anti-rollback-protection.html |
| S15 | U-Boot documentation: Boot Count Limit | mainline `master`, read 2026-11-12 | https://github.com/u-boot/u-boot/blob/master/doc/api/bootcount.rst |
| S16 | NXP U-Boot (uboot-imx): `arch/arm/mach-imx/ele_ahab.c`, the `ahab_*` commands | tag lf-6.18.37-2.1.0 | https://github.com/nxp-imx/uboot-imx/blob/lf-6.18.37-2.1.0/arch/arm/mach-imx/ele_ahab.c |
| S17 | NXP U-Boot (uboot-imx): `doc/imx/ahab/guides/sign_os_cntr.txt` and `introduction_ahab.txt` | tag lf-6.18.37-2.1.0 | https://github.com/nxp-imx/uboot-imx/tree/lf-6.18.37-2.1.0/doc/imx/ahab |
| S18 | NXP imx-mkimage: `Readme.imx95` | tag lf-6.18.37-2.1.0 | https://github.com/nxp-imx/imx-mkimage/blob/lf-6.18.37-2.1.0/Readme.imx95 |
| S19 | NXP imx-mkimage: `iMX95/soc.mak` | tag lf-6.18.37-2.1.0 | https://github.com/nxp-imx/imx-mkimage/blob/lf-6.18.37-2.1.0/iMX95/soc.mak |
| S20 | NXP imx-mkimage: `src/mkimage_imx8.c` (option table) | tag lf-6.18.37-2.1.0 | https://github.com/nxp-imx/imx-mkimage/blob/lf-6.18.37-2.1.0/src/mkimage_imx8.c |

## 2. Requirements taken from the SPEC

From docs/SPEC.md (this repository, commit on main at the time of writing):

- The platform image boots from the 32 GB eMMC on uSDHC1; microSD and FlexSPI NOR are the alternatives that the SW4 switch selects (SPEC row `platform-image`).
- The boot container is AHAB-signed with keys held in an HSM. Its anti-rollback floor follows the EdgeLock monotonic counter and the AHAB version field (SPEC row `boot-container`).
- How the image is built is the owner's decision. The CompuLab Yocto image is reference only (SPEC, owner decisions).

So an update scheme must: (a) verify a signature on the update before it writes anything; (b) let the update signing key live in an HSM; (c) fall back to the last good image if a new image fails to boot; (d) be able to replace the AHAB boot container as well as the root filesystem; (e) refuse downgrades in line with the boot-container floor.

## 3. Update frameworks

### 3.1 RAUC (v1.15.2)

- **Bundle and signature.** A RAUC bundle is a SquashFS image (the payload images plus a manifest) followed by a signature in CMS (RFC 5652) format. The signature carries the signer's certificate. The target checks that certificate against a keyring it already holds, then checks the bundle signature with the signer's key. RAUC chose CMS because it already handles intermediate CAs, expiry, revocation and HSMs, and it uses OpenSSL to sign and verify [S1].
- **HSM signing.** The signing key and certificate can be given as PEM files or as PKCS#11 URIs, so the key can stay in an HSM [S2]. Not confirmed: whether a PKCS#11 provider for go-xkms exists. That is a go-xkms question.
- **Bundle formats.** The `verity` format protects the payload with dm-verity, so it can be checked block by block while it is read, including over HTTP streaming. The `crypt` format adds AES-256 encryption of the payload through dm-crypt, with the key in a manifest that is encrypted to one or more recipient certificates. The target's decryption key can be a file or a PKCS#11 URI [S1]. The older `plain` format can be switched off in `system.conf` once every device has moved to verity [S2].
- **Compatibility checks.** Each bundle carries a `compatible` string that must match the one in the system's configuration, and an `install-check` hook lets the integrator add their own checks, such as a version check [S3]. Not confirmed: whether RAUC refuses downgrades by itself. I found no built-in version-floor check in the pages I read, so treat downgrade refusal as something the integrator writes in the hook.
- **Bootloader.** With `bootloader=uboot`, RAUC drives U-Boot through two environment variables: `BOOT_ORDER` (the slot names in the order to try) and `BOOT_<slot>_LEFT` (the boot attempts left for each slot). The integrator adapts a sample boot script from RAUC's `contrib/` directory to the board [S2]. Barebox's bootchooser is also supported [S4].
- **Boot loader updates.** RAUC has special slot types for updating the boot loader itself. `boot-emmc` uses the eMMC's two hardware boot partitions [S3], which fits the board's eMMC boot device. Whether the i.MX 95 boot ROM honours the eMMC boot-partition switch for the AHAB container is in section 5.

### 3.2 SWUpdate (2026.05.1)

- **What is signed.** SWUpdate does not sign the whole archive, because then the update could only be checked after part of it was written. It does not sign each sub-image alone either, because signed images could then be mixed into a release nobody built. Instead, it signs the release description (`sw-description`), which holds a hash of each sub-image, and checks each sub-image against its hash before installing it [S5].
- **Algorithms.** The signing method is chosen at build time: an RSA key pair (PKCS#1 v1.5 or PSS), CMS with certificates, or GPG. For RSA and CMS, the key or certificate is passed with `-k` [S5]. The crypto layer uses pluggable providers (such as OpenSSL) and modules (such as CMS, AES and PKCS#11) for verification, hashing and decryption [S5]. Not confirmed: which of these signing paths can sign from an HSM at build time without the key leaving it. The docs I read cover verification on the target, not HSM signing on the build host.
- **Version rules.** In `swupdate.cfg`, each update type can set `no-downgrading` (a minimum version), `max-version` and `no-reinstalling`, and `update-type-required` makes the type mandatory [S6]. So downgrade refusal against a configured floor is built in. The floor is a configuration value on the device, not a hardware counter.
- **Transactions and the boot loader.** SWUpdate marks an update as a transaction in the boot loader environment. It sets a transaction marker while installing, and a status variable (`ustate` by default) with the result [S6][S7]. After a reboot, the boot loader picks which copy runs, either single-copy (a rescue system) or double-copy (A/B) [S7]. The boot loader bindings are EFI Boot Guard, U-Boot, GRUB and an in-RAM test environment. For U-Boot, the environment library is loaded at run time [S8].

### 3.3 Mender
### 3.3 Mender (documentation "latest", which covers Mender 3.7 and later; mender client tag 5.2.0 at the time of writing)

- **Artifact signing.** The device is provisioned with a public verification key, set through the client's `ArtifactVerifyKey(s)` option. A signing system signs each Artifact after it is built [S9]. The documented algorithms are RSASSA-PKCS1-v1_5 (with a key of at least 3072 bits recommended) and ECDSA on P-256 [S9].
- **HSM signing.** On Linux, `mender-artifact` can sign with a key named by a PKCS#11 URI through the OpenSSL PKCS#11 engine, so the key can stay in an HSM or smart card. It can also sign with cloud key services (GCP KMS, Vault transit, Azure Key Vault, Keyfactor SignServer) [S9].
- **Not confirmed from the sources I reached.** Mender's A/B rollback mechanics with U-Boot (its boot-count variables), and whether the client refuses downgrades, are not covered by the page I read. The device-side overview page returned 404 from this lane. Mender's server-side features (the hosted or self-hosted server) are outside this survey.

### 3.4 OSTree with TUF (Foundries.io Linux microPlatform, aktualizr-lite)

- **Model.** The LmP OTA client, aktualizr-lite, updates a *Target*: an OSTree-managed root filesystem plus a set of Compose Apps (containers), bound together under one Target version [S10]. OSTree deploys a new root filesystem as hard links to a commit, next to the running one, so the device holds the old and the new version without fixed A/B partitions [S10][S11].
- **Rollback on boot failure.** If a boot into the new root filesystem fails three times, the boot loader falls back to the previous deployment and aktualizr-lite reinstalls the previous Apps [S10]. Boot artifacts (the boot loader) travel inside the OSTree root filesystem, so a boot loader update rolls back the same way. *How* the fallback is triggered after a failed boot loader update depends on the hardware [S10]. Not confirmed: what LmP does for i.MX 95 boot containers in particular.
- **Trust in updates.** FoundriesFactory signs update metadata with The Update Framework (TUF). TUF separates roles (root, targets and others) so that losing one role's key does less harm, and it lets the root key rotate and revoke other keys [S12][S13]. Foundries.io creates the initial TUF root key online; the factory admin is told to rotate it offline as soon as possible [S12].
- **Boot firmware anti-rollback.** LmP writes a boot firmware version (`LMP_BOOT_FIRMWARE_VERSION`) into the U-Boot device tree. Once `rollback_protection` is set in the boot loader environment, aktualizr-lite and U-Boot refuse boot firmware below the current version [S14]. This is a software floor kept in the U-Boot environment (on closed boards through `fiovb`, which [S14] does not describe further), not the AHAB version field or the EdgeLock monotonic counter. Not confirmed: whether LmP ties this floor to the i.MX 95's hardware anti-rollback.
- **Fit.** LmP is a full distribution with its own build system (Yocto layers) and a hosted factory service. Using it would decide the build-system question too, which is the owner's (SPEC, owner decisions; issue #14 is blocked on it).

## 4. Bootloader integration and boot counting

- **U-Boot boot count limit.** With `CONFIG_BOOTCOUNT_LIMIT`, U-Boot increments `bootcount` on each reboot while `upgrade_available` is non-zero. When the count passes `bootlimit`, U-Boot runs `altbootcmd` instead of `bootcmd`. A Linux service must reset the count once the system is known to be good. With `CONFIG_BOOTCOUNT_FS`, the count can live in a file on a FAT or ext filesystem instead [S15].
- **Framework variables.** RAUC uses its own `BOOT_ORDER` / `BOOT_<slot>_LEFT` variables and a boot script [S2]. SWUpdate uses a transaction marker and `ustate` [S6]. LmP falls back after three failed boots [S10]. Each one needs U-Boot's environment to be writable from Linux, so the environment (and its redundant copy) must sit somewhere both sides can reach on the eMMC.
- **Trust in the environment.** Not covered by the sources I read: a U-Boot environment that Linux can write is not signed. On a secure-boot board, the boot script and the variables it reads choose which signed kernel runs, so they must only be able to choose between images that are themselves verified (FIT signature or AHAB-signed OS container). See `sign_os_cntr.txt` in NXP's U-Boot for signing an OS container [S17]. This is my inference, not a vendor statement.

## 5. Updating the signed boot container

What the boot container holds, from NXP's public build tool. For the i.MX 95, imx-mkimage builds `flash.bin` with make targets such as `flash_lpboot_sm_a55` (System Manager plus Cortex-A55 boot, from SD/eMMC or FlexSPI NOR) and `flash_lpboot_sm_all` [S18]. The second container (TF-A `bl31`, an optional OP-TEE and U-Boot) is built with `-sw_version $(ROLLBACK_INDEX_IN_CONTAINER)` whenever that variable is set [S19]. The tool accepts `fuse_version` and `sw_version` options [S20].

Ways to update it in the field:

1. **Do not update it in the field.** The boot container changes only at manufacture or service. This is the smallest risk of bricking the board. Every SM, TF-A, OP-TEE or U-Boot security fix then needs a service visit.
2. **eMMC hardware boot partitions (A/B at the boot-partition level).** Write the new container to the inactive eMMC boot partition, then switch the eMMC's boot partition selection. RAUC supports this as the `boot-emmc` slot type [S3]. Not confirmed: whether the i.MX 95 boot ROM falls back to the other boot partition, or to a secondary container set, when AHAB authentication of the selected one fails. That behaviour is in IMX95RM and the Security Reference Manual, which SPEC lists as missing. Without such a fallback, a bad container that is correctly signed but fails to boot cannot be recovered by the ROM. Recovery would then need serial download over USB.
3. **Boot artifacts carried inside the OS update** (the LmP model) [S10]. The roll-back trigger for a failed boot loader is hardware-specific there too, so it comes down to the same ROM question as option 2.

## 6. Anti-rollback

The sources show three separate layers:

- **Hardware floor (AHAB).** The container header carries a software version (`-sw_version`, above) [S19][S20]. NXP's U-Boot has an `ahab_commit` command that writes any new SRK revocation and firmware version information found in the NXP (ELE firmware) and OEM containers into the fuses [S16]. This is irreversible, so this survey only describes it; no step here runs or scripts it. The ELE's monotonic counter is a separate floor for the key store (SPEC, row `secure-key-handling`; RM00284 §2.4.2, as cited in SPEC).
- **Boot loader floor (software).** LmP keeps a boot firmware version in the U-Boot device tree and refuses older firmware once a `rollback_protection` flag is set [S14].
- **OS floor (software).** SWUpdate refuses images below `no-downgrading` [S6]. RAUC leaves this to an `install-check` hook [S3]. OSTree/TUF metadata carries versions, and TUF is designed to resist rollback of the metadata [S13].

Ordering (my inference from the above, not a vendor statement): if the AHAB fuse version is committed while the new image is being installed, the old image can no longer boot, so a failed update cannot fall back. A safe order is: install to the inactive slot, boot it, mark it good (reset the boot count), and only then commit the version.

## 7. Comparison

## 8. What could not be confirmed

## 9. Questions for the owner
