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
restart_in_chroot_if_needed $*

get_default_board

# Flags.
DEFINE_string arch "" \
  "The target architecture (\"arm\" or \"x86\")."
DEFINE_string board "$DEFAULT_BOARD" \
  "The board to build an image for."
DEFINE_string arm_extra_bootargs "" \
  "Additional command line options to pass to the ARM kernel."
DEFINE_integer rootfs_partition_size 1024 \
  "rootfs parition size in MBs."

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
if [ ! -s ${STATEFUL_IMG} ]; then
  error "Can't find ${STATEFUL_IMG}"
  exit 1
fi

OEM_IMG="${IMAGEDIR}/partner_partition.image"
if [[ ! -s ${OEM_IMG} ]]; then
  error "Can't find ${OEM_IMG}"
  exit 1
fi

ESP_IMG="${IMAGEDIR}/esp.image"
if [ ! -s ${ESP_IMG} ]; then
  error "Can't find ${ESP_IMG}"
  exit 1
fi

# We'll need some code to put in the PMBR, for booting on legacy BIOS. Some ARM
# systems will use a U-Boot script temporarily, but it goes in the same place.
if [[ "$ARCH" = "arm" ]]; then
  PMBRCODE=/dev/zero
else
  PMBRCODE=$(readlink -f /usr/share/syslinux/gptmbr.bin)
fi

# Create the GPT. This has the side-effect of setting some global vars
# describing the partition table entries (see the comments in the source).
install_gpt $OUTDEV $(numsectors $ROOTFS_IMG) $(numsectors $STATEFUL_IMG) \
    $PMBRCODE $(numsectors $ESP_IMG) false $FLAGS_rootfs_partition_size

if [[ "$ARCH" = "arm" ]]; then
  # assume /dev/mmcblk1. we could not get this from ${OUTDEV}
  DEVICE=1
  MBR_SCRIPT_UIMG=$(make_arm_mbr \
    ${START_KERN_A} \
    ${NUM_KERN_SECTORS} \
    ${DEVICE} \
    "${FLAGS_arm_extra_bootargs}")
  sudo dd bs=1 count=`stat --printf="%s" ${MBR_SCRIPT_UIMG}` \
     if="$MBR_SCRIPT_UIMG" of=${OUTDEV} conv=notrunc
fi

# Emit helpful scripts for testers, etc.
${SCRIPTS_DIR}/emit_gpt_scripts.sh "${OUTDEV}" "${IMAGEDIR}"

sudo=
if [ ! -w "$OUTDEV" ] ; then
  # use sudo when writing to a block device.
  sudo=sudo
fi

# Now populate the partitions.
echo "Copying stateful partition..."
$sudo dd if=${STATEFUL_IMG} of=${OUTDEV} conv=notrunc bs=512 \
    seek=${START_STATEFUL}

echo "Copying OEM partition..."
$sudo dd if=${OEM_IMG} of=${OUTDEV} conv=notrunc bs=512 seek=${START_OEM}

echo "Copying kernel..."
$sudo dd if=${KERNEL_IMG} of=${OUTDEV} conv=notrunc bs=512 seek=${START_KERN_A}

echo "Copying rootfs..."
$sudo dd if=${ROOTFS_IMG} of=${OUTDEV} conv=notrunc bs=512 \
    seek=${START_ROOTFS_A}

echo "Copying EFI system partition..."
$sudo dd if=${ESP_IMG} of=${OUTDEV} conv=notrunc bs=512 seek=${START_ESP}

# Clean up temporary files.
if [[ -n "${MBR_IMG:-}" ]]; then
  rm "${MBR_IMG}"
fi
