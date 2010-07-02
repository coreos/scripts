#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Helper script that mounts chromium os image from a device or directory
# and creates mount points for /var and /usr/local (if in dev_mode).

. "$(dirname "$0")/common.sh"

# For functions related to gpt images.
. "$(dirname "$0")/chromeos-common.sh"
locate_gpt

get_default_board

# Flags.
DEFINE_string board "$DEFAULT_BOARD" \
  "The board for which the image was built." b
DEFINE_boolean unmount $FLAGS_FALSE \
  "Unmount previously mounted dir." u
DEFINE_string from "/dev/sdc" \
  "Directory containing image or device with image on it" f
DEFINE_string image "chromiumos_image.bin"\
  "Name of the bin file if a directory is specified in the from flag" i
DEFINE_string "rootfs_mountpt" "/tmp/m" "Mount point for rootfs" "r"
DEFINE_string "stateful_mountpt" "/tmp/s" \
    "Mount point for stateful partition" "s"
DEFINE_string "esp_mountpt" "" \
    "Mount point for esp partition" "e"
DEFINE_boolean most_recent ${FLAGS_FALSE} "Use the most recent image dir" m

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on error
set -e

# Common unmounts for either a device or directory
function unmount_image() {
  echo "Unmounting image from ${FLAGS_stateful_mountpt}" \
      "and ${FLAGS_rootfs_mountpt}"
  # Don't die on error to force cleanup
  set +e
  # Reset symlinks in /usr/local.
  setup_symlinks_on_root "/usr/local" "/var" \
    "${FLAGS_stateful_mountpt}"
  fix_broken_symlinks "${FLAGS_rootfs_mountpt}"
  sudo umount "${FLAGS_rootfs_mountpt}/usr/local"
  sudo umount "${FLAGS_rootfs_mountpt}/var"
  test -n "${FLAGS_esp_mountpt}" && sudo umount -d "${FLAGS_esp_mountpt}"
  sudo umount -d "${FLAGS_stateful_mountpt}"
  sudo umount -d "${FLAGS_rootfs_mountpt}"
  set -e
}

function get_usb_partitions() {
  sudo mount "${FLAGS_from}3" "${FLAGS_rootfs_mountpt}"
  sudo mount "${FLAGS_from}1" "${FLAGS_stateful_mountpt}"
  test -n "${FLAGS_esp_mountpt}" && \
    sudo mount "${FLAGS_from}12" "${FLAGS_esp_mountpt}"
}

function get_gpt_partitions() {
  local filename="${FLAGS_image}"

  # Mount the rootfs partition using a loopback device.
  local offset=$(partoffset "${FLAGS_from}/${filename}" 3)
  sudo mount -o loop,offset=$(( offset * 512 )) "${FLAGS_from}/${filename}" \
    "${FLAGS_rootfs_mountpt}"

  # Mount the stateful partition using a loopback device.
  offset=$(partoffset "${FLAGS_from}/${filename}" 1)
  sudo mount -o loop,offset=$(( offset * 512 )) "${FLAGS_from}/${filename}" \
    "${FLAGS_stateful_mountpt}"

  # Mount the stateful partition using a loopback device.
  if [[ -n "${FLAGS_esp_mountpt}" ]]; then
    offset=$(partoffset "${FLAGS_from}/${filename}" 12)
    sudo mount -o loop,offset=$(( offset * 512 )) "${FLAGS_from}/${filename}" \
      "${FLAGS_esp_mountpt}"
  fi
}

# Mount a gpt based image.
function mount_image() {
  mkdir -p "${FLAGS_rootfs_mountpt}"
  mkdir -p "${FLAGS_stateful_mountpt}"
  test -n "${FLAGS_esp_mountpt}" && \
    mkdir -p "${FLAGS_esp_mountpt}"

  # Get the partitions for the image / device.
  if [ -b ${FLAGS_from} ] ; then
    get_usb_partitions
  else
    get_gpt_partitions
  fi

  # Mount directories and setup symlinks.
  sudo mount --bind "${FLAGS_stateful_mountpt}/var" \
    "${FLAGS_rootfs_mountpt}/var"
  sudo mount --bind "${FLAGS_stateful_mountpt}/dev_image" \
    "${FLAGS_rootfs_mountpt}/usr/local"
  # Setup symlinks in /usr/local so you can emerge packages into /usr/local.
  setup_symlinks_on_root "${FLAGS_stateful_mountpt}/dev_image" \
    "${FLAGS_stateful_mountpt}/var" "${FLAGS_stateful_mountpt}"
  echo "Image specified by ${FLAGS_from} mounted at"\
    "${FLAGS_rootfs_mountpt} successfully."
}

# Find the last image built on the board.
if [ ${FLAGS_most_recent} -eq ${FLAGS_TRUE} ] ; then
  IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
  FLAGS_from="${IMAGES_DIR}/$(ls -t ${IMAGES_DIR} 2>&-| head -1)"
fi

# Turn path into an absolute path.
FLAGS_from=`eval readlink -f ${FLAGS_from}`

# Perform desired operation.
if [ ${FLAGS_unmount} -eq ${FLAGS_TRUE} ] ; then
  unmount_image
else
  mount_image
fi
