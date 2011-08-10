#!/bin/sh

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This should be able to run outside the chroot on a standard Ubuntu system.

BINFILE="$1"

if [ -z "$BINFILE" ]; then
  echo "usage: $0 .../path/to/file.bin"
  exit 1
fi

parted "$BINFILE" unit s print | awk -v BF="$BINFILE" '
/KERN-|ROOT-/ {
  # Common things
  printf "Partition " $1 " (" $NF "): "
  start=substr($2, 0, length($2) - 1)  # strip trailing "s"
}

/KERN-/ {
  cnt=substr($4, 0, length($4) - 1)
  system("dd if=\"" BF "\" bs=512 skip=" start " count=" cnt \
      " 2>/dev/null | openssl dgst -sha256 -binary | openssl base64")
}

/ROOT-/ {
  # we have rootfs. find the filesystem size
  "mktemp" | getline tmpfile
  close("mktemp")
  system("dd if=" BF " bs=512 skip=" start \
      " count=400 of=" tmpfile " 2>/dev/null")  # copy superblock
  blkcnt = 0
  cmd = "dumpe2fs " tmpfile " 2>/dev/null | grep \"Block count\" | \
      sed \"s/[^0-9]*//\""
  cmd | getline blkcnt
  close(cmd)
  system("rm -f " tmpfile)
  if (blkcnt > 0) {
    blkcnt *= 8  # 4096 byte blocks -> 512 byte sectors
    system("dd if=\"" BF "\" bs=512 skip=" start " count=" blkcnt \
        " 2>/dev/null | openssl dgst -sha256 -binary | openssl base64")
  } else {
    print "invalid filesystem"
  }
}

'
