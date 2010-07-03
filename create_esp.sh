#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Creates an empty ESP image.

. "$(dirname "$0")/common.sh"

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
# BIOS). We only need this for x86, but it's simpler and safer to keep the
# disk images the same for both x86 and ARM.
# NOTE: The size argument for mkfs.vfat is in 1024-byte blocks.
# We'll hard-code it to 16M for now.
ESP_BLOCKS=16384
/usr/sbin/mkfs.vfat -C "${FLAGS_to}" ${ESP_BLOCKS}
