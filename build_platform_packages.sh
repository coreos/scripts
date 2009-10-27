#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Script must be run inside the chroot
assert_inside_chroot

# Flags

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on error
set -e

PLATFORM_DIR="$SRC_ROOT/platform"

PLATFORM_DIRS="assets control_panel fake_hal init installer login_manager \
               memento_softwareupdate pam_google window_manager \
               control_panel cros chrome wifi screenlocker cryptohome \
               monitor_reconfig"

THIRD_PARTY_DIR="$SRC_ROOT/third_party"
THIRD_PARTY_PACKAGES="connman e2fsprogs/files gflags gtest glog \
                      ply-image slim/src synaptics \
                      wpa_supplicant xscreensaver/xscreensaver-5.08 \
                      xserver-xorg-core xserver-xorg-video-intel"

# Build third_party packages first, since packages and libs depend on them.
for i in $THIRD_PARTY_PACKAGES
do
  echo "Building package ${i}..."
  cd "$THIRD_PARTY_DIR/$i"
  ./make_pkg.sh
  cd -
done

# Build base lib next, since packages depend on it.
echo "Building base library..."
cd "$PLATFORM_DIR/base"
scons
cd -

#Build common lib next.
echo "Building common library..."
cd "$SRC_ROOT/common"
scons
cd -

# Build platform packages
for i in $PLATFORM_DIRS
do
  echo "Building package ${i}..."
  cd "$PLATFORM_DIR/$i"
  ./make_pkg.sh
  cd -
done

echo "All packages built."
