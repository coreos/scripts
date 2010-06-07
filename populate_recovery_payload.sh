#!/bin/bash
#
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to populate payload (partition B) of a Chrome OS recovery installer
# See install_gpt() in chromeos-common.sh for partition size details.
# Currently, rootfs is set to 1GB and kernel is set to 16MB.
# As long as the payload is large enough, we'll copy from src_image to
# dst_image, without ANY version checking.

# Need this script to get default board
. "$(dirname "$0")/common.sh"

# Need this script for functions related to gpt images.
. "$(dirname "$0")/chromeos-common.sh"

# We need to be in the chroot to use "gpt" command
assert_inside_chroot

get_default_board

DEFINE_string board "$DEFAULT_BOARD" \
  "The board to build an image for." b
DEFINE_string src_image "" \
  "Path to a pristine image to be written to a recovery image." s
DEFINE_string dst_image "" \
  "Path to a recovery image." d
DEFINE_boolean yes $FLAGS_FALSE "Answer yes to all prompts. Default: False" y

SCRIPT_NAME="populate_recovery_payload"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Make sure board is set
if [ -z $FLAGS_board ] ; then
  setup_board_warning
  die "${SCRIPT_NAME} failed. No board set"
fi

# Make sure image path is set
if [ -z $FLAGS_src_image ] ; then
  die "${SCRIPT_NAME} failed. No --src_image set"
fi

if [ -z $FLAGS_dst_image ] ; then
  die "${SCRIPT_NAME} failed. No --dst_image set"
fi

# Turn path into an absolute path.
FLAGS_src_image=`eval readlink -f ${FLAGS_src_image}`

# Abort early if we can't find the image
if [ ! -f $FLAGS_src_image ] ; then
  die "${SCRIPT_NAME} failed. No image found at $FLAGS_src_image"
fi

FLAGS_dst_image=`eval readlink -f ${FLAGS_dst_image}`
if [ ! -f $FLAGS_dst_image ] ; then
  die "${SCRIPT_NAME} failed. No image found at $FLAGS_dst_image"
fi

# Look up partition number
function get_part_num() {
  local image_type=$1
  local part_type=$2
  local part_num=

  case "${image_type}" in
    "src" )
    case "${part_type}" in
      "rootfs" ) part_num=3;;
      "kern" ) part_num=2;;
    esac
    ;;
    "dst" )
    case "${part_type}" in
      "rootfs" ) part_num=5;;
      "kern" ) part_num=4;;
    esac
    ;;
  esac

  echo "${part_num}"
}

# main process begins here.

# Confirm user wants to (re-)populate payload partition
if [ $FLAGS_yes -ne $FLAGS_TRUE ]; then
  read -p "Overwriting payload partition of recovery image ${FLAGS_dst_image}; \
are you sure (y/N)? " SURE
  SURE="${SURE:0:1}" # Get just the first character
  if [ "$SURE" != "y" ]; then
    echo "Ok, better safe than sorry. Abort."
    exit 1
  fi
fi
echo "About to overwrite payload partition..."

set -e

# Look up partition size and offset for rootfs, kernel on both images.
# Assume 512-byte sector/block size
SRC_ROOTFS_PART=$(get_part_num "src" "rootfs")
SRC_ROOTFS_OFFSET=$(partoffset "${FLAGS_src_image}" ${SRC_ROOTFS_PART})
SRC_ROOTFS_SECTORS=$(partsize "${FLAGS_src_image}" ${SRC_ROOTFS_PART})

DST_ROOTFS_PART=$(get_part_num "dst" "rootfs")
DST_ROOTFS_OFFSET=$(partoffset "${FLAGS_dst_image}" ${DST_ROOTFS_PART})
DST_ROOTFS_SECTORS=$(partsize "${FLAGS_dst_image}" ${DST_ROOTFS_PART})

# Verify source partition is not larger than destination partition
if [ $SRC_ROOTFS_SECTORS -gt $DST_ROOTFS_SECTORS ]; then
  echo "Rootfs partition is too large to be copied to payload. Source has \
${SRC_ROOTFS_SECTORS} sectors while destination only has \
${DST_ROOTFS_SECTORS} sectors. Abort."
  exit 1
fi

SRC_KERN_PART=$(get_part_num "src" "kern")
SRC_KERN_OFFSET=$(partoffset "${FLAGS_src_image}" ${SRC_KERN_PART})
SRC_KERN_SECTORS=$(partsize "${FLAGS_src_image}" ${SRC_KERN_PART})

DST_KERN_PART=$(get_part_num "dst" "kern")
DST_KERN_OFFSET=$(partoffset "${FLAGS_dst_image}" ${DST_KERN_PART})
DST_KERN_SECTORS=$(partsize "${FLAGS_dst_image}" ${DST_KERN_PART})

if [ $SRC_KERN_SECTORS -gt $DST_KERN_SECTORS ]; then
  echo "Kernel partition is too large to be copied to payload. Source has \
${SRC_KERN_SECTORS} sectors while destination only has \
${DST_KERN_SECTORS} sectors. Abort."
  exit 1
fi

# Check if we can use 2MB for faster write
SECTOR_SIZE=512  # default sector size in bytes
IDEAL_BLOCK_SIZE=$((2 * 1024 * 1024))  # large sector size in bytes
ROOTFS_BS=$SECTOR_SIZE
ROOTFS_COUNT=$SRC_ROOTFS_SECTORS  # number of SECTOR_SIZE sectors
ROOTFS_SKIP=$SRC_ROOTFS_OFFSET    # number of SECTOR_SIZE sectors
ROOTFS_SEEK=$DST_ROOTFS_OFFSET    # number of SECTOR_SIZE sectors
if [ $(( $SRC_ROOTFS_OFFSET % ($IDEAL_BLOCK_SIZE / $SECTOR_SIZE) )) = "0" ] && \
   [ $(( $SRC_ROOTFS_SECTORS % ($IDEAL_BLOCK_SIZE / $SECTOR_SIZE) )) = "0" ] \
   && \
   [ $(( $DST_ROOTFS_OFFSET % ($IDEAL_BLOCK_SIZE / $SECTOR_SIZE) )) = "0" ] && \
   [ $(( $DST_ROOTFS_SECTORS % ($IDEAL_BLOCK_SIZE / $SECTOR_SIZE) )) = "0" ]; \
   then
  ROOTFS_BS=$IDEAL_BLOCK_SIZE  # increase sector size to 2MB
  # Update number of sectors
  ROOTFS_COUNT=$(( ($SRC_ROOTFS_SECTORS * $SECTOR_SIZE) / $IDEAL_BLOCK_SIZE ))
  ROOTFS_SKIP=$(( ($SRC_ROOTFS_OFFSET * $SECTOR_SIZE) / $IDEAL_BLOCK_SIZE ))
  ROOTFS_SEEK=$(( ($DST_ROOTFS_OFFSET * $SECTOR_SIZE) / $IDEAL_BLOCK_SIZE ))
  echo "Use 2MB for rootfs block size"
fi

KERN_BS=$SECTOR_SIZE
KERN_COUNT=$SRC_KERN_SECTORS  # number of SECTOR_SIZE sectors
KERN_SKIP=$SRC_KERN_OFFSET    # number of SECTOR_SIZE sectors
KERN_SEEK=$DST_KERN_OFFSET    # number of SECTOR_SIZE sectors
if [ $(( $SRC_KERN_OFFSET % ($IDEAL_BLOCK_SIZE / $SECTOR_SIZE) )) = "0" ] && \
   [ $(( $SRC_KERN_SECTORS % ($IDEAL_BLOCK_SIZE / $SECTOR_SIZE) )) = "0" ] && \
   [ $(( $DST_KERN_OFFSET % ($IDEAL_BLOCK_SIZE / $SECTOR_SIZE) )) = "0" ] && \
   [ $(( $DST_KERN_SECTORS % ($IDEAL_BLOCK_SIZE / $SECTOR_SIZE) )) = "0" ]; \
   then
  KERN_BS=$IDEAL_BLOCK_SIZE
  KERN_COUNT=$(( ($SRC_KERN_SECTORS * $SECTOR_SIZE) / $IDEAL_BLOCK_SIZE ))
  KERN_SKIP=$(( ($SRC_KERN_OFFSET * $SECTOR_SIZE) / $IDEAL_BLOCK_SIZE ))
  KERN_SEEK=$(( ($DST_KERN_OFFSET * $SECTOR_SIZE) / $IDEAL_BLOCK_SIZE ))
  echo "Use 2MB for kernel block size"
fi

# Copy new partitions to dst_image
echo "Copying rootfs partition to payload ..."
sudo dd if=$FLAGS_src_image of=$FLAGS_dst_image conv=notrunc bs=$ROOTFS_BS \
  skip=$ROOTFS_SKIP seek=$ROOTFS_SEEK count=$ROOTFS_COUNT

echo "Copying kernel partition to payload ..."
sudo dd if=$FLAGS_src_image of=$FLAGS_dst_image conv=notrunc bs=$KERN_BS \
  skip=$KERN_SKIP seek=$KERN_SEEK count=$KERN_COUNT

echo "New partitions copied to payload. Done."
exit 0
