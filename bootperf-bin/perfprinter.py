# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Routines for printing boot time performance test results."""

import fnmatch
import os
import os.path
import re


def PrintRawData(reader, dirlist, use_timestats, keylist):
  """Print 'bootperf' results in "raw data" format."""
  for dir_ in dirlist:
    results = reader(dir_)
    if use_timestats:
      keyset = results.TimeKeySet()
    else:
      keyset = results.DiskKeySet()
    for i in range(0, keyset.num_iterations):
      if len(dirlist) > 1:
        line = "%s %3d" % (results.name, i)
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


def PrintStatisticsSummary(reader, dirlist, use_timestats, keylist):
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
    results = reader(dir_)
    if use_timestats:
      keyset = results.TimeKeySet()
    else:
      keyset = results.DiskKeySet()
    if keylist is not None:
      markers = keylist
    else:
      markers = keyset.markers
    if havedata:
      print
    if len(dirlist) > 1:
      print "%s" % results.name,
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
