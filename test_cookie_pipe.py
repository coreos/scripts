#!/usr/bin/env python

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Generates and passes authentication credentials to Chromium.

This script can be used to simulate the login manager's process of
passing authentication credentials to Chromium.  Running this script
will authenticate with Google Accounts with the provided login
credentials and then write the result to the specified pipe.  The
script will then block until the pipe is read.  To launch Chromium,
use the command:

  ./chrome --cookie-pipe=/tmp/cookie_pipe

"""

from optparse import OptionParser
import getpass
import os
import sys
import urllib
import urllib2

DEFAULT_COOKIE_PIPE = '/tmp/cookie_pipe'
GOOGLE_ACCOUNTS_URL = 'https://www.google.com/accounts'
LOGIN_SOURCE = 'test_harness'


class CookieCollectorRedirectHandler(urllib2.HTTPRedirectHandler):
  def __init__(self):
    self.__cookie_headers = []

  @property
  def cookie_headers(self):
    return self.__cookie_headers

  def http_error_302(self, req, fp, code, msg, headers):
    self.__cookie_headers.extend(fp.info().getallmatchingheaders('Set-Cookie'))
    result = urllib2.HTTPRedirectHandler.http_error_302(self, req, fp,
                                                        code, msg, headers)
    return result


def Authenticate(email, password):
  opener = urllib2.build_opener()
  payload = urllib.urlencode({'Email': email,
                              'Passwd': password,
                              'PersistentCookie': 'true',
                              'accountType' : 'HOSTED_OR_GOOGLE',
                              'source' : LOGIN_SOURCE})
  request = urllib2.Request(GOOGLE_ACCOUNTS_URL + '/ClientLogin', payload)
  response = opener.open(request)
  data = response.read().rstrip()

  # Convert the SID=xxx\nLSID=yyy\n response into a dict.
  l = [p.split('=') for p in data.split('\n')]
  cookies = dict((i[0], i[1]) for i in l)

  payload = urllib.urlencode({'SID': cookies['SID'],
                              'LSID': cookies['LSID'],
                              'source': LOGIN_SOURCE,
                              'service': 'gaia'})
  request = urllib2.Request(GOOGLE_ACCOUNTS_URL + '/IssueAuthToken', payload)
  response = opener.open(request)
  auth_token = response.read().rstrip()

  url = '/TokenAuth?continue=http://www.google.com/&source=%s&auth=%s' % \
        (LOGIN_SOURCE, auth_token)

  # Install a custom redirect handler here so we can catch all the
  # cookies served as the redirects get processed.
  cookie_collector = CookieCollectorRedirectHandler()
  opener = urllib2.build_opener(cookie_collector)
  request = urllib2.Request(GOOGLE_ACCOUNTS_URL + url)
  response = opener.open(request)

  cookie_headers = cookie_collector.cookie_headers
  cookie_headers.extend(response.info().getallmatchingheaders('Set-Cookie'))
  cookies = [s.replace('Set-Cookie: ', '') for s in cookie_headers]
  return cookies

def WriteToPipe(pipe_path, data):
  if os.path.exists(pipe_path):
    os.remove(pipe_path)
  os.mkfifo(pipe_path)
  f = open(pipe_path, 'w')
  f.write(data)
  f.close()

def main():
  usage = "usage: %prog [options]"
  parser = OptionParser(usage)
  parser.add_option('--email', dest='email',
                    help='email address used for login')
  parser.add_option('--password', dest='password',
                    help='password used for login (will prompt if omitted)')
  parser.add_option('--cookie-pipe', dest='cookiepipe',
                    default=DEFAULT_COOKIE_PIPE,
                    help='path of cookie pipe [default: %default]')
  (options, args) = parser.parse_args()

  if options.email is None:
    parser.error("You must supply an email address.")

  if options.password is None:
    options.password = getpass.getpass()

  cookies = Authenticate(options.email, options.password)
  data = ''.join(cookies)
  print 'Writing to "%s":' % options.cookiepipe
  print data
  WriteToPipe(options.cookiepipe, data)

if __name__ == '__main__':
  main()
