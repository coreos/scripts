#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to report issues from the command line

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Script must be run outside the chroot
assert_outside_chroot

# Define command line flags
# See http://code.google.com/p/shflags/wiki/Documentation10x
DEFINE_string author "$USER" "author" "a"
DEFINE_string description "" "description" "d"
DEFINE_string owner "$USER@chromium.org" "owner" "o"
DEFINE_string password "" "password" "p"
DEFINE_integer priority "2" "priority" "r"
DEFINE_string status "Untriaged" "status (see below)" "s"
DEFINE_string title "" "title" "t"
DEFINE_string type "Bug" "type" "y"
DEFINE_string username "$USER@chromium.org" "username" "u"
DEFINE_boolean verbose false "verbose" "v"

FLAGS_HELP="
  Description accepts html formatting characters.

  Open Statuses:
    Unconfirmed   = New, has not been verified or reproduced
    Untriaged     = Confirmed, not reviewed for priority and assignment
    Available     = Triaged, but no owner assigned
    Assigned      = In someone's queue, but not started
    Started       = Work in progress
    Upstream      = Issue has been reported to another project
    
  Closed Statuses:
    Fixed         = Work completed, needs verification
    Verified      = Test or reporter verified that the fix works
    Duplicate     = Same root cause as another issue
    WontFix       = Cannot reproduce, works as intended, or obsolete
    FixUnreleased = Security bug fixed on all branches, not released
    Invalid       = Not a valid issue report
    
  Types:
    Bug     = Software not working correctly
    Feature = Request for new or improved feature
    Task    = Project or work that doesn't change code
    Cleanup = Code maintenance unrelated to bugs
    
  Priority:
    0 = Critical. Resolve now. Blocks other work or users need immediate update.
    1 = High. Required for the specified milestone release.
    2 = Normal. Desired for, but does not block, the specified milestone release.
    3 = Low. Nice to have, but not important enough to start work on yet.
"

# parse the command-line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Now we can die on errors
set -e

# Function to escape XML
escape_xml() {
  RESULT_ESCAPE_XML="${1}"
  # Quote any ampersands first, since they appear in the substitutions
  RESULT_ESCAPE_XML="${RESULT_ESCAPE_XML//&/&amp;}"
  RESULT_ESCAPE_XML="${RESULT_ESCAPE_XML//</&lt;}"
  RESULT_ESCAPE_XML="${RESULT_ESCAPE_XML//>/&gt;}"
  RESULT_ESCAPE_XML="${RESULT_ESCAPE_XML//\"/\&quot;}"
  RESULT_ESCAPE_XML="${RESULT_ESCAPE_XML//\'/\&apos;}"
}

if [ ${FLAGS_verbose} -eq ${FLAGS_TRUE} ]; then
  set -v
else
  set +v
fi

# Make sure we have a password
if [ -z "${FLAGS_password}" ]; then
  echo -n "password: "
  stty -echo
  read FLAGS_password
  stty echo
fi

escape_xml "${FLAGS_description}"
FLAGS_description="${RESULT_ESCAPE_XML}"
escape_xml "${FLAGS_title}"
FLAGS_title="${RESULT_ESCAPE_XML}"

BODY="
<?xml version='1.0' encoding='UTF-8'?>
<entry xmlns='http://www.w3.org/2005/Atom'
    xmlns:issues='http://schemas.google.com/projecthosting/issues/2009'>
  <title>$FLAGS_title</title>
  <content type='html'>$FLAGS_description</content>
  <author><name>$FLAGS_author</name></author>
  <issues:status>$FLAGS_status</issues:status>
  <issues:owner>
     <issues:username>$FLAGS_owner</issues:username>
  </issues:owner>
  <issues:label>Type-$FLAGS_type</issues:label>
  <issues:label>Pri-$FLAGS_priority</issues:label>
</entry>
"

AUTH=`curl --silent -d "Email=$FLAGS_username&Passwd=$FLAGS_password&service=code&source=google-cltracker-1" \
  https://www.google.com/accounts/ClientLogin | sed -n -e '/^Auth=/{!d;s/Auth=//;p;}'`

if [ -z "${AUTH}" ]; then
  echo "Authentication Failure" >&2
  exit 1
fi

echo $BODY | curl --silent -X POST -H "Authorization: GoogleLogin auth=$AUTH" \
    -H "content-type: application/atom+xml" \
    -H "content-length: ${#BODY}" \
    -T - http://code.google.com/feeds/issues/p/chromium-os/issues/full

