#!/usr/bin/env bash
#
# FaceTime HD Camera Driver Installer
#
# Builds and registers the facetimehd (BCM1570) driver with DKMS and installs
# the Apple camera firmware, on Ubuntu 22.04 LTS through 26.04 LTS, Fedora and
# AlmaLinux 10 (and the other RHEL 10 rebuilds).
#
# The maintained driver source is included under src/, so installing needs no
# access to GitHub. The only remaining network access is firmware extraction
# (scripts/extract-firmware.sh), which downloads from Apple's servers because
# that firmware is proprietary and cannot be redistributed.
#
# Nothing here pins a kernel version or a driver version: the version is read
# from the maintained dkms.conf, and DKMS rebuilds on every kernel
# update. See CLAUDE.md, "Deliberate decisions", for why it is built this way.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

DRIVER_SRC="${FTHD_DRIVER_SRC:-$REPO_DIR/src/facetimehd}"
FIRMWARE_EXTRACTOR="${FTHD_FIRMWARE_EXTRACTOR:-$SCRIPT_DIR/extract-firmware.sh}"
MODULE_NAME=facetimehd

ASSUME_YES=0
FORCE_REBUILD=0
SKIP_FIRMWARE=0
SKIP_HW_CHECK=0

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

  -y, --yes            Do not prompt for confirmation.
      --force          Rebuild and reinstall even if already up to date.
      --skip-firmware  Do not touch the firmware (it is already installed).
      --skip-hw-check  Install even if no FaceTime HD camera is detected.
  -h, --help           Show this help.

Environment:
  FTHD_DRIVER_SRC      Driver source directory (default: src/facetimehd).
  FTHD_FIRMWARE_EXTRACTOR
                       Firmware extractor (default: scripts/extract-firmware.sh).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)        ASSUME_YES=1 ;;
        --force)         FORCE_REBUILD=1 ;;
        --skip-firmware) SKIP_FIRMWARE=1 ;;
        --skip-hw-check) SKIP_HW_CHECK=1 ;;
        -h|--help)       usage; exit 0 ;;
        *)               error "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

require_root

# ---------------------------------------------------------------------------
# 1. Environment checks
# ---------------------------------------------------------------------------

detect_os
step "Checking the system"
info "Distribution: ${OS_PRETTY:-unknown}"
info "Kernel:       $(uname -r)"

if is_debian_like; then
    PKG_FAMILY=debian
elif is_rpm_like; then
    PKG_FAMILY=rpm
else
    # Not a distribution we recognise by name, but if it has one of the two
    # package managers the package names are very likely to match anyway.
    case "$(pkg_manager 2>/dev/null || true)" in
        apt) PKG_FAMILY=debian ;;
        dnf) PKG_FAMILY=rpm ;;
        *)   die "Unrecognised distribution with neither apt-get nor dnf.
       Install build-essential/gcc, make, dkms, kernel headers, cpio, curl, xz
       and kmod yourself, then re-run with the dependency step already done." ;;
    esac
    warn "Unrecognised distribution; assuming $PKG_FAMILY package names because
       $(pkg_manager) is present. Check the package list if this step fails."
fi

if [ "$SKIP_HW_CHECK" -eq 0 ]; then
    hw_rc=0
    has_facetimehd_hardware || hw_rc=$?
    case "$hw_rc" in
        0) ok "FaceTime HD camera found on the PCI bus ($FTHD_PCI_ID)" ;;
        2) warn "lspci is not installed yet; skipping the hardware check." ;;
        *) error "No Broadcom 1570 device ($FTHD_PCI_ID) on the PCI bus."
           error "This driver only supports the PCIe FaceTime HD camera in"
           error "2013-2015 Intel MacBooks. Later models use a USB camera"
           error "(driven by uvcvideo) or an Apple Silicon ISP."
           die   "Re-run with --skip-hw-check to install anyway." ;;
    esac
fi

if have mokutil && [ "$(mokutil --sb-state 2>/dev/null || true)" = "SecureBoot enabled" ]; then
    warn "Secure Boot is enabled. DKMS will sign the module with your MOK key if"
    warn "one is enrolled; otherwise the module will build but refuse to load."
    warn "See README.md -> Troubleshooting and support."
fi

# ---------------------------------------------------------------------------
# 2. Build dependencies
# ---------------------------------------------------------------------------

step "Installing build dependencies"

# Enterprise Linux (AlmaLinux, Rocky, CentOS Stream, RHEL) has no dkms of its
# own - it comes from EPEL, which is not enabled out of the box. A no-op on
# Fedora and on the Debian family.
if is_enterprise_linux; then
    info "Enterprise Linux: dkms comes from EPEL, which is not enabled by"
    info "default. Enabling it (and CodeReady Builder, which EPEL needs)."
    if ensure_epel; then
        ok "EPEL is enabled"
    else
        # Not fatal: the dependency install below is what actually discovers a
        # missing package, and it names it. Stopping here would also be wrong
        # on a system whose administrator has EPEL mirrored under another name.
        warn "Could not enable EPEL automatically. If the next step cannot find"
        warn "dkms, enable it yourself and re-run:"
        warn "    sudo dnf install epel-release && sudo dnf config-manager setopt crb.enabled=1"
    fi
fi

pkg_refresh

# curl/xz/cpio/gzip are what the firmware extractor needs; cpio in particular
# is no longer part of a default install on either family. git is deliberately
# absent - the maintained source is included, so installing needs no GitHub.
if [ "$PKG_FAMILY" = rpm ]; then
    # diffutils is what makes the rebuild-skip below work. It is Essential on
    # Debian and so never listed there, but a minimal Fedora has no diff at all
    # - without it the idempotency check silently fails open and every run
    # rebuilds from scratch. elfutils-libelf-devel is what the kernel build
    # system needs and does not pull in itself; it is in AppStream on EL10, so
    # it needs no extra repository.
    DEPS=(gcc make cpio diffutils dkms elfutils-libelf-devel gzip kmod xz)

    # curl is asked for by name only when it is actually absent. The RPM
    # families' default installs carry curl-minimal, which already provides
    # /usr/bin/curl, and 'dnf install curl' *conflicts* with it rather than
    # upgrading it - so listing curl unconditionally breaks the whole
    # dependency step on a stock AlmaLinux or Fedora system.
    have curl || DEPS+=(curl)
else
    DEPS=(build-essential cpio curl dkms gzip kmod xz-utils)
fi

pkg_install "${DEPS[@]}" || die \
    "Could not install the build dependencies: ${DEPS[*]}
       If one of those names does not exist on this distribution, install the
       equivalents yourself (a compiler, make, dkms, kernel headers, cpio, curl,
       xz, gzip and kmod) and re-run this script.
       On Enterprise Linux, dkms comes from EPEL: check that
       'dnf repolist --enabled' lists epel and crb."

# Everything above is needed to build and install the driver, so failing to get
# it is fatal. These three are not: pciutils only powers the hardware check,
# v4l-utils only the verification advice at the end, and unar only the sensor
# calibration files. They are installed the same way, but a distribution that
# does not package one of them costs a diagnostic or the camera's colours - not
# a working camera - and refusing to install over that would be wrong.
#
# unar is the realistic case. It comes from EPEL on Enterprise Linux, and EPEL
# does not rebuild every Fedora package for every EL release.
EXTRAS=()

# Queue one such package, named by the command it provides so that an already
# satisfied dependency is never handed to the package manager again. Returns
# non-zero only when the package is genuinely not available anywhere, which is
# the answer the caller acts on.
want_extra() {
    local pkg="$1" cmd="$2"
    have "$cmd" && return 0
    if pkg_available "$pkg"; then
        EXTRAS+=("$pkg")
        return 0
    fi
    warn "$pkg is not packaged for this distribution."
    return 1
}

HAVE_UNAR=1
want_extra pciutils  lspci    || true
want_extra v4l-utils v4l2-ctl || true
want_extra unar      unar     || HAVE_UNAR=0

if [ ${#EXTRAS[@]} -gt 0 ] && ! pkg_install "${EXTRAS[@]}"; then
    warn "Could not install: ${EXTRAS[*]}"
    warn "Continuing - none of these is needed to build or load the driver."
    have unar || HAVE_UNAR=0
fi

if [ "$HAVE_UNAR" -eq 0 ]; then
    warn "Without unar the sensor calibration files cannot be unpacked. The"
    warn "camera will work; its colours will be off. Install unar later and"
    warn "re-run 'sudo $FIRMWARE_EXTRACTOR --calibration-only' to fix that."
fi

# Headers for the running kernel, so we can build right now, plus whatever
# makes future kernels arrive with headers already in place so DKMS never
# silently skips a rebuild.
install_headers_debian() {
    local kver="$1" want=() pkg status

    want+=("linux-headers-$kver")

    # The headers metapackage matching each installed kernel image metapackage.
    # Deriving the name from what is actually installed handles plain, HWE and
    # OEM kernels without this script carrying a list of Ubuntu release names.
    while read -r status pkg; do
        [ "$status" = installed ] || continue
        want+=("${pkg/-image-/-headers-}")
    done < <(dpkg-query -W -f='${db:Status-Status} ${Package}\n' \
                 'linux-image-generic*' 'linux-image-oem*' 2>/dev/null || true)

    local missing=()
    for pkg in "${want[@]}"; do
        pkg_installed "$pkg" || missing+=("$pkg")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        info "Installing kernel headers: ${missing[*]}"
        pkg_install "${missing[@]}" || true
    fi
}

install_headers_rpm() {
    local kver="$1"

    # kernel-devel is versioned per kernel and several may be installed at
    # once, so ask for the exact one the running kernel needs.
    if ! pkg_installed "kernel-devel-$kver"; then
        info "Installing kernel headers: kernel-devel-$kver"
        pkg_install "kernel-devel-$kver" || true
    fi

    # ...and the unversioned name, which resolves to the newest kernel-devel in
    # the repositories. On Fedora and the rebuilds this is what keeps a
    # kernel-devel arriving alongside each future kernel, so DKMS has something
    # to build against after 'dnf upgrade'.
    pkg_install kernel-devel >/dev/null 2>&1 || true
}

KVER="$(uname -r)"
if [ "$PKG_FAMILY" = rpm ]; then
    install_headers_rpm "$KVER"
else
    install_headers_debian "$KVER"
fi

# DKMS builds against /lib/modules/<kver>/build, so that is what has to resolve.
# Its absence is the one failure worth stopping for. The two families get there
# differently, and the useful advice differs with them:
#
#   Debian/Ubuntu  linux-headers-<kver> ships the tree and the symlink together.
#   Fedora/RHEL    kernel-modules-core ships the symlink, pointing into
#                  /usr/src/kernels/<kver>, which arrives only with
#                  kernel-devel. So the symlink is normally present and
#                  *dangling* until kernel-devel is installed - which is why
#                  this tests the resolved directory rather than the link.
if [ ! -d "/lib/modules/$KVER/build" ]; then
    error "No kernel build tree at /lib/modules/$KVER/build."
    if [ "$PKG_FAMILY" = rpm ]; then
        if [ -d "/usr/src/kernels/$KVER" ]; then
            error "The headers are unpacked at /usr/src/kernels/$KVER but"
            error "/lib/modules/$KVER/build does not point at them. Reinstalling"
            error "kernel-modules-core for this kernel restores that symlink."
        else
            error "Run 'dnf install kernel-devel-$KVER'."
            error "If dnf reports no match, the repositories have already moved"
            error "past the kernel you are running: 'dnf upgrade' and reboot into"
            error "the newest installed kernel, then re-run this script."
        fi
    else
        error "Run 'apt install linux-headers-$KVER', or reboot into the kernel"
        error "whose headers you have."
    fi
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Driver source
# ---------------------------------------------------------------------------

step "Using the maintained driver source"
info "$DRIVER_SRC"
[ -f "$DRIVER_SRC/Makefile" ] || die \
    "No driver source at $DRIVER_SRC.
       If this is a git checkout, the driver sources should be present already."
# The package version comes from upstream's own dkms.conf, carried through the
# fork. Nothing here hardcodes a version number.
[ -f "$DRIVER_SRC/dkms.conf" ] || die "Driver source has no dkms.conf; cannot continue."
DRIVER_VERSION="$(sed -n 's/^[[:space:]]*PACKAGE_VERSION=["'"'"']\{0,1\}\([^"'"'"']*\)["'"'"']\{0,1\}[[:space:]]*$/\1/p' \
                      "$DRIVER_SRC/dkms.conf" | head -n1)"
[ -n "$DRIVER_VERSION" ] || die "Could not read PACKAGE_VERSION from upstream dkms.conf."

# Hash the maintained sources into the version so a source edit cannot reuse the
# DKMS version of a tree that was already built.
require_cmds sha256sum
SOURCE_FINGERPRINT="$(driver_source_fingerprint "$DRIVER_SRC")"
DRIVER_VERSION="${DRIVER_VERSION}+d${SOURCE_FINGERPRINT}"
info "Driver version: $MODULE_NAME/$DRIVER_VERSION"

DRIVER_STAGE_TMP="$(mktemp -d -t facetimehd-driver.XXXXXXXX)"
trap 'rm -rf -- "$DRIVER_STAGE_TMP"' EXIT
SRC_STAGE="$DRIVER_STAGE_TMP/source"
prepare_driver_source "$DRIVER_SRC" "$SRC_STAGE"

SRC_DIR="/usr/src/${MODULE_NAME}-${DRIVER_VERSION}"

# List every facetimehd version DKMS currently knows about. Handles both the
# "name/version," format of DKMS 3.x and the "name, version," format of 2.x.
dkms_installed_versions() {
    dkms status -m "$MODULE_NAME" 2>/dev/null |
        sed -n -e "s|^${MODULE_NAME}/\([^,]*\),.*|\1|p" \
               -e "s|^${MODULE_NAME}, \([^,]*\),.*|\1|p" |
        sort -u
}

needs_install=1
# dkms.conf is excluded because the staged copy carries the rewritten
# PACKAGE_VERSION above; every other file must match the maintained source.
if [ -d "$SRC_DIR" ] && [ "$FORCE_REBUILD" -eq 0 ] &&
   diff -rq --exclude=dkms.conf "$SRC_STAGE" "$SRC_DIR" >/dev/null 2>&1 &&
   dkms_installed_versions | grep -qx "$DRIVER_VERSION" &&
   dkms status -m "$MODULE_NAME" -v "$DRIVER_VERSION" -k "$(uname -r)" 2>/dev/null |
       grep -q installed; then
    needs_install=0
fi

if [ "$needs_install" -eq 0 ]; then
    step "Driver already installed and up to date; skipping rebuild (use --force to override)"
else
    step "Registering the driver with DKMS"

    # Drop every previously registered version, including the one we are about
    # to install, so a re-run is a clean reinstall rather than a conflict.
    while read -r ver; do
        [ -n "$ver" ] || continue
        info "Removing existing DKMS registration $MODULE_NAME/$ver"
        dkms remove -m "$MODULE_NAME" -v "$ver" --all >/dev/null 2>&1 || true
    done < <(dkms_installed_versions)

    # /usr/src/facetimehd-driver is where releases before 1.1.0 put the source.
    rm -rf -- "$SRC_DIR" /usr/src/facetimehd-driver
    mkdir -p -- "$SRC_DIR"
    cp -a -- "$SRC_STAGE/." "$SRC_DIR/"

    # DKMS insists the source directory be named PACKAGE_NAME-PACKAGE_VERSION,
    # so the staged dkms.conf has to agree with the directory we just created.
    # Only the staged copy under /usr/src is changed.
    sed -i "s|^\([[:space:]]*PACKAGE_VERSION=\).*|\1$DRIVER_VERSION|" \
        "$SRC_DIR/dkms.conf"

    dkms add    -m "$MODULE_NAME" -v "$DRIVER_VERSION"
    dkms build  -m "$MODULE_NAME" -v "$DRIVER_VERSION" -k "$(uname -r)"
    dkms install -m "$MODULE_NAME" -v "$DRIVER_VERSION" -k "$(uname -r)" --force

    ok "Module built for $(uname -r)"
fi

# AUTOINSTALL="yes" in upstream's dkms.conf plus the dkms package's own kernel
# postinst hooks are what rebuild the module on future kernel updates. Nothing
# in this project needs to run again.

# ---------------------------------------------------------------------------
# 4. Firmware
# ---------------------------------------------------------------------------

FW_DIR="$(firmware_root)/$MODULE_NAME"

if [ "$SKIP_FIRMWARE" -eq 1 ]; then
    step "Skipping firmware (--skip-firmware)"
elif [ -s "$FW_DIR/firmware.bin" ] && [ "$FORCE_REBUILD" -eq 0 ]; then
    step "Firmware already present at $FW_DIR/firmware.bin"
else
    step "Extracting the Apple camera firmware"
    cat <<'EOF'
  This is the one step that needs the network. The camera firmware is
  proprietary Apple code and cannot be redistributed, so it is the one thing
  this repository does not ship. The extractor downloads a byte range of an
  Apple-hosted OS X 10.11.5 update, pulls the firmware out of the
  AppleCameraInterface kext, and verifies the SHA-256 of both the kext and the
  extracted image against known-good values before installing it.

EOF
    if ! confirm "  Download and extract the firmware from Apple's servers now?"; then
        warn "Firmware skipped. The driver will load but the camera will not"
        warn "produce an image until you run this script again."
        SKIP_FIRMWARE=1
    fi

    if [ "$SKIP_FIRMWARE" -eq 0 ]; then
        [ -x "$FIRMWARE_EXTRACTOR" ] || die \
            "No firmware extractor at $FIRMWARE_EXTRACTOR"

        # The extractor downloads, carves out the firmware, checksum-verifies
        # both the kext and the image, and installs it. It stages everything in
        # its own mktemp directory and cleans up after itself. The checksum
        # table lives there - we keep no second copy of it.
        "$FIRMWARE_EXTRACTOR" --dest "$FW_DIR"
        [ -s "$FW_DIR/firmware.bin" ] || die "Firmware extraction reported success but $FW_DIR/firmware.bin is missing."
        ok "Firmware installed to $FW_DIR/firmware.bin"
    fi
fi

# The sensor calibration files are a separate concern from the firmware: they
# come from a different Apple download (the Windows Boot Camp driver, the only
# thing that ships them), and they fix its colours. This step runs on every
# install that has unar, but a failure here is still a warning, never fatal:
# the camera streams without them, just with the wrong colours.
if [ "$SKIP_FIRMWARE" -eq 0 ] && [ "$HAVE_UNAR" -eq 0 ]; then
    step "Skipping the sensor calibration files (no unar)"
elif [ "$SKIP_FIRMWARE" -eq 0 ]; then
    if compgen -G "$FW_DIR/*_01XX.dat" >/dev/null && [ "$FORCE_REBUILD" -eq 0 ]; then
        step "Sensor calibration files already present"
    else
        step "Extracting the sensor calibration files"
        info "A second ~1.2 MB download. Without these the camera works but"
        info "its colours are wrong."
        if "$FIRMWARE_EXTRACTOR" --calibration-only --dest "$FW_DIR"; then
            ok "Calibration files installed to $FW_DIR"
        else
            warn "Could not install the sensor calibration files."
            warn "The camera will still work; its colours will be off."
            warn "Retry later with: sudo $FIRMWARE_EXTRACTOR --calibration-only"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 5. Load and verify
# ---------------------------------------------------------------------------

step "Loading the driver"
depmod -a "$(uname -r)"

# Unload first, so a rebuild actually takes effect. When the resident module is
# pinned by an open camera application the unload fails, and the modprobe that
# follows then succeeds trivially against the *old* module - which would be
# reported as a successful load of the build we just made. Track it instead.
MODULE_STALE=0
if lsmod | grep -q "^${MODULE_NAME}\b" && ! modprobe -r "$MODULE_NAME" 2>/dev/null; then
    MODULE_STALE=1
fi

if [ "$MODULE_STALE" -eq 1 ]; then
    warn "The running $MODULE_NAME could not be unloaded - it is probably in use"
    warn "by an open camera application. The newly built module takes over at"
    warn "the next reboot."
elif modprobe "$MODULE_NAME" 2>/dev/null; then
    ok "Kernel module loaded"
else
    warn "Could not load the module now; a reboot is usually enough."
fi

step "Verifying"
rc=0

if dkms status -m "$MODULE_NAME" -v "$DRIVER_VERSION" 2>/dev/null | grep -q installed; then
    ok "DKMS: $MODULE_NAME/$DRIVER_VERSION installed"
else
    bad "DKMS module is not registered as installed"; rc=1
fi

# What matters is whether the firmware is on disk, not whether this run put it
# there: --skip-firmware means "it is already installed", so checking the flag
# rather than the file would report a failure on exactly its intended use.
if [ -s "$FW_DIR/firmware.bin" ]; then
    ok "Firmware: $FW_DIR/firmware.bin"
elif [ "$SKIP_FIRMWARE" -eq 1 ]; then
    bad "Firmware missing at $FW_DIR/firmware.bin (skipped this run)"; rc=1
else
    bad "Firmware missing at $FW_DIR/firmware.bin"; rc=1
fi

if [ "$MODULE_STALE" -eq 1 ]; then
    bad "An older $MODULE_NAME is still loaded (reboot to pick up this build)"
elif lsmod | grep -q "^${MODULE_NAME}\b"; then
    ok "Module loaded"
else
    bad "Module not loaded yet (reboot required)"
fi

if [ -e /dev/video0 ]; then
    ok "Video device present: /dev/video0"
else
    bad "No /dev/video0 yet (reboot required)"
fi

echo
if [ "$rc" -eq 0 ]; then
    info "Installation complete."
else
    warn "Installation finished with warnings - see above."
fi

cat <<EOF

Next steps:
  1. Reboot:            sudo reboot
  2. Test the camera:   v4l2-ctl --list-devices   (or open Snapshot/Cheese)
  3. Camera access:     sudo usermod -aG video \$USER   (then log out and back in)

Optional:
  Fans and keyboard:    sudo ./scripts/macbook-tune.sh
                        (makes sure mbpfan and hid_apple are installed and
                         running - neither is reconfigured)
  Troubleshooting:      README.md -> Troubleshooting and support

The module rebuilds itself on kernel updates via DKMS; there is nothing to
re-run after 'apt upgrade' or 'dnf upgrade'.
EOF
