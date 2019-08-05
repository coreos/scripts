#!/bin/bash -ex

enter() {
        bin/cork enter --bind-gpg-agent=false -- "$@"
}

source .repo/manifests/version.txt
export COREOS_BUILD_ID

# Set up GPG for signing uploads.
gpg --import "${GPG_SECRET_KEY_FILE}"

# Wipe all of catalyst.
sudo rm -rf src/build

enter sudo /mnt/host/source/src/scripts/build_toolchains \
    --sign="${SIGNING_USER}" \
    --sign_digests="${SIGNING_USER}" \
    --upload_root="${UPLOAD_ROOT}" \
    --upload
