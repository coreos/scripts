# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Module that contains the interface for au_test_harness workers.

An au test harnss worker is a class that contains the logic for performing
and validating updates on a target.  This should be subclassed to handle
various types of target.  Types of targets include VM's, real devices, etc.
"""

import inspect
import threading
import os
import sys

import cros_build_lib as cros_lib

import dev_server_wrapper
import update_exception


class AUWorker(object):
  """Interface for a worker that updates and verifies images."""
  # Mapping between cached payloads to directory locations.
  update_cache = None

  # --- INTERFACE ---

  def __init__(self, options, test_results_root):
    """Processes options for the specific-type of worker."""
    self.board = options.board
    self.private_key = options.private_key
    self.test_results_root = test_results_root
    self.use_delta_updates = options.delta
    self.verbose = options.verbose
    self.vm_image_path = None
    if options.quick_test:
      self.verify_suite = 'build_RootFilesystemSize'
    else:
      self.verify_suite = 'suite_Smoke'

    # Set these up as they are used often.
    self.crosutils = os.path.join(os.path.dirname(__file__), '..', '..')
    self.crosutilsbin = os.path.join(os.path.dirname(__file__), '..')

  def CleanUp(self):
    """Called at the end of every test."""
    pass

  def UpdateImage(self, image_path, src_image_path='', stateful_change='old',
                  proxy_port=None, private_key_path=None):
    """Implementation of an actual update.

    See PerformUpdate for description of args.  Subclasses must override this
    method with the correct update procedure for the class.
    """
    pass

  def UpdateUsingPayload(self, update_path, stateful_change='old',
                         proxy_port=None):
    """Updates target with the pre-generated update stored in update_path.

    Subclasses must override this method with the correct update procedure for
    the class.

    Args:
      update_path:  Path to the image to update with. This directory should
        contain both update.gz, and stateful.image.gz
      proxy_port:  Port to have the client connect to. For use with
        CrosTestProxy.
    """
    pass

  def VerifyImage(self, unittest, percent_required_to_pass=100):
    """Verifies the image with tests.

    Verifies that the test images passes the percent required.  Subclasses must
    override this method with the correct update procedure for the class.

    Args:
      unittest: pointer to a unittest to fail if we cannot verify the image.
      percent_required_to_pass:  percentage required to pass.  This should be
        fall between 0-100.

    Returns:
      Returns the percent that passed.
    """
    pass

  # --- INTERFACE TO AU_TEST ---

  def PerformUpdate(self, image_path, src_image_path='', stateful_change='old',
                    proxy_port=None, private_key_path=None):
    """Performs an update using  _UpdateImage and reports any error.

    Subclasses should not override this method but override _UpdateImage
    instead.

    Args:
      image_path:  Path to the image to update with.  This image must be a test
        image.
      src_image_path:  Optional.  If set, perform a delta update using the
        image specified by the path as the source image.
      stateful_change: How to modify the stateful partition.  Values are:
          'old':  Don't modify stateful partition.  Just update normally.
          'clean':  Uses clobber-state to wipe the stateful partition with the
            exception of code needed for ssh.
      proxy_port:  Port to have the client connect to. For use with
        CrosTestProxy.
      private_key_path:  Path to a private key to use with update payload.
    Raises an update_exception.UpdateException if _UpdateImage returns an error.
    """
    try:
      if not self.use_delta_updates: src_image_path = ''
      if private_key_path:
        key_to_use = private_key_path
      else:
        key_to_use = self.private_key

      self.UpdateImage(image_path, src_image_path, stateful_change,
                              proxy_port, key_to_use)
    except update_exception.UpdateException as err:
      # If the update fails, print it out
      Warning(err.stdout)
      raise

  @classmethod
  def SetUpdateCache(cls, update_cache):
    """Sets the global update cache for getting paths to devserver payloads."""
    cls.update_cache = update_cache

  # --- METHODS FOR SUB CLASS USE ---

  def PrepareRealBase(self, image_path):
    """Prepares a remote device for worker test by updating it to the image."""
    self.UpdateImage(image_path)

  def PrepareVMBase(self, image_path):
    """Prepares a VM image for worker test by creating the VM file from the img.
    """
    # VM Constants.
    FULL_VDISK_SIZE = 6072
    FULL_STATEFULFS_SIZE = 3074
    # Needed for VM delta updates.  We need to use the qemu image rather
    # than the base image on a first update.  By tracking the first_update
    # we can set src_image to the qemu form of the base image when
    # performing generating the delta payload.
    self._first_update = True
    self.vm_image_path = '%s/chromiumos_qemu_image.bin' % os.path.dirname(
        image_path)
    if not os.path.exists(self.vm_image_path):
      cros_lib.Info('Creating %s' % self.vm_image_path)
      cros_lib.RunCommand(['./image_to_vm.sh',
                           '--full',
                           '--from=%s' % cros_lib.ReinterpretPathForChroot(
                               os.path.dirname(image_path)),
                           '--vdisk_size=%s' % FULL_VDISK_SIZE,
                           '--statefulfs_size=%s' % FULL_STATEFULFS_SIZE,
                           '--board=%s' % self.board,
                           '--test_image'
                          ], enter_chroot=True, cwd=self.crosutils)

    cros_lib.Info('Using %s as base' % self.vm_image_path)
    assert os.path.exists(self.vm_image_path)

  def GetStatefulChangeFlag(self, stateful_change):
    """Returns the flag to pass to image_to_vm for the stateful change."""
    stateful_change_flag = ''
    if stateful_change:
      stateful_change_flag = '--stateful_update_flag=%s' % stateful_change

    return stateful_change_flag

  def AppendUpdateFlags(self, cmd, image_path, src_image_path, proxy_port,
                        private_key_path):
    """Appends common args to an update cmd defined by an array.

    Modifies cmd in places by appending appropriate items given args.
    """
    if proxy_port: cmd.append('--proxy_port=%s' % proxy_port)

    # Get pregenerated update if we have one.
    update_id = dev_server_wrapper.GenerateUpdateId(image_path, src_image_path,
                                                    private_key_path)
    cache_path = self.update_cache[update_id]
    if cache_path:
      update_url = dev_server_wrapper.DevServerWrapper.GetDevServerURL(
          proxy_port, cache_path)
      cmd.append('--update_url=%s' % update_url)
    else:
      cmd.append('--image=%s' % image_path)
      if src_image_path: cmd.append('--src_image=%s' % src_image_path)

  def RunUpdateCmd(self, cmd):
    """Runs the given update cmd given verbose options.

    Raises an update_exception.UpdateException if the update fails.
    """
    if self.verbose:
      try:
        cros_lib.RunCommand(cmd)
      except Exception as e:
        Warning(str(e))
        raise update_exception.UpdateException(1, str(e))
    else:
      (code, stdout, stderr) = cros_lib.RunCommandCaptureOutput(cmd)
      if code != 0:
        Warning(stdout)
        raise update_exception.UpdateException(code, stdout)

  def AssertEnoughTestsPassed(self, unittest, output, percent_required_to_pass):
    """Helper function that asserts a sufficient number of tests passed.

    Args:
      output: stdout from a test run.
      percent_required_to_pass: percentage required to pass.  This should be
        fall between 0-100.
    Returns:
      percent that passed.
    """
    cros_lib.Info('Output from VerifyImage():')
    print >> sys.stderr, output
    sys.stderr.flush()
    percent_passed = self._ParseGenerateTestReportOutput(output)
    cros_lib.Info('Percent passed: %d vs. Percent required: %d' % (
        percent_passed, percent_required_to_pass))
    unittest.assertTrue(percent_passed >= percent_required_to_pass)
    return percent_passed

  def InitializeResultsDirectory(self):
    """Called by a test to initialize a results directory for this worker."""
    # Use the name of the test.
    test_name = inspect.stack()[1][3]
    self.results_directory = os.path.join(self.test_results_root, test_name)
    self.results_count = 0

  def GetNextResultsPath(self, label):
    """Returns a new results path based for this label.

    Prefixes directory returned for worker with time called i.e. 1_label,
    2_label, etc.
    """
    self.results_count += 1
    return os.path.join(self.results_directory, '%s_%s' % (self.results_count,
                                                           label))

  # --- PRIVATE HELPER FUNCTIONS ---

  def _ParseGenerateTestReportOutput(self, output):
    """Returns the percentage of tests that passed based on output."""
    percent_passed = 0
    lines = output.split('\n')

    for line in lines:
      if line.startswith("Total PASS:"):
        # FORMAT: ^TOTAL PASS: num_passed/num_total (percent%)$
        percent_passed = line.split()[3].strip('()%')
        cros_lib.Info('Percent of tests passed %s' % percent_passed)
        break

    return int(percent_passed)
