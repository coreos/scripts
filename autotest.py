# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# A python wrapper to call autotest ebuild.
#
# DO NOT CALL THIS SCRIPT DIRECTLY, CALL src/scripts/autotest INSTEAD.

import logging, optparse, os, subprocess, sys


def run(cmd):
  return subprocess.call(cmd, stdout=sys.stdout, stderr=sys.stderr)


class MyOptionPaser(optparse.OptionParser):
  """Override python's builtin OptionParser to accept any undefined args."""

  help = False

  def _process_args(self, largs, rargs, values):
    # see /usr/lib64/python2.6/optparse.py line 1414-1463
    while rargs:
      arg = rargs[0]
      # We handle bare "--" explicitly, and bare "-" is handled by the
      # standard arg handler since the short arg case ensures that the
      # len of the opt string is greater than 1.
      if arg == "--":
        del rargs[0]
        return
      elif arg[0:2] == "--":
        # process a single long option (possibly with value(s))
        try:
          self._process_long_opt(rargs, values)
        except optparse.BadOptionError:
          largs.append(arg)
      elif arg[:1] == "-" and len(arg) > 1:
        # process a cluster of short options (possibly with
        # value(s) for the last one only)
        try:
          self._process_short_opts(rargs, values)
        except optparse.BadOptionError:
          largs.append(arg)
      elif self.allow_interspersed_args:
        largs.append(arg)
        del rargs[0]
      else:
        return                  # stop now, leave this arg in rargs

  def print_help(self, file=None):
    optparse.OptionParser.print_help(self, file)
    MyOptionPaser.help = True


parser = MyOptionPaser()
parser.allow_interspersed_args = True

DEFAULT_BOARD = os.environ.get('DEFAULT_BOARD', '')

parser.add_option('--autox', dest='autox', action='store_true',
                  help='Build autox along with autotest.')
parser.add_option('--board', dest='board', action='store',
                  default=DEFAULT_BOARD,
                  help='The board for which you are building autotest.')
parser.add_option('--build', dest='build', action='store',
                  help='Only prebuild client tests, do not run.')
parser.add_option('--buildcheck', dest='buildcheck', action='store_true',
                  help='Fail if tests fail to build.')                
parser.add_option('--jobs', dest='jobs', action='store', type=int,
                  default=-1,
                  help='How many packages to build in parallel at maximum.')
parser.add_option('--noprompt', dest='noprompt', action='store_true',
                  help='Prompt user when building all tests.')


AUTOSERV='../third_party/autotest/files/server/autoserv'
AUTOTEST_CLIENT='../third_party/autotest/files/client/bin/autotest_client'

def parse_args_and_help():

  def nop(_):
    pass

  sys_exit = sys.exit
  sys.exit = nop
  options, args = parser.parse_args()
  sys.exit = sys_exit

  if MyOptionPaser.help:
    if options.build:
      print
      print 'Options inherited from autotest_client, which is used in build',
      print 'only mode.'
      run([AUTOTEST_CLIENT, '--help'])
    else:
      print
      print 'Options inherited from autoserv:'
      run([AUTOSERV, '--help'])
    sys.exit(-1)
  return options, args


def build_autotest(options):
  environ = os.environ
  if options.jobs != -1:
    emerge_jobs = '--jobs=%d' % options.jobs
  else:
    emerge_jobs = ''

  # Decide on USE flags based on options
  use_flag = environ.get('USE', '')
  if not options.autox:
    use_flag = use_flag + ' -autox'
  if options.buildcheck:
    use_flag = use_flag + ' buildcheck'

  board_blacklist_file = ('%s/src/overlays/overlay-%s/autotest-blacklist' %
                          (os.environ['GCLIENT_ROOT'], options.board))
  if os.path.exists(board_blacklist_file):
    blacklist = [line.strip()
                 for line in open(board_blacklist_file).readlines()]
  else:
    blacklist = []

  all_tests = 'compilebench,dbench,disktest,netperf2,ltp,unixbench'
  site_tests = '../third_party/autotest/files/client/site_tests'
  for site_test in os.listdir(site_tests):
    test_path = os.path.join(site_tests, site_test)
    if (os.path.exists(test_path) and os.path.isdir(test_path)
        and site_test not in blacklist):
      all_tests += ',' + site_test

  if 'all' == options.build.lower():
    if options.noprompt is not True:
      print 'You want to pre-build all client tests and it may take a long',
      print 'time to finish.'
      print 'Are you sure you want to continue?(N/y)',
      answer = sys.stdin.readline()
      if 'y' != answer[0].lower():
        print 'Use --build to specify tests you like to pre-compile. '
        print 'E.g.: ./autotest --build=disktest,hardware_SAT'
        sys.exit(0)
    test_list = all_tests
  else:
    test_list = options.build

  environ['FEATURES'] = ('%s -buildpkg -collision-protect' %
                         environ.get('FEATURES', ''))
  environ['TEST_LIST'] = test_list
  environ['USE'] = use_flag
  emerge_cmd = ['emerge-%s' % options.board,
                'chromeos-base/autotest']
  if emerge_jobs:
    emerge_cmd.append(emerge_jobs)
  status = run(emerge_cmd)
  if status:
    print 'build_autotest failed.'
    sys.exit(status)


def run_autoserv(board, args):
  environ = os.environ
  environ['AUTOSERV_ARGS'] = ' '.join(args)
  environ['FEATURES'] = ('%s -buildpkg -digest noauto' %
                         environ.get('FEATURES', ''))
  ebuild_cmd = ['ebuild-%s' % board,
                '../third_party/chromiumos-overlay/chromeos-base/'
                'autotest/autotest-0.0.1.ebuild',
                'clean', 'unpack', 'test']
  run(ebuild_cmd)


def main():
  options, args = parse_args_and_help()
  if options.build:
    build_autotest(options)
  else:
    run_autoserv(options.board, args)


if __name__ == '__main__':
  main()

