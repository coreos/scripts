#!/usr/bin/python2.6

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""This module is responsible for generate a stateful update payload."""

import logging
import optparse
import os
import subprocess
import tempfile

STATEFUL_FILE = 'stateful.tgz'


def GenerateStatefulPayload(image_path, output_directory, logger):
    """Generates a stateful update payload given a full path to an image.

    Args:
      image_path: Full path to the image.
      output_directory: Path to the directory to leave the resulting output.
      logger: logging instance.
    """
    logger.info('Generating stateful update file.')
    from_dir = os.path.dirname(image_path)
    image = os.path.basename(image_path)
    output_gz = os.path.join(output_directory, STATEFUL_FILE)
    crosutils_dir = os.path.dirname(__file__)

    # Temporary directories for this function.
    rootfs_dir = tempfile.mkdtemp(suffix='rootfs', prefix='tmp')
    stateful_dir = tempfile.mkdtemp(suffix='stateful', prefix='tmp')

    # Mount the image to pull out the important directories.
    try:
      # Only need stateful partition, but this saves us having to manage our
      # own loopback device.
      subprocess.check_call(['%s/mount_gpt_image.sh' % crosutils_dir,
                             '--from=%s' % from_dir,
                             '--image=%s' % image,
                             '--read_only',
                             '--rootfs_mountpt=%s' % rootfs_dir,
                             '--stateful_mountpt=%s' % stateful_dir,
                            ])
      logger.info('Tarring up /usr/local and /var!')
      subprocess.check_call(['sudo',
                             'tar',
                             '-czf',
                             output_gz,
                             '--directory=%s' % stateful_dir,
                             '--hard-dereference',
                             '--transform=s,^dev_image,dev_image_new,',
                             '--transform=s,^var,var_new,',
                             'dev_image',
                             'var',
                            ])
    except:
      logger.error('Failed to create stateful update file')
      raise
    finally:
      # Unmount best effort regardless.
      subprocess.call(['%s/mount_gpt_image.sh' % crosutils_dir,
                       '--unmount',
                       '--rootfs_mountpt=%s' % rootfs_dir,
                       '--stateful_mountpt=%s' % stateful_dir,
                      ])
      # Clean up our directories.
      os.rmdir(rootfs_dir)
      os.rmdir(stateful_dir)

    logger.info('Successfully generated %s' % output_gz)


def main():
  logging.basicConfig(level=logging.INFO)
  logger = logging.getLogger(os.path.basename(__file__))
  parser = optparse.OptionParser()
  parser.add_option('-i', '--image_path',
      help='The image to generate the stateful update for.')
  parser.add_option('-o', '--output_dir',
      help='The path to the directory to output the update file.')
  options, unused_args = parser.parse_args()
  if not options.image_path:
    parser.error('Missing image for stateful payload generator')
  if not options.output_dir:
    parser.error('Missing output directory for the payload generator')

  GenerateStatefulPayload(os.path.abspath(options.image_path),
                          options.output_dir, logger)


if __name__ == '__main__':
  main()
