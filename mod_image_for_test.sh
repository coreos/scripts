#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to modify a keyfob-based chromeos system image for testability.
#
# N.B.  This script duplicates function provided by
# "build_image --test"; that command option is the preferred
# command line interface for creating a test image.  Please don't
# add features (options, command line syntax, whatever) to this
# script, unless it's necessary to maintain compatibility with
# "build_image".
#
# TODO(vlaviano): delete this script.

SCRIPT_ROOT=$(dirname "$0")
. "${SCRIPT_ROOT}/build_library/build_common.sh" || exit 1


DEFINE_string board "$DEFAULT_BOARD" "Board for which the image was built" b
DEFINE_boolean factory $FLAGS_FALSE \
    "Modify the image for manufacturing testing" f
DEFINE_string image "" "Location of the rootfs raw image file" i
DEFINE_boolean installmask $FLAGS_TRUE \
    "Use INSTALL_MASK to shrink the resulting image." m
DEFINE_integer jobs -1 \
    "How many packages to build in parallel at maximum." j
DEFINE_boolean yes $FLAGS_FALSE "Answer yes to all prompts" y
DEFINE_string build_root "/build" \
    "The root location for board sysroots."
DEFINE_boolean fast $DEFAULT_FAST "Call many emerges in parallel"
DEFINE_boolean inplace $FLAGS_TRUE \
    "Modify/overwrite the image $CHROMEOS_IMAGE_NAME in place.  \
Otherwise the image will be copied to $CHROMEOS_TEST_IMAGE_NAME \
(or $CHROMEOS_FACTORY_TEST_IMAGE_NAME for --factory) if needed, and \
modified there"
DEFINE_boolean force_copy $FLAGS_FALSE \
    "Always rebuild test image if --noinplace"
DEFINE_boolean standard_backdoor ${FLAGS_TRUE} \
  "Install standard backdoor credentials for testing"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "$FLAGS_ARGV"

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'set -e' is specified before now.
set -e

. "${BUILD_LIBRARY_DIR}/board_options.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/mount_gpt_util.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/test_image_util.sh" || exit 1


# We have a board name but no image set.  Use image at default location
if [ -z "$FLAGS_image" ]; then
  IMAGES_DIR="$DEFAULT_BUILD_ROOT/images/$BOARD"
  FILENAME="$CHROMEOS_IMAGE_NAME"
  FLAGS_image="$IMAGES_DIR/$(ls -t $IMAGES_DIR 2>&-| head -1)/$FILENAME"
fi

# Turn path into an absolute path.
FLAGS_image=$(eval readlink -f "$FLAGS_image")


IMAGE_DIR=$(dirname "$FLAGS_image")
ROOT_FS_DIR="${IMAGE_DIR}/rootfs"
STATEFUL_FS_DIR="${IMAGE_DIR}/stateful_partition"

# Copy the image to a test location if required
if [ $FLAGS_inplace -eq $FLAGS_FALSE ]; then
  if [ $FLAGS_factory -eq $FLAGS_TRUE ]; then
    TEST_PATHNAME="$IMAGE_DIR/$CHROMEOS_FACTORY_TEST_IMAGE_NAME"
  else
    TEST_PATHNAME="$IMAGE_DIR/$CHROMEOS_TEST_IMAGE_NAME"
  fi
  if [ ! -f "$TEST_PATHNAME" -o $FLAGS_force_copy -eq $FLAGS_TRUE ]; then
    copy_image "$FLAGS_image" "$TEST_PATHNAME"
    FLAGS_image="$TEST_PATHNAME"
  else
    echo "Using cached $(basename "$FLAGS_image")"
    exit
  fi

  # No need to confirm now, since we are not overwriting the main image
  FLAGS_yes=$FLAGS_TRUE
fi

# Abort early if we can't find the image
if [ ! -f "$FLAGS_image" ]; then
  echo "No image found at $FLAGS_image"
  exit 1
fi

# Make sure this is really what the user wants, before nuking the device
if [ $FLAGS_yes -ne $FLAGS_TRUE ]; then
  read -p "Modifying image $FLAGS_image for test; are you sure (y/N)? " SURE
  SURE="${SURE:0:1}" # Get just the first character
  if [ "$SURE" != "y" ]; then
    echo "Ok, better safe than sorry."
    exit 1
  fi
else
  echo "Modifying image $FLAGS_image for test..."
fi

mod_image_for_test "$FLAGS_image"

print_time_elapsed
