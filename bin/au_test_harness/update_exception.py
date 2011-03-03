# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Module containing update exceptions."""

class UpdateException(Exception):
  """Exception thrown when _UpdateImage or _UpdateUsingPayload fail"""
  def __init__(self, code, stdout):
    self.code = code
    self.stdout = stdout
