#!/usr/bin/env python

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Makes changes to mounted Chromium OS image to allow it to run with VMs

This script changes two files within the Chromium OS image to let the image
work with VMs, particularly QEMU

Currently this script does the following,
1.) Modify xorg.conf to advertize a screen which can do 1280x1024
"""

from optparse import OptionParser
import os
import stat
import sys

USAGE = "usage: %prog --mounted_dir=directory"

REPLACE_SCREEN_PAIR = ('Identifier "DefaultMonitor"',
  'Identifier "DefaultMonitor"\n    HorizSync 28-51\n    VertRefresh 43-60')
XORG_CONF_FILENAME = os.path.join('etc', 'X11', 'xorg.conf')


# Modify the xorg.conf file to change all screen sections
def FixXorgConf(mount_point):
  xorg_conf_filename = os.path.join(mount_point, XORG_CONF_FILENAME)
  f = open(xorg_conf_filename, 'r')
  xorg_conf = f.read()
  f.close()

  # Add refresh rates for the screen
  xorg_conf = xorg_conf.replace(REPLACE_SCREEN_PAIR[0],
                                REPLACE_SCREEN_PAIR[1])

  # Write the file back out.
  f = open(xorg_conf_filename, 'w')
  f.write(xorg_conf)
  f.close()

def main():
  parser = OptionParser(USAGE)
  parser.add_option('--mounted_dir', dest='mounted_dir',
                    help='directory where the Chromium OS image is mounted')
  (options, args) = parser.parse_args()

  if not options.mounted_dir:
    parser.error("Please specify the mount point for the Chromium OS image");

  FixXorgConf(options.mounted_dir)


if __name__ == '__main__':
  main()
