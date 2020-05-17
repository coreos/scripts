# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

GLSA_WHITELIST=(
	201412-09 # incompatible CA certificate version numbers
	201908-14 # backported both CVE fixes
	201909-01 # Perl, SDK only
	201909-08 # backported fix
	201911-01 # package too old to even have the affected USE flag
	202003-20 # backported fix
	202003-12 # only applies to old, already-fixed CVEs
	202003-24 # SDK only
	202003-26 # SDK only
	202003-30 # fixed by updating within older minor release
	202003-31 # SDK only
	202003-52 # difficult to update :-(
	202004-10 # fixed by updating within older minor release
	202004-13 # fixed by updating within older minor release
	202005-02 # SDK only
	202005-09 # SDK only
)

glsa_image() {
  if glsa-check-$BOARD -t all | grep -Fvx "${GLSA_WHITELIST[@]/#/-e}"; then
    echo "The above GLSAs apply to $ROOT"
    return 1
  fi

  return 0
}

test_image_content() {
  local root="$1"
  local returncode=0

  info "Checking $1"
  local check_root="${BUILD_LIBRARY_DIR}/check_root"
  if ! ROOT="$root" "$check_root" libs; then
    warn "test_image_content: Failed dependency check"
    warn "This may be the result of having a long-lived SDK with binary"
    warn "packages that predate portage 2.2.18. If this is the case try:"
    echo "    emerge-$BOARD -agkuDN --rebuilt-binaries=y -j9  @world"
    echo "    emerge-$BOARD -a --depclean"
    #returncode=1
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

  # Check that there are no conflicts between /* and /usr/*
  if ! ROOT="$root" "$check_root" usr; then
    error "test_image_content: Failed /usr conflict check"
    returncode=1
  fi

  # Check that there are no #! lines pointing to non-existant locations
  if ! ROOT="$root" "$check_root" shebang; then
    warn "test_image_content: Failed #! check"
    # Only a warning for now. We still have to actually remove all of the
    # offending scripts.
    #error "test_image_content: Failed #! check"
    #returncode=1
  fi

  if ! sudo ROOT="$root" "$check_root" symlink; then
    error "test_image_content: Failed symlink check"
    returncode=1
  fi

  if ! ROOT="$root" glsa_image; then
      returncode=1
  fi

  return $returncode
}
