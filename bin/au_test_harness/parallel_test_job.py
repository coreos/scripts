# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Module containing methods/classes related to running parallel test jobs."""

import sys
import threading
import time

import cros_build_lib as cros_lib

class ParallelJob(threading.Thread):
  """Small wrapper for threading.  Thread that releases a semaphores on exit."""

  def __init__(self, starting_semaphore, ending_semaphore, target, args):
    """Initializes an instance of a job.

    Args:
      starting_semaphore: Semaphore used by caller to wait on such that
        there isn't more than a certain number of threads running.  Should
        be initialized to a value for the number of threads wanting to be run
        at a time.
      ending_semaphore:  Semaphore is released every time a job ends.  Should be
        initialized to 0 before starting first job.  Should be acquired once for
        each job.  Threading.Thread.join() has a bug where if the run function
        terminates too quickly join() will hang forever.
      target:  The func to run.
      args:  Args to pass to the fun.
    """
    threading.Thread.__init__(self, target=target, args=args)
    self._target = target
    self._args = args
    self._starting_semaphore = starting_semaphore
    self._ending_semaphore = ending_semaphore
    self._output = None
    self._completed = False

  def run(self):
    """Thread override.  Runs the method specified and sets output."""
    try:
      self._output = self._target(*self._args)
    finally:
      # Our own clean up.
      self._Cleanup()
      self._completed = True
      # From threading.py to avoid a refcycle.
      del self._target, self._args

  def GetOutput(self):
    """Returns the output of the method run."""
    assert self._completed, 'GetOutput called before thread was run.'
    return self._output

  def _Cleanup(self):
    """Releases semaphores for a waiting caller."""
    self._starting_semaphore.release()
    self._ending_semaphore.release()

  def __str__(self):
    return '%s(%s)' % (self._target, self._args)


def RunParallelJobs(number_of_simultaneous_jobs, jobs, jobs_args,
                    print_status):
  """Runs set number of specified jobs in parallel.

  Args:
    number_of_simultaneous_jobs:  Max number of threads to be run in parallel.
    jobs:  Array of methods to run.
    jobs_args:  Array of args associated with method calls.
    print_status: True if you'd like this to print out .'s as it runs jobs.
  Returns:
    Returns an array of results corresponding to each thread.
  """
  def _TwoTupleize(x, y):
    return (x, y)

  threads = []
  job_start_semaphore = threading.Semaphore(number_of_simultaneous_jobs)
  join_semaphore = threading.Semaphore(0)
  assert len(jobs) == len(jobs_args), 'Length of args array is wrong.'

  # Create the parallel jobs.
  for job, args in map(_TwoTupleize, jobs, jobs_args):
    thread = ParallelJob(job_start_semaphore, join_semaphore, target=job,
                         args=args)
    threads.append(thread)

  # Cache sudo access.
  cros_lib.RunCommand(['sudo', 'echo', 'Caching sudo credentials'],
                      print_cmd=False, redirect_stdout=True,
                      redirect_stderr=True)

  # We use a semaphore to ensure we don't run more jobs than required.
  # After each thread finishes, it releases (increments semaphore).
  # Acquire blocks of num jobs reached and continues when a thread finishes.
  for next_thread in threads:
    job_start_semaphore.acquire(blocking=True)
    next_thread.start()

  # Wait on the rest of the threads to finish.
  for thread in threads:
    while not join_semaphore.acquire(blocking=False):
      time.sleep(5)
      if print_status:
        print >> sys.stderr, '.',

  return [thread.GetOutput() for thread in threads]
