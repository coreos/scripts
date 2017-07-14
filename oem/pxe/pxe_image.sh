#!/usr/bin/env bash

set -e -o pipefail

: ${release:="alpha"}
: ${arch:="amd64-usr"}

#Set location for temporary directory
tmplocation="/tmp/etagsync/"
releaselocation="${tmplocation}/${release}"

#Create temporary directory for storage of CoreOS image state
mkdir -p ${releaselocation}
pushd ${releaselocation} > /dev/null 2>&1

#Set base, version, and image urls using $release and $arch
baseurl="https://${release}.release.core-os.net/${arch}/current"
version_url="${baseurl}/version.txt"
image_url="${baseurl}/coreos_production_pxe.vmlinuz"

#Make the etag file if it doesn't exist
if [ ! -f ${release}_etag ]; then
  touch ${release}_etag
fi

#Make the versions file if it doesn't exist
if [ ! -f versions ]; then
  touch versions
fi

#Get the etag information from version.txt
remote_etag=$(curl -I ${version_url} -k -s | \
  grep -i '^etag:' | sed -e 's/.*: *//' -e 's/["\r\n]//g')

#Load etag information
source ${release}_etag > /dev/null 2>&1

#If the etag info we just got is the same as on the system, then we're done
if [ "$remote_etag" == "$local_etag" ]; then
  echo "Everything is current"
  exit 0
#If the etag info is different, we may need to get a new image
else
  echo "Time to sync things!"
  echo "local_etag=$remote_etag" > ${release}_etag
  curl --fail -s -L -O ${version_url}
  #Use the vars in version.txt
  . version.txt
  mkdir $COREOS_VERSION
  #If the version of CoreOS isn't found under the other two relases, then
  # curl it down in a folder under $release/$version
  if ! grep $COREOS_VERSION ${tmplocation}/*/versions; then
    echo "Version not found in other releases, downloading image"
    curl --fail -s -L ${image_url} > ${releaselocation}/$COREOS_VERSION/coreos_production_pxe.vmlinuz
  #If the version is found under another relase, make a hard link to it.
  else
     echo "Version found in another release"
     ln ${tmplocation}/${something}/$COREOS_VERSION/coreos_production_pxe.vmlinuz ${releaselocation}/$COREOS_VERSION/coreos_production_pxe.vmlinuz
  fi
  #Add version number to $release versions list
  echo $COREOS_VERSION >> versions
  exit 1
fi

popd > /dev/null 2>&1

