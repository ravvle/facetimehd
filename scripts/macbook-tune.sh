#!/usr/bin/env bash
#
# MacBook Fan Support
#
# Under macOS the SMC runs its own fan curve in firmware; Linux's `applesmc`
# exposes only a very conservative floor, so these chassis sit at 90+ C and
# thermally throttle with the fans barely spinning. `mbpfan` is a small daemon
# that reads `coretemp` and drives the fans itself, with a fan curve of its
# own that is fine as shipped, so this script does not configure it - it only
# makes sure the package is installed and its service is running.
#
# The internal keyboard needs nothing here: `hid_apple` ships in the kernel on
# every distribution this project supports and already loads itself.
#
# This script is optional and independent of install.sh: the camera works
# without it, and it works on a Mac with no camera driver installed.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

STATE_DIR=/var/lib/facetimehd-ubuntu-macbook
MBPFAN_ENABLED="$STATE_DIR/mbpfan.enabled-by-us"

ASSUME_YES=0
ACTION=apply
DO_FAN=1

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

  -y, --yes       Do not prompt for confirmation.
      --skip-fan  Do not install or enable mbpfan.
      --revert    Disable mbpfan.service, if this script was the one that
                  enabled it. mbpfan itself stays installed.
  -h, --help      Show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)   ASSUME_YES=1 ;;
        --skip-fan) DO_FAN=0 ;;
        --revert)   ACTION=revert ;;
        -h|--help)  usage; exit 0 ;;
        *)          error "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

require_root

# ---------------------------------------------------------------------------
# Revert
# ---------------------------------------------------------------------------

if [ "$ACTION" = revert ]; then
    step "Restoring the fan configuration"
    if [ -e "$MBPFAN_ENABLED" ]; then
        systemctl disable --now mbpfan.service >/dev/null 2>&1 || true
        rm -f -- "$MBPFAN_ENABLED"
        ok "mbpfan.service disabled"
        warn "The fans go back to the SMC's own floor, which is what made this"
        warn "machine throttle in the first place. mbpfan is still installed."
    else
        info "mbpfan was already enabled before this script touched it, or was"
        info "never enabled by it - nothing to undo"
    fi
    rmdir -- "$STATE_DIR" 2>/dev/null || true

    echo
    info "Reverted."
    exit 0
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

detect_os
step "Checking MacBook fan support"
info "Distribution: ${OS_PRETTY:-unknown}"

apple_rc=0
is_apple_hardware || apple_rc=$?
case "$apple_rc" in
    0) info "Model:        $(dmi_product_name)" ;;
    2) warn "Cannot read DMI, so this machine could not be identified. mbpfan"
       warn "assumes Apple hardware." ;;
    *) warn "This is not Apple hardware according to DMI ($(dmi_product_name))."
       warn "mbpfan drives applesmc's fan controls and does nothing useful here."
       confirm "  Continue anyway?" || { info "Cancelled."; exit 0; } ;;
esac

if [ "$DO_FAN" -eq 0 ]; then
    step "Skipping the fans (--skip-fan)"
    exit 0
fi

pkg_manager >/dev/null ||
    die "This script installs mbpfan with apt or dnf, and this system has
       neither. Install mbpfan with your own package manager yourself."

# ---------------------------------------------------------------------------
# Fans
# ---------------------------------------------------------------------------

step "Installing mbpfan"

if have mbpfan || pkg_installed mbpfan; then
    info "mbpfan is already installed"
elif ! pkg_available mbpfan; then
    # Ubuntu has it in universe and Fedora in the main repositories, but a
    # derivative may have neither. Say so plainly instead of letting the
    # package manager fail with "no match for argument: mbpfan".
    error "mbpfan is not available in this system's repositories."
    echo
    info "Upstream is https://github.com/linux-on-mac/mbpfan and it builds"
    info "with 'make && sudo make install'. Install it, then re-run this"
    info "script."
    DO_FAN=0
else
    pkg_refresh
    pkg_install mbpfan || {
        warn "Could not install mbpfan."
        DO_FAN=0
    }
fi

if [ "$DO_FAN" -eq 1 ]; then
    if [ ! -d /sys/devices/platform/applesmc.768 ] &&
       ! compgen -G '/sys/devices/platform/applesmc*' >/dev/null; then
        warn "applesmc did not attach, so there are no fan controls to drive."
        warn "mbpfan will start and find nothing to do. On a real MacBook this"
        warn "usually means the module is blacklisted - check"
        warn "'grep -r applesmc /etc/modprobe.d/'."
    fi

    step "Enabling mbpfan"
    if ! unit_exists mbpfan.service; then
        warn "No mbpfan.service unit found. mbpfan is installed, but you will"
        warn "have to start it yourself (it takes no arguments)."
    else
        # Record that we enabled it, so --revert does not switch off a daemon
        # the user was already running before this script touched anything.
        if [ "$(systemctl is-enabled mbpfan.service 2>/dev/null)" != enabled ]; then
            install -d -m 0755 "$STATE_DIR"
            : > "$MBPFAN_ENABLED"
        fi
        systemctl enable --now mbpfan.service >/dev/null 2>&1 ||
            warn "Could not enable mbpfan.service."
        if systemctl is-active --quiet mbpfan.service; then
            ok "mbpfan.service is running"
        else
            warn "mbpfan.service did not start:"
            systemctl status mbpfan.service --no-pager || true
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
info "MacBook fan support checked."
cat <<EOF

mbpfan is left at its own defaults - not reconfigured by this project. See
/etc/mbpfan.conf (man mbpfan.conf) if you want a different fan curve.

Checking it:
  systemctl status mbpfan.service
  journalctl -u mbpfan -b       # what it decided and why

Undo:
  sudo $0 --revert
EOF
