#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Runs our own version of extlinux, which is in the third_party directory.
# Our version is quieter and faster. extlinux will be compiled if it's not
# already.

set -e

SCRIPTS_ROOT=`dirname "$0"`
THIRD_PARTY="${SCRIPTS_ROOT}/../third_party"
BUILD_ROOT=${BUILD_ROOT:-${SCRIPTS_ROOT}/../build}
EXTLINUX_BIN="$BUILD_ROOT"/x86/obj/src/third_party/syslinux/syslinux-*/extlinux/extlinux

echo bin is "$EXTLINUX_BIN"

if [ ! -e $EXTLINUX_BIN ]
then
  # compile extlinux
  (cd "$SCRIPTS_ROOT/../third_party/syslinux/files/" && make)
  if [ ! -e $EXTLINUX_BIN ]
  then
    echo "Can't find or compile extlinux. Sorry."
    exit 1
  fi
fi

# we don't want ""s around $* b/c that will group all args into a single arg
$EXTLINUX_BIN $*
