#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Helper script that mounts chromium os image from a device or directory
# and creates mount points for /var and /usr/local (if in dev_mode).

. "$(dirname "$0")/common.sh"

get_default_board

# Flags.
DEFINE_string board "$DEFAULT_BOARD" \
  "The board for which the image was built." b
DEFINE_boolean unmount $FLAGS_FALSE \
  "Unmount previously mounted dir." u
DEFINE_string from "/dev/sdc" \
  "Directory containing image or device with image on it" f
DEFINE_boolean test $FLAGS_FALSE "Use chromiumos_test_image.bin" t
DEFINE_string "rootfs_mountpt" "/tmp/m" "Mount point for rootfs" "r"
DEFINE_string "stateful_mountpt" "/tmp/s" \
    "Mount point for stateful partition" "s"
DEFINE_boolean most_recent ${FLAGS_FALSE} "Use the most recent image dir" m

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on error
set -e

# Common umounts for either a device or directory
function unmount_common() {
  echo "Unmounting image from ${FLAGS_stateful_mountpt}" \
      "and ${FLAGS_rootfs_mountpt}"
  # Don't die on error to force cleanup
  set +e
  if [ -e "${FLAGS_rootfs_mountpt}/root/.dev_mode" ] ; then
    sudo umount "${FLAGS_rootfs_mountpt}/usr/local"
  fi
  sudo umount "${FLAGS_rootfs_mountpt}/var"
  sudo umount -d "${FLAGS_stateful_mountpt}"
  sudo umount -d "${FLAGS_rootfs_mountpt}"
  set -e
}

# Sets up the rootfs and stateful partitions specified by
# ${FLAGS_from}${prefix}[31] to the given mount points and sets up var and
# usr/local
# ${1} - prefix name for the partition
# ${2} - extra mount options for the partitions
function mount_common() {
  mkdir -p "${FLAGS_rootfs_mountpt}"
  mkdir -p "${FLAGS_stateful_mountpt}"
  sudo mount ${2} "${FLAGS_from}${1}3" "${FLAGS_rootfs_mountpt}"
  sudo mount ${2} "${FLAGS_from}${1}1" "${FLAGS_stateful_mountpt}"
  sudo mount --bind "${FLAGS_stateful_mountpt}/var" \
    "${FLAGS_rootfs_mountpt}/var"
  if [ -e "${FLAGS_rootfs_mountpt}/root/.dev_mode" ] ; then
    sudo mount --bind "${FLAGS_stateful_mountpt}/dev_image" \
      "${FLAGS_rootfs_mountpt}/usr/local"
  fi
  echo "Root FS specified by "${FLAGS_from}${1}3" mounted at"\
    "${FLAGS_rootfs_mountpt} successfully."
}

# Find the last image built on the board
if [ ${FLAGS_most_recent} -eq ${FLAGS_TRUE} ] ; then
  IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
  FLAGS_from="${IMAGES_DIR}/$(ls -t ${IMAGES_DIR} 2>&-| head -1)"
fi

# Turn into absolute path
FLAGS_from=`eval readlink -f ${FLAGS_from}`

# Set the file name of the image if ${FLAGS_from} is not a device and cd
if [ -d "${FLAGS_from}" ] ; then
  cd "${FLAGS_from}"
  IMAGE_NAME=chromiumos_image.bin
  [ ${FLAGS_test} -eq ${FLAGS_TRUE} ] && IMAGE_NAME=chromiumos_test_image.bin
fi

if [ ${FLAGS_unmount} -eq ${FLAGS_TRUE} ] ; then
  unmount_common
  if [ -d "${FLAGS_from}" ] ; then
    echo "Re-packing partitions onto ${FLAGS_from}/${IMAGE_NAME}"
    ./pack_partitions.sh ${IMAGE_NAME} 2> /dev/null
    sudo rm part_*
  fi
else
  if [ -b ${FLAGS_from} ] ; then
    mount_common "" ""
  else
    echo "Unpacking partitions from ${FLAGS_from}/${IMAGE_NAME}"
    ./unpack_partitions.sh ${IMAGE_NAME} 2> /dev/null
    mount_common "/part_" "-o loop"
  fi
fi
