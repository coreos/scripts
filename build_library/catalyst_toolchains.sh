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

get_dependency_list() {
    local ROOT="$1"
    local IFS=$'| \t\n'
    shift

    PORTAGE_CONFIGROOT="$ROOT" SYSROOT="$ROOT" \
        ROOT="$ROOT" emerge ${clst_myemergeopts} \
        --pretend --with-bdeps=y --onlydeps --quiet \
        "$@" | sed -e 's/.*\] \([^ :]*\).*/=\1/' |
        egrep -v "(=$(echo "$*")-[0-9])"
}

configure_portage() {
    local pkg_path="$1"
    local profile="$2"

    mkdir -p "${ROOT}/etc/portage"
    echo "eselect will report '!!! Warning: Strange path.' but that's OK"
    eselect profile set --force "$profile"

    cat >"${ROOT}/etc/portage/make.conf" <<EOF
CHOST=${CHOST}
CBUILD=$(portageq envvar CBUILD)
HOSTCC=\${CBUILD}-gcc
ROOT="${ROOT}"
SYSROOT="${SYSROOT}"
PKG_CONFIG_PATH="\${SYSROOT}/usr/lib/pkgconfig/"
PORTDIR="$(portageq envvar PORTDIR)"
DISTDIR="\${PORTDIR}/distfiles"
PKGDIR="\${PORTDIR}/packages/${pkg_path}"
PORTDIR_OVERLAY="$(portageq envvar PORTDIR_OVERLAY)"
EOF
}

build_cross_toolchain() {
    local cross_chost="$1"
    local cross_pkgs=( "${TOOLCHAIN_PKGS[@]/*\//cross-${cross_chost}/}" )
    local PORTDIR="$(portageq envvar PORTDIR)"
    local PKGDIR="${PORTDIR}/packages/crossdev"

    PKGDIR="${PKGDIR}" crossdev \
        --ov-output "/tmp/crossdev" --stable \
        --portage "${clst_myemergeopts}" \
        --init-target --target "${cross_chost}"

    # If PKGCACHE is enabled check to see if binary packages are available.
    # If so then don't perform a full bootstrap and just call emerge instead.
    if [[ -n "${clst_PKGCACHE}" ]] && \
        PKGDIR="${PKGDIR}" emerge ${clst_myemergeopts} \
            --usepkgonly --binpkg-respect-use=y \
            --pretend "${cross_pkgs[@]}" &>/dev/null
    then
        PKGDIR="${PKGDIR}" run_merge -u "${cross_pkgs[@]}"
    else
        PKGDIR="${PKGDIR}" crossdev \
            --ov-output "/tmp/crossdev" --stable \
            --env PKGDIR="${PORTDIR}/packages/crossdev" \
            --portage "${clst_myemergeopts}" \
            --stage4 --target "${cross_chost}"
    fi

    # Setup ccache for our shiny new toolchain
    ccache-config --install-links "${cross_chost}"
}

configure_cross_root() {
    local cross_chost="$1"
    local ROOT="/usr/${cross_chost}"

    CHOST="${cross_chost}" ROOT="$ROOT" SYSROOT="$ROOT" \
        configure_portage "cross/${cross_chost}" \
        "${CROSS_PROFILE[${cross_chost}]}"

    # In order to get a dependency list we must calculate it before
    # updating package.provided. Otherwise portage will no-op.
    get_dependency_list "$ROOT" "${TOOLCHAIN_PKGS[@]}" \
        > "$ROOT/etc/portage/cross-${cross_chost}-depends"

    # Add toolchain to packages.provided since they are on the host system
    mkdir -p "$ROOT/etc/portage/profile/package.provided"
    local native_pkg cross_pkg cross_pkg_version
    for native_pkg in "${TOOLCHAIN_PKGS[@]}"; do
        cross_pkg="${native_pkg/*\//cross-${cross_chost}/}"
        cross_pkg_version=$(portageq match / "${cross_pkg}")
        echo "${native_pkg%/*}/${cross_pkg_version#*/}"
    done > "$ROOT/etc/portage/profile/package.provided/cross-${cross_chost}"
}

build_cross_libs() {
    local cross_chost="$1"
    local ROOT="/usr/${cross_chost}"
    local cross_deps=$(<"$ROOT/etc/portage/cross-${cross_chost}-depends")

    # --root is required because run_merge overrides ROOT=
    PORTAGE_CONFIGROOT="$ROOT" run_merge -u --root="$ROOT" $cross_deps
}

configure_target_root() {
    local board="$1"
    local cross_chost=$(get_board_chost "$1")

    CHOST="${cross_chost}" ROOT="/build/${board}" \
        SYSROOT="/usr/${cross_chost}" configure_portage \
        "target/${board}" "$(get_board_profile "${board}")"
}

build_target_toolchain() {
    local board="$1"
    local ROOT="/build/${board}"

    # --root is required because run_merge overrides ROOT=
    PORTAGE_CONFIGROOT="$ROOT" \
        run_merge -u --root="$ROOT" "${TOOLCHAIN_PKGS[@]}"
}

for cross_chost in $(get_chost_list); do
    echo "Building cross toolchain for ${cross_chost}"
    build_cross_toolchain "${cross_chost}"
    configure_cross_root "${cross_chost}"
    build_cross_libs "${cross_chost}"
done

for board in $(get_board_list); do
    echo "Building native toolchain for ${board}"
    configure_target_root "${board}"
    build_target_toolchain "${board}"
done
