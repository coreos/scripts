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
if [ -z "${FLAGS_version}" ]; then
  IMAGE_SUBDIR="${COREOS_VERSION_STRING}-a${FLAGS_build_attempt}"
else
  IMAGE_SUBDIR="${FLAGS_version}"
fi
BUILD_DIR="${FLAGS_output_root}/${BOARD}/${IMAGE_SUBDIR}"
OUTSIDE_OUTPUT_DIR="../build/images/${BOARD}/${IMAGE_SUBDIR}"
IMAGES_TO_BUILD=

EMERGE_BOARD_CMD="$GCLIENT_ROOT/chromite/bin/parallel_emerge"
EMERGE_BOARD_CMD="$EMERGE_BOARD_CMD --board=$BOARD"

export INSTALL_MASK="${DEFAULT_INSTALL_MASK}"

if [[ $FLAGS_jobs -ne -1 ]]; then
  EMERGE_JOBS="--jobs=$FLAGS_jobs"
fi

# Populates list of IMAGES_TO_BUILD from args passed in.
# Arguments should be the shortnames of images we want to build.
get_images_to_build() {
  local image_to_build
  for image_to_build in $*; do
    # Shflags leaves "'"s around ARGV.
    case ${image_to_build} in
      \'prod\' )
        IMAGES_TO_BUILD="${IMAGES_TO_BUILD} ${COREOS_PRODUCTION_IMAGE_NAME}"
        ;;
      \'base\' )
        IMAGES_TO_BUILD="${IMAGES_TO_BUILD} ${CHROMEOS_BASE_IMAGE_NAME}"
        ;;
      \'dev\' )
        IMAGES_TO_BUILD="${IMAGES_TO_BUILD} ${CHROMEOS_DEVELOPER_IMAGE_NAME}"
        ;;
      \'test\' )
        IMAGES_TO_BUILD="${IMAGES_TO_BUILD} ${CHROMEOS_TEST_IMAGE_NAME}"
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
}

check_blacklist() {
  info "Verifying that the base image does not contain a blacklisted package."
  info "Generating list of packages for ${BASE_PACKAGE}."
  local package_blacklist_file="${BUILD_LIBRARY_DIR}/chromeos_blacklist"
  if [ ! -e "${package_blacklist_file}" ]; then
    warn "Missing blacklist file."
    return
  fi
  local blacklisted_packages=$(${SCRIPTS_DIR}/get_package_list \
      --board="${BOARD}" "${BASE_PACKAGE}" \
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

create_boot_desc() {
  local image_type=$1

  local enable_rootfs_verification_flag=""
  if [[ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]]; then
    enable_rootfs_verification_flag="--enable_rootfs_verification"
  fi
  local enable_bootcache_flag=""
  if [[ ${FLAGS_enable_bootcache} -eq ${FLAGS_TRUE} ]]; then
    enable_bootcache_flag=--enable_bootcache
  fi

  cat <<EOF > ${BUILD_DIR}/boot.desc
  --board=${BOARD}
  --image_type=${image_type}
  --arch="${ARCH}"
  --keys_dir="${DEVKEYSDIR}"
  --boot_args="${FLAGS_boot_args}"
  --nocleanup_dirs
  ${enable_rootfs_verification_flag}
  ${enable_bootcache_flag}
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

# Basic command to emerge binary packages into the target image.
# Arguments to this command are passed as addition options/arguments
# to the basic emerge command.
emerge_to_image() {
  sudo -E ${EMERGE_BOARD_CMD} --root-deps=rdeps --usepkgonly -v \
    "$@" ${EMERGE_JOBS}
}
