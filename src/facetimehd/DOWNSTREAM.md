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
  Streaming is stopped and the stale ISP mappings are invalidated before the
  hardware goes down.
- A stream that was running when the machine went to sleep is **resumed**
  rather than failed. See "Suspending mid-stream" below.
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

## Suspending mid-stream

Closing the lid on a video call and opening it again used to leave the
application looking at a dead camera until it was restarted: suspend errored
the vb2 queue, so `DQBUF` and `poll()` returned `-EIO` and only a `STREAMOFF`
plus a fresh `STREAMON` could recover. Most applications do not attempt that —
they report a camera failure instead — which made "the camera stops working
after suspend" the visible behaviour.

Nothing about the hardware requires it. Suspend has to give up the ISP-side
resources, because the power cycle destroys them: the firmware image, the
channel, the S2 IOMMU mapping of every buffer and the descriptor objects that
point at them all go away. But the vb2 buffers themselves are ordinary memory
and survive untouched, and the descriptors are cheap to rebuild — which is
exactly what a `QBUF` does on every frame anyway.

So the driver now parks the stream instead of failing it:

- `fthd_v4l2_suspend_stop()` stops the channel and frees the ISP-side objects
  as before, but records the buffers vb2 has handed to the driver and leaves
  them owned by it. The queue is not errored and no buffer is returned, so
  userspace — frozen for the whole transition — has nothing to observe.
- `fthd_v4l2_resume_start()` runs from the system resume callback, after the
  firmware is back and before userspace is thawed. It re-prepares each parked
  buffer through the same `buf_prepare()` path a `QBUF` uses, restarts the
  channel, replays the control values and resubmits the buffers. Capture
  continues into the same buffers the application was already reading.
- Frame sequence numbers continue across the sleep rather than restarting at
  zero. `STREAMON` still resets them; the resume path deliberately does not,
  because the application never asked for a new stream.
- If any part of that fails, the old behaviour is the fallback: the parked
  buffers come back with an error, the queue is marked, and the application can
  recover with `STREAMOFF`/`STREAMON`. The failure is logged as
  `could not resume capture`.
- The shutdown and kexec path deliberately keeps the old behaviour, because
  there is no resume coming: a reader blocked in `DQBUF` is better told with
  `-EIO` than left waiting for frames that will never arrive.

The work happens in the `.resume` callback rather than a work item, because
that is the one place where userspace is guaranteed to be frozen: no `STREAMOFF`,
`close()` or `REQBUFS` can race the rebuild, and the parked buffer pointers
cannot go stale. The cost is that the channel-start command sequence sits in
the device-resume phase — a dozen firmware commands, each bounded by the usual
2 s command timeout — and it is paid only when something actually held the
camera streaming. No firmware is loaded there that a resume with an open camera
was not already loading.

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

## Frame-rate selection

`S_PARM` used to accept any rate and deliver 30 fps regardless, reporting 30
back so the two at least agreed. An application asking for 15 fps - which is
what video-conferencing software and most encoders do when they want to spend
less bandwidth - got 30 with no way to tell.

The sensor has one mode and one rate, so the rate is now produced by delivering
one frame in N and handing the rest straight back to the ISP:

- `V4L2_CID`-free and firmware-free by design. The obvious alternative was the
  ISP's own AE frame-rate window, `CISP_CMD_CH_AE_FRAME_RATE_{MIN,MAX}_SET`,
  which `fthd_start_channel()` already programs. It was rejected: it is the
  exposure loop's rate window rather than a sensor mode, its units are
  undocumented, and the sensor demonstrably keeps delivering 30 fps with it
  programmed to the value used there. Reporting a rate the hardware does not
  deliver is exactly the bug that made GStreamer's `pipewiresrc` compute
  negative frame durations and stall after one frame. Decimation cannot desync
  that way, because the divisor is applied to frames the driver already has.
- `G_PARM` reports `divisor/30` rather than a rounded integer, so 7.5 fps stays
  exact. `ENUM_FRAMEINTERVALS` reports the matching stepwise range - `1/30` to
  `30/30` in steps of `1/30` - which is precisely the set `S_PARM` can honour.
  A discrete list would either omit rates `S_PARM` accepts or advertise ones it
  cannot hit.
- A decimated buffer is never made visible to userspace: it stays owned by the
  driver and is resubmitted from a work item. It cannot be resubmitted inline,
  because `fthd_buffer_return_handler()` runs inside `fthd_irq_work()` and
  `fthd_send_h2t_buffer()` waits on the very channel whose completions that same
  work item processes.
- `fthd_stop_streaming()` and the suspend path `cancel_work_sync()` that worker
  after clearing `channel_running` and before reclaiming buffers. Without that
  ordering a worker already past its state check could hand a buffer back to the
  ISP just as vb2 reclaimed it.

The cost is honest and bounded: the ISP still runs at full rate, so this saves
work in the application and on the bus, not power in the camera.

## Cropping and digital zoom

`S_SELECTION` is implemented for `V4L2_SEL_TGT_CROP`, making the ISP's crop
rectangle settable rather than pinned to the full sensor array. On a fixed-focus
720p webcam that is digital zoom and pan, and the hardware was already doing the
crop-and-scale - only the rectangle was constant.

- The crop is never allowed smaller than the negotiated output size, so the
  scaler is only ever asked to shrink. Upscaling is a separate capability and
  nothing here can confirm the ISP has it.
- `S_FMT` grows the crop if the new output would not fit, which is the
  adjustment V4L2 permits and avoids making the result depend on whether the
  format or the selection was set first.
- `S_SELECTION` is refused with `-EBUSY` while buffers exist, because the
  rectangle only reaches the firmware in the channel-start sequence; accepting
  one mid-stream would silently do nothing until the next `STREAMON`.
- `V4L2_SEL_FLAG_GE`/`_LE` are refused with `-ERANGE`. The driver rounds in both
  directions and cannot keep either promise, and returning a rectangle that
  breaks the requested constraint is worse than refusing it.
- `fthd_v4l2_refresh_crop()` re-fits the stored rectangle at channel start,
  which is where the sensor's real geometry is first learned. This is what keeps
  a crop from surviving into a state the ISP would reject on the 12-inch
  MacBook, whose 848x588 array is smaller than the fallback bounds.

## V4L2 API improvements

- `S_PARM`, `G_PARM` and frame-interval enumeration consistently report the
  frame rate the driver actually delivers.
- Frame-size enumeration reports the same stepwise range accepted by
  `TRY_FMT`/`S_FMT`, and frame-interval enumeration validates both format and
  minimum/maximum dimensions.
- `G_SELECTION` reports the active crop for `V4L2_SEL_TGT_CROP` and the detected
  full sensor rectangle for the default and bounds targets.
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

## Image-quality controls

Three more of the ISP's processing blocks are exposed. All follow the same rule
as the block above: the opcodes are real, the payload layouts are inferred from
the shape every other per-channel setter uses, and a wrong guess is refused by
the firmware rather than being destructive.

- `V4L2_CID_BACKLIGHT_COMPENSATION` drives `CISP_CMD_CH_DRC_SET`. Dynamic range
  compression is already started unconditionally by `fthd_start_channel()`; this
  is the separate opcode that says how hard it pulls the shadows up, which is
  what backlight compensation means on a camera with no backlight-specific
  hardware of its own.
- Noise reduction (`CISP_CMD_CH_NOISE_REDUCTION_SET`) and chroma suppression
  (`CISP_CMD_CH_CHROMA_SUPPRESSION_SET`) are exposed as **driver-private**
  controls at `V4L2_CID_USER_BASE | 0x1001` and `| 0x1002`. V4L2 has no standard
  CID for either. `V4L2_CID_IMAGE_STABILIZATION` was the tempting place to put
  denoising and would have been wrong: an application asking for stabilisation
  would silently have got something else. A private control with an honest name
  is better than a standard one with an invented meaning.

## Sensor temperature

`CISP_CMD_CH_SENSOR_TEMPERATURE_GET` is read and exposed two ways, because its
*scale* is undocumented - celsius, deci-celsius and a raw sensor code are all
plausible readings of the same number.

- `hwmon` publishes `temp1_input`, which is millidegrees celsius by definition.
  A number in the wrong scale there is not a caveat, it is a wrong reading in
  every monitoring tool on the system. So the driver publishes a value only when
  the firmware returns something that can only sensibly be celsius (-40..125)
  and returns `-EIO` otherwise, with a rate-limited warning carrying the raw
  value.
- `debugfs/facetimehd/<dev>/sensor_temperature_raw` always reports the number
  exactly as the firmware gave it. That is the file to read when working out
  what the scale really is.
- Reading either powers a runtime-suspended camera up, the same documented
  trade-off the other debugfs accessors make. That is also why this is not a
  volatile V4L2 control: `G_CTRL` is not expected to spin up hardware.

`CISP_CMD_CH_AWB_1ST_GAIN_MANUAL` is deliberately **not** exposed as
`V4L2_CID_RED_BALANCE`/`BLUE_BALANCE`. The colour temperature and the
per-channel gains are two ways of writing the same white-balance state, so
putting both in one cluster would make the replay order decide which wins —
and runtime PM replays the whole handler on every idle cycle. One unambiguous
control is better than two that quietly fight.

`fthd_isp_cmd_channel_awb_gain_manual()` is nevertheless kept, unused and
commented as such. The choice between the two is a choice between two writable
representations of one piece of state, not between a working and a broken one -
so anyone reconsidering it (say, because hardware shows the CCT command is the
one the firmware ignores) needs this side implemented to compare against.

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
- `tests/script-smoke.sh` covers the installer plumbing that shellcheck cannot
  see, including that every source file in this directory is listed in the
  Makefile - the failure that otherwise compiles in no CI job and only shows up
  on a user's machine.

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
  `-EIO` and capture working again after restart — the behaviour of the time,
  since replaced by the resumed stream described under "Suspending mid-stream";
- the widened DDR probe check, with total module load around 640 ms; and
- firmware acceptance of all anti-banding and exposure-auto values.

This validates one machine, model and kernel rather than the complete
2013–2015 Mac range. Still untested or unproven are:

- the visible effect of anti-banding and exposure mode under controlled light;
- the resumed stream: that an application capturing when the lid closes is
  still receiving frames after it opens, without restarting and without an
  error, and that the firmware accepts the channel restart and the resubmitted
  buffers on the resume path. `tests/hw-validate.sh --only suspend` checks
  exactly this — its `suspend.viewer` result is the verdict;
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
  `sizeimage`;
- frame-rate selection: that a decimated stream really arrives at the requested
  rate with even spacing, that the requeue worker keeps up without starving the
  ISP of buffers at low divisors (only four exist), and that `STREAMOFF` during
  heavy decimation returns every buffer. This part needs no firmware guessing -
  it is driver logic - but it has not been run against hardware;
- the crop: that the ISP accepts a non-zero `x1`/`y1` at all, whether the
  rectangle needs an alignment stricter than the eight pixels assumed here, and
  whether the scaler will upscale (which would make the "crop is never smaller
  than the output" rule unnecessary rather than merely conservative);
- backlight compensation, noise reduction and chroma suppression: the same
  inferred-payload question as the controls above, plus whether their visible
  effect matches their names;
- the sensor temperature: what scale the firmware reports it in. Read
  `debugfs/facetimehd/<dev>/sensor_temperature_raw` on a warm camera and a cold
  one; if the values look like celsius the hwmon device is already correct, and
  if they do not the conversion in `fthd_hwmon_read()` needs writing. Also
  whether the command works at all with no channel running, which decides
  whether `sensors` is useful when the camera is idle.

Remove entries from this document when the corresponding fixes are accepted
upstream.
