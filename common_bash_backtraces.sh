# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Code used for bash stack dumps included by common.sh when we're in
# bash mode.

# Output a backtrace all the way back to the raw invocation, suppressing
# only the _dump_trace frame itself.

_dump_trace() {
  local j n p func src line args
  p=${#BASH_ARGV[@]}
  for (( n = ${#FUNCNAME[@]}; n > 1; n-- )); do
    func=${FUNCNAME[${n} - 1]}
    src=${BASH_SOURCE[${n}]##*/}
    line=${BASH_LINENO[${n} - 1]}
    args=
    if [[ -z ${BASH_ARGC[${n} -1]} ]]; then
      args='(args unknown, no debug available)'
    else
      for (( j = 0 ; j < ${BASH_ARGC[${n} -1]} ; ++j )); do
        args="${args:+${args} }'${BASH_ARGV[$(( p - j - 1 ))]}'"
      done
      ! (( p -= ${BASH_ARGC[${n} - 1]} ))
    fi
    if [[ $n == ${#FUNCNAME[@]} ]]; then
      error "script called: ${0##/*} ${args}"
      error "Backtrace:  (most recent call is last)"
    else
      error "$(printf '  file %s, line %s, called: %s %s' \
               "${src}" "${line}" "${func}" "${args}")"
    fi
  done
}
