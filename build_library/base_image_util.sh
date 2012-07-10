# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Shell function library and global variable initialization for
# creating an initial base image.  The main function for export in
# this library is 'create_base_image'; the remainder of the code is
# not used outside this file.


ROOT_LOOP_DEV=
STATEFUL_LOOP_DEV=

ROOT_FS_IMG="${BUILD_DIR}/rootfs.image"
STATEFUL_FS_IMG="${BUILD_DIR}/stateful_partition.image"
ESP_FS_IMG=${BUILD_DIR}/esp.image

cleanup_rootfs_loop() {
  sudo umount -d "${ROOT_FS_DIR}"
}

cleanup_stateful_fs_loop() {
  sudo umount "${ROOT_FS_DIR}/usr/local"
  sudo umount "${ROOT_FS_DIR}/var"
  sudo umount -d "${STATEFUL_FS_DIR}"
}

loopback_cleanup() {
  # Disable die on error.
  set +e

  if [[ -n "${STATEFUL_LOOP_DEV}" ]]; then
    cleanup_stateful_fs_loop
    STATEFUL_LOOP_DEV=
  fi

  if [[ -n "${ROOT_LOOP_DEV}" ]]; then
    cleanup_rootfs_loop
    ROOT_LOOP_DEV=
  fi

  # Turn die on error back on.
  set -e
}

zero_free_space() {
  local fs_mount_point=$1
  info "Zeroing freespace in ${fs_mount_point}"
  # dd is a silly thing and will produce a "No space left on device" message
  # that cannot be turned off and is confusing to unsuspecting victims.
  ( sudo dd if=/dev/zero of="${fs_mount_point}/filler" bs=4096 conv=fdatasync \
    || true ) 2>&1 | grep -v "No space left on device"
  sudo rm "${fs_mount_point}/filler"
}

# Takes as an arg the name of the image to be created.
create_base_image() {
  local image_name=$1

  trap "loopback_cleanup && delete_prompt" EXIT

  # Create and format the root file system.

  # Create root file system disk image.
  ROOT_SIZE_BYTES=$((1024 * 1024 * ${FLAGS_rootfs_size}))

  # Pad out for the hash tree.
  ROOT_HASH_PAD=$((FLAGS_rootfs_hash_pad * 1024 * 1024))
  info "Padding the rootfs image by ${ROOT_HASH_PAD} bytes for hash data"

  dd if=/dev/zero of="${ROOT_FS_IMG}" bs=1 count=1 \
     seek=$((ROOT_SIZE_BYTES + ROOT_HASH_PAD - 1))

  ROOT_LOOP_DEV=$(sudo losetup --show -f "${ROOT_FS_IMG}")
  if [ -z "${ROOT_LOOP_DEV}" ] ; then
    die_notrace \
        "No free loop device.  Free up a loop device or reboot.  exiting. "
  fi

  # Specify a block size and block count to avoid using the hash pad.
  sudo mkfs.ext2 -b 4096 "${ROOT_LOOP_DEV}" "$((ROOT_SIZE_BYTES / 4096))"

  # Tune and mount rootfs.
  DISK_LABEL="C-ROOT"
  # Disable checking and minimize metadata differences across builds
  # and wasted reserved space.
  sudo tune2fs -L "${DISK_LABEL}" \
               -U clear \
               -T 20091119110000 \
               -c 0 \
               -i 0 \
               -m 0 \
               -r 0 \
               -e remount-ro \
                "${ROOT_LOOP_DEV}"
  # TODO(wad) call tune2fs prior to finalization to set the mount count to 0.
  sudo mount -t ext2 "${ROOT_LOOP_DEV}" "${ROOT_FS_DIR}"

  # Create stateful partition of the same size as the rootfs.
  STATEFUL_SIZE_BYTES=$((1024 * 1024 * ${FLAGS_statefulfs_size}))
  dd if=/dev/zero of="${STATEFUL_FS_IMG}" bs=1 count=1 \
      seek=$((STATEFUL_SIZE_BYTES - 1))

  # Tune and mount the stateful partition.
  UUID=$(uuidgen)
  DISK_LABEL="C-STATE"
  STATEFUL_LOOP_DEV=$(sudo losetup --show -f "${STATEFUL_FS_IMG}")
  if [ -z "${STATEFUL_LOOP_DEV}" ] ; then
    die_notrace \
        "No free loop device.  Free up a loop device or reboot.  exiting. "
  fi
  sudo mkfs.ext4 "${STATEFUL_LOOP_DEV}"
  sudo tune2fs -L "${DISK_LABEL}" -U "${UUID}" -c 0 -i 0 "${STATEFUL_LOOP_DEV}"
  sudo mount -t ext4 "${STATEFUL_LOOP_DEV}" "${STATEFUL_FS_DIR}"

  # -- Install packages into the root file system --

  # Prepare stateful partition with some pre-created directories.
  sudo mkdir -p "${DEV_IMAGE_ROOT}"
  sudo mkdir -p "${STATEFUL_FS_DIR}/var_overlay"

  # Create symlinks so that /usr/local/usr based directories are symlinked to
  # /usr/local/ directories e.g. /usr/local/usr/bin -> /usr/local/bin, etc.
  setup_symlinks_on_root "${DEV_IMAGE_ROOT}" "${STATEFUL_FS_DIR}/var_overlay" \
    "${STATEFUL_FS_DIR}"

  # Perform binding rather than symlinking because directories must exist
  # on rootfs so that we can bind at run-time since rootfs is read-only.
  info "Binding directories from stateful partition onto the rootfs"
  sudo mkdir -p "${ROOT_FS_DIR}/usr/local"
  sudo mount --bind "${DEV_IMAGE_ROOT}" "${ROOT_FS_DIR}/usr/local"
  sudo mkdir -p "${ROOT_FS_DIR}/var"
  sudo mount --bind "${STATEFUL_FS_DIR}/var_overlay" "${ROOT_FS_DIR}/var"
  sudo mkdir -p "${ROOT_FS_DIR}/dev"

  # We need to install libc manually from the cross toolchain.
  # TODO: Improve this? It would be ideal to use emerge to do this.
  PKGDIR="/var/lib/portage/pkgs"
  LIBC_TAR="glibc-${LIBC_VERSION}.tbz2"
  LIBC_PATH="${PKGDIR}/cross-${CHOST}/${LIBC_TAR}"

  if ! [[ -e ${LIBC_PATH} ]]; then
    die_notrace \
      "${LIBC_PATH} does not exist. Try running ./setup_board" \
      "--board=${BOARD} to update the version of libc installed on that board."
  fi

  sudo tar jxpf "${LIBC_PATH}" -C "${ROOT_FS_DIR}" ./usr/${CHOST} \
    --strip-components=3 --exclude=usr/include --exclude=sys-include \
    --exclude=*.a --exclude=*.o

  . "${SRC_ROOT}/platform/dev/toolchain_utils.sh"
  board_ctarget=$(get_ctarget_from_board "${BOARD}")
  for atom in $(portageq match / cross-$board_ctarget/gcc); do
    copy_gcc_libs "${ROOT_FS_DIR}" $atom
  done

  if should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
    # Install our custom factory install kernel with the appropriate use flags
    # to the image.
    emerge_custom_kernel "${ROOT_FS_DIR}"
  fi

  # We "emerge --root=${ROOT_FS_DIR} --root-deps=rdeps --usepkgonly" all of the
  # runtime packages for chrome os. This builds up a chrome os image from
  # binary packages with runtime dependencies only.  We use INSTALL_MASK to
  # trim the image size as much as possible.
  emerge_to_image --root="${ROOT_FS_DIR}" chromeos ${EXTRA_PACKAGES}

  # Set /etc/lsb-release on the image.
  "${OVERLAY_CHROMEOS_DIR}/scripts/cros_set_lsb_release" \
    --root="${ROOT_FS_DIR}" \
    --board="${BOARD}"

  # Populates the root filesystem with legacy bootloader templates
  # appropriate for the platform.  The autoupdater and installer will
  # use those templates to update the legacy boot partition (12/ESP)
  # on update.
  # (This script does not populate vmlinuz.A and .B needed by syslinux.)
  # Factory install shims may be booted from USB by legacy EFI BIOS, which does
  # not support verified boot yet (see create_legacy_bootloader_templates.sh)
  # so rootfs verification is disabled if we are building with --factory_install
  local enable_rootfs_verification=
  if [[ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]]; then
    enable_rootfs_verification="--enable_rootfs_verification"
  fi

  ${BUILD_LIBRARY_DIR}/create_legacy_bootloader_templates.sh \
    --arch=${ARCH} \
    --to="${ROOT_FS_DIR}"/boot \
    --boot_args="${FLAGS_boot_args}" \
    ${enable_rootfs_verification}

  # Don't test the factory install shim
  if ! should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
    # Check that the image has been correctly created.
    test_image_content "$ROOT_FS_DIR"
  fi

  # Clean up symlinks so they work on a running target rooted at "/".
  # Here development packages are rooted at /usr/local.  However, do not
  # create /usr/local or /var on host (already exist on target).
  setup_symlinks_on_root "/usr/local" "/var" "${STATEFUL_FS_DIR}"

  # Create EFI System Partition to boot stock EFI BIOS (but not
  # ChromeOS EFI BIOS).  ARM uses this space to determine which
  # partition is bootable.  NOTE: The size argument for mkfs.vfat is
  # in 1024-byte blocks.  We'll hard-code it to 16M for now, unless
  # we are building a factory shim, in which case a larger room is
  # needed to allow two kernel blobs (each including initramfs) in
  # one EFI partition.
  if should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
    /usr/sbin/mkfs.vfat -C "${ESP_FS_IMG}" 32768
  else
    /usr/sbin/mkfs.vfat -C "${ESP_FS_IMG}" 16384
  fi

  # Zero rootfs free space to make it more compressible so auto-update
  # payloads become smaller
  zero_free_space "${ROOT_FS_DIR}"
  loopback_cleanup
  trap delete_prompt EXIT

  # Create the GPT-formatted image.
  build_gpt "${BUILD_DIR}/${image_name}" \
            "${ROOT_FS_IMG}" \
            "${STATEFUL_FS_IMG}" \
            "${ESP_FS_IMG}"
  # Clean up temporary files.
  rm -f "${ROOT_FS_IMG}" "${STATEFUL_FS_IMG}" "${ESP_FS_IMG}"

  # Emit helpful scripts for testers, etc.
  emit_gpt_scripts "${BUILD_DIR}/${image_name}" "${BUILD_DIR}"

  trap - EXIT

  USE_DEV_KEYS=
  if should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
    USE_DEV_KEYS="--use_dev_keys"
  fi

  # Place flags before positional args.
  if should_build_image ${image_name}; then
    ${SCRIPTS_DIR}/bin/cros_make_image_bootable "${BUILD_DIR}" \
                                                ${image_name} \
                                                ${USE_DEV_KEYS}
  fi

  # Setup hybrid MBR if it was enabled
  if [[ ${FLAGS_hybrid_mbr} -eq ${FLAGS_TRUE} ]]; then
    install_hybrid_mbr "${BUILD_DIR}/${image_name}"
  fi
}
