#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to modify a keyfob-based chromeos system image for testability.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

DEFAULT_BOARD=x86-generic
IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${DEFAULT_BOARD}"
DEFAULT_IMAGE="${IMAGES_DIR}/$(ls -t $IMAGES_DIR 2>&-| head -1)/rootfs.image"

DEFINE_string board "$DEFAULT_BOARD" "Board for which the image was built"
DEFINE_string image "$DEFAULT_IMAGE"    \
  "Location of the rootfs raw image file"
DEFINE_boolean yes $FLAGS_FALSE "Answer yes to all prompts" "y"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${DEFAULT_BOARD}"
DEFAULT_IMAGE="${IMAGES_DIR}/$(ls -t $IMAGES_DIR 2>&-| head -1)/rootfs.image"

# Make sure anything mounted in the rootfs is cleaned up ok on exit.
cleanup_rootfs_mounts() {
  # Occasionally there are some daemons left hanging around that have our
  # root image file system open. We do a best effort attempt to kill them.
  PIDS=`sudo lsof -t "${ROOT_FS_DIR}" | sort | uniq`
  for pid in ${PIDS}
  do
    local cmdline=`cat /proc/$pid/cmdline`
    echo "Killing process that has open file on our rootfs: $cmdline"
    ! sudo kill $pid  # Preceded by ! to disable ERR trap.
  done
}

cleanup_rootfs_loop() {
  sudo umount "${LOOP_DEV}"
  sleep 1  # in case $LOOP_DEV is in use
  sudo losetup -d "${LOOP_DEV}"
}

cleanup() {
  # Disable die on error.
  set +e

  cleanup_rootfs_mounts
  if [ -n "${LOOP_DEV}" ]
  then
    cleanup_rootfs_loop
  fi

  # Turn die on error back on.
  set -e
}

# main process begins here.
set -e
trap cleanup EXIT

ROOT_FS_DIR="`dirname ${FLAGS_image}`/rootfs"
mkdir -p "${ROOT_FS_DIR}"

LOOP_DEV=`sudo losetup -f`
sudo losetup "${LOOP_DEV}" "${FLAGS_image}"
sudo mount "${LOOP_DEV}" "${ROOT_FS_DIR}"

# Make sure this is really what the user wants, before nuking the device
if [ $FLAGS_yes -ne $FLAGS_TRUE ]; then
  read -p "Modifying image ${FLAGS_image} for test; are you sure (y/N)? " SURE
  SURE="${SURE:0:1}" # Get just the first character
  if [ "$SURE" != "y" ]; then
    echo "Ok, better safe than sorry."
    exit 1
  fi
else
  echo "Modifying image ${FLAGS_image} for test..."
fi

MOD_SCRIPTS_ROOT="${GCLIENT_ROOT}/src/scripts/mod_for_test_scripts"
sudo mkdir -p "${ROOT_FS_DIR}/modify_scripts"
sudo mount --bind "${MOD_SCRIPTS_ROOT}" "${ROOT_FS_DIR}/modify_scripts"

# Run test setup script inside chroot jail to modify the image
sudo chroot "${ROOT_FS_DIR}" "/modify_scripts/test_setup.sh"

sudo umount "${ROOT_FS_DIR}/modify_scripts"
sudo rmdir "${ROOT_FS_DIR}/modify_scripts"

cleanup
trap - EXIT

