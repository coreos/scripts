#!/bin/bash

# Copyright (c) 2009-2010 The Chromium OS Authors. All rights reserved.
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
. "${SCRIPT_ROOT}/common.sh" || (echo "Unable to load common.sh" && exit 1)
# --- END COMMON.SH BOILERPLATE ---

. "${SCRIPT_ROOT}/remote_access.sh"

# Script must be run inside the chroot.
restart_in_chroot_if_needed "$@"

DEFINE_string board "" "Override board reported by target"
DEFINE_string device "" "Override boot device reported by target"
DEFINE_string partition "" "Override kernel partition reported by target"
DEFINE_string arch "" "Override architecture reported by target"
DEFINE_boolean modules false "Update modules on target"
DEFINE_boolean firmware false "Update firmware on target"

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
function learn_partition() {
  [ -n "${FLAGS_partition}" ] && return
  remote_sh cat /proc/cmdline
  if echo "${REMOTE_OUT}" | egrep -q "${FLAGS_device}3"; then
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

  if [[ "${FLAGS_arch}" == "arm" ]]; then
    ./build_kernel_image.sh --arch=arm \
    --root='/dev/${devname}${rootpart}' \
    --vmlinuz=/build/${FLAGS_board}/boot/vmlinux.uimg --to new_kern.bin
  else
    vbutil_kernel --pack new_kern.bin \
    --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
    --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
    --version 1 \
    --config ../build/images/${FLAGS_board}/latest/config.txt \
    --bootloader /lib64/bootstub/bootstub.efi \
    --vmlinuz /build/${FLAGS_board}/boot/vmlinuz
  fi
}

function main() {
  trap cleanup EXIT

  TMP=$(mktemp -d /tmp/image_to_live.XXXX)

  remote_access_init

  learn_arch

  learn_board

  learn_device

  learn_partition

  remote_sh uname -r -v

  old_kernel="${REMOTE_OUT}"

  make_kernelimage

  remote_cp_to new_kern.bin /tmp

  remote_sh dd if=/tmp/new_kern.bin of="${FLAGS_partition}"

  if [[ ${FLAGS_modules} -eq ${FLAGS_TRUE} ]]; then
    echo "copying modules"
    tar -C /build/"${FLAGS_board}"/lib/modules -cjf /tmp/new_modules.tar .

    remote_cp_to /tmp/new_modules.tar /tmp/

    remote_sh mount -o remount,rw /
    remote_sh tar -C /lib/modules -xjf /tmp/new_modules.tar
  fi

  if [[ ${FLAGS_firmware} -eq ${FLAGS_TRUE} ]]; then
    echo "copying firmware"
    tar -C /build/"${FLAGS_board}"/lib/firmware -cjf /tmp/new_firmware.tar .

    remote_cp_to /tmp/new_firmware.tar /tmp/

    remote_sh mount -o remount,rw /
    remote_sh tar -C /lib/firmware -xjf /tmp/new_firmware.tar
  fi

  remote_reboot

  remote_sh uname -r -v
  info "old kernel: ${old_kernel}"
  info "new kernel: ${REMOTE_OUT}"
}

main "$@"
