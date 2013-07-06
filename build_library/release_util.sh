# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

GSUTIL_OPTS=
UPLOAD_ROOT="gs://storage.core-os.net/coreos"
UPLOAD_DEFAULT=${FLAGS_FALSE}
if [[ ${COREOS_OFFICIAL:-0} -eq 1 ]]; then
  UPLOAD_DEFAULT=${FLAGS_TRUE}
fi

DEFINE_boolean parallel ${FLAGS_TRUE} \
  "Enable parallelism in gsutil."
DEFINE_boolean upload ${UPLOAD_DEFAULT} \
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
