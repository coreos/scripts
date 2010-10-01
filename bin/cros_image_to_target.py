#!/usr/bin/python
#
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
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

from xml.dom import minidom


# This is the default filename within the image directory to load updates from
DEFAULT_IMAGE_NAME = 'chromiumos_image.bin'

# The filenames we provide to clients to pull updates
UPDATE_FILENAME = 'update.gz'
STATEFUL_FILENAME = 'stateful.image.gz'

# How long do we wait for the server to start before launching client
SERVER_STARTUP_WAIT = 1


class Command(object):
  """Shell command ease-ups for Python."""

  def __init__(self, env):
    self.env = env

  def RunPipe(self, pipeline, infile=None, outfile=None,
              capture=False, oneline=False):
    """Perform a command pipeline, with optional input/output filenames."""

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

      self.env.Info('Running: %s' % ' '.join(cmd))
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
  REBOOT_WAIT_TIME = 60

  def __init__(self, verbose=False):
    self.cros_root = os.path.dirname(os.path.abspath(sys.argv[0]))
    parent = os.path.dirname(self.cros_root)
    if os.path.exists(os.path.join(parent, 'chromeos-common.sh')):
      self.cros_root = parent
    self.cmd = Command(self)
    self.verbose = verbose

  def Error(self, msg):
    print >> sys.stderr, 'ERROR: %s' % msg

  def Fatal(self, msg=None):
    if msg:
      self.Error(msg)
    sys.exit(1)

  def Info(self, msg):
    if self.verbose:
      print 'INFO: %s' % msg

  def CrosUtilsPath(self, filename):
    return os.path.join(self.cros_root, filename)

  def ChrootPath(self, filename):
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

    if not self.cmd.Run(self.CrosUtilsPath('cros_generate_update_payload'),
                        '--image=%s' % src, '--output=%s' % dst,
                        '--patch_kernel'):
      self.Error('generate_payload failed')
      return False

    return True

  def BuildStateful(self, src, dst):
    """Create a stateful partition update image."""

    if self.GetCached(src, dst):
      self.Info('Using cached stateful %s' % dst)
      return True

    cgpt = self.ChrootPath('/usr/bin/cgpt')
    offset = self.cmd.OutputOneLine(cgpt, 'show', '-b', '-i', '1', src)
    size = self.cmd.OutputOneLine(cgpt, 'show', '-s', '-i', '1', src)
    if None in (size, offset):
      self.Error('Unable to use cgpt to get image geometry')
      return False

    return self.cmd.RunPipe([['dd', 'if=%s' % src, 'bs=512',
                              'skip=%s' % offset, 'count=%s' % size],
                             ['gzip', '-c']], outfile=dst)

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

  def CreateServer(self, port, update_file, stateful_file):
    """Start the devserver clone."""

    PingUpdateResponse.Setup(self.GetHash(update_file),
                             self.GetSha256(update_file),
                             self.GetSize(update_file))

    UpdateHandler.SetupUrl('/update', PingUpdateResponse())
    UpdateHandler.SetupUrl('/%s' % UPDATE_FILENAME,
                           FileUpdateResponse(update_file,
                                              verbose=self.verbose))
    UpdateHandler.SetupUrl('/%s' % STATEFUL_FILENAME,
                           FileUpdateResponse(stateful_file,
                                              verbose=self.verbose))

    self.http_server = BaseHTTPServer.HTTPServer(('', port), UpdateHandler)

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
    for attempt in range(self.REBOOT_WAIT_TIME/SSHCommand.CONNECT_TIMEOUT):
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

    status = self.GetUpdateStatus()
    if status != 'UPDATE_STATUS_IDLE':
      self.Error('Client update status is not IDLE: %s' % status)
      return False

    url_base = 'http://localhost:%d' % port
    update_url = '%s/update' % url_base
    fd, update_log = tempfile.mkstemp(prefix='image-to-target-')
    self.Info('Starting update on client.  Client output stored to %s' %
              update_log)
    self.ssh_cmd.Run('/usr/bin/update_engine_client', '--update',
                     '--omaha_url', update_url, remote_tunnel=(port, port),
                     outfile=update_log)

    if self.GetUpdateStatus() != 'UPDATE_STATUS_UPDATED_NEED_REBOOT':
      self.Error('Client update failed')
      return False

    self.ssh_cmd.Copy(self.CrosUtilsPath('../platform/dev/stateful_update'),
                      '/tmp')
    if not self.ssh_cmd.Run('/tmp/stateful_update', url_base,
                            remote_tunnel=(port, port)):
      self.Error('Client stateful update failed')
      return False

    self.Info('Rebooting client')
    if not self.ClientReboot():
      self.Error('Client may not have successfully rebooted...')
      return False

    print 'Client update completed successfully!'
    return True


class UpdateResponse(object):
  """Default response is the 404 error response."""

  def Reply(self, handler, send_content=True, post_data=None):
    handler.send_Error(404, 'File not found')
    return None


class FileUpdateResponse(UpdateResponse):
  """Respond by sending the contents of a file."""

  def __init__(self, filename, content_type='application/octet-stream',
               verbose=False, blocksize=16*1024):
    self.filename = filename
    self.content_type = content_type
    self.verbose = verbose
    self.blocksize = blocksize

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

    if not send_content:
      return

    if filesize <= self.blocksize:
      handler.wfile.write(f.read())
    else:
      sent_size = 0
      sent_percentage = None
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

  app_id = '87efface-864d-49a5-9bb3-4b050a7c227a'
  xmlns = 'http://www.google.com/update2/response'
  payload_success_template = """<?xml version="1.0" encoding="UTF-8"?>
    <gupdate xmlns="%s" protocol="2.0">
    <daystart elapsed_seconds="%s"/>
    <app appid="{%s}" status="ok">
      <ping status="ok"/>
      <updatecheck
      codebase="%s"
      hash="%s"
      sha256="%s"
      needsadmin="false"
      size="%s"
      status="ok"/>
    </app>
    </gupdate>
  """
  payload_failure_template = """<?xml version="1.0" encoding="UTF-8"?>
      <gupdate xmlns="%s" protocol="2.0">
        <daystart elapsed_seconds="%s"/>
        <app appid="{%s}" status="ok">
          <ping status="ok"/>
          <updatecheck status="noupdate"/>
        </app>
      </gupdate>
    """

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

    request_version = (minidom.parseString(post_data).firstChild.
                       getElementsByTagName('o:app')[0].
                       getAttribute('version'))

    if request_version == 'ForcedUpdate':
      host, pdict = cgi.parse_header(handler.headers.getheader('Host'))
      self.string = (self.payload_success_template %
                     (self.xmlns, self.SecondsSinceMidnight(),
                      self.app_id, 'http://%s/%s' % (host, UPDATE_FILENAME),
                      self.file_hash, self.file_sha256, self.file_size))
    else:
      self.string = (self.payload_failure_template %
                     (self.xmlns, self.SecondsSinceMidnight(), self.app_id))

    StringUpdateResponse.Reply(self, handler, send_content)

  def SecondsSinceMidnight(self):
    now = time.localtime()
    return now[3] * 3600 + now[4] * 60 + now[5]


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
                    default=DEFAULT_IMAGE_NAME,
                    help='Filename within image directory to load')
  parser.add_option('--port', dest='port', default=8081, type='int',
                    help='TCP port to serve from and tunnel through')
  parser.add_option('--remote', dest='remote', default=None,
                    help='Remote device-under-test IP address')
  parser.add_option('--server-only', dest='server_only', default=False,
                    action='store_true', help='Do not start client')
  parser.add_option('--verbose', dest='verbose', default=False,
                    action='store_true', help='Display running commands')

  (options, args) = parser.parse_args(argv)

  cros_env = CrosEnv(verbose=options.verbose)

  if not options.board:
    options.board = cros_env.GetDefaultBoard()

  if not options.src:
    options.src = cros_env.GetLatestImage(options.board)
    if options.src is None:
      parser.error('No --from argument given and no default image found')

  cros_env.Info('Performing update from %s' % options.src)

  if not os.path.exists(options.src):
    parser.error('Path %s does not exist' % options.src)

  if os.path.isdir(options.src):
    image_directory = options.src
    image_file = os.path.join(options.src, options.image_name)

    if not os.path.exists(image_file):
      parser.error('Image file %s does not exist' % image_file)
  else:
    image_file = options.src
    image_directory = os.path.dirname(options.src)

  if options.remote:
    cros_env.SetRemote(options.remote)
    rel = cros_env.GetRemoteRelease()
    if not rel:
      cros_env.Fatal('Could not retrieve remote lsb-release')
    board = rel.get('CHROMEOS_RELEASE_BOARD', '(None)')
    if board != options.board and not options.force_mismatch:
      cros_env.Error('Board %s does not match expected %s' %
                     (board, options.board))
      cros_env.Error('(Use --force-mismatch option to override this)')
      cros_env.Fatal()

  elif not options.server_only:
    parser.error('Either --server-only must be specified or '
                 '--remote=<client> needs to be given')

  update_file = os.path.join(image_directory, UPDATE_FILENAME)
  stateful_file = os.path.join(image_directory, STATEFUL_FILENAME)

  if (not cros_env.GenerateUpdatePayload(image_file, update_file) or
      not cros_env.BuildStateful(image_file, stateful_file)):
    cros_env.Fatal()

  cros_env.CreateServer(options.port, update_file, stateful_file)

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
        if cros_env.StartClient(options.port):
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
