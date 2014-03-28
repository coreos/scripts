# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

start_image() {
  local image_name=$1
  local disk_layout=$2
  local root_fs_dir=$3

  local disk_img="${BUILD_DIR}/${image_name}"

  info "Using image type ${disk_layout}"
  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      format "${disk_img}"

  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      mount "${disk_img}" "${root_fs_dir}"
  trap "cleanup_mounts '${root_fs_dir}' && delete_prompt" EXIT

  # First thing first, install baselayout with USE=build to create a
  # working directory tree. Don't use binpkgs due to the use flag change.
  sudo -E USE=build "emerge-${BOARD}" --root="${root_fs_dir}" \
      --usepkg=n --buildpkg=n --oneshot --quiet --nodeps sys-apps/baselayout

  # FIXME(marineam): Work around glibc setting EROOT=$ROOT
  # https://bugs.gentoo.org/show_bug.cgi?id=473728#c12
  sudo mkdir -p "${root_fs_dir}/etc/ld.so.conf.d"
}

finish_image() {
  local disk_layout=$1
  local root_fs_dir=$2
  local update_group=$3

  # Record directories installed to the state partition.
  # Explicitly ignore entries covered by existing configs.
  local tmp_ignore=$(awk '/^[dDfFL]/ {print "--ignore=" $2}' \
      "${root_fs_dir}"/usr/lib/tmpfiles.d/*.conf)
  sudo "${BUILD_LIBRARY_DIR}/gen_tmpfiles.py" --root="${root_fs_dir}" \
      --output="${root_fs_dir}/usr/lib/tmpfiles.d/base_image_var.conf" \
      ${tmp_ignore} "${root_fs_dir}/var"
  sudo "${BUILD_LIBRARY_DIR}/gen_tmpfiles.py" --root="${root_fs_dir}" \
      --output="${root_fs_dir}/usr/lib/tmpfiles.d/base_image_etc.conf" \
      ${tmp_ignore} "${root_fs_dir}/etc"

  # Set /etc/lsb-release on the image.
  "${BUILD_LIBRARY_DIR}/set_lsb_release" \
    --root="${root_fs_dir}" \
    --group="${update_group}" \
    --board="${BOARD}"

  ${BUILD_LIBRARY_DIR}/configure_bootloaders.sh \
    --arch=${ARCH} \
    --disk_layout="${disk_layout}" \
    --boot_dir="${root_fs_dir}"/usr/boot \
    --esp_dir="${root_fs_dir}"/boot/efi \
    --boot_args="${FLAGS_boot_args}"

  # Zero all fs free space to make it more compressible so auto-update
  # payloads become smaller, not fatal since it won't work on linux < 3.2
  sudo fstrim "${root_fs_dir}" || true
  sudo fstrim "${root_fs_dir}/usr" || true

  cleanup_mounts "${root_fs_dir}"
  trap - EXIT
}
