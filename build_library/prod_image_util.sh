# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

create_prod_image() {
  local image_name="$1"
  local disk_layout="$2"
  local update_group="$3"

  info "Building production image ${image_name}"
  local root_fs_dir="${BUILD_DIR}/rootfs"

  start_image "${image_name}" "${disk_layout}" "${root_fs_dir}"

  # Install minimal GCC (libs only) and then everything else
  emerge_prod_gcc "${root_fs_dir}"
  emerge_to_image "${root_fs_dir}" coreos-base/coreos

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

  finish_image "${disk_layout}" "${root_fs_dir}" "${update_group}"

  # Make the filesystem un-mountable as read-write.
  if [ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]; then
    "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      tune --disable2fs_rw "${BUILD_DIR}/${image_name}" "USR-A"
  fi
}
