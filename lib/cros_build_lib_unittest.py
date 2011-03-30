#!/usr/bin/python
#
# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Unit tests for cros_build_lib."""

import mox
import os
import tempfile
import unittest

import cros_build_lib

class CrosBuildLibTest(mox.MoxTestBase):
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

  def testGetCrosUtilsPathInChroot(self):
    """Tests whether we can get crosutils from chroot."""
    self.mox.StubOutWithMock(cros_build_lib, 'IsInsideChroot')
    crosutils_path_src = '/home/' + os.getenv('USER') + 'trunk/src/scripts'
    crosutils_path_installed = '/usr/lib/crosutils'

    cros_build_lib.IsInsideChroot().MultipleTimes().AndReturn(True)

    self.mox.ReplayAll()
    self.assertTrue(cros_build_lib.GetCrosUtilsPath(source_dir_path=True),
                    crosutils_path_src)
    self.assertTrue(cros_build_lib.GetCrosUtilsPath(source_dir_path=False),
                    crosutils_path_installed)
    self.mox.VerifyAll()

  def testGetCrosUtilsPathOutsideChroot(self):
    """Tests whether we can get crosutils from outside chroot."""
    self.mox.StubOutWithMock(cros_build_lib, 'IsInsideChroot')
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), '..')
    cros_build_lib.IsInsideChroot().MultipleTimes().AndReturn(False)

    self.mox.ReplayAll()
    self.assertTrue(cros_build_lib.GetCrosUtilsPath(), path)
    self.mox.VerifyAll()

  def testGetCrosUtilsBinPath(self):
    """Tests whether we can get crosutilsbin correctly."""
    self.mox.StubOutWithMock(cros_build_lib, 'IsInsideChroot')
    self.mox.StubOutWithMock(cros_build_lib, 'GetCrosUtilsPath')
    src_path = '/fake/src'
    chroot_src_path = '/chroot/fake/src'
    chroot_path = '/usr/bin'

    cros_build_lib.IsInsideChroot().AndReturn(False)
    cros_build_lib.GetCrosUtilsPath(True).AndReturn(src_path)
    cros_build_lib.IsInsideChroot().AndReturn(True)
    cros_build_lib.GetCrosUtilsPath(True).AndReturn(chroot_src_path)
    cros_build_lib.IsInsideChroot().AndReturn(True)

    self.mox.ReplayAll()
    # Outside chroot.
    self.assertTrue(cros_build_lib.GetCrosUtilsBinPath(source_dir_path=True),
                    src_path + '/bin')
    # Rest inside chroot.
    self.assertTrue(cros_build_lib.GetCrosUtilsBinPath(source_dir_path=True),
                    chroot_src_path + '/bin')
    self.assertTrue(cros_build_lib.GetCrosUtilsBinPath(source_dir_path=False),
                    chroot_path)
    self.mox.VerifyAll()



if __name__ == '__main__':
  unittest.main()
