#!/usr/bin/python
#
# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Unit tests for cros_build_lib."""

import os
import tempfile
import unittest

import cros_build_lib

class CrosBuildLibTest(unittest.TestCase):
  """Test class for cros_build_lib."""

  def testRunCommandSimple(self):
    """Test that RunCommand can run a simple successful command."""
    result = cros_build_lib.RunCommand(['ls'],
                                       # Keep the test quiet options
                                       print_cmd=False,
                                       redirect_stdout=True,
                                       redirect_stderr=True,
                                       # Test specific options
                                       exit_code=True)
    self.assertEqual(result, 0)

  def testRunCommandError(self):
    """Test that RunCommand can return an error code for a failed command."""
    result = cros_build_lib.RunCommand(['ls', '/nosuchdir'],
                                       # Keep the test quiet options
                                       print_cmd=False,
                                       redirect_stdout=True,
                                       redirect_stderr=True,
                                       # Test specific options
                                       exit_code=True)
    self.assertNotEqual(result, 0)
    self.assertEquals(type(result), int)

  def testRunCommandErrorRetries(self):
    """Test that RunCommand can retry a failed command that always fails."""

    # We don't actually check that it's retrying, just exercise the code path.
    result = cros_build_lib.RunCommand(['ls', '/nosuchdir'],
                                       # Keep the test quiet options
                                       print_cmd=False,
                                       redirect_stdout=True,
                                       redirect_stderr=True,
                                       # Test specific options
                                       num_retries=2,
                                       error_ok=True,
                                       exit_code=True)
    self.assertNotEqual(result, 0)
    self.assertEquals(type(result), int)

  def testRunCommandErrorException(self):
    """Test that RunCommand can throw an exception when a command fails."""

    function = lambda : cros_build_lib.RunCommand(['ls', '/nosuchdir'],
                                                  # Keep the test quiet options
                                                  print_cmd=False,
                                                  redirect_stdout=True,
                                                  redirect_stderr=True)
    self.assertRaises(cros_build_lib.RunCommandException, function)

  def testRunCommandErrorCodeNoException(self):
    """Test that RunCommand doesn't throw an exception with exit_code."""

    result = cros_build_lib.RunCommand(['ls', '/nosuchdir'],
                                       # Keep the test quiet options
                                       print_cmd=False,
                                       redirect_stdout=True,
                                       redirect_stderr=True,
                                       # Test specific options
                                       exit_code=True)
    # We are really testing that it doesn't throw an exception if exit_code
    #  if true.
    self.assertNotEqual(result, 0)
    self.assertEquals(type(result), int)

  def testRunCommandCaptureOutput(self):
    """Test that RunCommand can capture stdout if a command succeeds."""

    result = cros_build_lib.RunCommand(['echo', '-n', 'Hi'],
                                       # Keep the test quiet options
                                       print_cmd=False,
                                       redirect_stdout=True,
                                       redirect_stderr=True)
    self.assertEqual(result, 'Hi')

  def testRunCommandLogToFile(self):
    """Test that RunCommand can log output to a file correctly."""
    log_file = tempfile.mktemp()
    cros_build_lib.RunCommand(['echo', '-n', 'Hi'],
                               # Keep the test quiet options
                               print_cmd=False,
                               # Test specific options
                               log_to_file=log_file)
    log_fh = open(log_file)
    log_data = log_fh.read()
    self.assertEquals('Hi', log_data)
    log_fh.close()
    os.remove(log_file)


if __name__ == '__main__':
  unittest.main()
