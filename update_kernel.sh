#!/bin/bash

# Copyright (c) 2009-2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to update the kernel on a live running ChromiumOS instance.

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
. "${SCRIPT_ROOT}/common.sh" || { echo "Unable to load common.sh"; exit 1; }
# --- END COMMON.SH BOILERPLATE ---

. "${SCRIPT_ROOT}/remote_access.sh"

# Script must be run inside the chroot.
restart_in_chroot_if_needed "$@"

DEFINE_string board "" "Override board reported by target"
DEFINE_string device "" "Override boot device reported by target"
DEFINE_string partition "" "Override kernel partition reported by target"
DEFINE_string arch "" "Override architecture reported by target"
DEFINE_boolean reboot $FLAGS_TRUE "Reboot system after update"

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'set -e' is specified before now.
set -e

function cleanup {
  cleanup_remote_access
  rm -rf "${TMP}"
}

function learn_device() {
  [ -n "${FLAGS_device}" ] && return
  remote_sh df /mnt/stateful_partition
  FLAGS_device=$(echo "${REMOTE_OUT}" | awk '/dev/ {print $1}' | sed s/1\$//)
  info "Target reports root device is ${FLAGS_device}"
}

# Ask the target what the kernel partition is
function learn_partition_and_ro() {
  [ -n "${FLAGS_partition}" ] && return
  ! remote_sh rootdev
  if [ "${REMOTE_OUT}" == "/dev/dm-0" ]; then
    remote_sh ls /sys/block/dm-0/slaves
    REMOTE_OUT="/dev/${REMOTE_OUT}"
    REMOTE_VERITY=${FLAGS_TRUE}
    info "System is using verity: not updating firmware"
  else
    REMOTE_VERITY=${FLAGS_FALSE}
    info "System is not using verity: updating firmware and modules"
  fi
  if [ "${REMOTE_OUT}" == "${FLAGS_device}3" ]; then
    FLAGS_partition="${FLAGS_device}2"
  else
    FLAGS_partition="${FLAGS_device}4"
  fi
  if [ -z "${FLAGS_partition}" ]; then
    error "Partition required"
    exit 1
  fi
  info "Target reports kernel partition is ${FLAGS_partition}"
}

function make_kernelimage() {
  local bootloader_path
  local kernel_image
  if [[ "${FLAGS_arch}" == "arm" ]]; then
    name="bootloader.bin"
    bootloader_path="${SRC_ROOT}/build/images/${FLAGS_board}/latest/${name}"
    kernel_image="/build/${FLAGS_board}/boot/vmlinux.uimg"
  else
    bootloader_path="/lib64/bootstub/bootstub.efi"
    kernel_image="/build/${FLAGS_board}/boot/vmlinuz"
  fi
  vbutil_kernel --pack new_kern.bin \
    --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
    --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
    --version 1 \
    --config "${SRC_ROOT}/build/images/${FLAGS_board}/latest/config.txt" \
    --bootloader "${bootloader_path}" \
    --vmlinuz "${kernel_image}" \
    --arch "${FLAGS_arch}"
}

function copy_kernelimage() {
  if [ "${FLAGS_arch}" == "arm" -a ${REMOTE_VERITY} -eq ${FLAGS_FALSE} ]; then
    remote_cp_to /build/${FLAGS_board}/boot/vmlinux.uimg /boot
  fi

  remote_cp_to new_kern.bin /tmp

  remote_sh dd if=/tmp/new_kern.bin of="${FLAGS_partition}"
}

function main() {
  trap cleanup EXIT

  TMP=$(mktemp -d /tmp/image_to_live.XXXX)

  remote_access_init

  learn_arch

  learn_board

  learn_device

  learn_partition_and_ro

  remote_sh uname -r -v

  old_kernel="${REMOTE_OUT}"

  make_kernelimage

  if [[ ${REMOTE_VERITY} -eq ${FLAGS_FALSE} ]]; then
    tar -C /build/"${FLAGS_board}"/lib/modules -cjf /tmp/new_modules.tar .
    tar -C /build/"${FLAGS_board}"/lib/firmware -cjf /tmp/new_firmware.tar .

    remote_sh mount -o remount,rw /
    echo "copying modules"
    remote_cp_to /tmp/new_modules.tar /tmp/

    remote_sh tar -C /lib/modules -xjf /tmp/new_modules.tar

    echo "copying firmware"
    remote_cp_to /tmp/new_firmware.tar /tmp/

    remote_sh tar -C /lib/firmware -xjf /tmp/new_firmware.tar
  fi

  echo "copying kernel"

  copy_kernelimage

  if [ "${FLAGS_reboot}" -eq ${FLAGS_TRUE} ]; then
    echo "rebooting"

    remote_reboot

    remote_sh uname -r -v
    info "old kernel: ${old_kernel}"
    info "new kernel: ${REMOTE_OUT}"
  else
    info "Not rebooting (per request)"
  fi
}

main "$@"
