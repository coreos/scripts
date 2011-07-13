#!/bin/sh
#
# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to generate an universal factory install shim image, by merging
# multiple images signed by different keys.
# CAUTION: Recovery shim images are not supported yet because they require the
# kernel partitions to be laid out in a special way

SCRIPT="$0"
set -e

# CGPT Header: PMBR, header, table; sec_table, sec_header
CGPT_START_SIZE=$((1 + 1 + 32))
CGPT_END_SIZE=$((32 + 1))
CGPT_BS="512"

STATE_PARTITION="1"
LEGACY_PARTITIONS="8 9 10 11 12"
RESERVED_PARTITION="9"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# TODO(hungte) support parted if cgpt is not available
image_get_partition_offset() {
  cgpt show -n -i "$2" -b "$1"
}

image_get_partition_size() {
  cgpt show -n -i "$2" -s "$1"
}

image_get_partition_type() {
  cgpt show -n -i "$2" -t "$1"
}

image_get_partition_label() {
  cgpt show -n -i "$2" -l "$1"
}

image_enable_kernel() {
  cgpt add -P 1 -S 1 -i "$2" "$1"
}

image_copy_partition() {
  local from_image="$1"
  local from_part="$2"
  local to_image="$3"
  local to_part="$4"
  local bs="$CGPT_BS"

  local from_offset="$(image_get_partition_offset "$from_image" "$from_part")"
  local from_size="$(image_get_partition_size "$from_image" "$from_part")"
  local to_offset="$(image_get_partition_offset "$to_image" "$to_part")"
  local to_size="$(image_get_partition_size "$to_image" "$to_part")"

  if [ "$from_size" -ne "$to_size" ]; then
    die "Failed to copy partition: $from_image#$from_part -> $to_image#$to_part"
  fi

  # Seed up by increasing block size
  # TODO(hungte) improve obs calculation or change offsets
  while [ "$((from_size > 0 &&
              from_size % 2 == 0 &&
              from_offset % 2 == 0 &&
              to_offset % 2 == 0))" = "1" ]; do
    bs=$((bs * 2))
    from_size=$((from_size / 2))
    from_offset=$((from_offset / 2))
    to_offset=$((to_offset / 2))
  done

  # Display progress if the partition is larger than 32M.
  if [ "$((from_size * bs > 32 * 1048576))" = "1" ] && type pv >/dev/null 2>&1
  then
    dd if="$from_image" bs="$bs" count=$from_size skip="$from_offset" |
    pv -B "$bs" -s "$((bs * from_size))" |
    dd of="$to_image" bs="$bs" count="$from_size" seek="$to_offset" \
      conv=notrunc iflag=fullblock
  else
    dd if="$from_image" of="$to_image" bs="$bs" conv=notrunc \
      count=$from_size skip="$from_offset" seek="$to_offset"
  fi
}

images_get_total_size() {
  local image=""
  local total="0"
  local index

  # reference, slot_a, slot_b, slot_c.
  [ "$#" = 4 ] || die "incorrect call to images_get_total_size"

  # copy most partitions from first image
  total="$((total + CGPT_START_SIZE + CGPT_END_SIZE))"
  for index in $STATE_PARTITION $LEGACY_PARTITIONS; do
    total="$((total + $(image_get_partition_size "$1" $index) ))"
  done

  for image in "$2" "$3" "$4"; do
    if [ -z "$image" ]; then
      total="$((total + $(image_get_partition_size "$1" $RESERVED_PARTITION)))"
      total="$((total + $(image_get_partition_size "$1" $RESERVED_PARTITION)))"
      continue
    fi
    total="$((total + $(image_get_partition_size "$image" 2)))"
    total="$((total + $(image_get_partition_size "$image" 3)))"
  done
  echo "$total"
}

image_append_partition() {
  local from_image="$1"
  local to_image="$2"
  local from_part="$3"
  local last_part="$(cgpt show "$to_image" | grep Label | wc -l)"
  local to_part="$((last_part + 1))"
  echo "image_append_partition: $from_image#$from_part -> $to_image#$to_part"

  local guid="$(image_get_partition_type "$from_image" "$from_part")"
  local size="$(image_get_partition_size "$from_image" "$from_part")"
  local label="$(image_get_partition_label "$from_image" "$from_part")"
  local offset="$CGPT_START_SIZE"

  if [ "$last_part" -gt 0 ]; then
    offset="$(( $(image_get_partition_offset "$to_image" "$last_part") +
                $(image_get_partition_size "$to_image" "$last_part") ))"
  fi

  echo cgpt add "$to_image" -t "$guid" -b "$offset" -s "$size" -l "$label"
  cgpt add "$to_image" -t "$guid" -b "$offset" -s "$size" -l "$label"
  image_copy_partition "$from_image" "$from_part" "$to_image" "$to_part"
}

main() {
  local force=""
  local image=""
  local output=""
  local main_source=""
  local index=""
  local slots="0"

  while [ "$#" -gt 1 ]; do
    case "$1" in
      "-f" )
        force="True"
        shift
        ;;
      "-m" )
        main_source="$2"
        shift
        shift
        ;;
      * )
        break
    esac
  done

  if [ "$#" -lt 2 -o "$#" -gt 4 ]; then
    echo "Usage: $SCRIPT [-m master] [-f] output shim_image_1 [shim_2 [shim_3]]"
    exit 1
  fi

  if [ -z "$main_source" ]; then
    main_source="$2"
  fi
  output="$1"
  shift

  if [ -f "$output" -a -z "$force" ]; then
    die "Output file $output already exists. To overwrite the file, add -f."
  fi
  for image in "$main_source" "$@"; do
    if [ ! -f "$image" ]; then
      die "Cannot find input file $image."
    fi
  done

  # build output
  local total_size="$(images_get_total_size "$main_source" "$@")"
  # echo "Total size from [$@]: $total_size"
  truncate -s "0" "$output"  # starting with a new file is much faster.
  truncate -s "$((total_size * CGPT_BS))" "$output"
  cgpt create "$output"
  cgpt boot -p "$output"

  # copy most partitions from first image
  image_append_partition "$main_source" "$output" $STATE_PARTITION
  local kpart=2
  local rootfs_part=3
  for image in "$1" "$2" "$3"; do
    if [ -z "$image" ]; then
      image="$main_source"
      kpart="$RESERVED_PARTITION"
      rootfs_part="$RESERVED_PARTITION"
    fi
    image_append_partition "$image" "$output" "$kpart"
    image_append_partition "$image" "$output" "$rootfs_part"
    slots="$((slots + 1))"
    image_enable_kernel "$output" "$((slots * 2))"
  done
  for index in $LEGACY_PARTITIONS; do
    image_append_partition "$main_source" "$output" "$index"
  done
}

main "$@"
