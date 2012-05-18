#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# make_netboot.sh --board=[board]
#
# This script validates that the current latest image is an install shim,
# and generates a netboot image from it. This pulls the u-boot kernel
# image bundle (uimg), the legacy firmware for netbooting, and the install
# shim kernel image, bundled as a uboot gz/uimg, and places them in a
# "netboot" subfolder.

SCRIPT_ROOT=$(dirname $(readlink -f "$0"))
. "${SCRIPT_ROOT}/common.sh" || { echo "Unable to load common.sh"; exit 1; }

# Script must be run inside the chroot.
restart_in_chroot_if_needed "$@"

get_default_board

DEFINE_string board "${DEFAULT_BOARD}" \
  "The board to build an image for."
DEFINE_string image "" "Path to the image to use"

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

. "${SCRIPT_ROOT}/build_library/build_common.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/board_options.sh" || exit 1

switch_to_strict_mode
# build_packages artifact output.
SYSROOT="${GCLIENT_ROOT}/chroot/build/${FLAGS_board}"
# build_image artifact output.
IMAGES_DIR="${CHROOT_TRUNK_DIR}/src/build/images"

if [ -n "${FLAGS_image}" ]; then
  cd $(dirname "${FLAGS_image}")
  INSTALL_SHIM=$(basename "${FLAGS_image}")
else
  cd ${IMAGES_DIR}/${FLAGS_board}/latest
  # Canonical install shim name.
  INSTALL_SHIM="factory_install_shim.bin"
fi

if [ ! -f "${INSTALL_SHIM}" ]; then
  echo "Cannot locate ${INSTALL_SHIM}, nothing to netbootify!"
  exit 1
fi

# Generate staging dir for netboot files.
sudo rm -rf netboot
mkdir -p netboot

# Get netboot firmware.
# TODO(nsanders): Set default IP here when userspace
# env modification is available.
# TODO(nsanders): ARM generic doesn't build chromeos-u-boot package.
# When ARM generic goes away, delete the test.
if [ -r "${SYSROOT}/firmware/legacy_image.bin" ]; then
    echo "Copying netboot firmware legacy_image.bin"
    cp "${SYSROOT}/firmware/legacy_image.bin" "netboot"
    cp "${GCLIENT_ROOT}/chroot/usr/bin/update_firmware_vars.py" "netboot"
else
    echo "Skipping legacy fw: ${SYSROOT}/firmware/legacy_image.bin not present?"
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

if [ "${ARCH}" = "arm" ]; then
  export MKIMAGE_ARCH="arm"
else
  export MKIMAGE_ARCH="x86" # including amd64
fi

# Get netboot kernel.
if [ "${ARCH}" = "arm" ]; then
  # Currently we don't use initramfs for ARM. Someday we would probably want
  # initramfs for USB factory installation.
  # TODO: Converge build processes of ARM and x86.
  echo "Generating netboot kernel vmlinux.uimg"
  cp "r/boot/vmlinux.uimg" "netboot"
else
  echo "Building kernel"

  # Create temporary emerge root
  temp_build_path="$(mktemp -d bk_XXXXXXXX)"
  if ! [ -d "${temp_build_path}" ]; then
    echo "Failed to create temporary directory."
    exit 1
  fi

  # Emerge network boot kernel
  # We don't want to build whole install shim everytime we run this script,
  # and thus we only build kernel here. If this script is run against install
  # shim with different kernel version, this might not work. But as we don't
  # upgrade kernel so often, this is probably fine.
  export USE='netboot'
  export EMERGE_BOARD_CMD="emerge-${FLAGS_board}"
  emerge_custom_kernel ${temp_build_path}

  # Generate kernel uImage
  echo "Generating netboot kernel vmlinux.uimg"

  # U-boot put kernel image at 0x100000. We load it at 0x3000000 because
  # 0x3000000 is safe enough not to overlap with image at 0x100000.
  mkimage -A "${MKIMAGE_ARCH}" -O linux -T kernel -n "Linux kernel" -C none \
      -d "${temp_build_path}"/boot/vmlinuz \
      -a 0x03000000 -e 0x03000000 netboot/vmlinux.uimg

  # Clean up temporary emerge root
  sudo rm -rf "${temp_build_path}"
fi

echo "Add lsb-factory"
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
mkimage -A "${MKIMAGE_ARCH}" -O linux -T ramdisk -a 0x12008000 \
    -n "Factory Install RootFS" -C gzip -d ext2_rootfs.gz \
    netboot/initrd.uimg

# Cleanup
rm -rf ext2_rootfs.gz part_*
