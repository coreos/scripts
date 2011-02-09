#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a usb image.

# --- BEGIN COMMON.SH BOILERPLATE ---
# Load common CrOS utilities.  Inside the chroot this file is installed in
# /usr/lib/crosutils.  Outside the chroot we find it relative to the script's
# location.
find_common_sh() {
  local common_paths=(/usr/lib/crosutils $(dirname "$(readlink -f "$0")"))
  local path

  SCRIPT_ROOT=
  for path in "${common_paths[@]}"; do
    if [ -r "${path}/common.sh" ]; then
      SCRIPT_ROOT=${path}
      break
    fi
  done
}

find_common_sh
. "${SCRIPT_ROOT}/common.sh" || (echo "Unable to load common.sh" && exit 1)
# --- END COMMON.SH BOILERPLATE ---

# Load functions and constants for chromeos-install
[ -f /usr/lib/installer/chromeos-common.sh ] && \
  INSTALLER_ROOT=/usr/lib/installer || \
  INSTALLER_ROOT=$(dirname "$(readlink -f "$0")")

. "${INSTALLER_ROOT}/chromeos-common.sh" || \
  die "Unable to load chromeos-common.sh"

get_default_board

# Flags
DEFINE_string board "${DEFAULT_BOARD}" "Board for which the image was built"
DEFINE_string from "" \
  "Directory containing ${CHROMEOS_IMAGE_NAME}"
DEFINE_string to "/dev/sdX" "${DEFAULT_TO_HELP}"
DEFINE_boolean yes ${FLAGS_FALSE} "Answer yes to all prompts" "y"
DEFINE_boolean force_copy ${FLAGS_FALSE} "Always rebuild test image"
DEFINE_boolean force_non_usb ${FLAGS_FALSE} \
  "Write out image even if target (--to) doesn't look like a USB disk"
DEFINE_boolean factory_install ${FLAGS_FALSE} \
  "Whether to generate a factory install shim."
DEFINE_boolean factory ${FLAGS_FALSE} \
  "Whether to generate a factory runin image. Implies aututest and test"
DEFINE_boolean copy_kernel ${FLAGS_FALSE} \
  "Copy the kernel to the fourth partition."
DEFINE_boolean test_image "${FLAGS_FALSE}" \
  "Copies normal image to ${CHROMEOS_TEST_IMAGE_NAME}, modifies it for test."
DEFINE_string image_name "${CHROMEOS_IMAGE_NAME}" \
  "Base name of the image" i
DEFINE_string build_root "/build" \
  "The root location for board sysroots."
DEFINE_boolean install ${FLAGS_FALSE} "Install to the usb device."
DEFINE_string arch "" "Architecture of the image."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} ] ; then
  if [ ${FLAGS_factory_install} -eq ${FLAGS_TRUE} ] ; then
    echo "Factory test image is incompatible with factory install shim."
    exit 1
  fi
fi

# Require autotest for manucaturing image.
if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} ] ; then
  echo "Factory image requires --test_image, setting."
  FLAGS_test_image=${FLAGS_TRUE}
fi

# Require test for for factory install shim.
if [ ${FLAGS_factory_install} -eq ${FLAGS_TRUE} ] ; then
  echo "Factory install shim requires --test_image, setting."
  FLAGS_test_image=${FLAGS_TRUE}
fi


# Die on any errors.
set -e

# No board, no default and no image set then we can't find the image
if [ -z ${FLAGS_from} ] && [ -z ${FLAGS_board} ] ; then
  setup_board_warning
  exit 1
fi

# No board set during install
if [ -z "${FLAGS_board}" ] && [ ${FLAGS_install} -eq ${FLAGS_TRUE} ]; then
  setup_board_warning
  exit 1
fi

# We have a board name but no image set.  Use image at default location
if [ -z "${FLAGS_from}" ]; then
  IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"

  # Get latest image directory
  FLAGS_from="${IMAGES_DIR}/$(ls -t ${IMAGES_DIR} 2>&-| head -1)"
fi

if [ ! -d "${FLAGS_from}" ] ; then
  echo "Cannot find image directory ${FLAGS_from}"
  exit 1
fi

if [ "${FLAGS_to}" == "/dev/sdX" ]; then
  echo "You must specify a file or device to write to using --to."
  disks=$(list_usb_disks)
  if [ -n "$disks" ]; then
    echo "Available USB disks:"
    for disk in $disks; do
      echo "  /dev/$disk:"
      echo "    Manufacturer: $(get_disk_info $disk manufacturer)"
      echo "         Product: $(get_disk_info $disk product)"
      echo "            Size: $[$(cat /sys/block/$disk/size) * 512] bytes"
    done
  fi
  exit 1
fi

# Guess ARCH if it's unset
if [ "${FLAGS_arch}" = "" ]; then
  if echo "${FLAGS_board}" | grep -qs "x86"; then
    FLAGS_arch=INTEL
  else
    FLAGS_arch=ARM
  fi
fi

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f ${FOO}` won't work.
FLAGS_from=`eval readlink -f ${FLAGS_from}`
FLAGS_to=`eval readlink -f ${FLAGS_to}`

# One last check to make sure user is not shooting themselves in the foot
if [ -b "${FLAGS_to}" ]; then
  if list_usb_disks | grep -q '^'${FLAGS_to##*/}'$'; then
    disk_manufacturer=$(get_disk_info ${FLAGS_to##*/} manufacturer)
    disk_product=$(get_disk_info ${FLAGS_to##*/} product)
  elif [ ${FLAGS_force_non_usb} -ne ${FLAGS_TRUE} ]; then
    # Safeguard against writing to a real non-USB disk
    echo "Error: Device ${FLAGS_to} does not appear to be a USB disk!"
    echo "       To override this safeguard, use the --force_non_usb flag"
    exit 1
  fi
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

if [ ${FLAGS_test_image} -eq ${FLAGS_TRUE} ] ; then
  # Make a test image - this returns the test filename in CHROMEOS_RETURN_VAL
  prepare_test_image "${FLAGS_from}" "${FLAGS_image_name}"
  SRC_IMAGE="${CHROMEOS_RETURN_VAL}"
else
  # Use the standard image
  SRC_IMAGE="${FLAGS_from}/${FLAGS_image_name}"
fi

# Let's do it.
if [ -b "${FLAGS_to}" ]; then
  # Output to a block device (i.e., a real USB key), so need sudo dd
  if [ ${FLAGS_install} -ne ${FLAGS_TRUE} ]; then
    echo "Copying USB image ${SRC_IMAGE} to device ${FLAGS_to}..."
  else
    echo "Installing USB image ${SRC_IMAGE} to device ${FLAGS_to}..."
  fi

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
  if [ ${FLAGS_yes} -ne ${FLAGS_TRUE} ]; then
    sudo fdisk -l "${FLAGS_to}" 2>/dev/null | grep Disk | head -1
    [ -n "$disk_manufacturer" ] && echo "Manufacturer: $disk_manufacturer"
    [ -n "$disk_product" ] && echo "Product: $disk_product"
    echo "This will erase all data on this device:"
    read -p "Are you sure (y/N)? " SURE
    SURE="${SURE:0:1}" # Get just the first character
    if [ "${SURE}" != "y" ]; then
      echo "Ok, better safe than sorry."
      exit 1
    fi
  fi

  echo "Attempting to unmount any mounts on the USB device..."
  for i in $(mount | grep ^"${FLAGS_to}" | awk '{print $1}'); do
    if sudo umount "$i" 2>&1 >/dev/null | grep "not found"; then
      echo
      echo "The device you have specified is already mounted at some point "
      echo "that is not visible from inside the chroot.  Please unmount the "
      echo "device manually from outside the chroot and try again."
      echo
      exit 1
    fi
  done
  sleep 3

  if [ ${FLAGS_install} -ne ${FLAGS_TRUE} ]; then
    echo "Copying with dd ${SRC_IMAGE} to ${FLAGS_to}..."
    sudo ${COMMON_PV_CAT} "${SRC_IMAGE}" |
      sudo dd of="${FLAGS_to}" bs=4M oflag=sync status=noxfer
    sync
  else
    if [ ${INSIDE_CHROOT} -ne 1 ]; then
      echo "Installation must be done from inside the chroot."
      exit 1
    fi

    echo "Installing ${SRC_IMAGE} to ${FLAGS_to}..."
    "${FLAGS_build_root}/${FLAGS_board}/usr/sbin/chromeos-install" \
      --yes \
      --skip_src_removable \
      --skip_dst_removable \
      --arch="${FLAGS_arch}" \
      --payload_image="${SRC_IMAGE}" \
      --dst="${FLAGS_to}"
  fi
  echo "Done."
else
  # Output to a file, so just make a copy.
  echo "Copying ${SRC_IMAGE} to ${FLAGS_to}..."
  ${COMMON_PV_CAT} "${SRC_IMAGE}" >"${FLAGS_to}"

  echo "Done.  To copy to a USB drive, do something like:"
  echo "   sudo dd if=${FLAGS_to} of=/dev/sdX bs=4M oflag=sync"
  echo "where /dev/sdX is the entire drive."
fi
