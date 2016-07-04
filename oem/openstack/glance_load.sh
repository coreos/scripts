#!/usr/bin/env bash
# glance_load.sh
#
# A tool for loading a remote image into an OpenStack glance image store.
# This tool has been optimized for use on CoreOS but should work for most files
# where an ETag is exposed.
#
# You will need to source your glance credentials before using this script
#
# By default we retrieve the alpha image, set to  a different value to retrieve
# that release

set -e -o pipefail

release=${1:-"alpha"}
if [[ "$1" != http* ]]; then
  baseurl="https://${release}.release.core-os.net/amd64-usr/current"
else
  # for this convoluded trick, we take an arbitrary URL, chop it up, and try
  # to turn it into usable input for the rest of the script.

  # this is based on urls of the form:
  # https://storage.core-os.net/coreos/amd64-usr/master/version.txt
  # where the following sed expression extracts the "master" portion
  baseurl="${1%/*}"
  release="${baseurl##*/}"
fi
version_url="${baseurl}/version.txt"
image_url="${baseurl}/coreos_production_openstack_image.img.bz2"

# use the following location as our local work space
tmplocation=$(mktemp -d /var/tmp/glanceload.XXX)
pushd ${tmplocation} > /dev/null 2>&1

curl --fail -s -L -O ${version_url}
. version.txt
 
# if we already have the image don't waste time
if glance image-show "CoreOS-${release}-v${COREOS_VERSION}"; then
  echo "Image already exists."
  rm -rf ${tmplocation}
  exit 
fi

coreosimg="coreos_${COREOS_VERSION}_openstack_image.img"

# change the following line to reflect the image to be chosen, openstack
#  is used by default
curl --fail -s -L ${image_url} |  bunzip2 > ${coreosimg}
 
# perform actual image creation
#  here we set the os_release, os_verison, os_family, and os_distro variables
#  for intelligent consumption of images by scripts
glance --os-image-api-version 1 image-create --name CoreOS-${release}-v${COREOS_VERSION} --progress \
  --is-public true --property os_distro=coreos --property os_family=coreos \
  --property os_version=${COREOS_VERSION} \
  --disk-format qcow2 --container-format bare --min-disk 6 --file $coreosimg

# optionally, set --property os_release=${release} in the glance image-create
# command above and uncomment the two commands below to support searching by
# current channel as per CoreOS
#  
# grab UUID of newly created image
# new_glance_uuid=$(glance image-show CoreOS-${release}-v${COREOS_VERSION} | \
#  gawk '/ id / {print $4}')


# purge all previous tags on releases
#glance image-list --property "os_release=$release" \
#  | gawk '$4 ~ /CoreOS/ && !/'"$new_glance_uuid"'/ {printf \
#  "glance image-update --property os_distro=coreos --property \
#  os_family=coreos --property os_version=%s --purge-props %s \n",\
#  gensub(/CoreOS_v/, "", "g", $4), $2}' | sh

popd > /dev/null 2>&1

rm -rf ${tmplocation}

# vim: set ts=2 sw=2 expandtab:
