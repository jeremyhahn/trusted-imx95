# Device identity and enrollment protocols: a survey

Row: device-lifecycle. Issue #78. Status: survey, input to the owner's choice.

## 1. Scope and method

This survey compares the public protocols the board could use to obtain
its operational certificate for a key that is generated in, and never
leaves, the EdgeLock Enclave (ELE) key store (SPEC row
`secure-key-handling`). For each it records how the enclave's
attestation evidence can travel with the request, and how the issued
certificate is bound to the enclave-held key. It closes with the fit to
go-trusted-platform's enrollment, as input only: go-trusted-platform
owns enrollment and decides for itself ([SPEC](../SPEC.md), Purpose).

Method: public sources only, fetched on 2026-11-12. IETF documents were
read at the revision named in §11. Vendor material is summarised, not
quoted. Nothing here runs or scripts a fuse, life-cycle or provisioning
step. What could not be confirmed is listed in §10.

The evidence format itself (what the enclave signs, and the root it
chains to) is the subject of issue #40 and an open SPEC question; this
survey treats it as an opaque, signed blob that names the key.

## 2. What the device needs from an enrollment protocol

Derived from the SPEC rows `secure-key-handling` and `device-lifecycle`:

1. **Key stays in the enclave.** The protocol must work with a CSR (or
   equivalent) signed by the enclave; server-side key generation, where
   the CA ships a private key to the device, does not meet the row.
2. **Proof of possession** of the enclave key, which every protocol here
   gets from the CSR self-signature.
3. **Evidence that the key is enclave-held** and that the device is in an
   accepted state, bound to that same public key and fresh.
4. **Initial trust** for the first request: a factory identity, a shared
   secret, or the attestation itself.
5. **Renewal** with the operational certificate, without a person.
6. A transport the Linux side can drive (HTTPS; CoAP is optional).

## 3. EST (RFC 7030)

Sources: RFC 7030 (October 2013) [S1]; RFC 8951 (November 2020),
clarifying transfer encodings [S2]; RFC 9908, which updates RFC 7030's
CSR attributes [S3]; RFC 9148, EST over CoAPS (April 2022) [S4].

How it works [S1]: the client talks HTTPS to `/.well-known/est/`.
`/cacerts` returns the CA chain, `/simpleenroll` takes a PKCS#10 CSR and
returns the certificate, `/simplereenroll` renews with the current
certificate as the TLS client credential, `/csrattrs` tells the client
what the CA wants in the CSR, and the optional `/serverkeygen` returns a
server-made key (which this row excludes, §2). The client authenticates
with a TLS client certificate (a factory certificate on first
enrollment, the operational one on renewal) or with HTTP authentication.
RFC 7030 also defines an optional link between the CSR and the TLS
session: the client puts the TLS `tls-unique` value in the CSR's
challengePassword so the CA knows the key holder is the TLS peer
[S1 §3.5].

What is new since RFC 7030:

- **CSR templates.** RFC 9908 lets the server answer `/csrattrs` with a
  partly filled CSR template, so the CA can state exactly which
  extensions and key type it expects [S3 §3.4]. A CA can use this to ask
  for an attestation attribute.
- **Evidence in the CSR.** `draft-ietf-lamps-csr-attestation-33` defines
  a PKCS#10 attribute (and a CRMF extension) carrying an
  *AttestationBundle*: one or more typed attestation statements plus
  optional certificates to verify them [S7 §4]. Since EST carries a
  plain PKCS#10, the bundle rides through `/simpleenroll` unchanged.
- **Freshness nonce.** `draft-ietf-lamps-attestation-freshness-10`
  adds an EST `/.well-known/est/getnonce` endpoint (and CMP and CMC
  equivalents) so the device can fetch a nonce from the RA/CA and put it
  in its evidence before building the CSR [S8 §5].

Key binding: the CSR self-signature proves possession; the evidence must
then name the CSR's public key (directly, or by a verifiable reference
defined by the evidence format), and the draft makes the CA/RA
responsible for checking that binding before it relies on any attested
key property [S7 §6.1].

Related: BRSKI (RFC 8995) [S9] builds zero-touch onboarding on EST,
using the manufacturer's IDevID certificate and a signed voucher to
establish trust in the registrar before enrolling. It is relevant if
the board ships with a factory identity; whether the FRDM-IMX95 carries
an IDevID-style certificate is not confirmed (§10).

## 4. ACME with device attestation

Sources: ACME is RFC 8555 [S5]; the device attestation extension is the
IETF ACME working group draft `draft-ietf-acme-device-attest-10`
(10 August 2026) [S6]. Datatracker shows it as *Submitted to IESG for
Publication*, intended Proposed Standard, on 2026-11-12. It is not an RFC
yet.

How it works, in summary [S6 §3–§5]:

- Two new ACME identifier types. `permanent-identifier` names the device
  (typically a manufacturer serial, optionally with an assigner OID), and
  is carried in the certificate as an RFC 4043 PermanentIdentifier SAN.
  `hardware-module` names the secure cryptoprocessor that generated the
  key (serial plus a type OID), carried as an RFC 4108
  HardwareModuleName SAN [S6 §3, §4].
- A new challenge type, `device-attest-01`. The client builds the RFC
  8555 key authorization from the challenge token and its account key,
  and produces a WebAuthn *attestation object* whose signed input is that
  key authorization (or the token alone, for formats where an external
  authority signs before the account key is known). It posts the object
  in an `attObj` field [S6 §5].
- The server verifies the attestation statement with the WebAuthn
  procedure, checks the signed input matches what it stored, and checks
  the device identifier inside the statement matches the order [S6 §5].
- For enterprise PKI the draft recommends external account binding, and
  allows `device-attest-01` beside other challenge types so a mixed fleet
  can migrate [S6 §6.1].

Evidence and key binding. The evidence travels inside the challenge
response, not inside the CSR. Freshness comes from the ACME token, and
the account key is bound when the full key authorization is signed. The
draft relies on the attestation *format* to say which key the statement
covers; in the text read, it does not itself require the CSR's public
key to be the attested key. That check is format-specific and a server
policy matter (unconfirmed beyond [S6] §5 and §6.2).

Fit for the enclave. A WebAuthn attestation format is identified by a
string registered with IANA [S6 §5]. No format for the NXP EdgeLock
Enclave was found in the WebAuthn registry (unconfirmed: the registry
was not fetched in this lane; see §10). Using `device-attest-01` with the
enclave would therefore need either a private format identifier, or the
enclave's evidence wrapped in a generic one such as a RATS conceptual
message wrapper (§7). go-trusted-platform's own ACME support is covered
in §9.

## 5. SCEP (RFC 8894)

Source: RFC 8894, *Simple Certificate Enrolment Protocol*, September
2020, Informational [S10].

How it works [S10]: the client wraps a PKCS#10 CSR in a CMS
signed-and-enveloped message and sends it over HTTP to the CA. First
enrollment is usually authorised by a shared secret in the CSR's
challengePassword attribute; the client signs the outer message with a
self-signed certificate or an existing one, and renewal is signed with
the current certificate. Capability discovery (`GetCACaps`), polling for
pending requests and certificate retrieval are part of the protocol.

Evidence and key binding: RFC 8894 defines no attestation carriage.
Possession is proved only by the CSR signature. Because the request is
a PKCS#10, the csr-attestation attribute [S7] could in principle ride
inside it, but neither RFC 8894 nor the freshness draft [S8] defines a
SCEP binding for evidence or for a nonce (the freshness draft covers
CMP, EST and CMC only). The shared-secret model is also a weak initial
trust for a fleet. SCEP is listed for completeness; it does not meet
§2 item 3 without non-standard additions.

Also seen: CMP (RFC 9810, July 2025, with the Lightweight CMP profile
RFC 9483) [S11] and CMC (RFC 10002, July 2026) [S12] carry CRMF or
PKCS#10 requests, and both are covered by the csr-attestation and
freshness drafts [S7 §6.2, S8 §4, §6]. They are not in issue #78's list
and are not surveyed further here.

## 6. Vendor service: NXP EdgeLock 2GO

Sources: the NXP `el2go-agent` repository on GitHub, tag `v6.5.2`
(`doc/introduction.rst` and the source tree) [S13]. NXP's product pages
for EdgeLock 2GO returned 404 from this lane, and the agent docs point
to NXP application note AN12691, which was not read (§10).

What it is, as the agent repository describes it [S13]: EdgeLock 2GO is
an NXP-hosted cloud service that provisions keys and credentials into
NXP secure hardware and helps onboard the device to the customer's own
cloud. The on-device agent opens a secure connection to a per-account
EdgeLock 2GO hostname, reports device status, and receives "secure
objects" (keys, certificates, configuration). A device is tied to an
account either by registering its chip UID or by injecting a claim
code. The service is reached through NXP's own protocol (protobuf
message definitions are in `doc/protobuf`), not through EST, ACME or
SCEP.

Platforms in the v6.5.2 tree: SE05x secure elements, TF-M/PSA targets,
a PSA simulator, and an `smw` platform (NXP Secure Middleware, the
library the i.MX application processors use to reach the EdgeLock
Enclave) [S13, `platform/`]. Whether the i.MX 95 is a supported target,
and whether the SE051 on the FRDM board (SPEC row
`secure-key-handling`) could be its anchor instead, is not confirmed.

Evidence and key binding: the trust comes from NXP's per-chip identity
provisioned at manufacture, and the service, not the customer's CA,
does the device authentication. It is not a way to carry the enclave's
attestation evidence to a third-party CA. It would put an NXP cloud
service in the enrollment path, which is a dependency decision, not a
protocol one.

## 7. Carrying the enclave's attestation evidence

The enclave offers device attestation through its HSM API (RM00284
§3.12, cited by [SPEC](../SPEC.md), row `device-lifecycle`); the format
and root are open (#40). Whatever the format, there are three standard
places to put it:

| Carriage | Defined by | Used with | Key binding |
|---|---|---|---|
| PKCS#10 attribute / CRMF extension `id-aa-attestation` holding an AttestationBundle | `draft-ietf-lamps-csr-attestation-33` [S7] | EST, CMP, CMC, SCEP (no SCEP freshness binding) | The evidence must name the CSR key; the CA/RA must validate that link [S7 §6.1] |
| WebAuthn attestation object in the ACME challenge response (`attObj`) | `draft-ietf-acme-device-attest-10` [S6] | ACME | Signed over the ACME key authorization; the attested key versus the CSR key is format-specific [S6 §5, §6.2] |
| Conceptual Message Wrapper (CMW), as CBOR tag, JWT/CWT claim or X.509 extension | RFC 9999 [S14] | Either of the above, as the inner statement | A wrapper only; binding comes from the wrapped evidence |

Freshness: for the CSR route, `draft-ietf-lamps-attestation-freshness-10`
gives EST, CMP and CMC a nonce request [S8]; for ACME the challenge
token is the nonce [S6 §5].

A practical consequence: an enclave evidence format needs a type
identifier on either route, an OID for the CSR route or a WebAuthn
format string for ACME. Wrapping it in a CMW [S14] would let one
encoding serve both, with a single CMW type for the enclave. No
registered identifier for EdgeLock Enclave evidence was found (§10).

## 8. Comparison

Against the needs in §2:

| Need | EST | ACME + device-attest | SCEP | EdgeLock 2GO |
|---|---|---|---|---|
| Status | RFC 7030, updated by RFC 8951 and RFC 9908 | RFC 8555 + Internet-Draft -10 (at IESG) | RFC 8894, Informational | Vendor service, closed protocol |
| Key generated in the enclave, CSR signed there | Yes (`/simpleenroll`) | Yes (finalize CSR) | Yes | Unconfirmed for the i.MX 95 |
| Evidence carriage | CSR attribute [S7] (draft) | `attObj` in challenge [S6] (draft) | CSR attribute only, no defined freshness | Not for a third-party CA |
| Freshness | `getnonce` [S8] (draft) | Challenge token | None defined | Service-internal |
| First-contact trust | TLS client cert (factory identity) or HTTP auth; BRSKI for zero-touch [S9] | External account binding, or the attestation itself [S6 §6.1] | Shared challenge password | NXP chip UID or claim code |
| Renewal | `/simplereenroll` with the current cert | New order with the same account | Renewal request signed by current cert | Service pushes updates |
| Third-party dependency | None | None | None | NXP cloud |

## 9. Fit with go-trusted-platform's enrollment

Source: the go-trusted-platform repository, branch `main` at commit
`641fd51b21fa` (2026-11-11): `docs/ca/acme.md`,
`docs/device/architecture.md` and the source tree [S15]. This is input
for go-trusted-platform's owner; it decides nothing for that project.

What it already has [S15]:

- An RFC 8555 ACME server. Its documented challenge set includes the
  standard `http-01` and `dns-01`, a custom `enroll-01` that issues a
  TPM-anchored IDevID (the client submits a TCG-CSR-IDEVID with the IAK
  public key, the IAK-signed CSR and the EK certificate; the server then
  runs TPM credential activation against the EK before it finalises),
  `endorse-01` for TPM EK certificates, and `device-attest-01` listed in
  the configuration example (`docs/ca/acme.md`).
- Reference copies of `draft-ietf-acme-device-attest-10` and
  `draft-ietf-lamps-csr-attestation-30` under `docs/reference/`.
- The IDevID, held in the TPM, as the runtime mTLS credential for the
  device's later calls (`docs/device/architecture.md` §4.4, §5).
- No EST or SCEP code paths were found in the tree listing.

Where the i.MX 95 differs: go-trusted-platform's enrollment is built on
a TPM (EK, IAK, credential activation). The FRDM-IMX95 has the EdgeLock
Enclave and an SE051; no TPM is named in SPEC. The enclave has no EK
and no TPM credential activation, so `enroll-01` does not apply as is.

Options, as input:

1. **ACME `device-attest-01` with an enclave attestation format.** Fits
   the ACME server go-trusted-platform already runs and the draft it
   already tracks. Needs an attestation format identifier for the
   enclave and a verifier for it on the server side. Where the
   `device-attest-01` handler is implemented, and which formats it
   accepts, was not confirmed (§10).
2. **A new ACME challenge for the enclave**, in the pattern of
   `enroll-01`, carrying the enclave evidence in place of the TCG-CSR.
   Closest to the existing code, but a private extension.
3. **ACME finalize with the csr-attestation attribute** [S7] in the CSR,
   with an existing challenge for the identifier. Uses the standard CSR
   carriage and would carry over to EST unchanged.
4. **EST with csr-attestation and the freshness nonce** [S3, S7, S8].
   Standard and widely implemented, but new to go-trusted-platform.

## 10. Not confirmed

- NXP EdgeLock 2GO product pages (several nxp.com URLs returned 404 on
  2026-11-12) and NXP AN12691 were not read. Whether EdgeLock 2GO
  supports the i.MX 95's enclave is unconfirmed.
- The format of the enclave's attestation evidence (RM00284 §3.12):
  RM00284 is in the private vendor repository, which this lane cannot
  read; this survey relies on SPEC's citation only (#40).
- Whether the FRDM-IMX95 leaves the factory with any NXP-signed device
  identity certificate usable as an IDevID for EST or BRSKI.
- The IANA WebAuthn attestation format registry was not fetched; no
  enclave format is claimed to exist or not exist beyond what §4 says.
- go-trusted-platform: where `device-attest-01` is implemented and
  which attestation formats it verifies. The tree has no `pkg/acme`
  server code besides storage, so the server may live in a dependency;
  not traced.
- Final RFC numbers for the two drafts [S6, S7] and the freshness draft
  [S8]; all three were drafts on 2026-11-12.

## 11. Sources

All fetched 2026-11-12.

- [S1] RFC 7030, *Enrollment over Secure Transport*, October 2013.
  <https://www.rfc-editor.org/rfc/rfc7030>
- [S2] RFC 8951, *Clarification of Enrollment over Secure Transport
  (EST): Transfer Encodings and ASN.1*, November 2020.
  <https://www.rfc-editor.org/rfc/rfc8951>
- [S3] RFC 9908, *Clarification and enhancement of RFC7030 CSR
  Attributes definition* (published from
  `draft-ietf-lamps-rfc7030-csrattrs-23`).
  <https://www.rfc-editor.org/rfc/rfc9908>
- [S4] RFC 9148, *EST-coaps: Enrollment over Secure Transport with the
  Secure Constrained Application Protocol*, April 2022.
  <https://www.rfc-editor.org/rfc/rfc9148>
- [S5] RFC 8555, *Automatic Certificate Management Environment (ACME)*,
  March 2019. <https://www.rfc-editor.org/rfc/rfc8555>
- [S6] `draft-ietf-acme-device-attest-10`, *Automatic Certificate
  Management Environment (ACME) Device Attestation Extension*,
  10 August 2026.
  <https://datatracker.ietf.org/doc/draft-ietf-acme-device-attest/10/>
- [S7] `draft-ietf-lamps-csr-attestation-33`, *Use of Remote
  Attestation with Certification Signing Requests*, November 2026.
  <https://datatracker.ietf.org/doc/draft-ietf-lamps-csr-attestation/33/>
- [S8] `draft-ietf-lamps-attestation-freshness-10`, *Requesting a
  Freshness Nonce for Attestation Evidence in Certificate Signing
  Requests*.
  <https://datatracker.ietf.org/doc/draft-ietf-lamps-attestation-freshness/10/>
- [S9] RFC 8995, *Bootstrapping Remote Secure Key Infrastructure
  (BRSKI)*, May 2021. <https://www.rfc-editor.org/rfc/rfc8995>
- [S10] RFC 8894, *Simple Certificate Enrolment Protocol*, September
  2020. <https://www.rfc-editor.org/rfc/rfc8894>
- [S11] RFC 9810, *Internet X.509 Public Key Infrastructure --
  Certificate Management Protocol (CMP)*, July 2025, and RFC 9483,
  *Lightweight Certificate Management Protocol (CMP) Profile*, November
  2023. <https://www.rfc-editor.org/rfc/rfc9810>,
  <https://www.rfc-editor.org/rfc/rfc9483>
- [S12] RFC 10002, *Certificate Management over CMS (CMC)*, July 2026.
  <https://www.rfc-editor.org/rfc/rfc10002>
- [S13] NXP, `el2go-agent` (EdgeLock 2GO agent), tag `v6.5.2`.
  <https://github.com/NXP/el2go-agent/tree/v6.5.2>
- [S14] RFC 9999, *RATS Conceptual Messages Wrapper (CMW)* (published
  from `draft-ietf-rats-msg-wrap-23`).
  <https://www.rfc-editor.org/rfc/rfc9999>
- [S15] go-trusted-platform, `main` at `641fd51b21fa`.
  <https://github.com/jeremyhahn/go-trusted-platform/tree/641fd51b21fa>

## 12. Questions for the owner

1. **Which enrollment protocol does the board use?**
   Options: (a) ACME with `device-attest-01`; (b) a new
   go-trusted-platform ACME challenge for the enclave, like `enroll-01`;
   (c) ACME with the evidence in the finalize CSR; (d) EST with
   csr-attestation and the freshness nonce; (e) SCEP; (f) EdgeLock 2GO.
   Recommendation: (a), because go-trusted-platform already runs an ACME
   server, lists `device-attest-01` and tracks the draft [S6, S15], and
   the draft is at the IESG. Keep (c)/(d) open as the fallback, since
   the CSR attribute [S7] works for both. Not (e): no evidence carriage
   or freshness [S10]. The choice is go-trusted-platform's (SPEC,
   Purpose); this repository only needs to know it.
2. **How is the enclave's evidence encoded on the wire?**
   Options: (a) a private WebAuthn format string or OID for raw enclave
   evidence; (b) the enclave evidence inside a RATS CMW [S14], so one
   encoding serves both ACME and CSR routes. Recommendation: (b), as it
   keeps the protocol choice in question 1 reversible. Depends on #40.
3. **What authorises the first request?**
   Options: (a) the enclave attestation alone, verified against NXP's
   root; (b) external account binding with a per-device secret set at
   provisioning [S6 §6.1]; (c) a factory IDevID certificate (EST/BRSKI
   [S1, S9]). Recommendation: none yet; it depends on whether the
   enclave evidence chains to an NXP root that go-trusted-platform will
   trust (#40), and on the provisioning place (SPEC open questions).
4. **Is an NXP cloud service acceptable in the enrollment path?**
   Options: (a) no, enrollment talks only to go-trusted-platform;
   (b) yes, EdgeLock 2GO for initial credentials. Recommendation: (a);
   EdgeLock 2GO uses a closed protocol, its i.MX 95 support is not
   confirmed [S13], and SPEC gives enrollment to go-trusted-platform.
5. **Does the SE051 take part in enrollment?** Options: (a) no, the
   enclave key is the identity; (b) yes, as the EdgeLock 2GO anchor or
   a second identity. Recommendation: (a) unless the SE051 role
   question in SPEC (`secure-key-handling`) is answered otherwise.
