# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Module containing a fake  au worker class."""

import unittest

import au_worker

class DummyAUWorker(au_worker.AUWorker):
  """AU worker that emulates work for an au_worker without actually doing work.

  Collects different updates that would be generated that can be obtained
  from the class object delta_list.
  """

  # Class variable that stores the list of payloads that would be needed.
  delta_list = {}

  def __init__(self, options):
    au_worker.AUWorker.__init__(self, options)
    self.au_type = options.type

  def PrepareBase(self, image_path):
    """Copy how the actual worker would prepare the base image."""
    if self.au_type == 'vm':
      self.PrepareVMBase(image_path)
    else:
      self.PrepareRealBase(image_path)

  def UpdateImage(self, image_path, src_image_path='', stateful_change='old',
                  proxy_port=None, private_key_path=None):
    """Emulate Update and record the update payload in delta_list."""
    if self.au_type == 'vm' and src_image_path and self._first_update:
      src_image_path = self.vm_image_path
      self._first_update = False

    # Generate a value that combines delta with private key path.
    val = src_image_path
    if private_key_path: val = '%s+%s' % (val, private_key_path)
    if not self.delta_list.has_key(image_path):
      self.delta_list[image_path] = set([val])
    else:
      self.delta_list[image_path].add(val)
