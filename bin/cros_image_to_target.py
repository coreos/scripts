#!/usr/bin/python
#
# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Create and copy update image to target host.

auto-update and devserver change out from beneath us often enough
that despite having to duplicate a litte code, it seems that the
right thing to do here is to start over and do something that is
simple enough and easy enough to understand so that when more
stuff breaks, at least we can solve them faster.
"""

import BaseHTTPServer
import cgi
import errno
import optparse
import os
import signal
import subprocess
import sys
import tempfile
import time
import traceback

path = os.path.realpath(__file__)
path = os.path.normpath(os.path.join(os.path.dirname(path), '..', '..',
                                     'platform'))
sys.path.insert(0, path)
del path

from dev import autoupdate_lib


# This is the default filename within the image directory to load updates from
DEFAULT_IMAGE_NAME = 'coreos_image.bin'
DEFAULT_IMAGE_NAME_TEST = 'coreos_test_image.bin'

# The filenames we provide to clients to pull updates
UPDATE_FILENAME = 'update.gz'
STATEFUL_FILENAME = 'stateful.tgz'

# How long do we wait for the server to start before launching client
SERVER_STARTUP_WAIT = 1


class Command(object):
  """Shell command ease-ups for Python."""

  def __init__(self, env):
    self.env = env

  def RunPipe(self, pipeline, infile=None, outfile=None,
              capture=False, oneline=False, hide_stderr=False):
    """
    Perform a command pipeline, with optional input/output filenames.

    hide_stderr     Don't allow output of stderr (default False)
    """

    last_pipe = None
    while pipeline:
      cmd = pipeline.pop(0)
      kwargs = {}
      if last_pipe is not None:
        kwargs['stdin'] = last_pipe.stdout
      elif infile:
        kwargs['stdin'] = open(infile, 'rb')
      if pipeline or capture:
        kwargs['stdout'] = subprocess.PIPE
      elif outfile:
        kwargs['stdout'] = open(outfile, 'wb')
      if hide_stderr:
        kwargs['stderr'] = open('/dev/null', 'wb')

      self.env.Debug('Running: %s' % ' '.join(cmd))
      last_pipe = subprocess.Popen(cmd, **kwargs)

    if capture:
      ret = last_pipe.communicate()[0]
      if not ret:
        return None
      elif oneline:
        return ret.rstrip('\r\n')
      else:
        return ret
    else:
      return os.waitpid(last_pipe.pid, 0)[1] == 0

  def Output(self, *cmd):
    return self.RunPipe([cmd], capture=True)

  def OutputOneLine(self, *cmd):
    return self.RunPipe([cmd], capture=True, oneline=True)

  def Run(self, *cmd, **kwargs):
    return self.RunPipe([cmd], **kwargs)


class SSHCommand(Command):
  """Remote shell commands."""

  CONNECT_TIMEOUT = 5

  def __init__(self, env, remote):
    Command.__init__(self, env)
    self.remote = remote
    self.ssh_dir = None
    self.identity = env.CrosUtilsPath('mod_for_test_scripts/ssh_keys/'
                                      'testing_rsa')

  def Setup(self):
    self.ssh_dir = tempfile.mkdtemp(prefix='ssh-tmp-')
    self.known_hosts = os.path.join(self.ssh_dir, 'known-hosts')

  def Cleanup(self):
    Command.RunPipe(self, [['rm', '-rf', self.ssh_dir]])
    self.ssh_dir = None

  def GetArgs(self):
    if not self.ssh_dir:
      self.Setup()

    return ['-o', 'Compression=no',
            '-o', 'ConnectTimeout=%d' % self.CONNECT_TIMEOUT,
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=%s' % self.known_hosts,
            '-i', self.identity]

  def RunPipe(self, pipeline, **kwargs):
    args = ['ssh'] + self.GetArgs()
    if 'remote_tunnel' in kwargs:
      ports = kwargs.pop('remote_tunnel')
      args += ['-R %d:localhost:%d' % ports]
    pipeline[0] = args + ['root@%s' % self.remote] + list(pipeline[0])
    return Command.RunPipe(self, pipeline, **kwargs)

  def Reset(self):
    os.unlink(self.known_hosts)

  def Copy(self, src, dest):
    return Command.RunPipe(self, [['scp'] + self.GetArgs() +
                                  [src, 'root@%s:%s' %
                                   (self.remote, dest)]])


class CrosEnv(object):
  """Encapsulates the ChromeOS build system environment functionality."""

  REBOOT_START_WAIT = 5
  REBOOT_WAIT_TIME = 180

  SILENT = 0
  INFO = 1
  DEBUG = 2

  def __init__(self, verbose=SILENT):
    self.cros_root = os.path.dirname(os.path.abspath(sys.argv[0]))
    parent = os.path.dirname(self.cros_root)
    if os.path.exists(os.path.join(parent, 'chromeos-common.sh')):
      self.cros_root = parent
    self.cmd = Command(self)
    self.verbose = verbose

    # do we have the pv progress tool? (sudo apt-get install pv)
    self.have_pv = True
    try:
      self.cmd.Output('pv', '--help')
    except OSError:
      self.have_pv = False

  def Error(self, msg):
    print >> sys.stderr, 'ERROR: %s' % msg

  def Fatal(self, msg=None):
    if msg:
      self.Error(msg)
    sys.exit(1)

  def Info(self, msg):
    if self.verbose >= CrosEnv.INFO:
      print 'INFO: %s' % msg

  def Debug(self, msg):
    if self.verbose >= CrosEnv.DEBUG:
      print 'DEBUG: %s' % msg

  def CrosUtilsPath(self, filename):
    return os.path.join(self.cros_root, filename)

  def ChrootPath(self, filename):
    if os.path.exists('/etc/debian_chroot'):
      return filename
    else:
      return self.CrosUtilsPath(os.path.join('..', '..', 'chroot',
                                             filename.strip(os.path.sep)))

  def FileOneLine(self, filename):
    return file(filename).read().rstrip('\r\n')

  def GetLatestImage(self, board):
    return self.cmd.OutputOneLine(self.CrosUtilsPath('get_latest_image.sh'),
                                  '--board=%s' % board)

  def GetCached(self, src, dst):
    return (os.path.exists(dst) and
            os.path.getmtime(dst) >= os.path.getmtime(src))

  def GenerateUpdatePayload(self, src, dst):
    """Generate an update image from a build-image output file."""

    if self.GetCached(src, dst):
      self.Info('Using cached update image %s' % dst)
      return True

    if not self.cmd.Run(self.ChrootPath('/usr/bin/cros_generate_update_payload'),
                        '--image=%s' % src, '--output=%s' % dst):
      self.Error('generate_payload failed')
      return False

    return True

  def BuildStateful(self, src, dst_dir, dst_file):
    """Create a stateful partition update image."""

    if self.GetCached(src, dst_file):
      self.Info('Using cached stateful %s' % dst_file)
      return True

    return self.cmd.Run(
        self.ChrootPath('/usr/bin/cros_generate_stateful_update_payload'),
        '--image=%s' % src, '--output=%s' % dst_dir)

  def GetSize(self, filename):
    return os.path.getsize(filename)

  def GetHash(self, filename):
    return self.cmd.RunPipe([['openssl', 'sha1', '-binary'],
                             ['openssl', 'base64']],
                            infile=filename,
                            capture=True, oneline=True)

  def GetSha256(self, filename):
    return self.cmd.RunPipe([['openssl', 'dgst', '-sha256', '-binary'],
                             ['openssl', 'base64']],
                            infile=filename,
                            capture=True, oneline=True)

  def GetDefaultBoard(self):
    def_board_file = self.CrosUtilsPath('.default_board')
    if not os.path.exists(def_board_file):
      return None
    return self.FileOneLine(def_board_file)

  def SetRemote(self, remote):
    self.ssh_cmd = SSHCommand(self, remote)

  def ParseShVars(self, string):
    """Parse an input file into a dict containing all variable assignments."""

    ret = {}
    for line in string.splitlines():
      if '=' in line:
        var, sep, val = line.partition('=')
        var = var.strip('\t ').rstrip('\t ')
        if var:
          ret[var] = val.strip('\t ').rstrip('\t ')
    return ret

  def GetRemoteRelease(self):
    lsb_release = self.ssh_cmd.Output('cat', '/etc/lsb-release')
    if not lsb_release:
      return None
    return self.ParseShVars(lsb_release)

  def CreateServer(self, ports, update_file, stateful_file):
    """Start the devserver clone."""

    PingUpdateResponse.Setup(self.GetHash(update_file),
                             self.GetSha256(update_file),
                             self.GetSize(update_file))

    UpdateHandler.SetupUrl('/update', PingUpdateResponse())
    UpdateHandler.SetupUrl('/%s' % UPDATE_FILENAME,
                           FileUpdateResponse(update_file,
                                              verbose=self.verbose,
                                              have_pv=self.have_pv))
    UpdateHandler.SetupUrl('/%s' % STATEFUL_FILENAME,
                           FileUpdateResponse(stateful_file,
                                              verbose=self.verbose,
                                              have_pv=self.have_pv))
    for port in ports:
      try:
        self.http_server = BaseHTTPServer.HTTPServer(('', port),
                                                     UpdateHandler)
        return port
      except :
        # NOP.  Select next port.
        continue
      return None

  def StartServer(self):
    self.Info('Starting http server')
    self.http_server.serve_forever()

  def GetUpdateStatus(self):
    status = self.ssh_cmd.Output('/usr/bin/update_engine_client', '--status')
    if not status:
      self.Error('Cannot get update status')
      return None

    return self.ParseShVars(status).get('CURRENT_OP', None)

  def ClientReboot(self):
    """Send "reboot" command to the client, and wait for it to return."""

    self.ssh_cmd.Reset()
    self.ssh_cmd.Run('reboot')
    self.Info('Waiting for client to reboot')
    time.sleep(self.REBOOT_START_WAIT)
    for attempt in range(self.REBOOT_WAIT_TIME / SSHCommand.CONNECT_TIMEOUT):
      start = time.time()
      if self.ssh_cmd.Run('/bin/true'):
        return True
      # Make sure we wait at least as long as the connect timeout would have,
      # since we calculated our number of attempts based on that
      self.Info('Client has not yet restarted (try %d).  Waiting...' % attempt)
      wait_time = SSHCommand.CONNECT_TIMEOUT - (time.time() - start)
      if wait_time > 0:
        time.sleep(wait_time)

    return False

  def StartClient(self, port):
    """Ask the client machine to update from our server."""

    self.Info("Starting client...")
    status = self.GetUpdateStatus()
    if status != 'UPDATE_STATUS_IDLE':
      self.Error('Client update status is not IDLE: %s' % status)
      return False

    url_base = 'http://localhost:%d' % port
    update_url = '%s/update' % url_base
    fd, update_log = tempfile.mkstemp(prefix='image-to-target-')
    self.Info('Starting update on client.  Client output stored to %s' %
              update_log)

    # this will make the client read the files we have set up
    self.ssh_cmd.Run('/usr/bin/update_engine_client', '--update',
                     '--omaha_url', update_url, remote_tunnel=(port, port),
                     outfile=update_log)

    if self.GetUpdateStatus() != 'UPDATE_STATUS_UPDATED_NEED_REBOOT':
      self.Error('Client update failed')
      return False

    self.Info('Update complete - running update script on client')
    self.ssh_cmd.Copy(self.ChrootPath('/usr/bin/stateful_update'),
                      '/tmp')
    if not self.ssh_cmd.Run('/tmp/stateful_update', url_base,
                            remote_tunnel=(port, port)):
      self.Error('Client stateful update failed')
      return False

    self.Info('Rebooting client')
    if not self.ClientReboot():
      self.Error('Client may not have successfully rebooted...')
      return False

    self.Info('Client update completed successfully!')
    return True


class UpdateResponse(object):
  """Default response is the 404 error response."""

  def Reply(self, handler, send_content=True, post_data=None):
    handler.send_error(404, 'File not found')
    return None


class FileUpdateResponse(UpdateResponse):
  """Respond by sending the contents of a file."""

  def __init__(self, filename, content_type='application/octet-stream',
               verbose=False, blocksize=16 * 1024, have_pv=False):
    self.filename = filename
    self.content_type = content_type
    self.verbose = verbose
    self.blocksize = blocksize
    self.have_pv = have_pv

  def Reply(self, handler, send_content=True, post_data=None):
    """Return file contents to the client.  Optionally display progress."""

    try:
      f = open(self.filename, 'rb')
    except IOError:
      return UpdateResponse.Reply(self, handler)

    handler.send_response(200)
    handler.send_header('Content-type', self.content_type)
    filestat = os.fstat(f.fileno())
    filesize = filestat[6]
    handler.send_header('Content-Length', str(filesize))
    handler.send_header('Last-Modified',
                        handler.date_time_string(filestat.st_mtime))
    handler.end_headers()

    if send_content:
      sent_size = 0
      sent_percentage = None

      #TODO(sjg): this should use pv also
      while True:
        buf = f.read(self.blocksize)
        if not buf:
          break
        handler.wfile.write(buf)
        if self.verbose:
          sent_size += len(buf)
          percentage = int(100 * sent_size / filesize)
          if sent_percentage != percentage:
            sent_percentage = percentage
            print '\rSent %d%%' % sent_percentage,
            sys.stdout.flush()
      if self.verbose:
        print '\n'
    f.close()


class StringUpdateResponse(UpdateResponse):
  """Respond by sending the contents of a string."""

  def __init__(self, string, content_type='text/plain'):
    self.string = string
    self.content_type = content_type

  def Reply(self, handler, send_content=True, post_data=None):
    handler.send_response(200)
    handler.send_header('Content-type', self.content_type)
    handler.send_header('Content-Length', len(self.string))
    handler.end_headers()

    if not send_content:
      return

    handler.wfile.write(self.string)


class PingUpdateResponse(StringUpdateResponse):
  """Respond to a client ping with pre-fab XML response."""

  def __init__(self):
    self.content_type = 'text/xml'

  @staticmethod
  def Setup(filehash, filesha256, filesize):
    PingUpdateResponse.file_hash = filehash
    PingUpdateResponse.file_sha256 = filesha256
    PingUpdateResponse.file_size = filesize

  def Reply(self, handler, send_content=True, post_data=None):
    """Return (using StringResponse) an XML reply to ForcedUpdate clients."""

    if not post_data:
      return UpdateResponse.Reply(self, handler)

    protocol, app, _, _ = autoupdate_lib.ParseUpdateRequest(post_data)
    request_version = app.getAttribute('version')
    if request_version == 'ForcedUpdate':
      host, pdict = cgi.parse_header(handler.headers.getheader('Host'))
      url = 'http://%s/%s' % (host, UPDATE_FILENAME)
      self.string = autoupdate_lib.GetUpdateResponse(self.file_hash,
                                                     self.file_sha256,
                                                     self.file_size,
                                                     url,
                                                     False,
                                                     protocol)
    else:
      self.string = (autoupdate_lib.GetNoUpdateResponse(protocol))

    StringUpdateResponse.Reply(self, handler, send_content)


class UpdateHandler(BaseHTTPServer.BaseHTTPRequestHandler):
  """Handler for HTTP requests to devserver clone."""

  server_version = 'ImageToTargetUpdater/0.0'
  url_mapping = {}

  @staticmethod
  def SetupUrl(url, response):
    UpdateHandler.url_mapping[url] = response

  def do_GET(self):
    """Serve a GET request."""
    response = UpdateHandler.url_mapping.get(self.path, UpdateResponse())
    response.Reply(self, True)

  def do_HEAD(self):
    """Serve a HEAD request."""
    response = UpdateHandler.url_mapping.get(self.path, UpdateResponse())
    response.Reply(self, False)

  def do_POST(self):
    content_length = int(self.headers.getheader('Content-Length'))
    request = self.rfile.read(content_length)
    response = UpdateHandler.url_mapping.get(self.path, UpdateResponse())
    response.Reply(self, True, request)


class ChildFinished(Exception):
  """Child exit exception."""

  def __init__(self, pid):
    Exception.__init__(self)
    self.pid = pid
    self.status = None

  def __str__(self):
    return 'Process %d exited status %d' % (self.pid, self.status)

  def __nonzero__(self):
    return self.status is not None

  def SigHandler(self, signum, frame):
    """Handle SIGCHLD signal, and retreive client exit code."""

    while True:
      try:
        (pid, status) = os.waitpid(-1, os.WNOHANG)
      except OSError, e:
        if e.args[0] != errno.ECHILD:
          raise e

        # TODO(pstew): returning here won't help -- SocketServer gets EINTR
        return

      if pid == self.pid:
        if os.WIFEXITED(status):
          self.status = os.WEXITSTATUS(status)
        else:
          self.status = 255
        raise self

def MakePortList(user_supplied_port):
  range_start = user_supplied_port or 8082
  if user_supplied_port is not None:
    range_length = 1
  else:
    range_length = 10
  return range(range_start, range_start + range_length, 1)

def main(argv):
  usage = 'usage: %prog [options]'
  parser = optparse.OptionParser(usage=usage)
  parser.add_option('--board', dest='board', default=None,
                    help='Board platform type')
  parser.add_option('--force-mismatch', dest='force_mismatch', default=False,
                    action='store_true',
                    help='Upgrade even if client arch does not match')
  parser.add_option('--from', dest='src', default=None,
                    help='Source image to install')
  parser.add_option('--image-name', dest='image_name',
                    help='Filename within image directory to load')
  parser.add_option('--port', dest='port', type='int',
                    help='TCP port to serve from and tunnel through')
  parser.add_option('--remote', dest='remote', default=None,
                    help='Remote device-under-test IP address')
  parser.add_option('--server-only', dest='server_only', default=False,
                    action='store_true', help='Do not start client')
  parser.add_option('--verbose', dest='verbose', default=False,
                    action='store_true', help='Display progress')
  parser.add_option('--debug', dest='debug', default=False,
                    action='store_true', help='Display running commands')
  parser.add_option('--test', dest='test', default=True,
                    action='store_true', help='Select test image')
  parser.add_option('--no-test', dest='test',
                    action='store_false', help='Select non-test image')

  (options, args) = parser.parse_args(argv)

  verbosity = CrosEnv.SILENT
  if options.verbose:
      verbosity = CrosEnv.INFO
  if options.debug:
      verbosity = CrosEnv.DEBUG
  cros_env = CrosEnv(verbose=verbosity)

  if not options.board:
    options.board = cros_env.GetDefaultBoard()

  if options.remote:
    cros_env.Info('Contacting client %s' % options.remote)
    cros_env.SetRemote(options.remote)
    rel = cros_env.GetRemoteRelease()
    if not rel:
      cros_env.Fatal('Could not retrieve remote lsb-release')
    board = rel.get('CHROMEOS_RELEASE_BOARD', '(None)')
    if not options.board:
      options.board = board
    elif board != options.board and not options.force_mismatch:
      cros_env.Error('Board %s does not match expected %s' %
                     (board, options.board))
      cros_env.Error('(Use --force-mismatch option to override this)')
      cros_env.Fatal()

  elif not options.server_only:
    parser.error('Either --server-only must be specified or '
                 '--remote=<client> needs to be given')

  if not options.src:
    options.src = cros_env.GetLatestImage(options.board)
    if options.src is None:
      parser.error('No --from argument given and no default image found')

  cros_env.Info('Performing update from %s' % options.src)

  if not os.path.exists(options.src):
    parser.error('Path %s does not exist' % options.src)

  if not options.image_name:
    # auto-select the correct image
    if options.test:
      options.image_name = DEFAULT_IMAGE_NAME_TEST
    else:
      options.image_name = DEFAULT_IMAGE_NAME

  if os.path.isdir(options.src):
    image_directory = options.src
    image_file = os.path.join(options.src, options.image_name)

    if not os.path.exists(image_file):
      parser.error('Image file %s does not exist' % image_file)
  else:
    image_file = options.src
    image_directory = os.path.dirname(options.src)

  update_file = os.path.join(image_directory, UPDATE_FILENAME)
  stateful_file = os.path.join(image_directory, STATEFUL_FILENAME)

  cros_env.Debug("Image file %s" % image_file)
  cros_env.Debug("Update file %s" % update_file)
  cros_env.Debug("Stateful file %s" % stateful_file)

  if (not cros_env.GenerateUpdatePayload(image_file, update_file) or
      not cros_env.BuildStateful(image_file, image_directory, stateful_file)):
    cros_env.Fatal()

  port = cros_env.CreateServer(MakePortList(options.port),
                               update_file, stateful_file)
  if port is None:
    cros_env.Fatal('Unable to find a port for CreateServer.')

  exit_status = 1
  if options.server_only:
    child = None
  else:
    # Start an "image-to-live" instance that will pull bits from the server
    child = os.fork()
    if child:
      signal.signal(signal.SIGCHLD, ChildFinished(child).SigHandler)
    else:
      try:
        time.sleep(SERVER_STARTUP_WAIT)
        cros_env.ssh_cmd.Run('start', 'update-engine', hide_stderr=True)
        if cros_env.StartClient(port):
          exit_status = 0
      except KeyboardInterrupt:
        cros_env.Error('Client Exiting on Control-C')
      except:
        cros_env.Error('Exception in client code:')
        traceback.print_exc(file=sys.stdout)

      cros_env.ssh_cmd.Cleanup()
      cros_env.Info('Client exiting with status %d' % exit_status)
      sys.exit(exit_status)

  try:
    cros_env.StartServer()
  except KeyboardInterrupt:
    cros_env.Info('Server Exiting on Control-C')
    exit_status = 0
  except ChildFinished, e:
    cros_env.Info('Server Exiting on Client Exit (%d)' % e.status)
    exit_status = e.status
    child = None
  except:
    cros_env.Error('Exception in server code:')
    traceback.print_exc(file=sys.stdout)

  if child:
    os.kill(child, 15)

  cros_env.Info('Server exiting with status %d' % exit_status)
  sys.exit(exit_status)


if __name__ == '__main__':
  main(sys.argv)
