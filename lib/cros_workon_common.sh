#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Common library for functions used by workon tools.

show_workon_ebuilds() {
  pushd "${BOARD_DIR}"/etc/ 1> /dev/null
  source make.conf
  popd 1> /dev/null
  local CROS_OVERLAYS="${PORTDIR_OVERLAY}"

  for overlay in ${CROS_OVERLAYS}; do
    pushd ${overlay} 1> /dev/null
    find . -name '*.ebuild' | xargs fgrep cros-workon | \
      awk -F / '{ print $2 "/" $3 }' | uniq | sort
    popd 1> /dev/null
  done
}
