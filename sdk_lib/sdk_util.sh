#!/bin/bash

# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# common.sh must be properly sourced before this file.
[[ -n "${COREOS_SDK_VERSION}" ]] || exit 1

COREOS_SDK_ARCH="amd64" # We are unlikely to support anything else.
COREOS_SDK_TARBALL="coreos-sdk-${COREOS_SDK_ARCH}-${COREOS_SDK_VERSION}.tar.bz2"
COREOS_SDK_TARBALL_CACHE="${REPO_CACHE_DIR}/sdks"
COREOS_SDK_TARBALL_PATH="${COREOS_SDK_TARBALL_CACHE}/${COREOS_SDK_TARBALL}"
COREOS_SDK_URL="${COREOS_DOWNLOAD_ROOT}/sdk/${COREOS_SDK_ARCH}/${COREOS_SDK_VERSION}/${COREOS_SDK_TARBALL}"

# Download the current SDK tarball (if required) and verify digests/sig
sdk_download_tarball() {
    if sdk_verify_digests; then
        return 0
    fi

    info "Downloading ${COREOS_SDK_TARBALL}"
    info "URL: ${COREOS_SDK_URL}"
    local suffix
    for suffix in "" ".DIGESTS"; do # TODO(marineam): download .asc
        wget --tries=3 --timeout=30 --continue \
            -O  "${COREOS_SDK_TARBALL_PATH}${suffix}" \
            "${COREOS_SDK_URL}${suffix}" \
            || die_notrace "SDK download failed!"
    done

    sdk_verify_digests || die_notrace "SDK digest verification failed!"
    sdk_clean_cache
}

sdk_verify_digests() {
    if [[ ! -f "${COREOS_SDK_TARBALL_PATH}" || \
          ! -f "${COREOS_SDK_TARBALL_PATH}.DIGESTS" ]]; then
        return 1
    fi

    # TODO(marineam): Add gpg signature verification too.

    verify_digests "${COREOS_SDK_TARBALL_PATH}" || return 1
}

sdk_clean_cache() {
    pushd "${COREOS_SDK_TARBALL_CACHE}" >/dev/null
    local filename
    for filename in *; do
        if [[ "${filename}" == "${COREOS_SDK_TARBALL}"* ]]; then
            continue
        fi
        info "Cleaning up ${filename}"
        # Not a big deal if this fails
        rm -f "${filename}" || true
    done
    popd >/dev/null
}
