#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Simple script for building the entire system.

# Die on error; print commands
set -e

SCRIPTS_DIR=$(dirname $0)

$SCRIPTS_DIR/build_platform_packages.sh
$SCRIPTS_DIR/build_tests.sh
$SCRIPTS_DIR/build_kernel.sh
$SCRIPTS_DIR/run_tests.sh
$SCRIPTS_DIR/build_image.sh 
