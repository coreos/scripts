# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

setup_prod_image() {
  local image_name="$1"
  local update_track="$2"
  local au_key="$3"

  info "Configuring production image ${image_name}"
  local disk_layout="${FLAGS_disk_layout:-base}"
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

  # Make the filesystem un-mountable as read-write.
  if [ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]; then
    warn "Disabling r/w mount of the root filesystem"
    sudo mount -o remount,ro "${root_fs_dir}"
    root_dev=$(awk -v mnt="${root_fs_dir}" \
               '$2 == mnt { print $1 }' /proc/mounts)
    disable_rw_mount "$root_dev"
  fi

  cleanup_mounts "${root_fs_dir}"
  trap - EXIT
}
