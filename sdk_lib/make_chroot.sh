#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script sets up a Gentoo chroot environment. The script is passed the
# path to an empty folder, which will be populated with a Gentoo stage3 and
# setup for development. Once created, the password is set to PASSWORD (below).
# One can enter the chrooted environment for work by running enter_chroot.sh.

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

# Check if the host machine architecture is supported.
ARCHITECTURE="$(uname -m)"
if [[ "$ARCHITECTURE" != "x86_64" ]]; then
  echo "$SCRIPT_NAME: $ARCHITECTURE is not supported as a host machine architecture."
  exit 1
fi

# Script must be run outside the chroot
assert_outside_chroot

# Define command line flags
# See http://code.google.com/p/shflags/wiki/Documentation10x

DEFINE_string chroot "$DEFAULT_CHROOT_DIR" \
  "Destination dir for the chroot environment."
DEFINE_boolean usepkg $FLAGS_TRUE "Use binary packages to bootstrap."
DEFINE_boolean delete $FLAGS_FALSE "Delete an existing chroot."
DEFINE_boolean replace $FLAGS_FALSE "Overwrite existing chroot, if any."
DEFINE_integer jobs -1 "How many packages to build in parallel at maximum."
DEFINE_boolean fast ${DEFAULT_FAST} "Call many emerges in parallel"
DEFINE_string stage3_date "2010.03.09" \
  "Use the stage3 with the given date."
DEFINE_string stage3_path "" \
  "Use the stage3 located on this path."
DEFINE_boolean cros_sdk $FLAGS_FALSE "Internal: we're called from cros_sdk"

# Parse command line flags
FLAGS_HELP="usage: $SCRIPT_NAME [flags]"
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
check_flags_only_and_allow_null_arg "$@" && set --

if [ "${FLAGS_cros_sdk}" == "${FLAGS_TRUE}" ]; then
  # HACK: If we're being called by cros_sdk, change the messages.
  SCRIPT_NAME=cros_sdk
fi

assert_not_root_user
# Set the right umask for chroot creation.
umask 022

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'set -e' is specified before now.
# TODO: replace shflags with something less error-prone, or contribute a fix.
set -e

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
  CHROOT_CHROMITE_DIR="/home/${USER}/trunk/chromite"
  EMERGE_CMD="${CHROOT_CHROMITE_DIR}/bin/parallel_emerge"
fi

function in_chroot {
  sudo "${CHROOT_PASSTHRU[@]}" chroot "$FLAGS_chroot" "$@"
}

function bash_chroot {
  # Use $* not $@ since 'bash -c' needs a single arg
  # Use -l to force source of /etc/profile (login shell)
  sudo "${CHROOT_PASSTHRU[@]}" chroot "$FLAGS_chroot" bash -l -c "$*"
}

function sudo_chroot {
  # The same as bash_chroot, except ran as the normal user.
  sudo chroot "$FLAGS_chroot" sudo -i -u ${USER} "${CHROOT_PASSTHRU[@]}" -- "$@"
}

function cleanup {
  # Clean up mounts
  safe_umount_tree "${FLAGS_chroot}"
}

function delete_existing {
  # Delete old chroot dir
  if [[ -e "$FLAGS_chroot" ]]; then
    echo "$SCRIPT_NAME: Cleaning up old mount points..."
    cleanup
    echo "$SCRIPT_NAME: Deleting $FLAGS_chroot..."
    sudo rm -rf "$FLAGS_chroot"
    echo "$SCRIPT_NAME: Done."
  fi
}

function init_users () {
   echo "$SCRIPT_NAME: Set timezone..."
   # date +%Z has trouble with daylight time, so use host's info
   in_chroot rm -f /etc/localtime
   if [ -f /etc/localtime ] ; then
     sudo cp /etc/localtime "${FLAGS_chroot}/etc"
   else
     in_chroot ln -sf /usr/share/zoneinfo/PST8PDT /etc/localtime
   fi
   echo "$SCRIPT_NAME: Adding user/group..."
   # Add ourselves as a user inside the chroot.
   in_chroot groupadd -g 5000 eng
   # We need the UID to match the host user's. This can conflict with
   # a particular chroot UID. At the same time, the added user has to
   # be a primary user for the given UID for sudo to work, which is
   # determined by the order in /etc/passwd. Let's put ourselves on top
   # of the file.
   in_chroot useradd -o -G ${DEFGROUPS} -g eng -u `id -u` -s \
     /bin/bash -m -c "${FULLNAME}" -p ${CRYPTED_PASSWD} ${USER}
   # Because passwd generally isn't sorted and the entry ended up at the
   # bottom, it is safe to just take it and move it to top instead.
   in_chroot sed -e '1{h;d};$!{H;d};$G' -i /etc/passwd
}

function init_setup () {
   echo "$SCRIPT_NAME: Running init_setup()..."
   sudo mkdir -p "${FLAGS_chroot}/usr"
   sudo ln -sf "${CHROOT_TRUNK}/src/third_party/portage" \
     "${FLAGS_chroot}/usr/portage"
   sudo mkdir -p "${FLAGS_chroot}/usr/local/portage"
   sudo chmod 755 "${FLAGS_chroot}/usr/local/portage"
   sudo ln -sf "${CHROOT_TRUNK}/src/third_party/chromiumos-overlay" \
     "${FLAGS_chroot}"/"${CHROOT_OVERLAY}"
   sudo ln -sf "${CHROOT_TRUNK}/src/third_party/portage-stable" \
     "${FLAGS_chroot}"/"${PORTAGE_STABLE_OVERLAY}"
   sudo mkdir -p "${FLAGS_chroot}"/"${CROSSDEV_OVERLAY}"
   sudo chmod 755 "${FLAGS_chroot}"/"${CROSSDEV_OVERLAY}"

   # Some operations need an mtab
   in_chroot ln -s /proc/mounts /etc/mtab

   # Set up sudoers.  Inside the chroot, the user can sudo without a password.
   # (Safe enough, since the only way into the chroot is to 'sudo chroot', so
   # the user's already typed in one sudo password...)
   # Make sure the sudoers.d subdir exists as older stage3 base images lack it.
   sudo mkdir -p "${FLAGS_chroot}/etc/sudoers.d"
   sudo_clobber "${FLAGS_chroot}/etc/sudoers.d/90_cros" <<EOF
Defaults env_keep += CROS_WORKON_SRCROOT
Defaults env_keep += CHROMEOS_OFFICIAL
Defaults env_keep += PORTAGE_USERNAME
Defaults env_keep += http_proxy
Defaults env_keep += ftp_proxy
Defaults env_keep += all_proxy
%adm ALL=(ALL) ALL
root ALL=(ALL) ALL
$USER ALL=NOPASSWD: ALL
EOF
   bash_chroot "find /etc/sudoers* -type f -exec chmod 0440 {} +"
   bash_chroot "chown -R root:root /etc/sudoers*" # Fix bad group for some.

   echo "$SCRIPT_NAME: Setting up hosts/resolv..."
   # Copy config from outside chroot into chroot
   sudo cp /etc/hosts "$FLAGS_chroot/etc/hosts"
   sudo chmod 0644 "$FLAGS_chroot/etc/hosts"
   sudo cp /etc/resolv.conf "$FLAGS_chroot/etc/resolv.conf"
   sudo chmod 0644 "$FLAGS_chroot/etc/resolv.conf"

   # Setup host make.conf. This includes any overlay that we may be using
   # and a pointer to pre-built packages.
   # TODO: This should really be part of a profile in the portage
   echo "$SCRIPT_NAME: Setting up /etc/make.*..."
   sudo mv "${FLAGS_chroot}"/etc/make.conf{,.orig}
   sudo ln -sf "${CHROOT_CONFIG}/make.conf.amd64-host" \
     "${FLAGS_chroot}/etc/make.conf"
   sudo mv "${FLAGS_chroot}"/etc/make.profile{,.orig}
   sudo ln -sf "${CHROOT_OVERLAY}/profiles/default/linux/amd64/10.0" \
     "${FLAGS_chroot}/etc/make.profile"

   # Create make.conf.user
   sudo touch "${FLAGS_chroot}"/etc/make.conf.user
   sudo chmod 0644 "${FLAGS_chroot}"/etc/make.conf.user

   # Create directories referred to by our conf files.
   sudo mkdir -p -m 775 "${FLAGS_chroot}/var/lib/portage/distfiles"
   sudo mkdir -p -m 775 "${FLAGS_chroot}/var/lib/portage/distfiles-target"
   sudo mkdir -p -m 775 "${FLAGS_chroot}/var/lib/portage/pkgs"

   if [[ $FLAGS_jobs -ne -1 ]]; then
     EMERGE_JOBS="--jobs=$FLAGS_jobs"
   fi

   # Add chromite/bin and depot_tools into the path globally; note that the
   # chromite wrapper itself might also be found in depot_tools.
   # We rely on 'env-update' getting called below.
   target="${FLAGS_chroot}/etc/env.d/99chromiumos"
   sudo_clobber "${target}" <<EOF
PATH=/home/$USER/trunk/chromite/bin:/home/$USER/depot_tools
CROS_WORKON_SRCROOT="${CHROOT_TRUNK}"
PORTAGE_USERNAME=$USER
EOF

   # TODO(zbehan): Configure stuff that is usually configured in postinst's,
   # but wasn't. Fix the postinst's. crosbug.com/18036
   echo "Running post-inst configuration hacks"
   in_chroot env-update
   if [ -f ${FLAGS_chroot}/usr/bin/build-docbook-catalog ]; then
     # For too ancient chroots that didn't have build-docbook-catalog, this
     # is not relevant, and will get installed during update.
     in_chroot build-docbook-catalog
   fi

   # Configure basic stuff needed
   in_chroot env-update
   bash_chroot ls -l /etc/make.conf
   bash_chroot ls -l /etc/make.profile
   bash_chroot ls -l /usr/local/portage/chromiumos/profiles/default/linux/amd64/10.0

   target="${FLAGS_chroot}/etc/profile.d"
   sudo mkdir -p "${target}"
   sudo_clobber "${target}/chromiumos-niceties.sh" << EOF
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
     sudo_append "${localegen}" <<EOF
en_US ISO-8859-1
en_US.UTF-8 UTF-8
EOF
   fi

   # Add chromite as a local site-package.
   mkdir -p "${FLAGS_chroot}/home/$USER/.local/lib/python2.6/site-packages"
   ln -s ../../../../trunk/chromite \
     "${FLAGS_chroot}/home/$USER/.local/lib/python2.6/site-packages/"

   chmod a+x "$FLAGS_chroot/home/$USER/.bashrc"
   # Automatically change to scripts directory
   echo 'cd ${CHROOT_CWD:-~/trunk/src/scripts}' \
       >> "$FLAGS_chroot/home/$USER/.bash_profile"

   # Enable bash completion for build scripts
   echo ". ~/trunk/src/scripts/bash_completion" \
       >> "$FLAGS_chroot/home/$USER/.bashrc"

   # Warn if attempting to use source control commands inside the chroot
   for NOUSE in svn gcl gclient
   do
     echo "alias $NOUSE='echo In the chroot, it is a bad idea to run $NOUSE'" \
       >> "$FLAGS_chroot/home/$USER/.bash_profile"
   done

   if [[ "$USER" = "chrome-bot" ]]; then
     # Copy ssh keys, so chroot'd chrome-bot can scp files from chrome-web.
     cp -r ~/.ssh "$FLAGS_chroot/home/$USER/"
   fi

   if [[ -f $HOME/.gitconfig ]]; then
     # Copy .gitconfig into chroot so repo and git can be used from inside
     # This is required for repo to work since it validates the email address
     echo "Copying ~/.gitconfig into chroot"
     cp $HOME/.gitconfig "$FLAGS_chroot/home/$USER/"
   fi
}

# Handle deleting an existing environment
if [[ $FLAGS_delete  -eq $FLAGS_TRUE || \
      $FLAGS_replace -eq $FLAGS_TRUE ]]; then
  delete_existing
  [[ $FLAGS_delete -eq $FLAGS_TRUE ]] && exit 0
fi

CHROOT_TRUNK="${CHROOT_TRUNK_DIR}"
PORTAGE="${SRC_ROOT}/third_party/portage"
OVERLAY="${SRC_ROOT}/third_party/chromiumos-overlay"
CONFIG_DIR="${OVERLAY}/chromeos/config"
CHROOT_CONFIG="${CHROOT_TRUNK}/src/third_party/chromiumos-overlay/chromeos/config"
PORTAGE_STABLE_OVERLAY="/usr/local/portage/stable"
CROSSDEV_OVERLAY="/usr/local/portage/crossdev"
CHROOT_OVERLAY="/usr/local/portage/chromiumos"
CHROOT_STATE="${FLAGS_chroot}/etc/debian_chroot"
CHROOT_PASSTHRU=(CROS_WORKON_SRCROOT="$CHROOT_TRUNK" PORTAGE_USERNAME="$USER"
                 IGNORE_PREFLIGHT_BINHOST="$IGNORE_PREFLIGHT_BINHOST")

# Pass proxy variables into the environment.
for type in http ftp all; do
   value=$(env | grep ${type}_proxy || true)
   if [ -n "${value}" ]; then
      CHROOT_PASSTHRU+=("$value")
   fi
done

# Create the base Gentoo stage3 based on last version put in chroot
STAGE3="${OVERLAY}/chromeos/stage3/stage3-amd64-${FLAGS_stage3_date}.tar.bz2"
if [ -f $CHROOT_STATE ] && \
  ! sudo egrep -q "^STAGE3=$STAGE3" $CHROOT_STATE >/dev/null 2>&1
then
  echo "$SCRIPT_NAME: STAGE3 version has changed."
  delete_existing
fi

if [ -n "${FLAGS_stage3_path}" ]; then
  if [ -f "${FLAGS_stage3_path}" ]; then
    STAGE3="${FLAGS_stage3_path}"
  else
    error "Invalid stage3!"
    exit 1;
  fi
fi

# Create the destination directory
mkdir -p "$FLAGS_chroot"

echo
if [ -f $CHROOT_STATE ]
then
  echo "$SCRIPT_NAME: STAGE3 already set up.  Skipping..."
else
  echo "$SCRIPT_NAME: Unpacking STAGE3..."
  sudo tar -xp -I $(type -p pbzip2 || echo bzip2) \
      -C "${FLAGS_chroot}" -f "${STAGE3}"
  sudo rm -f $FLAGS_chroot/etc/make.globals
  sudo rm -f $FLAGS_chroot/etc/make.conf.user
fi

# Set up users, if needed, before mkdir/mounts below
[ -f $CHROOT_STATE ] || init_users

echo
echo "$SCRIPT_NAME: Setting up mounts..."
# Set up necessary mounts and make sure we clean them up on exit
trap cleanup EXIT
sudo mkdir -p "${FLAGS_chroot}/${CHROOT_TRUNK}"
sudo mount --bind /dev "${FLAGS_chroot}/dev"
sudo mount --bind "${GCLIENT_ROOT}" "${FLAGS_chroot}/${CHROOT_TRUNK}"
sudo mount none -t proc "$FLAGS_chroot/proc"
sudo mount none -t devpts "$FLAGS_chroot/dev/pts"
sudo mkdir -p "${FLAGS_chroot}/run"
if [ -d /run ]; then
  sudo mount --bind /run "$FLAGS_chroot/run"
  if [ -d /run/shm ]; then
    sudo mount --bind /run/shm "$FLAGS_chroot/run/shm"
  fi
fi
PREBUILT_SETUP="$FLAGS_chroot/etc/make.conf.prebuilt_setup"
if [[ -z "$IGNORE_PREFLIGHT_BINHOST" ]]; then
  echo 'PORTAGE_BINHOST="$FULL_BINHOST"' | sudo_clobber "$PREBUILT_SETUP"
else
  sudo_clobber "$PREBUILT_SETUP" < /dev/null
fi
sudo chmod 0644 "$PREBUILT_SETUP"

# For bootstrapping from old wget, disable certificate checking. Once we've
# upgraded to new curl (below), certificate checking is re-enabled. See
# http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=409938
bash_chroot 'cat > /etc/make.conf.fetchcommand_setup' <<'EOF'
FETCHCOMMAND="/usr/bin/wget -t 5 -T 60 --no-check-certificate --passive-ftp -O \"\${DISTDIR}/\${FILE}\" \"\${URI}\""
RESUMECOMMAND="/usr/bin/wget -c -t 5 -T 60 --no-check-certificate --passive-ftp -O \"\${DISTDIR}/\${FILE}\" \"\${URI}\""
EOF
sudo chmod 0644 "${FLAGS_chroot}"/etc/make.conf.fetchcommand_setup
bash_chroot 'cat > /etc/make.conf.host_setup' <<EOF
# Created by make_chroot
source make.conf.prebuilt_setup
source make.conf.fetchcommand_setup
MAKEOPTS="-j${NUM_JOBS}"
EOF
sudo chmod 0644 "${FLAGS_chroot}"/etc/make.conf.host_setup

if ! [ -f "$CHROOT_STATE" ];then
  INITIALIZE_CHROOT=1
fi


if [ -z "${INITIALIZE_CHROOT}" ];then
  echo "$SCRIPT_NAME: chroot already initialized.  Skipping..."
else
  # run all the init stuff to setup the env
  init_setup
fi

# Add file to indicate that it is a chroot
# Add version of $STAGE3 for update checks
sudo sh -c "echo STAGE3=$STAGE3 > $CHROOT_STATE"

echo "$SCRIPT_NAME: Updating portage"
in_chroot emerge -uNv portage

echo "$SCRIPT_NAME: Updating toolchain"
in_chroot emerge -uNv $USEPKG '>=sys-devel/gcc-4.4' sys-libs/glibc \
    sys-devel/binutils sys-kernel/linux-headers

# HACK: Select the latest toolchain. We're assuming that when this is
# ran, the chroot has no experimental versions of new toolchains, just
# one that is very old, and one that was just emerged.
CHOST="$(in_chroot portageq envvar CHOST)"
LATEST="$(in_chroot gcc-config -l | grep "${CHOST}" | tail -n1 | \
          cut -f3 -d' ')"
in_chroot gcc-config "${LATEST}"
in_chroot emerge --unmerge "<sys-devel/gcc-${LATEST/${CHOST}-/}"

# dhcpcd is included in 'world' by the stage3 that we pull in for some reason.
# We have no need to install it in our host environment, so pull it out here.
echo "$SCRIPT_NAME: Deselecting dhcpcd"
in_chroot $EMERGE_CMD --deselect dhcpcd

echo "$SCRIPT_NAME: Running emerge ccache curl sudo ..."
in_chroot $EMERGE_CMD -uNv $USEPKG ccache net-misc/curl sudo $EMERGE_JOBS

# Curl is now installed, so we can depend on it now.
bash_chroot 'cat > /etc/make.conf.fetchcommand_setup' <<'EOF'
FETCHCOMMAND='curl -f -y 30 --retry 9 -L --output \${DISTDIR}/\${FILE} \${URI}'
RESUMECOMMAND='curl -f -y 30 -C - --retry 9 -L --output \${DISTDIR}/\${FILE} \${URI}'
EOF
sudo chmod 0644 "${FLAGS_chroot}"/etc/make.conf.fetchcommand_setup

if [ -n "${INITIALIZE_CHROOT}" ]; then
  # If we're creating a new chroot, we also want to set it to the latest
  # version.
  sudo_chroot \
      "${CHROOT_TRUNK}/src/scripts/run_chroot_version_hooks" --force_latest
fi

# Update chroot
UPDATE_ARGS=""
if [[ $FLAGS_usepkg -eq $FLAGS_TRUE ]]; then
  UPDATE_ARGS+=" --usepkg"
else
  UPDATE_ARGS+=" --nousepkg"
fi
if [[ ${FLAGS_fast} -eq ${FLAGS_TRUE} ]]; then
  UPDATE_ARGS+=" --fast"
else
  UPDATE_ARGS+=" --nofast"
fi
sudo_chroot "${CHROOT_TRUNK}/src/scripts/update_chroot" ${UPDATE_ARGS}

# Unmount trunk
sudo umount "${FLAGS_chroot}/${CHROOT_TRUNK}"

# Clean up the chroot mounts
trap - EXIT
cleanup

if [[ "$FLAGS_chroot" = "$DEFAULT_CHROOT_DIR" ]]; then
  CHROOT_EXAMPLE_OPT=""
else
  CHROOT_EXAMPLE_OPT="--chroot=$FLAGS_chroot"
fi

print_time_elapsed

echo
echo "$SCRIPT_NAME: All set up.  To enter the chroot, run:"
echo "$SCRIPT_NAME: $ cros_sdk --enter $CHROOT_EXAMPLE_OPT"
echo ""
echo "CAUTION: Do *NOT* rm -rf the chroot directory; if there are stale bind"
echo "mounts you may end up deleting your source tree too.  To unmount and"
echo "delete the chroot cleanly, use:"
echo "$ $SCRIPT_NAME --delete $CHROOT_EXAMPLE_OPT"
