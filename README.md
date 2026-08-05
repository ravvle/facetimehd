# FaceTime HD Camera for Linux

Enable the built-in Apple FaceTime HD camera on 2013–2015 Intel MacBooks
running Ubuntu, Fedora or a compatible Linux distribution. Main improvements over
[patjak/facetimehd](https://github.com/patjak/facetimehd) is **working suspend/resume**, **safer code**, **image resolution/scaling fixes**, **auto calibration** and exposing the extra controls to user programs. It also uses more modern kernel tie ins and drops support for kernels older than 5.15.

[![CI](https://github.com/ravvle/facetimehd/actions/workflows/ci.yml/badge.svg)](https://github.com/ravvle/facetimehd/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/ravvle/facetimehd)](LICENSE)
[![Distros](https://img.shields.io/badge/distros-Ubuntu%20%7C%20Fedora-orange)](#distribution-compatibility)
[![Kernel](https://img.shields.io/badge/kernel-5.15%2B-blue)](https://kernel.org)

## Origins and acknowledgements

This project is derived from the work of **Patrik Jakobsson (`patjak`) and the
facetimehd contributors**:

- [patjak/facetimehd](https://github.com/patjak/facetimehd) provides the
  original Linux driver for the Broadcom 1570 PCIe camera.
- [patjak/facetimehd-firmware](https://github.com/patjak/facetimehd-firmware)
  provided the firmware-extraction work maintained here as
  [`scripts/extract-firmware.sh`](scripts/extract-firmware.sh).
- [godwill1224/facetimehd-ubuntu-macbook](https://github.com/godwill1224/facetimehd-ubuntu-macbook)
  for the base the install scripts were made from
- [linux-on-mac/mbpfan](https://github.com/linux-on-mac/mbpfan) provides the
  optional fan daemon used by the setup helper.

The installer, driver fork, audits, tests and documentation were
developed with assistance from **Claude Code** and **ChatGPT
Codex**. The driver was forked @ [patjak/facetimehd](https://github.com/patjak/facetimehd)
[`364b1c6`](https://github.com/patjak/facetimehd/commit/364b1c663583e64e27f07ed0257a7584bef095fc).

## What this project does

The repository packages everything needed to make the PCIe FaceTime HD camera
usable and mbpfan to improve cpu thermals:

- builds the `facetimehd` driver;
- registers it with DKMS so it is rebuilt after kernel updates;
- downloads an Apple update and safely extracts the proprietary camera
  firmware, which cannot be redistributed in this repository;
- installs the matching sensor calibration files (`unar` is a required
  dependency for this); and
- optionally installs and enables `mbpfan` on Apple hardware.

The driver built by this project lives in
[`src/facetimehd/`](src/facetimehd/). It is a fork of
`patjak/facetimehd` at
[`364b1c6`](https://github.com/patjak/facetimehd/commit/364b1c663583e64e27f07ed0257a7584bef095fc),
with a concise record of its changes in
[`src/facetimehd/DOWNSTREAM.md`](src/facetimehd/DOWNSTREAM.md).

## Improvements over the original patjak driver

The downstream driver retains the original hardware support while adding:

- bounds checks for hardware-register access and validation of data returned by
  firmware;
- safer ISP memory tracking, scatterlist handling and pointer-free VB2 buffer
  tags;
- bounded IRQ/ring processing and reliable propagation of hardware, firmware
  and streaming failures;
- symmetric probe, removal, suspend and resume cleanup, including safe handling
  of open file descriptors during unbind;
- runtime camera suspend/resume, reliable system sleep while streaming, safe
  shutdown and PCI error handling;
- wider DDR memory verification and removal of unfinished, unused calibration
  code containing ineffective timeouts and unbounded paths;
- correct full-sensor scaling at lower resolutions instead of a zoomed crop
  from the top-left corner;
- model-specific sensor-size detection, correct format limits and improved
  V4L2 frame-size, frame-rate, selection and status reporting;
- controls that are restored when streaming starts, plus optional 50/60 Hz
  anti-banding and automatic/manual exposure controls;
- correct MacBook Air sensor-calibration selection and complete
  `MODULE_FIRMWARE` declarations; and
- current Linux 5.15+ APIs, quieter diagnostics, Clang builds, Sparse checks
  and on-hardware validation scripts.

Core probing, capture, runtime suspend/resume and system suspend recovery have
been tested repeatedly on a MacBookAir7,2. The complete change list and current
hardware-validation limits are documented in
[`DOWNSTREAM.md`](src/facetimehd/DOWNSTREAM.md).

## Compatibility

### Hardware

This project is for the **Broadcom BCM1570 PCIe FaceTime HD camera**, PCI ID
`14e4:1570`, used in 2013–2015 Intel MacBooks. Known configurations include:

- MacBookPro11,1, MacBookPro11,2 and MacBookPro11,3;
- MacBookAir7,2, used for this project's hardware validation; and
- other 2013–2015 Intel MacBooks exposing the same `14e4:1570` PCI device.

Sensor dimensions are detected at runtime, including the 848x588 sensor used by
MacBook8,1. The installer checks the PCI bus and refuses by default when the
supported camera is not present.

Later Intel MacBooks with a USB camera normally use the kernel's `uvcvideo`
driver. Apple Silicon systems require the camera support provided by
[Asahi Linux](https://asahilinux.org/) and are outside this project's scope.

Check your hardware with:

```bash
lspci -nn | grep -i '14e4:1570'
```

### Distribution compatibility

| Distribution | Typical kernel | DKMS | Status |
| --- | --- | --- | --- |
| Ubuntu 26.04 LTS | 7.0 | 3.2.2 | Supported and CI-tested |
| Ubuntu 24.04 LTS | 6.8 / HWE | 3.0.11 | Supported and CI-tested |
| Ubuntu 22.04 LTS | 5.15 / HWE | 2.8.7 | Supported and CI-tested |
| Fedora 44 | 7.1 | 3.4.2 | Supported and CI-tested |

The scripts automatically use `apt-get` or `dnf`. Debian, Linux Mint, Pop!_OS
and Fedora derivatives will usually work when they provide DKMS and matching
kernel headers, but only the releases in the table are covered by CI.

RHEL, AlmaLinux and Rocky Linux are not directly supported because DKMS is
normally supplied through EPEL, which this installer does not enable.

## Installation

Clone the repository and run the guided setup:

```bash
git clone https://github.com/ravvle/facetimehd.git
cd facetimehd
sudo ./setup.sh
sudo reboot
```

The setup asks whether to install the camera driver and whether to add optional
fan support. For the camera, it checks the hardware, installs build dependencies
and matching kernel headers, builds the driver through DKMS, extracts the Apple
firmware and loads the module. It is safe to run again; an unchanged installed
driver is not rebuilt unnecessarily.

### Verify the installation

After rebooting:

```bash
lsmod | grep facetimehd
dkms status -m facetimehd
v4l2-ctl --list-devices
```

The camera should appear as **Apple FaceTime HD** under `/dev/videoN`.

If your user cannot open it, join the `video` group and then log out and back
in:

```bash
sudo usermod -aG video "$USER"
```

Secure Boot systems may require enrollment of the DKMS Machine Owner Key before
the module can load. See [Troubleshooting and support](#troubleshooting-and-support)
if the build succeeds but `modprobe facetimehd` fails.

## Firmware and sensor calibration

Apple's camera firmware is proprietary and is therefore **not included** in
this repository. During installation, the maintained extractor downloads only
the required portion of an Apple-hosted OS X update, extracts the
`AppleCameraInterface` firmware and verifies known SHA-256 checksums before
installing:

```text
/usr/lib/firmware/facetimehd/firmware.bin
```

Calibration files come from a separate Apple Boot Camp package. They are not
required for capture, but missing calibration can produce incorrect colours.
`install.sh` fetches them on every run, since `unar` is a required dependency;
if that step still failed for some other reason (e.g. no network access to
Apple's Boot Camp download), retry it directly:

```bash
sudo ./scripts/extract-firmware.sh --calibration-only
```

These Apple downloads are the only installation steps that require network
access beyond installing distribution packages; the driver source is already
included in the repository.

## Optional fan support

Some Intel MacBooks run hot under Linux because the firmware exposes only a
conservative fan floor. If wanted, this project can install and enable
[`mbpfan`](https://github.com/linux-on-mac/mbpfan). Select fan support when the
guided setup asks; it can also be added later by rerunning:

```bash
sudo ./setup.sh
```

The setup uses the distribution package and leaves mbpfan's own fan curve
unchanged. Check it with:

```bash
systemctl status mbpfan.service
journalctl -u mbpfan -b
```

To disable it again when this project enabled it:

```bash
sudo ./scripts/macbook-tune.sh --revert
```

## Uninstallation

```bash
sudo ./scripts/uninstall.sh
```

This removes all detected `facetimehd` DKMS versions, installed driver sources,
firmware and calibration files. It also disables `mbpfan` if this project
enabled it. To leave the fan daemon running:

```bash
sudo ./scripts/uninstall.sh --keep-tuning
```

## How installation is maintained

- `src/facetimehd/` is the reviewed driver fork that gets compiled.
- The installer derives the version from `dkms.conf`, appends a source
  fingerprint, and stages the result under `/usr/src/`.
- DKMS rebuilds the module for future kernel updates automatically.
- CI runs shell checks, GCC and Clang kernel builds, and Sparse analysis across
  the supported distribution matrix.

Driver fixes belong in `src/facetimehd/`, should be recorded in
`DOWNSTREAM.md`, and should also be proposed upstream where possible.

## Repository layout

```text
setup.sh                       Guided camera/fan setup
scripts/install.sh             Driver, DKMS, firmware and calibration installer
scripts/uninstall.sh           Complete removal
scripts/macbook-tune.sh        Optional mbpfan helper
scripts/extract-firmware.sh    Maintained Apple firmware extractor
src/facetimehd/                Maintained driver built by the installer
tests/                         Build, capture and hardware-validation scripts
```

## Troubleshooting and support

These commands provide the most useful initial diagnostics:

```bash
lspci -nn | grep -i '14e4:1570'
dkms status -m facetimehd
lsmod | grep facetimehd
v4l2-ctl --list-devices
sudo dmesg | grep -iE 'facetimehd|bcwc'
```

When opening an issue, include the MacBook model, distribution, kernel, DKMS
status and relevant kernel messages:

```bash
sudo dmidecode -s system-product-name
cat /etc/os-release
uname -r
dkms status -m facetimehd
sudo dmesg | grep -iE 'facetimehd|bcwc'
```

Issues and contributions are welcome through
[GitHub](https://github.com/ravvle/facetimehd/issues). Reports from additional 2013–2015 MacBook
models are especially useful.

## License

The project is **GPL-2.0-only**, including the maintained scripts, tests,
documentation and driver source. The extracted Apple firmware remains
proprietary and is not redistributed by this project. See [LICENSE](LICENSE)
for attribution and licensing details.
