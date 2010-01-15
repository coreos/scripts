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
DEFINE_boolean stable $FLAGS_FALSE "Build with stable version of browser."
DEFINE_boolean new_build $FLAGS_FALSE "Use chromiumos-build."
DEFINE_string architecture i386 "The architecture to build for (--new_build only)." a

# Fix up the command line and parse with shflags.
FIXED_FLAGS="$@"
FIXED_FLAGS=${FIXED_FLAGS/new-build/new_build}
FLAGS $FIXED_FLAGS || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on error
set -e

# Number of jobs for scons calls.
NUM_JOBS=`grep -c "^processor" /proc/cpuinfo`

PLATFORM_DIR="$SRC_ROOT/platform"

PLATFORM_DIRS="acpi assets fake_hal init installer login_manager \
               memento_softwareupdate pam_google window_manager \
               cros chrome screenlocker cryptohome \
               monitor_reconfig microbenchmark minijail metrics_collection \
               theme metrics_daemon"

THIRD_PARTY_DIR="$SRC_ROOT/third_party"
THIRD_PARTY_PACKAGES="e2fsprogs/files flimflam \
                      gflags google-breakpad gpt gtest gmock \
                      ibus ibus-chewing ibus-anthy ibus-hangul ibus-m17n \
                      ply-image slim/src synaptics \
                      upstart/files wpa_supplicant \
                      xscreensaver/xscreensaver-5.08 xserver-xorg-core \
                      xserver-xorg-video-intel"

if [ $FLAGS_stable -eq $FLAGS_TRUE ]
then
  # Passed to copy_chrome_zip.sh to get stable version of the browser
  export GET_STABLE_CHROME=1
fi

if [ $FLAGS_new_build -eq $FLAGS_TRUE ]; then
  # chromiumos-build works out the build order for itself.
  PACKAGES='dh-chromeos libchrome libchromeos'
  for PKG in $PLATFORM_DIRS $THIRD_PARTY_PACKAGES; do
    PACKAGES="$PACKAGES ${PKG%/*}"
  done
  echo chromiumos-build -a "$FLAGS_architecture" --apt-source $PACKAGES
  chromiumos-build -a "$FLAGS_architecture" --apt-source $PACKAGES
else
  # Build dh-chromeos really first. Some of third_party needs it.
  echo "Building package dh-chromeos..."
  cd "$PLATFORM_DIR/dh-chromeos"
  ./make_pkg.sh
  cd -

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
  cd "$THIRD_PARTY_DIR/chrome"
  ./make_pkg.sh
  cd -

  #Build common lib next.
  echo "Building common library..."
  cd "$SRC_ROOT/common"
  ./make_pkg.sh
  cd -

  # Build platform packages
  for i in $PLATFORM_DIRS
  do
    echo "Building package ${i}..."
    cd "$PLATFORM_DIR/$i"
    ./make_pkg.sh
    cd -
  done
fi

echo "All packages built."
