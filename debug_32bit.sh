#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Debug a 32 bit binary on 64 bit linux.  Can be run from inside or outside
# the chroot.  If inside, then the 32 bit gdb from the chroot is used, otherwise
# the system's 64 bit gdb is used.

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
  CHOST="x86-generic"
fi

SYSROOT="$FLAGS_chroot/build/$CHOST"
LIB_PATHS="/lib32:/usr/lib32:$LIB_PATHS:$SYSROOT/usr/lib:$SYSROOT/lib:."
LIB_PATHS="$LIB_PATHS:$SYSROOT/opt/google/chrome/chromeos"

if [ $INSIDE_CHROOT == 1 ]; then
  # if we're inside the chroot, the we'll be running a 32 bit gdb, so we'll
  # need the same library path as the target
  export LD_LIBRARY_PATH=$LIB_PATHS
  GDB="$SYSROOT/usr/bin/gdb"
else
  GDB="gdb"
fi

exec $GDB \
  --eval-command "set environment LD_LIBRARY_PATH=$LIB_PATHS" \
  --eval-command "set sysroot $SYSROOT " \
  --eval-command "set prompt (cros-gdb) " \
  --args "$@"
