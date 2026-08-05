#!/usr/bin/env bash
#
# FaceTime HD Camera Driver Uninstaller
#
# Removes every DKMS registration of the driver (whatever version it is), the
# source tree, and the firmware. It also disables mbpfan.service if
# macbook-tune.sh enabled it.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

MODULE_NAME=facetimehd
STATE_DIR=/var/lib/facetimehd

ASSUME_YES=0
KEEP_TUNING=0

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

  -y, --yes          Do not prompt for confirmation.
      --keep-tuning  Leave mbpfan enabled.
  -h, --help         Show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)      ASSUME_YES=1 ;;
        --keep-tuning) KEEP_TUNING=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             error "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

require_root

warn "This removes the FaceTime HD camera driver and firmware from this system."
confirm "Continue?" || { info "Cancelled."; exit 0; }

# ---------------------------------------------------------------------------
# Kernel module
# ---------------------------------------------------------------------------

step "Unloading the kernel module"
if lsmod | grep -q "^${MODULE_NAME}\b"; then
    if modprobe -r "$MODULE_NAME" 2>/dev/null; then
        ok "unloaded"
    else
        warn "Could not unload $MODULE_NAME - it is probably in use by an open"
        warn "camera application. Close it, or finish the removal after a reboot."
    fi
else
    info "not loaded"
fi

# ---------------------------------------------------------------------------
# DKMS
# ---------------------------------------------------------------------------

# Versions are discovered, never hardcoded: upstream's PACKAGE_VERSION has
# already moved from 0.1 to 0.7.0.1 and will move again.
dkms_installed_versions() {
    dkms status -m "$MODULE_NAME" 2>/dev/null |
        sed -n -e "s|^${MODULE_NAME}/\([^,]*\),.*|\1|p" \
               -e "s|^${MODULE_NAME}, \([^,]*\),.*|\1|p" |
        sort -u
}

step "Removing DKMS registrations"
if have dkms; then
    found=0
    while read -r ver; do
        [ -n "$ver" ] || continue
        found=1
        info "dkms remove $MODULE_NAME/$ver --all"
        dkms remove -m "$MODULE_NAME" -v "$ver" --all >/dev/null 2>&1 ||
            warn "dkms remove reported an error for $MODULE_NAME/$ver"
    done < <(dkms_installed_versions)
    if [ "$found" -eq 1 ]; then ok "DKMS registrations removed"; else info "none registered"; fi
else
    info "dkms is not installed"
fi

step "Removing the driver source"
removed_src=0
# facetimehd-driver is where releases before 1.1.0 put the tree.
for d in /usr/src/"${MODULE_NAME}"-* /usr/src/facetimehd-driver; do
    [ -d "$d" ] || continue
    rm -rf -- "$d"
    ok "removed $d"
    removed_src=1
done
if [ "$removed_src" -eq 0 ]; then info "no source tree found"; fi

# ---------------------------------------------------------------------------
# Firmware
# ---------------------------------------------------------------------------

step "Removing the firmware and calibration files"
removed_fw=0
# On a usr-merged system these two are the same directory, so the second pass
# finds nothing left to do and this costs one stat. Not short-circuited with a
# break, because on a system that is *not* usr-merged they are two real
# directories and stopping after the first would leave firmware behind - which
# the verification below, going through firmware_root(), would not notice.
for base in /usr/lib/firmware /lib/firmware; do
    d="$base/$MODULE_NAME"
    [ -d "$d" ] || continue
    rm -rf -- "$d"
    ok "removed $d"
    removed_fw=1
done
if [ "$removed_fw" -eq 0 ]; then info "no firmware found"; fi

# ---------------------------------------------------------------------------
# Leftovers
# ---------------------------------------------------------------------------

step "Cleaning up module files"
find /lib/modules -name "${MODULE_NAME}.ko*" -delete 2>/dev/null || true
find /lib/modules -name 'bcwc_pcie.ko*' -delete 2>/dev/null || true
# Written by DKMS from upstream's MODULES_CONF ("blacklist bdc_pci"); dkms
# remove usually takes it with it, but not if the registration was already gone.
rm -f -- "/etc/modprobe.d/${MODULE_NAME}-dkms.conf"

step "Updating module dependencies"
depmod -a

# ---------------------------------------------------------------------------
# Fan support
# ---------------------------------------------------------------------------

# Delegated rather than reimplemented: whether mbpfan.service was enabled by
# this project or was already running before it lives in exactly one place.
if [ "$KEEP_TUNING" -eq 0 ]; then
    step "Disabling mbpfan, if this project enabled it"
    if [ -x "$SCRIPT_DIR/macbook-tune.sh" ]; then
        "$SCRIPT_DIR/macbook-tune.sh" --revert --yes ||
            warn "macbook-tune.sh --revert reported an error; check $STATE_DIR."
    elif [ -e "$STATE_DIR/mbpfan.enabled-by-us" ]; then
        warn "macbook-tune.sh is missing, so mbpfan.service was left enabled."
        warn "Disable it yourself: sudo systemctl disable --now mbpfan.service"
    fi
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

step "Verifying removal"
clean=1
check() { if [ "$1" = ok ]; then ok "$2"; else bad "$2"; clean=0; fi; }

if have dkms && [ -n "$(dkms_installed_versions)" ]; then
    check bad "DKMS registration still present"
else
    check ok "no DKMS registration"
fi

if compgen -G "/usr/src/${MODULE_NAME}-*" >/dev/null || [ -d /usr/src/facetimehd-driver ]; then
    check bad "driver source still present under /usr/src"
else
    check ok "no driver source"
fi

if [ -d "$(firmware_root)/$MODULE_NAME" ]; then
    check bad "firmware still present"
else
    check ok "no firmware"
fi

if lsmod | grep -q "^${MODULE_NAME}\b"; then
    check bad "module still loaded (reboot to clear)"
else
    check ok "module not loaded"
fi

echo
if [ "$clean" -eq 1 ]; then
    info "Uninstall complete."
else
    warn "Uninstall finished with warnings; a reboot usually clears the rest."
fi
