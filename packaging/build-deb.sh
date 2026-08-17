#!/usr/bin/env bash
#
# Build facetimehd-dkms_<version>_all.deb.
#
# Built with dpkg-deb from a staging tree rather than with debhelper, because
# the package is only a source tree plus DKMS maintainer scripts and pulling in
# the whole Debian build toolchain to express that would need dpkg-dev,
# debhelper and dkms on the build host for no gain. dpkg-deb is in dpkg itself,
# which every Debian-family system already has.
#
# Needs no root: the staging tree's ownership is set by dpkg-deb.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"

MODULE_NAME=facetimehd
PKG_NAME="${MODULE_NAME}-dkms"
OUT_DIR="$SCRIPT_DIR/out"
DRIVER_SRC="$REPO_DIR/src/$MODULE_NAME"

require_cmds dpkg-deb sed install

[ -f "$DRIVER_SRC/dkms.conf" ] || die "No driver source at $DRIVER_SRC"
VERSION="$(sed -n 's/^[[:space:]]*PACKAGE_VERSION=["'"'"']\{0,1\}\([^"'"'"']*\)["'"'"']\{0,1\}[[:space:]]*$/\1/p' \
               "$DRIVER_SRC/dkms.conf" | head -n1)"
[ -n "$VERSION" ] || die "Could not read PACKAGE_VERSION from $DRIVER_SRC/dkms.conf"

step "Building $PKG_NAME $VERSION (deb)"

STAGE="$(mktemp -d -t facetimehd-deb.XXXXXXXX)"
trap 'rm -rf -- "$STAGE"' EXIT
# mktemp -d makes a 0700 directory, and dpkg-deb faithfully records that as the
# mode of the package's root - which dpkg then applies to /, breaking the system.
chmod 755 -- "$STAGE"

SRC_INSTALL="$STAGE/usr/src/${MODULE_NAME}-${VERSION}"
install -d -m 755 \
    "$STAGE/DEBIAN" \
    "$SRC_INSTALL" \
    "$STAGE/usr/bin" \
    "$STAGE/usr/share/doc/$PKG_NAME" \
    "$STAGE/usr/share/$PKG_NAME"

# The driver tree, exactly as it is built from everywhere else, minus the files
# that only mean something in a git checkout.
cp -a -- "$DRIVER_SRC/." "$SRC_INSTALL/"
rm -f -- "$SRC_INSTALL/.gitignore"

# The firmware extractor and the shared library it sources, so the wrapper below
# has something to call. Installed under /usr/share rather than /usr/bin because
# they are implementation, not the interface.
install -d -m 755 "$STAGE/usr/share/$PKG_NAME/lib"
install -m 755 "$REPO_DIR/scripts/extract-firmware.sh" "$STAGE/usr/share/$PKG_NAME/"
install -m 644 "$REPO_DIR/scripts/lib/common.sh" "$STAGE/usr/share/$PKG_NAME/lib/"

cat > "$STAGE/usr/bin/facetimehd-firmware-install" <<EOF
#!/bin/sh
# Fetch and install the Apple camera firmware. Separate from the package
# because the firmware is proprietary and cannot be redistributed, and because
# a post-install script has no business reaching the network.
exec /usr/share/$PKG_NAME/extract-firmware.sh --with-calibration "\$@"
EOF
chmod 755 "$STAGE/usr/bin/facetimehd-firmware-install"

install -m 644 "$REPO_DIR/LICENSE" "$STAGE/usr/share/doc/$PKG_NAME/copyright"
install -m 644 "$REPO_DIR/README.md" "$STAGE/usr/share/doc/$PKG_NAME/"

# Installed-Size is what dpkg reports before download; getting it roughly right
# costs one du.
INSTALLED_KB="$(du -ks "$STAGE" | cut -f1)"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION
Architecture: all
Maintainer: facetimehd contributors <https://github.com/ravvle/facetimehd>
Section: kernel
Priority: optional
Installed-Size: $INSTALLED_KB
Depends: dkms (>= 2.8)
Recommends: v4l-utils, unar
Suggests: mbpfan
Homepage: https://github.com/ravvle/facetimehd
Description: Apple FaceTime HD (BCM1570) camera driver (DKMS)
 Builds the facetimehd kernel module for the Broadcom BCM1570 PCIe camera
 found in 2013-2015 Intel MacBooks, via DKMS, so it is rebuilt automatically
 for each new kernel.
 .
 The camera also needs Apple's proprietary firmware, which cannot be
 redistributed and is therefore not in this package. After installing, run
 facetimehd-firmware-install once to fetch it from Apple.
EOF

cat > "$STAGE/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e

NAME=$MODULE_NAME
VERSION=$VERSION

case "\$1" in
configure)
    # dkms remove first: an interrupted upgrade can leave the same version
    # half-registered, and dkms add then fails rather than recovering.
    if dkms status -m "\$NAME" -v "\$VERSION" 2>/dev/null | grep -q .; then
        dkms remove -m "\$NAME" -v "\$VERSION" --all >/dev/null 2>&1 || true
    fi
    dkms add -m "\$NAME" -v "\$VERSION" || exit 1
    # Build failures are reported but do not fail the package install: the
    # usual cause is missing kernel headers, which the user can fix and then
    # re-run dkms autoinstall. Failing here would leave the package
    # half-configured and block every other package operation.
    if dkms build -m "\$NAME" -v "\$VERSION" && \\
       dkms install -m "\$NAME" -v "\$VERSION" --force; then
        echo "facetimehd: module built for \$(uname -r)"
    else
        echo "facetimehd: DKMS build failed - install the headers for your" >&2
        echo "            kernel (linux-headers-\$(uname -r)) and run" >&2
        echo "            'dkms autoinstall'." >&2
    fi

    if [ ! -s /usr/lib/firmware/\$NAME/firmware.bin ] &&
       [ ! -s /lib/firmware/\$NAME/firmware.bin ]; then
        echo ""
        echo "facetimehd: the camera firmware is NOT installed."
        echo "            It is Apple's and cannot be shipped in a package."
        echo "            Run: sudo facetimehd-firmware-install"
        echo ""
    fi
    ;;
esac

exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e

NAME=$MODULE_NAME
VERSION=$VERSION

case "\$1" in
remove|upgrade|deconfigure)
    if dkms status -m "\$NAME" -v "\$VERSION" 2>/dev/null | grep -q .; then
        dkms remove -m "\$NAME" -v "\$VERSION" --all >/dev/null 2>&1 || true
    fi
    ;;
esac

exit 0
EOF
chmod 755 "$STAGE/DEBIAN/prerm"

# The firmware is not ours to remove on purge: the user fetched it from Apple
# themselves and it is shared with any other install of this driver.
cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e

case "$1" in
purge)
    echo "facetimehd: the Apple firmware under /lib/firmware/facetimehd was"
    echo "            left in place. Remove it by hand if you want it gone."
    ;;
esac

exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postrm"

mkdir -p -- "$OUT_DIR"
DEB="$OUT_DIR/${PKG_NAME}_${VERSION}_all.deb"
# --root-owner-group avoids needing fakeroot for what is a tree of ordinary
# files that all belong to root anyway.
dpkg-deb --root-owner-group --build "$STAGE" "$DEB" >/dev/null

ok "Built $DEB"
info "Install with: sudo apt install $DEB"
info "Then fetch the firmware: sudo facetimehd-firmware-install"
