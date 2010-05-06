#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to modify a keyfob-based chromeos system image for testability.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Load functions and constants for chromeos-install
. "$(dirname "$0")/chromeos-common.sh"

get_default_board

DEFINE_string board "$DEFAULT_BOARD" "Board for which the image was built"
DEFINE_string qualdb "/tmp/run_remote_tests.*" \
    "Location of qualified component file"
DEFINE_string image "" "Location of the rootfs raw image file"
DEFINE_boolean factory $FLAGS_FALSE "Modify the image for manufacturing testing"
DEFINE_boolean factory_install $FLAGS_FALSE \
    "Modify the image for factory install shim"
DEFINE_boolean yes $FLAGS_FALSE "Answer yes to all prompts" "y"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# No board, no default and no image set then we can't find the image
if [ -z $FLAGS_image ] && [ -z $FLAGS_board ] ; then
  setup_board_warning
  echo "*** mod_image_for_test failed.  No board set and no image set"
  exit 1
fi

# We have a board name but no image set.  Use image at default location
if [ -z $FLAGS_image ] ; then
  IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
  FILENAME="chromiumos_image.bin"
  FLAGS_image="${IMAGES_DIR}/$(ls -t $IMAGES_DIR 2>&-| head -1)/${FILENAME}"
fi

# Abort early if we can't find the image
if [ ! -f $FLAGS_image ] ; then
  echo "No image found at $FLAGS_image"
  exit 1
fi

# Make sure anything mounted in the rootfs/stateful is cleaned up ok on exit.
cleanup_mounts() {
  # Occasionally there are some daemons left hanging around that have our
  # root/stateful image file system open. We do a best effort attempt to kill
  # them.
  PIDS=`sudo lsof -t "$1" | sort | uniq`
  for pid in ${PIDS}
  do
    local cmdline=`cat /proc/$pid/cmdline`
    echo "Killing process that has open file on the mounted directory: $cmdline"
    sudo kill $pid || /bin/true
  done
}

cleanup_loop() {
  sudo umount "$1"
  sleep 1  # in case the loop device is in use
  sudo losetup -d "$1"
}

cleanup() {
  # Disable die on error.
  set +e

  cleanup_mounts "${ROOT_FS_DIR}"
  if [ -n "${ROOT_LOOP_DEV}" ]
  then
    sudo umount "${ROOT_FS_DIR}/var"
    cleanup_loop "${ROOT_LOOP_DEV}"
  fi
  rmdir "${ROOT_FS_DIR}"

  cleanup_mounts "${STATEFUL_DIR}"
  if [ -n "${STATEFUL_LOOP_DEV}" ]
  then
    cleanup_loop "${STATEFUL_LOOP_DEV}"
  fi
  rmdir "${STATEFUL_DIR}"

  # Turn die on error back on.
  set -e
}

# main process begins here.

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

set -e

ROOT_FS_DIR=$(dirname "${FLAGS_image}")/rootfs
mkdir -p "${ROOT_FS_DIR}"

STATEFUL_DIR=$(dirname "${FLAGS_image}")/stateful_partition
mkdir -p "${STATEFUL_DIR}"

trap cleanup EXIT

# Figure out how to loop mount the rootfs partition. It should be partition 3
# on the disk image.
offset=$(partoffset "${FLAGS_image}" 3)

ROOT_LOOP_DEV=$(sudo losetup -f)
if [ -z "$ROOT_LOOP_DEV" ]; then
  echo "No free loop device"
  exit 1
fi
sudo losetup -o $(( $offset * 512 )) "${ROOT_LOOP_DEV}" "${FLAGS_image}"
sudo mount "${ROOT_LOOP_DEV}" "${ROOT_FS_DIR}"

# The stateful partition should be partition 1 on the disk image.
offset=$(partoffset "${FLAGS_image}" 1)

STATEFUL_LOOP_DEV=$(sudo losetup -f)
if [ -z "$STATEFUL_LOOP_DEV" ]; then
  echo "No free loop device"
  exit 1
fi
sudo losetup -o $(( $offset * 512 )) "${STATEFUL_LOOP_DEV}" "${FLAGS_image}"
sudo mount "${STATEFUL_LOOP_DEV}" "${STATEFUL_DIR}"
sudo mount --bind "${STATEFUL_DIR}/var" "${ROOT_FS_DIR}/var"
STATEFUL_DIR="${STATEFUL_DIR}"

MOD_TEST_ROOT="${GCLIENT_ROOT}/src/scripts/mod_for_test_scripts"
# Run test setup script to modify the image
sudo GCLIENT_ROOT="${GCLIENT_ROOT}" ROOT_FS_DIR="${ROOT_FS_DIR}" \
    "${MOD_TEST_ROOT}/test_setup.sh"

if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} ]; then
  MOD_FACTORY_ROOT="${GCLIENT_ROOT}/src/scripts/mod_for_factory_scripts"
  # Run factory setup script to modify the image
  sudo GCLIENT_ROOT="${GCLIENT_ROOT}" ROOT_FS_DIR="${ROOT_FS_DIR}" \
      STATEFUL_DIR="${STATEFUL_DIR}/dev_image" QUALDB="${FLAGS_qualdb}" \
      "${MOD_FACTORY_ROOT}/factory_setup.sh"
fi

if [ ${FLAGS_factory_install} -eq ${FLAGS_TRUE} ]; then
  # Run factory setup script to modify the image.
  sudo emerge-${FLAGS_board} --root=$ROOT_FS_DIR --usepkgonly \
      --root-deps=rdeps chromeos-factoryinstall

  # Set factory server if necessary.
  if [ "${FACTORY_SERVER}" != "" ]; then 
    sudo sed -i \
      "s/CHROMEOS_AUSERVER=.*$/CHROMEOS_AUSERVER=\
http:\/\/${FACTORY_SERVER}:8080\/update/" \
      ${ROOT_FS_DIR}/etc/lsb-release
  fi
fi

cleanup
trap - EXIT

