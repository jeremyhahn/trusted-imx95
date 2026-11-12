# OEM key provisioning: survey of the public flow

Row: `oem-key-provisioning` ([SPEC](../SPEC.md), issue #18). Survey for issue #35.

This survey covers what NXP's public repositories and upstream projects say about provisioning OEM keys into the i.MX 95's EdgeLock Secure Enclave (ELE) and about moving the device's life cycle.
It uses public sources only and summarises them in its own words.
It is documentation: it runs no step and scripts none.
Command and API names appear below only to show what a source offers, not as a procedure.

All sources were retrieved on 2026-11-12.
A claim marked **unconfirmed** could not be checked against a source that this lane could reach.

## Sources

### Reached

| Id | Title | Version surveyed | URL |
|---|---|---|---|
| S1 | NXP Secure Provisioning SDK (SPSDK), source and the `nxpele`, `nxpimage` and `el2go` command-line help | tag `v3.13.0` (latest tag on the day), PyPI package `spsdk==3.13.0` | https://github.com/nxp-mcuxpresso/spsdk |
| S2 | SPSDK example: i.MX95 anti-rollback protection (`examples/ahab/imx95/imx95_anti_rollback_protection.md`) | `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/examples/ahab/imx95/imx95_anti_rollback_protection.md |
| S3 | SPSDK example: EdgeLock Secure Enclave, the `nxpele` utility (`examples/ele/nxpele.ipynb`) | `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/examples/ele/nxpele.ipynb |
| S4 | SPSDK user guide for `nxpele` (`docs/apps/nxpele.rst`) and the release notes (`docs/release_notes.rst`) | `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/tree/v3.13.0/docs |
| S5 | NXP Secure Enclave userspace library (imx-secure-enclave), `README` and the header file list | tag `lf-6.18.37-2.1.0` (latest `lf-` tag on the day) | https://github.com/nxp-imx/imx-secure-enclave |
| S6 | ELE HSM API document (`doc/ele_hsm_api_document.pdf`, Doxygen output, PDF dated 2024-01-30), shipped in S5 | as shipped in `lf-6.18.37-2.1.0` | https://github.com/nxp-imx/imx-secure-enclave/blob/lf-6.18.37-2.1.0/doc/ele_hsm_api_document.pdf |
| S7 | U-Boot, `doc/imx/imx95_container.txt` (i.MX95 image container format) and the `arch/arm/mach-imx` file list | tag `v2026.10` | https://github.com/u-boot/u-boot/blob/v2026.10/doc/imx/imx95_container.txt |
| S8 | U-Boot documentation, board page `imx95_frdm` (U-Boot for the NXP i.MX95 15x15 FRDM board) | `v2026.10` | https://docs.u-boot.org/en/v2026.10/board/nxp/imx95_frdm.html |
| S9 | OP-TEE OS, file list of `core/drivers/crypto/ele` and `core/arch/arm/plat-imx` | tag `4.11.0` | https://github.com/OP-TEE/optee_os/tree/4.11.0/core/drivers/crypto/ele |

### Not reached

| Source | Why | Effect |
|---|---|---|
| Issue #35 itself | The forge API answered 403 from the lane | The survey follows the lane brief and the SPEC row; any scope in the issue text that they do not repeat is not covered |
| NXP AN14861, Secure OEM Key Provisioning with EdgeLock Secure Enclave, https://www.nxp.com/docs/en/application-note/AN14861.pdf | 404 from the lane (nxp.com's home page answered 200, so the documents may be gated or blocked for automated clients) | Whether AN14861 is public is **unconfirmed**. The SPEC row cites it from the private reference set; this survey does not |
| NXP AN14533 (anti-rollback, which S2 cites), https://www.nxp.com/doc/AN14533 | 404 from the lane | **Unconfirmed** |
| IMX95RM, the i.MX 95 Security Reference Manual, the ELE firmware API reference manual | Not public, or 404 from the lane | The fuse map, the number of version fuse bits and the exact life-cycle effects stay **unconfirmed**, as the SPEC row already says |
| NXP EdgeLock 2GO product page and the FRDM-IMX95 product page on nxp.com | 404 from the lane | **Unconfirmed** |
| SPSDK documentation on readthedocs for 3.13.0 | 404 from the lane | S1 and S4 cover the same content from the source tree and the installed tool's help |
| The source bodies of S5, S7 and S9 (C headers, `ele_ahab.c`, the OP-TEE ELE driver) and the YAML templates SPSDK generates | The lane's read guard does not allow reading code outside this repository | For these sources only the file names and the documentation are surveyed; what the code does is **unconfirmed** |
| GitHub REST API (release metadata) | Rate limited (unauthenticated) | Versions were taken from `git ls-remote` tags instead |
| imx-mkimage, https://github.com/nxp-imx/imx-mkimage | Its tags were listed, but its content was not surveyed | Not used |

## Findings

### F1. The life-cycle states the enclave exposes

- The ELE HSM API document names a life-cycle update call that takes one target state. The states it lists are NXP provisioned, OEM open, OEM closed, OEM field return, NXP field return and OEM locked (S6, §5.19).
- The device-info call reports the life cycle as one of three values: OEM open, OEM closed and OEM locked (S6, §5.13).
- The error list separates a signed-message check that fails in OEM closed (an error) from the same failure in OEM open (only a warning) (S6, §5.20). So OEM open is the state where provisioning can be tried and checked without bricking the board.
- SPSDK's `nxpele` can move the life cycle forward to `oem_closed` or `oem_locked`, and only to those two (S1, `nxpele forward-lifecycle-update --help`).
- SPSDK's signed-message tool has a `return_lifecycle_update_req` message for the i.MX 95 family `mimx9596` (S1, `nxpimage signed-msg get-template --help` and `get-families`). From its name it is the signed request for a field-return state. Its content and effect are **unconfirmed**.
- Whether a move to OEM closed or OEM locked can be undone on the i.MX 95, and what each one burns, are **unconfirmed**: they need IMX95RM and the Security Reference Manual.

### F2. Key exchange and key import

- The ELE import-key call takes one of two wrapped formats: an EdgeLock 2GO TLV, or an ELE TLV encrypted under a key-encryption key (KEK) that the caller names by identifier (S6, §5.2.2.3, §5.2.6.3).
- The library tag surveyed ships headers named `hsm_key_exchange.h`, `hsm_importkey.h`, `hsm_root_kek_export.h`, `hsm_lc_update.h`, `hsm_dev_write_fuse.h` and `hsm_dev_mono_counter.h` (S5, `include/hsm/internal/`). The API document of January 2024 (S6) does not yet describe key exchange. What the newer headers declare is **unconfirmed** (code not read).
- SPSDK has a signed `key_exchange_req` message for `mimx9596` (S1, `nxpimage signed-msg`). This fits the SPEC row's "key exchange, then the import of the wrapped key". The template's fields are **unconfirmed** (not read).
- SPSDK's `nxpele` can export the NXP production key-agreement public key from the enclave. Its default key identifier is 0x70000000 (S1, `nxpele export-nxp-prod-ka-puk --help`). From the name, this is the device-side public key that an OEM uses to agree on a wrapping key with the enclave. That reading is **unconfirmed** without AN14861.
- SPSDK also has a signed `keystore_reprovisioning_enable_req` message (S1). The ELE API says a key store reprovisioning erases every key store the HSM handles (S6, §5.18.1). The SPSDK release notes list i.MX95 B0 keystore reprovisioning and a fix to its flag in the signed message (S4).

### F3. EdgeLock 2GO as an alternative path

- SPSDK's `el2go` tool lists `mimx9596` as a family for `provision-device` (S1, `el2go get-families -c provision-device`). SPSDK has an i.MX93 EdgeLock 2GO example but no i.MX95 one (S1, `examples/el2go/imx93`).
- The ELE import-key call accepts an EdgeLock 2GO TLV directly (S6, §5.2.2.3).
- EdgeLock 2GO is an NXP-hosted service. Its terms, cost and trust model are **unconfirmed**: the product page was not reached.

### F4. Fuses and anti-rollback

- Each image container header has a fuse-version field and a software-version field, and the signature block holds the SRK table (S7).
- SPSDK's i.MX95 anti-rollback example works like this (S2, own summary). The container carries the fuse version to burn. A separate ELE commit request then burns it, once for the NXP firmware version and once for the OEM version. Afterwards, an OEM container with a lower version is refused in OEM closed or locked. In OEM open, the same container still boots and the ELE logs a bad-version event.
- `nxpele commit` can also commit NXP or OEM SRK revocation (S1, `nxpele commit --help`).
- `nxpele` can write single fuses and shadow fuses. SPSDK's example warns that a fuse write is one-time and cannot be reversed (S1, S3).
- How many version fuse bits the i.MX 95 has, and where the SRK hash fuses sit, are **unconfirmed** (IMX95RM).

### F5. How a host talks to the enclave

- `nxpele` reaches the ELE in three ways: through the ROM's mboot flashloader (which the guide gives for the RT1180), through the U-Boot serial console, or through U-Boot fastboot. The two U-Boot ways need U-Boot built with AHAB support and its `ele_message` command. Fastboot is described as the fastest (S4, `nxpele.rst`; S3).
- SPSDK's anti-rollback example for i.MX95 uses the U-Boot serial way (S2).
- Upstream U-Boot `v2026.10` has an `ele_ahab.c` in `arch/arm/mach-imx` (S7). Whether upstream U-Boot has the `ele_message` command SPSDK needs, or only NXP's U-Boot fork does, is **unconfirmed** (code not read).
- The upstream U-Boot FRDM-i.MX95 page builds with the NXP ELE firmware package `firmware-ele-imx-2.0.2` and gives separate ELE containers for A0 and B0 silicon (S8). That page is for the 15x15 FRDM-IMX95 board, not the FRDM-IMX95-PRO (machine `imx95-19x19-lpddr5-frdm-pro`); which ELE firmware version and container the PRO's BSP uses is **unconfirmed**.

### F6. Where the enclave is used from at run time

- On Linux, the imx-secure-enclave library gives the i.MX95 ELE-HSM, V2X-SHE and V2X-HSM services (S5, Table 1).
- An NVM manager daemon serves the ELE firmware's storage requests. It keeps the ELE key store at rest on the Linux file system, under `/etc/ele/` on the i.MX95 (S5, NVM Manager and Table 2). So persistent OEM keys depend on a Linux file-system path. How the stored blobs are protected is **unconfirmed**.
- OP-TEE `4.11.0` has an ELE crypto driver with key-management and sign/verify parts, and has i.MX95 platform registers (S9). The ECC key and signing path in that driver is limited to the i.MX 91 and i.MX 93, and it returns private keys to caller memory in plain text. On the i.MX 95, upstream OP-TEE uses the enclave for the HUK and RNG only, and no opaque-key-store path was found ([ele-hsm-api-survey.md](../secure-key-handling/ele-hsm-api-survey.md) §5.1). It does not provide enclave-held keys on this board. Whether it and the Linux library can share the enclave at the same time is **unconfirmed**. This bears on the `secure-world` row.

## What the public sources give, against the SPEC row

| SPEC row element | Public coverage |
|---|---|
| Key exchange, then the import of the wrapped key | Partly: the signed `key_exchange_req` (S1), the KA public-key export (S1) and the import-key formats (S6). The message contents and the order of steps are **unconfirmed** without AN14861 |
| Life cycle OEM open → OEM closed through the enclave | Yes for the existence of the calls (S1, S6). Reversibility and fuse effects are **unconfirmed** |
| Monotonic counter fuses configured once | Partly: the version commit (S2) and a header named for the monotonic counter (S5). Bit counts are **unconfirmed** |
| i.MX 95 fuse map and life-cycle effects | Not public; IMX95RM and the Security RM stay missing |

## Questions for the owner

1. **Which tool drives the one-time provisioning steps?**
   - (a) SPSDK `nxpele` on a host, through U-Boot (fastboot or serial).
   - (b) An on-device program built on imx-secure-enclave.
   - (c) An OP-TEE trusted application.

   Recommendation: (a) for the one-time steps (key-agreement key export, key exchange, version commit, life-cycle move). It is public, tagged and supports `mimx9596` (S1, S4). Its i.MX95 example uses this path (S2). Use (b) or (c) only for run-time key use (F6).
2. **Which key-exchange path?**
   - (a) The OEM's own signed `key_exchange_req`, with the OEM side of the agreement held in go-xkms custody.
   - (b) NXP EdgeLock 2GO.

   Recommendation: (a). The import call accepts both formats (S6), but (a) keeps the OEM keys out of any third-party service, as the SPEC's custody model asks. (b)'s trust model is **unconfirmed** (F3).
3. **Where does provisioning run?**
   - (a) A factory station connected to the board over USB or serial.
   - (b) In the field, driven by go-trusted-platform's control plane.
   - (c) Both: the one-time steps at the factory, re-provisioning in the field.

   No recommendation: the sources describe the transports (F5), not this policy. Note that the U-Boot paths need a U-Boot built with AHAB support, which a field image may not carry.
4. **When is the life cycle closed, and is OEM locked ever used?**
   - (a) Close at the factory, once a signed image boots in OEM open with no ELE events.
   - (b) Close at enrolment.
   - (c) Also move to OEM locked.

   Recommendation: (a), with OEM open used to check images, since OEM open only warns on a failed check (F1, F4). Decide on (c) only after IMX95RM shows what locked rules out, field return in particular (**unconfirmed**).
5. **When is the OEM firmware version committed to fuses?**
   - (a) At every release.
   - (b) Only at security-relevant releases.
   - (c) Never.

   Recommendation: (b). Each commit burns fuses for good (S2, S3), and the number of version bits is **unconfirmed**.
6. **Is the ELE key store on the Linux file system (`/etc/ele/`, F6) acceptable?**
   - (a) Yes, on a protected partition.
   - (b) No: keep no persistent OEM keys in the enclave key store, and re-import them each boot from go-xkms. This depends on an i.MX 95 wrapped-key import service, which is **unconfirmed** ([key-recovery-survey.md](../secure-key-handling/key-recovery-survey.md) §3.3).

   No recommendation until the blob protection is confirmed.
7. **Which silicon revision is the FRDM-IMX95-PRO in the kit, A0 or B0?** The ELE firmware container (S8) and SPSDK's keystore-reprovisioning support (S4) differ by revision. Recommendation: record the revision in [references/](../references/README.md) before any provisioning design is written.
8. **Can AN14861 and AN14533 be cited publicly?** This lane could not reach them on nxp.com. Recommendation: confirm whether they are public, and add IMX95RM, the Security Reference Manual and the ELE firmware API reference to [references/](../references/README.md), because F1, F2 and F4 stay unconfirmed without them.
