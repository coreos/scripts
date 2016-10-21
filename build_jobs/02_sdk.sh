#!/bin/bash
#
# Jenkins job for building the SDK tarball.
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
#   Uploads binary packages and tarball to gs://builds.developer.core-os.net

set -ex

# build may not be started without a ref value
[[ -n "${MANIFEST_REF#refs/tags/}" ]]

enter() {
  ./bin/cork enter --experimental -- "$@"
}

# hack because catalyst leaves things chowned as root
[[ -d .cache/sdks ]] && sudo chown -R $USER .cache/sdks

./bin/cork update --create --downgrade-replace --verify --verbose \
                  --manifest-url "${MANIFEST_URL}" \
                  --manifest-branch "${MANIFEST_REF}" \
                  --manifest-name "${MANIFEST_NAME}"

source .repo/manifests/version.txt
export COREOS_BUILD_ID

# Set up GPG for signing images
export GNUPGHOME="${PWD}/.gnupg"
sudo rm -rf "${GNUPGHOME}"
trap "sudo rm -rf '${GNUPGHOME}'" EXIT
mkdir --mode=0700 "${GNUPGHOME}"
gpg --import "${GPG_SECRET_KEY_FILE}"

# Wipe all of catalyst or just clear out old tarballs taking up space
if [[ "${COREOS_OFFICIAL:-0}" -eq 1 || "$USE_CACHE" == false ]]; then
  sudo rm -rf src/build/catalyst
fi
sudo rm -rf src/build/catalyst/builds

enter sudo emerge -uv --jobs=2 catalyst
enter sudo /mnt/host/source/src/scripts/bootstrap_sdk \
  --sign buildbot@coreos.com --sign_digests buildbot@coreos.com \
  --upload --upload_root gs://builds.developer.core-os.net
