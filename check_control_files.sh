#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script will check all existing AutoTest control files for correctness.

# Set pipefail so it will capture any nonzer exit codes
set -o pipefail

. "$(dirname "$0")/common.sh"

AUTOTEST_ROOT=${SRC_ROOT}/third_party/autotest/files
CHECKSCRIPT=${AUTOTEST_ROOT}/utils/check_control_file_vars.py
SITE_TESTS=${AUTOTEST_ROOT}/client/site_tests

find $SITE_TESTS -maxdepth 2 -name control | xargs -n1 $CHECKSCRIPT

if [ $? -ne 0 ]
then
  exit 1
fi
