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
from cros_build_lib import Info, Warning, Die


gflags.DEFINE_string('board', 'x86-generic',
                     'Board for which the package belongs.', short_name='b')
gflags.DEFINE_string('commit_ids', '',
                     """Optional list of commit ids for each package.
                     This list must either be empty or have the same length as
                     the packages list.  If not set all rev'd ebuilds will have
                     empty commit id's.""",
                     short_name='i')
gflags.DEFINE_string('packages', '',
                     'Space separated list of packages to mark as stable.',
                     short_name='p')
gflags.DEFINE_string('push_options', '',
                     'Options to use with git-cl push using push command.')
gflags.DEFINE_string('srcroot', '%s/trunk/src' % os.environ['HOME'],
                     'Path to root src directory.',
                     short_name='r')
gflags.DEFINE_string('tracking_branch', 'cros/master',
                     'Used with commit to specify branch to track against.',
                     short_name='t')
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


def _BuildEBuildDictionary(overlays, package_list, commit_id_list):
  for index in range(len(package_list)):
    package = package_list[index]
    commit_id = ''
    if commit_id_list:
      commit_id = commit_id_list[index]
    ebuild = _EBuild(package, commit_id)
    if ebuild.ebuild_path:
      for overlay in overlays:
        if ebuild.ebuild_path.startswith(overlay):
          overlays[overlay].append(ebuild)
          break
      else:
        Die('No overlay found for %s' % ebuild.ebuild_path)
    else:
      Die('No ebuild found for %s' % package)


def _CheckOnStabilizingBranch():
  """Returns true if the git branch is on the stabilizing branch."""
  current_branch = _SimpleRunCommand('git branch | grep \*').split()[1]
  return current_branch == _STABLE_BRANCH_NAME


def _CheckSaneArguments(package_list, commit_id_list, command):
  """Checks to make sure the flags are sane.  Dies if arguments are not sane."""
  if not command in _COMMAND_DICTIONARY.keys():
    _PrintUsageAndDie('%s is not a valid command' % command)
  if not gflags.FLAGS.packages and command == 'commit':
    _PrintUsageAndDie('Please specify at least one package')
  if not gflags.FLAGS.board and command == 'commit':
    _PrintUsageAndDie('Please specify a board')
  if not os.path.isdir(gflags.FLAGS.srcroot):
    _PrintUsageAndDie('srcroot is not a valid path')
  if commit_id_list and (len(package_list) != len(commit_id_list)):
    _PrintUsageAndDie(
        'Package list is not the same length as the commit id list')


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
  return proc_handle.communicate()[0]


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

  def __init__(self, package, commit_id=None):
    """Initializes all data about an ebuild.

    Uses equery to find the ebuild path and sets data about an ebuild for
    easy reference.
    """
    self.package = package
    self.ebuild_path = self._FindEBuildPath(package)
    (self.ebuild_path_no_revision,
     self.ebuild_path_no_version,
     self.current_revision) = self._ParseEBuildPath(self.ebuild_path)
    self.commit_id = commit_id

  @classmethod
  def _FindEBuildPath(cls, package):
    """Static method that returns the full path of an ebuild."""
    _Print('Looking for unstable ebuild for %s' % package)
    equery_cmd = (
        'ACCEPT_KEYWORDS="x86 arm amd64" equery-%s which %s 2> /dev/null'
            % (gflags.FLAGS.board, package))
    path = _SimpleRunCommand(equery_cmd)
    if path:
      _Print('Unstable ebuild found at %s' % path)
    return path.rstrip()

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
      ebuild_no_rev = ebuild_path.rpartition('.ebuild')[0]
      rev_string = "0"
    revision = int(rev_string)
    return (ebuild_no_rev, ebuild_no_version, revision)


class EBuildStableMarker(object):
  """Class that revs the ebuild and commits locally or pushes the change."""

  def __init__(self, ebuild):
    self._ebuild = ebuild

  def RevEBuild(self, commit_id="", redirect_file=None):
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
        redirect_file.write(line.replace("~", ""))
      elif line.startswith('EAPI'):
        # Always add new commit_id after EAPI definition.
        redirect_file.write(line)
        redirect_file.write('CROS_WORKON_COMMIT="%s"\n' % commit_id)
      elif not line.startswith('CROS_WORKON_COMMIT'):
        # Skip old CROS_WORKON_COMMIT definition.
        redirect_file.write(line)
    fileinput.close()

    _Print('Adding new stable ebuild to git')
    _SimpleRunCommand('git add %s' % new_ebuild_path)

    _Print('Removing old ebuild from git')
    _SimpleRunCommand('git rm %s' % self._ebuild.ebuild_path)

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

  package_list = gflags.FLAGS.packages.split()
  if gflags.FLAGS.commit_ids:
    commit_id_list = gflags.FLAGS.commit_ids.split()
  else:
    commit_id_list = None
  _CheckSaneArguments(package_list, commit_id_list, command)

  overlays = {
    '%s/private-overlays/chromeos-overlay' % gflags.FLAGS.srcroot: [],
    '%s/third_party/chromiumos-overlay' % gflags.FLAGS.srcroot: []
  }
  _BuildEBuildDictionary(overlays, package_list, commit_id_list)

  for overlay, ebuilds in overlays.items():
    if not os.path.exists(overlay):
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
      for ebuild in ebuilds:
        try:
          _Print('Working on %s' % ebuild.package)
          worker = EBuildStableMarker(ebuild)
          worker.RevEBuild(ebuild.commit_id)
          message = _GIT_COMMIT_MESSAGE % (ebuild.package, ebuild.commit_id)
          worker.CommitChange(message)
        except (OSError, IOError):
          Warning('Cannot rev %s\n' % ebuild.package,
                  'Note you will have to go into %s '
                  'and reset the git repo yourself.' % overlay)
          raise


if __name__ == '__main__':
  main(sys.argv)

