#!/usr/bin/env bash
#
# Validate the downstream changes that only a real MacBook can confirm.
#
# tests/smoke-capture.sh answers "does the camera work at all". This script
# answers the open questions in src/facetimehd/DOWNSTREAM.md under "Hardware
# validation status" - the ones a compiler, shellcheck and CI are all
# structurally unable to reach. Each section below names the item it is
# testing so a result can be pasted straight back into that document.
#
#   sudo ./tests/hw-validate.sh                 # everything except --reboot
#   sudo ./tests/hw-validate.sh --only probe,timing
#   sudo ./tests/hw-validate.sh --skip suspend  # laptop in use, or headless
#   sudo ./tests/hw-validate.sh --reboot        # arm the shutdown-path test
#
# Needs v4l-utils. The suspend section asks you to close and open the lid, so
# it needs a terminal and someone at the machine; --skip suspend drops it.
# The report is written to a file and printed at the end; attach it to a bug.
#
# This is destructive in the sense that it loads and unloads the module,
# suspends the machine, and (with --reboot) reboots it. It changes no
# persistent configuration.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"

MODULE_NAME=facetimehd
STATE_DIR=/var/lib/facetimehd-ubuntu-macbook
REBOOT_STATE="$STATE_DIR/hw-validate-reboot"
REPORT="${REPORT:-/tmp/facetimehd-hw-validate-$(date +%Y%m%d-%H%M%S).log}"

# Must exceed FTHD_AUTOSUSPEND_DELAY_MS (5000) in fthd_drv.c by enough that a
# loaded machine still parks the device before we look. Read from sysfs at run
# time where possible; this is only the fallback.
IDLE_WAIT="${IDLE_WAIT:-9}"
FRAMES="${FRAMES:-30}"
SUSPEND_SECS="${SUSPEND_SECS:-20}"
LID_TIMEOUT="${LID_TIMEOUT:-180}"
DEVICE="${DEVICE:-}"

ALL_SECTIONS="probe timing controls runtimepm suspend wedged"
SECTIONS="$ALL_SECTIONS"
DO_REBOOT=0
INTERACTIVE=1
[ -t 0 ] || INTERACTIVE=0

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

      --only LIST    Run only these sections (comma-separated).
      --skip LIST    Run everything except these sections.
      --reboot       Arm the reboot-while-streaming test. Streams, then reboots
                     the machine. Re-run this script after the reboot to read
                     the verdict. Not included in a default run.
      --no-interactive
                     Skip everything that needs a person: covering the camera
                     for the exposure tests, and the lid prompt for suspend.
  -h, --help         Show this help.

Sections: $ALL_SECTIONS

Environment:
  DEVICE        Video node to test (default: the node $MODULE_NAME claims).
  FRAMES        Frames per capture (default: 30).
  IDLE_WAIT     Seconds to wait for runtime suspend (default: 9).
  SUSPEND_SECS  Seconds to ask you to keep the lid closed (default: 20).
  LID_TIMEOUT   Seconds to wait for the lid before giving up (default: 180).
  REPORT        Report path (default: /tmp/facetimehd-hw-validate-DATE.log).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --only) shift; [ $# -gt 0 ] || die "--only needs a list"
                SECTIONS="${1//,/ }" ;;
        --skip) shift; [ $# -gt 0 ] || die "--skip needs a list"
                for _s in ${1//,/ }; do
                    SECTIONS="${SECTIONS//$_s/}"
                done ;;
        --reboot)         DO_REBOOT=1 ;;
        --no-interactive) INTERACTIVE=0 ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage >&2; die "Unknown argument: $1" ;;
    esac
    shift
done

for _s in $SECTIONS; do
    case " $ALL_SECTIONS " in
        *" $_s "*) ;;
        *) die "Unknown section: $_s (valid: $ALL_SECTIONS)" ;;
    esac
done

wants() { case " $SECTIONS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

require_root
require_cmds v4l2-ctl modprobe
has_facetimehd_hardware ||
    die "No FaceTime HD camera (14e4:1570) on this machine - nothing to test."

# ---------------------------------------------------------------- reporting --

# Every result is one line so the summary can be pasted into a bug report and
# still be read by a human. Status is one of PASS/FAIL/WARN/INFO/SKIP; FAIL is
# the only one that changes the exit code.
RESULTS=()
FAILED=0

result() {
    local status="$1" id="$2" msg="$3"
    RESULTS+=("$status|$id|$msg")
    case "$status" in
        PASS) ok   "[$id] $msg" ;;
        FAIL) bad  "[$id] $msg"; FAILED=1 ;;
        WARN) warn "[$id] $msg" ;;
        SKIP) info "[$id] skipped: $msg" ;;
        *)    info "[$id] $msg" ;;
    esac
    printf '%s|%s|%s\n' "$status" "$id" "$msg" >>"$REPORT.results"
}

log() { printf '%s\n' "$*" >>"$REPORT"; }

log_section() {
    log ""
    log "=============================================================="
    log "$*"
    log "=============================================================="
}

# dmesg cursors.
#
# Counting lines does not work here. This driver logs its whole DDR/PLL
# bring-up at dev_info level on *every* runtime-PM resume, which happens every
# few idle seconds, so the kernel ring buffer wraps within a minute or two on a
# normal run. Once it wraps, `dmesg | wc -l` stops growing and a
# `tail -n +$cursor` returns nothing at all - which silently turns "I found no
# PM records" into "the machine never suspended". That misdiagnosis is exactly
# what this replaces.
#
# Write a unique token into the log instead and read back everything after its
# last occurrence. If the token itself has been evicted we fall back to
# returning the whole buffer and say so: over-reporting is recoverable, an
# empty result that reads as a verdict is not.
DMESG_TOKEN=""
DMESG_CURSOR=0
DMESG_WRAPPED=0

dmesg_mark() {
    if [ -w /dev/kmsg ]; then
        DMESG_TOKEN="hw-validate-mark-$$-${EPOCHSECONDS:-$(date +%s)}-$RANDOM"
        if printf '%s\n' "$DMESG_TOKEN" >/dev/kmsg 2>/dev/null; then
            return 0
        fi
    fi
    DMESG_TOKEN=""
    DMESG_CURSOR="$(dmesg 2>/dev/null | wc -l)"
}

dmesg_since() {
    if [ -n "$DMESG_TOKEN" ]; then
        dmesg 2>/dev/null | awk -v tok="$DMESG_TOKEN" '
            { lines[NR] = $0; if (index($0, tok)) last = NR }
            END {
                if (last == 0) { print "HW-VALIDATE-RING-WRAPPED" }
                for (i = last + 1; i <= NR; i++) print lines[i]
            }'
    else
        dmesg 2>/dev/null | tail -n "+$((DMESG_CURSOR + 1))"
    fi
}

dmesg_driver() { dmesg_since | grep -i "$MODULE_NAME\|fthd" || true; }

# Call after any dmesg_since whose emptiness would be read as a result.
check_ring_wrap() {
    if dmesg_since | grep -q HW-VALIDATE-RING-WRAPPED; then
        DMESG_WRAPPED=1
        return 0
    fi
    return 1
}

# --------------------------------------------------------------- primitives --

pci_slot() {
    local d vendor device
    for d in /sys/bus/pci/devices/*; do
        [ -r "$d/vendor" ] && [ -r "$d/device" ] || continue
        read -r vendor <"$d/vendor"
        read -r device <"$d/device"
        if [ "$vendor" = 0x14e4 ] && [ "$device" = 0x1570 ]; then
            basename "$d"
            return 0
        fi
    done
    return 1
}

SLOT="$(pci_slot || true)"
PCI_DIR="${SLOT:+/sys/bus/pci/devices/$SLOT}"

runtime_status() {
    [ -n "$PCI_DIR" ] && [ -r "$PCI_DIR/power/runtime_status" ] || return 1
    cat "$PCI_DIR/power/runtime_status"
}

find_device() {
    local node name
    for node in /dev/video*; do
        [ -e "$node" ] || continue
        name="$(v4l2-ctl --device "$node" --info 2>/dev/null |
                sed -n 's/^[[:space:]]*Driver name[[:space:]]*:[[:space:]]*//p')"
        if [ "$name" = "$MODULE_NAME" ]; then
            printf '%s\n' "$node"
            return 0
        fi
    done
    return 1
}

wait_for_device() {
    local _
    for _ in $(seq 1 20); do
        DEVICE="$(find_device || true)"
        [ -n "$DEVICE" ] && return 0
        sleep 0.5
    done
    return 1
}

capture_ok() {
    v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count="${1:-$FRAMES}" \
             --stream-to=/dev/null >>"$REPORT" 2>&1
}

# Mean luma of one frame, sampled across the whole image rather than the head
# of the file. Taking the first 200KB of a 1280-wide YUYV frame only covers
# the top ~78 rows, so a hand entering the bottom of the shot, or a ceiling
# light in the top strip, skews the number badly - and this is the measurement
# the auto-exposure verdict rests on. Six chunks spread through the frame cost
# the same and actually represent it.
#
# Assumes a packed YUV format where byte 0 of each pair is Y - true for the
# YUYV this driver offers, and this is a relative comparison anyway.
mean_luma() {
    local tmp size chunk i off
    tmp="$(mktemp)"
    if ! v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=1 \
                  --stream-to="$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"; return 1
    fi
    size="$(stat -c %s "$tmp" 2>/dev/null || echo 0)"
    if [ "$size" -lt 12000 ]; then
        rm -f "$tmp"; return 1
    fi
    chunk=$(( size / 6 ))
    for i in 0 1 2 3 4 5; do
        off=$(( i * chunk ))
        dd if="$tmp" bs=1 skip="$off" count=10000 status=none 2>/dev/null
    done | od -An -tu1 -v |
        awk '{for(i=1;i<=NF;i+=2){s+=$i;n++}} END{if(n)printf "%.1f\n",s/n; else print "0"}'
    rm -f "$tmp"
}

# Dynamic debug turns on the dev_dbg lines - notably "DDR verification passed
# over N words", which is the only direct measurement of what the widened
# probe check costs.
#
# It has to be passed as a module parameter, not written to
# dynamic_debug/control beforehand: a module's callsites do not exist until it
# is loaded, so a `module facetimehd +p` query for an unloaded module matches
# nothing and the write fails. Setting it at load time is what actually gets
# the probe-path dev_dbg lines, which are the ones we need - by the time the
# module is loaded, probe has already run.
#
# Scoped to fthd_hw.c rather than a blanket +p: the DDR line we need lives
# there, and a whole-module +p adds enough extra output to hasten the ring
# wrap described above - which is how the first fix for this broke the
# suspend section.
DYNDBG_ARG="dyndbg=file fthd_hw.c +p"

# Reload from scratch with the dmesg cursor set just before probe, so
# dmesg_driver returns this probe's messages and not the previous one's.
load_module() {
    modprobe -r "$MODULE_NAME" 2>/dev/null || true
    sleep 1
    dmesg_mark
    # Fall back to a bare load if the kernel was built without dynamic debug,
    # which makes the dyndbg parameter unknown and modprobe fail outright.
    modprobe "$MODULE_NAME" "$DYNDBG_ARG" 2>/dev/null ||
        modprobe "$MODULE_NAME"
}

# shellcheck disable=SC2329,SC2317
cleanup() {
    [ -n "${STREAM_PID:-}" ] && kill "$STREAM_PID" 2>/dev/null
    return 0
}
trap cleanup EXIT

: >"$REPORT"
: >"$REPORT.results"
log "facetimehd hardware validation"
log "date:    $(date -Is)"
log "kernel:  $(uname -r)"
log "model:   $(dmi_product_name 2>/dev/null || echo unknown)"
log "slot:    ${SLOT:-not found}"
log "sections: $SECTIONS"
log "modinfo:"
modinfo "$MODULE_NAME" 2>>"$REPORT" | sed 's/^/  /' >>"$REPORT" || true

info "Report: $REPORT"

# ============================================================================
# Section: probe
# DOWNSTREAM.md - "Hardware-failure propagation"
#
# PLL, DDR and memory-verification failures used to be logged and ignored;
# they now fail probe. The regression this is hunting for is a machine that
# worked before and no longer probes - so the useful output is not just
# pass/fail but *which* check fired.
# ============================================================================
if wants probe; then
    step "probe: does the driver still come up on this machine?"
    log_section "SECTION probe"

    if load_module >>"$REPORT" 2>&1; then
        if wait_for_device; then
            result PASS probe.load "module loaded, $MODULE_NAME claims $DEVICE"
        else
            result FAIL probe.node "module loaded but no video node appeared"
        fi
    else
        result FAIL probe.load "modprobe failed - the driver refuses this machine"
    fi

    dmesg_driver >>"$REPORT"

    # Classify against the exact strings the hardened checks emit, so a report
    # says "DDR PLL stage 2" rather than "it broke".
    DRV_LOG="$(dmesg_driver)"
    while IFS='|' read -r pattern label; do
        [ -n "$pattern" ] || continue
        if printf '%s' "$DRV_LOG" | grep -qi -- "$pattern"; then
            result FAIL "probe.check" "hardware check fired: $label"
        fi
    done <<'EOF'
Failed to lock the DDR PLL|DDR PLL never locked
Failed to lock DDR PHY PLL in stage 1|DDR PHY PLL stage 1
Failed to lock DDR PHY PLL in stage 2|DDR PHY PLL stage 2
Failed to lock DDR PHY PLL in stage 3|DDR PHY PLL stage 3
First DDR40 VDL calibration failed|DDR40 VDL calibration
DDR verification failed|DDR memory verification (widened at probe)
Failed to init S2 PCIe link|S2 PCIe link init
PCI link in illegal state|PCI link state
Timeout waiting for STRAP valid|STRAP timeout
Failed to read PCI config|PCI config read
EOF

    # Non-fatal, but worth surfacing: the fixed DDR timings assume 450MHz.
    if printf '%s' "$DRV_LOG" | grep -qi "should be 450 MHz\|Unsupported DDR speed"; then
        result WARN probe.ddrfreq "DDR is not running at 450MHz - see report"
    fi
fi

# ============================================================================
# Section: timing
# DOWNSTREAM.md - "MEM_VERIFY_NUM_PROBE costs unmeasured time at probe"
#
# 64K words is 64K non-posted PCIe reads. The estimate in DOWNSTREAM.md is
# "tens of milliseconds" and nobody has ever timed it. This times the whole
# probe, then prints a per-line delta profile so the DDR verification step can
# be read off directly rather than inferred.
# ============================================================================
if wants timing; then
    step "timing: what does the widened DDR check cost at probe?"
    log_section "SECTION timing"

    modprobe -r "$MODULE_NAME" 2>/dev/null || true
    sleep 1
    dmesg_mark
    t0="$(date +%s%N)"
    if modprobe "$MODULE_NAME" "$DYNDBG_ARG" >>"$REPORT" 2>&1 ||
       modprobe "$MODULE_NAME" >>"$REPORT" 2>&1; then
        t1="$(date +%s%N)"
        elapsed_ms=$(( (t1 - t0) / 1000000 ))
        result INFO timing.modprobe "modprobe wall time: ${elapsed_ms}ms"
        if [ "$elapsed_ms" -gt 2000 ]; then
            result WARN timing.modprobe \
                "probe took ${elapsed_ms}ms - if this is objectionable, lower MEM_VERIFY_NUM_PROBE"
        else
            result PASS timing.modprobe "probe cost is acceptable (${elapsed_ms}ms)"
        fi

        # Per-message deltas from the kernel's own timestamps. The largest gap
        # is the answer; DDR verification is the line to look for next to it.
        log ""
        log "--- probe timeline (delta ms | message) ---"
        dmesg_driver | awk '
            match($0, /\[[ ]*[0-9]+\.[0-9]+\]/) {
                ts = substr($0, RSTART+1, RLENGTH-2) + 0
                if (prev != "") printf "%8.1f | %s\n", (ts-prev)*1000, $0
                prev = ts
            }' >>"$REPORT"

        biggest="$(dmesg_driver | awk '
            match($0, /\[[ ]*[0-9]+\.[0-9]+\]/) {
                ts = substr($0, RSTART+1, RLENGTH-2) + 0
                if (prev != "" && (ts-prev) > max) { max = ts-prev; line = $0 }
                prev = ts
            } END { if (line != "") printf "%.0fms at: %s\n", max*1000, line }')"
        [ -n "$biggest" ] && result INFO timing.slowest "longest gap: $biggest"

        if dmesg_driver | grep -qi "DDR verification passed"; then
            result PASS timing.ddr "$(dmesg_driver | grep -i 'DDR verification passed' | tail -1 | sed 's/.*facetimehd[^ ]* //')"
        else
            result INFO timing.ddr \
                "no DDR verification line (needs dynamic debug; is CONFIG_DYNAMIC_DEBUG on?)"
        fi
        wait_for_device || true
    else
        result FAIL timing.modprobe "modprobe failed during timing run"
    fi
fi

# ============================================================================
# Section: controls
# DOWNSTREAM.md - "V4L2_CID_POWER_LINE_FREQUENCY" (inferred Apple ABI 0x8208)
#                 "V4L2_CID_EXPOSURE_AUTO"
#
# The flicker control is the risky one: 0x8208 is an Apple-private opcode and
# the payload shape is an inference. The stated failure mode is that the
# firmware refuses the command and S_CTRL returns an error - so an error here
# is a real finding, and DOWNSTREAM.md says this is the first thing to revert.
# ============================================================================
if wants controls; then
    step "controls: the two controls wired to unverified firmware opcodes"
    log_section "SECTION controls"

    [ -n "$DEVICE" ] || wait_for_device || true
    if [ -z "$DEVICE" ]; then
        result SKIP controls "no video node"
    else
        v4l2-ctl --device "$DEVICE" --list-ctrls >>"$REPORT" 2>&1 || true

        # --- power_line_frequency: the inferred ABI -------------------------
        if v4l2-ctl --device "$DEVICE" --list-ctrls 2>/dev/null |
                grep -q power_line_frequency; then
            for val in 0 1 2; do
                case "$val" in
                    0) label=Disabled ;;
                    1) label=50Hz ;;
                    *) label=60Hz ;;
                esac
                dmesg_mark
                if v4l2-ctl --device "$DEVICE" \
                        --set-ctrl power_line_frequency="$val" >>"$REPORT" 2>&1; then
                    got="$(v4l2-ctl --device "$DEVICE" --get-ctrl power_line_frequency \
                           2>/dev/null | sed -n 's/^power_line_frequency: //p')"
                    if [ "$got" = "$val" ]; then
                        result PASS "controls.plf.$label" "accepted and read back"
                    else
                        result FAIL "controls.plf.$label" \
                            "set succeeded but reads back '$got'"
                    fi
                else
                    result FAIL "controls.plf.$label" \
                        "S_CTRL failed - opcode 0x8208 payload is likely wrong, revert this control"
                fi
                dmesg_driver >>"$REPORT"
            done

            # Banding is what the control exists to fix, and only an eye can
            # confirm it. Capture one frame per setting for later comparison.
            if [ "$INTERACTIVE" = 1 ]; then
                info "Point the camera at a wall lit by mains lighting, then press Enter."
                read -r _ || true
                for val in 0 1 2; do
                    v4l2-ctl --device "$DEVICE" --set-ctrl power_line_frequency="$val" \
                        >/dev/null 2>&1 || continue
                    sleep 2
                    v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=1 \
                        --stream-to="/tmp/facetimehd-plf-$val.raw" >/dev/null 2>&1 || true
                done
                result INFO controls.plf.frames \
                    "wrote /tmp/facetimehd-plf-{0,1,2}.raw - compare for banding"
            fi
            v4l2-ctl --device "$DEVICE" --set-ctrl power_line_frequency=0 \
                >/dev/null 2>&1 || true
        else
            result SKIP controls.plf "power_line_frequency not exposed"
        fi

        # --- auto exposure: named opcodes, unverified behaviour ------------
        # V4L2_CID_EXPOSURE_AUTO (0x009a0901) is printed by current v4l-utils
        # as "auto_exposure", and by older releases as "exposure_auto". Match
        # the control ID instead of either spelling, then use whichever name
        # this v4l2-ctl actually accepts for --set-ctrl.
        AE_NAME=""
        if v4l2-ctl --device "$DEVICE" --list-ctrls 2>/dev/null |
                grep -q '0x009a0901'; then
            AE_NAME="$(v4l2-ctl --device "$DEVICE" --list-ctrls 2>/dev/null |
                       sed -n 's/^[[:space:]]*\([a-z_]*\)[[:space:]]*0x009a0901.*/\1/p' |
                       head -1)"
        fi
        if [ -n "$AE_NAME" ]; then
            # 0 = AUTO, 1 = MANUAL in the V4L2 menu.
            for val in 1 0; do
                case "$val" in
                    0) label=auto ;;
                    *) label=manual ;;
                esac
                if v4l2-ctl --device "$DEVICE" \
                        --set-ctrl "$AE_NAME"="$val" >>"$REPORT" 2>&1; then
                    result PASS "controls.ae.$label" "accepted"
                else
                    result FAIL "controls.ae.$label" "S_CTRL failed"
                fi
            done

            if capture_ok 10; then
                result PASS controls.ae.stream "capture still works after toggling AE"
            else
                result FAIL controls.ae.stream "capture broke after toggling AE"
            fi

            # The real question is whether it *does* anything. Manual AE means
            # luma must NOT track a lighting change; auto means it must. Only a
            # human can change the lighting, so this stays interactive.
            if [ "$INTERACTIVE" = 1 ]; then
                v4l2-ctl --device "$DEVICE" --set-ctrl "$AE_NAME"=1 >/dev/null 2>&1 || true
                sleep 2
                base_manual="$(mean_luma || echo "")"
                # Partly shade, do not cover. Covering the sensor completely
                # drove luma to exactly 0.0 in both AUTO and MANUAL on two
                # runs: with no photons there is nothing for auto-exposure to
                # amplify, so both branches read the same floor and the test
                # cannot discriminate no matter what the firmware does.
                # Dimming leaves signal for AE to work on.
                info "PARTLY shade the camera - a hand a few inches away, or"
                info "half-cover the lens. Do NOT cover it completely."
                info "Then press Enter."
                read -r _ || true
                sleep 2
                dark_manual="$(mean_luma || echo "")"

                v4l2-ctl --device "$DEVICE" --set-ctrl "$AE_NAME"=0 >/dev/null 2>&1 || true
                sleep 3
                dark_auto="$(mean_luma || echo "")"
                info "Remove the shade, then press Enter."
                read -r _ || true
                sleep 3
                light_auto="$(mean_luma || echo "")"

                log "luma manual(lit)=$base_manual manual(dark)=$dark_manual"
                log "luma auto(dark)=$dark_auto auto(lit)=$light_auto"
                result INFO controls.ae.luma \
                    "manual lit=$base_manual dark=$dark_manual | auto dark=$dark_auto lit=$light_auto"

                # Direction matters, not just difference. Auto-exposure on a
                # dimmed scene should raise gain and so push luma *up* relative
                # to the manual reading of the same scene. A bare "they differ"
                # test passes on noise, and passes just as happily when AUTO
                # comes out darker - which is the opposite of the control
                # working.
                if awk -v m="$dark_manual" -v a="$dark_auto" \
                       'BEGIN{exit !(m+0 < 1 && a+0 < 1)}' 2>/dev/null &&
                   [ -n "$dark_manual" ] && [ -n "$dark_auto" ]; then
                    # Both on the floor: the shade was total, so there was no
                    # signal either setting could act on. Says nothing about AE.
                    result WARN controls.ae.effect \
                        "both readings floored at 0 - camera was fully covered, re-run and only partly shade it"
                elif [ -n "$dark_manual" ] && [ -n "$dark_auto" ]; then
                    if awk -v a="$dark_auto" -v m="$dark_manual" \
                           'BEGIN{exit !(a > m + 5)}'; then
                        result PASS controls.ae.effect \
                            "AUTO raised luma on a dark scene ($dark_manual -> $dark_auto) - AE is working"
                    elif awk -v a="$dark_auto" -v m="$dark_manual" \
                             'BEGIN{exit !(a < m - 5)}'; then
                        result WARN controls.ae.effect \
                            "AUTO came out darker than MANUAL ($dark_manual -> $dark_auto) - backwards, re-run with steady lighting before trusting it"
                    else
                        result WARN controls.ae.effect \
                            "AUTO and MANUAL within noise ($dark_manual vs $dark_auto) - control may be a silent no-op"
                    fi
                fi
            else
                result SKIP controls.ae.effect "needs --interactive to change the lighting"
            fi
            v4l2-ctl --device "$DEVICE" --set-ctrl "$AE_NAME"=0 >/dev/null 2>&1 || true
        else
            result SKIP controls.ae "V4L2_CID_EXPOSURE_AUTO (0x009a0901) not exposed"
        fi
    fi
fi

# ============================================================================
# Section: runtimepm
# DOWNSTREAM.md - "Runtime power management"
#
# The failure mode to catch: camera works on first use after boot but not
# after sitting idle. So the test is idle -> suspended -> open -> capture,
# repeated, because a firmware reload that works once can still leak.
# ============================================================================
if wants runtimepm; then
    step "runtimepm: does the camera survive being parked and woken?"
    log_section "SECTION runtimepm"

    if [ -z "$PCI_DIR" ]; then
        result SKIP runtimepm "PCI device not found in sysfs"
    elif [ "$(cat /sys/module/$MODULE_NAME/parameters/runtime_pm 2>/dev/null)" = "N" ]; then
        result SKIP runtimepm "loaded with runtime_pm=0"
    else
        # The driver calls pm_runtime_allow() itself, so power/control should
        # already read "auto" with nothing else on the system touching it.
        # Anything else means something external overrode the driver - TLP with
        # RUNTIME_PM_ON_AC=on, 'powertop --auto-tune', a udev rule - and that is
        # worth reporting rather than silently papering over, because it is the
        # configuration the user is actually running. Report, then set it, so
        # the rest of the section still tests the driver.
        ctrl="$(cat "$PCI_DIR/power/control" 2>/dev/null || echo unknown)"
        if [ "$ctrl" = auto ]; then
            result PASS runtimepm.control "power/control=auto (driver allowed it)"
        else
            result WARN runtimepm.control \
                "power/control=$ctrl - something outside the driver disabled runtime PM; forcing auto for this test"
            echo auto >"$PCI_DIR/power/control" 2>/dev/null || true
        fi
        delay="$(cat "$PCI_DIR/power/autosuspend_delay_ms" 2>/dev/null || echo 5000)"
        result INFO runtimepm.delay "autosuspend_delay_ms=$delay"
        wait_s=$(( delay / 1000 + 4 ))
        [ "$wait_s" -lt "$IDLE_WAIT" ] && wait_s="$IDLE_WAIT"

        for cycle in 1 2; do
            info "cycle $cycle: waiting ${wait_s}s for the device to park"
            sleep "$wait_s"
            st="$(runtime_status || echo unknown)"
            log "cycle $cycle idle runtime_status=$st"
            if [ "$st" = suspended ]; then
                result PASS "runtimepm.park.$cycle" "device parked (runtime_status=suspended)"
            else
                result FAIL "runtimepm.park.$cycle" \
                    "device did not park after ${wait_s}s idle (runtime_status=$st)"
            fi

            dmesg_mark
            [ -n "$DEVICE" ] || wait_for_device || true
            if [ -n "$DEVICE" ] && capture_ok 10; then
                result PASS "runtimepm.wake.$cycle" "captured after idle - firmware reloaded"
            else
                result FAIL "runtimepm.wake.$cycle" \
                    "capture FAILED after idle - this is the runtime_pm=0 case"
            fi
            st="$(runtime_status || echo unknown)"
            log "cycle $cycle post-capture runtime_status=$st"
            dmesg_driver >>"$REPORT"

            if dmesg_since | grep -qi "firmware stopped responding"; then
                result FAIL "runtimepm.wedged.$cycle" \
                    "firmware wedged during the wake cycle"
            fi
        done

        # Reading a debugfs file must itself power the camera up - that is the
        # documented reason the accessors take a runtime-PM reference.
        dbg="/sys/kernel/debug/$MODULE_NAME/$SLOT/channel_io"
        if [ -r "$dbg" ]; then
            sleep "$wait_s"
            [ "$(runtime_status || echo x)" = suspended ] &&
                info "device parked; reading debugfs should wake it"
            if head -c 128 "$dbg" >/dev/null 2>&1; then
                result PASS runtimepm.debugfs "debugfs read woke the device"
            else
                result FAIL runtimepm.debugfs "debugfs read failed while parked"
            fi
        else
            result SKIP runtimepm.debugfs "debugfs not mounted or not readable"
        fi
    fi
fi

# ============================================================================
# Section: suspend
# DOWNSTREAM.md - "Suspending mid-stream"
#
# Expected: the machine sleeps instead of refusing to, the running viewer sees
# a broken stream, and a restarted viewer gets a picture back. Before the fix
# the machine would refuse to suspend with the camera open.
# ============================================================================
if wants suspend; then
    step "suspend: system sleep with the camera streaming"
    log_section "SECTION suspend"

    # The lid switch, not rtcwake. An RTC alarm reliably *started* the suspend
    # on this hardware but never held it: every run came back after ~5s of a
    # 20s alarm, so the duration check was permanently WARN and told us nothing
    # about the driver. The lid is the way a MacBook is actually suspended, it
    # has no competing wakeup source, and the person running this is sitting in
    # front of the machine anyway. It does mean the section needs a terminal.
    if [ "$INTERACTIVE" = 0 ]; then
        result SKIP suspend "needs a terminal - the lid prompt drives this section"
    elif [ -z "$DEVICE" ] && ! wait_for_device; then
        result SKIP suspend "no video node"
    fi

    if wants suspend && [ "$INTERACTIVE" = 1 ] && [ -n "$DEVICE" ]; then
        dmesg_mark
        v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=100000 \
                 --stream-to=/dev/null >>"$REPORT" 2>&1 &
        STREAM_PID=$!
        sleep 3

        if ! kill -0 "$STREAM_PID" 2>/dev/null; then
            result FAIL suspend.stream "stream died before the suspend even started"
        else
            result INFO suspend.stream "streaming (pid $STREAM_PID), waiting for the lid"

            printf '\n'
            warn "The camera is streaming right now. To test suspend:"
            warn ""
            warn "    1. CLOSE the lid now."
            warn "    2. Leave it closed for at least ${SUSPEND_SECS} seconds."
            warn "    3. OPEN the lid again."
            warn ""
            warn "This script is frozen along with the machine and picks up on"
            warn "its own once you open the lid. Do not press anything."
            printf '\n'

            before="$(date +%s)"
            # This loop is frozen with everything else while the machine is
            # down, so it resumes by itself; it only has to notice that the
            # resume happened. Poll the PM records rather than the clock -
            # "PM: suspend exit" is the unambiguous signal that a full
            # suspend/resume cycle completed.
            waited=0
            while [ "$waited" -lt "$LID_TIMEOUT" ]; do
                if dmesg_since | grep -qi "PM: suspend exit"; then
                    break
                fi
                sleep 2
                waited=$(( waited + 2 ))
            done
            after="$(date +%s)"
            slept=$(( after - before ))

            timed_out=0
            [ "$waited" -ge "$LID_TIMEOUT" ] && timed_out=1

            # Wall-clock alone cannot tell "the driver refused to suspend" from
            # "the machine suspended and something woke it early" - both come
            # back sooner than asked. Only the kernel's own PM records can, so
            # capture them; a short sleep is otherwise misreported as a driver
            # bug. -EBUSY (-16) out of fthd_suspend is the specific regression
            # this section exists to catch.
            pm_log="$(dmesg_since | grep -i "PM: suspend\|failed to suspend\|$MODULE_NAME" || true)"
            printf '%s\n' "$pm_log" >>"$REPORT"

            if check_ring_wrap; then
                # The evidence was evicted before we could read it. Saying
                # "suspend never started" here would be inventing a result.
                result WARN suspend.entered \
                    "kernel ring buffer wrapped - PM records lost, cannot judge (raise log_buf_len)"
            elif printf '%s' "$pm_log" | grep -qi "fthd_suspend.*returns -16\|$MODULE_NAME.*failed to suspend"; then
                result FAIL suspend.refused \
                    "driver returned -EBUSY from fthd_suspend - it is blocking system sleep"
            elif printf '%s' "$pm_log" | grep -qi "PM: suspend entry"; then
                result PASS suspend.entered \
                    "machine entered suspend with the camera streaming (not refused)"
                # Elapsed includes however long you took to reach for the lid,
                # so it is context for the log, not a pass criterion. Whether
                # the machine suspended at all is the driver question, and the
                # PM records above already answered it.
                result INFO suspend.slept "${slept}s elapsed from prompt to resume"
                if printf '%s' "$pm_log" | grep -qi "Some devices failed to suspend"; then
                    if printf '%s' "$pm_log" | grep -qi "$MODULE_NAME.*failed to suspend"; then
                        result FAIL suspend.devices "facetimehd is the device that failed"
                    else
                        result WARN suspend.devices \
                            "some device failed to suspend, but not facetimehd - see report"
                    fi
                fi
            elif [ "$timed_out" -eq 1 ]; then
                # Nobody closed the lid, or this machine does not suspend on
                # lid close. Either way the driver was never asked to do
                # anything, so this is not a failure of it.
                result SKIP suspend.entered \
                    "no suspend in ${LID_TIMEOUT}s - lid never closed, or this machine does not sleep on lid close"
            else
                result FAIL suspend.entered \
                    "resume seen but no 'PM: suspend entry' - suspend never started"
            fi

            sleep 3
            if kill -0 "$STREAM_PID" 2>/dev/null; then
                result INFO suspend.viewer "viewer still running after resume"
                kill "$STREAM_PID" 2>/dev/null || true
            else
                result PASS suspend.viewer \
                    "viewer exited on resume (expected: broken stream, not a hang)"
            fi
            wait "$STREAM_PID" 2>/dev/null || true
            STREAM_PID=""

            # The half that matters: a picture must come back afterwards.
            sleep 2
            if capture_ok 10; then
                result PASS suspend.recover "capture works again after resume"
            else
                result FAIL suspend.recover "camera does not recover after resume"
            fi
            dmesg_driver >>"$REPORT"
        fi
    fi
fi

# ============================================================================
# Section: wedged
# DOWNSTREAM.md - "A firmware command timeout (dev_priv->wedged)"
#
# There is no known way to make the firmware stop answering, so this cannot be
# provoked. It is observational: scan for the message and for the rate-limited
# buffer-return warnings, which are the other thing that should never appear
# on a healthy machine.
# ============================================================================
if wants wedged; then
    step "wedged: scanning for firmware-timeout and buffer-return warnings"
    log_section "SECTION wedged"

    full="$(dmesg 2>/dev/null | grep -i "$MODULE_NAME\|fthd" || true)"
    printf '%s\n' "$full" >>"$REPORT"

    if printf '%s' "$full" | grep -qi "firmware stopped responding"; then
        result FAIL wedged.timeout \
            "firmware stopped responding - the wedged path fired, capture the report"
    else
        result PASS wedged.timeout "no firmware timeout observed"
    fi

    if printf '%s' "$full" | grep -qi "unknown tag\|wrong entry count\|unreadable descriptor"; then
        result FAIL wedged.buffers \
            "buffer-return mismatches logged - firmware returned tags we did not submit"
    else
        result PASS wedged.buffers "no buffer-return mismatches"
    fi

    if printf '%s' "$full" | grep -qi "Firmware did not establish the required IPC channels"; then
        result FAIL wedged.ipc "IPC channel validation rejected the firmware's table"
    fi
fi

# ============================================================================
# Section: reboot (opt-in, two-phase)
# DOWNSTREAM.md - "Rebooting/kexec'ing with the camera streaming"
#
# fthd_pci_shutdown() runs at reboot instead of fthd_pci_remove(). It cannot
# be tested without actually rebooting, so this arms a marker, starts a
# stream and reboots; the next run reads the marker and checks the log.
# ============================================================================
if [ -f "$REBOOT_STATE" ]; then
    step "reboot: reading the verdict from the previous run"
    log_section "SECTION reboot (post-reboot check)"
    armed_at="$(cat "$REBOOT_STATE" 2>/dev/null || echo unknown)"
    rm -f "$REBOOT_STATE"

    # A clean shutdown path leaves no oops/warning in the previous boot's log.
    if have journalctl; then
        prev="$(journalctl -b -1 -k --no-pager 2>/dev/null || true)"
        if [ -z "$prev" ]; then
            result INFO reboot.prev "no previous boot in the journal to inspect"
        elif printf '%s' "$prev" | grep -qiE "call trace|kernel bug|oops|warn_on.*fthd|$MODULE_NAME.*warn"; then
            result FAIL reboot.clean \
                "previous boot logged a trace/oops around shutdown - see report"
            printf '%s\n' "$prev" | grep -iE -A20 "call trace|oops|$MODULE_NAME" >>"$REPORT"
        else
            result PASS reboot.clean \
                "machine rebooted while streaming (armed $armed_at) with a clean log"
        fi
    else
        result INFO reboot.clean \
            "rebooted while streaming (armed $armed_at); no journalctl to check the previous boot"
    fi
fi

if [ "$DO_REBOOT" = 1 ]; then
    step "reboot: arming the shutdown-path test"
    [ -n "$DEVICE" ] || wait_for_device || die "no video node to stream from"
    mkdir -p "$STATE_DIR"
    date -Is >"$REBOOT_STATE"
    warn "Starting a stream and rebooting. Re-run this script afterwards to"
    warn "read the verdict. Ctrl-C now to abort."
    if [ "$INTERACTIVE" = 1 ]; then
        confirm "Reboot now with the camera streaming?" || {
            rm -f "$REBOOT_STATE"; die "aborted"
        }
    fi
    v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=100000 \
             --stream-to=/dev/null >/dev/null 2>&1 &
    sleep 3
    sync
    systemctl reboot || reboot
    exit 0
fi

# ---------------------------------------------------------------- summary ----

log_section "SUMMARY"
printf '\n'
step "Summary"
for r in "${RESULTS[@]}"; do
    status="${r%%|*}"; rest="${r#*|}"
    id="${rest%%|*}"; msg="${rest#*|}"
    printf '  %-5s %-26s %s\n' "$status" "$id" "$msg"
    log "$(printf '%-5s %-26s %s' "$status" "$id" "$msg")"
done

printf '\n'
if [ "$FAILED" -eq 0 ]; then
    ok "No failures. Report: $REPORT"
    info "Items marked INFO/WARN still need a human to read them - especially"
    info "the timing profile and any luma numbers."
else
    error "Failures above. Report: $REPORT"
    error "Attach that file when reporting; it has the driver's dmesg output."
fi

if [ "$DMESG_WRAPPED" -eq 1 ]; then
    warn "The kernel ring buffer wrapped during this run, so some evidence was"
    warn "evicted before it could be read. This driver logs its whole DDR/PLL"
    warn "bring-up at dev_info on every runtime-PM resume, which is enough to"
    warn "fill the default buffer in a couple of minutes. Re-run with a bigger"
    warn "buffer for a trustworthy result:  log_buf_len=4M on the kernel cmdline"
fi

if ! wants suspend; then
    info "Not covered by this run: suspend-while-streaming."
fi
[ "$DO_REBOOT" = 1 ] || info "Not covered by this run: reboot while streaming (--reboot)."

exit "$FAILED"
