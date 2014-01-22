# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Files that are known to conflict with /usr but are OK because they
# are already fixed by toggling the symlink-usr USE flag.
USR_CONFLICT_WHITELIST=(
    /bin/awk
    /bin/basename
    /bin/chroot
    /bin/cut
    /bin/dir
    /bin/dirname
    /bin/du
    /bin/env
    /bin/expr
    /bin/gawk
    /bin/head
    /bin/mkfifo
    /bin/mktemp
    /bin/passwd
    /bin/readlink
    /bin/seq
    /bin/sleep
    /bin/sort
    /bin/tail
    /bin/touch
    /bin/tr
    /bin/tty
    /bin/uname
    /bin/vdir
    /bin/wc
    /bin/yes
)

test_image_content() {
  local root="$1"
  local returncode=0

  if [[ -z "$BOARD" ]]; then
    die '$BOARD is undefined!'
  fi
  local portageq="portageq-$BOARD"

  local binaries=(
    "$root/boot/vmlinuz"
    "$root/bin/sed"
  )

  for test_file in "${binaries[@]}"; do
    if [ ! -f "$test_file" ]; then
      error "test_image_content: Cannot find '$test_file'"
      returncode=1
    fi
  done

  local libs=( $(sudo find "$root" -type f -name '*.so*') )

  # Check that all .so files, plus the binaries, have the appropriate
  # dependencies.
  local check_deps="${BUILD_LIBRARY_DIR}/check_deps"
  if ! "$check_deps"  "$root" "${binaries[@]}" "${libs[@]}"; then
    error "test_image_content: Failed dependency check"
    returncode=1
  fi

  local blacklist_dirs=(
    "$root/usr/share/locale"
  )
  for dir in "${blacklist_dirs[@]}"; do
    if [ -d "$dir" ]; then
      warn "test_image_content: Blacklisted directory found: $dir"
      # Only a warning for now, size isn't important enough to kill time
      # playing whack-a-mole on things like this this yet.
      #error "test_image_content: Blacklisted directory found: $dir"
      #returncode=1
    fi
  done

  # Check that the symlink-usr flag agrees with the filesystem state.
  # Things are likely to break if they don't match.
  if [[ $(ROOT="${root}" $portageq envvar USE) == *symlink-usr* ]]; then
    local dir
    for dir in bin sbin lib32 lib64; do
      if [[ -d "${root}/usr/${dir}" ]]; then
        if [[ ! -h "${root}/${dir}" || \
          $(readlink "${root}/${dir}") != "usr/${dir}" ]]
        then
          error "test_image_content: /${dir} is not a symlink to /usr/${dir}"
          returncode=1
        fi
      fi
    done

    # The whitelist is only required if the use flag is unset
    USR_CONFLICT_WHITELIST=()
  fi

  # Check that there are no conflicts between /* and /usr/*
  local pkgdb=$(ROOT="${root}" $portageq vdb_path)
  local files=$(awk '$2 ~ /^\/(bin|sbin|lib|lib32|lib64)\// {print $2}' \
                "${pkgdb}"/*/*/CONTENTS)
  local check_file
  for check_file in $files; do
    local whitelist
    for whitelist in "${USR_CONFLICT_WHITELIST[@]}"; do
      if [[ "${check_file}" == "${whitelist}" ]]; then
        continue 2
      fi
    done
    if grep -q "^... /usr$check_file " "${pkgdb}"/*/*/CONTENTS; then
      error "test_image_content: $check_file conflicts with /usr$check_file"
      returncode=1
    fi
  done

  return $returncode
}
