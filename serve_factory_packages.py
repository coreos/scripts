#!/usr/bin/python
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""
This script runs inside chroot environment. It signs and build factory packages.
Then serves them using devserver. All paths should be specified relative to the
chroot environment.

E.g.: ./enter_chroot.sh -- serve_factory_packages.py --board <board>

Always precede the call to the script with './enter_chroot.sh -- ".
"""

import gflags
import os
import shlex
import signal
import subprocess
import sys


CWD = os.getcwd()
USER = os.environ['USER']
HOME_DIR = '/home/%s/trunk/src' % USER
SCRIPTS_DIR = HOME_DIR + '/scripts'
DEVSERVER_DIR = HOME_DIR + '/platform/dev'

# Paths to image signing directory and dev key.
VBOOT_REF_DIR = HOME_DIR + '/platform/vboot_reference'
IMG_SIGN_DIR = VBOOT_REF_DIR + '/scripts/image_signing'
DEVKEYS = VBOOT_REF_DIR + '/tests/devkeys'

FLAGS = gflags.FLAGS

gflags.DEFINE_string('board', None, 'Platform to build.')
gflags.DEFINE_string('base_image', None, 'Path to base image.')
gflags.DEFINE_string('firmware_updater', None, 'Path to firmware updater.')


class KillableProcess():
  """A killable process.
  """

  running_process = None

  def __init__(self, cmd, timeout=60, cwd=CWD):
    """Initialize process

    Args:
      cmd: command to run.
    """
    self.cmd = shlex.split(cmd)
    self.cmd_timeout = timeout
    self.cmd_cwd = cwd

  def start(self, wait=True):
    """Start the process.

    Args:
      wait: wait for command to complete.
    """
    self.running_process = subprocess.Popen(self.cmd,
                                            cwd=self.cmd_cwd)
    if wait:
      self.running_process.wait()

  def stop(self):
    """Stop the process.

       This will only work for commands that do not exit.
    """
    self.running_process.send_signal(signal.SIGINT)
    self.running_process.wait()


def start_devserver():
  """Starts devserver."""
  cmd = 'python devserver.py'
  print 'Running command: %s' % cmd
  devserver_process = KillableProcess(cmd, cwd=DEVSERVER_DIR)
  devserver_process.start(wait=False)


def assert_is_file(path, message):
  """Assert file exists.

  Args:
    path: path to file.
    message: message to print if file does not exist.
  """
  if not os.path.isfile(path):
    error_message = '%s: %s is not a file!' % (message, path)
    print error_message
    sys.exit(1)


def setup_board(board):
  """Setup the board inside chroot.
  """
  cmd = './setup_board --board %s' % board
  print 'Setting up board: %s' % board
  setup_board_process = KillableProcess(cmd, cwd=SCRIPTS_DIR)
  setup_board_process.start()


def sign_build(image, output):
  """Make an SSD signed build.

  Args:
    image: image to sign.
    output: destination path for signed image.
  """
  assert_is_file(image, 'Asserting base image exists')
  cmd = ('sudo ./sign_official_build.sh ssd %s %s %s'
         % (image, DEVKEYS, output))
  print 'IMG_SIGN_DIR: %s' % IMG_SIGN_DIR
  print 'Signing image: %s' % cmd
  sign_process = KillableProcess(cmd, cwd=IMG_SIGN_DIR)
  sign_process.start()


def build_factory_packages(signed_image, base_image, fw_updater, folder, board):
  """Build image and modify mini omaha config.
  """
  cmd = ('./make_factory_package.sh --release %s --factory %s'
         ' --firmware_updater %s --subfolder %s --board %s'
         % (signed_image, base_image, fw_updater, folder, board))
  print 'Building factory packages: %s' % cmd
  build_packages_process = KillableProcess(cmd, cwd=SCRIPTS_DIR)
  build_packages_process.start()


def exit(message):
  print message
  sys.exit(1)


def main(argv):
  try:
    argv = FLAGS(argv)
  except gflags.FlagsError, e:
    print '%s\nUsage: %s ARGS\n%s' % (e, sys.argv[0], FLAGS)
    sys.exit(1)

  if not FLAGS.base_image:
    exit('No --base_image specified.')
  if not FLAGS.firmware_updater:
    exit('No --firmware_updater specified.')

  assert_is_file(FLAGS.base_image, 'Invalid or missing base image.')
  assert_is_file(FLAGS.firmware_updater, 'Invalid or missing firmware updater.')

  signed_image = os.path.join(os.path.dirname(FLAGS.base_image),
                              '%s_ssd_signed.bin' % FLAGS.board)

  setup_board(FLAGS.board)
  sign_build(FLAGS.base_image, signed_image)
  build_factory_packages(signed_image, FLAGS.base_image,
                         FLAGS.firmware_updater,
                         folder=FLAGS.board, board=FLAGS.board)

  start_devserver()


if __name__ == '__main__':
  main(sys.argv)
