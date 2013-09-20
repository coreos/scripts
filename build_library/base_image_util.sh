# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. "${SRC_ROOT}/platform/dev/toolchain_utils.sh" || exit 1

# Overlays are parts of the disk that live on the state partition
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
  safe_umount_tree "${state_fs_dir}"
  safe_umount_tree "${esp_fs_dir}"
  safe_umount_tree "${oem_fs_dir}"

   # Turn die on error back on.
  set -e
}

create_base_image() {
  local image_name=$1
  local rootfs_verification_enabled=$2
  local image_type="base"

  if [[ "${FLAGS_disk_layout}" != "default" ]]; then
      image_type="${FLAGS_disk_layout}"
  fi

  check_valid_layout "base"
  check_valid_layout ${image_type}

  info "Using image type ${image_type}"

  root_fs_dir="${BUILD_DIR}/rootfs"
  state_fs_dir="${BUILD_DIR}/state"
  esp_fs_dir="${BUILD_DIR}/esp"
  oem_fs_dir="${BUILD_DIR}/oem"

  trap "cleanup_mounts && delete_prompt" EXIT
  cleanup_mounts &> /dev/null

  local root_fs_label="ROOT-A"
  local root_fs_num=$(get_num ${image_type} ${root_fs_label})
  local root_fs_img="${BUILD_DIR}/rootfs.image"
  local root_fs_bytes=$(get_filesystem_size ${image_type} ${root_fs_num})

  local state_fs_label="STATE"
  local state_fs_num=$(get_num ${image_type} ${state_fs_label})
  local state_fs_img="${BUILD_DIR}/state.image"
  local state_fs_bytes=$(get_filesystem_size ${image_type} ${state_fs_num})
  local state_fs_uuid=$(uuidgen)

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

  # Build state FS disk image.
  info "Building ${state_fs_img}"
  truncate --size="${state_fs_bytes}" "${state_fs_img}"
  /sbin/mkfs.ext4 -F -q "${state_fs_img}"
  /sbin/tune2fs -L "${state_fs_label}" -U "${state_fs_uuid}" \
               -c 0 -i 0 "${state_fs_img}"
  mkdir -p "${state_fs_dir}"
  sudo mount -o loop "${state_fs_img}" "${state_fs_dir}"

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

  # Prepare state partition with some pre-created directories.
  info "Binding directories from state partition onto the rootfs"
  for i in "${ROOT_OVERLAYS[@]}"; do
    sudo mkdir -p "${state_fs_dir}/overlays/$i"
    sudo mkdir -p "${root_fs_dir}/$i"
    sudo mount --bind "${state_fs_dir}/overlays/$i" "${root_fs_dir}/$i"
  done

  # TODO(bp): remove these temporary fixes for /mnt/stateful_partition going moving
  sudo mkdir -p "${root_fs_dir}/mnt/stateful_partition/"
  sudo ln -s /media/state/overlays/usr/local "${root_fs_dir}/mnt/stateful_partition/dev_image"
  sudo ln -s /media/state/overlays/home "${root_fs_dir}/mnt/stateful_partition/home"
  sudo ln -s /media/state/overlays/var "${root_fs_dir}/mnt/stateful_partition/var_overlay"
  sudo ln -s /media/state/etc "${root_fs_dir}/mnt/stateful_partition/etc"

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
  lbzip2 -dc "${LIBC_PATH}" | \
    sudo tar xpf - -C "${root_fs_dir}" ./usr/${CHOST} \
      --strip-components=3 "${libc_excludes[@]/#/--exclude=}"

  board_ctarget=$(get_ctarget_from_board "${BOARD}")
  for atom in $(portageq match / cross-$board_ctarget/gcc); do
    copy_gcc_libs "${root_fs_dir}" $atom
  done

  # We "emerge --root=${root_fs_dir} --root-deps=rdeps --usepkgonly" all of the
  # runtime packages for chrome os. This builds up a chrome os image from
  # binary packages with runtime dependencies only.  We use INSTALL_MASK to
  # trim the image size as much as possible.
  emerge_to_image --root="${root_fs_dir}" ${BASE_PACKAGE}

  # Record directories installed to the state partition.
  # Ignore /var/tmp, systemd covers this entry.
  sudo "${BUILD_LIBRARY_DIR}/gen_tmpfiles.py" --root="${root_fs_dir}" \
      --output="${root_fs_dir}/usr/lib/tmpfiles.d/base_image.conf" \
      --ignore=/var/tmp "${root_fs_dir}/var"

  # Set /etc/lsb-release on the image.
  "${BUILD_LIBRARY_DIR}/set_lsb_release" \
  --root="${root_fs_dir}" \
  --board="${BOARD}"

  # Create the boot.desc file which stores the build-time configuration
  # information needed for making the image bootable after creation with
  # cros_make_image_bootable.
  create_boot_desc

  # Populates the root filesystem with legacy bootloader templates
  # appropriate for the platform.  The autoupdater and installer will
  # use those templates to update the legacy boot partition (12/ESP)
  # on update.
  local enable_rootfs_verification=
  if [[ ${rootfs_verification_enabled} -eq ${FLAGS_TRUE} ]]; then
    enable_rootfs_verification="--enable_rootfs_verification"
  fi

  ${BUILD_LIBRARY_DIR}/create_legacy_bootloader_templates.sh \
    --arch=${ARCH} \
    --to="${root_fs_dir}"/boot \
    --boot_args="${FLAGS_boot_args}" \
      ${enable_rootfs_verification}

  if [[ ${skip_test_image_content} -ne 1 ]]; then
    # Check that the image has been correctly created.
    test_image_content "$root_fs_dir"
  fi

  # Zero all fs free space to make it more compressible so auto-update
  # payloads become smaller, not fatal since it won't work on linux < 3.2
  sudo fstrim "${root_fs_dir}" || true
  sudo fstrim "${state_fs_dir}" || true

  cleanup_mounts

  # Create the GPT-formatted image.
  build_gpt "${BUILD_DIR}/${image_name}" \
          "${root_fs_img}" \
          "${state_fs_img}" \
          "${esp_fs_img}" \
          "${oem_fs_img}"

  # Clean up temporary files.
  rm -f "${root_fs_img}" "${state_fs_img}" "${esp_fs_img}" "{oem_fs_img}"

  # Emit helpful scripts for testers, etc.
  emit_gpt_scripts "${BUILD_DIR}/${image_name}" "${BUILD_DIR}"

  ${SCRIPTS_DIR}/bin/cros_make_image_bootable "${BUILD_DIR}" \
    ${image_name} --adjust_part="${FLAGS_adjust_part}"
}
