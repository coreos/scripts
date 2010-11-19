#!/usr/bin/python2.4

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""This module uprevs Chrome for cbuildbot."""

import optparse
import os
import re
import sys
import urllib

sys.path.append(os.path.join(os.path.dirname(__file__), '..'))
import cros_mark_as_stable

sys.path.append(os.path.join(os.path.dirname(__file__), '../lib'))
from cros_build_lib import RunCommand, Info, Warning

BASE_CHROME_SVN_URL = 'http://src.chromium.org/svn'

# Command for which chrome ebuild to uprev.
TIP_OF_TRUNK, LATEST_RELEASE, STICKY = 'tot', 'latest_release', 'sticky_release'
CHROME_REV = [TIP_OF_TRUNK, LATEST_RELEASE, STICKY]

# Helper regex's for finding ebuilds.
_CHROME_VERSION_REGEX = '\d+\.\d+\.\d+\.\d+'
_NON_STICKY_REGEX = '%s[(_rc.*)|(_alpha.*)]+' % _CHROME_VERSION_REGEX

# Dir where all the action happens.
_CHROME_OVERLAY_DIR = ('%(srcroot)s/third_party/chromiumos-overlay'
                       '/chromeos-base/chromeos-chrome')

# Different than cros_mark so devs don't have local collisions.
_STABLE_BRANCH_NAME = 'chrome_stabilizing_branch'

_GIT_COMMIT_MESSAGE = ('Marking %(chrome_rev)s for chrome ebuild with version '
                       '%(chrome_version)s as stable.')


def _GetSvnUrl():
  """Returns the path to the svn url for the given chrome branch."""
  return os.path.join(BASE_CHROME_SVN_URL, 'trunk')


def  _GetTipOfTrunkSvnRevision():
  """Returns the current svn revision for the chrome tree."""
  svn_url = _GetSvnUrl()
  svn_info = RunCommand(['svn', 'info', svn_url], redirect_stdout=True)

  revision_re = re.compile('^Revision:\s+(\d+).*')
  for line in svn_info.splitlines():
    match = revision_re.search(line)
    if match:
      return match.group(1)

  raise Exception('Could not find revision information from %s' % svn_url)


def _GetTipOfTrunkVersion():
  """Returns the current Chrome version."""
  svn_url = _GetSvnUrl()
  chrome_version_file = urllib.urlopen(os.path.join(svn_url, 'src', 'chrome',
                                                    'VERSION'))
  chrome_version_info = chrome_version_file.read()
  chrome_version_file.close()

  # Sanity check.
  if '404 Not Found' in chrome_version_info:
    raise Exception('Url %s does not have version file.' % svn_url)

  chrome_version_array = []

  for line in chrome_version_info.splitlines():
    chrome_version_array.append(line.rpartition('=')[2])

  return '.'.join(chrome_version_array)


def _GetLatestRelease(branch=None):
  """Gets the latest release version from the buildspec_url for the branch.

  Args:
    branch:  If set, gets the latest release for branch, otherwise latest
      release.
  Returns:
    Latest version string.
  """
  buildspec_url = 'http://src.chromium.org/svn/releases'
  svn_ls = RunCommand(['svn', 'ls', buildspec_url], redirect_stdout=True)
  sorted_ls = RunCommand(['sort', '--version-sort'], input=svn_ls,
                         redirect_stdout=True)
  if branch:
    chrome_version_re = re.compile('^%s\.\d+.*' % branch)
  else:
    chrome_version_re = re.compile('^[0-9]\..*')
  for chrome_version in sorted_ls.splitlines():
    if chrome_version_re.match(chrome_version):
      current_version = chrome_version

  return current_version.rstrip('/')


def _GetStickyVersion(stable_ebuilds):
  """Discovers the sticky version from the current stable_ebuilds."""
  sticky_ebuilds = []
  non_sticky_re = re.compile(_NON_STICKY_REGEX)
  for ebuild in stable_ebuilds:
    if not non_sticky_re.match(ebuild.version):
      sticky_ebuilds.append(ebuild)

  if not sticky_ebuilds:
    raise Exception('No sticky ebuilds found')
  elif len(sticky_ebuilds) > 1:
    Warning('More than one sticky ebuild found')

  return cros_mark_as_stable.BestEBuild(sticky_ebuilds).chrome_version


class ChromeEBuild(cros_mark_as_stable.EBuild):
  """Thin sub-class of EBuild that adds a chrome_version field."""
  chrome_version_re = re.compile('.*chromeos-chrome-(%s|9999).*' % (
      _CHROME_VERSION_REGEX))
  chrome_version = ''

  def __init__(self, path):
    cros_mark_as_stable.EBuild.__init__(self, path)
    re_match = self.chrome_version_re.match(self.ebuild_path_no_revision)
    if re_match:
      self.chrome_version = re_match.group(1)

  def __cmp__(self, other):
    """Use ebuild paths for comparison."""
    if self.ebuild_path == other.ebuild_path:
      return 0
    elif self.ebuild_path > other.ebuild_path:
      return 1
    else:
      return (-1)


def FindChromeCandidates(overlay_dir):
  """Return a tuple of chrome's unstable ebuild and stable ebuilds.

  Args:
    overlay_dir: The path to chrome's portage overlay dir.
  Returns:
    Tuple [unstable_ebuild, stable_ebuilds].
  Raises:
    Exception: if no unstable ebuild exists for Chrome.
  """
  stable_ebuilds = []
  unstable_ebuilds = []
  for path in [
      os.path.join(overlay_dir, entry) for entry in os.listdir(overlay_dir)]:
    if path.endswith('.ebuild'):
      ebuild = ChromeEBuild(path)
      if not ebuild.chrome_version:
        Warning('Poorly formatted ebuild found at %s' % path)
      else:
        if not ebuild.is_stable:
          unstable_ebuilds.append(ebuild)
        else:
          stable_ebuilds.append(ebuild)

  # Apply some sanity checks.
  if not unstable_ebuilds:
    raise Exception('Missing 9999 ebuild for %s' % overlay_dir)
  if not stable_ebuilds:
    Warning('Missing stable ebuild for %s' % overlay_dir)

  return cros_mark_as_stable.BestEBuild(unstable_ebuilds), stable_ebuilds


def FindChromeUprevCandidate(stable_ebuilds, chrome_rev, sticky_branch):
  """Finds the Chrome uprev candidate for the given chrome_rev.

  Using the pre-flight logic, this means the stable ebuild you are uprevving
  from.  The difference here is that the version could be different and in
  that case we want to find it to delete it.

  Args:
    stable_ebuilds: A list of stable ebuilds.
    chrome_rev: The chrome_rev designating which candidate to find.
    sticky_branch:  The the branch that is currently sticky with Major/Minor
      components.  For example: 9.0.553
  Returns:
    Returns the EBuild, otherwise None if none found.
  """
  candidates = []
  if chrome_rev == TIP_OF_TRUNK:
    chrome_branch_re = re.compile('%s.*_alpha.*' % _CHROME_VERSION_REGEX)
    for ebuild in stable_ebuilds:
      if chrome_branch_re.search(ebuild.version):
        candidates.append(ebuild)

  elif chrome_rev == STICKY:
    chrome_branch_re = re.compile('%s\.\d+.*_rc.*' % sticky_branch)
    for ebuild in stable_ebuilds:
      if chrome_branch_re.search(ebuild.version):
        candidates.append(ebuild)

  else:
    chrome_branch_re = re.compile('%s.*_rc.*' % _CHROME_VERSION_REGEX)
    for ebuild in stable_ebuilds:
      if chrome_branch_re.search(ebuild.version) and (
          not ebuild.chrome_version.startswith(sticky_branch)):
        candidates.append(ebuild)

  if candidates:
    return cros_mark_as_stable.BestEBuild(candidates)
  else:
    return None


def MarkChromeEBuildAsStable(stable_candidate, unstable_ebuild, chrome_rev,
                             chrome_version, commit, overlay_dir):
  """Uprevs the chrome ebuild specified by chrome_rev.

  This is the main function that uprevs the chrome_rev from a stable candidate
  to its new version.

  Args:
    stable_candidate: ebuild that corresponds to the stable ebuild we are
      revving from.  If None, builds the a new ebuild given the version
      and logic for chrome_rev type with revision set to 1.
    unstable_ebuild:  ebuild corresponding to the unstable ebuild for chrome.
    chrome_rev: one of CHROME_REV
      TIP_OF_TRUNK -  Requires commit value.  Revs the ebuild for the TOT
        version and uses the portage suffix of _alpha.
      LATEST_RELEASE - This uses the portage suffix of _rc as they are release
        candidates for the next sticky version.
      STICKY -  Revs the sticky version.
    chrome_version:  The \d.\d.\d.\d version of Chrome.
    commit:  Used with TIP_OF_TRUNK.  The svn revision of chrome.
    overlay_dir:  Path to the chromeos-chrome package dir.
  """
  base_path = os.path.join(overlay_dir, 'chromeos-chrome-%s' % chrome_version)
  # Case where we have the last stable candidate with same version just rev.
  if stable_candidate and stable_candidate.chrome_version == chrome_version:
    new_ebuild_path = '%s-r%d.ebuild' % (
        stable_candidate.ebuild_path_no_revision,
        stable_candidate.current_revision + 1)
  else:
    if chrome_rev == TIP_OF_TRUNK:
      portage_suffix = '_alpha'
    else:
      portage_suffix = '_rc'

    new_ebuild_path = base_path + ('%s-r1.ebuild' % portage_suffix)

  cros_mark_as_stable.EBuildStableMarker.MarkAsStable(
      unstable_ebuild.ebuild_path, new_ebuild_path, 'CROS_SVN_COMMIT', commit)
  RunCommand(['git', 'add', new_ebuild_path])
  if stable_candidate:
    RunCommand(['git', 'rm', stable_candidate.ebuild_path])

  cros_mark_as_stable.EBuildStableMarker.CommitChange(
      _GIT_COMMIT_MESSAGE % {'chrome_rev': chrome_rev,
                             'chrome_version': chrome_version})


def main(argv):
  usage = '%s OPTIONS commit|clean|push'
  parser = optparse.OptionParser(usage)
  parser.add_option('-c', '--chrome_rev', default=None,
                    help='One of %s' % CHROME_REV)
  parser.add_option('-s', '--srcroot', default='.',
                    help='Path to the src directory')
  parser.add_option('-t', '--tracking_branch', default='cros/master',
                    help='Branch we are tracking changes against')
  (options, argv) = parser.parse_args(argv)

  if len(argv) != 2 or argv[1] not in (
      cros_mark_as_stable.COMMAND_DICTIONARY.keys()):
    parser.error('Arguments are invalid, see usage.')

  command = argv[1]
  overlay_dir = os.path.abspath(_CHROME_OVERLAY_DIR %
                                {'srcroot': options.srcroot})

  os.chdir(overlay_dir)
  if command == 'clean':
    cros_mark_as_stable.Clean(options.tracking_branch)
    return
  elif command == 'push':
    cros_mark_as_stable.PushChange(_STABLE_BRANCH_NAME, options.tracking_branch)
    return

  if not options.chrome_rev or options.chrome_rev not in CHROME_REV:
    parser.error('Commit requires type set to one of %s.' % CHROME_REV)

  chrome_rev = options.chrome_rev
  version_to_uprev = None
  commit_to_use = None

  (unstable_ebuild, stable_ebuilds) = FindChromeCandidates(overlay_dir)
  sticky_version = _GetStickyVersion(stable_ebuilds)
  sticky_branch = sticky_version.rpartition('.')[0]

  if chrome_rev == TIP_OF_TRUNK:
    version_to_uprev = _GetTipOfTrunkVersion()
    commit_to_use = _GetTipOfTrunkSvnRevision()
  elif chrome_rev == LATEST_RELEASE:
    version_to_uprev = _GetLatestRelease()
  else:
    version_to_uprev = _GetLatestRelease(sticky_branch)

  stable_candidate = FindChromeUprevCandidate(stable_ebuilds, chrome_rev,
                                              sticky_branch)
  # There are some cases we don't need to do anything.  Check for them.
  if stable_candidate and (version_to_uprev == stable_candidate.chrome_version
                           and not commit_to_use):
    Info('Found nothing to do for chrome_rev %s with version %s.' % (
        chrome_rev, version_to_uprev))
  else:
    work_branch = cros_mark_as_stable.GitBranch(
        _STABLE_BRANCH_NAME, options.tracking_branch)
    work_branch.CreateBranch()
    try:
      MarkChromeEBuildAsStable(stable_candidate, unstable_ebuild, chrome_rev,
                               version_to_uprev, commit_to_use, overlay_dir)
    except:
      work_branch.Delete()
      raise


if __name__ == '__main__':
  main(sys.argv)
