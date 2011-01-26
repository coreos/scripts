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
tests -- Runs the smoke suite and au test harness in a qemu-based VM using KVM.
rev_overlays -- Select what overlays to look at for revving. This can be
                'public', 'private' or 'both'.
push_overlays -- Select what overlays to push at. This should be a subset of
                 rev_overlays for the particular builder.  Must be None if
                 not a master.  There should only be one master bot pushing
                 changes to each overlay per branch.
test_mod -- Create a test mod image. (default True)
factory_install_mod -- Create a factory install image. (default True)
factory_test_mod -- Create a factory test image. (default True)
"""


config = {}
config['default'] = {
  'board' : 'x86-generic',
  'uprev' : False,
  'master' : False,
  'important' : False,
  'unittests' : False,
  'tests' : False,
  'rev_overlays': 'public',
  'push_overlays': None,
}
config['x86-generic-pre-flight-queue'] = {
  'board' : 'x86-generic',
  'uprev' : True,
  'master' : True,
  'important' : False,
  'hostname' : 'chromeosbuild2',
  'unittests' : True,
  'tests' : True,
  'rev_overlays': 'public',
  'push_overlays': 'public',
}
config['x86-mario-pre-flight-queue'] = {
  'board' : 'x86-mario',
  'uprev' : True,
  'master' : True,
  'important' : False,
  'unittests' : True,
  'tests' : True,
  'rev_overlays': 'both',
  'push_overlays': 'private',
}
config['x86-mario-pre-flight-branch'] = {
  'board' : 'x86-mario',
  'uprev' : True,
  'master' : True,
  'important' : False,
  'unittests' : True,
  'tests' : True,
  'rev_overlays': 'both',
  'push_overlays': 'both',
}
config['x86_agz_bin'] = {
  'board' : 'x86-agz',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'unittests' : True,
  'tests' : True,
  'rev_overlays': 'both',
  'push_overlays': None,
}
config['x86_dogfood_bin'] = {
  'board' : 'x86-dogfood',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'unittests' : True,
  'tests' : True,
  'rev_overlays': 'both',
  'push_overlays': None,
}
config['x86_pineview_bin'] = {
  'board' : 'x86-pineview',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'unittests': True,
  'rev_overlays': 'public',
  'push_overlays': None,
}
config['arm_tegra2_bin'] = {
  'board' : 'tegra2_dev-board',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'unittests' : False,
  'rev_overlays': 'public',
  'push_overlays': None,
  'factory_install_mod' : False,
  'factory_test_mod' : False,
}
config['arm_generic_bin'] = {
  'board' : 'arm-generic',
  'uprev' : True,
  'master' : False,
  'important' : False,
  'unittests' : False,
  'rev_overlays': 'public',
  'push_overlays': None,
  'factory_install_mod' : False,
  'factory_test_mod' : False,
}
