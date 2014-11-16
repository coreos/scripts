# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# The GCC package includes both its libraries and the compiler.
# In prod images we only need the shared libraries.
extract_prod_gcc() {
    local root_fs_dir="$1"; shift
    local gcc=$(portageq-${BOARD} best_version "${BOARD_ROOT}" sys-devel/gcc)
    local pkg="$(portageq-${BOARD} pkgdir)/${gcc}.tbz2"

    if [[ ! -f "${pkg}" ]]; then
        die "Binary package missing: $pkg"
    fi

    # Normally GCC's shared libraries are installed to:
    #  /usr/lib/gcc/x86_64-cros-linux-gnu/$version/*
    # Instead we extract them to plain old /usr/lib
    qtbz2 -O -t "${pkg}" | \
        sudo tar -C "${root_fs_dir}" -xj \
        --transform 's#/usr/lib/.*/#/usr/lib/#' \
        --wildcards './usr/lib/gcc/*.so*'

    package_provided "${gcc}"
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
  extract_prod_gcc "${root_fs_dir}"
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
  sudo rm -rf ${root_fs_dir}/etc/env.d
  sudo rm -rf ${root_fs_dir}/var/db/pkg

  # Move the ld.so configs into /usr so they can be symlinked from /
  sudo mv ${root_fs_dir}/etc/ld.so.conf ${root_fs_dir}/usr/lib
  sudo mv ${root_fs_dir}/etc/ld.so.conf.d ${root_fs_dir}/usr/lib

  sudo ln --symbolic ../usr/lib/ld.so.conf ${root_fs_dir}/etc/ld.so.conf

  # Add a tmpfiles rule that symlink ld.so.conf from /usr into /
  sudo tee "${root_fs_dir}/usr/lib64/tmpfiles.d/baselayout-ldso.conf" \
      > /dev/null <<EOF
L+  /etc/ld.so.conf     -   -   -   -   ../usr/lib/ld.so.conf
EOF

  # Only try to disable rw on /usr if there is a /usr partition 
  local disable_read_write=${FLAGS_enable_rootfs_verification}
  if ! mountpoint -q "${root_fs_dir}/usr"; then
    disable_read_write=${FLAGS_FALSE}
  fi

  finish_image "${image_name}" "${disk_layout}" "${root_fs_dir}" "${image_contents}"

  # Make the filesystem un-mountable as read-write and setup verity.
  if [[ ${disable_read_write} -eq ${FLAGS_TRUE} ]]; then
    "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      verity "${BUILD_DIR}/${image_name}"
  fi

  upload_image -d "${BUILD_DIR}/${image_name}.bz2.DIGESTS" \
      "${BUILD_DIR}/${image_contents}" \
      "${BUILD_DIR}/${image_packages}" \
      "${BUILD_DIR}/${image_name}"
}
