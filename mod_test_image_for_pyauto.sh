#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to modify a keyfob-based chromeos test image to have pyauto installed.

# --- BEGIN COMMON.SH BOILERPLATE ---
# Load common CrOS utilities.  Inside the chroot this file is installed in
# /usr/lib/crosutils.  Outside the chroot we find it relative to the script's
# location.
find_common_sh() {
  local common_paths=(/usr/lib/crosutils $(dirname "$(readlink -f "$0")"))
  local path

  SCRIPT_ROOT=
  for path in "${common_paths[@]}"; do
    if [ -r "${path}/common.sh" ]; then
      SCRIPT_ROOT=${path}
      break
    fi
  done
}

cleanup() {
  "${SCRIPTS_DIR}/mount_gpt_image.sh" -u -r "$ROOT_FS_DIR"
}

find_common_sh
. "${SCRIPT_ROOT}/common.sh" || { echo "Unable to load common.sh"; exit 1; }
# --- END COMMON.SH BOILERPLATE ---

# Need to be inside the chroot to load chromeos-common.sh
assert_inside_chroot

get_default_board

DEFINE_string board "$DEFAULT_BOARD" "Board for which the image was built" b
DEFINE_string image "$FLAGS_image" "Location of the test image file" i
DEFINE_string build_root "/build" \
   "The root location for board sysroots, override with autotest bundle"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "$FLAGS_ARGV"

if [ "${FLAGS_build_root}" = "/build" ]; then
  FLAGS_build_root="/build/${FLAGS_board}/usr/local/autotest"
fi

IMAGE_DIR=$(dirname "$FLAGS_image")
IMAGE_NAME=$(basename "$FLAGS_image")
ROOT_FS_DIR="${IMAGE_DIR}/rootfs"

PYAUTO_DEP="${FLAGS_build_root}/client/deps/pyauto_dep"
CHROME_DEP="${FLAGS_build_root}/client/deps/chrome_test"

if [ ! -d $PYAUTO_DEP ]; then
  die "The required path: $PYAUTO_DEP does not exist.  Did you mean to pass \
--build_root and the path to the autotest bundle?"
fi

if [ ! -d $CHROME_DEP ]; then
  die "The required path: $CHROME_DEP does not exist.  Did you mean to pass \
--build_root and the path to the autotest bundle?"
fi

trap cleanup EXIT

# Mounts gpt image and sets up var, /usr/local and symlinks.
"$SCRIPTS_DIR/mount_gpt_image.sh" -i "$IMAGE_NAME" -f "$IMAGE_DIR" \
  -r "$ROOT_FS_DIR"

# Copy all of the needed pyauto deps onto the image
sudo mkdir "${ROOT_FS_DIR}/usr/local/autotest"
sudo mkdir "${ROOT_FS_DIR}/usr/local/autotest/deps/"
sudo cp -r "${FLAGS_build_root}/client/cros" \
  "${ROOT_FS_DIR}/usr/local/autotest/"
sudo cp -r $CHROME_DEP "${ROOT_FS_DIR}/usr/local/autotest/deps"
sudo cp -r $PYAUTO_DEP "${ROOT_FS_DIR}/usr/local/autotest/deps"

# Setup permissions and symbolic links
for item in chrome_test pyauto_dep; do
  echo $item
  pushd .
  cd "${ROOT_FS_DIR}/usr/local/autotest/deps/$item/test_src/out/Release"
  sudo cp "${ROOT_FS_DIR}/usr/local/bin/python2.6" suid-python
  sudo chown root:root suid-python
  sudo chmod 4755 suid-python
  sudo sh setup_test_links.sh
  popd
done

cleanup

# Now make it bootable with the flags from build_image
"${SCRIPTS_DIR}/bin/cros_make_image_bootable" "$(dirname "${FLAGS_image}")" \
                                            "$(basename "${FLAGS_image}")" \
                                            --force_developer_mode
