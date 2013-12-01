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

  mount_image "${BUILD_DIR}/${image_name}" "${root_fs_dir}" \
    "${state_fs_dir}" "${esp_fs_dir}"

  # Install developer packages described in coreos-dev.
  emerge_to_image --root="${root_fs_dir}" coreos-base/coreos-dev

  # Make sure profile.env and ld.so.cache has been generated
  sudo ROOT="${root_fs_dir}" env-update

  # Install the bare necessary files so that the "emerge" command works
  sudo mkdir -p ${root_fs_dir}/etc/make.profile

  # Mark the image as a developer image (input to chromeos_startup).
  # TODO(arkaitzr): Remove this file when applications no longer rely on it
  # (crosbug.com/16648). The preferred way of determining developer mode status
  # is via crossystem cros_debug?1 (checks boot args for "cros_debug").
  sudo mkdir -p "${root_fs_dir}/root"
  sudo touch "${root_fs_dir}/root/.dev_mode"

  # Zero all fs free space, not fatal since it won't work on linux < 3.2
  sudo fstrim "${root_fs_dir}" || true
  sudo fstrim "${state_fs_dir}" || true

  info "Developer image built and stored at ${image_name}"

  cleanup_mounts
  trap - EXIT

  if should_build_image ${image_name}; then
    ${SCRIPTS_DIR}/bin/cros_make_image_bootable "${BUILD_DIR}" \
      ${image_name} --force_developer_mode --noenable_rootfs_verification
  fi
}
