#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

echo "Modifying image for factory test..."
set -e

SCRIPT_BASE="${GCLIENT_ROOT}/src/scripts/mod_for_factory_scripts/"
for SCRIPT in "${SCRIPT_BASE}"[0-9][0-9][0-9]*[!$~]
do
  echo "Apply $(basename "${SCRIPT}")..."
  "${SCRIPT}"
done
