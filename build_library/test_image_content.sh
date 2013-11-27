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

  # Check that /etc/localtime is a symbolic link pointing at
  # /var/lib/timezone/localtime.
  local localtime="$root/etc/localtime"
  if [ ! -L "$localtime" ]; then
    error "test_image_content: /etc/localtime is not a symbolic link"
    returncode=1
  else
    local dest=$(readlink "$localtime")
    if [ "$dest" != "/var/lib/timezone/localtime" ]; then
      error "test_image_content: /etc/localtime points at $dest"
      returncode=1
    fi
  fi

  # Check that there are no conflicts between /* and /usr/*
  # TODO(marineam): Before symlinking to /usr this test will need to be
  # rewritten to query the package database instead of the filesystem.
  local check_dir
  for check_dir in "${root}"/usr/*; do
    if [[ ! -d "${check_dir}" || -h "${check_dir}" ]]; then
      continue
    fi
    for check_file in "${check_dir}"/*; do
      root_file="${root}${check_file##*/usr}"
      trimmed_path="${root_file#${root}}"
      local whitelist
      for whitelist in "${USR_CONFLICT_WHITELIST[@]}"; do
        if [[ "${trimmed_path}" == "${whitelist}" ]]; then
	  continue 2
	fi
      done
      if [[ -e "${root_file}" || -h "${root_file}" ]]; then
        # TODO(marineam): make fatal before switching to symlinks
        warn "test_image_content: ${root_file#${root}} conflicts with /usr"
      fi
    done
  done

  return $returncode
}
