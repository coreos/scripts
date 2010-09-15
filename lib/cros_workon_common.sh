#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Common library for functions used by workon tools.

find_keyword_workon_ebuilds() {
  keyword="${1}"

  pushd "${BOARD_DIR}"/etc/ 1> /dev/null
  source make.conf
  popd 1> /dev/null
  local CROS_OVERLAYS="${PORTDIR_OVERLAY}"

  # NOTE: overlay may be a symlink, and we have to use ${overlay}/
  for overlay in ${CROS_OVERLAYS}; do
    # only look up ebuilds named 9999 to eliminate duplicates
    find ${overlay}/ -name '*9999.ebuild' | \
      xargs grep -l "inherit.*cros-workon" | \
      xargs grep -l "KEYWORDS=.*${keyword}.*"
  done
}

show_workon_ebuilds() {
  keyword=$1

  find_keyword_workon_ebuilds ${keyword} | \
    sed -e 's/.*\/\([^/]*\)\/\([^/]*\)\/.*\.ebuild/\1\/\2/' | \
       sort -u
  # This changes the absolute path to ebuilds into category/package.
}
