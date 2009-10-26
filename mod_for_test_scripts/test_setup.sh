#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

cd `dirname $0`
for SCRIPT in [0-9][0-9][0-9]*[!$~]
do
  ./${SCRIPT}
done

