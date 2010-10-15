#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to create a Chrome OS dev recovery image using a dev install shim

# Source constants and utility functions
. "$(dirname "$0")/resize_stateful_partition.sh"

get_default_board

# Constants
TEMP_IMG=$(mktemp "/tmp/temp_img.XXXXXX")

DEFINE_string board "$DEFAULT_BOARD" "Board for which the image was built \
Default: ${DEFAULT_BOARD}"
DEFINE_string dev_install_shim "" "Path of the developer install shim. \
Default: (empty)"
DEFINE_string payload_dir "" "Directory containing developer payload and \
(optionally) a custom install script. Default: (empty)"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

set -e

# No board set and no default set then we can't proceed
if [ -z $FLAGS_board ] ; then
  setup_board_warning
  die "No board set"
fi

# Abort early if --payload_dir is not set, invalid or empty
if [ -z $FLAGS_payload_dir ] ; then
  die "flag --payload_dir not set"
fi

if [ ! -d "${FLAGS_payload_dir}" ] ; then
  die "${FLAGS_payload_dir} is not a directory"
fi

PAYLOAD_DIR_SIZE=
if [ -z "$(ls -A $FLAGS_payload_dir)" ] ; then
  die "${FLAGS_payload_dir} is empty"
else
  # Get directory size in 512-byte sectors so we can resize stateful partition
  PAYLOAD_DIR_SIZE=\
"$(du --apparent-size -B 512 ${FLAGS_payload_dir} | awk '{print $1}')"
  info "${FLAGS_payload_dir} has ${PAYLOAD_DIR_SIZE} 512-byte sectors"
fi

DEV_INSTALL_SHIM="dev_install_shim.bin"
# We have a board name but no dev_install_shim set. Try find a recent one
if [ -z $FLAGS_dev_install_shim ] ; then
  IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
  FLAGS_dev_install_shim=\
"${IMAGES_DIR}/$(ls -t $IMAGES_DIR 2>&-| head -1)/${DEV_INSTALL_SHIM}"
fi

# Turn relative path into an absolute path.
FLAGS_dev_install_shim=$(eval readlink -f ${FLAGS_dev_install_shim})

# Abort early if we can't find the install shim
if [ ! -f $FLAGS_dev_install_shim ] ; then
  die "No dev install shim found at $FLAGS_dev_install_shim"
else
  info "Using a recent dev install shim at ${FLAGS_dev_install_shim}"
fi

# Constants
INSTALL_SHIM_DIR="$(dirname "$FLAGS_dev_install_shim")"
DEV_RECOVERY_IMAGE="dev_recovery_image.bin"

# Creates a dev recovery image using an existing dev install shim
# If successful, content of --payload_dir is copied to a directory named
# "dev_payload" under the root of stateful partition.
create_dev_recovery_image() {
  local temp_state=$(mktemp "/tmp/temp_state.XXXXXX")
  local stateful_offset=$(partoffset ${FLAGS_dev_install_shim} 1)
  local stateful_count=$(partsize ${FLAGS_dev_install_shim} 1)
  dd if="${FLAGS_dev_install_shim}" of="${temp_state}" conv=notrunc bs=512 \
    skip=${stateful_offset} count=${stateful_count} &>/dev/null

  local resized_sectors=$(enlarge_partition_image $temp_state $PAYLOAD_DIR_SIZE)

  # Mount resized stateful FS and copy payload content to its root directory
  local temp_mnt=$(mktemp -d "/tmp/temp_mnt.XXXXXX")
  local loop_dev=$(get_loop_dev)
  trap "cleanup_loop_dev ${loop_dev}" EXIT
  mkdir -p "${temp_mnt}"
  sudo mount -o loop=${loop_dev} "${temp_state}" "${temp_mnt}"
  trap "umount_from_loop_dev ${temp_mnt} && rm -f \"${temp_state}\"" EXIT
  sudo cp -R "${FLAGS_payload_dir}" "${temp_mnt}/dev_payload"

  # Mark image as dev recovery
  sudo touch "${temp_mnt}/.recovery"
  sudo touch "${temp_mnt}/.dev_recovery"

  # TODO(tgao): handle install script (for default and custom cases)
  (update_partition_table $FLAGS_dev_install_shim $temp_state \
       $resized_sectors $TEMP_IMG)

  # trap handler will clean up loop device and temp mount point
}

# Main
DST_PATH="${INSTALL_SHIM_DIR}/${DEV_RECOVERY_IMAGE}"
info "Attempting to create dev recovery image using dev install shim \
${FLAGS_dev_install_shim}"
(create_dev_recovery_image)

if [ -n ${TEMP_IMG} ] && [ -f ${TEMP_IMG} ]; then
  mv -f $TEMP_IMG $DST_PATH
  info "Dev recovery image created at ${DST_PATH}"
else
  info "Failed to create developer recovery image"
fi
