#!/usr/bin/python

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""This module allows adding and deleting of projects to the local manifest."""

import sys
import optparse
import os
import xml.etree.ElementTree as ElementTree

from cros_build_lib import Die, FindRepoDir


def _ReadManifest(manifest, err_not_found=False):
  if os.path.isfile(manifest):
    ptree = LocalManifest(open(manifest).read())
  elif err_not_found:
    Die('Manifest file, %s, not found' % manifest)
  else:
    ptree = LocalManifest()
  ptree.Parse()
  return ptree


class LocalManifest:
  """Class which provides an abstraction for manipulating the local manifest."""

  def __init__(self, text=None):
    self._text = text or '<manifest>\n</manifest>'

  def Parse(self):
    """Parse the manifest."""
    self._root = ElementTree.fromstring(self._text)

  def AddProjectElement(self, element, workon='False'):
    """Add a new project element to the manifest tree.

    Returns:
      True on success.
    """
    name = element.attrib['name']
    path = element.attrib['path']
    for project in self._root.findall('project'):
        if project.attrib['path'] == path or project.attrib['name'] == name:
          if project.attrib['path'] == path and project.attrib['name'] == name:
            return True
          else:
            return False
    element.attrib['workon'] = workon
    element.tail = '\n'
    self._root.append(element)
    return True

  def AddProject(self, name, path, workon='False'):
    """Add a workon project if it is not already in the manifest.

    Returns:
      True on success.
    """
    element = ElementTree.Element('project', name=name, path=path)
    return self.AddProjectElement(element, workon=workon)

  def AddWorkonProjectElement(self, element):
    return self.AddProjectElement(element, workon='True')

  def AddWorkonProject(self, name, path):
    return self.AddProject(name, path, workon='True')

  def GetProject(self, name):
    """Accessor method for getting a project node from the manifest tree.

    Returns:
      project element node from ElementTree, otherwise, None
    """

    for project in self._root.findall('project'):
      if project.attrib['name'] == name:
        return project
    return None

  def ToString(self):
    return ElementTree.tostring(self._root, encoding='UTF-8')


def main(argv):
  repo_dir = FindRepoDir()
  if not repo_dir:
    Die("Unable to find repo dir.")

  usage = 'usage: %prog add [options] <name>'
  parser = optparse.OptionParser(usage=usage)
  parser.add_option('-w', '--workon', action='store_true', dest='workon',
                    default=False, help='Is this a workon package?')
  parser.add_option('-f', '--file', dest='local_manifest',
                    default='%s/local_manifest.xml' % repo_dir,
                    help='Non-default manifest file to read.')
  parser.add_option('-d', '--default', dest='full_manifest',
                    default='%s/manifests/full.xml' % repo_dir,
                    help='Default manifest file to read.')
  (options, args) = parser.parse_args(argv[2:])
  if len(args) < 1:
      parser.error('Not enough arguments')
  if argv[1] not in ['add']:
      parser.error('Unsupported command: %s.' % argv[1])
  if not options.workon:
      parser.error('Adding of non-workon projects is currently unsupported.')
  name = args[0]

  local_tree = _ReadManifest(options.local_manifest)
  full_tree = _ReadManifest(options.full_manifest)

  project_element = full_tree.GetProject(name)
  if project_element == None:
    Die('No project named, %s, in the default manifest.' % name)
  success = local_tree.AddWorkonProjectElement(project_element)
  if not success:
    Die('name "%s" already exits with a different path.' % name)

  try:
    print >> open(options.local_manifest, 'w'), local_tree.ToString()
  except Exception, e:
    Die('Error writing to manifest: %s' % e)


if __name__ == '__main__':
  main(sys.argv)
