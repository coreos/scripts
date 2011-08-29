# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Shell function library for functions specific to creating dev
# images from base images.  The main function for export in this
# library is 'install_dev_packages'.


# Modifies an existing image to add development packages
install_dev_packages() {
  local image_name=$1

  echo "Adding developer packages to ${image_name}"

  trap "unmount_image ; delete_prompt" EXIT

  mount_image "${OUTPUT_DIR}/${image_name}" "${ROOT_FS_DIR}" \
    "${STATEFUL_FS_DIR}" "${ESP_FS_DIR}"

  # Determine the root dir for developer packages.
  local root_dev_dir="${ROOT_FS_DIR}"
  [ ${FLAGS_statefuldev} -eq ${FLAGS_TRUE} ] &&
    root_dev_dir="${ROOT_FS_DIR}/usr/local"

  # Install developer packages described in chromeos-dev.
  emerge_to_image --root="${root_dev_dir}" chromeos-dev

  # Install the bare necessary files so that the "emerge" command works
  if [ ${FLAGS_statefuldev} -eq ${FLAGS_TRUE} ]; then
    sudo cp -a ${root_dev_dir}/share/portage ${ROOT_FS_DIR}/usr/share
    sudo sed -i s,/usr/bin/wget,wget, \
      ${ROOT_FS_DIR}/usr/share/portage/config/make.globals
  fi
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

  # Check that the image has been correctly created.  Only do it if not
  # building a factory install shim, as the INSTALL_MASK for it will make
  # test_image fail.
  if [ ${FLAGS_factory_install} -eq ${FLAGS_FALSE} ]; then
    test_image_content "$ROOT_FS_DIR"
  fi
  echo "Developer image built and stored at ${image_name}"

  unmount_image
  trap - EXIT

  ${SCRIPTS_DIR}/bin/cros_make_image_bootable "${OUTPUT_DIR}" \
                                              "${DEVELOPER_IMAGE_NAME}" \
                                              --force_developer_mode
}
