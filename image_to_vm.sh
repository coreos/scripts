#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a VMware image and write a
# corresponding VMware config file.

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

# Need to be inside the chroot to load chromeos-common.sh
assert_inside_chroot

# Load functions and constants for chromeos-install
. "/usr/lib/installer/chromeos-common.sh" || \
  die "Unable to load /usr/lib/installer/chromeos-common.sh"

. "${SCRIPT_ROOT}/lib/cros_vm_constants.sh" || \
  die "Unable to load ${SCRIPT_ROOT}/lib/cros_vm_constants.sh"

get_default_board

# Flags
DEFINE_string board "${DEFAULT_BOARD}" \
  "Board for which the image was built"
DEFINE_boolean factory $FLAGS_FALSE \
    "Modify the image for manufacturing testing"
DEFINE_boolean factory_install $FLAGS_FALSE \
    "Modify the image for factory install shim"

# We default to TRUE so the buildbot gets its image. Note this is different
# behavior from image_to_usb.sh
DEFINE_boolean force_copy ${FLAGS_TRUE} "Always rebuild test image"
DEFINE_string format "qemu" \
  "Output format, either qemu, vmware or virtualbox"
DEFINE_string from "" \
  "Directory containing rootfs.image and mbr.image"
DEFINE_boolean full "${FLAGS_FALSE}" "Build full image with all partitions."
DEFINE_boolean make_vmx ${FLAGS_TRUE} \
  "Create a vmx file for use with vmplayer (vmware only)."
DEFINE_integer mem "${DEFAULT_MEM}" \
  "Memory size for the vm config in MBs (vmware only)."
DEFINE_integer rootfs_partition_size 1024 \
  "rootfs parition size in MBs."
DEFINE_string state_image "" \
  "Stateful partition image (defaults to creating new statful partition)"
DEFINE_integer statefulfs_size 2048 \
  "Stateful partition size in MBs."
DEFINE_boolean test_image "${FLAGS_FALSE}" \
  "Copies normal image to ${CHROMEOS_TEST_IMAGE_NAME}, modifies it for test."
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

if [ "${FLAGS_full}" -eq "${FLAGS_TRUE}" ] && \
    ( [[ ${FLAGS_vdisk_size} < ${MIN_VDISK_SIZE_FULL} ]] || \
      [[ ${FLAGS_statefulfs_size} < ${MIN_STATEFUL_FS_SIZE_FULL} ]]); then
  warn "Disk is too small for full, using minimum:  vdisk size equal to \
${MIN_VDISK_SIZE_FULL} and statefulfs size equal to \
${MIN_STATEFUL_FS_SIZE_FULL}."
  FLAGS_vdisk_size=${MIN_VDISK_SIZE_FULL}
  FLAGS_statefulfs_size=${MIN_STATEFUL_FS_SIZE_FULL}
fi

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
# Default to the most recent image
if [ -z "${FLAGS_from}" ] ; then
  FLAGS_from="$(./get_latest_image.sh --board=${FLAGS_board})"
else
  pushd "${FLAGS_from}" && FLAGS_from=`pwd` && popd
fi
if [ -z "${FLAGS_to}" ] ; then
  FLAGS_to="${FLAGS_from}"
fi

if [ ${FLAGS_test_image} -eq ${FLAGS_TRUE} ] ; then
  # Make a test image - this returns the test filename in CHROMEOS_RETURN_VAL
  prepare_test_image "${FLAGS_from}" "${CHROMEOS_IMAGE_NAME}"
  SRC_IMAGE="${CHROMEOS_RETURN_VAL}"
else
  # Use the standard image
  SRC_IMAGE="${FLAGS_from}/${CHROMEOS_IMAGE_NAME}"
fi

# Memory units are in MBs
TEMP_IMG="$(dirname "${SRC_IMAGE}")/vm_temp_image.bin"

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
TEMP_KERN="${TEMP_DIR}"/part_2
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
    sudo e2fsck -pf "${STATEFUL_LOOP_DEV}"
    sudo resize2fs "${STATEFUL_LOOP_DEV}"
    sync
    sudo losetup -d "${STATEFUL_LOOP_DEV}"
  fi
fi
TEMP_PMBR="${TEMP_DIR}"/pmbr
dd if="${SRC_IMAGE}" of="${TEMP_PMBR}" bs=512 count=1

TEMP_MNT=$(mktemp -d)
TEMP_ESP_MNT=$(mktemp -d)
cleanup() {
  sudo umount -d "${TEMP_MNT}"
  sudo umount -d "${TEMP_ESP_MNT}"
  rmdir "${TEMP_MNT}" "${TEMP_ESP_MNT}"
}
trap cleanup INT TERM EXIT
mkdir -p "${TEMP_MNT}"
enable_rw_mount "${TEMP_ROOTFS}"
sudo mount -o loop "${TEMP_ROOTFS}" "${TEMP_MNT}"
mkdir -p "${TEMP_ESP_MNT}"
sudo mount -o loop "${TEMP_ESP}" "${TEMP_ESP_MNT}"

if [ "${FLAGS_format}" = "qemu" ]; then
  sudo python "${SCRIPTS_DIR}/fixup_image_for_qemu.py" \
      --mounted_dir="${TEMP_MNT}" \
      --enable_tablet=true
else
  sudo python "${SCRIPTS_DIR}/fixup_image_for_qemu.py" \
      --mounted_dir="${TEMP_MNT}" \
      --enable_tablet=false
fi

# Modify the unverified usb template which uses a default usb_disk of sdb3
sudo sed -i -e 's/sdb3/sda3/g' "${TEMP_MNT}/boot/syslinux/usb.A.cfg"

# Unmount everything prior to building a final image
sync
trap - INT TERM EXIT
cleanup

# TOOD(adlr): pick a size that will for sure accomodate the partitions.
dd if=/dev/zero of="${TEMP_IMG}" bs=1 count=1 \
  seek=$((${FLAGS_vdisk_size} * 1024 * 1024 - 1))

GPT_FULL="false"
[ "${FLAGS_full}" -eq "${FLAGS_TRUE}" ] && GPT_FULL="true"

# Set up the partition table
install_gpt "${TEMP_IMG}" "$(numsectors $TEMP_ROOTFS)" \
  "$(numsectors $TEMP_STATE)" "${TEMP_PMBR}" "$(numsectors $TEMP_ESP)" \
  "${GPT_FULL}" ${FLAGS_rootfs_partition_size}
# Copy into the partition parts of the file
dd if="${TEMP_ROOTFS}" of="${TEMP_IMG}" conv=notrunc bs=512 \
  seek="${START_ROOTFS_A}"
dd if="${TEMP_STATE}"  of="${TEMP_IMG}" conv=notrunc bs=512 \
  seek="${START_STATEFUL}"
dd if="${TEMP_KERN}"   of="${TEMP_IMG}" conv=notrunc bs=512 \
  seek="${START_KERN_A}"
dd if="${TEMP_ESP}"    of="${TEMP_IMG}" conv=notrunc bs=512 \
  seek="${START_ESP}"

# Make the built-image bootable and ensure that the legacy default usb boot
# uses /dev/sda instead of /dev/sdb3.
# NOTE: The TEMP_IMG must live in the same image dir as the original image
#       to operate automatically below.
${SCRIPTS_DIR}/bin/cros_make_image_bootable $(dirname "${TEMP_IMG}") \
                                            $(basename "${TEMP_IMG}") \
                                            --usb_disk /dev/sda3

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


if [ "${FLAGS_format}" == "qemu" ]; then
  echo "If you have qemu-kvm installed, you can start the image by:"
  echo "sudo kvm -m ${FLAGS_mem} -vga std -pidfile /tmp/kvm.pid -net nic,model=virtio " \
       "-net user,hostfwd=tcp::9222-:22 \\"
  echo "        -hda ${FLAGS_to}/${DEFAULT_QEMU_IMAGE}"
fi
