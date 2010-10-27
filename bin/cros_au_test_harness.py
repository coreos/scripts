#!/usr/bin/python

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

import optparse
import os
import sys
import unittest

sys.path.append(os.path.join(os.path.dirname(__file__), '../lib'))
from cros_build_lib import Die
from cros_build_lib import Info
from cros_build_lib import ReinterpretPathForChroot
from cros_build_lib import RunCommand
from cros_build_lib import Warning


_KVM_PID_FILE = '/tmp/harness_pid'
_FULL_VDISK_SIZE = 6072
_FULL_STATEFULFS_SIZE = 3074

# Globals to communicate options to unit tests.
global base_image_path
global board
global remote
global target_image_path
global vm_graphics_flag


_VERIFY_SUITE = 'suite_Smoke'

class AUTest(object):
  """Abstract interface that defines an Auto Update test."""
  source_image = ''
  use_delta_updates = False

  def setUp(self):
    unittest.TestCase.setUp(self)
    # Set these up as they are used often.
    self.crosutils = os.path.join(os.path.dirname(__file__), '..')
    self.crosutilsbin = os.path.join(os.path.dirname(__file__))

  def GetStatefulChangeFlag(self, stateful_change):
    """Returns the flag to pass to image_to_vm for the stateful change."""
    stateful_change_flag = ''
    if stateful_change:
      stateful_change_flag = '--stateful_update_flag=%s' % stateful_change

    return stateful_change_flag

  def ParseGenerateTestReportOutput(self, output):
    """Returns the percentage of tests that passed based on output."""
    percent_passed = 0
    lines = output.split('\n')

    for line in lines:
      if line.startswith("Total PASS:"):
        # FORMAT: ^TOTAL PASS: num_passed/num_total (percent%)$
        percent_passed = line.split()[3].strip('()%')
        Info('Percent of tests passed %s' % percent_passed)
        break

    return int(percent_passed)

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

  def VerifyImage(self, percent_required_to_pass):
    """Verifies the image with tests.

    Verifies that the test images passes the percent required.

    Args:
      percent_required_to_pass:  percentage required to pass.  This should be
        fall between 0-100.

    Returns:
      Returns the percent that passed.
    """
    pass

  def CommonVerifyImage(self, unittest, output, percent_required_to_pass):
    """Helper function for VerifyImage that returns percent of tests passed.

    Takes output from a test suite, verifies the number of tests passed is
    sufficient and outputs info.

    Args:
      unittest: Handle to the unittest.
      output: stdout from a test run.
      percent_required_to_pass: percentage required to pass.  This should be
        fall between 0-100.
    Returns:
      percent that passed.
    """
    Info('Output from VerifyImage():')
    print output
    percent_passed = self.ParseGenerateTestReportOutput(output)
    Info('Percent passed: %d vs. Percent required: %d' % (
        percent_passed, percent_required_to_pass))
    unittest.assertTrue(percent_passed >=
                        percent_required_to_pass)
    return percent_passed

  def testFullUpdateKeepStateful(self):
    """Tests if we can update normally.

    This test checks that we can update by updating the stateful partition
    rather than wiping it.
    """
    # Just make sure some tests pass on original image.  Some old images
    # don't pass many tests.
    self.PrepareBase()
    # TODO(sosa): move to 100% once we start testing using the autotest paired
    # with the dev channel.
    percent_passed = self.VerifyImage(10)

    if self.use_delta_updates: self.source_image = base_image_path

    # Update to - all tests should pass on new image.
    Info('Updating from base image on vm to target image.')
    self.UpdateImage(target_image_path)
    self.VerifyImage(100)

    if self.use_delta_updates: self.source_image = target_image_path

    # Update from - same percentage should pass that originally passed.
    Info('Updating from updated image on vm back to base image.')
    self.UpdateImage(base_image_path)
    self.VerifyImage(percent_passed)

  # TODO(sosa): Re-enable once we have a good way of checking for version
  # compatibility.
  def testFullUpdateWipeStateful(self):
    """Tests if we can update after cleaning the stateful partition.

    This test checks that we can update successfully after wiping the
    stateful partition.
    """
    # Just make sure some tests pass on original image.  Some old images
    # don't pass many tests.
    self.PrepareBase()
    # TODO(sosa): move to 100% once we start testing using the autotest paired
    # with the dev channel.
    percent_passed = self.VerifyImage(10)

    if self.use_delta_updates: self.source_image = base_image_path

    # Update to - all tests should pass on new image.
    Info('Updating from base image on vm to target image and wiping stateful.')
    self.UpdateImage(target_image_path, 'clean')
    self.VerifyImage(100)

    if self.use_delta_updates: self.source_image = target_image_path

    # Update from - same percentage should pass that originally passed.
    Info('Updating from updated image back to base image and wiping stateful.')
    self.UpdateImage(base_image_path, 'clean')
    self.VerifyImage(percent_passed)


class RealAUTest(unittest.TestCase, AUTest):
  """Test harness for updating real images."""

  def setUp(self):
    AUTest.setUp(self)

  def PrepareBase(self):
    """Auto-update to base image to prepare for test."""
    self.UpdateImage(base_image_path)

  def UpdateImage(self, image_path, stateful_change='old'):
    """Updates a remote image using image_to_live.sh."""
    stateful_change_flag = self.GetStatefulChangeFlag(stateful_change)

    RunCommand([
        '%s/image_to_live.sh' % self.crosutils,
        '--image=%s' % image_path,
        '--remote=%s' % remote,
        stateful_change_flag,
        '--verify',
        '--src_image=%s' % self.source_image,
        ], enter_chroot=False)


  def VerifyImage(self, percent_required_to_pass):
    """Verifies an image using run_remote_tests.sh with verification suite."""
    output = RunCommand([
        '%s/run_remote_tests.sh' % self.crosutils,
        '--remote=%s' % remote,
        _VERIFY_SUITE,
       ], error_ok=True, enter_chroot=False, redirect_stdout=True)
    return self.CommonVerifyImage(self, output, percent_required_to_pass)


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
    AUTest.setUp(self)
    self._KillExistingVM(_KVM_PID_FILE)

  def PrepareBase(self):
    """Creates an update-able VM based on base image."""

    self.vm_image_path = ('%s/chromiumos_qemu_image.bin' % os.path.dirname(
          base_image_path))
    if not os.path.exists(self.vm_image_path):
      Info('Qemu image not found, creating one.')
      RunCommand(['%s/image_to_vm.sh' % self.crosutils,
                  '--full',
                  '--from=%s' % ReinterpretPathForChroot(
                      os.path.dirname(base_image_path)),
                  '--vdisk_size=%s' % _FULL_VDISK_SIZE,
                  '--statefulfs_size=%s' % _FULL_STATEFULFS_SIZE,
                  '--board=%s' % board,
                  '--test_image'], enter_chroot=True)
    else:
      Info('Using existing VM image')

    self.assertTrue(os.path.exists(self.vm_image_path))

  def UpdateImage(self, image_path, stateful_change='old'):
    """Updates VM image with image_path."""
    stateful_change_flag = self.GetStatefulChangeFlag(stateful_change)

    RunCommand(['%s/cros_run_vm_update' % self.crosutilsbin,
                '--update_image_path=%s' % image_path,
                '--vm_image_path=%s' % self.vm_image_path,
                '--snapshot',
                vm_graphics_flag,
                '--persist',
                '--kvm_pid=%s' % _KVM_PID_FILE,
                stateful_change_flag,
                '--src_image=%s' % self.source_image,
               ], enter_chroot=False)

  def VerifyImage(self, percent_required_to_pass):
    """Runs vm smoke suite to verify image."""
    # image_to_live already verifies lsb-release matching.  This is just
    # for additional steps.
    output = RunCommand(['%s/cros_run_vm_test' % self.crosutilsbin,
                         '--image_path=%s' % self.vm_image_path,
                         '--snapshot',
                         '--persist',
                         vm_graphics_flag,
                         '--kvm_pid=%s' % _KVM_PID_FILE,
                         '--test_case=%s' % _VERIFY_SUITE,
                         ], error_ok=True, enter_chroot=False,
                            redirect_stdout=True)
    return self.CommonVerifyImage(self, output, percent_required_to_pass)


if __name__ == '__main__':
  parser = optparse.OptionParser()
  parser.add_option('-b', '--base_image',
                    help='path to the base image.')
  parser.add_option('-t', '--target_image',
                    help='path to the target image.')
  parser.add_option('-r', '--board',
                    help='board for the images.')
  parser.add_option('-p', '--type', default='vm',
                    help='type of test to run: [vm, real]. Default: vm.')
  parser.add_option('-m', '--remote',
                    help='Remote address for real test.')
  parser.add_option('--no_graphics', action='store_true',
                    help='Disable graphics for the vm test.')
  parser.add_option('--no_delta', action='store_false', default=True,
                    dest='delta',
                    help='Disable using delta updates.')
  # Set the usage to include flags.
  parser.set_usage(parser.format_help())
  # Parse existing sys.argv so we can pass rest to unittest.main.
  (options, sys.argv) = parser.parse_args(sys.argv)

  base_image_path = options.base_image
  target_image_path = options.target_image
  board = options.board

  if not base_image_path:
    parser.error('Need path to base image for vm.')
  elif not os.path.exists(base_image_path):
    Die('%s does not exist' % base_image_path)

  if not target_image_path:
    parser.error('Need path to target image to update with.')
  elif not os.path.exists(target_image_path):
    Die('%s does not exist' % target_image_path)

  if not board:
    parser.error('Need board to convert base image to vm.')

  # Communicate flags to tests.
  vm_graphics_flag = ''
  if options.no_graphics: vm_graphics_flag = '--no_graphics'

  AUTest.use_delta_updates = options.delta

  # Only run the test harness we care about.
  if options.type == 'vm':
    suite = unittest.TestLoader().loadTestsFromTestCase(VirtualAUTest)
    test_result = unittest.TextTestRunner(verbosity=2).run(suite)
  elif options.type == 'real':
    if not options.remote:
      parser.error('Real tests require a remote test machine.')
    else:
      remote = options.remote

    suite = unittest.TestLoader().loadTestsFromTestCase(RealAUTest)
    test_result = unittest.TextTestRunner(verbosity=2).run(suite)
  else:
    parser.error('Could not parse harness type %s.' % options.type)

  if not test_result.wasSuccessful():
    Die('Test harness was not successful')
