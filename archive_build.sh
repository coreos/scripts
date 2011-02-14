#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to archive build results.  Used by the buildbots.

# --- BEGIN COMMON.SH BOILERPLATE ---
# Load common CrOS utilities.  Inside the chroot this file is installed in
# /usr/lib/crosutils.  Outside the chroot we find it relative to the script's
# location.
find_common_sh() {
  local common_paths=(/usr/lib/crosutils $(dirname "$(readlink -f "$0")"))
  local path

  SCRIPT_ROOT=
  for path in "${common_paths[@]}"; do
    if [ -r "${path}/common.sh" ]; then
      SCRIPT_ROOT=${path}
      break
    fi
  done
}

find_common_sh
. "${SCRIPT_ROOT}/common.sh" || (echo "Unable to load common.sh" && exit 1)
# --- END COMMON.SH BOILERPLATE ---

# Script must be run outside the chroot
assert_outside_chroot

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images"
# Default to the most recent image
DEFAULT_TO="${GCLIENT_ROOT}/archive"
DEFAULT_FROM="${IMAGES_DIR}/$DEFAULT_BOARD/$(ls -t1 \
              $IMAGES_DIR/$DEFAULT_BOARD 2>&-| head -1)"

# Flags
DEFINE_boolean archive_debug $FLAGS_TRUE \
    "Archive debug information for build"
DEFINE_string board "$DEFAULT_BOARD" \
    "The board to build packages for."
DEFINE_string build_number "" \
    "The build-bot build number (when called by buildbot only)." "b"
DEFINE_string chroot "$DEFAULT_CHROOT_DIR" \
    "The chroot of the build to archive."
DEFINE_boolean debug $FLAGS_FALSE "Run, but don't upload anything."
DEFINE_boolean factory_install_mod $FLAGS_FALSE \
    "Modify image for factory install purposes"
DEFINE_boolean factory_test_mod $FLAGS_FALSE \
    "Modify image for factory testing purposes"
DEFINE_string from "$DEFAULT_FROM" \
    "Directory to archive"
DEFINE_string gsutil "gsutil" \
    "Location of gsutil"
DEFINE_string gsd_gen_index "" \
    "Location of gsd_generate_index.py"
DEFINE_string acl "private" \
    "ACL to set on GSD archives"
DEFINE_string gsutil_archive "" \
    "Optional datastore archive location"
DEFINE_integer keep_max 0 "Maximum builds to keep in archive (0=all)"
DEFINE_boolean official_build $FLAGS_FALSE \
    "Set CHROMEOS_OFFICIAL=1 for release builds."
DEFINE_string test_tarball "" "Optional path to test tarball to archive"
DEFINE_boolean test_mod $FLAGS_TRUE "Modify image for testing purposes"
DEFINE_boolean prebuilt_upload $FLAGS_FALSE "Upload prebuilt binary packages."
DEFINE_string to "$DEFAULT_TO" "Directory of build archive"
DEFINE_string zipname "image.zip" "Name of zip file to create."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Set if default from path is used
DEFAULT_USED=

# Reset "default" FLAGS_from based on passed-in board if not set on cmd-line
if [ "$FLAGS_from" = "$DEFAULT_FROM" ]; then
  # Keep the directory name of the current image set (*.bin).
  IMG_DIR="$(readlink ${IMAGES_DIR}/${FLAGS_board}/latest)"
  FLAGS_from="${IMAGES_DIR}/${FLAGS_board}/${IMG_DIR}"
  DEFAULT_USED=1
fi

# Die on any errors.
set -e

if [ -z "$DEFAULT_USED" ]; then
  if [ $FLAGS_test_mod -eq $FLAGS_TRUE ] || \
     [ $FLAGS_factory_install_mod -eq $FLAGS_TRUE ] || \
     [ $FLAGS_factory_test_mod -eq $FLAGS_TRUE ]
  then
    echo "test_mod requires that the default from path be used."
    echo "If non default behavior is desired, run mod_image_for_test manually"
    echo "re-run archive build without test_mod"
    exit 1
  fi
fi

if [ ! -d "$FLAGS_from" ]; then
   echo "$FLAGS_from does not exist.  Exiting..."
   exit 1
fi

if [ $FLAGS_official_build -eq $FLAGS_TRUE ]; then
   CHROMEOS_OFFICIAL=1
fi

# Get version information
. ${SRC_ROOT}/third_party/chromiumos-overlay/chromeos/config/chromeos_version.sh

# Get git hash
# Use git:8 chars of sha1
REVISION=$(git rev-parse HEAD)
REVISION=${REVISION:0:8}

# Use the version number plus revision as the last change.  (Need both, since
# trunk builds multiple times with the same version string.)
LAST_CHANGE="${CHROMEOS_VERSION_STRING}-r${REVISION}"
if [ -n "$FLAGS_build_number" ]; then
   LAST_CHANGE="$LAST_CHANGE-b${FLAGS_build_number}"
fi

# The Chromium buildbot scripts only create a clickable link to the archive
# if an output line of the form "last change: XXX" exists
echo "last change: $LAST_CHANGE"
echo "archive from: $FLAGS_from"

# Create the output directory
OUTDIR="${FLAGS_to}/${LAST_CHANGE}"
ZIPFILE="${OUTDIR}/${FLAGS_zipname}"
FACTORY_ZIPFILE="${OUTDIR}/factory_${FLAGS_zipname}"
echo "archive to dir: $OUTDIR"
echo "archive to file: $ZIPFILE"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"


SRC_IMAGE="${FLAGS_from}/chromiumos_image.bin"
BACKUP_IMAGE="${FLAGS_from}/chromiumos_image_bkup.bin"

# Apply mod_image_for_test to the developer image, and store the
# result in a new location. Usage:
# do_chroot_mod "$OUTPUT_IMAGE" "--flags_to_mod_image_for_test"
function do_chroot_mod() {
  MOD_ARGS=$2
  OUTPUT_IMAGE=$1
  cp -f "${SRC_IMAGE}" "${BACKUP_IMAGE}"
  ./enter_chroot.sh -- ./mod_image_for_test.sh --board $FLAGS_board \
      --yes ${MOD_ARGS}
  mv "${SRC_IMAGE}" "${OUTPUT_IMAGE}"
  mv "${BACKUP_IMAGE}" "${SRC_IMAGE}"
}

# Modify image for test if flag set.
if [ $FLAGS_test_mod -eq $FLAGS_TRUE ]; then
  echo "Modifying image for test"
  do_chroot_mod "${FLAGS_from}/chromiumos_test_image.bin" ""

  pushd "${FLAGS_chroot}/build/${FLAGS_board}/usr/local"
  echo "Archiving autotest build artifacts"
  tar cjf "${FLAGS_from}/autotest.tar.bz2" --checkpoint=1000 autotest
  popd
fi

if [ $FLAGS_factory_test_mod -eq $FLAGS_TRUE ]; then
  echo "Modifying image for factory test"
  do_chroot_mod "${FLAGS_from}/chromiumos_factory_image.bin" \
      "--factory"
fi

# Modify for recovery
if [ $FLAGS_official_build -eq $FLAGS_TRUE ]; then
  BUILDVER="$(readlink ${IMAGES_DIR}/${FLAGS_board}/latest)"
  CHROOT_IMAGE_DIR=/home/$USER/trunk/src/build/images/$FLAGS_board/$BUILDVER
  ./enter_chroot.sh -- ./mod_image_for_recovery.sh --board $FLAGS_board \
    --image $CHROOT_IMAGE_DIR/chromiumos_base_image.bin
fi

# Remove the developer build if test image is also built.
if [ $FLAGS_test_mod -eq $FLAGS_TRUE ] ; then
  rm -f ${SRC_IMAGE}
fi

# Build differently sized shims. Currently only factory install shim is
# supported, TODO(tgao): Add developer shim.
if [ $FLAGS_factory_install_mod -eq $FLAGS_TRUE ]; then
  echo "Building factory install shim."
  # HACK: The build system can't currently handle more than one image size
  # at a time. Therefor eit's necessary to do another round of build after
  # archiving the original build. This should be fixed in Chromite.

  # HACK: cbuild has a special case when running on chrome-bot that
  # zeroes out the current revision, which makes calling build_image directly
  # fail. You must explictly call replace and specify a unique name numerically
  # using build_attempt.
  ./enter_chroot.sh -- ./build_image --board $FLAGS_board --factory_install \
      --replace --build_attempt 7

  # Get the install shim dir: It is the newest build.
  # This is the output dir for the factory shim, the factory test and
  # release images will remain in IMG_DIR, defined previously.
  SHIM_DIR="$(readlink ${IMAGES_DIR}/${FLAGS_board}/latest)"

  echo "Factory image dir: ${IMG_DIR}"
  echo "Factory install shim dir: ${SHIM_DIR}"
fi

# Zip the build
echo "Compressing and archiving build..."
cd "$FLAGS_from"
MANIFEST=`ls | grep -v factory`
zip -r "${ZIPFILE}" ${MANIFEST}

if [ $FLAGS_factory_test_mod -eq $FLAGS_TRUE ] || \
   [ $FLAGS_factory_install_mod -eq $FLAGS_TRUE ]; then
  # We need to have directory structure for factory package, as
  # signing and packaging utilities need unpack_partitions.sh.
  echo "Compressing factory software"
  pushd ..
  [ -n "${SHIM_DIR}" ] && rm -f factory_shim && ln -s "${SHIM_DIR}" factory_shim
  [ -n "${IMG_DIR}" ] && rm -f factory_test && ln -s "${IMG_DIR}" factory_test

  # Restore "latest" status to the original image.
  # The "latest" symlink and latest timestamp are used extensively
  # throughout the build scripts rather than explicitly specifying an image.
  touch "${IMG_DIR}"
  [ -n "${IMG_DIR}" ] && rm -f latest && ln -s "${IMG_DIR}" latest
  FACTORY_MANIFEST=`find factory_shim factory_test -follow \
      -type f  | grep -E "(factory_image|factory_install|partition)"`
  zip "${FACTORY_ZIPFILE}" ${FACTORY_MANIFEST}
  echo "Zipped"
  popd
  chmod 644 "${FACTORY_ZIPFILE}"
fi
cd -

# Update LATEST file
echo "$LAST_CHANGE" > "${FLAGS_to}/LATEST"

# Make sure files are readable
chmod 644 "$ZIPFILE" "${FLAGS_to}/LATEST"
chmod 755 "$OUTDIR"
cp -f  "${FLAGS_from}/au-generator.zip" "${OUTDIR}/"


function gsutil_archive() {
  IN_PATH="$1"
  OUT_PATH="$2"
  echo "Using gsutil to archive to ${OUT_PATH}..."
  if [ -z "$FLAGS_gsutil_archive" -o ${FLAGS_debug} -eq ${FLAGS_TRUE} ]; then
    echo -n "In debug mode.  Would have run: "
    echo "gsutil cp ${IN_PATH} <gsutil_archive>/${OUT_PATH}"
    return
  fi

  FULL_OUT_PATH="${FLAGS_gsutil_archive}/${OUT_PATH}"
  ${FLAGS_gsutil} cp ${IN_PATH} ${FULL_OUT_PATH}
  ${FLAGS_gsutil} setacl ${FLAGS_acl} ${FULL_OUT_PATH}
  if [ -n "$FLAGS_gsd_gen_index" ]; then
    echo "Updating indexes..."
    ${FLAGS_gsd_gen_index} \
      --gsutil=${FLAGS_gsutil} \
      -a ${FLAGS_acl} \
      -p ${FULL_OUT_PATH} ${FLAGS_gsutil_archive}
  fi
}

if [ $FLAGS_test_mod -eq $FLAGS_TRUE -a $FLAGS_official_build -eq $FLAGS_TRUE ]
then
  echo "Creating hwqual archive"
  HWQUAL_NAME="chromeos-hwqual-${FLAGS_board}-${CHROMEOS_VERSION_STRING}"
  "${SCRIPTS_DIR}/archive_hwqual" --from "${OUTDIR}" \
    --output_tag "${HWQUAL_NAME}"
  gsutil_archive "${OUTDIR}/${HWQUAL_NAME}.tar.bz2" \
    "${LAST_CHANGE}/${HWQUAL_NAME}.tar.bz2"
fi


if [ $FLAGS_prebuilt_upload -eq $FLAGS_TRUE ]; then
  # Construct prebuilt upload command.
  # This will upload prebuilt packages to Google Storage.
  prebuilt_cmd="${GCLIENT_ROOT}/chromite/buildbot/prebuilt.py"
  prebuilt_cmd="$prebuilt_cmd -u gs://chromeos-prebuilt --git-sync -V master"
  prebuilt_cmd="$prebuilt_cmd -p ${GCLIENT_ROOT} -b ${FLAGS_board}"

  if [ "${FLAGS_board}" == "x86-generic" ]
  then
    prebuilt_cmd="$prebuilt_cmd --sync-host"
  fi

  if [ ${FLAGS_debug} -eq ${FLAGS_FALSE} ]; then
    echo "Running $prebuilt_cmd"
    $prebuilt_cmd
  else
    echo "Would have run $prebuilt_cmd"
  fi
fi

gsutil_archive "${ZIPFILE}" "${LAST_CHANGE}/${FLAGS_zipname}"

if [ $FLAGS_archive_debug -eq $FLAGS_TRUE ]; then
  echo "Generating Breakpad symbols"
  ! ${SCRIPTS_DIR}/cros_generate_breakpad_symbols --board=${FLAGS_board}
  echo "Creating debug archive"
  pushd "${FLAGS_chroot}/build/${FLAGS_board}/usr/lib"
  sudo tar czf "${OUTDIR}/debug.tgz" --checkpoint=1000 --exclude\
      debug/usr/local/autotest --exclude debug/tests debug
  CMD="chown \${SUDO_UID}:\${SUDO_GID} ${OUTDIR}/debug.tgz"
  sudo sh -c "${CMD}"
  popd
  gsutil_archive "${OUTDIR}/debug.tgz" "${LAST_CHANGE}/debug.tgz"
fi

if [ $FLAGS_factory_test_mod -eq $FLAGS_TRUE ] || \
   [ $FLAGS_factory_install_mod -eq $FLAGS_TRUE ]; then
  gsutil_archive "${FACTORY_ZIPFILE}" \
    "${LAST_CHANGE}/factory_${FLAGS_zipname}"
fi

gsutil_archive "${FLAGS_to}/LATEST" "LATEST"

if [ -n "${FLAGS_gsutil_archive}" ]; then
  FULL_INDEX_PATH="${FLAGS_gsutil_archive}/${LAST_CHANGE}/_index.html"
  RELATIVE_ARCHIVE_URL_PATH="${FULL_INDEX_PATH#gs://}"
  echo "CROS_ARCHIVE_URL=\
https://sandbox.google.com/storage/${RELATIVE_ARCHIVE_URL_PATH}"
fi

if [ -n "${FLAGS_test_tarball}" ]; then
  gsutil_archive "${FLAGS_test_tarball}" "${LAST_CHANGE}/test_results.tgz"
fi

# Purge old builds if necessary
if [ $FLAGS_keep_max -gt 0 ]; then
  echo "Deleting old builds (all but the newest ${FLAGS_keep_max})..."
  cd "$FLAGS_to"
  # +2 because line numbers start at 1 and need to skip LATEST file
  rm -rf `ls -t1 | tail --lines=+$(($FLAGS_keep_max + 2))`
  cd -
fi

echo "Done."
