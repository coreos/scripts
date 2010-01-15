#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script makes autotest client tests inside an Ubuntu chroot
# environment.  The idea is to compile any platform-dependent autotest
# client tests in the build environment, since client systems under
# test lack the proper toolchain.
#
# The user can enter_chroot later and run autotest against an ssh
# enabled test client system, or install the compiled client tests
# directly onto the rootfs image, using mod_image_for_test.

. "$(dirname "$0")/common.sh"

# Script must be run inside the chroot
assert_inside_chroot

# More useful help
FLAGS_HELP="usage: $0 [flags]"

# parse the command-line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
set -e

AUTOTEST_SRC="${GCLIENT_ROOT}/src/third_party/autotest/files"
# Destination in chroot to install autotest.
AUTOTEST_DEST="/usr/local/autotest"

# Copy a local "installation" of autotest into the chroot, to avoid
# polluting the src dir with tmp files, results, etc.
echo -n "Installing Autotest... "
sudo mkdir -p ${AUTOTEST_DEST}
sudo chmod 777 ${AUTOTEST_DEST}
cd ${CHROOT_TRUNK_DIR}/src/third_party/autotest/files
cp -fpru {client,conmux,server,tko,utils,global_config.ini,shadow_config.ini} \
    ${AUTOTEST_DEST}

# Create python package init files for top level test case dirs.
function touchInitPy() {
  local dirs=${1}
  for base_dir in $dirs
  do
    local sub_dirs="$(find ${base_dir} -maxdepth 1 -type d)"
    for sub_dir in ${sub_dirs}
    do
      touch ${sub_dir}/__init__.py
    done
  touch ${base_dir}/__init__.py
  done
}

cd ${AUTOTEST_DEST}
touchInitPy client/tests client/site_tests
touch __init__.py

# run the magic test setup script.
client/bin/autotest client/site_tests/setup/control
