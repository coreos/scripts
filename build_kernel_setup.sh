#!/bin/sh

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script will launch the kernel build script from outside a chroot
# environment and copy the kernel package into the chromeos source repository's
# src/platform/kernel directory.

set -e

SRC_ROOT=${SRC_ROOT:-$(cd "$(dirname $0)/.." ; pwd)}
KERNEL_DATA="${SRC_ROOT}/third_party/kernel"   # version-controlled kernel stuff
BUILD_SCRIPT="build_kernel.sh"

KCONFIG="$1"                        # kernel config file
PKGREVISION="$2"                    # version number to stamp on the package
ROOTFS="$3"                         # development environment (fakeroot)

if [ $# -lt 3 ]
then
    echo "usage: $0 <kernel_config> <package_revision> <rootfs> <patch>"
    echo "kernel_config: Kernel config from ${KERNEL_DATA}/config/."
    echo "package_revision: The revision to stamp on the final .deb package."
    echo "rootfs: Root directory of build environment"
    echo "remaining arguments are assumed to be kernel patch names"
    echo -n "Usage example: sh build_kernel.sh config.2.6.30-rc8-chromeos-intel-"
    echo    "menlow 001 ~/src/chromeos/devenv"
    echo ""
    exit 1
fi

# Use remaining arguments as patch names.
shift; shift; shift
PATCHES="$*"

if [ ! -d "$ROOTFS" ]
then
    echo "$ROOTFS is not a directory"
    exit 1
fi

# Create a tmpfs to store output from build script which this script can copy
# the output from later on. We won't know the actual filename of the output
# but since this is a new namespace we're using it should be safe to use a use
# a wildcard (e.g. linux-image*.deb) without copying the wrong .debs.
OUTPUT_DIR="${ROOTFS}/tmp"
sudo mkdir -p "$OUTPUT_DIR"
sudo mount -t tmpfs size=32M "${OUTPUT_DIR}"
do_cleanup() {
    sudo umount "${OUTPUT_DIR}"
}
trap do_cleanup EXIT

# Copy kernel build helper script to chroot environment
sudo cp "${SRC_ROOT}/scripts/${BUILD_SCRIPT}" "${ROOTFS}/tmp/"

# Run the build script.
sudo chroot "$ROOTFS" "/tmp/${BUILD_SCRIPT}" "$KCONFIG" \
            "$PKGREVISION" "${OUTPUT_DIR#$ROOTFS}/" "$PATCHES"

# Copy kernel package from the output directory into Chrome OS sources
# before the cleanup routine clobbers it.
echo "Copying kernel to "$KERNEL_DATA""
cp -i "$OUTPUT_DIR"/linux-image*.deb "$KERNEL_DATA"

set +e
