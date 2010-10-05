#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Prints the path to the most recently built image to stdout.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

get_default_board

DEFINE_string board "$DEFAULT_BOARD" \
  "The name of the board to check for images."

# Parse command line flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Check on the board that they are trying to set up.
if [ -z "$FLAGS_board" ] ; then
  die "Error: --board required."
fi

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"

# If there are no images, return nothing
[ -d $IMAGES_DIR ] || exit 0

# Use latest link if it exists, otherwise most recently changed dir
if [ -L ${IMAGES_DIR}/latest ] ; then
  DEFAULT_FROM="${IMAGES_DIR}/`readlink ${IMAGES_DIR}/latest`"
else
  DEFAULT_FROM="${IMAGES_DIR}/`ls -t $IMAGES_DIR | head -1`"
fi

echo $DEFAULT_FROM
