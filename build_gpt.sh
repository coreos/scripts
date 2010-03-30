#!/bin/bash
#
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Load functions and constants for chromeos-install
. "$(dirname "$0")/chromeos-common.sh"

# Script must be run inside the chroot.
assert_inside_chroot

get_default_board

# Flags.
DEFINE_string arch "" \
  "The target architecture (\"arm\" or \"x86\")."
DEFINE_string board "$DEFAULT_BOARD" \
  "The board to build an image for."
DEFINE_string board_root "" \
  "The build directory, needed to find tools for ARM."

# Usage.
FLAGS_HELP=$(cat <<EOF
 
Usage: $(basename $0) [flags] IMAGEDIR OUTDEV

This takes the image components in IMAGEDIR and creates a bootable,
GPT-formatted image in OUTDEV. OUTDEV can be a file or block device.
 
EOF
)

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

if [[ -z "$FLAGS_board" ]] ; then
  error "--board is required."
  exit 1
fi

if [[ -z "$1" || -z "$2" ]] ; then
  flags_help
  exit 1
fi
IMAGEDIR="$1"
OUTDEV="$2"

if [[ -n "$FLAGS_arch" ]]; then
  ARCH=${FLAGS_arch}
else
  # Figure out ARCH from the given toolchain.
  # TODO: Move to common.sh as a function after scripts are switched over.
  TC_ARCH=$(echo "$CHOST" | awk -F'-' '{ print $1 }')
  case "$TC_ARCH" in
    arm*)
      ARCH="arm"
      ;;
    *86)
      ARCH="x86"
      ;;
    *)
      error "Unable to determine ARCH from toolchain: $CHOST"
      exit 1
  esac
fi

if [[ -z "$FLAGS_board_root" ]]; then
  FLAGS_board_root="/build/${FLAGS_board}"
fi

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'set -e' is specified before now.
set -e
# Die on uninitialized variables.
set -u

# Check for missing parts.
ROOTFS_IMG="${IMAGEDIR}/rootfs.image"
if [[ ! -s ${ROOTFS_IMG} ]]; then
  error "Can't find ${ROOTFS_IMG}"
  exit 1
fi

KERNEL_IMG="${IMAGEDIR}/vmlinuz.image"
if [[ ! -s ${KERNEL_IMG} ]]; then
  error "Can't find ${KERNEL_IMG}"
  exit 1
fi

STATEFUL_IMG="${IMAGEDIR}/stateful_partition.image"
if [[ ! -s ${STATEFUL_IMG} ]]; then
  error "Can't find ${STATEFUL_IMG}"
  exit 1
fi

# We'll need some code to put in the PMBR, for booting on legacy BIOS. Some ARM
# systems will use a U-Boot script temporarily, but it goes in the same place.
if [[ "$ARCH" = "arm" ]]; then
  # U-Boot script copies the kernel into memory, then boots it.
  KERNEL_OFFSET=$(printf "0x%08x" ${START_KERN_A})
  KERNEL_SECS_HEX=$(printf "0x%08x" ${NUM_KERN_BLOCKS})
  MBR_SCRIPT="${IMAGEDIR}/mbr_script"
  echo -e "echo\necho ---- ChromeOS Boot ----\necho\n" \
          "mmc read 1 C0008000 $KERNEL_OFFSET $KERNEL_SECS_HEX\n" \
          "bootm C0008000" > ${MBR_SCRIPT}
  MKIMAGE="${FLAGS_board_root}/u-boot/mkimage"
  if [[ -f "$MKIMAGE".gz ]]; then
    sudo gunzip "$MKIMAGE".gz
  fi
  if [[ -x "$MKIMAGE" ]]; then
    MBR_SCRIPT_UIMG="${MBR_SCRIPT}.uimg"
    "$MKIMAGE" -A "${ARCH}" -O linux  -T script -a 0 -e 0 -n "COS boot" \
               -d ${MBR_SCRIPT} ${MBR_SCRIPT_UIMG}
    MBR_IMG=${IMAGEDIR}/mbr.img
    dd bs=1 count=`stat --printf="%s" ${MBR_SCRIPT_UIMG}` \
       if="$MBR_SCRIPT_UIMG" of="$MBR_IMG" conv=notrunc
    hexdump -v -C "$MBR_IMG"
  else
    echo "Error: u-boot mkimage not found or not executable."
  fi
  PMBRCODE=${MBR_IMG}
else
  PMBRCODE=$(readlink -f /usr/share/syslinux/gptmbr.bin)
fi

# Create the GPT. This has the side-effect of setting some global vars
# describing the partition table entries (see the comments in the source).
install_gpt $OUTDEV $ROOTFS_IMG $KERNEL_IMG $STATEFUL_IMG $PMBRCODE

# Now populate the partitions.
echo "Copying stateful partition..."
dd if=${STATEFUL_IMG} of=${OUTDEV} conv=notrunc bs=512 seek=${START_STATEFUL}

echo "Copying kernel..."
dd if=${KERNEL_IMG} of=${OUTDEV} conv=notrunc bs=512 seek=${START_KERN_A}
  
echo "Copying rootfs..."
dd if=${ROOTFS_IMG} of=${OUTDEV} conv=notrunc bs=512 seek=${START_ROOTFS_A}

