#!/bin/bash

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

# Define command line flags.
# See http://code.google.com/p/shflags/wiki/Documentation10x

DEFINE_string chroot "$DEFAULT_CHROOT_DIR" \
  "Destination dir for the chroot environment."
DEFINE_boolean usepkg $FLAGS_TRUE "Use binary packages to bootstrap."
DEFINE_boolean delete $FLAGS_FALSE "Delete an existing chroot."
DEFINE_boolean replace $FLAGS_FALSE "Overwrite existing chroot, if any."
DEFINE_integer jobs -1 "How many packages to build in parallel at maximum."
DEFINE_boolean fast ${DEFAULT_FAST} "Call many emerges in parallel"
DEFINE_string stage3_date "20130130" \
  "Use the stage3 with the given date."
DEFINE_string stage3_path "" \
  "Use the stage3 located on this path."
DEFINE_string cache_dir "" "Directory to store caches within."

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

[[ "${FLAGS_delete}" == "${FLAGS_FALSE}" ]] && \
  [[ -z "${FLAGS_cache_dir}" ]] && \
  die "--cache_dir is required"

. "${SCRIPT_ROOT}"/sdk_lib/make_conf_util.sh

FULLNAME="ChromeOS Developer"
DEFGROUPS="eng,adm,cdrom,floppy,audio,video,portage"
PASSWORD=chronos
CRYPTED_PASSWD=$(perl -e 'print crypt($ARGV[0], "foo")', $PASSWORD)

USEPKG=""
if [[ $FLAGS_usepkg -eq $FLAGS_TRUE ]]; then
  # Use binary packages. Include all build-time dependencies,
  # so as to avoid unnecessary differences between source
  # and binary builds.
  USEPKG="--getbinpkg --usepkg --with-bdeps y"
fi

# Support faster build if necessary.
EMERGE_CMD="emerge"
if [ "$FLAGS_fast" -eq "${FLAGS_TRUE}" ]; then
  CHROOT_CHROMITE_DIR="${CHROOT_TRUNK_DIR}/chromite"
  EMERGE_CMD="${CHROOT_CHROMITE_DIR}/bin/parallel_emerge"
fi

ENTER_CHROOT_ARGS=(
  CROS_WORKON_SRCROOT="$CHROOT_TRUNK"
  PORTAGE_USERNAME="${SUDO_USER}"
  IGNORE_PREFLIGHT_BINHOST="$IGNORE_PREFLIGHT_BINHOST"
)

# Invoke enter_chroot.  This can only be used after sudo has been installed.
enter_chroot() {
  "$ENTER_CHROOT" --cache_dir "${FLAGS_cache_dir}" --chroot "$FLAGS_chroot" \
    -- "${ENTER_CHROOT_ARGS[@]}" "$@"
}

# Invoke enter_chroot running the command as root, and w/out sudo.
# This should be used prior to sudo being merged.
early_env=()
early_enter_chroot() {
  "$ENTER_CHROOT" --chroot "$FLAGS_chroot" --early_make_chroot \
    --cache_dir "${FLAGS_cache_dir}" \
    -- "${ENTER_CHROOT_ARGS[@]}" "${early_env[@]}" "$@"
}

# Run a command within the chroot.  The main usage of this is to avoid
# the overhead of enter_chroot, and do not need access to the source tree,
# don't need the actual chroot profile env, and can run the command as root.
bare_chroot() {
  chroot "${FLAGS_chroot}" "$@"
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
   info "Set timezone..."
   # date +%Z has trouble with daylight time, so use host's info.
   rm -f "${FLAGS_chroot}/etc/localtime"
   if [ -f /etc/localtime ] ; then
     cp /etc/localtime "${FLAGS_chroot}/etc"
   else
     ln -sf /usr/share/zoneinfo/PST8PDT "${FLAGS_chroot}/etc/localtime"
   fi
   info "Adding user/group..."
   # Add ourselves as a user inside the chroot.
   bare_chroot groupadd -g 5000 eng
   # We need the UID to match the host user's. This can conflict with
   # a particular chroot UID. At the same time, the added user has to
   # be a primary user for the given UID for sudo to work, which is
   # determined by the order in /etc/passwd. Let's put ourselves on top
   # of the file.
   bare_chroot useradd -o -G ${DEFGROUPS} -g eng -u ${SUDO_UID} -s \
     /bin/bash -m -c "${FULLNAME}" -p ${CRYPTED_PASSWD} ${SUDO_USER}
   # Because passwd generally isn't sorted and the entry ended up at the
   # bottom, it is safe to just take it and move it to top instead.
   sed -e '1{h;d};$!{H;d};$G' -i "${FLAGS_chroot}/etc/passwd"
}

init_setup () {
   info "Running init_setup()..."
   mkdir -p -m 755 "${FLAGS_chroot}/usr" \
     "${FLAGS_chroot}/usr/local/portage" \
     "${FLAGS_chroot}"/"${CROSSDEV_OVERLAY}"
   ln -sf "${CHROOT_TRUNK_DIR}/src/third_party/portage" \
     "${FLAGS_chroot}/usr/portage"
   ln -sf "${CHROOT_TRUNK_DIR}/src/third_party/coreos-overlay" \
     "${FLAGS_chroot}"/"${CHROOT_OVERLAY}"
   ln -sf "${CHROOT_TRUNK_DIR}/src/third_party/portage-stable" \
     "${FLAGS_chroot}"/"${PORTAGE_STABLE_OVERLAY}"

   # Some operations need an mtab.
   ln -s /proc/mounts "${FLAGS_chroot}/etc/mtab"

   # Set up sudoers.  Inside the chroot, the user can sudo without a password.
   # (Safe enough, since the only way into the chroot is to 'sudo chroot', so
   # the user's already typed in one sudo password...)
   # Make sure the sudoers.d subdir exists as older stage3 base images lack it.
   mkdir -p "${FLAGS_chroot}/etc/sudoers.d"

   # Use the standardized upgrade script to setup proxied vars.
   load_environment_whitelist
   bash -e "${SCRIPT_ROOT}/chroot_version_hooks.d/45_rewrite_sudoers.d" \
     "${FLAGS_chroot}" "${SUDO_USER}" "${ENVIRONMENT_WHITELIST[@]}"

   find "${FLAGS_chroot}/etc/"sudoers* -type f -exec chmod 0440 {} +
   # Fix bad group for some.
   chown -R root:root "${FLAGS_chroot}/etc/"sudoers*

   info "Setting up hosts/resolv..."
   # Copy config from outside chroot into chroot.
   cp /etc/{hosts,resolv.conf} "$FLAGS_chroot/etc/"
   chmod 0644 "$FLAGS_chroot"/etc/{hosts,resolv.conf}

   # Setup host make.conf. This includes any overlay that we may be using
   # and a pointer to pre-built packages.
   # TODO: This should really be part of a profile in the portage.
   info "Setting up /etc/make.*..."
   ln -sf "${CHROOT_CONFIG}/make.conf.amd64-host" \
     "${FLAGS_chroot}/etc/make.conf"
   ln -sf "${CHROOT_OVERLAY}/profiles/default/linux/amd64/10.0" \
     "${FLAGS_chroot}/etc/make.profile"

   # Create make.conf.user .
   touch "${FLAGS_chroot}"/etc/make.conf.user
   chmod 0644 "${FLAGS_chroot}"/etc/make.conf.user

   # Create directories referred to by our conf files.
   mkdir -p -m 775 "${FLAGS_chroot}/var/lib/portage/pkgs" \
     "${FLAGS_chroot}/var/cache/"chromeos-{cache,chrome} \
     "${FLAGS_chroot}/etc/profile.d"

   echo "export CHROMEOS_CACHEDIR=/var/cache/chromeos-cache" > \
     "${FLAGS_chroot}/etc/profile.d/chromeos-cachedir.sh"
   chmod 0644 "${FLAGS_chroot}/etc/profile.d/chromeos-cachedir.sh"
   rm -rf "${FLAGS_chroot}/var/cache/distfiles"
   ln -s chromeos-cache/distfiles "${FLAGS_chroot}/var/cache/distfiles"

   # Run this from w/in the chroot so we use whatever uid/gid
   # these are defined as w/in the chroot.
   bare_chroot chown "${SUDO_USER}:portage" /var/cache/chromeos-chrome

   # These are created for compatibility while transitioning
   # make.conf and friends over to the new location.
   # TODO(ferringb): remove this 01/13 or so.
   ln -s ../../cache/chromeos-cache/distfiles/host \
     "${FLAGS_chroot}/var/lib/portage/distfiles"
   ln -s ../../cache/chromeos-cache/distfiles/target \
     "${FLAGS_chroot}/var/lib/portage/distfiles-target"

   # Add chromite/bin and depot_tools into the path globally; note that the
   # chromite wrapper itself might also be found in depot_tools.
   # We rely on 'env-update' getting called below.
   target="${FLAGS_chroot}/etc/env.d/99chromiumos"
   cat <<EOF > "${target}"
PATH=${CHROOT_TRUNK_DIR}/chromite/bin:${DEPOT_TOOLS_DIR}
CROS_WORKON_SRCROOT="${CHROOT_TRUNK_DIR}"
PORTAGE_USERNAME=${SUDO_USER}
EOF

   # Add chromite into python path.
   for python_path in "${FLAGS_chroot}/usr/lib/"python2.*; do
     sudo mkdir -p "${python_path}"
     sudo ln -s "${CHROOT_TRUNK_DIR}"/chromite "${python_path}"
   done

   # TODO(zbehan): Configure stuff that is usually configured in postinst's,
   # but wasn't. Fix the postinst's.
   info "Running post-inst configuration hacks"
   early_enter_chroot env-update

   # This is basically a sanity check of our chroot.  If any of these
   # don't exist, then either bind mounts have failed, an invocation
   # from above is broke, or some assumption about the stage3 is no longer
   # true.
   early_enter_chroot ls -l /etc/make.{conf,profile} \
     /usr/local/portage/coreos/profiles/default/linux/amd64/10.0

   target="${FLAGS_chroot}/etc/profile.d"
   mkdir -p "${target}"
   cat << EOF > "${target}/chromiumos-niceties.sh"
# Niceties for interactive logins. (cr) denotes this is a chroot, the
# __git_branch_ps1 prints current git branch in ./ . The $r behavior is to
# make sure we don't reset the previous $? value which later formats in
# $PS1 might rely on.
PS1='\$(r=\$?; __git_branch_ps1 "(%s) "; exit \$r)'"\${PS1}"
PS1="(cr) \${PS1}"
EOF

   # Select a small set of locales for the user if they haven't done so
   # already.  This makes glibc upgrades cheap by only generating a small
   # set of locales.  The ones listed here are basically for the buildbots
   # which always assume these are available.  This works in conjunction
   # with `cros_sdk --enter`.
   # http://crosbug.com/20378
   local localegen="$FLAGS_chroot/etc/locale.gen"
   if ! grep -q -v -e '^#' -e '^$' "${localegen}" ; then
     cat <<EOF >> "${localegen}"
en_US ISO-8859-1
en_US.UTF-8 UTF-8
EOF
   fi

   # Automatically change to scripts directory.
   echo 'cd ${CHROOT_CWD:-~/trunk/src/scripts}' \
       | user_append "$FLAGS_chroot/home/${SUDO_USER}/.bash_profile"

   # Enable bash completion for build scripts.
   echo ". ~/trunk/src/scripts/bash_completion" \
       | user_append "$FLAGS_chroot/home/${SUDO_USER}/.bashrc"

   if [[ "${SUDO_USER}" = "chrome-bot" ]]; then
     # Copy ssh keys, so chroot'd chrome-bot can scp files from chrome-web.
     cp -rp ~/.ssh "$FLAGS_chroot/home/${SUDO_USER}/"
   fi

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
PORTAGE="${SRC_ROOT}/third_party/portage"
OVERLAY="${SRC_ROOT}/third_party/coreos-overlay"
CONFIG_DIR="${OVERLAY}/coreos/config"
CHROOT_CONFIG="${CHROOT_TRUNK_DIR}/src/third_party/coreos-overlay/coreos/config"
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

# Create the base Gentoo stage3 based on last version put in chroot.
STAGE3="${OVERLAY}/coreos/stage3/stage3-amd64-${FLAGS_stage3_date}.tar.bz2"
if [ -f $CHROOT_STATE ] && \
  ! egrep -q "^STAGE3=$STAGE3" $CHROOT_STATE >/dev/null 2>&1
then
  info "STAGE3 version has changed."
  delete_existing
fi

if [ -n "${FLAGS_stage3_path}" ]; then
  if [ ! -f "${FLAGS_stage3_path}" ]; then
    error "Invalid stage3!"
    exit 1;
  fi
  STAGE3="${FLAGS_stage3_path}"
fi

# Create the destination directory.
mkdir -p "$FLAGS_chroot"

echo
if [ -f $CHROOT_STATE ]
then
  info "STAGE3 already set up.  Skipping..."
else
  info "Unpacking STAGE3..."
  case ${STAGE3} in
    *.tbz2|*.tar.bz2) DECOMPRESS=$(type -p pbzip2 || echo bzip2) ;;
    *.tar.xz) DECOMPRESS="xz" ;;
    *) die "Unknown tarball compression: ${STAGE3}";;
  esac
  ${DECOMPRESS} -dc "${STAGE3}" | \
    tar -xp -C "${FLAGS_chroot}"
  rm -f "$FLAGS_chroot/etc/"make.{globals,conf.user}
fi

# Set up users, if needed, before mkdir/mounts below.
[ -f $CHROOT_STATE ] || init_users

# Reset internal vars to force them to the 'inside the chroot' value;
# since user directories now exist, this can do the upgrade in place.
set_chroot_trunk_dir "${FLAGS_chroot}" poppycock

echo
info "Setting up mounts..."
# Set up necessary mounts and make sure we clean them up on exit.
mkdir -p "${FLAGS_chroot}/${CHROOT_TRUNK_DIR}" \
    "${FLAGS_chroot}/${DEPOT_TOOLS_DIR}" "${FLAGS_chroot}/run"

# Create a special /etc/make.conf.host_setup that we use to bootstrap
# the chroot.  The regular content for the file will be generated the
# first time we invoke update_chroot (further down in this script).
create_bootstrap_host_setup "${FLAGS_chroot}"

if ! [ -f "$CHROOT_STATE" ];then
  INITIALIZE_CHROOT=1
fi


if ! early_enter_chroot bash -c 'type -P pbzip2' >/dev/null ; then
  # This chroot lacks pbzip2 early on, so we need to disable it.
  early_env+=(
    PORTAGE_BZIP2_COMMAND="bzip2"
    PORTAGE_BUNZIP2_COMMAND="bunzip2"
  )
fi

if [ -z "${INITIALIZE_CHROOT}" ];then
  info "chroot already initialized.  Skipping..."
else
  # Run all the init stuff to setup the env.
  init_setup
fi

# Add file to indicate that it is a chroot.
# Add version of $STAGE3 for update checks.
echo STAGE3=$STAGE3 > $CHROOT_STATE

info "Updating portage"
early_enter_chroot emerge -uNv --quiet portage

# Packages that inherit cros-workon commonly get a circular dependency
# curl->openssl->git->curl that is broken by emerging an early version of git
# without curl (and webdav that depends on it).
# We also need to do this before the toolchain as those will sometimes also
# fetch via remote git trees (for some bot configs).
if [[ ! -e "${FLAGS_chroot}/usr/bin/git" ]]; then
  info "Updating early git"
  USE="-curl -webdav" early_enter_chroot $EMERGE_CMD -uNv $USEPKG dev-vcs/git

  # OpenSSL is a cros-workon package too, but the default http repo is now
  # unusable since we disabled building with curl above.  Reject minilayouts.
  if [[ ! -d ${SRC_ROOT}/third_party/openssl ]]; then
    die "bootstrapping requires a full manifest checkout"
  fi
  early_enter_chroot $EMERGE_CMD -uNv $USEPKG --select $EMERGE_JOBS \
      dev-libs/openssl net-misc/curl

  # (Re-)emerge the full version of git.
  info "Updating full version of git"
  early_enter_chroot $EMERGE_CMD -uNv $USEPKG dev-vcs/git
fi

info "Updating host toolchain"
early_enter_chroot $EMERGE_CMD -uNv crossdev
TOOLCHAIN_ARGS=( --deleteold )
if [[ ${FLAGS_usepkg} -eq ${FLAGS_FALSE} ]]; then
  TOOLCHAIN_ARGS+=( --nousepkg )
fi
# Note: early_enter_chroot executes as root.
early_enter_chroot "${CHROOT_TRUNK_DIR}/chromite/bin/cros_setup_toolchains" \
    --hostonly "${TOOLCHAIN_ARGS[@]}"

# dhcpcd is included in 'world' by the stage3 that we pull in for some reason.
# We have no need to install it in our host environment, so pull it out here.
info "Deselecting dhcpcd"
early_enter_chroot $EMERGE_CMD --deselect dhcpcd

info "Running emerge curl sudo ..."
early_enter_chroot $EMERGE_CMD -uNv $USEPKG --select $EMERGE_JOBS \
  pbzip2 dev-libs/openssl net-misc/curl sudo

if [ -n "${INITIALIZE_CHROOT}" ]; then
  # If we're creating a new chroot, we also want to set it to the latest
  # version.
  enter_chroot \
    "${CHROOT_TRUNK_DIR}/src/scripts/run_chroot_version_hooks" --force_latest
fi

# Update chroot.
# Skip toolchain update because it already happened above, and the chroot is
# not ready to emerge all cross toolchains.
UPDATE_ARGS=( --skip_toolchain_update )
if [[ ${FLAGS_usepkg} -eq ${FLAGS_TRUE} ]]; then
  UPDATE_ARGS+=( --usepkg )
else
  UPDATE_ARGS+=( --nousepkg )
fi
if [[ ${FLAGS_fast} -eq ${FLAGS_TRUE} ]]; then
  UPDATE_ARGS+=( --fast )
else
  UPDATE_ARGS+=( --nofast )
fi
if [[ "${FLAGS_jobs}" -ne -1 ]]; then
  UPDATE_ARGS+=( --jobs=${FLAGS_jobs} )
fi
enter_chroot "${CHROOT_TRUNK_DIR}/src/scripts/update_chroot" "${UPDATE_ARGS[@]}"

CHROOT_EXAMPLE_OPT=""
if [[ "$FLAGS_chroot" != "$DEFAULT_CHROOT_DIR" ]]; then
  CHROOT_EXAMPLE_OPT="--chroot=$FLAGS_chroot"
fi

# As a final pass, build all desired cross-toolchains.
info "Updating toolchains"
enter_chroot sudo -E "${CHROOT_TRUNK_DIR}/chromite/bin/cros_setup_toolchains" \
    "${TOOLCHAIN_ARGS[@]}"

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
