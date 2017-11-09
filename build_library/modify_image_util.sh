#!/bin/bash

# Copyright (c) 2014 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Shell library for modifying an image built with build_image.

start_modify_image() {
    # Default to the most recent image
    if [[ -z "${FLAGS_from}" ]] ; then
        FLAGS_from="$(${SCRIPT_ROOT}/get_latest_image.sh --board=${FLAGS_board})"
    else
        FLAGS_from="$(readlink -f "${FLAGS_from}")"
    fi

    local src_image="${FLAGS_from}/${COREOS_PRODUCTION_IMAGE_NAME}"
    if [[ ! -f "${src_image}" ]]; then
        die_notrace "Source image does not exist: ${src_image}"
    fi

    # Source should include version.txt, switch to its version information
    if [[ ! -f "${FLAGS_from}/version.txt" ]]; then
        die_notrace "Source version info does not exist: ${FLAGS_from}/version.txt"
    fi
    source "${FLAGS_from}/version.txt"
    COREOS_VERSION_STRING="${COREOS_VERSION}"

    # Load after version.txt to set the correct output paths
    . "${BUILD_LIBRARY_DIR}/toolchain_util.sh"
    . "${BUILD_LIBRARY_DIR}/board_options.sh"
    . "${BUILD_LIBRARY_DIR}/build_image_util.sh"

    # Handle existing directory.
    if [[ -e "${BUILD_DIR}" ]]; then
        if [[ ${FLAGS_replace} -eq ${FLAGS_TRUE} ]]; then
            sudo rm -rf "${BUILD_DIR}"
        else
            error "Directory ${BUILD_DIR} already exists."
            error "Use --build_attempt option to specify an unused attempt."
            error "Or use --replace if you want to overwrite this directory."
            die "Unwilling to overwrite ${BUILD_DIR}."
        fi
    fi

    # Create the output directory and temporary mount points.
    DST_IMAGE="${BUILD_DIR}/${COREOS_PRODUCTION_IMAGE_NAME}"
    ROOT_FS_DIR="${BUILD_DIR}/rootfs"
    mkdir -p "${ROOT_FS_DIR}"

    info "Copying from ${FLAGS_from}"
    cp "${src_image}" "${DST_IMAGE}"

    # Copy all extra useful things, these do not need to be modified.
    local update_prefix="${COREOS_PRODUCTION_IMAGE_NAME%_image.bin}_update"
    local production_prefix="${COREOS_PRODUCTION_IMAGE_NAME%.bin}"
    local container_prefix="${COREOS_DEVELOPER_CONTAINER_NAME%.bin}"
    local pcr_data="${COREOS_PRODUCTION_IMAGE_NAME%.bin}_pcr_policy.zip"
    EXTRA_FILES=(
        "version.txt"
        "${update_prefix}.bin"
        "${update_prefix}.zip"
        "${pcr_data}"
        "${production_prefix}_contents.txt"
        "${production_prefix}_packages.txt"
        "${production_prefix}_kernel_config.txt"
        "${COREOS_DEVELOPER_CONTAINER_NAME}"
        "${container_prefix}_contents.txt"
        "${container_prefix}_packages.txt"
        )
    for filename in "${EXTRA_FILES[@]}"; do
        if [[ -e "${FLAGS_from}/${filename}" ]]; then
            cp "${FLAGS_from}/${filename}" "${BUILD_DIR}/${filename}"
        fi
    done

    "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${FLAGS_disk_layout}" \
            mount "${DST_IMAGE}" "${ROOT_FS_DIR}"
    trap "cleanup_mounts '${ROOT_FS_DIR}'" EXIT
}

finish_modify_image() {
    cleanup_mounts "${ROOT_FS_DIR}"
    trap - EXIT

    upload_image "${DST_IMAGE}"
    for filename in "${EXTRA_FILES[@]}"; do
        if [[ -e "${BUILD_DIR}/${filename}" ]]; then
            upload_image "${BUILD_DIR}/${filename}"
        fi
    done

    set_build_symlinks "${FLAGS_group}-latest"

    info "Done. Updated image is in ${BUILD_DIR}"
    cat << EOF
To convert it to a virtual machine image, use:
  ./image_to_vm.sh --from=${OUTSIDE_OUTPUT_DIR} --board=${BOARD} --prod_image

The default type is qemu, see ./image_to_vm.sh --help for other options.
EOF
}
