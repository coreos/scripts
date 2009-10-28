#!/usr/bin/env python

# This program operates much like dd, but with two important differences:
# 1. Many features lacking
# 2. seek_bytes= param can specify seek offset in bytes, not block size

import os
import sys
import time

def parseNumber(numstr):
  if numstr.endswith("GB"):
    return int(numstr[:-2]) * 1000 * 1000 * 1000
  if numstr.endswith("MB"):
    return int(numstr[:-2]) * 1000 * 1000
  if numstr.endswith("kB"):
    return int(numstr[:-2]) * 1000
  if numstr.endswith("G"):
    return int(numstr[:-1]) * 1024 * 1024 * 1024
  if numstr.endswith("M"):
    return int(numstr[:-1]) * 1024 * 1024
  if numstr.endswith("K"):
    return int(numstr[:-1]) * 1024
  if numstr.endswith("b"):
    return int(numstr[:-1]) * 512
  if numstr.endswith("w"):
    return int(numstr[:-1]) * 2
  if numstr.endswith("c"):
    return int(numstr[:-1])
  if not numstr.isdigit():
    print >> sys.stderr, "Don't know how to parse number", numstr
    sys.exit(1)
  return int(numstr)

def main(argv):
  arg_if = ""
  arg_of = ""
  arg_bs = 512
  arg_seek = -1
  arg_seek_bytes = -1
  
  for i in argv:
    if i.startswith("if="):
      arg_if=i[3:]
    elif i.startswith("of="):
      arg_of=i[3:]
    elif i.startswith("bs="):
      arg_bs=parseNumber(i[3:])
    elif i.startswith("seek="):
      arg_seek=int(i[5:])
    elif i.startswith("seek_bytes="):
      arg_seek_bytes=parseNumber(i[11:])

  if arg_seek >= 0 and arg_seek_bytes >= 0:
    print >> sys.stderr, "you can't specify seek= and seek_bytes="
    sys.exit(1)
  
  seek_bytes = 0
  if arg_seek >= 0:
    seek_bytes = arg_seek * arg_bs
  elif arg_seek_bytes >= 0:
    seek_bytes = arg_seek_bytes

  if_fd = 0
  of_fd = 1
  if len(arg_if) != 0:
    print >> sys.stderr, "opening for read", arg_if
    if_fd = os.open(arg_if, os.O_RDONLY)
  if len(arg_of) != 0:
    print >> sys.stderr, "opening for write", arg_of
    of_fd = os.open(arg_of, os.O_WRONLY | os.O_TRUNC | os.O_CREAT)
  
  if arg_seek_bytes > 0:
    print >> sys.stderr, "seeking to", seek_bytes, "bytes in output file"
    os.lseek(of_fd, seek_bytes, os.SEEK_SET)
  
  bytes_copied = 0
  
  t1 = time.time()

  buf = os.read(if_fd, arg_bs)
  while len(buf) > 0:
    bytes_written = 0
    while bytes_written < len(buf):
      bytes_written += os.write(of_fd, buf[bytes_written:])
      bytes_copied += bytes_written
    buf = os.read(if_fd, arg_bs)
  
  t2 = time.time()

  os.close(if_fd)
  os.close(of_fd)
  
  # print timing info
  print >> sys.stderr, 'copy %d bytes took %0.3f s' % (bytes_copied, t2 - t1)
  print >> sys.stderr, 'speed: %0.1f MB/s' % \
      ((bytes_copied / 1000000) / (t2 - t1))

if __name__ == '__main__':
  main(sys.argv)
