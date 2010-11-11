#!/usr/bin/python

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""This module uprevs a given package's ebuild to the next revision."""


import fileinput
import gflags
import os
import re
import shutil
import subprocess
import sys

sys.path.append(os.path.join(os.path.dirname(__file__), 'lib'))
from cros_build_lib import Info, RunCommand, Warning, Die


gflags.DEFINE_string('board', '',
                     'Board for which the package belongs.', short_name='b')
gflags.DEFINE_string('overlays', '',
                     'Colon-separated list of overlays to modify.',
                     short_name='o')
gflags.DEFINE_string('packages', '',
                     'Colon-separated list of packages to mark as stable.',
                     short_name='p')
gflags.DEFINE_string('push_options', '',
                     'Options to use with git-cl push using push command.')
gflags.DEFINE_string('srcroot', '%s/trunk/src' % os.environ['HOME'],
                     'Path to root src directory.',
                     short_name='r')
gflags.DEFINE_string('tracking_branch', 'cros/master',
                     'Used with commit to specify branch to track against.',
                     short_name='t')
gflags.DEFINE_boolean('all', False,
                      'Mark all packages as stable.')
gflags.DEFINE_boolean('verbose', False,
                      'Prints out verbose information about what is going on.',
                      short_name='v')


# Takes two strings, package_name and commit_id.
_GIT_COMMIT_MESSAGE = \
  'Marking 9999 ebuild for %s with commit %s as stable.'

# Dictionary of valid commands with usage information.
_COMMAND_DICTIONARY = {
                        'clean':
                          'Cleans up previous calls to either commit or push',
                        'commit':
                          'Marks given ebuilds as stable locally',
                        'push':
                          'Pushes previous marking of ebuilds to remote repo',
                      }

# Name used for stabilizing branch.
_STABLE_BRANCH_NAME = 'stabilizing_branch'

# ======================= Global Helper Functions ========================


def _Print(message):
  """Verbose print function."""
  if gflags.FLAGS.verbose:
    Info(message)


def _CleanStalePackages(board, package_array):
    """Cleans up stale package info from a previous build."""
    Info('Cleaning up stale packages %s.' % package_array)
    unmerge_board_cmd = ['emerge-%s' % board, '--unmerge']
    unmerge_board_cmd.extend(package_array)
    RunCommand(unmerge_board_cmd)

    unmerge_host_cmd = ['sudo', 'emerge', '--unmerge']
    unmerge_host_cmd.extend(package_array)
    RunCommand(unmerge_host_cmd)

    RunCommand(['eclean-%s' % board, '-d', 'packages'], redirect_stderr=True)
    RunCommand(['sudo', 'eclean', '-d', 'packages'], redirect_stderr=True)


def _BestEBuild(ebuilds):
  """Returns the newest EBuild from a list of EBuild objects."""
  from portage.versions import vercmp
  winner = ebuilds[0]
  for ebuild in ebuilds[1:]:
    if vercmp(winner.version, ebuild.version) < 0:
      winner = ebuild
  return winner


def _FindUprevCandidates(files):
  """Return a list of uprev candidates from specified list of files.

  Usually an uprev candidate is a the stable ebuild in a cros_workon directory.
  However, if no such stable ebuild exists (someone just checked in the 9999
  ebuild), this is the unstable ebuild.

  Args:
    files: List of files.
  """
  workon_dir = False
  stable_ebuilds = []
  unstable_ebuilds = []
  for path in files:
    if path.endswith('.ebuild') and not os.path.islink(path):
      ebuild = _EBuild(path)
      if ebuild.is_workon:
        workon_dir = True
        if ebuild.is_stable:
          stable_ebuilds.append(ebuild)
        else:
          unstable_ebuilds.append(ebuild)

  # If we found a workon ebuild in this directory, apply some sanity checks.
  if workon_dir:
    if len(unstable_ebuilds) > 1:
      Die('Found multiple unstable ebuilds in %s' % os.path.dirname(path))
    if len(stable_ebuilds) > 1:
      stable_ebuilds = [_BestEBuild(stable_ebuilds)]

      # Print a warning if multiple stable ebuilds are found in the same
      # directory. Storing multiple stable ebuilds is error-prone because
      # the older ebuilds will not get rev'd.
      #
      # We make a special exception for x11-drivers/xf86-video-msm for legacy
      # reasons.
      if stable_ebuilds[0].package != 'x11-drivers/xf86-video-msm':
        Warning('Found multiple stable ebuilds in %s' % os.path.dirname(path))

    if not unstable_ebuilds:
      Die('Missing 9999 ebuild in %s' % os.path.dirname(path))
    if not stable_ebuilds:
      Warning('Missing stable ebuild in %s' % os.path.dirname(path))
      return unstable_ebuilds[0]

  if stable_ebuilds:
    return stable_ebuilds[0]
  else:
    return None


def _BuildEBuildDictionary(overlays, all, packages):
  """Build a dictionary of the ebuilds in the specified overlays.

  overlays: A map which maps overlay directories to arrays of stable EBuilds
    inside said directories.
  all: Whether to include all ebuilds in the specified directories. If true,
    then we gather all packages in the directories regardless of whether
    they are in our set of packages.
  packages: A set of the packages we want to gather.
  """
  for overlay in overlays:
    for package_dir, dirs, files in os.walk(overlay):
      # Add stable ebuilds to overlays[overlay].
      paths = [os.path.join(package_dir, path) for path in files]
      ebuild = _FindUprevCandidates(paths)

      # If the --all option isn't used, we only want to update packages that
      # are in packages.
      if ebuild and (all or ebuild.package in packages):
        overlays[overlay].append(ebuild)


def _CheckOnStabilizingBranch():
  """Returns true if the git branch is on the stabilizing branch."""
  current_branch = _SimpleRunCommand('git branch | grep \*').split()[1]
  return current_branch == _STABLE_BRANCH_NAME


def _CheckSaneArguments(package_list, command):
  """Checks to make sure the flags are sane.  Dies if arguments are not sane."""
  if not command in _COMMAND_DICTIONARY.keys():
    _PrintUsageAndDie('%s is not a valid command' % command)
  if not gflags.FLAGS.packages and command == 'commit' and not gflags.FLAGS.all:
    _PrintUsageAndDie('Please specify at least one package')
  if not gflags.FLAGS.board and command == 'commit':
    _PrintUsageAndDie('Please specify a board')
  if not os.path.isdir(gflags.FLAGS.srcroot):
    _PrintUsageAndDie('srcroot is not a valid path')
  gflags.FLAGS.srcroot = os.path.abspath(gflags.FLAGS.srcroot)


def _Clean():
  """Cleans up uncommitted changes on either stabilizing branch or master."""
  _SimpleRunCommand('git reset HEAD --hard')
  _SimpleRunCommand('git checkout %s' % gflags.FLAGS.tracking_branch)


def _PrintUsageAndDie(error_message=''):
  """Prints optional error_message the usage and returns an error exit code."""
  command_usage = 'Commands: \n'
  # Add keys and usage information from dictionary.
  commands = sorted(_COMMAND_DICTIONARY.keys())
  for command in commands:
    command_usage += '  %s: %s\n' % (command, _COMMAND_DICTIONARY[command])
  commands_str = '|'.join(commands)
  Warning('Usage: %s FLAGS [%s]\n\n%s\nFlags:%s' % (sys.argv[0], commands_str,
                                                  command_usage, gflags.FLAGS))
  if error_message:
    Die(error_message)
  else:
    sys.exit(1)

def _PushChange():
  """Pushes changes to the git repository.

  Pushes locals commits from calls to CommitChange to the remote git
  repository specified by os.pwd.

  Raises:
      OSError: Error occurred while pushing.
  """

  # TODO(sosa) - Add logic for buildbot to check whether other slaves have
  # completed and push this change only if they have.

  # Sanity check to make sure we're on a stabilizing branch before pushing.
  if not _CheckOnStabilizingBranch():
    Info('Not on branch %s so no work found to push.  Exiting' % \
        _STABLE_BRANCH_NAME)
    return

  description = _SimpleRunCommand('git log --format=format:%s%n%n%b ' +
                            gflags.FLAGS.tracking_branch + '..')
  description = 'Marking set of ebuilds as stable\n\n%s' % description
  merge_branch_name = 'merge_branch'
  _SimpleRunCommand('git remote update')
  merge_branch = _GitBranch(merge_branch_name)
  merge_branch.CreateBranch()
  if not merge_branch.Exists():
    Die('Unable to create merge branch.')
  _SimpleRunCommand('git merge --squash %s' % _STABLE_BRANCH_NAME)
  _SimpleRunCommand('git commit -m "%s"' % description)
  # Ugh. There has got to be an easier way to push to a tracking branch
  _SimpleRunCommand('git config push.default tracking')
  _SimpleRunCommand('git push')


def _SimpleRunCommand(command):
  """Runs a shell command and returns stdout back to caller."""
  _Print('  + %s' % command)
  proc_handle = subprocess.Popen(command, stdout=subprocess.PIPE, shell=True)
  stdout = proc_handle.communicate()[0]
  retcode = proc_handle.wait()
  assert retcode == 0, "Return code %s for command: %s" % (retcode, command)
  return stdout


# ======================= End Global Helper Functions ========================


class _GitBranch(object):
  """Wrapper class for a git branch."""

  def __init__(self, branch_name):
    """Sets up variables but does not create the branch."""
    self.branch_name = branch_name

  def CreateBranch(self):
    """Creates a new git branch or replaces an existing one."""
    if self.Exists():
      self.Delete()
    self._Checkout(self.branch_name)

  def _Checkout(self, target, create=True):
    """Function used internally to create and move between branches."""
    if create:
      git_cmd = 'git checkout -b %s %s' % (target, gflags.FLAGS.tracking_branch)
    else:
      git_cmd = 'git checkout %s' % target
    _SimpleRunCommand(git_cmd)

  def Exists(self):
    """Returns True if the branch exists."""
    branch_cmd = 'git branch'
    branches = _SimpleRunCommand(branch_cmd)
    return self.branch_name in branches.split()

  def Delete(self):
    """Deletes the branch and returns the user to the master branch.

    Returns True on success.
    """
    self._Checkout(gflags.FLAGS.tracking_branch, create=False)
    delete_cmd = 'git branch -D %s' % self.branch_name
    _SimpleRunCommand(delete_cmd)


class _EBuild(object):
  """Wrapper class for an ebuild."""

  def __init__(self, path):
    """Initializes all data about an ebuild.

    Uses equery to find the ebuild path and sets data about an ebuild for
    easy reference.
    """
    from portage.versions import pkgsplit
    self.ebuild_path = path
    (self.ebuild_path_no_revision,
     self.ebuild_path_no_version,
     self.current_revision) = self._ParseEBuildPath(self.ebuild_path)
    _, self.category, pkgpath, filename = path.rsplit('/', 3)
    filename_no_suffix = os.path.join(filename.replace('.ebuild', ''))
    self.pkgname, version_no_rev, rev = pkgsplit(filename_no_suffix)
    self.version = '%s-%s' % (version_no_rev, rev)
    self.package = '%s/%s' % (self.category, self.pkgname)
    self.is_workon = False
    self.is_stable = False

    for line in fileinput.input(path):
      if line.startswith('inherit ') and 'cros-workon' in line:
        self.is_workon = True
      elif (line.startswith('KEYWORDS=') and '~' not in line and
            ('amd64' in line or 'x86' in line or 'arm' in line)):
        self.is_stable = True
    fileinput.close()

  def GetCommitId(self):
    """Get the commit id for this ebuild."""

    # Grab and evaluate CROS_WORKON variables from this ebuild.
    unstable_ebuild = '%s-9999.ebuild' % self.ebuild_path_no_version
    cmd = ('CROS_WORKON_LOCALNAME="%s" CROS_WORKON_PROJECT="%s" '
           'eval $(grep -E "^CROS_WORKON" %s) && '
           'echo $CROS_WORKON_PROJECT '
           '$CROS_WORKON_LOCALNAME/$CROS_WORKON_SUBDIR'
           % (self.pkgname, self.pkgname, unstable_ebuild))
    project, subdir = _SimpleRunCommand(cmd).split()

    # Calculate srcdir.
    srcroot = gflags.FLAGS.srcroot
    if self.category == 'chromeos-base':
      dir = 'platform'
    else:
      dir = 'third_party'
    srcdir = os.path.join(srcroot, dir, subdir)

    # TODO(anush): This hack is only necessary because the kernel ebuild has
    # 'if' statements, so we can't grab the CROS_WORKON_LOCALNAME properly.
    # We should clean up the kernel ebuild and remove this hack.
    if not os.path.exists(srcdir) and subdir == 'kernel/':
      srcdir = os.path.join(srcroot, 'third_party/kernel/files')

    if not os.path.exists(srcdir):
      Die('Cannot find commit id for %s' % self.ebuild_path)

    # Verify that we're grabbing the commit id from the right project name.
    # NOTE: chromeos-kernel has the wrong project name, so it fails this
    # check.
    # TODO(davidjames): Fix the project name in the chromeos-kernel ebuild.
    cmd = 'cd %s && git config --get remote.cros.projectname' % srcdir
    actual_project = _SimpleRunCommand(cmd).rstrip()
    if project not in (actual_project, 'chromeos-kernel'):
      Die('Project name mismatch for %s (%s != %s)' % (unstable_ebuild, project,
          actual_project))

    # Get commit id.
    output = _SimpleRunCommand('cd %s && git rev-parse HEAD' % srcdir)
    if not output:
      Die('Missing commit id for %s' % self.ebuild_path)
    return output.rstrip()

  @classmethod
  def _ParseEBuildPath(cls, ebuild_path):
    """Static method that parses the path of an ebuild

    Returns a tuple containing the (ebuild path without the revision
    string, without the version string, and the current revision number for
    the ebuild).
    """
     # Get the ebuild name without the revision string.
    (ebuild_no_rev, _, rev_string) = ebuild_path.rpartition('-')

    # Verify the revision string starts with the revision character.
    if rev_string.startswith('r'):
      # Get the ebuild name without the revision and version strings.
      ebuild_no_version = ebuild_no_rev.rpartition('-')[0]
      rev_string = rev_string[1:].rpartition('.ebuild')[0]
    else:
      # Has no revision so we stripped the version number instead.
      ebuild_no_version = ebuild_no_rev
      ebuild_no_rev = ebuild_path.rpartition('9999.ebuild')[0] + '0.0.1'
      rev_string = '0'
    revision = int(rev_string)
    return (ebuild_no_rev, ebuild_no_version, revision)


class EBuildStableMarker(object):
  """Class that revs the ebuild and commits locally or pushes the change."""

  def __init__(self, ebuild):
    self._ebuild = ebuild

  def RevEBuild(self, commit_id='', redirect_file=None):
    """Revs an ebuild given the git commit id.

    By default this class overwrites a new ebuild given the normal
    ebuild rev'ing logic.  However, a user can specify a redirect_file
    to redirect the new stable ebuild to another file.

    Args:
        commit_id: String corresponding to the commit hash of the developer
          package to rev.
        redirect_file: Optional file to write the new ebuild.  By default
          it is written using the standard rev'ing logic.  This file must be
          opened and closed by the caller.

    Raises:
        OSError: Error occurred while creating a new ebuild.
        IOError: Error occurred while writing to the new revved ebuild file.
    Returns:
      True if the revved package is different than the old ebuild.
    """
    # TODO(sosa):  Change to a check.
    if not self._ebuild:
      Die('Invalid ebuild given to EBuildStableMarker')

    new_ebuild_path = '%s-r%d.ebuild' % (self._ebuild.ebuild_path_no_revision,
                                         self._ebuild.current_revision + 1)

    _Print('Creating new stable ebuild %s' % new_ebuild_path)
    workon_ebuild = '%s-9999.ebuild' % self._ebuild.ebuild_path_no_version
    if not os.path.exists(workon_ebuild):
      Die('Missing 9999 ebuild: %s' % workon_ebuild)
    shutil.copyfile(workon_ebuild, new_ebuild_path)

    for line in fileinput.input(new_ebuild_path, inplace=1):
      # Has to be done here to get changes to sys.stdout from fileinput.input.
      if not redirect_file:
        redirect_file = sys.stdout
      if line.startswith('KEYWORDS'):
        # Actually mark this file as stable by removing ~'s.
        redirect_file.write(line.replace('~', ''))
      elif line.startswith('EAPI'):
        # Always add new commit_id after EAPI definition.
        redirect_file.write(line)
        redirect_file.write('CROS_WORKON_COMMIT="%s"\n' % commit_id)
      elif not line.startswith('CROS_WORKON_COMMIT'):
        # Skip old CROS_WORKON_COMMIT definition.
        redirect_file.write(line)
    fileinput.close()

    old_ebuild_path = self._ebuild.ebuild_path
    diff_cmd = ['diff', '-Bu', old_ebuild_path, new_ebuild_path]
    if 0 == RunCommand(diff_cmd, exit_code=True, redirect_stdout=True,
                       redirect_stderr=True, print_cmd=gflags.FLAGS.verbose):
      os.unlink(new_ebuild_path)
      return False
    else:
      _Print('Adding new stable ebuild to git')
      _SimpleRunCommand('git add %s' % new_ebuild_path)

      if self._ebuild.is_stable:
        _Print('Removing old ebuild from git')
        _SimpleRunCommand('git rm %s' % old_ebuild_path)

      return True

  def CommitChange(self, message):
    """Commits current changes in git locally.

    This method will take any changes from invocations to RevEBuild
    and commits them locally in the git repository that contains os.pwd.

    Args:
        message: the commit string to write when committing to git.

    Raises:
        OSError: Error occurred while committing.
    """
    _Print('Committing changes for %s with commit message %s' % \
           (self._ebuild.package, message))
    git_commit_cmd = 'git commit -am "%s"' % message
    _SimpleRunCommand(git_commit_cmd)


def main(argv):
  try:
    argv = gflags.FLAGS(argv)
    if len(argv) != 2:
      _PrintUsageAndDie('Must specify a valid command')
    else:
      command = argv[1]
  except gflags.FlagsError, e :
    _PrintUsageAndDie(str(e))

  package_list = gflags.FLAGS.packages.split(':')
  _CheckSaneArguments(package_list, command)
  if gflags.FLAGS.overlays:
    overlays = {}
    for path in gflags.FLAGS.overlays.split(':'):
      if not os.path.exists(path):
        Die('Cannot find overlay: %s' % path)
      overlays[path] = []
  else:
    Warning('Missing --overlays argument')
    overlays = {
      '%s/private-overlays/chromeos-overlay' % gflags.FLAGS.srcroot: [],
      '%s/third_party/chromiumos-overlay' % gflags.FLAGS.srcroot: []
    }

  if command == 'commit':
    _BuildEBuildDictionary(overlays, gflags.FLAGS.all, package_list)

  for overlay, ebuilds in overlays.items():
    if not os.path.exists(overlay):
      Warning("Skipping %s" % overlay)
      continue
    os.chdir(overlay)

    if command == 'clean':
      _Clean()
    elif command == 'push':
      _PushChange()
    elif command == 'commit' and ebuilds:
      work_branch = _GitBranch(_STABLE_BRANCH_NAME)
      work_branch.CreateBranch()
      if not work_branch.Exists():
        Die('Unable to create stabilizing branch in %s' % overlay)

      # Contains the array of packages we actually revved.
      revved_packages = []
      for ebuild in ebuilds:
        try:
          _Print('Working on %s' % ebuild.package)
          worker = EBuildStableMarker(ebuild)
          commit_id = ebuild.GetCommitId()
          if worker.RevEBuild(commit_id):
            message = _GIT_COMMIT_MESSAGE % (ebuild.package, commit_id)
            worker.CommitChange(message)
            revved_packages.append(ebuild.package)

        except (OSError, IOError):
          Warning('Cannot rev %s\n' % ebuild.package,
                  'Note you will have to go into %s '
                  'and reset the git repo yourself.' % overlay)
          raise

      if revved_packages:
        _CleanStalePackages(gflags.FLAGS.board, revved_packages)
      else:
        work_branch.Delete()


if __name__ == '__main__':
  main(sys.argv)
