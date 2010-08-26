# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Dictionary values that aren't self-explanatory:
# 'master' - only one allowed to be True.  This bot controls the uprev process.
# 'important' - master bot uses important bots to determine overall status.
#               i.e. if master bot succeeds and other important slaves succeed
#               then the master will uprev packages.  This should align
#               with info vs. closer except for the master.
# 'hostname' - Needed for 'important' slaves.  The hostname of the bot.  Should
#              match hostname in slaves.cfg in buildbot checkout.

config = {}
config['default'] = {
  'board' : 'x86-generic',
  'uprev' : False,
  'master' : False,
  'important' : False,
}
config['x86-generic-pre-flight-queue'] = {
  'board' : 'x86-generic',
  'uprev' : True,
  'master' : True,
  'important' : False,
}
