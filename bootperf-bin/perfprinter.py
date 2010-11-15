# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Routines for printing boot time performance test results."""

import fnmatch
import os
import os.path
import re

import resultset


_PERF_KEYVAL_PATTERN = re.compile("(.*){perf}=(.*)\n")


def ReadKeyvalFile(results, file_):
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
  for run in dirlist:
    keyval_path = os.path.join(dir_, run, _RESULTS_PATH)
    try:
      kvf = open(keyval_path)
    except IOError:
      continue
    ReadKeyvalFile(res_set, kvf)
  res_set.FinalizeResults()
  return res_set


def PrintRawData(dirlist, use_timestats, keylist):
  """Print 'bootperf' results in "raw data" format."""
  for dir_ in dirlist:
    if use_timestats:
      keyset = ReadResultsDirectory(dir_).TimeKeySet()
    else:
      keyset = ReadResultsDirectory(dir_).DiskKeySet()
    for i in range(0, keyset.num_iterations):
      if len(dirlist) > 1:
        line = "%s %3d" % (dir_, i)
      else:
        line = "%3d" % i
      if keylist is not None:
        markers = keylist
      else:
        markers = keyset.markers
      for stat in markers:
        (_, v) = keyset.PrintableStatistic(keyset.RawData(stat)[i])
        line += " %5s" % str(v)
      print line


def PrintStatisticsSummary(dirlist, use_timestats, keylist):
  """Print 'bootperf' results in "summary of averages" format."""
  if use_timestats:
    header = "%5s %3s  %5s %3s  %s" % (
        "time", "s%", "dt", "s%", "event")
    format = "%5s %2d%%  %5s %2d%%  %s"
  else:
    header = "%6s %3s  %6s %3s  %s" % (
        "diskrd", "s%", "delta", "s%", "event")
    format = "%6s %2d%%  %6s %2d%%  %s"
  havedata = False
  for dir_ in dirlist:
    if use_timestats:
      keyset = ReadResultsDirectory(dir_).TimeKeySet()
    else:
      keyset = ReadResultsDirectory(dir_).DiskKeySet()
    if keylist is not None:
      markers = keylist
    else:
      markers = keyset.markers
    if havedata:
      print
    if len(dirlist) > 1:
      print "%s" % dir_,
    print "(on %d cycles):" % keyset.num_iterations
    print header
    prevvalue = 0
    prevstat = None
    for stat in markers:
      (valueavg, valuedev) = keyset.Statistics(stat)
      valuepct = int(100 * valuedev / valueavg + 0.5)
      if prevstat:
        (deltaavg, deltadev) = keyset.DeltaStatistics(prevstat, stat)
        deltapct = int(100 * deltadev / deltaavg + 0.5)
      else:
        deltapct = valuepct
      (valstring, val_printed) = keyset.PrintableStatistic(valueavg)
      delta = val_printed - prevvalue
      (deltastring, _) = keyset.PrintableStatistic(delta)
      print format % (valstring, valuepct, "+" + deltastring, deltapct, stat)
      prevvalue = val_printed
      prevstat = stat
    havedata = True
