#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

echo "This command is deprecated, please run cros_sdk $*"
# Run 'gclient' to sync depot_tools. Just in case.
gclient &> /dev/null
exit 1
