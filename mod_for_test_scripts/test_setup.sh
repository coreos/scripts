#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -e

for SCRIPT in \
    ${GCLIENT_ROOT}/src/scripts/mod_for_test_scripts/[0-9][0-9][0-9]*[!$~]
do
  ${SCRIPT}
done

