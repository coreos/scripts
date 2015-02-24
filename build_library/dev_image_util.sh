# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

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

    sudo mkdir -p "$1/etc/portage/repos.conf"
    sudo_clobber "$1/etc/portage/make.conf" <<EOF
# make.conf for CoreOS dev images
ARCH=$(get_board_arch $BOARD)
CHOST=$(get_board_chost $BOARD)
BOARD_USE="$BOARD"

# Use /var/lib/portage instead of /usr/portage
DISTDIR="/var/lib/portage/distfiles"
PKGDIR="/var/lib/portage/pkgs"
PORT_LOGDIR="/var/log/portage"
PORTDIR="/var/lib/portage/portage-stable"
PORTDIR_OVERLAY="/var/lib/portage/coreos-overlay"
PORTAGE_BINHOST="$(get_board_binhost $BOARD $COREOS_VERSION_ID)"
EOF

sudo_clobber "$1/etc/portage/repos.conf/coreos.conf" <<EOF
[DEFAULT]
main-repo = portage-stable

[gentoo]
disabled = true

[coreos]
location = /var/lib/portage/coreos-overlay
sync-type = git
sync-uri = https://github.com/coreos/coreos-overlay.git

[portage-stable]
location = /var/lib/portage/portage-stable
sync-type = git
sync-uri = https://github.com/coreos/portage-stable.git
EOF

    # Now set the correct profile
    sudo PORTAGE_CONFIGROOT="$1" ROOT="$1" \
        PORTDIR="$1/var/lib/portage/portage-stable" \
        PORTDIR_OVERLAY="$1/var/lib/portage/coreos-overlay" \
        eselect profile set --force $(get_board_profile $BOARD)/dev
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

create_dev_image() {
  local image_name=$1
  local disk_layout=$2
  local update_group=$3
  local base_pkg="$4"
  local devserver=$(detect_dev_url)
  local auserver=""

  if [ -z "${base_pkg}" ]; then
    echo "did not get base package!"
    exit 1
  fi

  if [[ -n "${devserver}" ]]; then
    info "Using ${devserver} for local dev server URL."
    auserver="${devserver}/update"
  else
    info "Unable do detect local dev server address."
  fi

  info "Building developer image ${image_name}"
  local root_fs_dir="${BUILD_DIR}/rootfs"
  local image_contents="${image_name%.bin}_contents.txt"
  local image_packages="${image_name%.bin}_packages.txt"

  start_image "${image_name}" "${disk_layout}" "${root_fs_dir}" "${update_group}"

  set_image_profile dev
  emerge_to_image "${root_fs_dir}" @system ${base_pkg}
  write_packages "${root_fs_dir}" "${BUILD_DIR}/${image_packages}"

  # Setup portage for emerge and gmerge
  configure_dev_portage "${root_fs_dir}" "${devserver}"

  sudo_append "${root_fs_dir}/etc/coreos/update.conf" <<EOF
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
  systemd_enable "${root_fs_dir}" "multi-user.target" "remount-usr.service"

  finish_image "${image_name}" "${disk_layout}" "${root_fs_dir}" "${image_contents}"
  upload_image -d "${BUILD_DIR}/${image_name}.bz2.DIGESTS" \
      "${BUILD_DIR}/${image_contents}" \
      "${BUILD_DIR}/${image_packages}" \
      "${BUILD_DIR}/${image_name}"
}
