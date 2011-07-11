#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Prints the path to the most recently built image to stdout.

# --- BEGIN COMMON.SH BOILERPLATE ---
# Load common CrOS utilities.  Inside the chroot this file is installed in
# /usr/lib/crosutils.  Outside the chroot we find it relative to the script's
# location.
find_common_sh() {
  local common_paths=(/usr/lib/crosutils $(dirname "$(readlink -f "$0")"))
  local path

  SCRIPT_ROOT=
  for path in "${common_paths[@]}"; do
    if [ -r "${path}/common.sh" ]; then
      SCRIPT_ROOT=${path}
      break
    fi
  done
}

find_common_sh
. "${SCRIPT_ROOT}/common.sh" || { echo "Unable to load common.sh"; exit 1; }
# --- END COMMON.SH BOILERPLATE ---

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
