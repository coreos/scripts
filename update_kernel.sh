#!/bin/bash

# Copyright (c) 2009-2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to update the kernel on a live running ChromiumOS instance.

SCRIPT_ROOT=$(dirname $(readlink -f "$0"))
. "${SCRIPT_ROOT}/common.sh" || exit 1
. "${SCRIPT_ROOT}/remote_access.sh" || exit 1

# Script must be run inside the chroot.
restart_in_chroot_if_needed "$@"

DEFINE_string board "" "Override board reported by target"
DEFINE_string device "" "Override boot device reported by target"
DEFINE_string partition "" "Override kernel partition reported by target"
DEFINE_string arch "" "Override architecture reported by target"
DEFINE_boolean reboot $FLAGS_TRUE "Reboot system after update"
DEFINE_boolean vboot $FLAGS_TRUE "Update the vboot kernel"

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'switch_to_strict_mode' is specified before now.
switch_to_strict_mode

cleanup() {
  cleanup_remote_access
  rm -rf "${TMP}"
}

learn_device() {
  [ -n "${FLAGS_device}" ] && return
  remote_sh df /mnt/stateful_partition
  FLAGS_device=$(echo "${REMOTE_OUT}" | awk '/dev/ {print $1}' | sed s/1\$//)
  info "Target reports root device is ${FLAGS_device}"
}

# Ask the target what the kernel partition is
learn_partition_and_ro() {
  [ -n "${FLAGS_partition}" ] && return
  ! remote_sh rootdev
  if [ "${REMOTE_OUT%%-*}" == "/dev/dm" ]; then
    remote_sh rootdev -s
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
    die "Partition required"
  fi
  if [ ${REMOTE_VERITY} -eq ${FLAGS_TRUE} ]; then
    info "Target reports kernel partition is ${FLAGS_partition}"
    if [ ${FLAGS_vboot} -eq ${FLAGS_FALSE} ]; then
      die "Must update vboot when target is using verity"
    fi
  fi
}

make_kernelimage() {
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
  vbutil_kernel --pack $TMP/new_kern.bin \
    --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
    --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
    --version 1 \
    --config "${SRC_ROOT}/build/images/${FLAGS_board}/latest/config.txt" \
    --bootloader "${bootloader_path}" \
    --vmlinuz "${kernel_image}" \
    --arch "${FLAGS_arch}"
}

copy_kernelimage() {
  remote_cp_to $TMP/new_kern.bin /tmp
  remote_sh dd if=/tmp/new_kern.bin of="${FLAGS_partition}"
}

check_kernelbuildtime() {
  local version=$(readlink "/build/${FLAGS_board}/boot/vmlinuz" | cut -d- -f2-)
  local build_dir="/build/${FLAGS_board}/lib/modules/${version}/build"
  if [ "${build_dir}/Makefile" -nt "/build/${FLAGS_board}/boot/vmlinuz" ]; then
    warn "Your build directory has been built more recently than"
    warn "the installed kernel being updated to.  Did you forget to"
    warn "run 'cros_workon_make chromeos-kernel --install'?"
  fi
}

main() {
  trap cleanup EXIT

  TMP=$(mktemp -d /tmp/update_kernel.XXXXXX)

  remote_access_init

  learn_arch

  learn_board

  learn_device

  learn_partition_and_ro

  remote_sh uname -r -v

  old_kernel="${REMOTE_OUT}"

  check_kernelbuildtime

  if [ ${FLAGS_vboot} -eq ${FLAGS_TRUE} ]; then
    make_kernelimage
  fi

  if [[ ${REMOTE_VERITY} -eq ${FLAGS_FALSE} ]]; then
    remote_sh mount -o remount,rw /
    echo "copying kernel"
    remote_send_to /build/"${FLAGS_board}"/boot/ /boot/

    # ARM does not have the syslinux directory, so skip it when the
    # partition or the syslinux vmlinuz target is missing.
    echo "updating syslinux kernel"
    remote_sh grep $(echo ${FLAGS_device}12 | cut -d/ -f3) /proc/partitions
    if [ $(echo "$REMOTE_OUT" | wc -l) -eq 1 ]; then
        remote_sh mkdir -p /tmp/12
        remote_sh mount ${FLAGS_device}12 /tmp/12

        if [ "$FLAGS_partition" = "${FLAGS_device}2" ]; then
            target="/tmp/12/syslinux/vmlinuz.A"
        else
            target="/tmp/12/syslinux/vmlinuz.B"
        fi
        remote_sh "test ! -f $target || cp /boot/vmlinuz $target"

        remote_sh umount /tmp/12
        remote_sh rmdir /tmp/12
    fi

    echo "copying modules"
    remote_send_to /build/"${FLAGS_board}"/lib/modules/ /lib/modules/

    echo "copying firmware"
    remote_send_to /build/"${FLAGS_board}"/lib/firmware/ /lib/firmware/
  fi

  if [ ${FLAGS_vboot} -eq ${FLAGS_TRUE} ]; then
    info "Copying vboot kernel image"
    copy_kernelimage
  else
    info "Skipping update of vboot (per request)"
  fi

  # An early kernel panic can prevent the normal sync on reboot.  Explicitly
  # sync for safety to avoid random file system corruption.
  remote_sh sync

  if [ ${FLAGS_reboot} -eq ${FLAGS_TRUE} ]; then
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
