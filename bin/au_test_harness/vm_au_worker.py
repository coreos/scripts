# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Module containing implementation of an au_worker for virtual machines."""

import os
import threading
import unittest

import cros_build_lib as cros_lib

import au_worker


class VMAUWorker(au_worker.AUWorker):
  """Test harness for updating virtual machines."""

  # Class variables used to acquire individual VM variables per test.
  _vm_lock = threading.Lock()
  _next_port = 9222

  def __init__(self, options):
    """Processes vm-specific options."""
    au_worker.AUWorker.__init__(self, options)
    self.graphics_flag = ''
    if options.no_graphics: self.graphics_flag = '--no_graphics'
    if not self.board: cros_lib.Die('Need board to convert base image to vm.')

    self._AcquireUniquePortAndPidFile()
    self._KillExistingVM(self._kvm_pid_file)

  def _KillExistingVM(self, pid_file):
    """Kills an existing VM specified by the pid_file."""
    if os.path.exists(pid_file):
      cros_lib.Warning('Existing %s found.  Deleting and killing process' %
                       pid_file)
      cros_lib.RunCommand(['./cros_stop_vm', '--kvm_pid=%s' % pid_file],
                          cwd=self.crosutilsbin)

    assert not os.path.exists(pid_file)

  def _AcquireUniquePortAndPidFile(self):
    """Acquires unique ssh port and pid file for VM."""
    with VMAUWorker._vm_lock:
      self._ssh_port = VMAUWorker._next_port
      self._kvm_pid_file = '/tmp/kvm.%d' % self._ssh_port
      VMAUWorker._next_port += 1

  def CleanUp(self):
    """Stop the vm after a test."""
    self._KillExistingVM(self._kvm_pid_file)

  def PrepareBase(self, image_path):
    """Creates an update-able VM based on base image."""
    self.PrepareVMBase(image_path)

  def UpdateImage(self, image_path, src_image_path='', stateful_change='old',
                  proxy_port='', private_key_path=None):
    """Updates VM image with image_path."""
    stateful_change_flag = self.GetStatefulChangeFlag(stateful_change)
    if src_image_path and self._first_update:
      src_image_path = self.vm_image_path
      self._first_update = False

    cmd = ['%s/cros_run_vm_update' % self.crosutilsbin,
           '--vm_image_path=%s' % self.vm_image_path,
           '--snapshot',
           self.graphics_flag,
           '--persist',
           '--kvm_pid=%s' % self._kvm_pid_file,
           '--ssh_port=%s' % self._ssh_port,
           stateful_change_flag,
          ]
    self.AppendUpdateFlags(cmd, image_path, src_image_path, proxy_port,
                           private_key_path)
    self.RunUpdateCmd(cmd)

  def UpdateUsingPayload(self, update_path, stateful_change='old',
                         proxy_port=None):
    """Updates a vm image using cros_run_vm_update."""
    stateful_change_flag = self.GetStatefulChangeFlag(stateful_change)
    cmd = ['%s/cros_run_vm_update' % self.crosutilsbin,
           '--payload=%s' % update_path,
           '--vm_image_path=%s' % self.vm_image_path,
           '--snapshot',
           self.graphics_flag,
           '--persist',
           '--kvm_pid=%s' % self._kvm_pid_file,
           '--ssh_port=%s' % self._ssh_port,
           stateful_change_flag,
           ]
    if proxy_port: cmd.append('--proxy_port=%s' % proxy_port)
    self.RunUpdateCmd(cmd)

  def VerifyImage(self, unittest, percent_required_to_pass=100):
    """Runs vm smoke suite to verify image."""
    # image_to_live already verifies lsb-release matching.  This is just
    # for additional steps.
    commandWithArgs = ['%s/cros_run_vm_test' % self.crosutilsbin,
                       '--image_path=%s' % self.vm_image_path,
                       '--snapshot',
                       '--persist',
                       '--kvm_pid=%s' % self._kvm_pid_file,
                       '--ssh_port=%s' % self._ssh_port,
                       self.verify_suite,
                      ]
    if self.graphics_flag: commandWithArgs.append(self.graphics_flag)
    output = cros_lib.RunCommand(commandWithArgs, error_ok=True,
                                 enter_chroot=False, redirect_stdout=True)
    return self.AssertEnoughTestsPassed(unittest, output,
                                        percent_required_to_pass)

