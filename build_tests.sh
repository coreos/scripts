#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

assert_inside_chroot
assert_not_root_user

# Flags
DEFINE_string build_root "$DEFAULT_BUILD_ROOT"                \
  "Root of build output"
DEFINE_string board "" "Target board for which tests are to be built"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on error; print commands
set -e

TEST_DIRS="pam_google window_manager cryptohome"

if [ -n "$FLAGS_board" ]
then  
  sudo TEST_DIRS="${TEST_DIRS}" \
    emerge-${FLAGS_board} chromeos-base/chromeos-unittests
else 
  PLATFORM_DIR="$SRC_ROOT/platform"  
  
  # Build tests
  for i in ${TEST_DIRS}
  do
    echo "building $PLATFORM_DIR/$i"
    cd "$PLATFORM_DIR/$i"
    OUT_DIR="${FLAGS_build_root}/x86/tests" ./make_tests.sh
    cd -
  done

  echo "All tests built."
fi
