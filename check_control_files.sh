#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script will check all existing AutoTest control files for correctness.

# Set pipefail so it will capture any nonzer exit codes
set -o pipefail

# --- BEGIN COMMON.SH BOILERPLATE ---
# Load common CrOS utilities.  Inside the chroot this file is installed in
# /usr/lib/crosutils.  Outside the chroot we find it relative to the script's
# location.
find_common_sh() {
  local common_paths=(/usr/lib/crosutils $(dirname "$(readlink -f "$0")"))
  local path

  SCRIPT_ROOT=
  for path in "${common_paths[@]}"; do
    if [ -r "${path}/common.sh" ]; then
      SCRIPT_ROOT=${path}
      break
    fi
  done
}

find_common_sh
. "${SCRIPT_ROOT}/common.sh" || (echo "Unable to load common.sh" && exit 1)
# --- END COMMON.SH BOILERPLATE ---

AUTOTEST_ROOT=${SRC_ROOT}/third_party/autotest/files
CHECKSCRIPT=${AUTOTEST_ROOT}/utils/check_control_file_vars.py
SITE_TESTS=${AUTOTEST_ROOT}/client/site_tests

find $SITE_TESTS -maxdepth 2 -name control | xargs -n1 $CHECKSCRIPT

if [ $? -ne 0 ]
then
  exit 1
fi
