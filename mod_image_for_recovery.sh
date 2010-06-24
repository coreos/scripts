#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to modify a pristine/dev Chrome OS image to be used for recovery

. "$(dirname "$0")/common.sh"

# Script must be run inside the chroot.
restart_in_chroot_if_needed $*

DEFINE_string image_dir "" \
  "Directory to pristine/base image."
DEFINE_string image_name "chromiumos_image.bin" \
  "Name of Chrome OS image to modify."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

set -e

if [ -z $FLAGS_image_dir ] || [ ! -d $FLAGS_image_dir ]; then
  echo "Error: invalid flag --image_dir"
  exit 1
fi

SRC_PATH="${FLAGS_image_dir}/${FLAGS_image_name}"
if [ -z $FLAGS_image_name ] || [ ! -f $SRC_PATH ]; then
  echo "Error: invalid flag --image_name"
  exit 1
fi

# Constants
OUTPUT_DIR=$FLAGS_image_dir
ROOT_FS_DIR="${OUTPUT_DIR}/rootfs"
STATEFUL_FS_DIR="${OUTPUT_DIR}/stateful_partition"
RECOVERY_IMAGE="recovery_image.bin"

mount_gpt_cleanup() {
  "${SCRIPTS_DIR}/mount_gpt_image.sh" -u -r "$1" -s "$2"
}

# Modifies an existing image for recovery use
update_recovery_packages() {
  local image_name=$1
  local sector_size=512  # sector size in bytes
  local num_sectors_vb=128  # number of sectors in kernel verification blob
  # Start offset of kernel A (aligned to 4096-sector boundary)
  local start_kern_a=4096
  local vb_file="${STATEFUL_FS_DIR}/verification_blob.kernel"

  echo "Modifying image ${image_name} for recovery use"

  trap "mount_gpt_cleanup \"${ROOT_FS_DIR}\" \"${STATEFUL_FS_DIR}\"" EXIT

  ${SCRIPTS_DIR}/mount_gpt_image.sh --from "${OUTPUT_DIR}" \
    --image "$( basename ${image_name} )" -r "${ROOT_FS_DIR}" \
    -s "${STATEFUL_FS_DIR}"

  # Mark the image as a recovery image (needed for recovery boot)
  sudo touch "${STATEFUL_FS_DIR}/.recovery"

  # Copy verification blob out of kernel A into stateful partition
  # so that we can restore it during recovery
  sudo touch $vb_file
  echo "Backing up kernel verification blob onto stateful partition ..."
  sudo dd if="$image_name" of="$vb_file" skip=$start_kern_a bs=$sector_size \
      count=$num_sectors_vb conv=notrunc

  # Overwrite verification blob with recovery image verification blob
  # TODO(tgao): resign kernel for recovery image
  echo "Overwrite kernel verification blob with resigned blob for recovery..."
  sudo dd if=/dev/zero of="$image_name" seek=$start_kern_a bs=$sector_size \
      count=$num_sectors_vb conv=notrunc

  trap - EXIT
  ${SCRIPTS_DIR}/mount_gpt_image.sh -u -r "${ROOT_FS_DIR}" \
      -s "${STATEFUL_FS_DIR}"
}

# Main

DST_PATH="${OUTPUT_DIR}/${RECOVERY_IMAGE}"
echo "Making a copy of original image ${SRC_PATH}"
cp $SRC_PATH $DST_PATH
update_recovery_packages $DST_PATH
echo "Recovery image created at ${DST_PATH}"
