# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# When bootstrapping the chroot, only wget is available, and we must
# disable certificate checking.  Once the chroot is fully
# initialized, we can switch to curl, and re-enable the certificate
# checks.  See http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=409938
#
# Usage:
# $1 - 'wget' requests the bootstrap special content; otherwise
#      uses 'curl'.
_make_conf_fetchcommand() {
  local cmd options output_opt resume_opt
  local fileref='\"\${DISTDIR}/\${FILE}\"'
  local uri_ref='\"\${URI}\"'

  if [ "$1" = "wget" ] ; then
    cmd=/usr/bin/wget
    options="-t 5 -T 60 --no-check-certificate --passive-ftp"
    resume_opt="-c"
    output_opt="-O"
  else
    cmd=curl
    options="-f -y 30 --retry 9 -L"
    resume_opt="-C -"
    output_opt="--output"
  fi

  local args="$options $output_opt $fileref $uri_ref"
  echo FETCHCOMMAND=\"$cmd $args\"
  echo RESUMECOMMAND=\"$cmd $resume_opt $args\"
  echo
}

# The default PORTAGE_BINHOST setting selects the preflight
# binhosts.  We override the setting if the build environment
# requests it.
_make_conf_prebuilt() {
  if [[ -n "$IGNORE_PREFLIGHT_BINHOST" ]]; then
    echo 'PORTAGE_BINHOST="$FULL_BINHOST"'
    echo
  fi
}

# Include configuration settings for building private overlay
# packages, if the overlay is present.
#
# N.B. The test for the presence of the private overlay uses a path
# that only exists inside the chroot.  When this function is invoked
# during bootstrapping, the test will fail, meaning the private
# overlay won't be used during bootstrapping.  This is OK for
# current requirements.  If you're reading this comment because you
# can't get the private overlay included during bootstrapping, this
# is your bug.  :-)
_make_conf_private() {
  local chromeos_overlay="src/private-overlays/chromeos-overlay"
  chromeos_overlay="$CHROOT_TRUNK_DIR/$chromeos_overlay"
  if [ -d "$chromeos_overlay" ]; then
    local boto_config="$chromeos_overlay/googlestorage_account.boto"
    local gsutil_cmd='gsutil cp \"${URI}\" \"${DISTDIR}/${FILE}\"'
    cat <<EOF
source $chromeos_overlay/make.conf

FETCHCOMMAND_GS="bash -c 'BOTO_CONFIG=$boto_config $gsutil_cmd'"
RESUMECOMMAND_GS="$FETCHCOMMAND_GS"

PORTDIR_OVERLAY="\$PORTDIR_OVERLAY $chromeos_overlay"

EOF
  fi
}

# Create /etc/make.conf.host_setup according to parameters.
#
# Usage:
# $1 - 'wget' for bootstrapping; 'curl' otherwise.
# $2 - When outside the chroot, path to the chroot.  Empty when
#      inside the chroot.
_create_host_setup() {
  local fetchtype="$1"
  local host_setup="$2/etc/make.conf.host_setup"
  ( echo "# Automatically generated.  EDIT THIS AND BE SORRY."
    echo
    _make_conf_fetchcommand "$fetchtype"
    _make_conf_private
    _make_conf_prebuilt
    echo 'MAKEOPTS="-j'${NUM_JOBS}'"' ) | sudo_clobber "$host_setup"
  sudo chmod 644 "$host_setup"
}


# Create /etc/make.conf.host_setup for early bootstrapping of the
# chroot.  This is done early in make_chroot, and the results are
# overwritten later in the process.
#
# Usage:
#   $1 - Path to chroot as seen from outside
create_bootstrap_host_setup() {
  _create_host_setup wget "$@"
}


# Create /etc/make.conf.host_setup for normal usage.
create_host_setup() {
  _create_host_setup curl ''
}
