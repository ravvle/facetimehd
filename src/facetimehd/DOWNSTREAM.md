# Downstream changes to the FaceTime HD driver

This directory is the driver built and installed by this project. It is a
 fork of `patjak/facetimehd` commit
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

## Manual exposure and white balance

`V4L2_CID_EXPOSURE_AUTO` and `V4L2_CID_AUTO_WHITE_BALANCE` each used to
advertise only half a feature: both could be switched to manual, and neither
had anything to set once they were. Selecting manual exposure simply froze the
picture wherever the automatic loop had last left it.

- `V4L2_CID_EXPOSURE_ABSOLUTE` and `V4L2_CID_GAIN` now sit in a
  `v4l2_ctrl_auto_cluster()` led by `V4L2_CID_EXPOSURE_AUTO`, so they are
  marked inactive while the ISP owns the exposure and become settable when it
  does not. The ISP has no "set the gain" command, only a gain-cap pair;
  collapsing its minimum and maximum onto one value is what pins a fixed gain.
- `V4L2_CID_WHITE_BALANCE_TEMPERATURE` is clustered against
  `V4L2_CID_AUTO_WHITE_BALANCE` the same way.
- `V4L2_CID_AUTO_EXPOSURE_BIAS` offers ±2 EV in thirds. Unlike the cluster
  above it applies with automatic exposure still running, which makes it the
  control that actually helps a backlit subject.
- `V4L2_CID_EXPOSURE_METERING` replaces the metering mode `fthd_start_channel()`
  used to pin to 3 on every channel start. The control's default is that same
  mode, so out-of-the-box behaviour is unchanged; the hardcoded call was removed
  for the reason the brightness and contrast ones were, namely that
  `v4l2_ctrl_handler_setup()` replays the handler immediately afterwards and
  would otherwise be overridden.
- `V4L2_CID_SHARPNESS` and a `V4L2_CID_TEST_PATTERN` menu are exposed.
  The test pattern is worth having as a diagnostic: it is the only way to
  separate "the sensor or firmware is not producing frames" from "the ring, the
  IOMMU mapping or buffer return is broken" without a lit room or a subject.

`CISP_CMD_CH_AWB_1ST_GAIN_MANUAL` is deliberately **not** exposed as
`V4L2_CID_RED_BALANCE`/`BLUE_BALANCE`. The colour temperature and the
per-channel gains are two ways of writing the same white-balance state, so
putting both in one cluster would make the replay order decide which wins —
and runtime PM replays the whole handler on every idle cycle. One unambiguous
control is better than two that quietly fight.

As with the anti-banding command, the opcodes above are real but Apple
documents none of their argument layouts, so each payload follows the shape
every other per-channel setter uses. A wrong guess is refused by the firmware
and surfaces as an error from `S_CTRL` rather than as a wedged ISP. All of
them are hardware-validation targets.

## Pixel formats

- `V4L2_PIX_FMT_NV16` is offered again, as a **single-planar** format. It was
  disabled upstream pending multiplanar support, but V4L2 defines NV16 as one
  buffer holding a luma plane followed by an interleaved CbCr plane of the same
  size, so no multiplanar queue is needed — only a second address for the ISP.
  `iommu_allocate_sgtable()` maps each buffer into one contiguous run of S2 IOVA
  pages, so that address is a byte offset from the start of the same mapping.
- The vb2 queue is therefore always single-planar. `struct fthd_fmt.planes`
  counts the addresses handed to the ISP, not vb2 planes; `queue_setup()` used
  to return it directly, which would have asked a `V4L2_BUF_TYPE_VIDEO_CAPTURE`
  queue for two planes.
- `V4L2_PIX_FMT_NV12` is **not** offered. The ISP's output-format codes are
  known only for the three formats the driver enumerates (NV16 is 0, YUYV 1,
  YVYU 2) and nothing identifies a 4:2:0 code. This is not a guess of the same
  kind as a command payload, where a wrong value is simply refused: sizing a
  buffer for 4:2:0 at 1.5 bytes per pixel while the ISP still writes 4:2:2 at 2
  would have the hardware DMA past the end of the mapping. It stays out until
  hardware can confirm a code.

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
- orderly reboot or kexec while actively streaming;
- recovery from a real firmware command timeout, which has not been reproduced;
- every command backing the manual exposure, white balance, exposure bias,
  metering, sharpness and test-pattern controls. The opcodes are real but their
  payload layouts are inferred, so each needs confirming that the firmware
  accepts it and that the picture changes as expected. The test pattern menu
  lists four entries; only "Disabled" is known to be implemented, and the
  indices that are not should be removed once hardware says which those are;
- NV16 capture: that the ISP accepts output format code 0 through the current
  `S_FMT` path, that the chroma plane really does land at
  `bytesperline * height` into the buffer, and that no frame is written past
  `sizeimage`.

Remove entries from this document when the corresponding fixes are accepted
upstream.
