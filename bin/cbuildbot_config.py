# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Dictionary of configuration types for cbuildbot.

Each dictionary entry is in turn a dictionary of config_param->value.

config_param's:
board -- The board of the image to build.
uprev -- Uprevs the local ebuilds to build new changes since last stable.
         build.  If master then also pushes these changes on success.
master -- Only one allowed to be True.  This bot controls the uprev process.
important -- Master bot uses important bots to determine overall status.
             i.e. if master bot succeeds and other important slaves succeed
             then the master will uprev packages.  This should align
             with info vs. closer except for the master.
hostname -- Needed for 'important' slaves.  The hostname of the bot.  Should
            match hostname in slaves.cfg in buildbot checkout.
unittests -- Runs unittests for packages.
smoke_bvt -- Runs the test smoke suite in a qemu-based VM using KVM.

"""


config = {}
config['default'] = {
  'board' : 'x86-generic',
  'uprev' : False,
  'master' : False,
  'important' : False,
  'unittests' : False,
  'smoke_bvt' : False,
}
config['x86-generic-pre-flight-queue'] = {
  'board' : 'x86-generic',
  'uprev' : True,
  'master' : True,
  'important' : False,
  'hostname' : 'chromeosbuild2',
  'unittests' : True,
  'smoke_bvt' : True,
}
config['x86_pineview_bin'] = {
  'board' : 'x86-pineview',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'hostname' : 'codf200.jail',
  'unittests': True,
}
config['arm_tegra2_bin'] = {
  'board' : 'tegra2',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'hostname' : 'codg172.jail',
  'unittests' : False,
}
config['arm_voguev210_bin'] = {
  'board' : 'voguev210',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'hostname' : 'codf196.jail',
  'unittests' : False,
}
config['arm_beagleboard_bin'] = {
  'board' : 'beagleboard',
  'master' : False,
  'uprev' : True,
  'important' : False,
  'hostname' : 'codf202.jail',
  'unittests' : False,
}
config['arm_st1q_bin'] = {
  'board' : 'st1q',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'hostname' : 'codg158.jail',
  'unittests' : False,
}
config['arm_generic_bin'] = {
  'board' : 'arm-generic',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'hostname' : 'codg175.jail',
  'unittests' : False,
}
