#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Utility methods used to resize a stateful partition and update the GPT table

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
. "${SCRIPT_ROOT}/common.sh" || (echo "Unable to load common.sh" && exit 1)
# --- END COMMON.SH BOILERPLATE ---

# Need to be inside the chroot to load chromeos-common.sh
assert_inside_chroot

# Load functions and constants for chromeos-install
. "/usr/lib/installer/chromeos-common.sh" || \
  die "Unable to load /usr/lib/installer/chromeos-common.sh"

locate_gpt

umount_from_loop_dev() {
  local mnt_pt=$1
  mount | grep -q " on ${mnt_pt}" && sudo umount -d ${mnt_pt}
  rmdir ${mnt_pt}
}

cleanup_loop_dev() {
  sudo losetup -d ${1} || /bin/true
}

# Resize stateful partition of install shim to hold payload content
# Due to this resize, we need to create a new partition table and a new image.
# (see update_partition_table() for details)
enlarge_partition_image() {
  local source_part=$1  # source partition
  local add_num_sectors=$2  # number of 512-byte sectors to be added

  local source_sectors=$(roundup $(numsectors ${source_part}))
  info "source partition has ${source_sectors} 512-byte sectors."
  local resized_sectors=$(roundup $(expr $source_sectors + $add_num_sectors))
  info "resized partition has ${resized_sectors} 512-byte sectors."

  # Extend the source file size to the new size.
  dd if=/dev/zero of="${source_part}" bs=1 count=1 \
      seek=$((512 * ${resized_sectors} - 1)) &>/dev/null

  # Resize the partition.
  local loop_dev=$(losetup --show -f "${source_part}")
  if [ -z "${loop_dev}" ]; then
    die "No free loop device. Free up a loop device or reboot. Exiting."
  fi
  trap "cleanup_loop_dev ${loop_dev}" EXIT
  sudo e2fsck -fp "${loop_dev}" &> /dev/null
  sudo resize2fs "${loop_dev}" &> /dev/null
  # trap handler will clean up the loop device
  echo "${resized_sectors}"
}

# Update partition table with resized stateful partition
update_partition_table() {
  local src_img=$1          # source image
  local temp_state=$2       # stateful partition image
  local resized_sectors=$3  # number of sectors in resized stateful partition
  local temp_img=$4

  local kern_a_offset=$(partoffset ${src_img} 2)
  local kern_a_count=$(partsize ${src_img} 2)
  local kern_b_offset=$(partoffset ${src_img} 4)
  local kern_b_count=$(partsize ${src_img} 4)
  local rootfs_offset=$(partoffset ${src_img} 3)
  local rootfs_count=$(partsize ${src_img} 3)
  local oem_offset=$(partoffset ${src_img} 8)
  local oem_count=$(partsize ${src_img} 8)
  local esp_offset=$(partoffset ${src_img} 12)
  local esp_count=$(partsize ${src_img} 12)

  local temp_pmbr=$(mktemp "/tmp/pmbr.XXXXXX")
  dd if="${src_img}" of="${temp_pmbr}" bs=512 count=1 &>/dev/null

  trap "rm -rf \"${temp_pmbr}\"" EXIT
  # Set up a new partition table
  install_gpt "${temp_img}" "${rootfs_count}" "${resized_sectors}" \
    "${temp_pmbr}" "${esp_count}" false \
    $(((rootfs_count * 512)/(1024 * 1024)))

  # Copy into the partition parts of the file
  dd if="${src_img}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_ROOTFS_A}" skip=${rootfs_offset} count=${rootfs_count}
  dd if="${temp_state}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_STATEFUL}"
  # Copy the full kernel (i.e. with vboot sections)
  dd if="${src_img}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_KERN_A}" skip=${kern_a_offset} count=${kern_a_count}
  dd if="${src_img}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_KERN_B}" skip=${kern_b_offset} count=${kern_b_count}
  dd if="${src_img}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_OEM}" skip=${oem_offset} count=${oem_count}
  dd if="${src_img}" of="${temp_img}" conv=notrunc bs=512 \
    seek="${START_ESP}" skip=${esp_offset} count=${esp_count}
}
