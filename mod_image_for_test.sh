#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to modify a keyfob-based chromeos system image for testability.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Load functions and constants for chromeos-install
. "$(dirname "$0")/chromeos-common.sh"

# We need to be in the chroot to emerge test packages.
assert_inside_chroot

get_default_board

DEFINE_string board "$DEFAULT_BOARD" "Board for which the image was built" b
DEFINE_boolean factory $FLAGS_FALSE \
    "Modify the image for manufacturing testing" f
DEFINE_boolean factory_install $FLAGS_FALSE \
    "Modify the image for factory install shim"
DEFINE_string image "" "Location of the rootfs raw image file" i
DEFINE_boolean installmask $FLAGS_TRUE \
    "Use INSTALL_MASK to shrink the resulting image." m
DEFINE_integer jobs -1 \
    "How many packages to build in parallel at maximum." j
DEFINE_string qualdb "" "Location of qualified component file" d
DEFINE_boolean yes $FLAGS_FALSE "Answer yes to all prompts" y
DEFINE_string build_root "/build" \
    "The root location for board sysroots."
DEFINE_boolean fast ${DEFAULT_FAST} "Call many emerges in parallel"
DEFINE_boolean inplace $FLAGS_TRUE \
    "Modify/overwrite the image ${CHROMEOS_IMAGE_NAME} in place.  \
Otherwise the image will be copied to ${CHROMEOS_TEST_IMAGE_NAME} \
if needed, and  modified there"
DEFINE_boolean force_copy ${FLAGS_FALSE} \
    "Always rebuild test image if --noinplace"


# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

EMERGE_CMD="emerge"
EMERGE_BOARD_CMD="emerge-${FLAGS_board}"
if [ "${FLAGS_fast}" -eq "${FLAGS_TRUE}" ]; then
  echo "Using alternate emerge"
  EMERGE_CMD="${SCRIPTS_DIR}/parallel_emerge"
  EMERGE_BOARD_CMD="${EMERGE_CMD} --board=${FLAGS_board}"
fi

# No board, no default and no image set then we can't find the image
if [ -z $FLAGS_image ] && [ -z $FLAGS_board ] ; then
  setup_board_warning
  die "mod_image_for_test failed.  No board set and no image set"
fi

# We have a board name but no image set.  Use image at default location
if [ -z $FLAGS_image ] ; then
  IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
  FILENAME="${CHROMEOS_IMAGE_NAME}"
  FLAGS_image="${IMAGES_DIR}/$(ls -t $IMAGES_DIR 2>&-| head -1)/${FILENAME}"
fi

# Turn path into an absolute path.
FLAGS_image=`eval readlink -f ${FLAGS_image}`

# Abort early if we can't find the image
if [ ! -f $FLAGS_image ] ; then
  echo "No image found at $FLAGS_image"
  exit 1
fi

# What cross-build are we targeting?
. "${FLAGS_build_root}/${FLAGS_board}/etc/make.conf.board_setup"
# Figure out ARCH from the given toolchain.
# TODO: Move to common.sh as a function after scripts are switched over.
TC_ARCH=$(echo "${CHOST}" | awk -F'-' '{ print $1 }')
case "${TC_ARCH}" in
  arm*)
    ARCH="arm"
    ;;
  *86)
    ARCH="x86"
    ;;
  *)
    error "Unable to determine ARCH from toolchain: ${CHOST}"
    exit 1
esac

# Make sure anything mounted in the rootfs/stateful is cleaned up ok on exit.
cleanup_mounts() {
  # Occasionally there are some daemons left hanging around that have our
  # root/stateful image file system open. We do a best effort attempt to kill
  # them.
  PIDS=`sudo lsof -t "$1" | sort | uniq`
  for pid in ${PIDS}
  do
    local cmdline=`cat /proc/$pid/cmdline`
    echo "Killing process that has open file on the mounted directory: $cmdline"
    sudo kill $pid || /bin/true
  done
}

cleanup() {
  "$SCRIPTS_DIR/mount_gpt_image.sh" -u -r "$ROOT_FS_DIR" -s "$STATEFUL_DIR"
}

# Emerges chromeos-test onto the image.
emerge_chromeos_test() {
  INSTALL_MASK=""
  if [[ $FLAGS_installmask -eq ${FLAGS_TRUE} ]]; then
    INSTALL_MASK="$DEFAULT_INSTALL_MASK"
  fi

  # Determine the root dir for test packages.
  ROOT_DEV_DIR="$ROOT_FS_DIR/usr/local"

  sudo INSTALL_MASK="$INSTALL_MASK" $EMERGE_BOARD_CMD \
    --root="$ROOT_DEV_DIR" --root-deps=rdeps \
    --usepkgonly chromeos-test $EMERGE_JOBS
}


install_autotest() {
    SYSROOT="${FLAGS_build_root}/${FLAGS_board}"
    AUTOTEST_SRC="${SYSROOT}/usr/local/autotest"
    stateful_root="${ROOT_FS_DIR}/usr/local"
    autotest_client="/autotest"

    echo "Install autotest into stateful partition from $AUTOTEST_SRC"

    sudo mkdir -p "${stateful_root}${autotest_client}"

    # Remove excess files from stateful partition.
    # If these aren't there, that's fine.
    sudo rm -rf "${stateful_root}${autotest_client}/*" || true
    sudo rm -rf "${stateful_root}/autotest-pkgs" || true
    sudo rm -rf "${stateful_root}/lib/icedtea6" || true

    sudo rsync --delete --delete-excluded -auv \
      --exclude=deps/realtimecomm_playground \
      --exclude=tests/ltp \
      --exclude=site_tests/graphics_O3DSelenium \
      --exclude=site_tests/realtimecomm_GTalk\* \
      --exclude=site_tests/platform_StackProtector \
      --exclude=deps/chrome_test \
      --exclude=site_tests/desktopui_BrowserTest \
      --exclude=site_tests/desktopui_PageCyclerTests \
      --exclude=site_tests/desktopui_UITest \
      --exclude=.svn \
      ${AUTOTEST_SRC}/client/* "${stateful_root}/${autotest_client}"

    sudo chmod 755 "${stateful_root}/${autotest_client}"
    sudo chown -R 1000:1000 "${stateful_root}/${autotest_client}"
}

# main process begins here.

IMAGE_DIR="$(dirname "${FLAGS_image}")"

# Copy the image to a test location if required
if [ ${FLAGS_inplace} -eq ${FLAGS_FALSE} ]; then
  TEST_PATHNAME="${IMAGE_DIR}/${CHROMEOS_TEST_IMAGE_NAME}"
  if [ ! -f "${TEST_PATHNAME}" ] || \
     [ ${FLAGS_force_copy} -eq ${FLAGS_TRUE} ] ; then
    echo "Creating test image from original..."
    ${COMMON_PV_CAT} "${FLAGS_image}" >"${TEST_PATHNAME}" \
      || die "Cannot copy ${FLAGS_image} to test image"
    FLAGS_image="${TEST_PATHNAME}"
  else
    echo "Using cached test image"
  fi

  # No need to confirm now, since we are not overwriting the main image
  FLAGS_yes="$FLAGS_TRUE"
fi

# Make sure this is really what the user wants, before nuking the device
if [ $FLAGS_yes -ne $FLAGS_TRUE ]; then
  read -p "Modifying image ${FLAGS_image} for test; are you sure (y/N)? " SURE
  SURE="${SURE:0:1}" # Get just the first character
  if [ "$SURE" != "y" ]; then
    echo "Ok, better safe than sorry."
    exit 1
  fi
else
  echo "Modifying image ${FLAGS_image} for test..."
fi

set -e

IMAGE_DIR="$(dirname "$FLAGS_image")"
IMAGE_NAME="$(basename "$FLAGS_image")"
ROOT_FS_DIR="$IMAGE_DIR/rootfs"
STATEFUL_DIR="$IMAGE_DIR/stateful_partition"
SCRIPTS_DIR=$(dirname "$0")
DEV_USER="chronos"

trap cleanup EXIT

# Mounts gpt image and sets up var, /usr/local and symlinks.
"$SCRIPTS_DIR/mount_gpt_image.sh" -i "$IMAGE_NAME" -f "$IMAGE_DIR" \
  -r "$ROOT_FS_DIR" -s "$STATEFUL_DIR"

if [ ${FLAGS_factory_install} -eq ${FLAGS_TRUE} ]; then
  # We don't want to emerge test packages on factory install, otherwise we run
  # out of space.

  # Run factory setup script to modify the image.
  sudo $EMERGE_BOARD_CMD --root=$ROOT_FS_DIR --usepkgonly \
      --root-deps=rdeps --nodeps chromeos-factoryinstall

  # Set factory server if necessary.
  if [ "${FACTORY_SERVER}" != "" ]; then
    sudo sed -i \
      "s/CHROMEOS_AUSERVER=.*$/CHROMEOS_AUSERVER=\
http:\/\/${FACTORY_SERVER}:8080\/update/" \
      ${ROOT_FS_DIR}/etc/lsb-release
  fi
else
  emerge_chromeos_test

  # Mark "OOBE completed" flag so that OEM partition is not mounted on startup.
  sudo touch "${ROOT_FS_DIR}/home/${DEV_USER}/.oobe_completed"

  MOD_TEST_ROOT="${GCLIENT_ROOT}/src/scripts/mod_for_test_scripts"
  # Run test setup script to modify the image
  sudo GCLIENT_ROOT="${GCLIENT_ROOT}" ROOT_FS_DIR="${ROOT_FS_DIR}" \
      STATEFUL_DIR="${STATEFUL_DIR}" ARCH="${ARCH}" "${MOD_TEST_ROOT}/test_setup.sh"

  if [ ${FLAGS_factory} -eq ${FLAGS_TRUE} ]; then
    install_autotest

    MOD_FACTORY_ROOT="${GCLIENT_ROOT}/src/scripts/mod_for_factory_scripts"
    # Run factory setup script to modify the image
    sudo GCLIENT_ROOT="${GCLIENT_ROOT}" ROOT_FS_DIR="${ROOT_FS_DIR}" \
        QUALDB="${FLAGS_qualdb}" BOARD=${FLAGS_board} \
        "${MOD_FACTORY_ROOT}/factory_setup.sh"
  fi
fi

# Let's have a look at the image just in case..
if [ "${VERIFY}" = "true" ]; then
  pushd "${ROOT_FS_DIR}"
  bash
  popd
fi

cleanup

# Now make it bootable with the flags from build_image
${SCRIPTS_DIR}/bin/cros_make_image_bootable $(dirname "${FLAGS_image}") \
                                            $(basename "${FLAGS_image}")

print_time_elapsed

trap - EXIT

