#!/usr/bin/env bash

# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script sets up a Gentoo chroot environment. The script is passed the
# path to an empty folder, which will be populated with a Gentoo stage3 and
# setup for development. Once created, the password is set to PASSWORD (below).
# One can enter the chrooted environment for work by running enter_chroot.sh.

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

ENTER_CHROOT=$(readlink -f $(dirname "$0")/enter_chroot.sh)

if [ -n "${USE}" ]; then
  echo "$SCRIPT_NAME: Building with a non-empty USE: ${USE}"
  echo "This modifies the expected behaviour and can fail."
fi

# Check if the host machine architecture is supported.
ARCHITECTURE="$(uname -m)"
if [[ "$ARCHITECTURE" != "x86_64" ]]; then
  echo "$SCRIPT_NAME: $ARCHITECTURE is not supported as a host machine architecture."
  exit 1
fi

# Script must be run outside the chroot and as root.
assert_outside_chroot
assert_root_user
assert_kernel_version

# Define command line flags.
# See http://code.google.com/p/shflags/wiki/Documentation10x

DEFINE_string chroot "$DEFAULT_CHROOT_DIR" \
  "Destination dir for the chroot environment."
DEFINE_boolean usepkg $FLAGS_TRUE "Use binary packages to bootstrap."
DEFINE_boolean getbinpkg $FLAGS_TRUE \
  "Download binary packages from remote repository."
DEFINE_boolean delete $FLAGS_FALSE "Delete an existing chroot."
DEFINE_boolean replace $FLAGS_FALSE "Overwrite existing chroot, if any."
DEFINE_integer jobs "${NUM_JOBS}" \
  "How many packages to build in parallel at maximum."
DEFINE_string stage3_path "" \
  "Use the stage3 located on this path."
DEFINE_string cache_dir "" "unused"

# Parse command line flags.
FLAGS_HELP="usage: $SCRIPT_NAME [flags]"
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
check_flags_only_and_allow_null_arg "$@" && set --

CROS_LOG_PREFIX=cros_sdk:make_chroot
SUDO_HOME=$(eval echo ~${SUDO_USER})

# Set the right umask for chroot creation.
umask 022

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'switch_to_strict_mode' is specified before now.
# TODO: replace shflags with something less error-prone, or contribute a fix.
switch_to_strict_mode

ENTER_CHROOT_ARGS=(
  CROS_WORKON_SRCROOT="$CHROOT_TRUNK"
  PORTAGE_USERNAME="${SUDO_USER}"
)

# Invoke enter_chroot.  This can only be used after sudo has been installed.
enter_chroot() {
  "$ENTER_CHROOT" --chroot "$FLAGS_chroot" -- "${ENTER_CHROOT_ARGS[@]}" "$@"
}

# Invoke enter_chroot running the command as root, and w/out sudo.
# This should be used prior to sudo being merged.
early_enter_chroot() {
  "$ENTER_CHROOT" --chroot "$FLAGS_chroot" --early_make_chroot \
    -- "${ENTER_CHROOT_ARGS[@]}" "$@"
}

# Run a command within the chroot.  The main usage of this is to avoid
# the overhead of enter_chroot, and do not need access to the source tree,
# don't need the actual chroot profile env, and can run the command as root.
bare_chroot() {
  chroot "${FLAGS_chroot}" /usr/bin/env \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$@"
}

cleanup() {
  # Clean up mounts
  safe_umount_tree "${FLAGS_chroot}"
}

delete_existing() {
  # Delete old chroot dir.
  if [[ ! -e "$FLAGS_chroot" ]]; then
    return
  fi
  info "Cleaning up old mount points..."
  cleanup
  info "Deleting $FLAGS_chroot..."
  rm -rf "$FLAGS_chroot"
  info "Done."
}

init_users () {
  # make sure user/group database files exist
  touch "${FLAGS_chroot}/etc/"{group,gshadow,passwd,shadow}
  chmod 640 "${FLAGS_chroot}/etc/"{gshadow,shadow}

  # do nothing with the CoreOS system user
  if [[ "${SUDO_USER}" == core ]]; then
    return
  fi

  local baselayout="${FLAGS_chroot}/usr/share/baselayout"
  local full_name=$(getent passwd "${SUDO_USER}" | cut -d: -f5)
  local group_name=$(getent group "${SUDO_GID}" | cut -d: -f1)
  [[ -n "${group_name}" ]] || die "Looking up gid $SUDO_GID failed."

  if ! grep -q "^${group_name}:" "${baselayout}/group"; then
    info "Adding group ${group_name}..."
    bare_chroot groupadd -o -g "${SUDO_GID}" "${group_name}"
  fi

  info "Adding user ${SUDO_USER}..."
  bare_chroot useradd -o -g "${SUDO_GID}" -u "${SUDO_UID}" \
      -s /bin/bash -m -c "${full_name}" "${SUDO_USER}"

  # copy and update other system groups the developer should be in
  local group
  for group in kvm portage; do
    grep "^${group}:" "${baselayout}/group" >> "${FLAGS_chroot}/etc/group"
    bare_chroot gpasswd -a "${SUDO_USER}" "${group}"
  done
}

init_setup () {
   info "Running init_setup()..."
   # clean up old catalyst configs to avoid error from env-update
   # TODO(marineam): remove repos.conf bit in a week or so
   rm -f "${FLAGS_chroot}/etc/portage/make.conf" \
     "${FLAGS_chroot}/etc/portage/repos.conf/coreos.conf"

   # Set up sudoers.  Inside the chroot, the user can sudo without a password.
   # (Safe enough, since the only way into the chroot is to 'sudo chroot', so
   # the user's already typed in one sudo password...)
   # Setup proxied vars.
   load_environment_whitelist
   local extended_whitelist=(
        "${ENVIRONMENT_WHITELIST[@]}"
        CROS_WORKON_SRCROOT
        PORTAGE_USERNAME
   )

   cat > "${FLAGS_chroot}/etc/sudoers.d/90_cros" <<EOF
Defaults env_keep += "${extended_whitelist[*]}"
${SUDO_USER} ALL=NOPASSWD: ALL
EOF

   chmod 0440 "${FLAGS_chroot}/etc/sudoers.d/90_cros"

   # Add chromite/bin into the path globally
   # We rely on 'env-update' getting called below.
   target="${FLAGS_chroot}/etc/env.d/99coreos"
   cat <<EOF > "${target}"
PATH=${CHROOT_TRUNK_DIR}/chromite/bin
ROOTPATH=${CHROOT_TRUNK_DIR}/chromite/bin
CROS_WORKON_SRCROOT="${CHROOT_TRUNK_DIR}"
PORTAGE_USERNAME=${SUDO_USER}
EOF
   early_enter_chroot env-update

   # Add chromite into python path.
   for python_path in "${FLAGS_chroot}/usr/lib/"python2.*; do
     sudo mkdir -p "${python_path}"
     sudo ln -s "${CHROOT_TRUNK_DIR}"/chromite "${python_path}"
   done

   # Create ~/trunk symlink, it must point to CHROOT_TRUNK_DIR
   ln -sfT "${CHROOT_TRUNK_DIR}" "$FLAGS_chroot/home/${SUDO_USER}/trunk"

   # Automatically change to scripts directory.
   echo 'cd ${CHROOT_CWD:-~/trunk/src/scripts}' \
       | user_append "$FLAGS_chroot/home/${SUDO_USER}/.bash_profile"

   # Enable bash completion for build scripts.
   echo ". ~/trunk/src/scripts/bash_completion" \
       | user_append "$FLAGS_chroot/home/${SUDO_USER}/.bashrc"

   if [[ -f ${SUDO_HOME}/.gitconfig ]]; then
     # Copy .gitconfig into chroot so repo and git can be used from inside.
     # This is required for repo to work since it validates the email address.
     echo "Copying ~/.gitconfig into chroot"
     user_cp "${SUDO_HOME}/.gitconfig" "$FLAGS_chroot/home/${SUDO_USER}/"
   fi

   # If the user didn't set up their username in their gitconfig, look
   # at the default git settings for the user.
   if ! git config -f "${SUDO_HOME}/.gitconfig" user.email >& /dev/null; then
     ident=$(cd /; sudo -u ${SUDO_USER} -- git var GIT_COMMITTER_IDENT || :)
     ident_name=${ident%% <*}
     ident_email=${ident%%>*}; ident_email=${ident_email##*<}
     gitconfig=${FLAGS_chroot}/home/${SUDO_USER}/.gitconfig
     git config -f ${gitconfig} --replace-all user.name "${ident_name}" || :
     git config -f ${gitconfig} --replace-all user.email "${ident_email}" || :
     chown ${SUDO_UID}:${SUDO_GID} ${FLAGS_chroot}/home/${SUDO_USER}/.gitconfig
   fi

   if [[ -f ${SUDO_HOME}/.cros_chroot_init ]]; then
     sudo -u ${SUDO_USER} -- /bin/bash "${SUDO_HOME}/.cros_chroot_init" \
       "${FLAGS_chroot}"
   fi
}

# Handle deleting an existing environment.
if [[ $FLAGS_delete  -eq $FLAGS_TRUE || \
  $FLAGS_replace -eq $FLAGS_TRUE ]]; then
  delete_existing
  [[ $FLAGS_delete -eq $FLAGS_TRUE ]] && exit 0
fi

CHROOT_TRUNK="${CHROOT_TRUNK_DIR}"
PORTAGE_STABLE_OVERLAY="/usr/local/portage/stable"
CROSSDEV_OVERLAY="/usr/local/portage/crossdev"
CHROOT_OVERLAY="/usr/local/portage/coreos"
CHROOT_STATE="${FLAGS_chroot}/etc/debian_chroot"

# Pass proxy variables into the environment.
for type in http ftp all; do
   value=$(env | grep ${type}_proxy || true)
   if [ -n "${value}" ]; then
      CHROOT_PASSTHRU+=("$value")
   fi
done

if [ ! -f "${FLAGS_stage3_path}" ]; then
  error "Invalid stage3!"
  exit 1;
fi
STAGE3="${FLAGS_stage3_path}"

# Create the destination directory.
mkdir -p "$FLAGS_chroot"

echo
if [ -f $CHROOT_STATE ]
then
  info "STAGE3 already set up.  Skipping..."
else
  info "Unpacking STAGE3..."
  case ${STAGE3} in
    *.tbz2|*.tar.bz2) DECOMPRESS=$(type -p lbzip2 || echo bzip2) ;;
    *.tar.xz) DECOMPRESS="xz" ;;
    *) die "Unknown tarball compression: ${STAGE3}";;
  esac
  ${DECOMPRESS} -dc "${STAGE3}" | \
    tar -xp -C "${FLAGS_chroot}"
  rm -f "$FLAGS_chroot/etc/"make.{globals,conf.user}

  # Set up users, if needed, before mkdir/mounts below.
  init_users

  # Run all the init stuff to setup the env.
  init_setup
fi

# Add file to indicate that it is a chroot.
echo STAGE3=$STAGE3 > $CHROOT_STATE

# Update chroot.
UPDATE_ARGS=()
if [[ ${FLAGS_usepkg} -eq ${FLAGS_TRUE} ]]; then
  UPDATE_ARGS+=( --usepkg )
  if [[ ${FLAGS_getbinpkg} -eq ${FLAGS_TRUE} ]]; then
    UPDATE_ARGS+=( --getbinpkg )
  else
    UPDATE_ARGS+=( --nogetbinpkg )
  fi
else
  UPDATE_ARGS+=( --nousepkg )
fi
if [[ "${FLAGS_jobs}" -ne -1 ]]; then
  UPDATE_ARGS+=( --jobs=${FLAGS_jobs} )
fi
enter_chroot "${CHROOT_TRUNK_DIR}/src/scripts/update_chroot" "${UPDATE_ARGS[@]}"

CHROOT_EXAMPLE_OPT=""
if [[ "$FLAGS_chroot" != "$DEFAULT_CHROOT_DIR" ]]; then
  CHROOT_EXAMPLE_OPT="--chroot=$FLAGS_chroot"
fi

command_completed

cat <<EOF

${CROS_LOG_PREFIX:-cros_sdk}: All set up.  To enter the chroot, run:
$ cros_sdk --enter $CHROOT_EXAMPLE_OPT

CAUTION: Do *NOT* rm -rf the chroot directory; if there are stale bind
mounts you may end up deleting your source tree too.  To unmount and
delete the chroot cleanly, use:
$ cros_sdk --delete $CHROOT_EXAMPLE_OPT

EOF

warn_if_nfs "${SUDO_HOME}"
