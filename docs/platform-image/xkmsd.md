# Platform image: how xkmsd is packaged and checked

Every setting here is a provisional default, pending the owner's answer on #14.
xkmsd is go-xkms's daemon; this repository only packages it (SPEC.md,
Boundaries). Files: `platform-image/recipes-security/xkmsd/` (recipe, unit, mount
and config), `scripts/platform-image-xkmsd-smoke.sh` and
`scripts/platform-image-xkmsd-target-check.sh` (the on-target check, §The
on-target check).

## Key custody: which case applied

The production configuration (`files/xkmsd.yaml`, installed as
`/etc/xkms/xkmsd.yaml`) must not keep keys in files on the state partition,
where root can read them. The order was: use the enclave key-custody backend if
go-xkms at the pin has one; if it has none, leave key operations unavailable
until the enclave is provisioned.

Approved by the owner, 2026-11-25 (queue 339): the production configuration drops
software key custody, and key operations fail closed until the enclave is
provisioned.

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
- `xkmsd.service` keeps `Restart=on-failure` with `RestartSec=5s`, bounded by
  `StartLimitIntervalSec=300` and `StartLimitBurst=5` in `[Unit]`: until the
  enclave backend exists the daemon refuses to start, the unit is restarted at
  most five times in 300 seconds, and then it settles in the `failed` state
  instead of looping and flooding the journal. That is the fail-closed
  behaviour. `test/platform_image_xkmsd_test.sh` requires both limits, as
  positive numbers (0 or `infinity` would switch the bound off), and has a
  fixture for each way to lose it. Whether the unit should stay enabled until
  the backend exists is a question for the owner.

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

## Stopping on SIGTERM: an upstream question for go-xkms

The smoke script accepts a stop only when the daemon exits with status 0 **and**
logs `Server shutdown complete`. A status of 143 (the signal killed the process),
any other non-zero status, or status 0 with no such line fails the script; it
never skips. The string is in the binary built from the pin. The stubbed test
has a fixture for each of the three failures (`FAKE_DAEMON=sigterm-die`,
`sigterm-nonzero`, `sigterm-silent`).

What the real daemon does at the pin, run on the development config with the
barrier sealed (how it starts, §Key custody), SIGTERM sent after the ready line,
three seconds or immediately after it: it exits with status 143 and logs
nothing after `barrier sealed; sealed-window listener up, waiting for unseal`.
So **the real smoke run fails at this step** until go-xkms changes, or answers
that a sealed node should exit this way. This repository keeps the check
fail-closed rather than accept 143.

A failed stop does not hide the two checks that follow it. The script records
the failure, prints it as a `FAIL` line, and still runs the production-config
refusal and the read-only-state refusal, each of which prints its own `ok` or
fails the script at once. It exits non-zero after them with the stop failure
named. So against the pinned daemon a run reports the SIGTERM `FAIL`, the two
`ok` refusal lines, and then fails. The stubbed test has the three stop fixtures
assert both `ok` lines and a non-zero exit.

Upstream question for go-xkms (to be raised by the coordinator; nothing is
posted from this repository): does xkmsd handle SIGTERM with a clean shutdown
(exit 0 and `Server shutdown complete`) when the barrier is still sealed, or
only after an unseal? `xkmsd.service` stops the daemon with SIGTERM, so a
sealed node that dies by the signal reports a failed stop to systemd.

## The on-target check

`scripts/platform-image-xkmsd-target-check.sh` is the on-target check of the
deployed unit and its state. It is to be run once an image is built and booted;
nothing here has run it on a board. Its stubbed test,
`test/platform_image_xkmsd_target_check_test.sh` (in `make test`), answers the
script's ssh calls from fixtures, with one failing fixture for each property
below, and runs no board and no network.

Run it with `XKMSD_TARGET_HOST=<ssh destination> make platform-image-xkmsd-target-check`.
There is no default host: the script and the make target refuse without the
variable, and the repository names no host. The ssh user must be root;
`XKMSD_TARGET_SSH_OPTS` adds ssh options. It fails closed: each of these
that does not hold prints a `FAIL` line and the script exits non-zero.

1. **The unit and its sandbox.** `systemctl show xkmsd.service` reports the
   unit `active` and `running` with a main process, `User=xkmsd` and
   `Group=xkmsd`, and the effective sandbox of the unit: `NoNewPrivileges`,
   `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome`, `ProtectProc=invisible`,
   the `ProtectKernel*`, `ProtectClock` and `ProtectControlGroups` switches,
   `RestrictNamespaces`, `RestrictRealtime`, `RestrictSUIDSGID`,
   `LockPersonality`, an empty `CapabilityBoundingSet` and `UMask=0077`. A
   property that is missing from the output fails, it is not assumed.
2. **The main process as the kernel sees it.** `/proc/<pid>/status` shows the
   uid and gid of the image's `xkmsd` user in all four fields (not 0), no
   capability in any set, `NoNewPrivs: 1` and `Seccomp: 2`. This is what the
   smoke script cannot show: it runs the daemon as the build user, outside the
   sandbox.
3. **The state directory is the persistent state mount.** `findmnt` says
   `/var/lib/xkms` is a mount point of ext4 labelled `xkms-state`, read-write,
   `nosuid,nodev,noexec`; `var-lib-xkms.mount` is active with the `What=` and
   `Where=` of the image layout; and the directory is owned by `xkmsd`, mode
   0750.
4. **The daemon refuses to start on a read-only state mount.** The script stops
   the unit, remounts `/var/lib/xkms` read-only, starts the unit and requires
   the start to fail and the unit not to be active (the unit's
   `AssertPathIsReadWrite=`), then remounts read-write and starts the unit
   again. Both restores must succeed, or the script fails and says to restore the
   board by hand. A remount the kernel refused fails the check; it does not pass
   it. This step changes the board for a moment, so it runs only when steps 1 to
   3 passed.

**Expected result on a production image today.** The production configuration
names no key custody (§Key custody), so the real daemon refuses it and the
enabled unit reaches `failed` after five starts. Step 1 requires the unit to be
active, so the script fails closed on such an image, at its first line. That is
a true report, not a script fault: the unit is not serving. A run that passes
needs a configuration the daemon accepts (the enclave backend, once go-xkms has
one). Until then the script is checked against its stubs only.

## Owner decisions, 2026-11-25 (queue 339)

Two points of this page were proposals and are now **approved by the owner,
2026-11-25**:

- (a) **Key custody.** The production configuration drops software key custody,
  and key operations fail closed until the enclave is provisioned: approved by
  the owner, 2026-11-25. §Key custody describes what the file does.
- (b) **Reboot persistence test deferred.** The check that state under
  `/var/lib/xkms` survives a reboot (write a marker, reboot, read the marker and
  the mount) is deferred to the image-build row: approved by the owner,
  2026-11-25. Nothing here boots an image or reboots a board.

Everything else the image-build row is to do on the target stays proposed,
pending owner approval: boot the image, run the on-target check above, and
confirm there that the bounded restart (`StartLimitBurst=5` in 300 seconds)
takes the unit to `failed` on a production config that fails closed. That bound
is checked statically only until then.
