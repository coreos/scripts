# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

if [ -z "${FLAGS_board}" ]; then
  error "--board is required."
  exit 1
fi

BOARD="${FLAGS_board}"
BOARD_ROOT="/build/${BOARD}"
ARCH=$(get_board_arch ${BOARD})

# What cross-build are we targeting?
. "${BOARD_ROOT}/etc/make.conf.board_setup"
