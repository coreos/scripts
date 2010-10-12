#!/usr/bin/python
#
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Unit tests for ctest."""

import mox
import os
import unittest
import urllib

import ctest

_TEST_BOOT_DESC = """
  --arch="x86"
  --output_dir="/home/chrome-bot/0.8.70.5-a1"
  --espfs_mountpoint="/home/chrome-bot/0.8.70.5-a1/esp"
  --enable_rootfs_verification
"""

class CrosTestTest(mox.MoxTestBase):
  """Test class for CTest."""

  def setUp(self):
    mox.MoxTestBase.setUp(self)
    self.board = 'test-board'
    self.channel = 'test-channel'
    self.version = '1.2.3.4.5'
    self.revision = '7ghfa9999-12345'
    self.image_name = 'TestOS-%s-%s' % (self.version, self.revision)
    self.download_folder = 'test_folder'
    self.latestbase = 'http://test-latest/TestOS'
    self.zipbase = 'http://test-zips/archive/TestOS'
    self.image_url = '%s/%s/%s/%s/%s.zip' % (self.zipbase, self.channel,
                                             self.board, self.version,
                                             self.image_name)
    self.test_regex = 'ChromeOS-\d+\.\d+\.\d+\.\d+-.*\.zip'

  def testModifyBootDesc(self):
    """Tests to make sure we correctly modify a boot desc."""
    in_chroot_path = ctest.ReinterpretPathForChroot(os.path.abspath(
        self.download_folder))
    self.mox.StubOutWithMock(__builtins__, 'open')
    self.mox.StubOutWithMock(ctest.fileinput, 'input')
    m_file = self.mox.CreateMock(file)

    mock_file = _TEST_BOOT_DESC.splitlines(True)
    ctest.fileinput.input('%s/%s' % (os.path.abspath(self.download_folder),
                                     'boot.desc'),
                          inplace=1).AndReturn(mock_file)

    m_file.write('\n')
    m_file.write('  --arch="x86"\n')
    m_file.write('  --output_dir="%s"\n' % in_chroot_path)
    m_file.write('  --espfs_mountpoint="%s/%s"\n' % (in_chroot_path, 'esp'))
    m_file.write('  --enable_rootfs_verification\n')

    self.mox.ReplayAll()
    ctest.ModifyBootDesc(os.path.abspath(self.download_folder), m_file)
    self.mox.VerifyAll()


  def testGetLatestZipUrl(self):
    """Test case that tests GetLatestZipUrl with test urls."""
    self.mox.StubOutWithMock(urllib, 'urlopen')
    m_file = self.mox.CreateMock(file)

    urllib.urlopen('%s/%s/LATEST-%s' % (self.latestbase, self.channel,
                   self.board)).AndReturn(m_file)
    m_file.read().AndReturn('%s.bin.gz' % self.image_name)
    m_file.close()

    self.mox.ReplayAll()
    self.assertEquals(ctest.GetLatestZipUrl(self.board, self.channel,
                                            self.latestbase, self.zipbase),
                      self.image_url)
    self.mox.VerifyAll()

  def testGetLatestZipFromBadUrl(self):
    """Tests whether GetLatestZipUrl returns correct url given bad link."""
    self.mox.StubOutWithMock(urllib, 'urlopen')
    self.mox.StubOutWithMock(ctest, 'GetNewestLinkFromZipBase')
    m_file = self.mox.CreateMock(file)

    urllib.urlopen('%s/%s/LATEST-%s' % (self.latestbase, self.channel,
                   self.board)).AndRaise(IOError('Cannot open url.'))
    ctest.GetNewestLinkFromZipBase(self.board, self.channel,
                                   self.zipbase).AndReturn(self.image_url)

    self.mox.ReplayAll()
    self.assertEquals(ctest.GetLatestZipUrl(self.board, self.channel,
                                            self.latestbase, self.zipbase),
                                            self.image_url)
    self.mox.VerifyAll()

  def testGrabZipAndExtractImageUseCached(self):
    """Test case where cache holds our image."""
    self.mox.StubOutWithMock(os.path, 'exists')
    self.mox.StubOutWithMock(__builtins__, 'open')
    m_file = self.mox.CreateMock(file)

    os.path.exists('%s/%s' % (
        self.download_folder, 'download_url')).AndReturn(True)

    open('%s/%s' % (self.download_folder, 'download_url')).AndReturn(m_file)
    m_file.read().AndReturn(self.image_url)
    m_file.close()

    os.path.exists('%s/%s' % (
        self.download_folder, ctest._IMAGE_TO_EXTRACT)).AndReturn(True)

    self.mox.ReplayAll()
    ctest.GrabZipAndExtractImage(self.image_url, self.download_folder,
                                 ctest._IMAGE_TO_EXTRACT)
    self.mox.VerifyAll()

  def CommonDownloadAndExtractImage(self):
    """Common code to mock downloading image, unzipping it and setting url."""
    zip_path = os.path.join(self.download_folder, 'image.zip')
    m_file = self.mox.CreateMock(file)

    ctest.RunCommand(['rm', '-rf', self.download_folder], print_cmd=False)
    os.mkdir(self.download_folder)
    urllib.urlretrieve(self.image_url, zip_path)
    ctest.RunCommand(['unzip', '-d', self.download_folder, zip_path],
                     print_cmd=False, error_message=mox.IgnoreArg())

    ctest.ModifyBootDesc(self.download_folder)

    open('%s/%s' % (self.download_folder, 'download_url'),
         'w+').AndReturn(m_file)
    m_file.write(self.image_url)
    m_file.close()

    self.mox.ReplayAll()
    ctest.GrabZipAndExtractImage(self.image_url, self.download_folder,
                                 ctest._IMAGE_TO_EXTRACT)
    self.mox.VerifyAll()

  def testGrabZipAndExtractImageNoCache(self):
    """Test case where download_url doesn't exist."""
    self.mox.StubOutWithMock(os.path, 'exists')
    self.mox.StubOutWithMock(os, 'mkdir')
    self.mox.StubOutWithMock(__builtins__, 'open')
    self.mox.StubOutWithMock(ctest, 'RunCommand')
    self.mox.StubOutWithMock(urllib, 'urlretrieve')
    self.mox.StubOutWithMock(ctest, 'ModifyBootDesc')

    m_file = self.mox.CreateMock(file)

    os.path.exists('%s/%s' % (
        self.download_folder, 'download_url')).AndReturn(False)

    self.CommonDownloadAndExtractImage()


  def testGrabZipAndExtractImageWrongCache(self):
    """Test case where download_url exists but doesn't match our url."""
    self.mox.StubOutWithMock(os.path, 'exists')
    self.mox.StubOutWithMock(os, 'mkdir')
    self.mox.StubOutWithMock(__builtins__, 'open')
    self.mox.StubOutWithMock(ctest, 'RunCommand')
    self.mox.StubOutWithMock(urllib, 'urlretrieve')
    self.mox.StubOutWithMock(ctest, 'ModifyBootDesc')

    m_file = self.mox.CreateMock(file)

    os.path.exists('%s/%s' % (
        self.download_folder, 'download_url')).AndReturn(True)

    open('%s/%s' % (self.download_folder, 'download_url')).AndReturn(m_file)
    m_file.read().AndReturn(self.image_url)
    m_file.close()

    os.path.exists('%s/%s' % (
        self.download_folder, ctest._IMAGE_TO_EXTRACT)).AndReturn(False)

    self.CommonDownloadAndExtractImage()

  def testGetLatestLinkFromPage(self):
    """Tests whether we get the latest link from a url given a regex."""
    test_url = 'test_url'
    test_html = """
    <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
    <html>
    <body>
    <h1>Test Index</h1>
    <a href="ZsomeCruft">Cruft</a>
    <a href="YotherCruft">Cruft</a>
    <a href="ChromeOS-0.9.12.4-blahblah.zip">testlink1/</a>
    <a href="ChromeOS-0.9.12.4-blahblah.zip.other/">testlink2/</a>
    <a href="ChromeOS-Factory-0.9.12.4-blahblah.zip/">testlink3/</a>
    </body></html>
    """
    self.mox.StubOutWithMock(urllib, 'urlopen')
    m_file = self.mox.CreateMock(file)

    urllib.urlopen(test_url).AndReturn(m_file)
    m_file.read().AndReturn(test_html)
    m_file.close()

    self.mox.ReplayAll()
    latest_link = ctest.GetLatestLinkFromPage(test_url, regex=self.test_regex)
    self.assertTrue(latest_link == 'ChromeOS-0.9.12.4-blahblah.zip')
    self.mox.VerifyAll()


class HTMLDirectoryParserTest(unittest.TestCase):
  """Test class for HTMLDirectoryParser."""

  def setUp(self):
    self.test_regex = '\d+\.\d+\.\d+\.\d+/'

  def testHandleStarttagGood(self):
    parser = ctest.HTMLDirectoryParser(regex=self.test_regex)
    parser.handle_starttag('a', [('href', '0.9.74.1/')])
    self.assertTrue('0.9.74.1' in parser.link_list)

  def testHandleStarttagBad(self):
    parser = ctest.HTMLDirectoryParser(regex=self.test_regex)
    parser.handle_starttag('a', [('href', 'ZsomeCruft/')])
    self.assertTrue('ZsomeCruft' not in parser.link_list)


if __name__ == '__main__':
  unittest.main()
