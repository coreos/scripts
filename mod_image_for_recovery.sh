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

  echo "Modifying image ${image_name} for recovery use"

  trap "mount_gpt_cleanup \"${ROOT_FS_DIR}\" \"${STATEFUL_FS_DIR}\"" EXIT

  ${SCRIPTS_DIR}/mount_gpt_image.sh --from "${OUTPUT_DIR}" \
    --image "$( basename ${image_name} )" -r "${ROOT_FS_DIR}" \
    -s "${STATEFUL_FS_DIR}"

  # Mark the image as a recovery image (needed for recovery boot)
  sudo touch "${STATEFUL_FS_DIR}/.recovery"

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
