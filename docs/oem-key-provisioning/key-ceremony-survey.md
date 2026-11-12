# OEM key provisioning: factory station and key ceremony survey

Row: `oem-key-provisioning` ([SPEC.md](../SPEC.md)). Issue #86. Documentation only.
Nothing here was run against a device, nothing here is a script, and nothing
here is a key.

Status: survey, for the owner's decision. Surveyed 2026-11-12.

## 1. Scope and method

The question (issue #86): how public sources describe a secure provisioning
station and key ceremony for NXP devices with an EdgeLock Secure Enclave (ELE),
and in particular for the i.MX 95 on the FRDM-IMX95-PRO:

- who is present, what hardware holds the OEM keys (the owner's target is an
  HSM under go-xkms custody), how the wrapped key reaches the device, and the
  records kept;
- what SPSDK's provisioning tools and EdgeLock 2GO each expect from the
  station;
- the checks a station runs before the irreversible life-cycle step, as a
  checklist for the owner.

Method: public sources only. Vendor text is summarised, not copied. For
SPSDK, the source tree was cloned at its release tag and the released wheel
was installed in a scratch virtual environment outside the repository, and
only the tool's own `--help` output and family lists were consulted (no
device was attached, no command that talks to a device was run, no template
was exported). Each claim carries a source tag in brackets, for example
`[S1]`, that refers to section 2.

## 2. Sources surveyed

| Tag | Title | Version / date | URL | Reached |
|-----|-------|----------------|-----|---------|
| S1 | SPSDK (Secure Provisioning SDK), source repository | tag `v3.13.0`, commit dated 2026-11-03 | https://github.com/nxp-mcuxpresso/spsdk | yes |
| S2 | SPSDK on PyPI | 3.13.0 (latest on 2026-11-12) | https://pypi.org/project/spsdk/ | yes |
| S3 | SPSDK user guide: `el2go-host` (`docs/apps/el2go-host.rst` in S1) | v3.13.0 | https://spsdk.readthedocs.io/en/latest/apps/el2go-host.html | yes (via S1) |
| S4 | SPSDK user guide: `nxpele` (`docs/apps/nxpele.rst` in S1) | v3.13.0 | https://spsdk.readthedocs.io/en/latest/apps/nxpele.html | yes (via S1) |
| S5 | SPSDK user guide: `nxpdevhsm` (`docs/apps/nxpdevhsm.rst` in S1) | v3.13.0 | https://spsdk.readthedocs.io/en/latest/apps/nxpdevhsm.html | yes (via S1) |
| S6 | SPSDK image guide: AHAB (`docs/images/ahab.rst` in S1) | v3.13.0 | https://spsdk.readthedocs.io/en/latest/images/ahab.html | yes (via S1) |
| S7 | SPSDK 3.13.0 command-line help: `nxpele --help`, `el2go-host --help`, `nxpimage signed-msg --help` and their `get-families` lists | 3.13.0 wheel from S2 | (generated locally from S2) | yes |
| S8 | NXP EdgeLock 2GO product page | page fetched 2026-11-12, no version shown | https://www.nxp.com/products/security-and-authentication/secure-service-2go-platform/edgelock-2go:EDGELOCK-2GO | yes (HTTP 200) |
| S9 | NXP AN14861, *Secure OEM Key Provisioning with EdgeLock Secure Enclave on RT1180* | Rev. 1.0, 13 November 2025 | https://www.nxp.com/docs/en/application-note/AN14861.pdf | yes |
| S10 | U-Boot documentation, *i.MX93 AHAB secure boot* guide (`doc/imx/ahab/guides/mx93_secure_boot.rst`) | upstream `master`, commit dated 2026-11-11 | https://docs.u-boot.org/en/latest/imx/ahab/guides/mx93_secure_boot.html | yes (source tree) |
| S11 | NXP AN14586 (EdgeLock 2GO introduction) and AN14544 (EdgeLock 2GO provisioning methods), as linked from S3 | not shown | https://docs.nxp.com/bundle/AN14586/page/topics/introduction.html, https://docs.nxp.com/bundle/AN14544/page/topics/edgelock_2go_provisioning_methods.html | page served (HTTP 200), but its content is rendered by script and could not be read: **unconfirmed** |
| S12 | NXP `imx-secure-enclave` (user-space library for the enclave on i.MX Linux) | not established | https://github.com/nxp-imx/imx-secure-enclave | reached, not read: **unconfirmed** |
| S13 | IANA, *Root KSK Ceremonies* page | page fetched 2026-11-12 (lists ceremonies up to 2027-08) | https://www.iana.org/dnssec/ceremonies | yes |

Not reached, or not public: NXP AN12312 and AN13994 (HTTP 404 at the
`nxp.com/docs` URLs tried); the i.MX 95 reference manual (IMX95RM) and the
i.MX 95 Security Reference Manual, which [SPEC.md](../SPEC.md) already lists
as missing; NXP's EdgeLock Secure Enclave user guides (AN14861 says the
RT1180 one, UG10192, is available only through NXP sales [S9]); go-xkms's
own documentation (not public as far as this lane could tell).

## 3. The key ceremony in public sources

### 3.1 The ELE key exchange and key import flow

The only public NXP document reached that walks through an OEM key import
end to end is AN14861 [S9]. It is written for the i.MX RT1180, not the
i.MX 95. In outline [S9]:

1. **Precondition.** The device's super root key hash (SRKH) is already
   fused. The life cycle need not be advanced to try the flow.
2. **NXP's key-agreement key.** The enclave holds an NXP production
   key-agreement key pair (NIST P-256, key ID `0x70000000`). Its public half
   is read from the device. SPSDK 3.13.0 has a matching command,
   `nxpele export-nxp-prod-ka-puk` [S7].
3. **Key exchange.** The host generates its own ECDH key pair. It builds a
   key-exchange request carrying the digest of its public key and the
   attributes of the key to derive, and signs that request as an ELE signed
   message with an OEM SRK, the same root key that signs the boot images.
   The enclave checks the signature, runs ECDH against its own private key
   and derives an OEM import master key (`OEM_IMPORT_MK_SK`). The host derives
   the same master key from its side of the exchange.
4. **Wrapping.** From the master key both sides derive a wrapping key and a
   CMAC key. The host wraps the OEM key (AES key wrap, RFC 3394) and signs
   the wrapped blob and its attributes with CMAC, as a key-import TLV.
5. **Import.** The device passes the TLV to the enclave's key-import command.
   The enclave unwraps it into its key store. With the sync option it hands
   back the key encrypted for storage in the device's non-volatile memory.
6. **Use.** The key is referred to by its key ID from then on. On the RT1180
   key exchange and import run under a separate "OEM provisioning" enclave
   firmware, and normal use runs under the runtime firmware.

Three points from S9 matter for the custody design:

- **The master key is shared by a fleet.** Because the enclave side uses
  NXP's production key, every device with the same SRKH derives the same
  master key for the same host key pair. The request has a salt option that
  mixes the device SRKH into the derived wrap and CMAC keys [S9]. In either
  case the master key and its derived keys are fleet secrets, not per-device
  secrets.
- **The host-side secrets are files in the walkthrough.** The host ECDH
  private key, the signing SRK (`signer: type=file;...`), the derived master
  key (written by `nxpimage signed-msg export` to an output folder) and the
  raw OEM key are all plain files on the host PC [S9]. The note
  demonstrates the mechanism and does not describe how to protect these keys.
- **Each imported key carries a life-cycle attribute.** This says whether
  the key is usable in the open life cycle, the closed one, or closed and
  locked [S9]. A key imported with the wrong attribute stops working after
  the life-cycle step.

For the i.MX 95, SPSDK 3.13.0 offers both the signed message and the
key-import TLV for the i.MX 95 families [S7], which suggests the same
mechanism. That the i.MX 95 enclave firmware implements the same key exchange
algorithm, key ID and TLV format as the RT1180 is **not confirmed** from a
public source.

### 3.2 Who is present, and the records kept

- None of the NXP or upstream sources reached (S1 to S12) describes the
  people at a provisioning station, dual control, or a ceremony log. They
  describe the commands only.
- The only provisioning record in NXP's tooling is in EdgeLock 2GO's
  product-based flow: the station keeps a local database of the secure
  objects used and uploads a provisioning report to the service [S7].
- As a public precedent from outside NXP, IANA runs its DNSSEC root key
  ceremonies on a published schedule. Each ceremony has a published agenda,
  involves named roles (crypto officers and Trusted Community
  Representatives), and the hardware is recorded as it enters and leaves
  service (HSMs introduced, replaced and destroyed are agenda items) [S13].
  This survey cites it only as an example of the record-keeping a ceremony
  can have, not as an NXP requirement.

### 3.3 What has to stay inside the HSM

Section 3.1 lists the secrets the flow uses [S9]. A go-xkms custody model
would keep all of them inside the HSM:

| Secret | Used for | In S9's walkthrough |
|--------|----------|---------------------|
| OEM SRK private keys | signing images [S6, S10] and the key-exchange signed message [S9] | PEM file |
| Host ECDH private key | key exchange with the enclave | PEM file |
| `OEM_IMPORT_MK_SK` and its wrap and CMAC keys | wrapping the OEM key | file written by SPSDK |
| The OEM keys to import | the payload | raw binary file |

SPSDK as documented performs the ECDH, the key derivation, the wrap and
the CMAC in host software [S9]. Keeping these steps inside the HSM therefore
needs an HSM that can do them itself (ECDH with the KDF the enclave uses,
RFC 3394 wrap, CMAC, and the TLV layout), or go-xkms producing the wrapped
blob inside its own custody (the requirement in
[provisioning-host-survey.md](provisioning-host-survey.md) §4 and §5).
Whether go-xkms can do either is **not confirmed** (its documentation was
not reached).

A station that runs these steps in SPSDK holds the host ECDH private key,
`OEM_IMPORT_MK_SK` and the derived wrap and CMAC keys in its own memory,
even if only for the length of the ceremony. Those are fleet secrets
(section 3.1): a compromised station could copy them from RAM and then
decrypt any captured provisioning blob for the fleet or authenticate new
imports. Holding them in host memory is the same exposure, for that
window, as the clear key-wrapping key that the provisioning host must not
hold (provisioning-host-survey §4). So, in this survey:

- **Production prerequisite.** For any key that protects a fleet, the ECDH,
  key derivation, wrap and CMAC run inside the HSM or inside go-xkms
  custody, and the station receives only the wrapped blob. Until that is
  confirmed, there is **no production import path**; production keys are
  not imported.
- **Software fallback, development only.** SPSDK with the keys in host
  memory or in files (as in S9) is acceptable only with disposable
  development keys: a throw-away host ECDH key and SRK set, on development
  boards, whose import and wrapping keys never protect a fleet key and are
  discarded after use.

## 4. What SPSDK expects from the station

SPSDK is NXP's open-source Python tool set for image building and device
provisioning [S1]. The release surveyed is 3.13.0 [S1, S2]. Four of its tools
bear on an OEM key ceremony for the i.MX 95.

### 4.1 `nxpele`: talking to the enclave

- `nxpele` sends EdgeLock Enclave messages from the host. It has three
  transports: through the MCU bootloader (`mboot`, used on the i.MX RT1180),
  through a U-Boot serial console, and through U-Boot fastboot [S4]. The two
  U-Boot transports need a U-Boot built with AHAB support, and fastboot also
  needs console multiplexing [S4]. For the i.MX 95, which boots U-Boot, the
  station would therefore talk to the enclave through a provisioning U-Boot
  on the board, not through a ROM bootloader. That `mboot` is not offered for
  the i.MX 95 is an inference from S4 naming only the RT1180 for it; not
  confirmed.
- The commands relevant to a ceremony [S7] are: reading the enclave's
  firmware version, status and information (`get-ele-fw-version`,
  `get-ele-fw-status`, `get-info`); reading fuses and shadow fuses
  (`read-common-fuse`, `read-shadow-fuse`); writing a fuse (`write-fuse`);
  sending an OEM-signed message to the enclave (`signed-message`);
  exporting NXP's production key-agreement public key
  (`export-nxp-prod-ka-puk`); reading stored enclave events (`get-events`);
  `commit`; and moving the life cycle forward to OEM closed or locked
  (`forward-lifecycle-update`). Fuse programming and the move to OEM
  closed are irreversible [S10]. None of these commands was run.

### 4.2 `nxpimage signed-msg`: preparing what the enclave accepts

- `nxpimage signed-msg` builds, parses and verifies ELE signed messages, and
  its `tlv` sub-group builds, parses and verifies a key-import TLV blob (the
  only TLV type it offers is `key_import`) [S7].
- In 3.13.0 both list the i.MX 95 (revisions a0, a1, b0) among the supported
  families, with the i.MX 8ULP, 91, 93, 943, 952 and RT118x [S7]. So the
  wrapped-key import blob and the signed message that carries it can be
  prepared off-line with SPSDK [S7, S9]. In S9 the two blobs are compiled
  into a device application that calls the enclave; whether
  `nxpele signed-message` [S7] can carry the key exchange and key import on
  the i.MX 95 instead is **not confirmed**.
- The key-exchange signed message is signed with an OEM SRK, the root key
  that also signs the boot images [S9]. The template names the SRK set,
  the SRK used, a revoke mask and the signer [S9]. A ceremony that signs a
  signed message therefore exercises the same HSM key as image signing.
  Whether SPSDK can sign through a PKCS#11 HSM directly, or only through its
  signature-provider plug-in interface, is not confirmed in this survey.

### 4.3 `nxpimage ahab`: the images the station checks

- On the i.MX 9x the boot image is a set of AHAB containers: container 0 is
  NXP's enclave firmware, signed by NXP; containers 1 and 2 (System Manager,
  OEI DDR firmware, SPL, then TF-A, U-Boot and optionally OP-TEE) are signed
  by the OEM [S6]. The i.MX 95 B0 uses AHAB container version 2 [S6].
- SPSDK can sign, re-sign and replace the encryption key blob of an existing
  image [S6]. The ceremony's link to image signing is that the SRK hash
  fused into the device must match the SRK table in these containers.

### 4.4 `nxpdevhsm`: device-HSM provisioning (not for the i.MX 95)

- `nxpdevhsm` drives a "device HSM" flow that makes the chip itself produce
  a provisioning SB3 file, over the MCU bootloader [S5]. It targets MCU
  families with the MCU bootloader; its applicability to the i.MX 95 was not
  established and it is listed only so that the owner does not mistake it for
  an HSM integration.

## 5. What EdgeLock 2GO expects from the station

EdgeLock 2GO is NXP's hosted service for provisioning keys and certificates
into NXP devices [S8]. SPSDK's `el2go-host` is the station-side client [S3].

- **Account and service set-up, before the station runs.** The OEM holds an
  EdgeLock 2GO account, creates an API key, a device group and the secure
  objects, and assigns the objects to the group [S3].
- **Network.** The station reaches the EdgeLock 2GO REST API over the
  internet and the device over UART or USB (I2C and SPI through a BusPal
  bridge) [S3]. A station that uses EdgeLock 2GO is therefore not an
  air-gapped station.
- **Device-side firmware.** The device runs the "EdgeLock 2GO NXP
  Provisioning Firmware" during provisioning [S3].
- **Two flows.** Per-device: the station reads the device UUID, registers
  it in the device group, asks the service to generate the group's secure
  objects for it, downloads them and loads them into the device [S3, S7].
  Product-based: the station draws secure objects from a pre-generated batch,
  provisions them, keeps a local database of what was used, and uploads a
  provisioning report back to the service (`prod store-report`,
  `validate-reports`, `db-stats`) [S7].
- **i.MX 95 support.** `el2go-host dev` lists the i.MX 95 (a0, a1, b0) among
  its families in 3.13.0 [S7]. The user guide's worked example and its known
  issues are written for MCX N and RT parts, with a device in ISP and FlexSPI
  boot modes [S3]; how the i.MX 95 runs the provisioning firmware (through
  U-Boot or otherwise) is not described in S3 and is not confirmed.
- **Where the OEM keys live.** In EdgeLock 2GO the secure objects are
  generated or held by NXP's service and arrive at the device already
  wrapped for it [S3, S8]; the OEM's own HSM does not hold the device keys in
  that flow. This is the main difference from a go-xkms custody model.

## 6. Pre-close checklist (before the irreversible life-cycle step)

For the owner to adopt or amend. Nothing in it was run. The closest public
procedure is U-Boot's i.MX 93 guide [S10]; the i.MX 95 equivalent was not
found, so the commands named below are those of the i.MX 93 guide and of
SPSDK 3.13.0, and their behaviour on the i.MX 95 is not confirmed.

Before the step, the station confirms and records:

1. **Life cycle is OEM open.** U-Boot's `ahab_status` prints the life
   cycle [S10]. Closing from any other state is not covered by the source.
2. **The SRK hash is fused and correct.** The fuse words read back from the
   device match the hash that the SRK tool produced from the SRK table used
   to sign the images. A wrong SRK hash leaves a part that will not boot
   [S10]. Read-back on the host: `nxpele read-common-fuse` [S7].
3. **A fully signed image boots with no enclave events.** U-Boot's
   `ahab_status` reports no events after a signed boot [S10];
   `nxpele get-events` reads the same store from the host [S7]. On the
   i.MX 95 every OEM container (System Manager, OEI DDR firmware, SPL, then
   TF-A and U-Boot) must be OEM-signed [S6].
4. **The image's SRK table is the fused one.** The signed message and image
   configurations name the SRK set, the SRK used and the revoke mask [S9].
   The station records which SRK index signed the image and the
   provisioning messages.
5. **Imported keys work after the step.** Each key imported through the
   key-import TLV has a life-cycle attribute (open, closed, closed and
   locked) [S9]. Check that keys meant for the field allow the closed life
   cycle, and that each key ID answers before the step.
6. **One-time fuse decisions are made.** Fuses tied to features have to be
   set as the owner decides, for example the i.MX 95 fast-boot enable fuse,
   which the container's fast-boot modes depend on [S6]. Whether such fuses
   can still be written after the move to OEM closed is **not confirmed**;
   the monotonic counter fuse configuration that [SPEC.md](../SPEC.md)
   names comes from a manual this lane could not reach.
7. **Versions are recorded.** The enclave firmware version and status
   (`get-ele-fw-version`, `get-ele-fw-status`) [S7], the SPSDK version, and
   the digest of the signed boot image.
8. **The step itself.** Named here for the record only; this repository
   does not run or script it. The i.MX 93 guide uses U-Boot's
   `ahab_close` [S10]; SPSDK lists `nxpele forward-lifecycle-update` [S7];
   neither was run, and their behaviour on the i.MX 95 is not confirmed.
   Afterwards, reboot and confirm
   that `ahab_status` shows OEM closed with no events [S10].

Per-device record (proposed; no public NXP source defines one, see 3.2):
device UUID or serial, SRK hash read back, SRK index used, enclave firmware
version, key IDs imported and their life-cycle attributes, image digest, life
cycle before and after, date, station and the people present.

## 7. Not confirmed

- That the i.MX 95 enclave firmware supports the key exchange and key import
  of AN14861 with the same key ID (`0x70000000`), algorithm and TLV format.
  SPSDK lists the i.MX 95 for both blobs [S7], but no i.MX 95 document was
  reached.
- How the station reaches the i.MX 95 enclave in practice: `nxpele` over
  U-Boot serial or fastboot [S4], a Linux application using
  `imx-secure-enclave` [S12], or an EdgeLock 2GO provisioning firmware.
- Whether the i.MX 95 needs a separate provisioning enclave firmware, as the
  RT1180 does [S9].
- How `el2go-host` provisions an i.MX 95, which it lists as supported [S7]
  while its guide describes MCU boot modes only [S3]; the content of AN14586
  and AN14544 [S11].
- Whether SPSDK can sign signed messages and images through a PKCS#11 HSM,
  and whether go-xkms can perform the ECDH, key derivation, RFC 3394 wrap and
  CMAC of section 3.3 inside the HSM. Until it is confirmed, production
  OEM key import has no path that this survey accepts (section 3.3,
  question 2).
- The i.MX 95 equivalents of U-Boot's `ahab_status` and `ahab_close` [S10],
  and whether fuses can be written after OEM closed.
- Who should be present at a provisioning step and what to record: no NXP
  source was found (section 3.2).

## 8. Questions for the owner

1. **Which provisioning path for the OEM keys?**
   - (a) The enclave's own key exchange and key import [S9], driven by a
     station under go-xkms custody.
   - (b) EdgeLock 2GO [S3, S8]: NXP's service generates the secure objects;
     the station needs internet access and an EdgeLock 2GO account.
   - (c) Both: EdgeLock 2GO for device credentials, (a) for the OEM's own
     keys.

   Recommendation: (a). It is the only path in which the OEM keys can stay
   in the OEM's custody, and it needs no link to NXP's service [S3, S9].
   That holds only if the ECDH, key derivation and wrap run inside the HSM
   or go-xkms custody (question 2); with SPSDK doing them on the station,
   the fleet import keys sit in host memory (section 3.3). The i.MX 95
   support is not confirmed (section 7).
2. **Where do the ECDH, key derivation and wrap run?**
   - (a) Inside the go-xkms HSM, or inside go-xkms custody with only the
     wrapped blob returned to the station.
   - (b) In SPSDK on an off-line station, with the derived keys held in
     memory only for the ceremony.
   - (c) In SPSDK as in AN14861, with the keys in files [S9].

   Recommendation: (a) is a **production prerequisite**, not a preference.
   (b) and (c) put the fleet import, wrapping and CMAC keys in host memory
   or on disk (section 3.3), so they are for disposable development keys on
   development boards only, never for keys that protect a fleet. If go-xkms
   cannot do (a), production import is blocked until it can; there is no
   production software fallback. Whether go-xkms can do (a) is not
   confirmed (section 7).
3. **Should the derived import keys be salted with the device SRKH?**
   - (a) Zero salt.
   - (b) SRKH salt [S9].

   Recommendation: (b). In S9, written for the RT1180, it ties the wrap and
   CMAC keys to one SRK set, so a leaked set of import keys is no use with
   a different SRK set. That the i.MX 95 enclave mixes the SRKH in the same
   way is **not confirmed** (section 3.1), and the keys stay shared by every
   device with that SRK set. Sources offer the option but give no guidance.
4. **How does the station reach the i.MX 95 enclave?**
   - (a) `nxpele` over U-Boot fastboot.
   - (b) `nxpele` over the U-Boot serial console.
   - (c) An on-device application (U-Boot, OP-TEE or Linux) that is given the
     signed message and TLV, as in AN14861 [S9].

   Recommendation: (a). SPSDK calls fastboot its fastest transport [S4].
   Confirm on a development board in OEM open that it works for the i.MX 95.
5. **When is the life cycle closed, and where?**
   - (a) At the provisioning station, straight after the checklist in
     section 6.
   - (b) Later, as a separate step (for example at final test).
   - (c) Never on the FRDM-IMX95-PRO development boards.

   Recommendation: (c) for development boards and (a) for production units.
   Closing a part that fails any item in section 6 leaves it unrecoverable
   [S10].
6. **Who is present at a ceremony?**
   - (a) One operator.
   - (b) Two people under dual control, each holding part of the go-xkms
     authorisation, plus a witness who signs the log.
   - (c) A scheduled ceremony on the IANA model, with published agendas and
     named roles [S13].

   Recommendation: (b) for the ceremonies that use the SRK or the import
   master key (key generation, signing, rotation); (a) for per-device
   station runs, with the go-xkms audit log as the record. No NXP source
   prescribes this (section 3.2).
7. **What is recorded, and where is it kept?**
   - (a) The per-device record of section 6, kept by the station.
   - (b) (a), plus a ceremony log signed by those present, kept with
     go-xkms's audit log.
   - (c) No formal record.

   Recommendation: (b).
8. **Which life-cycle attribute do imported keys carry?**
   - (a) Closed only.
   - (b) Open and closed.
   - (c) Closed and locked as well.

   Recommendation: none from the sources, which list the values but do not
   advise [S9]. Production keys should not be usable in open; this depends
   on question 5.
