#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Common library for functions used by workon tools.

find_workon_ebuilds() {
  pushd "${BOARD_DIR}"/etc/ 1> /dev/null
  source make.conf
  popd 1> /dev/null
  local CROS_OVERLAYS="${PORTDIR_OVERLAY}"

  # NOTE: overlay may be a symlink, and we have to use ${overlay}/
  for overlay in ${CROS_OVERLAYS}; do
    # only look up ebuilds named 9999 to eliminate duplicates
    find ${overlay}/ -name '*9999.ebuild' | xargs fgrep cros-workon | \
      sed -e 's/\([.]ebuild\):.*/\1/'|uniq
  done
}

# wrapper script that caches the result of find_workon_ebuilds()
show_workon_ebuilds_files() {
  if [ -z "${CROS_ALL_EBUILDS}" ]; then
    CROS_ALL_EBUILDS=$(find_workon_ebuilds)
  fi
  echo "${CROS_ALL_EBUILDS}"
}

show_workon_ebuilds() {
  show_workon_ebuilds_sources | \
    sed -e 's/.*\/\([^/]*\)\/\([^/]*\)\/.*\.ebuild/\1\/\2/'| sort
}
