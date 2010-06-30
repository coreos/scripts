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
  "Directory with the signing keys. (Defaults to test keys)"
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

# Wrap the public keys with VbPublicKey headers.
vbutil_key \
  --pack \
  --in "${FLAGS_keys_dir}/key_rsa2048.keyb" \
  --version 1 \
  --algorithm 4 \
  --out "${FLAGS_working_dir}/key_alg4.vbpubk"
WORK="${WORK} ${FLAGS_working_dir}/key_alg4.vbpubk"

vbutil_key \
  --pack \
  --in "${FLAGS_keys_dir}/key_rsa4096.keyb" \
  --version 1 \
  --algorithm 8 \
  --out "${FLAGS_working_dir}/key_alg8.vbpubk"
WORK="${WORK} ${FLAGS_working_dir}/key_alg8.vbpubk"

vbutil_keyblock \
  --pack "${FLAGS_working_dir}/data4_sign8.keyblock" \
  --datapubkey "${FLAGS_working_dir}/key_alg4.vbpubk" \
  --signprivate "${FLAGS_keys_dir}/key_rsa4096.pem" \
  --algorithm 8 \
  --flags 15
WORK="${WORK} ${FLAGS_working_dir}/data4_sign8.keyblock"

# Verify the keyblock.
vbutil_keyblock \
  --unpack "${FLAGS_working_dir}/data4_sign8.keyblock" \
  --signpubkey "${FLAGS_working_dir}/key_alg8.vbpubk"

# Sign the kernel:
vbutil_kernel \
  --pack "${FLAGS_to}" \
  --keyblock "${FLAGS_working_dir}/data4_sign8.keyblock" \
  --signprivate "${FLAGS_keys_dir}/key_rsa2048.pem" \
  --version 1 \
  --config "${FLAGS_working_dir}/config.txt" \
  --bootloader /lib64/bootstub/bootstub.efi \
  --vmlinuz "${FLAGS_vmlinuz}"

# And verify it.
vbutil_kernel \
  --verify "${FLAGS_to}" \
  --signpubkey "${FLAGS_working_dir}/key_alg8.vbpubk"

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
