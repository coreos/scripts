#!/usr/bin/python

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Unit tests for cros_mark_as_stable.py."""


import mox
import os
import sys
import unittest

# Required to include '.' in the python path.
sys.path.append(os.path.dirname(__file__))
import cros_mark_as_stable

class GitBranchTest(mox.MoxTestBase):

  def setUp(self):
    mox.MoxTestBase.setUp(self)
    # Always stub RunCommmand out as we use it in every method.
    self.mox.StubOutWithMock(cros_mark_as_stable, '_SimpleRunCommand')
    self._branch = 'test_branch'

  def testCreateBranchNoPrevious(self):
    # Test init with no previous branch existing.
    branch = cros_mark_as_stable._GitBranch(self._branch)
    self.mox.StubOutWithMock(branch, 'Exists')
    self.mox.StubOutWithMock(branch, '_Checkout')
    branch.Exists().AndReturn(False)
    branch._Checkout(self._branch)
    self.mox.ReplayAll()
    branch.CreateBranch()
    self.mox.VerifyAll()

  def testCreateBranchWithPrevious(self):
    # Test init with previous branch existing.
    branch = cros_mark_as_stable._GitBranch(self._branch)
    self.mox.StubOutWithMock(branch, 'Exists')
    self.mox.StubOutWithMock(branch, 'Delete')
    self.mox.StubOutWithMock(branch, '_Checkout')
    branch.Exists().AndReturn(True)
    branch.Delete()
    branch._Checkout(self._branch)
    self.mox.ReplayAll()
    branch.CreateBranch()
    self.mox.VerifyAll()

  def testCheckoutCreate(self):
    # Test init with no previous branch existing.
    cros_mark_as_stable._SimpleRunCommand(
        'git checkout -b %s cros/master' % self._branch)
    self.mox.ReplayAll()
    branch = cros_mark_as_stable._GitBranch(self._branch)
    branch._Checkout(self._branch)
    self.mox.VerifyAll()

  def testCheckoutNoCreate(self):
    # Test init with previous branch existing.
    cros_mark_as_stable._SimpleRunCommand('git checkout cros/master')
    self.mox.ReplayAll()
    branch = cros_mark_as_stable._GitBranch(self._branch)
    branch._Checkout('cros/master', False)
    self.mox.VerifyAll()

  def testDelete(self):
    branch = cros_mark_as_stable._GitBranch(self._branch)
    self.mox.StubOutWithMock(branch, '_Checkout')
    branch._Checkout('cros/master', create=False)
    cros_mark_as_stable._SimpleRunCommand('git branch -D ' + self._branch)
    self.mox.ReplayAll()
    branch.Delete()
    self.mox.VerifyAll()

  def testExists(self):
    branch = cros_mark_as_stable._GitBranch(self._branch)

    # Test if branch exists that is created
    cros_mark_as_stable._SimpleRunCommand('git branch').AndReturn(
        '%s %s' % (self._branch, 'cros/master'))
    self.mox.ReplayAll()
    self.assertTrue(branch.Exists())
    self.mox.VerifyAll()


class EBuildTest(mox.MoxTestBase):

  def setUp(self):
    mox.MoxTestBase.setUp(self)
    self.package = 'test_package'
    self.ebuild_path = '/path/test_package-0.0.1-r1.ebuild'
    self.ebuild_path_no_rev = '/path/test_package-0.0.1.ebuild'

  def testInit(self):
    self.mox.StubOutWithMock(cros_mark_as_stable._EBuild, '_FindEBuildPath')
    self.mox.StubOutWithMock(cros_mark_as_stable._EBuild, '_ParseEBuildPath')

    cros_mark_as_stable._EBuild._FindEBuildPath(
        self.package).AndReturn(self.ebuild_path)
    cros_mark_as_stable._EBuild._ParseEBuildPath(
        self.ebuild_path).AndReturn(['/path/test_package-0.0.1',
                                     '/path/test_package',
                                     1])
    self.mox.ReplayAll()
    ebuild = cros_mark_as_stable._EBuild(self.package, 'my_id')
    self.mox.VerifyAll()
    self.assertEquals(ebuild.package, self.package)
    self.assertEquals(ebuild.ebuild_path, self.ebuild_path)
    self.assertEquals(ebuild.ebuild_path_no_revision,
                      '/path/test_package-0.0.1')
    self.assertEquals(ebuild.ebuild_path_no_version, '/path/test_package')
    self.assertEquals(ebuild.current_revision, 1)
    self.assertEquals(ebuild.commit_id, 'my_id')

  def testFindEBuildPath(self):
    self.mox.StubOutWithMock(cros_mark_as_stable, '_SimpleRunCommand')
    cmd = ('ACCEPT_KEYWORDS="x86 arm amd64" '
           'equery-x86-generic which %s 2> /dev/null')
    cros_mark_as_stable._SimpleRunCommand(cmd % self.package).AndReturn(
        self.ebuild_path)
    self.mox.ReplayAll()
    path = cros_mark_as_stable._EBuild._FindEBuildPath(self.package)
    self.mox.VerifyAll()
    self.assertEquals(path, self.ebuild_path)

  def testParseEBuildPath(self):
    # Test with ebuild with revision number.
    no_rev, no_version, revision = cros_mark_as_stable._EBuild._ParseEBuildPath(
        self.ebuild_path)
    self.assertEquals(no_rev, '/path/test_package-0.0.1')
    self.assertEquals(no_version, '/path/test_package')
    self.assertEquals(revision, 1)

  def testParseEBuildPathNoRevisionNumber(self):
    # Test with ebuild without revision number.
    no_rev, no_version, revision = cros_mark_as_stable._EBuild._ParseEBuildPath(
        self.ebuild_path_no_rev)
    self.assertEquals(no_rev, '/path/test_package-0.0.1')
    self.assertEquals(no_version, '/path/test_package')
    self.assertEquals(revision, 0)


class EBuildStableMarkerTest(mox.MoxTestBase):

  def setUp(self):
    mox.MoxTestBase.setUp(self)
    self.mox.StubOutWithMock(cros_mark_as_stable, '_SimpleRunCommand')
    self.m_ebuild = self.mox.CreateMock(cros_mark_as_stable._EBuild)
    self.m_ebuild.package = 'test_package'
    self.m_ebuild.current_revision = 1
    self.m_ebuild.ebuild_path_no_revision = '/path/test_package-0.0.1'
    self.m_ebuild.ebuild_path_no_version = '/path/test_package'
    self.m_ebuild.ebuild_path = '/path/test_package-0.0.1-r1.ebuild'
    self.revved_ebuild_path = '/path/test_package-0.0.1-r2.ebuild'

  def testRevEBuild(self):
    self.mox.StubOutWithMock(cros_mark_as_stable.fileinput, 'input')
    self.mox.StubOutWithMock(cros_mark_as_stable.shutil, 'copyfile')
    m_file = self.mox.CreateMock(file)

    # Prepare mock fileinput.  This tests to make sure both the commit id
    # and keywords are changed correctly.
    mock_file = ['EAPI=2', 'CROS_WORKON_COMMIT=old_id',
                 'KEYWORDS=\"~x86 ~arm\"', 'src_unpack(){}']

    cros_mark_as_stable.shutil.copyfile(
        self.m_ebuild.ebuild_path_no_version + '-9999.ebuild',
        self.revved_ebuild_path)
    cros_mark_as_stable.fileinput.input(self.revved_ebuild_path,
                                        inplace=1).AndReturn(mock_file)
    m_file.write('EAPI=2')
    m_file.write('CROS_WORKON_COMMIT="my_id"\n')
    m_file.write('KEYWORDS="x86 arm"')
    m_file.write('src_unpack(){}')
    cros_mark_as_stable._SimpleRunCommand('git add ' + self.revved_ebuild_path)
    cros_mark_as_stable._SimpleRunCommand('git rm ' + self.m_ebuild.ebuild_path)

    self.mox.ReplayAll()
    marker = cros_mark_as_stable.EBuildStableMarker(self.m_ebuild)
    marker.RevEBuild('my_id', redirect_file=m_file)
    self.mox.VerifyAll()


  def testCommitChange(self):
    mock_message = 'Commit me'
    cros_mark_as_stable._SimpleRunCommand(
        'git commit -am "%s"' % mock_message)
    self.mox.ReplayAll()
    marker = cros_mark_as_stable.EBuildStableMarker(self.m_ebuild)
    marker.CommitChange(mock_message)
    self.mox.VerifyAll()

  def testPushChange(self):
    #cros_mark_as_stable._SimpleRunCommand('git push')
    #self.mox.ReplayAll()
    #marker = cros_mark_as_stable.EBuildStableMarker(self.m_ebuild)
    #marker.PushChange()
    #self.mox.VerifyAll()
    pass


if __name__ == '__main__':
  unittest.main()
