#!/usr/bin/python

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Unittests for cbuildbot.  Needs to be run inside of chroot for mox."""

import __builtin__
import mox
import os
import posix
import shutil
import unittest

# Fixes circular dependency error.
import cbuildbot_comm
import cbuildbot

class CBuildBotTest(mox.MoxTestBase):

  def setUp(self):
    mox.MoxTestBase.setUp(self)
    # Always stub RunCommmand out as we use it in every method.
    self.mox.StubOutWithMock(cbuildbot, 'RunCommand')
    self.tracking_branch = 'cros/master'
    self._test_repos = [['kernel', 'third_party/kernel/files'],
                        ['login_manager', 'platform/login_manager']
                       ]
    self._test_cros_workon_packages = \
      'chromeos-base/kernel\nchromeos-base/chromeos-login\n'
    self._test_board = 'test-board'
    self._buildroot = '.'
    self._test_dict = {'kernel' : ['chromos-base/kernel', 'dev-util/perf'],
                       'cros' : ['chromos-base/libcros']
                      }
    self._test_string = "kernel.git@12345test cros.git@12333test"
    self._test_string += " crosutils.git@blahblah"
    self._revision_file = 'test-revisions.pfq'
    self._test_parsed_string_array = [
                                      ['chromeos-base/kernel', '12345test'],
                                      ['dev-util/perf', '12345test'],
                                      ['chromos-base/libcros', '12345test']
                                     ]

  def testParseRevisionString(self):
    """Test whether _ParseRevisionString parses string correctly."""
    return_array = cbuildbot._ParseRevisionString(self._test_string,
                                                  self._test_dict)
    self.assertEqual(len(return_array), 3)
    self.assertTrue(
      'chromeos-base/kernel', '12345test' in return_array)
    self.assertTrue(
      'dev-util/perf', '12345test' in return_array)
    self.assertTrue(
      'chromos-base/libcros', '12345test' in return_array)

  def testCreateDictionary(self):
    self.mox.StubOutWithMock(cbuildbot, '_GetAllGitRepos')
    self.mox.StubOutWithMock(cbuildbot, '_GetCrosWorkOnSrcPath')
    cbuildbot._GetAllGitRepos(mox.IgnoreArg()).AndReturn(self._test_repos)
    cbuildbot.RunCommand(mox.IgnoreArg(),
                         cwd='%s/src/scripts' % self._buildroot,
                         redirect_stdout=True,
                         redirect_stderr=True,
                         enter_chroot=True,
                         print_cmd=False).AndReturn(
                             self._test_cros_workon_packages)
    cbuildbot._GetCrosWorkOnSrcPath(self._buildroot, self._test_board,
                                    'chromeos-base/kernel').AndReturn(
        '/home/test/third_party/kernel/files')
    cbuildbot._GetCrosWorkOnSrcPath(self._buildroot, self._test_board,
                                    'chromeos-base/chromeos-login').AndReturn(
        '/home/test/platform/login_manager')
    self.mox.ReplayAll()
    repo_dict = cbuildbot._CreateRepoDictionary(self._buildroot,
                                                self._test_board)
    self.assertEqual(repo_dict['kernel'], ['chromeos-base/kernel'])
    self.assertEqual(repo_dict['login_manager'],
                     ['chromeos-base/chromeos-login'])
    self.mox.VerifyAll()

  # TODO(sosa): Re-add once we use cros_mark vs. cros_mark_all.
  #def testUprevPackages(self):
  #  """Test if we get actual revisions in revisions.pfq."""
  #  self.mox.StubOutWithMock(cbuildbot, '_CreateRepoDictionary')
  #  self.mox.StubOutWithMock(cbuildbot, '_ParseRevisionString')
  #  self.mox.StubOutWithMock(cbuildbot, '_UprevFromRevisionList')
  #  self.mox.StubOutWithMock(__builtin__, 'open')

  #  # Mock out file interaction.
  #  m_file = self.mox.CreateMock(file)
  #  __builtin__.open(self._revision_file).AndReturn(m_file)
  #  m_file.read().AndReturn(self._test_string)
  #  m_file.close()

  #  cbuildbot._CreateRepoDictionary(self._buildroot,
  #                                  self._test_board).AndReturn(self._test_dict)
  #  cbuildbot._ParseRevisionString(self._test_string,
  #                                 self._test_dict).AndReturn(
  #                                     self._test_parsed_string_array)
  #  cbuildbot._UprevFromRevisionList(self._buildroot,
  #                                   self._test_parsed_string_array)
  #  self.mox.ReplayAll()
  #  cbuildbot._UprevPackages(self._buildroot, self._revision_file,
  #                           self._test_board)
  #  self.mox.VerifyAll()

  def testArchiveTestResults(self):
    """Test if we can archive the latest results dir as well as clean up."""
    self.mox.StubOutWithMock(os.path, 'exists')
    self.mox.StubOutWithMock(os, 'listdir')
    self.mox.StubOutWithMock(os, 'stat')
    self.mox.StubOutWithMock(shutil, 'rmtree')
    self.mox.StubOutWithMock(shutil, 'copytree')
    self.mox.StubOutWithMock(shutil, 'copyfile')

    # Create mock stats so that file2 is older than file1.
    dir_listing = ['file1', 'file2']
    stat1 = self.mox.CreateMock(posix.stat_result)
    stat2 = self.mox.CreateMock(posix.stat_result)
    stat1.st_mtime = 99999
    stat2.st_mtime = 10000

    # Set vars for call.
    buildroot = '/fake_dir'
    test_results_dir = 'fake_results_dir'
    archive_dir = 1234
    board = 'fake-board'

    # Expected calls.
    os.path.exists(cbuildbot.ARCHIVE_BASE).AndReturn(True)
    os.listdir(os.path.join(cbuildbot.ARCHIVE_BASE)).AndReturn(dir_listing)
    os.stat('file1').AndReturn(stat1)
    os.stat('file2').AndReturn(stat2)
    # Should remove the oldest path.
    shutil.rmtree(os.path.join(cbuildbot.ARCHIVE_BASE, 'file2'))

    # Convenience variables to make archive easier to understand.
    path_to_results = os.path.join(buildroot, 'chroot', test_results_dir)
    path_to_archive_dir = os.path.join(cbuildbot.ARCHIVE_BASE, str(archive_dir))
    path_to_image = os.path.join(buildroot, 'src', 'build', 'images', board,
                                 'latest', 'chromiumos_qemu_image.bin')
    # Archive logic
    os.path.exists(path_to_archive_dir).AndReturn(False)
    cbuildbot.RunCommand(['sudo', 'chmod', '-R', '+r', path_to_results])
    shutil.copytree(path_to_results, path_to_archive_dir)
    cbuildbot.RunCommand(['gzip', '-f', path_to_image])
    shutil.copyfile(path_to_image + '.gz', os.path.join(
        path_to_archive_dir, 'chromiumos_qemu_image.bin.gz'))

    self.mox.ReplayAll()
    cbuildbot.ARCHIVE_COUNT = 2 # Set equal to list size so we force clean up.
    cbuildbot._ArchiveTestResults(buildroot, board, archive_dir,
                                  test_results_dir)
    self.mox.VerifyAll()

  # TODO(sosa):  Remove once we un-comment above.
  def testUprevPackages(self):
    """Test if we get actual revisions in revisions.pfq."""
    self.mox.StubOutWithMock(__builtin__, 'open')

    # Mock out file interaction.
    m_file = self.mox.CreateMock(file)
    __builtin__.open(self._revision_file).AndReturn(m_file)
    m_file.read().AndReturn(self._test_string)
    m_file.close()

    cbuildbot.RunCommand(['./cros_mark_as_stable', '--all',
                     '--board=%s' % self._test_board,
                     '--tracking_branch="cros/master"', 'commit'],
                     cwd='%s/src/scripts' % self._buildroot,
                     enter_chroot=True)

    self.mox.ReplayAll()
    cbuildbot._UprevPackages(self._buildroot, self.tracking_branch,
                             self._revision_file, self._test_board)
    self.mox.VerifyAll()

  def testUprevAllPackages(self):
    """Test if we get None in revisions.pfq indicating Full Builds."""
    self.mox.StubOutWithMock(__builtin__, 'open')

    # Mock out file interaction.
    m_file = self.mox.CreateMock(file)
    __builtin__.open(self._revision_file).AndReturn(m_file)
    m_file.read().AndReturn('None')
    m_file.close()

    cbuildbot.RunCommand(['./cros_mark_as_stable', '--all',
                         '--board=%s' % self._test_board,
                         '--tracking_branch="cros/master"', 'commit'],
                         cwd='%s/src/scripts' % self._buildroot,
                         enter_chroot=True)

    self.mox.ReplayAll()
    cbuildbot._UprevPackages(self._buildroot, self.tracking_branch,
                             self._revision_file, self._test_board)
    self.mox.VerifyAll()


if __name__ == '__main__':
  unittest.main()
