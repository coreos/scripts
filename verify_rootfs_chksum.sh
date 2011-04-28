#!/bin/bash
#
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to verify integrity of root file system for a GPT-based image

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

# Load functions and constants for chromeos-install
[ -f /usr/lib/installer/chromeos-common.sh ] && \
  INSTALLER_ROOT=/usr/lib/installer || \
  INSTALLER_ROOT=$(dirname "$(readlink -f "$0")")

. "${INSTALLER_ROOT}/chromeos-common.sh" || \
  die "Unable to load chromeos-common.sh"

# Needed for partoffset and partsize calls
locate_gpt

# Script must be run inside the chroot.
restart_in_chroot_if_needed "$@"

DEFINE_string image "" "Device or an image path. Default: (empty)."

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

if [ -z $FLAGS_image ] ; then
  die "Use --from to specify a device or an image file."
fi

# Turn path into an absolute path.
FLAGS_image=$(eval readlink -f ${FLAGS_image})

# Abort early if we can't find the image
if [ ! -b ${FLAGS_image} ] && [ ! -f $FLAGS_image ] ; then
  die "No image found at $FLAGS_image"
fi

set -e

function get_partitions() {
  if [ -b ${FLAGS_image} ] ; then
    KERNEL_IMG=$(make_partition_dev "${FLAGS_image}" 2)
    ROOTFS_IMG=$(make_partition_dev "${FLAGS_image}" 3)
    return
  fi

  KERNEL_IMG=$(mktemp)
  ROOTFS_IMG=$(mktemp)
  local kernel_offset=$(partoffset "${FLAGS_image}" 2)
  local kernel_count=$(partsize "${FLAGS_image}" 2)
  local rootfs_offset=$(partoffset "${FLAGS_image}" 3)
  local rootfs_count=$(partsize "${FLAGS_image}" 3)

  # TODO(tgao): use loop device to save 1GB in temp space
  dd if="${FLAGS_image}" of=${KERNEL_IMG} bs=512 skip=${kernel_offset} \
      count=${kernel_count} &>/dev/null
  dd if="${FLAGS_image}" of=${ROOTFS_IMG} bs=512 skip=${rootfs_offset} \
      count=${rootfs_count} &>/dev/null
}

function cleanup() {
  for i in ${KERNEL_IMG} ${ROOTFS_IMG}; do
    if [ ! -b ${i} ]; then
      rm -f ${i}
    fi
  done
}

get_partitions

# Logic below extracted from src/platform/installer/chromeos-setimage
DUMP_KERNEL_CONFIG=/usr/bin/dump_kernel_config
KERNEL_CONFIG=$(sudo "${DUMP_KERNEL_CONFIG}" "${KERNEL_IMG}")
kernel_cfg="$(echo "${KERNEL_CONFIG}" | sed -e 's/.*dm="\([^"]*\)".*/\1/g' |
              cut -f2- -d,)"
rootfs_sectors=$(echo ${kernel_cfg} | cut -f2 -d' ')
verity_algorithm=$(echo ${kernel_cfg} | cut -f8 -d' ')

# Compute the rootfs hash tree
VERITY=/bin/verity
# First argument to verity is reserved/unused and MUST be 0
table="vroot none ro,"$(sudo "${VERITY}" create 0 \
        "${verity_algorithm}" \
        "${ROOTFS_IMG}" \
        $((rootfs_sectors / 8)) \
        /dev/null)

expected_hash=$(echo ${kernel_cfg} | cut -f9 -d' ')
generated_hash=$(echo ${table} | cut -f2- -d, | cut -f9 -d' ')

cleanup

if [ "${expected_hash}" != "${generated_hash}" ]; then
  warn "expected hash = ${expected_hash}"
  warn "actual hash = ${generated_hash}"
  die "Root filesystem has been modified unexpectedly!"
else
  info "Root filesystem checksum match!"
fi
