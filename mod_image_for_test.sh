#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to modify a keyfob-based chromeos system image for testability.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images"
DEFAULT_IMAGE="${IMAGES_DIR}/$(ls -t $IMAGES_DIR 2>&-| head -1)/rootfs.image"
DEFINE_string image "$DEFAULT_IMAGE"    \
  "Location of the rootfs raw image file"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

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

echo "Modifying image ${FLAGS_image} for test..."

# Run build steps for modify for test
sudo mkdir -p "${ROOT_FS_DIR}/modify_build"
scripts_dir="${GCLIENT_ROOT}/src/scripts/mod_for_test_scripts"
for script in "${scripts_dir}"/b[0-9][0-9][0-9]*[!$~]; do
  . ${script}
done

MOD_SCRIPTS_ROOT="${GCLIENT_ROOT}/src/scripts/mod_for_test_scripts"
sudo mkdir -p "${ROOT_FS_DIR}/modify_scripts"
sudo mount --bind "${MOD_SCRIPTS_ROOT}" "${ROOT_FS_DIR}/modify_scripts"

# Run test setup script inside chroot jail to modify the image
sudo chroot "${ROOT_FS_DIR}" "/modify_scripts/test_setup.sh"

sudo umount "${ROOT_FS_DIR}/modify_scripts"
sudo rmdir "${ROOT_FS_DIR}/modify_scripts"
sudo rm -rf "${ROOT_FS_DIR}/modify_build"

cleanup
trap - EXIT

