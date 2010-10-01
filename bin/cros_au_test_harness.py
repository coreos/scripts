#!/usr/bin/python

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

import optparse
import os
import sys
import unittest

sys.path.append(os.path.join(os.path.dirname(__file__), '../lib'))
from cros_build_lib import RunCommand, Info, Warning

_KVM_PID_FILE = '/tmp/harness_pid'
_SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), '..')
_FULL_VDISK_SIZE = 6072
_FULL_STATEFULFS_SIZE = 2048

global base_image_path
global target_image_path

_VERIFY_SUITE = 'suite_Smoke'

class AUTest(object):
  """Abstract interface that defines an Auto Update test."""

  def PrepareBase(self):
    """Prepares target with base_image_path."""
    pass

  def UpdateImage(self, image_path, stateful_change='old'):
    """Updates target with the image given by the image_path.

    Args:
      image_path:  Path to the image to update with.  This image must be a test
        image.
      stateful_change: How to modify the stateful partition.  Values are:
          'old':  Don't modify stateful partition.  Just update normally.
          'clean':  Uses clobber-state to wipe the stateful partition with the
            exception of code needed for ssh.
    """
    pass

  def VerifyImage(self):
    """Verifies the image is correct."""
    pass

  def testFullUpdateKeepStateful(self):
    # Prepare and verify the base image has been prepared correctly.
    self.PrepareBase()
    self.VerifyImage()

    # Update to.
    Info('Updating from base image on vm to target image.')
    self.UpdateImage(target_image_path)
    self.VerifyImage()

    # Update from.
    Info('Updating from updated image on vm back to base image.')
    self.UpdateImage(base_image_path)
    self.VerifyImage()

  def testFullUpdateWipeStateful(self):
    # Prepare and verify the base image has been prepared correctly.
    self.PrepareBase()
    self.VerifyImage()

    # Update to.
    Info('Updating from base image on vm to target image and wiping stateful.')
    self.UpdateImage(target_image_path, 'clean')
    self.VerifyImage()

    # Update from.
    Info('Updating from updated image back to base image and wiping stateful.')
    self.UpdateImage(base_image_path, 'clean')
    self.VerifyImage()


class VirtualAUTest(unittest.TestCase, AUTest):
  """Test harness for updating virtual machines."""
  vm_image_path = None

  def _KillExistingVM(self, pid_file):
    if os.path.exists(pid_file):
      Warning('Existing %s found.  Deleting and killing process' %
              pid_file)
      pid = RunCommand(['sudo', 'cat', pid_file], redirect_stdout=True,
                       enter_chroot=False)
      if pid:
        RunCommand(['sudo', 'kill', pid.strip()], error_ok=True,
                   enter_chroot=False)
        RunCommand(['sudo', 'rm', pid_file], enter_chroot=False)

  def setUp(self):
    """Unit test overriden method.  Is called before every test."""

    self._KillExistingVM(_KVM_PID_FILE)

  def PrepareBase(self):
    """Creates an update-able VM based on base image."""

    self.vm_image_path = ('%s/chromiumos_qemu_image.bin' % os.path.dirname(
          base_image_path))
    if not os.path.exists(self.vm_image_path):
      Info('Qemu image not found, creating one.')
      RunCommand(['%s/image_to_vm.sh' % _SCRIPTS_DIR,
                  '--full',
                  '--from %s' % os.path.dirname(base_image_path),
                  '--vdisk_size %s' % _FULL_VDISK_SIZE,
                  '--statefulfs_size %s' % _FULL_STATEFULFS_SIZE,
                  '--test_image'], enter_chroot=True)
    else:
      Info('Using existing VM image')

    self.assertTrue(os.path.exists(self.vm_image_path))

  def UpdateImage(self, image_path, stateful_change='old'):
    """Updates VM image with image_path."""

    stateful_change_flag = ''
    if stateful_change:
      stateful_change_flag = '--stateful_flags=%s' % stateful_change

    RunCommand(['%s/cros_run_vm_update' % os.path.dirname(__file__),
                '--update_image_path=%s' % image_path,
                '--vm_image_path=%s' % self.vm_image_path,
                '--snapshot',
                '--persist',
                '--kvm_pid=%s' % _KVM_PID_FILE,
                stateful_change_flag,
               ], enter_chroot=False)

  def VerifyImage(self):
    """Runs vm smoke suite to verify image."""

    # image_to_live already verifies lsb-release matching.  This is just
    # for additional steps.

    # TODO(sosa):  Compare output with results of base image.
    RunCommand(['%s/cros_run_vm_test' % os.path.dirname(__file__),
                '--image_path=%s' % self.vm_image_path,
                '--snapshot',
                '--persist',
                '--kvm_pid=%s' % _KVM_PID_FILE,
                '--test_case=%s' % _VERIFY_SUITE,
               ], error_ok=True, enter_chroot=False)


if __name__ == '__main__':
  parser = optparse.OptionParser()
  parser.add_option('-b', '--base_image',
                    help='path to the base image.')
  parser.add_option('-t', '--target_image',
                    help='path to the target image')
  # Set the usage to include flags.
  parser.set_usage(parser.format_help())
  # Parse existing sys.argv so we can pass rest to unittest.main.
  (options, sys.argv) = parser.parse_args(sys.argv)

  base_image_path = options.base_image
  target_image_path = options.target_image

  if not base_image_path:
    parser.error('Need path to base image for vm.')

  if not target_image_path:
    parser.error('Need path to target image to update with.')

  unittest.main()
