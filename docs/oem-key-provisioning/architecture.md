# oem-key-provisioning — architecture

> **Status: NORMATIVE** · Scope: trusted-imx95 `oem-key-provisioning` · Last verified: 2026-11-12
> The detail of the `oem-key-provisioning` row of [SPEC.md](../SPEC.md). Conflicts with SPEC.md are defects in this file.

Every statement below cites a document and section listed in [references/README.md](../references/README.md).
A fact the documents do not give is under [Missing](#missing); a choice the owner has not made is under
[Open questions](#open-questions). No key, fuse address or fuse value appears here.

This row is blocked on the owner's approval ([SPEC.md](../SPEC.md), `oem-key-provisioning` row). This file is
documentation only: it describes the flow and runs nothing against a device.

## Problem

The board's OEM keys must be provisioned into the EdgeLock secure enclave through the vendor's flow, so that they
are generated or held in the enclave's key store and never leave it in the clear ([SPEC.md](../SPEC.md),
`oem-key-provisioning` and `secure-key-handling` rows; RM00284 §2.4, §3.2). AN14861 is NXP's application note on
secure OEM key provisioning with the EdgeLock secure enclave; it is written for the RT1180, and the enclave flow is
the same family ([references/README.md](../references/README.md), NXP documents table; AN14861 §2). This file
states what the cited sections give for the provisioning flow, the life-cycle close and the monotonic counter
fuses, and names what they do not give for the i.MX 95.

## Provisioning flow

The vendor's flow has two steps, in this order ([SPEC.md](../SPEC.md), `oem-key-provisioning` row):

1. **Key exchange.** The enclave and the provisioning side agree a key with which the OEM key is wrapped
   (AN14861 §2, §5.2; RM00284 §3.20).
2. **Import of the wrapped key.** The OEM key, wrapped under the exchanged key, is imported into the enclave's
   key store (AN14861 §5.3; RM00284 §3.2.6.3).

- The imported key lands in the enclave's key store, which the `secure-key-handling` row describes (RM00284 §2.4,
  §3.2). A key store update counts only after an operation with the strict-operation flag is acknowledged, and that
  operation also advances the monotonic counter that protects the store from rollback (RM00284 §2.4.2).
- The message formats, key types, algorithms and the wrapping scheme of each step are in AN14861 §5.2, §5.3 and
  RM00284 §3.20, §3.2.6.3; this digest was written without read access to them and restates none (see
  [Missing](#missing)).
- The enclave tooling the vendor publishes for provisioning is NXP's Secure Provisioning SDK (SPSDK)
  ([references/README.md](../references/README.md), "Vendor SDKs and documentation online"). Whether the flow uses
  it is not decided here (see [Open questions](#open-questions)).

## Life-cycle close

- The device's life cycle moves from OEM open to OEM closed through the enclave (RM00284 §3.23).
- **Irreversible. Needs the owner's explicit approval before it is run on any device.** Closing the life cycle is a
  one-way step; this project treats it as irreversible, and when it is closed is the owner's question
  ([SPEC.md](../SPEC.md), `oem-key-provisioning` row).
  No lane and no build target closes it.
- What closing the life cycle enforces on the i.MX 95, at boot and in the enclave, comes from IMX95RM and the
  i.MX 95 Security Reference Manual, both missing (see [Missing](#missing)). The boot-side effect on container
  verification is the `boot-container` row's concern ([SPEC.md](../SPEC.md)).

## Monotonic counter fuses

- The enclave's monotonic counter fuses are configured once (RM00284 §3.24).
- **Irreversible. Needs the owner's explicit approval before it is run on any device.** Configuring them is a fuse
  write (RM00284 §3.24).
- The anti-rollback floor of the `boot-container` row follows this counter (RM00284 §3.24; [SPEC.md](../SPEC.md),
  `boot-container` row). Which fuses hold the counter on the i.MX 95, and their layout, come from the fuse map in
  IMX95RM, which is missing (see [Missing](#missing)).

## Order of the steps

The steps that cannot be undone are marked; each needs the owner's explicit approval. The row is blocked on that
approval ([SPEC.md](../SPEC.md), `oem-key-provisioning` row; RM00284 §3.23, §3.24).

| Step | Source | Reversible |
|---|---|---|
| Key exchange with the enclave | AN14861 §2, §5.2; RM00284 §3.20 | Not given (see [Missing](#missing)) |
| Import of the wrapped OEM key into the key store | AN14861 §5.3; RM00284 §3.2.6.3 | Not given (see [Missing](#missing)) |
| Configure the monotonic counter fuses | RM00284 §3.24 | No: fuse write, owner's explicit approval |
| Move the life cycle from OEM open to OEM closed | RM00284 §3.23 | No: life-cycle close, owner's explicit approval |

The order of the last two steps relative to each other, and relative to the key import, is not given by the
SPEC row's citations (see [Missing](#missing)); the table lists them in the SPEC row's order, not as a decision.

## Boundaries

- This row covers the enclave side of OEM key provisioning on this device. Holding signing keys is go-xkms's
  custody and is out of scope ([SPEC.md](../SPEC.md), Boundaries and Features).
- Device enrollment, the device registry and attestation verification belong to go-trusted-platform and go-xkms
  ([SPEC.md](../SPEC.md), Boundaries); the device side of attestation is the `device-lifecycle` row.
- The use of the provisioned keys by the HSM API (signing, data storage, attestation) is the
  `secure-key-handling` row (RM00284 §3.4, §3.8, §3.12).
- The NXP SE051 secure element on the board is not part of this flow; its role is an open question under the
  `secure-key-handling` row ([SPEC.md](../SPEC.md)).
- The CompuLab UCM-iMX95 material is reference only and is not cited for this device
  ([references/README.md](../references/README.md), "The device").

## Missing

- The i.MX 95 Applications Processor Reference Manual (IMX95RM): the fuse map, including where the monotonic
  counter fuses sit ([references/README.md](../references/README.md), "Still missing").
- The i.MX 95 Security Reference Manual: what the OEM closed life cycle enforces on the i.MX 95, and the
  life-cycle states beyond OEM open and OEM closed ([references/README.md](../references/README.md),
  "Still missing").
- How far AN14861's RT1180 flow carries over unchanged to the i.MX 95 enclave: AN14861 is written for the RT1180,
  and no cited document states the i.MX 95 differences.
- Whether the key exchange and the key import can be repeated or undone, and in which order the fuse write, the
  key import and the life-cycle close must run.
- What AN14861 §2, §5.2, §5.3 and RM00284 §3.20, §3.2.6.3, §3.23, §3.24 give beyond the facts above (message
  formats, key types, algorithms, wrapping scheme, preconditions, error returns): this digest was written from
  the citations already in [SPEC.md](../SPEC.md) and [references/README.md](../references/README.md), without
  read access to the private vendor context repository. A reader with access deepens each section from those
  documents, citing the section.

## Open questions

- When the life cycle is closed: the owner's ([SPEC.md](../SPEC.md), `oem-key-provisioning` row).
- Where provisioning runs: the owner's ([SPEC.md](../SPEC.md), `oem-key-provisioning` row).
- Whether provisioning uses NXP's SPSDK enclave tools or another path: the owner's.
- Which side calls the enclave's HSM API, the Cortex-A55 Linux side or the Cortex-M7: the owner's, under
  `secure-key-handling` ([SPEC.md](../SPEC.md)).
