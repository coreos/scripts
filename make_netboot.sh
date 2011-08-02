#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# make_netboot.sh --board=[board]
#
# This script validates that the current latest image is an install shim,
# and generates a netboot image from it. This pulls the u-boot kernel
# image bundle (uimg), the legacy firmware for netbooting, and the install
# shim kernel image, bundled as a uboot gz/uimg, and places them in a
# "netboot" subfolder.

# This script is intended to be called mainly form archive_build.sh, where
# these files are added to the factory install artifacts generated on buildbot.

# --- BEGIN COMMON.SH BOILERPLATE ---
# Load common CrOS utilities.  Inside the chroot this file is installed in
# /usr/lib/crosutils.  Outside the chroot we find it relative to the script's
# location.
find_common_sh() {
  local common_paths=(/usr/lib/crosutils $(dirname "$(readlink -f "$0")"))
  local path

  SCRIPT_ROOT=
  for path in "${common_paths[@]}"; do
    if [ -r "${path}/common.sh" ]; then
      SCRIPT_ROOT=${path}
      break
    fi
  done
}

find_common_sh
. "${SCRIPT_ROOT}/common.sh" || { echo "Unable to load common.sh"; exit 1; }
# --- END COMMON.SH BOILERPLATE ---
# Script must be run inside the chroot.
restart_in_chroot_if_needed "$@"

get_default_board

DEFINE_string board "${DEFAULT_BOARD}" \
  "The board to build an image for."

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

set -e
# build_packages artifact output.
SYSROOT="${GCLIENT_ROOT}/chroot/build/${FLAGS_board}"
# build_image artifact output.
IMAGES_DIR="${CHROOT_TRUNK_DIR}/src/build/images"
# Canonical install shim name.
INSTALL_SHIM="factory_install_shim.bin"

cd ${IMAGES_DIR}/${FLAGS_board}/latest

if [ ! -f "${INSTALL_SHIM}" ]; then
  echo "Cannot locate ${INSTALL_SHIM}, nothing to netbootify!"
  exit 1
fi

# Generate staging dir for netboot files.
sudo rm -rf netboot
mkdir -p netboot

# Get netboot kernel.
echo "Generating netboot kernel vmlinux.uimg"
cp "${SYSROOT}/boot/vmlinux.uimg" "netboot"

# Get netboot firmware.
# TODO(nsanders): Set default IP here when userspace
# env modification is available.
# TODO(nsanders): ARM generic doesn't build chromeos-u-boot package.
# When ARM generic goes away, delete the test.
if [ -r "${SYSROOT}/u-boot/legacy_image.bin" ]; then
    echo "Copying netboot firmware legacy_image.bin"
    cp "${SYSROOT}/u-boot/legacy_image.bin" "netboot"
    cp "${GCLIENT_ROOT}/chroot/usr/bin/update_firmware_vars.py" "netboot"
else
    echo "Skipping legacy fw: ${SYSROOT}/u-boot/legacy_image.bin not present?"
fi

# Get HWID bundle if available.
hwid_dir="usr/share/chromeos-hwid"
sudo rm -rf hwid
mkdir -p hwid
if updater_files=$(ls "${SYSROOT}/${hwid_dir}/" | grep updater_); then
    echo "Copying HWID bundles: $updater_files"
    for file in $updater_files; do
        cp "${SYSROOT}/${hwid_dir}/${file}" "hwid/"
    done
else
    echo "Skipping HWID: ${SYSROOT}/${hwid_dir}/" \
         "does not contain updater"
fi


# Prepare to mount rootfs.
umount_loop() {
  sudo umount r || true
  sudo umount s || true
  false
}

echo "Unpack factory install shim partitions"
./unpack_partitions.sh "${INSTALL_SHIM}"

# Genrate clean mountpoints.
sudo rm -rf r s
mkdir -p r s

# Clean ROified filesystem headers, and mount.
trap "umount_loop" EXIT
enable_rw_mount part_3
sudo mount -o loop part_3 r
sudo mount -o loop part_1 s
echo "Mount install shim rootfs (partition 3)"

# Copy factory config file.
# TODO(nsanders): switch this to u-boot env var config.
LSB_FACTORY_DIR="mnt/stateful_partition/dev_image/etc"
sudo mkdir -p "r/${LSB_FACTORY_DIR}"
sudo cp "s/dev_image/etc/lsb-factory" "r/${LSB_FACTORY_DIR}"

# Clean up mounts.
trap - EXIT
sudo umount r s
sudo rm -rf r s

# Generate an initrd fo u-boot to load.
gzip -9 -c part_3 > ext2_rootfs.gz
echo "Generating netboot rootfs initrd.uimg"
# U-boot's uimg wrapper specifies where we will load the blob into memory.
# tftp boot's default root address is set to 0x12008000 in legacy_image.bin,
# so we want to unpack it there.
mkimage -A arm -O linux -T ramdisk -a 0x12008000 \
    -n "Factory Install RootFS" -C gzip -d ext2_rootfs.gz \
    netboot/initrd.uimg

# Cleanup
rm -rf ext2_rootfs.gz part_*
