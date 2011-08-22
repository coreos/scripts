# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This global array variable is used to remember options from
# mount_image so that unmount_image can do its job.
MOUNT_GPT_OPTIONS=( )

# mount_image - Mount the root, stateful, and optionally ESP partitions
#   in a Chromium OS image.
# $1: path to image to be mounted
# $2: path to root fs mount point
# $3: path to stateful fs mount point
# $4: path to ESP fs mount point; if empty the ESP will not be mounted
mount_image() {
  local image_dir="$(dirname $1)"
  local image="$(basename $1)"
  MOUNT_GPT_OPTIONS=( -r "$2" -s "$3" )

  if [ $# -ge 4 ]; then
    MOUNT_GPT_OPTIONS=( "${MOUNT_GPT_OPTIONS[@]}" -e "$4" )
  fi

  "${SCRIPTS_DIR}/mount_gpt_image.sh" --from="$image_dir" --image="$image" \
    "${MOUNT_GPT_OPTIONS[@]}"
}

# unmount_image - Unmount the file systems mounted in the previous
#   call to mount_image.
# No arguments
unmount_image() {
  "${SCRIPTS_DIR}/mount_gpt_image.sh" -u "${MOUNT_GPT_OPTIONS[@]}"

  MOUNT_GPT_OPTIONS=( )
}
