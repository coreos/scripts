#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a VirtualBox image.

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
. "${SCRIPT_ROOT}/common.sh" || (echo "Unable to load common.sh" && exit 1)
# --- END COMMON.SH BOILERPLATE ---

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

"${SCRIPTS_DIR}/image_to_vmware.sh" --format=virtualbox --from="$FLAGS_from" \
  --to="$(dirname "$FLAGS_to")" --vbox_disk="$(basename "$FLAGS_to")"
