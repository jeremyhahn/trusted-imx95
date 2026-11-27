# Platform image build configuration

Every choice here is a provisional default, pending the owner's answer on
#14. The owner has not answered; the defaults are the ones
[build-system-options.md](build-system-options.md) recommends (section 10 and
section 11), written down so the owner can read a working proposal.

## What is in the tree

- `platform-image/manifest.lock`: the pins. NXP's manifest repository at the
  commit tag `lf-6.18.37-2.1.0` peels to, the manifest file
  `imx-6.18.37-2.1.0.xml`, and every project the manifest lists (19 layers),
  each with its repository, path and 40-hex commit. Hashes were read from the
  manifest file, and by `git ls-remote` for the three layers the manifest
  names by tag. None is typed by hand and none is MISSING.
- `platform-image/conf/distro/trusted-imx95.conf`: the headless distro,
  requiring `poky.conf` (NXP's `fsl-imx-fb-minimal` sets an option wrynose
  rejects; see [build-host-check.md](build-host-check.md)), with the display,
  audio and wireless features removed. It signs nothing.
- `platform-image/conf/layer.conf`, `local.conf.template`,
  `bblayers.conf.template`: the layer, and the templates for machine
  `imx95-19x19-lpddr5-frdm-pro`.
- `scripts/platform-image-fetch.sh`, `make platform-image-fetch`: checks the
  layers out into a directory outside the clone and fails when a layer's
  commit differs from the lock. A fetched layer must also be clean: any staged,
  unstaged, untracked or ignored file fails the fetch, so remove the layer
  directory and fetch again. It needs the network, so it is in neither
  `make build` nor `make test`.
- `scripts/platform-image-parse.sh`, `make platform-image-parse`: the metadata
  check, run on a build host (bitbake and the network). It rejects a directory
  inside the clone first and deletes only an ignored, untracked
  `pyshtables.py` of the bitbake checkout (else it fails closed). It fetches the pinned
  layers, writes the build directory's conf from the templates, runs
  `bitbake -p`, then `bitbake -e` for `trusted-imx95-image` and
  `trusted-imx95-image-debug`. It checks that the effective `MACHINE` is the
  lock's, `DISTRO` is `local.conf.template`'s, `INIT_MANAGER` is the distro's,
  and that `IMAGE_FEATURES` holds none of `debug-tweaks`, `empty-root-password`,
  `allow-empty-password` or `allow-root-login`. It refuses to overwrite a
  `build/conf/local.conf` or `bblayers.conf` that differs from the templates,
  unless `PLATFORM_IMAGE_PARSE_FORCE=1`. It builds no image.
- `scripts/platform-image-kernel-config.sh`, `make platform-image-kernel-config`:
  the kernel configuration check, run on a build host after the parse check.
  In the same build directory it runs `bitbake linux-imx -c configure`, finds
  the generated `.config` (`B` from `bitbake -e linux-imx`) and checks it
  against `platform-image/kernel-required.txt`, the one table
  `test/platform_image_kernel_test.sh` also checks the fragment against.
  A required `n` holds when the symbol is "is not set" or absent.
- `scripts/platform-image-layer-check.sh`, `make platform-image-layer-check`:
  the layer check, run on a host with the fetched tree (`make platform-image-fetch`;
  no bitbake). It reads the BBLAYERS paths of `platform-image/conf/bblayers.conf.template`
  and fails when a listed layer has no `conf/layer.conf`, when a `LAYERDEPENDS`
  entry names a collection no listed layer provides, or when a layer's
  `LAYERSERIES_COMPAT` lacks a series openembedded-core's `LAYERSERIES_CORENAMES`
  gives. Version constraints (`name:N`) are reported, not enforced. It parses the
  files as text, so it is weaker than bitbake's own parse. Its stub-tree test is
  `test/platform_image_layer_check_test.sh`.

- `scripts/platform-image-hosttools.sh`, `make platform-image-hosttools`: sets
  up a non-root build host in a cache directory: Yocto buildtools-extended 6.0.1
  (checked against its pinned and published sha256, failing closed) and the
  apt-fetched cpio, diffstat, file, gawk and socat, then writes an `env.sh` to
  source before the two targets below. Its stubbed test is
  `test/platform_image_hosttools_test.sh`.

- `scripts/platform-image-verify.sh`, `make platform-image-verify OUT=<dir>`:
  checks a published output directory against `platform-image/manifest.lock`,
  offline, with no bitbake (see "Checking an output directory" below). Its
  stubbed test is `test/platform_image_verify_test.sh`.

The build-host run is recorded in [build-host-check.md](build-host-check.md),
with a "repeat this run" section.

Both build-host targets, `make platform-image-parse` (the metadata check) and
`make platform-image-kernel-config` (the kernel-config check), need bitbake
and the network, and **CI does not run them yet** (provisional, pending a
build-host CI runner). Their stub-driven tests, `test/platform_image_parse_test.sh`
and `test/platform_image_kernel_config_test.sh`, run in `make test`.
- `test/platform_image_test.sh`, in `make test`: offline checks of the lock,
  the machine name, the distro file, the templates against the lock, and the
  absence of root-login relaxations (`debug-tweaks` and the like) in the image
  metadata.

## The #14 questions and the answer assumed

| Question | Assumed (provisional) |
|---|---|
| Q1 build system | (a) Yocto with NXP meta-imx |
| Q2 BSP baseline | (a) manifest imx-6.18.37-2.1.0, every layer at the manifest's commit; the release `system-manager/sm.lock` already pins |
| Q3 distro | (b) our own headless distro, based on poky.conf with the fsl-imx-base settings it needs |
| Q4 signing | (b) AHAB signing a separate step after the build, not inside it |

## The image recipes

Every setting below is a provisional default, pending the owner's answer on
#14 (hardening-survey question 7, recommendation (b)). Files:
`platform-image/recipes-core/images/trusted-imx95-image.bb` (production) and
`trusted-imx95-image-debug.bb` (debug, requires the production one and never
holds production keys). `conf/layer.conf` adds the `recipes-*/*/*.bb` BBFILES
line.

| Setting | Where | Source |
|---|---|---|
| `require recipes-core/images/core-image-minimal.bb` | production image | hardening-survey section 7, question 7 (b) |
| `IMAGE_FEATURES += "read-only-rootfs"` | production image | hardening-survey section 7; verified-boot-survey section 3.6, question 5 (a) (dm-verity comes later) |
| `IMAGE_INSTALL = "packagegroup-core-boot ..."` | production image | hardening-survey section 7 (only what exists today; `firmware-ele-imx` comes from the machine) |
| `SUMMARY` | both images | MISSING: no survey names it |
| `IMAGE_FEATURES += "tools-debug package-management"` | debug image | hardening-survey section 7 for the tools and package manager; no `debug-tweaks`: the login policy is not relaxed in the debug image (provisional, pending #14) |
| `IMAGE_INSTALL:append = " bash gdb strace imx-test"` | debug image | hardening-survey section 7 |
| `INIT_MANAGER = "systemd"` | distro | hardening-survey section 7 (systemd 259.5 on wrynose) |
| `DISTRO_FEATURES:remove`, `DISTRO_FEATURES_OPTED_OUT`, `IMAGE_FEATURES:remove` | distro | hardening-survey section 7 (no display stack or audio); removing bluetooth, wifi, nfc and 3g is MISSING |
| `DISTRO`, `DISTRO_NAME`, `DISTRO_VERSION` | distro | MISSING: naming choices of this layer |
| `BBFILES += recipes-*/*/*.bb` | layer.conf | MISSING: no survey covers it |

Reproducible builds and the SBOM stay at Yocto's defaults
(reproducible-build-survey sections 3 and 4, question 5 (a)): the fallback
`SOURCE_DATE_EPOCH`, the fixed `REPRODUCIBLE_TIMESTAMP_ROOTFS` and `create-spdx`
(SPDX 3.0) are on, and the test fails if any file under `platform-image/` sets
the first two or removes the third.

Open, MISSING, and deliberately not set: the `BBFILES += recipes-*/*/*.bbappend`
line in `conf/layer.conf` (no survey covers the search path), `BB_NO_NETWORK`, hash equivalence, the
`SPDX_INCLUDE_*`, `SPDX_INVOKED_BY` and `SPDX_ON_BEHALF_OF` fields
(reproducible-build-survey question 6 has no recommendation), the xkmsd
package (go-xkms has no recipe yet; hardening-survey question 7), and any
login-policy image feature in the production image.

## Kernel hardening fragment

Proposed, pending owner approval (hardening-survey question 1 (c) and question
5 (b)). `platform-image/recipes-kernel/linux/linux-imx_%.bbappend` adds
`files/hardening.cfg` as a kernel-yocto fragment to meta-imx-bsp's
`linux-imx_6.18.bb`, which accepts fragments and rejects
`DELTA_KERNEL_DEFCONFIG` (survey section 5). `test/platform_image_kernel_test.sh`
checks the fragment offline.

| Setting group | Source section | Status |
|---|---|---|
| The "cheap, no expected driver impact" KSPP options with a plain value (`HARDENED_USERCOPY`, the SLAB and page-allocator randomisation, `LIST_HARDENED`, `FORTIFY_SOURCE`, `INIT_ON_ALLOC_DEFAULT_ON`, `DEFAULT_MMAP_MIN_ADDR=65536`, `SLAB_MERGE_DEFAULT`, `LDISC_AUTOLOAD`, `LEGACY_PTYS`, `LEGACY_TIOCSTI` off, and the rest of that list) | hardening-survey section 3 | provisional |
| `DEVMEM`, `DEVPORT`, `KEXEC`, `KEXEC_FILE`, `CRASH_DUMP` off | section 4, question 5 (b) | provisional |
| `PANIC_ON_OOPS=y`, `PANIC_TIMEOUT=-1`, `MAGIC_SYSRQ_DEFAULT_ENABLE=0xb0` | section 3 "behaviour changes", question 5 (b) | provisional |

Dropped because the survey states no usable value: `STATIC_USERMODEHELPER`
(it also needs a helper path, which the survey does not give; an empty path
would block every usermode helper).

Deliberately not set, left to the owner: `MODULES=n` and `MODULE_SIG_FORCE`
with its signing key (questions 2 and 3: out-of-tree BSP modules, key custody
and reproducibility); lockdown (question 4: its debugfs conflict is
unconfirmed, section 6); `COMPAT=n` (vendor binaries may be 32-bit); the
"runtime cost" group; the symbols the survey says 6.18 removed; and every
toolchain-dependent option (`SHADOW_CALL_STACK`, `CFI_CLANG`,
`ARM64_BTI_KERNEL`, `ARM64_MTE`, `KASAN_HW_TAGS`, `UNWIND_PATCH_PAC_INTO_SCS`),
which need a real cross build (sections 3 and 9).

Not verified: no kernel build; no check that the options resolve in 6.18 or
that the BSP drivers survive them (survey section 6, question 2). The survey
gave the SysRq mask as 176 without a base; Kconfig reads that symbol as hex, so
the fragment writes `0xb0` (sync 0x10, remount read-only 0x20, reboot 0x80).

## Verified and not verified

Verified: the lock's hashes were read from their sources; the test runs
offline; the test checks the two image recipes, the BBFILES line, the absence
of overrides of the reproducible and SBOM defaults, and that the fetch script
fails with "checked out X, the lock pins Y" for a pin on an annotated tag
object, against a local stub repository; `meta-imx` at its tag has the machine `imx95-19x19-lpddr5-frdm-pro`
and the `fsl-imx-fb-minimal` distro the file requires.

Also verified, on a build host ([build-host-check.md](build-host-check.md)):
the fetch, `bitbake -p` and `bitbake -e` of both images, and the kernel
`.config` generated by `bitbake linux-imx -c configure`.

Not verified: see "The first build" for the real build. The NXP EULA is
accepted (`ACCEPT_FSL_EULA = "1"` in `local.conf.template`, the owner's
acceptance of 2026-11-24; #14 is answered).

## The first build (provisional)

Command, on a non-root x86_64 host with the network (provisional default,
pending #14):

```sh
make platform-image-hosttools                 # once; then source the env.sh it prints
make platform-image                           # PI_DEBUG=1 adds trusted-imx95-image-debug
make platform-image ARGS=--check              # names missing host tools; fetches and builds nothing
```

`scripts/platform-image-build.sh` fetches the pins, writes the build
directory's conf from the templates (it refuses to overwrite a conf that
differs unless `PLATFORM_IMAGE_BUILD_FORCE=1`), runs bitbake (extra bitbake
arguments such as `-k` go in `PLATFORM_IMAGE_BITBAKE_ARGS`), then copies the
real wic and rootfs files of the deploy directory, with each target's package
manifest (`.manifest`) and SPDX SBOM (`.spdx.json`; a target with an image
artefact but no SBOM fails the build, because `create-spdx` stays on), not the
plain-name links, `.testdata.json`, `.env` or `.qemuboot.conf`,
to `.platform-image/out/` (git-ignored; `PLATFORM_IMAGE_OUT` overrides it),
with `SHA256SUMS` and `build-info.txt` (machine, distro, targets,
`SOURCE_DATE_EPOCH`, build seconds, this checkout's commit, whether
`platform-image/` differs from it (`platform_image_dirty=yes`, with the sha256
of the status and diff; dirty inputs are recorded, not refused), the manifest
commit and every layer commit). The script deletes `PLATFORM_IMAGE_OUT` only
when it carries the `.platform-image-out` marker it wrote, and refuses an empty
value, a relative path, any path with a `..` component (`.`, `//` and a
trailing slash are collapsed first, so the path checked is the one used), `/`,
the checkout or an ancestor, a path outside `.platform-image/`
inside the checkout, and any path overlapping the fetch directory. The fetch
directory is canonicalised the same way before that comparison, and one with a
`..` component is refused. `SOURCE_DATE_EPOCH` is read from `bitbake -e`
(plain or `export`ed, last value, decimal integer only; anything else stops
the script). Its stub test is `test/platform_image_build_test.sh`, in `make test`.
It is not in CI.

**Earlier result (before the EULA was accepted; see "Results of the first real build" below): no image was built.** The build stopped on the NXP EULA, which is
the owner's to accept (#14) and which this lane did not accept. Run on a lane
host (112 CPUs, 372 GB RAM, 866 GB free disk), `bitbake trusted-imx95-image`
attempted 1661 tasks, with the first failure at
`imx-m7-demos` `do_unpack`: "you need to accept the Freescale EULA". A second
run with `-k` (keep going) attempted 4651 tasks, 1660 of them already done,
and failed three: `do_unpack` of `imx-m7-demos`, `firmware-ele-imx` and
`imx-boot-firmware-files`, each with the same EULA message. No other task
failed, so no configuration error in `platform-image/` surfaced and none was
changed. The kernel, the toolchain, the native tools, OP-TEE OS, ATF, the
system manager and the OEI built or packaged. The image's
`do_rootfs` and `do_image_wic` did not run, because their inputs include the
three recipes above; so no `SHA256SUMS` exists.

Cost, measured: the `-k` run took about 7000 s (just under two hours) with
`BB_NUMBER_THREADS` and `make -j` at 16 (the script's cap); the build directory
reached 64 GB and the downloads and layers 7.5 GB.

Gaps, all provisional:

- **EULA.** Accepted on 2026-11-24 by the owner: `ACCEPT_FSL_EULA = "1"` is set
  in `local.conf.template` (#14 answered). The run above is the one before that.
- Reproducibility: the first real two-build run (2026-11-27, "Results of the
  --repro and debug builds" below) found the images **not identical**; the
  causes are named there and the row stays open.
- The debug image was built on its own on 2026-11-27 (same section).
- The host-tool list in the script (gcc, g++, make, git, python3, tar, xz,
  bzip2, patch, perl, unzip, wget, diffstat, chrpath, gawk, cpio, file, socat,
  zstd, lz4c) is a working list from this run, not Yocto's full required list.

## Results of the first real build

Date: 2026-11-24. Target `trusted-imx95-image` (not the debug image), with the
EULA accepted. Run on a 112-CPU lane build node with `BB_NUMBER_THREADS=16` and
`PARALLEL_MAKE="-j 16"`, a build directory and OUT outside the clone, no
changes to the script. bitbake attempted 4716 tasks, none was rerun from a
cache, all succeeded (3 warnings). `do_rootfs`, `do_image_wic` and the SPDX
tasks ran. Wall time: 7947 s for the build (`build_seconds`), about 8100 s with
the fetch. Disk: the build tree 71 GB, the fetched layers 166 MB (the download
cache is inside the tree). `rm_work` is not enabled; the tree is far under
250 GB. `sha256sum -c SHA256SUMS` and `make platform-image-verify` both pass.

Pins (from `build-info.txt`): machine `imx95-19x19-lpddr5-frdm-pro`, distro
`trusted-imx95`, `SOURCE_DATE_EPOCH=1302044400`, manifest commit
`0c44ab18abe471b4326037b61893f4e69b6fc182`, `platform_image_dirty=no`, and the
layers: bitbake `acfe02fa`, openembedded-core `5d1aa5c8`, meta-yocto `24c24cef`,
meta-clang `ef0d22f2`, meta-openembedded `6bf0d8ad`, fsl-community-bsp-base
`1d8c41be`, meta-freescale `ca31f33c`, meta-freescale-3rdparty `26d8b36a`,
meta-freescale-distro `4464f38b`, meta-freescale-ml `1330790b`, meta-arm
`0979b804`, meta-qt6 `302c4fab`, meta-browser `407e3ac9`, meta-security
`c0d1d620`, meta-timesys `bf4ff1bb`, meta-virtualization `30f1a9d7`, meta-imx
`2eb758f4`, meta-nxp-connectivity `12e139aa`, meta-nxp-demo-experience
`dd4e742a` (full hashes in `build-info.txt`).

Artefacts (name prefix `trusted-imx95-image-imx95-19x19-lpddr5-frdm-pro.rootfs-20261124152713`):

| Artefact | Bytes | SHA-256 |
| --- | --- | --- |
| `.wic.zst` | 39565817 | `e063e81f24053fb4eb00a00a31b7d7044264a7d37bf6da0847b65815ff972d11` |
| `.wic.bmap` | 3825 | `6051c1a434ffd048cdbe502035670c97b75ea9629625c47b8d6d05eaf7a0670b` |
| `.tar.zst` (rootfs) | 22452684 | `c091f99f0c13b6e1742a0083a311135dabbf0f312cd30f1413623cc6ac37b043` |
| `.manifest` | 3166 | `9a786f5267c99ef5c6dbcb8469a58b2ba9d5cd834b46c6e190326d519e5996d8` |
| `.spdx.json` (SBOM) | 3700404 | `541cd494c29b857540db3c298621bc2e3a58726752c34a118f4501a32a8fc9e1` |

The image is unsigned. The `--repro` run is recorded in "Results of the --repro
and debug builds" below.

## Reproducibility check (provisional; first real run found a difference)

`make platform-image ARGS=--repro` (or `scripts/platform-image-build.sh --repro`)
runs the build twice, each in its own freshly emptied build directory
(`<dir>.repro-a`, `<dir>.repro-b`) and output directory (`<out>.repro-a`,
`<out>.repro-b`), under the same pinned layers and the same
`SOURCE_DATE_EPOCH`. A directory is emptied only when it is absent, empty or
carries the marker this mode wrote. Then
`scripts/platform-image-repro-compare.sh OUT_A OUT_B` compares the outputs, and
`.platform-image/out/` is written only when they match; on a difference the two
outputs stay for inspection and nothing is published. `--check` with `--repro`
builds nothing.

What is compared: each output against its own `SHA256SUMS` (a missing file, an
unlisted file or a changed byte fails); then every artefact in both
`SHA256SUMS` with the same hash; then `build-info.txt` line by line, layer
commits and `SOURCE_DATE_EPOCH` included. The one ignored key is
`build_seconds`, which differs every run. A difference names the artefact and
both hashes, or the build-info key and both values. A `build-info.txt` that is
missing, unreadable, empty, or without `SOURCE_DATE_EPOCH` or a layer commit
fails the compare, naming the file. Any differing or missing artefact fails;
the compare script has no exception option. An empty comparison fails too: two
`SHA256SUMS` that list no artefact never print OK.

The SBOM (`.spdx.json`) and the package manifest (`.manifest`) are artefacts
like the rest: they are listed in `SHA256SUMS`, paired across the two builds by
their name without the build timestamp, and compared byte for byte. The first
real run shows Yocto's SPDX 3.0 image SBOM is not byte-reproducible (see the
results section); the compare reports it and allows nothing.

The real run is in "Results of the --repro and debug builds" below. Besides
that run, `test/platform_image_repro_test.sh` and
`test/platform_image_build_test.sh` exercise the mode against a stub bitbake.


## Results of the --repro and debug builds

Date: 2026-11-27. Same host class, caps and checkout as the first build
(`BB_NUMBER_THREADS=16`, `PARALLEL_MAKE="-j 16"`, build and output directories
outside the clone), checkout commit `ce27c75d97262e8236b66a34b2285b9da1987a23`,
`platform_image_dirty=no`, manifest commit
`0c44ab18abe471b4326037b61893f4e69b6fc182` (`platform-image/manifest.lock`
unchanged; `platform-image-verify` checks every layer commit against it),
`SOURCE_DATE_EPOCH=1302044400`.
`ARGS=--check` passed first. No script was changed: the run exposed no script
defect. The EULA was not touched by this run (the template sets it).

A container kill between sessions stopped both builds mid-compile; the build
directories were kept and the builds restarted. The debug restart then failed
once in `binutils-native` `do_compile` (gas link: undefined x86 target symbols,
the half-written objects of the killed build). `bitbake -c cleansstate
binutils-native` and a restart finished it; this is not a script or recipe
fault. The `--repro` mode empties its two directories itself, so its restart
began from nothing.

### `make platform-image ARGS=--repro`: NOT identical (gap, row open)

Nothing was published to the default output directory. Both outputs were kept
and both pass `make platform-image-verify`. Build A took 6472 s. Build B
attempted 4716 tasks, 4686 of which "didn't need to be rerun": the two builds
share the host-tools cache's sstate directory, so B restored the recipes' built
packages from A and re-ran only the image assembly (rootfs, wic, SBOM), 1161 s.
So this run compares the image assembly of the same packages, **not** two
independent compiles of every recipe; whether the compiled packages are
reproducible is not shown, and a run with a separate `SSTATE_DIR` per build is
still to do.

| Artefact (name without the build stamp) | Build A SHA-256 | Build B SHA-256 | Same |
| --- | --- | --- | --- |
| `.manifest` | `9a786f5267c99ef5c6dbcb8469a58b2ba9d5cd834b46c6e190326d519e5996d8` | `9a786f5267c99ef5c6dbcb8469a58b2ba9d5cd834b46c6e190326d519e5996d8` | yes |
| `.tar.zst` (rootfs) | `c091f99f0c13b6e1742a0083a311135dabbf0f312cd30f1413623cc6ac37b043` | `c091f99f0c13b6e1742a0083a311135dabbf0f312cd30f1413623cc6ac37b043` | yes |
| `.wic.zst` | `0ec7d0f69ce1b5787abd44b998f15b952e58635d891e8a82a5ba973f5390c5af` | `7d8ca4c77b0623e8aaa3967da431f7ded93f63e4c516dee1556db6a1961e70b6` | **no** |
| `.wic.bmap` | `4798177db2553e86c8008872a1bf5a7b57cf767f44629d77b2b9e6adb10b7ffb` | `87de17ec36899bd46fff61e0e5af1d354e9e17c915773f2e1d2aa4ee70c16e86` | **no** |
| `.spdx.json` (SBOM) | `6b4027da615551eea26642afa4d63664238e551346500380c3522e5a83acd33f` | `5c358a66379d5ecb9e55d06151ec0f7c5993fe33b4289a4f9bb0f38fa2d2d936` | **no** |

The rootfs tarball and the package manifest are bit-identical across the two
builds (and equal to the first build's, 2026-11-24). `build-info.txt` matched
on every line but `build_seconds`.

Differing files and the cause found:

- `.wic.zst` and `.wic.bmap` (the `.bmap` follows the image's block map). The
  decompressed images have the same size (443534336 bytes) and differ in 62450
  bytes. The first differences read from a byte comparison are the two GPT
  partition GUIDs (bytes 1040-1055 and 1168-1183) and with them the
  partition-array and header CRCs (528-531, 600-603), the FAT volume serial of
  the `boot` partition (8388647-8388650), and a 16-byte run in the ext4
  superblock (276825193-276825207) that is the filesystem UUID. The remaining
  differences were not itemised; they are consistent with the checksums that
  depend on that UUID, but that was not verified. The disk GUID and the partition
  table layout are the same, and the rootfs tarball that feeds the root
  partition is identical. The likely cause is the wks file wic uses,
  NXP's `imx-imx-boot-bootpart.wks.in`: its three `part` lines set no `--uuid`
  and no `--fsuuid`. The fix, not made in this slice (it is outside its file
  map), is an own wks file in `platform-image/` with fixed `--uuid` and
  `--fsuuid` (and a FAT serial) per partition, selected by `WKS_FILE`.
- `.spdx.json`. Both documents hold 5063 graph elements of the same types. They
  differ in the order of `@graph`, in the numbering of the `_:CreationInfoNN`
  blank nodes (all 4916 elements with the same `spdxId` differ only there), and
  in which recipe's document carries 62 shared licence elements (62 `spdxId`s
  appear only in A and 62 others only in B, for example the same licence under
  another recipe's document; the order in which the recipe documents are
  combined is the likely cause, not confirmed). A
  fix is outside this slice: a normalising step or a Yocto SPDX setting,
  to be chosen with the reproducible-build survey's question 6.

### `make platform-image PI_DEBUG=1`

Built both targets, `trusted-imx95-image` and `trusted-imx95-image-debug`
(10 artefacts); `build_seconds=1219` for the run that finished (the earlier
partial run's tasks were reused). `make platform-image-verify OUT=<out dir>`
passes (10 artefacts, pins match). Output `SHA256SUMS`, stamp
`20261127015816`:

| Artefact | SHA-256 |
| --- | --- |
| `trusted-imx95-image-debug` `.manifest` | `3183831da97d482e5998965cb150469a323b05409bdc7f120aeac525f0aa7b34` |
| `trusted-imx95-image-debug` `.spdx.json` | `2d041bf89a0fc9c6c3defac861f7323b3eaca5dad900262371d0fb47a2d22d80` |
| `trusted-imx95-image-debug` `.tar.zst` | `15c645e589d9a4260d1468405a44864e34274e90a05ca36553089706804c3da1` |
| `trusted-imx95-image-debug` `.wic.bmap` | `d2b187e90bc104ac4de3c119cfed28dc9d7bb4e49e2a671f909105fca5142eb7` |
| `trusted-imx95-image-debug` `.wic.zst` | `1d0e3051ea227b7f1e12f00003753594b63dfb726fad51af08c5488153d02022` |
| `trusted-imx95-image` `.manifest` | `9a786f5267c99ef5c6dbcb8469a58b2ba9d5cd834b46c6e190326d519e5996d8` |
| `trusted-imx95-image` `.spdx.json` | `a9f870c5e2637567ee4cb6863784480a1ea0dd0671bfbbd85b246c674a5079df` |
| `trusted-imx95-image` `.tar.zst` | `c091f99f0c13b6e1742a0083a311135dabbf0f312cd30f1413623cc6ac37b043` |
| `trusted-imx95-image` `.wic.bmap` | `80d8ecb868c79bad17917f8c0d63a806f138db6d423804bb34ab3caec5daf874` |
| `trusted-imx95-image` `.wic.zst` | `8272a69cb17ae10fd5f72311e9350612dc07665f28a10f6950e97353ee60eaf9` |

The production rootfs tarball and manifest hashes equal the two `--repro` builds'
and the first build's: three builds, one hash. The debug build was not run
under `--repro`.

Open: the wic and SBOM differences above, and a `--repro` run with a separate
`SSTATE_DIR` per build. The reproducibility row stays open.

## Checking an output directory (provisional)

`scripts/platform-image-verify.sh [--allow-dirty] OUT [LOCK]`, or
`make platform-image-verify OUT=<dir>` (`ALLOW_DIRTY=1` for `--allow-dirty`; empty or `0` is off, any other value is an error),
checks that an output directory came from this checkout's pins. It is offline
and needs no bitbake. It fails, naming every problem, when: `SHA256SUMS` does
not verify or OUT holds an unlisted file (the compare script's own check, which
it calls); `build-info.txt` lacks a key or has one twice; `machine=`,
`manifest_commit=` or a `layer_*_commit=` differs from `LOCK` (default
`platform-image/manifest.lock`), or a layer is missing or extra;
`platform_image_dirty=yes` without `--allow-dirty`; or a target in `targets=`
has no `.spdx.json` listed; or the production target `trusted-imx95-image` has
no listed `.manifest`, an empty one, or one that names a package the debug
recipe adds (`IMAGE_INSTALL:append` in `trusted-imx95-image-debug.bb`, read
from that file, so the list is not typed twice; exit 2 if it cannot be parsed).
A package is matched by its whole name, so `gdbserver` is not `gdb`. The
production manifest must also name no package manager (`rpm`, `opkg`, `dnf`,
`apt`, `dpkg`: a list in the script, because the debug recipe installs one
through the `package-management` image feature, not a package name; a
provisional default, pending #14), again matched by whole name. The debug
target's manifest is not checked. Exit 0 is OK, 1 a mismatch, 2 a usage error.

A consumer runs it before AHAB signing (#14 Q4 (b)) or provisioning. It has
passed on real artefacts: the first build's output, and on 2026-11-27 the debug
output and both `--repro` outputs (see the results section below). Its stub
test is `test/platform_image_verify_test.sh`.

## Operator procedure (provisional, the EULA is accepted)

For a run with the NXP EULA accepted: the owner accepted it on 2026-11-24 and
the conf template sets `ACCEPT_FSL_EULA`; no step below sets it.

1. `make platform-image-hosttools`, then `source` the `env.sh` it prints.
2. `make platform-image ARGS=--check`: names missing host tools; builds nothing.
3. `make platform-image ARGS=--repro`: two builds and the compare; the output is
   published to `.platform-image/out/` only when they match. Add `PI_DEBUG=1`
   to build `trusted-imx95-image-debug` too.
4. `make platform-image-verify OUT=.platform-image/out`: the pins, the SBOMs and
   the production manifest check (see "Checking an output directory"). Add
   `ALLOW_DIRTY=1` only if `platform_image_dirty=yes` is expected, and say so.
5. Write back into this file, under "The first build": the sha256 of each
   artefact from `SHA256SUMS`; wall time of each build and the disk used;
   every failure, with the task and the message; the compare result (match, or
   the artefact and both hashes); and the verify result. Replace the "no image
   was built" result and the "not run" notes in the same commit.

If a step fails, stop there and record it; do not work around the compare or the
verify (neither has an exception option).
