# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

GSUTIL_OPTS=
UPLOAD_ROOT=
UPLOAD_PATH=
TORCX_UPLOAD_ROOT=
UPLOAD_DEFAULT=${FLAGS_FALSE}

# Default upload root can be overridden from the environment.
_user="${USER}"
[[ ${USER} == "root" ]] && _user="${SUDO_USER}"
: ${COREOS_UPLOAD_ROOT:=gs://users.developer.core-os.net/${_user}}
: ${COREOS_TORCX_UPLOAD_ROOT:=${COREOS_UPLOAD_ROOT}/torcx}
unset _user

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
DEFINE_string download_root "" \
  "HTTP download prefix, board/version/etc will be appended."
DEFINE_string download_path "" \
  "HTTP download path, overrides --download_root."
DEFINE_string torcx_upload_root "${COREOS_TORCX_UPLOAD_ROOT}" \
  "Tectonic torcx package and manifest Upload prefix. Must be a gs:// URL."
DEFINE_string tectonic_torcx_download_root "" \
  "HTTP download prefix for tectonic torcx packages and manifests."
DEFINE_string tectonic_torcx_download_path "" \
  "HTTP download path, overrides --tectonic_torcx_download_root."
DEFINE_string sign "" \
  "Sign all files to be uploaded with the given GPG key."
DEFINE_string signing_pin "" \
  "Pass this pin as a gpg --passphrase for GPG signing, for use with --sign"
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

    if [[ -n "${FLAGS_torcx_upload_root}" ]]; then
        if [[ "${FLAGS_torcx_upload_root}" != gs://* ]]; then
            die_notrace "--torcx_upload_root must be a gs:// URL"
        fi
        # Make sure the path doesn't end with a slash
        TORCX_UPLOAD_ROOT="${FLAGS_torcx_upload_root%%/}"
    fi

    if [[ -n "${FLAGS_upload_path}" ]]; then
        if [[ "${FLAGS_upload_path}" != gs://* ]]; then
            die_notrace "--upload_path must be a gs:// URL"
        fi
        # Make sure the path doesn't end with a slash
        UPLOAD_PATH="${FLAGS_upload_path%%/}"
    fi

    # Ensure scripts run via sudo can use the user's gsutil/boto configuration.
    if [[ -n "${SUDO_USER}" ]]; then
        : ${BOTO_PATH:="$HOME/.boto:/home/$SUDO_USER/.boto"}
        export BOTO_PATH
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


# Identical to upload_files but GPG signs every file if enabled.
# Usage: sign_and_upload_files "file type" "${UPLOAD_ROOT}/default/path" "" files...
#  arg1: file type reported via log
#  arg2: default upload path, overridden by --upload_path
#  arg3: upload path suffix that can't be overridden, must end in /
#  argv: remaining args are files or directories to upload
sign_and_upload_files() {
    [[ ${FLAGS_upload} -eq ${FLAGS_TRUE} ]] || return 0

    local msg="$1"
    local path="$2"
    local suffix="$3"
    shift 3

    # Create simple GPG detached signature for all uploads.
    local sigs=()
    if [[ -n "${FLAGS_sign}" ]]; then
        local file
        local sigfile
        local sigdir=$(mktemp --directory)
        trap "rm -rf ${sigdir}" RETURN
        for file in "$@"; do
            if [[ "${file}" =~ \.(asc|gpg|sig)$ ]]; then
                continue
            fi

            for sigfile in $(find "${file}" ! -type d); do
                mkdir -p "${sigdir}/${sigfile%/*}"
                gpgsign "${sigfile}" "${sigdir}/${sigfile}.sig"
            done

            [ -d "${file}" ] &&
            sigs+=( "${sigdir}/${file}" ) ||
            sigs+=( "${sigdir}/${file}.sig" )
        done
    fi

    upload_files "${msg}" "${path}" "${suffix}" "$@" "${sigs[@]}"
}

gpgsign() {
  local file="$1"
  local sig="$2"

  if [[ -n "${FLAGS_signing_pin}" ]]; then
    gpg --batch --no-tty --pinentry-mode loopback \
        --passphrase "${FLAGS_signing_pin}" \
        --local-user "${FLAGS_sign}" \
        --output "${sig}" \
        --detach-sign "${file}" || die "gpg failed"

  else
    gpg --batch --local-user "${FLAGS_sign}" \
        --output "${sig}" \
        --detach-sign "${file}" || die "gpg failed"
  fi
}

upload_packages() {
    [[ ${FLAGS_upload} -eq ${FLAGS_TRUE} ]] || return 0
    [[ -n "${BOARD}" ]] || die "board_options.sh must be sourced first"

    local board_packages="${1:-"${BOARD_ROOT}/packages"}"
    local def_upload_path="${UPLOAD_ROOT}/boards/${BOARD}/${COREOS_VERSION}"
    sign_and_upload_files packages ${def_upload_path} "pkgs/" \
        "${board_packages}"/*
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
    local def_upload_path="${UPLOAD_ROOT}/boards/${BOARD}/${COREOS_VERSION}"
    sign_and_upload_files "${log_msg}" "${def_upload_path}" "" "${uploads[@]}"
}

# Translate the configured upload URL to a download URL
# Usage: download_image_url "path/suffix"
download_image_url() {
    if [[ ${FLAGS_upload} -ne ${FLAGS_TRUE} ]]; then
        echo "$1"
        return 0
    fi

    local download_root="${FLAGS_download_root:-${UPLOAD_ROOT}}"

    local download_path
    if [[ -n "${FLAGS_download_path}" ]]; then
        download_path="${FLAGS_download_path%%/}"
    elif [[ "${download_root}" = *release.core-os.net* ]]; then
        # Official release download paths don't include the boards directory
        download_path="${download_root%%/}/${BOARD}/${COREOS_VERSION}"
    else
        download_path="${download_root%%/}/boards/${BOARD}/${COREOS_VERSION}"
    fi

    # Just in case download_root was set from UPLOAD_ROOT
    if [[ "${download_path}" == gs://* ]]; then
        download_path="http://${download_path#gs://}"
    fi

    echo "${download_path}/$1"
}

# Translate the configured torcx upload URL to a download url
# This is similar to the download_image_url, other than assuming the release
# bucket is the tectonic_torcx one.
download_tectonic_torcx_url() {
    if [[ ${FLAGS_upload} -ne ${FLAGS_TRUE} ]]; then
        echo "$1"
        return 0
    fi

    local download_root="${FLAGS_tectonic_torcx_download_root:-${TORCX_UPLOAD_ROOT}}"

    local download_path
    if [[ -n "${FLAGS_tectonic_torcx_download_path}" ]]; then
        download_path="${FLAGS_tectonic_torcx_download_path%%/}"
    else
        download_path="${download_root%%/}"
    fi

    # Just in case download_root was set from UPLOAD_ROOT
    if [[ "${download_path}" == gs://* ]]; then
        download_path="http://${download_path#gs://}"
    fi

    echo "${download_path}/$1"
}
