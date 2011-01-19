#!/usr/bin/python
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

import copy
import mox
import os
import prebuilt
import shutil
import tempfile
import unittest
import urllib
from chromite.lib import cros_build_lib
from chromite.lib.binpkg import PackageIndex

PUBLIC_PACKAGES = [{'CPV': 'gtk+/public1', 'SHA1': '1'},
                   {'CPV': 'gtk+/public2', 'SHA1': '2',
                    'PATH': 'gtk%2B/foo.tgz'}]
PRIVATE_PACKAGES = [{'CPV': 'private', 'SHA1': '3'}]


def SimplePackageIndex(header=True, packages=True):
   pkgindex = PackageIndex()
   if header:
     pkgindex.header['URI'] = 'http://www.example.com'
   if packages:
     pkgindex.packages = copy.deepcopy(PUBLIC_PACKAGES + PRIVATE_PACKAGES)
   return pkgindex


class TestUpdateFile(unittest.TestCase):

  def setUp(self):
    self.contents_str = ['# comment that should be skipped',
                         'PKGDIR="/var/lib/portage/pkgs"',
                         'PORTAGE_BINHOST="http://no.thanks.com"',
                         'portage portage-20100310.tar.bz2',
                         'COMPILE_FLAGS="some_value=some_other"',
                         ]
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

  def setUp(self):
    self.mox = mox.Mox()

  def tearDown(self):
    self.mox.UnsetStubs()
    self.mox.VerifyAll()

  def testGenerateUploadDict(self):
    base_local_path = '/b/cbuild/build/chroot/build/x86-dogfood/'
    gs_bucket_path = 'gs://chromeos-prebuilt/host/version'
    local_path = os.path.join(base_local_path, 'public1.tbz2')
    self.mox.StubOutWithMock(prebuilt.os.path, 'exists')
    prebuilt.os.path.exists(local_path).AndReturn(True)
    self.mox.ReplayAll()
    pkgs = [{ 'CPV': 'public1' }]
    result = prebuilt.GenerateUploadDict(base_local_path, gs_bucket_path, pkgs)
    expected = { local_path: gs_bucket_path + '/public1.tbz2' }
    self.assertEqual(result, expected)

  def testFailonUploadFail(self):
    """Make sure we fail if one of the upload processes fail."""
    files = {'test': '/uasd'}
    self.assertEqual(prebuilt.RemoteUpload(files), set([('test', '/uasd')]))

  def testDeterminePrebuiltConf(self):
    """Test the different known variants of boards for proper path discovery."""
    targets = {'amd64': os.path.join(prebuilt._PREBUILT_MAKE_CONF['amd64']),
               'x86-generic': os.path.join(prebuilt._BINHOST_BASE_DIR,
                                        'overlay-x86-generic', 'prebuilt.conf'),
               'arm-tegra2_vogue': os.path.join(
                    prebuilt._BINHOST_BASE_DIR,
                    'overlay-variant-arm-tegra2-vogue', 'prebuilt.conf'),}
    for target in targets:
      self.assertEqual(prebuilt.DeterminePrebuiltConfFile(target),
                       targets[target])

  def testPrivatePrebuiltConf(self):
    """Test that we get a different path for private prebuilts"""
    targets = {'amd64': os.path.join(prebuilt._PREBUILT_MAKE_CONF['amd64']),
               'x86-generic': os.path.join(
                   prebuilt._PRIVATE_OVERLAY_DIR, 'overlay-x86-generic',
                   'prebuilt.conf'),
               'arm-tegra2_vogue': os.path.join(
                    prebuilt._PRIVATE_OVERLAY_DIR,
                    'overlay-variant-arm-tegra2-vogue', 'prebuilt.conf'),}

    self.mox.StubOutWithMock(prebuilt.os.path, 'exists')
    # Add mocks for every target we check
    for mock_count in range(len(targets)):
      prebuilt.os.path.exists(prebuilt._PRIVATE_OVERLAY_DIR).AndReturn(True)
    self.mox.ReplayAll()

    for target in targets:
      self.assertEqual(prebuilt.DeterminePrebuiltConfFile(target),
                       targets[target])

  def testDeterminePrebuiltConfGarbage(self):
    """Ensure an exception is raised on bad input."""
    self.assertRaises(prebuilt.UnknownBoardFormat,
                      prebuilt.DeterminePrebuiltConfFile, 'asdfasdf')


class TestPackagesFileFiltering(unittest.TestCase):

  def testFilterPkgIndex(self):
    pkgindex = SimplePackageIndex()
    pkgindex.RemoveFilteredPackages(lambda pkg: pkg in PRIVATE_PACKAGES)
    self.assertEqual(pkgindex.packages, PUBLIC_PACKAGES)
    self.assertEqual(pkgindex.modified, True)


class TestPopulateDuplicateDB(unittest.TestCase):

  def testEmptyIndex(self):
    pkgindex = SimplePackageIndex(packages=False)
    db = {}
    pkgindex._PopulateDuplicateDB(db)
    self.assertEqual(db, {})

  def testNormalIndex(self):
    pkgindex = SimplePackageIndex()
    db = {}
    pkgindex._PopulateDuplicateDB(db)
    self.assertEqual(len(db), 3)
    self.assertEqual(db['1'], 'http://www.example.com/gtk%2B/public1.tbz2')
    self.assertEqual(db['2'], 'http://www.example.com/gtk%2B/foo.tgz')
    self.assertEqual(db['3'], 'http://www.example.com/private.tbz2')

  def testMissingSHA1(self):
    db = {}
    pkgindex = SimplePackageIndex()
    del pkgindex.packages[0]['SHA1']
    pkgindex._PopulateDuplicateDB(db)
    self.assertEqual(len(db), 2)
    self.assertEqual(db['2'], 'http://www.example.com/gtk%2B/foo.tgz')
    self.assertEqual(db['3'], 'http://www.example.com/private.tbz2')

  def testFailedPopulate(self):
    db = {}
    pkgindex = SimplePackageIndex(header=False)
    self.assertRaises(KeyError, pkgindex._PopulateDuplicateDB, db)
    pkgindex = SimplePackageIndex()
    del pkgindex.packages[0]['CPV']
    self.assertRaises(KeyError, pkgindex._PopulateDuplicateDB, db)


class TestResolveDuplicateUploads(unittest.TestCase):

  def testEmptyList(self):
    pkgindex = SimplePackageIndex()
    pristine = SimplePackageIndex()
    uploads = pkgindex.ResolveDuplicateUploads([])
    self.assertEqual(uploads, pristine.packages)
    self.assertEqual(pkgindex.packages, pristine.packages)
    self.assertEqual(pkgindex.modified, False)

  def testEmptyIndex(self):
    pkgindex = SimplePackageIndex()
    pristine = SimplePackageIndex()
    empty = SimplePackageIndex(packages=False)
    uploads = pkgindex.ResolveDuplicateUploads([empty])
    self.assertEqual(uploads, pristine.packages)
    self.assertEqual(pkgindex.packages, pristine.packages)
    self.assertEqual(pkgindex.modified, False)

  def testDuplicates(self):
    pkgindex = SimplePackageIndex()
    dup_pkgindex = SimplePackageIndex()
    expected_pkgindex = SimplePackageIndex()
    for pkg in expected_pkgindex.packages:
      pkg.setdefault('PATH', urllib.quote(pkg['CPV'] + '.tbz2'))
    uploads = pkgindex.ResolveDuplicateUploads([dup_pkgindex])
    self.assertEqual(pkgindex.packages, expected_pkgindex.packages)

  def testMissingSHA1(self):
    db = {}
    pkgindex = SimplePackageIndex()
    dup_pkgindex = SimplePackageIndex()
    expected_pkgindex = SimplePackageIndex()
    del pkgindex.packages[0]['SHA1']
    del expected_pkgindex.packages[0]['SHA1']
    for pkg in expected_pkgindex.packages[1:]:
      pkg.setdefault('PATH', pkg['CPV'] + '.tbz2')
    uploads = pkgindex.ResolveDuplicateUploads([dup_pkgindex])
    self.assertEqual(pkgindex.packages, expected_pkgindex.packages)


class TestWritePackageIndex(unittest.TestCase):

  def setUp(self):
    self.mox = mox.Mox()

  def tearDown(self):
    self.mox.UnsetStubs()
    self.mox.VerifyAll()

  def testSimple(self):
    pkgindex = SimplePackageIndex()
    self.mox.StubOutWithMock(pkgindex, 'Write')
    pkgindex.Write(mox.IgnoreArg())
    self.mox.ReplayAll()
    f = pkgindex.WriteToNamedTemporaryFile()
    self.assertEqual(f.read(), '')


if __name__ == '__main__':
  unittest.main()
