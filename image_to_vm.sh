#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a VMware image and write a
# corresponding VMware config file.

# Helper scripts should be run from the same location as this script.
SCRIPT_ROOT=$(dirname "$(readlink -f "$0")")
. "${SCRIPT_ROOT}/common.sh" || exit 1
. "${SCRIPT_ROOT}/build_library/disk_layout_util.sh" || exit 1
. "${SCRIPT_ROOT}/build_library/build_common.sh" || exit 1
. "${SCRIPT_ROOT}/build_library/build_image_util.sh" || exit 1

# Need to be inside the chroot to load chromeos-common.sh
assert_inside_chroot

# Load functions and constants for chromeos-install
. /usr/lib/installer/chromeos-common.sh || exit 1
. "${SCRIPT_ROOT}/lib/cros_vm_constants.sh" || exit 1

# Flags
DEFINE_string adjust_part "" \
  "Adjustments to apply to the partition table"
DEFINE_string board "${DEFAULT_BOARD}" \
  "Board for which the image was built"
DEFINE_boolean prod $FLAGS_FALSE \
    "Build prod image"

# We default to TRUE so the buildbot gets its image. Note this is different
# behavior from image_to_usb.sh
DEFINE_boolean force_copy ${FLAGS_FALSE} "Always rebuild test image"
DEFINE_string format "qemu" \
  "Output format, either xen, qemu, vmware or virtualbox"
DEFINE_string from "" \
  "Directory containing rootfs.image and mbr.image"
DEFINE_string disk_layout "vm" \
  "The disk layout type to use for this image."
DEFINE_boolean make_vmx ${FLAGS_TRUE} \
  "Create a vmx file for use with vmplayer (vmware only)."
DEFINE_integer mem "${DEFAULT_MEM}" \
  "Memory size for the vm config in MBs (vmware only)."
DEFINE_string state_image "" \
  "Stateful partition image (defaults to creating new statful partition)"
DEFINE_boolean test_image "${FLAGS_FALSE}" \
  "Copies normal image to ${CHROMEOS_TEST_IMAGE_NAME}, modifies it for test."
DEFINE_boolean prod_image "${FLAGS_FALSE}" \
  "Copies normal image to ${COREOS_OFFICIAL_IMAGE_NAME}, modifies it for test."
DEFINE_string to "" \
  "Destination folder for VM output file(s)"
DEFINE_string vbox_disk "${DEFAULT_VBOX_DISK}" \
  "Filename for the output disk (virtualbox only)."
DEFINE_string vmdk "${DEFAULT_VMDK}" \
  "Filename for the vmware disk image (vmware only)."
DEFINE_string vmx "${DEFAULT_VMX}" \
  "Filename for the vmware config (vmware only)."

# The following arguments are ignored.
# They are here as part of a transition for CL #29931 beacuse the buildbots
# specify these arguments.
DEFINE_integer vdisk_size 3072 \
  "virtual disk size in MBs."
DEFINE_boolean full "${FLAGS_FALSE}" "Build full image with all partitions."
DEFINE_integer rootfs_partition_size 1024 \
  "rootfs parition size in MBs."
DEFINE_integer statefulfs_size 2048 \
  "Stateful partition size in MBs."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
switch_to_strict_mode

if [ -z "${FLAGS_board}" ] ; then
  die_notrace "--board is required."
fi

BOARD="$FLAGS_board"

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
# Default to the most recent image
if [ -z "${FLAGS_from}" ] ; then
  FLAGS_from="$(${SCRIPT_ROOT}/get_latest_image.sh --board=${FLAGS_board})"
else
  pushd "${FLAGS_from}" && FLAGS_from=`pwd` && popd
fi
if [ -z "${FLAGS_to}" ] ; then
  FLAGS_to="${FLAGS_from}"
fi

if [ ${FLAGS_prod_image} -eq ${FLAGS_TRUE} ]; then
  SRC_IMAGE="${FLAGS_from}/${COREOS_PRODUCTION_IMAGE_NAME}"
elif [ ${FLAGS_test_image} -eq ${FLAGS_TRUE} ]; then
  SRC_IMAGE="${FLAGS_from}/${CHROMEOS_TEST_IMAGE_NAME}"
else
  # Use the standard image
  SRC_IMAGE="${FLAGS_from}/${CHROMEOS_IMAGE_NAME}"
fi

locate_gpt
legacy_offset_size_export ${SRC_IMAGE}

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
pushd "${TEMP_DIR}" >/dev/null
"${FLAGS_from}/unpack_partitions.sh" "${SRC_IMAGE}"
popd >/dev/null

# Fix the kernel command line
TEMP_ESP="${TEMP_DIR}"/part_${NUM_ESP}
TEMP_OEM="${TEMP_DIR}"/part_${NUM_OEM}
TEMP_ROOTFS="${TEMP_DIR}"/part_${NUM_ROOTFS_A}
TEMP_STATE="${TEMP_DIR}"/part_${NUM_STATEFUL}
if [ -n "${FLAGS_state_image}" ]; then
  TEMP_STATE="${FLAGS_state_image}"
else
  STATEFUL_SIZE_BYTES=$(get_filesystem_size "${FLAGS_disk_layout}" ${NUM_STATEFUL})
  STATEFUL_SIZE_MEGABYTES=$(( STATEFUL_SIZE_BYTES / 1024 / 1024 ))
  original_image_size=$(stat -c%s "${TEMP_STATE}")
  if [ "${original_image_size}" -gt "${STATEFUL_SIZE_BYTES}" ]; then
    die "Cannot resize stateful image to smaller than original. Exiting."
  fi

  echo "Resizing stateful partition to ${STATEFUL_SIZE_MEGABYTES}MB"
  # Extend the original file size to the new size.
  sudo e2fsck -pf "${TEMP_STATE}"
  sudo resize2fs "${TEMP_STATE}" ${STATEFUL_SIZE_MEGABYTES}M
fi

# handle OEM stuff if needed
TEMP_OEM_MNT="${TEMP_DIR}"/oem_mnt
mkdir -p $TEMP_OEM_MNT
sudo mount -o loop ${TEMP_OEM} ${TEMP_OEM_MNT}

# oem hacks
if [ "${FLAGS_format}" == "ami" ]; then
	echo ami
	emerge_to_image --root="${TEMP_OEM_MNT}" oem-ami
	# sudo rm -rf, how could this go wrong?
	# TODO: figure out how to keep portage from putting these
	# portage files on disk, we don't need or want them.
	sudo rm -rvf ${TEMP_OEM_MNT}/var
	sudo rm -rvf ${TEMP_OEM_MNT}/etc
	sudo rm -rvf ${TEMP_OEM_MNT}/tmp
	if [ ! -e ${TEMP_OEM_MNT}/run.sh ]; then
		echo "ERROR: requires oem/run.sh for oem partition to work" 1>&2
		exit 1
	fi
fi

sudo umount ${TEMP_OEM_MNT}
rm -rf ${TEMP_OEM_MNT}


TEMP_PMBR="${TEMP_DIR}"/pmbr
dd if="${SRC_IMAGE}" of="${TEMP_PMBR}" bs=512 count=1

# Set up a new partition table
PARTITION_SCRIPT_PATH=$( tempfile )
write_partition_script "${FLAGS_disk_layout}" "${PARTITION_SCRIPT_PATH}"
. "${PARTITION_SCRIPT_PATH}"
write_partition_table "${TEMP_IMG}" "${TEMP_PMBR}"
rm "${PARTITION_SCRIPT_PATH}"

# Copy into the partition parts of the file
dd if="${TEMP_ROOTFS}" of="${TEMP_IMG}" conv=notrunc bs=512 \
  seek=$(partoffset ${TEMP_IMG} ${NUM_ROOTFS_A})
dd if="${TEMP_STATE}"  of="${TEMP_IMG}" conv=notrunc bs=512 \
  seek=$(partoffset ${TEMP_IMG} ${NUM_STATEFUL})
dd if="${TEMP_ESP}"    of="${TEMP_IMG}" conv=notrunc bs=512 \
  seek=$(partoffset ${TEMP_IMG} ${NUM_ESP})
dd if="${TEMP_OEM}"    of="${TEMP_IMG}" conv=notrunc bs=512 \
  seek=$(partoffset ${TEMP_IMG} ${NUM_OEM})

echo Creating final image
# Convert image to output format
if [ "${FLAGS_format}" = "virtualbox" -o "${FLAGS_format}" = "qemu" \
     -o "${FLAGS_format}" = "xen" ]; then
  if [ "${FLAGS_format}" = "virtualbox" ]; then
    sudo VBoxManage convertdd "${TEMP_IMG}" "${FLAGS_to}/${FLAGS_vbox_disk}"
  else
    mv ${TEMP_IMG} ${FLAGS_to}/${DEFAULT_QEMU_IMAGE}
  fi
elif [ "${FLAGS_format}" = "vmware" ]; then
  qemu-img convert -f raw "${TEMP_IMG}" \
    -O vmdk "${FLAGS_to}/${FLAGS_vmdk}"
elif [ "${FLAGS_format}" = "ami" ]; then
  /usr/sbin/gdisk ${TEMP_IMG} <<EOF
r
h
1
N
c
Y
N
w
Y
Y
EOF
  mv ${TEMP_IMG} ${FLAGS_to}/${DEFAULT_QEMU_IMAGE/qemu/ami}
else
  die_notrace "Invalid format: ${FLAGS_format}"
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
  echo "qemu-kvm -m ${FLAGS_mem} -curses -pidfile /tmp/kvm.pid -net nic,model=virtio \\"
  echo "  -net user,hostfwd=tcp::2222-:22 -hda ${FLAGS_to}/${DEFAULT_QEMU_IMAGE}"
  echo "SSH into the host with:"
  echo "ssh 127.0.0.1 -p 2222"
fi
