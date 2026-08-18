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

- The driver provides runtime and system `dev_pm_ops`. Runtime PM is opt-in
  with `facetimehd.runtime_pm=1`: when enabled, an open video file holds a
  reference, after the final close the camera autosuspends, and the next open
  reloads its firmware. The default leaves the PCI device powered.
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
- All nine possible sensor calibration files are listed with
  `MODULE_FIRMWARE`, allowing initramfs tools and `modinfo` to discover them.
  Missing calibration remains non-fatal but can result in incorrect colours.
  `extract-firmware.sh` currently produces only four of the nine - the ones
  reachable inside Boot Camp 5.1.5722's `AppleCamera.sys`, which is the only
  Boot Camp `.sys` a calibration layout has been recorded for - so a machine
  needing one of the other five gets no calibration until an offset table is
  added for a driver binary that carries it. `fthd_isp_cmd_set_loadfile()`
  logs the filename it wanted whenever the request comes back empty, so that
  gap is visible in `dmesg` rather than silent.
- `V4L2_CID_POWER_LINE_FREQUENCY` exposes disabled, 50 Hz and 60 Hz anti-banding
  settings using the firmware flicker-frequency command.
- `V4L2_CID_EXPOSURE_AUTO` exposes the firmware's automatic/manual exposure
  start and stop commands.

The firmware accepts every value for both new controls and capture continues
after they are changed. Their visible effect has not yet been proven under
controlled lighting, so they should still be treated as hardware-validation
targets.

## Removed inferred firmware controls

The manual-exposure, manual-white-balance and image-quality controls added by
the post-`20bdd61` feature series have been removed, including their module
parameter gate. Registering them made `v4l2_ctrl_handler_setup()` send every
default command at ordinary `STREAMON`, and the combined build repeatedly
hard-locked the MacBookAir7,2. Static firmware analysis then proved that
several payloads were malformed rather than merely untested. The complete
wire-layout evidence is in
[`FIRMWARE-REVERSE-ENGINEERING.md`](FIRMWARE-REVERSE-ENGINEERING.md).

The stable brightness, contrast, saturation, hue, automatic white balance,
anti-banding and automatic/manual exposure switches remain available and use
their hardware-tested command paths.

`V4L2_CID_EXPOSURE_AUTO` and `V4L2_CID_AUTO_WHITE_BALANCE` each used to
advertise only half a feature: both could be switched to manual, and neither
had anything to set once they were. Selecting manual exposure simply froze the
picture wherever the automatic loop had last left it.

- The attempted `V4L2_CID_EXPOSURE_ABSOLUTE` and `V4L2_CID_GAIN` sat in a
  `v4l2_ctrl_auto_cluster()` led by `V4L2_CID_EXPOSURE_AUTO`, so they are
  marked inactive while the ISP owns the exposure and become settable when it
  does not. The ISP has no "set the gain" command, only a gain-cap pair;
  collapsing its minimum and maximum onto one value is what pins a fixed gain.
- The attempted `V4L2_CID_WHITE_BALANCE_TEMPERATURE` was clustered against
  `V4L2_CID_AUTO_WHITE_BALANCE` the same way.
- The attempted `V4L2_CID_AUTO_EXPOSURE_BIAS` claimed ±2 EV in thirds without
  evidence for that unit. Firmware actually reads a 16-bit bias and a separate
  32-bit tag; the request omitted the tag and was four bytes short.
- The attempted `V4L2_CID_EXPOSURE_METERING` replaced the established mode 3.
  The fixed, hardware-tested command has been restored.
- `V4L2_CID_SHARPNESS` and a `V4L2_CID_TEST_PATTERN` menu were attempted.
  The test pattern is worth having as a diagnostic: it is the only way to
  separate "the sensor or firmware is not producing frames" from "the ring, the
  IOMMU mapping or buffer return is broken" without a lit room or a subject.

## Image-quality controls

Three more ISP processing blocks had been placed behind the same module gate.
They are no longer exposed. Firmware disassembly shows that sharpness, noise
reduction and DRC consume one byte, while chroma suppression consumes three
independent bytes and cannot honestly be represented by one generic strength.

- The attempted `V4L2_CID_BACKLIGHT_COMPENSATION` drove `CISP_CMD_CH_DRC_SET`. Dynamic range
  compression is already started unconditionally by `fthd_start_channel()`; this
  is the separate opcode that says how hard it pulls the shadows up, which is
  what backlight compensation means on a camera with no backlight-specific
  hardware of its own.
- Noise reduction (`CISP_CMD_CH_NOISE_REDUCTION_SET`) and chroma suppression
  (`CISP_CMD_CH_CHROMA_SUPPRESSION_SET`) were exposed as **driver-private**
  controls at `V4L2_CID_USER_BASE | 0x1001` and `| 0x1002`. V4L2 has no standard
  CID for either. `V4L2_CID_IMAGE_STABILIZATION` was the tempting place to put
  denoising and would have been wrong: an application asking for stabilisation
  would silently have got something else. A private control with an honest name
  is better than a standard one with an invented meaning.

## Colour-temperature readback

`FTHD_CID_AWB_CCT_ESTIMATE` (`V4L2_CID_USER_BASE | 0x1003`, printed by v4l-utils
as `awb_cct_estimate`) reports the ISP's own current colour-temperature estimate
from `CISP_CMD_CH_AWB_CCT_GET`. It is the first firmware value recovered during
the lockup investigation to reach the ordinary V4L2 surface, and both halves of
that sentence needed justifying.

**Why it is safe to register at all.** The rule the removed controls broke is
that `v4l2_ctrl_handler_setup()` replays every registered control's default at
each `STREAMON`, which is what sent malformed commands without anyone touching a
control. This one is `V4L2_CTRL_FLAG_READ_ONLY`, and `handler_setup()` skips
read-only controls outright — so registering it adds a GET an application may
ask for and no SET the framework can ever replay. That is a structural
guarantee, not a convention, and `tests/script-smoke.sh` asserts the flag.

**Why the unit is not a guess.** Under warm light this firmware reported `2652`
and under cool light `5777`, with the right ordering and realistic magnitudes;
the value tracked lighting and not exposure. Cross-model confirmation is still
open, which is part of why it is a private CID.

**Why not `V4L2_CID_WHITE_BALANCE_TEMPERATURE`.** That control means the
temperature the application asks the camera to assume: writable, and paired with
a manual AWB mode. This is a measurement the ISP produces, and the manual
AWB-CCT setter carries a second payload word whose meaning is still
unidentified, so there is nothing to write. Publishing a measurement under a CID
that means a set point would make an application that wrote it silently get
nothing — the same class of dishonesty as mapping denoising onto
`V4L2_CID_IMAGE_STABILIZATION`. `0x1001` and `0x1002` are deliberately skipped:
they belonged to the removed noise-reduction and chroma-suppression controls.

The control is volatile, so `g_volatile_ctrl` issues the GET on demand under a
runtime-PM reference. It does not take `ioctl_lock`: `vdev->lock` *is*
`ioctl_lock`, so `video_ioctl2()` already holds it, which is also what serialises
this against the debugfs readbacks. On an idle camera it reports the last value
sampled while streaming rather than failing or powering the ISP up — a
diagnostic read is not a reason to retrain DDR and re-upload firmware, and
returning an error there would fail `v4l2-compliance` for no gain.

## Readbacks recovered from the dispatcher sweep

Decoding all twelve of the firmware's dispatcher jump tables (see
`FIRMWARE-REVERSE-ENGINEERING.md`, "Complete dispatcher table sweep") settled
which commands this firmware actually implements, rather than which ones
upstream's enum has names for. Four implemented GETs are now exposed as
mode-`0400` debugfs files alongside the existing readbacks:
`ae_frame_rate_max_raw`, `ae_frame_rate_min_raw`, `awb_2nd_gain_raw` and
`crop_raw`.

They follow the rule that has governed everything since the lockups: **GET
first, and a recovered value reaches V4L2 only as a read-only control once its
meaning is established.** None of these has an established meaning yet, so none
is a V4L2 control — `tests/script-smoke.sh` asserts both the `0400` mode and
the absence of any V4L2 path. Each read takes `ioctl_lock`, requires a running
channel, holds a runtime-PM reference for exactly one command, and adds nothing
to `STREAMON` or resume.

**`crop_raw` returns the active crop and the sensor array.**
`CISP_CMD_CH_CROP_GET` is implemented, and its handler returns *eight* words —
two four-word rectangles — where `CISP_CMD_CH_CROP_SET` sends only one.
Hardware has now identified both: the first group tracks the crop in effect
exactly, and the second stayed at `0 0 1280 720` across every rectangle tested,
which is the full sensor array. Both are in the `(left, top, right, bottom)`
form the setter uses.

This was initially pitched here as the cheap route to root-causing the
far-corner rectangle that starves the stream, on the reading that the two
groups might be "requested" and "what the ISP latched". **That was wrong.** The
first group only echoes the geometry in effect and the second is a constant, so
neither can reveal a rectangle being silently adjusted, and the command says
nothing about why one rectangle starves. The firmware log at `dyndbg=+p`
remains the route to that. What the readback does give is confirmation from the
ISP's side that a crop took effect, and the array bounds without inferring
them. The struct still names them `rect1`/`rect2` by position rather than by
meaning, because "active crop" and "sensor array" are what one machine showed
and the names would be a claim about all of them. The opt-in `crop-geometry`
section is what separated them: it samples `crop_raw` from a live stream across
several rectangles, ending with the far corners, where a starving rectangle is
the most informative sample rather than a failure — the channel still starts,
so the GET still answers, and the bottom-right corner did exactly that while
delivering no frames.

**`ae_frame_rate_max_raw`/`ae_frame_rate_min_raw` come with a caveat that is
part of the interface.** Both handlers compare a channel-context field against
`0xffff` first and take a path that never writes the response word when it
matches. Since `fthd_isp_cmd()` leaves the caller's buffer alone in that case,
an unwritten field reads back as the zero the driver submitted. A zero here
therefore means "firmware wrote nothing", not "zero frames per second", and the
file says so on the line rather than leaving the next reader to assume a rate.
These read the AE frame-rate window whose setters `fthd_start_channel()`
already programs, and which "Frame-rate selection" above rejected as a rate
mechanism because the sensor kept delivering 30 fps with it set. Hardware has
now supplied the missing half of that observation: both read `7672`, which is
`29.97` fps in Q8.8 (`7672 / 256 = 29.96875`; NTSC `30000/1001` truncates to
`7672`), and minimum equal to maximum means the window is clamped to the
sensor's single rate. The behavioural conclusion was right, and there is now a
readable reason for it. It also corroborates the Q8.8 encoding on a quantity
whose true value was measured independently, which the gain values alone could
only suggest. No setter is added here.

**`awb_2nd_gain_raw` returns three words, not two.** The handler loads three
destination pointers and fills them through a channel-context vtable entry. An
R/B reading would have predicted two, so the values are printed positionally
and no colour is named. Hardware then closed it as a control candidate: all
three read exactly `4096` while the CCT estimate reported `2785`, markedly warm
light in which a live gain triple cannot be equal on all three channels. It is
a manual stage sitting at unity, which the sweep independently supports -
`0x30c` 2nd-gain manual is implemented while `0x30b` its adaptive thresholds is
not. Unlike `awb_cct_estimate` there is no evidence it measures anything, so it
stays a debugfs readback and gets no CID.

Note what the same sweep ruled *out*, because it closes off work that looked
available: AE and AWB metering-*window* configuration (`0x21d`/`0x21e`,
`0x302`/`0x303`) is not implemented on this firmware at all, so the metering
harness's spatial-weighting question cannot be answered by programming a
window. And `0xa08` scaler-sharpness GET is unimplemented too, which means every
image-processing setter this firmware has — sharpness, noise reduction, chroma
suppression, DRC, scaler sharpness — is write-only, with no way to read a
default back and therefore no way to restore one except by reloading firmware.
Any future harness for those has to be built around that.

## Sensor temperature

Firmware disassembly confirms that `CISP_CMD_CH_SENSOR_TEMPERATURE_GET` returns
a signed 16-bit sensor value, sign-extended into the response word after the
channel. It is exposed only through the root-readable `sensor_temperature_raw`
debugfs file, and only while a stream is already active. Each read sends one
GET; nothing polls it.

**This is now closed rather than open.** Every sampled condition on the
MacBookAir7,2 returned `-1`: cold after boot, after ten minutes of continuous
streaming, and under bright, dark, warm and cool light. A physical scale, however
unknown, would have moved with the die temperature over a ten-minute stream. A
constant `-1` is a not-supported sentinel, so there is nothing to calibrate and
nothing to publish. `FTHD_SENSOR_TEMPERATURE_NONE` names the value and the
debugfs file prints `-1 (unavailable)` — the raw number stays first on the line
so anything parsing the file keeps working, with the interpretation appended
rather than substituted. hwmon registration would still be wrong even on a
sensor that returns something else, because that ABI requires millidegrees
Celsius and no reading here establishes a unit.

The same active-stream, mode-`0400` boundary exposes confirmed readbacks for
AWB CCT, AE bias/tag, gain-cap states, AE integration limits, and Apple AE
metering mode. Reads hold `ioctl_lock` across one firmware transaction so a
concurrent STREAMOFF cannot tear down the channel underneath it. Nominal GET
slots for sharpness, noise reduction, chroma suppression, and DRC are not
exposed: this firmware's dispatcher routes those opcodes to its unsupported
command path even though their names exist in the recovered enum.

The first complete readback run on 2026-08-18 returned temperature `-1`, AWB
CCT `4697`, AE bias/tag `256/0`, gain cap/minimum `8192/256`, integration
maximum `33`, sensor integration bounds `38..1000000`, and metering mode `3`.
All GETs completed during one stream and the subsequent teardown logged no
firmware, channel, IOMMU, or DMAR fault. Temperature `-1` may be an unavailable
sentinel; the other apparent fixed-point/unit interpretations remain hypotheses.

A follow-up controlled profile sampled bright, dark, warm, and cool scenes,
requested 30 and 15 fps, and a ten-minute continuous stream. AWB CCT changed
from `2652` under warm/yellow light to `5777` under cool/blue-white light,
strongly supporting a current kelvin CCT interpretation on this machine. Bias
and tag stayed `256/0`, gain cap/minimum stayed `8192/256`, and AE integration
maximum stayed `33` under every sampled lighting condition; these are
configuration limits, not current-exposure telemetry. Keeping `33` at requested
15 fps is also consistent with host-side decimation leaving the 30 fps sensor
and AE configuration unchanged. Sensor integration limits stayed
`38..1000000`. Temperature remained `-1` after ten minutes, strengthening the
unavailable-sentinel interpretation. The 29.97/14.98-fps streams and teardown
were fault-free. The durable report is
`/tmp/facetimehd-hw-validate-20260818-144108.log` on the test machine.

For the next validation stage, five mode-`0200` debugfs files accept only
`same`. Each holds `ioctl_lock`, requires a running channel, GETs the current
value, SETs that exact value once, GETs again, and returns an error on mismatch.
They cover AE bias with its returned tag, metering mode, AE integration maximum,
gain cap, and minimum gain cap. They are test scaffolding only: no arbitrary
value is accepted, nothing calls them automatically, and no V4L2 control is
registered. `tests/hw-validate.sh --only roundtrips` adds persistent pre-write
markers, a fresh stream per setter, restart capture, runtime cycling, and fault
checks. All five paths subsequently passed individually on the MacBookAir7,2:
their GET/SET/GET values matched, the live stream survived, capture restarted,
runtime resume captured, and no firmware, channel-stop, IOMMU, or DMAR fault
appeared. The reports are timestamped `145904`, `145932`, `145959`, `150018`,
and `150103` under `/tmp/facetimehd-hw-validate-20260818-*.log`. This validates
the payloads with their current values only; units, ranges, non-current values,
and multi-command sequencing remain unvalidated, so no V4L2 exposure or replay
is justified yet.

The next opt-in stage is deliberately limited to AE metering modes `0..3`, the
closed domain recovered from this firmware. A mode-`0200` test node accepts only
four fixed `modeN` tokens, SETs one under the stream/lock/runtime-PM boundary,
GETs it back, and rejects a mismatch. `hw-validate.sh --only metering-modes`
uses a fresh stream and an armed marker for each mode, discards settling frames,
records spatial luma and raw frames from a fixed high-contrast scene, restores
and verifies the original mode before STREAMOFF, then validates restart,
runtime resume, and fault logs. This remains semantics-test scaffolding: the
standard V4L2 metering menu is not registered until hardware results justify a
mapping.

The first bounded run accepted and read back all four non-current/current
values, restored mode `3` after each, passed restart and runtime-PM capture, and
logged no firmware or DMA fault. Its centre-quarter luma was nevertheless below
the outer-region luma in every capture (`37..39` versus `55..59`), so the scene
did not provide the requested bright central target; modes `0` and `1` also
differed by less than one luma. The run validates bounded setter safety but not
the menu semantics. The runner now measures a smaller central spot and requires
it to be at least 20 luma above the outer region and below clipping in the
mode-3 baseline, stopping before modes `0..2` if that precondition is not met.

The controlled rerun (`/tmp/facetimehd-hw-validate-20260818-152753.log`) met
that precondition: mode `3` measured spot/outer `99.8/40.0`. All four modes
again read back exactly, restored to `3`, survived restart and runtime PM, and
remained fault-free. They were nevertheless visually indistinguishable: across
modes the full-frame mean varied by at most `1.2`, the central spot by `0.7`,
the centre quarter by `0.6`, and the outer region by `1.5` luma. That is not
enough evidence to map the firmware values onto the standard V4L2 menu.

Because the normal channel sequence programs metering before AE starts but the
first semantics test mutates it while AE is already running, an optional second
test path now stops AE, sets one of the same four compile-time modes, restarts
AE, and verifies the GET. `METERING_RESTART_AE=1 ./tests/hw-validate.sh --only
metering-modes` selects it. The root-only endpoint uses the same stream, lock,
runtime-PM and restoration boundaries, and it does not register or replay a
production control.

The same analysis proved the unused AWB first-gain helper wrong: firmware reads
four packed halfwords at offsets that the attempted red/blue `u32` structure
did not provide. The helper was removed; its recovered layout is recorded in
the reverse-engineering notes.

## Pixel formats

YUYV, YVYU and **NV12** are advertised. The ISP's semi-planar output, format
code 0, is NV12 - 4:2:0, not the 4:2:2 this driver assumed for a decade. NV12 is
enumerated last, so an application that takes the first format offered still
gets what it always got.

That it is NV12 rather than NV16 is a hardware result, and it corrects an
assumption this fork inherited. Upstream's 2015 comment called code 0 "plane 0 Y
plane 1 UV" without giving it a sampling; every later reading, including this
document's, filled in 4:2:2 and called it NV16. A capture on the MacBookAir7,2
settled it: the ISP wrote a `width * height` luma plane followed by exactly
`width * height / 2` of chroma - 360 chroma rows for a 720-row frame - and left
the remaining 460,800 bytes of the NV16-sized buffer at zero. Splitting that
chroma into its components gave Cb 122.3 and Cr 135.3, against 122.5 and 135.4
from a YUYV capture of the same scene seconds later.

The layout is therefore:

```text
bytesperline = width
sizeimage    = width * height * 3 / 2
ISP addr0    = mapped buffer base
ISP addr1    = mapped buffer base + width * height
```

`iommu_allocate_sgtable()` gives each buffer one contiguous run of S2 IOVA
pages, so the chroma plane is a byte offset into the same mapping and needs no
second one; the vb2 queue stays single-planar, with the semi-planar case derived
from the pixel format at each use rather than cached in a plane count - a cached
count is what once asked a `V4L2_BUF_TYPE_VIDEO_CAPTURE` queue for two planes.

**The old warning against NV12 had the risk backwards** and is withdrawn. It
said nothing identified a 4:2:0 code, and that sizing a buffer at 1.5 bytes per
pixel while the ISP wrote 4:2:2 at 2 would make the hardware DMA past the
mapping. The code is identified - it is 0 - and the error ran the other way:
sizing for 4:2:2 over-allocated and left a tail unwritten, which can never
overrun. NV16 is now the format with no evidence behind it, and is not offered.

It was gated behind a module parameter until the driver had streamed with
`sizeimage` cut to the 4:2:0 size, since the measurements above came from an
over-sized buffer. That run passed - `sizeimage` 1,382,400, no blank luma rows,
chroma 127.2 against a YUYV reference midpoint of 126.8, and no firmware, buffer
or DMA fault - so the parameter is gone and `nv12` is part of the default test
suite rather than an opt-in experiment.

**Two silent-failure lessons are built into the test.** The first NV16 "pass"
was really YUYV: the format was absent from `ENUM_FMT`, `S_FMT` silently coerced
the fourcc, and both formats had the same byte count, so a size-and-capture
check could not tell them apart. The `nv12` section therefore re-reads `G_FMT`
and requires the fourcc to survive. The second was the row stride below: the
section counts blank luma rows, and compares chroma against a YUYV capture of
the same scene rather than an absolute threshold, which is what turned "the
chroma looks wrong" into "the chroma is 4:2:0".

### The output-config stride

`CISP_CMD_CH_OUTPUT_CONFIG_SET`'s `x2` is the destination row stride in bytes.
Upstream hardcoded `width * 2`, which for the packed formats is simultaneously a
correct stride and an unremarkable constant, so nothing distinguished the two
readings until a one-byte-per-pixel plane arrived.

With `width * 2` still being sent for the semi-planar luma plane, the ISP wrote
luma rows 2560 bytes apart into a buffer laid out for 1280: exactly 50% of the
luma plane came back zero, in a strict every-other-row pattern. **No IOMMU fault
occurred** - `sizeimage` still covered everything written - so the corruption was
silent, and only inspecting the planes separately found it. This document
previously predicted that a wrong stride would fault loudly and be caught that
way; it does not, because the ISP skips rows rather than overrunning.

`fthd_isp_cmd_channel_output_config_set()` now takes the stride and is passed
`bytesperline`. For YUYV and YVYU that is `width * 2`, so the command is
byte-for-byte what it always was.

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
  `tests/hw-validate.sh` covers probe, timing, controls, frame-rate decimation,
  cropping, runtime PM, suspend, firmware-wedge evidence and the optional reboot
  path, plus the opt-in readback-profile, round-trip, metering-semantics and
  NV12 experiments. Sections that only exercise driver logic run by default;
  anything that mutates firmware state or enables an unvalidated format is
  opt-in.
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

A corrected-build reboot on 2026-08-18 then confirmed that the driver loads
normally with all inferred firmware interfaces removed and runtime PM off. It
captured 30 frames, passed all 57 applicable `v4l2-compliance` tests, captured
after every retained control value, captured both packed formats, accepted and
captured a centered 640x480 crop, and delivered a requested 15 fps decimated
stream. No FaceTimeHD, IOMMU, timeout, oops, or firmware-fault record appeared.
See `FIRMWARE-REVERSE-ENGINEERING.md` for the exact values and incident record.

A following boot with runtime PM enabled completed five consecutive
runtime-suspended -> ten-frame capture -> runtime-suspended cycles. The PCI
runtime counters advanced normally and no driver, firmware, IOMMU, or kernel
fault appeared. Runtime PM is therefore validated on this corrected build and
MacBookAir7,2. The full installer now selects it by default, with
`--runtime-pm off` retained as the recovery path; the module's bare default
remains off for installs that bypass the project installer.

The first subsequent suspend-while-streaming test visibly resumed the original
viewer and a fresh capture, but its detailed log exposed a failed channel stop,
invalid/unknown buffer tags, and four DMAR writes to unmapped address zero when
the test terminated the viewer. SIGTERM had interrupted the completion wait
for an already-submitted firmware STOP command (`-ERESTARTSYS`), after which
STREAMOFF released mappings firmware could still use. Firmware-ring waits are
now bounded but non-interruptible, paired with non-restrictive IRQ wakeups, and
the validator treats any matching
channel, tag, or DMA fault as a failure.

On the final paired-wakeup build, terminating a confirmed live stream completed
in 715 ms, an immediate 30-frame capture recovered, runtime PM suspended the
device again, and none of those channel, tag, or DMA faults appeared. This
directly validates signal-time STREAMOFF.

The repeat lid test on that final module then passed every criterion: deep
suspend was entered, the original viewer continued capturing after resume, a
fresh capture recovered, runtime PM returned to suspended, and neither the
validator nor an independent boot-log scan found any channel, tag, DMA, or
kernel fault. Stream restoration across full system suspend is therefore
validated on this MacBookAir7,2.

### Frame-rate decimation and cropping (2026-08-18)

Run on the MacBookAir7,2, Ubuntu 26.04, kernel 7.0.0-29-generic, against the
installed DKMS build - so these results describe the driver as it already
shipped, not any later change.

Decimation passes at every requested rate. The rate is measured from the
difference between a short and a long capture at the same setting, which
cancels v4l2-ctl's fixed start-up cost; that cost measured 3.2-4.4 s, against a
6.0 s steady-state window, so subtracting it is not optional:

| Requested | Divisor | `G_PARM` | Measured | Steady-state window |
|---:|---:|---:|---:|---:|
| 30 | 1 | `30.000` | 29.95 | 180 frames in 6010 ms |
| 15 | 2 | `15.000` | 14.97 | 90 frames in 6012 ms |
| 10 | 3 | `10.000` | 9.98 | 60 frames in 6014 ms |
| 6 | 5 | `6.000` | 5.99 | 36 frames in 6012 ms |
| 3 | 10 | `3.000` | 3.05 | 18 frames in 5909 ms |
| 1 | 30 | `1.000` | 1.00 | 6 frames in 6012 ms |

Every rate is within 1.7% of the request, `G_PARM` reports the divisor-derived
rate exactly, and nothing starved - including divisor 30, where the requeue path
recycles 29 of every 30 frames through a pool of four buffers. Per-frame spacing
was not measured; only the bunching floor, which passed everywhere.

Cropping: the ISP **does** honour a non-zero origin. Frames captured through
`+8+8` and through the full array produce clearly different block signatures
(the bright region moves from the centre column to the outer columns), which is
the question "Cropping and digital zoom" left open. Aligned rectangles read back
exactly; a request for `left=4, top=5` was stored as `left=8, top=5`, confirming
that `left` is rounded to eight pixels and `top` is not.

**A far-offset crop rectangle starves the stream, and wedges the channel.**
With a 640x360 output on a 1280x720 sensor, a rectangle at the array's far
corner is accepted by `S_SELECTION` and then delivers no buffers at all: the
capture sits in `vb2_wait_for_done_vb` until it is killed, while the device
stays runtime-active. Worse, the channel does not recover on its own - every
subsequent `STREAMON` returns `-EIO` until the firmware is reloaded, so one bad
rectangle invalidates every rectangle tested after it in the same run.

Which rectangle triggers it is **not** yet fully pinned down, but the
`crop-geometry` run of 2026-08-18 narrowed it. With a runtime-PM firmware
reload forced between rectangles - so each corner was tested on a healthy
channel rather than after a wedge - **both** far corners starved: `+640+360`
and `+640+0` alike. They share `left == sensor_width - output_width` and differ
in `top`, so the top is not the variable. That contradicts the earlier record
here, taken from a run without recovery between cases, that `+640+0` streamed
while `+640+360` starved; the recovered run is the more trustworthy.

A flush right edge looked like the trigger and was tested directly: `left =
632`, whose right edge at `1272` clears the `1280` array, **starved as well**.
So the flush edge is not it, and the older note here that a left eight pixels
lower streams normally does not survive either - it too came from a run without
recovery between rectangles.

The left-offset sweep then bracketed it tightly. With a 640-wide crop on the
1280-wide array, left `0`, `8`, `240` and `320` stream; left `400`, `480`,
`560`, `632` and `640` starve. **The boundary is between `320` and `400`.**

Two further readings die there. Five rectangles streamed consecutively on one
firmware load before the first starve, which ends "the first far-offset
rectangle after a load starves". And the right edge alone is not it: the full
array ends at `1280` and streams while a 640-wide crop ending at `1280`
starves.

**The rule is `left <= (sensor_width - crop_width) / 2`**: the crop may sit at
or left of centre, never right of it. At 640 wide the boundary is exactly
centre - `320` streams, `328` starves - and at 320 wide, whose centre is `480`,
left `480` streams while `560` starves. That `480` is what rules out a fixed
offset limit. Across every rectangle measured, three crop widths and the exact
eight-pixel boundary at two different centres, it predicts 16 of 16 outcomes.

The vertical axis is not covered by that evidence: every rectangle used to
derive it had `top = 0`. Whether `top` faces the matching limit against
`(sensor_height - crop_height) / 2` is what the section's third phase asks.

No driver-side clamp is added yet. The horizontal rule is now measured rather
than guessed, but it is measured on one sensor, the vertical half is open, and
silently moving a rectangle the application asked for is its own harm - so the
shape of any fix is a decision to take deliberately, not a side effect of
learning the rule.

Crop GET narrows it further from the other side: in both starving cases the ISP
returned *exactly* the rectangle it was given. It is not rejecting the geometry
and not silently adjusting it, so the fault lies downstream of crop programming.

The `crop` section arms both corners as named cases, forces a runtime-PM
recovery after a starvation, and marks later rectangles untrustworthy if the
channel does not come back.

Note that the driver's own clamping can produce such a rectangle from a request
that does not look like one: `left=648, width=632` is rounded to `+640+0`
640x360.

Root-causing it needs the firmware's own log at `dyndbg=+p`; the ordinary log
shows the stall but no channel or SIF error. No driver-side workaround has been
added - refusing or nudging the rectangle would be a guess at the cause and
would silently alter what the application asked for.

### The semi-planar format is NV12, not NV16 (2026-08-18)

Two runs, on the MacBookAir7,2 with the format enabled by module parameter.

The first negotiated correctly and did not fault - `ENUM_FMT`, `G_FMT` holding
the fourcc, ten frames as an exact multiple, no IOMMU or DMAR fault - and still
produced a broken frame: 50% of the luma plane zero in an every-other-row
pattern, chroma averaging 73.6 with Cb 71.7 and Cr 75.4. That was the
output-config stride, described under "Pixel formats" above.

With the stride fixed, the second run gave `nv12.stride_rows` clean at 0.0%
blank rows and a luma mean of 96.7, but chroma still failed at 64.3 against a
YUYV reference of Cb 122.5 / Cr 135.4. Mapping the whole frame row by row
explained both numbers at once:

| Region | Bytes | Content |
|---|---:|---|
| rows 0-719 | 921,600 | luma, complete, no blank rows |
| rows 720-1079 | 460,800 | chroma, mean 128.3 |
| rows 1080-1439 | 460,800 | **all zero, never written** |

Chroma is 360 rows for a 720-row image: 4:2:0. The failing mean of 64.3 was
simply the real chroma averaged with an equal quantity of untouched zeros. Taken
over its actual extent the chroma reads Cb 122.3 / Cr 135.3 against the YUYV
reference's 122.5 / 135.4, and luma 93.1 against 92.9 - the same picture, to
within a fifth of a luma level.

The driver now advertises NV12 with `sizeimage = width * height * 3 / 2`. It was
behind `facetimehd.nv12=1` while that sizing was still unproven; the run above
proved it, so the parameter is gone and the format is enumerated unconditionally
(last, after YUYV and YVYU, so first-format applications are unaffected). NV16
is removed: no output-format code produces it.

This validates one machine, model and kernel rather than the complete
2013–2015 Mac range. Still untested or unproven are:

- the combined post-`20bdd61` feature build repeatedly hard-locked this
  MacBookAir7,2 after a successful probe and before a panic could reach the
  journal or pstore. The lock persisted with runtime PM and hwmon registration
  disabled, ruling both out as the sole cause. The strongest remaining
  automatic path was control replay at `STREAMON`: it issued every inferred
  firmware command simply because the controls were registered. Firmware
  disassembly subsequently proved multiple layouts malformed, including an
  AE-bias request four bytes shorter than the fields firmware reads. The
  controls and their module gate have been removed; the non-firmware frame-rate
  and buffer work remains enabled;

- the visible effect of anti-banding and exposure mode under controlled light;
- whether `CISP_CMD_CH_CROP_GET`'s second rectangle is the sensor array on any
  machine other than the MacBookAir7,2. There it was constant at `0 0 1280 720`
  across four crops while the first tracked each one, which identifies both on
  that sensor and no other;
- that `awb_cct_estimate` reads kelvin on any machine other than the
  MacBookAir7,2. The warm-to-cool tracking there is strong evidence, and the
  control is read-only so a wrong unit misinforms rather than misconfigures,
  but it is one sensor;
- orderly reboot or kexec while actively streaming;
- recovery from a real firmware command timeout, which has not been reproduced;
- any future reimplementation of manual exposure, white balance, exposure
  bias, sharpness or test-pattern controls. Recovered layouts and remaining
  semantic questions are recorded in `FIRMWARE-REVERSE-ENGINEERING.md`;
- NV12 on any machine other than the MacBookAir7,2. The format, its sampling,
  its plane offsets and its stride are all measured there, and it is advertised
  on that evidence, but like everything else here it is one sensor;
- frame-rate selection is **validated** on the MacBookAir7,2 - see below - apart
  from per-frame spacing, which the `decimation` section still does not measure.
  It checks a coarse bunching floor only, so a stream that arrives at the right
  mean rate with uneven spacing would pass;
- the crop origin is **confirmed** honoured, but a far-corner rectangle starves
  the stream and wedges the channel - see below. Two further questions on that item
  are not reachable through this ABI at all and are not attempted: the driver
  rounds the rectangle before the ISP ever sees it, so an alignment finer than
  eight pixels cannot be requested, and it refuses a crop smaller than the
  output, so whether the scaler would upscale cannot be asked. Both need
  scaffolding of their own; the test records what the driver did with a
  misaligned request so that work has a baseline;
- any future backlight-compensation, noise-reduction or chroma-suppression
  controls: their visible effect and an honest mapping for every firmware
  field. They are not currently exposed;
- whether any supported sensor returns something other than the `-1`
  unavailable temperature sentinel, and its scale if so. Closed on the
  MacBookAir7,2 - see "Sensor temperature" - and open only for other sensors.

Remove entries from this document when the corresponding fixes are accepted
upstream.
