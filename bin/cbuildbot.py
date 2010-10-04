#!/usr/bin/python

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""CBuildbot is wrapper around the build process used by the pre-flight queue"""

import errno
import re
import optparse
import os
import sys

import cbuildbot_comm
from cbuildbot_config import config

sys.path.append(os.path.join(os.path.dirname(__file__), '../lib'))
from cros_build_lib import Die, Info, RunCommand, Warning

_DEFAULT_RETRIES = 3

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
      if rw_checkout:
        # Always re-run in case of new git repos or repo sync
        # failed in a previous run because of a forced Stop Build.
        RunCommand(['repo', 'forall', '-c', 'git', 'config',
                    'url.ssh://git@gitrw.chromium.org:9222.pushinsteadof',
                    'http://git.chromium.org/git'], cwd=buildroot)

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
  extract_cmd = ["grep", "project name="]
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


def _UprevFromRevisionList(buildroot, revision_list):
  """Uprevs based on revision list."""
  if not revision_list:
    Info('No packages found to uprev')
    return

  package_str = ''
  commit_str = ''
  for package, revision in revision_list:
    package_str += package + ' '
    commit_str += revision + ' '

  package_str = package_str.strip()
  commit_str = commit_str.strip()

  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['./cros_mark_as_stable',
              '--tracking_branch="cros/master"',
              '--packages="%s"' % package_str,
              '--commit_ids="%s"' % commit_str,
              'commit'],
              cwd=cwd, enter_chroot=True)


def _UprevAllPackages(buildroot):
  """Uprevs all packages that have been updated since last uprev."""
  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['./cros_mark_all_as_stable',
              '--tracking_branch="cros/master"'],
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


# =========================== Main Commands ===================================

def _FullCheckout(buildroot, rw_checkout=True, retries=_DEFAULT_RETRIES):
  """Performs a full checkout and clobbers any previous checkouts."""
  RunCommand(['sudo', 'rm', '-rf', buildroot])
  MakeDir(buildroot, parents=True)
  RunCommand(['repo', 'init', '-u', 'http://src.chromium.org/git/manifest'],
             cwd=buildroot, input='\n\ny\n')
  RepoSync(buildroot, rw_checkout, retries)


def _IncrementalCheckout(buildroot, rw_checkout=True,
                         retries=_DEFAULT_RETRIES):
  """Performs a checkout without clobbering previous checkout."""
  _UprevCleanup(buildroot, error_ok=True)
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


def _WipeOldOutput(buildroot):
  RunCommand(['rm', '-rf', 'src/build/images'], cwd=buildroot)


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
              '--vdisk_size %s' % vdisk_size,
              '--statefulfs_size %s' % statefulfs_size,
              ], cwd=cwd, enter_chroot=True)


def _RunUnitTests(buildroot):
  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['./cros_run_unit_tests'], cwd=cwd, enter_chroot=True)


def _RunSmokeSuite(buildroot):
  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['bin/cros_run_vm_test',
              '--no_graphics',
              '--test_case',
              'suite_Smoke',
              ], cwd=cwd, error_ok=True)


def _UprevPackages(buildroot, revisionfile, board):
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
  #  _UprevFromRevisionList(buildroot, revision_list)
  #else:
  Info('CBUILDBOT Revving all')
  _UprevAllPackages(buildroot)


def _UprevCleanup(buildroot, error_ok=False):
  """Clean up after a previous uprev attempt."""
  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['./cros_mark_as_stable', '--srcroot=..',
              '--tracking_branch="cros/master"', 'clean'],
             cwd=cwd, error_ok=error_ok)


def _UprevPush(buildroot):
  """Pushes uprev changes to the main line."""
  cwd = os.path.join(buildroot, 'src', 'scripts')
  RunCommand(['./cros_mark_as_stable', '--srcroot=..',
              '--tracking_branch="cros/master"',
              '--push_options', '--bypass-hooks -f', 'push'],
             cwd=cwd)


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
  (options, args) = parser.parse_args()

  buildroot = options.buildroot
  revisionfile = options.revisionfile

  # Passed option to clobber.
  if options.clobber:
    RunCommand(['sudo', 'rm', '-rf', buildroot])

  if len(args) >= 1:
    buildconfig = _GetConfig(args[-1])
  else:
    Warning('Missing configuration description')
    parser.print_usage()
    sys.exit(1)

  try:
    if not os.path.isdir(buildroot):
      _FullCheckout(buildroot)
    else:
      _IncrementalCheckout(buildroot)

    chroot_path = os.path.join(buildroot, 'chroot')
    if not os.path.isdir(chroot_path):
      _MakeChroot(buildroot)

    boardpath = os.path.join(chroot_path, 'build', buildconfig['board'])
    if not os.path.isdir(boardpath):
      _SetupBoard(buildroot, board=buildconfig['board'])

    if buildconfig['uprev']:
      _UprevPackages(buildroot, revisionfile, board=buildconfig['board'])

    _EnableLocalAccount(buildroot)
    _Build(buildroot)
    if buildconfig['unittests']:
      _RunUnitTests(buildroot)

    _BuildImage(buildroot)

    if buildconfig['smoke_bvt']:
      _BuildVMImageForTesting(buildroot)
      _RunSmokeSuite(buildroot)

    if buildconfig['uprev']:
      if buildconfig['master']:
        # Master bot needs to check if the other slaves completed.
        if cbuildbot_comm.HaveSlavesCompleted(config):
          _UprevPush(buildroot)
          _UprevCleanup(buildroot)
        else:
          # At least one of the slaves failed or we timed out.
          _UprevCleanup(buildroot)
          Die('CBUILDBOT - One of the slaves has failed!!!')
      else:
        # Publish my status to the master if its expecting it.
        if buildconfig['important']:
          cbuildbot_comm.PublishStatus(cbuildbot_comm.STATUS_BUILD_COMPLETE)

        _UprevCleanup(buildroot)
  except:
    # Send failure to master bot.
    if not buildconfig['master'] and buildconfig['important']:
      cbuildbot_comm.PublishStatus(cbuildbot_comm.STATUS_BUILD_FAILED)

    raise


if __name__ == '__main__':
    main()
