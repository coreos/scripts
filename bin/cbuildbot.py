#!/usr/bin/python

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""CBuildbot is wrapper around the build process used by the pre-flight queue"""

import errno
import heapq
import re
import optparse
import os
import shutil
import sys

import cbuildbot_comm
from cbuildbot_config import config

sys.path.append(os.path.join(os.path.dirname(__file__), '../lib'))
from cros_build_lib import (Die, Info, ReinterpretPathForChroot, RunCommand,
                            Warning)

_DEFAULT_RETRIES = 3
_PACKAGE_FILE = '%(buildroot)s/src/scripts/cbuildbot_package.list'
ARCHIVE_BASE = '/var/www/archive'
ARCHIVE_COUNT = 10

# ======================== Utility functions ================================

def MakeDir(path, parents=False):
  """Basic wrapper around os.mkdirs.

  Keyword arguments:
  path -- Path to create.
  parents -- Follow mkdir -p logic.

  """
  try:
    os.makedirs(path)
  except OSError, e:
    if e.errno == errno.EEXIST and parents:
      pass
    else:
      raise


def RepoSync(buildroot, rw_checkout=False, retries=_DEFAULT_RETRIES):
  """Uses repo to checkout the source code.

  Keyword arguments:
  rw_checkout -- Reconfigure repo after sync'ing to read-write.
  retries -- Number of retries to try before failing on the sync.

  """
  while retries > 0:
    try:
      # The --trace option ensures that repo shows the output from git. This
      # is needed so that the buildbot can kill us if git is not making
      # progress.
      RunCommand(['repo', '--trace', 'sync'], cwd=buildroot)
      retries = 0
    except:
      retries -= 1
      if retries > 0:
        Warning('CBUILDBOT -- Repo Sync Failed, retrying')
      else:
        Warning('CBUILDBOT -- Retries exhausted')
        raise

  # Output manifest
  RunCommand(['repo', 'manifest', '-r', '-o', '-'], cwd=buildroot)

# =========================== Command Helpers =================================

def _GetAllGitRepos(buildroot, debug=False):
  """Returns a list of tuples containing [git_repo, src_path]."""
  manifest_tuples = []
  # Gets all the git repos from a full repo manifest.
  repo_cmd = "repo manifest -o -".split()
  output = RunCommand(repo_cmd, cwd=buildroot, redirect_stdout=True,
                      redirect_stderr=True, print_cmd=debug)

  # Extract all lines containg a project.
  extract_cmd = ['grep', 'project name=']
  output = RunCommand(extract_cmd, cwd=buildroot, input=output,
                      redirect_stdout=True, print_cmd=debug)
  # Parse line using re to get tuple.
  result_array = re.findall('.+name=\"([\w-]+)\".+path=\"(\S+)".+', output)

  # Create the array.
  for result in result_array:
    if len(result) != 2:
      Warning('Found incorrect xml object %s' % result)
    else:
      # Remove pre-pended src directory from manifest.
      manifest_tuples.append([result[0], result[1].replace('src/', '')])

  return manifest_tuples


def _GetCrosWorkOnSrcPath(buildroot, board, package, debug=False):
  """Returns ${CROS_WORKON_SRC_PATH} for given package."""
  cwd = os.path.join(buildroot, 'src', 'scripts')
  equery_cmd = ('equery-%s which %s' % (board, package)).split()
  ebuild_path = RunCommand(equery_cmd, cwd=cwd, redirect_stdout=True,
                             redirect_stderr=True, enter_chroot=True,
                             error_ok=True, print_cmd=debug)
  if ebuild_path:
    ebuild_cmd = ('ebuild-%s %s info' % (board, ebuild_path)).split()
    cros_workon_output = RunCommand(ebuild_cmd, cwd=cwd,
                                    redirect_stdout=True, redirect_stderr=True,
                                    enter_chroot=True, print_cmd=debug)

    temp = re.findall('CROS_WORKON_SRCDIR="(\S+)"', cros_workon_output)
    if temp:
      return temp[0]

  return None


def _CreateRepoDictionary(buildroot, board, debug=False):
  """Returns the repo->list_of_ebuilds dictionary."""
  repo_dictionary = {}
  manifest_tuples = _GetAllGitRepos(buildroot)
  Info('Creating dictionary of git repos to portage packages ...')

  cwd = os.path.join(buildroot, 'src', 'scripts')
  get_all_workon_pkgs_cmd = './cros_workon list --all'.split()
  packages = RunCommand(get_all_workon_pkgs_cmd, cwd=cwd,
                        redirect_stdout=True, redirect_stderr=True,
                        enter_chroot=True, print_cmd=debug)
  for package in packages.split():
    cros_workon_src_path = _GetCrosWorkOnSrcPath(buildroot, board, package)
    if cros_workon_src_path:
      for tuple in manifest_tuples:
        # This path tends to have the user's home_dir prepended to it.
        if cros_workon_src_path.endswith(tuple[1]):
          Info('For %s found matching package %s' % (tuple[0], package))
          if repo_dictionary.has_key(tuple[0]):
            repo_dictionary[tuple[0]] += [package]
          else:
            repo_dictionary[tuple[0]] = [package]

  return repo_dictionary


def _ParseRevisionString(revision_string, repo_dictionary):
  """Parses the given revision_string into a revision dictionary.

  Returns a list of tuples that contain [portage_package_name, commit_id] to
  update.

  Keyword arguments:
  revision_string -- revision_string with format
      'repo1.git@commit_1 repo2.git@commit2 ...'.
  repo_dictionary -- dictionary with git repository names as keys (w/out git)
      to portage package names.

  """
  # Using a dictionary removes duplicates.
  revisions = {}
  for revision in revision_string.split():
    # Format 'package@commit-id'.
    revision_tuple = revision.split('@')
    if len(revision_tuple) != 2:
      Warning('Incorrectly formatted revision %s' % revision)

    repo_name = revision_tuple[0].replace('.git', '')
    # Might not have entry if no matching ebuild.
    if repo_dictionary.has_key(repo_name):
      # May be many corresponding packages to a given git repo e.g. kernel).
      for package in repo_dictionary[repo_name]:
        revisions[package] = revision_tuple[1]

  return revisions.items()


def _UprevFromRevisionList(buildroot, tracking_branch, revision_list, board,
                           overlays):
  """Uprevs based on revision list."""
  if not revision_list:
    Info('No packages found to uprev')
    return

  packages = []
  for package, revision in revision_list:
    assert ':' not in package, 'Invalid package name: %s' % package
    packages.append(package)

  chroot_overlays = [ReinterpretPathForChroot(path) for path in overlays]

  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['./cros_mark_as_stable',
              '--board=%s' % board,
              '--tracking_branch=%s' % tracking_branch,
              '--overlays=%s' % ':'.join(chroot_overlays),
              '--packages=%s' % ':'.join(packages),
              '--drop_file=%s' % ReinterpretPathForChroot(_PACKAGE_FILE %
                  {'buildroot': buildroot}),
              'commit'],
             cwd=cwd, enter_chroot=True)


def _UprevAllPackages(buildroot, tracking_branch, board, overlays):
  """Uprevs all packages that have been updated since last uprev."""
  cwd = os.path.join(buildroot, 'src', 'scripts')
  chroot_overlays = [ReinterpretPathForChroot(path) for path in overlays]
  RunCommand(['./cros_mark_as_stable', '--all',
              '--board=%s' % board,
              '--overlays=%s' % ':'.join(chroot_overlays),
              '--tracking_branch=%s' % tracking_branch,
              '--drop_file=%s' % ReinterpretPathForChroot(_PACKAGE_FILE %
                  {'buildroot': buildroot}),
              'commit'],
              cwd=cwd, enter_chroot=True)


def _GetVMConstants(buildroot):
  """Returns minimum (vdisk_size, statefulfs_size) recommended for VM's."""
  cwd = os.path.join(buildroot, 'src', 'scripts', 'lib')
  source_cmd = 'source %s/cros_vm_constants.sh' % cwd
  vdisk_size = RunCommand([
      '/bin/bash', '-c', '%s && echo $MIN_VDISK_SIZE_FULL' % source_cmd],
       redirect_stdout=True)
  statefulfs_size = RunCommand([
      '/bin/bash', '-c', '%s && echo $MIN_STATEFUL_FS_SIZE_FULL' % source_cmd],
       redirect_stdout=True)
  return (vdisk_size.strip(), statefulfs_size.strip())


def _GitCleanup(buildroot, board, tracking_branch, overlays):
  """Clean up git branch after previous uprev attempt."""
  cwd = os.path.join(buildroot, 'src', 'scripts')
  if os.path.exists(cwd):
    RunCommand(['./cros_mark_as_stable', '--srcroot=..',
                '--board=%s' % board,
                '--overlays=%s' % ':'.join(overlays),
                '--tracking_branch=%s' % tracking_branch, 'clean'],
               cwd=cwd, error_ok=True)


def _CleanUpMountPoints(buildroot):
  """Cleans up any stale mount points from previous runs."""
  mount_output = RunCommand(['mount'], redirect_stdout=True)
  mount_pts_in_buildroot = RunCommand(['grep', buildroot], input=mount_output,
                                      redirect_stdout=True, error_ok=True)

  for mount_pt_str in mount_pts_in_buildroot.splitlines():
    mount_pt = mount_pt_str.rpartition(' type ')[0].partition(' on ')[2]
    RunCommand(['sudo', 'umount', '-l', mount_pt], error_ok=True)


def _WipeOldOutput(buildroot):
  """Wipes out build output directories."""
  RunCommand(['rm', '-rf', 'src/build/images'], cwd=buildroot)


# =========================== Main Commands ===================================


def _PreFlightRinse(buildroot, board, tracking_branch, overlays):
  """Cleans up any leftover state from previous runs."""
  _GitCleanup(buildroot, board, tracking_branch, overlays)
  _CleanUpMountPoints(buildroot)
  RunCommand(['sudo', 'killall', 'kvm'], error_ok=True)


def _FullCheckout(buildroot, tracking_branch, rw_checkout=True,
                  retries=_DEFAULT_RETRIES,
                  url='http://git.chromium.org/git/manifest'):
  """Performs a full checkout and clobbers any previous checkouts."""
  RunCommand(['sudo', 'rm', '-rf', buildroot])
  MakeDir(buildroot, parents=True)
  branch = tracking_branch.split('/');
  RunCommand(['repo', 'init', '-u',
             url, '-b',
             '%s' % branch[-1]], cwd=buildroot, input='\n\ny\n')
  RepoSync(buildroot, rw_checkout, retries)


def _IncrementalCheckout(buildroot, rw_checkout=True,
                         retries=_DEFAULT_RETRIES):
  """Performs a checkout without clobbering previous checkout."""
  RepoSync(buildroot, rw_checkout, retries)


def _MakeChroot(buildroot):
  """Wrapper around make_chroot."""
  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['./make_chroot', '--fast'], cwd=cwd)


def _SetupBoard(buildroot, board='x86-generic'):
  """Wrapper around setup_board."""
  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['./setup_board', '--fast', '--default', '--board=%s' % board],
             cwd=cwd, enter_chroot=True)


def _Build(buildroot):
  """Wrapper around build_packages."""
  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['./build_packages'], cwd=cwd, enter_chroot=True)


def _EnableLocalAccount(buildroot):
  cwd = os.path.join(buildroot, 'src', 'scripts')
  # Set local account for test images.
  RunCommand(['./enable_localaccount.sh',
             'chronos'],
             print_cmd=False, cwd=cwd)


def _BuildImage(buildroot):
  _WipeOldOutput(buildroot)

  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['./build_image', '--replace'], cwd=cwd, enter_chroot=True)


def _BuildVMImageForTesting(buildroot):
  (vdisk_size, statefulfs_size) = _GetVMConstants(buildroot)
  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['./image_to_vm.sh',
              '--test_image',
              '--full',
              '--vdisk_size=%s' % vdisk_size,
              '--statefulfs_size=%s' % statefulfs_size,
              ], cwd=cwd, enter_chroot=True)


def _RunUnitTests(buildroot):
  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['./cros_run_unit_tests',
              '--package_file=%s' % ReinterpretPathForChroot(_PACKAGE_FILE %
                  {'buildroot': buildroot}),
             ], cwd=cwd, enter_chroot=True)


def _RunSmokeSuite(buildroot, results_dir):
  results_dir_in_chroot = os.path.join(buildroot, 'chroot',
                                       results_dir.lstrip('/'))
  if os.path.exists(results_dir_in_chroot):
    shutil.rmtree(results_dir_in_chroot)

  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['bin/cros_run_vm_test',
              '--no_graphics',
              '--test_case=suite_Smoke',
              '--results_dir_root=%s' % results_dir,
              ], cwd=cwd, error_ok=False)


def _UprevPackages(buildroot, tracking_branch, revisionfile, board, overlays):
  """Uprevs a package based on given revisionfile.

  If revisionfile is set to None or does not resolve to an actual file, this
  function will uprev all packages.

  Keyword arguments:
  revisionfile -- string specifying a file that contains a list of revisions to
      uprev.
  """
  # Purposefully set to None as it means Force Build was pressed.
  revisions = 'None'
  if (revisionfile):
    try:
      rev_file = open(revisionfile)
      revisions = rev_file.read()
      rev_file.close()
    except Exception, e:
      Warning('Error reading %s, revving all' % revisionfile)
      revisions = 'None'

  revisions = revisions.strip()

  # TODO(sosa): Un-comment once we close individual trees.
  # revisions == "None" indicates a Force Build.
  #if revisions != 'None':
  #  print >> sys.stderr, 'CBUILDBOT Revision list found %s' % revisions
  #  revision_list = _ParseRevisionString(revisions,
  #      _CreateRepoDictionary(buildroot, board))
  #  _UprevFromRevisionList(buildroot, tracking_branch, revision_list, board,
  #                         overlays)
  #else:
  Info('CBUILDBOT Revving all')
  _UprevAllPackages(buildroot, tracking_branch, board, overlays)


def _UprevPush(buildroot, tracking_branch, board, overlays):
  """Pushes uprev changes to the main line."""
  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['./cros_mark_as_stable', '--srcroot=..',
              '--board=%s' % board,
              '--overlays=%s' % ':'.join(overlays),
              '--tracking_branch=%s' % tracking_branch,
              '--push_options=--bypass-hooks -f', 'push'],
             cwd=cwd)


def _ArchiveTestResults(buildroot, board, archive_dir, test_results_dir):
  """Archives the test results into the www dir for later use.

  Takes the results from the test_results_dir and dumps them into the archive
  dir specified.  This also archives the last qemu image.

  board:  Board to find the qemu image.
  archive_dir:  Path from ARCHIVE_BASE to store image.
  test_results_dir: Path from buildroot/chroot to find test results.  This must
    a subdir of /tmp.
  """
  test_results_dir = test_results_dir.lstrip('/')
  if not os.path.exists(ARCHIVE_BASE):
    os.makedirs(ARCHIVE_BASE)
  else:
    dir_entries = os.listdir(ARCHIVE_BASE)
    if len(dir_entries) >= ARCHIVE_COUNT:
      oldest_dirs = heapq.nsmallest((len(dir_entries) - ARCHIVE_COUNT) + 1,
          [os.path.join(ARCHIVE_BASE, filename) for filename in dir_entries],
          key=lambda fn: os.stat(fn).st_mtime)
      Info('Removing archive dirs %s' % oldest_dirs)
      for oldest_dir in oldest_dirs:
        shutil.rmtree(os.path.join(ARCHIVE_BASE, oldest_dir))

  archive_target = os.path.join(ARCHIVE_BASE, str(archive_dir))
  if os.path.exists(archive_target):
    shutil.rmtree(archive_target)

  results_path = os.path.join(buildroot, 'chroot', test_results_dir)
  RunCommand(['sudo', 'chmod', '-R', '+r', results_path])
  try:
    shutil.copytree(results_path, archive_target)
  except:
    Warning('Some files could not be copied')

  image_name = 'chromiumos_qemu_image.bin'
  image_path = os.path.join(buildroot, 'src', 'build', 'images', board,
                            'latest', image_name)
  RunCommand(['gzip', '-f', '--fast', image_path])
  shutil.copyfile(image_path + '.gz', os.path.join(archive_target,
                                                   image_name + '.gz'))



def _GetConfig(config_name):
  """Gets the configuration for the build"""
  default = config['default']
  buildconfig = {}
  if not config.has_key(config_name):
    Warning('Non-existent configuration specified.')
    Warning('Please specify one of:')
    config_names = config.keys()
    config_names.sort()
    for name in config_names:
      Warning('  %s' % name)
    sys.exit(1)

  buildconfig = config[config_name]

  for key in default.iterkeys():
    if not buildconfig.has_key(key):
      buildconfig[key] = default[key]

  return buildconfig


def _ResolveOverlays(buildroot, overlays):
  """Return the list of overlays to use for a given buildbot.

  Args:
    buildroot: The root directory where the build occurs. Must be an absolute
               path.
    overlays: A string describing which overlays you want.
              'private': Just the private overlay.
              'public': Just the public overlay.
              'both': Both the public and private overlays.
  """
  public_overlay = '%s/src/third_party/chromiumos-overlay' % buildroot
  private_overlay = '%s/src/private-overlays/chromeos-overlay' % buildroot
  if overlays == 'private':
    paths = [private_overlay]
  elif overlays == 'public':
    paths = [public_overlay]
  elif overlays == 'both':
    paths = [public_overlay, private_overlay]
  else:
    Die('Incorrect overlay configuration: %s' % overlays)
  return paths


def main():
  # Parse options
  usage = "usage: %prog [options] cbuildbot_config"
  parser = optparse.OptionParser(usage=usage)
  parser.add_option('-r', '--buildroot',
                    help='root directory where build occurs', default=".")
  parser.add_option('-n', '--buildnumber',
                    help='build number', type='int', default=0)
  parser.add_option('-f', '--revisionfile',
                    help='file where new revisions are stored')
  parser.add_option('--clobber', action='store_true', dest='clobber',
                    default=False,
                    help='Clobbers an old checkout before syncing')
  parser.add_option('--debug', action='store_true', dest='debug',
                    default=False,
                    help='Override some options to run as a developer.')
  parser.add_option('-t', '--tracking-branch', dest='tracking_branch',
                    default='cros/master', help='Run the buildbot on a branch')
  parser.add_option('-u', '--url', dest='url',
                    default='ssh://git@gitrw.chromium.org:9222/manifest',
                    help='Run the buildbot on internal manifest')

  (options, args) = parser.parse_args()

  buildroot = os.path.abspath(options.buildroot)
  revisionfile = options.revisionfile
  tracking_branch = options.tracking_branch

  if len(args) >= 1:
    buildconfig = _GetConfig(args[-1])
  else:
    Warning('Missing configuration description')
    parser.print_usage()
    sys.exit(1)

  # Calculate list of overlay directories.
  overlays = _ResolveOverlays(buildroot, buildconfig['overlays'])

  try:
    _PreFlightRinse(buildroot, buildconfig['board'], tracking_branch, overlays)
    if options.clobber or not os.path.isdir(buildroot):
      _FullCheckout(buildroot, tracking_branch, url=options.url)
    else:
      _IncrementalCheckout(buildroot)

    # Check that all overlays can be found.
    for path in overlays:
      assert ':' not in path, 'Overlay must not contain colons: %s' % path
      if not os.path.isdir(path):
        Die('Missing overlay: %s' % path)

    chroot_path = os.path.join(buildroot, 'chroot')
    if not os.path.isdir(chroot_path):
      _MakeChroot(buildroot)

    boardpath = os.path.join(chroot_path, 'build', buildconfig['board'])
    if not os.path.isdir(boardpath):
      _SetupBoard(buildroot, board=buildconfig['board'])

    if buildconfig['uprev']:
      _UprevPackages(buildroot, tracking_branch, revisionfile,
                     buildconfig['board'], overlays)

    _EnableLocalAccount(buildroot)
    _Build(buildroot)
    if buildconfig['unittests']:
      _RunUnitTests(buildroot)

    _BuildImage(buildroot)

    if buildconfig['smoke_bvt']:
      _BuildVMImageForTesting(buildroot)
      test_results_dir = '/tmp/run_remote_tests.%s' % options.buildnumber
      try:
        _RunSmokeSuite(buildroot, test_results_dir)
      finally:
        _ArchiveTestResults(buildroot, buildconfig['board'],
                            archive_dir=options.buildnumber,
                            test_results_dir=test_results_dir)

    if buildconfig['uprev']:
      # Don't push changes for developers.
      if not options.debug:
        if buildconfig['master']:
          # Master bot needs to check if the other slaves completed.
          if cbuildbot_comm.HaveSlavesCompleted(config):
            _UprevPush(buildroot, tracking_branch, buildconfig['board'],
                       overlays)
          else:
            Die('CBUILDBOT - One of the slaves has failed!!!')

        else:
          # Publish my status to the master if its expecting it.
          if buildconfig['important']:
            cbuildbot_comm.PublishStatus(cbuildbot_comm.STATUS_BUILD_COMPLETE)

  except:
    # Send failure to master bot.
    if not buildconfig['master'] and buildconfig['important']:
      cbuildbot_comm.PublishStatus(cbuildbot_comm.STATUS_BUILD_FAILED)

    raise


if __name__ == '__main__':
    main()
