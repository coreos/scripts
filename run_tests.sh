#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Script must be run inside the chroot
restart_in_chroot_if_needed $*
get_default_board

# Flags
DEFINE_string build_root "$DEFAULT_BUILD_ROOT" \
  "Root of build output"
DEFINE_string board "$DEFAULT_BOARD" \
  "Target board of which tests were built"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Run tests
if [ -z "$FLAGS_board" ]; then
  echo Error: --board required
  exit 1
fi

TESTS_DIR="/build/${FLAGS_board}/tests"
LD_LIBRARY_PATH=/build/${FLAGS_board}/lib:/build/${FLAGS_board}/usr/lib:\
/build/${FLAGS_board}/usr/lib/gcc/i686-pc-linux-gnu/4.4.1/:\
/build/${FLAGS_board}/usr/lib/opengl/xorg-x11/lib

# Die on error; print commands
set -ex

# NOTE: We currently skip cryptohome_tests (which happens to have a different
# suffix than the other tests), because it doesn't work.
for i in /build/${FLAGS_board}/tests/*_{test,unittests}; do
  if [[ "`file -b $i`" = "POSIX shell script text executable" ]]; then
    LD_LIBRARY_PATH=$LD_LIBRARY_PATH /build/${FLAGS_board}/lib/ld-linux.so.2 /build/${FLAGS_board}/bin/bash $i
  else
    LD_LIBRARY_PATH=$LD_LIBRARY_PATH /build/${FLAGS_board}/lib/ld-linux.so.2 $i
  fi
done

