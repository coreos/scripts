# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Shell library for functions and initialization private to
# build_image, and not specific to any particular kind of image.
#
# TODO(jrbarnette):  There's nothing holding this code together in
# one file aside from its lack of anywhere else to go.  Probably,
# this file should get broken up or otherwise reorganized.

# Use canonical path since some tools (e.g. mount) do not like symlinks.
# Append build attempt to output directory.
IMAGE_SUBDIR="R${CHROME_BRANCH}"
if [ -z "${FLAGS_version}" ]; then
  IMAGE_SUBDIR="${IMAGE_SUBDIR}-${CHROMEOS_VERSION_STRING}-a\
${FLAGS_build_attempt}"
else
  IMAGE_SUBDIR="${IMAGE_SUBDIR}-${FLAGS_version}"
fi
BUILD_DIR="${FLAGS_output_root}/${BOARD}/${IMAGE_SUBDIR}"
OUTSIDE_OUTPUT_DIR="../build/images/${BOARD}/${IMAGE_SUBDIR}"
IMAGES_TO_BUILD=


# Populates list of IMAGES_TO_BUILD from args passed in.
# Arguments should be the shortnames of images we want to build.
get_images_to_build() {
  local image_to_build
  for image_to_build in $*; do
    # Shflags leaves "'"s around ARGV.
    case ${image_to_build} in
      \'base\' )
        IMAGES_TO_BUILD="${IMAGES_TO_BUILD} ${CHROMEOS_BASE_IMAGE_NAME}"
        ;;
      \'dev\' )
        IMAGES_TO_BUILD="${IMAGES_TO_BUILD} ${CHROMEOS_DEVELOPER_IMAGE_NAME}"
        ;;
      \'test\' )
        IMAGES_TO_BUILD="${IMAGES_TO_BUILD} ${CHROMEOS_TEST_IMAGE_NAME}"
        ;;
      \'factory_test\' )
        IMAGES_TO_BUILD="${IMAGES_TO_BUILD} ${CHROMEOS_FACTORY_TEST_IMAGE_NAME}"
        ;;
      \'factory_install\' )
        IMAGES_TO_BUILD="${IMAGES_TO_BUILD} \
          ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}"
        ;;
      * )
        die "${image_to_build} is not an image specification."
        ;;
    esac
  done

  # Set default if none specified.
  if [ -z "${IMAGES_TO_BUILD}" ]; then
    IMAGES_TO_BUILD=${CHROMEOS_DEVELOPER_IMAGE_NAME}
  fi

  info "The following images will be built ${IMAGES_TO_BUILD}."
}

# Look at flags to determine which image types we should build.
parse_build_image_args() {
  get_images_to_build ${FLAGS_ARGV}
  if should_build_image ${CHROMEOS_TEST_IMAGE_NAME}; then
    if should_build_image "${CHROMEOS_FACTORY_TEST_IMAGE_NAME}"; then
      die_notrace "Cannot build both the test and factory_test images."
    fi
  fi
  if should_build_image ${CHROMEOS_BASE_IMAGE_NAME} \
      ${CHROMEOS_DEVELOPER_IMAGE_NAME} ${CHROMEOS_TEST_IMAGE_NAME} \
      ${CHROMEOS_FACTORY_TEST_IMAGE_NAME} &&
      should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
    die_notrace \
        "Can't build ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME} with any other" \
        "image."
  fi
  if should_build_image ${CHROMEOS_FACTORY_INSTALL_SHIM_NAME}; then
    FLAGS_enable_rootfs_verification=${FLAGS_FALSE}
  fi
}

check_blacklist() {
  info "Verifying that the base image does not contain a blacklisted package."
  info "Generating list of packages for chromeos-base/chromeos."
  local package_blacklist_file="${BUILD_LIBRARY_DIR}/chromeos_blacklist"
  if [ ! -e "${package_blacklist_file}" ]; then
    warn "Missing blacklist file."
    return
  fi
  local blacklisted_packages=$(${SCRIPTS_DIR}/get_package_list \
      --board="${BOARD}" chromeos-base/chromeos \
      | grep -x -f "${package_blacklist_file}")
  if [ -n "${blacklisted_packages}" ]; then
    die "Blacklisted packages found: ${blacklisted_packages}."
  fi
  info "No blacklisted packages found."
}

make_salt() {
  # It is not important that the salt be cryptographically strong; it just needs
  # to be different for each release. The purpose of the salt is just to ensure
  # that if someone collides a block in one release, they can't reuse it in
  # future releases.
  xxd -l 32 -p -c 32 /dev/urandom
}

# Takes no arguments and populates the configuration for
# cros_make_image_bootable.
create_boot_desc() {
  local enable_rootfs_verification_flag=""
  if [[ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]]; then
    enable_rootfs_verification_flag="--enable_rootfs_verification"
  fi

  [ -z "${FLAGS_verity_salt}" ] && FLAGS_verity_salt=$(make_salt)
  cat <<EOF > ${BUILD_DIR}/boot.desc
  --arch="${ARCH}"
  --boot_args="${FLAGS_boot_args}"
  --rootfs_size="${FLAGS_rootfs_size}"
  --rootfs_hash_pad="${FLAGS_rootfs_hash_pad}"
  --verity_error_behavior="${FLAGS_verity_error_behavior}"
  --verity_max_ios="${FLAGS_verity_max_ios}"
  --verity_algorithm="${FLAGS_verity_algorithm}"
  --verity_salt="${FLAGS_verity_salt}"
  --keys_dir="${DEVKEYSDIR}"
  --usb_disk="${FLAGS_usb_disk}"
  --nocleanup_dirs
  ${enable_rootfs_verification_flag}
EOF
}

delete_prompt() {
  echo "An error occurred in your build so your latest output directory" \
    "is invalid."

  # Only prompt if both stdin and stdout are a tty. If either is not a tty,
  # then the user may not be present, so we shouldn't bother prompting.
  if [ -t 0 -a -t 1 -a "${USER}" != 'chrome-bot' ]; then
    read -p "Would you like to delete the output directory (y/N)? " SURE
    SURE="${SURE:0:1}" # Get just the first character.
  else
    SURE="y"
    echo "Running in non-interactive mode so deleting output directory."
  fi
  if [ "${SURE}" == "y" ] ; then
    sudo rm -rf "${BUILD_DIR}"
    echo "Deleted ${BUILD_DIR}"
  else
    echo "Not deleting ${BUILD_DIR}."
  fi
}

generate_au_zip () {
  local lgenerateauzip="${BUILD_LIBRARY_DIR}/generate_au_zip.py"
  local largs="-o ${BUILD_DIR}"
  test ! -d "${BUILD_DIR}" && mkdir -p "${BUILD_DIR}"
  info "Running ${lgenerateauzip} ${largs} for generating AU updater zip file"
  $lgenerateauzip $largs
}
