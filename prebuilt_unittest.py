#!/usr/bin/python

import os
import unittest
import prebuilt
import tempfile
import mox
from chromite.lib import cros_build_lib

class TestUpdateFile(unittest.TestCase):


  def setUp(self):
    self.contents_str = ['stage 20100309/stage3-amd64-20100309.tar.bz2',
                         'portage portage-20100310.tar.bz2']
    temp_fd, self.version_file = tempfile.mkstemp()
    os.write(temp_fd, '\n'.join(self.contents_str))
    os.close(temp_fd)

  def tearDown(self):
    os.remove(self.version_file)

  def _read_version_file(self):
    """
    Read the contents of self.version_file and return as a list
    """
    version_fh = open(self.version_file)
    try:
      return [line.strip() for line in version_fh.readlines()]
    finally:
      version_fh.close()

  def _verify_key_pair(self, key, val):
    file_contents = self._read_version_file()
    for entry in file_contents:
      file_key, file_val = entry.split()
      if file_key == key:
        if val == file_val:
          break
    else:
      self.fail('Could not find "%s %s" in version file' % (key, val))

  def testAddVariableThatDoesnotExist(self):
    """
    Add in a new variable that was no present in the file
    """
    key = 'x86-testcase'
    value = '1234567'
    prebuilt.UpdateLocalFile(self.version_file, key, value)
    current_version_str = self._read_version_file()
    self._verify_key_pair(key, value)

  def testUpdateVariable(self):
    """
    Test updating a variable that already exists.
    """
    # take first entry in contents
    key, val = self.contents_str[0].split()
    new_val = 'test_update'
    self._verify_key_pair(key, val)
    prebuilt.UpdateLocalFile(self.version_file, key, new_val)
    self._verify_key_pair(key, new_val)
    

class TestPrebuiltFilters(unittest.TestCase):

  def setUp(self):
    self.FAUX_FILTERS = ['oob', 'bibby', 'bob']
    temp_fd, self.filter_filename = tempfile.mkstemp()
    os.write(temp_fd, '\n'.join(self.FAUX_FILTERS))
    os.close(temp_fd)

  def tearDown(self):
    os.remove(self.filter_filename)

  def testListFiles(self):
    """
    create a faux directory and expect specific output from 
    ListFiles
    """
    pass

  def testLoadFilterFile(self):
    """
    Call filter packages with a list of packages that should be filtered
    and ensure they are.
    """
    loaded_filters = prebuilt.LoadFilterFile(self.filter_filename)
    self.assertEqual(self.FAUX_FILTERS, loaded_filters)

  def testFilterPattern(self):
    """
    Check that particular packages are filtered properly.
    """
    prebuilt.LoadFilterFile(self.filter_filename)
    file_list = ['/usr/local/package/oob',
                 '/usr/local/package/other/path/valid',
                 '/var/tmp/bibby.file',
                 '/tmp/b/o/b']
    expected_list = ['/usr/local/package/other/path/valid',
                     '/tmp/b/o/b']
    filtered_list = [file for file in file_list if not
                     prebuilt.FilterPackage(file)]
    self.assertEqual(expected_list, filtered_list)


  def testPrebuiltFiles(self):
    """
    probably need to pull this function out
    """
    pass

class TestPrebuilt(unittest.TestCase):

  files_to_sync = ['/b/cbuild/build/chroot/build/x86-dogfood/packages/x11-misc/shared-mime-info-0.70.tbz2',
                   '/b/cbuild/build/chroot/build/x86-dogfood/packages/x11-misc/util-macros-1.5.0.tbz2',
                   '/b/cbuild/build/chroot/build/x86-dogfood/packages/x11-misc/xbitmaps-1.1.0.tbz2',
                   '/b/cbuild/build/chroot/build/x86-dogfood/packages/x11-misc/read-edid-1.4.2.tbz2',
                   '/b/cbuild/build/chroot/build/x86-dogfood/packages/x11-misc/xdg-utils-1.0.2-r3.tbz2']

  strip_path = '/b/cbuild/build/chroot/build/x86-dogfood/'


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
      results[entry] = os.path.join(gs_bucket_path,
                                 entry.replace(self.strip_path, '').lstrip('/'))
    return results


  def testGenerateUploadDict(self):
    gs_bucket_path = 'gs://chromeos-prebuilt/host/version'
    self.mox.StubOutWithMock(cros_build_lib, 'ListFiles')
    cros_build_lib.ListFiles(' ').AndReturn(self.files_to_sync)
    self.mox.ReplayAll()
    result = prebuilt.GenerateUploadDict(' ', gs_bucket_path, self.strip_path)
    print result
    self.assertEqual(result, self._generate_dict_results(gs_bucket_path))

    


if __name__ == '__main__':
  unittest.main()
