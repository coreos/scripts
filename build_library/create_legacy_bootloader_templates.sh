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

# Common kernel command-line args
common_args="console=tty0 ro noswap cros_legacy"
common_args="${common_args} ${FLAGS_boot_args}"

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

  # Add hvc0 for hypervisors
  grub_args="${common_args} console=hvc0"

  cat <<EOF | sudo dd of="${GRUB_DIR}/menu.lst.A" 2>/dev/null
timeout         0

title           CoreOS A Kernel
root            (hd0,0)
kernel          /syslinux/vmlinuz.A ${grub_args} root=gptprio:

title           CoreOS B Kernel
root            (hd0,0)
kernel          /syslinux/vmlinuz.B ${grub_args} root=gptprio:

title           CoreOS bootengine
root            (hd0,0)
kernel          /syslinux/vmlinuz-boot_kernel ${grub_args} root=gptprio:

title           CoreOS A Root Rescue
root            (hd0,0)
kernel          /syslinux/vmlinuz.A ${grub_args} root=${ROOTA}

title           CoreOS B Root Rescue
root            (hd0,0)
kernel          /syslinux/vmlinuz.B ${grub_args} root=${ROOTB}
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

  # Add ttyS0 as a secondary console, useful for qemu -nographic
  # This leaves /dev/console mapped to tty0 (vga) which is reasonable default.
  syslinux_args="console=ttyS0,115200n8 ${common_args}"

  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/syslinux.cfg" 2>/dev/null
SERIAL 0 115200
PROMPT 0
TIMEOUT 0
DEFAULT boot_kernel

include /syslinux/boot_kernel.cfg

# coreos.A
include /syslinux/root.A.cfg

# coreos.B
include /syslinux/root.B.cfg
EOF
  info "Emitted ${SYSLINUX_DIR}/syslinux.cfg"

  # Different files are used so that the updater can only touch the file it
  # needs to for a given change.  This will minimize any potential accidental
  # updates issues, hopefully.
  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/boot_kernel.cfg" 2>/dev/null
label boot_kernel
  menu label boot_kernel
  kernel vmlinuz-boot_kernel
  append ${syslinux_args} root=gptprio:
EOF
  info "Emitted ${SYSLINUX_DIR}/boot_kernel.cfg"
  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/root.A.cfg" 2>/dev/null
label coreos.A
  menu label coreos.A
  kernel vmlinuz.A
  append ${syslinux_args} root=${ROOTA}
EOF
  info "Emitted ${SYSLINUX_DIR}/root.A.cfg"

  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/root.B.cfg" 2>/dev/null
label coreos.B
  menu label coreos.B
  kernel vmlinuz.B
  append ${syslinux_args} root=${ROOTB}
EOF
  info "Emitted ${SYSLINUX_DIR}/root.B.cfg"

  exit 0
fi

info "The target platform does not use bootloader templates."
