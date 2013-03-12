. "${SRC_ROOT}/platform/dev/toolchain_utils.sh" || exit 1

OUTSIDE_OUTPUT_DIR="src/build/containers/${BOARD}/${IMAGE_SUBDIR}/rootfs"

install_dev_packages() {
  local image_name=$1

  info "Adding developer packages to ${image_name}"

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

  # Re-run ldconfig to fix /etc/ldconfig.so.cache.
  sudo /sbin/ldconfig -r "${root_fs_dir}"

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

  # If python is installed on stateful-dev, fix python symlinks.
  local python_path="/usr/local/bin/python2.6"
  if [ -e "${root_fs_dir}${python_path}" ]; then
    info "Fixing python symlinks for developer and test images."
    local python_paths="/usr/bin/python /usr/local/bin/python \
        /usr/bin/python2 /usr/local/bin/python2"
    for path in ${python_paths}; do
      sudo rm -f "${root_fs_dir}${path}"
      sudo ln -s  ${python_path} "${root_fs_dir}${path}"
    done
  fi

  cleanup_mounts
  trap - EXIT
}

create_base_container() {
  local image_name=$1
  local rootfs_verification_enabled=$2
  local bootcache_enabled=$3 local image_type="usb"

  root_fs_dir="${BUILD_DIR}/rootfs"
  stateful_fs_dir="${BUILD_DIR}/stateful"
  esp_fs_dir="${BUILD_DIR}/esp"
  oem_fs_dir="${BUILD_DIR}/oem"

  trap "cleanup_mounts && delete_prompt" EXIT
  cleanup_mounts &> /dev/null

  mkdir -p "${root_fs_dir}"
  mkdir -p "${stateful_fs_dir}"
  mkdir -p "${oem_fs_dir}"

  # Prepare stateful partition with some pre-created directories.
  sudo mkdir "${stateful_fs_dir}/dev_image"
  sudo mkdir "${stateful_fs_dir}/var_overlay"

  # Create symlinks so that /usr/local/usr based directories are symlinked to
  # /usr/local/ directories e.g. /usr/local/usr/bin -> /usr/local/bin, etc.
  setup_symlinks_on_root "${stateful_fs_dir}/dev_image" \
    "${stateful_fs_dir}/var_overlay" "${stateful_fs_dir}"

  # Perform binding rather than symlinking because directories must exist
  # on rootfs so that we can bind at run-time since rootfs is read-only.
  info "Binding directories from stateful partition onto the rootfs"
  sudo mkdir -p "${root_fs_dir}/usr/local"
  sudo mount --bind "${stateful_fs_dir}/dev_image" "${root_fs_dir}/usr/local"
  sudo mkdir -p "${root_fs_dir}/var"
  sudo mount --bind "${stateful_fs_dir}/var_overlay" "${root_fs_dir}/var"
  sudo mkdir -p "${root_fs_dir}/dev"

  info "Binding directories from OEM partition onto the rootfs"
  sudo mkdir -p "${root_fs_dir}/usr/share/oem"
  sudo mount --bind "${oem_fs_dir}" "${root_fs_dir}/usr/share/oem"

  # We need to install libc manually from the cross toolchain.
  # TODO: Improve this? It would be ideal to use emerge to do this.
  PKGDIR="/var/lib/portage/pkgs"
  LIBC_TAR="glibc-${LIBC_VERSION}.tbz2"
  LIBC_PATH="${PKGDIR}/cross-${CHOST}/${LIBC_TAR}"

  if ! [[ -e ${LIBC_PATH} ]]; then
  die_notrace \
    "${LIBC_PATH} does not exist. Try running ./setup_board" \
    "--board=${BOARD} to update the version of libc installed on that board."
  fi

  # Strip out files we don't need in the final image at runtime.
  local libc_excludes=(
    # Compile-time headers.
    'usr/include' 'sys-include'
    # Link-time objects.
    '*.[ao]'
  )
  pbzip2 -dc --ignore-trailing-garbage=1 "${LIBC_PATH}" | \
    sudo tar xpf - -C "${root_fs_dir}" ./usr/${CHOST} \
      --strip-components=3 "${libc_excludes[@]/#/--exclude=}"

  board_ctarget=$(get_ctarget_from_board "${BOARD}")
  for atom in $(portageq match / cross-$board_ctarget/gcc); do
    copy_gcc_libs "${root_fs_dir}" $atom
  done

  # We "emerge --root=${root_fs_dir} --root-deps=rdeps --usepkgonly" all of the
  # runtime packages for chrome os. This builds up a chrome os image from
  # binary packages with runtime dependencies only.  We use INSTALL_MASK to
  # trim the image size as much as possible.
  emerge_to_image --root="${root_fs_dir}" ${BASE_PACKAGE}

  # Set /etc/lsb-release on the image.
  "${OVERLAY_CHROMEOS_DIR}/scripts/cros_set_lsb_release" \
  --root="${root_fs_dir}" \
  --board="${BOARD}"

  # Create the boot.desc file which stores the build-time configuration
  # information needed for making the image bootable after creation with
  # cros_make_image_bootable.
  create_boot_desc "${image_type}"

  # Clean up symlinks so they work on a running target rooted at "/".
  # Here development packages are rooted at /usr/local.  However, do not
  # create /usr/local or /var on host (already exist on target).
  setup_symlinks_on_root "/usr/local" "/var" "${stateful_fs_dir}"

  USE_DEV_KEYS=
  if should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
    USE_DEV_KEYS="--use_dev_keys"
  fi
}
