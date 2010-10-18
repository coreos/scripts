#!/usr/bin/python
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

import mox
import os
import prebuilt
import shutil
import tempfile
import unittest
from chromite.lib import cros_build_lib

class TestUpdateFile(unittest.TestCase):

  def setUp(self):
    self.contents_str = ['# comment that should be skipped',
                         'PKGDIR="/var/lib/portage/pkgs"',
                         'PORTAGE_BINHOST="http://no.thanks.com"',
                         'portage portage-20100310.tar.bz2']
    temp_fd, self.version_file = tempfile.mkstemp()
    os.write(temp_fd, '\n'.join(self.contents_str))
    os.close(temp_fd)

  def tearDown(self):
    os.remove(self.version_file)

  def _read_version_file(self):
    """Read the contents of self.version_file and return as a list."""
    version_fh = open(self.version_file)
    try:
      return [line.strip() for line in version_fh.readlines()]
    finally:
      version_fh.close()

  def _verify_key_pair(self, key, val):
    file_contents = self._read_version_file()
    # ensure key for verify is wrapped on quotes
    if '"' not in val:
      val = '"%s"' % val
    for entry in file_contents:
      if '=' not in entry:
        continue
      file_key, file_val = entry.split('=')
      if file_key == key:
        if val == file_val:
          break
    else:
      self.fail('Could not find "%s=%s" in version file' % (key, val))

  def testAddVariableThatDoesNotExist(self):
    """Add in a new variable that was no present in the file."""
    key = 'PORTAGE_BINHOST'
    value = '1234567'
    prebuilt.UpdateLocalFile(self.version_file, value)
    print self.version_file
    current_version_str = self._read_version_file()
    self._verify_key_pair(key, value)
    print self.version_file

  def testUpdateVariable(self):
    """Test updating a variable that already exists."""
    key, val = self.contents_str[2].split('=')
    new_val = 'test_update'
    self._verify_key_pair(key, val)
    prebuilt.UpdateLocalFile(self.version_file, new_val)
    self._verify_key_pair(key, new_val)


class TestPrebuiltFilters(unittest.TestCase):

  def setUp(self):
    self.tmp_dir = tempfile.mkdtemp()
    self.private_dir = os.path.join(self.tmp_dir,
                                    prebuilt._PRIVATE_OVERLAY_DIR)
    self.private_structure_base = 'chromeos-overlay/chromeos-base'
    self.private_pkgs = ['test-package/salt-flavor-0.1.r3.ebuild',
                         'easy/alpha_beta-0.1.41.r3.ebuild',
                         'dev/j-t-r-0.1.r3.ebuild',]
    self.expected_filters = set(['salt-flavor', 'alpha_beta', 'j-t-r'])

  def tearDown(self):
    if self.tmp_dir:
      shutil.rmtree(self.tmp_dir)

  def _CreateNestedDir(self, tmp_dir, dir_structure):
    for entry in dir_structure:
      full_path = os.path.join(os.path.join(tmp_dir, entry))
      # ensure dirs are created
      try:
        os.makedirs(os.path.dirname(full_path))
        if full_path.endswith('/'):
          # we only want to create directories
          return
      except OSError, err:
        if err.errno == errno.EEXIST:
          # we don't care if the dir already exists
          pass
        else:
          raise
      # create dummy files
      tmp = open(full_path, 'w')
      tmp.close()

  def _LoadPrivateMockFilters(self):
    """Load mock filters as defined in the setUp function."""
    dir_structure = [os.path.join(self.private_structure_base, entry)
                     for entry in self.private_pkgs]

    self._CreateNestedDir(self.private_dir, dir_structure)
    prebuilt.LoadPrivateFilters(self.tmp_dir)
 
  def testFilterPattern(self):
    """Check that particular packages are filtered properly."""
    self._LoadPrivateMockFilters()
    packages = ['/some/dir/area/j-t-r-0.1.r3.tbz',
                '/var/pkgs/new/alpha_beta-0.2.3.4.tbz',
                '/usr/local/cache/good-0.1.3.tbz',
                '/usr-blah/b_d/salt-flavor-0.0.3.tbz']
    expected_list = ['/usr/local/cache/good-0.1.3.tbz']
    filtered_list = [file for file in packages if not
                     prebuilt.ShouldFilterPackage(file)]
    self.assertEqual(expected_list, filtered_list)

  def testLoadPrivateFilters(self):
    self._LoadPrivateMockFilters()
    prebuilt.LoadPrivateFilters(self.tmp_dir)
    self.assertEqual(self.expected_filters, prebuilt._FILTER_PACKAGES)

  def testEmptyFiltersErrors(self):
    """Ensure LoadPrivateFilters errors if an empty list is generated."""
    os.makedirs(os.path.join(self.tmp_dir, prebuilt._PRIVATE_OVERLAY_DIR))
    self.assertRaises(prebuilt.FiltersEmpty, prebuilt.LoadPrivateFilters,
                      self.tmp_dir)


class TestPrebuilt(unittest.TestCase):
  fake_path = '/b/cbuild/build/chroot/build/x86-dogfood/'
  bin_package_mock = ['packages/x11-misc/shared-mime-info-0.70.tbz2',
                      'packages/x11-misc/util-macros-1.5.0.tbz2',
                      'packages/x11-misc/xbitmaps-1.1.0.tbz2',
                      'packages/x11-misc/read-edid-1.4.2.tbz2',
                      'packages/x11-misc/xdg-utils-1.0.2-r3.tbz2']

  files_to_sync = [os.path.join(fake_path, file) for file in bin_package_mock]

  def setUp(self):
    self.mox = mox.Mox()

  def tearDown(self):
    self.mox.UnsetStubs()
    self.mox.VerifyAll()

  def _generate_dict_results(self, gs_bucket_path):
    """
    Generate a dictionary result similar to GenerateUploadDict
    """
    results = {}
    for entry in self.files_to_sync:
      results[entry] = os.path.join(
        gs_bucket_path, entry.replace(self.fake_path, '').lstrip('/'))
    return results

  def testGenerateUploadDict(self):
    gs_bucket_path = 'gs://chromeos-prebuilt/host/version'
    self.mox.StubOutWithMock(cros_build_lib, 'ListFiles')
    cros_build_lib.ListFiles(' ').AndReturn(self.files_to_sync)
    self.mox.ReplayAll()
    result = prebuilt.GenerateUploadDict(' ', gs_bucket_path, self.fake_path)
    self.assertEqual(result, self._generate_dict_results(gs_bucket_path))

  def testFailonUploadFail(self):
    """Make sure we fail if one of the upload processes fail."""
    files = {'test': '/uasd'}
    self.assertEqual(prebuilt.RemoteUpload(files), set([('test', '/uasd')]))

  def testDetermineMakeConf(self):
    """Test the different known variants of boards for proper path discovery."""
    targets = {'amd64': os.path.join(prebuilt._PREBUILT_MAKE_CONF['amd64']),
               'x86-generic': os.path.join(prebuilt._BINHOST_BASE_DIR,
                                           'overlay-x86-generic', 'make.conf'),
               'arm-tegra2_vogue': os.path.join(
                    prebuilt._BINHOST_BASE_DIR,
                    'overlay-variant-arm-tegra2-vogue', 'make.conf'),}
    for target in targets:
      self.assertEqual(prebuilt.DetermineMakeConfFile(target), targets[target])

  def testDetermineMakeConfGarbage(self):
    """Ensure an exception is raised on bad input."""
    self.assertRaises(prebuilt.UnknownBoardFormat, prebuilt.DetermineMakeConfFile,
                      'asdfasdf')


if __name__ == '__main__':
  unittest.main()
