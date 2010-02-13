#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script for building our own custom Chrome

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Script must be run outside the chroot
assert_outside_chroot

# This script defaults Chrome source is in ~/chrome
# You may override the Chrome source dir via the --chrome_dir option or by
# setting CHROMEOS_CHROME_DIR (for example, in ./.chromeos_dev)
DEFAULT_CHROME_DIR="${CHROMEOS_CHROME_DIR:-/home/$USER/chrome}"

# The number of jobs to pass to tools that can run in parallel (such as make
# and dpkg-buildpackage
NUM_JOBS=`grep -c "^processor" /proc/cpuinfo`

# Flags
DEFINE_string chrome_dir "$DEFAULT_CHROME_DIR" \
  "Directory to Chrome/Chromium source"
DEFINE_string mode "Release" \
  "The mode to build Chrome/Chromium in (Debug or Release)"
DEFINE_string num_jobs "$NUM_JOBS" \
  "The number of jobs to run in parallel"
DEFINE_boolean runhooks true \
  "Execute gclient runhooks before build (if norunhooks then chrome and official are ignored)"
DEFINE_boolean chrome false \
  "Builds a chrome branded version (requires src-internal)"
DEFINE_boolean official false \
  "Builds an official version (additional optimizations)"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on error; print commands
set -e

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f $FOO` won't work.
FLAGS_chrome_dir=`eval readlink -f $FLAGS_chrome_dir`

# Build Chrome
echo Building Chrome in mode $FLAGS_mode
export GYP_GENERATORS="make"
export GYP_DEFINES="target_arch=ia32 chromeos=1"

if [ $FLAGS_chrome -eq $FLAGS_TRUE ]
then
  export GYP_DEFINES="${GYP_DEFINES} branding=Chrome ffmpeg_branding=Chrome"
fi

if [ $FLAGS_official -eq $FLAGS_TRUE ]
then
  export GYP_DEFINES="${GYP_DEFINES} buildtype=Official"
fi

CHROME_DIR=$FLAGS_chrome_dir
cd "$CHROME_DIR/src"

if [ $FLAGS_runhooks -eq $FLAGS_TRUE ]
then
  gclient runhooks --force
fi

make BUILDTYPE=$FLAGS_mode -j$FLAGS_num_jobs -r chrome candidate_window

# Zip into chrome-chromeos.zip and put in local_assets
BUILD_DIR="$CHROME_DIR/src/out"
CHROME_LINUX_DIR="$BUILD_DIR/chrome-chromeos"
OUTPUT_DIR="${SRC_ROOT}/build/x86/local_assets"
OUTPUT_ZIP="$BUILD_DIR/chrome-chromeos.zip"
if [ -n "$OUTPUT_DIR" ]
then
  mkdir -p $OUTPUT_DIR
fi
# create symlink so that we can create the zip file with prefix chrome-chromeos
rm -f $CHROME_LINUX_DIR
ln -s $BUILD_DIR/$FLAGS_mode $CHROME_LINUX_DIR

echo Zipping $CHROME_LINUX_DIR to $OUTPUT_ZIP
cd $BUILD_DIR
rm -f $OUTPUT_ZIP
zip -r1 $OUTPUT_ZIP chrome-chromeos -i "chrome-chromeos/chrome*" \
  "chrome-chromeos/candidate_window" \
  "chrome-chromeos/libffmpegsumo.so" "chrome-chromeos/xdg-settings" \
  "chrome-chromeos/locales/*" "chrome-chromeos/resources/*" \
  "chrome-chromeos/*.png" "chrome-chromeos/session" \
  "chrome-chromeos/emit_login_prompt_ready" -x "*.d"
cp -f $OUTPUT_ZIP $OUTPUT_DIR
echo Done.
