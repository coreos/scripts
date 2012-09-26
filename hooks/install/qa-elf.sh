#!/bin/bash

# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

check_compiler_flags()
{
  local binary="$1"
  local flags=false
  local fortify=true
  local stack=true
  ${readelf} -p .GCC.command.line "${binary}" | \
  {
    while read flag ; do
      flags=true
      case "${flag}" in
        *"-U_FORTIFY_SOURCE"*)
          fortify=false
          ;;
        *"-fno-stack-protector"*)
          stack=false
          ;;
      esac
    done
    if ! ${flags}; then
      echo "File not built with -frecord-gcc-switches: ${binary}"
      return
    fi
    ${fortify} || echo "File not built with -D_FORTIFY_SOURCE: ${binary}"
    ${stack} || echo "File not built with -fstack-protector: ${binary}"
  }
}

check_linker_flags()
{
  local binary="$1"
  local pie=false
  local relro=false
  local now=false
  local gold=false
  ${readelf} -dlSW "${binary}" | \
  {
    while read line ; do
      case "${line}" in
        *".note.gnu.gold-version"*)
          gold=true
          ;;
        *"Shared object file"*)
          pie=true
          ;;
        *"GNU_RELRO"*)
          relro=true
          ;;
        *"BIND_NOW"*)
          now=true
          ;;
      esac
    done

    ${pie} || echo "File not PIE: ${binary}"
    ${relro} || echo "File not built with -Wl,-z,relro: ${binary}"
    ${now} || echo "File not built with -Wl,-z,now: ${binary}"
    ${gold} || echo "File not built with gold: ${binary}"
  }
}

check_binaries()
{
  local CTARGET="${CTARGET:-${CHOST}}"
  local readelf="${CTARGET}-readelf"
  local binary
  scanelf -y -B -F '%F' -R "${D}" | \
    while read binary ; do
      case "${binary}" in
        *.ko)
          ;;
        *)
          check_compiler_flags "${binary}"
          check_linker_flags "${binary}"
          ;;
      esac
    done
}

check_binaries
