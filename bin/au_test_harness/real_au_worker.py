# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Module containing class that implements an au_worker for a test device."""

import unittest

import cros_build_lib as cros_lib

import au_worker

class RealAUWorker(au_worker.AUWorker):
  """Test harness for updating real images."""

  def __init__(self, options):
    """Processes non-vm-specific options."""
    au_worker.AUWorker.__init__(self, options)
    self.remote = options.remote
    if not self.remote: cros_lib.Die('We require a remote address for tests.')

  def PrepareBase(self, image_path):
    """Auto-update to base image to prepare for test."""
    self.PrepareRealBase(image_path)

  def UpdateImage(self, image_path, src_image_path='', stateful_change='old',
                  proxy_port=None, private_key_path=None):
    """Updates a remote image using image_to_live.sh."""
    stateful_change_flag = self.GetStatefulChangeFlag(stateful_change)
    cmd = ['%s/image_to_live.sh' % self.crosutils,
           '--remote=%s' % self.remote,
           stateful_change_flag,
           '--verify',
          ]
    self.AppendUpdateFlags(cmd, image_path, src_image_path, proxy_port,
                           private_key_path)
    self.RunUpdateCmd(cmd)

  def UpdateUsingPayload(self, update_path, stateful_change='old',
                         proxy_port=None):
    """Updates a remote image using image_to_live.sh."""
    stateful_change_flag = self.GetStatefulChangeFlag(stateful_change)
    cmd = ['%s/image_to_live.sh' % self.crosutils,
           '--payload=%s' % update_path,
           '--remote=%s' % self.remote,
           stateful_change_flag,
           '--verify',
          ]
    if proxy_port: cmd.append('--proxy_port=%s' % proxy_port)
    self.RunUpdateCmd(cmd)

  def VerifyImage(self, unittest, percent_required_to_pass=100):
    """Verifies an image using run_remote_tests.sh with verification suite."""
    output = cros_lib.RunCommand(
        ['%s/run_remote_tests.sh' % self.crosutils,
         '--remote=%s' % self.remote,
         self.verify_suite,
        ], error_ok=True, enter_chroot=False, redirect_stdout=True)
    return self.AssertEnoughTestsPassed(unittest, output,
                                        percent_required_to_pass)

