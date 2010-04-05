#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Run a 32 bit binary on 64 bit linux, can be run from inside or outside
# the chroot.

. "$(dirname "$0")/common.sh"

# Command line options
DEFINE_string chroot "$DEFAULT_CHROOT_DIR" "Location of chroot"

# Parse command line and update positional args
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

  # Die on any errors
set -e

if [ -z "$SYSROOT" ]; then
  if [ $INSIDE_CHROOT == 1 ]; then
    SYSROOT=/build/x86-generic
  else
    SYSROOT=$FLAGS_chroot/build/x86-generic
  fi
fi

if [ -z "$CHOST" ]; then
  CHOST=i686-pc-linux-gnu
fi

LIB_PATHS="/lib32:/usr/lib32:$LIB_PATHS:$SYSROOT/usr/lib:$SYSROOT/lib:."
LIB_PATHS="$LIB_PATHS:$SYSROOT/opt/google/chrome/chromeos"
export LD_LIBRARY_PATH=$LIB_PATHS

exec "$@"
