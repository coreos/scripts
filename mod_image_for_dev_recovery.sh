#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to create a Chrome OS dev recovery image using a dev install shim

# Source constants and utility functions
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/chromeos-common.sh"

get_default_board
locate_gpt

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

umount_from_loop_dev() {
  local mnt_pt=$1
  mount | grep -q " on ${mnt_pt}" && sudo umount ${mnt_pt}
  rmdir ${mnt_pt}
}

cleanup_loop_dev() {
  sudo losetup -d ${1} || /bin/true
}

get_loop_dev() {
  local loop_dev=$(sudo losetup -f)
  if [ -z "${loop_dev}" ]; then
    die "No free loop device. Free up a loop device or reboot. Exiting."
  fi
  echo ${loop_dev}
}

# Resize stateful partition of install shim to hold payload content
# Due to this resize, we need to create a new partition table and a new image.
# (see update_partition_table() for details)
resize_partition() {
  local source_part=$1  # source partition
  local add_num_sectors=$2  # number of 512-byte sectors to be added

  local source_sectors=$(roundup $(numsectors ${source_part}))
  info "source partition has ${source_sectors} 512-byte sectors."
  local resized_sectors=$(roundup $(expr $source_sectors + $add_num_sectors))
  info "resized partition has ${resized_sectors} 512-byte sectors."

  local loop_dev=$(get_loop_dev)
  trap "cleanup_loop_dev ${loop_dev}" EXIT

  # Extend the source file size to the new size.
  dd if=/dev/zero of="${source_part}" bs=1 count=1 \
      seek=$((512 * ${resized_sectors} - 1)) &>/dev/null

  # Resize the partition.
  sudo losetup "${loop_dev}" "${source_part}"
  sudo e2fsck -fp "${loop_dev}" &> /dev/null
  sudo resize2fs "${loop_dev}" &> /dev/null
  # trap handler will clean up the loop device
  echo "${resized_sectors}"
}

# Update partition table with resized stateful partition and create the final
# dev recovery image
update_partition_table() {
  local temp_state=$1       # stateful partition image
  local resized_sectors=$2  # number of sectors in resized stateful partition
  local temp_img=$(mktemp "/tmp/temp_img.XXXXXX")

  local kernel_offset=$(partoffset ${FLAGS_dev_install_shim} 2)
  local kernel_count=$(partsize ${FLAGS_dev_install_shim} 2)
  local rootfs_offset=$(partoffset ${FLAGS_dev_install_shim} 3)
  local rootfs_count=$(partsize ${FLAGS_dev_install_shim} 3)
  local oem_offset=$(partoffset ${FLAGS_dev_install_shim} 8)
  local oem_count=$(partsize ${FLAGS_dev_install_shim} 8)
  local esp_offset=$(partoffset ${FLAGS_dev_install_shim} 12)
  local esp_count=$(partsize ${FLAGS_dev_install_shim} 12)

  local temp_pmbr=$(mktemp "/tmp/pmbr.XXXXXX")
  dd if="${FLAGS_dev_install_shim}" of="${temp_pmbr}" bs=512 count=1 &>/dev/null

  # Set up a new partition table
  install_gpt "${temp_img}" "${rootfs_count}" "${resized_sectors}" \
    "${temp_pmbr}" "${esp_count}" false $(roundup ${rootfs_count}) &>/dev/null

  rm -rf "${temp_pmbr}"

  # Copy into the partition parts of the file
  dd if="${FLAGS_dev_install_shim}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_ROOTFS_A}" skip=${rootfs_offset} count=${rootfs_count} \
    &>/dev/null
  dd if="${temp_state}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_STATEFUL}" &>/dev/null
  # Copy the full kernel (i.e. with vboot sections)
  dd if="${FLAGS_dev_install_shim}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_KERN_A}" skip=${kernel_offset} count=${kernel_count} \
    &>/dev/null
  dd if="${FLAGS_dev_install_shim}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_OEM}" skip=${oem_offset} count=${oem_count} &>/dev/null
  dd if="${FLAGS_dev_install_shim}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_ESP}" skip=${esp_offset} count=${esp_count} &>/dev/null

  echo ${temp_img}
}

# Creates a dev recovery image using an existing dev install shim
# If successful, content of --payload_dir is copied to a directory named
# "dev_payload" under the root of stateful partition.
create_dev_recovery_image() {
  local temp_state=$(mktemp "/tmp/temp_state.XXXXXX")
  local stateful_offset=$(partoffset ${FLAGS_dev_install_shim} 1)
  local stateful_count=$(partsize ${FLAGS_dev_install_shim} 1)
  dd if="${FLAGS_dev_install_shim}" of="${temp_state}" conv=notrunc bs=512 \
    skip=${stateful_offset} count=${stateful_count} &>/dev/null

  local resized_sectors=$(resize_partition $temp_state $PAYLOAD_DIR_SIZE)

  # Mount resized stateful FS and copy payload content to its root directory
  local temp_mnt=$(mktemp -d "/tmp/temp_mnt.XXXXXX")
  local loop_dev=$(get_loop_dev)
  trap "umount_from_loop_dev ${temp_mnt} && cleanup_loop_dev ${loop_dev}" EXIT
  mkdir -p "${temp_mnt}"
  sudo mount -o loop=${loop_dev} "${temp_state}" "${temp_mnt}"
  sudo cp -R "${FLAGS_payload_dir}" "${temp_mnt}"
  sudo mv "${temp_mnt}/$(basename ${FLAGS_payload_dir})" \
    "${temp_mnt}/dev_payload"
  # Mark image as dev recovery
  sudo touch "${temp_mnt}/.recovery"
  sudo touch "${temp_mnt}/.dev_recovery"

  # TODO(tgao): handle install script (for default and custom cases)
  local temp_img=$(update_partition_table $temp_state $resized_sectors)

  rm -f "${temp_state}"
  # trap handler will clean up loop device and temp mount point
  echo ${temp_img}
}

# Main
DST_PATH="${INSTALL_SHIM_DIR}/${DEV_RECOVERY_IMAGE}"
info "Attempting to create dev recovery image using dev install shim \
${FLAGS_dev_install_shim}"
TEMP_IMG=$(create_dev_recovery_image)

mv -f $TEMP_IMG $DST_PATH
info "Dev recovery image created at ${DST_PATH}"
