# Boot-container signing pipeline (test PKI)

Status: host-side pipeline for issue #9, in the `boot-container` row of
[docs/SPEC.md](../SPEC.md). It follows the owner's decision in
[signing-tool-options.md](signing-tool-options.md): SPSDK 3.13.0, ECDSA P-384, i.MX 95 B0
(SPSDK family `mimx9596`, revision `b0`).

`make ahab-sign-test` builds one AHAB OEM container around a random test payload, signs it with a
throwaway test PKI and verifies it with `nxpimage ahab verify`. It never touches a real key, an HSM,
a fuse, the life cycle or a board.

## How to run

In the devcontainer image, where the pinned SPSDK venv is at `/opt/spsdk` (`SPSDK_VENV`):

```sh
make docker-run CMD='make ahab-sign-test'
```

On a host with `python3` and `pip`, `make ahab-sign-test` runs the same steps. The first run
installs the pinned closure (`scripts/ahab/requirements.txt` and `build-requirements.txt`, every
file checked against its SHA-256 with `pip install --require-hashes`) into a venv under
`${XDG_CACHE_HOME:-$HOME/.cache}/trusted-imx95/`; set `SPSDK_VENV` to use another directory
outside the clone. The run fails, naming the pin, if the venv's `nxpimage` is not 3.13.0.

Set `AHAB_OUT_DIR` to keep a copy of the signed `container.bin`; nothing else leaves the run.
`scripts/ahab/sign-test.sh verify <container.bin>` verifies a container on its own and prints
`verify: OK` or `verify: FAILED`.

What one run does, in a `mktemp -d` work directory outside the clone that is removed on exit:

1. `nxpcrypto key generate -k secp384r1` writes four test SRKs (`srkN.pem`, `srkN.pub`).
2. `nxpimage ahab export -c container.yaml` builds and signs the container from
   [scripts/ahab/container.yaml](../../scripts/ahab/container.yaml) with SRK 0.
3. The `.bcf` fuse script that the export writes is deleted unread. It is never run.
4. `nxpimage ahab verify` checks the container.
5. The run prints the SRK table hash, labelled as for this test PKI only. It is not a value for any
   device's fuses.

`test/ahab_sign_test.sh` (in `make test`) checks that the container verifies, that copies with one
signature byte or one payload byte flipped are rejected, that the run writes nothing in the clone,
and that a wrong SPSDK version fails.

## musl and libuuu

SPSDK 3.13.0 requires `libuuu`, which publishes only glibc (manylinux) wheels. On musl (the Alpine
image) pip installs the pinned `libuuu` sdist instead. The sdist compiles nothing. It only packages
NXP's prebuilt glibc `libuuu.so`, which `nxpimage ahab export` and `verify` never load, so the
pipeline runs on musl. Board flashing through `nxpuuu` would load that library and is not part of
this pipeline.

## MISSING

- The container's anti-rollback `fuse_version` and header version for a real device, and a real
  device's SRK hash fuse values. Their sources (IMX95RM, the i.MX 95 Security Reference Manual)
  are not in `docs/references`. See the comments in `container.yaml`.
- HSM signing (go-xkms custody) and the CST cross-check are out of scope here.
