#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to resign the kernel partition generated in the output of build_image
# with keys of our choosing.

# --- BEGIN COMMON.SH BOILERPLATE ---
# Load common CrOS utilities.  Inside the chroot this file is installed in
# /usr/lib/crosutils.  Outside the chroot we find it relative to the script's
# location.
find_common_sh() {
  local common_paths=("$(dirname "$(readlink -f "$0")")/.." /usr/lib/crosutils)
  local path

  SCRIPT_ROOT="${common_paths[0]}"
  for path in "${common_paths[@]}"; do
    if [ -r "${path}/common.sh" ]; then
      SCRIPT_ROOT="${path}"
      break
    fi
  done
}

find_common_sh
. "${SCRIPT_ROOT}/common.sh" || exit 1
# --- END COMMON.SH BOILERPLATE ---

# Need to be inside the chroot to load chromeos-common.sh
assert_inside_chroot

# Load functions and constants for chromeos-install
. /usr/lib/installer/chromeos-common.sh || exit 1

locate_gpt

DEFINE_string from "coreos_image.bin" \
  "Input file name of Chrome OS image to re-sign."
DEFINE_string datakey "" \
  "Private Kernel Data Key (.vbprivk) to use for re-signing."
DEFINE_string keyblock "" \
  "Kernel Keyblock (.keyblock) to use for generating the vblock"
DEFINE_string to "" \
  "Output file name for the re-signed image."
DEFINE_string vsubkey "" \
  "(Optional) Public Kernel SubKey (.vbpubk) to use for testing verification."
DEFINE_string vbutil_dir "" \
  "(Optional) Path to directory containing vboot utility binaries"
DEFINE_integer bootflags 0 \
  "(Optional) Boot flags to use for verifying the output image"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Abort on error
switch_to_strict_mode

if [ -z $FLAGS_from ] || [ ! -f $FLAGS_from ] ; then
  echo "Error: invalid flag --from"
  exit 1
fi

if [ -z $FLAGS_datakey ] || [ ! -f $FLAGS_datakey ] ; then
  echo "Error: invalid kernel data key"
  exit 1
fi

if [ -z $FLAGS_keyblock ] || [ ! -f $FLAGS_keyblock ] ; then
  echo "Error: invalid kernel keyblock"
  exit 1
fi

if [ -z $FLAGS_to ]; then
  echo "Error: invalid flag --to"
  exit 1
fi

sector_size=512  # sector size in bytes
num_sectors_vb=128  # number of sectors in kernel verification blob
koffset="$(partoffset ${FLAGS_from} 2)"
ksize="$(partsize ${FLAGS_from} 2)"

echo "Re-signing image ${FLAGS_from} and outputting ${FLAGS_to}"
temp_kimage=$(mktemp)
trap "rm -f ${temp_kimage}" EXIT
temp_out_vb=$(mktemp)
trap "rm -f ${temp_out_vb}" EXIT

# Grab the kernel image in preparation for resigning
dd if="${FLAGS_from}" of="${temp_kimage}" skip=$koffset bs=$sector_size \
  count=$ksize
${FLAGS_vbutil_dir}vbutil_kernel \
  --repack "${temp_out_vb}" \
  --vblockonly \
  --keyblock "${FLAGS_keyblock}" \
  --signprivate "${FLAGS_datakey}" \
  --oldblob "${temp_kimage}"

# Create a copy of the input image and put in the new vblock
cp "${FLAGS_from}" "${FLAGS_to}"
dd if="${temp_out_vb}" of="${FLAGS_to}" seek=$koffset bs=$sector_size \
  count=$num_sectors_vb conv=notrunc

# Only test verification if the public subkey was passed in.
if [ ! -z $FLAGS_vsubkey ]; then
  ${FLAGS_vbutil_dir}load_kernel_test "${FLAGS_to}" "${FLAGS_vsubkey}" \
    ${FLAGS_bootflags}
fi

echo "New signed image was output to ${FLAGS_to}"

# Clean up temporary files
rm -f ${temp_kimage}
rm -f ${temp_out_vb}
