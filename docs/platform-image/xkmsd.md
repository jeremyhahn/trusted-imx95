# Platform image: how xkmsd is packaged and checked

Every setting here is a provisional default, pending the owner's answer on #14.
xkmsd is go-xkms's daemon; this repository only packages it (SPEC.md,
Boundaries). Files: `platform-image/recipes-security/xkmsd/` (recipe, unit, mount
and config) and `scripts/platform-image-xkmsd-smoke.sh`.

## Key custody: which case applied

The production configuration (`files/xkmsd.yaml`, installed as
`/etc/xkms/xkmsd.yaml`) must not keep keys in files on the state partition,
where root can read them. The order was: use the enclave key-custody backend if
go-xkms at the pin has one; if it has none, leave key operations unavailable
until the enclave is provisioned.

**Case that applied: go-xkms has no enclave key-custody backend at the pin
(`v0.64.2-alpha`, commit `9f040cea`), so production fails closed.** Read in the
checkout at the pin: `pkg/backend` holds `avr`, `awskms`, `azurekv`, `gcpkms`,
`importtoken`, `mocks`, `phone`, `pkcs11`, `software`, `tpm2` and `vault`;
`pkg/enclaveprovider` is go-enclave memory sealing, not a key backend. None of
them is the i.MX95 enclave (ELE) key store. `pkcs11` and `tpm2` are not claimed
as stand-ins: the board's key custody is the enclave's (hsm-device-protocol
R2), and neither is configured here.

What the production file does:

- It names no `default_backend`, no `backends:` entry and no `ca:` identity.
  The software and pkcs8 backends and the software CA keystore moved to
  `platform-image/recipes-security/xkmsd/dev/xkmsd-dev.yaml`, which the recipe
  does not name in `SRC_URI`, `do_install` or `FILES`, so the image never
  carries it. `rng` stays `software` in both: that is the entropy source
  (the kernel's `getrandom`), not key custody.
- The real daemon refuses that file. Run on the binary built from the pin it
  logs `Failed to load configuration ... default_backend must be specified` and
  exits 1; with a backend named but none enabled it says `at least one backend
  must be enabled`; with `pkcs11` or `tpm2` enabled and no library or device it
  says so and exits 1. It serves nothing, so no key operation is available.
- `xkmsd.service` keeps `Restart=on-failure` with `RestartSec=5s`: until the
  enclave backend exists the unit restarts every five seconds and fails each
  time. That is the fail-closed behaviour, and it is noisy in the journal.
  Whether the unit should stay enabled until then is a question for the owner.

Checks: `test/platform_image_xkmsd_test.sh` fails when an active line of the
production file, outside its `rng:` section, names `software` or `pkcs8`
(a `default_backend`, a `backends:` entry or a `keystore-type`), and when the
recipe names the development file. The smoke script starts the daemon on the
development file to reach the ready state, and checks the real daemon refuses
the production file: it must exit non-zero and serve no socket.

When go-xkms ships an enclave backend, the production file selects it, the
`ca:` section comes back with an enclave keystore, and the smoke script's
refusal check changes to a ready-state check on that file.

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
