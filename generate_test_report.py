#!/usr/bin/python
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.


"""Parses and displays the contents of one or more autoserv result directories.

This script parses the contents of one or more autoserv results folders and
generates test reports.
"""


import glob
import optparse
import os
import re
import sys

sys.path.append(os.path.join(os.path.dirname(__file__), 'lib'))
from cros_build_lib import Color, Die

_STDOUT_IS_TTY = hasattr(sys.stdout, 'isatty') and sys.stdout.isatty()

# List of crashes which are okay to ignore. This list should almost always be
# empty. If you add an entry, mark it with a TODO(<your name>) and the issue
# filed for the crash.
_CRASH_WHITELIST = {
  # TODO(dalecurtis): chromium-os:12212. Remove when resolved.
  'chromeos-wm': ['sig 6']
}

class ReportGenerator(object):
  """Collects and displays data from autoserv results directories.

  This class collects status and performance data from one or more autoserv
  result directories and generates test reports.
  """

  _KEYVAL_INDENT = 2

  def __init__(self, options, args):
    self._options = options
    self._args = args
    self._color = Color(options.color)

  def _CollectPerf(self, testdir):
    """Parses keyval file under testdir.

    If testdir contains a result folder, process the keyval file and return
    a dictionary of perf keyval pairs.

    Args:
      testdir: The autoserv test result directory.

    Returns:
      If the perf option is disabled or the there's no keyval file under
      testdir, returns an empty dictionary. Otherwise, returns a dictionary of
      parsed keyvals. Duplicate keys are uniquified by their instance number.
    """

    perf = {}
    if not self._options.perf:
      return perf

    keyval_file = os.path.join(testdir, 'results', 'keyval')
    if not os.path.isfile(keyval_file):
      return perf

    instances = {}

    for line in open(keyval_file):
      match = re.search(r'^(.+){perf}=(.+)$', line)
      if match:
        key = match.group(1)
        val = match.group(2)

        # If the same key name was generated multiple times, uniquify all
        # instances other than the first one by adding the instance count
        # to the key name.
        key_inst = key
        instance = instances.get(key, 0)
        if instance:
          key_inst = '%s{%d}' % (key, instance)
        instances[key] = instance + 1

        perf[key_inst] = val

    return perf

  def _CollectResult(self, testdir):
    """Adds results stored under testdir to the self._results dictionary.

    If testdir contains 'status.log' or 'status' files, assume it's a test
    result directory and add the results data to the self._results dictionary.
    The test directory name is used as a key into the results dictionary.

    Args:
      testdir: The autoserv test result directory.
    """

    status_file = os.path.join(testdir, 'status.log')
    if not os.path.isfile(status_file):
      status_file = os.path.join(testdir, 'status')
      if not os.path.isfile(status_file):
        return

    # Remove false positives that are missing a debug dir.
    if not os.path.exists(os.path.join(testdir, 'debug')):
      return

    status_raw = open(status_file, 'r').read()
    status = 'FAIL'
    if (re.search(r'GOOD.+completed successfully', status_raw) and
        not re.search(r'ABORT|ERROR|FAIL|TEST_NA', status_raw)):
      status = 'PASS'

    perf = self._CollectPerf(testdir)

    if testdir.startswith(self._options.strip):
      testdir = testdir.replace(self._options.strip, '', 1)

    crashes = []
    regex = re.compile('Received crash notification for ([-\w]+).+ (sig \d+)')
    for match in regex.finditer(status_raw):
      if (match.group(1) in _CRASH_WHITELIST and
          match.group(2) in _CRASH_WHITELIST[match.group(1)]):
        continue
      crashes.append('%s %s' % match.groups())

    self._results[testdir] = {'crashes': crashes,
                              'status': status,
                              'perf': perf}

  def _CollectResultsRec(self, resdir):
    """Recursively collect results into the self._results dictionary.

    Args:
      resdir: results/test directory to parse results from and recurse into.
    """

    self._CollectResult(resdir)
    for testdir in glob.glob(os.path.join(resdir, '*')):
      self._CollectResultsRec(testdir)

  def _CollectResults(self):
    """Parses results into the self._results dictionary.

    Initializes a dictionary (self._results) with test folders as keys and
    result data (status, perf keyvals) as values.
    """
    self._results = {}
    for resdir in self._args:
      if not os.path.isdir(resdir):
        Die('\'%s\' does not exist' % resdir)
      self._CollectResultsRec(resdir)

    if not self._results:
      Die('no test directories found')

  def GetTestColumnWidth(self):
    """Returns the test column width based on the test data.

    Aligns the test results by formatting the test directory entry based on
    the longest test directory or perf key string stored in the self._results
    dictionary.

    Returns:
      The width for the test columnt.
    """
    width = len(max(self._results, key=len))
    for result in self._results.values():
      perf = result['perf']
      if perf:
        perf_key_width = len(max(perf, key=len))
        width = max(width, perf_key_width + self._KEYVAL_INDENT)
    return width + 1

  def _GenerateReportText(self):
    """Prints a result report to stdout.

    Prints a result table to stdout. Each row of the table contains the test
    result directory and the test result (PASS, FAIL). If the perf option is
    enabled, each test entry is followed by perf keyval entries from the test
    results.
    """
    tests = self._results.keys()
    tests.sort()

    tests_with_errors = []

    width = self.GetTestColumnWidth()
    line = ''.ljust(width + 5, '-')

    crashes = {}
    tests_pass = 0
    print line
    for test in tests:
      # Emit the test/status entry first
      test_entry = test.ljust(width)
      result = self._results[test]
      status_entry = result['status']
      if status_entry == 'PASS':
        color = Color.GREEN
        tests_pass += 1
      else:
        color = Color.RED
        tests_with_errors.append(test)

      status_entry = self._color.Color(color, status_entry)
      print test_entry + status_entry

      # Emit the perf keyvals entries. There will be no entries if the
      # --no-perf option is specified.
      perf = result['perf']
      perf_keys = perf.keys()
      perf_keys.sort()

      for perf_key in perf_keys:
        perf_key_entry = perf_key.ljust(width - self._KEYVAL_INDENT)
        perf_key_entry = perf_key_entry.rjust(width)
        perf_value_entry = self._color.Color(Color.BOLD, perf[perf_key])
        print perf_key_entry + perf_value_entry

      # Ignore top-level entry, since it's just a combination of all the
      # individual results.
      if result['crashes'] and test != tests[0]:
        for crash in result['crashes']:
          if not crash in crashes:
            crashes[crash] = set([])
          crashes[crash].add(test)

    print line

    total_tests = len(tests)
    percent_pass = 100 * tests_pass / total_tests
    pass_str = '%d/%d (%d%%)' % (tests_pass, total_tests, percent_pass)
    print 'Total PASS: ' + self._color.Color(Color.BOLD, pass_str)

    if self._options.crash_detection:
      print ''
      if crashes:
        print self._color.Color(Color.RED, 'Crashes detected during testing:')
        print line

        for crash_name, crashed_tests in sorted(crashes.iteritems()):
          print self._color.Color(Color.RED, crash_name)
          for crashed_test in crashed_tests:
            print ' '*self._KEYVAL_INDENT + crashed_test

        print line
        print 'Total unique crashes: ' + self._color.Color(Color.BOLD,
                                                           str(len(crashes)))
      else:
        print self._color.Color(Color.GREEN,
                                'No crashes detected during testing.')

    # Print out the client debug information for failed tests.
    if self._options.print_debug:
      for test in tests_with_errors:
        debug_file_regex = os.path.join(self._options.strip, test, 'debug',
                                       '%s*.DEBUG' % os.path.basename(test))
        for path in glob.glob(debug_file_regex):
          try:
            fh = open(path)
            print >> sys.stderr, (
                '\n========== DEBUG FILE %s FOR TEST %s ==============\n' % (
                path, test))
            out = fh.read()
            while out:
              print >> sys.stderr, out
              out = fh.read()
            print >> sys.stderr, (
                 '\n=========== END DEBUG %s FOR TEST %s ===============\n' % (
                 path, test))
            fh.close()
          except:
            print 'Could not open %s' % path

      # Sometimes the builders exit before these buffers are flushed.
      sys.stderr.flush()
      sys.stdout.flush()

  def Run(self):
    """Runs report generation."""
    self._CollectResults()
    self._GenerateReportText()
    for v in self._results.itervalues():
      if v['status'] != 'PASS' or (self._options.crash_detection
                                   and v['crashes']):
        sys.exit(1)


def main():
  usage = 'Usage: %prog [options] result-directories...'
  parser = optparse.OptionParser(usage=usage)
  parser.add_option('--color', dest='color', action='store_true',
                    default=_STDOUT_IS_TTY,
                    help='Use color for text reports [default if TTY stdout]')
  parser.add_option('--no-color', dest='color', action='store_false',
                    help='Don\'t use color for text reports')
  parser.add_option('--no-crash-detection', dest='crash_detection',
                    action='store_false', default=True,
                    help='Don\'t report crashes or error out when detected')
  parser.add_option('--perf', dest='perf', action='store_true',
                    default=True,
                    help='Include perf keyvals in the report [default]')
  parser.add_option('--no-perf', dest='perf', action='store_false',
                    help='Don\'t include perf keyvals in the report')
  parser.add_option('--strip', dest='strip', type='string', action='store',
                    default='results.',
                    help='Strip a prefix from test directory names'
                    ' [default: \'%default\']')
  parser.add_option('--no-strip', dest='strip', const='', action='store_const',
                    help='Don\'t strip a prefix from test directory names')
  parser.add_option('--no-debug', dest='print_debug', action='store_false',
                    default=True,
                    help='Don\'t print out the debug log when a test fails.')
  (options, args) = parser.parse_args()

  if not args:
    parser.print_help()
    Die('no result directories provided')

  generator = ReportGenerator(options, args)
  generator.Run()


if __name__ == '__main__':
  main()
