# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Shell library for functions and initialization private to
# build_image, and not specific to any particular kind of image.
#
# TODO(jrbarnette):  There's nothing holding this code together in
# one file aside from its lack of anywhere else to go.  Probably,
# this file should get broken up or otherwise reorganized.

# Use canonical path since some tools (e.g. mount) do not like symlinks.
# Append build attempt to output directory.
if [ -z "${FLAGS_version}" ]; then
  IMAGE_SUBDIR="${FLAGS_group}-${COREOS_VERSION_STRING}-a${FLAGS_build_attempt}"
else
  IMAGE_SUBDIR="${FLAGS_group}-${FLAGS_version}"
fi
BUILD_DIR="${FLAGS_output_root}/${BOARD}/${IMAGE_SUBDIR}"
OUTSIDE_OUTPUT_DIR="../build/images/${BOARD}/${IMAGE_SUBDIR}"

set_build_symlinks() {
    local build=$(basename ${BUILD_DIR})
    local link
    for link in "$@"; do
        local path="${FLAGS_output_root}/${BOARD}/${link}"
        ln -sfT "${build}" "${path}"
    done
}

cleanup_mounts() {
  echo "Cleaning up mounts"
  "${BUILD_LIBRARY_DIR}/disk_util" umount "$1" || true
}

delete_prompt() {
  echo "An error occurred in your build so your latest output directory" \
    "is invalid."

  # Only prompt if both stdin and stdout are a tty. If either is not a tty,
  # then the user may not be present, so we shouldn't bother prompting.
  if [ -t 0 -a -t 1 ]; then
    read -p "Would you like to delete the output directory (y/N)? " SURE
    SURE="${SURE:0:1}" # Get just the first character.
  else
    SURE="y"
    echo "Running in non-interactive mode so deleting output directory."
  fi
  if [ "${SURE}" == "y" ] ; then
    sudo rm -rf "${BUILD_DIR}"
    echo "Deleted ${BUILD_DIR}"
  else
    echo "Not deleting ${BUILD_DIR}."
  fi
}

extract_update() {
  local image_name="$1"
  local disk_layout="$2"
  local update_path="${BUILD_DIR}/${image_name%_image.bin}_update.bin"

  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
    extract "${BUILD_DIR}/${image_name}" "USR-A" "${update_path}"
  upload_image "${update_path}"
}

zip_update_tools() {
  # There isn't a 'dev' variant of this zip, so always call it production.
  local update_zip="coreos_production_update.zip"

  info "Generating update tools zip"
  # Make sure some vars this script needs are exported
  export REPO_MANIFESTS_DIR SCRIPTS_DIR
  "${BUILD_LIBRARY_DIR}/generate_au_zip.py" \
    --output-dir "${BUILD_DIR}" --zip-name "${update_zip}"

  upload_image "${BUILD_DIR}/${update_zip}"
}

generate_update() {
  local image_name="$1"
  local disk_layout="$2"
  local update_prefix="${image_name%_image.bin}_update"
  local update="${BUILD_DIR}/${update_prefix}"
  local devkey="/usr/share/update_engine/update-payload-key.key.pem"

  echo "Generating update payload, signed with a dev key"
  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
    extract "${BUILD_DIR}/${image_name}" "USR-A" "${update}.bin"
  delta_generator -private_key "${devkey}" \
    -new_image "${update}.bin" -out_file "${update}.gz"

  upload_image -d "${update}.DIGESTS" "${update}".{bin,gz,zip}
}

# Basic command to emerge binary packages into the target image.
# Arguments to this command are passed as addition options/arguments
# to the basic emerge command.
emerge_to_image() {
  local root_fs_dir="$1"; shift

  sudo -E ROOT="${root_fs_dir}" \
      PORTAGE_CONFIGROOT="${BUILD_DIR}"/configroot \
      emerge --root-deps=rdeps --usepkgonly --jobs=$FLAGS_jobs -v "$@"

  # Make sure profile.env and ld.so.cache has been generated
  sudo -E ROOT="${root_fs_dir}" env-update

  # TODO(marineam): just call ${BUILD_LIBRARY_DIR}/check_root directly once
  # all tests are fatal, for now let the old function skip soname errors.
  ROOT="${root_fs_dir}" PORTAGE_CONFIGROOT="${BUILD_DIR}"/configroot \
      test_image_content "${root_fs_dir}"
}

# Switch to the dev or prod sub-profile
set_image_profile() {
  local suffix="$1"
  local profile="${BUILD_DIR}/configroot/etc/portage/make.profile"
  if [[ ! -d "${profile}/${suffix}" ]]; then
      die "Not a valid profile: ${profile}/${suffix}"
  fi
  local realpath=$(readlink -f "${profile}/${suffix}")
  ln -snf "${realpath}" "${profile}"
}

# Usage: systemd_enable /root default.target something.service
# Or: systemd_enable /root default.target some@.service some@thing.service
systemd_enable() {
  local root_fs_dir="$1"
  local target="$2"
  local unit_file="$3"
  local unit_alias="${4:-$3}"
  local wants_dir="${root_fs_dir}/usr/lib/systemd/system/${target}.wants"

  sudo mkdir -p "${wants_dir}"
  sudo ln -sf "../${unit_file}" "${wants_dir}/${unit_alias}"
}

# Generate a ls-like listing of a directory tree.
# The ugly printf is used to predictable time format and size in bytes.
write_contents() {
    info "Writing ${2##*/}"
    pushd "$1" >/dev/null
    sudo TZ=UTC find -printf \
        '%M %2n %-7u %-7g %7s %TY-%Tm-%Td %TH:%TM ./%P -> %l\n' \
        | sed -e 's/ -> $//' > "$2"
    popd >/dev/null
}

# Generate a list of packages installed in an image.
# Usage: image_packages /image/root
image_packages() {
    local profile="${BUILD_DIR}/configroot/etc/portage/profile"    
    ROOT="$1" PORTAGE_CONFIGROOT="${BUILD_DIR}"/configroot \
        equery --no-color list --format '$cpv::$repo' '*'
    # In production images GCC libraries are extracted manually.
    if [[ -f "${profile}/package.provided" ]]; then
        xargs --arg-file="${profile}/package.provided" \
            equery-${BOARD} --no-color list --format '$cpv::$repo'
    fi
}

# Generate a list of installed packages in the format:
#   sys-apps/systemd-212-r8::coreos
write_packages() {
    info "Writing ${2##*/}"
    image_packages "$1" | sort > "$2"
}

# Generate a list of packages w/ their licenses in the format:
#   sys-apps/systemd-212-r8::coreos GPL-2 LGPL-2.1 MIT public-domain
write_licenses() {
    info "Writing ${2##*/}"
    local vdb=$(portageq-${BOARD} vdb_path)
    local pkg lic
    for pkg in $(image_packages "$1" | sort); do
        lic="$vdb/${pkg%%:*}/LICENSE"
        if [[ -f "$lic" ]]; then
            echo "$pkg $(< "$lic")"
	fi
    done > "$2"
}

extract_docs() {
    local root_fs_dir="$1"

    info "Extracting docs"
    tar --create --auto-compress --file="${BUILD_DIR}/doc.tar.bz2" \
        --directory="${root_fs_dir}/usr/share/coreos" doc
    sudo rm --recursive --force "${root_fs_dir}/usr/share/coreos/doc"
}

# Add an entry to the image's package.provided
package_provided() {
    local p profile="${BUILD_DIR}/configroot/etc/portage/profile"    
    for p in "$@"; do
        info "Writing $p to package.provided and soname.provided"
        echo "$p" >> "${profile}/package.provided"
	pkg_soname_provides "$p" >> "${profile}/soname.provided"
    done
}

assert_image_size() {
  local disk_img="$1"
  local disk_type="$2"

  local size
  size=$(qemu-img info -f "${disk_type}" --output json "${disk_img}" | \
    jq --raw-output '.["virtual-size"]' ; exit ${PIPESTATUS[0]})
  if [[ $? -ne 0 ]]; then
    die_notrace "assert failed: could not read image size"
  fi

  MiB=$((1024*1024))
  if [[ $(($size % $MiB)) -ne 0 ]]; then
    die_notrace "assert failed: image must be a multiple of 1 MiB ($size B)"
  fi
}

start_image() {
  local image_name="$1"
  local disk_layout="$2"
  local root_fs_dir="$3"
  local update_group="$4"

  local disk_img="${BUILD_DIR}/${image_name}"

  mkdir -p "${BUILD_DIR}"/configroot/etc/portage/profile
  ln -s "${BOARD_ROOT}"/etc/portage/make.* \
      "${BOARD_ROOT}"/etc/portage/package.* \
      "${BOARD_ROOT}"/etc/portage/repos.conf \
      "${BUILD_DIR}"/configroot/etc/portage/

  info "Using image type ${disk_layout}"
  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      format "${disk_img}"

  assert_image_size "${disk_img}" raw

  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      mount "${disk_img}" "${root_fs_dir}"
  trap "cleanup_mounts '${root_fs_dir}' && delete_prompt" EXIT

  # First thing first, install baselayout to create a working filesystem.
  emerge_to_image "${root_fs_dir}" --nodeps --oneshot sys-apps/baselayout

  # FIXME(marineam): Work around glibc setting EROOT=$ROOT
  # https://bugs.gentoo.org/show_bug.cgi?id=473728#c12
  sudo mkdir -p "${root_fs_dir}/etc/ld.so.conf.d"

  # Set /etc/lsb-release on the image.
  "${BUILD_LIBRARY_DIR}/set_lsb_release" \
    --root="${root_fs_dir}" \
    --group="${update_group}" \
    --board="${BOARD}"
}

finish_image() {
  local image_name="$1"
  local disk_layout="$2"
  local root_fs_dir="$3"
  local image_contents="$4"
  local install_grub=0

  local disk_img="${BUILD_DIR}/${image_name}"

  # Copy kernel to support dm-verity boots
  sudo mkdir -p "${root_fs_dir}/boot/coreos"
  sudo cp "${root_fs_dir}/usr/boot/vmlinuz" \
       "${root_fs_dir}/boot/coreos/vmlinuz-a"

  # Record directories installed to the state partition.
  # Explicitly ignore entries covered by existing configs.
  local tmp_ignore=$(awk '/^[dDfFL]/ {print "--ignore=" $2}' \
      "${root_fs_dir}"/usr/lib/tmpfiles.d/*.conf)
  sudo "${BUILD_LIBRARY_DIR}/gen_tmpfiles.py" --root="${root_fs_dir}" \
      --output="${root_fs_dir}/usr/lib/tmpfiles.d/base_image_var.conf" \
      ${tmp_ignore} "${root_fs_dir}/var"
  sudo "${BUILD_LIBRARY_DIR}/gen_tmpfiles.py" --root="${root_fs_dir}" \
      --output="${root_fs_dir}/usr/lib/tmpfiles.d/base_image_etc.conf" \
      ${tmp_ignore} "${root_fs_dir}/etc"

  # Only configure bootloaders if there is a boot partition
  if mountpoint -q "${root_fs_dir}"/boot; then
    install_grub=1
    ${BUILD_LIBRARY_DIR}/configure_bootloaders.sh \
      --boot_dir="${root_fs_dir}"/usr/boot
  fi

  if [[ -n "${FLAGS_developer_data}" ]]; then
    local data_path="/usr/share/coreos/developer_data"
    local unit_path="usr-share-coreos-developer_data"
    sudo cp "${FLAGS_developer_data}" "${root_fs_dir}/${data_path}"
    systemd_enable "${root_fs_dir}" system-config.target \
        "system-cloudinit@.service" "system-cloudinit@${unit_path}.service"
  fi

  write_contents "${root_fs_dir}" "${BUILD_DIR}/${image_contents}"

  # Zero all fs free space to make it more compressible so auto-update
  # payloads become smaller, not fatal since it won't work on linux < 3.2
  sudo fstrim "${root_fs_dir}" || true
  if mountpoint -q "${root_fs_dir}/usr"; then
    sudo fstrim "${root_fs_dir}/usr" || true
  fi

  # Build the selinux policy
  if pkg_use_enabled coreos-base/coreos selinux; then
      sudo chroot "${root_fs_dir}" bash -c "cd /usr/share/selinux/mcs && semodule -i *.pp"
  fi

  # We only need to disable rw and apply dm-verity in prod with a /usr partition
  if [ "${PROD_IMAGE}" -eq 1 ] && mountpoint -q "${root_fs_dir}/usr"; then
    local disable_read_write=${FLAGS_enable_rootfs_verification}

    # Unmount /usr partition
    sudo umount --recursive "${root_fs_dir}/usr" || exit 1

    # Make the filesystem un-mountable as read-write and setup verity.
    if [[ ${disable_read_write} -eq ${FLAGS_TRUE} ]]; then
      "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" verity \
        --root_hash="${BUILD_DIR}/${image_name%.bin}_verity.txt" \
        "${BUILD_DIR}/${image_name}"

      # Magic alert! Root hash injection works by replacing a seldom-used rdev
      # error message in the uncompressed section of the kernel that happens to
      # be exactly SHA256-sized. Our modified GRUB extracts it to the cmdline.
      printf %s "$(cat ${BUILD_DIR}/${image_name%.bin}_verity.txt)" | \
        sudo dd of="${root_fs_dir}/boot/coreos/vmlinuz-a" conv=notrunc seek=64 count=64 bs=1
    fi
  fi

  # Sign the kernel after /usr is in a consistent state and verity is calculated
  if [[ ${COREOS_OFFICIAL:-0} -ne 1 ]]; then
      sudo sbsign --key /usr/share/sb_keys/DB.key \
	   --cert /usr/share/sb_keys/DB.crt \
	   "${root_fs_dir}/boot/coreos/vmlinuz-a"
      sudo mv "${root_fs_dir}/boot/coreos/vmlinuz-a.signed" \
	   "${root_fs_dir}/boot/coreos/vmlinuz-a"
  fi

  rm -rf "${BUILD_DIR}"/configroot
  cleanup_mounts "${root_fs_dir}"
  trap - EXIT

  # This script must mount the ESP partition differently, so run it after unmount
  if [[ "${install_grub}" -eq 1 ]]; then
    local target
    for target in i386-pc x86_64-efi x86_64-xen; do
      if [[ "${PROD_IMAGE}" -eq 1 && ${FLAGS_enable_verity} -eq ${FLAGS_TRUE} ]]; then
        ${BUILD_LIBRARY_DIR}/grub_install.sh \
            --target="${target}" --disk_image="${disk_img}" --verity
      else
        ${BUILD_LIBRARY_DIR}/grub_install.sh \
            --target="${target}" --disk_image="${disk_img}" --noverity
      fi
    done
  fi
}
