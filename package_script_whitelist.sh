#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script is used to maintain the whitelist for package maintainer scripts.
# If a package maintainer script is in the whitelist file then it is ok to skip
# running that maintainer script when installing the package. Otherwise there
# should be an equivalent script that can perform those operation on a target
# root file system.
#
# The whitelist contains on entry per line which is the filename followed by
# its md5sum. Ideally it is kept in sorted by package name like below:
#    bar.postinst MD5SUM1
#    bar.postinst MD5SUM2
#    bar.preinst  MD5SUM3
#    foo.postinst MD5SUM4
#
# TODO: Should be able to whitelist on built packages and not just an already
# created rootfs.

. "$(dirname "$0")/common.sh"

DEFINE_string whitelist "${SRC_ROOT}/package_scripts/package.whitelist" \
  "The whitelist file to use."
DEFINE_string file "" "The path to a presinst/postinst file for add/audit."
DEFINE_string root "" \
  "Mounted root on which to look for the maintainer scripts when using audit."
DEFINE_string audit_pattern "*" \
  "Package name pattern used when auditing all packages [ex: 'lib*']"

FLAGS_HELP="Usage: $(basename $0) [options] add|audit|check

Use this script to maintain the package scripts whitelist. It handles the
following commands:

  add: Add the --file= specified file to the whitelist.
  audit: If no --file= is given, audit all non-whitelisted scripts in the
         given rootfs. This will show you the files in turn and give you
         the option to Skip/View/Whitelist/Create template for the script.
         If --file is given it will do the same for that one file.
  check: Checks if the --file= is in the whitelist.
"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Adds a the file at the given path to the whitelist.
#
# $1 - Path to file to add to whitelist.
add_to_whitelist() {
  local path=$1
  local whitelist="$FLAGS_whitelist"
  local file=$(basename "$path")

  local checksum=$(md5sum "$path" | awk '{ print $1 }')
  if [ ! -f "$whitelist" ]; then
cat <<EOF > "$whitelist"
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
EOF
  fi

  echo "$file $checksum" | \
    sort -u -o "${whitelist}.new" "$whitelist" -
  mv "${whitelist}.new" "$whitelist"
}

# Creates a template alternative maintainer script in the same directory
# as the whitelist file. This will run instead of the whitelisted package
# scripts using only build machine binaries and targeting a rootfs.
#
# $1 - The name of the template (like 'foo.postinst')
create_script_template() {
  local file=$1

  local whitelist_dir=$(dirname "$FLAGS_whitelist")
  local path="${whitelist_dir}/${file}"
  if [ -f "$path" ]; then
    echo "Error: Alternative maintainer script '$path' already exists."
    return
  fi

cat <<EOF > "$path"
#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# \$ROOT - The path to the target root file system.
# \$SRC_ROOT - The path to the source tree.

# $file

# TODO: The equivalent of $file running from outside of the target rootfs
# that only uses tools from the build machine and not from the target.
EOF
  chmod 0750 "$path"
}

# Show the script to the user for audit purposes.
#
# $1 - The script to show.
show_script() {
  local path=$1
  local type=$(file -b "$path")
  local is_text=$(echo "$type" | grep -c "text")
  if [ $is_text -eq 0 ]; then
    local file=$(basename "$path")
    echo "Unable to view '$file'; not a text file. Type is '$type'"
  else
    local pager="/usr/bin/less"
    if [ -n "$PAGER" ]; then
      pager="$PAGER"
    fi
    $pager "$path"
  fi
}

# Process a given script for audit purposes. We show the script to the user
# and then prompt them with options.
#
# $1 - The script to process
audit_script() {
  local path=$1
  local file=$(basename "$path")
  local prompt="$file: (Q)uit, (S)kip, (V)iew, (W)hitelist, (C)reate template?"

  show_script "$path"
  while true; do
    read -n 1 -p "$prompt " ANSWER
    echo ""
    ANSWER="${ANSWER:0:1}" # Get just the first character
    case $ANSWER in
      Q*|q*)
        exit 0
        ;;
      S*|s*)
        echo "Skipping: $file"
        return
        ;;
      V*|v*)
        show_script "$path"
        ;;
      W*|w*)
        echo "Whitelisting: $file"
        add_to_whitelist "$path"
        return
        ;;
      C*|c*)
        echo "Creating template for: $file"
        create_script_template "$file"
        ;;
      *)
        echo "Unknown response: '$ANSWER'"
        ;;
    esac
  done
}

# Audit all non-whitelisted script in $FLAGS_root
audit_all() {
  echo "Auditing packages at: $FLAGS_root"
  local dpkg_info="$FLAGS_root/var/lib/dpkg/info"
  local scripts=$(ls "$dpkg_info"/$FLAGS_audit_pattern.preinst \
                  "$dpkg_info"/$FLAGS_audit_pattern.postinst | sort -r)

  for s in $scripts; do
    if ! is_whitelisted "$s"; then
      audit_script "$s"
    fi
  done
}

case $1 in
  add)
    if [ -z "$FLAGS_file" ]; then
      echo "--file parameter is required for 'add' command."
      exit 1
    fi
    add_to_whitelist "$FLAGS_file"
    ;;
  audit)
    if [ -n "$FLAGS_file" ]; then
      audit_script "$FLAGS_file"
    elif [ -n "$FLAGS_root" ]; then
      audit_all
    else
      echo "Error: One of --file or --root is needed for audit command."
    fi
    ;;
  check)
    if [ -z "$FLAGS_file" ]; then
      echo "--file parameter is required for 'check' command."
      exit 1
    fi
    if is_whitelisted "$FLAGS_file"; then
      echo "Whitelisted"
    else
      echo "Not whitelisted"
    fi
    ;;
  *)
  echo "Unknown command."
  ;;
esac
