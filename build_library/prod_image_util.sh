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
  local base_pkg="$4"
  if [ -z "${base_pkg}" ]; then
    echo "did not get base package!"
    exit 1
  fi

  info "Building production image ${image_name}"
  local root_fs_dir="${BUILD_DIR}/rootfs"
  local image_contents="${image_name%.bin}_contents.txt"
  local image_packages="${image_name%.bin}_packages.txt"
  local image_licenses="${image_name%.bin}_licenses.txt"

  start_image "${image_name}" "${disk_layout}" "${root_fs_dir}" "${update_group}"

  # Install minimal GCC (libs only) and then everything else
  set_image_profile prod
  extract_prod_gcc "${root_fs_dir}"
  emerge_to_image "${root_fs_dir}" "${base_pkg}"
  run_ldconfig "${root_fs_dir}"
  write_packages "${root_fs_dir}" "${BUILD_DIR}/${image_packages}"
  write_licenses "${root_fs_dir}" "${BUILD_DIR}/${image_licenses}"
  extract_docs "${root_fs_dir}"

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

  finish_image "${image_name}" "${disk_layout}" "${root_fs_dir}" "${image_contents}"

  upload_image -d "${BUILD_DIR}/${image_name}.bz2.DIGESTS" \
      "${BUILD_DIR}/${image_contents}" \
      "${BUILD_DIR}/${image_packages}" \
      "${BUILD_DIR}/${image_name}"
}
