#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script makes autotest client tests inside a chroot environment.  The idea
# is to compile any platform-dependent autotest client tests in the build
# environment, since client systems under test lack the proper toolchain.
#
# The user can later run autotest against an ssh enabled test client system, or
# install the compiled client tests directly onto the rootfs image.

. "$(dirname "$0")/common.sh"

get_default_board

DEFINE_string board "$DEFAULT_BOARD" \
    "The board for which you are building autotest"

FLAGS "$@" || exit 1

if [[ -n "${CROS_WORKON_SRCROOT}" ]]; then
  if [[ -z "${FLAGS_board}" ]]; then
    setup_board_warning
    exit 1
  fi
  emerge-${FLAGS_board} autotest-all
else
  ./autotest --noprompt --build=all --board="${FLAGS_board}" $@
fi

