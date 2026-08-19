# Packaging

Builds a distribution package that installs the driver source and registers it
with DKMS, so the camera can be installed and removed with the system package
manager instead of a shell script.

```bash
./packaging/build-deb.sh        # facetimehd-dkms_<version>_all.deb
./packaging/build-rpm.sh        # facetimehd-dkms-<version>-1.noarch.rpm
```

Both write into `packaging/out/`.

## What the packages do and deliberately do not do

They install `src/facetimehd/` under `/usr/src/facetimehd-<version>` and run
`dkms add`/`build`/`install` from the maintainer scripts. That is the whole
driver half of `scripts/install.sh`, expressed the way each package manager
expects it.

They do **not** download the Apple firmware. The firmware is proprietary and
cannot be redistributed, so it can only come from Apple at install time — and a
package post-install script that reaches the network breaks offline installs,
image builds and any environment where the package manager is not expected to
have internet access, with a failure that is very hard to report usefully.

So the packages install `facetimehd-firmware-install`, a wrapper the user runs
once afterwards:

```bash
sudo facetimehd-firmware-install
```

The post-install script says so in as many words, because a driver with no
firmware loads fine and produces no image — the least debuggable possible
outcome.

They also do not touch Secure Boot. DKMS signs modules with whatever key the
system has configured; enrolling one needs a password typed at a console and a
reboot, neither of which a package manager can do. `install.sh --enroll-mok`
remains the way to set that up.

## Which to use

The shell installer and the packages do the same thing to the driver. Use the
packages if you want the driver tracked by `dpkg`/`rpm`, or if you are building
an image. Use `scripts/install.sh` if you want the guided path that also
handles firmware, calibration and Secure Boot in one run.

## Versioning

The package version is `PACKAGE_VERSION` from `src/facetimehd/dkms.conf`.
Unlike `scripts/install.sh`, no source fingerprint is appended: the fingerprint
exists so a *rebuild from an edited working tree* cannot reuse a version, and a
package is a fixed artefact with a version already in its filename. Bump
`PACKAGE_VERSION` when the driver changes.
