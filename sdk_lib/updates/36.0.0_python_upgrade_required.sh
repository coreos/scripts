#!/bin/bash

# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

cat >&2 <<EOF

Your SDK chroot is too old! (or the version wasn't detected properly)
As of v36 CoreOS has switched from python2.6 to 2.7 but the easiest way
to upgrade is to recreate the chroot. On the host system please run:

 repo sync
 ./chromite/bin/cros_sdk --replace

Note: This will delete your existing chroot (but not your source tree)
so if you have anything kicking around in there like fancy dot files in
chroot/home/$USER be sure to copy them elsewhere first!

EOF
exit 1
