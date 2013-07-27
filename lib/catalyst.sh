#!/bin/bash
# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# common.sh should be sourced first
[[ -n "${DEFAULT_BUILD_ROOT}" ]] || exit 1

# Default option values, may be provided before including this file
: ${TYPE:="coreos-sdk"}
: ${ARCH:=$(portageq envvar ARCH)}
: ${DEFAULT_CATALYST_ROOT:="${DEFAULT_BUILD_ROOT}/catalyst"}
: ${DEFAULT_SEED:="${DEFAULT_CATALYST_ROOT}/builds/${TYPE}/stage4-${ARCH}-latest.tar.bz2"}
: ${DEFAULT_PROFILE:="coreos:default/linux/${ARCH}/10.0"}

# Values set in catalyst_init, don't use till after calling it
CATALYST_ROOT=
DEBUG=
BUILDS=
BINPKGS=
DISTDIR=
TEMPDIR=
STAGES=

# For searching for alternatives when DEFAULT_SEED doesn't exist
# unset SDK_SEARCH=1 to disable this fallback
SDK_TARBALL="coreos-sdk-${ARCH}-${COREOS_SDK_VERSION}.tar.bz2"
SDK_SEARCH=1

DEFINE_string catalyst_root "${DEFAULT_CATALYST_ROOT}" \
    "Path to directory for all catalyst images and other files."
DEFINE_string portage_stable "${SRC_ROOT}/third_party/portage-stable" \
    "Path to the portage-stable git checkout."
DEFINE_string coreos_overlay "${SRC_ROOT}/third_party/coreos-overlay" \
    "Path to the coreos-overlay git checkout."
DEFINE_string seed_tarball "${DEFAULT_SEED}" \
    "Path to an existing stage tarball to start from."
DEFINE_string version "${COREOS_VERSION_STRING}" \
    "Version to use for portage snapshot and stage tarballs."
DEFINE_string profile "${DEFAULT_PROFILE}" \
    "Portage profile, may be prefixed with repo:"
DEFINE_boolean rebuild ${FLAGS_FALSE} \
    "Rebuild and overwrite stages that already exist."
DEFINE_boolean debug ${FLAGS_FALSE} "Enable verbose output from catalyst."

#####################
# CONFIG DEFINITIONS
#
# These templates can be expanded by calling the wrapping function after
# catalyst_init has been called. They are written as files in write_configs
# rather than passed as command line args for easier inspection and debugging
# by hand, catalyst can get tricky.
######################

# Values to write to catalyst.conf
catalyst_conf() {
cat <<EOF
# catalyst.conf
contents="auto"
digests="md5 sha1 sha512 whirlpool"
hash_function="crc32"
options="autoresume ccache pkgcache"
sharedir="/usr/lib/catalyst"
storedir="$CATALYST_ROOT"
distdir="$DISTDIR"
envscript="$TEMPDIR/catalystrc"
port_logdir="$CATALYST_ROOT/log"
portdir="$FLAGS_portage_stable"
snapshot_cache="$CATALYST_ROOT/tmp/snapshot_cache"
EOF
}

catalystrc() {
echo "export MAKEOPTS='--jobs=${NUM_JOBS} --load-average=${NUM_JOBS}'"
echo "export EMERGE_DEFAULT_OPTS=--jobs=${NUM_JOBS}"
echo "export FEATURES='parallel-install -ebuild-locks'"
}

# Common values for all stage spec files
catalyst_stage_default() {
cat <<EOF
subarch: $ARCH
rel_type: $TYPE
portage_overlay: $FLAGS_coreos_overlay
profile: $FLAGS_profile
snapshot: $FLAGS_version
version_stamp: $FLAGS_version
cflags: -O2 -pipe
cxxflags: -O2 -pipe
ldflags: -Wl,-O2 -Wl,--as-needed
EOF
}

# Config values for each stage
catalyst_stage1() {
cat <<EOF
target: stage1
# stage1 packages aren't published, save in tmp
pkgcache_path: ${TEMPDIR}/stage1-${ARCH}-packages
EOF
catalyst_stage_default
}

catalyst_stage2() {
cat <<EOF
target: stage2
# stage2 packages aren't published, save in tmp
pkgcache_path: ${TEMPDIR}/stage2-${ARCH}-packages
EOF
catalyst_stage_default
}

catalyst_stage3() {
cat <<EOF
target: stage3
pkgcache_path: $BINPKGS
EOF
catalyst_stage_default
}

catalyst_stage4() {
die "The calling script should redefine this function!"
}

##########################
# END CONFIG DEFINITIONS #
##########################

# catalyst_init
# Parses command ling arguments, validates them, and sets up environment
# for the rest of the functions here. Should be the first thing called
# after any script specific shflags DEFINE_* statements.
# Usage: catalyst_init "$@"
catalyst_init() {
    FLAGS "$@" || exit 1
    switch_to_strict_mode
    eval set -- "${FLAGS_ARGV}"

    if [[ $# -eq 0 ]]; then
        STAGES="stage1 stage2 stage3 stage4"
    else
        for stage in "$@"; do
            if [[ ! "$stage" =~ ^stage[1234]$ ]]; then
                die_notrace "Invalid target name $stage"
            fi
        done
        STAGES="$*"
    fi

    if [[ $(id -u) != 0 ]]; then
        die_notrace "This script must be run as root."
    fi

    if ! which catalyst &>/dev/null; then
        die_notrace "catalyst not found, not installed or bad PATH?"
    fi

    DEBUG=
    if [[ ${FLAGS_debug} -eq ${FLAGS_TRUE} ]]; then
        DEBUG="--debug --verbose"
    fi

    # Create output dir, expand path for easy comparison later
    mkdir -p "$FLAGS_catalyst_root"
    CATALYST_ROOT=$(readlink -f "$FLAGS_catalyst_root")

    BUILDS="$CATALYST_ROOT/builds/$TYPE"
    BINPKGS="$CATALYST_ROOT/packages/$TYPE"
    TEMPDIR="$CATALYST_ROOT/tmp/$TYPE"
    DISTDIR="$CATALYST_ROOT/distfiles"

    # possibly search for existing seeds
    search_for_sdk_seed

    # confirm seed exists
    if [[ ! -f "$FLAGS_seed_tarball" ]]; then
        die_notrace "Seed tarball not found: $FLAGS_seed_tarball"
    fi

    # so far so good, expand path to work with weird comparison code below
    FLAGS_seed_tarball=$(readlink -f "$FLAGS_seed_tarball")

    if [[ ! "$FLAGS_seed_tarball" =~ .*\.tar\.bz2 ]]; then
        die_notrace "Seed tarball doesn't end in .tar.bz2 :-/"
    fi

    # catalyst is obnoxious and wants the $TYPE/stage3-$VERSION part of the
    # path, not the real path to the seed tarball. (Because it could be a
    # directory under $TEMPDIR instead, aka the SEEDCACHE feature.)
    if [[ "$FLAGS_seed_tarball" =~ "$CATALYST_ROOT/builds/".* ]]; then
        SEED="${FLAGS_seed_tarball#$CATALYST_ROOT/builds/}"
        SEED="${SEED%.tar.bz2}"
    else
        mkdir -p "$CATALYST_ROOT/builds/seed"
        cp -n "$FLAGS_seed_tarball" "$CATALYST_ROOT/builds/seed"
        SEED="seed/${FLAGS_seed_tarball##*/}"
        SEED="${SEED%.tar.bz2}"
    fi
}

# search_for_sdk_seed
# As a fallback search around for an existing SDK tarball we
# can use as a seed when the default doesn't exist.
search_for_sdk_seed() {
    # Search disabled
    [[ "${SDK_SEARCH}" != 1 ]] && return
    # Seed already exists
    [[ -f "${FLAGS_seed_tarball}" ]] && return
    # User set the option so we shouldn't change it
    [[ "${FLAGS_seed_tarball}" != "${DEFAULT_SEED}" ]] && return

    local check_path
    for check_path in \
        "${CATALYST_ROOT}/builds/coreos-sdk/${SDK_TARBALL}" \
        "${CATALYST_ROOT}/builds/seeds/${SDK_TARBALL}" \
        "/var/cache/chromeos-cache/sdks/${SDK_TARBALL}" \
        "/mnt/host/source/.cache/sdks/${SDK_TARBALL}"
    do
        if [[ -f "${check_path}" ]]; then
            info "Using SDK for seed: ${check_path}"
            FLAGS_seed_tarball="${check_path}"
            return
        fi
    done
}

write_configs() {
    # No catalyst config option, so defined via environment
    export CCACHE_DIR="$TEMPDIR/ccache"

    info "Creating output directories..."
    mkdir -p "$TEMPDIR" "$DISTDIR" "$CCACHE_DIR"
    info "Writing out catalyst configs..."
    info "    $TEMPDIR/catalyst.conf"
    catalyst_conf > "$TEMPDIR/catalyst.conf"
    info "    $TEMPDIR/catalystrc"
    catalystrc > "$TEMPDIR/catalystrc"
    info "    $TEMPDIR/stage1.spec"
    catalyst_stage1 > "$TEMPDIR/stage1.spec"
    info "    $TEMPDIR/stage2.spec"
    catalyst_stage2 > "$TEMPDIR/stage2.spec"
    info "    $TEMPDIR/stage3.spec"
    catalyst_stage3 > "$TEMPDIR/stage3.spec"
    info "    $TEMPDIR/stage4.spec"
    catalyst_stage4 > "$TEMPDIR/stage4.spec"
}

build_stage() {
    stage="$1"
    srcpath="$2"
    target_tarball="${stage}-${ARCH}-${FLAGS_version}.tar.bz2"

    if [[ -f "$BUILDS/${target_tarball}" && $FLAGS_rebuild == $FLAGS_FALSE ]]
    then
        info "Skipping $stage, $target_tarball already exists."
        return
    fi

    info "Starting $stage"
    catalyst $DEBUG \
        -c "$TEMPDIR/catalyst.conf" \
        -f "$TEMPDIR/${stage}.spec" \
        -C "source_subpath=$srcpath"
    # Catalyst doesn't clean up after itself...
    rm -rf "$TEMPDIR/$stage-${ARCH}-${FLAGS_version}"
    ln -sf "$stage-${ARCH}-${FLAGS_version}.tar.bz2" \
        "$BUILDS/$stage-${ARCH}-latest.tar.bz2"
    info "Finished building $target_tarball"
}

build_snapshot() {
    if [[ -f "$CATALYST_ROOT/snapshots/portage-${FLAGS_version}.tar.bz2" ]]
    then
        info "Skipping snapshot, portage-${FLAGS_version}.tar.bz2 exists"
    else
        info "Creating snapshot portage-${FLAGS_version}.tar.bz2"
        catalyst $DEBUG -c "$TEMPDIR/catalyst.conf" -s "$FLAGS_version"
    fi
}

catalyst_build() {
    # assert catalyst_init has been called
    [[ -n "$CATALYST_ROOT" ]]

    info "Building stages: $STAGES"
    write_configs
    build_snapshot

    used_seed=0
    if [[ "$STAGES" =~ stage1 ]]; then
        build_stage stage1 "$SEED"
        used_seed=1
    fi

    if [[ "$STAGES" =~ stage2 ]]; then
        if [[ $used_seed -eq 1 ]]; then
            SEED="${TYPE}/stage1-${ARCH}-latest"
        fi
        build_stage stage2 "$SEED"
        used_seed=1
    fi

    if [[ "$STAGES" =~ stage3 ]]; then
        if [[ $used_seed -eq 1 ]]; then
            SEED="${TYPE}/stage2-${ARCH}-latest"
        fi
        build_stage stage3 "$SEED"
        used_seed=1
    fi

    if [[ "$STAGES" =~ stage4 ]]; then
        if [[ $used_seed -eq 1 ]]; then
            SEED="${TYPE}/stage3-${ARCH}-latest"
        fi
        build_stage stage4 "$SEED"
        used_seed=1
    fi

    # Cleanup snapshots, we don't use them
    rm -rf "$CATALYST_ROOT/snapshots/portage-${FLAGS_version}.tar.bz2"*
}
