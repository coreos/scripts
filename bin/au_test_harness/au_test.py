# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Module containing a test suite that is run to test auto updates."""

import os
import time
import unittest

import cros_build_lib as cros_lib

import cros_test_proxy
import dummy_au_worker
import real_au_worker
import vm_au_worker


class AUTest(unittest.TestCase):
  """Test harness that uses an au_worker to perform and validate updates.

  Defines a test suite that is run using an au_worker.  An au_worker can
  be created to perform and validates updates on both virtual and real devices.
  See documentation for au_worker for more information.
  """
  @classmethod
  def ProcessOptions(cls, options, use_dummy_worker):
    """Processes options for the test suite and sets up the worker class.

    Args:
      options: options class to be parsed from main class.
      use_dummy_worker: If True, use a dummy_worker_class rather than deriving
        one from options.type.
    """
    cls.base_image_path = options.base_image
    cls.target_image_path = options.target_image
    cls.clean = options.clean

    assert options.type in ['real', 'vm'], 'Failed to specify either real|vm.'
    if use_dummy_worker:
      cls.worker_class = dummy_au_worker.DummyAUWorker
    elif options.type == 'vm':
      cls.worker_class = vm_au_worker.VMAUWorker
    else:
      cls.worker_class = real_au_worker.RealAUWorker

    # Sanity checks.
    if not cls.base_image_path:
      cros_lib.Die('Need path to base image for vm.')
    elif not os.path.exists(cls.base_image_path):
      cros_lib.Die('%s does not exist' % cls.base_image_path)

    if not cls.target_image_path:
      cros_lib.Die('Need path to target image to update with.')
    elif not os.path.exists(cls.target_image_path):
      cros_lib.Die('%s does not exist' % cls.target_image_path)

    # Cache away options to instantiate workers later.
    cls.options = options

  def AttemptUpdateWithPayloadExpectedFailure(self, payload, expected_msg):
    """Attempt a payload update, expect it to fail with expected log"""
    try:
      self.worker.UpdateUsingPayload(payload)
    except UpdateException as err:
      # Will raise ValueError if expected is not found.
      if re.search(re.escape(expected_msg), err.stdout, re.MULTILINE):
        return
      else:
        cros_lib.Warning("Didn't find '%s' in:" % expected_msg)
        cros_lib.Warning(err.stdout)

    self.fail('We managed to update when failure was expected')

  def AttemptUpdateWithFilter(self, filter, proxy_port=8081):
    """Update through a proxy, with a specified filter, and expect success."""
    self.worker.PrepareBase(self.target_image_path)

    # The devserver runs at port 8080 by default. We assume that here, and
    # start our proxy at a different one. We then tell our update tools to
    # have the client connect to our proxy_port instead of 8080.
    proxy = cros_test_proxy.CrosTestProxy(port_in=proxy_port,
                                          address_out='127.0.0.1',
                                          port_out=8080,
                                          filter=filter)
    proxy.serve_forever_in_thread()
    try:
      self.worker.PerformUpdate(self.target_image_path, self.target_image_path,
                                proxy_port=proxy_port)
    finally:
      proxy.shutdown()

  # --- UNITTEST SPECIFIC METHODS ---

  def setUp(self):
    """Overrides unittest.TestCase.setUp and called before every test.

    Sets instance specific variables and initializes worker.
    """
    unittest.TestCase.setUp(self)
    self.worker = self.worker_class(self.options)
    self.crosutils = os.path.join(os.path.dirname(__file__), '..', '..')
    self.download_folder = os.path.join(self.crosutils, 'latest_download')
    if not os.path.exists(self.download_folder):
      os.makedirs(self.download_folder)

  def tearDown(self):
    """Overrides unittest.TestCase.tearDown and called after every test."""
    self.worker.CleanUp()

  def testUpdateKeepStateful(self):
    """Tests if we can update normally.

    This test checks that we can update by updating the stateful partition
    rather than wiping it.
    """
    # Just make sure some tests pass on original image.  Some old images
    # don't pass many tests.
    self.worker.PrepareBase(self.base_image_path)
    # TODO(sosa): move to 100% once we start testing using the autotest paired
    # with the dev channel.
    percent_passed = self.worker.VerifyImage(self, 10)

    # Update to - all tests should pass on new image.
    self.worker.PerformUpdate(self.target_image_path, self.base_image_path)
    percent_passed = self.worker.VerifyImage(self)

    # Update from - same percentage should pass that originally passed.
    self.worker.PerformUpdate(self.base_image_path, self.target_image_path)
    self.worker.VerifyImage(self, percent_passed)

  def testUpdateWipeStateful(self):
    """Tests if we can update after cleaning the stateful partition.

    This test checks that we can update successfully after wiping the
    stateful partition.
    """
    # Just make sure some tests pass on original image.  Some old images
    # don't pass many tests.
    self.worker.PrepareBase(self.base_image_path)
    percent_passed = self.worker.VerifyImage(self, 10)

    # Update to - all tests should pass on new image.
    self.worker.PerformUpdate(self.target_image_path, self.base_image_path,
                              'clean')
    self.worker.VerifyImage(self)

    # Update from - same percentage should pass that originally passed.
    self.worker.PerformUpdate(self.base_image_path, self.target_image_path,
                              'clean')
    self.worker.VerifyImage(self, percent_passed)

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

    self.AttemptUpdateWithFilter(InterruptionFilter(), proxy_port=8082)

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

    self.AttemptUpdateWithFilter(DelayedFilter(), proxy_port=8083)

  def SimpleTest(self):
    """A simple update that updates once from a base image to a target.

    We explicitly don't use test prefix so that isn't run by default.  Can be
    run using test_prefix option.
    """
    self.worker.PrepareBase(self.base_image_path)
    self.worker.PerformUpdate(self.target_image_path, self.base_image_path)
    self.worker.VerifyImage(self)

  # --- DISABLED TESTS ---

  # TODO(sosa): Get test to work with verbose.
  def NotestPartialUpdate(self):
    """Tests what happens if we attempt to update with a truncated payload."""
    # Preload with the version we are trying to test.
    self.worker.PrepareBase(self.target_image_path)

    # Image can be updated at:
    # ~chrome-eng/chromeos/localmirror/autest-images
    url = 'http://gsdview.appspot.com/chromeos-localmirror/' \
          'autest-images/truncated_image.gz'
    payload = os.path.join(self.download_folder, 'truncated_image.gz')

    # Read from the URL and write to the local file
    urllib.urlretrieve(url, payload)

    expected_msg = 'download_hash_data == update_check_response_hash failed'
    self.AttemptUpdateWithPayloadExpectedFailure(payload, expected_msg)

  # TODO(sosa): Get test to work with verbose.
  def NotestCorruptedUpdate(self):
    """Tests what happens if we attempt to update with a corrupted payload."""
    # Preload with the version we are trying to test.
    self.worker.PrepareBase(self.target_image_path)

    # Image can be updated at:
    # ~chrome-eng/chromeos/localmirror/autest-images
    url = 'http://gsdview.appspot.com/chromeos-localmirror/' \
          'autest-images/corrupted_image.gz'
    payload = os.path.join(self.download_folder, 'corrupted.gz')

    # Read from the URL and write to the local file
    urllib.urlretrieve(url, payload)

    # This update is expected to fail...
    expected_msg = 'zlib inflate() error:-3'
    self.AttemptUpdateWithPayloadExpectedFailure(payload, expected_msg)
