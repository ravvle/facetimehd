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

The standard dispatcher's `0x2xx` jump table at `0x4826e` and the Apple-private
table at `0x7910` provide a closed, non-exploratory GET list. `0x4826e` is one
of twelve such tables; see "Complete dispatcher table sweep" below. The driver exposes these
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

## Complete dispatcher table sweep

The `0x4826e` table used above is not the dispatcher's only one. The dispatcher
is a binary-search compare tree over the opcode that routes each *dense* opcode
class to its own `tbh [pc, rN, lsl #1]` table and handles sparse or low opcodes
by explicit comparison. Every one of those tables is guarded by the same
range check and the same default target -- the unsupported-command block at
`0x4996c`:

```text
subw  rN, r2, #<class base>
cmp   rN, #<count - 1>
bhi.w 0x4996c              ; unsupported
tbh   [pc, rN, lsl #1]     ; table base = this address + 4
```

Entries are little-endian halfwords; the target is `table_base + 2 * entry`.
An entry resolving to `0x4996c` is a command this firmware does **not**
implement. Scanning the image for `E8DF F0.x` and keeping the sites whose
preamble branches to `0x4996c` finds exactly twelve, and they are complete in
the sense that no thirteenth table shares that default:

| Table | Opcodes | Entries | Implemented | Unsupported |
|---|---|---:|---:|---:|
| `0x47644` | `0x104`--`0x126` | 35 | 34 | 1 |
| `0x48272` | `0x200`--`0x23a` | 59 | 50 | 9 |
| `0x4993a` | `0x300`--`0x311` | 18 | 13 | 5 |
| `0x4990a` | `0x400`--`0x40d` | 14 | 12 | 2 |
| `0x47fae` | `0x500`--`0x50c` | 13 | 13 | 0 |
| `0x47de6` | `0x602`--`0x608` | 7 | 7 | 0 |
| `0x47aa2` | `0x700`--`0x707` | 8 | 8 | 0 |
| `0x4788c` | `0x800`--`0x80a` | 11 | 11 | 0 |
| `0x4780c` | `0xa01`--`0xa2c` | 44 | 38 | 6 |
| `0x47746` | `0xb00`--`0xb05` | 6 | 6 | 0 |
| `0x47720` | `0xc00`--`0xc04` | 5 | 5 | 0 |
| `0x476e8` | `0xd00`--`0xd0d` | 14 | 14 | 0 |

234 opcodes, 211 implemented, 23 unsupported.

**Scope.** This settles only opcodes that fall inside a table range. An opcode
*outside* every range is resolved by the compare tree and is not decided by this
sweep -- `0x100` `CH_START` and `0x101` `CH_STOP` are outside every table and are
obviously implemented, since the driver starts a channel with them on every
stream. Do not read "absent from the tables" as "unsupported"; trace the tree.
Traced individually, `0xa00` `COLOR_SATURATION_GET` *is* unsupported: for it the
tree falls through to the `0x800` preamble at `0x4787e`, where
`0xa00 - 0x800 = 0x200` exceeds the count and branches to `0x4996c`. The Apple
`0x8xxx`/`0xcxxx` commands the driver uses are likewise compare-tree cases, not
table entries.

### Why this sweep can be trusted

It reproduces the hand-derived results already in this file, and it agrees with
hardware:

- all four GETs previously found unsupported -- `0xa0a` sharpness, `0xa0c` noise
  reduction, `0xa0e` chroma suppression, `0xa1a` DRC -- come out unsupported;
- all ten standard-dispatcher GETs in "Confirmed read-only command surface"
  come out implemented, at the exact handler addresses recorded there
  (`0x499ec`, `0x49b06`, `0x49b58`, `0x49ede`, `0x49f40`, `0x49f7c`, `0x49fbe`,
  `0x4a000`, `0x4a7ae`, `0x497a6`) -- fourteen independent agreements;
- of the 68 `CISP_CMD_*` opcodes `fthd_isp.c` actually sends, every one that
  falls inside a table is marked implemented. Zero contradictions. These are
  commands that demonstrably work on the MacBookAir7,2, so a table entry
  claiming otherwise would have falsified the method.

### Newly settled: unsupported on this firmware

These carry upstream names but reach `0x4996c`. Sending one gets an
unsupported-command response, so none is a candidate for anything:

`0x113` `RAW_FRAME_PROCESS_GO`; `0x210`/`0x211` AE noise-reduction control
param GET/SET; `0x213`/`0x214` AE pre-frame-rate GET/SET; `0x215`/`0x216` AE
red-eye param GET/SET; `0x21b` AE strobe param GET; `0x21d`/`0x21e` AE window
param GET/SET; `0x302`/`0x303` AWB window param GET/SET; `0x309`/`0x30a` AWB
CCM warmup matrix SET/GET; `0x30b` AWB 2nd-gain adaptive thresholds SET;
`0x408`/`0x409` AF window param GET/SET; `0xa02` tone-curve custom GET;
`0xa08` scaler sharpness GET; `0xa0a`, `0xa0c`, `0xa0e`, `0xa1a` as above.

Two consequences worth stating. AE and AWB metering-*window* configuration does
not exist on this firmware at all, so the spatial-weighting question left open
by the metering-mode harness cannot be answered by programming a window --
`0x8206` mode selection is the only lever. And `0xa07` scaler sharpness joins
`0xa09`/`0xa0b`/`0xa0d`/`0xa19` as a setter with no readback: every
image-processing setter this firmware implements is write-only, so none of them
can be restored except by a firmware reload.

### Newly settled: implemented, with no driver readback

Implemented GET handlers the driver does not currently use. This is the list
rule 4 ("add GET support first") can draw on; each still needs its response
layout recovered before it is worth wiring up:

| Opcode | Name | Handler |
|---|---|---|
| `0x105`/`0x106` | camera config current / camera config GET | `0x482f2` / `0x483a4` |
| `0x10d` | channel info GET | `0x4866a` |
| `0x119`/`0x11a` | camera MIPI freq current / MIPI frequency GET | `0x488f8` / `0x48916` |
| `0x11d` | ISO params GET | `0x48988` |
| `0x11e`/`0x11f` | camera pixel freq current / pixel frequency GET | `0x489ae` / `0x489cc` |
| `0x121` | camera error-count GET | `0x48a0c` |
| `0x205` | AE clip GET | `0x49a38` |
| `0x207`/`0x209` | AE frame-rate maximum / minimum GET | `0x49a7c` / `0x49ac2` |
| `0x212` | AE param GET | `0x49bcc` |
| `0x217`/`0x219` | AE speed / AE stability GET | `0x49c1a` / `0x49c5e` |
| `0x223` | AE target GET | `0x49dc6` |
| `0x228` | AE stability-to-stable GET | `0x49e9e` |
| `0x236` | AE mode GET | `0x4a0ee` |
| `0x30d` | AWB 2nd gain GET | `0x4a9b4` |
| `0x501` | sensor NVM GET | `0x49702` |
| `0x507`/`0x508` | per-module LSC info / LSC GET | `0x497d2` / `0x497f0` |
| `0x800` | crop GET | `0x478a2` |
| `0x805`/`0x807`/`0x808` | colour calibration data / ideal / abs GET | `0x49360` / `0x493ca` / `0x49400` |
| `0xa22` | colour LSC table GET | `0x49110` |
| `0xb00` | output config GET | `0x47752` |

### Layouts recovered from the sweep

Three handlers were disassembled far enough to state a response layout. All
offsets are from the start of the complete command, as elsewhere in this file.

**`0x800` crop GET** (`0x478a2`) writes eight consecutive words, two rectangles,
straight out of the channel context:

```text
+0x0c..+0x18   ctx+0xd0, +0xd4, +0xd8, +0xdc
+0x1c..+0x28   ctx+0xb0, +0xb4, +0xb8, +0xbc
```

The driver's `CISP_CMD_CH_CROP_SET` sends one four-word rectangle, so the GET
returns two of them -- most plausibly the requested rectangle and the geometry
the ISP actually latched, though which group is which is not yet established.
This is directly relevant to the far-corner crop starvation in DOWNSTREAM.md:
it is a way to ask what the ISP did with the rectangle without needing the
firmware's own log, and it is read-only.

**`0x30d` AWB 2nd gain GET** (`0x4a9b4`) loads three destination pointers,
`+0x0c`, `+0x10` and `+0x14`, and calls a vtable entry at `ctx.obj+0x70`. Three
words of gain, not the two an R/B reading would predict.

**`0x207`/`0x209` AE frame-rate maximum/minimum GET** (`0x49a7c`, `0x49ac2`)
share a helper at `0x470d8`, selected by its third argument (`1` maximum, `0`
minimum), and store a single `u32` at `+0x0c` (`0x49f74` and `0x4aad8`). Both
first test a channel-context field at `+0x98` against `0xffff` and take a
different, non-value path when it matches, so `0xffff` is a not-set sentinel
and a readback has to be prepared for the sentinel case.

Note that `0x203` and `0x20b` reach their responses through `0x4a722`, which is
nothing but `blx r2` on a function pointer taken from the channel context. Their
widths are therefore a runtime vtable decision and are *not* recoverable from
the dispatcher alone -- the layouts recorded for them earlier in this file rest
on the paired-setter reasoning, not on this sweep.

### First hardware run of the swept readbacks (2026-08-18)

MacBookAir7,2, kernel `7.0.0-29-generic`, DKMS build, warm indoor light.
`tests/hw-validate.sh --only readbacks` passed every check with no firmware,
channel-stop, IOMMU or DMAR fault, and the stream stayed live through all of
them (`/tmp/facetimehd-hw-validate-20260818-202422.log`):

| Readback | Raw result |
|---|---|
| `ae_frame_rate_max_raw` | `7672` |
| `ae_frame_rate_min_raw` | `7672` |
| `awb_2nd_gain_raw` | `4096 4096 4096` |
| `crop_raw` | `0 0 1280 720` / `0 0 1280 720` |

The previously established readbacks were unchanged in the same run - sensor
temperature `-1`, AE bias `256/0`, gain cap `8192/256`, AE integration maximum
`33`, sensor integration `38..1000000`, metering mode `3` - with AWB CCT at
`2785`, consistent with the warm light.

**The frame-rate window is `29.97` fps in Q8.8, and it is pinned.** `7672 / 256`
is `29.96875`, and NTSC `30000/1001` is `29.97003`, which in Q8.8 truncates to
exactly `7672`. That is the rate the decimation measurements already recorded
for this sensor (29.95-29.97 at divisor 1). Two conclusions follow. The Q8.8
reading previously described as "consistent with but not proved" by the gain
values now has an independent corroboration on a quantity whose true value was
measured by a different method entirely. And minimum equal to maximum means the
AE frame-rate window is clamped to the sensor's single rate, which is direct
evidence for what DOWNSTREAM.md, "Frame-rate selection", concluded behaviourally:
this window is not a usable rate control. Neither handler took its `0xffff`
sentinel path, so the not-written case remains untested.

**AWB second gain is not a live measurement.** All three words read exactly
`4096` while the CCT estimate reported `2785`, which is markedly warm light: a
live white-balance gain triple cannot be equal on all three channels under an
illuminant that far from neutral. The value is most plausibly unity in a
fixed-point format where `4096` is `1.0`, left at its default. The dispatcher
sweep supports that reading - `0x30c` AWB 2nd-gain *manual* is implemented
while `0x30b` its adaptive thresholds is not - which describes a manual-only
stage that nothing is currently driving. This closes it as a candidate for a
second read-only V4L2 control: unlike `awb_cct_estimate`, there is no evidence
it measures anything. It stays a debugfs readback.

**Crop GET returns the right geometry, and does not yet disambiguate.** Both
rectangles read `0 0 1280 720`, matching the full-array default the driver had
programmed, in the `(left, top, right, bottom)` form the setter sends. That
confirms the eight-word layout, the offsets and the encoding. It does **not**
say which group is the request and which is what the ISP latched, because at
the default rectangle they agree - and agreeing is what they should do when the
ISP accepted the geometry unchanged. Separating them needs a rectangle the ISP
does *not* honour verbatim, which is exactly the far-corner case that starves
the stream. That is what the opt-in `crop-geometry` section exists to sample.

### What the two crop rectangles are (2026-08-18)

`tests/hw-validate.sh --only crop-geometry` on the same MacBookAir7,2, sampling
`crop_raw` from a live stream with a 640x360 output on the 1280x720 array
(`/tmp/facetimehd-hw-validate-20260818-203222.log`). Values are
`(left, top, right, bottom)`, the form the setter sends:

| Rectangle set | First group | Second group | Frames |
|---|---|---|---|
| full array | `0 0 1280 720` | `0 0 1280 720` | streaming |
| `+8+8` | `8 8 648 368` | `0 0 1280 720` | streaming |
| centred | `320 180 960 540` | `0 0 1280 720` | streaming |
| bottom-right corner | `640 360 1280 720` | `0 0 1280 720` | **none** |
| top-right corner | `640 0 1280 360` | `0 0 1280 720` | **none** |

The last two rows come from the repeat run with the harness fixed
(`/tmp/facetimehd-hw-validate-20260818-204049.log`), where a runtime-PM
firmware reload between rectangles let the second corner be reached at all.

**The first group is the active crop; the second is the full sensor array.**
The first tracked every rectangle exactly, and the second never moved off
`0 0 1280 720` - the array bounds - across four different crops. So the words
at channel-context `0xd0..0xdc` are the current crop and those at `0xb0..0xbc`
are the sensor rectangle. They agreed in the readbacks run only because the
crop was the full array at the time, which made the two indistinguishable.

**This retracts the hope that crop GET could root-cause the starving
rectangle.** The earlier reading of this command - two rectangles, plausibly
"requested" and "what the ISP latched" - was wrong in the half that mattered.
The first group merely echoes the geometry in effect and the second is a
constant, so neither can show a rectangle being silently adjusted, and the
command carries no differential information about why one rectangle starves.
The firmware's own log at `dyndbg=+p` is again the route to that question. What
crop GET *is* good for is confirming from the ISP's side that a crop took
effect, and reading the sensor array bounds without inferring them.

**Both far corners starve, and firmware stored both rectangles exactly.** With
a firmware reload forced between them, `+640+360` and `+640+0` each returned
its own rectangle from crop GET while delivering no frames at all: the channel
started, so the GET answered, and the stream then sat in `vb2_wait_for_done_vb`.
That is a useful negative. The ISP is not rejecting the geometry and not
quietly adjusting it - it holds precisely what was asked for and still produces
nothing, so the fault is downstream of crop programming rather than in it.

It also moves the "which rectangle triggers it" question, twice. The two
starving corners share `left = sensor_width - output_width` (`640`) and differ
in `top` (`360` and `0`), so the top is not the variable - which contradicts
the earlier record that `+640+0` streamed while `+640+360` starved. That run
had no recovery between cases; this one reloads firmware after each starve, so
it is the more trustworthy.

A flush right edge then looked like the trigger, and the `nearcorner` case was
added to test it: `left = 632`, whose right edge at `1272` is *not* flush with
the `1280` array. **It starved too**
(`/tmp/facetimehd-hw-validate-20260818-204531.log`), which falsifies the flush
edge outright. It also contradicts the older note that a left eight pixels
lower streams normally - another observation from a run without recovery.

The left-offset sweep then located the boundary
(`/tmp/facetimehd-hw-validate-20260818-205545.log`). With a 640-wide crop on
the 1280-wide array, at a fixed top:

| left | right edge | Result |
|---:|---:|---|
| `0` (full array, 1280 wide) | `1280` | streaming |
| `8` | `648` | streaming |
| `240` | `880` | streaming |
| `320` | `960` | streaming |
| `400` | `1040` | starved |
| `480` | `1120` | starved |
| `560` | `1200` | starved |
| `632` | `1272` | starved |
| `640` | `1280` | starved |

**The boundary is between left `320` and left `400`.** Two more readings die
here. `full`, `topleft`, `midoffset`, `240` and `320` streamed *consecutively
on one firmware load* before `400` starved, so "the first far-offset rectangle
after a firmware load starves" is finished - five far-from-trivial rectangles
preceded the first starve without a reload between them. And the right edge
alone is not the trigger either: the full array ends at `1280` and streams
while a 640-wide crop ending at `1280` starves, so the same right edge does
both depending on the width.

What is left is a limit on the left offset, and `320` is a suspicious value for
it: `(1280 - 640) / 2` is exactly `320`, the **centred** position. Every
rectangle that streamed sits at or left of centre and every one that starved
sits right of it. So:

- **A.** `left` may not exceed `(sensor_width - crop_width) / 2` - the crop may
  be centred or left of centre, never right of centre.
- **B.** `left` may not exceed a fixed limit somewhere in `320..400`,
  independent of the crop width.

Both fit every measurement so far, because every rectangle tested has been 640
wide, which makes the two coincide. A *narrower* crop separates them: a
320-wide crop centres at left `480`, past anything a 640-wide crop could
stream. Under A it streams there; under B it starves. The section now runs two
phases - a fine walk just past centre at 640 wide, then the same probe at 320
wide - which decides it and pins the boundary at the same time.

That run also exposed a defect in the harness rather than the driver. The
section judged channel health with `capture_ok()`, which tests only
`v4l2-ctl`'s exit status - and `v4l2-ctl` exits 0 when `VIDIOC_STREAMON` fails.
So it reported no wedge while the channel was plainly dead, and the operator
saw a bare warning with no cause. It now judges health by whether a whole frame
arrived, restores a known-good rectangle before testing recovery so it measures
the channel rather than the geometry just set, and reports for every rectangle
whether frames actually flowed. This is the same trap recorded under "Pixel
formats": an exit status is not evidence that a capture happened.

### Reproduction

```text
r2 -q -2 -a arm -b 16 -e cfg.bigendian=false -c 'pd 8 @ 0x4826e' firmware.bin
arm-none-eabi-objdump -D -b binary -m arm -EL -M force-thumb \
    --start-address=0x47530 --stop-address=0x47640 firmware.bin
```

Scan for the halfword pair `E8DF` / `F0.x`, keep the sites whose preceding
instructions branch to `0x4996c`, read `<class base>` from the `subw` and the
entry count from the `cmp`, then decode `table_base + 2 * entry` per entry.


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

## Semi-planar output: NV12, not NV16

Output-format code 0 was not invented by the 2026 feature patch; it existed in
the upstream driver in 2015, where a comment described it only as "plane 0 Y
plane 1 UV". Upstream commit `d57b16fc6438` disabled it with the note that
multiplanar support was missing, and it remains disabled in upstream
`364b1c663583`. The old code modelled it as two vb2 planes while using the
single-planar `V4L2_BUF_TYPE_VIDEO_CAPTURE` API and reported only
`width * height` bytes per plane.

Nothing in that comment gave the format a chroma sampling. Every later reading -
upstream's, this fork's, and this document's earlier revision - supplied 4:2:2
from the format's assumed name and called it NV16. **Hardware says 4:2:0.**

Capturing through code 0 on the MacBookAir7,2 and mapping the frame row by row:

| Region | Bytes | Content |
|---|---:|---|
| rows 0-719 | 921,600 | luma, complete |
| rows 720-1079 | 460,800 | chroma, mean 128.3 |
| rows 1080-1439 | 460,800 | never written, all zero |

360 chroma rows for a 720-row frame is 4:2:0. Split into components the chroma
gives Cb 122.3 and Cr 135.3, against Cb 122.5 and Cr 135.4 from a YUYV capture
of the same scene seconds later; luma agrees at 93.1 against 92.9. The correct
single-planar layout is therefore:

```text
bytesperline = width
sizeimage    = width * height * 3 / 2
ISP addr0    = mapped buffer base
ISP addr1    = mapped buffer base + width * height
```

The driver's IOMMU allocator gives the scatterlist one contiguous ISP
virtual-address range, so the chroma plane needs no mapping of its own.

One field was a known unknown and is now resolved. `x2` in
`CISP_CMD_CH_OUTPUT_CONFIG_SET` is the **destination row stride in bytes**, not
the "chroma size?" upstream guessed at. Upstream hardcoded `width * 2`, which
for the packed formats is simultaneously a correct stride and an unremarkable
constant, so nothing distinguished the two readings.

The semi-planar format distinguished them. With `width * 2` still being sent for
a one-byte-per-pixel luma plane, hardware wrote luma rows 2560 bytes apart into
a buffer laid out for 1280: exactly 50% of the luma rows came back zero, in a
strict every-other-row pattern. No IOMMU fault occurred, because `sizeimage`
still covered everything written - the predicted "bounded, loud" failure was in
fact silent, because the ISP skips rows rather than overrunning. The driver now
passes `bytesperline`, which leaves the packed formats byte-for-byte unchanged.

Two earlier claims in this file are withdrawn by the above. NV12 was said to be
unidentifiable and dangerous to guess, on the grounds that sizing a buffer at
1.5 bytes per pixel while the ISP wrote 4:2:2 at 2 would overrun the mapping.
The code is identified - it is 0 - and the error ran the other way: sizing for
4:2:2 over-allocated and left a tail unwritten, which cannot overrun anything.

The earlier hardware report did **not** validate the format despite recording a
pass: it was absent from `ENUM_FMT`, `S_FMT` silently coerced the fourcc to
YUYV, both formats had the same total byte count, and the test checked only size
and capture. `tests/hw-validate.sh --only nv12` is built around each half of
that mistake and around the stride failure above: it re-reads `G_FMT` and
requires the fourcc to survive, checks `bytesperline` and `sizeimage`, counts
blank luma rows, inspects the planes separately at their 4:2:0 extents, and
compares chroma against a YUYV capture of the same scene rather than an absolute
threshold.

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
   On the MacBookAir7,2 there is nothing to establish: see the sentinel note
   below.
8. Do not advertise a pixel format until `G_FMT` confirms the fourcc survives
   and captured luma/chroma plane contents are both plausible at the sizing
   being claimed. Implementing it behind a default-off module parameter is not
   the same as advertising it, and is what makes the test runnable. NV12 has
   since completed that path - measured 4:2:0, correct stride, and a stream at
   the 4:2:0 `sizeimage` - so its parameter was removed and it is now
   enumerated unconditionally. NV16 never will be: no output-format code
   produces it.
9. A recovered value may reach V4L2 as a **read-only** control once its meaning
   is supported by hardware evidence. `v4l2_ctrl_handler_setup()` skips
   read-only controls, so such a control cannot replay a firmware SET - which is
   the mechanism behind the lockups, and the reason rule 1 exists.
   `FTHD_CID_AWB_CCT_ESTIMATE` is the first of these. Use a driver-private CID
   unless the standard control means exactly the same thing; a measurement
   published under a CID that means a set point is a wrong answer with a
   familiar name.

## Open questions

- AE-bias encoding, units, valid range, and tag semantics.
- AWB-CCT manual-set second-word/tag semantics. The GET value strongly tracks
  kelvin on the MacBookAir7,2 and is now published as the read-only
  `awb_cct_estimate` V4L2 control; what remains open is cross-model confirmation
  of the unit, and the manual setter's second word, which is why there is a
  readback and no way to write one.
- The four packed fields used by AWB first-gain manual.
- The first halfword and supported pattern indices for sensor test pattern.
- Integration-time and gain units/ranges, and the correct atomic manual-exposure
  sequence (the firmware also has manual-mode and combined integration/gain
  opcodes that may be more appropriate than collapsing two gain caps). The
  dispatcher sweep confirms `0x22b` AE manual-mode set and `0x236` AE mode get
  are both implemented on this firmware, so that alternative is real rather
  than hypothetical; neither payload has been recovered yet.
- Meanings and safe combinations of the three chroma-suppression bytes.
- Whether any sensor *other* than this one returns something other than the `-1`
  unavailable sentinel, and its scale if so. This is closed for the
  MacBookAir7,2: `-1` came back cold, after ten minutes of continuous streaming
  and under every sampled lighting condition, and a physical scale would have
  moved with die temperature over that stream. The driver names the value
  `FTHD_SENSOR_TEMPERATURE_NONE` and reports it as `-1 (unavailable)` rather
  than inviting calibration of a constant.
- Nothing remains open about the semi-planar format's layout: code 0 is NV12,
  measured. What is untested is the driver streaming with `sizeimage` at the
  4:2:0 size, since the measurements came from an over-sized buffer.
- Why one far-offset crop rectangle starves the stream and wedges the channel.
  The ISP does honour a non-zero `x1`/`y1` - that part is answered - but which
  rectangle triggers the starvation is not pinned down. An earlier reading, that
  it required `x1 = sensor_width - width` together with `y1 = 0`, was falsified
  by the root run, where `+640+360` starved while `+640+0` streamed; see
  DOWNSTREAM.md, "Frame-rate decimation and cropping", which is authoritative on
  this. The driver's log was not readable in the session that found it; a SIF or
  channel-start error at `dyndbg=+p` is the obvious next evidence, and would say
  whether firmware rejected the geometry outright. The dispatcher sweep adds a
  second, cheaper route: `0x800` crop GET is implemented and returns two
  four-word rectangles, so the geometry the ISP actually latched can be read
  back without the firmware log, through a read-only command.
- Per-frame spacing under decimation. The mean rate is now measured and correct
  at every divisor, but `hw-validate.sh` checks only a coarse bunching floor, so
  uneven spacing at the right average would still pass.
