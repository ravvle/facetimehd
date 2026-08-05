# Downstream changes to the FaceTime HD driver

This directory is the driver built and installed by this project. It is a
maintained fork of `patjak/facetimehd` commit
`364b1c663583e64e27f07ed0257a7584bef095fc`.

## Safety and correctness

- All register and memcpy helpers check BAR bounds before accessing hardware.
- Firmware-provided channel descriptors, ring addresses, command responses and
  buffer-return data are validated before use.
- ISP memory objects are identified by tracked indices instead of exposing
  kernel addresses to firmware.
- Scatterlists are walked correctly, including chained lists and unaligned
  first segments.
- VB2 buffers use opaque generation tags rather than kernel pointers. Buffer
  ownership is protected, invalid returns are rate-limited in `dmesg`, and all
  buffers are returned to VB2 on failure paths.
- IRQ retries and ring processing are bounded, fixing a clobbered retry counter
  and preventing unbounded work on malformed firmware data.
- PLL, DDR and memory-verification failures now propagate instead of being
  logged and ignored. The inverted PLL lock check is also fixed.
- Probe, remove, suspend and resume now use symmetric setup and teardown paths.
  Partial ISP initialization is unwound consistently.
- Firmware command timeouts no longer allow command memory to be reused while
  slow firmware might still access it. A timed-out ISP is marked wedged, later
  commands fail quickly with `-EIO`, and the next power cycle reloads it.
- Firmware failures such as stuck IRQs, malformed buffer returns or failed
  submissions are propagated to the VB2 queue instead of leaving applications
  waiting indefinitely.
- Device and debugfs file descriptors hold references to driver state. Unbind
  disconnects V4L2 and stops streaming before hardware resources are released,
  so already-open descriptors fail safely with `-ENODEV`.

## Power management and lifecycle

- The driver now provides runtime and system `dev_pm_ops`. An open video file
  holds a runtime-PM reference; after the final close the camera autosuspends,
  then reloads its firmware on the next open.
- `facetimehd.runtime_pm=0` remains available as an escape hatch for machines
  where runtime PM is unreliable.
- System suspend no longer fails with `-EBUSY` when the camera is streaming.
  Streaming is stopped, buffers and stale ISP mappings are invalidated, and
  blocked applications receive `-EIO`; they can recover with `STREAMOFF` and a
  new `STREAMON` after resume.
- Forced runtime suspend/resume preserves whether the camera was already idle,
  avoiding an unnecessary firmware reload during system resume.
- Debugfs entries survive suspend and take runtime-PM references when accessed.
  Their parsing, reference counting and multi-device handling are also fixed.
- Shutdown and kexec now quiesce DMA, IRQs and streaming without incorrectly
  running the full device-removal path while applications may still be open.
- PCI AER/DPC errors mark the device wedged and wake blocked V4L2 users with an
  error instead of leaving them hung.
- MSI setup uses `pci_alloc_irq_vectors()`/`pci_free_irq_vectors()` and no
  longer incorrectly requests a shared IRQ.

## Image geometry

- Lower resolutions now use the full sensor array as the crop and ask the ISP
  to scale it down. Upstream instead cropped the requested dimensions from the
  top-left, producing a zoomed and off-centre picture.
- Sensor dimensions are detected at channel start rather than hardcoded. This
  supports both 1280x720 sensors and the 848x588 sensor found in MacBook8,1.
- Width alignment correctly uses multiples of eight without exceeding sensor
  limits.
- Crop programming now sets `y1` correctly instead of assigning `y2` twice.
- `S_FMT` refuses to change firmware geometry while old-size buffers are still
  allocated or queued.

## V4L2 API improvements

- `S_PARM`, `G_PARM` and frame-interval enumeration consistently report the
  fixed frame rate the sensor actually delivers.
- Frame-size enumeration reports the same stepwise range accepted by
  `TRY_FMT`/`S_FMT`, and frame-interval enumeration validates both format and
  minimum/maximum dimensions.
- `G_SELECTION` reports the detected full sensor rectangle for the capture
  crop targets.
- V4L2 controls are replayed after the ISP channel starts, so values set before
  `STREAMON` and across runtime-PM cycles take effect. Hardcoded brightness and
  contrast resets were removed, saturation/hue/white balance are restored, and
  the white-balance fall-through and unknown-control handling are fixed.
- Unsupported `VIDIOC_CREATE_BUFS` is no longer advertised. The hardware has a
  fixed four-buffer pool, so pretending that the pool could grow returned
  misleading results.
- `VIDIOC_LOG_STATUS` now reports cached control values through the standard
  V4L2 helper.
- Fixed-size V4L2 names use bounded `strscpy()` calls.

## Calibration and additional controls

- Calibration selection uses the correct DMI product and vendor fields.
  MacBook Air systems now request their intended `1771_01XX.dat` file rather
  than incorrectly falling back to `1871_01XX.dat`.
- All eight possible sensor calibration files are listed with
  `MODULE_FIRMWARE`, allowing initramfs tools and `modinfo` to discover them.
  Missing calibration remains non-fatal but can result in incorrect colours.
- `V4L2_CID_POWER_LINE_FREQUENCY` exposes disabled, 50 Hz and 60 Hz anti-banding
  settings using the firmware flicker-frequency command.
- `V4L2_CID_EXPOSURE_AUTO` exposes the firmware's automatic/manual exposure
  start and stop commands.

The firmware accepts every value for both new controls and capture continues
after they are changed. Their visible effect has not yet been proven under
controlled lighting, so they should still be treated as hardware-validation
targets.

## Kernel integration, diagnostics and testing

- Compatibility branches older than the supported Linux 5.15 CI floor were
  removed.
- The code uses current runtime-PM, PCI BAR, MSI and V4L2 interfaces. Operation
  tables are `const`, firmware wire structures are `__packed`, and long waits
  sleep rather than busy-waiting.
- Repeated DDR, PLL, DMA and firmware-console progress messages were moved to
  debug logging because runtime resume can run them many times. Probe emits one
  concise camera-ready message, while warnings and failures remain prominent.
- CI performs warning-clean Clang builds and Sparse semantic checks through
  `tests/build-driver.sh`.
- `tests/smoke-capture.sh` checks the V4L2 surface on real hardware, while
  `tests/hw-validate.sh` covers probe, timing, controls, runtime PM, suspend,
  firmware-wedge evidence and the optional reboot path.

## DDR handling

- Roughly 500 lines of unfinished, unused DDR shmoo calibration code were
  removed. The deleted implementation contained incomplete stages, ineffective
  timeouts and potentially unbounded loops; the original is available in the
  upstream commit linked above.
- DDR continues to use the fixed hardware initialization sequence, memory
  verification and saved PHY registers used for runtime resume.
- Probe verification was widened from 128 words (512 bytes) to 65,536 words
  (256 KiB), providing meaningful address-line coverage without materially
  slowing startup. Runtime resume retains the smaller fast check.
- Memory verification now honours its base address, clamps the requested range
  to the mapped BAR and no longer describes a small sample as a “full” check.

## Hardware validation status

Four validation runs on 2026-08-05 used a MacBookAir7,2, firmware 1.43.0 and
Ubuntu kernel 7.0.0-29-generic. They confirmed:

- clean probe and DDR initialization;
- repeated runtime suspend, firmware reload and capture recovery;
- debugfs access waking a suspended camera;
- successful system suspend while streaming, with the application receiving
  `-EIO` and capture working again after restart;
- the widened DDR probe check, with total module load around 640 ms; and
- firmware acceptance of all anti-banding and exposure-auto values.

This validates one machine, model and kernel rather than the complete
2013–2015 Mac range. Still untested or unproven are:

- the visible effect of anti-banding and exposure mode under controlled light;
- orderly reboot or kexec while actively streaming; and
- recovery from a real firmware command timeout, which has not been reproduced.

Remove entries from this document when the corresponding fixes are accepted
upstream.
