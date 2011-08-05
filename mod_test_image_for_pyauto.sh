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
DEFINE_boolean scrub "$FLAGS_FALSE" "Don't include pyauto tests and data" s
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
VBOOT_DIR="${CHROOT_TRUNK_DIR}/src/platform/vboot_reference/scripts/"\
"image_signing"

echo ${CHROOT_TRUNK_DIR}

if [ ! -d $PYAUTO_DEP ]; then
  die "The required path: $PYAUTO_DEP does not exist.  Did you mean to pass \
--build_root and the path to the autotest bundle?"
fi

if [ ! -d $CHROME_DEP ]; then
  die "The required path: $CHROME_DEP does not exist.  Did you mean to pass \
--build_root and the path to the autotest bundle?"
fi

if [ ! -d $VBOOT_DIR ]; then
  die "The required path: $VBOOT_DIR does not exist.  This directory needs to \
be sync'd into your chroot."
fi

trap cleanup EXIT

# Mounts gpt image and sets up var, /usr/local and symlinks.
"$SCRIPTS_DIR/mount_gpt_image.sh" -i "$IMAGE_NAME" -f "$IMAGE_DIR" \
  -r "$ROOT_FS_DIR"

ROOT_FS_AUTOTEST_DIR="${ROOT_FS_DIR}/usr/local/autotest"

# Copy all of the needed pyauto deps onto the image
sudo mkdir "${ROOT_FS_AUTOTEST_DIR}"
sudo mkdir "${ROOT_FS_DIR}/usr/local/autotest/deps/"
sudo cp -r "${FLAGS_build_root}/client/cros" \
  "${ROOT_FS_DIR}/usr/local/autotest/"
sudo cp -r $CHROME_DEP "${ROOT_FS_DIR}/usr/local/autotest/deps"
sudo cp -r $PYAUTO_DEP "${ROOT_FS_DIR}/usr/local/autotest/deps"

if [ $FLAGS_scrub -eq $FLAGS_TRUE ]; then
  sudo rm -rf \
    "${ROOT_FS_AUTOTEST_DIR}/deps/chrome_test/test_src/chrome/test/data/" \
    "${ROOT_FS_AUTOTEST_DIR}/deps/chrome_test/test_src/chrome/test/functional/"
  sudo mkdir \
    "${ROOT_FS_AUTOTEST_DIR}/deps/chrome_test/test_src/chrome/test/data/" \
    "${ROOT_FS_AUTOTEST_DIR}/deps/chrome_test/test_src/chrome/test/functional/"
  # Create an example pyauto test.
  echo -e "#!/usr/bin/python\n\
# Copyright (c) 2011 The Chromium Authors. All rights reserved.\n\
# Use of this source code is governed by a BSD-style license that can be\n\
# found in the LICENSE file.\n\
\n\
import os\n\
import subprocess\n\
\n\
import pyauto_functional  # Must be imported before pyauto\n\
import pyauto\n\
\n\
class ChromeosDemo(pyauto.PyUITest):\n\
  \"\"\"Example PyAuto test for ChromeOS.\n\
\n\
  To run this test, you must be logged into the Chromebook as root.  Then run\n\
  the following command:\n\
  $ python example.py\n\
  \"\"\"\n\
\n\
  assert os.geteuid() == 0, 'Need to run this test as root'\n\
\n\
  def testLoginAsGuest(self):\n\
    \"\"\"Test we can login with guest mode.\"\"\"\n\
    self.LoginAsGuest()\n\
    login_info = self.GetLoginInfo()\n\
    self.assertTrue(login_info['is_logged_in'], msg='Not logged in at all.')\n\
    self.assertTrue(login_info['is_guest'], msg='Not logged in as guest.')\n\
\n\
if __name__ == '__main__':\n\
  pyauto_functional.Main()" > "/tmp/example.py"
  sudo cp "/tmp/example.py" \
    "${ROOT_FS_AUTOTEST_DIR}/deps/chrome_test/test_src/\
chrome/test/functional/example.py"
fi

sudo chown -R chronos "${ROOT_FS_DIR}/usr/local/autotest"
sudo chgrp -R chronos "${ROOT_FS_DIR}/usr/local/autotest"

# Setup permissions and symbolic links
for item in chrome_test pyauto_dep; do
  pushd .
  cd "${ROOT_FS_DIR}/usr/local/autotest/deps/$item/test_src/out/Release"
  sudo cp "${ROOT_FS_DIR}/usr/local/bin/python2.6" suid-python
  sudo chown root:root suid-python
  sudo chmod 4755 suid-python
  sudo sh setup_test_links.sh
  popd
done

# Add an easy link to get to the functional folder
 sudo ln -f -s \
  "/usr/local/autotest/deps/chrome_test/test_src/chrome/test/functional" \
  "${ROOT_FS_DIR}/pyauto"

cleanup

# cros_make_image_bootable is unstable (crosbug.com/18709)
DEVKEYS_DIR="${CHROOT_TRUNK_DIR}/src/platform/vboot_reference/tests/devkeys/"
TMP_BIN_PATH="$(dirname "${FLAGS_image}")/pyauto_tmp.bin"

echo ${TMP_BIN_PATH}

rm -f "${TMP_BIN_PATH}"

"${VBOOT_DIR}/sign_official_build.sh" usb "${FLAGS_image}" \
                                     "${DEVKEYS_DIR}" \
                                     "${TMP_BIN_PATH}" \

rm -f "${FLAGS_image}"
mv "${TMP_BIN_PATH}" "${FLAGS_image}"

