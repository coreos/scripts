# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# The GCC package includes both its libraries and the compiler.
# In prod images we only need the shared libraries.
emerge_prod_gcc() {
    local root_fs_dir="$1"; shift
    local mask="${INSTALL_MASK:-$(portageq-$BOARD envvar INSTALL_MASK)}"
    test -n "$mask" || die "INSTALL_MASK not defined"

    mask="${mask}
        /usr/bin
        /usr/*/gcc-bin
        /usr/lib/gcc/*/*/*.o
        /usr/lib/gcc/*/*/include
        /usr/lib/gcc/*/*/include-fixed
        /usr/lib/gcc/*/*/plugin
        /usr/libexec
        /usr/share/gcc-data/*/*/c89
        /usr/share/gcc-data/*/*/c99
        /usr/share/gcc-data/*/*/python"

    INSTALL_MASK="${mask}" emerge_to_image "${root_fs_dir}" --nodeps sys-devel/gcc "$@"
}

create_prod_image() {
  local image_name="$1"
  local disk_layout="$2"
  local update_group="$3"

  info "Building production image ${image_name}"
  local root_fs_dir="${BUILD_DIR}/rootfs"
  local image_contents="${image_name%.bin}_contents.txt"
  local image_packages="${image_name%.bin}_packages.txt"

  start_image "${image_name}" "${disk_layout}" "${root_fs_dir}" "${update_group}"

  # Install minimal GCC (libs only) and then everything else
  set_image_profile prod
  emerge_prod_gcc "${root_fs_dir}"
  emerge_to_image "${root_fs_dir}" coreos-base/coreos
  write_packages "${root_fs_dir}" "${BUILD_DIR}/${image_packages}"

  # Assert that if this is supposed to be an official build that the
  # official update keys have been used.
  if [[ ${COREOS_OFFICIAL:-0} -eq 1 ]]; then
      grep -q official \
          "${root_fs_dir}"/var/db/pkg/coreos-base/coreos-au-key-*/USE \
          || die_notrace "coreos-au-key is missing the 'official' use flag"
  fi

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
L+  /etc/ld.so.conf     -   -   -   -   ../usr/lib/ld.so.conf
EOF

  # clear them out explicitly, so this fails if something else gets dropped
  # into xinetd.d
  sudo rm ${root_fs_dir}/etc/xinetd.d/rsyncd
  sudo rmdir ${root_fs_dir}/etc/xinetd.d

  # Only try to disable rw on /usr if there is a /usr partition 
  local disable_read_write=${FLAGS_enable_rootfs_verification}
  if ! mountpoint -q "${root_fs_dir}/usr"; then
    disable_read_write=${FLAGS_FALSE}
  fi

  finish_image "${image_name}" "${disk_layout}" "${root_fs_dir}" "${image_contents}"

  # Make the filesystem un-mountable as read-write.
  if [[ ${disable_read_write} -eq ${FLAGS_TRUE} ]]; then
    "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      tune --disable2fs_rw "${BUILD_DIR}/${image_name}" "USR-A"
  fi

  upload_image -d "${BUILD_DIR}/${image_name}.bz2.DIGESTS" \
      "${BUILD_DIR}/${image_contents}" \
      "${BUILD_DIR}/${image_packages}" \
      "${BUILD_DIR}/${image_name}"
}
