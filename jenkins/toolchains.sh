#!/bin/bash -ex

enter() {
        bin/cork enter --bind-gpg-agent -- "$@"
}

source .repo/manifests/version.txt
export COREOS_BUILD_ID

# Set up GPG for signing uploads.
gpg --import "${GPG_SECRET_KEY_FILE}"

# Wipe all of catalyst.
sudo rm -rf src/build

S=/mnt/host/source/src/scripts
enter sudo emerge -uv --jobs=2 catalyst
enter sudo ${S}/build_toolchains \
    --sign="${SIGNING_USER}" \
    --signing_pin="${GPG_SECRET_KEY_PIN-}" \
    --sign_digests="${SIGNING_USER}" \
    --upload_root="${UPLOAD_ROOT}" \
    --upload

# Free some disk space only on success to allow debugging failures.
sudo rm -rf src/build/catalyst/builds
