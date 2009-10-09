#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Simple script for building the entire system.

# Die on error; print commands
set -e

./build_platform_packages.sh
./build_tests.sh
./build_kernel.sh
./run_tests.sh
./build_image.sh --replace
