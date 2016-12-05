#!/bin/bash
#
# Jenkins job for creating build manifests.
#
# Input Parameters:
#
#   MANIFEST_REF=master
#     Git branch or tag in github.com/coreos/manifest to build
#
#   LOCAL_MANIFEST=
#     Repo local manifest to amend the branch's default manifest with.
#     https://wiki.cyanogenmod.org/w/Doc:_Using_manifests#The_local_manifest
#
# Input Artifacts:
#
#   $WORKSPACE/bin/cork from a recent mantle build.
#
# Git:
#
#   github.com/coreos/manifest checked out to $WORKSPACE/manifest
#   SSH push access to github.com/coreos-inc/manifest-builds
#
# Output:
#
#   Pushes build tag to manifest-builds.
#   Writes manifest.properties w/ parameters for sdk and toolchain jobs.

set -ex

export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no"

finish() {
  local tag="$1"
  git -C "${WORKSPACE}/manifest" push \
    "ssh://git@github.com/coreos-inc/manifest-builds.git" \
    "refs/tags/${tag}:refs/tags/${tag}"
  tee "${WORKSPACE}/manifest.properties" <<EOF
MANIFEST_URL = ssh://git@github.com/coreos-inc/manifest-builds.git
MANIFEST_REF = refs/tags/${tag}
MANIFEST_NAME = release.xml
COREOS_OFFICIAL = ${COREOS_OFFICIAL:-0}
EOF
}

# Branches are of the form remote-name/branch-name. Tags are just tag-name.
# If we have a release tag use it, for branches we need to make a tag.
COREOS_OFFICIAL=0
if [[ "${GIT_BRANCH}" != */* ]]; then
  COREOS_OFFICIAL=1
  finish "${GIT_BRANCH}"
  exit
fi

MANIFEST_BRANCH="${GIT_BRANCH##*/}"
MANIFEST_NAME="${MANIFEST_BRANCH}.xml"
[[ -f "manifest/${MANIFEST_NAME}" ]]

source manifest/version.txt
export COREOS_BUILD_ID="${MANIFEST_BRANCH}-${BUILD_NUMBER}"

# hack to get repo to set things up using the manifest repo we already have
# (amazing that it tolerates this considering it usually is so intolerant)
mkdir -p .repo
ln -sfT ../manifest .repo/manifests
ln -sfT ../manifest/.git .repo/manifests.git

# Cleanup/setup local manifests
rm -rf .repo/local_manifests
if [[ -n "${LOCAL_MANIFEST}" ]]; then
  mkdir -p .repo/local_manifests
  cat >.repo/local_manifests/local.xml <<<"${LOCAL_MANIFEST}"
fi

./bin/cork update --create --downgrade-replace --verbose \
                  --manifest-url "${GIT_URL}" \
                  --manifest-branch "${GIT_COMMIT}" \
                  --manifest-name "${MANIFEST_NAME}" \
                  --new-version "${COREOS_VERSION}" \
                  --sdk-version "${COREOS_SDK_VERSION}"

./bin/cork enter --experimental -- sh -c \
  "pwd; repo manifest -r > '/mnt/host/source/manifest/${COREOS_BUILD_ID}.xml'"

cd manifest
git add "${COREOS_BUILD_ID}.xml" 

ln -sf "${COREOS_BUILD_ID}.xml" default.xml
ln -sf "${COREOS_BUILD_ID}.xml" release.xml
git add default.xml release.xml

tee version.txt <<EOF
COREOS_VERSION=${COREOS_VERSION_ID}+${COREOS_BUILD_ID}
COREOS_VERSION_ID=${COREOS_VERSION_ID}
COREOS_BUILD_ID=${COREOS_BUILD_ID}
COREOS_SDK_VERSION=${COREOS_SDK_VERSION}
EOF
git add version.txt

EMAIL="jenkins@jenkins.coreos.systems"
GIT_AUTHOR_NAME="CoreOS Jenkins"
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
export EMAIL GIT_AUTHOR_NAME GIT_COMMITTER_NAME
git commit \
  -m "${COREOS_BUILD_ID}: add build manifest" \
  -m "Based on ${GIT_URL} branch ${MANIFEST_BRANCH}" \
  -m "${BUILD_URL}"
git tag -m "${COREOS_BUILD_ID}" "${COREOS_BUILD_ID}" HEAD

# assert that what we just did will work, update symlink because verify doesn't have a --manifest-name option yet
cd "${WORKSPACE}"
ln -sf "manifests/${COREOS_BUILD_ID}.xml" .repo/manifest.xml
./bin/cork verify

finish "${COREOS_BUILD_ID}"
