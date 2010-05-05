#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

assert_not_root_user
restart_in_chroot_if_needed $*
get_default_board

# Flags
DEFINE_string build_root "$DEFAULT_BUILD_ROOT"                \
  "Root of build output"
DEFINE_string board "$DEFAULT_BOARD" \
  "Target board for which tests are to be built"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

if [ -z "$FLAGS_board" ]; then
  echo Error: --board required
  exit 1
fi

# Die on error; print commands
set -e

TEST_DIRS="crash pam_google window_manager cryptohome"

sudo TEST_DIRS="${TEST_DIRS}" \
  emerge-${FLAGS_board} chromeos-base/chromeos-unittests
