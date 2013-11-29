#!/bin/bash

set -e
source /tmp/chroot-functions.sh
source /tmp/toolchain_util.sh

# A note on packages:
# The default PKGDIR is /usr/portage/packages
# To make sure things are uploaded to the correct places we split things up:
# crossdev build packages use ${PKGDIR}/crossdev (uploaded to SDK location)
# build deps in crossdev's sysroot use ${PKGDIR}/cross/${CHOST} (no upload)
# native toolchains use ${PKGDIR}/target/${BOARD} (uploaded to board location)

configure_target_root() {
    local board="$1"
    local cross_chost=$(get_board_chost "$1")
    local profile=$(get_board_profile "${board}")

    CHOST="${cross_chost}" \
        ROOT="/build/${board}" \
        SYSROOT="/usr/${cross_chost}" \
        _configure_sysroot "${profile}"
}

build_target_toolchain() {
    local board="$1"
    local ROOT="/build/${board}"

    # --root is required because run_merge overrides ROOT=
    PORTAGE_CONFIGROOT="$ROOT" \
        run_merge -u --root="$ROOT" "${TOOLCHAIN_PKGS[@]}"
}

mkdir -p "/tmp/crossdev"
export PORTDIR_OVERLAY="/tmp/crossdev $(portageq envvar PORTDIR_OVERLAY)"

for cross_chost in $(get_chost_list); do
    echo "Building cross toolchain for ${cross_chost}"
    PKGDIR="$(portageq envvar PKGDIR)/crossdev" \
        install_cross_toolchain "${cross_chost}" ${clst_myemergeopts}
    PKGDIR="$(portageq envvar PKGDIR)/cross/${cross_chost}" \
        install_cross_libs "${cross_chost}" ${clst_myemergeopts}
done

for board in $(get_board_list); do
    echo "Building native toolchain for ${board}"
    target_pkgdir="$(portageq envvar PKGDIR)/target/${board}"
    PKGDIR="${target_pkgdir}" configure_target_root "${board}"
    PKGDIR="${target_pkgdir}" build_target_toolchain "${board}"
done
