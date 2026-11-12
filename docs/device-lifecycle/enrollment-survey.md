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

## 7. Carrying the enclave's attestation evidence

## 8. Comparison

## 9. Fit with go-trusted-platform's enrollment

## 10. Not confirmed

## 11. Sources

## 12. Questions for the owner
