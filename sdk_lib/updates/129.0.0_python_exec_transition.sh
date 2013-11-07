#!/bin/bash

# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Upgrade python-exec, will transition to dev-lang/python-exec
sudo emerge -qu dev-python/python-exec

# Re-install portage and gentoolkit which tended to have issues
sudo emerge -q sys-apps/portage app-portage/gentoolkit
