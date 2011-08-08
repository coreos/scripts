# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

if [ -z "${FLAGS_board}" ]; then
  error "--board is required."
  exit 1
fi

BOARD="${FLAGS_board}"
BOARD_ROOT="${FLAGS_build_root}/${BOARD}"

# What cross-build are we targeting?
. "${BOARD_ROOT}/etc/make.conf.board_setup"

# Figure out ARCH from the given toolchain.
# TODO(jrbarnette): There's a copy of this code in setup_board;
# it should be shared.
case "$(echo "${CHOST}" | awk -F'-' '{ print $1 }')" in
  arm*)
    ARCH="arm"
    ;;
  *86)
    ARCH="x86"
    ;;
  *x86_64)
    ARCH="amd64"
    ;;
  *)
    error "Unable to determine ARCH from toolchain: ${CHOST}"
    exit 1
esac
