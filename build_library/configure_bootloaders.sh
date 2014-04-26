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
DEFINE_string boot_dir "/tmp/boot" \
  "Path to boot directory in root filesystem (Default: /tmp/boot)"
DEFINE_string esp_dir "" \
  "Path to ESP partition mount point (Default: none)"
DEFINE_string boot_args "" \
  "Additional boot arguments to pass to the commandline (Default: '')"
DEFINE_string disk_layout "base" \
  "The disk layout type to use for this image."

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
switch_to_strict_mode

# Common kernel command-line args
common_args="console=tty0 ro noswap cros_legacy"
common_args="${common_args} ${FLAGS_boot_args}"

# Get partition UUIDs from the json config
get_uuid() {
  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${FLAGS_disk_layout}" \
      readuuid "$1"
}

# Filesystem command line args.
root_args="root=LABEL=ROOT rootflags=subvol=root"
gptprio_args="${root_args} usr=gptprio:"
slot_a_args="${root_args} usr=PARTUUID=$(get_uuid USR-A)"
slot_b_args="${root_args} usr=PARTUUID=$(get_uuid USR-B)"

GRUB_DIR="${FLAGS_boot_dir}/grub"
SYSLINUX_DIR="${FLAGS_boot_dir}/syslinux"

# Build configuration files for pygrub/pvgrub
configure_grub() {
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
  info "Emitted ${GRUB_DIR}/menu.lst.A"

  sudo_clobber "${GRUB_DIR}/menu.lst.B" <<EOF
default         1
EOF
  sudo_append "${GRUB_DIR}/menu.lst.B" <"${GRUB_DIR}/menu.lst.A"
  info "Emitted ${GRUB_DIR}/menu.lst.B"
  sudo cp ${GRUB_DIR}/menu.lst.A ${GRUB_DIR}/menu.lst
}

# Build configuration files for syslinux
configure_syslinux() {
  sudo mkdir -p "${SYSLINUX_DIR}"

  # Add ttyS0 as a secondary console, useful for qemu -nographic
  # This leaves /dev/console mapped to tty0 (vga) which is reasonable default.
  syslinux_args="console=ttyS0,115200n8 ${common_args}"

  sudo_clobber "${SYSLINUX_DIR}/syslinux.cfg" <<EOF
SERIAL 0 115200
PROMPT 1
# display boot: prompt for a half second
TIMEOUT 5
# never sit at the prompt longer than a minute
TOTALTIMEOUT 600

# controls which kernel is the default
include /syslinux/default.cfg

include /syslinux/boot_kernel.cfg

# coreos.A
include /syslinux/root.A.cfg

# coreos.B
include /syslinux/root.B.cfg
EOF
  info "Emitted ${SYSLINUX_DIR}/syslinux.cfg"

  sudo_clobber "${SYSLINUX_DIR}/default.cfg" <<EOF
DEFAULT boot_kernel
EOF
  info "Emitted ${SYSLINUX_DIR}/default.cfg"

  sudo_clobber "${SYSLINUX_DIR}/default.cfg.A" <<EOF
DEFAULT coreos.A
EOF
  info "Emitted ${SYSLINUX_DIR}/default.cfg.A"

  sudo_clobber "${SYSLINUX_DIR}/default.cfg.B" <<EOF
DEFAULT coreos.B
EOF
  info "Emitted ${SYSLINUX_DIR}/default.cfg.B"

  # Different files are used so that the updater can only touch the file it
  # needs to for a given change.  This will minimize any potential accidental
  # updates issues, hopefully.
  sudo_clobber "${SYSLINUX_DIR}/boot_kernel.cfg" <<EOF
label boot_kernel
  menu label boot_kernel
  kernel vmlinuz-boot_kernel
  append ${syslinux_args} ${gptprio_args}
EOF
  info "Emitted ${SYSLINUX_DIR}/boot_kernel.cfg"

  sudo_clobber "${SYSLINUX_DIR}/root.A.cfg" <<EOF
label coreos.A
  menu label coreos.A
  kernel vmlinuz.A
  append ${syslinux_args} ${slot_a_args}
EOF
  info "Emitted ${SYSLINUX_DIR}/root.A.cfg"

  sudo_clobber "${SYSLINUX_DIR}/root.B.cfg" <<EOF
label coreos.B
  menu label coreos.B
  kernel vmlinuz.B
  append ${syslinux_args} ${slot_b_args}
EOF
  info "Emitted ${SYSLINUX_DIR}/root.B.cfg"
}

# Copy configurations to the ESP, this is what is actually used to boot
copy_to_esp() {
  if ! mountpoint -q "${FLAGS_esp_dir}"; then
    die "${FLAGS_esp_dir} is not a mount point."
  fi

  sudo mkdir -p "${FLAGS_esp_dir}"/{syslinux,boot/grub,EFI/boot}
  sudo cp -r "${GRUB_DIR}/." "${FLAGS_esp_dir}/boot/grub"
  sudo cp -r "${SYSLINUX_DIR}/." "${FLAGS_esp_dir}/syslinux"

  # Install UEFI bootloader
  sudo cp /usr/share/syslinux/efi64/ldlinux.e64 \
    "${FLAGS_esp_dir}/EFI/boot/ldlinux.e64"
  sudo cp /usr/share/syslinux/efi64/syslinux.efi \
    "${FLAGS_esp_dir}/EFI/boot/bootx64.efi"

  # Stage all kernels with the only one we built.
  for kernel in syslinux/{vmlinuz-boot_kernel,vmlinuz.A,vmlinuz.B}
  do
    sudo cp "${FLAGS_boot_dir}/vmlinuz" "${FLAGS_esp_dir}/${kernel}"
  done
}

if [[ "${FLAGS_arch}" = "x86" || "${FLAGS_arch}" = "amd64"  ]]; then
  configure_grub
  configure_syslinux
  if [[ -n "${FLAGS_esp_dir}" ]]; then
    copy_to_esp
  fi
else
  error "No bootloader configuration for ${FLAGS_arch}"
fi
