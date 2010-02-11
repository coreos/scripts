#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a usb image.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"


# Flags
DEFINE_string board "" "Board for which the image was built"
DEFINE_string from "" \
  "Directory containing rootfs.image and mbr.image"
DEFINE_string to "" "$DEFAULT_TO_HELP"
DEFINE_boolean yes $FLAGS_FALSE "Answer yes to all prompts" "y"
DEFINE_boolean install_autotest $FLAGS_FALSE \
  "Whether to install autotest to the stateful partition."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Inside the chroot, so output to usb.img in the same dir as the other
# Script can be run either inside or outside the chroot.
if [ $INSIDE_CHROOT -eq 1 ]
then
  AUTOTEST_SRC="/usr/local/autotest/${FLAGS_board}"
else
  AUTOTEST_SRC="${DEFAULT_CHROOT_DIR}/usr/local/autotest/${FLAGS_board}"
fi

# Die on any errors.
set -e

# If from isn't explicitly set
if [ -z "$FLAGS_from" ]; then
  IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
  FLAGS_from="${IMAGES_DIR}/$(ls -t $IMAGES_DIR 2>&-| head -1)"
fi

# If to isn't explicitly set
if [ -z "$FLAGS_to" ]; then
  # Script can be run either inside or outside the chroot.
  if [ $INSIDE_CHROOT -eq 1 ]
  then
    # Inside the chroot, so output to usb.img in the same dir as the other
    # images.
    FLAGS_to="${FLAGS_from}/usb.img"
  else
    # Outside the chroot, so output to the default device for a usb key.
    FLAGS_to="/dev/sdb"
  fi
fi

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f $FOO` won't work.
FLAGS_from=`eval readlink -f $FLAGS_from`
FLAGS_to=`eval readlink -f $FLAGS_to`

function do_cleanup {
  sudo losetup -d "$LOOP_DEV"
}

STATEFUL_DIR=${FLAGS_from}/stateful_partition
mkdir -p "${STATEFUL_DIR}"

function install_autotest {
  if [ -d ${AUTOTEST_SRC} ]
  then
    echo -ne "Install autotest into stateful partition..."
	  local autotest_client="/home/autotest-client"
    sudo mkdir -p "${STATEFUL_DIR}${autotest_client}"
    sudo cp -fpru ${AUTOTEST_SRC}/client/* \
	    "${STATEFUL_DIR}${autotest_client}"
    sudo chmod 755 "${STATEFUL_DIR}${autotest_client}"
    sudo chown -R 1000:1000 "${STATEFUL_DIR}${autotest_client}"
    echo "Done."
    sudo umount "${STATEFUL_DIR}"
  else
    echo "/usr/local/autotest under ${DEFAULT_CHROOT_DIR} is not installed."
    echo "Please call make_autotest.sh inside chroot first."
    sudo umount "${STATEFUL_DIR}"
    exit -1
  fi
}

# Copy MBR and rootfs to output image
if [ -b "$FLAGS_to" ]
then
  # Output to a block device (i.e., a real USB key), so need sudo dd
  echo "Copying USB image ${FLAGS_from} to device ${FLAGS_to}..."

  # Warn if it looks like they supplied a partition as the destination.
  if echo $FLAGS_to | grep -q '[0-9]$'; then
    drive=$(echo $FLAGS_to | sed -re 's/[0-9]+$//')
    if [ -b "$drive" ]; then
      echo
      echo "NOTE: It looks like you may have supplied a partition as the "
      echo "destination.  This script needs to write to the drive's device "
      echo "node instead (i.e. ${drive} rather than ${FLAGS_to})."
      echo
    fi
  fi

  # Make sure this is really what the user wants, before nuking the device
  if [ $FLAGS_yes -ne $FLAGS_TRUE ]
  then
    echo "This will erase all data on this device:"
    sudo fdisk -l "$FLAGS_to" | grep Disk | head -1
    read -p "Are you sure (y/N)? " SURE
    SURE="${SURE:0:1}" # Get just the first character
    if [ "$SURE" != "y" ]
    then
      echo "Ok, better safe than sorry."
      exit 1
    fi
  fi

  echo "attempting to unmount any mounts on the USB device"
  for i in "$FLAGS_to"*
  do
    ! sudo umount "$i"
  done
  sleep 3

  PART_SIZE=$(stat -c%s "${FLAGS_from}/rootfs.image")  # Bytes

  echo "Copying root fs..."
  sudo "${SCRIPTS_DIR}"/file_copy.py \
    if="${FLAGS_from}/rootfs.image" \
    of="$FLAGS_to" bs=4M \
    seek_bytes=$(( ($PART_SIZE * 2) + 512 ))

  # Set up loop device
  LOOP_DEV=$(sudo losetup -f)
  if [ -z "$LOOP_DEV" ]
  then
    echo "No free loop device. Free up a loop device or reboot. exiting."
    exit 1
  fi

  trap do_cleanup EXIT

  echo "Creating stateful partition..."
  sudo losetup -o 512 "$LOOP_DEV" "$FLAGS_to"
  sudo mkfs.ext3 -F -b 4096 -L C-STATE "$LOOP_DEV" $(( $PART_SIZE / 4096 ))
  if [ $FLAGS_install_autotest -eq $FLAGS_TRUE ]
  then
    sudo mount "${LOOP_DEV}" "${STATEFUL_DIR}"
    install_autotest
  fi
  sync
  sudo losetup -d "$LOOP_DEV"
  sync

  trap - EXIT

  echo "Copying MBR..."
  sudo "${SCRIPTS_DIR}"/file_copy.py \
    if="${FLAGS_from}/mbr.image" of="$FLAGS_to"
  sync
  echo "Done."
else
  # Output to a file, so just cat the source images together

  PART_SIZE=$(stat -c%s "${FLAGS_from}/rootfs.image")

  echo "Creating empty stateful partition"
  dd if=/dev/zero of="${FLAGS_from}/stateful_partition.image" bs=1 count=1 \
      seek=$(($PART_SIZE - 1))
  mkfs.ext3 -F -L C-STATE "${FLAGS_from}/stateful_partition.image"

  if [ $FLAGS_install_autotest -eq $FLAGS_TRUE ]
  then
    sudo mount -o loop "${FLAGS_from}/stateful_partition.image" \
      "${STATEFUL_DIR}"
    install_autotest
  fi

  # Create a sparse output file
  dd if=/dev/zero of="${FLAGS_to}" bs=1 count=1 \
      seek=$(( ($PART_SIZE * 2) + 512 - 1))

  echo "Copying USB image to file ${FLAGS_to}..."

  dd if="${FLAGS_from}/mbr.image" of="$FLAGS_to" conv=notrunc
  dd if="${FLAGS_from}/stateful_partition.image" of="$FLAGS_to" seek=1 bs=512 \
      conv=notrunc
  cat "${FLAGS_from}/rootfs.image" >> "$FLAGS_to"

  echo "Done.  To copy to USB keyfob, outside the chroot, do something like:"
  echo "   sudo dd if=${FLAGS_to} of=/dev/sdb bs=4M"
  echo "where /dev/sdb is the entire keyfob."
  if [ $INSIDE_CHROOT -eq 1 ]
  then
    echo "NOTE: Since you are currently inside the chroot, and you'll need to"
    echo "run dd outside the chroot, the path to the USB image will be"
    echo "different (ex: ~/chromeos/trunk/src/build/images/SOME_DIR/usb.img)."
  fi
fi
