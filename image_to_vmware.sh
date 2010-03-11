#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a VMware image and write a
# corresponding VMware config file.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

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

# Make two sparse files. One for an empty partition, another for
# stateful partition.
PART_SIZE=$(stat -c%s "${FLAGS_from}/rootfs.image")
dd if=/dev/zero of="${FLAGS_from}/empty.image" bs=1 count=1 \
    seek=$(( $PART_SIZE - 1 ))
dd if=/dev/zero of="${FLAGS_from}/state.image" bs=1 count=1 \
    seek=$(( $PART_SIZE - 1 ))
mkfs.ext3 -F -L C-STATE "${FLAGS_from}/state.image"

# Fix bootloader config.
TEMP_IMG=$(mktemp)
TEMP_MNT=$(mktemp -d)
cp "${FLAGS_from}/rootfs.image" "$TEMP_IMG"
mkdir -p "$TEMP_MNT"
sudo mount -o loop "$TEMP_IMG" "$TEMP_MNT"
sudo "$TEMP_MNT"/postinst /dev/sda3
sudo umount "$TEMP_MNT"
rmdir "$TEMP_MNT"

if [ "$FLAGS_format" = "virtualbox" ]; then
  # Copy MBR and rootfs to output image
  qemu-img convert -f raw \
    "${FLAGS_from}/mbr.image" "${FLAGS_from}/state.image" \
    "${FLAGS_from}/empty.image" "$TEMP_IMG" \
    -O raw "${VBOX_TEMP_IMAGE}"
  VBoxManage convertdd "${VBOX_TEMP_IMAGE}" "${FLAGS_to}/${FLAGS_vbox_disk}"
elif [ "$FLAGS_format" = "vmware" ]; then
  # Copy MBR and rootfs to output image
  qemu-img convert -f raw \
    "${FLAGS_from}/mbr.image" "${FLAGS_from}/state.image" \
    "${FLAGS_from}/empty.image" "$TEMP_IMG" \
    -O vmdk "${FLAGS_to}/${FLAGS_vmdk}"
else
  echo invalid format: "$FLAGS_format"
  exit 1
fi

rm -f "${FLAGS_from}/empty.image" "${FLAGS_from}/state.image" \
  "$TEMP_IMG" "${VBOX_TEMP_IMAGE}"

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

