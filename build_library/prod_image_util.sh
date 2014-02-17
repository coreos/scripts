# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

setup_prod_image() {
  local image_name="$1"
  local disk_layout="$2"
  local update_track="$3"
  local au_key="$4"

  info "Configuring production image ${image_name}"
  local root_fs_dir="${BUILD_DIR}/rootfs"
  local enable_rootfs_verification_flag=--noenable_rootfs_verification
  if [[ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]]; then
    enable_rootfs_verification_flag=--enable_rootfs_verification
  fi

  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      mount "${BUILD_DIR}/${image_name}" "${root_fs_dir}"
  trap "cleanup_mounts '${root_fs_dir}' && delete_prompt" EXIT

  # Replace /etc/lsb-release on the image.
  "${BUILD_LIBRARY_DIR}/set_lsb_release" \
    --production_track="${update_track}" \
    --root="${root_fs_dir}" \
    --board="${BOARD}"

  # Install an auto update key on the root before sealing it off
  local key_location=${root_fs_dir}"/usr/share/update_engine/"
  sudo mkdir -p "${key_location}"
  sudo cp "${au_key}" "$key_location/update-payload-key.pub.pem"
  sudo chown root:root "$key_location/update-payload-key.pub.pem"
  sudo chmod 644 "$key_location/update-payload-key.pub.pem"

  # clean-ups of things we do not need
  sudo rm ${root_fs_dir}/etc/csh.env
  sudo rm -rf ${root_fs_dir}/var/db/pkg
  sudo rm ${root_fs_dir}/var/db/Makefile
  sudo rm ${root_fs_dir}/etc/locale.gen
  sudo rm -rf ${root_fs_dir}/etc/lvm/

  # clear them out explicitly, so this fails if something else gets dropped
  # into xinetd.d
  sudo rm ${root_fs_dir}/etc/xinetd.d/rsyncd
  sudo rmdir ${root_fs_dir}/etc/xinetd.d

  cleanup_mounts "${root_fs_dir}"
  trap - EXIT

  # Make the filesystem un-mountable as read-write.
  if [ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]; then
    local ro_label="ROOT-A"
    if [[ "${disk_layout}" == *-usr ]]; then
      ro_label="USR-A"
    fi
    "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      tune --disable2fs_rw "${BUILD_DIR}/${image_name}" "${ro_label}"
  fi
}
