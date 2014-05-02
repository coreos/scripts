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
  IMAGE_SUBDIR="${FLAGS_group}-${COREOS_VERSION_STRING}-a${FLAGS_build_attempt}"
else
  IMAGE_SUBDIR="${FLAGS_group}-${FLAGS_version}"
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
      \'prod\' )
        IMAGES_TO_BUILD="${IMAGES_TO_BUILD} ${COREOS_PRODUCTION_IMAGE_NAME}"
        ;;
      \'base\' )
        IMAGES_TO_BUILD="${IMAGES_TO_BUILD} ${CHROMEOS_BASE_IMAGE_NAME}"
        ;;
      \'dev\' )
        IMAGES_TO_BUILD="${IMAGES_TO_BUILD} ${CHROMEOS_DEVELOPER_IMAGE_NAME}"
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

should_build_image() {
  # Fast pass back if we should build all incremental images.
  local image_name
  local image_to_build

  for image_name in "$@"; do
    for image_to_build in ${IMAGES_TO_BUILD}; do
      [ "${image_to_build}" = "${image_name}" ] && return 0
    done
  done

  return 1
}

# Utility function for creating a copy of an image prior to
# modification from the BUILD_DIR:
#  $1: source filename
#  $2: destination filename
copy_image() {
  local src="${BUILD_DIR}/$1"
  local dst="${BUILD_DIR}/$2"
  if should_build_image $1; then
    echo "Creating $2 from $1..."
    cp --sparse=always "${src}" "${dst}" || die "Cannot copy $1 to $2"
  else
    mv "${src}" "${dst}" || die "Cannot move $1 to $2"
  fi
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

cleanup_mounts() {
  echo "Cleaning up mounts"
  "${BUILD_LIBRARY_DIR}/disk_util" umount "$1" || true
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

generate_update() {
  local image_name="$1"
  local disk_layout="$2"
  local update_prefix="${image_name%_image.bin}_update"
  local update="${BUILD_DIR}/${update_prefix}"
  local devkey="/usr/share/update_engine/update-payload-key.key.pem"

  echo "Generating update payload, signed with a dev key"
  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
    extract "${BUILD_DIR}/${image_name}" "USR-A" "${update}.bin"
  delta_generator -private_key "${devkey}" \
    -new_image "${update}.bin" -out_file "${update}.gz"
  delta_generator -private_key "${devkey}" \
    -in_file "${update}.gz" -out_metadata "${update}.meta"

  info "Generating update tools zip"
  # Make sure some vars this script needs are exported
  export REPO_MANIFESTS_DIR SCRIPTS_DIR
  "${BUILD_LIBRARY_DIR}/generate_au_zip.py" \
    --output-dir "${BUILD_DIR}" --zip-name "${update_prefix}.zip"

  upload_image -d "${update}.DIGESTS" "${update}".{bin,gz,meta,zip}
}

# Basic command to emerge binary packages into the target image.
# Arguments to this command are passed as addition options/arguments
# to the basic emerge command.
emerge_to_image() {
  local mask="${INSTALL_MASK:-$(portageq-$BOARD envvar PROD_INSTALL_MASK)}"
  test -n "$mask" || die "PROD_INSTALL_MASK not defined"

  local emerge_cmd
  if [[ "${FLAGS_fast}" -eq "${FLAGS_TRUE}" ]]; then
    emerge_cmd="$GCLIENT_ROOT/chromite/bin/parallel_emerge --board=$BOARD"
  else
    emerge_cmd="emerge-$BOARD"
  fi
  emerge_cmd+=" --root-deps=rdeps --usepkgonly -v"

  if [[ $FLAGS_jobs -ne -1 ]]; then
    emerge_cmd+=" --jobs=$FLAGS_jobs"
  fi

  sudo -E INSTALL_MASK="$mask" ${emerge_cmd} "$@"
}

# The GCC package includes both its libraries and the compiler.
# In prod images we only need the shared libraries.
emerge_prod_gcc() {
    local mask="${INSTALL_MASK:-$(portageq-$BOARD envvar PROD_INSTALL_MASK)}"
    test -n "$mask" || die "PROD_INSTALL_MASK not defined"

    mask="${mask}
        /usr/bin
        /usr/*/gcc-bin
        /usr/lib/gcc/*/*/*.o
        /usr/lib/gcc/*/*/include
        /usr/lib/gcc/*/*/include-fixed
        /usr/lib/gcc/*/*/plugin
        /usr/libexec
        /usr/share/gcc-data/*/*/c89
        /usr/share/gcc-data/*/*/c99
        /usr/share/gcc-data/*/*/python"

    INSTALL_MASK="${mask}" emerge_to_image --nodeps sys-devel/gcc "$@"
}
