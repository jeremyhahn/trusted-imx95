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
### 3.3 Mender
### 3.4 OSTree with TUF/Uptane (Foundries.io LmP, aktualizr)

## 4. Bootloader integration and boot counting

## 5. Updating the signed boot container

## 6. Anti-rollback

## 7. Comparison

## 8. What could not be confirmed

## 9. Questions for the owner
