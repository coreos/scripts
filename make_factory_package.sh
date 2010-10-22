#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to generate a factory install partition set and miniomaha.conf
# file from a release image and a factory image. This creates a server
# configuration that can be installed using a factory install shim.
#
# miniomaha lives in src/platform/dev/ and miniomaha partition sets live
# in src/platform/dev/static.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Load functions and constants for chromeos-install
. "$(dirname "$0")/chromeos-common.sh"

get_default_board

# Flags
DEFINE_string board "${DEFAULT_BOARD}" "Board for which the image was built"
DEFINE_string factory "" \
  "Directory and file containing factory image: /path/chromiumos_test_image.bin"
DEFINE_string firmware_updater "" \
  "If set, include the firmware shellball into the server configuration"
DEFINE_string release "" \
  "Directory and file containing release image: /path/chromiumos_image.bin"
DEFINE_string subfolder "" \
  "If set, the name of the subfolder to put the payload items inside"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

if [ ! -f "${FLAGS_release}" ] ; then
  echo "Cannot find image file ${FLAGS_release}"
  exit 1
fi

if [ ! -f "${FLAGS_factory}" ] ; then
  echo "Cannot find image file ${FLAGS_factory}"
  exit 1
fi

if [ ! -z "${FLAGS_firmware_updater}" ] && \
   [ ! -f "${FLAGS_firmware_updater}" ] ; then
  echo "Cannot find firmware file ${FLAGS_firmware_updater}"
  exit 1
fi

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f ${FOO}` won't work.
OMAHA_DIR=${SRC_ROOT}/platform/dev
OMAHA_DATA_DIR=${OMAHA_DIR}/static/

# Note: The subfolder flag can only append configs.  That means you will need
# to have unique board IDs for every time you run.  If you delete miniomaha.conf
# you can still use this flag and it will start fresh.
if [ -n "${FLAGS_subfolder}" ] ; then
  OMAHA_DATA_DIR=${OMAHA_DIR}/static/${FLAGS_subfolder}/
fi

if [ ${INSIDE_CHROOT} -eq 0 ]; then
  echo "Caching sudo authentication"
  sudo -v
  echo "Done"
fi

# Use this image as the source image to copy
RELEASE_DIR=`dirname ${FLAGS_release}`
FACTORY_DIR=`dirname ${FLAGS_factory}`
RELEASE_IMAGE=`basename ${FLAGS_release}`
FACTORY_IMAGE=`basename ${FLAGS_factory}`


prepare_omaha() {
  sudo rm -rf ${OMAHA_DATA_DIR}/rootfs-test.gz
  sudo rm -rf ${OMAHA_DATA_DIR}/rootfs-release.gz
  rm -rf ${OMAHA_DATA_DIR}/efi.gz
  rm -rf ${OMAHA_DATA_DIR}/oem.gz
  rm -rf ${OMAHA_DATA_DIR}/state.gz
  if [ ! -f "${OMAHA_DATA_DIR}" ] ; then
    mkdir -p ${OMAHA_DATA_DIR}
  fi
}

prepare_dir() {
  sudo rm -rf rootfs-test.gz
  sudo rm -rf rootfs-release.gz
  rm -rf efi.gz
  rm -rf oem.gz
  rm -rf state.gz
}


# Clean up stale config and data files.
prepare_omaha

# Get the release image.
pushd ${RELEASE_DIR} > /dev/null
echo "Generating omaha release image from ${FLAGS_release}"
echo "Generating omaha factory image from ${FLAGS_factory}"
echo "Output omaha image to ${OMAHA_DATA_DIR}"
echo "Output omaha config to ${OMAHA_DIR}/miniomaha.conf"

prepare_dir

sudo ./unpack_partitions.sh ${RELEASE_IMAGE} &> /dev/null
release_hash=`sudo ${SCRIPTS_DIR}/mk_memento_images.sh part_2 part_3 \
    | grep hash | awk '{print $4}'`
sudo chmod a+rw update.gz
mv update.gz rootfs-release.gz
mv rootfs-release.gz ${OMAHA_DATA_DIR}
echo "release: ${release_hash}"

cat part_8 | gzip -9 > oem.gz
oem_hash=`cat oem.gz | openssl sha1 -binary | openssl base64`
mv oem.gz ${OMAHA_DATA_DIR}
echo "oem: ${oem_hash}"

cat part_12 | gzip -9 > efi.gz
efi_hash=`cat efi.gz | openssl sha1 -binary | openssl base64`
mv efi.gz ${OMAHA_DATA_DIR}
echo "efi: ${efi_hash}"

popd > /dev/null

# Go to retrieve the factory test image.
pushd ${FACTORY_DIR} > /dev/null
prepare_dir


sudo ./unpack_partitions.sh ${FACTORY_IMAGE} &> /dev/null
test_hash=`sudo ${SCRIPTS_DIR}//mk_memento_images.sh part_2 part_3 \
    | grep hash | awk '{print $4}'`
sudo chmod a+rw update.gz
mv update.gz rootfs-test.gz
mv rootfs-test.gz ${OMAHA_DATA_DIR}
echo "test: ${test_hash}"

cat part_1 | gzip -9 > state.gz
state_hash=`cat state.gz | openssl sha1 -binary | openssl base64`
mv state.gz ${OMAHA_DATA_DIR}
echo "state: ${state_hash}"

popd > /dev/null

if [ ! -z ${FLAGS_firmware_updater} ] ; then
  SHELLBALL="${FLAGS_firmware_updater}"
  if [ ! -f  "$SHELLBALL" ]; then
    echo "Failed to find firmware updater: $SHELLBALL."
    exit 1
  fi

  cat $SHELLBALL | gzip -9 > firmware.gz
  firmware_hash=`cat firmware.gz | openssl sha1 -binary | openssl base64`
  mv firmware.gz ${OMAHA_DATA_DIR}
  echo "firmware: ${firmware_hash}"
fi

# If the file does exist and we are using the subfolder flag we are going to
# append another config.
if [ -n "${FLAGS_subfolder}" ] && \
   [ -f "${OMAHA_DIR}"/miniomaha.conf"" ] ; then
  # Remove the ']' from the last line of the file so we can add another config.
  sed -i '$d' < ${OMAHA_DIR}/miniomaha.conf
else
  echo -e "config = [" > ${OMAHA_DIR}/miniomaha.conf
fi

if [ -n "${FLAGS_subfolder}" ] ; then
  subfolder="${FLAGS_subfolder}/"
fi

echo -n "{
   'qual_ids': set([\"${FLAGS_board}\"]),
   'factory_image': '"${subfolder}"rootfs-test.gz',
   'factory_checksum': '${test_hash}',
   'release_image': '"${subfolder}"rootfs-release.gz',
   'release_checksum': '${release_hash}',
   'oempartitionimg_image': '"${subfolder}"oem.gz',
   'oempartitionimg_checksum': '${oem_hash}',
   'efipartitionimg_image': '"${subfolder}"efi.gz',
   'efipartitionimg_checksum': '${efi_hash}',
   'stateimg_image': '"${subfolder}"state.gz',
   'stateimg_checksum': '${state_hash}'," >> ${OMAHA_DIR}/miniomaha.conf

if [ ! -z "${FLAGS_firmware_updater}" ]  ; then
  echo -n "
   'firmware_image': 'firmware.gz',
   'firmware_checksum': '${firmware_hash}'," >> ${OMAHA_DIR}/miniomaha.conf
fi

echo -n "
 },
]
" >> ${OMAHA_DIR}/miniomaha.conf

echo "The miniomaha server lives in src/platform/dev"
echo "to validate the configutarion, run:"
echo "  python2.6 devserver.py --factory_config miniomaha.conf \
--validate_factory_config"
echo "To run the server:"
echo "  python2.6 devserver.py --factory_config miniomaha.conf"
