# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

GSUTIL_OPTS=
UPLOAD_ROOT="gs://storage.core-os.net/coreos"


IMAGE_ZIPPER="lbzip2 --compress --keep"
IMAGE_ZIPEXT=".bz2"

DEFINE_boolean parallel ${FLAGS_TRUE} \
  "Enable parallelism in gsutil."
DEFINE_boolean upload ${FLAGS_FALSE} \
  "Upload all packages/images via gsutil."

check_gsutil_opts() {
    [[ ${FLAGS_upload} -eq ${FLAGS_TRUE} ]] || return 0

    if [[ ${FLAGS_parallel} -eq ${FLAGS_TRUE} ]]; then
        GSUTIL_OPTS="-m"
    fi

    if [[ ! -f "$HOME/.boto" ]]; then
        die_notrace "Please run gsutil config to create ~/.boto"
    fi
}

upload_packages() {
    [[ ${FLAGS_upload} -eq ${FLAGS_TRUE} ]] || return 0
    [[ -n "${BOARD}" ]] || die "board_options.sh must be sourced first"

    local BOARD_PACKAGES="${1:-"${BOARD_ROOT}/packages"}"
    local UPLOAD_PATH="${UPLOAD_ROOT}/${BOARD}/${COREOS_VERSION_STRING}/pkgs/"
    info "Uploading packages"
    gsutil ${GSUTIL_OPTS} cp -R "${BOARD_PACKAGES}"/* "${UPLOAD_PATH}"
}

make_digests() {
    local dirname=$(dirname "$1")
    local filename=$(basename "$1")
    cd "${dirname}"
    info "Computing DIGESTS for ${filename}"
    echo -n > "${filename}.DIGESTS"
    for hash in md5 sha1 sha512; do
        echo "# $hash HASH" | tr "a-z" "A-Z" >> "${filename}.DIGESTS"
        ${hash}sum "${filename}" >> "${filename}.DIGESTS"
    done
    cd -
}

upload_image() {
    [[ ${FLAGS_upload} -eq ${FLAGS_TRUE} ]] || return 0
    [[ -n "${BOARD}" ]] || die "board_options.sh must be sourced first"

    local BUILT_IMAGE="$1"
    local UPLOAD_PATH="${UPLOAD_ROOT}/${BOARD}/${COREOS_VERSION_STRING}/"

    if [[ ! -f "${BUILT_IMAGE}" ]]; then
        die "Image '${BUILT_IMAGE}' does not exist!"
    fi

    # Compress raw images
    if [[ "${BUILT_IMAGE}" =~ \.(img|bin)$ ]]; then
        info "Compressing ${BUILT_IMAGE##*/}"
        $IMAGE_ZIPPER "${BUILT_IMAGE}"
        BUILT_IMAGE="${BUILT_IMAGE}${IMAGE_ZIPEXT}"
    fi

    # For consistency generate a .DIGESTS file similar to the one catalyst
    # produces for the SDK tarballs and up upload it too.
    make_digests "${BUILT_IMAGE}"

    info "Uploading ${BUILT_IMAGE##*/}"
    gsutil ${GSUTIL_OPTS} cp "${BUILT_IMAGE}" \
        "${BUILT_IMAGE}.DIGESTS" "${UPLOAD_PATH}"
}
