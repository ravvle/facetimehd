# FaceTimeHD firmware command notes

This file records facts recovered from the camera firmware while investigating
repeatable whole-machine lockups on a MacBookAir7,2. It deliberately separates
observed firmware behaviour from guesses. Do not turn an item marked
**unknown** into a userspace ABI without new evidence and a hardware test.

## Image examined

- Host: `MacBookAir7,2`, Broadcom FaceTime HD `14e4:1570`
- OS/kernel during the incident: Ubuntu, `7.0.0-29-generic` x86-64
- File: `firmware.bin` extracted for the machine (not tracked by this project)
- SHA-256: `e3e6034a67dfdaa27672dd547698bbc5b33f47f1fc7f5572a2fb68ea09d32d3d`
- Size: 1,425,412 bytes
- Embedded version strings: `S2ISP-01.43.00`, `H4ISPAPPLE`, `H4ISPCD`, and
  `A4.5.5.1 release`
- Format: raw little-endian ARM image. The vector table begins in ARM mode and
  the command implementation is Thumb-2.

All firmware addresses below are offsets in that exact image. They are useful
for reproducing the analysis but must not be assumed stable across firmware
versions.

## Reproduction commands

The useful packages on Ubuntu are `binutils-arm-none-eabi`, `radare2`, and
`gdb-multiarch`. The installed versions used here were GNU objdump
`2.45.50.20251209`, radare2 `6.0.7`, and GDB `17.1`. Static inspection used no
command submission to the live ISP.

```text
sha256sum firmware.bin
strings -a -t x firmware.bin
arm-none-eabi-objdump -D -b binary -m arm -EL -M force-thumb firmware.bin
r2 -q -2 -a arm -b 16 -e cfg.bigendian=false \
   -c 'aaa; pdc @ 0x47530' firmware.bin
```

Radare2 identifies the main channel-command dispatcher as the Thumb function
at `0x47530`. Its analysed control-flow range is `0x47530..0x68bf6` (the
function has many non-contiguous basic blocks).

Apple-private commands use a separate dispatcher beginning at `0x70f0`. For
opcode `0x8208`, its table at `0x7910` selects block `0x8e4a`. That block reads
one 32-bit word at `+0x0c` and forwards it unchanged to wrapper `0xca2c`.

String cross-references can be found by searching the image for a string
address encoded as a little-endian 32-bit value, then finding the Thumb
PC-relative load of that literal. For example, the AE-bias log string is at
`0xa9384`, its pointer is stored at `0x4a490`, and the dispatcher loads that
pointer at `0x49a2e`.

## Wire framing

Linux sends an eight-byte `isp_cmd_hdr`, followed by the command payload:

```text
command+0x00  u32 unknown0
command+0x04  u16 opcode
command+0x06  u16 status
command+0x08  u32 channel             (for per-channel commands)
command+0x0c  first command field
```

This is confirmed both by `struct isp_cmd_hdr` and by the firmware dispatcher,
which reads the opcode at `command+0x04`, routes the channel from the first
payload word, and accesses command-specific data from `command+0x0c` onward.
The dispatcher does not appear to enforce a distinct minimum request length
for every opcode. A short Linux payload can therefore make firmware read past
the submitted object; it is not safe to assume a malformed request will be
rejected.

That last point invalidates the feature commit's original safety claim. On the
test MacBook, the affected driver repeatedly froze the entire machine without
a panic or pstore record. The same code had automatically replayed every new
control during ordinary `STREAMON`.

## Incident reconstruction

1. The older driver at commit `20bdd61` booted and passed probe, capture,
   established-control, runtime-PM, and system-suspend recovery tests.
2. The later feature series (`953fe61` through `8e154f9`) installed and reported
   success, then repeatedly hard-locked the whole laptop. No orderly kernel
   failure reached the journal or pstore; recovery required a power-button
   reset.
3. Disabling runtime PM did not prevent the lock. Disabling hwmon registration
   did not prevent it either, excluding each as the sole cause.
4. Booting with `module_blacklist=facetimehd` reliably recovered the system.
   A build with experimental controls, formats, hwmon, and runtime PM disabled
   then booted, captured 30 frames, and passed 57/57 applicable
   `v4l2-compliance` tests.
5. That localization led to the ordinary stream-start path. Registering V4L2
   controls makes `v4l2_ctrl_handler_setup()` submit their default setters at
   every `STREAMON`; users did not have to touch an experimental control to
   trigger the firmware traffic.
6. Firmware disassembly proved that AE bias and manual AWB CCT requests were
   shorter than the fields the firmware reads, and that the test-pattern,
   manual-gain, and chroma-suppression interpretations were also wrong or
   incomplete. The unsafe interfaces were therefore removed rather than left
   behind module flags.

During the final state audit, `install.sh --status` also falsely reported the
resident module as unloaded. The scripts used `lsmod | grep -q` under
`set -o pipefail`; an early successful grep could close the pipe and turn
`lsmod`'s SIGPIPE into a failed pipeline. Module lifecycle checks now read the
authoritative `/sys/module/facetimehd` directory instead.

The strongest root-cause statement supported by the evidence is: **automatic
replay of malformed or semantically guessed firmware commands caused the new
build's lockups**. AE bias is the leading individual command because it was
sent by default and provably made firmware read a missing word. It cannot be
named as the sole cause without a controlled one-command reproduction, which
would be an unnecessary whole-machine risk at this stage.

## Recovered command layouts

`+0xNN` offsets in this table are from the start of the complete command,
including the eight-byte header.

| Opcode | Command | Firmware evidence | Consequence for the attempted driver API |
|---|---|---|---|
| `0x8208` | Apple AE flicker-frequency set | Apple dispatcher block `0x8e4a`: reads one word at `+0x0c` and forwards it to wrapper `0xca2c`. | The existing `u32 channel; u32 frequency` layout is correct. Hardware accepted `0`, `50`, and `60`; static analysis does not prove their visible anti-banding effect. |
| `0x204` | AE bias exposure set | Block `0x49a04`: reads a halfword at `+0x0c` and a word at `+0x10`; log at `0xa9384` prints both as `bias` and `tag`. | Payload is at least `u32 channel; u16 bias; u16 reserved; u32 tag`. The attempted `u32 channel; s32 bias` was four bytes short, omitted the tag, treated the bias as signed milli-EV without evidence, and made firmware read beyond the request. This is the leading lockup candidate. |
| `0x20f` | AE integration time set | Handler ending at `0x4ab84`; reads a word at `+0x0c`. Log at `0xa903b`. | `u32 channel; u32 value` has the correct size/offset. The claim that the unit is microseconds is not yet proven. |
| `0x20c` | AE gain-cap set | Block `0x49b1e`: reads a word at `+0x0c`; log at `0xa9206`. | `u32 channel; u32 value` is structurally correct. The `0..255` V4L2 range and use as a manual sensor-gain control are not proven. |
| `0x22e` | AE minimum gain-cap set | Block `0x49f92`: reads a word at `+0x0c`; log at `0xa922f`. | The individual payload shape is correct. Pinning gain by writing minimum then maximum was an inference; it may transiently make min exceed max and has not been validated. |
| `0x305` | AWB CCT manual | Block `0x4a7c6`: copies words at `+0x0c` and `+0x10` into an eight-byte internal request; log at `0xa8e9a`. | Payload is `u32 channel` plus two words. The attempted helper supplied only `channel + cct`, so the second word was read beyond the request. The second word is plausibly a tag, but that name and the kelvin interpretation remain unproven. |
| `0x311` | AWB first-gain manual | Block `0x4aa54`: reads halfwords at `+0x0e`, `+0x10`, `+0x12`, and `+0x14`. | The unused attempted `channel + red u32 + blue u32` helper is wrong and too short. Firmware expects additional packed 16-bit fields; their meanings are unknown. |
| `0x503` | Sensor test-pattern config | Block `0x4973c`: reads halfwords at `+0x0c` and `+0x0e`; the log at `0xa8f51` reports the `+0x0e` field as the pattern. | The attempted `u32 channel; u32 pattern` put the menu value in the wrong halfword, so every selection actually requested pattern zero. The meaning of the first halfword is unknown. |
| `0x506` | Sensor temperature get | Block `0x497a6`: the sensor returns a signed 16-bit value, which the dispatcher sign-extends and stores as a word at `+0x0c`; log at `0xa8f21`. | `u32 channel; s32 temperature` is structurally correct. The scale is still unknown, so publishing it as hwmon millidegrees Celsius is not justified until raw readings are compared against a known temperature. A manual raw read is defensible; automatic polling is not yet. |
| `0xa07` | Scaler sharpness set | Block `0x48b68`: reads one byte at `+0x0c`; wrapper `0x563c4`; log at `0xa93e2`. | One `0..255` byte is structurally valid. This is a different opcode from the attempted V4L2 control. |
| `0xa09` | Sharpness set | Block `0x48b90`: reads one byte at `+0x0c`; wrapper `0x55548`. | The attempted control used this opcode and its value layout is structurally valid. Its effect and preferred default still need image-based validation. |
| `0xa0b` | Noise reduction set | Block `0x48baa`: reads one byte at `+0x0c`; wrapper `0x5e2b8`. | The attempted one-byte-strength interpretation is structurally valid, but its effect and safe default are unvalidated. |
| `0xa0d` | Chroma suppression set | Block `0x48bc0`: reads three separate bytes at `+0x0c`, `+0x0d`, and `+0x0e`; wrapper `0x555a0`; log at `0xa946c`. | A single V4L2 strength is not an honest representation. The attempted `u32 strength` happened to supply `{strength, 0, 0}`, but the meanings and valid combinations of all three fields are unknown. |
| `0xa19` | DRC set | Block `0x48f9c`: reads one byte at `+0x0c`; wrapper `0x56450`. | A one-byte value is structurally valid. Mapping it to `V4L2_CID_BACKLIGHT_COMPENSATION` is a policy guess, not firmware evidence. |

The small internal wrappers reinforce these widths: sharpness and DRC store a
single byte, while chroma suppression stores three consecutive bytes before
submitting a fixed-size internal message.

## Confirmed read-only command surface

The standard dispatcher jump table at `0x4826e` and the Apple-private table at
`0x7910` provide a closed, non-exploratory GET list. The driver exposes these
only as mode-`0400` debugfs files while channel zero is already streaming:

| Opcode | Readback | Dispatcher evidence | Response after `u32 channel` |
|---|---|---|---|
| `0x203` | AE bias/tag | `0x499ec`, paired vtable GET for the `0x204` layout | `u16 bias; u16 reserved; u32 tag` |
| `0x20b` | AE gain cap | `0x49b06` | one `u32` |
| `0x20d` | AE integration-time maximum | `0x49b58` | one `u32` |
| `0x22a` | Sensor integration-time minimum | `0x49ede` | one computed `u32` |
| `0x22c` | Sensor integration-time maximum | `0x49f40` | one computed `u32` |
| `0x22d` | AE gain-cap minimum | `0x49f7c` | one `u32` |
| `0x22f` | AE gain-cap maximum with exposure | `0x49fbe` | one `u32` |
| `0x231` | AE gain-cap off value | `0x4a000` | one `u32` |
| `0x304` | AWB CCT | `0x4a7ae`, wrapper `0x9e464` | one `u32` |
| `0x506` | Sensor temperature | `0x497a6` | signed 16-bit sensor result, sign-extended to `s32` |
| `0x8207` | Apple AE metering mode | `0x8e0a`, mappings at `0x9518`--`0x9522` | one `u8` (`0`--`3`) |

The image-processing enum is misleading on this exact firmware: the main
dispatcher table sends `0xa0a` sharpness GET, `0xa0c` noise-reduction GET,
`0xa0e` chroma-suppression GET, and `0xa1a` DRC GET directly to the unsupported
command block at `0x4996c`. Only the adjacent setters are implemented. Those
GET names are retained as recovered protocol documentation but must not be
sent, and the driver creates no debugfs files for them.

An on-demand read holds `ioctl_lock`, verifies `channel_running`, takes a
runtime-PM reference, sends exactly one compile-time-selected GET, and drops
the reference before unlocking. It cannot start an idle ISP, does not poll,
does not register hwmon, and offers no arbitrary-opcode input.

The first complete hardware run finished fault-free on 2026-08-18
(`/tmp/facetimehd-hw-validate-20260818-142628.log`):

| Readback | Raw result |
|---|---:|
| Sensor temperature | `-1` |
| AWB CCT | `4697` |
| AE bias / tag | `256` / `0` |
| AE gain cap / minimum | `8192` / `256` |
| AE gain cap with exposure / off | `0` / `0` |
| AE integration maximum | `33` |
| Sensor integration minimum / maximum | `38` / `1000000` |
| AE metering mode | `3` |

The stream stayed live and teardown produced no firmware, channel-stop, buffer,
IOMMU, or DMAR fault. These values make Q8.8 gain/bias and microsecond sensor
bounds plausible, but do not prove those units. Temperature `-1` is more likely
an unavailable sentinel than a physical reading. The readback section is now
part of the normal hardware suite.

A controlled profile on the same machine then completed fault-free
(`/tmp/facetimehd-hw-validate-20260818-144108.log`). It sampled the values after
a runtime resume, under bright and dark scenes, under warm and cool light,
after ten minutes of continuous streaming, and at requested 30 and 15 fps:

| Condition | AWB CCT | AE bias/tag | Gain cap/min | AE integration max | Temperature |
|---|---:|---:|---:|---:|---:|
| Ambient, 30 fps | `4995` | `256/0` | `8192/256` | `33` | `-1` |
| Bright neutral/white | `5906` | `256/0` | `8192/256` | `33` | — |
| Fully covered/dark | `5352` | `256/0` | `8192/256` | `33` | — |
| Warm/yellow light | `2652` | `256/0` | — | — | — |
| Cool/blue-white light | `5777` | `256/0` | — | — | — |
| After ten-minute stream | `5301` | — | `8192/256` | `33` | `-1` |
| Ambient, requested 15 fps | — | `256/0` | `8192/256` | `33` | — |

Warm versus cool light moving the first AWB word from `2652` to `5777`, with
realistic magnitudes and ordering, is strong hardware evidence that it is the
current correlated-colour-temperature estimate in kelvin. A dark-frame CCT has
no useful illuminant to describe and is not evidence against that reading.
Cross-model validation is still needed before treating the unit as a stable ABI.

Bias/tag, both gain caps, and AE integration maximum remained invariant across
the lighting changes. They are therefore configuration state or limits rather
than live measurements of the current exposure. The gain values continue to be
consistent with, but do not prove, Q8.8 (`256` = 1x and `8192` = 32x). The
integration maximum remaining `33` when userspace requested 15 fps agrees with
the driver's downstream frame decimation: the sensor/AE limit was not changed.
The sensor limits also remained `38..1000000`. Temperature remained `-1` after
ten minutes of streaming, making an unavailable/not-supported sentinel much
more likely than an unknown physical scale on this sensor. Capture ran at about
29.97 and 14.98 fps and teardown remained free of firmware, channel, IOMMU and
DMAR faults.

## Same-value setter harness

Five root-write-only debugfs nodes support the next controlled experiment: AE
bias/tag (`0x204`), metering mode (`0x8206`), AE integration maximum (`0x20e`),
gain cap (`0x20c`), and minimum gain cap (`0x22e`). They accept no numeric input:
the only valid write is `same`. Under `ioctl_lock` and an active-stream check,
the kernel performs GET, SET of the exact returned value, then GET and equality
verification. Thus userspace cannot choose an out-of-range value or make two
gain limits cross, and no action occurs at module load, STREAMON, or resume.

`tests/hw-validate.sh --only roundtrips` persists an armed marker before each
write, uses a new live stream for each command, checks capture after STREAMOFF,
cycles runtime PM, and scans for firmware/DMA faults. `ROUNDTRIPS` can restrict
a run to one name so the first hardware validation remains one setter per run.
This harness is intentionally not a V4L2 ABI and must be removed or kept as
debug-only scaffolding once the command semantics are established.

All five same-value paths passed individually on the MacBookAir7,2 on
2026-08-18:

| Setter | Value written back | Durable report |
|---|---:|---|
| AE bias/tag | `256/0` | `/tmp/facetimehd-hw-validate-20260818-145904.log` |
| AE metering mode | `3` | `/tmp/facetimehd-hw-validate-20260818-145932.log` |
| AE integration maximum | `33` | `/tmp/facetimehd-hw-validate-20260818-145959.log` |
| AE gain cap | `8192` | `/tmp/facetimehd-hw-validate-20260818-150018.log` |
| AE minimum gain cap | `256` | `/tmp/facetimehd-hw-validate-20260818-150103.log` |

For every command, the in-kernel GET/SET/GET comparison matched, the original
stream remained alive, capture succeeded after STREAMOFF and restart, capture
succeeded after a runtime-PM idle cycle, and the log contained no firmware,
channel-stop, IOMMU, or DMAR fault. This validates each recovered setter's
payload width and its ability to accept the firmware's own current value. It
does **not** establish units, ranges, visible effects, safe non-current values,
or a correct multi-command manual-exposure sequence. In particular, it does not
justify exposing these setters through V4L2 or replaying them at STREAMON.

## Bounded metering-mode semantics harness

Metering is the first non-current-value experiment because firmware disassembly
closes its domain to four values (`0`--`3`), mode `3` is already programmed by
the established channel-start sequence, and its current-value setter passed the
full round-trip test above. A root-write-only `test_ae_metering_mode` debugfs
node accepts only the literal tokens `mode0`, `mode1`, `mode2`, and `mode3`.
It rejects numeric parsing and every other string, requires a running channel,
holds `ioctl_lock` and a runtime-PM reference, performs the SET followed by a
GET, and fails unless firmware returns exactly the requested mode.

The opt-in `metering-modes` hardware-test section starts a fresh stream for
each mode. It records the startup mode, persists an armed marker, changes one
mode, discards 120 frames for AE settling, retains 12 packed-YUV frames, and
reports full-frame, central-spot, centre-quarter, and outer-region mean luma
from the final complete frame. The operator supplies a fixed high-contrast
scene with a bright central target and dark surround. The mode-3 baseline must
measure the spot at least 20 luma above the outer region without clipping;
otherwise the test stops before modes `0`--`2`. Before STREAMOFF the test writes
and verifies the original mode; it then checks a fresh capture, a runtime-PM
idle/resume capture, and firmware/channel/IOMMU/DMAR logs. An EXIT trap attempts
the same restore if the runner is interrupted while the stream is live.
Independent of that trap, every new channel still starts in established mode
`3`.

This test can establish acceptance and visible spatial-weighting differences.
It must not assign the standard V4L2 average, centre-weighted, spot, or matrix
names until the measurements support those meanings. No production control or
automatic replay is added by this harness.

The first bounded run completed without an operational failure
(`/tmp/facetimehd-hw-validate-20260818-151936.log`). Every mode read back
exactly, remained selected through settling and capture, restored to `3`,
survived stream restart and runtime PM, and produced no firmware, channel,
IOMMU, or DMAR fault. Its final-frame measurements were:

| Mode | Full | Centre quarter | Outer |
|---:|---:|---:|---:|
| `3` | `50.3` | `37.0` | `54.7` |
| `0` | `53.9` | `38.9` | `58.8` |
| `1` | `54.0` | `38.6` | `59.1` |
| `2` | `52.0` | `37.7` | `56.7` |

This establishes bounded non-current-value safety on the MacBookAir7,2, but
not semantics. The measured centre was darker than the outer region, opposite
the intended bright-centre scene, and modes `0` and `1` were effectively
indistinguishable in a single final-frame sample. The result must not be used
to assign V4L2 menu names. It prompted the explicit central-spot precondition
above.

The controlled rerun passed that precondition and again completed without an
operational failure (`/tmp/facetimehd-hw-validate-20260818-152753.log`):

| Mode | Full | Central spot | Centre quarter | Outer |
|---:|---:|---:|---:|---:|
| `3` | `40.2` | `99.8` | `40.9` | `40.0` |
| `0` | `40.0` | `99.1` | `40.3` | `39.9` |
| `1` | `41.2` | `99.6` | `40.7` | `41.4` |
| `2` | `40.2` | `99.4` | `40.4` | `40.1` |

The spot was about 60 luma above its surround and was not clipped, but the
largest cross-mode spreads were only `1.2` full-frame, `0.7` spot, `0.6`
centre-quarter, and `1.5` outer luma. Those differences are too small to assign
average, centre-weighted, spot, or matrix meanings; they are compatible with
capture noise or small scene drift. Modes `0`--`3` are therefore established
as accepted, persistent, bounded and teardown-safe, but not as visibly distinct.

The established startup sequence programs mode `3` before channel start, then
starts AE through V4L2 control replay. The mutation harness changes the mode
while AE is already running. A second root-only test node accepts the same four
fixed tokens but performs AE STOP, metering SET, AE START and exact GET under
the same lock/stream/runtime-PM boundary. `METERING_RESTART_AE=1` selects that
path in the existing runner, including restoration through the same sequence.
AE start/stop is an existing hardware-tested V4L2 path; this remains an
explicit diagnostic and adds no production metering control.

## Why default streaming froze

With the inferred controls registered, `v4l2_ctrl_handler_setup()` replayed
their defaults after each channel start. Auto exposure and auto white balance
returned before their manual setters, so the malformed AWB-CCT command was not
part of a default stream. The default replay did include AE bias, sharpness,
test pattern, DRC, noise reduction, and chroma suppression.

Of those, AE bias is the clearest memory-safety defect: firmware reads the
missing tag word beyond Linux's request. Test-pattern values were placed in the
wrong halfword, and chroma suppression omitted two meaningful parameters, but
their reads remained inside the eight-byte value word that Linux supplied.
This makes AE bias the leading explanation, not a proof that the other guessed
commands are safe.

## NV16 findings

NV16 output code zero was not invented by the 2026 feature patch. It existed in
the upstream driver in 2015. Upstream commit `d57b16fc6438` disabled NV16 with
the comment that multiplanar support was missing, and it remains disabled in
upstream `364b1c663583`.

The old code modelled NV16 as two vb2 planes but used the single-planar
`V4L2_BUF_TYPE_VIDEO_CAPTURE` API and incorrectly reported only
`width * height` bytes per plane. A correct single-planar NV16 buffer is one
userspace buffer containing a `width * height` luma plane followed by an equal
sized interleaved chroma plane. It therefore needs:

```text
bytesperline = width
sizeimage    = width * height * 2
ISP addr0    = mapped buffer base
ISP addr1    = mapped buffer base + width * height
```

The newer implementation follows that layout, and the driver's IOMMU allocator
does give the scatterlist one contiguous ISP virtual-address range. Static
analysis cannot prove that format code zero works on this sensor, so it still
needs an explicit capture test before being advertised to normal format
negotiators.

The earlier hardware report did **not** validate NV16 despite recording a pass:
NV16 was absent from `ENUM_FMT`, `S_FMT` silently coerced the unsupported fourcc
to YUYV, both formats have the same total byte count, and the test checked only
size and capture. A valid future test must read back `G_FMT` and require the
returned fourcc to remain `NV16`, in addition to checking plane content.

## Other feature status learned during the incident

- The exact old driver core at commit `20bdd61` passed probe, capture, stable
  controls, two runtime suspend/resume cycles, and system suspend recovery on
  this MacBook. Its viewer did exit across suspend; capture recovered after the
  application restarted.
- The latest source with inferred controls, NV16 and hwmon all disabled booted
  and streamed successfully. It exposed only YUYV/YVYU and the seven established
  controls. A 30-frame capture and `v4l2-compliance` run completed with 57 tests
  successful and zero failures.
- The later build had already frozen with runtime PM disabled, so runtime PM was
  not the sole cause. Runtime PM remains default-off until the latest guarded
  core is cycled deliberately.
- Frame-rate division is driver-only: it drops/recycles frames already received
  from the ISP and sends no new configuration opcode.
- Mutable crop uses the established crop opcode and known payload, but non-default
  rectangles still need visual hardware validation.
- Stream restoration across system suspend is software/lifecycle work, not a
  new undocumented image-control opcode. It needs a new end-to-end lid test on
  the guarded latest build.
- The installer once derived the DKMS version from the live tree before copying
  it, allowing the label and staged source to race. It now snapshots first and
  hashes/parses the staged copy.

### Corrected-build reboot validation (2026-08-18)

The corrected source was installed through DKMS with `runtime_pm=0` and loaded
automatically on a normal reboot, without a kernel-command-line blacklist. The
installed `/usr/src` snapshot matches the maintained driver source (apart from
DKMS's required `PACKAGE_VERSION` rewrite). Boot produced `camera ready: DDR
450 MHz, 64-bit DMA` and no FaceTimeHD, IOMMU, timeout, oops, or firmware-fault
record. The ordinary out-of-tree/unsigned-module taint was the only matching
warning; Secure Boot was off.

The post-reboot hardware checks established:

- only the `runtime_pm` module parameter exists, and it read `N`;
- only YUYV and YVYU are enumerated;
- only brightness, contrast, saturation, hue, automatic white balance,
  power-line frequency, and automatic/manual exposure are exposed;
- a 30-frame smoke capture succeeded;
- `v4l2-compliance` completed 57/57 applicable tests with zero failures; its
  one warning was the intentionally unsupported `VIDIOC_CREATE_BUFS` on the
  fixed four-buffer hardware pool;
- brightness, contrast, saturation, and hue were each exercised at 64 and 192;
  automatic white balance at 0 and 1; power-line frequency at 0, 1, and 2; and
  automatic exposure at manual and auto. A capture succeeded after every set;
- YUYV and YVYU each captured ten 1280x720 frames after exact fourcc readback;
- a crop at left 320, top 120, size 640x480 read back exactly and captured ten
  frames; and
- a requested 15 fps read back as `30/2` and captured 30 frames without buffer
  starvation.

Format, crop, frame rate, and all controls were restored to their defaults at
the end. Runtime-PM cycling and system suspend remain separate boot/lid tests;
they were not silently enabled as part of this baseline.

### Corrected-build runtime-PM validation (2026-08-18)

The next boot loaded the same corrected DKMS source with `runtime_pm=Y`.
Immediately after boot the PCI device reported `power/control=auto`, a 5000 ms
autosuspend delay, and `runtime_status=suspended`.

Five consecutive cycles each began in the suspended state, opened the video
node, captured ten 1280x720 YUYV frames, and returned to suspended after idle.
Capture startup/completion took 2.106-2.171 seconds per cycle. The PCI runtime
counters advanced from 26,758 ms active / 49,969 ms suspended to 67,425 ms
active / 54,537 ms suspended. After the fifth cycle, the device still reported
`suspended`. No FaceTimeHD warning, firmware timeout, IOMMU/DMAR fault, oops,
general-protection fault, or call trace appeared.

This validates repeated runtime teardown, firmware reload, streaming, and
re-idle on the corrected build. It does not replace the separate full-system
suspend-while-streaming lid test.

### Full-system suspend finding (2026-08-18)

The first corrected-build lid test did enter deep suspend, resumed after 23
seconds, continued delivering frames to the already-running `v4l2-ctl`, and
completed a fresh ten-frame recovery capture. Those visible results initially
looked successful, but the detailed log made the run a failure:

```text
failed to stop firmware channel: -512
buffer return tag 0x182 has invalid state 0
buffer return ... carries unknown tag 0x183 ... 0x185
DMAR: [DMA Write NO_PASID] Request device [02:00.0] fault addr 0x0
```

`-512` is `-ERESTARTSYS`. After checking that the resumed viewer was still
advancing, the test sent it SIGTERM. The signal interrupted the driver's
firmware channel-STOP completion wait even though the STOP request had already
entered the hardware ring. STREAMOFF then released VB2/IOMMU mappings while
firmware still owned buffers, producing the stale returns and four observed
DMA writes to unmapped address zero.

This is a general signal-time stream-teardown defect, not proof that the
suspend restart itself failed: killing an ordinary capturing application can
reach the same path. Submitted firmware commands are not cancellable, so their
already-bounded waits are now non-interruptible, and the IRQ completion paths
use `wake_up()` so those tasks are woken immediately. An intermediate build
left `wake_up_interruptible()` in place; that cannot wake an uninterruptible
waiter and made command sequences advance only at timeout boundaries. The
suspend validator also
fails on channel-stop errors, invalid/unknown tags, and IOMMU/DMAR faults; the
old version had incorrectly reported the run as clean.

The final wait/wakeup-paired build was then tested against the original
signal-time failure without system sleep. A stream was allowed to produce
frames before SIGTERM; teardown completed in 715 ms, a fresh 30-frame capture
succeeded immediately afterwards, runtime PM returned the device to suspended,
and the boot log contained no channel-stop failure, invalid/unknown buffer tag,
IOMMU/DMAR fault, oops, or call trace. This validates the direct teardown fix;
the lid test still has to confirm the same result after stream restoration.

The repeat lid test on the final module completed the validation. The machine
entered deep suspend, the original viewer continued receiving frames after
resume without reopening the device, a fresh capture succeeded, and runtime PM
returned the camera to suspended. The validator and an independent full-boot
scan found no channel-stop failure, invalid/unknown buffer tag, IOMMU/DMAR
fault, oops, or call trace. The durable report is
`/tmp/facetimehd-hw-validate-20260818-135449.log` on the test machine.

Full-system suspend and signal-time STREAMOFF are therefore validated for this
build on the MacBookAir7,2. Orderly reboot while actively streaming remains an
optional, separate shutdown-path test.

## Rules for any reimplementation

1. Never register a control whose defaults cause an unvalidated opcode to be
   sent by ordinary `STREAMON` or runtime-resume replay.
2. Match every field width, offset and total payload length to firmware evidence.
   Zero-initialise reserved fields explicitly.
3. Do not invent units, ranges, or a standard V4L2 meaning from an opcode name.
4. Add GET support first where possible; it can reveal current firmware values
   and valid structure widths without changing image state.
5. Validate one setter at a time, only after a normal stream is stable. Sync
   storage first and preserve a one-boot module-blacklist recovery path. A
   same-value pass validates framing, not the command's unit or safe range.
6. A successful ioctl is not enough. Read the value back, inspect the firmware
   log, capture frames, measure the intended image effect, stop/restart the
   stream, and check for delayed faults.
7. Do not expose sensor temperature through hwmon until its scale is established.
8. Do not advertise NV16 until `G_FMT` confirms NV16 and captured luma/chroma
   plane contents are both plausible.

## Open questions

- AE-bias encoding, units, valid range, and tag semantics.
- AWB-CCT manual-set second-word/tag semantics; the GET value now strongly
  tracks kelvin on the MacBookAir7,2 but still needs cross-model confirmation.
- The four packed fields used by AWB first-gain manual.
- The first halfword and supported pattern indices for sensor test pattern.
- Integration-time and gain units/ranges, and the correct atomic manual-exposure
  sequence (the firmware also has manual-mode and combined integration/gain
  opcodes that may be more appropriate than collapsing two gain caps).
- Meanings and safe combinations of the three chroma-suppression bytes.
- Whether any supported sensor returns something other than the `-1`
  unavailable sentinel, and its scale if so.
- NV16 operation and chroma ordering on the MacBookAir7,2 sensor.
