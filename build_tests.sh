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

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on error; print commands
set -e

PLATFORM_DIR="$SRC_ROOT/platform"
PLATFORM_DIRS="pam_google window_manager cryptohome"

# Build tests
for i in $PLATFORM_DIRS
do
  echo "building $PLATFORM_DIR/$i"
  cd "$PLATFORM_DIR/$i"
  ./make_tests.sh
  cd -
done

echo "All tests built."
