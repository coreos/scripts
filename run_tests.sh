#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Flags
DEFINE_string build_root "$DEFAULT_BUILD_ROOT"                \
  "Root of build output"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on error; print commands
set -ex

# Run tests
TESTS_DIR="$FLAGS_build_root/x86/tests"
cd "$TESTS_DIR"

# TODO: standardize test names - should all end in "_test" so we can find 
# and run them without listing them explicitly.
./pam_google_unittests
for i in *_test; do ./${i}; done

cd -
echo "All tests passed."
