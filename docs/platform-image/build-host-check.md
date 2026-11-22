# Build-host check of the platform image metadata

A real BitBake run of the metadata in `platform-image/`, recorded so it can be
repeated. Provisional, pending the owner's answer on #14. No image was built:
the run parses the metadata and configures the kernel.

- Date: 2026-11-22.
- Yocto release: 6.0.1 (wrynose), through its buildtools-extended SDK.
- Machine: `imx95-19x19-lpddr5-frdm-pro` (the lock's).
- Worker: a non-root user on Debian 13 (trixie), x86_64, with no apt lists of
  its own, no `wget` and no `file`.

## The layers (from `platform-image/manifest.lock`)

NXP manifest `imx-6.18.37-2.1.0.xml` at tag `lf-6.18.37-2.1.0`
(`0c44ab18abe471b4326037b61893f4e69b6fc182`). The fetch check passed for all 19
layers, each at the lock's commit:

| Layer | Commit |
|---|---|
| bitbake | `acfe02fa38b5da9e6a36c6cedcf91d4fcbefbfbd` |
| openembedded-core | `5d1aa5c806c061a2994f4decb59016610f093213` |
| meta-yocto | `24c24cef5d1523fefe43a3e3d34667b37ae551f3` |
| meta-clang | `ef0d22f21910a0c30c967eeb17d8f209806e2d81` |
| meta-openembedded | `6bf0d8ad57b33950bab4c7f6c037e1ccb6f6e2eb` |
| fsl-community-bsp-base | `1d8c41be87979d063b34a98044cc5f8e1279eb2c` |
| meta-freescale | `ca31f33c5b5e433939c5f8442d2de56925d638bd` |
| meta-freescale-3rdparty | `26d8b36a72acf1458a2520e4e9f4d654a4ba77e4` |
| meta-freescale-distro | `4464f38b4aa618b5942f5e35dd25cff590f410a6` |
| meta-freescale-ml | `1330790bc6cdd3808260a16383d928e05a0e0eeb` |
| meta-arm | `0979b80429099f1a42dc0026c8c466cee780bc74` |
| meta-qt6 | `302c4fab8d230f5cb7b21e4304c728831a0658cb` |
| meta-browser | `407e3ac990f5ed466cb76e5002f918860503799c` |
| meta-security | `c0d1d6200e7a84c39fb940cb1f22aad4b0b3d808` |
| meta-timesys | `bf4ff1bb4c85bb7a1c65bc6f2cc6188ff5b76ef2` |
| meta-virtualization | `30f1a9d7e5ef1b41c64ff4c3c40951133d548ed8` |
| meta-imx (`rel_imx_6.18.37_2.1.0`) | `2eb758f42cfb96042344815b7dd7755b06ba1e3b` |
| meta-nxp-connectivity (`rel_imx_6.18.37_2.1.0`) | `12e139aa362660e2a7545b2924076038958e5144` |
| meta-nxp-demo-experience (`rel_imx_6.18.37_2.1.0`) | `dd4e742a339c51f90dec8ea59c62add1f7f157fa` |

## The host tools

- Yocto buildtools-extended 6.0.1,
  `x86_64-buildtools-extended-nativesdk-standalone-6.0.1.sh`, sha256
  `fe21a5aaf7084db0792d0c7392201875ab813bef68e8ab04b02ad5d15447cd2c`. The
  script checks the download against this pin and against the published
  `.sh.sha256sum`; either mismatch fails closed and installs nothing.
- Host packages, fetched with `apt-get download` into a private apt state
  directory and unpacked with `dpkg -x` (no root):

| Package | Version |
|---|---|
| cpio | 2.15+dfsg-2 |
| diffstat | 1.67-1 |
| file | 1:5.46-5 |
| libmagic-mgc | 1:5.46-5 |
| libmagic1t64 | 1:5.46-5 |
| gawk | 1:5.2.1-2+b1 |
| libsigsegv2 | 2.14-1+b2 |
| socat | upstream 1.8, patch level 0.3, Debian revision 1+deb13u1 |
| libwrap0 | 7.6.q-36 |

BitBake runs its tasks with a filtered environment, so each extracted tool is
reached through a wrapper that sets `LD_LIBRARY_PATH` and `MAGIC`; without it
`gawk` could not load `libsigsegv` and quilt-native's configure failed.

## The commands and their exit status

| Command | Exit status |
|---|---|
| `make platform-image-hosttools` | 0 |
| `make platform-image-parse` (after sourcing the generated `env.sh`) | 0: 3604 recipes parsed, 0 errors |
| `make platform-image-kernel-config` (after sourcing the generated `env.sh`) | 0: 630 tasks, all succeeded; 31 required symbols checked |

The run found and fixed these metadata and script defects, each in its own
commit: the distro's `DISTRO_FEATURES_BACKFILL_CONSIDERED` is
`DISTRO_FEATURES_OPTED_OUT` on wrynose; NXP's `fsl-imx-fb-minimal.conf` at the
lock's meta-imx commit sets the obsolete `DISTRO_FEATURES_DEFAULT`, so the
distro requires `poky.conf` and carries over the settings it needs from
`fsl-imx-base.inc`; meta-perl and meta-multimedia (for the `wireplumber` and
`dvb-apps` bbappends of meta-imx) joined the layer set; the parse script
removes BitBake's generated `lib/bb/pysh/pyshtables.py` so a repeat run passes
the fetch's cleanliness check; both scripts stop the BitBake server they
started on every exit.

## The checked values

`make platform-image-parse` checks `MACHINE`, `DISTRO`, `INIT_MANAGER` and
that `IMAGE_FEATURES` holds none of `debug-tweaks`, `empty-root-password`,
`allow-empty-password` or `allow-root-login`. `bitbake -e` gave:

| Image | `MACHINE` | `DISTRO` | `INIT_MANAGER` | `IMAGE_FEATURES` |
|---|---|---|---|---|
| `trusted-imx95-image` | `imx95-19x19-lpddr5-frdm-pro` | `trusted-imx95` | `systemd` | `read-only-rootfs` |
| `trusted-imx95-image-debug` | `imx95-19x19-lpddr5-frdm-pro` | `trusted-imx95` | `systemd` | `package-management read-only-rootfs tools-debug` |

`make platform-image-kernel-config` ran `bitbake linux-imx -c configure`
(linux-imx 6.18.37) and checked the generated `.config` against
`platform-image/kernel-required.txt`. Every required symbol held its required
state (a required `n` holds when the symbol is "is not set" or absent):

| Symbol | Required state | Result |
|---|---|---|
| `HARDENED_USERCOPY`, `SLAB_FREELIST_RANDOM`, `SLAB_FREELIST_HARDENED`, `SLAB_BUCKETS`, `RANDOM_KMALLOC_CACHES`, `SHUFFLE_PAGE_ALLOCATOR`, `LIST_HARDENED`, `BUG_ON_DATA_CORRUPTION`, `SCHED_STACK_END_CHECK`, `FORTIFY_SOURCE`, `SECURITY_DMESG_RESTRICT`, `RANDOMIZE_KSTACK_OFFSET_DEFAULT`, `INIT_ON_ALLOC_DEFAULT_ON`, `SYN_COOKIES`, `PROC_MEM_NO_FORCE`, `DEBUG_WX`, `ARM64_SW_TTBR0_PAN`, `ZERO_CALL_USED_REGS`, `PANIC_ON_OOPS` | `y` | `y` |
| `SLAB_MERGE_DEFAULT`, `LDISC_AUTOLOAD`, `LEGACY_PTYS`, `LEGACY_TIOCSTI`, `DEVMEM`, `DEVPORT`, `KEXEC`, `KEXEC_FILE`, `CRASH_DUMP` | `n` | `n` |
| `DEFAULT_MMAP_MIN_ADDR` | `65536` | `65536` |
| `PANIC_TIMEOUT` | `-1` | `-1` |
| `MAGIC_SYSRQ_DEFAULT_ENABLE` | `0xb0` | `0xb0` |

## Not covered

No image was built; no kernel was compiled (only configured); the options were
not checked against the BSP drivers. CI does not run these targets.

## Repeat this run

On an x86_64 Linux host with the network, a non-root user and `curl`,
`apt-get`, `dpkg` and `sha256sum`:

```sh
make platform-image-hosttools        # buildtools + host tools into a cache directory (HOSTTOOLS_DIR overrides it)
. "$HOME/.cache/trusted-imx95/hosttools/env.sh"
make platform-image-parse            # fetch the pins, bitbake -p, bitbake -e for both images
make platform-image-kernel-config    # bitbake linux-imx -c configure, then the .config check
```

The first run downloads the sources and builds the native tools (630 tasks for
the kernel configure) and takes a long time. If the host tools change, delete
`build/tmp/hosttools` in the platform-image cache directory, because BitBake
keeps symlinks there to the old ones.
