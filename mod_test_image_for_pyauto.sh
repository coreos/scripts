#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to modify a keyfob-based chromeos test image to install pyauto.

SCRIPT_ROOT=$(dirname $(readlink -f "$0"))
. "${SCRIPT_ROOT}/common.sh" || { echo "Unable to load common.sh"; exit 1; }

cleanup() {
  "${SCRIPTS_DIR}/mount_gpt_image.sh" -u -r "$ROOT_FS_DIR" -s "$STATEFUL_FS_DIR"
}


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

FLAGS_build_root=$(eval readlink -f "${FLAGS_build_root}")
FLAGS_image=$(eval readlink -f "${FLAGS_image}")

IMAGE_DIR=$(dirname "${FLAGS_image}")
IMAGE_NAME=$(basename "${FLAGS_image}")
ROOT_FS_DIR="${IMAGE_DIR}/rootfs"
STATEFUL_FS_DIR="${IMAGE_DIR}/stateful"

PYAUTO_DEP="${FLAGS_build_root}/client/deps/pyauto_dep"
CHROME_DEP="${FLAGS_build_root}/client/deps/chrome_test"
VBOOT_DIR="${CHROOT_TRUNK_DIR}/src/platform/vboot_reference/scripts/"\
"image_signing"

if [ ! -d $PYAUTO_DEP ]; then
  die_notrace  "The required path: $PYAUTO_DEP does not exist.  Did you mean \
to pass --build_root and the path to the autotest bundle?"
fi

if [ ! -d $CHROME_DEP ]; then
  die_notrace "The required path: $CHROME_DEP does not exist.  Did you mean \
to pass --build_root and the path to the autotest bundle?"
fi

if [ ! -d $VBOOT_DIR ]; then
  die_notrace "The required path: $VBOOT_DIR does not exist.  This directory \
needs to be sync'd into your chroot.\n $ cros_workon start vboot_reference \
--board ${FLAGS_board}"
fi

if [ ! -d "${FLAGS_build_root}/client/cros" ]; then
  die "The required path: ${FLAGS_build_root}/client/cros does not exist."
fi

trap cleanup EXIT

cleanup EXIT

# Mounts gpt image and sets up var, /usr/local and symlinks.
"$SCRIPTS_DIR/mount_gpt_image.sh" -i "$IMAGE_NAME" -f "$IMAGE_DIR" \
  -r "$ROOT_FS_DIR" -s "$STATEFUL_FS_DIR"

STATEFUL_FS_AUTOTEST_DIR="${STATEFUL_FS_DIR}/dev_image/autotest"
IMAGE_TEST_SRC_DIR="${STATEFUL_FS_AUTOTEST_DIR}/deps/chrome_test/test_src"
IMAGE_RELEASE_DIR="${IMAGE_TEST_SRC_DIR}/out/Release"

sudo mkdir -p "${STATEFUL_FS_AUTOTEST_DIR}"
sudo mkdir -p "${IMAGE_TEST_SRC_DIR}"
sudo mkdir -p "${IMAGE_RELEASE_DIR}"

sudo cp -f -r "${FLAGS_build_root}/client/cros" "${STATEFUL_FS_AUTOTEST_DIR}"

# We want to copy everything that is in this directory except the out folder
# since it has very large test binaries that we don't need for pyauto.
info "Copying test source depedencies..."
for item in base chrome content net pdf third_party; do
  info "Copying $item to ${IMAGE_TEST_SRC_DIR}"
  sudo cp -f -r "${CHROME_DEP}/test_src/$item" "${IMAGE_TEST_SRC_DIR}"
done

info "Copying chrome dep components..."
sudo cp -f -r "${CHROME_DEP}/test_src/out/Release/setup_test_links.sh" \
    "${IMAGE_RELEASE_DIR}/"

info "Copying pyauto dependencies..."
sudo cp -r $PYAUTO_DEP "${STATEFUL_FS_AUTOTEST_DIR}/deps"

if [ $FLAGS_scrub -eq $FLAGS_TRUE ]; then
  IMAGE_TEST_DIR="${IMAGE_TEST_SRC_DIR}/chrome"
  sudo rm -rf \
    "${IMAGE_TEST_DIR}/data/" \
    "${IMAGE_TEST_DIR}/functional/"
  sudo mkdir \
    "${IMAGE_TEST_DIR}/data/" \
    "${IMAGE_TEST_DIR}/functional/"
  sudo cp "${CHROME_DEP}/test_src/chrome/test/functional/pyauto_functional.py" \
    "${IMAGE_TEST_DIR}/functional/"
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
    "${STATEFUL_FS_AUTOTEST_DIR}/deps/chrome_test/test_src/\
chrome/test/functional/example.py"
fi

# In some chroot configurations chronos is not configured, so we use 1000
sudo chown -R 1000 "${STATEFUL_FS_AUTOTEST_DIR}"
sudo chgrp -R 1000 "${STATEFUL_FS_AUTOTEST_DIR}"

# Based on how the autotest package is extracted, the user running in the chroot
# may not have access to navigate into this folder because only the owner
# (chronos) has access.  This fixes that so anyone can access.
sudo chmod 747 -R "${STATEFUL_FS_AUTOTEST_DIR}"

# Setup permissions and symbolic links
for item in chrome_test pyauto_dep; do
  pushd .
  cd "${STATEFUL_FS_AUTOTEST_DIR}/deps/$item/test_src/out/Release"
  sudo cp "${ROOT_FS_DIR}/usr/local/bin/python2.6" suid-python
  sudo chown root:root suid-python
  sudo chmod 4755 suid-python
  popd
done

# Add an easy link to get to the functional folder
 sudo ln -f -s \
  "/usr/local/autotest/deps/chrome_test/test_src/chrome/test/functional" \
  "${ROOT_FS_DIR}/pyauto"

info "Setting up pyauto required symbolic links..."
SETUP_LINKS="/usr/local/autotest/deps/chrome_test/test_src/out/\
Release/setup_test_links.sh"
sudo chroot "${ROOT_FS_DIR}" sudo bash "${SETUP_LINKS}"

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

