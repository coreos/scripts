#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Helper script to generate GRUB bootloader configuration files for
# x86 platforms.

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

# We're invoked only by build_image, which runs in the chroot
assert_inside_chroot

# Flags.
DEFINE_string arch "x86" \
  "The boot architecture: arm or x86. (Default: x86)"
DEFINE_string to "/tmp/boot" \
  "Path to populate with bootloader templates (Default: /tmp/boot)"
DEFINE_string usb_disk /dev/sdb3 \
  "Path syslinux should use to do a usb boot. Default: /dev/sdb3"
DEFINE_string boot_args "" \
  "Additional boot arguments to pass to the commandline (Default: '')"
DEFINE_boolean enable_bootcache ${FLAGS_FALSE} \
  "Default all bootloaders to NOT use boot cache."
DEFINE_boolean enable_rootfs_verification ${FLAGS_FALSE} \
  "Controls if verity is used for root filesystem checking (Default: false)"
DEFINE_integer verity_error_behavior 3 \
  "Verified boot error behavior [0: I/O errors, 1: reboot, 2: nothing] \
(Default: 3)"
DEFINE_integer verity_max_ios -1 \
  "Optional number of outstanding I/O operations. (Default: 1024)"

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
switch_to_strict_mode

# Useful for getting partition UUID values
. "${BUILD_LIBRARY_DIR}/disk_layout_util.sh" || exit 1

# Only let dm-verity block if rootfs verification is configured.
# Also, set which device mapper correspondes to verity
dev_wait=0
ROOTDEV=/dev/dm-0
if [[ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]]; then
  dev_wait=1
  if [[ ${FLAGS_enable_bootcache} -eq ${FLAGS_TRUE} ]]; then
    ROOTDEV=/dev/dm-1
  fi
fi

# Common kernel command-line args
common_args="init=/sbin/init console=tty0 boot=local rootwait ro noresume"
common_args="${common_args} noswap ${FLAGS_boot_args}"

# Common verified boot command-line args
verity_common="dm_verity.error_behavior=${FLAGS_verity_error_behavior}"
verity_common="${verity_common} dm_verity.max_bios=${FLAGS_verity_max_ios}"
# Ensure that dm-verity waits for its device.
# TODO(wad) should add a timeout that display a useful message
verity_common="${verity_common} dm_verity.dev_wait=${dev_wait}"

# Populate the x86 rootfs to support legacy and EFI bios config templates.
# The templates are used by the installer to populate partition 12 with
# the correct bootloader configuration.
if [[ "${FLAGS_arch}" = "x86" || "${FLAGS_arch}" = "amd64"  ]]; then
  sudo mkdir -p ${FLAGS_to}

  # Get partition UUIDs from the json config
  ROOTA="PARTUUID=$(get_uuid base ROOT-A)"
  ROOTB="PARTUUID=$(get_uuid base ROOT-B)"

  # Build configuration files for pygrub/pvgrub
  GRUB_DIR="${FLAGS_to}/boot/grub"
  sudo mkdir -p "${GRUB_DIR}"

  cat <<EOF | sudo dd of="${GRUB_DIR}/menu.lst.A" 2>/dev/null
timeout         0

title           CoreOS A
root            (hd0,0)
kernel          /syslinux/vmlinuz.A ${common_args} root=${ROOTA} cros_legacy

title           CoreOS B
root            (hd0,0)
kernel          /syslinux/vmlinuz.B ${common_args} root=${ROOTB} cros_legacy
EOF
  info "Emitted ${GRUB_DIR}/menu.lst.A"

  cat <<EOF | sudo dd of="${GRUB_DIR}/menu.lst.B" 2>/dev/null
default         1
EOF
  sudo sh -c "cat ${GRUB_DIR}/menu.lst.A >> ${GRUB_DIR}/menu.lst.B"
  info "Emitted ${GRUB_DIR}/menu.lst.B"

  sudo cp ${GRUB_DIR}/menu.lst.A ${GRUB_DIR}/menu.lst

  # /boot/syslinux must be installed in partition 12 as /syslinux/.
  SYSLINUX_DIR="${FLAGS_to}/syslinux"
  sudo mkdir -p "${SYSLINUX_DIR}"

  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/syslinux.cfg" 2>/dev/null
PROMPT 0
TIMEOUT 0

# the actual target
include /syslinux/default.cfg

# coreos.A
include /syslinux/root.A.cfg

# coreos.B
include /syslinux/root.B.cfg
EOF
  info "Emitted ${SYSLINUX_DIR}/syslinux.cfg"

  # To change the active target, only this file needs to change.
  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/default.cfg" 2>/dev/null
DEFAULT coreos.A
EOF
  info "Emitted ${SYSLINUX_DIR}/default.cfg"

  # Different files are used so that the updater can only touch the file it
  # needs to for a given change.  This will minimize any potential accidental
  # updates issues, hopefully.
  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/root.A.cfg" 2>/dev/null
label coreos.A
  menu label coreos.A
  kernel vmlinuz.A
  append ${common_args} root=${ROOTA} i915.modeset=1 cros_legacy
EOF
  info "Emitted ${SYSLINUX_DIR}/root.A.cfg"

  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/root.B.cfg" 2>/dev/null
label coreos.B
  menu label coreos.B
  kernel vmlinuz.B
  append ${common_args} root=${ROOTB} i915.modeset=1 cros_legacy
EOF
  info "Emitted ${SYSLINUX_DIR}/root.B.cfg"

  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/README" 2>/dev/null
Partition 12 contains the active bootloader configuration when
booting from a non-Chrome OS BIOS.  EFI BIOSes use /efi/*
and legacy BIOSes use this syslinux configuration.
EOF
  info "Emitted ${SYSLINUX_DIR}/README"

  # To cover all of our bases, now populate templated boot support for efi.
  sudo mkdir -p "${FLAGS_to}"/efi/boot

  if [[ -f /bin/grub2-mkimage ]];then
    # Use the newer grub2 1.99+
    sudo grub2-mkimage -p /efi/boot -O x86_64-efi \
     -o "${FLAGS_to}/efi/boot/bootx64.efi" \
     part_gpt fat ext2 hfs hfsplus normal boot chain configfile linux
  else
    # Remove this else case after a few weeks (sometime in Dec 2011)
    sudo grub-mkimage -p /efi/boot -o "${FLAGS_to}/efi/boot/bootx64.efi" \
     part_gpt fat ext2 normal boot sh chain configfile linux
  fi
  # Templated variables:
  #  DMTABLEA, DMTABLEB -> '0 xxxx verity ... '
  # This should be replaced during postinst when updating the ESP.
  cat <<EOF | sudo dd of="${FLAGS_to}/efi/boot/grub.cfg" 2>/dev/null
set default=0
set timeout=2

# NOTE: These magic grub variables are a Chrome OS hack. They are not portable.

menuentry "local image A" {
  linux \$grubpartA/boot/vmlinuz ${common_args} i915.modeset=1 cros_efi root=/dev/\$linuxpartA
}

menuentry "local image B" {
  linux \$grubpartB/boot/vmlinuz ${common_args} i915.modeset=1 cros_efi root=/dev/\$linuxpartB
}

menuentry "verified image A" {
  linux \$grubpartA/boot/vmlinuz ${common_args} ${verity_common} \
      i915.modeset=1 cros_efi root=${ROOTDEV} dm=\\"DMTABLEA\\"
}

menuentry "verified image B" {
  linux \$grubpartB/boot/vmlinuz ${common_args} ${verity_common} \
      i915.modeset=1 cros_efi root=${ROOTDEV} dm=\\"DMTABLEB\\"
}

# FIXME: usb doesn't support verified boot for now
menuentry "Alternate USB Boot" {
  linux (hd0,3)/boot/vmlinuz ${common_args} root=/dev/sdb3 i915.modeset=1 cros_efi
}
EOF
  if [[ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]]; then
    sudo sed -i -e 's/^set default=.*/set default=2/' \
       "${FLAGS_to}/efi/boot/grub.cfg"
  fi
  info "Emitted ${FLAGS_to}/efi/boot/grub.cfg"
  exit 0
fi

info "The target platform does not use bootloader templates."
