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
  if [ -t 0 -a -t 1 -a "${USER}" != 'chrome-bot' ]; then
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

# Generate a list of installed packages in the format:
#   sys-apps/systemd-212-r8::coreos
write_packages() {
    local profile="${BUILD_DIR}/configroot/etc/portage/profile"    
    info "Writing ${2##*/}"
    ROOT="$1" PORTAGE_CONFIGROOT="${BUILD_DIR}"/configroot \
        equery --no-color list '*' --format '$cpv::$repo' > "$2"
    if [[ -f "${profile}/package.provided" ]]; then
        cat "${profile}/package.provided" >> "$2"
    fi
}

# Add an entry to the image's package.provided
package_provided() {
    local p profile="${BUILD_DIR}/configroot/etc/portage/profile"    
    for p in "$@"; do
        info "Writing $p to package.provided"
        echo "$p" >> "${profile}/package.provided"
    done
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
      --arch=${ARCH} \
      --disk_layout="${disk_layout}" \
      --boot_dir="${root_fs_dir}"/usr/boot \
      --esp_dir="${root_fs_dir}"/boot \
      --boot_args="${FLAGS_boot_args}"
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

  rm -rf "${BUILD_DIR}"/configroot
  cleanup_mounts "${root_fs_dir}"
  trap - EXIT

  # This script must mount the ESP partition differently, so run it after unmount
  if [[ "${install_grub}" -eq 1 ]]; then
    local target
    for target in i386-pc x86_64-efi; do
      ${BUILD_LIBRARY_DIR}/grub_install.sh \
          --target="${target}" --disk_image="${disk_img}"
    done
  fi
}
