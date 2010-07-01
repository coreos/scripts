#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Helper script that generates the signed kernel image

. "$(dirname "$0")/common.sh"

get_default_board

# Flags.
DEFINE_string arch "x86" \
  "The boot architecture: arm or x86. (Default: x86)"
DEFINE_string to "/tmp/vmlinuz.image" \
  "The path to the kernel image to be created. (Default: /tmp/vmlinuz.image)"
DEFINE_string vmlinuz "vmlinuz" \
  "The path to the kernel (Default: vmlinuz)"
DEFINE_string working_dir "/tmp/vmlinuz.working" \
  "Working directory for in-progress files. (Default: /tmp/vmlinuz.working)"
DEFINE_boolean keep_work ${FLAGS_FALSE} \
  "Keep temporary files (*.keyblock, *.vbpubk). (Default: false)"
DEFINE_string keys_dir "${SRC_ROOT}/platform/vboot_reference/tests/testkeys" \
  "Directory with the RSA signing keys. (Defaults to test keys)"
# Note, to enable verified boot, the caller would pass:
# --boot_args='dm="... /dev/sd%D%P /dev/sd%D%P ..." \
# --root=/dev/dm-0
DEFINE_string boot_args "noinitrd" \
  "Additional boot arguments to pass to the commandline (Default: noinitrd)"
DEFINE_string root "/dev/sd%D%P" \
  "Expected device root (Default: root=/dev/sd%D%P)"

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on error
set -e

# FIXME: At the moment, we're working on signed images for x86 only. ARM will
# support this before shipping, but at the moment they don't.
if [[ "${FLAGS_arch}" = "x86" ]]; then

# Legacy BIOS will use the kernel in the rootfs (via syslinux), as will
# standard EFI BIOS (via grub, from the EFI System Partition). Chrome OS
# BIOS will use a separate signed kernel partition, which we'll create now.
# FIXME: remove serial output, debugging messages.
mkdir -p ${FLAGS_working_dir}
cat <<EOF > "${FLAGS_working_dir}/config.txt"
earlyprintk=serial,ttyS0,115200
console=ttyS0,115200
init=/sbin/init
add_efi_memmap
boot=local
rootwait
root=${FLAGS_root}
ro
noresume
noswap
i915.modeset=1
loglevel=7
cros_secure
${FLAGS_boot_args}
EOF
WORK="${FLAGS_working_dir}/config.txt"


# FIX: The .vbprivk files are not encrypted, so we shouldn't just leave them
# lying around as a general thing.

# Wrap the kernel data keypair, used for the kernel body
vbutil_key \
  --pack "${FLAGS_working_dir}/kernel_data_key.vbpubk" \
  --key "${FLAGS_keys_dir}/key_rsa2048.keyb" \
  --version 1 \
  --algorithm 4
WORK="${WORK} ${FLAGS_working_dir}/kernel_data_key.vbpubk"

vbutil_key \
  --pack "${FLAGS_working_dir}/kernel_data_key.vbprivk" \
  --key "${FLAGS_keys_dir}/key_rsa2048.pem" \
  --algorithm 4
WORK="${WORK} ${FLAGS_working_dir}/kernel_data_key.vbprivk"


# Wrap the kernel subkey pair, used for the kernel's keyblock
vbutil_key \
  --pack "${FLAGS_working_dir}/kernel_subkey.vbpubk" \
  --key "${FLAGS_keys_dir}/key_rsa4096.keyb" \
  --version 1 \
  --algorithm 8
WORK="${WORK} ${FLAGS_working_dir}/kernel_subkey.vbpubk"

vbutil_key \
  --pack "${FLAGS_working_dir}/kernel_subkey.vbprivk" \
  --key "${FLAGS_keys_dir}/key_rsa4096.pem" \
  --algorithm 8
WORK="${WORK} ${FLAGS_working_dir}/kernel_subkey.vbprivk"


# Create the kernel keyblock, containing the kernel data key
vbutil_keyblock \
  --pack "${FLAGS_working_dir}/kernel.keyblock" \
  --datapubkey "${FLAGS_working_dir}/kernel_data_key.vbpubk" \
  --signprivate "${FLAGS_working_dir}/kernel_subkey.vbprivk" \
  --flags 15
WORK="${WORK} ${FLAGS_working_dir}/kernel.keyblock"

# Verify the keyblock.
vbutil_keyblock \
  --unpack "${FLAGS_working_dir}/kernel.keyblock" \
  --signpubkey "${FLAGS_working_dir}/kernel_subkey.vbpubk"

# TODO: We should sign the kernel blob using the recovery root key and recovery
# kernel data key instead (to create the recovery image), and then re-sign it
# this way for the install image. But we'll want to keep the install vblock
# separate, so we can just copy that part over separately when we install it
# instead of the whole kernel blob.

# Create and sign the kernel blob
vbutil_kernel \
  --pack "${FLAGS_to}" \
  --keyblock "${FLAGS_working_dir}/kernel.keyblock" \
  --signprivate "${FLAGS_working_dir}/kernel_data_key.vbprivk" \
  --version 1 \
  --config "${FLAGS_working_dir}/config.txt" \
  --bootloader /lib64/bootstub/bootstub.efi \
  --vmlinuz "${FLAGS_vmlinuz}"

# And verify it.
vbutil_kernel \
  --verify "${FLAGS_to}" \
  --signpubkey "${FLAGS_working_dir}/kernel_subkey.vbpubk"

else
  # FIXME: For now, ARM just uses the unsigned kernel by itself.
  cp -f "${FLAGS_vmlinuz}" "${FLAGS_to}"
fi

set +e  # cleanup failure is a-ok

if [[ ${FLAGS_keep_work} -eq ${FLAGS_FALSE} ]]; then
  echo "Cleaning up temporary files: ${WORK}"
  rm ${WORK}
  rmdir ${FLAGS_working_dir}
fi

echo "Kernel partition image emitted: ${FLAGS_to}"
