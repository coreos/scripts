#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script modifies a base image to act as a recovery installer.
# If a developer payload is supplied, it will be used.
# It is very straight forward, top to bottom to show clearly what is
# little is needed to create a developer shim to run a signed script.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Load functions and constants for chromeos-install
. "$(dirname "$0")/chromeos-common.sh"

DEFINE_integer statefulfs_size 2 \
  "Number of mebibytes to use for the stateful filesystem"
DEFINE_string developer_private_key \
    "/usr/share/vboot/devkeys/kernel_data_key.vbprivk" \
    "Path to the developer's private key"
DEFINE_string developer_keyblock \
    "/usr/share/vboot/devkeys/kernel.keyblock" \
    "Path to the developer's keyblock"
DEFINE_string developer_script "" \
    "Path to the developer script if desired."
# TODO(wad) wire up support for just swapping a pre-made kernel
# Skips the build steps and just does the kernel swap.
DEFINE_string kernel_image "" \
    "Path to a pre-built recovery kernel"
DEFINE_boolean verbose $FLAGS_FALSE \
     "Emits stderr too" v
DEFINE_string image "dev_runner_image.bin" \
    "Path to output image to"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

if [ $FLAGS_verbose -eq $FLAGS_FALSE ]; then
  exec 2>/dev/null
fi
set -x  # Make debugging with -v easy.

if [ -z "$FLAGS_kernel_image" ]; then
  die "--kernel_image with a recovery kernel is needed"
fi

if [ -z "$FLAGS_developer_script" ]; then
  die "--developer_script must be supplied."
fi

locate_gpt

set -eu

header_offset=34
stateful_sectors=$(((FLAGS_statefulfs_size * 1024 * 1024) / 512))
stateful_sectors=$(roundup $stateful_sectors)

if [ -b "$FLAGS_image" ]; then
  sudo=sudo
else
  max_kern_size=32768
  dd if=/dev/zero of="${FLAGS_image}" bs=512 count=0 \
     seek=$((1 + max_kern_size + header_offset + stateful_sectors))
  sudo=""
fi

## STATEFUL

stateful_image=$(mktemp)
trap "rm $stateful_image" EXIT

dd if=/dev/zero of="$stateful_image" bs=512 \
    seek=$stateful_sectors count=0
/sbin/mkfs.ext3 -F -b 4096 $stateful_image 1>&2

stateful_mnt=$(mktemp -d)
sudo mount -o loop $stateful_image "$stateful_mnt" || exit 1
userdir="$stateful_mnt/userdir"
userfile="$userdir/runme"
sudo mkdir -p "$userdir"
sudo cp "$FLAGS_developer_script" "$userfile"
sudo chmod +x "$userfile"
sudo dev_sign_file --sign "$userfile" \
                   --keyblock "$FLAGS_developer_keyblock" \
                   --signprivate "$FLAGS_developer_private_key" \
                   --vblock "${userfile}.vblock"
sudo umount -d "$stateful_mnt"
rmdir "$stateful_mnt"

## GPT

kernel_bytes=$(stat -c '%s' $FLAGS_kernel_image)
kernel_sectors=$((kernel_bytes / 512))
kernel_sectors=$(roundup $kernel_sectors)

$sudo $GPT create $FLAGS_image
trap "rm $FLAGS_image" ERR

offset=$header_offset
$sudo $GPT add -b $offset -s $stateful_sectors \
               -t data -l "STATE" $FLAGS_image
$sudo dd if=$stateful_image of=$FLAGS_image bs=512 conv=notrunc \
         seek=$offset count=$stateful_sectors

offset=$((offset + stateful_sectors))
$sudo $GPT add -b $offset -s $kernel_sectors \
               -t kernel -l "KERN-A" -S 0 -T 15 -P 15 $FLAGS_image
$sudo dd if=$FLAGS_kernel_image of=$FLAGS_image bs=512 conv=notrunc \
         seek=$offset count=$kernel_sectors
# The kernel will ignore GPT without a legacymbr.
PMBRCODE=$(readlink -f /usr/share/syslinux/gptmbr.bin)
# Have it legacy boot off of stateful, not that it should matter.
$sudo $GPT boot -p -b "$PMBRCODE" -i 1 $FLAGS_image 1>&2

$sudo $GPT show $FLAGS_image

echo "Done."
