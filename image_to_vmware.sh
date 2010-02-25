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
# Memory units are in MBs
DEFAULT_MEM="1024"

# Flags
DEFINE_string from "$DEFAULT_FROM" \
  "Directory containing rootfs.image and mbr.image"
DEFINE_string to "$DEFAULT_TO" \
  "Destination folder for VMware files"
DEFINE_boolean make_vmx true \
  "Create a vmx file for use with vmplayer."
DEFINE_string vmdk "$DEFAULT_VMDK" \
  "Filename for the vmware disk image"
DEFINE_string vmx "$DEFAULT_VMX" \
  "Filename for the vmware config"
DEFINE_integer mem "$DEFAULT_MEM" \
  "Memory size for the vmware config in MBs."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

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

# Copy MBR and rootfs to output image
qemu-img convert -f raw \
  "${FLAGS_from}/mbr.image" "${FLAGS_from}/state.image" \
  "${FLAGS_from}/empty.image" "${FLAGS_from}/rootfs.image" \
  -O vmdk "${FLAGS_to}/${FLAGS_vmdk}"

rm -f "${FLAGS_from}/empty.image" "${FLAGS_from}/state.image"

echo "Created VMware image ${FLAGS_to}"

# Generate the vmware config file
# A good reference doc: http://www.sanbarrow.com/vmx.html
VMX_CONFIG=$(cat <<END
#!/usr/bin/vmware
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "4"
memsize = "${FLAGS_mem}"
ide0:0.present = "TRUE"
ide0:0.fileName = "${FLAGS_vmdk}"
ethernet0.present = "TRUE"
usb.present = "TRUE"
sound.present = "TRUE"
sound.virtualDev = "es1371"
displayName = "ChromeOS"
guestOS = "otherlinux"
ethernet0.addressType = "generated"
floppy0.present = "FALSE"
END)

if [[ ${FLAGS_make_vmx} ]]; then
  echo "${VMX_CONFIG}" > "${FLAGS_to}/${FLAGS_vmx}"
  echo "Wrote the following config to: ${FLAGS_to}/${FLAGS_vmx}"
  echo "${VMX_CONFIG}"
fi

