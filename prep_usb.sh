#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

DEFINE_boolean "unmount" $FLAGS_FALSE "unmount USB partitions" "u"
DEFINE_string "device" "/dev/sdc" \
    "The device on which the mountable partitions live." "d"
DEFINE_string "rootfs_mountpt" "/tmp/m" "Mount point for rootfs" "r"
DEFINE_string "stateful_mountpt" "/tmp/s" \
    "Mount point for stateful partition" "s"

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

mkdir -p "${FLAGS_rootfs_mountpt}"
mkdir -p "${FLAGS_stateful_mountpt}"

if [[ $FLAGS_unmount -eq $FLAGS_FALSE ]]; then
  sudo mount "${FLAGS_device}3" "${FLAGS_rootfs_mountpt}"
  sudo mount "${FLAGS_device}1" "${FLAGS_stateful_mountpt}"
  sudo mount --bind "${FLAGS_stateful_mountpt}/var" \
      "${FLAGS_rootfs_mountpt}/var"
  echo "RootFS of bootable medium mounted at ${FLAGS_rootfs_mountpt}."
else
  echo "Attempting to unmount ${FLAGS_stateful_mountpt} " \
      "and ${FLAGS_rootfs_mountpt}"
  sudo umount "${FLAGS_rootfs_mountpt}/var"
  sudo umount "${FLAGS_stateful_mountpt}"
  sudo umount "${FLAGS_rootfs_mountpt}"
fi
