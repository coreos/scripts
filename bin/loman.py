#!/usr/bin/python

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""This module allows adding and deleting of projects to the local manifest."""

import sys
import optparse
import os
import xml.etree.ElementTree as ElementTree

from cros_build_lib import Die


def _FindRepoDir():
  cwd = os.getcwd()
  while cwd != '/':
    repo_dir = os.path.join(cwd, '.repo')
    if os.path.isdir(repo_dir):
      return repo_dir
    cwd = os.path.dirname(cwd)
  return None


class LocalManifest:
  """Class which provides an abstraction for manipulating the local manifest."""

  def __init__(self, text=None):
    self._text = text or '<manifest>\n</manifest>'

  def Parse(self):
    """Parse the manifest."""
    self._root = ElementTree.fromstring(self._text)

  def AddWorkonProject(self, name, path):
    """Add a new workon project if it is not already in the manifest.

    Returns:
      True on success.
    """

    for project in self._root.findall('project'):
        if project.attrib['path'] == path or project.attrib['name'] == name:
          if project.attrib['path'] == path and project.attrib['name'] == name:
            return True
          else:
            return False
    self._AddProject(name, path, workon='True')
    return True

  def _AddProject(self, name, path, workon='False'):
    element = ElementTree.Element('project', name=name, path=path,
                                  workon=workon)
    element.tail = '\n'
    self._root.append(element)

  def ToString(self):
    return ElementTree.tostring(self._root, encoding='UTF-8')


def main(argv):
  usage = 'usage: %prog add [options] <name> <path>'
  parser = optparse.OptionParser(usage=usage)
  parser.add_option('-w', '--workon', action='store_true', dest='workon',
                    default=False, help='Is this a workon package?')
  parser.add_option('-f', '--file', dest='manifest',
                    help='Non-default manifest file to read.')
  (options, args) = parser.parse_args(argv[2:])
  if len(args) < 2:
      parser.error('Not enough arguments')
  if argv[1] not in ['add']:
      parser.error('Unsupported command: %s.' % argv[1])
  if not options.workon:
      parser.error('Adding of non-workon projects is currently unsupported.')
  (name, path) = (args[0], args[1])

  repo_dir = _FindRepoDir()
  if not repo_dir:
    Die("Unable to find repo dir.")
  local_manifest = options.manifest or \
    os.path.join(_FindRepoDir(), 'local_manifest.xml')
  if os.path.isfile(local_manifest):
    ptree = LocalManifest(open(local_manifest).read())
  else:
    ptree = LocalManifest()
  ptree.Parse()
  if not ptree.AddWorkonProject(name, path):
      Die('Path "%s" or name "%s" already exits in the manifest.' %
          (path, name))
  try:
    print >> open(local_manifest, 'w'), ptree.ToString()
  except Exception, e:
    Die('Error writing to manifest: %s' % e)


if __name__ == '__main__':
  main(sys.argv)
