#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images"

# Flags
DEFINE_string  from   "" "Directory containing rootfs.image and mbr.image"
DEFINE_string  to     "" "Destination file for USB image."
DEFINE_integer offset 0  "Offset to write the kernel to in the destination."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

if [ -z "${FLAGS_from}" -o -z "${FLAGS_to}" -o -z "${FLAGS_offset}" ]
then
  echo "You must define all of from, to and offset."
  exit 1
fi

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f $FOO` won't work.
FLAGS_from=`eval readlink -f ${FLAGS_from}`
FLAGS_to=`eval readlink -f ${FLAGS_to}`

function do_cleanup {
  sync
  sudo umount -l /tmp/kernel_fetch.$$
  rmdir /tmp/kernel_fetch.$$
}

trap do_cleanup EXIT

#
# Set up loop device.  This time it is used to fetch the built kernel from the
# root image.  This kernel is then written to the fourth partition.
#
echo "Fetching kernel from root image..."
mkdir /tmp/kernel_fetch.$$
sudo mount -o loop "${FLAGS_from}/rootfs.image" /tmp/kernel_fetch.$$

echo "Writing kernel to ${FLAGS_to} at ${FLAGS_offset}..."
sudo "${SCRIPTS_DIR}"/file_copy.py \
  if=/tmp/kernel_fetch.$$/boot/vmlinux.uimg \
  of="${FLAGS_to}" \
  seek_bytes="${FLAGS_offset}"
echo "Done."

do_cleanup

trap - EXIT
