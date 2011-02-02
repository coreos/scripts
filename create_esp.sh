#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Creates an empty ESP image.

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

get_default_board

# Flags.
DEFINE_string to "/tmp/esp.img" \
  "Path to esp image (Default: /tmp/esp.img)"

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
set -e

if [[ -e "${FLAGS_to}" ]]; then
  info "ESP already exists: ${FLAGS_to}"
  exit 0
fi

info "Creating a new esp image at ${FLAGS_to}" anyway.
# Create EFI System Partition to boot stock EFI BIOS (but not ChromeOS EFI
# BIOS).  ARM uses this space to determine which partition is bootable.
# NOTE: The size argument for mkfs.vfat is in 1024-byte blocks.
# We'll hard-code it to 16M for now.
ESP_BLOCKS=16384
/usr/sbin/mkfs.vfat -C "${FLAGS_to}" ${ESP_BLOCKS}
