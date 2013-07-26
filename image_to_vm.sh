#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a usable virtual machine
# disk image, supporting a variety of different targets.



# Helper scripts should be run from the same location as this script.
SCRIPT_ROOT=$(dirname "$(readlink -f "$0")")
. "${SCRIPT_ROOT}/common.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/disk_layout_util.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/build_common.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/build_image_util.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/vm_image_util.sh" || exit 1

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
  "Output format, one of: ${VALID_IMG_TYPES[*]}"
DEFINE_string from "" \
  "Directory containing rootfs.image and mbr.image"
DEFINE_string disk_layout "vm" \
  "The disk layout type to use for this image."
DEFINE_integer mem "${DEFAULT_MEM}" \
  "Memory size for the vm config in MBs."
DEFINE_string state_image "" \
  "Stateful partition image (defaults to creating new statful partition)"
DEFINE_boolean test_image "${FLAGS_FALSE}" \
  "Copies normal image to ${CHROMEOS_TEST_IMAGE_NAME}, modifies it for test."
DEFINE_boolean prod_image "${FLAGS_FALSE}" \
  "Copies normal image to ${COREOS_OFFICIAL_IMAGE_NAME}, modifies it for test."
DEFINE_string to "" \
  "Destination folder for VM output file(s)"

# include upload options
. "${BUILD_LIBRARY_DIR}/release_util.sh" || exit 1

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
switch_to_strict_mode

if ! set_vm_type "${FLAGS_format}"; then
    die_notrace "Invalid format: ${FLAGS_format}"
fi

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

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f $FOO` won't work.
FLAGS_from=`eval readlink -f $FLAGS_from`
FLAGS_to=`eval readlink -f $FLAGS_to`

if [ ${FLAGS_prod_image} -eq ${FLAGS_TRUE} ]; then
  set_vm_paths "${FLAGS_from}" "${FLAGS_to}" "${COREOS_PRODUCTION_IMAGE_NAME}"
elif [ ${FLAGS_test_image} -eq ${FLAGS_TRUE} ]; then
  set_vm_paths "${FLAGS_from}" "${FLAGS_to}" "${CHROMEOS_TEST_IMAGE_NAME}"
else
  # Use the standard image
  set_vm_paths "${FLAGS_from}" "${FLAGS_to}" "${CHROMEOS_IMAGE_NAME}"
fi

locate_gpt
legacy_offset_size_export ${VM_SRC_IMG}

# Make sure things are cleaned up on failure
trap vm_cleanup EXIT

# Unpack image, using alternate state image if defined
# Resize to use all available space in new disk layout
STATEFUL_SIZE=$(get_filesystem_size "${FLAGS_disk_layout}" ${NUM_STATEFUL})
unpack_source_disk "${FLAGS_disk_layout}" "${FLAGS_state_image}"
resize_state_partition "${STATEFUL_SIZE}"

# Optionally install any OEM packages
install_oem_package

# Changes done, glue it together
write_vm_disk
write_vm_conf "${FLAGS_mem}"

vm_cleanup
trap - EXIT

# Optionally upload all of our hard work
upload_image "${VM_GENERATED_FILES[@]}"

# Ready to set sail!
okboat
command_completed
print_readme
