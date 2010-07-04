#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Helper script that generates the legacy/efi bootloader partitions.
# It does not populate the templates, but can update a loop device.

. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/chromeos-common.sh"  # installer

get_default_board

# Flags.
DEFINE_string arch "x86" \
  "The boot architecture: arm or x86. (Default: x86)"
# TODO(wad) once extlinux is dead, we can remove this.
DEFINE_boolean install_syslinux ${FLAGS_FALSE} \
  "Controls whether syslinux is run on 'to'. (Default: false)"
DEFINE_string from "/tmp/boot" \
  "Path the legacy bootloader templates are copied from. (Default /tmp/boot)"
DEFINE_string to "/tmp/esp.img" \
  "Path to esp image or ARM output MBR (Default: /tmp/esp.img)"
DEFINE_string vmlinuz "/tmp/vmlinuz" \
  "Path to the vmlinuz file to use (Default: /tmp/vmlinuz)"
# The kernel_partition and the kernel_cmdline each are used to supply
# verified boot configuration: dm="".
DEFINE_string kernel_partition "/tmp/vmlinuz.image" \
  "Path to the signed kernel image. (Default: /tmp/vmlinuz.image)"
DEFINE_string kernel_cmdline "" \
  "Kernel commandline if no kernel_partition given. (Default: '')"
DEFINE_string kernel_partition_offset "0" \
  "Offset to the kernel partition [KERN-A] (Default: 0)"
DEFINE_string kernel_partition_sectors "0" \
  "Kernel partition sectors (Default: 0)"
DEFINE_string usb_disk /dev/sdb3 \
  "Path syslinux should use to do a usb (or arm!) boot. Default: /dev/sdb3"

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
set -e

# If not provided by chromeos-common.sh, this will update all of the
# boot loader files (both A and B) with the data pulled
# from the kernel_partition.  The default boot target should
# be set when the rootfs is stuffed.
if ! type -p update_x86_bootloaders; then
  update_x86_bootloaders() {
    local old_root="$1"  # e.g., sd%D%P
    local kernel_cmdline="$2"
    local esp_fs_dir="$3"
    local template_dir="$4"

    # Pull out the dm="" values
    dm_table=
    if echo "$kernel_cmdline" | grep -q 'dm="'; then
      dm_table=$(echo "$kernel_cmdline" | sed -s 's/.*dm="\([^"]*\)".*/\1/')
    fi

    # Rewrite grub table
    grub_dm_table_a=${dm_table//${old_root}/\$linuxpartA}
    grub_dm_table_b=${dm_table//${old_root}/\$linuxpartB}
    sed -e "s|DMTABLEA|${grub_dm_table_a}|g" \
        -e "s|DMTABLEB|${grub_dm_table_b}|g" \
        "${template_dir}"/efi/boot/grub.cfg |
        sudo dd of="${esp_fs_dir}"/efi/boot/grub.cfg

    # Rewrite syslinux DM_TABLE
    usb_target="${FLAGS_usb_disk//\//\\\/}"
    syslinux_dm_table_usb=${dm_table//\/dev\/${old_root}/${usb_target}}
    sed -e "s|DMTABLEA|${syslinux_dm_table_usb}|g" \
        "${template_dir}"/syslinux/usb.A.cfg |
        sudo dd of="${esp_fs_dir}"/syslinux/usb.A.cfg

    syslinux_dm_table_a=${dm_table//\/dev\/${old_root}/HDROOTA}
    sed -e "s|DMTABLEA|${syslinux_dm_table_a}|g" \
        "${template_dir}"/syslinux/root.A.cfg |
        sudo dd of="${esp_fs_dir}"/syslinux/root.A.cfg

    syslinux_dm_table_b=${dm_table//\/dev\/${old_root}/HDROOTB}
    sed -e "s|DMTABLEA|${syslinux_dm_table_a}|g" \
        "${template_dir}"/syslinux/root.B.cfg |
        sudo dd of="${esp_fs_dir}"/syslinux/root.B.cfg

    # Copy the vmlinuz's into place for syslinux
    sudo cp -f "${template_dir}"/vmlinuz "${esp_fs_dir}"/syslinux/vmlinuz.A
    sudo cp -f "${template_dir}"/vmlinuz "${esp_fs_dir}"/syslinux/vmlinuz.B

    # The only work left for the installer is to pick the correct defaults
    # and replace HDROOTA and HDROOTB with the correct /dev/sd%D%P.
  }
fi

ESP_DEV=
if [[ ! -e "${FLAGS_to}" ]]; then
  error "The ESP doesn't exist"
  # This shouldn't happen.
  info "Creating a new esp image at ${FLAGS_to}" anyway.
  # Create EFI System Partition to boot stock EFI BIOS (but not ChromeOS EFI
  # BIOS). We only need this for x86, but it's simpler and safer to keep the
  # disk images the same for both x86 and ARM.
  # NOTE: The size argument for mkfs.vfat is in 1024-byte blocks.
  # We'll hard-code it to 16M for now.
  ESP_BLOCKS=16384
  /usr/sbin/mkfs.vfat -C "${FLAGS_to}" ${ESP_BLOCKS}
  ESP_DEV=$(sudo losetup -f)
  test -z "${ESP_DEV}" && error "No free loop devices."
  sudo losetup "${ESP_DEV}" "${FLAGS_to}"
else
  if [[ -f "${FLAGS_to}" ]]; then
    ESP_DEV=$(sudo losetup -f)
    test -z "${ESP_DEV}" && error "No free loop devices."
    sudo losetup "${ESP_DEV}" "${FLAGS_to}"
  else
    # If it is a block device or something else, try to mount it anyway.
    ESP_DEV="${FLAGS_to}"
  fi
fi

ESP_FS_DIR=$(mktemp -d /tmp/esp.XXXXXX)
cleanup() {
  set +e
  sudo umount "${ESP_FS_DIR}"
  if [[ -n "${ESP_DEV}" && -z "${ESP_DEV//\/dev\/loop*}" ]]; then
    sudo losetup -d  "${ESP_DEV}"
  fi
  rm -rf "${ESP_FS_DIR}"
}
trap cleanup EXIT
sudo mount "${ESP_DEV}" "${ESP_FS_DIR}"

if [[ "${FLAGS_arch}" = "x86" ]]; then
  # Populate the EFI bootloader configuration
  sudo mkdir -p "${ESP_FS_DIR}/efi/boot"
  sudo cp "${FLAGS_from}"/efi/boot/bootx64.efi \
          "${ESP_FS_DIR}/efi/boot/bootx64.efi"
  sudo cp "${FLAGS_from}/efi/boot/grub.cfg" \
          "${ESP_FS_DIR}/efi/boot/grub.cfg"

  # Prepopulate the syslinux directories too and update for verified boot values
  # after the rootfs work is done.
  sudo mkdir -p "${ESP_FS_DIR}"/syslinux
  sudo cp -r "${FLAGS_from}"/syslinux/. "${ESP_FS_DIR}"/syslinux

  # Stage both kernels with the only one we built.
  sudo cp -f "${FLAGS_vmlinuz}" "${ESP_FS_DIR}"/syslinux/vmlinuz.A
  sudo cp -f "${FLAGS_vmlinuz}" "${ESP_FS_DIR}"/syslinux/vmlinuz.B

  # Extract kernel flags
  kernel_cfg=
  old_root="sd%D%P"
  if [[ -n "${FLAGS_kernel_cmdline}" ]]; then
    info "Using supplied kernel_cmdline to update templates."
    kernel_cfg="${FLAGS_kernel_cmdline}"
  elif [[ -n "${FLAGS_kernel_partition}" ]]; then
    info "Extracting the kernel command line from ${FLAGS_kernel_partition}"
    kernel_cfg=$(dump_kernel_config "${FLAGS_kernel_partition}")
  fi
  update_x86_bootloaders "${old_root}" \
                         "${kernel_cfg}" \
                         "${ESP_FS_DIR}" \
                         "${FLAGS_from}"

  # Install the syslinux loader on the ESP image (part 12) so it is ready when
  # we cut over from rootfs booting (extlinux).
  if [[ ${FLAGS_install_syslinux} -eq ${FLAGS_TRUE} ]]; then
    sudo umount "${ESP_FS_DIR}"
    sudo syslinux -d /syslinux "${FLAGS_to}"
  fi
elif [[ "${FLAGS_arch}" = "arm" ]]; then
  # Extract kernel flags
  kernel_cfg=
  old_root="sd%D%P"
  if [[ -n "${FLAGS_kernel_cmdline}" ]]; then
    info "Using supplied kernel_cmdline to update templates."
    kernel_cfg="${FLAGS_kernel_cmdline}"
  elif [[ -n "${FLAGS_kernel_partition}" ]]; then
    info "Extracting the kernel command line from ${FLAGS_kernel_partition}"
    kernel_cfg=$(dump_kernel_config "${kernel_partition}")
  fi
  dm_table=
  if echo "$kernel_cfg" | grep -q 'dm="'; then
    dm_table=$(echo "$kernel_cfg" | sed -s 's/.*dm="\([^"]*\)".*/\1/')
  fi
  # TODO(wad) assume usb_disk contains the arm boot location for now.
  new_root="${FLAGS_usb_disk}"
  info "Replacing dm slave devices with /dev/${new_root}"
  dm_table="${dm_table//ROOT_DEV/\/dev\/${new_root}}"
  dm_table="${dm_table//HASH_DEV/\/dev\/${new_root}}"

  warn "FIXME: cannot replace root= here for the arm bootloader yet."
  dm_table=""  # TODO(wad) Clear it until we can fix root=/dev/dm-0

  local device=1
  local MBR_SCRIPT_UIMG=$(make_arm_mbr \
    ${FLAGS_kernel_partition_offset} \
    ${FLAGS_kernel_partition_sectors} \
    ${device} \
    "'dm=\"${dm_table}\"'")
  sudo dd bs=1 count=`stat --printf="%s" ${MBR_SCRIPT_UIMG}` \
     if="$MBR_SCRIPT_UIMG" of=${FLAGS_to}
  info "Emitted new ARM MBR to ${FLAGS_to}"
fi

set +e
