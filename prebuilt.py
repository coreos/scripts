#!/usr/bin/python
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

import datetime
import optparse
import os
import sys
from multiprocessing import Pool

from chromite.lib import cros_build_lib
"""
This script is used to upload host prebuilts as well as board BINHOSTS to
Google Storage.

After a build is successfully uploaded a file is updated with the proper
BINHOST version as well as the target board. This file is defined in GIT_FILE


To read more about prebuilts/binhost binary packages please refer to:
http://sites/chromeos/for-team-members/engineering/releng/prebuilt-binaries-for-streamlining-the-build-process


Example of uploading prebuilt amd64 host files
./prebuilt.py -p /b/cbuild/build -s -u gs://chromeos-prebuilt

Example of uploading x86-dogfood binhosts
./prebuilt.py -b x86-dogfood -p /b/cbuild/build/ -u gs://chromeos-prebuilt  -g
"""

VER_FILE = 'src/third_party/chromiumos-overlay/chromeos/config/stable_versions'

# as per http://crosbug.com/5855 always filter the below packages
FILTER_PACKAGES = set()
_RETRIES = 3
_HOST_PACKAGES_PATH = 'chroot/var/lib/portage/pkgs'
_HOST_TARGET = 'amd64'
_BOARD_PATH = 'chroot/build/%(board)s'
_BOTO_CONFIG = '/home/chrome-bot/external-boto'
# board/board-target/version'
_GS_BOARD_PATH = 'board/%(board)s/%(version)s/'
# We only support amd64 right now
_GS_HOST_PATH = 'host/%s' % _HOST_TARGET

def UpdateLocalFile(filename, key, value):
  """Update the key in file with the value passed.
  File format:
    key value

  Args:
    filename: Name of file to modify.
    key: The variable key to update.
    value: Value to write with the key.
  """
  file_fh = open(filename)
  file_lines = []
  found = False
  for line in file_fh:
    file_var, file_val = line.split()
    if file_var == key:
      found = True
      print 'Updating %s %s to %s %s' % (file_var, file_val, key, value)
      file_lines.append('%s %s' % (key, value))
    else:
      file_lines.append('%s %s' % (file_var, file_val))

  if not found:
    file_lines.append('%s %s' % (key, value))

  file_fh.close()
  # write out new file
  new_file_fh = open(filename, 'w')
  new_file_fh.write('\n'.join(file_lines))
  new_file_fh.close()


def RevGitFile(filename, key, value):
  """Update and push the git file.

  Args:
    filename: file to modify that is in a git repo already
    key: board or host package type e.g. x86-dogfood
    value: string representing the version of the prebuilt that has been
      uploaded.
  """
  prebuilt_branch = 'prebuilt_branch'
  old_cwd = os.getcwd()
  os.chdir(os.path.dirname(filename))
  cros_build_lib.RunCommand('repo start %s  .' % prebuilt_branch, shell=True)
  UpdateLocalFile(filename, key, value)
  description = 'Update BINHOST key/value %s %s' % (key, value)
  print description
  git_ssh_config_cmd = (
    'git config url.ssh://git@gitrw.chromium.org:9222.pushinsteadof '
    'http://git.chromium.org/git')
  try:
    cros_build_lib.RunCommand(git_ssh_config_cmd, shell=True)
    cros_build_lib.RunCommand('git pull', shell=True)
    cros_build_lib.RunCommand('git config push.default tracking', shell=True)
    cros_build_lib.RunCommand('git commit -am "%s"' % description, shell=True)
    cros_build_lib.RunCommand('git push', shell=True)
  finally:
    cros_build_lib.RunCommand('repo abandon %s .' % prebuilt_branch, shell=True)
    os.chdir(old_cwd)


def GetVersion():
  """Get the version to put in LATEST and update the git version with."""
  return datetime.datetime.now().strftime('%d.%m.%y.%H%M%S')


def LoadFilterFile(filter_file):
  """Load a file with keywords on a per line basis.

  Args:
    filter_file: file to load into FILTER_PACKAGES
  """
  filter_fh = open(filter_file)
  try:
    FILTER_PACKAGES.update([filter.strip() for filter in filter_fh])
  finally:
    filter_fh.close()
  return FILTER_PACKAGES


def ShouldFilterPackage(file_path):
  """Skip a particular file if it matches a pattern.

  Skip any files that machine the list of packages to filter in FILTER_PACKAGES.

  Args:
    file_path: string of a file path to inspect against FILTER_PACKAGES

  Returns:
    True if we should filter the package,
    False otherwise.
  """
  for name in FILTER_PACKAGES:
    if name in file_path:
      print 'FILTERING %s' % file_path
      return True

  return False


def _GsUpload(args):
  """Upload to GS bucket.

  Args:
    args: a tuple of two arguments that contains local_file and remote_file.
  """
  (local_file, remote_file) = args
  if ShouldFilterPackage(local_file):
    return

  cmd = 'gsutil cp -a public-read %s %s' % (local_file, remote_file)
  # TODO(scottz): port to use _Run or similar when it is available in
  # cros_build_lib.
  for attempt in range(_RETRIES):
    try:
      output = cros_build_lib.RunCommand(cmd, print_cmd=False, shell=True)
      break
    except cros_build_lib.RunCommandError:
      print 'Failed to sync %s -> %s, retrying' % (local_file, remote_file)
  else:
    # TODO(scottz): potentially return what failed so we can do something with
    # with it but for now just print an error.
    print 'Retry failed uploading %s -> %s, giving up' % (local_file,
                                                          remote_file)


def RemoteUpload(files, pool=10):
  """Upload to google storage.

  Create a pool of process and call _GsUpload with the proper arguments.

  Args:
    files: dictionary with keys to local files and values to remote path.
    pool: integer of maximum proesses to have at the same time.
  """
  # TODO(scottz) port this to use _RunManyParallel when it is available in
  # cros_build_lib
  pool = Pool(processes=pool)
  workers = []
  for local_file, remote_path in files.iteritems():
    workers.append((local_file, remote_path))

  result = pool.map_async(_GsUpload, workers, chunksize=1)
  while True:
    try:
      result.get(60*60)
      break
    except multiprocessing.TimeoutError:
      pass


def GenerateUploadDict(local_path, gs_path, strip_str):
  """Build a dictionary of local remote file key pairs for gsutil to upload.

  Args:
    local_path: A path to the file on the local hard drive.
    gs_path: Path to upload in Google Storage.
    strip_str: String to remove from the local_path so that the relative
      file path can be tacked on to the gs_path.

  Returns:
    Returns a dictionary of file path/gs_dest_path pairs
  """
  files_to_sync = cros_build_lib.ListFiles(local_path)
  upload_files = {}
  for file_path in files_to_sync:
    filename = file_path.replace(strip_str, '').lstrip('/')
    gs_file_path = os.path.join(gs_path, filename)
    upload_files[file_path] = gs_file_path

  return upload_files


def UploadPrebuilt(build_path, bucket, board=None, git_file=None):
  """Upload Host prebuilt files to Google Storage space.

  Args:
    build_path: The path to the root of the chroot.
    bucket: The Google Storage bucket to upload to.
    board: The board to upload to Google Storage, if this is None upload
      host packages.
    git_file: If set, update this file with a host/version combo, commit and
      push it.
  """
  version = GetVersion()

  if not board:
    # We are uploading host packages
    # TODO: eventually add support for different host_targets
    package_path = os.path.join(build_path, _HOST_PACKAGES_PATH)
    gs_path = os.path.join(bucket, _GS_HOST_PATH, version)
    strip_pattern = package_path
    package_string = _HOST_TARGET
  else:
    board_path = os.path.join(build_path, _BOARD_PATH % {'board': board})
    package_path = os.path.join(board_path, 'packages')
    package_string = board
    strip_pattern = board_path
    gs_path = os.path.join(bucket, _GS_BOARD_PATH % {'board': board,
                                                     'version': version})

  upload_files = GenerateUploadDict(package_path, gs_path, strip_pattern)

  print 'Uploading %s' % package_string
  RemoteUpload(upload_files)

  if git_file:
    RevGitFile(git_file, package_string, version)


def usage(parser, msg):
  """Display usage message and parser help then exit with 1."""
  print msg
  parser.print_help()
  sys.exit(1)


def main():
  parser = optparse.OptionParser()
  parser.add_option('-b', '--board', dest='board', default=None,
                    help='Board type that was built on this machine')
  parser.add_option('-p', '--build-path', dest='build_path',
                    help='Path to the chroot')
  parser.add_option('-s', '--sync-host', dest='sync_host',
                    default=False, action='store_true',
                    help='Sync host prebuilts')
  parser.add_option('-g', '--git-sync', dest='git_sync',
                    default=False, action='store_true',
                    help='Enable git version sync (This commits to a repo)')
  parser.add_option('-u', '--upload', dest='upload',
                    default=None,
                    help='Upload to GS bucket')
  parser.add_option('-f', '--filter', dest='filter_file',
                    default=None,
                    help='File to use for filtering GS bucket uploads')

  options, args = parser.parse_args()
  # Setup boto environment for gsutil to use
  os.environ['BOTO_CONFIG'] = _BOTO_CONFIG
  if not options.build_path:
    usage(parser, 'Error: you need provide a chroot path')

  if not options.upload:
    usage(parser, 'Error: you need to provide a gsutil upload bucket -u')

  if options.filter_file:
    LoadFilterFile(options.filter_file)

  git_file = None
  if options.git_sync:
    git_file = os.path.join(options.build_path, VER_FILE)

  if options.sync_host:
    UploadPrebuilt(options.build_path, options.upload, git_file=git_file)

  if options.board:
    UploadPrebuilt(options.build_path, options.upload, board=options.board,
                   git_file=git_file)


if __name__ == '__main__':
  main()
