# Platform image build configuration

Every choice here is a provisional default, pending the owner's answer on
#14. The owner has not answered; the defaults are the ones
[build-system-options.md](build-system-options.md) recommends (section 10 and
section 11), written down so the owner can read a working proposal.

## What is in the tree

- `platform-image/manifest.lock`: the pins. NXP's manifest repository at the
  commit tag `lf-6.18.37-2.1.0` peels to, the manifest file
  `imx-6.18.37-2.1.0.xml`, and every project the manifest lists (20 layers),
  each with its repository, path and 40-hex commit. Hashes were read from the
  manifest file, and by `git ls-remote` for the three layers the manifest
  names by tag. None is typed by hand and none is MISSING.
- `platform-image/conf/distro/trusted-imx95.conf`: the headless distro,
  requiring NXP's `fsl-imx-fb-minimal`, with the display, audio and wireless
  features removed. It signs nothing.
- `platform-image/conf/layer.conf`, `local.conf.template`,
  `bblayers.conf.template`: the layer, and the templates for machine
  `imx95-19x19-lpddr5-frdm-pro`.
- `scripts/platform-image-fetch.sh`, `make platform-image-fetch`: checks the
  layers out into a directory outside the clone and fails when a layer's
  commit differs from the lock. It needs the network, so it is in neither
  `make build` nor `make test`.
- `test/platform_image_test.sh`, in `make test`: offline checks of the lock,
  the machine name and the distro file.

## The #14 questions and the answer assumed

| Question | Assumed (provisional) |
|---|---|
| Q1 build system | (a) Yocto with NXP meta-imx |
| Q2 BSP baseline | (a) manifest imx-6.18.37-2.1.0, every layer at the manifest's commit; the release `system-manager/sm.lock` already pins |
| Q3 distro | (b) our own headless distro, derived from an fsl-imx-* one |
| Q4 signing | (b) AHAB signing a separate step after the build, not inside it |

## Verified and not verified

Verified: the lock's hashes were read from their sources; the test runs
offline; `meta-imx` at its tag has the machine `imx95-19x19-lpddr5-frdm-pro`
and the `fsl-imx-fb-minimal` distro the file requires.

Not verified: no bitbake run, so the distro, the layer set in
`bblayers.conf.template` and the removed features are untested proposals;
`make platform-image-fetch` has not been run end to end; the NXP EULA
(`ACCEPT_FSL_EULA`) is left to the owner.
