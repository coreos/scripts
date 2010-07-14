#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a VMware image and write a
# corresponding VMware config file.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/chromeos-common.sh"

get_default_board

DEFAULT_VMDK="ide.vmdk"
DEFAULT_VMX="chromiumos.vmx"
DEFAULT_VBOX_DISK="os.vdi"
DEFAULT_QEMU_IMAGE="chromiumos_qemu_image.bin"

MOD_SCRIPTS_ROOT="${GCLIENT_ROOT}/src/scripts/mod_for_test_scripts"

# Flags
DEFINE_string board "${DEFAULT_BOARD}" \
  "Board for which the image was built"
DEFINE_boolean factory $FLAGS_FALSE \
    "Modify the image for manufacturing testing"
DEFINE_boolean factory_install $FLAGS_FALSE \
    "Modify the image for factory install shim"
DEFINE_boolean force_copy ${FLAGS_FALSE} "Always rebuild test image"
DEFINE_string format "qemu" \
  "Output format, either qemu, vmware or virtualbox"
DEFINE_string from "" \
  "Directory containing rootfs.image and mbr.image"
DEFINE_boolean make_vmx ${FLAGS_TRUE} \
  "Create a vmx file for use with vmplayer (vmware only)."
DEFINE_integer mem "${DEFAULT_MEM}" \
  "Memory size for the vm config in MBs (vmware only)."
DEFINE_integer rootfs_partition_size 1024 \
  "rootfs parition size in MBs."
DEFINE_string state_image "" \
  "Stateful partition image (defaults to creating new statful partition)"
DEFINE_integer statefulfs_size -1 \
  "Stateful partition size in MBs."
DEFINE_boolean test_image "${FLAGS_FALSE}" \
  "Copies normal image to chromiumos_test_image.bin, modifies it for test."
DEFINE_string to "" \
  "Destination folder for VM output file(s)"
DEFINE_string vbox_disk "${DEFAULT_VBOX_DISK}" \
  "Filename for the output disk (virtualbox only)."
DEFINE_integer vdisk_size 3072 \
  "virtual disk size in MBs."
DEFINE_string vmdk "${DEFAULT_VMDK}" \
  "Filename for the vmware disk image (vmware only)."
DEFINE_string vmx "${DEFAULT_VMX}" \
  "Filename for the vmware config (vmware only)."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

if [ -z "${FLAGS_board}" ] ; then
  die "--board is required."
fi

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
# Default to the most recent image
if [ -z "${FLAGS_from}" ] ; then
  FLAGS_from="${IMAGES_DIR}/$(ls -t $IMAGES_DIR | head -1)"
else
  pushd "${FLAGS_from}" && FLAGS_from=`pwd` && popd
fi
if [ -z "${FLAGS_to}" ] ; then
  FLAGS_to="${FLAGS_from}"
fi

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
      EXTRA_ARGS="--factory"
    fi

    # Check for install shim.
    if [ ${FLAGS_factory_install} -eq ${FLAGS_TRUE} ] ; then
      EXTRA_ARGS="--factory_install"
    fi

    # Modify it.  Pass --yes so that mod_image_for_test.sh won't ask us if we
    # really want to modify the image; the user gave their assent already with
    # --test-image and the original image is going to be preserved.
    "${SCRIPTS_DIR}/mod_image_for_test.sh" --image \
      "${FLAGS_from}/chromiumos_test_image.bin" ${EXTRA_ARGS} --yes
    echo "Done with mod_image_for_test."
  else
    echo "Using cached test image."
  fi
  SRC_IMAGE="${FLAGS_from}/chromiumos_test_image.bin"
  echo "Source test image is: ${SRC_IMAGE}"
fi

# Memory units are in MBs
DEFAULT_MEM="1024"
TEMP_IMAGE="${IMAGES_DIR}/temp_image.img"


# If we're not building for VMWare, don't build the vmx
if [ "${FLAGS_format}" != "vmware" ]; then
  FLAGS_make_vmx="${FLAGS_FALSE}"
fi

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f $FOO` won't work.
FLAGS_from=`eval readlink -f $FLAGS_from`
FLAGS_to=`eval readlink -f $FLAGS_to`

# Split apart the partitions and make some new ones
TEMP_DIR=$(mktemp -d)
(cd "${TEMP_DIR}" &&
  "${FLAGS_from}/unpack_partitions.sh" "${SRC_IMAGE}")

# Fix the kernel command line
TEMP_ESP="${TEMP_DIR}"/part_12
TEMP_ROOTFS="${TEMP_DIR}"/part_3
TEMP_STATE="${TEMP_DIR}"/part_1
if [ -n "${FLAGS_state_image}" ]; then
  TEMP_STATE="${FLAGS_state_image}"
else
  # If we have a stateful fs size specified create a new state partition
  # of the specified size.
  if [ "${FLAGS_statefulfs_size}" -ne -1 ]; then
    STATEFUL_SIZE_BYTES=$((1024 * 1024 * ${FLAGS_statefulfs_size}))
    original_image_size=$(stat -c%s "${TEMP_STATE}")
    if [ "${original_image_size}" -gt "${STATEFUL_SIZE_BYTES}" ]; then
      die "Cannot resize stateful image to smaller than original. Exiting."
    fi

    echo "Resizing stateful partition to ${FLAGS_statefulfs_size}MB"
    STATEFUL_LOOP_DEV=$(sudo losetup -f)
    if [ -z "${STATEFUL_LOOP_DEV}" ]; then
      die "No free loop device. Free up a loop device or reboot. Exiting."
    fi

    # Extend the original file size to the new size.
    dd if=/dev/zero of="${TEMP_STATE}" bs=1 count=1 \
        seek=$((STATEFUL_SIZE_BYTES - 1))
    # Resize the partition.
    sudo losetup "${STATEFUL_LOOP_DEV}" "${TEMP_STATE}"
    sudo e2fsck -f "${STATEFUL_LOOP_DEV}"
    sudo resize2fs "${STATEFUL_LOOP_DEV}"
    sudo losetup -d "${STATEFUL_LOOP_DEV}"
  fi
fi
TEMP_KERN="${TEMP_DIR}"/part_2
TEMP_PMBR="${TEMP_DIR}"/pmbr
dd if="${SRC_IMAGE}" of="${TEMP_PMBR}" bs=512 count=1

TEMP_MNT=$(mktemp -d)
cleanup() {
  sudo umount -d "${TEMP_MNT}"
  rmdir "${TEMP_MNT}"
}
trap cleanup INT TERM EXIT
mkdir -p "${TEMP_MNT}"
sudo mount -o loop "${TEMP_ROOTFS}" "${TEMP_MNT}"
if [ "${FLAGS_format}" = "qemu" ]; then
  sudo python ./fixup_image_for_qemu.py --mounted_dir="${TEMP_MNT}" \
  --for_qemu=true
else
  sudo python ./fixup_image_for_qemu.py --mounted_dir="${TEMP_MNT}" \
  --for_qemu=false
fi

# Change this value if the rootfs partition changes
ROOTFS_PARTITION=/dev/sda3
sudo "${TEMP_MNT}"/postinst_vm "${ROOTFS_PARTITION}"
trap - INT TERM EXIT
cleanup

# Make 3 GiB output image
TEMP_IMG=$(mktemp)
# TOOD(adlr): pick a size that will for sure accomodate the partitions
sudo dd if=/dev/zero of="${TEMP_IMG}" bs=1 count=1 \
  seek=$((${FLAGS_vdisk_size} * 1024 * 1024 - 1))

# Set up the partition table
install_gpt "${TEMP_IMG}" "${TEMP_ROOTFS}" "${TEMP_KERN}" "${TEMP_STATE}" \
  "${TEMP_PMBR}" "${TEMP_ESP}" false ${FLAGS_rootfs_partition_size}
# Copy into the partition parts of the file
dd if="${TEMP_ROOTFS}" of="${TEMP_IMG}" conv=notrunc bs=512 \
  seek="${START_ROOTFS_A}"
dd if="${TEMP_STATE}"  of="${TEMP_IMG}" conv=notrunc bs=512 \
  seek="${START_STATEFUL}"
dd if="${TEMP_KERN}"   of="${TEMP_IMG}" conv=notrunc bs=512 \
  seek="${START_KERN_A}"
dd if="${TEMP_ESP}"    of="${TEMP_IMG}" conv=notrunc bs=512 \
  seek="${START_ESP}"

echo Creating final image
# Convert image to output format
if [ "${FLAGS_format}" = "virtualbox" -o "${FLAGS_format}" = "qemu" ]; then
  if [ "${FLAGS_format}" = "virtualbox" ]; then
    VBoxManage convertdd "${TEMP_IMG}" "${FLAGS_to}/${FLAGS_vbox_disk}"
  else
    mv ${TEMP_IMG} ${FLAGS_to}/${DEFAULT_QEMU_IMAGE}
  fi
elif [ "${FLAGS_format}" = "vmware" ]; then
  qemu-img convert -f raw "${TEMP_IMG}" \
    -O vmdk "${FLAGS_to}/${FLAGS_vmdk}"
else
  die "Invalid format: ${FLAGS_format}"
fi

rm -rf "${TEMP_DIR}" "${TEMP_IMG}"
if [ -z "${FLAGS_state_image}" ]; then
  rm -f "${STATE_IMAGE}"
fi

echo "Created image at ${FLAGS_to}"

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

if [[ "${FLAGS_make_vmx}" = "${FLAGS_TRUE}" ]]; then
  echo "${VMX_CONFIG}" > "${FLAGS_to}/${FLAGS_vmx}"
  echo "Wrote the following config to: ${FLAGS_to}/${FLAGS_vmx}"
  echo "${VMX_CONFIG}"
fi

