#!/usr/bin/env bash
# check_etag.sh
#
# A tool for monitoring remote files and acting if the file has changed
# This tool has been optimized for use on CoreOS but should work 
# for most files where an ETag is exposed.
 
# by default we retrieve the alpha image, set to  a different value to retrieve
# that release

set -e -o pipefail
 
release=${1:-"alpha"}
if [[ $1 != http* ]]; then
  url="http://storage.core-os.net/coreos/amd64-usr/$release/version.txt"
else
  url=$1
  release=$(echo ${url} | sed -e 's/http:\/\///1' -e 's/\//-/g' )
fi
tmplocation="/tmp/etagsync"
 
mkdir -p ${tmplocation}
pushd ${tmplocation} > /dev/null 2>&1
 
remote_etag=$(curl -I ${url} -k -s  | \
  gawk '/ETag/ {print gensub("\"", "", "g", $2)}')
 
source ${release}_etag > /dev/null 2>&1
 
if [ "$remote_etag" == "$local_etag" ]; then
  echo "Everything is current"
  exit 0
else
  echo "Time to sync things!"
  echo "local_etag=$remote_etag" > ${release}_etag
  exit 1
fi

popd > /dev/null 2>&1

# vim: set ts=2 sw=2 expandtab:
