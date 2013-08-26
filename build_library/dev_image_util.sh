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

  # Determine the root dir for developer packages.
  local root_dev_dir="${root_fs_dir}/usr/local"

  # Install developer packages described in chromeos-dev.
  emerge_to_image --root="${root_dev_dir}" coreos-base/coreos-dev

  # Copy over the libc debug info so that gdb
  # works with threads and also for a better debugging experience.
  sudo mkdir -p "${root_fs_dir}/usr/local/usr/lib/debug"
  pbzip2 -dc --ignore-trailing-garbage=1 "${LIBC_PATH}" | \
    sudo tar xpf - -C "${root_fs_dir}/usr/local/usr/lib/debug" \
      ./usr/lib/debug/usr/${CHOST} --strip-components=6
  # Since gdb only looks in /usr/lib/debug, symlink the /usr/local
  # path so that it is found automatically.
  sudo ln -s /usr/local/usr/lib/debug "${root_fs_dir}/usr/lib/debug"

  # Install the bare necessary files so that the "emerge" command works
  sudo sed -i s,/usr/bin/wget,wget, \
    ${root_fs_dir}/usr/share/portage/config/make.globals

  sudo mkdir -p ${root_fs_dir}/etc/make.profile

  # Mark the image as a developer image (input to chromeos_startup).
  # TODO(arkaitzr): Remove this file when applications no longer rely on it
  # (crosbug.com/16648). The preferred way of determining developer mode status
  # is via crossystem cros_debug?1 (checks boot args for "cros_debug").
  sudo mkdir -p "${root_fs_dir}/root"
  sudo touch "${root_fs_dir}/root/.dev_mode"

  # Additional changes to developer image.

  # Leave core files for developers to inspect.
  sudo touch "${root_fs_dir}/root/.leave_core"

  # This hack is only needed for devs who have old versions of glibc, which
  # filtered out ldd when cross-compiling.  TODO(davidjames): Remove this hack
  # once everybody has upgraded to a new version of glibc.
  if [[ ! -x "${root_fs_dir}/usr/bin/ldd" ]]; then
    sudo cp -a "$(which ldd)" "${root_fs_dir}/usr/bin"
  fi

  # If vim is installed, then a vi symlink would probably help.
  if [[ -x "${root_fs_dir}/usr/local/bin/vim" ]]; then
    sudo ln -sf vim "${root_fs_dir}/usr/local/bin/vi"
  fi

  # If pygtk is installed in stateful-dev, then install a path.
  if [[ -d \
      "${root_fs_dir}/usr/local/lib/python2.6/site-packages/gtk-2.0" ]]; then
    sudo bash -c "\
        echo gtk-2.0 > \
        ${root_fs_dir}/usr/local/lib/python2.6/site-packages/pygtk.pth"
  fi

  # File searches /usr/share by default, so add a wrapper script so it
  # can find the right path in /usr/local.
  local path="${root_fs_dir}/usr/local/bin/file"
  if [[ -x ${path} ]]; then
    sudo mv "${path}" "${path}.bin"
    sudo_clobber "${path}" <<EOF
#!/bin/sh
exec file.bin -m /usr/local/share/misc/magic.mgc "\$@"
EOF
    sudo chmod a+rx "${path}"
  fi

  # If git is installed in the state partition it needs some help
  if [[ -x "${root_fs_dir}/usr/local/bin/git" ]]; then
    sudo_clobber "${root_fs_dir}/etc/env.d/99git" <<EOF
GIT_EXEC_PATH=/usr/local/libexec/git-core
EOF
  fi

  # Re-run env-update/ldconfig to fix profile and ldconfig.so.cache.
  sudo ROOT="${root_fs_dir}" env-update

  # Zero all fs free space, not fatal since it won't work on linux < 3.2
  sudo fstrim "${root_fs_dir}" || true
  sudo fstrim "${state_fs_dir}" || true

  info "Developer image built and stored at ${image_name}"

  cleanup_mounts
  trap - EXIT

  if [[ ${skip_kernelblock_install} -ne 1 ]]; then
    if should_build_image ${image_name}; then
      ${SCRIPTS_DIR}/bin/cros_make_image_bootable "${BUILD_DIR}" \
        ${image_name} --force_developer_mode
    fi
  fi
}
