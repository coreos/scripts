# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Classes and functions for managing platform_BootPerf results.

Results from the platform_BootPerf test in the ChromiumOS autotest
package are stored in as performance 'keyvals', that is, a mapping
of names to numeric values.  For each iteration of the test, one
set of keyvals is recorded.

This module currently tracks two kinds of keyval results, the boot
time results, and the disk read results.  These results are stored
with keyval names such as 'seconds_kernel_to_login' and
'rdbytes_kernel_to_login'.  Additionally, some older versions of the
test produced keyval names such as 'sectors_read_kernel_to_login'.
These keyvals record an accumulated total measured from a fixed
time in the past (kernel startup), e.g. 'seconds_kernel_to_login'
records the total seconds from kernel startup to login screen
ready.

The boot time keyval names all start with the prefix
'seconds_kernel_to_', and record time in seconds since kernel
startup.

The disk read keyval names all start with the prefix
'rdbytes_kernel_to_', and record bytes read from the boot device
since kernel startup.  The obsolete disk keyvals start with the
prefix 'sectors_read_kernel_to_' and record the same statistic
measured in 512-byte sectors.

Boot time and disk kevyal values have a consistent ordering
across iterations.  For instance, if in one iteration the value of
'seconds_kernel_to_login' is greater than the value of
'seconds_kernel_to_x_started', then it will be greater in *all*
iterations.  This property is a consequence of the underlying
measurement procedure; it is not enforced by this module.

"""

import math


def _ListStats(list_):
  # Utility function - calculate the average and (sample) standard
  # deviation of a list of numbers.  Result is float, even if the
  # input list is full of int's
  sum_ = 0.0
  sumsq = 0.0
  for v in list_:
    sum_ += v
    sumsq += v * v
  n = len(list_)
  avg = sum_ / n
  var = (sumsq - sum_ * avg) / (n - 1)
  if var < 0.0:
    var = 0.0
  dev = math.sqrt(var)
  return (avg, dev)


def _DoCheck(dict_):
  # Utility function - check the that all keyvals occur the same
  # number of times.  On success, return the number of occurrences;
  # on failure return None
  check = map(len, dict_.values())
  if not check:
    return None
  for i in range(1, len(check)):
    if check[i] != check[i-1]:
      return None
  return check[0]


def _KeyDelta(dict_, key0, key1):
  # Utility function - return a list of the vector difference between
  # two keyvals.
  return map(lambda a, b: b - a, dict_[key0], dict_[key1])


class TestResultSet(object):
  """A set of boot time and disk usage result statistics.

  Objects of this class consist of two sets of result statistics:
  the boot time statistics and the disk statistics.

  Class TestResultsSet does not interpret or store keyval mappings
  directly; iteration results are processed by attached _KeySet
  objects, one for boot time (`_timekeys`), one for disk read
  (`_diskkeys`).  These attached _KeySet objects can be obtained
  with appropriate methods; various methods on these objects will
  calculate statistics on the results, and provide the raw data.

  """

  def __init__(self, name):
    self.name = name
    self._timekeys = _TimeKeySet()
    self._diskkeys = _DiskKeySet()
    self._olddiskkeys = _OldDiskKeySet()

  def AddIterationResults(self, runkeys):
    """Add keyval results from a single iteration.

    A TestResultSet is constructed by repeatedly calling
    AddRunResults(), iteration by iteration.  Iteration results are
    passed in as a dictionary mapping keyval attributes to values.
    When all iteration results have been added, FinalizeResults()
    makes the results available for analysis.

    """

    self._timekeys.AddRunResults(runkeys)
    self._diskkeys.AddRunResults(runkeys)
    self._olddiskkeys.AddRunResults(runkeys)

  def FinalizeResults(self):
    """Make results available for analysis.

    A TestResultSet is constructed by repeatedly feeding it results,
    iteration by iteration.  Iteration results are passed in as a
    dictionary mapping keyval attributes to values.  When all iteration
    results have been added, FinalizeResults() makes the results
    available for analysis.

    """

    self._timekeys.FinalizeResults()
    if not self._diskkeys.FinalizeResults():
      self._olddiskkeys.FinalizeResults()
      self._diskkeys = self._olddiskkeys
    self._olddiskkeys = None

  def TimeKeySet(self):
    """Return the boot time statistics result set."""
    return self._timekeys

  def DiskKeySet(self):
    """Return the disk read statistics result set."""
    return self._diskkeys


class _KeySet(object):
  """Container for a set of related statistics.

  _KeySet is an abstract superclass for containing collections of
  either boot time or disk read statistics.  Statistics are stored
  as a dictionary (`_keyvals`) mapping keyval names to lists of
  values.

  The mapped keyval names are shortened by stripping the prefix
  that identifies the type of prefix (keyvals that don't start with
  the proper prefix are ignored).  So, for example, with boot time
  keyvals, 'seconds_kernel_to_login' becomes 'login' (and
  'rdbytes_kernel_to_login' is ignored).

  A list of all valid keyval names is stored in the `markers`
  instance variable.  The list is sorted by the natural ordering of
  the underlying values (see the module comments for more details).

  The list of values associated with a given keyval name are indexed
  in the order in which they were added.  So, all values for a given
  iteration are stored at the same index.

  """

  def __init__(self):
    self._keyvals = {}

  def AddRunResults(self, runkeys):
    """Add results for one iteration."""

    for key, value in runkeys.iteritems():
      if not key.startswith(self.PREFIX):
        continue
      shortkey = key[len(self.PREFIX):]
      keylist = self._keyvals.setdefault(shortkey, [])
      keylist.append(self._ConvertVal(value))

  def FinalizeResults(self):
    """Finalize this object's results.

    This method makes available the `markers` and `num_iterations`
    instance variables.  It also ensures that every keyval occurred
    in every iteration by requiring that all keyvals have the same
    number of data points.

    """

    count = _DoCheck(self._keyvals)
    if count is None:
      self.num_iterations = 0
      self.markers = []
      return False
    self.num_iterations = count
    keylist = map(lambda k: (self._keyvals[k][0], k),
                  self._keyvals.keys())
    keylist.sort(key=lambda tp: tp[0])
    self.markers = map(lambda tp: tp[1], keylist)
    return True

  def RawData(self, key):
    """Return the list of values for the given marker key."""
    return self._keyvals[key]

  def DeltaData(self, key0, key1):
    """Return vector difference of the values of the given keys."""
    return _KeyDelta(self._keyvals, key0, key1)

  def Statistics(self, key):
    """Return the average and standard deviation of the key's values."""
    return _ListStats(self._keyvals[key])

  def DeltaStatistics(self, key0, key1):
    """Return the average and standard deviation of the differences
    between two keys.

    """

    return _ListStats(self.DeltaData(key0, key1))


class _TimeKeySet(_KeySet):
  """Concrete subclass of _KeySet for boot time statistics."""

  # TIME_KEY_PREFIX = 'seconds_kernel_to_'
  PREFIX = 'seconds_kernel_to_'

  # Time-based keyvals are reported in seconds and get converted to
  # milliseconds
  TIME_SCALE = 1000

  def _ConvertVal(self, value):
    # We use a "round to nearest int" formula here to make sure we
    # don't lose anything in the conversion from decimal.
    return int(self.TIME_SCALE * float(value) + 0.5)

  def PrintableStatistic(self, value):
    v = int(value + 0.5)
    return ("%d" % v, v)


class _DiskKeySet(_KeySet):
  """Concrete subclass of _KeySet for disk read statistics."""

  PREFIX = 'rdbytes_kernel_to_'

  # Disk read keyvals are reported in bytes and get converted to
  # MBytes (1 MByte = 1 million bytes, not 2**20)
  DISK_SCALE = 1.0e-6

  def _ConvertVal(self, value):
    return self.DISK_SCALE * float(value)

  def PrintableStatistic(self, value):
    v = round(value, 1)
    return ("%.1fM" % v, v)


class _OldDiskKeySet(_DiskKeySet):
  """Concrete subclass of _KeySet for the old-style disk read statistics."""

  # Older versions of platform_BootPerf reported total sectors read
  # using names of the form sectors_read_kernel_to_* (instead of the
  # more recent rdbytes_kernel_to_*), but some of those names
  # exceeded the 30-character limit in the MySQL database schema.
  PREFIX = 'sectors_read_kernel_to_'

  # Old sytle disk read keyvals are reported in 512-byte sectors and
  # get converted to MBytes (1 MByte = 1 million bytes, not 2**20)
  SECTOR_SCALE = 512 * _DiskKeySet.DISK_SCALE

  def _ConvertVal(self, value):
    return self.SECTOR_SCALE * float(value)
