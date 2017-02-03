#!/bin/bash

# Toolchain packages are treated a bit specially, since they take a
# while to build and are generally more complicated to build they are
# only built via catalyst and everyone else installs them as binpkgs.
TOOLCHAIN_PKGS=(
    sys-devel/binutils
    sys-devel/gcc
    sys-kernel/linux-headers
    sys-libs/glibc
)

# Portage profile to use for building out the cross compiler's SYSROOT.
# This is only used as an intermediate step to be able to use the cross
# compiler to build a full native toolchain. Packages are not uploaded.
declare -A CROSS_PROFILES
CROSS_PROFILES["x86_64-cros-linux-gnu"]="coreos:coreos/amd64/generic"
CROSS_PROFILES["aarch64-cros-linux-gnu"]="coreos:coreos/arm64/generic"
CROSS_PROFILES["powerpc64le-unknown-linux-gnu"]="ppc64le:coreos/ppc64le/generic"

# Map board names to CHOSTs and portage profiles. This is the
# definitive list, there is assorted code new and old that either
# guesses or hard-code these. All that should migrate to this list.
declare -A BOARD_CHOSTS BOARD_PROFILES
BOARD_CHOSTS["amd64-usr"]="x86_64-cros-linux-gnu"
BOARD_PROFILES["amd64-usr"]="coreos:coreos/amd64/generic"

BOARD_CHOSTS["arm64-usr"]="aarch64-cros-linux-gnu"
BOARD_PROFILES["arm64-usr"]="coreos:coreos/arm64/generic"

BOARD_CHOSTS["ppc64le-usr"]="powerpc64le-unknown-linux-gnu"
BOARD_PROFILES["ppc64le-usr"]="ppc64le:coreos/ppc64le/generic"

BOARD_NAMES=( "${!BOARD_CHOSTS[@]}" )

# Declare the above globals as read-only to avoid accidental conflicts.
declare -r \
    TOOLCHAIN_PKGS \
    CROSS_PROFILES \
    BOARD_CHOSTS \
    BOARD_NAMES \
    BOARD_PROFILES

### Generic metadata fetching functions ###

# map CHOST to portage ARCH, list came from crossdev
# Usage: get_portage_arch chost
get_portage_arch() {
    case "$1" in
        aarch64*)   echo arm64;;
        alpha*)     echo alpha;;
        arm*)       echo arm;;
        hppa*)      echo hppa;;
        ia64*)      echo ia64;;
        i?86*)      echo x86;;
        m68*)       echo m68k;;
        mips*)      echo mips;;
        powerpc64*) echo ppc64;;
        ppc64le*)     echo ppc64le;;
        powerpc*)   echo ppc;;
        sparc*)     echo sparc;;
        s390*)      echo s390;;
        sh*)        echo sh;;
        x86_64*)    echo amd64;;
        *)          die "Unknown CHOST '$1'";;
    esac
}

# map CHOST to kernel ARCH
# Usage: get_kernel_arch chost
get_kernel_arch() {
    case "$1" in
        aarch64*)   echo arm64;;
        alpha*)     echo alpha;;
        arm*)       echo arm;;
        hppa*)      echo parisc;;
        ia64*)      echo ia64;;
        i?86*)      echo x86;;
        m68*)       echo m68k;;
        mips*)      echo mips;;
        powerpc*)   echo powerpc;;
        sparc64*)   echo sparc64;;
        sparc*)     echo sparc;;
        s390*)      echo s390;;
        sh*)        echo sh;;
        x86_64*)    echo x86;;
        *)          die "Unknown CHOST '$1'";;
    esac
}

get_board_list() {
    local IFS=$'\n\t '
    sort <<<"${BOARD_NAMES[*]}"
}

get_chost_list() {
    local IFS=$'\n\t '
    sort -u <<<"${BOARD_CHOSTS[*]}"
}

get_profile_list() {
    local IFS=$'\n\t '
    sort -u <<<"${BOARD_PROFILES[*]}"
}

# Usage: get_board_arch board [board...]
get_board_arch() {
    local board
    for board in "$@"; do
        get_portage_arch $(get_board_chost "${board}")
    done
}

# Usage: get_board_chost board [board...]
get_board_chost() {
    local board
    for board in "$@"; do
        if [[ ${#BOARD_CHOSTS["$board"]} -ne 0 ]]; then
            echo "${BOARD_CHOSTS["$board"]}"
        else
            die "Unknown board '$board'"
        fi
    done
}

# Usage: get_board_profile board [board...]
get_board_profile() {
    local board
    for board in "$@"; do
        if [[ ${#BOARD_PROFILES["$board"]} -ne 0 ]]; then
            echo "${BOARD_PROFILES["$board"]}"
        else
            die "Unknown board '$board'"
        fi
    done
}

# Usage: get_board_binhost [-t] board [version...]
# -t: toolchain only, full rebuilds re-using toolchain pkgs
# If no versions are specified the current and SDK versions are used.
get_board_binhost() {
    local toolchain_only=0 board ver
    if [[ "$1" == "-t" ]]; then
        toolchain_only=1
        shift
    fi
    board="$1"
    shift

    if [[ $# -eq 0 ]]; then
        set -- "${COREOS_SDK_VERSION}" "${COREOS_VERSION_ID}"
    fi

    for ver in "$@"; do
        if [[ $toolchain_only -eq 0 ]]; then
            echo "${COREOS_DEV_BUILDS}/boards/${board}/${ver}/pkgs/"
        fi
        echo "${COREOS_DEV_BUILDS}/boards/${board}/${ver}/toolchain/"
    done
}

get_sdk_arch() {
    get_portage_arch $(uname -m)
}

get_sdk_profile() {
    if [[ "$(get_sdk_arch)" == "ppc64le" ]]; then
        echo "ppc64le:coreos/$(get_sdk_arch)/sdk"
    else
        echo "coreos:coreos/$(get_sdk_arch)/sdk"
    fi
}

get_sdk_libdir() {
    # Looking for LIBDIR_amd64 or similar
    portageq envvar "LIBDIR_$(get_sdk_arch)"
}

# Usage: get_sdk_binhost [version...]
# If no versions are specified the current and SDK versions are used.
get_sdk_binhost() {
    local arch=$(get_sdk_arch) ver
    if [[ $# -eq 0 ]]; then
        set -- "${COREOS_SDK_VERSION}" "${COREOS_VERSION_ID}"
    fi

    for ver in "$@"; do
        echo "${COREOS_DEV_BUILDS}/sdk/${arch}/${ver}/pkgs/"
        echo "${COREOS_DEV_BUILDS}/sdk/${arch}/${ver}/toolchain/"
    done
}

# Usage: get_cross_pkgs chost [chost2...]
get_cross_pkgs() {
    local cross_chost native_pkg
    for cross_chost in "$@"; do
        for native_pkg in "${TOOLCHAIN_PKGS[@]}"; do
            echo "${native_pkg/*\//cross-${cross_chost}/}"
        done
    done
}

# Get portage arguments restricting toolchains to binary packages only.
get_binonly_args() {
    local pkgs=( "${TOOLCHAIN_PKGS[@]}" $(get_cross_pkgs "$@") )
    echo "${pkgs[@]/#/--useoldpkg-atoms=}" "${pkgs[@]/#/--rebuild-exclude=}"
}

### Toolchain building utilities ###

# Create the crossdev overlay and repos.conf entry.
# crossdev will try to setup this itself but doesn't do everything needed
# to make the newer repos.conf based configuration system happy. This can
# probably go away if crossdev itself is improved.
configure_crossdev_overlay() {
    local root="$1"
    local location="$2"

    # may be called from either catalyst (root) or update_chroot (user)
    local sudo="env"
    if [[ $(id -u) -ne 0 ]]; then
        sudo="sudo -E"
    fi

    $sudo mkdir -p "${root}${location}/"{profiles,metadata}
    echo "x-crossdev" | \
        $sudo tee "${root}${location}/profiles/repo_name" > /dev/null
    $sudo tee "${root}${location}/metadata/layout.conf" > /dev/null <<EOF
masters = portage-stable coreos
use-manifests = true
thin-manifests = true
EOF

    $sudo tee "${root}/etc/portage/repos.conf/crossdev.conf" > /dev/null <<EOF
[x-crossdev]
location = ${location}
EOF
}

# Ugly hack to get a dependency list of a set of packages.
# This is required to figure out what to install in the crossdev sysroot.
# Usage: ROOT=/foo/bar _get_dependency_list pkgs... [--portage-opts...]
_get_dependency_list() {
    local pkgs=( ${*/#-*/} )
    local IFS=$'| \t\n'

    PORTAGE_CONFIGROOT="$ROOT" emerge "$@" --pretend \
        --emptytree --root-deps=rdeps --onlydeps --quiet | \
        sed -e 's/[^]]*\] \([^ :]*\).*/=\1/' |
        egrep -v "(=$(echo "${pkgs[*]}")-[0-9])"
}

# Configure a new ROOT
# Values are copied from the environment or the current host configuration.
# Usage: CBUILD=foo-bar-linux-gnu ROOT=/foo/bar SYSROOT=/foo/bar configure_portage coreos:some/profile
# Note: if using portageq to get CBUILD it must be called before CHOST is set.
_configure_sysroot() {
    local profile="$1"

    # may be called from either catalyst (root) or setup_board (user)
    local sudo="env"
    if [[ $(id -u) -ne 0 ]]; then
        sudo="sudo -E"
    fi

    $sudo mkdir -p "${ROOT}/etc/portage/"{profile,repos.conf}
    $sudo cp /etc/portage/repos.conf/* "${ROOT}/etc/portage/repos.conf/"
    $sudo eselect profile set --force "$profile"

    $sudo tee "${ROOT}/etc/portage/make.conf" >/dev/null <<EOF
$(portageq envvar -v CHOST CBUILD ROOT SYSROOT \
    PORTDIR PORTDIR_OVERLAY DISTDIR PKGDIR)
HOSTCC=\${CBUILD}-gcc
PKG_CONFIG_PATH="\${SYSROOT}/usr/lib/pkgconfig/"
EOF
}

# Dump crossdev information to determine if configs must be reganerated
_crossdev_info() {
    local cross_chost="$1"; shift
    echo -n "# "; crossdev --version
    echo "# $@"
    crossdev "$@" --show-target-cfg
}

# Build/install a toolchain w/ crossdev.
# Usage: build_cross_toolchain chost [--portage-opts....]
install_cross_toolchain() {
    local cross_chost="$1"; shift
    local cross_pkgs=( $(get_cross_pkgs $cross_chost) )
    # gdb doesn't respect the --stable flag, set it stable explicitly
    local cross_flags=( --gdb '[stable]' --ex-gdb --stable --target "${cross_chost}" )
    local cross_cfg="/usr/${cross_chost}/etc/portage/${cross_chost}-crossdev"
    local cross_cfg_data=$(_crossdev_info "${cross_flags[@]}")
    local emerge_flags=( "$@" --binpkg-respect-use=y --update --newuse )

    # Forcing binary packages for toolchain packages breaks crossdev since it
    # prevents it from rebuilding with different use flags during bootstrap.
    local safe_flags=( "${@/#--useoldpkg-atoms=*/}" )
    safe_flags=( "${safe_flags[@]/#--rebuild-exclude=*/}" )
    cross_flags+=( --portage "${safe_flags[*]}" )

    # may be called from either catalyst (root) or upgrade_chroot (user)
    local sudo="env"
    if [[ $(id -u) -ne 0 ]]; then
        sudo="sudo -E"
    fi

    # crossdev will arbitrarily choose an overlay that it finds first.
    # Force it to use the one created by configure_crossdev_overlay
    local cross_overlay=$(portageq get_repo_path / x-crossdev)
    if [[ -n "${cross_overlay}" ]]; then
        cross_flags+=( --ov-output "${cross_overlay}" )
    else
        echo "No x-crossdev overlay found!" >&2
        return 1
    fi

    # Only call crossdev to regenerate configs if something has changed
    if ! cmp --quiet - "${cross_cfg}" <<<"${cross_cfg_data}"
    then
        $sudo crossdev "${cross_flags[@]}" --init-target
        $sudo tee "${cross_cfg}" <<<"${cross_cfg_data}" >/dev/null
    fi

    # Check if any packages need to be built from source. If so do a full
    # bootstrap via crossdev, otherwise just install the binaries (if enabled).
    # It is ok to build gdb from source outside of crossdev.
    if emerge "${emerge_flags[@]}" \
        --pretend "${cross_pkgs[@]}" | grep -q '^\[ebuild'
    then
        $sudo crossdev "${cross_flags[@]}" --stage4
    else
        $sudo emerge "${emerge_flags[@]}" \
            "cross-${cross_chost}/gdb" "${cross_pkgs[@]}"
    fi

    # Setup environment and wrappers for our shiny new toolchain
    gcc_set_latest_profile "${cross_chost}"
    $sudo CC_QUIET=1 ccache-config --install-links "${cross_chost}"
    $sudo CC_QUIET=1 sysroot-config --install-links "${cross_chost}"
}

# Build/install toolchain dependencies into the cross sysroot for a
# given CHOST. This is required to build target board toolchains since
# the target sysroot under /build/$BOARD is incomplete at this stage.
# Usage: build_cross_toolchain chost [--portage-opts....]
install_cross_libs() {
    local cross_chost="$1"; shift
    local ROOT="/usr/${cross_chost}"
    local package_provided="$ROOT/etc/portage/profile/package.provided"

    # may be called from either catalyst (root) or setup_board (user)
    local sudo="env"
    if [[ $(id -u) -ne 0 ]]; then
        sudo="sudo -E"
    fi

    CBUILD="$(portageq envvar CBUILD)" \
        CHOST="${cross_chost}" \
        ROOT="$ROOT" \
        SYSROOT="$ROOT" \
        _configure_sysroot "${CROSS_PROFILES[${cross_chost}]}"

    # In order to get a dependency list we must calculate it before
    # updating package.provided. Otherwise portage will no-op.
    $sudo rm -f "${package_provided}/cross-${cross_chost}"
    local cross_deps=$(ROOT="$ROOT" _get_dependency_list \
        "$@" "${TOOLCHAIN_PKGS[@]}" | $sudo tee \
        "$ROOT/etc/portage/cross-${cross_chost}-depends")

    # Add toolchain to packages.provided since they are on the host system
    if [[ -f "${package_provided}" ]]; then
        # emerge-wrapper is trying a similar trick but doesn't work
        $sudo rm -f "${package_provided}"
    fi
    $sudo mkdir -p "${package_provided}"
    local native_pkg cross_pkg cross_pkg_version
    for native_pkg in "${TOOLCHAIN_PKGS[@]}"; do
        cross_pkg="${native_pkg/*\//cross-${cross_chost}/}"
        cross_pkg_version=$(portageq match / "${cross_pkg}")
        echo "${native_pkg%/*}/${cross_pkg_version#*/}"
    done | $sudo tee "${package_provided}/cross-${cross_chost}" >/dev/null

    # OK, clear as mud? Install those dependencies now!
    PORTAGE_CONFIGROOT="$ROOT" ROOT="$ROOT" $sudo emerge "$@" -u $cross_deps
}

# Get the latest GCC profile for a given CHOST
# The extra flag can be blank, hardenednopie, and so on. See gcc-config -l
# Usage: gcc_get_latest_profile chost [extra]
gcc_get_latest_profile() {
    local prefix="${1}-"
    local suffix="${2+-$2}"
    local status
    gcc-config -l | cut -d' ' -f3 | grep "^${prefix}[0-9\\.]*${suffix}$" | tail -n1

    # return 1 if anything in the above pipe failed
    for status in ${PIPESTATUS[@]}; do
        [[ $status -eq 0 ]] || return 1
    done
}

# Update to the latest GCC profile for a given CHOST if required
# The extra flag can be blank, hardenednopie, and so on. See gcc-config -l
# Usage: gcc_set_latest_profile chost [extra]
gcc_set_latest_profile() {
    local latest=$(gcc_get_latest_profile "$@")
    if [[ -z "${latest}" ]]; then
        echo "Failed to detect latest gcc profile for $1" >&2
        return 1
    fi

    # may be called from either catalyst (root) or upgrade_chroot (user)
    local sudo="env"
    if [[ $(id -u) -ne 0 ]]; then
        sudo="sudo -E"
    fi

    if [[ "${latest}" != $(gcc-config -c "$1") ]]; then
        $sudo gcc-config "${latest}"
    fi
}
