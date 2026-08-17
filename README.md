# FaceTime HD Camera for Linux

Enable the built-in Apple FaceTime HD camera on 2013–2015 Intel MacBooks
running Ubuntu, Fedora, AlmaLinux or a compatible Linux distribution. Main improvements over
[patjak/facetimehd](https://github.com/patjak/facetimehd) is **working suspend/resume**, **safer code**, **image resolution/scaling fixes**, **auto calibration** and exposing the extra controls to user programs. It also uses more modern kernel tie ins and drops support for kernels older than 5.15.

[![CI](https://github.com/ravvle/facetimehd/actions/workflows/ci.yml/badge.svg)](https://github.com/ravvle/facetimehd/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/ravvle/facetimehd)](LICENSE)
[![Distros](https://img.shields.io/badge/distros-Ubuntu%20%7C%20Fedora%20%7C%20AlmaLinux-orange)](#distribution-compatibility)
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
- a stream that survives suspend: an application capturing when the lid closes
  keeps capturing when it opens, without being restarted;
- wider DDR memory verification and removal of unfinished, unused calibration
  code containing ineffective timeouts and unbounded paths;
- correct full-sensor scaling at lower resolutions instead of a zoomed crop
  from the top-left corner;
- model-specific sensor-size detection, correct format limits and improved
  V4L2 frame-size, frame-rate, selection and status reporting;
- controls that are restored when streaming starts, plus optional 50/60 Hz
  anti-banding and automatic/manual exposure controls;
- manual exposure time, gain and white-balance temperature, which the automatic
  switches previously offered no way to set, alongside exposure compensation,
  metering mode, sharpness and a sensor test pattern;
- backlight compensation, noise reduction and chroma noise suppression;
- **selectable frame rates** — an application asking for 15 fps now gets 15 fps
  instead of 30, at any whole division of the sensor's rate;
- **digital zoom and pan** through `VIDIOC_S_SELECTION`, instead of a crop
  rectangle fixed at the full sensor;
- the sensor die temperature through `hwmon` and debugfs;
- `NV16` offered next to `YUYV` and `YVYU`;
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
| AlmaLinux 10 | 6.12 | 3.x (EPEL) | Supported and CI-tested |

The scripts automatically use `apt-get` or `dnf`. Debian, Linux Mint, Pop!_OS
and Fedora derivatives will usually work when they provide DKMS and matching
kernel headers, but only the releases in the table are covered by CI.

#### Enterprise Linux (AlmaLinux, Rocky, CentOS Stream, RHEL)

Red Hat does not ship DKMS, so on these distributions it comes from
[EPEL](https://docs.fedoraproject.org/en-US/epel/), which is not enabled out of
the box. **The installer enables it for you**: it turns on CodeReady Builder
(which EPEL's own dependencies need) and installs `epel-release` from the
distribution's `extras` repository, falling back to the EPEL project's own
`epel-release-latest-<major>` package on RHEL proper, which has no `extras`.
Both steps are skipped when EPEL is already enabled, and neither is undone by
`scripts/uninstall.sh` — other packages may depend on EPEL by then, so removing
a system-wide repository on the way out would be the more surprising choice.

To set it up yourself beforehand, or to check what the installer did:

```bash
sudo dnf install epel-release
sudo dnf config-manager setopt crb.enabled=1   # dnf4: --set-enabled crb
dnf repolist --enabled | grep -E 'epel|crb'
```

**AlmaLinux 10 is the first Enterprise Linux release this driver can be used
on.** RHEL 9 and its rebuilds ship kernel 5.14, just below the 5.15 floor;
RHEL 10's 6.12 clears it comfortably. `mbpfan` and `unar` also come from EPEL,
and EPEL does not rebuild every Fedora package for every EL release — if either
is missing, the installer says so and carries on. Neither is needed to build or
load the driver; `unar` only unpacks the sensor calibration files, so without
it the camera works but its colours are off.

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
./scripts/install.sh --status
```

This checks the hardware, the DKMS registration, the module, the firmware, the
calibration files, Secure Boot and the video device in one pass, and prints a
`fix:` line for anything that is wrong. It needs no root.

The camera should appear as **Apple FaceTime HD** under `/dev/videoN`.

If your user cannot open it, join the `video` group and then log out and back
in:

```bash
sudo usermod -aG video "$USER"
```

### Secure Boot

With Secure Boot enabled, an unsigned kernel module builds perfectly and then
refuses to load — which looks like a successful install and a broken camera.
DKMS can sign the module, but only with a key the firmware trusts:

```bash
sudo ./scripts/install.sh --enroll-mok
```

That generates a Machine Owner Key, points DKMS at it and hands it to
`mokutil`, which asks you to choose a one-time password. **The next boot needs
you at the keyboard**: a blue MokManager screen appears before the system
starts, where you choose *Enrol MOK → Continue → Yes* and enter that password.
Skip that screen and the key is not enrolled.

`install.sh --status` reports whether a key is enrolled. Uninstalling does not
remove the key — by then it may be signing other modules on the machine.

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
`install.sh` fetches them on every run where `unar` is available — which is
every distribution in the table above, `unar` being a normal dependency of the
install. That download currently carries files for four of the nine sensors
the driver recognises; a machine whose sensor needs one of the other five sees
this in `dmesg` (`no sensor calibration file ...`), and `install.sh --status`
surfaces the same thing. If the step instead failed outright (no network
access to Apple's Boot Camp download, or a distribution that does not package
`unar`), retry it directly once the cause is fixed:

```bash
sudo ./scripts/extract-firmware.sh --calibration-only
```

These Apple downloads are the only installation steps that require network
access beyond installing distribution packages; the driver source is already
included in the repository.

## Installing as a package

If you would rather have the driver tracked by `dpkg` or `rpm` than by a shell
script — or you are building a system image:

```bash
./packaging/build-deb.sh     # facetimehd-dkms_<version>_all.deb
./packaging/build-rpm.sh     # facetimehd-dkms-<version>-1.noarch.rpm
sudo apt install ./packaging/out/facetimehd-dkms_*.deb
sudo facetimehd-firmware-install
```

The packages install the driver source and register it with DKMS. They
deliberately do **not** download the firmware during installation: it is
Apple's and cannot be redistributed, and a package post-install script that
reaches the network breaks offline installs and image builds. That is what the
separate `facetimehd-firmware-install` command is for. See
[`packaging/README.md`](packaging/README.md).

Secure Boot is also outside what a package can do — enrolling a key needs a
password typed at a console and a reboot. Use `install.sh --enroll-mok`.

## Camera controls

Beyond the usual brightness and contrast, the driver exposes:

```bash
v4l2-ctl --list-ctrls                       # everything available
v4l2-ctl --set-parm 15                      # 15 fps instead of 30
v4l2-ctl --set-ctrl auto_exposure=1,exposure_time_absolute=200
v4l2-ctl --set-ctrl backlight_compensation=200   # lift a backlit face
v4l2-ctl --set-ctrl noise_reduction=200          # dim rooms
v4l2-ctl --set-ctrl power_line_frequency=1       # 50 Hz anti-banding
```

Frame rates are any whole division of the sensor's fixed 30 fps — 30, 15, 10,
7.5, 6, 5 and so on — reported exactly by `v4l2-ctl --list-formats-ext`.

Digital zoom crops the sensor and lets the ISP scale the result:

```bash
v4l2-ctl --set-selection=target=crop,left=160,top=90,width=960,height=540
```

The crop is only settable while nothing is streaming, and never smaller than the
capture size.

The sensor die temperature appears under `hwmon` when the firmware reports it in
a scale the driver can trust; the raw value is always in
`/sys/kernel/debug/facetimehd/*/sensor_temperature_raw`. See
[`DOWNSTREAM.md`](src/facetimehd/DOWNSTREAM.md) for why that distinction exists.

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
                               (also --status, --enroll-mok, --runtime-pm)
scripts/uninstall.sh           Complete removal
scripts/macbook-tune.sh        Optional mbpfan helper
scripts/extract-firmware.sh    Maintained Apple firmware extractor
scripts/collect-diagnostics.sh One-file bug report
packaging/                     .deb and .rpm builders
src/facetimehd/                Maintained driver built by the installer
tests/                         Build, capture, script and hardware-validation
                               scripts
```

## Troubleshooting and support

Start here — it names the problem in most cases and tells you how to fix it:

```bash
./scripts/install.sh --status
```

Common answers:

| Symptom | Cause | Fix |
| --- | --- | --- |
| Module builds, will not load | Secure Boot with no enrolled key | `sudo ./scripts/install.sh --enroll-mok` |
| Camera present, black image | Firmware not installed | `sudo ./scripts/extract-firmware.sh` |
| Image works, colours wrong | Calibration files missing | `sudo ./scripts/extract-firmware.sh --calibration-only` |
| Nothing rebuilt after a kernel update | Kernel headers missing | `apt install linux-headers-$(uname -r)` / `dnf install kernel-devel-$(uname -r)` |
| Camera unreliable when idle | Driver runtime PM | `sudo ./scripts/install.sh --runtime-pm off` |
| Install fails at the Apple download | Apple's URL moved | `./scripts/extract-firmware.sh --check-sources` and open an issue |

### Opening an issue

```bash
./scripts/collect-diagnostics.sh
```

That writes one file with the model, distribution, kernel, PCI device, DKMS
state, module parameters, firmware, Secure Boot state and kernel messages. It
removes the DMI serial number and UUID; please skim it before posting. Attach it
to a [GitHub issue](https://github.com/ravvle/facetimehd/issues) — the templates
ask for it.

**Reports from MacBook models other than the MacBookAir7,2 are the single most
useful contribution to this project**, whether the camera worked or not. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

The project is **GPL-2.0-only**, including the maintained scripts, tests,
documentation and driver source. The extracted Apple firmware remains
proprietary and is not redistributed by this project. See [LICENSE](LICENSE)
for attribution and licensing details.
