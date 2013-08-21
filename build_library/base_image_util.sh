# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. "${SRC_ROOT}/platform/dev/toolchain_utils.sh" || exit 1

# Overlays are parts of the disk that live on the stateful partition
ROOT_OVERLAYS=(var opt srv home usr/local)

cleanup_mounts() {
  local prev_ret=$?

  # Disable die on error.
  set +e

  # See if we ran out of space.  Only show if we errored out via a trap.
  if [[ ${prev_ret} -ne 0 ]]; then
    local df=$(df -B 1M "${root_fs_dir}")
    if [[ ${df} == *100%* ]]; then
      error "Here are the biggest files (by disk usage):"
      # Send final output to stderr to match `error` behavior.
      sudo find "${root_fs_dir}" -xdev -type f -printf '%b %P\n' | \
        awk '$1 > 16 { $1 = $1 * 512; print }' | sort -n | tail -100 1>&2
      error "Target image has run out of space:"
      error "${df}"
    fi
  fi

  echo "Cleaning up mounts"
  safe_umount_tree "${root_fs_dir}"
  safe_umount_tree "${stateful_fs_dir}"
  safe_umount_tree "${esp_fs_dir}"
  safe_umount_tree "${oem_fs_dir}"

   # Turn die on error back on.
  set -e
}

create_base_image() {
  local image_name=$1
  local rootfs_verification_enabled=$2
  local bootcache_enabled=$3
  local image_type="usb"

  if [[ "${FLAGS_disk_layout}" != "default" ]]; then
      image_type="${FLAGS_disk_layout}"
  else
    if should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
      image_type="factory_install"
    fi
  fi

  check_valid_layout "base"
  check_valid_layout ${image_type}

  info "Using image type ${image_type}"

  root_fs_dir="${BUILD_DIR}/rootfs"
  stateful_fs_dir="${BUILD_DIR}/stateful"
  esp_fs_dir="${BUILD_DIR}/esp"
  oem_fs_dir="${BUILD_DIR}/oem"

  trap "cleanup_mounts && delete_prompt" EXIT
  cleanup_mounts &> /dev/null

  local root_fs_label="ROOT-A"
  local root_fs_num=$(get_num ${image_type} ${root_fs_label})
  local root_fs_img="${BUILD_DIR}/rootfs.image"
  local root_fs_bytes=$(get_filesystem_size ${image_type} ${root_fs_num})

  local stateful_fs_label="STATE"
  local stateful_fs_num=$(get_num ${image_type} ${stateful_fs_label})
  local stateful_fs_img="${BUILD_DIR}/stateful.image"
  local stateful_fs_bytes=$(get_filesystem_size ${image_type} ${stateful_fs_num})
  local stateful_fs_uuid=$(uuidgen)

  local esp_fs_label="EFI-SYSTEM"
  local esp_fs_num=$(get_num ${image_type} ${esp_fs_label})
  local esp_fs_img="${BUILD_DIR}/esp.image"
  local esp_fs_bytes=$(get_filesystem_size ${image_type} ${esp_fs_num})

  local oem_fs_label="OEM"
  local oem_fs_num=$(get_num ${image_type} ${oem_fs_label})
  local oem_fs_img="${BUILD_DIR}/oem.image"
  local oem_fs_bytes=$(get_filesystem_size ${image_type} ${oem_fs_num})
  local oem_fs_uuid=$(uuidgen)

  local fs_block_size=$(get_fs_block_size)

  # Build root FS image.
  info "Building ${root_fs_img}"
  truncate --size="${root_fs_bytes}" "${root_fs_img}"
  /sbin/mkfs.ext2 -F -q -b ${fs_block_size} "${root_fs_img}" \
    "$((root_fs_bytes / fs_block_size))"
  /sbin/tune2fs -L "${root_fs_label}" \
               -U clear \
               -T 20091119110000 \
               -c 0 \
               -i 0 \
               -m 0 \
               -r 0 \
               -e remount-ro \
                "${root_fs_img}"
  mkdir -p "${root_fs_dir}"
  sudo mount -o loop "${root_fs_img}" "${root_fs_dir}"

  df -h "${root_fs_dir}"

  # Build stateful FS disk image.
  info "Building ${stateful_fs_img}"
  truncate --size="${stateful_fs_bytes}" "${stateful_fs_img}"
  /sbin/mkfs.ext4 -F -q "${stateful_fs_img}"
  /sbin/tune2fs -L "${stateful_fs_label}" -U "${stateful_fs_uuid}" \
               -c 0 -i 0 "${stateful_fs_img}"
  mkdir -p "${stateful_fs_dir}"
  sudo mount -o loop "${stateful_fs_img}" "${stateful_fs_dir}"

  # Build ESP disk image.
  info "Building ${esp_fs_img}"
  truncate --size="${esp_fs_bytes}" "${esp_fs_img}"
  /usr/sbin/mkfs.vfat "${esp_fs_img}"

  # Build OEM FS disk image.
  info "Building ${oem_fs_img}"
  truncate --size="${oem_fs_bytes}" "${oem_fs_img}"
  /sbin/mkfs.ext4 -F -q "${oem_fs_img}"
  /sbin/tune2fs -L "${oem_fs_label}" -U "${oem_fs_uuid}" \
               -c 0 -i 0 "${oem_fs_img}"
  mkdir -p "${oem_fs_dir}"
  sudo mount -o loop "${oem_fs_img}" "${oem_fs_dir}"

  # Prepare stateful partition with some pre-created directories.
  for i in ${ROOT_OVERLAYS}; do
    sudo mkdir -p "${stateful_fs_dir}/overlays/$i"
    sudo mkdir -p "${root_fs_dir}/$i"
    sudo mount --bind "${stateful_fs_dir}/overlays/$i" "${root_fs_dir}/$i"
  done

  sudo mkdir -p "${stateful_fs_dir}/overlays/usr/local"

  # Create symlinks so that /usr/local/usr based directories are symlinked to
  # /usr/local/ directories e.g. /usr/local/usr/bin -> /usr/local/bin, etc.
  setup_symlinks_on_root "${stateful_fs_dir}/overlays/usr/local" \
    "${stateful_fs_dir}/overlays/var" \
    "${stateful_fs_dir}"

  # Perform binding rather than symlinking because directories must exist
  # on rootfs so that we can bind at run-time since rootfs is read-only.
  info "Binding directories from stateful partition onto the rootfs"

  # Setup the dev image for developer tools
  sudo mkdir -p "${root_fs_dir}/usr/local"
  sudo mount --bind "${stateful_fs_dir}/overlays/usr/local" "${root_fs_dir}/usr/local"

  # TODO(bp): remove these temporary fixes for /mnt/stateful_partition going moving
  sudo mkdir -p "${root_fs_dir}/mnt/stateful_partition/"
  sudo ln -s /media/state/overlays/usr/local "${root_fs_dir}/mnt/stateful_partition/dev_image"
  sudo ln -s /media/state/overlays/home "${root_fs_dir}/mnt/stateful_partition/home"
  sudo ln -s /media/state/overlays/var "${root_fs_dir}/mnt/stateful_partition/var_overlay"
  sudo ln -s /media/state/etc "${root_fs_dir}/mnt/stateful_partition/etc"

  sudo mkdir -p "${root_fs_dir}/dev"

  info "Binding directories from OEM partition onto the rootfs"
  sudo mkdir -p "${root_fs_dir}/usr/share/oem"
  sudo mount --bind "${oem_fs_dir}" "${root_fs_dir}/usr/share/oem"

  # First thing first, install baselayout with USE=build to create a
  # working directory tree. Don't use binpkgs due to the use flag change.
  sudo -E USE=build ${EMERGE_BOARD_CMD} --root="${root_fs_dir}" \
      --usepkg=n --buildpkg=n --oneshot --quiet --nodeps sys-apps/baselayout

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

  # Strip out files we don't need in the final image at runtime.
  local libc_excludes=(
    # Compile-time headers.
    'usr/include' 'sys-include'
    # Link-time objects.
    '*.[ao]'
    # Empty lib dirs, replaced by symlinks
    'lib'
  )
  pbzip2 -dc --ignore-trailing-garbage=1 "${LIBC_PATH}" | \
    sudo tar xpf - -C "${root_fs_dir}" ./usr/${CHOST} \
      --strip-components=3 "${libc_excludes[@]/#/--exclude=}"

  board_ctarget=$(get_ctarget_from_board "${BOARD}")
  for atom in $(portageq match / cross-$board_ctarget/gcc); do
    copy_gcc_libs "${root_fs_dir}" $atom
  done

  if should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
    # Install our custom factory install kernel with the appropriate use flags
    # to the image.
    emerge_custom_kernel "${root_fs_dir}"
  fi

  # We "emerge --root=${root_fs_dir} --root-deps=rdeps --usepkgonly" all of the
  # runtime packages for chrome os. This builds up a chrome os image from
  # binary packages with runtime dependencies only.  We use INSTALL_MASK to
  # trim the image size as much as possible.
  emerge_to_image --root="${root_fs_dir}" ${BASE_PACKAGE}

  # Record directories installed to the stateful partition.
  sudo "${SCRIPTS_DIR}/gen_tmpfiles.py" --root="${root_fs_dir}" \
      --output="${root_fs_dir}/usr/lib/tmpfiles.d/base_image.conf" \
      "${root_fs_dir}/var"

  # Set /etc/lsb-release on the image.
  "${BUILD_LIBRARY_DIR}/set_lsb_release" \
  --root="${root_fs_dir}" \
  --board="${BOARD}"

  # Create the boot.desc file which stores the build-time configuration
  # information needed for making the image bootable after creation with
  # cros_make_image_bootable.
  create_boot_desc "${image_type}"

  # Populates the root filesystem with legacy bootloader templates
  # appropriate for the platform.  The autoupdater and installer will
  # use those templates to update the legacy boot partition (12/ESP)
  # on update.
  # (This script does not populate vmlinuz.A and .B needed by syslinux.)
  # Factory install shims may be booted from USB by legacy EFI BIOS, which does
  # not support verified boot yet (see create_legacy_bootloader_templates.sh)
  # so rootfs verification is disabled if we are building with --factory_install
  local enable_rootfs_verification=
  if [[ ${rootfs_verification_enabled} -eq ${FLAGS_TRUE} ]]; then
    enable_rootfs_verification="--enable_rootfs_verification"
  fi
  local enable_bootcache=
  if [[ ${bootcache_enabled} -eq ${FLAGS_TRUE} ]]; then
    enable_bootcache="--enable_bootcache"
  fi

  ${BUILD_LIBRARY_DIR}/create_legacy_bootloader_templates.sh \
    --arch=${ARCH} \
    --to="${root_fs_dir}"/boot \
    --boot_args="${FLAGS_boot_args}" \
      ${enable_rootfs_verification} \
      ${enable_bootcache}

  # Don't test the factory install shim
  if ! should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
    if [[ ${skip_test_image_content} -ne 1 ]]; then
      # Check that the image has been correctly created.
      test_image_content "$root_fs_dir"
    fi
  fi

  # Clean up symlinks so they work on a running target rooted at "/".
  # Here development packages are rooted at /usr/local.  However, do not
  # create /usr/local or /var on host (already exist on target).
  setup_symlinks_on_root "/usr/local" "/var" "${stateful_fs_dir}"

  # Zero all fs free space to make it more compressible so auto-update
  # payloads become smaller, not fatal since it won't work on linux < 3.2
  sudo fstrim "${root_fs_dir}" || true
  sudo fstrim "${stateful_fs_dir}" || true

  cleanup_mounts

  # Create the GPT-formatted image.
  build_gpt "${BUILD_DIR}/${image_name}" \
          "${root_fs_img}" \
          "${stateful_fs_img}" \
          "${esp_fs_img}" \
          "${oem_fs_img}"

  # Clean up temporary files.
  rm -f "${root_fs_img}" "${stateful_fs_img}" "${esp_fs_img}" "{oem_fs_img}"

  # Emit helpful scripts for testers, etc.
  emit_gpt_scripts "${BUILD_DIR}/${image_name}" "${BUILD_DIR}"

  USE_DEV_KEYS=
  if should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
    USE_DEV_KEYS="--use_dev_keys"
  fi

  if [[ ${skip_kernelblock_install} -ne 1 ]]; then
    # Place flags before positional args.
    ${SCRIPTS_DIR}/bin/cros_make_image_bootable "${BUILD_DIR}" \
      ${image_name} ${USE_DEV_KEYS} --adjust_part="${FLAGS_adjust_part}"
  fi
}
