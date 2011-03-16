# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""This module manages interactions between an image and a public key."""

import os
import tempfile

import cros_build_lib as cros_lib

class PublicKeyManager(object):
  """Class wrapping interactions with a public key on an image."""
  TARGET_KEY_PATH = 'usr/share/update_engine/update-payload-key.pub.pem'

  def __init__(self, image_path, key_path):
    """Initializes a manager with image_path and key_path we plan to insert."""
    self.image_path = image_path
    self.key_path = key_path
    self._rootfs_dir = tempfile.mkdtemp(suffix='rootfs', prefix='tmp')
    self._stateful_dir = tempfile.mkdtemp(suffix='stateful', prefix='tmp')

    # Gather some extra information about the image.
    try:
      cros_lib.MountImage(image_path, self._rootfs_dir, self._stateful_dir,
                          read_only=True)
      self._full_target_key_path = os.path.join(
          self._rootfs_dir, PublicKeyManager.TARGET_KEY_PATH)
      self._is_key_new = True
      if os.path.exists(self._full_target_key_path):
        diff_output = cros_lib.RunCommand(['diff',
                                           self.key_path,
                                           self._full_target_key_path],
                                          print_cmd=False, redirect_stdout=True,
                                          redirect_stderr=True, error_ok=True)

        if not diff_output: self._is_key_new = False

    finally:
      cros_lib.UnmountImage(self._rootfs_dir, self._stateful_dir)

  def __del__(self):
    """Remove our temporary directories we created in init."""
    os.rmdir(self._rootfs_dir)
    os.rmdir(self._stateful_dir)

  def AddKeyToImage(self):
    """Adds the key specified in init to the image."""
    if not self._is_key_new:
      cros_lib.Info('Public key already on image %s.  No work to do.' %
                    self.image_path)
      return

    cros_lib.Info('Copying %s into %s' % (self.key_path, self.image_path))
    try:
      cros_lib.MountImage(self.image_path, self._rootfs_dir, self._stateful_dir,
                          read_only=False)

      dir_path = os.path.dirname(self._full_target_key_path)
      cros_lib.RunCommand(['sudo', 'mkdir', '--parents', dir_path],
                          print_cmd=False)
      cros_lib.RunCommand(['sudo', 'cp', '--force', '-p', self.key_path,
                           self._full_target_key_path], print_cmd=False)
    finally:
      cros_lib.UnmountImage(self._rootfs_dir, self._stateful_dir)
      self._MakeImageBootable()

  def RemoveKeyFromImage(self):
    """Removes the key specified in init from the image."""
    cros_lib.Info('Removing public key from image %s.' % self.image_path)
    try:
      cros_lib.MountImage(self.image_path, self._rootfs_dir, self._stateful_dir,
                          read_only=False)
      cros_lib.RunCommand(['sudo', 'rm', '--force', self._full_target_key_path],
                          print_cmd=False)
    finally:
      cros_lib.UnmountImage(self._rootfs_dir, self._stateful_dir)
      self._MakeImageBootable()

  def _MakeImageBootable(self):
    """Makes the image bootable.  Note, it is only useful for non-vm images."""
    image = os.path.basename(self.image_path)
    if 'qemu' in image:
      return

    from_dir = os.path.dirname(self.image_path)
    cros_lib.RunCommand(['bin/cros_make_image_bootable',
                         cros_lib.ReinterpretPathForChroot(from_dir),
                         image], print_cmd=False, redirect_stdout=True,
                        redirect_stderr=True, enter_chroot=True,
                        cwd=cros_lib.CROSUTILS_DIRECTORY)
