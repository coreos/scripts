#!/usr/bin/python
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.


import getpass
import os
import re
import subprocess
import sys
import tempfile
import urllib


def Authenticate():
  default_username = getpass.getuser()
  username = os.environ.get('GSDCURL_USERNAME')
  if username is None:
    sys.stderr.write('Username [' + default_username + ']: ')
    username = raw_input()
  if username == '':
    username = default_username + '@google.com'
  elif '@' not in username:
    username = username + '@google.com'
  passwd = os.environ.get('GSDCURL_PASSWORD')
  if passwd is None:
    sys.stderr.write('Password: ')
    passwd = getpass.getpass(prompt='')
  cmd = [
      'curl', '--silent', 'https://www.google.com/accounts/ClientLogin',
      '-d', 'Email=' + username,
      '-d', 'Passwd=' + urllib.quote_plus(passwd),
      '-d', 'accountType=GOOGLE',
      '-d', 'source=Google-gsdcurl-ver1',
      '-d', 'service=cds',
  ]
  p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
  (p_stdout, _) = p.communicate()
  assert p.returncode == 0
  m = re.search('\nAuth=([^\n]+)\n', p_stdout)
  if not m:
    sys.stderr.write('BAD LOGIN\n')
    sys.exit(1)
  auth = m.group(1)
  return auth


def DoCurl(auth, argv):
  (_, cookies) = tempfile.mkstemp(prefix='gsdcookie')
  cmd = [
      'curl', '-L',
      '-b', cookies, '-c', cookies,
      '--header', 'Authorization: GoogleLogin auth=' + auth,
  ] + argv[1:]
  try:
    p = subprocess.Popen(cmd)
    return p.wait()
  finally:
    os.remove(cookies)


def main(argv):
  auth = Authenticate()
  return DoCurl(auth, argv)


if __name__ == '__main__':
  sys.exit(main(sys.argv))
