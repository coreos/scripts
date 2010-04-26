#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a usb image.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Load functions and constants for chromeos-install
. "$(dirname "$0")/chromeos-common.sh"

get_default_board

# Flags
DEFINE_string board "${DEFAULT_BOARD}" "Board for which the image was built"
DEFINE_string from "" \
  "Directory containing chromiumos_image.bin"
DEFINE_string to "" "${DEFAULT_TO_HELP}"
DEFINE_boolean yes ${FLAGS_FALSE} "Answer yes to all prompts" "y"
DEFINE_boolean force_copy ${FLAGS_FALSE} "Always rebuild test image"
DEFINE_boolean factory ${FLAGS_FALSE} \
  "Whether to generate a factory runin image. Implies aututest and test"
DEFINE_boolean install_autotest ${FLAGS_FALSE} \
  "Whether to install autotest to the stateful partition."
DEFINE_boolean copy_kernel ${FLAGS_FALSE} \
  "Copy the kernel to the fourth partition."
DEFINE_boolean test_image "${FLAGS_FALSE}" \
  "Copies normal image to chromiumos_test_image.bin, modifies it for test."
DEFINE_string build_root "/build" \
  "The root location for board sysroots."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Require autotest for manucaturing image.
if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} ] ; then
  echo "Factory image requires --install_autotest and --test_image, setting."
  FLAGS_install_autotest=${FLAGS_TRUE}
  FLAGS_test_image=${FLAGS_TRUE}
fi

# Inside the chroot, so output to usb.img in the same dir as the other
# Script can be run either inside or outside the chroot.
if [ ${INSIDE_CHROOT} -eq 1 ]
then
  SYSROOT="${FLAGS_build_root}/${FLAGS_board}"
else
  SYSROOT="${DEFAULT_CHROOT_DIR}${FLAGS_build_root}/${FLAGS_board}"
  echo "Caching sudo authentication"
  sudo -v
  echo "Done"
fi
AUTOTEST_SRC="${SYSROOT}/usr/local/autotest"

# Die on any errors.
set -e

# No board, no default and no image set then we can't find the image
if [ -z ${FLAGS_from} ] && [ -z ${FLAGS_board} ] ; then
  setup_board_warning
  exit 1
fi

# We have a board name but no image set.  Use image at default location
if [ -z "${FLAGS_from}" ]; then
  IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
  FLAGS_from="${IMAGES_DIR}/$(ls -t ${IMAGES_DIR} 2>&-| head -1)"
fi

if [ ! -d "${FLAGS_from}" ] ; then
  echo "Cannot find image directory ${FLAGS_from}"
  exit 1
fi

if [ -z "${FLAGS_to}" ]; then
  echo "You must specify a file or device to write to using --to."
  exit 1
fi

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f ${FOO}` won't work.
FLAGS_from=`eval readlink -f ${FLAGS_from}`
FLAGS_to=`eval readlink -f ${FLAGS_to}`

# Use this image as the source image to copy
SRC_IMAGE="${FLAGS_from}/chromiumos_image.bin"

# If we're asked to modify the image for test, then let's make a copy and
# modify that instead.
if [ ${FLAGS_test_image} -eq ${FLAGS_TRUE} ] ; then
  if [ ! -f "${FLAGS_from}/chromiumos_test_image.bin" ] || \
     [ ${FLAGS_force_copy} -eq ${FLAGS_TRUE} ] ; then
    # Copy it.
    echo "Creating test image from original..."
    cp -f "${SRC_IMAGE}" "${FLAGS_from}/chromiumos_test_image.bin"

    # Check for manufacturing image.
    if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} ] ; then
      FACTORY_ARGS="--factory"
    fi

    # Modify it.  Pass --yes so that mod_image_for_test.sh won't ask us if we
    # really want to modify the image; the user gave their assent already with
    # --test-image and the original image is going to be preserved.
    "${SCRIPTS_DIR}/mod_image_for_test.sh" --image \
      "${FLAGS_from}/chromiumos_test_image.bin" ${FACTORY_ARGS} --yes
    echo "Done with mod_image_for_test."
  else
    echo "Using cached test image."
  fi
  SRC_IMAGE="${FLAGS_from}/chromiumos_test_image.bin"
  echo "Source test image is: ${SRC_IMAGE}"
fi

STATEFUL_DIR="${FLAGS_from}/stateful_partition"
mkdir -p "${STATEFUL_DIR}"

function do_cleanup {
  echo "Cleaning loopback devices: ${STATEFUL_LOOP_DEV}"
  if [ "${STATEFUL_LOOP_DEV}" != "" ]; then
    sudo umount "${STATEFUL_DIR}"
    sudo losetup -d "${STATEFUL_LOOP_DEV}"
    rmdir "${STATEFUL_DIR}"
    echo "Cleaned"
  fi
}

if [ ${FLAGS_install_autotest} -eq ${FLAGS_TRUE} ] ; then
  echo "Detecting autotest at ${AUTOTEST_SRC}"
  if [ -d ${AUTOTEST_SRC} ]
  then
    # Figure out how to loop mount the stateful partition. It's always
    # partition 1 on the disk image.
    offset=$(partoffset "${SRC_IMAGE}" 1)

    stateful_loop_dev=$(sudo losetup -f)
    if [ -z "${stateful_loop_dev}" ]
    then
      echo "No free loop device. Free up a loop device or reboot. exiting."
      exit 1
    fi
    STATEFUL_LOOP_DEV=$stateful_loop_dev
    trap do_cleanup INT TERM EXIT

    echo "Mounting ${STATEFUL_DIR} loopback"
    sudo losetup -o $(( $offset * 512 )) "${stateful_loop_dev}" "${SRC_IMAGE}"
    sudo mount "${stateful_loop_dev}" "${STATEFUL_DIR}"
    stateful_root="${STATEFUL_DIR}/dev_image"

    echo "Install autotest into stateful partition..."
    autotest_client="/home/autotest-client"
    sudo mkdir -p "${stateful_root}${autotest_client}"
    sudo ln -sf /mnt/stateful_partition/dev_image${autotest_client} \
      ${stateful_root}/autotest

    sudo cp -fpru ${AUTOTEST_SRC}/client/* \
      "${stateful_root}/${autotest_client}"
    sudo chmod 755 "${stateful_root}/${autotest_client}"
    sudo chown -R 1000:1000 "${stateful_root}/${autotest_client}"

    sudo umount ${STATEFUL_DIR}
    sudo losetup -d "${stateful_loop_dev}"
    trap - INT TERM EXIT
    rmdir "${STATEFUL_DIR}"
  else
    echo "/usr/local/autotest under ${DEFAULT_CHROOT_DIR} is not installed."
    echo "Please call build_autotest.sh inside chroot first."
    exit -1
  fi
fi


# Let's do it.
if [ -b "${FLAGS_to}" ]
then
  # Output to a block device (i.e., a real USB key), so need sudo dd
  echo "Copying USB image ${SRC_IMAGE} to device ${FLAGS_to}..."

  # Warn if it looks like they supplied a partition as the destination.
  if echo "${FLAGS_to}" | grep -q '[0-9]$'; then
    drive=$(echo "${FLAGS_to}" | sed -re 's/[0-9]+$//')
    if [ -b "${drive}" ]; then
      echo
      echo "NOTE: It looks like you may have supplied a partition as the "
      echo "destination.  This script needs to write to the drive's device "
      echo "node instead (i.e. ${drive} rather than ${FLAGS_to})."
      echo
    fi
  fi

  # Make sure this is really what the user wants, before nuking the device
  if [ ${FLAGS_yes} -ne ${FLAGS_TRUE} ]
  then
    sudo fdisk -l "${FLAGS_to}" 2>/dev/null | grep Disk | head -1
    echo "This will erase all data on this device:"
    read -p "Are you sure (y/N)? " SURE
    SURE="${SURE:0:1}" # Get just the first character
    if [ "${SURE}" != "y" ]
    then
      echo "Ok, better safe than sorry."
      exit 1
    fi
  fi

  echo "Attempting to unmount any mounts on the USB device..."
  for i in $(mount | grep ^"${FLAGS_to}" | awk '{print $1}')
  do
    sudo umount "$i"
  done
  sleep 3

  echo "Copying ${SRC_IMAGE} to ${FLAGS_to}..."
  sudo dd if="${SRC_IMAGE}" of="${FLAGS_to}" bs=4M

  echo "Done."
else
  # Output to a file, so just make a copy.
  echo "Copying ${SRC_IMAGE} to ${FLAGS_to}..."
  cp -f "${SRC_IMAGE}" "${FLAGS_to}"

  echo "Done.  To copy to a USB drive, outside the chroot, do something like:"
  echo "   sudo dd if=${FLAGS_to} of=/dev/sdX bs=4M"
  echo "where /dev/sdX is the entire drive."
  if [ ${INSIDE_CHROOT} -eq 1 ]
  then
    example=$(basename "${FLAGS_to}")
    echo "NOTE: Since you are currently inside the chroot, and you'll need to"
    echo "run dd outside the chroot, the path to the USB image will be"
    echo "different (ex: ~/chromeos/trunk/src/build/images/SOME_DIR/$example)."
  fi
fi
