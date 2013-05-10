#!/bin/bash

# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Helper script that mounts chromium os image from a device or directory
# and creates mount points for /var and /usr/local (if in dev_mode).

# Helper scripts should be run from the same location as this script.
SCRIPT_ROOT=$(dirname "$(readlink -f "$0")")
. "${SCRIPT_ROOT}/common.sh" || exit 1

if [ $INSIDE_CHROOT -ne 1 ]; then
  INSTALL_ROOT="$SRC_ROOT/platform/installer/"
else
  INSTALL_ROOT=/usr/lib/installer/
fi
# Load functions and constants for chromeos-install
. "${INSTALL_ROOT}/chromeos-common.sh" || exit 1

locate_gpt

# Flags.
DEFINE_string board "$DEFAULT_BOARD" \
  "The board for which the image was built." b
DEFINE_boolean read_only $FLAGS_FALSE \
  "Mount in read only mode -- skips stateful items."
DEFINE_boolean safe $FLAGS_FALSE \
  "Mount rootfs in read only mode."
DEFINE_boolean unmount $FLAGS_FALSE \
  "Unmount previously mounted dir." u
DEFINE_string from "/dev/sdc" \
  "Directory, image, or device with image on it" f
DEFINE_string image "chromiumos_image.bin"\
  "Name of the bin file if a directory is specified in the from flag" i
DEFINE_string "rootfs_mountpt" "/tmp/m" "Mount point for rootfs" "r"
DEFINE_string "stateful_mountpt" "/tmp/s" \
    "Mount point for stateful partition" "s"
DEFINE_string "esp_mountpt" "" \
    "Mount point for esp partition" "e"
DEFINE_boolean most_recent ${FLAGS_FALSE} "Use the most recent image dir" m

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on error
switch_to_strict_mode

# Find the last image built on the board.
if [ ${FLAGS_most_recent} -eq ${FLAGS_TRUE} ] ; then
  FLAGS_from="$(${SCRIPT_ROOT}/get_latest_image.sh --board="${FLAGS_board}")"
fi

# Check for conflicting args.
# If --from is a block device, --image can't also be specified.
if [ -b "${FLAGS_from}" ]; then
  if [ "${FLAGS_image}" != "chromiumos_image.bin" ]; then
    die_notrace "-i ${FLAGS_image} can't be used with block device ${FLAGS_from}"
  fi
fi

# Allow --from /foo/file.bin
if [ -f "${FLAGS_from}" ]; then
  # If --from is specified as a file, --image cannot be also specified.
  if [ "${FLAGS_image}" != "chromiumos_image.bin" ]; then
    die_notrace "-i ${FLAGS_image} can't be used with --from file ${FLAGS_from}"
  fi
  pathname=$(dirname "${FLAGS_from}")
  filename=$(basename "${FLAGS_from}")
  FLAGS_image="${filename}"
  FLAGS_from="${pathname}"
fi

# Common unmounts for either a device or directory
unmount_image() {
  info "Unmounting image from ${FLAGS_stateful_mountpt}" \
      "and ${FLAGS_rootfs_mountpt}"
  # Don't die on error to force cleanup
  set +e
  # Reset symlinks in /usr/local.
  if mount | egrep -q ".* ${FLAGS_stateful_mountpt} .*\(rw,"; then
    setup_symlinks_on_root "/usr/local" "/var" \
      "${FLAGS_stateful_mountpt}"
    fix_broken_symlinks "${FLAGS_rootfs_mountpt}"
  fi
  safe_umount "${FLAGS_rootfs_mountpt}/usr/local"
  safe_umount "${FLAGS_rootfs_mountpt}/var"
  if [[ -n "${FLAGS_esp_mountpt}" ]]; then
    safe_umount "${FLAGS_esp_mountpt}"
  fi
  safe_umount "${FLAGS_stateful_mountpt}"
  safe_umount "${FLAGS_rootfs_mountpt}"
  switch_to_strict_mode
}

get_usb_partitions() {
  local ro_flag=""
  local safe_flag=""
  [ ${FLAGS_read_only} -eq ${FLAGS_TRUE} ] && ro_flag="-o ro"
  [ ${FLAGS_read_only} -eq ${FLAGS_TRUE} -o \
    ${FLAGS_safe} -eq ${FLAGS_TRUE} ] && safe_flag="-o ro -t ext2"

  sudo mount ${safe_flag} "${FLAGS_from}4" "${FLAGS_rootfs_mountpt}"
  sudo mount ${ro_flag} "${FLAGS_from}10" "${FLAGS_stateful_mountpt}"
  if [[ -n "${FLAGS_esp_mountpt}" ]]; then
    sudo mount ${ro_flag} "${FLAGS_from}2" "${FLAGS_esp_mountpt}"
  fi
}

get_gpt_partitions() {
  local filename="${FLAGS_image}"

  legacy_offset_size_export "${FLAGS_from}/${FLAGS_image}"

  # Mount the rootfs partition using a loopback device.
  local offset=$(partoffset "${FLAGS_from}/${filename}" ${NUM_ROOTFS_A})
  local ro_flag=""
  local safe_flag=""

  if [ ${FLAGS_read_only} -eq ${FLAGS_TRUE} ]; then
    ro_flag="-o ro"
  fi

  if [ ${FLAGS_read_only} -eq ${FLAGS_TRUE} -o \
       ${FLAGS_safe} -eq ${FLAGS_TRUE} ]; then
    safe_flag="-o ro -t ext2"
  else
    # Make sure any callers can actually mount and modify the fs
    # if desired.
    # cros_make_image_bootable should restore the bit if needed.
    enable_rw_mount "${FLAGS_from}/${filename}" "$(( offset * 512 ))"
  fi

  if ! sudo mount ${safe_flag} -o loop,offset=$(( offset * 512 )) \
      "${FLAGS_from}/${filename}" "${FLAGS_rootfs_mountpt}" ; then
    error "mount failed: options=${safe_flag} offset=$(( offset * 512 ))" \
        "target=${FLAGS_rootfs_mountpt}"
    return 1
  fi

  # Mount the stateful partition using a loopback device.
  offset=$(partoffset "${FLAGS_from}/${filename}" ${NUM_STATEFUL})
  if ! sudo mount ${ro_flag} -o loop,offset=$(( offset * 512 )) \
      "${FLAGS_from}/${filename}" "${FLAGS_stateful_mountpt}" ; then
    error "mount failed: options=${ro_flag} offset=$(( offset * 512 ))" \
        "target=${FLAGS_stateful_mountpt}"
    return 1
  fi

  # Mount the esp partition using a loopback device.
  if [[ -n "${FLAGS_esp_mountpt}" ]]; then
    offset=$(partoffset "${FLAGS_from}/${filename}" ${NUM_ESP})
    if ! sudo mount ${ro_flag} -o loop,offset=$(( offset * 512 )) \
        "${FLAGS_from}/${filename}" "${FLAGS_esp_mountpt}" ; then
      error "mount failed: options=${ro_flag} offset=$(( offset * 512 ))" \
          "target=${FLAGS_esp_mountpt}"
      return 1
    fi
  fi
}

# Mount a gpt based image.
mount_image() {
  mkdir -p "${FLAGS_rootfs_mountpt}"
  mkdir -p "${FLAGS_stateful_mountpt}"
  if [[ -n "${FLAGS_esp_mountpt}" ]]; then
    mkdir -p "${FLAGS_esp_mountpt}"
  fi

  # Get the partitions for the image / device.
  if [ -b ${FLAGS_from} ] ; then
    get_usb_partitions
  elif ! get_gpt_partitions ; then
    echo "Current loopback device status:"
    sudo losetup --all | sed 's/^/    /'
    die "Failed to mount all partitions in ${FLAGS_from}/${FLAGS_image}"
  fi

  # Mount directories and setup symlinks.
  sudo mount --bind "${FLAGS_stateful_mountpt}/var_overlay" \
    "${FLAGS_rootfs_mountpt}/var"
  sudo mount --bind "${FLAGS_stateful_mountpt}/dev_image" \
    "${FLAGS_rootfs_mountpt}/usr/local"
  # Setup symlinks in /usr/local so you can emerge packages into /usr/local.

  if [ ${FLAGS_read_only} -eq ${FLAGS_FALSE} ]; then
    setup_symlinks_on_root "${FLAGS_stateful_mountpt}/dev_image" \
      "${FLAGS_stateful_mountpt}/var_overlay" "${FLAGS_stateful_mountpt}"
  fi
  info "Image specified by ${FLAGS_from} mounted at"\
    "${FLAGS_rootfs_mountpt} successfully."
}

# Turn paths into absolute paths.
FLAGS_from=`eval readlink -f ${FLAGS_from}`
FLAGS_rootfs_mountpt=`eval readlink -f ${FLAGS_rootfs_mountpt}`
FLAGS_stateful_mountpt=`eval readlink -f ${FLAGS_stateful_mountpt}`

# Perform desired operation.
if [ ${FLAGS_unmount} -eq ${FLAGS_TRUE} ] ; then
  unmount_image
else
  mount_image
fi
