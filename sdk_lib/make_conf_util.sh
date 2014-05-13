# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

create_host_setup() {
  local host_setup="$2/etc/portage/make.conf.host_setup"
  ( echo "# Automatically generated.  EDIT THIS AND BE SORRY."
    echo "MAKEOPTS='--jobs=${NUM_JOBS} --load-average=${NUM_JOBS}'"
  ) | sudo_clobber "$host_setup"
  sudo chmod 644 "$host_setup"
}
