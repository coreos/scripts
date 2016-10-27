#!/bin/bash
#
# Jenkins job for building final VM and OEM target images.
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
#   FORMAT=qemu
#     Target VM or OEM.
#
#   GROUP=developer
#     Target update group.
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
#   Writes gce.properties for triggering a GCE test job if applicable.

set -ex

rm -f gce.properties
sudo rm -rf tmp

# check that the matrix didn't go bananas
if [[ "${COREOS_OFFICIAL}" -eq 1 ]]; then
  [[ "${GROUP}" != developer ]]
else
  [[ "${GROUP}" == developer ]]
fi

script() {
  local script="/mnt/host/source/src/scripts/${1}"; shift
  ./bin/cork enter --experimental -- "${script}" "$@"
}

enter() {
  ./bin/cork enter --experimental -- "$@"
}

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

if [[ "${GROUP}" == developer ]]; then
  root="gs://builds.developer.core-os.net"
  dlroot=""
else
  root="gs://builds.release.core-os.net/${GROUP}"
  dlroot="--download_root https://${GROUP}.release.core-os.net"
fi

mkdir -p src tmp
./bin/cork download-image --root="${root}/boards/${BOARD}/${COREOS_VERSION}" \
                          --json-key="${GOOGLE_APPLICATION_CREDENTIALS}" \
                          --cache-dir=./src \
                          --platform=qemu
img=src/coreos_production_image.bin
if [[ "${img}.bz2" -nt "${img}" ]]; then
  enter lbunzip2 -k -f "/mnt/host/source/${img}.bz2"
fi

sudo rm -rf chroot/build
script image_to_vm.sh --board=${BOARD} \
                      --format=${FORMAT} \
                      --prod_image \
                      --getbinpkg \
                      --getbinpkgver=${COREOS_VERSION} \
                      --from=/mnt/host/source/src/ \
                      --to=/mnt/host/source/tmp/ \
                      --sign=buildbot@coreos.com \
                      --sign_digests=buildbot@coreos.com \
                      --upload_root="${root}" \
                      --upload ${dlroot}
