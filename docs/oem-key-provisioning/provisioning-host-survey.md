# oem-key-provisioning — provisioning host tooling survey

> **Status: DRAFT survey for the owner** · Row: `oem-key-provisioning` ([SPEC](../SPEC.md)) · Issue #108 · Surveyed: 2026-11-12
> Public sources only. Nothing here runs or scripts a provisioning, fuse or life-cycle step.

## 1. Scope and method

This survey answers issue #108 for the `oem-key-provisioning` row: which host-side tools talk to an i.MX 95 while it is in
serial download mode, how they are released and signed, how to pin them, what the provisioning host may hold, and how it
would reach go-xkms for wrapped keys.

Method: release metadata, tags and documentation were read from the public GitHub repositories and PyPI on 2026-11-12.
Vendor text is summarised, never quoted. Every claim carries a source number from §2. Where a fact could only be inferred,
the text says so, and §7 lists everything not confirmed. No tool was run against hardware, and nothing in this file is a
provisioning, fuse or life-cycle procedure.

## 2. Sources

| # | Title | Version / tag | URL |
|---|---|---|---|
| S1 | SPSDK (Secure Provisioning SDK), GitHub release | v3.13.0, published 2026-11-03, tag commit `e104adf5…` | https://github.com/nxp-mcuxpresso/spsdk/releases/tag/v3.13.0 |
| S2 | SPSDK on PyPI, project metadata and files | 3.13.0 (wheel and sdist), requires Python ≥ 3.10 | https://pypi.org/project/spsdk/3.13.0/ |
| S3 | PyPI integrity API, provenance of `spsdk-3.13.0-py3-none-any.whl` | 3.13.0 | https://pypi.org/integrity/spsdk/3.13.0/spsdk-3.13.0-py3-none-any.whl/provenance |
| S4 | SPSDK user guide, *nxpele* (`docs/apps/nxpele.rst` in the source tree) | v3.13.0 | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/docs/apps/nxpele.rst |
| S5 | SPSDK user guide, *nxpuuu* (`docs/apps/nxpuuu.rst`) | v3.13.0 | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/docs/apps/nxpuuu.rst |
| S6 | SPSDK user guide, *sdpshost* (`docs/apps/sdpshost.rst`) | v3.13.0 | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/docs/apps/sdpshost.rst |
| S7 | SPSDK release notes (`docs/release_notes.rst`) | v3.13.0 | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/docs/release_notes.rst |
| S8 | SPSDK source tree: `spsdk/apps/` and `spsdk/data/devices/` directory listings | v3.13.0 | https://github.com/nxp-mcuxpresso/spsdk/tree/v3.13.0/spsdk |
| S9 | mfgtools (uuu), GitHub release | uuu_1.5.243, published 2025-12-16, annotated tag `bb04dcf4…` | https://github.com/nxp-imx/mfgtools/releases/tag/uuu_1.5.243 |
| S10 | GitHub REST API, tag and commit verification for S1 and S9 | as above | https://api.github.com/repos/nxp-imx/mfgtools/git/tags/bb04dcf48c7be428bd6d9b6d50b15c021bdd6495 , https://api.github.com/repos/nxp-mcuxpresso/spsdk/commits/e104adf55184fd6a987d42c506afbce4b9eae807 |
| S11 | This repository: [SPEC.md](../SPEC.md) row `oem-key-provisioning`, and [references/README.md](../references/README.md) §"The Code Signing Tool in the build" | main at the time of writing | (in-repo) |
| S12 | mfgtools README (`README.md` at the tag) | uuu_1.5.243 | https://github.com/nxp-imx/mfgtools/blob/uuu_1.5.243/README.md |
| S13 | `libuuu` on PyPI, project metadata and files | 1.5.243 | https://pypi.org/project/libuuu/1.5.243/ |
| S14 | PyPI integrity API, provenance of `libuuu-1.5.243-py3-none-manylinux_2_28_x86_64.whl` | 1.5.243 | https://pypi.org/integrity/libuuu/1.5.243/libuuu-1.5.243-py3-none-manylinux_2_28_x86_64.whl/provenance |
| S15 | go-xkms specification (`docs/SPEC.md`), rows `hsm-device-protocol`, `key-policy-and-crypto`, `authz-device-onboarding` | `main` at commit `d55b1b73c78f22610e60f08020027c4c2caac62b` | https://github.com/jeremyhahn/go-xkms/blob/d55b1b73c78f22610e60f08020027c4c2caac62b/docs/SPEC.md |
| S16 | go-xkms `docs/key-policy-and-crypto/README.md` | same commit | https://github.com/jeremyhahn/go-xkms/blob/d55b1b73c78f22610e60f08020027c4c2caac62b/docs/key-policy-and-crypto/README.md |
| S17 | go-xkms `docs/architecture/README.md` (command list, including `pkcs11-module`) | same commit | https://github.com/jeremyhahn/go-xkms/blob/d55b1b73c78f22610e60f08020027c4c2caac62b/docs/architecture/README.md |

## 3. Host-side tools for serial download mode

### 3.1 SPSDK: blhost and nxpele

- **Release surveyed.** SPSDK v3.13.0 is the latest GitHub release (S1) and the latest PyPI release (S2). It ships, among
  others, the applications `blhost`, `sdphost`, `sdpshost`, `nxpele`, `nxpuuu`, `nxpfuses`, `nxpimage` and `nxpdevhsm`
  (S8, `spsdk/apps/`).
- **i.MX 95 support.** The device database has entries for the i.MX 95 part numbers (`mimx9596`, `mimx95294` and others;
  S8), and the release notes record i.MX 95 work on AHAB containers, fuses (including the OEM SRK hash locks) and the
  enclave keystore, through several releases up to v3.13.0 (S7). Which part number the FRDM-IMX95-PRO carries was not
  checked against the board manual in this survey (§7).
- **nxpele.** It talks to the EdgeLock Enclave in three modes: over mboot (named for the i.MX RT1180, with a flashloader
  in target memory), over the U-Boot serial console, or over U-Boot fastboot; both U-Boot modes need U-Boot built with
  AHAB support, and the fastboot mode also needs console multiplexing (S4). The guide ties only the mboot mode to a device
  (the i.MX RT1180) and names the i.MX 93 as another target without saying which mode it uses (S4). That the i.MX 95 uses
  the U-Boot modes is an inference, not a stated fact (§7).
- **blhost.** It speaks NXP's mboot protocol to a ROM or flashloader (S4 describes nxpele's mboot mode as relying on the
  blhost connection options). No source read here states that the i.MX 95 boot ROM in serial download mode answers mboot;
  the serial download protocols of the i.MX applications processors are SDP and SDPS (inferred from the tool names, not
  from an i.MX 95 document), for which SPSDK has `sdphost`/`sdpshost` (S6) and uuu has its own
  implementation (S9). **Whether blhost has any role on the i.MX 95 is not confirmed** (§7).
- **sdpshost.** SPSDK marks it as a prototype that is not tested (S6), so it is a poor base for a production flow.
- **The flow this implies (inferred).** The host loads a U-Boot with AHAB support over serial download mode with uuu
  (§3.2), then nxpele talks to the enclave through that U-Boot. Any provisioning step on that path is out of scope here.

### 3.2 uuu (mfgtools)

- **Release surveyed.** uuu_1.5.243 is the latest mfgtools release (S9). It ships prebuilt binaries for Linux x86-64
  (also an Ubuntu 20.04 build), Linux aarch64 and armv7, macOS arm64 and Windows, the source as tar.gz and zip, and a
  PDF manual (S9).
- **What it is.** NXP's universal update utility for loading and flashing images on i.MX processors over the serial
  download protocols and fastboot (S5 describes the same engine as used by SPSDK). It is BSD licensed, with LGPL libusb
  linked statically into the Windows binary (S12).
- **Inside SPSDK.** SPSDK 3.13.0 depends on the Python package `libuuu` (>= 1.5.239, < 2) (S2), which is published from
  mfgtools' own `wrapper` directory at the same version, 1.5.243 (S13). SPSDK's `nxpuuu` drives that library (S5). So one
  pinned SPSDK install can carry uuu with it, without a separate binary.
- **i.MX 95 support.** The uuu README surveyed does not list supported SoCs (S12), and the release body for 1.5.243 is
  empty (S9). SPSDK's `nxpuuu` guide shows `-f <family>` for its built-in scripts, with i.MX 8ULP and i.MX 943 examples
  (S5). **That uuu 1.5.243 or `nxpuuu` 3.13.0 lists the i.MX 95 family was not confirmed from a document** (§7).

### 3.3 Release signing and how to pin each tool

| Tool | Channel | Publisher signature | What can be checked | Pin by |
|---|---|---|---|---|
| SPSDK 3.13.0 | PyPI wheel and sdist | PyPI provenance attestation (Sigstore-backed, in-toto statement) naming the publisher as GitHub repository `nxp-mcuxpresso/spsdk`, workflow `deploy.yml` (S3) | the file's SHA-256 against the attestation's subject digest; the attestation's publisher identity | exact version plus SHA-256 hash of each file, in a hash-locked requirements file, with every transitive dependency also hash-pinned |
| SPSDK 3.13.0 | GitHub tag | the tag is lightweight (it points straight at a commit); that commit shows as *verified* on GitHub, made by GitHub's web-flow identity (S10) | the commit SHA | the commit SHA `e104adf55184fd6a987d42c506afbce4b9eae807` |
| libuuu 1.5.243 | PyPI wheels and sdist | PyPI provenance attestation naming GitHub repository `nxp-imx/mfgtools`, workflow `build_wrapper.yaml` (S14) | as for SPSDK | as for SPSDK |
| uuu 1.5.243 | GitHub release binaries | **none found**: the annotated tag `uuu_1.5.243` is unsigned (S10), and the release carries no signature or checksum file (S9). GitHub's API reports a SHA-256 digest for each asset (S9), but that is computed by GitHub, not signed by NXP | the asset digest, and a rebuild from the source archive | the SHA-256 of the binary, or build from the tag's source and pin the source archive's SHA-256 |

Observations:

- The PyPI attestations are the only publisher-bound signatures found for any of these tools. They bind a file to a
  GitHub workflow in NXP's organisation; they do not carry an NXP release key (S3, S14).
- Neither repository signs its release tags with a GPG or SSH key the survey could find (S10). A hash pin is
  therefore the main control, with the PyPI attestation as a second check for the Python packages.
- The prebuilt uuu binary has the weakest chain. Taking uuu through `libuuu` (attested) inside SPSDK, rather than
  the standalone binary, gives one attested source for both tools.

## 4. What the provisioning host holds and must not hold

The row's flow, after AN14861, is a key exchange with the enclave followed by the import of a wrapped OEM key (S11, citing
AN14861 §2, §5.2, §5.3 and RM00284 §3.20). AN14861 is in the private context repository, not a public source, so this
section relies only on what SPEC.md already records about it and on the public tool sources.

**May hold** (all public or integrity-checked):

- the pinned tools of §3.3 and their lock file, checked before use (§6);
- the boot images the flow loads over serial download mode (a signed U-Boot with AHAB support, S4), taken from this
  repository's build by digest;
- public material only: the SRK table and its hash, the enclave's public key-exchange output, and certificates. The host
  relays the enclave's key-agreement public key but is not trusted for it: go-xkms authenticates it independently of the
  host before wrapping (§5);
- the wrapped key blobs, but only as **potentially reusable provisioning credentials**, not as harmless data. The SPEC
  row describes import of a wrapped key (S11), but no source read here shows that a blob is bound to one device: the
  key-ceremony survey ([key-ceremony-survey.md](key-ceremony-survey.md) §3.1) records that the import and wrapping keys
  are shared by every device with the same SRK hash, and neither survey shows a separately authenticated device UID in
  the import TLV. Device binding on the i.MX 95 is **unconfirmed** (§7). Until it is verified, a blob may import into
  any device of the fleet, so the host holds blobs under the same access controls as the session credential below: only
  the provisioning account reads them, they are kept only for the wrap-to-import window of one device and then
  deleted, and they never leave the host except to the device being provisioned;
- a session credential to go-xkms (§5), short-lived and scoped to the wrap operation, not a key.

**Must not hold:**

- any OEM private key, SRK private key or key-wrapping key in the clear: in this repository's model, signing keys stay in
  an HSM under go-xkms custody (S11, the boot-container row, after AN14471);
- a PKCS#11 PIN or token for the signing HSM stored on disk;
- any script that writes fuses or moves the life cycle: those steps are outside this survey and this repository's lanes.

SPSDK can sign through an external signer: its PyPI metadata offers a `pkcs11` extra (S2), and go-xkms ships a
`pkcs11-module` command (S17). Whether SPSDK's PKCS#11 path can drive go-xkms's module for AHAB signing was not tested
(§7).

## 5. Reaching go-xkms for wrapped keys

What go-xkms's public documents say today (S15, S16, S17, at go-xkms `main`, commit `d55b1b73c78f…`):

- go-xkms owns `hsm-device-protocol`, status *future*: the wire protocol between xkmsd and an HSM device, with the
  FRDM-IMX95-PRO as the first device. Its open questions are the direct-attach transport and the network protocol surface
  (S15). That protocol is for the device in service, running xkmsd on its Linux side; it is not a provisioning-host
  protocol.
- The `xkms.v1` key-management service is shipped and serves a `Rewrap` utility, wrapped data keys, key metadata that
  reports exportability, and gated export paths (`ExportKey`, `ExportKeyMaterial`, `WrapKeyByID`), each behind a
  permission, on every transport (S15, S16).
- No go-xkms row read here names the EdgeLock enclave's key-import format, AN14861, or a provisioning-host client (S15).

So the provisioning host would reach go-xkms as an ordinary authenticated client of `xkms.v1`, asking it to wrap an OEM key
for one device's enclave and returning only the wrapped blob. **What go-xkms decides, not this repository:**

1. whether it produces the enclave's import format itself (a new go-xkms row), or exports under a generic wrap that a
   host-side tool reshapes (which would put key material on the host: rejected by §4);
2. the permission and identity a provisioning host uses, and whether that identity is a device-onboarding permission
   (S15 lists `authz-device-onboarding` as planned);
3. the transport the host uses (REST, gRPC or other; S16 says every transport serves the key-management RPCs).

This repository only states the requirement: the wrap happens inside go-xkms custody, and the host receives only the
wrapped blob. The repository also asks for the blob to be bound to one device, but whether the i.MX 95 import format can
do that is unconfirmed (§7), so host custody must not rely on it.

The wrap is only as safe as the peer key it is made for. The enclave's key-agreement public key reaches go-xkms through
the host, and a compromised host could substitute a public key whose private half it knows, then unwrap the OEM key from
the blob go-xkms returns, with every secret still inside go-xkms. Signing the exchange request does not prevent this; it
authenticates the OEM to the enclave, not the enclave's key to go-xkms. So the requirement also includes: **before any
production wrap, go-xkms verifies the peer key itself**, against an NXP key-agreement public key it trusts from an
authenticated NXP source, or against authenticated evidence that binds the peer key to the device, checked against an NXP
root go-xkms trusts. Neither mechanism is documented in a public source for the i.MX 95 (§7), so production import stays
blocked until one is confirmed from vendor documents ([key-ceremony-survey.md](key-ceremony-survey.md) §3.3).

## 6. How this repository would pin and check the tools

The model is the CST rule in [references/README.md](../references/README.md) (S11): the build never reads the tool from
this tree, takes its location from an environment variable, stops and names the variable when it is unset, and
`.gitignore` keeps the archive out. Applied to the provisioning host tools (a proposal, not built in this lane):

- **Where.** `SPSDK_VENV` names a Python virtual environment outside the repository; `UUU_PATH` names a standalone uuu
  binary only if the owner chooses the binary over `libuuu` (Q2). A step that needs a tool and finds its variable unset
  stops and names it.
- **What is pinned in the repository.** A hash-locked requirements file for SPSDK 3.13.0 and its whole dependency closure
  (including `libuuu` 1.5.243), every line with `--hash=sha256:`; for a standalone uuu, the release tag and the asset's
  SHA-256. The SPSDK wheel's SHA-256 at the time of writing is
  `2826ce4960db848b4bc4922d6e925e6654d55da4a7097c62e63c71c143d16df4` (S3).
- **How it is checked.** Install with hash checking required (pip's `--require-hashes`), then check the PyPI provenance
  of SPSDK and libuuu against the expected publisher repository and workflow (S3, S14). For a uuu binary, compare its
  SHA-256 with the pinned value. A mismatch stops the step.
- **CI.** A CI job can verify the lock file and the attestations without a board and without running any tool against a
  device: it installs, checks, and runs `--version` only.
- **Updates.** The repository's latest-version check (SPEC release criteria) reports a newer SPSDK or uuu; a bump is a
  reviewed change to the lock file.

## 7. Not confirmed

1. Whether the i.MX 95 boot ROM in serial download mode answers blhost (mboot) at all; this survey infers it does not and
   that the path is SDPS to load U-Boot, then nxpele over U-Boot (§3.1).
2. Which nxpele mode the i.MX 95 uses; the guide does not say (S4).
3. Whether uuu 1.5.243 and SPSDK's `nxpuuu` name the i.MX 95 family for their built-in scripts (§3.2).
4. The SoC part number on the FRDM-IMX95-PRO, and so which SPSDK device entry applies (UM12527 is private, not read here).
5. Whether a wrapped key from the AN14861 flow is bound to one device, and its format on the i.MX 95 (AN14861 is written
   for the RT1180, S11; IMX95RM and the i.MX 95 Security Reference Manual are missing). The key-ceremony survey records
   fleet-shared import and wrapping keys for devices with the same SRK hash, and no source read shows a separately
   authenticated device UID in the import TLV. Until binding is verified, the host treats every blob as a reusable
   provisioning credential (§4); its custody does not rest on the blob being useless on another device.
6. Whether SPSDK's PKCS#11 signer works with go-xkms's PKCS#11 module.
7. NXP's public SPSDK and uuu product pages were not read; the GitHub and PyPI sources were used instead. Any signing
   NXP applies on its own download site (outside GitHub and PyPI) is not confirmed.
8. Whether the uuu Windows and macOS binaries are code-signed by NXP with an Authenticode or Apple identity; not checked.
9. How go-xkms can authenticate the enclave's key-agreement public key independently of the host: whether NXP publishes
   or signs the production key-agreement public key through a channel go-xkms can verify, or whether the enclave's
   attestation binds it to the device. Neither is shown in a public source; production import is blocked until one is
   confirmed (§5; key-ceremony survey §3.3, §7).

## 8. Questions for the owner

1. **Which tools does the provisioning host carry?**
   Options: (a) SPSDK only, with uuu through its `libuuu` dependency and `nxpuuu`; (b) SPSDK plus the standalone uuu
   binary; (c) the standalone uuu plus a separate nxpele install.
   Recommendation: (a). It is one install with publisher attestations for both parts (S3, S14), where the standalone
   binary has no signature (S9, S10).
2. **How is uuu taken if a standalone binary is needed?**
   Options: (a) the release binary pinned by SHA-256; (b) built from the `uuu_1.5.243` source archive in this
   repository's devcontainer, with the archive pinned by SHA-256.
   Recommendation: (b), since the release carries no publisher signature (S9, S10).
3. **Is blhost in scope?**
   Options: (a) drop it from the i.MX 95 flow unless an i.MX 95 source shows the ROM speaks mboot; (b) keep it listed
   pending IMX95RM.
   Recommendation: (a), revisited when IMX95RM is in references (§7 item 1).
4. **Where does the OEM key get wrapped for the enclave?**
   Options: (a) a new go-xkms row that produces the enclave's import blob inside go-xkms custody; (b) a generic go-xkms
   export reshaped on the host.
   Recommendation: (a). Option (b) puts key material on the host, which §4 rules out. This is go-xkms's decision; the
   question here is whether to ask go-xkms for the row. The row must include go-xkms's own check of the enclave's
   key-agreement public key before wrapping (§5); without it, (a) does not keep the OEM key from a compromised host.
5. **What identity does the provisioning host present to go-xkms?**
   Options: (a) a device-onboarding permission (go-xkms `authz-device-onboarding`, planned, S15); (b) a dedicated
   provisioning-station service account.
   No recommendation: the sources do not settle it; go-xkms decides.
6. **How strict is the pin check?**
   Options: (a) hashes only; (b) hashes plus PyPI provenance checked against the publisher repository and workflow.
   Recommendation: (b): the attestations exist for both packages today (S3, S14).
7. **Which SPSDK version is the floor?**
   Options: (a) 3.13.0, the latest at the time of writing (S1); (b) an earlier release the owner has already validated.
   Recommendation: (a), since the release notes list i.MX 95 keystore and fuse fixes through recent releases (S7).
