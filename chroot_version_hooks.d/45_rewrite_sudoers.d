# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Note that this script is invoked by make_chroot in addition
# to normal upgrade pathways.

if [ "${UID:-$(id -u)}" != 0 ]; then
  # Note that since we're screwing w/ sudo variables, this script
  # explicitly bounces up to root for everything it does- that way
  # if anyone introduces a temp depriving in the sudo setup, it can't break
  # mid upgrade.
  load_environment_whitelist
  exec sudo bash -e "${VERSION_HOOKS_DIR}/45_rewrite_sudoers.d" \
    / "${USER}" "${ENVIRONMENT_WHITELIST[@]}"
  exit 1
fi

# Reaching here means we're root.

if [ $# -lt 2 ]; then
  echo "Invoked with wrong number of args; expected root USER [variables]*"
  exit 1
fi

root=$1
username=$2
shift
shift
set -- "${@}" CROS_WORKON_SRCROOT PORTAGE_USERNAME

cat > "${root}/etc/sudoers.d/90_cros" <<EOF
Defaults env_keep += "${*}"
%adm ALL=(ALL) ALL
root ALL=(ALL) ALL
${username} ALL=NOPASSWD: ALL
EOF

chmod 0440 "${root}/etc/sudoers.d/90_cros"
chown root:root "${root}/etc/sudoers.d/90_cros"

exit 0
