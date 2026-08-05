#!/usr/bin/env bash
#
# FaceTime HD Camera Setup
#
# Single entry point: asks what you want, then runs the scripts that do it.
#
#   scripts/macbook-tune.sh   mbpfan, so the fans stop throttling
#   scripts/install.sh        the camera driver + firmware (DKMS, extraction)
#
# Everything here also runs standalone - see README.md - this is only a menu
# in front of them for anyone who would rather not read it first. Each
# script's own options (--skip-firmware, --skip-fan, --revert, and so on)
# are not exposed here; run that script directly for finer control.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SCRIPT_DIR/scripts/lib/common.sh"

ASSUME_YES=0

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

  -y, --yes   Do not ask - install the driver and fan support.
  -h, --help  Show this help.

Runs scripts/macbook-tune.sh and scripts/install.sh, in that order. Each has its own
options for anyone who wants more control - see README.md, or run either
script with --help directly.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)  ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *)         error "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

require_root

cat <<'EOF'
FaceTime HD Camera Setup
========================
EOF

detect_os
info "Distribution: ${OS_PRETTY:-unknown}"

hw_rc=0
has_facetimehd_hardware || hw_rc=$?
case "$hw_rc" in
    0) ok "FaceTime HD camera found on the PCI bus" ;;
    2) info "lspci is not installed yet; the driver install will check again." ;;
    *) warn "No FaceTime HD camera found on the PCI bus. The driver install"
       warn "will ask again, and refuses by default on hardware it cannot help." ;;
esac
echo

# Asked up front rather than left to each script's own confirmation prompt,
# so a single "yes to everything" run does not still stop twice.
if [ "$ASSUME_YES" -eq 1 ]; then
    do_driver=1
    do_fan=1
else
    do_driver=1
    confirm "Install the camera driver and firmware?" || do_driver=0
    do_fan=1
    confirm "Install fan support (mbpfan, so the machine stops throttling)?" || do_fan=0
fi

if [ "$do_driver" -eq 0 ] && [ "$do_fan" -eq 0 ]; then
    info "Nothing selected - nothing to do."
    exit 0
fi

rc=0
args=()
[ "$ASSUME_YES" -eq 1 ] && args=(-y)

if [ "$do_fan" -eq 1 ]; then
    step "Running scripts/macbook-tune.sh"
    "$SCRIPT_DIR/scripts/macbook-tune.sh" "${args[@]}" || rc=$?
    echo
else
    info "Skipping fan support."
fi

if [ "$do_driver" -eq 1 ]; then
    step "Running scripts/install.sh"
    "$SCRIPT_DIR/scripts/install.sh" "${args[@]}" || rc=$?
    echo
else
    info "Skipping the camera driver."
fi

if [ "$rc" -eq 0 ]; then
    info "Setup complete."
else
    warn "Setup finished with warnings - see above."
fi
exit "$rc"
