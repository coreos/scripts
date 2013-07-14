# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

GSUTIL_OPTS=
UPLOAD_ROOT="gs://storage.core-os.net/coreos"
UPLOAD_PATH=
UPLOAD_DEFAULT=${FLAGS_FALSE}
if [[ ${COREOS_OFFICIAL:-0} -eq 1 ]]; then
  UPLOAD_DEFAULT=${FLAGS_TRUE}
fi

IMAGE_ZIPPER="lbzip2 --compress --keep"
IMAGE_ZIPEXT=".bz2"

DEFINE_boolean parallel ${FLAGS_TRUE} \
  "Enable parallelism in gsutil."
DEFINE_boolean upload ${UPLOAD_DEFAULT} \
  "Upload all packages/images via gsutil."
DEFINE_string upload_path "" \
  "Upload files to an alternative location. Must be a full gs:// URL."

check_gsutil_opts() {
    [[ ${FLAGS_upload} -eq ${FLAGS_TRUE} ]] || return 0

    if [[ ${FLAGS_parallel} -eq ${FLAGS_TRUE} ]]; then
        GSUTIL_OPTS="-m"
    fi

    if [[ -n "${FLAGS_upload_path}" ]]; then
        # Make sure the path doesn't end with a slash
        UPLOAD_PATH="${FLAGS_upload_path%%/}"
    fi

    # Search for .boto, may be run via sudo
    local boto
    for boto in "$HOME/.boto" "/home/$SUDO_USER/.boto"; do
        if [[ -f "$boto" ]]; then
            info "Using boto config $boto"
            export BOTO_CONFIG="$boto"
            break
        fi
    done
    if [[ ! -f "$BOTO_CONFIG" ]]; then
        die_notrace "Please run gsutil config to create ~/.boto"
    fi
}

# Generic upload function
# Usage: upload_files "file type" "${UPLOAD_ROOT}/default/path" "" files...
#  arg1: file type reported via log
#  arg2: default upload path, overridden by --upload_path
#  arg3: upload path suffix that can't be overridden, must end in /
#  argv: remaining args are files or directories to upload
upload_files() {
    [[ ${FLAGS_upload} -eq ${FLAGS_TRUE} ]] || return 0

    local msg="$1"
    local local_upload_path="$2"
    local extra_upload_suffix="$3"
    shift 3

    if [[ -n "${UPLOAD_PATH}" ]]; then
        local_upload_path="${UPLOAD_PATH}"
    fi

    if [[ -n "${extra_upload_suffix}" && "${extra_upload_suffix}" != */ ]]
    then
        die "upload suffix '${extra_upload_suffix}' doesn't end in /"
    fi

    info "Uploading ${msg} to ${local_upload_path}"
    gsutil ${GSUTIL_OPTS} cp -R "$@" \
        "${local_upload_path}/${extra_upload_suffix}"
}

upload_packages() {
    [[ ${FLAGS_upload} -eq ${FLAGS_TRUE} ]] || return 0
    [[ -n "${BOARD}" ]] || die "board_options.sh must be sourced first"

    local board_packages="${1:-"${BOARD_ROOT}/packages"}"
    local def_upload_path="${UPLOAD_ROOT}/${BOARD}/${COREOS_VERSION_STRING}"
    upload_files packages ${def_upload_path} "pkgs/" "${board_packages}"/*
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

    local log_msg="${BUILT_IMAGE##*/}"
    local def_upload_path="${UPLOAD_ROOT}/${BOARD}/${COREOS_VERSION_STRING}"
    upload_files "${log_msg}" "${def_upload_path}" "" \
        "${BUILT_IMAGE}" "${BUILT_IMAGE}.DIGESTS"
}
