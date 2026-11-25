# Platform image: how xkmsd is packaged and checked

Every setting here is a provisional default, pending the owner's answer on #14.
xkmsd is go-xkms's daemon; this repository only packages it (SPEC.md,
Boundaries). Files: `platform-image/recipes-security/xkmsd/` (recipe, unit, mount
and config) and `scripts/platform-image-xkmsd-smoke.sh`.

## What the smoke script checks

`make platform-image-xkmsd-smoke` builds the pinned go-xkms with the recipe's
build script and starts the daemon on a scratch state directory. Its offline
stubbed test is `test/platform_image_xkmsd_test.sh`, which runs in `make test`.

Unit and mount (`xkmsd.service`, `var-lib-xkms.mount`): the script runs
`systemd-analyze verify` on both files, and `systemd-analyze condition` on the
two Assert lines of the service. Both Assert lines are required in the unit:

- `AssertPathIsMountPoint=/var/lib/xkms` makes the unit fail, not skip, when
  nothing is mounted on the state directory;
- `AssertPathIsReadWrite=/var/lib/xkms` makes it fail when the mount is
  read-only. It tests the mount's read-only flag, not directory permissions.

The script checks that `/` satisfies the mount-point assertion, that a plain
directory does not, and that a writable directory satisfies the read-write
assertion. When `systemd-analyze` is absent (some CI images), or
`XKMSD_SMOKE_OFFLINE_UNITS=1` is set, it falls back to reading the unit and the
mount file for the same lines (`RequiresMountsFor=`, `After=`, both Asserts,
and the mount's `What=` and `Where=`).

## Boot and reboot persistence: proposed, pending owner approval

Boot-and-reboot persistence of `/var/lib/xkms` on a built wic image is deferred
to the image-build row. Nothing here boots an image: the wic layout is unbuilt
and the smoke script runs on the build host. Proposed, pending owner approval:
the image-build row boots the image, writes a marker under `/var/lib/xkms`,
reboots, and checks the marker and the mount. Until then the guarantee is only
that the unit refuses to start without the mount (the checks above).
