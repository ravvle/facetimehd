# shellcheck shell=bash
#
# Shared helpers for the facetimehd scripts.
# Sourced, never executed directly.

[ -n "${_FTHD_COMMON_SH:-}" ] && return 0
_FTHD_COMMON_SH=1

# --- Output -----------------------------------------------------------------

# Colour only when stdout is a terminal and the user has not opted out.
# https://no-color.org/
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'; C_OFF=$'\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_OFF=''
fi

info()  { printf '%s[INFO]%s %s\n'  "$C_GREEN"  "$C_OFF" "$*"; }
step()  { printf '%s[==>]%s %s\n'   "$C_BLUE"   "$C_OFF" "$*"; }
warn()  { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_OFF" "$*" >&2; }
error() { printf '%s[ERROR]%s %s\n' "$C_RED"    "$C_OFF" "$*" >&2; }
die()   { error "$@"; exit 1; }
ok()    { printf '%s  ✓%s %s\n'     "$C_GREEN"  "$C_OFF" "$*"; }
bad()   { printf '%s  ✗%s %s\n'     "$C_YELLOW" "$C_OFF" "$*"; }

# --- Preconditions ----------------------------------------------------------

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must be run as root (use sudo)."
}

have() { command -v "$1" >/dev/null 2>&1; }

require_cmds() {
    local missing=() c
    for c in "$@"; do have "$c" || missing+=("$c"); done
    [ ${#missing[@]} -eq 0 ] || die "Missing required command(s): ${missing[*]}"
}

# Copy the maintained driver tree to a disposable build tree. What is in src/
# is what gets built.
prepare_driver_source() {
    local source_dir="$1" dest_dir="$2"

    [ -f "$source_dir/Makefile" ] || die "No driver source at $source_dir"
    source_dir="$(cd -- "$source_dir" && pwd)"
    mkdir -p -- "$dest_dir"
    dest_dir="$(cd -- "$dest_dir" && pwd)"
    cp -a -- "$source_dir/." "$dest_dir/"
}

# A short content identity for the driver tree.  It becomes part of the DKMS
# version so editing a source file can never be mistaken for an already-built
# tree.
#
# Only the files that go into the module are hashed: dkms.conf carries the
# version this feeds into, and the docs alongside the source do not change what
# is compiled.  Names are hashed with the contents so a rename is a change.
driver_source_fingerprint() {
    local source_dir="$1" f files=()

    [ -f "$source_dir/Makefile" ] || die "No driver source at $source_dir"
    source_dir="$(cd -- "$source_dir" && pwd)"

    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(cd -- "$source_dir" && find . -type f \
        \( -name '*.c' -o -name '*.h' -o -name 'Makefile' \) -print0 | sort -z)
    [ ${#files[@]} -gt 0 ] || die "No driver sources found in $source_dir"

    {
        for f in "${files[@]}"; do
            printf '%s\0%s\0' "$f" "$(sha256sum "$source_dir/${f#./}" | cut -d' ' -f1)"
        done
    } | sha256sum | cut -c1-12
}

# Ask for confirmation unless ASSUME_YES=1.
confirm() {
    [ "${ASSUME_YES:-0}" = "1" ] && return 0
    local reply
    printf '%s [y/N] ' "$1"
    read -r reply || return 1
    [[ $reply =~ ^[Yy]$ ]]
}

# --- Platform detection -----------------------------------------------------

# Populates OS_ID, OS_ID_LIKE, OS_VERSION_ID, OS_PLATFORM_ID, OS_PRETTY from
# /etc/os-release.
#
# The file is sourced in a *subshell*, not here: it is a shell fragment that
# defines NAME, VERSION, LOGO, SUPPORT_END and whatever else a distribution
# felt like adding, none of which belongs in the calling script's namespace.
# Only the five fields below cross back. The result is cached because
# is_debian_like/is_rpm_like call this on every invocation and /etc/os-release
# does not change underneath a running script.
# shellcheck disable=SC2034  # OS_* are read by the scripts that source this file
detect_os() {
    [ -n "${_FTHD_OS_CACHED:-}" ] && return 0
    OS_ID=''; OS_ID_LIKE=''; OS_VERSION_ID=''; OS_PLATFORM_ID=''; OS_PRETTY=''
    _FTHD_OS_CACHED=1
    [ -r /etc/os-release ] || return 0
    {
        IFS= read -r OS_ID
        IFS= read -r OS_ID_LIKE
        IFS= read -r OS_VERSION_ID
        IFS= read -r OS_PLATFORM_ID
        IFS= read -r OS_PRETTY
    } < <(
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s\n%s\n%s\n%s\n%s\n' "${ID:-}" "${ID_LIKE:-}" "${VERSION_ID:-}" \
            "${PLATFORM_ID:-}" "${PRETTY_NAME:-${ID:-} ${VERSION_ID:-}}"
    )
}

is_debian_like() {
    detect_os
    case " $OS_ID $OS_ID_LIKE " in
        *" debian "*|*" ubuntu "*) return 0 ;;
    esac
    [ "$OS_ID" = debian ] || [ "$OS_ID" = ubuntu ]
}

# Fedora and its derivatives. Fedora itself carries no ID_LIKE at all, hence
# the explicit ID check; the rhel/centos arms catch the enterprise rebuilds,
# which use the same package names.
is_rpm_like() {
    detect_os
    case " $OS_ID $OS_ID_LIKE " in
        *" fedora "*|*" rhel "*|*" centos "*) return 0 ;;
    esac
    [ "$OS_ID" = fedora ]
}

# Enterprise Linux - RHEL and its rebuilds (AlmaLinux, Rocky, CentOS Stream,
# Oracle) - as opposed to Fedora. Both are is_rpm_like, but only these need
# EPEL: Red Hat ships a deliberately small package set, and dkms is not in it.
#
# AlmaLinux sets ID_LIKE="rhel centos fedora", so the fedora arm of is_rpm_like
# matches it too; that is why Fedora is excluded by ID *first* rather than by
# letting the case below decide. A Fedora derivative that inherits only
# ID_LIKE="fedora" falls through to 1, which is what we want - it has dkms.
is_enterprise_linux() {
    detect_os
    [ "$OS_ID" = fedora ] && return 1
    case " $OS_ID $OS_ID_LIKE " in
        *" rhel "*|*" centos "*) return 0 ;;
    esac
    return 1
}

# Major EL release ("10"), empty when it cannot be determined.
#
# PLATFORM_ID is the field to read: it is "platform:el10" on RHEL and on every
# rebuild of it, and it stays correct across point releases, where VERSION_ID
# has already become "10.1". VERSION_ID is the fallback for the rebuilds that
# omit PLATFORM_ID.
el_major_version() {
    detect_os
    case "$OS_PLATFORM_ID" in
        platform:el*) printf '%s\n' "${OS_PLATFORM_ID#platform:el}"; return 0 ;;
    esac
    # The VERSION_ID fallback is only meaningful on an EL rebuild. Everywhere
    # else that major number counts something else entirely - Fedora 44, Ubuntu
    # 24.04 - and an epel-release-latest-24 URL is not a useful thing to build.
    is_enterprise_linux || return 1
    [ -n "$OS_VERSION_ID" ] || return 1
    printf '%s\n' "${OS_VERSION_ID%%.*}"
}

# --- Package management -----------------------------------------------------
#
# Only the handful of operations the scripts actually need. Package *names*
# differ per family too, so callers pick those themselves; this layer only
# abstracts the verbs.

# Prints "apt" or "dnf" and returns non-zero when neither is usable.
pkg_manager() {
    if have apt-get; then printf 'apt\n'
    elif have dnf; then printf 'dnf\n'
    elif have yum; then printf 'dnf\n'   # driven through the dnf-compatible CLI
    else return 1
    fi
}

_pkg_cmd() {
    if have dnf; then printf 'dnf\n'; else printf 'yum\n'; fi
}

# Refresh the package metadata. Deliberately non-fatal on both families: a
# single unreachable mirror or one stale third-party repository should not
# abort an install that the package lists already on disk can satisfy. If a
# package really is missing, pkg_install fails right afterwards and says so.
pkg_refresh() {
    case "$(pkg_manager)" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update ||
                 warn "apt-get update failed; continuing with the package lists already on disk." ;;
        dnf) "$(_pkg_cmd)" -y makecache --refresh >/dev/null ||
                 warn "dnf makecache failed; continuing with the metadata already on disk." ;;
        *)   return 1 ;;
    esac
}

pkg_install() {
    [ $# -gt 0 ] || return 0
    case "$(pkg_manager)" in
        apt) DEBIAN_FRONTEND=noninteractive \
                 apt-get install -y --no-install-recommends "$@" ;;
        dnf) "$(_pkg_cmd)" install -y --setopt=install_weak_deps=False "$@" ;;
        *)   return 1 ;;
    esac
}

# Is this package name resolvable in the configured repositories? Used to tell
# "not installed yet" apart from "not packaged for this distribution at all",
# which are worth different messages.
pkg_available() {
    case "$(pkg_manager)" in
        apt) apt-cache show "$1" >/dev/null 2>&1 ;;
        dnf) "$(_pkg_cmd)" -q list --available "$1" >/dev/null 2>&1 ||
             "$(_pkg_cmd)" -q list --installed "$1" >/dev/null 2>&1 ;;
        *)   return 1 ;;
    esac
}

pkg_installed() {
    case "$(pkg_manager)" in
        apt) dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null |
                 grep -q '^installed$' ;;
        dnf) rpm -q "$1" >/dev/null 2>&1 ;;
        *)   return 1 ;;
    esac
}

# --- EPEL, on Enterprise Linux ----------------------------------------------
#
# This is the one place where the package layer knows a package *name* rather
# than only a verb, and the exception is deliberate: "enable EPEL" is a verb,
# epel-release is the same name on every RHEL rebuild, and both install.sh
# (dkms) and macbook-tune.sh (mbpfan) need it. Splitting it between them would
# put the same three-repository dance in two files.

# Is this dnf repository configured *and* enabled?
dnf_repo_enabled() {
    have dnf || have yum || return 1
    "$(_pkg_cmd)" repolist --enabled 2>/dev/null |
        awk -v want="$1" 'NR > 1 && $1 == want { found = 1 } END { exit !found }'
}

# dnf5 (EL10) replaced 'config-manager --set-enabled' with 'config-manager
# setopt'; dnf4 (EL9, Fedora before 41) understands only the former. Try both
# rather than working out which generation this system has.
_enable_crb_once() {
    "$(_pkg_cmd)" config-manager --set-enabled crb >/dev/null 2>&1 ||
    "$(_pkg_cmd)" config-manager setopt crb.enabled=1 >/dev/null 2>&1
}

# CodeReady Builder, Red Hat's build-dependency repository.
#
# Nothing this project installs comes from CRB directly - elfutils-libelf-devel
# is in AppStream on EL10 - but a large part of EPEL build-depends on it, so
# EPEL packages can fail to resolve while it is off. AlmaLinux has enabled it by
# default since 2025-09; this is for the installs made before that and for the
# rebuilds that have not followed.
#
# Best-effort by design: a failure here is not worth stopping for, because the
# dependency install that follows reports exactly which package could not be
# resolved, which is more useful than anything guessed at this point.
enable_crb() {
    dnf_repo_enabled crb && return 0

    _enable_crb_once || {
        # config-manager is a plugin, and a minimal install may not have it.
        # The package is named for the dnf generation that provides it.
        pkg_install dnf-plugins-core >/dev/null 2>&1 ||
            pkg_install dnf5-plugins >/dev/null 2>&1 || true
        _enable_crb_once || true
    }

    dnf_repo_enabled crb
}

# Make EPEL available, on the distributions that need it. A no-op on Fedora and
# on the Debian family, so callers do not have to ask first.
#
# Returns 0 when EPEL is usable afterwards and 1 when it is not. Callers treat
# that as advisory for the same reason enable_crb is best-effort: pkg_install
# is what actually discovers a missing package, and it says which one.
ensure_epel() {
    is_enterprise_linux || return 0

    if dnf_repo_enabled epel; then
        enable_crb || true
        return 0
    fi

    enable_crb || true

    # AlmaLinux, Rocky and CentOS Stream carry epel-release in their own
    # 'extras' repository, which is enabled out of the box, so this is all it
    # takes there.
    if pkg_install epel-release >/dev/null 2>&1 && dnf_repo_enabled epel; then
        return 0
    fi

    # RHEL proper has no epel-release of its own; it is fetched from the
    # project. The URL is keyed by the EL major version and is the one EPEL
    # documents, so there is no version list to keep here.
    local major
    major="$(el_major_version)" || return 1
    [ -n "$major" ] || return 1
    pkg_install \
        "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major}.noarch.rpm" \
        >/dev/null 2>&1 || return 1

    dnf_repo_enabled epel
}

# PCI ID of the Broadcom 1570 ISP behind the FaceTime HD camera.
readonly FTHD_PCI_ID='14e4:1570'

has_facetimehd_hardware() {
    have lspci || return 2                      # cannot tell
    [ -n "$(lspci -d "$FTHD_PCI_ID" 2>/dev/null)" ]
}

# Apple hardware, by DMI rather than by the camera: macbook-tune.sh configures
# the keyboard and the fans, which every Intel Mac has and which outlive the
# 2013-2015 camera this project is named after. Returns 2 when DMI cannot be
# read at all (a container, an unusual firmware), because that is not the same
# answer as "no".
is_apple_hardware() {
    local vendor
    [ -r /sys/class/dmi/id/sys_vendor ] || return 2
    read -r vendor < /sys/class/dmi/id/sys_vendor || return 2
    case "$vendor" in Apple*) return 0 ;; esac
    return 1
}

# Model string from DMI ("MacBookPro11,1"), empty when unavailable.
dmi_product_name() {
    local name
    [ -r /sys/class/dmi/id/product_name ] || return 0
    read -r name < /sys/class/dmi/id/product_name || return 0
    printf '%s\n' "$name"
}

# Ubuntu, Debian and the Fedora/RHEL family have all been usr-merged for years,
# so these are the same directory; resolve it the same way the upstream firmware
# Makefile does so the paths we print match the paths it writes.
firmware_root() {
    if [ -d /usr/lib/firmware ]; then printf '/usr/lib/firmware\n'
    else printf '/lib/firmware\n'; fi
}

# --- systemd ----------------------------------------------------------------

unit_exists() {
    have systemctl || return 1
    systemctl list-unit-files "$1" >/dev/null 2>&1 &&
        [ -n "$(systemctl list-unit-files --no-legend "$1" 2>/dev/null)" ]
}
