#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script contains common utility function to deal with disk images,
# especially for being redistributed into platforms without complete Chromium OS
# developing environment.

# Checks if given command is available in current system
image_has_command() {
  type "$1" >/dev/null 2>&1
}

# Prints error message and exit as 1 (error)
image_die() {
  echo "ERROR: $@" >&2
  exit 1
}

# Finds the best gzip compressor and invoke it
image_gzip_compress() {
  if image_has_command pigz; then
    # echo " ** Using parallel gzip **" >&2
    # Tested with -b 32, 64, 128(default), 256, 1024, 16384, and -b 32 (max
    # window size of Deflate) seems to be the best in output size.
    pigz -b 32 "$@"
  else
    gzip "$@"
  fi
}

# Finds the best bzip2 compressor and invoke it
image_bzip2_compress() {
  if image_has_command pbzip2; then
    pbzip2 "$@"
  else
    bzip2 "$@"
  fi
}

# Finds if current system has tools for part_* commands
image_has_part_tools() {
  image_has_command cgpt || image_has_command parted
}

# Finds the best partition tool and print partition offset
image_part_offset() {
  local file="$1"
  local partno="$2"
  local unpack_file="$(dirname "$file")/unpack_partitions.sh"

  # TODO parted is available on most Linux so we may deprecate other code path
  if image_has_command cgpt; then
    cgpt show -b -i "$partno" "$file"
  elif image_has_command parted; then
    parted -m "$file" unit s print | awk -F ':' "/^$partno:/ { print int(\$2) }"
  elif [ -f "$unpack_file" ]; then
    awk "/ $partno  *Label:/ { print \$2 }" "$unpack_file"
  else
    exit 1
  fi
}

# Finds the best partition tool and print partition size
image_part_size() {
  local file="$1"
  local partno="$2"
  local unpack_file="$(dirname "$file")/unpack_partitions.sh"

  # TODO parted is available on most Linux so we may deprecate other code path
  if image_has_command cgpt; then
    cgpt show -s -i "$partno" "$file"
  elif image_has_command parted; then
    parted -m "$file" unit s print | awk -F ':' "/^$partno:/ { print int(\$4) }"
  elif [ -s "$unpack_file" ]; then
    awk "/ $partno  *Label:/ { print \$3 }" "$unpack_file"
  else
    exit 1
  fi
}

# Dumps a file by given offset and size (in sectors)
image_dump_partial_file() {
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

  if image_has_command pv; then
    dd if="$file" bs=$bs skip="$offset" count="$sectors" \
      oflag=sync status=noxfer 2>/dev/null |
      pv -ptreb -B $bs -s $((sectors * bs))
  else
    dd if="$file" bs=$bs skip="$offset" count="$sectors" \
      oflag=sync status=noxfer 2>/dev/null
  fi
}

# Dumps a specific partition from given image file
image_dump_partition() {
  local file="$1"
  local part_num="$2"
  local offset="$(image_part_offset "$file" "$part_num")" ||
    image_die "failed to find partition #$part_num from: $file"
  local size="$(image_part_size "$file" "$part_num")" ||
    image_die "failed to find partition #$part_num from: $file"

  image_dump_partial_file "$file" "$offset" "$size"
}

# Maps a specific partition from given image file to a loop device
image_map_partition() {
  local file="$1"
  local part_num="$2"
  local offset="$(image_part_offset "$file" "$part_num")" ||
    image_die "failed to find partition #$part_num from: $file"
  local size="$(image_part_size "$file" "$part_num")" ||
    image_die "failed to find partition #$part_num from: $file"

  losetup --offset $((offset * 512)) --sizelimit=$((size * 512)) \
    -f --show "$file"
}

# Unmaps a loop device created by image_map_partition
image_unmap_partition() {
  local map_point="$1"

  losetup -d "$map_point"
}

# Mounts a specific partition inside a given image file
image_mount_partition() {
  local file="$1"
  local part_num="$2"
  local mount_point="$3"
  local mount_opt="$4"
  local offset="$(image_part_offset "$file" "$part_num")" ||
    image_die "failed to find partition #$part_num from: $file"
  local size="$(image_part_size "$file" "$part_num")" ||
    image_die "failed to find partition #$part_num from: $file"

  if [ -z "$mount_opt" ]; then
    # by default, mount as read-only.
    mount_opt=",ro"
  fi

  mount \
    -o "loop,offset=$((offset * 512)),sizelimit=$((size * 512)),$mount_opt" \
    "$file" \
    "$mount_point"
}

# Unmounts a partition mount point by mount_partition
image_umount_partition() {
  local mount_point="$1"

  umount -d "$mount_point"
}
