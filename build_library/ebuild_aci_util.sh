# Copyright (c) 2016 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Expects BOARD, BUILD_DIR, BUILD_LIBRARY_DIR, and COREOS_VERSION in env.

# Copied from create_prod_image()
create_ebuild_aci_image() {
    local image_name="$1"
    local disk_layout="$2"
    local update_group="$3"
    local pkg="$4"

    info "Building ACI staging image ${image_name}"
    local root_fs_dir="${BUILD_DIR}/rootfs"
    local image_contents="${image_name%.bin}_contents.txt"
    local image_packages="${image_name%.bin}_packages.txt"
    local image_licenses="${image_name%.bin}_licenses.json"

    start_image \
        "${image_name}" "${disk_layout}" "${root_fs_dir}" "${update_group}"

    # Install minimal GCC (libs only) and then everything else
    extract_prod_gcc "${root_fs_dir}"

    emerge_to_image_unchecked "${root_fs_dir}" "${pkg}"
    run_ldconfig "${root_fs_dir}"
    write_packages "${root_fs_dir}" "${BUILD_DIR}/${image_packages}"
    write_licenses "${root_fs_dir}" "${BUILD_DIR}/${image_licenses}"

    cleanup_mounts "${root_fs_dir}"
    trap - EXIT
}

ebuild_aci_write_manifest() {
    local manifest="${1?No output path was specified}"
    local name="${2?No ACI name was specified}"
    local version="${3?No ACI version was specified}"
    local appc_arch=

    case "${BOARD}" in
        amd64-usr) appc_arch=amd64 ;;
        *) die_notrace "Cannot map \"${BOARD}\" to an appc arch" ;;
    esac

    sudo cp "${BUILD_LIBRARY_DIR}/ebuild_aci_manifest.in" "${manifest}"
    sudo sed "${manifest}" -i \
        -e "s,@ACI_NAME@,${name}," \
        -e "s,@ACI_VERSION@,${version}," \
        -e "s,@ACI_ARCH@,${appc_arch},"
}

ebuild_aci_create() {
    local aciroot="${BUILD_DIR}"
    local aci_name="${1?No aci name was specified}"; shift
    local output_image="${1?No output file specified}"; shift
    local pkg="${1?No package given}"; shift
    local version="${1?No package version given}"; shift
    local extra_version="${1?No extra version number given}"; shift
    local pkg_files=( "${@}" )

    local staging_image="coreos_pkg_staging_aci_stage.bin"

    local ebuild_atom="=${pkg}-${version}"

    local ebuild=$(equery-"${BOARD}" w "${ebuild_atom}" 2>/dev/null)
    [ -n "${ebuild}" ] || die_notrace "No ebuild exists for ebuild \"${pkg}\""

    # Build a staging image for this ebuild.
    create_ebuild_aci_image "${staging_image}" container stable "${ebuild_atom}"

    # Remount the staging image to brutalize the rootfs for broken services.
    "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout=container \
        mount "${BUILD_DIR}/${staging_image}" "${aciroot}/rootfs"
    trap "cleanup_mounts '${aciroot}/rootfs' && delete_prompt" EXIT

    # Substitute variables into the manifest to produce the final version.
    ebuild_aci_write_manifest \
        "${aciroot}/manifest" \
        "${aci_name}" \
        "${version}_coreos.${extra_version}"

    local pkg_files_in_rootfs=( "${pkg_files[@]/#/rootfs}" )

    # Write a tar ACI file containing the manifest and desired parts of the mounted rootfs
    sudo tar -C "${aciroot}" -hczf "${BUILD_DIR}/${output_image}.aci" \
        manifest ${pkg_files_in_rootfs[@]}

    # Unmount the staging image, and delete it to save space.
    cleanup_mounts "${aciroot}/rootfs"
    trap - EXIT
    rm -f "${BUILD_DIR}/${staging_image}"

    echo "Created aci for ${pkg}-${version}: ${BUILD_DIR}/${output_image}.aci"
}
