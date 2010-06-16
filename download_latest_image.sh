#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Downloads the latest buildbot image and prints the path to it.
# This only works internally at Google.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

get_default_board

DEFINE_string board "$DEFAULT_BOARD" \
  "The name of the board to check for images."
DEFINE_boolean incremental "${FLAGS_FALSE}" "Download incremental build"

# Parse command line flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Check on the board that they are trying to set up.
if [ -z "$FLAGS_board" ] ; then
  echo "Error: --board required."
  exit 1
fi

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"

if [ $FLAGS_board = x86-generic ]; then
  if [ "$FLAGS_incremental" -eq "$FLAGS_TRUE" ]; then
    URL_PREFIX="http://codg174.jail.google.com/archive/x86-generic-inc"
  else
    URL_PREFIX="http://codg163.jail.google.com/archive/x86-generic-rel"
  fi
else
  echo "Unrecognized board: $FLAGS_board" >&2
  exit 1
fi

LATEST_BUILD=$(curl -s $URL_PREFIX/LATEST)
LATEST_IMAGE_DIR="$IMAGES_DIR/$LATEST_BUILD"
if [ ! -e $LATEST_IMAGE_DIR/chromiumos_base_image.bin ]; then
  mkdir -p $LATEST_IMAGE_DIR
  curl $URL_PREFIX/$LATEST_BUILD/image.zip -o $LATEST_IMAGE_DIR/image.zip \
      || die "Could not download image.zip"
  ( cd $LATEST_IMAGE_DIR && unzip -qo image.zip ) \
      || die "Could not unzip image.zip"
fi

echo $LATEST_IMAGE_DIR
exit 0
