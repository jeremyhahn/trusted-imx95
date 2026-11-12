# i.MX 95 fuse map and OEM programming plan: a survey

Row: oem-key-provisioning ([SPEC](../SPEC.md)). Issue #99. Status: draft, for the owner's review.

This is documentation only. Nothing here writes a fuse, changes the life cycle or
scripts a provisioning step. Every statement summarises, in this repository's own
words, a public source listed in [section 2](#2-sources). Where a source could not
be read, or a point could not be confirmed, the text says **not confirmed in public
sources**.

## 1. Scope and method

Issue #99 asks four things. Which i.MX 95 fuse words does the OEM provisioning flow
write (SRK hash, life cycle, debug, boot configuration, anti-rollback)? In what
order? Which writes cannot be undone? Which tools perform them? It also asks for a
plan the owner approves before any fuse is touched.

Method: NXP's public GitHub repositories (the U-Boot fork and SPSDK) were read at the
branches and tags in section 2. The i.MX 95 Reference Manual (IMX95RM), the i.MX 95
Security Reference Manual and the EdgeLock Enclave API reference are not public:
they need an NXP account, and some need an NDA. This lane could not reach them, and
the project's vendor-nxp context repository was not readable from the lane either.
So every fuse index below comes from public source code or guides, and none from
those manuals. The index of a field that only one source gives is marked as such.

## 2. Sources

| # | Title | Version surveyed | URL |
|---|-------|------------------|-----|
| S1 | U-Boot (NXP fork), AHAB secure boot guide for i.MX 8ULP and i.MX 9x, `doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt` | branch `lf_v2025.04`, commit `99518e6b6f20` (2026-02-02) | https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/doc/imx/ahab/guides/mx8ulp_9x_secure_boot.txt |
| S2 | U-Boot (NXP fork), EdgeLock Enclave AHAB commands, `arch/arm/mach-imx/ele_ahab.c` | as S1 | https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/arch/arm/mach-imx/ele_ahab.c |
| S3 | U-Boot (NXP fork), EdgeLock Enclave fuse driver, `drivers/misc/imx_ele/fuse.c` | as S1 | https://github.com/nxp-imx/uboot-imx/blob/lf_v2025.04/drivers/misc/imx_ele/fuse.c |
| S4 | SPSDK, fuse description for the `mimx9596` family, `spsdk/data/devices/mimx9596/fuses.json` | tag `v3.13.0` (released 2026-11-03) | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/spsdk/data/devices/mimx9596/fuses.json |
| S5 | SPSDK, device database for `mimx9596`, `spsdk/data/devices/mimx9596/database.yaml` | tag `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/spsdk/data/devices/mimx9596/database.yaml |
| S6 | SPSDK, `nxpele` command-line tool, `spsdk/apps/nxpele.py` | tag `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/spsdk/apps/nxpele.py |
| S7 | SPSDK example, i.MX95 anti-rollback protection, `examples/ahab/imx95/imx95_anti_rollback_protection.md` | tag `v3.13.0` | https://github.com/nxp-mcuxpresso/spsdk/blob/v3.13.0/examples/ahab/imx95/imx95_anti_rollback_protection.md |

Sources this lane could not reach, or did not read:

| Title | Why | Where it would help |
|-------|-----|---------------------|
| i.MX 95 Applications Processor Reference Manual (IMX95RM) | not public; vendor-nxp repository unreachable from the lane | fuse map, boot fuses, life-cycle fuse encoding |
| i.MX 95 Security Reference Manual | not public | debug fuses, lock semantics, life-cycle rules |
| EdgeLock Secure Enclave API reference (RM00284, cited in SPEC) | in the vendor-nxp repository, unreachable from the lane | write-fuse, forward life cycle and commit service rules |
| NXP AN14533, anti-rollback application note (linked from S7: https://www.nxp.com/doc/AN14533) | not fetched in this slice | version fuse layout and commit rules |
| `spsdk/apps/nxpfuses.py` (SPSDK v3.13.0) | present in the tag, not read | whole-configuration fuse programming |

## 3. Fuse words the OEM flow writes

Addressing. U-Boot names an i.MX 9 fuse by bank and word, with eight 32-bit words per
bank. Its driver turns that into the enclave's flat fuse index, `bank * 8 + word`,
and passes the index to the enclave's write-fuse service (S3, `fuse_prog`). SPSDK
gives each fuse word the same flat index (`index_int`) and an identifier `fuseN`
where N is that index (S4). Both numberings are used below.

### 3.1 SRK hash (root of trust)

- **Where:** `OEM_SRKH0` to `OEM_SRKH15`, flat index `0x80` to `0x8F` (banks 16 and
  17) (S4). U-Boot reads banks 16 and 17 through the enclave, not through the fuse
  shadow block (S3, `ele_api_mapping_table`).
- **The width depends on silicon revision** (S5):
  - Revisions A0 and A1: SPSDK groups `fuse128` to `fuse135` (bank 16 only) as a
    256-bit SHA-256 SRK hash.
  - Revision B0: SPSDK groups `fuse128` to `fuse143` (banks 16 and 17) as a
    512-bit SHA-512 SRK hash. It adds a second group, `OEM_PQC_SRKH0` to
    `OEM_PQC_SRKH15` (flat index `0x1C0` to `0x1CF`), for the hash of a
    post-quantum SRK table, and it uses version 2 of the AHAB container.
  - The U-Boot guide shows only the eight-word, bank-16 form for i.MX 93 and
    i.MX 95 (S1 §1.6), which matches A0 and A1, not B0.
  - Which revision the project's FRDM-IMX95 board carries is **not confirmed in
    public sources** (see question 1).
- **Write lock:** S4 ties words `0x80` to `0x87` to a lock field
  `ELE_OEM_SRKH0_LOCK` (in `LOCK_CFG4`), and `0x88` to `0x8F` to
  `ELE_OEM_SRKH1_LOCK` (in `LOCK_CFG8`). `ELE_OEM_PQC_SRKH_LOCK` sits in `LOCK_CFG8`
  too. Whether the OEM must set these locks, or the close sets them, is **not
  confirmed in public sources**.
- **Value source:** the SRK hash fuse table that the signing tool writes when it
  builds the SRK table (S1 §1.6; SPSDK computes the same hash, S5 `srkh`).
- **Effect of an error:** S1 §1.6 warns that a wrong SRK hash leaves a part that
  does not boot (once it is closed).

### 3.2 Life cycle

- **Not a raw word the OEM writes.** U-Boot's `ahab_close` asks the enclave to move
  the life cycle forward, and the enclave burns the fuses (S2, `do_ahab_close`
  calling `ele_forward_lifecycle`). SPSDK's equivalent is
  `nxpele forward-lifecycle-update` (S6).
- **Reading the state:** U-Boot reads it from the fuse shadow block at offset `0x414`
  on i.MX 95 and i.MX 94, and `0x41c` on other i.MX 9 parts (S2).
- **States on i.MX 95** (S2, `display_life_cycle`, i.MX 95 branch): BLANK, FAB
  default, FAB, NXP provisioned, OEM open (`0x10`), OEM secure world closed
  (`0x20`), OEM closed (`0x40`), OEM locked (`0x80`), field return OEM, field return
  NXP, and bricked. These differ from i.MX 93, where OEM open is `0x8` and OEM
  closed `0x20`. The example output in S1 §1.7 and §1.8 shows the i.MX 93 values,
  so it does not match an i.MX 95.
- **Transitions U-Boot offers** (S2):

  | Command | Change | Request value |
  |---------|--------|---------------|
  | `ahab_close` | OEM open to OEM closed | 8 |
  | `ahab_lock` | OEM closed to OEM locked | 128 |
  | `ahab_return_lifecycle` | to field return OEM | a message block signed by the OEM SRK |

  U-Boot refuses `ahab_close` unless the state it reads back is OEM open, and
  refuses `ahab_lock` unless it is OEM closed (S2).
- **OEM secure world closed:** S2 decodes this state but has no command that enters
  it. What the state closes, and how it is entered, is **not confirmed in public
  sources**.

### 3.3 Debug

S4 names these OEM-controlled debug fields. Each four-bit field covers
`{spiden, sniden, dbgen, niden}` for one debug domain.

| Flat index | Word (S4) | Field | Domain (S4) |
|------------|-----------|-------|-------------|
| `0x38` | `ELE_MISC_CTRL0` bits 0-3 | `SOC_SCOPE_PRIMARY_DBG_DISABLE` | Cortex-M33 domain |
| `0x38` | bits 4-7 | `SOC_SCOPE1_DBG_DISABLE` | trace memory controller |
| `0x38` | bits 8-11 | `SOC_SCOPE2_DBG_DISABLE` | Cortex-M7 |
| `0x38` | bits 12-15 | `SOC_SCOPE3_DBG_DISABLE` | DAP AHB-AP |
| `0x39` | `ELE_MISC_CTRL1` bits 0-3 | `SOC_SCOPE4_DBG_DISABLE` | application cores, camera subsystem and GPU |
| `0x3A` | `ELE_MISC_CTRL2` bit 8 | `SOC_GLBL_DBG_DISABLE` | all debug |
| `0x3A` | bit 10 | `TZ_GLBL_DBG_DISABLE` | TrustZone; the source gives no further description |

S4 marks these words as 16 bits wide. How a 16-bit field maps onto the 32-bit
enclave word, the redundancy scheme that S3's `redundancy` flag suggests, and whether
debug stays reachable through authenticated debug once disabled are all **not
confirmed in public sources**.

### 3.4 Boot configuration

- `BOOT_CFG0` sits at flat index `0x18` (bank 3, word 0), followed by `BOOT_CFG1`,
  `BOOT_CFG2`, `BOOT_CFG3`, `BOOT_CFG8`, `BOOT_CFG9` and `BOOT_CFG11` (S4).
  `BOOT_CFG0` holds `BT_FUSE_SEL`, which selects whether boot settings come from
  the fuses or from the boot pins. Its lock is `BOOT_CFG_LOCK` in `LOCK_CFG7` (S4).
- The fuse values a given boot device needs (eMMC, SD, FlexSPI) are not summarised
  here; their meaning is in IMX95RM, which is **not public**.

### 3.5 Anti-rollback and SRK revocation

- U-Boot's `ahab_commit` and SPSDK's `nxpele commit` ask the enclave to burn the SRK
  revocation bits and firmware version numbers it found in the NXP container and the
  OEM container that booted (S2, S6). SPSDK names the choices `NXP_FW_FUSE` and
  `OEM_FW_FUSE` (S7). The OEM does not pick a fuse word: the enclave takes the
  value from the signed container. The OEM sets its value through the container's
  `fuse_version` field (S7).
- Effect (S7): once committed, an NXP container with a lower fuse version will not
  boot in OEM open, closed or locked. An OEM container with a lower version will not
  boot in OEM closed or locked, and boots with an enclave event in OEM open.
- `OEM_SRK_RVK`, `ELE_MISC_CTRL7` bits 12-15 (flat index `0x3F`), holds the OEM SRK
  revocation bits (S4).
- The flat index of the version fields is **not confirmed in public sources**.

### 3.6 Other OEM fuses seen, out of this survey's scope

- General-purpose secure fuses `GPR2_CFG0` onward (S4). S4 says they can be
  programmed only in OEM open, and are read back only through enclave API calls.
- `OTFAD1_KEY` (`fuse184` to `fuse187`), a key-encryption key for on-the-fly
  decryption (S5). This survey writes no key and plans none.
- `ahab_sec_fuse_prog` (S2) and `nxpele signed-message` (S6) program "secure"
  fuses through a message block signed by the OEM SRK. Which i.MX 95 fuses need
  that path is **not confirmed in public sources**.

## 4. Order, irreversibility and tools

### 4.1 Order the sources support

1. **Read-only checks first.** Read the life cycle (`ahab_status`, or `nxpele
   get-info`) and confirm it is OEM open (S2, S6, S7).
2. **Boot a signed image while still OEM open,** then check that the enclave
   reported no events (S1 §1.7). In OEM open, authentication failures are only
   logged (S1 §1.7, S7).
3. **Program the SRK hash** (S1 §1.6), then reboot and check again that no events
   are reported (S1 §1.7).
4. **Program the other OEM configuration while still OEM open:** debug, boot
   configuration and the locks. S4 says some OEM fuses can be programmed only in
   OEM open. Whether the debug and boot words can still be written after the close
   is **not confirmed in public sources**, so this plan does them before it.
5. **Commit the anti-rollback version, if wanted** (S7). S7 runs the commit with
   the board booted in U-Boot; it does not say whether this comes before or after
   the close.
6. **Close** (OEM open to OEM closed) only after steps 2 and 3 show no events
   (S1 §1.8; S2 also asks the operator to confirm).
7. **OEM locked** is a further optional step (S2, `ahab_lock`).

### 4.2 What cannot be undone

- **Every fuse bit.** Fuses are one-time programmable. The i.MX 9 fuse block itself
  protects ECC-protected words, so a second write to such a word fails (S3, comment
  in `fuse_prog`). The SRK hash words must therefore be right the first time.
- **The close.** S1 §1.8 calls it irreversible, and warns that a board can be made
  unbootable if an earlier step went wrong. The only way back that S2 shows is a
  move forward to field return OEM, through a message signed by the OEM SRK. That
  is not a return to OEM open.
- **Lock fields** (`LOCK_CFGn`, S4): once set, they stop later writes to the words
  they guard. Their exact rules are **not confirmed in public sources**.
- **Version commits:** they raise the minimum firmware version for good (S7).

### 4.3 Tools

| Tool | Write fuse | Life cycle | Version commit | Read back | Source |
|------|------------|------------|----------------|-----------|--------|
| U-Boot console | `fuse prog <bank> <word> <value>` (the enclave write-fuse service); `fuse override` writes a shadow only | `ahab_close`, `ahab_lock`, `ahab_return_lifecycle` | `ahab_commit` | `fuse read`, `fuse sense`, `ahab_status` | S1, S2, S3 |
| SPSDK `nxpele` | `write-fuse --index --data [--lock]`; `write-shadow-fuse` | `forward-lifecycle-update` | `commit -i NXP_FW_FUSE / OEM_FW_FUSE` | `read-common-fuse`, `read-shadow-fuse`, `get-info`, `get-events` | S6, S7 |
| SPSDK fuse database | names, indexes, locks and SRK hash grouping for each revision; names `nxpele` as the fuse tool | n/a | n/a | n/a | S4, S5 |
| Enclave API | the service that both tools above call | forward life cycle | commit | read common fuse | S2, S3; the API reference itself is not read |

SPSDK's `nxpele` reaches the enclave through a U-Boot console transport
(`uboot_serial`, S7), so in that mode U-Boot is on the path either way.

## 5. Programming plan for the owner's approval

This is a plan to approve, not a script. No step is to be run until the owner
answers section 7 and approves this table. Each value is produced, checked and
recorded before the step runs.

| Step | Target | Value source | Check before | Check after | Reversible |
|------|--------|--------------|--------------|-------------|------------|
| P0 | none (read only) | n/a | n/a | record the life cycle (`0x10` = OEM open on i.MX 95, S2), silicon revision and ELE firmware version | yes |
| P1 | none (boot test) | signed image from the signing toolchain (#9, CST or SPSDK) | P0 shows OEM open | no enclave events after boot (S1 §1.7) | yes |
| P2 | SRK hash, `0x80`-`0x87` (A0/A1) or `0x80`-`0x8F` (B0) | the SRK hash table from the signing tool. Two people compare it against a hash computed independently from the SRK public keys. | read back all zero; revision known (P0) | read back equals the table; signed image boots with no events | **no** |
| P3 | PQC SRK hash, `0x1C0`-`0x1CF` (B0 only, if chosen) | PQC SRK table hash from SPSDK | as P2 | as P2 | **no** |
| P4 | debug fields `0x38`-`0x3A` (section 3.3) | owner's debug policy (question 5) | P2 verified | read back equals the policy; debugger refused where disabled | **no** |
| P5 | boot configuration `BOOT_CFG*` (section 3.4) | only if the owner chooses fuse boot (question 6); values from IMX95RM | IMX95RM obtained | board boots from the intended device with the boot pins changed | **no** |
| P6 | locks (`LOCK_CFG*`) | owner's choice (question 4), after the Security Reference Manual is read | P2 to P5 verified | read back | **no** |
| P7 | version commit (`OEM_FW_FUSE`, `NXP_FW_FUSE`) | the `fuse_version` in the signed release container | a version policy exists (question 8) | `get-info` shows the version; an older image is refused | **no** |
| P8 | life cycle to OEM closed | n/a | P1 and P2 show no events; spare board available (question 10) | life cycle reads `0x40`; signed image boots; unsigned image refused | **no** |
| P9 | life cycle to OEM locked | n/a | owner's explicit choice (question 7) | life cycle reads `0x80` | **no** |

Each step's commands, operator and record go into a signed-off provisioning log.
They are written when the owner approves this plan, not here.

## 6. What could not be confirmed

- The silicon revision of the project's board, and so the SRK hash width (256 or
  512 bits) and whether the PQC SRK hash applies.
- What `OEM_SRKH8` to `OEM_SRKH15` mean on A0/A1 parts, where SPSDK groups only
  eight words.
- What the life cycle "OEM secure world closed" means, and how it is entered.
- The flat index of the anti-rollback version fuses.
- Which OEM fuses can still be written after the close, and which need the signed
  message path.
- The rules of the `LOCK_CFG*` fields, and whether the close sets any lock itself.
- How the 16-bit, redundant debug words map onto 32-bit enclave writes.
- The values the boot configuration fuses need for this board.
- Everything in IMX95RM, the i.MX 95 Security Reference Manual, RM00284 and AN14533,
  none of which this lane read.

## 7. Questions for the owner

1. **Which silicon revision is on the FRDM-IMX95 board?**
   Options: (a) read it from the board with a read-only command (`nxpele get-info`
   or U-Boot's boot banner); (b) ask NXP. Recommendation: (a) before any other step.
   The SRK hash width depends on it (S5).
2. **Which tool programs the fuses?**
   Options: (a) U-Boot `fuse prog` and `ahab_*` (S1, S2); (b) SPSDK `nxpele`
   (S6), which carries the per-revision fuse map (S4, S5). Recommendation: (b),
   because it groups the SRK hash words per revision and so lowers the chance of a
   wrong index. Decide together with #9 (CST or SPSDK).
3. **On B0, program the PQC SRK hash?**
   Options: (a) yes, with a PQC SRK table; (b) no, leave it blank. No public source
   read says what a blank PQC hash means for boot. Recommendation: none until the
   Security Reference Manual is read.
4. **Set the SRK hash and other lock fields?**
   Options: (a) set them after verification; (b) rely on the close. The sources do
   not say which is needed. Recommendation: defer until the Security Reference
   Manual is read.
5. **Debug policy?**
   Options: (a) leave debug open on development boards; (b) disable per domain
   (section 3.3); (c) global disable. Recommendation: (a) on development boards;
   choose (b) or (c) for production once authenticated debug has been surveyed.
6. **Boot from pins or from fuses?**
   Options: (a) keep the boot pins; (b) burn `BOOT_CFG*` and `BT_FUSE_SEL`.
   Recommendation: (a) on development boards, since the values need IMX95RM.
7. **Target life cycle?**
   Options: (a) stay OEM open; (b) OEM closed; (c) OEM locked. Recommendation: (b)
   on one sacrificial board first, after P1 and P2 pass. Do not choose (c) until a
   source explains what it adds and what it removes.
8. **Anti-rollback policy?**
   Options: (a) no commit during development; (b) commit OEM versions at each
   release; (c) also commit the NXP firmware version. Recommendation: (a) now, and
   write a version policy before the first release. S7 shows that a commit stops
   older images from booting once the board is closed.
9. **Where does provisioning run?** (This is an open question in SPEC.)
   Options: (a) on the bench over the U-Boot console; (b) a factory station.
   Recommendation: (a) for the first boards; the sources show only console-based
   flows.
10. **Get a spare board for the first close?**
    Options: (a) yes; (b) no. Recommendation: (a). S1 §1.8 warns that a failed
    close can leave a board that cannot be recovered.
