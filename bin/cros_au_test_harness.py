#!/usr/bin/python

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

import optparse
import os
import re
import sys
import thread
import time
import unittest
import urllib

sys.path.append(os.path.join(os.path.dirname(__file__), '../lib'))
from cros_build_lib import Die
from cros_build_lib import Info
from cros_build_lib import ReinterpretPathForChroot
from cros_build_lib import RunCommand
from cros_build_lib import RunCommandCaptureOutput
from cros_build_lib import Warning

import cros_test_proxy

# VM Constants.
_FULL_VDISK_SIZE = 6072
_FULL_STATEFULFS_SIZE = 3074
_KVM_PID_FILE = '/tmp/harness_pid'
_VERIFY_SUITE = 'suite_Smoke'

# Globals to communicate options to unit tests.
global base_image_path
global board
global remote
global target_image_path
global vm_graphics_flag

class UpdateException(Exception):
  """Exception thrown when UpdateImage or UpdateUsingPayload fail"""
  def __init__(self, code, stdout):
    self.code = code
    self.stdout = stdout

class AUTest(object):
  """Abstract interface that defines an Auto Update test."""
  source_image = ''
  use_delta_updates = False
  verbose = False

  def setUp(self):
    unittest.TestCase.setUp(self)
    # Set these up as they are used often.
    self.crosutils = os.path.join(os.path.dirname(__file__), '..')
    self.crosutilsbin = os.path.join(os.path.dirname(__file__))
    self.download_folder = os.path.join(self.crosutils, 'latest_download')
    if not os.path.exists(self.download_folder):
      os.makedirs(self.download_folder)

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

  # TODO(sosa) - Remove try and convert function to DeltaUpdateImage().
  def TryDeltaAndFallbackToFull(self, src_image, image, stateful_change='old'):
    """Tries the delta update first if set and falls back to full update."""
    if self.use_delta_updates:
      try:
        self.source_image = src_image
        self._UpdateImageReportError(image, stateful_change)
      except:
        Warning('Delta update failed, disabling delta updates and retrying.')
        self.use_delta_updates = False
        self.source_image = ''
        self._UpdateImageReportError(image, stateful_change)
    else:
      self._UpdateImageReportError(image, stateful_change)

  def _UpdateImageReportError(self, image_path, stateful_change='old',
                              proxy_port=None):
    """Calls UpdateImage and reports any error to the console.

       Still throws the exception.
    """
    try:
      self.UpdateImage(image_path, stateful_change, proxy_port)
    except UpdateException as err:
      # If the update fails, print it out
      Warning(err.stdout)
      raise

  def _AttemptUpdateWithPayloadExpectedFailure(self, payload, expected_msg):
    """Attempt a payload update, expect it to fail with expected log"""
    try:
      self.UpdateUsingPayload(payload)
    except UpdateException as err:
      # Will raise ValueError if expected is not found.
      if re.search(re.escape(expected_msg), err.stdout, re.MULTILINE):
        return

    Warning("Didn't find '%s' in:" % expected_msg)
    Warning(err.stdout)
    self.fail('We managed to update when failure was expected')

  def _AttemptUpdateWithFilter(self, filter):
    """Update through a proxy, with a specified filter, and expect success."""

    self.PrepareBase(target_image_path)

    # The devserver runs at port 8080 by default. We assume that here, and
    # start our proxy at 8081. We then tell our update tools to have the
    # client connect to 8081 instead of 8080.
    proxy_port = 8081
    proxy = cros_test_proxy.CrosTestProxy(port_in=proxy_port,
                                          address_out='127.0.0.1',
                                          port_out=8080,
                                          filter=filter)
    proxy.serve_forever_in_thread()

    # This update is expected to fail...
    try:
      self._UpdateImageReportError(target_image_path, proxy_port=proxy_port)
    finally:
      proxy.shutdown()

  def PrepareBase(self, image_path):
    """Prepares target with base_image_path."""
    pass

  def UpdateImage(self, image_path, stateful_change='old', proxy_port=None):
    """Updates target with the image given by the image_path.

    Args:
      image_path:  Path to the image to update with.  This image must be a test
        image.
      stateful_change: How to modify the stateful partition.  Values are:
          'old':  Don't modify stateful partition.  Just update normally.
          'clean':  Uses clobber-state to wipe the stateful partition with the
            exception of code needed for ssh.
      proxy_port:  Port to have the client connect to. For use with
        CrosTestProxy.
    """
    pass

  def UpdateUsingPayload(self,
                         update_path,
                         stateful_change='old',
                         proxy_port=None):
    """Updates target with the pre-generated update stored in update_path

    Args:
      update_path:  Path to the image to update with. This directory should
        contain both update.gz, and stateful.image.gz
      proxy_port:  Port to have the client connect to. For use with
        CrosTestProxy.
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
    print >> sys.stderr, output
    sys.stderr.flush()
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
    self.PrepareBase(base_image_path)
    # TODO(sosa): move to 100% once we start testing using the autotest paired
    # with the dev channel.
    percent_passed = self.VerifyImage(10)

    # Update to - all tests should pass on new image.
    Info('Updating from base image on vm to target image.')
    self.TryDeltaAndFallbackToFull(base_image_path, target_image_path)
    self.VerifyImage(100)

    # Update from - same percentage should pass that originally passed.
    Info('Updating from updated image on vm back to base image.')
    self.TryDeltaAndFallbackToFull(target_image_path, base_image_path)
    self.VerifyImage(percent_passed)

  def testFullUpdateWipeStateful(self):
    """Tests if we can update after cleaning the stateful partition.

    This test checks that we can update successfully after wiping the
    stateful partition.
    """
    # Just make sure some tests pass on original image.  Some old images
    # don't pass many tests.
    self.PrepareBase(base_image_path)
    # TODO(sosa): move to 100% once we start testing using the autotest paired
    # with the dev channel.
    percent_passed = self.VerifyImage(10)

    # Update to - all tests should pass on new image.
    Info('Updating from base image on vm to target image and wiping stateful.')
    self.TryDeltaAndFallbackToFull(base_image_path, target_image_path, 'clean')
    self.VerifyImage(100)

    # Update from - same percentage should pass that originally passed.
    Info('Updating from updated image back to base image and wiping stateful.')
    self.TryDeltaAndFallbackToFull(target_image_path, base_image_path, 'clean')
    self.VerifyImage(percent_passed)

  def testPartialUpdate(self):
    """Tests what happens if we attempt to update with a truncated payload."""
    # Preload with the version we are trying to test.
    self.PrepareBase(target_image_path)

    # Image can be updated at:
    # ~chrome-eng/chromeos/localmirror/autest-images
    url = 'http://gsdview.appspot.com/chromeos-localmirror/' \
          'autest-images/truncated_image.gz'
    payload = os.path.join(self.download_folder, 'truncated_image.gz')

    # Read from the URL and write to the local file
    urllib.urlretrieve(url, payload)

    expected_msg = 'download_hash_data == update_check_response_hash failed'
    self._AttemptUpdateWithPayloadExpectedFailure(payload, expected_msg)

  def testCorruptedUpdate(self):
    """Tests what happens if we attempt to update with a corrupted payload."""
    # Preload with the version we are trying to test.
    self.PrepareBase(target_image_path)

    # Image can be updated at:
    # ~chrome-eng/chromeos/localmirror/autest-images
    url = 'http://gsdview.appspot.com/chromeos-localmirror/' \
          'autest-images/corrupted_image.gz'
    payload = os.path.join(self.download_folder, 'corrupted.gz')

    # Read from the URL and write to the local file
    urllib.urlretrieve(url, payload)

    # This update is expected to fail...
    expected_msg = 'zlib inflate() error:-3'
    self._AttemptUpdateWithPayloadExpectedFailure(payload, expected_msg)

  def testInterruptedUpdate(self):
    """Tests what happens if we interrupt payload delivery 3 times."""

    class InterruptionFilter(cros_test_proxy.Filter):
      """This filter causes the proxy to interrupt the download 3 times

         It does this by closing the first three connections to transfer
         2M total in the outbound connection after they transfer the
         2M.
      """
      def __init__(self):
        """Defines variable shared across all connections"""
        self.close_count = 0

      def setup(self):
        """Called once at the start of each connection."""
        self.data_size = 0

      def OutBound(self, data):
        """Called once per packet for outgoing data.

           The first three connections transferring more than 2M
           outbound will be closed.
        """
        if self.close_count < 3:
          if self.data_size > (2 * 1024 * 1024):
            self.close_count += 1
            return None

        self.data_size += len(data)
        return data

    self._AttemptUpdateWithFilter(InterruptionFilter())

  def testDelayedUpdate(self):
    """Tests what happens if some data is delayed during update delivery"""

    class DelayedFilter(cros_test_proxy.Filter):
      """Causes intermittent delays in data transmission.

         It does this by inserting 3 20 second delays when transmitting
         data after 2M has been sent.
      """
      def setup(self):
        """Called once at the start of each connection."""
        self.data_size = 0
        self.delay_count = 0

      def OutBound(self, data):
        """Called once per packet for outgoing data.

           The first three packets after we reach 2M transferred
           are delayed by 20 seconds.
        """
        if self.delay_count < 3:
          if self.data_size > (2 * 1024 * 1024):
            self.delay_count += 1
            time.sleep(20)

        self.data_size += len(data)
        return data

    self._AttemptUpdateWithFilter(DelayedFilter())

  def SimpleTest(self):
    """A simple update  that updates the target image to itself.

    We explicitly don't use test prefix so that isn't run by default.  Can be
    run using test_prefix option.
    """
    self.PrepareBase(target_image_path)
    self.UpdateImage(target_image_path)
    self.VerifyImage(100)


class RealAUTest(unittest.TestCase, AUTest):
  """Test harness for updating real images."""

  def setUp(self):
    AUTest.setUp(self)

  def PrepareBase(self, image_path):
    """Auto-update to base image to prepare for test."""
    self._UpdateImageReportError(image_path)

  def UpdateImage(self, image_path, stateful_change='old', proxy_port=None):
    """Updates a remote image using image_to_live.sh."""
    stateful_change_flag = self.GetStatefulChangeFlag(stateful_change)
    cmd = ['%s/image_to_live.sh' % self.crosutils,
           '--image=%s' % image_path,
           '--remote=%s' % remote,
           stateful_change_flag,
           '--verify',
           '--src_image=%s' % self.source_image
          ]

    if proxy_port:
      cmd.append('--proxy_port=%s' % proxy_port)

    if self.verbose:
      try:
        RunCommand(cmd)
      except Exception, e:
        raise UpdateException(1, e.message)
    else:
      (code, stdout, stderr) = RunCommandCaptureOutput(cmd)
      if code != 0:
        raise UpdateException(code, stdout)

  def UpdateUsingPayload(self,
                         update_path,
                         stateful_change='old',
                         proxy_port=None):
    """Updates a remote image using image_to_live.sh."""
    stateful_change_flag = self.GetStatefulChangeFlag(stateful_change)
    cmd = ['%s/image_to_live.sh' % self.crosutils,
           '--payload=%s' % update_path,
           '--remote=%s' % remote,
           stateful_change_flag,
           '--verify',
          ]

    if proxy_port:
      cmd.append('--proxy_port=%s' % proxy_port)

    if self.verbose:
      try:
        RunCommand(cmd)
      except Exception, e:
        raise UpdateException(1, e.message)
    else:
      (code, stdout, stderr) = RunCommandCaptureOutput(cmd)
      if code != 0:
        raise UpdateException(code, stdout)

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
      RunCommand(['./cros_stop_vm', '--kvm_pid=%s' % pid_file],
                 cwd=self.crosutilsbin)

    assert not os.path.exists(pid_file)

  def setUp(self):
    """Unit test overriden method.  Is called before every test."""
    AUTest.setUp(self)
    self._KillExistingVM(_KVM_PID_FILE)

  def PrepareBase(self, image_path):
    """Creates an update-able VM based on base image."""
    self.vm_image_path = '%s/chromiumos_qemu_image.bin' % os.path.dirname(
        image_path)

    Info('Creating: %s' % self.vm_image_path)

    if not os.path.exists(self.vm_image_path):
      Info('Qemu image %s not found, creating one.' % self.vm_image_path)
      RunCommand(['%s/image_to_vm.sh' % self.crosutils,
                  '--full',
                  '--from=%s' % ReinterpretPathForChroot(
                      os.path.dirname(image_path)),
                  '--vdisk_size=%s' % _FULL_VDISK_SIZE,
                  '--statefulfs_size=%s' % _FULL_STATEFULFS_SIZE,
                  '--board=%s' % board,
                  '--test_image'], enter_chroot=True)
    else:
      Info('Using existing VM image %s' % self.vm_image_path)


    Info('Testing for %s' % self.vm_image_path)

    self.assertTrue(os.path.exists(self.vm_image_path))

  def UpdateImage(self, image_path, stateful_change='old', proxy_port=None):
    """Updates VM image with image_path."""
    stateful_change_flag = self.GetStatefulChangeFlag(stateful_change)
    if self.source_image == base_image_path:
      self.source_image = self.vm_image_path

    cmd = ['%s/cros_run_vm_update' % self.crosutilsbin,
           '--update_image_path=%s' % image_path,
           '--vm_image_path=%s' % self.vm_image_path,
           '--snapshot',
           vm_graphics_flag,
           '--persist',
           '--kvm_pid=%s' % _KVM_PID_FILE,
           stateful_change_flag,
           '--src_image=%s' % self.source_image,
           ]

    if proxy_port:
      cmd.append('--proxy_port=%s' % proxy_port)

    if self.verbose:
      try:
        RunCommand(cmd)
      except Exception, e:
        raise UpdateException(1, e.message)
    else:
      (code, stdout, stderr) = RunCommandCaptureOutput(cmd)
      if code != 0:
        raise UpdateException(code, stdout)

  def UpdateUsingPayload(self,
                         update_path,
                         stateful_change='old',
                         proxy_port=None):
    """Updates a remote image using image_to_live.sh."""
    stateful_change_flag = self.GetStatefulChangeFlag(stateful_change)
    if self.source_image == base_image_path:
      self.source_image = self.vm_image_path

    cmd = ['%s/cros_run_vm_update' % self.crosutilsbin,
           '--payload=%s' % update_path,
           '--vm_image_path=%s' % self.vm_image_path,
           '--snapshot',
           vm_graphics_flag,
           '--persist',
           '--kvm_pid=%s' % _KVM_PID_FILE,
           stateful_change_flag,
           '--src_image=%s' % self.source_image,
           ]

    if proxy_port:
      cmd.append('--proxy_port=%s' % proxy_port)

    if self.verbose:
      try:
        RunCommand(cmd)
      except Exception, e:
        raise UpdateException(1, e.message)
    else:
      (code, stdout, stderr) = RunCommandCaptureOutput(cmd)
      if code != 0:
        raise UpdateException(code, stdout)

  def VerifyImage(self, percent_required_to_pass):
    """Runs vm smoke suite to verify image."""
    # image_to_live already verifies lsb-release matching.  This is just
    # for additional steps.

    commandWithArgs = ['%s/cros_run_vm_test' % self.crosutilsbin,
                       '--image_path=%s' % self.vm_image_path,
                       '--snapshot',
                       '--persist',
                       '--kvm_pid=%s' % _KVM_PID_FILE,
                       _VERIFY_SUITE,
                       ]

    if vm_graphics_flag:
      commandWithArgs.append(vm_graphics_flag)

    output = RunCommand(commandWithArgs, error_ok=True, enter_chroot=False,
                        redirect_stdout=True)
    return self.CommonVerifyImage(self, output, percent_required_to_pass)


if __name__ == '__main__':
  parser = optparse.OptionParser()
  parser.add_option('-b', '--base_image',
                    help='path to the base image.')
  parser.add_option('-r', '--board',
                    help='board for the images.')
  parser.add_option('--no_delta', action='store_false', default=True,
                    dest='delta',
                    help='Disable using delta updates.')
  parser.add_option('--no_graphics', action='store_true',
                    help='Disable graphics for the vm test.')
  parser.add_option('-m', '--remote',
                    help='Remote address for real test.')
  parser.add_option('-q', '--quick_test', default=False, action='store_true',
                    help='Use a basic test to verify image.')
  parser.add_option('-t', '--target_image',
                    help='path to the target image.')
  parser.add_option('--test_prefix', default='test',
                    help='Only runs tests with specific prefix i.e. '
                         'testFullUpdateWipeStateful.')
  parser.add_option('-p', '--type', default='vm',
                    help='type of test to run: [vm, real]. Default: vm.')
  parser.add_option('--verbose', default=False, action='store_true',
                    help='Print out rather than capture output as much as '
                         'possible.')
  # Set the usage to include flags.
  parser.set_usage(parser.format_help())
  # Parse existing sys.argv so we can pass rest to unittest.main.
  (options, sys.argv) = parser.parse_args(sys.argv)

  AUTest.verbose = options.verbose
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
  if options.quick_test: _VERIFY_SUITE = 'build_RootFilesystemSize'
  AUTest.use_delta_updates = options.delta

  # Only run the test harness we care about.
  test_loader = unittest.TestLoader()
  test_loader.testMethodPrefix = options.test_prefix

  if options.type == 'vm':  test_class = VirtualAUTest
  elif options.type == 'real': test_class = RealAUTest
  else: parser.error('Could not parse harness type %s.' % options.type)

  remote = options.remote

  test_suite = test_loader.loadTestsFromTestCase(test_class)
  test_result = unittest.TextTestRunner(verbosity=2).run(test_suite)

  if not test_result.wasSuccessful():
    Die('Test harness was not successful')
