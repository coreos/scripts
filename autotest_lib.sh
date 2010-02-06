# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Provides common commands for dealing running/building autotest

# Populates the chroot's /usr/local/autotest directory based on
# the given source directory.
# args:
#   $1 - original source directory
function update_chroot_autotest() {
  local original=$1
  echo "Updating chroot Autotest from ${original}..."
  local autotest_dir="${DEFAULT_CHROOT_DIR}/usr/local/autotest"
  sudo mkdir -p "${autotest_dir}"
  sudo chmod 777 "${autotest_dir}"
  cp -fpru ${original}/{client,conmux,server,tko,utils,global_config.ini,shadow_config.ini} ${autotest_dir}
}
