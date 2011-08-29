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
IMAGE_SUBDIR="${CHROMEOS_VERSION_STRING}-a${FLAGS_build_attempt}"
OUTPUT_DIR="${FLAGS_output_root}/${BOARD}/${IMAGE_SUBDIR}"
OUTSIDE_OUTPUT_DIR="../build/images/${BOARD}/${IMAGE_SUBDIR}"


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

# Takes no arguments and populates the configuration for
# cros_make_image_bootable.
create_boot_desc() {
  local enable_rootfs_verification_flag=""
  if [[ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]]; then
    enable_rootfs_verification_flag="--enable_rootfs_verification"
  fi

  cat <<EOF > ${OUTPUT_DIR}/boot.desc
  --arch="${ARCH}"
  --output_dir="${OUTPUT_DIR}"
  --boot_args="${FLAGS_boot_args}"
  --rootfs_size="${FLAGS_rootfs_size}"
  --rootfs_hash_pad="${FLAGS_rootfs_hash_pad}"
  --rootfs_hash="${OUTPUT_DIR}/rootfs.hash"
  --rootfs_mountpoint="${ROOT_FS_DIR}"
  --statefulfs_mountpoint="${STATEFUL_FS_DIR}"
  --espfs_mountpoint="${ESP_FS_DIR}"
  --verity_error_behavior="${FLAGS_verity_error_behavior}"
  --verity_max_ios="${FLAGS_verity_max_ios}"
  --verity_algorithm="${FLAGS_verity_algorithm}"
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
    sudo rm -rf "${OUTPUT_DIR}"
    echo "Deleted ${OUTPUT_DIR}"
  else
    echo "Not deleting ${OUTPUT_DIR}."
  fi
}

generate_au_zip () {
  local lgenerateauzip="${BUILD_LIBRARY_DIR}/generate_au_zip.py"
  local largs="-o ${OUTPUT_DIR}"
  test ! -d "${OUTPUT_DIR}" && mkdir -p "${OUTPUT_DIR}"
  info "Running ${lgenerateauzip} ${largs} for generating AU updater zip file"
  $lgenerateauzip $largs
}
