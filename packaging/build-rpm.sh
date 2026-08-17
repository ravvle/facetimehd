#!/usr/bin/env bash
#
# Build facetimehd-dkms-<version>-1.noarch.rpm.
#
# Needs rpmbuild (rpm-build). Runs as a normal user: the build tree is created
# under a temporary directory rather than in ~/rpmbuild, so this leaves nothing
# behind on the build host.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"

MODULE_NAME=facetimehd
PKG_NAME="${MODULE_NAME}-dkms"
OUT_DIR="$SCRIPT_DIR/out"
DRIVER_SRC="$REPO_DIR/src/$MODULE_NAME"
SPEC_IN="$SCRIPT_DIR/${PKG_NAME}.spec.in"

require_cmds rpmbuild sed tar install

[ -f "$DRIVER_SRC/dkms.conf" ] || die "No driver source at $DRIVER_SRC"
[ -f "$SPEC_IN" ] || die "No spec template at $SPEC_IN"

VERSION="$(sed -n 's/^[[:space:]]*PACKAGE_VERSION=["'"'"']\{0,1\}\([^"'"'"']*\)["'"'"']\{0,1\}[[:space:]]*$/\1/p' \
               "$DRIVER_SRC/dkms.conf" | head -n1)"
[ -n "$VERSION" ] || die "Could not read PACKAGE_VERSION from $DRIVER_SRC/dkms.conf"

step "Building $PKG_NAME $VERSION (rpm)"

WORK="$(mktemp -d -t facetimehd-rpm.XXXXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT

mkdir -p -- "$WORK"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# The source tarball rpmbuild unpacks. Only what the spec actually installs goes
# in, so the tarball is not a copy of the whole repository.
TARDIR="$WORK/${PKG_NAME}-${VERSION}"
mkdir -p -- "$TARDIR/src" "$TARDIR/scripts/lib"
cp -a -- "$DRIVER_SRC" "$TARDIR/src/"
install -m 755 "$REPO_DIR/scripts/extract-firmware.sh" "$TARDIR/scripts/"
install -m 644 "$REPO_DIR/scripts/lib/common.sh" "$TARDIR/scripts/lib/"
install -m 644 "$REPO_DIR/LICENSE" "$TARDIR/"
install -m 644 "$REPO_DIR/README.md" "$TARDIR/"

tar -C "$WORK" -czf "$WORK/SOURCES/${PKG_NAME}-${VERSION}.tar.gz" \
    "${PKG_NAME}-${VERSION}"

SPEC="$WORK/SPECS/${PKG_NAME}.spec"
sed "s/@VERSION@/$VERSION/g" "$SPEC_IN" > "$SPEC"

rpmbuild --define "_topdir $WORK" -bb "$SPEC" >"$WORK/rpmbuild.log" 2>&1 || {
    error "rpmbuild failed:"
    tail -40 "$WORK/rpmbuild.log" >&2
    exit 1
}

mkdir -p -- "$OUT_DIR"
found=0
while IFS= read -r rpm; do
    install -m 644 "$rpm" "$OUT_DIR/"
    ok "Built $OUT_DIR/$(basename "$rpm")"
    found=1
done < <(find "$WORK/RPMS" -name '*.rpm' -type f)

[ "$found" -eq 1 ] || die "rpmbuild reported success but produced no package."

info "Install with: sudo dnf install $OUT_DIR/${PKG_NAME}-${VERSION}-1*.rpm"
info "Then fetch the firmware: sudo facetimehd-firmware-install"
