#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to archive build results.  Used by the buildbots.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Script must be run outside the chroot
assert_outside_chroot

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images"
# Default to the most recent image
DEFAULT_FROM="${IMAGES_DIR}/`ls -t1 $IMAGES_DIR | head -1`"
DEFAULT_TO="${GCLIENT_ROOT}/archive"

# Flags
DEFINE_string from "$DEFAULT_FROM" \
  "Directory to archive"
DEFINE_string to "$DEFAULT_TO" "Directory of build archive"
DEFINE_integer keep_max 0 "Maximum builds to keep in archive (0=all)"
DEFINE_string zipname "image.zip" "Name of zip file to create."
DEFINE_boolean official_build $FLAGS_FALSE "Set CHROMEOS_OFFICIAL=1 for release builds."
DEFINE_string build_number "" \
  "The build-bot build number (when called by buildbot only)." "b"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

if [ $FLAGS_official_build -eq $FLAGS_TRUE ]
then
   CHROMEOS_OFFICIAL=1
fi

# Get version information
. "${SCRIPTS_DIR}/chromeos_version.sh"

# Get git hash
# Use git:8 chars of sha1
REVISION=$(git rev-parse HEAD)
REVISION=${REVISION:0:8}

# Use the version number plus revision as the last change.  (Need both, since
# trunk builds multiple times with the same version string.)
LAST_CHANGE="${CHROMEOS_VERSION_STRING}-r${REVISION}-b${FLAGS_build_number}"

# The Chromium buildbot scripts only create a clickable link to the archive
# if an output line of the form "last change: XXX" exists
echo "last change: $LAST_CHANGE"
echo "archive from: $FLAGS_from"

# Create the output directory
OUTDIR="${FLAGS_to}/${LAST_CHANGE}"
ZIPFILE="${OUTDIR}/${FLAGS_zipname}"
echo "archive to dir: $OUTDIR"
echo "archive to file: $ZIPFILE"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

# Zip the build
echo "Compressing and archiving build..."
cd "$DEFAULT_FROM"
zip -r "$ZIPFILE" *
cd -

# Update LATEST file
echo "$LAST_CHANGE" > "${FLAGS_to}/LATEST"

# Make sure files are readable
chmod 644 "$ZIPFILE" "${FLAGS_to}/LATEST"
chmod 755 "$OUTDIR"

# Purge old builds if necessary
if [ $FLAGS_keep_max -gt 0 ]
then
  echo "Deleting old builds (all but the newest ${FLAGS_keep_max})..."
  cd "$FLAGS_to"
  # +2 because line numbers start at 1 and need to skip LATEST file
  rm -rf `ls -t1 | tail --lines=+$(($FLAGS_keep_max + 2))`
  cd -
fi

echo "Done."
