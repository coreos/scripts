#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Helper script to generate bootloader configuration files for systems
# that predate our new GRUB2 based gptprio bootloader.

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

# We're invoked only by build_image, which runs in the chroot
assert_inside_chroot

# Flags.
DEFINE_string boot_dir "/tmp/boot" \
  "Path to boot directory in root filesystem (Default: /tmp/boot)"

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
switch_to_strict_mode

# Common kernel command-line args
common_args="console=tty0 ro noswap cros_legacy"
common_args="${common_args} ${FLAGS_boot_args}"

# Filesystem command line args.
root_args="root=LABEL=ROOT rootflags=subvol=root"
slot_a_args="${root_args} usr=PARTLABEL=USR-A"
slot_b_args="${root_args} usr=PARTLABEL=USR-B"

GRUB_DIR="${FLAGS_boot_dir}/grub"
SYSLINUX_DIR="${FLAGS_boot_dir}/syslinux"

# Build configuration files for pygrub/pvgrub
configure_pvgrub() {
  info "Installing legacy PV-GRUB configuration"
  sudo mkdir -p "${GRUB_DIR}"

  # Add hvc0 for hypervisors
  grub_args="${common_args} console=hvc0"

  sudo_clobber "${GRUB_DIR}/menu.lst.A" <<EOF
timeout         0

title           CoreOS A Root
root            (hd0,0)
kernel          /syslinux/vmlinuz.A ${grub_args} ${slot_a_args}

title           CoreOS B Root
root            (hd0,0)
kernel          /syslinux/vmlinuz.B ${grub_args} ${slot_b_args}
EOF

  sudo_clobber "${GRUB_DIR}/menu.lst.B" <<EOF
default         1
$(< "${GRUB_DIR}/menu.lst.A")
EOF
}

# Build configuration files for syslinux
configure_syslinux() {
  info "Installing legacy SYSLINUX configuration"
  sudo mkdir -p "${SYSLINUX_DIR}"

  # Add ttyS0 as a secondary console, useful for qemu -nographic
  # This leaves /dev/console mapped to tty0 (vga) which is reasonable default.
  syslinux_args="console=ttyS0,115200n8 ${common_args}"

  sudo_clobber "${SYSLINUX_DIR}/default.cfg.A" <<<"DEFAULT coreos.A"
  sudo_clobber "${SYSLINUX_DIR}/default.cfg.B" <<<"DEFAULT coreos.B"

  sudo_clobber "${SYSLINUX_DIR}/root.A.cfg" <<EOF
label coreos.A
  menu label coreos.A
  kernel vmlinuz.A
  append ${syslinux_args} ${slot_a_args}
EOF

  sudo_clobber "${SYSLINUX_DIR}/root.B.cfg" <<EOF
label coreos.B
  menu label coreos.B
  kernel vmlinuz.B
  append ${syslinux_args} ${slot_b_args}
EOF
}

configure_pvgrub
configure_syslinux
