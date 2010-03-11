#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a VirtualBox image.
# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images"
# Default to the most recent image
DEFAULT_FROM="${IMAGES_DIR}/`ls -t $IMAGES_DIR | head -1`"
DEFAULT_TO="${DEFAULT_FROM}/os.vdi"
TEMP_IMAGE="${IMAGES_DIR}/temp.img"

# Flags
DEFINE_string from "$DEFAULT_FROM" \
  "Directory containing rootfs.image and mbr.image"
DEFINE_string to "$DEFAULT_TO" \
  "Destination file for VirtualBox image"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

# Convert args to paths.  Need eval to un-quote the string so that shell 
# chars like ~ are processed; just doing FOO=`readlink -f $FOO` won't work.
FLAGS_from=`eval readlink -f $FLAGS_from`
FLAGS_to=`eval readlink -f $FLAGS_to`

# Check if qemu-img and VBoxManage are available.
for EXTERNAL_tools in qemu-img VBoxManage; do
  if ! type ${EXTERNAL_tools} >/dev/null 2>&1; then
    echo "Error: This script requires ${EXTERNAL_tools}."
    exit 1
  fi
done

$(dirname "$0")/image_to_vmware.sh --format=virtualbox --from=$FLAGS_from \
  --to=$(dirname "$FLAGS_to") --vbox_disk=$(basename "$FLAGS_to")
