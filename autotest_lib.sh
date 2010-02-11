# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Provides common commands for dealing running/building autotest

# Populates the chroot's /usr/local/autotest/$FLAGS_board directory based on
# the given source directory.
# args:
#   $1 - original source directory
#   $2 - target directory
function update_chroot_autotest() {
  local original=$1
  local target=$2
  echo "Updating chroot Autotest from ${original} to ${target}..."
  sudo mkdir -p "${target}"
  sudo chmod 777 "${target}"
  cp -fpru ${original}/{client,conmux,server,tko,utils,global_config.ini,shadow_config.ini} ${target}
}
