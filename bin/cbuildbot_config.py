# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Dictionary of configuration types for cbuildbot.

Each dictionary entry is in turn a dictionary of config_param->value.

config_param's:
board -- The board of the image to build.
uprev -- Uprevs the local ebuilds to build new changes since last stable.
         build.  If master then also pushes these changes on success.
master -- This bot pushes changes to the overlays.
important -- Master bot uses important bots to determine overall status.
             i.e. if master bot succeeds and other important slaves succeed
             then the master will uprev packages.  This should align
             with info vs. closer except for the master.
hostname -- Needed for 'important' slaves.  The hostname of the bot.  Should
            match hostname in slaves.cfg in buildbot checkout.
unittests -- Runs unittests for packages.
smoke_bvt -- Runs the test smoke suite in a qemu-based VM using KVM.
overlays -- Select what overlays to look at. This can be 'public', 'private'
            or 'both'. There should only be one master bot pushing changes to
            each overlay per branch.
"""


config = {}
config['default'] = {
  'board' : 'x86-generic',
  'uprev' : False,
  'master' : False,
  'important' : False,
  'unittests' : False,
  'smoke_bvt' : False,
  'overlays': 'public',
}
config['x86-generic-pre-flight-queue'] = {
  'board' : 'x86-generic',
  'uprev' : True,
  'master' : True,
  'important' : False,
  'hostname' : 'chromeosbuild2',
  'unittests' : True,
  'smoke_bvt' : True,
  'overlays': 'public',
}
config['x86-mario-pre-flight-queue'] = {
  'board' : 'x86-mario',
  'uprev' : True,
  'master' : True,
  'important' : False,
  'unittests' : True,
  'smoke_bvt' : True,
  'overlays': 'private',
}
config['x86-mario-pre-flight-branch'] = {
  'board' : 'x86-mario',
  'uprev' : True,
  'master' : True,
  'important' : False,
  'unittests' : True,
  'smoke_bvt' : True,
  'overlays': 'both',
}
config['x86_agz_bin'] = {
  'board' : 'x86-agz',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'unittests' : True,
  'smoke_bvt' : True,
  'overlays': 'private',
}
config['x86_dogfood_bin'] = {
  'board' : 'x86-dogfood',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'unittests' : True,
  'smoke_bvt' : True,
  'overlays': 'private',
}
config['x86_pineview_bin'] = {
  'board' : 'x86-pineview',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'unittests': True,
  'overlays': 'public',
}
config['arm_tegra2_bin'] = {
  'board' : 'tegra2',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'unittests' : False,
  'overlays': 'public',
}
config['arm_generic_bin'] = {
  'board' : 'arm-generic',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'unittests' : False,
  'overlays': 'public',
}
