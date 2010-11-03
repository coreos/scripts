#!/usr/bin/python
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Runs tests on VMs in parallel."""

import optparse
import os
import subprocess
import sys

sys.path.append(os.path.join(os.path.dirname(__file__), '../lib'))
from cros_build_lib import Die
from cros_build_lib import Info


class ParallelTestRunner(object):
  """Runs tests on VMs in parallel."""

  _DEFAULT_START_SSH_PORT = 9222

  def __init__(self, tests, results_dir_root=None):
    """Constructs and initializes the test runner class.

    Args:
      tests: A list of test names (see run_remote_tests.sh).
      results_dir_root: The results directory root. If provided, the results
        directory root for each test will be created under it with the SSH port
        appended to the test name.
    """
    self._tests = tests
    self._results_dir_root = results_dir_root

  def _SpawnTests(self):
    """Spawns VMs and starts the test runs on them.

    Runs all tests in |self._tests|. Each test is executed on a separate VM.

    Returns:
      A list of test process info objects containing the following dictionary
      entries:
        'test': the test name;
        'proc': the Popen process instance for this test run.
    """
    ssh_port = self._DEFAULT_START_SSH_PORT
    spawned_tests = []
    # Test runs shouldn't need anything from stdin. However, it seems that
    # running with stdin leaves the terminal in a bad state so redirect from
    # /dev/null.
    dev_null = open('/dev/null')
    for test in self._tests:
      args = [ os.path.join(os.path.dirname(__file__), 'cros_run_vm_test'),
               '--snapshot',  # The image is shared so don't modify it.
               '--no_graphics',
               '--ssh_port=%d' % ssh_port,
               '--test_case=%s' % test ]
      if self._results_dir_root:
        args.append('--results_dir_root=%s/%s.%d' %
                    (self._results_dir_root, test, ssh_port))
      Info('Running %r...' % args)
      proc = subprocess.Popen(args, stdin=dev_null)
      test_info = { 'test': test,
                    'proc': proc }
      spawned_tests.append(test_info)
      ssh_port = ssh_port + 1
    return spawned_tests

  def _WaitForCompletion(self, spawned_tests):
    """Waits for tests to complete and returns a list of failed tests.

    Args:
      spawned_tests: A list of test info objects (see _SpawnTests).

    Returns:
      A list of failed test names.
    """
    failed_tests = []
    for test_info in spawned_tests:
      proc = test_info['proc']
      proc.wait()
      if proc.returncode: failed_tests.append(test_info['test'])
    return failed_tests

  def Run(self):
    """Runs the tests in |self._tests| on separate VMs in parallel."""
    spawned_tests = self._SpawnTests()
    failed_tests = self._WaitForCompletion(spawned_tests)
    if failed_tests: Die('Tests failed: %r' % failed_tests)


def main():
  usage = 'Usage: %prog [options] tests...'
  parser = optparse.OptionParser(usage=usage)
  parser.add_option('--results_dir_root', help='Root results directory.')
  (options, args) = parser.parse_args()

  if not args:
    parser.print_help()
    Die('no tests provided')

  runner = ParallelTestRunner(args, options.results_dir_root)
  runner.Run()


if __name__ == '__main__':
  main()
