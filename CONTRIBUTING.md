# Contributing

The most valuable contribution to this project is not code. It is a report from
a MacBook that is not a MacBookAir7,2 — see
[Hardware reports](#hardware-reports) below.

## Before you start

Read [CLAUDE.md](CLAUDE.md). It is written for AI assistants but it is the
architecture document for the repository, and its "Deliberate decisions"
section records why several things that look wrong are the way they are. A
change that reverses one of those is not automatically unwelcome, but it needs
to argue with the reasoning that is already written down.

## Hardware reports

This project has been validated in depth on exactly one machine. Everything
else in the supported range — MacBookPro11,x, MacBook8,1, the rest of the
2013–2015 line — rests on code review and on a sensor-detection path that has
only been exercised on one sensor.

If you have any other model:

```bash
sudo ./tests/hw-validate.sh          # a few minutes, one section per open item
./scripts/collect-diagnostics.sh     # one file to attach
```

Open a **Hardware report** issue with the output. A failing report is as useful
as a passing one; several entries in
[`src/facetimehd/DOWNSTREAM.md`](src/facetimehd/DOWNSTREAM.md) under "Hardware
validation status" are waiting on exactly this.

## Code

```bash
# What CI runs
shellcheck -x --source-path=SCRIPTDIR \
    setup.sh \
    scripts/install.sh scripts/uninstall.sh scripts/macbook-tune.sh \
    scripts/extract-firmware.sh scripts/collect-diagnostics.sh \
    tests/build-driver.sh tests/smoke-capture.sh tests/hw-validate.sh \
    tests/script-smoke.sh

./tests/build-driver.sh                        # every headers tree present
W=1 WERROR=1 ./tests/build-driver.sh           # warnings are errors
SPARSE=1 W=1 ./tests/build-driver.sh           # semantic checks
./tests/script-smoke.sh                        # installer/uninstaller plumbing
```

Conventions:

- Shell is `#!/usr/bin/env bash` with `set -euo pipefail`, executable, and
  shellcheck-clean.
- Everything must be idempotent, reversible, and leave the system bootable if
  interrupted.
- Commit messages are `type: brief description` — `fix:`, `feat:`, `docs:`,
  `refactor:`, `test:`, `chore:`.

### Driver changes

**A change to `src/facetimehd/` is not finished until `DOWNSTREAM.md` says
why.** The fork carries no patch headers, so that file is the entire review
record for its divergence from upstream. Describe the reasoning, not the diff.

Please also propose driver fixes upstream at
[patjak/facetimehd](https://github.com/patjak/facetimehd) where they apply
there. This fork exists because upstream is quiet, not because it is wrong.

### Guessing at firmware

Several ISP commands are exposed whose payload layouts Apple never documented.
The rule that makes that acceptable is: **a wrong guess must be refused, not
destructive.** A command payload the firmware rejects surfaces as an error from
`S_CTRL`. A wrongly sized buffer has the hardware DMA past the end of a
mapping. The first is a fine thing to ship behind a hardware-validation note;
the second is not, which is why `V4L2_PIX_FMT_NV12` is still not offered.

Anything inferred goes in DOWNSTREAM.md's "Hardware validation status" list
until hardware confirms it.

## Licensing

The whole project is GPL-2.0-only, including scripts, tests and documentation.
Derived code keeps its upstream attribution header — do not reword provenance
away.
