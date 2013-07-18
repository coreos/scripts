#!/bin/bash

# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Helper script that generates the legacy/efi bootloader partitions.
# It does not populate the templates, but can update a loop device.

SCRIPT_ROOT=$(dirname $(readlink -f "$0"))
. "${SCRIPT_ROOT}/common.sh" || exit 1

# Need to be inside the chroot to load chromeos-common.sh
assert_inside_chroot

# Load functions and constants for chromeos-install
. /usr/lib/installer/chromeos-common.sh || exit 1

# Flags.
DEFINE_string arch "x86" \
  "The boot architecture: arm or x86. (Default: x86)"
# TODO(wad) once extlinux is dead, we can remove this.
DEFINE_boolean install_syslinux ${FLAGS_TRUE} \
  "Controls whether syslinux is run on 'to'. (Default: true)"
DEFINE_string from "/tmp/boot" \
  "Path the legacy bootloader templates are copied from. (Default /tmp/boot)"
DEFINE_string to "/tmp/esp.img" \
  "Path to esp image (Default: /tmp/esp.img)"
DEFINE_integer to_offset 0 \
  "Offset in bytes into 'to' if it is a file (Default: 0)"
DEFINE_integer to_size -1 \
  "Size in bytes of 'to' to use if it is a file. -1 is ignored. (Default: -1)"
DEFINE_string vmlinuz "/tmp/vmlinuz" \
  "Path to the vmlinuz file to use (Default: /tmp/vmlinuz)"
DEFINE_string vmlinuz_boot_kernel "/tmp/vmlinuz-boot_kernel" \
  "Path to the vmlinuz-boot_kernel file to use (Default: /tmp/vmlinuz)"

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
switch_to_strict_mode

part_index_to_uuid() {
  local image="$1"
  local index="$2"
  cgpt show -i "$index" -u "$image"
}

ESP_DEV=
if [[ ! -e "${FLAGS_to}" ]]; then
  error "The ESP doesn't exist"
  # This shouldn't happen.
  info "Creating a new esp image at ${FLAGS_to}" anyway.
  # Create EFI System Partition to boot stock EFI BIOS (but not ChromeOS EFI
  # BIOS).  ARM uses this space to determine which partition is bootable.
  # NOTE: The size argument for mkfs.vfat is in 1024-byte blocks.
  # We'll hard-code it to 16M for now.
  ESP_BLOCKS=16384
  /usr/sbin/mkfs.vfat -C "${FLAGS_to}" ${ESP_BLOCKS}
  ESP_DEV=$(sudo losetup --show -f "${FLAGS_to}")
  if [ -z "${ESP_DEV}" ]; then
    die "No free loop devices."
  fi
else
  if [[ -f "${FLAGS_to}" ]]; then
    esp_offset="--offset ${FLAGS_to_offset}"
    esp_size="--sizelimit ${FLAGS_to_size}"
    if [ ${FLAGS_to_size} -lt 0 ]; then
      esp_size=
    fi
    ESP_DEV=$(sudo losetup --show -f ${esp_offset} ${esp_size} "${FLAGS_to}")
    if [ -z "${ESP_DEV}" ]; then
      die "No free loop devices."
    fi
  else
    # If it is a block device or something else, try to mount it anyway.
    ESP_DEV="${FLAGS_to}"
  fi
fi

ESP_FS_DIR=$(mktemp -d /tmp/esp.XXXXXX)
cleanup() {
  set +e
  if ! safe_umount "${ESP_FS_DIR}"; then
      # There is a race condition possible on some ubuntu setups
      # with mounting and unmounting a device very quickly
      # Doing a quick sleep/retry as a temporary workaround
      warn "Initial unmount failed. Possibly crosbug.com/23443. Retrying"
      sleep 5
      safe_umount "${ESP_FS_DIR}"
  fi
  if [[ -n "${ESP_DEV}" && -z "${ESP_DEV//\/dev\/loop*}" ]]; then
    sudo losetup -d  "${ESP_DEV}"
  fi
  rm -rf "${ESP_FS_DIR}"
}
trap cleanup EXIT
sudo mount "${ESP_DEV}" "${ESP_FS_DIR}"

if [[ "${FLAGS_arch}" = "x86" || "${FLAGS_arch}" = "amd64" ]]; then
  # Copy over the grub configurations for cloud machines and the
  # kernel into both the A and B slot
  sudo mkdir -p "${ESP_FS_DIR}"/boot/grub
  sudo cp -r "${FLAGS_from}"/boot/grub/. "${ESP_FS_DIR}"/boot/grub
  sudo cp -r "${FLAGS_from}"/boot/grub/menu.lst.A "${ESP_FS_DIR}"/boot/grub/menu.lst

  # Prepopulate the syslinux directories too and update for verified boot values
  # after the rootfs work is done.
  sudo mkdir -p "${ESP_FS_DIR}"/syslinux
  sudo cp -r "${FLAGS_from}"/syslinux/. "${ESP_FS_DIR}"/syslinux

  # Stage both kernels with the only one we built.
  sudo cp -f "${FLAGS_vmlinuz_boot_kernel}" "${ESP_FS_DIR}"/syslinux/vmlinuz-boot_kernel
  sudo cp -f "${FLAGS_vmlinuz}" "${ESP_FS_DIR}"/syslinux/vmlinuz.A
  sudo cp -f "${FLAGS_vmlinuz}" "${ESP_FS_DIR}"/syslinux/vmlinuz.B

  # Extract kernel flags
  kernel_cfg="cros_debug"
  old_root="%U+1"

  # Install the syslinux loader on the ESP image (part 12) so it is ready when
  # we cut over from rootfs booting (extlinux).
  if [[ ${FLAGS_install_syslinux} -eq ${FLAGS_TRUE} ]]; then
    safe_umount "${ESP_FS_DIR}"
    sudo syslinux -d /syslinux "${ESP_DEV}"
    # mount again for cleanup to free resource gracefully
    sudo mount -o ro "${ESP_DEV}" "${ESP_FS_DIR}"
  fi
elif [[ "${FLAGS_arch}" = "arm" ]]; then
  # Copy u-boot script to ESP partition
  if [ -r "${FLAGS_from}/boot-A.scr.uimg" ]; then
    sudo mkdir -p "${ESP_FS_DIR}/u-boot"
    sudo cp "${FLAGS_from}/boot-A.scr.uimg" \
      "${ESP_FS_DIR}/u-boot/boot.scr.uimg"
    sudo cp -f "${FLAGS_from}"/vmlinuz "${ESP_FS_DIR}"/vmlinuz.uimg.A
    sudo cp -f "${FLAGS_from}"/zImage "${ESP_FS_DIR}"/vmlinuz.A
  fi
fi

set +e
