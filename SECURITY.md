# Security policy

## Reporting

Report suspected vulnerabilities through GitHub's private advisory form:
<https://github.com/ravvle/facetimehd/security/advisories/new>. If that is
unavailable, open a regular issue asking for a private contact and leave the
details out of it.

Please include the MacBook model, distribution, kernel version and the output of
`./scripts/collect-diagnostics.sh`.

## What is in scope

This project installs a kernel module and downloads firmware, so the interesting
surface is small but real:

- **The driver** (`src/facetimehd/`) parses data supplied by the camera's
  firmware — channel descriptors, ring entries, command responses and buffer
  returns — inside the kernel. A firmware image that could get the driver to
  read or write outside a mapping is in scope. The driver validates these
  structures deliberately; see DOWNSTREAM.md, "Safety and correctness".
- **Firmware extraction** (`scripts/extract-firmware.sh`) downloads from Apple
  over HTTPS and SHA-256-verifies both the containing kext and the extracted
  image before installing anything. A path that installs unverified bytes, or a
  way to make the verification pass on the wrong data, is in scope.
- **The installers** run as root. Anything that lets an unprivileged user
  influence what they write, or that leaves world-writable state behind, is in
  scope.

## What is not

- **The Apple firmware itself.** It is proprietary, unmodifiable and not
  redistributed by this project. Bugs inside it cannot be fixed here.
- **Secure Boot key handling.** `install.sh --enroll-mok` generates a Machine
  Owner Key and asks the user to enrol it. That key can sign any kernel module
  on the machine, which is inherent to how module signing works and is why the
  flag is opt-in rather than automatic. Uninstalling does not remove the key —
  it may be signing other modules by then.
- **Kernel bugs reachable only with root**, which is already enough to load a
  module of one's choosing.

## Supported versions

Only the current `master`. This is a small project with no release branches;
fixes land there and reach users through a `git pull` and a re-run of
`install.sh`.
