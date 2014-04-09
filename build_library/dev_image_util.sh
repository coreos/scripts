# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Shell function library for functions specific to creating dev
# images from base images.  The main function for export in this
# library is 'install_dev_packages'.

configure_dev_portage() {
    # Need profiles at the bare minimum
    local repo
    for repo in portage-stable coreos-overlay; do
        sudo mkdir -p "$1/var/lib/portage/${repo}"
        sudo rsync -rtl --exclude=md5-cache \
            "${SRC_ROOT}/third_party/${repo}/metadata" \
            "${SRC_ROOT}/third_party/${repo}/profiles" \
            "$1/var/lib/portage/${repo}"
    done

    sudo mkdir -p "$1/etc/portage"
    sudo_clobber "$1/etc/portage/make.conf" <<EOF
# make.conf for CoreOS dev images
ARCH=$(get_board_arch $BOARD)
CHOST=$(get_board_chost $BOARD)
BOARD_USE="$BOARD"

# Use /var/lib/portage instead of /usr/portage
DISTDIR="/var/lib/portage/distfiles"
PKGDIR="/var/lib/portage/packages"
PORTDIR="/var/lib/portage/portage-stable"
PORTDIR_OVERLAY="/var/lib/portage/coreos-overlay"
EOF

    # Now set the correct profile
    sudo PORTAGE_CONFIGROOT="$1" ROOT="$1" \
        PORTDIR="$1/var/lib/portage/portage-stable" \
        PORTDIR_OVERLAY="$1/var/lib/portage/coreos-overlay" \
        eselect profile set --force $(get_board_profile $BOARD)
}

detect_dev_url() {
    local port=":8080"
    local host=$(hostname --fqdn 2>/dev/null)
    if [[ -z "${host}" ]]; then
        host=$(ip addr show scope global | \
            awk '$1 == "inet" { sub(/[/].*/, "", $2); print $2; exit }')
    fi
    if [[ -n "${host}" ]]; then
        echo "http://${host}${port}"
    fi
}

# Modifies an existing image to add development packages.
# Takes as an arg the name of the image to be created.
install_dev_packages() {
  local image_name=$1
  local disk_layout=$2
  local devserver=$(detect_dev_url)
  local auserver=""

  if [[ -n "${devserver}" ]]; then
    info "Using ${devserver} for local dev server URL."
    auserver="${devserver}/update"
  else
    info "Unable do detect local dev server address."
  fi

  info "Adding developer packages to ${image_name}"
  local root_fs_dir="${BUILD_DIR}/rootfs"

  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      mount "${BUILD_DIR}/${image_name}" "${root_fs_dir}"
  trap "cleanup_mounts '${root_fs_dir}' && delete_prompt" EXIT

  # Install developer packages described in coreos-dev.
  emerge_to_image --root="${root_fs_dir}" coreos-base/coreos-dev

  # Make sure profile.env and ld.so.cache has been generated
  sudo ROOT="${root_fs_dir}" env-update

  # Setup portage for emerge and gmerge
  configure_dev_portage "${root_fs_dir}" "${devserver}"

  sudo mkdir -p "${root_fs_dir}/etc/coreos"
  sudo_clobber "${root_fs_dir}/etc/coreos/update.conf" <<EOF
SERVER=${auserver}

# For gmerge
DEVSERVER=${devserver}
EOF

  # Mark the image as a developer image (input to chromeos_startup).
  # TODO(arkaitzr): Remove this file when applications no longer rely on it
  # (crosbug.com/16648). The preferred way of determining developer mode status
  # is via crossystem cros_debug?1 (checks boot args for "cros_debug").
  sudo mkdir -p "${root_fs_dir}/root"
  sudo touch "${root_fs_dir}/root/.dev_mode"

  # Remount the system partition read-write by default.
  # The remount services are provided by coreos-base/coreos-init
  local fs_wants="${root_fs_dir}/usr/lib/systemd/system/local-fs.target.wants"
  sudo mkdir -p "${fs_wants}"
  if [[ "${disk_layout}" == *-usr ]]; then
    sudo ln -s ../remount-usr.service "${fs_wants}"
  else
    sudo ln -s ../remount-root.service "${fs_wants}"
  fi

  # Zero all fs free space, not fatal since it won't work on linux < 3.2
  sudo fstrim "${root_fs_dir}" || true
  if [[ "${disk_layout}" == *-usr ]]; then
    sudo fstrim "${root_fs_dir}/usr" || true
  else
    sudo fstrim "${root_fs_dir}/media/state" || true
  fi

  info "Developer image built and stored at ${image_name}"

  cleanup_mounts "${root_fs_dir}"
  trap - EXIT
}
