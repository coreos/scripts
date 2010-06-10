#!/usr/bin/python

''' Utility to upload debug symbols to the Google Breakpad Server '''

import os
import subprocess
import sys

# Common Global Variables
DEBUG_BASE_PATH='/build'
DEBUG_SUBPATH='/usr/lib/debug'
DEBUG_EXT='.sym'
BP_UPLOAD=('../third_party/google-breakpad/'
'files/src/tools/linux/symupload/symupload')

def CheckBinaryExists():
  if os.path.exists(BP_UPLOAD):
    return True
  return False 

def FindDebugFiles():

  curdir = os.curdir
  if not os.path.exists("/etc/debian_chroot"):
    DEBUG_BASE_PATH= sys.argv[0] + '/../../chroot/build'

  files = []
  for dirpath, dirnames, filenames in os.walk(DEBUG_BASE_PATH):
    filenames[:] = [os.path.join(dirpath, fname) 
        for fname in filenames if fname.endswith(DEBUG_EXT)]
    files.extend(filenames)
  return files   

def Upload(filenames=[]):

    for filename in filenames:
      print 'executing..' + BP_UPLOAD + ' ' + filename
      retval = subprocess.call([BPUPLOAD, filename])
      print retval
      print 'done.'

def Main():
  if not CheckBinaryExists():
    print "Could not find Breakpad Upload Binary at : %s " % BP_UPLOAD
    return

  filenames = FindDebugFiles()
  Upload(filenames)

if  __name__ == '__main__':
  Main()
