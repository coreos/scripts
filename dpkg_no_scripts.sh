#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script can be used to replace the "dpkg" binary as far as the
# "apt-get install" command is concerned. When "apt-get install foo"
# runs it will make two calls to dpkg like:
#   dpkg --status-fd ## --unpack --auto-deconfigure /path/to/foo.deb
#   dpkg --status-fd ## --configure foo
# This script will extract the .deb file and make it appear to be installed
# successfully. It will skip the maintainer scripts and configure steps.
#
# As a one-off test, you can run like:
#  apt-get -o="Dir::Bin::dpkg=/path/to/this" install foo

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Flags
DEFINE_string root "" \
  "The target rootfs directory in which to install packages."
DEFINE_string status_fd "" \
  "The file descriptor to report status on; ignored."
DEFINE_boolean unpack $FLAGS_FALSE "Is the action 'unpack'?"
DEFINE_boolean configure $FLAGS_FALSE "Is the action 'configure'?"
DEFINE_boolean auto_deconfigure $FLAGS_FALSE "Ignored"

# Fix up the command line and parse with shflags.
FIXED_FLAGS="$@"
FIXED_FLAGS=${FIXED_FLAGS/status-fd/status_fd}
FIXED_FLAGS=${FIXED_FLAGS/auto-deconfigure/auto_deconfigure}
FLAGS $FIXED_FLAGS || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
set -e

if [ $FLAGS_configure -eq $FLAGS_TRUE ]; then
  # We ignore configure requests.
  exit 0
fi
if [ $FLAGS_unpack -ne $FLAGS_TRUE ]; then
  # Ignore unknown command line.
  echo "Unexpected command line: $@"
  exit 0
fi
if [ -z "$FLAGS_root" ]; then
  echo "Missing root directory."
  exit 0
fi

DPKG_STATUS=""
if [ -d "$FLAGS_root/var/lib/dpkg" ]; then
  DPKG_STATUS="$FLAGS_root/var/lib/dpkg/status"
  DPKG_INFO="$FLAGS_root/var/lib/dpkg/info/"
fi

for p in "$@"; do
  echo "Extracting $p"
  dpkg-deb --extract "$p" "$FLAGS_root"

  if [ -n "$DPKG_STATUS" ]; then
    TMPDIR=$(mktemp -d)
    dpkg-deb --control "$p" "$TMPDIR"

    # Copy the info files
    PACKAGE=$(dpkg-deb --field "$p" Package)
    FILES=$(ls "$TMPDIR" | grep -v control)
    for f in $FILES; do
      cp "${TMPDIR}/$f" "${DPKG_INFO}/$PACKAGE.$f"
    done

    # Mark the package as installed successfully.
    echo "Status: install ok installed" >> "$DPKG_STATUS"
    cat "${TMPDIR}/control" >> "$DPKG_STATUS"
    echo "" >> "$DPKG_STATUS"

    rm -rf "$TMPDIR"
  fi
done
