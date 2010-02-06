#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script makes autotest client tests inside an Ubuntu chroot
# environment.  The idea is to compile any platform-dependent autotest
# client tests in the build environment, since client systems under
# test lack the proper toolchain.
#
# The user can later run autotest against an ssh enabled test client system, or
# install the compiled client tests directly onto the rootfs image, using
# mod_image_for_test.sh.

. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/autotest_lib.sh"

# Script must be run inside the chroot
assert_inside_chroot

DEFAULT_CONTROL=client/site_tests/setup/control

DEFINE_string control "${DEFAULT_CONTROL}" \
  "Setup control file -- path relative to the destination autotest directory" c

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
update_chroot_autotest "${CHROOT_TRUNK_DIR}/src/third_party/autotest/files"

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

# Export GCLIENT_ROOT so that tests have access to the source and build trees
export GCLIENT_ROOT

# run the magic test setup script.
echo "Building tests using ${FLAGS_control}..."
client/bin/autotest ${FLAGS_control}
