#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to modify a pristine/dev Chrome OS image to be used for recovery

. "$(dirname "$0")/common.sh"

# Load functions and constants for chromeos-install
. "$(dirname "$0")/chromeos-common.sh"

# Script must be run inside the chroot.
restart_in_chroot_if_needed $*

get_default_board

DEFINE_string board "$DEFAULT_BOARD" "Board for which the image was built"
DEFINE_string image "" "Location of the rootfs raw image file"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# No board, no default and no image set then we can't find the image
if [ -z $FLAGS_image ] && [ -z $FLAGS_board ] ; then
  setup_board_warning
  die "mod_image_for_recovery failed.  No board set and no image set"
fi

# We have a board name but no image set.  Use image at default location
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

set -e

# Constants
IMAGE_DIR="$(dirname "$FLAGS_image")"
IMAGE_NAME="$(basename "$FLAGS_image")"
ROOT_FS_DIR="$IMAGE_DIR/rootfs"
STATEFUL_DIR="$IMAGE_DIR/stateful_partition"
RECOVERY_IMAGE="recovery_image.bin"

mount_gpt_cleanup() {
  "${SCRIPTS_DIR}/mount_gpt_image.sh" -u -r "$1" -s "$2"
}

# Modifies an existing image for recovery use
update_recovery_packages() {
  local image_name=$1

  echo "Modifying image ${image_name} for recovery use"

  trap "mount_gpt_cleanup \"${ROOT_FS_DIR}\" \"${STATEFUL_DIR}\"" EXIT

  ${SCRIPTS_DIR}/mount_gpt_image.sh --from "${IMAGE_DIR}" \
    --image "$( basename ${image_name} )" -r "${ROOT_FS_DIR}" \
    -s "${STATEFUL_DIR}"

  # Mark the image as a recovery image (needed for recovery boot)
  sudo touch "${STATEFUL_DIR}/.recovery"

  trap - EXIT
  ${SCRIPTS_DIR}/mount_gpt_image.sh -u -r "${ROOT_FS_DIR}" \
      -s "${STATEFUL_DIR}"
}

# Main

DST_PATH="${IMAGE_DIR}/${RECOVERY_IMAGE}"
echo "Making a copy of original image ${FLAGS_image}"
cp $FLAGS_image $DST_PATH
update_recovery_packages $DST_PATH
echo "Recovery image created at ${DST_PATH}"
