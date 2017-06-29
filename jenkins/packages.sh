#!/bin/bash -ex

# Use a ccache dir that persists across SDK recreations.
# XXX: alternatively use a ccache dir that is usable by all jobs on a given node.
mkdir -p .cache/ccache

enter() {
        local verify_key=
        trap 'sudo rm -f chroot/etc/portage/gangue.*' RETURN
        [ -s verify.asc ] &&
        sudo ln -f verify.asc chroot/etc/portage/gangue.asc &&
        verify_key=--verify-key=/etc/portage/gangue.asc
        sudo ln -f "${GOOGLE_APPLICATION_CREDENTIALS}" \
            chroot/etc/portage/gangue.json
        bin/cork enter --experimental -- env \
            CCACHE_DIR=/mnt/host/source/.cache/ccache \
            CCACHE_MAXSIZE=5G \
            COREOS_DEV_BUILDS="${DOWNLOAD_ROOT}" \
            PORTAGE_SSH_OPTS= \
            {FETCH,RESUME}COMMAND_GS="/usr/bin/gangue get \
--json-key=/etc/portage/gangue.json $verify_key \
"'"${URI}" "${DISTDIR}/${FILE}"' \
            "$@"
}

script() {
        enter "/mnt/host/source/src/scripts/$@"
}

sudo cp bin/gangue chroot/usr/bin/gangue  # XXX: until SDK mantle has it

source .repo/manifests/version.txt
export COREOS_BUILD_ID

# Set up GPG for signing uploads.
gpg --import "${GPG_SECRET_KEY_FILE}"

# Figure out if ccache is doing us any good in this scheme.
enter ccache --zero-stats

script setup_board \
    --board="${BOARD}" \
    --getbinpkgver=${RELEASE_BASE:-"${COREOS_VERSION}" --toolchainpkgonly} \
    --skip_chroot_upgrade \
    --force

script build_packages \
    --board="${BOARD}" \
    --getbinpkgver=${RELEASE_BASE:-"${COREOS_VERSION}" --toolchainpkgonly} \
    --skip_chroot_upgrade \
    $([ -x src/scripts/build_torcx_store ] && echo --skip_torcx_store) \
    --sign="${SIGNING_USER}" \
    --sign_digests="${SIGNING_USER}" \
    --upload_root="${UPLOAD_ROOT}" \
    --upload

# Build and upload torcx images if this version supports it.
[ -x src/scripts/build_torcx_store ] &&
script build_torcx_store \
    --board="${BOARD}" \
    --sign="${SIGNING_USER}" \
    --sign_digests="${SIGNING_USER}" \
    --upload_root="${UPLOAD_ROOT}" \
    --upload

enter ccache --show-stats
