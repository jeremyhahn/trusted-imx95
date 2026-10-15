# Resources

CompuLab UCM-iMX95 and SB-UCMIMX95 carrier artifacts, kept as reference for another i.MX 95 board; our device is the
NXP FRDM-IMX95-PRO (see docs/references/). Small design files are in this directory; the Linux image is too large for
the repository and is kept outside it, with its checksum recorded here.

| File | What |
|---|---|
| ucm-imx95_sb-design.zip | SB-UCMIMX95 carrier design 1v0: schematics (PDF and DSN), BOM, gerbers, layout, assembly drawings |
| ucm-imx95-mechanical-drawings.zip | UCM-iMX95 mechanical drawings (DXF, PDF) |
| ucm-imx95_3d-model.zip | UCM-iMX95 3D model (STEP) |

## Linux image (not in git)

| | |
|---|---|
| File | ucm-imx95_yocto-linux_04-12-2025.zip, 2,010,963,911 bytes |
| sha256 | 069e4f89c79600b6fd0ba52f8577ed927940e6b208f811886a0a7c8f142bc2b3 |
| Location | recorded in the private context repository jeremyhahn/vendor-nxp |
| Contents | CompuLab Yocto image 2025-12-03: imx-image-full-ucm-imx95 rootfs (wic.zst, bmap, manifest), kernel Image, dtbs (som, rpmsg, lvds overlay), modules, imx-boot binaries per silicon revision and DRAM variant, version.txt |

Fetch it from the location the private context repository jeremyhahn/vendor-nxp records; the zip itself is ignored by git in this directory.
