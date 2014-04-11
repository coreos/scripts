# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

GSUTIL_OPTS=
UPLOAD_ROOT=
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
DEFINE_string upload_root "${COREOS_UPLOAD_ROOT}" \
  "Upload prefix, board/version/etc will be appended. Must be a gs:// URL."
DEFINE_string upload_path "" \
  "Full upload path, overrides --upload_root. Must be a full gs:// URL."
DEFINE_string sign_digests "" \
  "Sign image DIGESTS files with the given GPG key."

check_gsutil_opts() {
    [[ ${FLAGS_upload} -eq ${FLAGS_TRUE} ]] || return 0

    if [[ ${FLAGS_parallel} -eq ${FLAGS_TRUE} ]]; then
        GSUTIL_OPTS="-m"
    fi

    if [[ -n "${FLAGS_upload_root}" ]]; then
        if [[ "${FLAGS_upload_root}" != gs://* ]]; then
            die_notrace "--upload_root must be a gs:// URL"
        fi
        # Make sure the path doesn't end with a slash
        UPLOAD_ROOT="${FLAGS_upload_root%%/}"
    fi

    if [[ -n "${FLAGS_upload_path}" ]]; then
        if [[ "${FLAGS_upload_path}" != gs://* ]]; then
            die_notrace "--upload_path must be a gs:// URL"
        fi
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

# Upload a set of files (usually images) and digest, optionally w/ gpg sig
# If more than one file is specified -d must be the first argument
# Usage: upload_image [-d file.DIGESTS] file1 [file2...]
upload_image() {
    [[ ${FLAGS_upload} -eq ${FLAGS_TRUE} ]] || return 0
    [[ -n "${BOARD}" ]] || die "board_options.sh must be sourced first"

    # The name to use for .DIGESTS and .DIGESTS.asc must be explicit if
    # there is more than one file to upload to avoid potential confusion.
    local digests
    if [[ "$1" == "-d" ]]; then
        [[ -n "$2" ]] || die "-d requires an argument"
        digests="$2"
        shift 2
    else
        [[ $# -eq 1 ]] || die "-d is required for multi-file uploads"
        # digests is assigned after image is possibly compressed/renamed
    fi

    local uploads=()
    local filename
    for filename in "$@"; do
        if [[ ! -f "${filename}" ]]; then
            die "File '${filename}' does not exist!"
        fi

        # Compress disk images
        if [[ "${filename}" =~ \.(img|bin|vdi|vhd|vmdk)$ ]]; then
            info "Compressing ${filename##*/}"
            $IMAGE_ZIPPER -f "${filename}"
            uploads+=( "${filename}${IMAGE_ZIPEXT}" )
        else
            uploads+=( "${filename}" )
        fi
    done

    if [[ -z "${digests}" ]]; then
        digests="${uploads[0]}.DIGESTS"
    fi

    # For consistency generate a .DIGESTS file similar to the one catalyst
    # produces for the SDK tarballs and up upload it too.
    make_digests -d "${digests}" "${uploads[@]}"
    uploads+=( "${digests}" )

    # Create signature as ...DIGESTS.asc as Gentoo does.
    if [[ -n "${FLAGS_sign_digests}" ]]; then
      rm -f "${digests}.asc"
      gpg --batch --local-user "${FLAGS_sign_digests}" \
          --clearsign "${digests}" || die "gpg failed"
      uploads+=( "${digests}.asc" )
    fi

    local log_msg=$(basename "$digests" .DIGESTS)
    local def_upload_path="${UPLOAD_ROOT}/${BOARD}/${COREOS_VERSION_STRING}"
    upload_files "${log_msg}" "${def_upload_path}" "" "${uploads[@]}"
}
