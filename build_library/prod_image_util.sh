# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

setup_prod_image() {
  local image_name="$1"
  local disk_layout="$2"
  local au_key="$3"

  info "Configuring production image ${image_name}"
  local root_fs_dir="${BUILD_DIR}/rootfs"
  local enable_rootfs_verification_flag=--noenable_rootfs_verification
  if [[ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]]; then
    enable_rootfs_verification_flag=--enable_rootfs_verification
  fi

  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      mount "${BUILD_DIR}/${image_name}" "${root_fs_dir}"
  trap "cleanup_mounts '${root_fs_dir}' && delete_prompt" EXIT

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

  # Move the ld.so configs into /usr so they can be symlinked from /
  sudo mv ${root_fs_dir}/etc/ld.so.conf ${root_fs_dir}/usr/lib
  sudo mv ${root_fs_dir}/etc/ld.so.conf.d ${root_fs_dir}/usr/lib

  sudo ln --symbolic ../usr/lib/ld.so.conf ${root_fs_dir}/etc/ld.so.conf

  # Add a tmpfiles rule that symlink ld.so.conf from /usr into /
  sudo tee "${root_fs_dir}/usr/lib64/tmpfiles.d/baselayout-ldso.conf" \
      > /dev/null <<EOF
L   /etc/ld.so.conf     -   -   -   -   ../usr/lib/ld.so.conf
EOF

  # clear them out explicitly, so this fails if something else gets dropped
  # into xinetd.d
  sudo rm ${root_fs_dir}/etc/xinetd.d/rsyncd
  sudo rmdir ${root_fs_dir}/etc/xinetd.d

  cleanup_mounts "${root_fs_dir}"
  trap - EXIT

  # Make the filesystem un-mountable as read-write.
  if [ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]; then
    "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      tune --disable2fs_rw "${BUILD_DIR}/${image_name}" "USR-A"
  fi
}
