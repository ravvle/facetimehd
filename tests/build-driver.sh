#!/usr/bin/env bash
#
# Compile the maintained driver tree against every kernel build tree.
#
# This is what CI runs against each supported Ubuntu release's headers, and it
# is runnable locally against whatever kernel you happen to have:
#
#   ./tests/build-driver.sh                       # all trees under /lib/modules
#   ./tests/build-driver.sh 7.0.0-14-generic      # one kernel
#   KDIR=/path/to/headers ./tests/build-driver.sh # an unpacked headers package
#   CC=gcc-14 ./tests/build-driver.sh             # a specific compiler
#   LLVM=1 ./tests/build-driver.sh                 # the LLVM toolchain
#   W=1 ./tests/build-driver.sh                    # extra kernel warnings
#   WERROR=1 ./tests/build-driver.sh              # fail on any compiler warning
#   SPARSE=1 ./tests/build-driver.sh               # sparse, warnings are errors
#
# Builds out-of-tree into a temporary directory, so src/ is never dirtied.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"

SRC="$REPO_DIR/src/facetimehd"
[ -f "$SRC/Makefile" ] || die "No driver source at $SRC"

BUILD_MAKE="${MAKE:-make}"
require_cmds "$BUILD_MAKE"
if [ -n "${SPARSE:-}" ]; then require_cmds sparse; fi

TMP="$(mktemp -d -t build-driver.XXXXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

# Collect the kernel build trees to try.
kdirs=()
if [ -n "${KDIR:-}" ]; then
    kdirs+=("$KDIR")
elif [ $# -gt 0 ]; then
    for k in "$@"; do kdirs+=("/lib/modules/$k/build"); done
else
    for d in /lib/modules/*/build; do [ -d "$d" ] && kdirs+=("$d"); done
fi

[ ${#kdirs[@]} -gt 0 ] || die "No kernel build tree found. Install linux-headers-\$(uname -r)."

rc=0
built=0
for kdir in "${kdirs[@]}"; do
    if [ ! -d "$kdir" ]; then
        error "no such build tree: $kdir"
        rc=1
        continue
    fi

    # Prefer the release the headers themselves declare; the directory name is
    # only meaningful for trees under /lib/modules.
    if [ -r "$kdir/include/config/kernel.release" ]; then
        kver="$(cat "$kdir/include/config/kernel.release")"
    else
        kver="$(basename "$(dirname "$kdir")")"
    fi
    step "Building against $kver"
    info "$kdir"

    obj="$TMP/${kver//\//_}"
    prepare_driver_source "$SRC" "$obj"

    # Forward toolchain selection when the caller pins it. A kernel built by
    # a different compiler family or version may reject unfamiliar flags.
    make_args=(-C "$kdir" M="$obj" modules)
    if [ -n "${CC:-}" ]; then make_args+=("CC=$CC"); fi
    if [ -n "${LLVM:-}" ]; then make_args+=("LLVM=$LLVM"); fi
    if [ -n "${W:-}" ]; then make_args+=("W=$W"); fi
    if [ -n "${WERROR:-}" ]; then make_args+=('KCFLAGS=-Werror'); fi
    if [ -n "${SPARSE:-}" ]; then
        make_args+=('C=2' 'CHECK=sparse' 'CF=-Wsparse-error')
    fi

    if "$BUILD_MAKE" "${make_args[@]}"; then
        if [ -f "$obj/facetimehd.ko" ]; then
            ok "facetimehd.ko built for $kver"
            if have modinfo; then
                modinfo "$obj/facetimehd.ko" |
                    grep -E '^(version|license|vermagic|firmware|alias)' || true
            fi
            built=$((built + 1))
        else
            error "make succeeded but facetimehd.ko is missing for $kver"
            rc=1
        fi
    else
        error "build failed for $kver"
        rc=1
    fi
    echo
done

if [ "$rc" -eq 0 ] && [ "$built" -gt 0 ]; then
    info "Built cleanly for $built kernel(s)."
else
    error "Driver build failed."
fi
exit "$rc"
