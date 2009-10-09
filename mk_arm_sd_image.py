#!/usr/bin/env python

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Script to generate ARM beagleboard SD card image from kernel, root fs

This script must be passed a uImage file and a tarred up root filesystem.
It also needs EITHER an output device or a file + size. If you use a real
device, the entire device will be used. if you specify a file, the file
will be truncated to the given length and be formatted as a disk image.

To copy a disk image to a device (e.g. /dev/sdb):
# dd if=disk_image.img of=/dev/sdb bs=4M
"""

from optparse import OptionParser
import math
import os
import re
import shutil
import subprocess
import sys

def DieWithUsage(exec_path):
  print 'usage:', exec_path, ' [-f file] [-s filesize] [-d device] ', \
    'path/to/uImage path/to/armel-rootfs.tgz'
  print 'You must pass either -d or both -f and -s'
  print 'size may end in k, m, or g for kibibyte, mebibytes, gibibytes.'
  print 'This will erase all data on the device or in the file passed.'
  print 'This script must be run as root.'
  sys.exit(1)

def ParseFilesize(size):
  if size == '':
    return -1
  multiplier = 1
  number_part = size[:-1]
  last_char = size[-1]
  if (last_char == 'k') or (last_char == 'K'):
    multiplier = 1024
  elif (last_char == 'm') or (last_char == 'M'):
    multiplier = 1024 * 1024
  elif (last_char == 'g') or (last_char == 'G'):
    multiplier = 1024 * 1024 * 1024
  else:
    number_part = size
  return long(number_part) * multiplier

def ParseArgs(argv):
  use_file = False
  file_size = 0
  device_path = ''
  uimage_path = ''
  rootfs_path = ''
  
  parser = OptionParser()
  parser.add_option('-f', action='store', type='string', dest='filename')
  parser.add_option('-s', action='store', type='string', dest='filesize')
  parser.add_option('-d', action='store', type='string', dest='devname')
  (options, args) = parser.parse_args()

  # check for valid arg presence
  if len(args) != 2:
    DieWithUsage(argv[0])
  if (options.filename != None) != (options.filesize != None):
    DieWithUsage(argv[0])
  if not (bool((options.filename != None) and (options.filesize != None)) ^
          bool(options.devname != None)):
    DieWithUsage(argv[0])
  
  # check the device isn't a partition
  if options.devname != None:
    if (options.devname[-1] >= '0') and (options.devname[-1] <= '9'):
      print 'Looks like you specified a partition device, rather than the ' \
            'entire device. try using -d',options.devname[:-1]
      DieWithUsage(argv[0])
  
  # if size passed, parse size
  if options.filesize != None:
    file_size = ParseFilesize(options.filesize)
    if file_size < 0:
      DieWithUsage(argv[0])
  if options.devname != None:
    device_path = options.devname
  if options.filename != None:
    use_file = True
    device_path = options.filename
  uimage_path = args[0]
  rootfs_path = args[1]
  
  # print args
  if use_file:
    print "file size:", file_size
  print "dev path:", device_path
  print "uimage:", uimage_path
  print 'rootfs:', rootfs_path
  return use_file, file_size, device_path, uimage_path, rootfs_path

def CreateSparseFile(path, size):
  fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0644)
  if (fd < 0):
    print 'os.open() failed'
    exit(1)
  os.ftruncate(fd, size)
  os.close(fd)

# creates the partion table with the first partition having enough
# space for the uimage, the second partition takingn the rest of the space
def CreatePartitions(uimage_path, device_path):
  # get size of first partition in mebibytes
  statinfo = os.stat(uimage_path)
  first_part_size = int(math.ceil(statinfo.st_size / (1024.0 * 1024.0)) + 1)
  System('echo -e ",' + str(first_part_size) \
         + ',c,*\\n,,83,-" | sfdisk -uM \'' + device_path + '\'')

# uses losetup to set up two loopback devices for the two partitions
# returns the two loopback device paths
def SetupLoopbackDevices(device_path):
  sector_size = 512  # bytes
  # get size of partitons
  output = subprocess.Popen(['sfdisk', '-d', device_path],
                            stdout=subprocess.PIPE).communicate()[0]
  m = re.search('start=\\s+(\\d+), size=\\s+(\\d+),.*?start=\\s+(\\d+), size=\\s+(\\d+),', output, re.DOTALL)
  part1_start = long(m.group(1)) * sector_size
  part1_size  = long(m.group(2)) * sector_size
  part2_start = long(m.group(3)) * sector_size
  part2_size  = long(m.group(4)) * sector_size
  if part1_start < 1 or part1_size < 1 or part2_start < 1 or part2_size < 1:
    print 'failed to read partition table'
    sys.exit(1)
  return SetupLoopbackDevice(device_path, part1_start, part1_size), \
         SetupLoopbackDevice(device_path, part2_start, part2_size)

# returns loopback device path
def SetupLoopbackDevice(path, start, size):
  # get a device
  device = subprocess.Popen(['losetup', '-f'],
                            stdout=subprocess.PIPE).communicate()[0].rstrip()
  if device == '':
    print 'can\'t get device'
    sys.exit(1)
  System('losetup -o ' + str(start) + ' --sizelimit ' + str(size) + ' ' + device + ' ' + path)
  return device

def DeleteLoopbackDevice(dev):
  System('losetup -d ' + dev)

def FormatDevices(first, second):
  System('mkfs.msdos -F 32 ' + first)
  System('mkfs.ext3 ' + second)

# returns mounted paths
def MountFilesystems(paths):
  i = 0
  ret = []
  for path in paths:
    i = i + 1
    mntpoint = 'mnt' + str(i)
    System('mkdir ' + mntpoint)
    System('mount ' + path + ' ' + mntpoint)
    ret.append(mntpoint)
  return ret

def UnmountFilesystems(mntpoints):
  for mntpoint in mntpoints:
    System('umount ' + mntpoint)
    os.rmdir(mntpoint)

def System(cmd):
  print 'system(' + cmd + ')'
  p = subprocess.Popen(cmd, shell=True)
  return os.waitpid(p.pid, 0)

def main(argv):
  (use_file, file_size, device_path, uimage_path, rootfs_path) = ParseArgs(argv)
  if use_file:
    CreateSparseFile(device_path, file_size)
  CreatePartitions(uimage_path, device_path)
  if use_file:
    (dev1, dev2) = SetupLoopbackDevices(device_path)
  else:
    dev1 = device_path + '1'
    dev2 = device_path + '2'
  
  FormatDevices(dev1, dev2)
  (mnt1, mnt2) = MountFilesystems([dev1, dev2])
  
  # copy data in
  shutil.copy(uimage_path, mnt1 + '/uImage')
  System('tar xzpf ' + rootfs_path + ' -C ' + mnt2)
  
  UnmountFilesystems([mnt1, mnt2])
  
  if use_file:
    DeleteLoopbackDevice(dev1)
    DeleteLoopbackDevice(dev2)
  print 'all done!'
  if use_file:
    print 'you may want to run dd if=' + device_path + ' of=/some/device bs=4M'

if __name__ == '__main__':
  main(sys.argv)
