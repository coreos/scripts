# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Shell function library for functions specific to creating dev
# images from base images.  The main function for export in this
# library is 'install_dev_packages'.


# Modifies an existing image to add development packages.
# Takes as an arg the name of the image to be created.
install_dev_packages() {
  local image_name=$1

  info "Adding developer packages to ${image_name}"

  trap "unmount_image ; delete_prompt" EXIT

  mount_image "${BUILD_DIR}/${image_name}" "${ROOT_FS_DIR}" \
    "${STATEFUL_FS_DIR}" "${ESP_FS_DIR}"

  # Determine the root dir for developer packages.
  local root_dev_dir="${ROOT_FS_DIR}/usr/local"

  # Install developer packages described in chromeos-dev.
  emerge_to_image --root="${root_dev_dir}" chromeos-dev

  # Copy over the libc debug info so that gdb
  # works with threads and also for a better debugging experience.
  sudo mkdir -p "${ROOT_FS_DIR}/usr/local/usr/lib/debug"
  sudo tar jxpf "${LIBC_PATH}" -C "${ROOT_FS_DIR}/usr/local/usr/lib/debug" \
    ./usr/lib/debug/usr/${CHOST} --strip-components=6
  # Since gdb only looks in /usr/lib/debug, symlink the /usr/local
  # path so that it is found automatically.
  sudo ln -s /usr/local/usr/lib/debug "${ROOT_FS_DIR}/usr/lib/debug"

  # Install the bare necessary files so that the "emerge" command works
  sudo cp -a ${root_dev_dir}/share/portage ${ROOT_FS_DIR}/usr/share
  sudo sed -i s,/usr/bin/wget,wget, \
    ${ROOT_FS_DIR}/usr/share/portage/config/make.globals

  sudo mkdir -p ${ROOT_FS_DIR}/etc/make.profile

  # Re-run ldconfig to fix /etc/ldconfig.so.cache.
  sudo /sbin/ldconfig -r "${ROOT_FS_DIR}"

  # Mark the image as a developer image (input to chromeos_startup).
  # TODO(arkaitzr): Remove this file when applications no longer rely on it
  # (crosbug.com/16648). The preferred way of determining developer mode status
  # is via crossystem cros_debug?1 (checks boot args for "cros_debug").
  sudo mkdir -p "${ROOT_FS_DIR}/root"
  sudo touch "${ROOT_FS_DIR}/root/.dev_mode"

  # Additional changes to developer image.

  # Leave core files for developers to inspect.
  sudo touch "${ROOT_FS_DIR}/root/.leave_core"

  # This hack is only needed for devs who have old versions of glibc, which
  # filtered out ldd when cross-compiling.  TODO(davidjames): Remove this hack
  # once everybody has upgraded to a new version of glibc.
  if [[ ! -x "${ROOT_FS_DIR}/usr/bin/ldd" ]]; then
    sudo cp -a "$(which ldd)" "${ROOT_FS_DIR}/usr/bin"
  fi

  # If vim is installed, then a vi symlink would probably help.
  if [[ -x "${ROOT_FS_DIR}/usr/local/bin/vim" ]]; then
    sudo ln -sf vim "${ROOT_FS_DIR}/usr/local/bin/vi"
  fi

  # If pygtk is installed in stateful-dev, then install a path.
  if [[ -d \
      "${ROOT_FS_DIR}/usr/local/lib/python2.6/site-packages/gtk-2.0" ]]; then
    sudo bash -c "\
        echo gtk-2.0 > \
        ${ROOT_FS_DIR}/usr/local/lib/python2.6/site-packages/pygtk.pth"
  fi

  # File searches /usr/share by default, so add a wrapper script so it
  # can find the right path in /usr/local.
  local path="${ROOT_FS_DIR}/usr/local/bin/file"
  if [[ -x ${path} ]]; then
    sudo mv "${path}" "${path}.bin"
    sudo_clobber "${path}" <<EOF
#!/bin/sh
exec file.bin -m /usr/local/share/misc/magic.mgc "\$@"
EOF
    sudo chmod a+rx "${path}"
  fi

  # If python is installed on stateful-dev, fix python symlinks.
  local python_path="/usr/local/bin/python2.6"
  if [ -e "${ROOT_FS_DIR}${python_path}" ]; then
    info "Fixing python symlinks for developer and test images."
    local python_paths="/usr/bin/python /usr/local/bin/python \
        /usr/bin/python2 /usr/local/bin/python2"
    for path in ${python_paths}; do
      sudo rm -f "${ROOT_FS_DIR}${path}"
      sudo ln -s  ${python_path} "${ROOT_FS_DIR}${path}"
    done
  fi

  info "Developer image built and stored at ${image_name}"

  unmount_image
  trap - EXIT

  if should_build_image ${image_name}; then
    ${SCRIPTS_DIR}/bin/cros_make_image_bootable "${BUILD_DIR}" \
                                                ${image_name} \
                                                --force_developer_mode
  fi
}
