#!/bin/bash

# Copyright (c) 2014 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Replacement script for 'grub-install' which does not detect drives
# properly when partitions are mounted via individual loopback devices.

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

# We're invoked only by build_image, which runs in the chroot
assert_inside_chroot

# Flags.
DEFINE_string target "" \
  "The GRUB target to install such as i386-pc or x86_64-efi"
DEFINE_string esp_dir "" \
  "Path to EFI System partition mount point."
DEFINE_string disk_image "" \
  "The disk image containing the EFI System partition."

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
switch_to_strict_mode

# Our GRUB lives under coreos/grub so new pygrub versions cannot find grub.cfg
GRUB_DIR="coreos/grub/${FLAGS_target}"

# Assumes the ESP is the first partition, GRUB cannot search for it by type.
GRUB_PREFIX="(,gpt1)/coreos/grub"

# Modules required to find and read everything else from ESP
CORE_MODULES=( fat part_gpt gzio )

# Name of the core image, depends on target
CORE_NAME=

case "${FLAGS_target}" in
    i386-pc)
        CORE_MODULES+=( biosdisk )
        CORE_NAME="core.img"
        ;;
    x86_64-efi)
        CORE_NAME="core.efi"
        ;;
    *)
        die_notrace "Unknown GRUB target ${FLAGS_target}"
        ;;
esac

# In order for grub-setup-bios to properly detect the layout of the disk
# image it expects a normal partitioned block device. For most of the build
# disk_util maps individual loop devices to each partition in the image so
# the kernel can automatically detach the loop devices on unmount. When
# using a single loop device with partitions there is no such cleanup.
# That's the story of why this script has all this goo for loop and mount.
STAGE_DIR=
ESP_DIR=
LOOP_DEV=

cleanup() {
    if [[ -d "${STAGE_DIR}" ]]; then
        rm -rf "${STAGE_DIR}"
    fi
    if [[ -d "${ESP_DIR}" ]]; then
        if mountpoint -q "${ESP_DIR}"; then
            sudo umount "${ESP_DIR}"
        fi
        rm -rf "${ESP_DIR}"
    fi
    if [[ -b "${LOOP_DEV}" ]]; then
        sudo losetup --detach "${LOOP_DEV}"
    fi
}
trap cleanup EXIT

STAGE_DIR=$(mktemp --directory)
mkdir -p "${STAGE_DIR}/${GRUB_DIR}"

info "Compressing modules in ${GRUB_DIR}"
for file in "/usr/lib/grub/${FLAGS_target}"/*{.lst,.mod}; do
    out="${STAGE_DIR}/${GRUB_DIR}/${file##*/}"
    gzip --best --stdout "${file}" > "${out}"
done

info "Generating ${GRUB_DIR}/${CORE_NAME}"
grub-mkimage \
    --compression=auto \
    --format "${FLAGS_target}" \
    --prefix "${GRUB_PREFIX}" \
    --output "${STAGE_DIR}/${GRUB_DIR}/${CORE_NAME}" \
    "${CORE_MODULES[@]}"

info "Installing GRUB ${FLAGS_target} to ${FLAGS_disk_image##*/}"
LOOP_DEV=$(sudo losetup --find --show --partscan "${FLAGS_disk_image}")
ESP_DIR=$(mktemp --directory)

# work around slow/buggy udev, make sure the node is there before mounting
if [[ ! -b "${LOOP_DEV}p1" ]]; then
    # sleep a little just in case udev is ok but just not finished yet
    warn "loopback device node ${LOOP_DEV}p1 missing, waiting on udev..."
    sleep 0.5
    for (( i=0; i<5; i++ )); do
        if [[ -b "${LOOP_DEV}p1" ]]; then
            break
        fi
        warn "looback device node still ${LOOP_DEV}p1 missing, reprobing..."
        blockdev --rereadpt ${LOOP_DEV}
        sleep 0.5
    done
    if [[ ! -b "${LOOP_DEV}p1" ]]; then
        failboat "${LOOP_DEV}p1 where art thou? udev has forsaken us!"
    fi
fi

sudo mount -t vfat "${LOOP_DEV}p1" "${ESP_DIR}"
sudo cp -r "${STAGE_DIR}/." "${ESP_DIR}/."

# This script will get called a few times, no need to re-copy grub.cfg
if [[ ! -f "${ESP_DIR}/coreos/grub/grub.cfg" ]]; then
    info "Installing grub.cfg"
    sudo cp "${BUILD_LIBRARY_DIR}/grub.cfg" "${ESP_DIR}/coreos/grub/grub.cfg"
fi

# Now target specific steps to make the system bootable
case "${FLAGS_target}" in
    i386-pc)
        info "Installing MBR and the BIOS Boot partition."
        sudo cp "/usr/lib/grub/i386-pc/boot.img" "${ESP_DIR}/${GRUB_DIR}"
        sudo grub-bios-setup --device-map=/dev/null \
            --directory="${ESP_DIR}/${GRUB_DIR}" "${LOOP_DEV}"
        ;;
    x86_64-efi)
        info "Installing default x86_64 UEFI bootloader."
        sudo mkdir -p "${ESP_DIR}/EFI/boot"
        sudo cp "${STAGE_DIR}/${GRUB_DIR}/${CORE_NAME}" \
            "${ESP_DIR}/EFI/boot/bootx64.efi"
        ;;
esac

cleanup
trap - EXIT
command_completed
