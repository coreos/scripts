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

# Portage arguments to enforce the toolchain to only use binpkgs.
TOOLCHAIN_BINONLY=( "${TOOLCHAIN_PKGS[@]/#/--useoldpkg-atoms=}" )

# Portage profile to use for building out the cross compiler's SYSROOT.
# This is only used as an intermediate step to be able to use the cross
# compiler to build a full native toolchain. Packages are not uploaded.
CROSS_PROFILE["x86_64-cros-linux-gnu"]="coreos:coreos/amd64/generic"

# Map board names to CHOSTs and portage profiles. This is the
# definitive list, there is assorted code new and old that either
# guesses or hard-code these. All that should migrate to this list.
declare -A BOARD_CHOST BOARD_PROFILE
BOARD_CHOST["amd64-generic"]="x86_64-cros-linux-gnu"
BOARD_PROFILE["amd64-generic"]="coreos:coreos/amd64/generic"
BOARD_NAMES=( "${!BOARD_CHOST[@]}" )

get_board_list() {
    local IFS=$'\n\t '
    sort <<<"${BOARD_NAMES[*]}"
}

get_chost_list() {
    local IFS=$'\n\t '
    sort -u <<<"${BOARD_CHOST[*]}"
}

get_profile_list() {
    local IFS=$'\n\t '
    sort -u <<<"${BOARD_PROFILE[*]}"
}

get_board_chost() {
    if [[ ${#BOARD_CHOST["$1"]} -ne 0 ]]; then
        echo "${BOARD_CHOST["$1"]}"
    else
        die "Unknown board '$1'"
    fi
}

get_board_profile() {
    if [[ ${#BOARD_PROFILE["$1"]} -ne 0 ]]; then
        echo "${BOARD_PROFILE["$1"]}"
    else
        die "Unknown board '$1'"
    fi
}
