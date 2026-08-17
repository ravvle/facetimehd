#!/usr/bin/env bash
#
# Exercise the installer and uninstaller plumbing without a MacBook, without
# root and without touching the system.
#
# Linting catches syntax and quoting; it does not catch an option that was
# added to the help text and never wired into the case statement, a --status
# that dies on a machine with no camera, or an uninstaller that mishandles the
# DKMS version format it is given. Those are exactly the failures that only
# show up on a user's machine, so they get a test that runs in CI.
#
# Everything here is read-only with respect to the real system: the scripts are
# driven with FTHD_* environment overrides and a fake PATH, and anything that
# would write outside the sandbox is a test failure.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"

INSTALL="$REPO_DIR/scripts/install.sh"
UNINSTALL="$REPO_DIR/scripts/uninstall.sh"
EXTRACT="$REPO_DIR/scripts/extract-firmware.sh"
TUNE="$REPO_DIR/scripts/macbook-tune.sh"
DIAG="$REPO_DIR/scripts/collect-diagnostics.sh"
SETUP="$REPO_DIR/setup.sh"

pass=0
fail=0

result() {
    if [ "$1" = ok ]; then ok "$2"; pass=$((pass + 1))
    else bad "$2"; fail=$((fail + 1)); fi
}

# Run a command, capture everything, and report on its exit status.
expect_status() {
    local want="$1" name="$2"; shift 2
    local out rc=0
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" -eq "$want" ]; then
        result ok "$name (exit $rc)"
    else
        result bad "$name: expected exit $want, got $rc"
        printf '%s\n' "$out" | sed 's/^/      | /' | head -20
    fi
}

expect_output() {
    local pattern="$1" name="$2"; shift 2
    local out
    out="$("$@" 2>&1 || true)"
    if printf '%s\n' "$out" | grep -q -- "$pattern"; then
        result ok "$name"
    else
        result bad "$name: output did not contain '$pattern'"
        printf '%s\n' "$out" | sed 's/^/      | /' | head -20
    fi
}

WORK="$(mktemp -d -t fthd-script-smoke.XXXXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT

# ---------------------------------------------------------------------------
step "Help and usage"
# ---------------------------------------------------------------------------
#
# Every script must answer --help without root and without side effects. A
# non-zero exit here usually means set -u caught an unset variable on a path
# nobody runs interactively.

for s in "$INSTALL" "$UNINSTALL" "$EXTRACT" "$TUNE" "$DIAG" "$SETUP"; do
    expect_status 0 "$(basename "$s") --help" "$s" --help
done

# ---------------------------------------------------------------------------
step "Option parsing"
# ---------------------------------------------------------------------------
#
# An unknown option must be refused with exit 2 rather than silently ignored -
# a typo in a documented flag would otherwise run a full install with defaults.

expect_status 2 "install.sh rejects an unknown option" \
    "$INSTALL" --definitely-not-an-option
expect_status 2 "uninstall.sh rejects an unknown option" \
    "$UNINSTALL" --definitely-not-an-option
expect_status 2 "extract-firmware.sh rejects an unknown option" \
    "$EXTRACT" --definitely-not-an-option

# Every long option the help text advertises must actually be handled. This is
# the check that catches a flag documented and never wired up: an unhandled one
# falls through to the "Unknown option" arm and exits 2.
check_documented_options() {
    local script="$1" name opt out rc
    name="$(basename "$script")"
    while read -r opt; do
        [ -n "$opt" ] || continue
        # --help exits 0 by design; the rest are probed with a deliberately
        # invalid argument so they fail on their *own* validation, never on
        # having been treated as unknown.
        [ "$opt" = "--help" ] && continue
        rc=0
        out="$("$script" "$opt" 2>&1)" || rc=$?
        if printf '%s\n' "$out" | grep -q "Unknown option: $opt"; then
            result bad "$name: $opt is documented but not handled"
        else
            result ok "$name: $opt is handled"
        fi
    done < <("$script" --help 2>&1 | grep -oE '^\s+(-[a-zA-Z], )?--[a-z-]+' |
             grep -oE '\-\-[a-z-]+' | sort -u)
}

check_documented_options "$INSTALL"
check_documented_options "$UNINSTALL"
check_documented_options "$EXTRACT"
check_documented_options "$TUNE"

# ---------------------------------------------------------------------------
step "install.sh --status"
# ---------------------------------------------------------------------------
#
# --status must run to completion as a normal user on a machine with no camera,
# no DKMS and no firmware, and say so rather than dying. Exit 1 is the correct
# answer here - nothing is installed - so only a crash (or 0) is a failure.

status_rc=0
status_out="$("$INSTALL" --status 2>&1)" || status_rc=$?
if [ "$status_rc" -eq 1 ]; then
    result ok "--status reports an incomplete install with exit 1"
elif [ "$status_rc" -gt 1 ]; then
    result bad "--status crashed (exit $status_rc)"
    printf '%s\n' "$status_out" | sed 's/^/      | /' | head -20
else
    result bad "--status returned 0 on a machine with nothing installed"
fi

for want in 'System' 'Driver' 'Firmware' 'Secure Boot'; do
    if printf '%s\n' "$status_out" | grep -q "$want"; then
        result ok "--status reports on: $want"
    else
        result bad "--status is missing its '$want' section"
    fi
done

expect_status 1 "install.sh --runtime-pm takes only on/off" \
    "$INSTALL" --runtime-pm sideways

# ---------------------------------------------------------------------------
step "Root enforcement"
# ---------------------------------------------------------------------------
#
# The scripts that write to the system must refuse to run as a normal user.
# Skipped when the tests are themselves run as root, where the check cannot
# fire and asserting on it would be asserting on nothing.

if [ "$(id -u)" -ne 0 ]; then
    expect_output 'must be run as root' "install.sh requires root" \
        "$INSTALL" --skip-hw-check -y
    expect_output 'must be run as root' "uninstall.sh requires root" \
        "$UNINSTALL" -y
    expect_output 'must be run as root' "macbook-tune.sh requires root" \
        "$TUNE" -y
else
    info "running as root; skipping the root-refusal checks"
fi

# extract-firmware.sh --no-install is the documented root-free path, so it must
# get past the root check. Pointed at a driver file that does not exist so it
# stops on that rather than on the download: this test must not depend on
# Apple's CDN being reachable, which is what --check-sources is for.
expect_output 'No such driver file' \
    "extract-firmware.sh --no-install needs no root" \
    "$EXTRACT" --no-install -x "$WORK/does-not-exist"

# --dest with --no-install is contradictory and must be refused rather than
# silently ignoring one of them.
expect_status 2 "extract-firmware.sh rejects --dest with --no-install" \
    "$EXTRACT" --no-install --dest "$WORK/dest"

# ---------------------------------------------------------------------------
step "DKMS version parsing"
# ---------------------------------------------------------------------------
#
# uninstall.sh discovers what to remove by parsing 'dkms status'. That output
# has two formats in the wild - "name/version," on DKMS 3.x and "name, version,"
# on 2.x - and getting it wrong means leaving a registration behind while
# reporting success. Both are replayed here through a stub dkms on PATH.

make_stub_dkms() {
    local output="$1" dir="$2"
    mkdir -p -- "$dir"
    cat > "$dir/dkms" <<EOF
#!/bin/sh
# Stub dkms for tests. 'status' replays a recorded format; everything else
# succeeds silently so the uninstaller can walk its whole path.
case "\$1" in
    status) cat <<'DKMSEOF'
$output
DKMSEOF
        ;;
    *) exit 0 ;;
esac
EOF
    chmod +x -- "$dir/dkms"
}

check_dkms_format() {
    local label="$1" output="$2" want="$3"
    local dir="$WORK/stub-$label"
    make_stub_dkms "$output" "$dir"

    local found
    found="$(
        PATH="$dir:$PATH"
        MODULE_NAME=facetimehd
        dkms status -m "$MODULE_NAME" 2>/dev/null |
            sed -n -e "s|^${MODULE_NAME}/\([^,]*\),.*|\1|p" \
                   -e "s|^${MODULE_NAME}, \([^,]*\),.*|\1|p" |
            sort -u | tr '\n' ' '
    )"
    found="${found% }"

    if [ "$found" = "$want" ]; then
        result ok "dkms $label format parses to '$want'"
    else
        result bad "dkms $label format parsed to '$found', expected '$want'"
    fi
}

check_dkms_format '3.x' \
    'facetimehd/0.1+d0123456789ab, 6.8.0-1-generic, x86_64: installed' \
    '0.1+d0123456789ab'
check_dkms_format '2.x' \
    'facetimehd, 0.1+d0123456789ab, 6.8.0-1-generic, x86_64: installed' \
    '0.1+d0123456789ab'
check_dkms_format 'multi-version' \
    'facetimehd/0.1+daaaaaaaaaaa, 6.8.0-1-generic, x86_64: installed
facetimehd/0.1+dbbbbbbbbbbb, 6.9.0-1-generic, x86_64: installed' \
    '0.1+daaaaaaaaaaa 0.1+dbbbbbbbbbbb'

# ---------------------------------------------------------------------------
step "Driver source fingerprint"
# ---------------------------------------------------------------------------
#
# The fingerprint is what stops an edited source tree from reusing the DKMS
# version of a tree that was already built. If it ever stopped changing with
# the sources, every subsequent install would silently skip the rebuild.

fp1="$(driver_source_fingerprint "$REPO_DIR/src/facetimehd")"
cp -a -- "$REPO_DIR/src/facetimehd" "$WORK/driver"
fp2="$(driver_source_fingerprint "$WORK/driver")"
if [ "$fp1" = "$fp2" ]; then
    result ok "fingerprint is stable across an identical copy"
else
    result bad "fingerprint changed for an identical copy ($fp1 vs $fp2)"
fi

printf '\n/* smoke test */\n' >> "$WORK/driver/fthd_drv.c"
fp3="$(driver_source_fingerprint "$WORK/driver")"
if [ "$fp1" != "$fp3" ]; then
    result ok "fingerprint changes when a source file changes"
else
    result bad "fingerprint did not change after editing fthd_drv.c"
fi

# A file that is not compiled must not move the fingerprint: DOWNSTREAM.md
# changes on most driver commits, and rebuilding for a documentation edit would
# make the idempotency check worthless.
cp -a -- "$REPO_DIR/src/facetimehd" "$WORK/driver2"
printf '\ndocs only\n' >> "$WORK/driver2/DOWNSTREAM.md"
fp4="$(driver_source_fingerprint "$WORK/driver2")"
if [ "$fp1" = "$fp4" ]; then
    result ok "fingerprint ignores non-compiled files"
else
    result bad "fingerprint changed for a DOWNSTREAM.md edit"
fi

# ---------------------------------------------------------------------------
step "dkms.conf agrees with the Makefile"
# ---------------------------------------------------------------------------
#
# install.sh reads PACKAGE_VERSION out of dkms.conf and rewrites only the staged
# copy. If the name or version ever stopped parsing, the installer would build a
# directory DKMS then refuses to find.

conf="$REPO_DIR/src/facetimehd/dkms.conf"
ver="$(sed -n 's/^[[:space:]]*PACKAGE_VERSION=["'"'"']\{0,1\}\([^"'"'"']*\)["'"'"']\{0,1\}[[:space:]]*$/\1/p' "$conf" | head -n1)"
if [ -n "$ver" ]; then
    result ok "PACKAGE_VERSION parses as '$ver'"
else
    result bad "PACKAGE_VERSION could not be parsed from dkms.conf"
fi

# Every object the Makefile builds must have a matching source file, which is
# what catches a new .c added to one and not the other.
missing_src=0
while read -r obj; do
    [ -n "$obj" ] || continue
    [ -f "$REPO_DIR/src/facetimehd/${obj%.o}.c" ] || {
        result bad "Makefile builds $obj with no ${obj%.o}.c"
        missing_src=1
    }
done < <(sed -n 's/^facetimehd-objs *:= *//p' "$REPO_DIR/src/facetimehd/Makefile" | tr ' ' '\n')
[ "$missing_src" -eq 0 ] && result ok "every Makefile object has a source file"

# ...and the reverse: a source file added to the tree and never added to the
# Makefile compiles in no CI job and fails only on a user's machine.
unbuilt=0
objs="$(sed -n 's/^facetimehd-objs *:= *//p' "$REPO_DIR/src/facetimehd/Makefile")"
for src in "$REPO_DIR"/src/facetimehd/*.c; do
    base="$(basename "$src" .c)"
    case " $objs " in
        *" $base.o "*) ;;
        *) result bad "$base.c is not in facetimehd-objs"; unbuilt=1 ;;
    esac
done
[ "$unbuilt" -eq 0 ] && result ok "every source file is in facetimehd-objs"

# ---------------------------------------------------------------------------
echo
if [ "$fail" -eq 0 ]; then
    info "All $pass checks passed."
    exit 0
fi
warn "$fail of $((pass + fail)) checks failed."
exit 1
