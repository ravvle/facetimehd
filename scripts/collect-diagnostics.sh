#!/usr/bin/env bash
#
# Collect everything a facetimehd bug report needs into one file.
#
# The README used to ask for the output of five commands, pasted by hand. That
# reliably produced reports missing the one thing that would have identified the
# problem, so this runs them all and writes a single file to attach.
#
# Runs without root and collects nothing a normal user cannot already read; the
# few commands that need root are simply reported as unavailable. What it writes
# is meant to be posted in public, so it deliberately gathers only the machine's
# hardware and software configuration - see "redaction" below for what is
# actively kept out.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

MODULE_NAME=facetimehd
OUTPUT=''

usage() {
    cat <<EOF
Usage: $0 [-o FILE]

  -o, --output FILE  Write the report here (default: a file in the current
                     directory named facetimehd-diagnostics-<date>.txt).
  -h, --help         Show this help.

Runs without root. Attach the resulting file to a GitHub issue.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) shift; [ $# -gt 0 ] || die "--output needs a file name"
                     OUTPUT="$1" ;;
        --output=*)  OUTPUT="${1#*=}" ;;
        -h|--help)   usage; exit 0 ;;
        *)           error "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

[ -n "$OUTPUT" ] || OUTPUT="facetimehd-diagnostics-$(date +%Y%m%d-%H%M%S).txt"

# --- redaction --------------------------------------------------------------
#
# Two things in this output identify the machine rather than describe it: the
# DMI serial number and the UUID. Neither helps anyone debug a camera driver,
# and both are the kind of thing people paste into a public issue without
# noticing. Everything written below goes through this.
#
# Deliberately narrow. A filter aggressive enough to catch anything
# serial-shaped would eat PCI IDs, firmware versions and kernel release strings,
# which are exactly what the report is for.
redact() {
    local serial uuid
    serial="$(cat /sys/class/dmi/id/product_serial 2>/dev/null || true)"
    uuid="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || true)"

    local -a args=(-e 's/$//')
    [ -n "${serial// /}" ] && args+=(-e "s|${serial//|/\\|}|<serial redacted>|g")
    [ -n "${uuid// /}" ]   && args+=(-e "s|${uuid//|/\\|}|<uuid redacted>|g")
    sed "${args[@]}"
}

# Run a command as one report section. A command that is missing or fails is
# recorded as such rather than skipped: "dkms is not installed" is itself a
# useful answer, and a silent gap looks like the collector broke.
section() {
    local title="$1"; shift
    printf '\n===== %s =====\n' "$title"
    if ! have "$1"; then
        printf '(%s is not installed)\n' "$1"
        return 0
    fi
    "$@" 2>&1 || printf '(command failed: %s)\n' "$*"
}

collect() {
    printf 'facetimehd diagnostics\n'
    printf 'collected: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    printf 'collector: %s\n' "$(cd -- "$SCRIPT_DIR/.." && git rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout')"

    printf '\n===== Machine =====\n'
    printf 'model:   %s\n' "$(dmi_product_name || true)"
    printf 'kernel:  %s\n' "$(uname -r)"
    printf 'arch:    %s\n' "$(uname -m)"
    detect_os
    printf 'distro:  %s\n' "${OS_PRETTY:-unknown}"

    section 'PCI camera device' lspci -nn -d 14e4:1570
    section 'PCI camera device (verbose)' lspci -vv -d 14e4:1570

    printf '\n===== DKMS =====\n'
    if have dkms; then
        dkms status -m "$MODULE_NAME" 2>&1 || true
        [ "$(id -u)" -eq 0 ] || printf '(not root: dkms status may be incomplete)\n'
    else
        printf '(dkms is not installed)\n'
    fi

    printf '\n===== Module =====\n'
    lsmod 2>/dev/null | grep -E "^(${MODULE_NAME}|videobuf2|videodev)\b" ||
        printf '(no facetimehd or v4l2 modules loaded)\n'
    printf '\n'
    section 'modinfo' modinfo "$MODULE_NAME"

    printf '\n===== Module parameters =====\n'
    if [ -d "/sys/module/$MODULE_NAME/parameters" ]; then
        for p in "/sys/module/$MODULE_NAME/parameters/"*; do
            [ -r "$p" ] || continue
            printf '%s = %s\n' "${p##*/}" "$(cat "$p" 2>/dev/null || echo '?')"
        done
    else
        printf '(module not loaded)\n'
    fi
    printf '\n'
    printf 'modprobe drop-ins:\n'
    grep -rs "$MODULE_NAME" /etc/modprobe.d/ 2>/dev/null || printf '(none)\n'

    printf '\n===== Firmware =====\n'
    fw_dir="$(firmware_root)/$MODULE_NAME"
    if [ -d "$fw_dir" ]; then
        # Sizes and names only. The firmware itself is Apple's and must not be
        # redistributed, which includes not pasting it into an issue.
        ls -l "$fw_dir" 2>&1 || true
        if [ -r "$fw_dir/firmware.bin" ] && have sha256sum; then
            printf 'firmware.bin sha256: %s\n' \
                "$(sha256sum "$fw_dir/firmware.bin" | cut -d' ' -f1)"
        fi
    else
        printf '(no %s directory)\n' "$fw_dir"
    fi

    printf '\n===== Secure Boot =====\n'
    if have mokutil; then
        mokutil --sb-state 2>&1 || true
    else
        printf '(mokutil is not installed)\n'
    fi

    section 'V4L2 devices' v4l2-ctl --list-devices
    section 'V4L2 capabilities' v4l2-ctl -d /dev/video0 --all
    section 'V4L2 formats' v4l2-ctl -d /dev/video0 --list-formats-ext

    printf '\n===== Kernel messages =====\n'
    # dmesg is restricted to root on most distributions now; the journal is the
    # readable path for a normal user, so try both and take whichever answers.
    if dmesg 2>/dev/null | grep -iE "${MODULE_NAME}|bcwc" ; then
        :
    elif have journalctl && journalctl -k -b --no-pager 2>/dev/null |
             grep -iE "${MODULE_NAME}|bcwc"; then
        :
    else
        printf '(no kernel messages found; re-run with sudo for the full ring buffer)\n'
    fi

}

step "Collecting diagnostics"
collect | redact > "$OUTPUT"

ok "Wrote $OUTPUT ($(wc -l < "$OUTPUT") lines)"
info "The DMI serial and UUID are removed. Please skim it before posting."
info "Attach it to: https://github.com/ravvle/facetimehd/issues"
