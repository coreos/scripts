#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Helper script that generates the signed kernel image

# --- BEGIN COMMON.SH BOILERPLATE ---
# Load common CrOS utilities.  Inside the chroot this file is installed in
# /usr/lib/crosutils.  Outside the chroot we find it relative to the script's
# location.
find_common_sh() {
  local common_paths=(/usr/lib/crosutils $(dirname "$(readlink -f "$0")"))
  local path

  SCRIPT_ROOT=
  for path in "${common_paths[@]}"; do
    if [ -r "${path}/common.sh" ]; then
      SCRIPT_ROOT=${path}
      break
    fi
  done
}

find_common_sh
. "${SCRIPT_ROOT}/common.sh" || (echo "Unable to load common.sh" && exit 1)
# --- END COMMON.SH BOILERPLATE ---

get_default_board

# Flags.
DEFINE_string arch "x86" \
  "The boot architecture: arm or x86. (Default: x86)"
DEFINE_string to "/tmp/vmlinuz.image" \
  "The path to the kernel image to be created. (Default: /tmp/vmlinuz.image)"
DEFINE_string hd_vblock "/tmp/vmlinuz_hd.vblock" \
  "The path to the installed kernel's vblock (Default: /tmp/vmlinuz_hd.vblock)"
DEFINE_string vmlinuz "vmlinuz" \
  "The path to the kernel (Default: vmlinuz)"
DEFINE_string working_dir "/tmp/vmlinuz.working" \
  "Working directory for in-progress files. (Default: /tmp/vmlinuz.working)"
DEFINE_boolean keep_work ${FLAGS_FALSE} \
  "Keep temporary files (*.keyblock, *.vbpubk). (Default: false)"
DEFINE_string keys_dir "${SRC_ROOT}/platform/vboot_reference/tests/testkeys" \
  "Directory with the RSA signing keys. (Defaults to test keys)"
DEFINE_boolean use_dev_keys ${FLAGS_FALSE} \
  "Use developer keys for signing. (Default: false)"
# Note, to enable verified boot, the caller would manually pass:
# --boot_args='dm="... %U+1 %U+1 ..." \
# --root=/dev/dm-0
DEFINE_string boot_args "noinitrd" \
  "Additional boot arguments to pass to the commandline (Default: noinitrd)"
# By default, we use a firmware enumerated value, but it isn't reliable for
# production use.  If +%d can be added upstream, then we can use:
#   root=PARTUID=uuid+1
DEFINE_string root "/dev/sd%D%P" \
  "Expected device root partition"
# If provided, will automatically add verified boot arguments.
DEFINE_string rootfs_image "" \
  "Optional path to the rootfs device or image.(Default: \"\")"
DEFINE_string rootfs_hash "" \
  "Optional path to output the rootfs hash to. (Default: \"\")"
DEFINE_integer verity_error_behavior 2 \
  "Verified boot error behavior [0: I/O errors, 1: reboot, 2: nothing] \
(Default: 2)"
DEFINE_integer verity_max_ios -1 \
  "Optional number of outstanding I/O operations. (Default: -1)"
DEFINE_string verity_hash_alg "sha1" \
  "Cryptographic hash algorithm used for dm-verity. (Default: sha1)"

# TODO(clchiou): Remove this flag after arm verified boot is stable
DEFINE_boolean crosbug12352_arm_kernel_signing ${FLAGS_TRUE} \
  "Sign kernel partition for ARM images (temporary hack)."

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on error
set -e

verity_args=
# Even with a rootfs_image, root= is not changed unless specified.
if [[ -n "${FLAGS_rootfs_image}" && -n "${FLAGS_rootfs_hash}" ]]; then
  # Gets the number of blocks. 4096 byte blocks _are_ expected.
  root_fs_blocks=$(sudo dumpe2fs "${FLAGS_rootfs_image}" 2> /dev/null |
                   grep "Block count" |
                   tr -d ' ' |
                   cut -f2 -d:)
  root_fs_block_sz=$(sudo dumpe2fs "${FLAGS_rootfs_image}" 2> /dev/null |
                     grep "Block size" |
                     tr -d ' ' |
                     cut -f2 -d:)
  info "rootfs is ${root_fs_blocks} blocks of ${root_fs_block_sz} bytes"
  if [[ ${root_fs_block_sz} -ne 4096 ]]; then
    error "Root file system blocks are not 4k!"
  fi

  info "Generating root fs hash tree."
  # Runs as sudo in case the image is a block device.
  # First argument to verity is reserved/unused and MUST be 0
  table=$(sudo verity create 0 \
                        ${FLAGS_verity_hash_alg} \
                        ${FLAGS_rootfs_image} \
                        ${root_fs_blocks} \
                        ${FLAGS_rootfs_hash})
  if [[ -f "${FLAGS_rootfs_hash}" ]]; then
    sudo chmod a+r "${FLAGS_rootfs_hash}"
  fi
  # Don't claim the root device unless the root= flag is pointed to
  # the verified boot device.  Doing so will claim /dev/sdDP out from
  # under the system.
  if [[ ${FLAGS_root} = "/dev/dm-0" ]]; then
    if [[ "${FLAGS_arch}" = "x86" ]]; then
      base_root='%U+1'  # kern_guid + 1
    elif [[ "${FLAGS_arch}" = "arm" ]]; then
      base_root='/dev/${devname}${rootpart}'
    fi
    table=${table//HASH_DEV/${base_root}}
    table=${table//ROOT_DEV/${base_root}}
  fi
  verity_args="dm=\"vroot none ro,${table}\""
  info "dm-verity configuration: ${verity_args}"
fi

mkdir -p "${FLAGS_working_dir}"

# Only let dm-verity block if rootfs verification is configured.
dev_wait=0
if [[ ${FLAGS_root} = "/dev/dm-0" ]]; then
  dev_wait=1
fi

cat <<EOF > "${FLAGS_working_dir}/boot.config"
root=${FLAGS_root}
rootwait
ro
dm_verity.error_behavior=${FLAGS_verity_error_behavior}
dm_verity.max_bios=${FLAGS_verity_max_ios}
dm_verity.dev_wait=${dev_wait}
${verity_args}
${FLAGS_boot_args}
EOF

WORK="${WORK} ${FLAGS_working_dir}/boot.config"
info "Emitted cross-platform boot params to ${FLAGS_working_dir}/boot.config"

if [[ "${FLAGS_arch}" = "x86" ]]; then
  # Legacy BIOS will use the kernel in the rootfs (via syslinux), as will
  # standard EFI BIOS (via grub, from the EFI System Partition). Chrome OS
  # BIOS will use a separate signed kernel partition, which we'll create now.
  # FIXME: remove serial output, debugging messages.
  cat <<EOF | cat - "${FLAGS_working_dir}/boot.config" \
    > "${FLAGS_working_dir}/config.txt"
quiet
loglevel=1
console=tty2
init=/sbin/init
add_efi_memmap
boot=local
noresume
noswap
i915.modeset=1
cros_secure
kern_guid=%U
tpm_tis.force=1
tpm_tis.interrupts=0
nmi_watchdog=panic,lapic
EOF
  WORK="${WORK} ${FLAGS_working_dir}/config.txt"

  bootloader_path="/lib64/bootstub/bootstub.efi"
  kernel_image="${FLAGS_vmlinuz}"

  sign_the_kernel=${FLAGS_TRUE}
elif [[ "${FLAGS_arch}" = "arm" ]]; then
  cat <<EOF | cat - "${FLAGS_working_dir}/boot.config" \
    > "${FLAGS_working_dir}/config.txt"
earlyprintk
kern_guid=%U
EOF
  WORK="${WORK} ${FLAGS_working_dir}/config.txt"

  kernel_script="${FLAGS_working_dir}/kernel.scr"
  kernel_script_img="${FLAGS_working_dir}/kernel.scr.uimg"

  echo -n 'setenv bootargs ${bootargs} ' > "${kernel_script}"
  tr '\n' ' ' < "${FLAGS_working_dir}/boot.config" >> "${kernel_script}"
  echo >> "${kernel_script}"

  mkimage -A arm -O linux -T script -C none -a 0 -e 0 \
    -n kernel_script -d "${kernel_script}" "${kernel_script_img}"

  WORK="${WORK} ${kernel_script} ${kernel_script_img}"

  bootloader_path="${kernel_script_img}"
  kernel_image="${FLAGS_vmlinuz/vmlinuz/vmlinux.uimg}"

  sign_the_kernel=${FLAGS_crosbug12352_arm_kernel_signing}
else
  error "Unknown arch: ${FLAGS_arch}"
fi

if [[ "${sign_the_kernel}" -eq "${FLAGS_TRUE}" ]]; then
  # We sign the image with the recovery_key, because this is what goes onto the
  # USB key. We can only boot from the USB drive in recovery mode.
  # For dev install shim, we need to use the installer keyblock instead of
  # the recovery keyblock because of the difference in flags.
  if [ ${FLAGS_use_dev_keys} -eq ${FLAGS_TRUE} ]; then
    USB_KEYBLOCK=installer_kernel.keyblock
    info "DEBUG: use dev install signing key"
  else
    USB_KEYBLOCK=recovery_kernel.keyblock
    info "DEBUG: use recovery signing key"
  fi

  # Create and sign the kernel blob
  vbutil_kernel \
    --pack "${FLAGS_to}" \
    --keyblock "${FLAGS_keys_dir}/${USB_KEYBLOCK}" \
    --signprivate "${FLAGS_keys_dir}/recovery_kernel_data_key.vbprivk" \
    --version 1 \
    --config "${FLAGS_working_dir}/config.txt" \
    --bootloader "${bootloader_path}" \
    --vmlinuz "${kernel_image}" \
    --arch "${FLAGS_arch}"

  # And verify it.
  vbutil_kernel \
    --verify "${FLAGS_to}" \
    --signpubkey "${FLAGS_keys_dir}/recovery_key.vbpubk"


  # Now we re-sign the same image using the normal keys. This is the kernel
  # image that is put on the hard disk by the installer. Note: To save space on
  # the USB image, we're only emitting the new verfication block, and the
  # installer just replaces that part of the hard disk's kernel partition.
  vbutil_kernel \
    --repack "${FLAGS_hd_vblock}" \
    --vblockonly \
    --keyblock "${FLAGS_keys_dir}/kernel.keyblock" \
    --signprivate "${FLAGS_keys_dir}/kernel_data_key.vbprivk" \
    --oldblob "${FLAGS_to}"


  # To verify it, we have to replace the vblock from the original image.
  tempfile=$(mktemp)
  trap "rm -f $tempfile" EXIT
  cat "${FLAGS_hd_vblock}" > $tempfile
  dd if="${FLAGS_to}" bs=65536 skip=1 >> $tempfile

  vbutil_kernel \
    --verify $tempfile \
    --signpubkey "${FLAGS_keys_dir}/kernel_subkey.vbpubk"

  rm -f $tempfile
  trap - EXIT

else
  # FIXME: This stuff is unsigned. This part should be removed or made
  # non-default after ARM verified boot is stable.

  kernel_size=$((($(stat -c %s "${kernel_image}") + 511) / 512))
  script_size=16

  # Add more scripts to boot script image for loading kernel image
  printf 'read ${devtype} ${devnum}:${kernelpart} ${loadaddr} %x %x\n' \
    ${script_size} ${kernel_size} >> "${kernel_script}"
  echo 'bootm ${loadaddr}' >> ${kernel_script}
  mkimage -A arm -O linux -T script -C none -a 0 -e 0 \
    -n kernel_script -d "${kernel_script}" "${kernel_script_img}"

  if [ $(stat -c %s "${kernel_script_img}") -gt $((512 * ${script_size})) ]
  then
    echo 'Kernel script too large for reserved space.'
    exit 1
  fi

  # Assemble image
  rm -f "${FLAGS_to}"
  dd if="${kernel_script_img}" of="${FLAGS_to}" bs=512 count="${script_size}"
  dd if="${kernel_image}" of="${FLAGS_to}" bs=512 seek="${script_size}"

  # TODO: HACK: Until the kernel partition contains a signed image, create a
  # phony hd.vblock to keep chromeos-install and cros_generate_update_payload
  # working.
  dd if="${FLAGS_to}" of="${FLAGS_hd_vblock}" bs=64K count=1
fi

set +e  # cleanup failure is a-ok

if [[ ${FLAGS_keep_work} -eq ${FLAGS_FALSE} ]]; then
  info "Cleaning up temporary files: ${WORK}"
  rm ${WORK}
  rmdir ${FLAGS_working_dir}
fi

info "Kernel partition image emitted: ${FLAGS_to}"

if [[ -f ${FLAGS_rootfs_hash} ]]; then
  info "Root filesystem hash emitted: ${FLAGS_rootfs_hash}"
fi
