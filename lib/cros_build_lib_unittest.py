#!/usr/bin/python
#
# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Unit tests for cros_build_lib."""

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
                                       error_ok=True,
                                       exit_code=True)
    self.assertNotEqual(result, 0)

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

  def testRunCommandErrorException(self):
    """Test that RunCommand can throw an exception when a command fails."""

    function = lambda : cros_build_lib.RunCommand(['ls', '/nosuchdir'],
                                                  # Keep the test quiet options
                                                  print_cmd=False,
                                                  redirect_stdout=True,
                                                  redirect_stderr=True) 
    self.assertRaises(cros_build_lib.RunCommandException, function)

  def testRunCommandCaptureOutput(self):
    """Test that RunCommand can capture stdout if a command succeeds."""
    
    result = cros_build_lib.RunCommand(['echo', '-n', 'Hi'],
                                       # Keep the test quiet options
                                       print_cmd=False,
                                       redirect_stdout=True,
                                       redirect_stderr=True)
    self.assertEqual(result, 'Hi')


if __name__ == '__main__':
  unittest.main()
