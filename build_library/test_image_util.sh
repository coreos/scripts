# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Shell function library for functions specific to creating test
# images from dev images.  This file also contains additional
# functions and initialization shared between build_image and
# mod_image_for_test.sh.
#
# TODO(jrbarnette): The two halves of this file aren't particularly
# related; they're together merely to consolidate the shared code in
# one file.  Arguably, they should be broken up.


# ----
# The initialization and functions below are shared between
# build_image and mod_image_for_test.sh.  The code is not used
# by the mod_image_for_test function.

EMERGE_BOARD_CMD="$GCLIENT_ROOT/chromite/bin/parallel_emerge"
EMERGE_BOARD_CMD="$EMERGE_BOARD_CMD --board=$BOARD"

if [ $FLAGS_jobs -ne -1 ]; then
  EMERGE_JOBS="--jobs=$FLAGS_jobs"
fi

export INSTALL_MASK="${DEFAULT_INSTALL_MASK}"


# Utility function for creating a copy of an image prior to
# modification from the BUILD_DIR:
#  $1: source filename
#  $2: destination filename
copy_image() {
  local src="${BUILD_DIR}/$1"
  local dst="${BUILD_DIR}/$2"
  if should_build_image $1; then
    echo "Creating $2 from $1..."
    $COMMON_PV_CAT "$src" >"$dst" || die "Cannot copy $1 to $2"
  else
    mv "${src}" "${dst}" || die "Cannot move $1 to $2"
  fi
}

# Basic command to emerge binary packages into the target image.
# Arguments to this command are passed as addition options/arguments
# to the basic emerge command.
emerge_to_image() {
  sudo -E ${EMERGE_BOARD_CMD} --root-deps=rdeps --usepkgonly -v \
    "$@" ${EMERGE_JOBS}
}

# Returns 0 if any of the images was requested to be built, 1 otherwise.
# $@ The name(s) of the images to check.
should_build_image() {
  # Fast pass back if we should build all incremental images.
  local images="$@"
  local image_name
  local image_to_build

  for image_name in ${images}; do
    for image_to_build in ${IMAGES_TO_BUILD}; do
      [ ${image_to_build} = ${image_name} ] && return 0
    done
  done

  return 1
}

# ----
# From here down, the main exported function is
# 'mod_image_for_test'.  The remainder of the code is not used
# outside this file.

# Emerges chromeos-test onto the image.
emerge_chromeos_test() {
  # Determine the root dir for test packages.
  local root_dev_dir="${ROOT_FS_DIR}/usr/local"

  emerge_to_image --root="${ROOT_FS_DIR}" chromeos-test-init
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
    "${ROOT_FS_DIR}" "${STATEFUL_FS_DIR}"

  emerge_chromeos_test

  BACKDOOR=0
  if [ $FLAGS_standard_backdoor -eq $FLAGS_TRUE ]; then
    BACKDOOR=1
  fi

  local mod_test_script="${SCRIPTS_DIR}/mod_for_test_scripts/test_setup.sh"
  # Run test setup script to modify the image
  sudo -E GCLIENT_ROOT="${GCLIENT_ROOT}" ROOT_FS_DIR="${ROOT_FS_DIR}" \
    STATEFUL_DIR="${STATEFUL_FS_DIR}" ARCH="${ARCH}" BACKDOOR="${BACKDOOR}" \
    BOARD_ROOT="${BOARD_ROOT}" \
    "${mod_test_script}"

  # Legacy parameter (used by mod_image_for_test.sh --factory)
  [ -n "${FLAGS_factory}" ] || FLAGS_factory=${FLAGS_FALSE}

  if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} ] ||
      should_build_image "${CHROMEOS_FACTORY_TEST_IMAGE_NAME}"; then
    emerge_to_image --root="${ROOT_FS_DIR}" factorytest-init
    INSTALL_MASK="${FACTORY_TEST_INSTALL_MASK}"
    emerge_to_image --root="${ROOT_FS_DIR}/usr/local" \
      chromeos-base/autotest chromeos-base/autotest-all \
      chromeos-base/chromeos-factory
    prepare_hwid_for_factory "${BUILD_DIR}"

    local mod_factory_script
    mod_factory_script="${SCRIPTS_DIR}/mod_for_factory_scripts/factory_setup.sh"
    # Run factory setup script to modify the image
    sudo -E GCLIENT_ROOT="${GCLIENT_ROOT}" ROOT_FS_DIR="${ROOT_FS_DIR}" \
            BOARD="${BOARD}" "${mod_factory_script}"
  fi

  # Re-run ldconfig to fix /etc/ldconfig.so.cache.
  sudo ldconfig -r "${ROOT_FS_DIR}"

  unmount_image
  trap - EXIT

  # Now make it bootable with the flags from build_image.
  if should_build_image ${image_name}; then
    "${SCRIPTS_DIR}/bin/cros_make_image_bootable" "${BUILD_DIR}" \
                                                  ${image_name} \
                                                 --force_developer_mode
  fi
}
