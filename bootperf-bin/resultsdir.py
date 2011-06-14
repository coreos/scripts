# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Routines for reading performance results from a directory.

The directory should match the format created by the 'bootperf'
script; see comments in that script for a summary of the layout.

"""

import fnmatch
import os
import re

import resultset


_PERF_KEYVAL_PATTERN = re.compile("(.*){perf}=(.*)\n")


def _ReadKeyvalFile(results, file_):
  """Read an autotest keyval file, and process the results.

  The `file_` parameter is a file object with contents in autotest
  perf keyval format:
      <keyname>{perf}=<value>

  Each iteration of the test is terminated with a single blank line,
  including the last iteration.  Each iteration's results are added
  to the `results` parameter, which should be an instance of
  TestResultSet.

  """
  kvd = {}
  for line in iter(file_):
    if line == "\n":
      results.AddIterationResults(kvd)
      kvd = {}
      continue
    m = _PERF_KEYVAL_PATTERN.match(line)
    if m is None:
      continue
    kvd[m.group(1)] = m.group(2)


_RESULTS_PATH = (
    "summary/platform_BootPerfServer/platform_BootPerfServer/results/keyval")


def ReadResultsDirectory(dir_):
  """Process results from a 'bootperf' output directory.

  The accumulated results are returned in a newly created
  TestResultSet object.

  """
  res_set = resultset.TestResultSet(dir_)
  dirlist = fnmatch.filter(os.listdir(dir_), "run.???")
  dirlist.sort()
  for rundir in dirlist:
    keyval_path = os.path.join(dir_, rundir, _RESULTS_PATH)
    try:
      kvf = open(keyval_path)
    except IOError:
      continue
    _ReadKeyvalFile(res_set, kvf)
  res_set.FinalizeResults()
  return res_set
