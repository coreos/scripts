#!/usr/bin/python
#
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Wrapper for tests that are run on builders."""

import fileinput
import optparse
import os
import sys
import traceback
import urllib

sys.path.append(os.path.join(os.path.dirname(__file__), '../lib'))
from cros_build_lib import Info, RunCommand, ReinterpretPathForChroot

_IMAGE_TO_EXTRACT = 'chromiumos_test_image.bin'


def ModifyBootDesc(download_folder, redirect_file=None):
  """Modifies the boot description of a downloaded image to work with path.

  The default boot.desc from another system is specific to the directory
  it was created in.  This modifies the boot description to be compatiable
  with the download folder.

  Args:
    download_folder: Absoulte path to the download folder.
    redirect_file:  For testing.  Where to copy new boot desc.
  """
  boot_desc_path = os.path.join(download_folder, 'boot.desc')
  in_chroot_folder = ReinterpretPathForChroot(download_folder)

  for line in fileinput.input(boot_desc_path, inplace=1):
    # Has to be done here to get changes to sys.stdout from fileinput.input.
    if not redirect_file:
      redirect_file = sys.stdout
    split_line = line.split('=')
    if len(split_line) > 1:
      var_part = split_line[0]
      potential_path = split_line[1].replace('"', '').strip()

      if potential_path.startswith('/home') and not 'output_dir' in var_part:
        new_path = os.path.join(in_chroot_folder,
                                os.path.basename(potential_path))
        new_line = '%s="%s"' % (var_part, new_path)
        Info('Replacing line %s with %s' % (line, new_line))
        redirect_file.write('%s\n' % new_line)
        continue
      elif 'output_dir' in var_part:
        # Special case for output_dir.
        new_line = '%s="%s"' % (var_part, in_chroot_folder)
        Info('Replacing line %s with %s' % (line, new_line))
        redirect_file.write('%s\n' % new_line)
        continue

    # Line does not need to be modified.
    redirect_file.write(line)

  fileinput.close()


def GetLatestZipUrl(board, channel, latest_url_base, zip_server_base):
  """Returns the url of the latest image zip for the given arguments.

  Args:
    board: board for the image zip.
    channel: channel for the image zip.
    latest_url_base: base url for latest links.
    zip_server_base:  base url for zipped images.
  """
  # Grab the latest image info.
  latest_file_url = os.path.join(latest_url_base, channel,
                                 'LATEST-%s' % board)
  latest_image_file = urllib.urlopen(latest_file_url)
  latest_image = latest_image_file.read()
  latest_image_file.close()

  # Convert bin.gz into zip.
  latest_image = latest_image.replace('.bin.gz', '.zip')
  version = latest_image.split('-')[1]
  zip_base = os.path.join(zip_server_base, channel, board)
  return os.path.join(zip_base, version, latest_image)


def GrabZipAndExtractImage(zip_url, download_folder, image_name) :
  """Downloads the zip and extracts the given image.

  Doesn't re-download if matching version found already in download folder.
  Args:
    zip_url - url for the image.
    download_folder - download folder to store zip file and extracted images.
    image_name - name of the image to extract from the zip file.
  """
  zip_path = os.path.join(download_folder, 'image.zip')
  versioned_url_path = os.path.join(download_folder, 'download_url')
  found_cached = False

  if os.path.exists(versioned_url_path):
    fh = open(versioned_url_path)
    version_url = fh.read()
    fh.close()

    if version_url == zip_url and os.path.exists(os.path.join(download_folder,
                                                 image_name)):
      Info('Using cached %s' % image_name)
      found_cached = True

  if not found_cached:
    Info('Downloading %s' % zip_url)
    RunCommand(['rm', '-rf', download_folder], print_cmd=False)
    os.mkdir(download_folder)
    urllib.urlretrieve(zip_url, zip_path)

    # Using unzip because python implemented unzip in native python so
    # extraction is really slow.
    Info('Unzipping image %s' % image_name)
    RunCommand(['unzip', '-d', download_folder, zip_path],
               print_cmd=False, error_message='Failed to download %s' % zip_url)

    ModifyBootDesc(download_folder)

    # Put url in version file so we don't have to do this every time.
    fh = open(versioned_url_path, 'w+')
    fh.write(zip_url)
    fh.close()


def RunAUTestHarness(board, channel, latest_url_base, zip_server_base,
                     no_graphics, type, remote):
  """Runs the auto update test harness.

  The auto update test harness encapsulates testing the auto-update mechanism
  for the latest image against the latest official image from the channel.  This
  also tests images with suite_Smoke (built-in as part of its verification
  process).

  Args:
    board: the board for the latest image.
    channel: the channel to run the au test harness against.
    latest_url_base: base url for getting latest links.
    zip_server_base:  base url for zipped images.
    no_graphics: boolean - If True, disable graphics during vm test.
    type: which test harness to run.  Possible values: real, vm.
    remote: ip address for real test harness run.
  """
  crosutils_root = os.path.join(os.path.dirname(__file__), '..')
  download_folder = os.path.abspath('latest_download')
  zip_url = GetLatestZipUrl(board, channel, latest_url_base, zip_server_base)
  GrabZipAndExtractImage(zip_url, download_folder, _IMAGE_TO_EXTRACT)

  no_graphics_flag = ''
  if no_graphics: no_graphics_flag = '--no_graphics'

  # Tests go here.
  latest_image = RunCommand(['./get_latest_image.sh', '--board=%s' % board],
                            cwd=crosutils_root, redirect_stdout=True,
                            print_cmd=True).strip()

  RunCommand(['bin/cros_au_test_harness',
              '--base_image=%s' % os.path.join(download_folder,
                                                 _IMAGE_TO_EXTRACT),
              '--target_image=%s' % os.path.join(latest_image,
                                                 _IMAGE_TO_EXTRACT),
              no_graphics_flag,
              '--board=%s' % board,
              '--type=%s' % type,
              '--remote=%s' % remote,
             ], cwd=crosutils_root)


def main():
  parser = optparse.OptionParser()
  parser.add_option('-b', '--board',
                    help='board for the image to compare against.')
  parser.add_option('-c', '--channel',
                    help='channel for the image to compare against.')
  parser.add_option('-l', '--latestbase',
                    help='Base url for latest links.')
  parser.add_option('-z', '--zipbase',
                    help='Base url for hosted images.')
  parser.add_option('--no_graphics', action='store_true', default=False,
                    help='Disable graphics for the vm test.')
  parser.add_option('--type', default='vm',
                    help='type of test to run: [vm, real]. Default: vm.')
  parser.add_option('--remote', default='0.0.0.0',
                    help='For real tests, ip address of the target machine.')

  # Set the usage to include flags.
  parser.set_usage(parser.format_help())
  (options, args) = parser.parse_args()

  if args:
    parser.error('Extra args found %s.' % args)

  if not options.board:
    parser.error('Need board for image to compare against.')

  if not options.channel:
    parser.error('Need channel for image to compare against.')

  if not options.latestbase:
    parser.error('Need latest url base to get images.')

  if not options.zipbase:
    parser.error('Need zip url base to get images.')

  RunAUTestHarness(options.board, options.channel, options.latestbase,
                   options.zipbase, options.no_graphics, options.type,
                   options.remote)


if __name__ == '__main__':
  try:
    main()
  except Exception:
    print "Got exception."
    traceback.print_exc(file=sys.stdout)

