# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Lookup the current version of a binary package, downloading it if needed.
# Usage: get_binary_pkg some-pkg/name
# Prints: some-pkg/name-1.2.3
get_binary_pkg() {
    local name="$1" version

    # If possible use the version installed in $BOARD_ROOT,
    # fall back to any binary package that is available.
    version=$(pkg_version installed "${name}")
    if [[ -z "${version}" ]]; then
        version=$(pkg_version binary "${name}")
    fi

    # Nothing? Maybe we can fetch it.
    if [[ -z "${version}" && ${FLAGS_getbinpkg} -eq ${FLAGS_TRUE} ]]; then
        emerge-${BOARD} --getbinpkg --usepkgonly --fetchonly --nodeps "${name}" >&2
        version=$(pkg_version binary "${name}")
    fi

    # Cry
    if [[ -z "${version}" ]]; then
        die "Binary package missing for ${name}"
    fi

    echo "${version}"
}

# The GCC package includes both its libraries and the compiler.
# In prod images we only need the shared libraries.
extract_prod_gcc() {
    local root_fs_dir="$1" gcc pkg
    gcc=$(get_binary_pkg sys-devel/gcc)

    # FIXME(marineam): Incompatible with FEATURES=binpkg-multi-instance
    pkg="$(portageq-${BOARD} pkgdir)/${gcc}.tbz2"
    [[ -f "${pkg}" ]] || die "${pkg} is missing"

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
  local image_kernel="${image_name%.bin}.vmlinuz"
  local image_pcr_policy="${image_name%.bin}_pcr_policy.zip"

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
  if [[ ${COREOS_OFFICIAL:-0} -eq 1 && "${BOARD}" != arm64-usr ]]; then
      grep -q official \
          "${root_fs_dir}"/var/db/pkg/coreos-base/coreos-au-key-*/USE \
          || die_notrace "coreos-au-key is missing the 'official' use flag"
  fi

  # clean-ups of things we do not need
  sudo rm ${root_fs_dir}/etc/csh.env
  sudo rm -rf ${root_fs_dir}/etc/env.d
  sudo rm -rf ${root_fs_dir}/var/db/pkg

  sudo mv ${root_fs_dir}/etc/profile.env \
      ${root_fs_dir}/usr/share/baselayout/profile.env

  # Move the ld.so configs into /usr so they can be symlinked from /
  sudo mv ${root_fs_dir}/etc/ld.so.conf ${root_fs_dir}/usr/lib
  sudo mv ${root_fs_dir}/etc/ld.so.conf.d ${root_fs_dir}/usr/lib

  sudo ln --symbolic ../usr/lib/ld.so.conf ${root_fs_dir}/etc/ld.so.conf

  # Add a tmpfiles rule that symlink ld.so.conf from /usr into /
  sudo tee "${root_fs_dir}/usr/lib/tmpfiles.d/baselayout-ldso.conf" \
      > /dev/null <<EOF
L+  /etc/ld.so.conf     -   -   -   -   ../usr/lib/ld.so.conf
EOF

  # Move the PAM configuration into /usr
  sudo mkdir -p ${root_fs_dir}/usr/lib/pam.d
  sudo mv -n ${root_fs_dir}/etc/pam.d/* ${root_fs_dir}/usr/lib/pam.d/
  sudo rmdir ${root_fs_dir}/etc/pam.d

  finish_image \
      "${image_name}" \
      "${disk_layout}" \
      "${root_fs_dir}" \
      "${image_contents}" \
      "${image_kernel}" \
      "${image_pcr_policy}"

  upload_image -d "${BUILD_DIR}/${image_name}.bz2.DIGESTS" \
      "${BUILD_DIR}/${image_contents}" \
      "${BUILD_DIR}/${image_packages}" \
      "${BUILD_DIR}/${image_name}" \
      "${BUILD_DIR}/${image_kernel}" \
      "${BUILD_DIR}/${image_pcr_policy}"
}
