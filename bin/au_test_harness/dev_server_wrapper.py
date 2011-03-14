# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Module containing methods and classes to interact with a devserver instance.
"""

import os
import threading

import cros_build_lib as cros_lib

def GenerateUpdateId(target, src, key):
  """Returns a simple representation id of target and src paths."""
  update_id = target
  if src: update_id = '->'.join([update_id, src])
  if key: update_id = '+'.join([update_id, key])
  return update_id

class DevServerWrapper(threading.Thread):
  """A Simple wrapper around a dev server instance."""

  def __init__(self, test_root):
    self.proc = None
    self.test_root = test_root
    threading.Thread.__init__(self)

  def run(self):
    # Kill previous running instance of devserver if it exists.
    cros_lib.RunCommand(['sudo', 'pkill', '-f', 'devserver.py'], error_ok=True,
                        print_cmd=False)
    cros_lib.RunCommand(['sudo',
                         'start_devserver',
                         '--archive_dir=./static',
                         '--client_prefix=ChromeOSUpdateEngine',
                         '--production',
                         ], enter_chroot=True, print_cmd=False,
                         log_to_file=os.path.join(self.test_root,
                                                  'dev_server.log'))

  def Stop(self):
    """Kills the devserver instance."""
    cros_lib.RunCommand(['sudo', 'pkill', '-f', 'devserver.py'], error_ok=True,
                        print_cmd=False)

  @classmethod
  def GetDevServerURL(cls, port, sub_dir):
    """Returns the dev server url for a given port and sub directory."""
    ip_addr = cros_lib.GetIPAddress()
    if not port: port = 8080
    url = 'http://%(ip)s:%(port)s/%(dir)s' % {'ip': ip_addr,
                                              'port': str(port),
                                              'dir': sub_dir}
    return url
