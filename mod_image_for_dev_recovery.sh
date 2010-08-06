#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to create a Chrome OS dev recovery image using a dev install shim

# Source constants and utility functions
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/chromeos-common.sh"

get_default_board

DEFINE_string board "$DEFAULT_BOARD" "Board for which the image was built \
Default: ${DEFAULT_BOARD}"
DEFINE_string dev_install_shim "" "Path of the developer install shim. \
Default: (empty)"
DEFINE_string payload_dir "" "Directory containing developer payload and \
(optionally) a custom install script. Default: (empty)"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

set -e

# No board set and no default set then we can't proceed
if [ -z $FLAGS_board ] ; then
  setup_board_warning
  die "No board set"
fi

# Abort early if --payload_dir is not set, invalid or empty
if [ -z $FLAGS_payload_dir ] ; then
  die "flag --payload_dir not set"
fi

if [ ! -d "${FLAGS_payload_dir}" ] ; then
  die "${FLAGS_payload_dir} is not a directory"
fi

PAYLOAD_DIR_SIZE=
if [ -z "$(ls -A $FLAGS_payload_dir)" ] ; then
  die "${FLAGS_payload_dir} is empty"
else
  # Get directory size in 512-byte sectors so we can resize stateful partition
  PAYLOAD_DIR_SIZE=\
"$(du --apparent-size -B 512 ${FLAGS_payload_dir} | awk '{print $1}')"
  info "${FLAGS_payload_dir} has ${PAYLOAD_DIR_SIZE} 512-byte sectors"
fi

DEV_INSTALL_SHIM="dev_install_shim.bin"
# We have a board name but no dev_install_shim set. Try find a recent one
if [ -z $FLAGS_dev_install_shim ] ; then
  IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
  FLAGS_dev_install_shim=\
"${IMAGES_DIR}/$(ls -t $IMAGES_DIR 2>&-| head -1)/${DEV_INSTALL_SHIM}"
fi

# Turn relative path into an absolute path.
FLAGS_dev_install_shim=$(eval readlink -f ${FLAGS_dev_install_shim})

# Abort early if we can't find the install shim
if [ ! -f $FLAGS_dev_install_shim ] ; then
  die "No dev install shim found at $FLAGS_dev_install_shim"
else
  info "Using a recent dev install shim at ${FLAGS_dev_install_shim}"
fi

# Constants
INSTALL_SHIM_DIR="$(dirname "$FLAGS_dev_install_shim")"
DEV_RECOVERY_IMAGE="dev_recovery_image.bin"

# Resize stateful partition of install shim to hold payload content
# Due to this resize, we can't just re-pack the modified part back into an
# image using pack_partition.sh generated for the dev install shim. Instead,
# a revised partition table and a new image is needed
# (see update_partition_table() for details)
resize_statefulfs() {
  local source_part=$1  # source stateful partition
  local num_sectors=$2  # number of 512-byte sectors to be added

  source_image_sectors=$(roundup $(numsectors ${source_part}))
  info "source stateful fs has $((512 * $(expr $source_image_sectors))) bytes"
  resized_image_bytes=$((512 * $(expr $source_image_sectors + $num_sectors)))
  info "resized stateful fs has $resized_image_bytes bytes"

  STATEFUL_LOOP_DEV=$(sudo losetup -f)
  if [ -z "${STATEFUL_LOOP_DEV}" ]; then
    die "No free loop device. Free up a loop device or reboot. Exiting."
  fi

  # Extend the source file size to the new size.
  dd if=/dev/zero of="${source_part}" bs=1 count=1 \
      seek=$((resized_image_bytes - 1))

  # Resize the partition.
  sudo losetup "${STATEFUL_LOOP_DEV}" "${source_part}"
  sudo e2fsck -f "${STATEFUL_LOOP_DEV}"
  sudo resize2fs "${STATEFUL_LOOP_DEV}"
  sudo losetup -d "${STATEFUL_LOOP_DEV}"
}

# Update partition table with resized stateful partition and create the final
# dev recovery image
update_partition_table() {
  TEMP_IMG=$(mktemp)

  TEMP_KERN="${TEMP_DIR}"/part_2
  TEMP_ROOTFS="${TEMP_DIR}"/part_3
  TEMP_OEM="${TEMP_DIR}"/part_8
  TEMP_ESP="${TEMP_DIR}"/part_12
  TEMP_PMBR="${TEMP_DIR}"/pmbr
  dd if="${FLAGS_dev_install_shim}" of="${TEMP_PMBR}" bs=512 count=1

  # Set up a new partition table
  install_gpt "${TEMP_IMG}" "${TEMP_ROOTFS}" "${TEMP_STATE}" "${TEMP_PMBR}" \
    "${TEMP_ESP}" false $(roundup $(numsectors ${TEMP_ROOTFS}))

  # Copy into the partition parts of the file
  dd if="${TEMP_ROOTFS}" of="${TEMP_IMG}" conv=notrunc bs=512 \
    seek="${START_ROOTFS_A}"
  dd if="${TEMP_STATE}"  of="${TEMP_IMG}" conv=notrunc bs=512 \
    seek="${START_STATEFUL}"
  # Copy the full kernel (i.e. with vboot sections)
  dd if="${TEMP_KERN}"   of="${TEMP_IMG}" conv=notrunc bs=512 \
    seek="${START_KERN_A}"
  dd if="${TEMP_OEM}"    of="${TEMP_IMG}" conv=notrunc bs=512 \
    seek="${START_OEM}"
  dd if="${TEMP_ESP}"    of="${TEMP_IMG}" conv=notrunc bs=512 \
    seek="${START_ESP}"
}

# Creates a dev recovery image using an existing dev install shim
# If successful, content of --payload_dir is copied to a directory named
# "dev_payload" under the root of stateful partition.
create_dev_recovery_image() {
  # Split apart the partitions so we can make modifications
  TEMP_DIR=$(mktemp -d)
  (cd "${TEMP_DIR}" &&
    "${INSTALL_SHIM_DIR}/unpack_partitions.sh" "${FLAGS_dev_install_shim}")

  TEMP_STATE="${TEMP_DIR}"/part_1

  resize_statefulfs $TEMP_STATE $PAYLOAD_DIR_SIZE

  # Mount resized stateful FS and copy payload content to its root directory
  TEMP_MNT_STATE=$(mktemp -d)
  mkdir -p "${TEMP_MNT_STATE}"
  sudo mount -o loop "${TEMP_STATE}" "${TEMP_MNT_STATE}"
  sudo cp -R "${FLAGS_payload_dir}" "${TEMP_MNT_STATE}"
  sudo mv "${TEMP_MNT_STATE}/$(basename ${FLAGS_payload_dir})" \
"${TEMP_MNT_STATE}/dev_payload"
  # Mark image as dev recovery
  sudo touch "${TEMP_MNT_STATE}/.recovery"
  sudo touch "${TEMP_MNT_STATE}/.dev_recovery"

  # TODO(tgao): handle install script (for default and custom cases)
  update_partition_table

  sudo umount "${TEMP_MNT_STATE}"
  trap - EXIT
}

# Main
DST_PATH="${INSTALL_SHIM_DIR}/${DEV_RECOVERY_IMAGE}"
info "Attempting to create dev recovery image using dev install shim \
${FLAGS_dev_install_shim}"
create_dev_recovery_image

mv -f $TEMP_IMG $DST_PATH
info "Dev recovery image created at ${DST_PATH}"
