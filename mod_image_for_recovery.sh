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

# loop device utility methods mostly duplicated from
#   src/platform/installer/chromeos-install
# TODO(tgao): minimize duplication by refactoring these methods into a separate
# library script which both scripts can reference

# Set up loop device for an image file at specified offset
loop_offset_setup() {
  local filename=$1
  local offset=$2  # 512-byte sectors

  LOOP_DEV=$(sudo losetup -f)
  if [ -z "$LOOP_DEV" ]
  then
    echo "No free loop device. Free up a loop device or reboot. Exiting."
    exit 1
  fi

  sudo losetup -o $(($offset * 512)) ${LOOP_DEV} ${filename}
}

loop_offset_cleanup() {
  sudo losetup -d ${LOOP_DEV} || /bin/true
}

mount_on_loop_dev() {
  TMPMNT=$(mktemp -d)
  sudo mount ${LOOP_DEV} ${TMPMNT}
}

# Unmount loop-mounted device.
umount_from_loop_dev() {
  mount | grep -q " on ${TMPMNT} " && sudo umount ${TMPMNT}
}

# Undo both mount and loop.
my_cleanup() {
  umount_from_loop_dev
  loop_offset_cleanup
}

# Modifies an existing image for recovery use
update_recovery_packages() {
  local image_name=$1

  echo "Modifying image ${image_name} for recovery use"

  locate_gpt  # set $GPT env var
  loop_offset_setup ${image_name} $(partoffset "${image_name}" 1)
  trap loop_offset_cleanup EXIT
  mount_on_loop_dev "readwrite"
  trap my_cleanup EXIT
  sudo touch ${TMPMNT}/.recovery
  umount_from_loop_dev
  trap loop_offset_cleanup EXIT
  loop_offset_cleanup
  trap - EXIT
}

# Main

DST_PATH="${IMAGE_DIR}/${FLAGS_output}"
echo "Making a copy of original image ${FLAGS_image}"
cp $FLAGS_image $DST_PATH
update_recovery_packages $DST_PATH

echo "Recovery image created at ${DST_PATH}"
