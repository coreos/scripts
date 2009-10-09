#!/usr/bin/env python

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

from sets import Set
import subprocess
import sys
import time

preferred_virtual_pkg_providers = {
  '<debconf-2.0>': 'debconf',
  '<libgl1>': 'libgl1-mesa-glx',
  '<modutils>': 'module-init-tools',
  '<x-terminal-emulator>': 'xvt',
  '<xserver-xorg-input-4>': 'xserver-xorg-input-kbd',
  '<xserver-xorg-video-5>': 'xserver-xorg-video-dummy'
}

# if we have a set of packages to choose from, we see if any packages we
# can choose from are in this list (starting from element 0). if we find a
# match, we use that, otherwise the script just picks one from the set
preferred_packages = [
  'debconf',
  'debconf-english',
  'ttf-bitstream-vera',
  'libgl1-mesa-glx',
  'module-init-tools',
  '<x-terminal-emulator>',
  'xserver-xorg-input-kbd',
  'xserver-xorg-video-dummy',
  '<xserver-xorg-input-4>',
  '<xserver-xorg-video-5>',
  'udev'
]

def isVirtualPackage(packagename):
  return packagename.startswith('<') and packagename.endswith('>')

def providerForVirtualPkg(packagename):
  # check for any pre-chosen packages
  if packagename in preferred_virtual_pkg_providers:
    return preferred_virtual_pkg_providers[packagename]
  
  name = packagename.strip('<>')
  lines = subprocess.Popen(['apt-cache', 'showpkg', name],
                           stdout=subprocess.PIPE).communicate()[0].split('\n')
  if len(lines) < 2:
    print 'too few lines!', packagename
    sys.exit(1)
  got_reverse_provides_line = False
  for line in lines:
    if got_reverse_provides_line:
      # just take the first one
      provider = line.split(' ')[0]
      if provider == '':
        print 'no provider for', packagename
        sys.exit(1)
      print '"' + provider + '" provides "' + packagename + '"'
      return provider
    got_reverse_provides_line = line.startswith('Reverse Provides:')
  print 'didn\'t find a provider for', packagename
  sys.exit(1)

def getDepsFor(packagename):
  results = subprocess.Popen(['apt-cache', 'depends', packagename],
                             stdout=subprocess.PIPE).communicate()[0]
  lines = results.split('\n')
  if len(lines) < 2:
    print 'too few lines!', packagename
    sys.exit(1)
  ret = Set()
  prefix = '  Depends: '
  # If a package depends on any in a set of packages then each possible package
  # in the set, except for the last one, will have a pipe before Depends.
  # For example:
  #   Depends: foo
  #   Depends: bar
  #  |Depends: baz
  #  |Depends: bat
  #  |Depends: flower
  #   Depends: candle
  #   Depends: trunk
  # means this package depends on foo, bar, trunk, and any one of baz, bat,
  # flower, and candle.
  # I couldn't find this documented anywhere.
  set_prefix = ' |Depends: '
  dep_set = Set()
  for line in lines:
    if line.startswith(set_prefix):
      dep_set.add(line[len(set_prefix):])
      continue
    if not line.startswith(prefix):
      dep_set.clear()
      continue
    pkgname = line[len(prefix):]
    if len(dep_set) > 0:
      dep_set.add(pkgname)
      # we need to pick one from dep_set
      found_pref = False
      for pref in preferred_packages:
        if pref in dep_set:
          print 'using pref to choose "' + pref + '" from set ' + str(dep_set)
          pkgname = pref
          found_pref = True
          break
      if not found_pref:
        print 'chose "' + pkgname + '" from set ' + str(dep_set)
      dep_set.clear()
    ret.add(pkgname)
  print packagename + ' has deps: ' + str(ret)
  return ret

def main(argv):
  checked = Set()
  unchecked = Set()
  for arg in argv[1:]:
    unchecked.add(arg)
  while True:
    directdeps = Set()
    for pkg in unchecked:
      if isVirtualPackage(pkg):
        pkg = providerForVirtualPkg(pkg)
      directdeps = directdeps.union(getDepsFor(pkg))
      checked.add(pkg)
    directdeps = directdeps.difference(checked)
    unchecked = directdeps
    if len(unchecked) == 0:
      print 'done'
      checked_list = list(checked)
      checked_list.sort()
      print 'all:', checked_list
      print 'total of ' + str(len(checked_list)) + ' items'
      sys.exit(0)
    

if __name__ == '__main__':
  main(sys.argv)
