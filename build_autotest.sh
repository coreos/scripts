#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script makes autotest client tests inside a chroot environment.  The idea
# is to compile any platform-dependent autotest client tests in the build
# environment, since client systems under test lack the proper toolchain.
#
# The user can later run autotest against an ssh enabled test client system, or
# install the compiled client tests directly onto the rootfs image.

# Includes common already
./autotest --build=all $@

