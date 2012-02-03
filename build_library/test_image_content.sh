# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

test_image_content() {
  local root="$1"
  local returncode=0

  local binaries=(
    "$root/usr/bin/Xorg"
    "$root/boot/vmlinuz"
    "$root/sbin/session_manager"
    "$root/bin/sed"
    "$root/opt/google/chrome/chrome"
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

  return $returncode
}
