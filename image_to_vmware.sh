#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a VMware image and write a
# corresponding VMware config file.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/chromeos-common.sh"

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images"
# Default to the most recent image
DEFAULT_FROM="${IMAGES_DIR}/`ls -t $IMAGES_DIR | head -1`"
DEFAULT_TO="${DEFAULT_FROM}"
DEFAULT_VMDK="ide.vmdk"
DEFAULT_VMX="chromeos.vmx"
DEFAULT_VBOX_DISK="os.vdi"
# Memory units are in MBs
DEFAULT_MEM="1024"
VBOX_TEMP_IMAGE="${IMAGES_DIR}/vbox_temp.img"


# Flags
DEFINE_string from "$DEFAULT_FROM" \
  "Directory containing rootfs.image and mbr.image"
DEFINE_string to "$DEFAULT_TO" \
  "Destination folder for VM output file(s)"
DEFINE_string state_image "" \
  "Stateful partition image (defaults to creating new statful partition)"
DEFINE_string format "vmware" \
  "Output format, either vmware or virtualbox"

DEFINE_boolean make_vmx ${FLAGS_TRUE} \
  "Create a vmx file for use with vmplayer (vmware only)."
DEFINE_string vmdk "$DEFAULT_VMDK" \
  "Filename for the vmware disk image (vmware only)."
DEFINE_string vmx "$DEFAULT_VMX" \
  "Filename for the vmware config (vmware only)."
DEFINE_integer mem "$DEFAULT_MEM" \
  "Memory size for the vm config in MBs (vmware only)."

DEFINE_string vbox_disk "$DEFAULT_VBOX_DISK" \
  "Filename for the output disk (virtualbox only)."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

if [ "$FLAGS_format" != "vmware" ]; then
  FLAGS_make_vmx=${FLAGS_FALSE}
fi

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f $FOO` won't work.
FLAGS_from=`eval readlink -f $FLAGS_from`
FLAGS_to=`eval readlink -f $FLAGS_to`

# Split apart the partitions and make some new ones
TEMP_DIR=$(mktemp -d)
(cd "$TEMP_DIR" &&
  "${FLAGS_from}/unpack_partitions.sh" "${FLAGS_from}/chromiumos_image.bin")

# Fix the kernel command line
# FIXME: TEMP_ESP is only partition 4 at the moment. It may change!
TEMP_ESP="$TEMP_DIR"/part_4
TEMP_ROOTFS="$TEMP_DIR"/part_3
TEMP_STATE="$TEMP_DIR"/part_1
if [ -n "${FLAGS_state_image}" ]; then
  TEMP_STATE="${FLAGS_state_image}"
fi
TEMP_KERN="$TEMP_DIR"/part_2
TEMP_PMBR="$TEMP_DIR"/pmbr
dd if="${FLAGS_from}/chromiumos_image.bin" of="$TEMP_PMBR" bs=512 count=1

TEMP_MNT=$(mktemp -d)
cleanup() {
  sudo umount -d "$TEMP_MNT"
  rmdir "$TEMP_MNT"
}
trap cleanup INT TERM EXIT
mkdir -p "$TEMP_MNT"
sudo mount -o loop "$TEMP_ROOTFS" "$TEMP_MNT"
sudo "$TEMP_MNT"/postinst /dev/sda3
trap - INT TERM EXIT
cleanup

# Make 3 GiB output image
TEMP_IMG=$(mktemp)
# TOOD(adlr): pick a size that will for sure accomodate the partitions
sudo dd if=/dev/zero of="${TEMP_IMG}" bs=1 count=1 \
  seek=$((3 * 1024 * 1024 * 1024 - 1))

# Set up the partition table
install_gpt "$TEMP_IMG" "$TEMP_ROOTFS" "$TEMP_KERN" "$TEMP_STATE" \
  "$TEMP_PMBR" "$TEMP_ESP" true
# Copy into the partition parts of the file
dd if="$TEMP_ROOTFS" of="$TEMP_IMG" conv=notrunc bs=512 seek="$START_ROOTFS_A"
dd if="$TEMP_STATE"  of="$TEMP_IMG" conv=notrunc bs=512 seek="$START_STATEFUL"
dd if="$TEMP_KERN"   of="$TEMP_IMG" conv=notrunc bs=512 seek="$START_KERN_A"
dd if="$TEMP_ESP"    of="$TEMP_IMG" conv=notrunc bs=512 seek="$START_ESP"

echo Creating final image
# Convert image to output format
if [ "$FLAGS_format" = "virtualbox" ]; then
  qemu-img convert -f raw $TEMP_IMG \
    -O raw "${VBOX_TEMP_IMAGE}"
  VBoxManage convertdd "${VBOX_TEMP_IMAGE}" "${FLAGS_to}/${FLAGS_vbox_disk}"
elif [ "$FLAGS_format" = "vmware" ]; then
  qemu-img convert -f raw $TEMP_IMG \
    -O vmdk "${FLAGS_to}/${FLAGS_vmdk}"
else
  echo invalid format: "$FLAGS_format"
  exit 1
fi

rm -rf "$TEMP_DIR" "${VBOX_TEMP_IMAGE}" "$TEMP_IMG"
if [ -z "$FLAGS_state_image" ]; then
  rm -f "$STATE_IMAGE"
fi

echo "Created image ${FLAGS_to}"

# Generate the vmware config file
# A good reference doc: http://www.sanbarrow.com/vmx.html
VMX_CONFIG="#!/usr/bin/vmware
.encoding = \"UTF-8\"
config.version = \"8\"
virtualHW.version = \"4\"
memsize = \"${FLAGS_mem}\"
ide0:0.present = \"TRUE\"
ide0:0.fileName = \"${FLAGS_vmdk}\"
ethernet0.present = \"TRUE\"
usb.present = \"TRUE\"
sound.present = \"TRUE\"
sound.virtualDev = \"es1371\"
displayName = \"Chromium OS\"
guestOS = \"otherlinux\"
ethernet0.addressType = \"generated\"
floppy0.present = \"FALSE\""

if [[ ${FLAGS_make_vmx} = ${FLAGS_TRUE} ]]; then
  echo "${VMX_CONFIG}" > "${FLAGS_to}/${FLAGS_vmx}"
  echo "Wrote the following config to: ${FLAGS_to}/${FLAGS_vmx}"
  echo "${VMX_CONFIG}"
fi

