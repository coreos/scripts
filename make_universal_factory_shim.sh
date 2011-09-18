#!/bin/sh

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to generate an universal factory install shim image, by merging
# multiple images signed by different keys.
# CAUTION: Recovery shim images are not supported yet because they require the
# kernel partitions to be laid out in a special way

# --- BEGIN FACTORY SCRIPTS BOILERPLATE ---
# This script may be executed in a full CrOS source tree or an extracted factory
# bundle with limited tools, so we must always load scripts from $SCRIPT_ROOT
# and search for binary programs in $SCRIPT_ROOT/../bin

SCRIPT="$(readlink -f "$0")"
SCRIPT_ROOT="$(dirname "$SCRIPT")"
. "$SCRIPT_ROOT/lib/cros_image_common.sh" || exit 1
image_find_tool "cgpt" "$SCRIPT_ROOT/../bin"
# --- END FACTORY SCRIPTS BOILERPLATE ---

# CGPT Header: PMBR, header, table; sec_table, sec_header
CGPT_START_SIZE=$((1 + 1 + 32))
CGPT_END_SIZE=$((32 + 1))
CGPT_BS="512"

# Alignment of partition sectors
PARTITION_SECTOR_ALIGNMENT=256

LAYOUT_FILE="$(mktemp --tmpdir)"

RESERVED_PARTITION="10"
LEGACY_PARTITIONS="10 11 12"  # RESERVED, RWFW, EFI
MAX_INPUT_SOURCES=4  # (2~9) / 2

alert() {
  echo "$*" >&2
}

die() {
  alert "ERROR: $*"
  exit 1
}

on_exit() {
  rm -f "$LAYOUT_FILE"
}

# Returns offset aligned to alignment.
# If size is given, only align if size >= alignment.
image_alignment() {
  local offset="$1"
  local alignment="$2"
  local size="$3"

  # If size is assigned, align only if the new size is larger then alignment.
  if [ "$((offset % alignment))" != "0" ]; then
    if [ -z "$size" -o "$size" -ge "$alignment" ]; then
      offset=$((offset + alignment - (offset % alignment)))
    fi
  fi
  echo "$((offset))"
}

# Processes a logical disk image layout description file.
# Each entry in layout is a "file:partnum" entry (:partnum is optional),
# referring to the #partnum partition in file.
# The index starts at one, referring to the first partition in layout.
image_process_layout() {
  local layout_file="$1"
  local callback="$2"
  shift
  shift
  local param="$@"
  local index=0

  while read layout; do
    local image_file="${layout%:*}"
    local part_num="${layout#*:}"
    index="$((index + 1))"
    [ "$image_file" != "$layout" ] || part_num=""

    "$callback" "$image_file" "$part_num" "$index" "$param"
  done <"$layout_file"
}

# Processes a list of disk geometry sectors into aligned (offset, sectors) form.
# The index starts at zero, referring to the partition table object itself.
image_process_geometry() {
  local sectors_list="$1"
  local callback="$2"
  shift
  shift
  local param="$@"
  local offset=0 sectors
  local index=0

  for sectors in $sectors_list; do
    offset="$(image_alignment $offset $PARTITION_SECTOR_ALIGNMENT $sectors)"
    "$callback" "$offset" "$sectors" "$index" "$param"
    offset="$((offset + sectors))"
    index="$((index + 1))"
  done
}

# Callback of image_process_layout. Returns the size (in sectors) of given
# object (partition in image or file).
layout_get_sectors() {
  local image_file="$1"
  local part_num="$2"

  if [ -n "$part_num" ]; then
    image_part_size "$image_file" "$part_num"
  else
    image_alignment "$(stat -c"%s" "$image_file")" $CGPT_BS ""
  fi
}

# Callback of image_process_layout. Copies an input source object (file or
# partition) into specified partition on output file.
layout_copy_partition() {
  local input_file="$1"
  local input_part="$2"
  local output_part="$3"
  local output_file="$4"
  alert "$(basename "$input_file"):$input_part =>" \
        "$(basename "$output_file"):$output_part"

  if [ -n "$part_num" ]; then
    # TODO(hungte) update partition type if available
    image_partition_copy "$input_file" "$input_part" \
                         "$output_file" "$output_part"
    # Update partition type information
    local partition_type="$(cgpt show -q -n -t -i "$input_part" "$input_file")"
    local partition_attr="$(cgpt show -q -n -A -i "$input_part" "$input_file")"
    local partition_label="$(cgpt show -q -n -l -i "$input_part" "$input_file")"
    cgpt add -t "$partition_type" -l "$partition_label" -A "$partition_attr" \
             -i "$output_part" "$output_file"
  else
    image_update_partition "$output_file" "$output_part" <"$input_file"
  fi
}


# Callback of image_process_geometry. Creates a partition by give offset,
# size(sectors), and index.
geometry_create_partition() {
  local offset="$1"
  local sectors="$2"
  local index="$3"
  local output_file="$4"

  if [ "$offset" = "0" ]; then
    # first entry is CGPT; ignore.
    return
  fi
  cgpt add -b $offset -s $sectors -i $index -t reserved "$output_file"
}

# Callback of image_process_geometry. Prints the proper offset of current
# partition by give offset and size.
geometry_get_partition_offset() {
  local offset="$1"
  local sectors="$2"
  local index="$3"

  image_alignment "$offset" "$PARTITION_SECTOR_ALIGNMENT" "$sectors"
}

build_image_file() {
  local layout_file="$1"
  local output_file="$2"
  local output_file_size=0
  local sectors_list partition_offsets

  # Check and obtain size information from input sources
  sectors_list="$(image_process_layout "$layout_file" layout_get_sectors)"

  # Calculate output image file size
  partition_offsets="$(image_process_geometry \
                       "$CGPT_START_SIZE $sectors_list $CGPT_END_SIZE 1" \
                       geometry_get_partition_offset)"
  output_file_size="$(echo "$partition_offsets" | tail -n 1)"

  # Create empty image file
  truncate -s "0" "$output_file"  # starting with a new file is much faster.
  truncate -s "$((output_file_size * CGPT_BS))" "$output_file"

  # Initialize partition table (GPT)
  cgpt create "$output_file"
  cgpt boot -p "$output_file" >/dev/null

  # Create partition tables
  image_process_geometry "$CGPT_START_SIZE $sectors_list" \
                         geometry_create_partition \
                         "$output_file"
  # Copy partitions content
  image_process_layout "$layout_file" layout_copy_partition "$output_file"
}

# Creates standard multiple image layout
create_standard_layout() {
  local main_source="$1"
  local layout_file="$2"
  local image index
  shift
  shift

  for image in "$main_source" "$@"; do
    if [ ! -f "$image" ]; then
      die "Cannot find input file $image."
    fi
  done

  echo "$main_source:1" >>"$layout_file"  # stateful partition
  for index in $(seq 1 $MAX_INPUT_SOURCES); do
    local kernel_source="$main_source:$RESERVED_PARTITION"
    local rootfs_source="$main_source:$RESERVED_PARTITION"
    if [ "$#" -gt 0 ]; then
      # TODO(hungte) detect if input source is a recovery/USB image
      kernel_source="$1:2"
      rootfs_source="$1:3"
      shift
    fi
    echo "$kernel_source" >>"$layout_file"
    echo "$rootfs_source" >>"$layout_file"
  done
  for index in $LEGACY_PARTITIONS; do
    echo "$main_source:$index" >>"$LAYOUT_FILE"
  done
}

usage_die() {
  alert "Usage: $SCRIPT [-m master] [-f] output shim1 [shim2 ... shim4]"
  alert "   or  $SCRIPT -l layout [-f] output"
  exit 1
}

main() {
  local force=""
  local image=""
  local output=""
  local main_source=""
  local index=""
  local slots="0"
  local layout_mode=""

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
      "-l" )
        cat "$2" >"$LAYOUT_FILE"
        layout_mode="TRUE"
        shift
        shift
        ;;
      * )
        break
    esac
  done

  if [ -n "$layout_mode" ]; then
    [ "$#" = 1 ] || usage_die
  elif [ "$#" -lt 2 -o "$#" -gt "$((MAX_INPUT_SOURCES + 1))" ]; then
    alert "ERROR: invalid number of parameters ($#)."
    usage_die
  fi

  if [ -z "$main_source" ]; then
    main_source="$2"
  fi
  output="$1"
  shift

  if [ -f "$output" -a -z "$force" ]; then
    die "Output file $output already exists. To overwrite the file, add -f."
  fi

  if [ -z "$layout_mode" ]; then
    create_standard_layout "$main_source" "$LAYOUT_FILE" "$@"
  fi
  build_image_file "$LAYOUT_FILE" "$output"
  echo ""
  echo "Image created: $output"
}

set -e
trap on_exit EXIT
main "$@"
