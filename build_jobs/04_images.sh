#!/bin/bash
#
# Jenkins job for building the base production image and dev container.
#
# Input Parameters:
#
#   USE_CACHE=false
#     Enable use of any binary packages cached locally from previous builds.
#     Currently not safe to enable, particularly bad with multiple branches.
#
#   MANIFEST_URL=https://github.com/coreos/manifest-builds.git
#   MANIFEST_REF=refs/tags/
#   MANIFEST_NAME=release.xml
#     Git URL, tag, and manifest file for this build.
#
#   COREOS_OFFICIAL=0
#     Set to 1 when building official releases.
#
#   BOARD=amd64-usr
#     Target board to build.
#
# Input Artifacts:
#
#   $WORKSPACE/bin/cork from a recent mantle build.
#
# Secrets:
#
#   GPG_SECRET_KEY_FILE=
#     Exported GPG public/private key used to sign uploaded files.
#
#   GOOGLE_APPLICATION_CREDENTIALS=
#     JSON file defining a Google service account for uploading files.
#
# Output:
#
#   Uploads test branch images to gs://builds.developer.core-os.net and
#   official images to gs://builds.release.core-os.net

set -ex

# build may not be started without a ref value
[[ -n "${MANIFEST_REF#refs/tags/}" ]]

# first thing, clear out old images
sudo rm -rf src/build

script() {
  local script="/mnt/host/source/src/scripts/${1}"; shift
  ./bin/cork enter --experimental -- "${script}" "$@"
}

./bin/cork update --create --downgrade-replace --verify --verbose \
                  --manifest-url "${MANIFEST_URL}" \
                  --manifest-branch "${MANIFEST_REF}" \
                  --manifest-name "${MANIFEST_NAME}"

source .repo/manifests/version.txt
export COREOS_BUILD_ID

if [[ "${COREOS_VERSION}" == 1010.* && "${BOARD}" == arm64-usr ]]; then
  echo "SKIPPING ARM"
  exit 0
fi

# Set up GPG for signing images
export GNUPGHOME="${PWD}/.gnupg"
rm -rf "${GNUPGHOME}"
trap "rm -rf '${GNUPGHOME}'" EXIT
mkdir --mode=0700 "${GNUPGHOME}"
gpg --import "${GPG_SECRET_KEY_FILE}"

sudo rm -rf chroot/build
script setup_board --board=${BOARD} \
                   --getbinpkgver="${COREOS_VERSION}" \
                   --regen_configs_only

if [[ "${COREOS_OFFICIAL}" -eq 1 ]]; then
  GROUP=stable
  UPLOAD=gs://builds.release.core-os.net/stable
  script set_official --board=${BOARD} --official
else
  GROUP=developer
  UPLOAD=gs://builds.developer.core-os.net
  script set_official --board=${BOARD} --noofficial
fi

script build_image --board=${BOARD} \
                   --group=${GROUP} \
                   --getbinpkg \
                   --getbinpkgver="${COREOS_VERSION}" \
                   --sign=buildbot@coreos.com \
                   --sign_digests=buildbot@coreos.com \
                   --upload_root=${UPLOAD} \
                   --upload prod container

if [[ "${COREOS_OFFICIAL}" -eq 1 ]]; then
  script image_set_group --board=${BOARD} \
                         --group=alpha \
                         --sign=buildbot@coreos.com \
                         --sign_digests=buildbot@coreos.com \
                         --upload_root=gs://builds.release.core-os.net/alpha \
                         --upload
  script image_set_group --board=${BOARD} \
                         --group=beta \
                         --sign=buildbot@coreos.com \
                         --sign_digests=buildbot@coreos.com \
                         --upload_root=gs://builds.release.core-os.net/beta \
                         --upload
fi
