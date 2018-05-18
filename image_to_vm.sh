#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a usable virtual machine
# disk image, supporting a variety of different targets.


# Helper scripts should be run from the same location as this script.
SCRIPT_ROOT=$(dirname "$(readlink -f "$0")")
. "${SCRIPT_ROOT}/common.sh" || exit 1

# Script must run inside the chroot
restart_in_chroot_if_needed "$@"

assert_not_root_user

. "${BUILD_LIBRARY_DIR}/toolchain_util.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/build_image_util.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/vm_image_util.sh" || exit 1

# Flags
DEFINE_string board "${DEFAULT_BOARD}" \
  "Board for which the image was built"

# We default to TRUE so the buildbot gets its image. Note this is different
# behavior from image_to_usb.sh
DEFINE_string format "" \
  "Output format, one of: ${VALID_IMG_TYPES[*]}"
DEFINE_string from "" \
  "Directory containing coreos_developer_image.bin or coreos_production_image.bin."
DEFINE_string disk_layout "" \
  "The disk layout type to use for this image."
DEFINE_integer mem "" \
  "Memory size for the vm config in MBs."
DEFINE_boolean dev_image "${FLAGS_FALSE}" \
  "Use the development image instead of the default production image."
DEFINE_string to "" \
  "Destination folder for VM output file(s)"
DEFINE_string oem_pkg "" \
  "OEM package to install"
DEFINE_boolean getbinpkg "${FLAGS_FALSE}" \
  "Download binary packages from remote repository."
DEFINE_string getbinpkgver "" \
  "Use binary packages from a specific version."

# include upload options
. "${BUILD_LIBRARY_DIR}/release_util.sh" || exit 1

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
switch_to_strict_mode

check_gsutil_opts

if [[ -z "${FLAGS_format}" ]]; then
    FLAGS_format="$(get_default_vm_type ${FLAGS_board})"
fi

if ! set_vm_type "${FLAGS_format}"; then
    die_notrace "Invalid format: ${FLAGS_format}"
fi

if [ ! -z "${FLAGS_oem_pkg}" ] && ! set_vm_oem_pkg "${FLAGS_oem_pkg}"; then
  die_notrace "Invalid oem : ${FLAGS_oem_pkg}"
fi

if [ -z "${FLAGS_board}" ] ; then
  die_notrace "--board is required."
fi

if [[ -z "${FLAGS_mem}" ]]; then
  FLAGS_mem=$(get_vm_mem ${FLAGS_board})
fi

# If downloading packages is enabled ensure the board is configured properly.
if [[ ${FLAGS_getbinpkg} -eq ${FLAGS_TRUE} ]]; then
  "${SRC_ROOT}/scripts/setup_board" --board="${FLAGS_board}" \
      --getbinpkgver="${FLAGS_getbinpkgver}" --regen_configs_only
fi

# Loaded late because board_options depends on setup_board
. "${BUILD_LIBRARY_DIR}/board_options.sh" || exit 1


IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
# Default to the most recent image
if [ -z "${FLAGS_from}" ] ; then
  FLAGS_from="$(${SCRIPT_ROOT}/get_latest_image.sh --board=${FLAGS_board})"
else
  pushd "${FLAGS_from}" >/dev/null && FLAGS_from=`pwd` && popd >/dev/null
fi
if [ -z "${FLAGS_to}" ] ; then
  FLAGS_to="${FLAGS_from}"
fi

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f $FOO` won't work.
FLAGS_from=`eval readlink -f $FLAGS_from`
FLAGS_to=`eval readlink -f $FLAGS_to`

# If source includes version.txt switch to its version information
if [ -f "${FLAGS_from}/version.txt" ]; then
    source "${FLAGS_from}/version.txt"
    COREOS_VERSION_STRING="${COREOS_VERSION}"
fi

if [ ${FLAGS_dev_image} -eq ${FLAGS_TRUE} ]; then
  set_vm_paths "${FLAGS_from}" "${FLAGS_to}" "${COREOS_DEVELOPER_IMAGE_NAME}"
  if [[ "${FLAGS_disk_layout}" == "" ]]; then
    FLAGS_disk_layout=devel
  fi
else
  set_vm_paths "${FLAGS_from}" "${FLAGS_to}" "${COREOS_PRODUCTION_IMAGE_NAME}"
fi

# Make sure things are cleaned up on failure
trap vm_cleanup EXIT

fix_mtab

# Setup new (raw) image, possibly resizing filesystems
setup_disk_image "${FLAGS_disk_layout}"

# Optionally install any OEM packages
install_oem_package
install_oem_aci
run_fs_hook

# Changes done, glue it together
write_vm_disk
write_vm_conf "${FLAGS_mem}"
write_vm_bundle

vm_cleanup
trap - EXIT

# Optionally upload all of our hard work
vm_upload

# Ready to set sail!
okboat
command_completed
print_readme
