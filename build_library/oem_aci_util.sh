# Copyright (c) 2016 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Expects BOARD, BUILD_DIR, BUILD_LIBRARY_DIR, and COREOS_VERSION in env.

# There must be a manifest template included with the ebuild at
# files/manifest.in, which will have some variable values substituted before
# being written into place for the ACI.  Optionally, a shell script can also be
# included at files/manglefs.sh to be run after all packages are installed.  It
# is intended to be used to make modifications to the file system layout and
# program paths that some included agent software might expect.

# Copied from create_prod_image()
create_oem_aci_image() {
    local image_name="$1"
    local disk_layout="$2"
    local update_group="$3"
    local base_pkg="${4?No base package was specified}"

    info "Building OEM ACI staging image ${image_name}"
    local root_fs_dir="${BUILD_DIR}/rootfs"
    local image_contents="${image_name%.bin}_contents.txt"
    local image_packages="${image_name%.bin}_packages.txt"
    local image_licenses="${image_name%.bin}_licenses.txt"

    start_image \
        "${image_name}" "${disk_layout}" "${root_fs_dir}" "${update_group}"

    # Install minimal GCC (libs only) and then everything else
    set_image_profile oem-aci
    extract_prod_gcc "${root_fs_dir}"
    emerge_to_image "${root_fs_dir}" "${base_pkg}"
    run_ldconfig "${root_fs_dir}"
    write_packages "${root_fs_dir}" "${BUILD_DIR}/${image_packages}"
    write_licenses "${root_fs_dir}" "${BUILD_DIR}/${image_licenses}"

    # clean-ups of things we do not need
    sudo rm ${root_fs_dir}/etc/csh.env
    sudo rm -rf ${root_fs_dir}/etc/env.d
    sudo rm -rf ${root_fs_dir}/var/db/pkg

    sudo mv ${root_fs_dir}/etc/profile.env \
        ${root_fs_dir}/usr/share/baselayout/profile.env

    # Move the ld.so configs into /usr so they can be symlinked from /
    sudo mv ${root_fs_dir}/etc/ld.so.conf ${root_fs_dir}/usr/lib
    sudo mv ${root_fs_dir}/etc/ld.so.conf.d ${root_fs_dir}/usr/lib

    sudo ln --symbolic ../usr/lib/ld.so.conf ${root_fs_dir}/etc/ld.so.conf

    # Add a tmpfiles rule that symlink ld.so.conf from /usr into /
    sudo tee "${root_fs_dir}/usr/lib/tmpfiles.d/baselayout-ldso.conf" \
        > /dev/null <<EOF
L+  /etc/ld.so.conf     -   -   -   -   ../usr/lib/ld.so.conf
EOF

    # Move the PAM configuration into /usr
    sudo mkdir -p ${root_fs_dir}/usr/lib/pam.d
    sudo mv -n ${root_fs_dir}/etc/pam.d/* ${root_fs_dir}/usr/lib/pam.d/
    sudo rmdir ${root_fs_dir}/etc/pam.d

    # Take the non-kernel-related bits from finish_image().
    rm -rf "${BUILD_DIR}"/configroot
    cleanup_mounts "${root_fs_dir}"
    trap - EXIT
}

oem_aci_write_manifest() {
    local manifest_template="${1?No input path was specified}"
    local manifest="${2?No output path was specified}"
    local name="${3?No ACI name was specified}"
    local appc_arch=

    case "${BOARD}" in
        amd64-usr) appc_arch=amd64 ;;
        arm64-usr) appc_arch=aarch64 ;;
        *) die_notrace "Cannot map \"${BOARD}\" to an appc arch" ;;
    esac

    sudo cp "${manifest_template}" "${manifest}"
    sudo sed "${manifest}" -i \
        -e "s,@ACI_NAME@,${name}," \
        -e "s,@ACI_VERSION@,${COREOS_VERSION}," \
        -e "s,@ACI_ARCH@,${appc_arch},"
}

oem_aci_create() {
    local aciroot="${BUILD_DIR}"
    local oem="${1?No OEM was specified}"
    local base_pkg="coreos-base/coreos-oem-${oem}"
    local ebuild=$(equery-"${BOARD}" w "${base_pkg}" 2>/dev/null)
    local staging_image="coreos_oem_${oem}_aci_stage.bin"

    [ -n "${ebuild}" ] || die_notrace "No ebuild exists for OEM \"${oem}\""
    grep -Fqs '(meta package)' "${ebuild}" ||
        die_notrace "The \"${base_pkg}\" ebuild is not a meta package"

    # Build a staging image for this OEM.
    create_oem_aci_image "${staging_image}" container stable "${base_pkg}"

    # Remount the staging image to brutalize the rootfs for broken services.
    "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout=container \
        mount "${BUILD_DIR}/${staging_image}" "${aciroot}/rootfs"
    trap "cleanup_mounts '${aciroot}/rootfs' && delete_prompt" EXIT
    [ -r "${ebuild%/*}/files/manglefs.sh" ] &&
        sudo sh -c "cd '${aciroot}/rootfs' && . '${ebuild%/*}/files/manglefs.sh'"

    # Substitute variables into the OEM manifest to produce the final version.
    oem_aci_write_manifest \
        "${ebuild%/*}/files/manifest.in" \
        "${aciroot}/manifest" \
        "coreos.com/oem-${oem}"

    # Write a tar ACI file containing the manifest and mounted rootfs contents.
    sudo tar -C "${aciroot}" -czf "${BUILD_DIR}/coreos-oem-${oem}.aci" \
        manifest rootfs

    # Unmount the staging image, and delete it to save space.
    cleanup_mounts "${aciroot}/rootfs"
    trap - EXIT
    rm -f "${BUILD_DIR}/${staging_image}"
}
