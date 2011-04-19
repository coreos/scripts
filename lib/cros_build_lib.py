# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Common python commands used by various build scripts."""

import inspect
import os
import re
import subprocess
import sys

_STDOUT_IS_TTY = hasattr(sys.stdout, 'isatty') and sys.stdout.isatty()

# TODO(sosa):  Move logging to logging module.

class RunCommandException(Exception):
  """Raised when there is an error in RunCommand."""
  pass


def GetCallerName():
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
  if enter_chroot:  cmd = ['./enter_chroot.sh', '--'] + cmd

  # Print out the command before running.
  cmd_string = 'PROGRAM(%s) -> RunCommand: %r in dir %s' % (GetCallerName(),
                                                            cmd, cwd)
  if print_cmd:
    if not log_to_file:
      Info(cmd_string)
    else:
      Info('%s -- Logging to %s' % (cmd_string, log_to_file))

  for retry_count in range(num_retries + 1):

    # If it's not the first attempt, it's a retry
    if retry_count > 0 and print_cmd:
      Info('PROGRAM(%s) -> RunCommand: retrying %r in dir %s' %
           (GetCallerName(), cmd, cwd))

    proc = subprocess.Popen(cmd, cwd=cwd, stdin=stdin,
                            stdout=stdout, stderr=stderr)
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
    error_info = ('Command "%r" failed.\n' % (cmd) +
                  (error_message or error or output or ''))
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

  if enter_chroot:  cmd = ['./enter_chroot.sh', '--'] + cmd

  # Print out the command before running.
  if print_cmd:
    Info('PROGRAM(%s) -> RunCommand: %r in dir %s' %
         (GetCallerName(), cmd, cwd))

  proc = subprocess.Popen(cmd, cwd=cwd, stdin=stdin,
                          stdout=stdout, stderr=stderr)
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


def Die(message):
  """Emits a red error message and halts execution.

  Keyword arguments:
    message: The message to be emitted before exiting.
  """
  print >> sys.stderr, (
      Color(_STDOUT_IS_TTY).Color(Color.RED, '\nERROR: ' + message))
  sys.stderr.flush()
  sys.exit(1)


def Warning(message):
  """Emits a yellow warning message and continues execution.

  Keyword arguments:
    message: The message to be emitted.
  """
  print >> sys.stderr, (
      Color(_STDOUT_IS_TTY).Color(Color.YELLOW, '\nWARNING: ' + message))
  sys.stderr.flush()


def Info(message):
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


def ReinterpretPathForChroot(path):
  """Returns reinterpreted path from outside the chroot for use inside.

  Keyword arguments:
    path: The path to reinterpret.  Must be in src tree.
  """
  root_path = os.path.join(FindRepoDir(path), '..')

  path_abs_path = os.path.abspath(path)
  root_abs_path = os.path.abspath(root_path)

  # Strip the repository root from the path and strip first /.
  relative_path = path_abs_path.replace(root_abs_path, '')[1:]

  if relative_path == path_abs_path:
    raise Exception('Error: path is outside your src tree, cannot reinterpret.')

  new_path = os.path.join('/home', os.getenv('USER'), 'trunk', relative_path)
  return new_path


def PrependChrootPath(path):
  """Assumes path is a chroot path and prepends chroot to create full path."""
  chroot_path = os.path.join(FindRepoDir(), '..', 'chroot')
  if path.startswith('/'):
    return os.path.realpath(os.path.join(chroot_path, path[1:]))
  else:
    return os.path.realpath(os.path.join(chroot_path, path))


def GetIPAddress(device='eth0'):
  """Returns the IP Address for a given device using ifconfig.

  socket.gethostname() is insufficient for machines where the host files are
  not set up "correctly."  Since some of our builders may have this issue,
  this method gives you a generic way to get the address so you are reachable
  either via a VM or remote machine on the same network.
  """
  ifconfig_output = RunCommand(['/sbin/ifconfig', device],
                               redirect_stdout=True, print_cmd=False)
  match = re.search('.*inet addr:(\d+\.\d+\.\d+\.\d+).*', ifconfig_output)
  if match:
    return match.group(1)
  else:
    Warning('Failed to find ip address in %s' % ifconfig_output)
    return None


def MountImage(image_path, root_dir, stateful_dir, read_only):
  """Mounts a Chromium OS image onto mount dir points."""
  from_dir = os.path.dirname(image_path)
  image = os.path.basename(image_path)
  extra_args = []
  if read_only: extra_args.append('--read_only')
  cmd = ['./mount_gpt_image.sh',
         '--from=%s' % from_dir,
         '--image=%s' % image,
         '--rootfs_mountpt=%s' % root_dir,
         '--stateful_mountpt=%s' % stateful_dir,
        ]
  cmd.extend(extra_args)
  RunCommand(cmd, print_cmd=False, redirect_stdout=True, redirect_stderr=True,
             cwd=CROSUTILS_DIRECTORY)


def UnmountImage(root_dir, stateful_dir):
  """Unmounts a Chromium OS image specified by mount dir points."""
  RunCommand(['./mount_gpt_image.sh',
              '--unmount',
              '--rootfs_mountpt=%s' % root_dir,
              '--stateful_mountpt=%s' % stateful_dir,
             ], print_cmd=False, redirect_stdout=True, redirect_stderr=True,
             cwd=CROSUTILS_DIRECTORY)


def GetCrosUtilsPath(source_dir_path=True):
  """Return the path to src/scripts.

  Args:
    source_dir_path:  If True, returns the path from the source code directory.
  """
  if IsInsideChroot():
    if source_dir_path:
      return os.path.join(os.getenv('HOME'), 'trunk', 'src', 'scripts')

    return os.path.join('/usr/lib/crosutils')

  # Outside the chroot => from_source.
  return os.path.join(os.path.dirname(os.path.realpath(__file__)), '..')


def GetCrosUtilsBinPath(source_dir_path=True):
  """Return the path to crosutils/bin.

  Args:
    source_dir_path:  If True, returns the path from the source code directory.
  """
  if IsInsideChroot() and not source_dir_path:
      return '/usr/bin'

  return os.path.join(GetCrosUtilsPath(source_dir_path), 'bin')


def IsInsideChroot():
  """Returns True if we are inside chroot."""
  return os.path.exists('/etc/debian_chroot')


# TODO(sosa): Remove once all callers use method.
CROSUTILS_DIRECTORY = GetCrosUtilsPath(True)
