# FaceTime HD Camera for Linux

Enable the built-in Apple FaceTime HD camera on 2013–2015 Intel MacBooks
running Ubuntu, Fedora, AlmaLinux or a compatible Linux distribution. The main
improvements over [patjak/facetimehd](https://github.com/patjak/facetimehd) are
**working suspend/resume**, **safer code**, **image resolution and scaling
fixes**, **automatic sensor calibration** and extra controls exposed to
applications. It uses current kernel interfaces and drops support for kernels
older than 5.15.

[![CI](https://github.com/ravvle/facetimehd/actions/workflows/ci.yml/badge.svg)](https://github.com/ravvle/facetimehd/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/ravvle/facetimehd)](LICENSE)
[![Distros](https://img.shields.io/badge/distros-Ubuntu%20%7C%20Fedora%20%7C%20AlmaLinux-orange)](#distribution-compatibility)
[![Kernel](https://img.shields.io/badge/kernel-5.15%2B-blue)](https://kernel.org)

## Origins and acknowledgements

This project is derived from the work of **Patrik Jakobsson (`patjak`) and the
facetimehd contributors**:

- [patjak/facetimehd](https://github.com/patjak/facetimehd) provides the
  original Linux driver for the Broadcom 1570 PCIe camera. The driver here is a
  fork of commit
  [`364b1c6`](https://github.com/patjak/facetimehd/commit/364b1c663583e64e27f07ed0257a7584bef095fc).
- [patjak/facetimehd-firmware](https://github.com/patjak/facetimehd-firmware)
  provided the firmware-extraction work maintained here as
  [`scripts/extract-firmware.sh`](scripts/extract-firmware.sh).
- [godwill1224/facetimehd-ubuntu-macbook](https://github.com/godwill1224/facetimehd-ubuntu-macbook)
  provided the base for the install scripts.
- [linux-on-mac/mbpfan](https://github.com/linux-on-mac/mbpfan) provides the
  optional fan daemon used by the setup helper.

The installer, driver fork, tests and documentation were developed with
assistance from **Claude Code** and **ChatGPT Codex**.

## What this project does

- builds the `facetimehd` driver from
  [`src/facetimehd/`](src/facetimehd/), which is included in this repository;
- registers it with DKMS so it is rebuilt after kernel updates;
- downloads an Apple update and extracts the proprietary camera firmware, which
  cannot be redistributed here;
- installs the matching sensor calibration files where `unar` is available; and
- optionally installs and enables `mbpfan` to improve thermals.

The fork's divergence from upstream is recorded in
[`src/facetimehd/DOWNSTREAM.md`](src/facetimehd/DOWNSTREAM.md).

## Improvements over the original patjak driver

The fork keeps the original hardware support and adds:

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
- restoration of a stream that was active across system suspend;
- wider DDR memory verification, and removal of unfinished calibration code
  containing ineffective timeouts and unbounded paths;
- correct full-sensor scaling at lower resolutions instead of a zoomed crop
  from the top-left corner;
- model-specific sensor-size detection, correct format limits and improved
  V4L2 frame-size, frame-rate, selection and status reporting;
- controls that are restored when streaming starts, plus 50/60 Hz anti-banding
  and automatic/manual exposure;
- selectable frame rates produced by safe frame decimation;
- digital zoom and pan through `VIDIOC_S_SELECTION`;
- NV12 output alongside the packed YUYV/YVYU formats, with the correct 4:2:0
  sizing and destination row stride;
- removal of guessed firmware controls and formats that made firmware read
  beyond short requests and repeatedly hard-locked a MacBookAir7,2;
- correct MacBook Air sensor-calibration selection and complete
  `MODULE_FIRMWARE` declarations; and
- current Linux 5.15+ APIs, quieter diagnostics, Clang builds, Sparse checks
  and on-hardware validation scripts.

Core probing, capture, runtime suspend/resume and system suspend recovery are
tested on a MacBookAir7,2. The complete change list and current
hardware-validation limits are in
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

The setup asks whether to install the camera driver and whether to add fan
support; both prompts default to yes, as does the proprietary firmware
download. For the camera, it checks the hardware, installs build dependencies
and matching kernel headers, builds the driver through DKMS, extracts the Apple
firmware and loads the module. It is safe to run again; an unchanged installed
driver is not rebuilt.

The full installer enables the driver's runtime power management by default.
The module's own default remains off, so a manual or package-only install does
not get it. `--runtime-pm off` is the recovery opt-out. Either way the
installer refreshes the early-boot image afterwards, because this PCI driver
can load from the initramfs before the real root filesystem and its
`/etc/modprobe.d` are mounted.

For recovery or controlled testing, `--no-load` installs the DKMS build without
touching the running module; combine it with `--runtime-pm off` when isolating
a power-transition failure, then reboot deliberately.

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

Sensor calibration files come from a separate Apple Boot Camp package and need
`unar` to unpack. They are not required for capture, but missing calibration
produces incorrect colours, so `install.sh` fetches them on every run where
`unar` is present. Two things can leave a machine without them:

- **`unar` is missing**, which on Enterprise Linux means EPEL has not rebuilt
  it for that release. The installer warns and continues.
- **Your sensor is not one of the four the download carries.** The driver
  recognises nine; a machine needing one of the other five logs
  `no sensor calibration file ...` in `dmesg`, and `install.sh --status`
  reports the same.

Once the cause is fixed, retry the calibration step on its own:

```bash
sudo ./scripts/extract-firmware.sh --calibration-only
```

These Apple downloads are the only installation steps needing network access
beyond distribution packages; the driver source is already in the repository.

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

Beyond the usual brightness, contrast, saturation and hue, the driver exposes:

```bash
v4l2-ctl --list-ctrls
v4l2-ctl --set-ctrl auto_exposure=1          # manual exposure mode
v4l2-ctl --set-ctrl power_line_frequency=1   # 50 Hz anti-banding
v4l2-ctl --get-ctrl awb_cct_estimate         # read-only, while streaming
```

`awb_cct_estimate` is the ISP's own current colour-temperature estimate in
kelvin, read live from the firmware. It is read-only, so nothing about it is
ever sent back to the camera; while the camera is idle it reports the last
value sampled during a stream, or `0` if there has not been one yet. It is a
driver-private control rather than the standard
`V4L2_CID_WHITE_BALANCE_TEMPERATURE` because that one means the temperature an
application asks the camera to *assume*, and this camera has no validated way
to be told one.

Controls for inferred firmware commands — manual exposure, manual white
balance, sharpness, test pattern, noise reduction, chroma suppression and
backlight compensation — are intentionally absent. Registering them made an
ordinary `STREAMON` replay every unvalidated command, which repeatedly
hard-locked the validation MacBook, and firmware disassembly then proved
several payload layouts incomplete or misplaced. See the
[firmware reverse-engineering notes](src/facetimehd/FIRMWARE-REVERSE-ENGINEERING.md)
and [`DOWNSTREAM.md`](src/facetimehd/DOWNSTREAM.md).

### Pixel formats

`YUYV` and `YVYU` are offered, both 4:2:2 packed at the sensor's native size or
any smaller 8-pixel-aligned width.

`NV12` (semi-planar 4:2:0) is also offered. It is enumerated after the packed
formats, so applications that take the first format available are unaffected.

`NV16` is not offered: the camera's semi-planar output was measured writing
4:2:0, so nothing it produces is 4:2:2 semi-planar.

### Raw firmware readbacks

For reverse-engineering and hardware validation, confirmed firmware GET
commands are available as root-only debugfs files. They work only while the
camera is already streaming; reading one sends exactly one whitelisted GET and
never changes or replays a setting. Keep a stream open in one terminal:

```bash
v4l2-ctl --device /dev/video0 --stream-mmap --stream-count=100000 \
         --stream-to=/dev/null
```

Then read a value in another (replace the PCI directory if needed):

```bash
sudo ls /sys/kernel/debug/facetimehd/0000:02:00.0/
sudo cat /sys/kernel/debug/facetimehd/0000:02:00.0/awb_cct_raw
sudo cat /sys/kernel/debug/facetimehd/0000:02:00.0/crop_raw
```

The numbers are labelled `raw` because firmware documents no units or ranges.
An idle read fails with `EPIPE`; there is no polling or hwmon registration. The
complete check is `sudo ./tests/hw-validate.sh --only readbacks`.

Two readbacks have known meanings. `sensor_temperature_raw` prints
`-1 (unavailable)` on the validation MacBook — repeated sampling never returned
anything else, so it is a not-supported sentinel rather than a reading on an
unknown scale, and it will never become an hwmon channel on such a sensor. The
AWB colour temperature does track lighting, so it is also available to ordinary
applications as the `awb_cct_estimate` control above.

Three opt-in experiments build on those reads:

```bash
# Interactive dark/bright, warm/cool, 15/30-fps and warm-up profile (GETs only)
sudo ./tests/hw-validate.sh --only readback-profile

# One same-value setter only; repeat with another ROUNDTRIPS name afterward
sudo env ROUNDTRIPS=ae_bias ./tests/hw-validate.sh --only roundtrips

# Interactive, bounded firmware metering-mode semantics test
sudo ./tests/hw-validate.sh --only metering-modes
```

The setter nodes are root-write-only and accept only the literal word `same`.
The kernel reads the current value, writes that exact value once, reads it
back, and fails if it changed. Nothing is registered with V4L2 or replayed at
stream start. Valid `ROUNDTRIPS` names are `ae_bias`, `ae_metering_mode`,
`ae_integration_time_max`, `ae_gain_cap` and `ae_gain_cap_min`.

The `metering-modes` section is the one experiment that writes a value the
firmware was not already using, and it is limited to the four modes firmware
disassembly proved valid. Its test node accepts only the tokens `mode0` through
`mode3`. The runner uses a fresh stream per token, reads the mode back, retains
raw frames, reports full/spot/centre/outer luma, and restores the original mode
before `STREAMOFF`, then checks restart, runtime resume and kernel faults. It
requires a fixed high-contrast scene: the mode-3 baseline must show the central
target at least 20 luma above the surround without clipping, or the runner
stops before the other modes. This is test scaffolding, not a V4L2 control.

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
  the supported distribution matrix, plus a weekly watchdog on Apple's
  downloads.

Driver fixes belong in `src/facetimehd/`, should be recorded in
`DOWNSTREAM.md`, and should also be proposed upstream where possible.

## Repository layout

```text
setup.sh                       Guided camera/fan setup
scripts/install.sh             Driver, DKMS, firmware and calibration installer
                               (also --status, --enroll-mok, --runtime-pm,
                               --no-load)
scripts/uninstall.sh           Complete removal
scripts/macbook-tune.sh        Optional mbpfan helper
scripts/extract-firmware.sh    Maintained Apple firmware extractor
scripts/collect-diagnostics.sh One-file bug report
packaging/                     .deb and .rpm builders
src/facetimehd/                Maintained driver built by the installer
driver-patches/                The same change set as a patch series against
                               upstream, regenerated by hand
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
| Camera unreliable when idle | Driver runtime PM explicitly enabled | `sudo ./scripts/install.sh --runtime-pm off` |
| Live reload freezes the machine | Kernel-driver regression | Reinstall with `--no-load --runtime-pm off`, then reboot deliberately |
| Install fails at the Apple download | Apple's URL moved | `./scripts/extract-firmware.sh --check-sources` and open an issue |
| Cropped picture is not where you asked for it | Crop origin clamped to the array centre | Expected; read the rectangle back with `G_SELECTION` (see below) |

### The crop origin is limited to the array centre

If you set a crop rectangle, the driver may move its origin left or up. That is
deliberate. On this firmware a crop whose origin sits past the middle of the
sensor is accepted and then produces no frames at all, and the camera stays
unusable — for every application, not just yours — until the driver reloads. So
the origin is clamped to:

```text
left <= (sensor_width  - crop_width)  / 2
top  <= (sensor_height - crop_height) / 2
```

Equivalently, the crop's centre may not pass the sensor's centre. Landing
exactly on the limit is fine — a centred rectangle is the furthest right and
furthest down you can go, and a smaller crop can start further along than a
larger one. `left` is also rounded to a multiple of eight pixels.

`VIDIOC_G_SELECTION` always reports the rectangle that was actually programmed,
so read it back if the framing matters. Most applications never set a crop and
are unaffected.

### Opening an issue

```bash
./scripts/collect-diagnostics.sh
```

That writes one file with the model, distribution, kernel, PCI device, DKMS
state, module parameters, firmware, Secure Boot state and kernel messages. It
removes the DMI serial number and UUID; please skim it before posting. Attach
it to a [GitHub issue](https://github.com/ravvle/facetimehd/issues) — the
templates ask for it.

**Reports from MacBook models other than the MacBookAir7,2 are the single most
useful contribution to this project**, whether the camera worked or not. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

The project is **GPL-2.0-only**, including the maintained scripts, tests,
documentation and driver source. The extracted Apple firmware remains
proprietary and is not redistributed by this project. See [LICENSE](LICENSE)
for attribution and licensing details.
