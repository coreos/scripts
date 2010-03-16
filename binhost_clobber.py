#!/usr/bin/python
# Copyright (c) 2009 The Chromium Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Script to grab a list of ebuilds which cannot be safely mirrored.

Some ebuilds do not have the proper versioning magic to be able to be safely
mirrored. We would like to phase them out gradually, by updating a list which
can be safely cached.
"""

import os
import re
import StringIO
import tarfile
import urllib


def main():
  # Get a tarball of chromiumos-overlay.
  fh = urllib.urlopen('http://src.chromium.org/cgi-bin/gitweb.cgi?'
                      'p=chromiumos-overlay.git;a=snapshot;h=HEAD;sf=tgz')
  tgz = fh.read()
  fh.close()

  # Prepare a set of files to clobber.
  clobber_list = set()
  # Prepare a set of files to exempt from clobbering.
  exempt_list = set()

  # Walk the tarball looking for SAFE_TO_CACHE lists and ebuilds containing
  # CHROMEOS_ROOT.
  tgzf = StringIO.StringIO(tgz)
  tar = tarfile.open(fileobj=tgzf, mode='r')
  for tinfoi in tar:
    if not tinfoi.isdir():
      original_name = tinfoi.name
      tinfo = tinfoi
      while tinfo.islnk() or tinfo.issym():
        path = os.path.normpath(os.path.join(os.path.dirname(tinfo.name),
                                             tinfo.linkname)) 
        tinfo = tar.getmember(path)
      if tinfo.name.endswith('.ebuild'):
        # Load each ebuild.
        fh = tar.extractfile(tinfo)
        ebuild_data = fh.read()
        fh.close()
        # Add to the clobber list if it contains CHROMEOS_ROOT.
        if 'CHROMEOS_ROOT' in ebuild_data:
          filename = os.path.split(original_name)[1]
          basename = os.path.splitext(filename)[0]
          clobber_list.add(basename)
      elif tinfo.name.endswith('/SAFE_TO_CACHE'):
        fh = tar.extractfile(tinfo)
        for line in fh:
          if len(line) > 1 and line[0] != '#':
            exempt_list.add(line.strip())
        fh.close()
  tar.close()
  tgzf.close()

  # Don't clobber ebuilds listed in SAFE_TO_CACHE.
  clobber_list -= exempt_list

  # Scan the current directory for any Packages files, modify to remove
  # packages that shouldn't be cached.
  for root, _, files in os.walk('.', topdown=False):
    for name in files:
      filename = os.path.join(root, name)
      basename = os.path.split(filename)[1]
      if basename == 'Packages':
        # Filter out entries involving uncache-able ebuilds.
        allowed = True
        nlines = []
        fh = open(filename, 'r')
        for line in fh:
          m = re.match('^CPV\: [^\n]+/([^/]+)[\n]$', line)
          if m:
            allowed = m.group(1) not in clobber_list
          if allowed:
            nlines.append(line)
        fh.close()
        # Write out new contents.
        fh = open(filename, 'w')
        for line in nlines:
          fh.write(line)
        fh.close()


if __name__ == '__main__':
  main()
