#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to modify a pristine/dev Chrome OS image to be used for recovery

. "$(dirname "$0")/resize_stateful_partition.sh"

# Script must be run inside the chroot.
restart_in_chroot_if_needed $*

get_default_board

# Constants
TEMP_IMG=$(mktemp "/tmp/temp_img.XXXXXX")
RECOVERY_IMAGE="recovery_image.bin"

DEFINE_string board "$DEFAULT_BOARD" "Board for which the image was built"
DEFINE_string image "" "Location of the rootfs raw image file"
DEFINE_string output "${RECOVERY_IMAGE}" \
  "(optional) output image name. Default: ${RECOVERY_IMAGE}"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# No board, no default and no image set then we can't find the image
if [ -z $FLAGS_image ] && [ -z $FLAGS_board ] ; then
  setup_board_warning
  die "mod_image_for_recovery failed.  No board set and no image set"
fi

# We have a board name but no image set. Use image at default location
if [ -z $FLAGS_image ] ; then
  IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
  FILENAME="chromiumos_image.bin"
  FLAGS_image="${IMAGES_DIR}/$(ls -t $IMAGES_DIR 2>&-| head -1)/${FILENAME}"
fi

# Turn path into an absolute path.
FLAGS_image=$(eval readlink -f ${FLAGS_image})

# Abort early if we can't find the image
if [ ! -f $FLAGS_image ] ; then
  echo "No image found at $FLAGS_image"
  exit 1
fi

set -u
set -e

# Constants
IMAGE_DIR="$(dirname "$FLAGS_image")"

# Creates a dev recovery image using an existing dev install shim
# If successful, content of --payload_dir is copied to a directory named
# "dev_payload" under the root of stateful partition.
create_recovery_image() {
  local src_img=$1  # base image
  local src_state=$(mktemp "/tmp/src_state.XXXXXX")
  local stateful_offset=$(partoffset ${src_img} 1)
  local stateful_count=$(partsize ${src_img} 1)

  dd if="${src_img}" of="${src_state}" conv=notrunc bs=512 \
    skip=${stateful_offset} count=${stateful_count}

  # Mount original stateful partition to figure out its actual size
  local src_loop_dev=$(get_loop_dev)
  trap "cleanup_loop_dev ${src_loop_dev}" EXIT

  # Setup loop dev
  sudo losetup $src_loop_dev $src_state
  local block_size=$(sudo /sbin/dumpe2fs $src_loop_dev | grep "Block size:" \
                     | tr -d ' ' | cut -f2 -d:)
  echo "block_size = $block_size"
  local min_size=$(sudo /sbin/resize2fs -P $src_loop_dev | tr -d ' ' \
                   | cut -f2 -d:)
  echo "min_size = $min_size $block_size blocks"

  # Add 20%, convert to 512-byte sectors and round up to 2Mb boundary
  local min_sectors=$(roundup $(((min_size * block_size * 120) / (512 * 100))))
  echo "min_sectors = ${min_sectors} 512-byte blocks"
  sudo e2fsck -fp "${src_loop_dev}"
  # Resize using 512-byte sectors
  sudo /sbin/resize2fs $src_loop_dev ${min_sectors}s

  # Delete the loop
  trap - EXIT
  cleanup_loop_dev ${src_loop_dev}

  # Truncate the image at the new size
  dd if=/dev/zero of=$src_state bs=512 seek=$min_sectors count=0

  # Mount and touch .recovery  # Soon not to be needed :/
  local new_mnt=$(mktemp -d "/tmp/src_mnt.XXXXXX")
  mkdir -p "${new_mnt}"
  local new_loop_dev=$(get_loop_dev)
  trap "cleanup_loop_dev ${new_loop_dev} && rmdir ${new_mnt} && \
        rm -f ${src_state}" EXIT
  sudo mount -o loop=${new_loop_dev} "${src_state}" "${new_mnt}"
  trap "umount_from_loop_dev ${new_mnt} && rm -f ${src_state}" EXIT
  sudo touch "${new_mnt}/.recovery"

  (update_partition_table $src_img $src_state $min_sectors $TEMP_IMG)
  # trap handler will handle unmount and clean up of loop device and temp files
}

# Main
DST_PATH="${IMAGE_DIR}/${FLAGS_output}"
echo "Making a copy of original image ${FLAGS_image}"
(create_recovery_image $FLAGS_image)

if [ -n ${TEMP_IMG} ] && [ -f ${TEMP_IMG} ]; then
  mv -f $TEMP_IMG $DST_PATH
  echo "Recovery image created at ${DST_PATH}"
else
  echo "Failed to create recovery image"
fi
