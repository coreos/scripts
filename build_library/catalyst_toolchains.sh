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

build_cross_libs() {
    local cross_chost="$1"
    local ROOT="/usr/${cross_chost}"

    CHOST="${cross_chost}" ROOT="$ROOT" SYSROOT="$ROOT" \
        _configure_sysroot "${CROSS_PROFILE[${cross_chost}]}"

    # In order to get a dependency list we must calculate it before
    # updating package.provided. Otherwise portage will no-op.
    ROOT="$ROOT" _get_dependency_list \
        ${clst_myemergeopts} "${TOOLCHAIN_PKGS[@]}" > \
        "$ROOT/etc/portage/cross-${cross_chost}-depends"

    # Add toolchain to packages.provided since they are on the host system
    mkdir -p "$ROOT/etc/portage/profile/package.provided"
    local native_pkg cross_pkg cross_pkg_version
    for native_pkg in "${TOOLCHAIN_PKGS[@]}"; do
        cross_pkg="${native_pkg/*\//cross-${cross_chost}/}"
        cross_pkg_version=$(portageq match / "${cross_pkg}")
        echo "${native_pkg%/*}/${cross_pkg_version#*/}"
    done > "$ROOT/etc/portage/profile/package.provided/cross-${cross_chost}"
    local cross_deps=$(<"$ROOT/etc/portage/cross-${cross_chost}-depends")

    # --root is required because run_merge overrides ROOT=
    PORTAGE_CONFIGROOT="$ROOT" run_merge -u --root="$ROOT" $cross_deps
}

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

    sysroot_pkgdir="$(portageq envvar PKGDIR)/cross/${cross_chost}"
    PKGDIR="${sysroot_pkgdir}" build_cross_libs "${cross_chost}"
done

for board in $(get_board_list); do
    echo "Building native toolchain for ${board}"
    target_pkgdir="$(portageq envvar PKGDIR)/target/${board}"
    PKGDIR="${target_pkgdir}" configure_target_root "${board}"
    PKGDIR="${target_pkgdir}" build_target_toolchain "${board}"
done
