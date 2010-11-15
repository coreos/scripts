#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script contains common utility function to deal with disk images,
# especially for being redistributed into platforms without complete Chromium OS
# developing environment.

# Check if given command is available in current system
has_command() {
  type "$1" >/dev/null 2>&1
}

err_die() {
  echo "ERROR: $@" >&2
  exit 1
}

# Finds the best gzip compressor and invoke it.
gzip_compress() {
  if has_command pigz; then
    # echo " ** Using parallel gzip **" >&2
    # Tested with -b 32, 64, 128(default), 256, 1024, 16384, and -b 32 (max
    # window size of Deflate) seems to be the best in output size.
    pigz -b 32 "$@"
  else
    gzip "$@"
  fi
}

# Finds if current system has tools for part_* commands
has_part_tools() {
  has_command cgpt || has_command parted
}

# Finds the best partition tool and print partition offset
part_offset() {
  local file="$1"
  local partno="$2"

  if has_command cgpt; then
    cgpt show -b -i "$partno" "$file"
  elif has_command parted; then
    parted -m "$file" unit s print |
      grep "^$partno:" | cut -d ':' -f 2 | sed 's/s$//'
  else
    exit 1
  fi
}

# Finds the best partition tool and print partition size
part_size() {
  local file="$1"
  local partno="$2"

  if has_command cgpt; then
    cgpt show -s -i "$partno" "$file"
  elif has_command parted; then
    parted -m "$file" unit s print |
      grep "^$partno:" | cut -d ':' -f 4 | sed 's/s$//'
  else
    exit 1
  fi
}

# Dumps a file by given offset and size (in sectors)
dump_partial_file() {
  local file="$1"
  local offset="$2"
  local sectors="$3"
  local bs=512

  # Try to use larger buffer if offset/size can be re-aligned.
  # 2M / 512 = 4096
  local buffer_ratio=4096
  if [ $((offset % buffer_ratio)) -eq 0 -a \
       $((sectors % buffer_ratio)) -eq 0 ]; then
    offset=$((offset / buffer_ratio))
    sectors=$((sectors / buffer_ratio))
    bs=$((bs * buffer_ratio))
  fi

  if has_command pv; then
    dd if="$file" bs=$bs skip="$offset" count="$sectors" \
      oflag=sync status=noxfer 2>/dev/null |
      pv -ptreb -B 4m -s $((sectors * $bs))
  else
    dd if="$file" bs=$bs skip="$offset" count="$sectors" \
      oflag=sync status=noxfer 2>/dev/null
  fi
}

# Dumps a specific partition from given image file
dump_partition() {
  local file="$1"
  local part_num="$2"
  local offset="$(part_offset "$file" "$part_num")" ||
    err_die "failed to dump partition #$part_num from: $file"
  local size="$(part_size "$file" "$part_num")" ||
    err_die "failed to dump partition #$part_num from: $file"

  dump_partial_file "$file" "$offset" "$size"
}

