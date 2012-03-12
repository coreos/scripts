#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Prints the path to the most recently built image to stdout.

SCRIPT_ROOT=$(dirname $(readlink -f "$0"))
. "${SCRIPT_ROOT}/common.sh" || exit 1

DEFINE_string board "$DEFAULT_BOARD" \
  "The name of the board to check for images."

# Parse command line flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Check on the board that they are trying to set up.
if [ -z "$FLAGS_board" ] ; then
  die_notrace "Error: --board required."
fi

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"

# If there are no images, error out since presumably the
# caller isn't doing this for fun.
if [[ ! -d ${IMAGES_DIR} ]] ; then
  die_notrace \
      "${IMAGES_DIR} does not exist; have you run ./build_image?"
fi

# Use latest link if it exists, otherwise most recently changed dir
if [ -L ${IMAGES_DIR}/latest ] ; then
  if ! dst=$(readlink "${IMAGES_DIR}"/latest) ; then
    die_notrace "Could not read ${IMAGES_DIR}/latest; have you run ./build_image?"
  fi
  DEFAULT_FROM="${IMAGES_DIR}/${dst}"
else
  DEFAULT_FROM=$(ls -dt "$IMAGES_DIR"/*/ | head -1)
fi

echo $DEFAULT_FROM
