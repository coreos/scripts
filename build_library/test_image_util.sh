# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Shell function library for functions specific to creating test
# images from dev images.  This file also contains additional
# functions and initialization shared between build_image and
# mod_image_for_test.sh.
#

# Emerges chromeos-test onto the image.
emerge_chromeos_test() {
  # Determine the root dir for test packages.
  local root_dev_dir="${root_fs_dir}/usr/local"

  emerge_to_image --root="${root_fs_dir}" chromeos-test-init
  emerge_to_image --root="${root_dev_dir}" chromeos-test
}

prepare_hwid_for_factory() {
  local hwid_dest="$1/hwid"
  local hwid_src="${BOARD_ROOT}/usr/share/chromeos-hwid"

  # Force refreshing source folder in build root folder
  sudo rm -rf "${hwid_src}" "${hwid_dest}"
  emerge_to_image chromeos-hwid
  if [ -d "${hwid_src}" ]; then
    # TODO(hungte) After being archived by chromite, the HWID files will be in
    # factory_test/hwid; we should move it to top level folder.
    cp -r "${hwid_src}" "${hwid_dest}"
  else
    echo "Skipping HWID: No HWID bundles found."
  fi
}

# Converts a dev image into a test or factory test image
# Takes as an arg the name of the image to be created.
mod_image_for_test () {
  local image_name="$1"

  trap unmount_image EXIT
  mount_image "${BUILD_DIR}/${image_name}" \
    "${root_fs_dir}" "${stateful_fs_dir}"

  emerge_chromeos_test

  BACKDOOR=0
  if [ $FLAGS_standard_backdoor -eq $FLAGS_TRUE ]; then
    BACKDOOR=1
  fi

  local mod_test_script="${SCRIPTS_DIR}/mod_for_test_scripts/test_setup.sh"
  # Run test setup script to modify the image
  sudo -E GCLIENT_ROOT="${GCLIENT_ROOT}" ROOT_FS_DIR="${root_fs_dir}" \
    STATEFUL_DIR="${stateful_fs_dir}" ARCH="${ARCH}" BACKDOOR="${BACKDOOR}" \
    BOARD_ROOT="${BOARD_ROOT}" \
    "${mod_test_script}"

  # Legacy parameter (used by mod_image_for_test.sh --factory)
  [ -n "${FLAGS_factory}" ] || FLAGS_factory=${FLAGS_FALSE}

  if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} ] ||
      should_build_image "${CHROMEOS_FACTORY_TEST_IMAGE_NAME}"; then
    emerge_to_image --root="${root_fs_dir}" factorytest-init
    INSTALL_MASK="${FACTORY_TEST_INSTALL_MASK}"
    emerge_to_image --root="${root_fs_dir}/usr/local" \
      chromeos-base/autotest chromeos-base/autotest-all \
      chromeos-base/chromeos-factory
    prepare_hwid_for_factory "${BUILD_DIR}"

    local mod_factory_script
    mod_factory_script="${SCRIPTS_DIR}/mod_for_factory_scripts/factory_setup.sh"
    # Run factory setup script to modify the image
    sudo -E GCLIENT_ROOT="${GCLIENT_ROOT}" ROOT_FS_DIR="${root_fs_dir}" \
            BOARD="${BOARD}" "${mod_factory_script}"
  fi

  # Re-run ldconfig to fix /etc/ldconfig.so.cache.
  sudo ldconfig -r "${root_fs_dir}"

  cleanup_mounts
  trap - EXIT

  # Now make it bootable with the flags from build_image.
  if should_build_image ${image_name}; then
    "${SCRIPTS_DIR}/bin/cros_make_image_bootable" "${BUILD_DIR}" \
                                                  ${image_name} \
                                                 --force_developer_mode
  fi
}
