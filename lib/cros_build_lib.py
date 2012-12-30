# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Common python commands used by various build scripts."""

import inspect
import os
import subprocess
import sys

_STDOUT_IS_TTY = hasattr(sys.stdout, 'isatty') and sys.stdout.isatty()

# TODO(sosa):  Move logging to logging module.

class RunCommandException(Exception):
  """Raised when there is an error in RunCommand."""
  pass


def _GetCallerName():
  """Returns the name of the calling module with __main__."""
  top_frame = inspect.stack()[-1][0]
  return os.path.basename(top_frame.f_code.co_filename)


def RunCommand(cmd, print_cmd=True, error_ok=False, error_message=None,
               exit_code=False, redirect_stdout=False, redirect_stderr=False,
               cwd=None, input=None, enter_chroot=False, num_retries=0,
               log_to_file=None, combine_stdout_stderr=False):
  """Runs a shell command.

  Arguments:
    cmd: cmd to run.  Should be input to subprocess.POpen.  If a string,
      converted to an array using split().
    print_cmd: prints the command before running it.
    error_ok: does not raise an exception on error.
    error_message: prints out this message when an error occurrs.
    exit_code: returns the return code of the shell command.
    redirect_stdout: returns the stdout.
    redirect_stderr: holds stderr output until input is communicated.
    cwd: the working directory to run this cmd.
    input: input to pipe into this command through stdin.
    enter_chroot: this command should be run from within the chroot.  If set,
      cwd must point to the scripts directory.
    num_retries: the number of retries to perform before dying
    log_to_file: Redirects all stderr and stdout to file specified by this path.
    combine_stdout_stderr: Combines stdout and stdin streams into stdout. Auto
      set to true if log_to_file specifies a file.

  Returns:
    If exit_code is True, returns the return code of the shell command.
    Else returns the output of the shell command.

  Raises:
    Exception:  Raises RunCommandException on error with optional error_message,

                but only if exit_code, and error_ok are both False. 
  """
  # Set default for variables.
  stdout = None
  stderr = None
  stdin = None
  file_handle = None
  output = ''

  # Modify defaults based on parameters.
  if log_to_file:
    file_handle = open(log_to_file, 'w+')
    stdout = file_handle
    stderr = file_handle
  else:
    if redirect_stdout:  stdout = subprocess.PIPE
    if redirect_stderr:  stderr = subprocess.PIPE
    if combine_stdout_stderr: stderr = subprocess.STDOUT

  if input:  stdin = subprocess.PIPE
  if enter_chroot:  cmd = ['cros_sdk', '--'] + cmd

  # Print out the command before running.
  cmd_string = 'PROGRAM(%s) -> RunCommand: %r in dir %s' % (_GetCallerName(),
                                                            cmd, cwd)
  if print_cmd:
    if not log_to_file:
      _Info(cmd_string)
    else:
      _Info('%s -- Logging to %s' % (cmd_string, log_to_file))

  for retry_count in range(num_retries + 1):

    # If it's not the first attempt, it's a retry
    if retry_count > 0 and print_cmd:
      _Info('PROGRAM(%s) -> RunCommand: retrying %r in dir %s' %
            (_GetCallerName(), cmd, cwd))

    proc = subprocess.Popen(cmd, cwd=cwd, stdin=stdin,
                            stdout=stdout, stderr=stderr, close_fds=True)
    (output, error) = proc.communicate(input)

    # if the command worked, don't retry any more.
    if proc.returncode == 0:
      break

  if file_handle: file_handle.close()

  # If they asked for an exit_code, give it to them on success or failure
  if exit_code:
    return proc.returncode

  # If the command (and all retries) failed, handle error result
  if proc.returncode != 0 and not error_ok:
    if output:
      print >> sys.stderr, output
      sys.stderr.flush()

    error_info = ('Command "%r" failed.\n' % (cmd) +
                  (error_message or error or ''))
    if log_to_file: error_info += '\nOutput logged to %s' % log_to_file
    raise RunCommandException(error_info)

  # return final result
  return output


def RunCommandCaptureOutput(cmd, print_cmd=True, cwd=None, input=None,
                            enter_chroot=False,
                            combine_stdout_stderr=True,
                            verbose=False):
  """Runs a shell command. Differs from RunCommand, because it allows
     you to run a command and capture the exit code, output, and stderr
     all at the same time.

  Arguments:
    cmd: cmd to run.  Should be input to subprocess.POpen.  If a string,
      converted to an array using split().
    print_cmd: prints the command before running it.
    cwd: the working directory to run this cmd.
    input: input to pipe into this command through stdin.
    enter_chroot: this command should be run from within the chroot.  If set,
      cwd must point to the scripts directory.
    combine_stdout_stderr -- combine outputs together.
    verbose -- also echo cmd.stdout and cmd.stderr to stdout and stderr

  Returns:
    Returns a tuple: (exit_code, stdout, stderr) (integer, string, string)
    stderr is None if combine_stdout_stderr is True
  """
  # Set default for variables.
  stdout = subprocess.PIPE
  stderr = subprocess.PIPE
  stdin = None

  # Modify defaults based on parameters.
  if input:  stdin = subprocess.PIPE
  if combine_stdout_stderr: stderr = subprocess.STDOUT

  if enter_chroot:  cmd = ['cros_sdk', '--'] + cmd

  # Print out the command before running.
  if print_cmd:
    _Info('PROGRAM(%s) -> RunCommand: %r in dir %s' %
          (_GetCallerName(), cmd, cwd))

  proc = subprocess.Popen(cmd, cwd=cwd, stdin=stdin,
                          stdout=stdout, stderr=stderr, close_fds=True)
  output, error = proc.communicate(input)

  if verbose:
    if output: sys.stdout.write(output)
    if error: sys.stderr.write(error)

  # Error is None if stdout, stderr are combined.
  return proc.returncode, output, error


class Color(object):
  """Conditionally wraps text in ANSI color escape sequences."""
  BLACK, RED, GREEN, YELLOW, BLUE, MAGENTA, CYAN, WHITE = range(8)
  BOLD = -1
  COLOR_START = '\033[1;%dm'
  BOLD_START = '\033[1m'
  RESET = '\033[0m'

  def __init__(self, enabled=True):
    self._enabled = enabled

  def Color(self, color, text):
    """Returns text with conditionally added color escape sequences.

    Keyword arguments:
      color: Text color -- one of the color constants defined in this class.
      text: The text to color.

    Returns:
      If self._enabled is False, returns the original text. If it's True,
      returns text with color escape sequences based on the value of color.
    """
    if not self._enabled:
      return text
    if color == self.BOLD:
      start = self.BOLD_START
    else:
      start = self.COLOR_START % (color + 30)
    return start + text + self.RESET


def _Info(message):
  """Emits a blue informational message and continues execution.

  Keyword arguments:
    message: The message to be emitted.
  """
  print >> sys.stderr, (
      Color(_STDOUT_IS_TTY).Color(Color.BLUE, '\nINFO: ' + message))
  sys.stderr.flush()


def FindRepoDir(path=None):
  """Returns the nearest higher-level repo dir from the specified path.

  Args:
    path: The path to use. Defaults to cwd.
  """
  if path is None:
    path = os.getcwd()
  path = os.path.abspath(path)
  while path != '/':
    repo_dir = os.path.join(path, '.repo')
    if os.path.isdir(repo_dir):
      return repo_dir
    path = os.path.dirname(path)
  return None


def PrependChrootPath(path):
  """Assumes path is a chroot path and prepends chroot to create full path."""
  chroot_path = os.path.join(FindRepoDir(), '..', 'chroot')
  if path.startswith('/'):
    return os.path.realpath(os.path.join(chroot_path, path[1:]))
  else:
    return os.path.realpath(os.path.join(chroot_path, path))


def IsInsideChroot():
  """Returns True if we are inside chroot."""
  return os.path.exists('/etc/debian_chroot')
