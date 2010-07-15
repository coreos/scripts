#!/bin/sh

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to push the output of build_image.sh to a remote image server

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

# Flags
DEFINE_string upgrade_server "" "SSH-capable host for upgrade server install"
DEFINE_string dest_path "" "Directory on host to do install"
DEFINE_string client_address "" "IP Address of netbook to update"
DEFINE_string server_address "" "IP Address of upgrade server"
DEFINE_boolean start_server ${FLAGS_TRUE} "Start up the server"
DEFINE_boolean stop_server  ${FLAGS_FALSE} "Start up the server"
DEFINE_boolean no_copy_archive  ${FLAGS_FALSE} "Skip copy of files to server"
DEFINE_string from "" "Image directory to upload to server"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

set -e

# Make sure dev server argument has been set
require_upgrade_server () {
  if [ -z "${FLAGS_upgrade_server}" ] ; then
    echo "The --upgrade-server= argument is mandatory"
    exit 1
  fi
}

# Make sure a pointer to the latest image has been created
require_latest_image () {
  [ -n "$latest_image" ] && return
  if [ -n "${FLAGS_from}" ] ; then
    latest_image=$(readlink -f ${FLAGS_from})
  else
    latest_image=$(env CHROMEOS_BUILD_ROOT=${SCRIPTS_DIR}/../build \
      ${SCRIPTS_DIR}/get_latest_image.sh)
  fi
}

validate_devserver_path () {
  if [ $(expr "${FLAGS_dest_path}" : '\.\.') != 0 ]; then
    echo "Error: --dest_path argument (${FLAGS_dest_path}) must not be relative"
    exit 1
  fi
  FLAGS_dest_path=/tmp/devserver/${FLAGS_dest_path##/tmp/devserver/}
}

# Copy the various bits of the dev server scripts over to our remote host
create_devserver () {
  FLAGS_dest_path=$1
  validate_devserver_path

  echo "Creating dev server in ${FLAGS_upgrade_server}:${FLAGS_dest_path}..."

  require_upgrade_server
  # Create new empty directory to hold server components
  ssh "${FLAGS_upgrade_server}" rm -rf "${FLAGS_dest_path}" || true
  ssh "${FLAGS_upgrade_server}" mkdir -p "${FLAGS_dest_path}/python"

  # Copy server components into place
  (cd ${SCRIPTS_DIR}/../.. && \
      tar zcf - --exclude=.git --exclude=.svn \
      src/scripts/start_devserver \
      src/scripts/{common,get_latest_image,mk_memento_images}.sh \
      src/third_party/shflags src/platform/dev) | \
      ssh ${FLAGS_upgrade_server} "cd ${FLAGS_dest_path} && tar zxf -"

  # Copy Python web library into place out of the chroot
  (cd ${SCRIPTS_DIR}/../../chroot/usr/lib/python*/site-packages && \
      tar zcf - web*) | \
      ssh ${FLAGS_upgrade_server} "cd ${FLAGS_dest_path}/python && tar zxf -"
}

# Copy the latest image over to archive server
create_archive_dir () {
  archive_dir=$1

  echo "Creating archive dir in ${FLAGS_upgrade_server}:${archive_dir}..."

  require_upgrade_server
  require_latest_image

  # Copy the latest image into the newly created archive
  ssh "${FLAGS_upgrade_server}" "mkdir -p ${archive_dir}"

  image_path=${latest_image##*build/}

  (cd ${SCRIPTS_DIR}/../build && tar zcf - ${image_path}) | \
      ssh ${FLAGS_upgrade_server} "cd ${archive_dir} && tar zxf -"

  # unpack_partitions.sh lies in its hashbang.  It really wants bash
  unpack_script=${archive_dir}/${image_path}/unpack_partitions.sh
  ssh ${FLAGS_upgrade_server} "sed -e 's/^#!\/bin\/sh/#!\/bin\/bash/' < ${unpack_script} > ${unpack_script}.new && chmod 755 ${unpack_script}.new && mv ${unpack_script}.new ${unpack_script}"

  # Since we are in static-only mode, we need to create a few links
  for file in update.gz stateful.image.gz ; do
    ssh ${FLAGS_upgrade_server} "cd ${archive_dir} && ln -sf ${image_path}/$file ."
    ssh ${FLAGS_upgrade_server} "ln -sf ${archive_dir}/$file ${FLAGS_dest_path}/src/platform/dev/static"
  done
}

stop_server () {
  require_upgrade_server
  echo "Stopping remote devserver..."
  echo "(Fast restart using \"$0 --upgrade_server=${FLAGS_upgrade_server} --dest_path=${FLAGS_dest_path} --no_copy_archive\")"
  ssh ${FLAGS_upgrade_server} pkill -f ${archive_dir} || /bin/true
}

# Start remote server
start_server () {
  require_upgrade_server
  echo "Starting remote devserver..."
  server_logfile=/tmp/devserver_log.$$
  portlist=/tmp/devserver_portlist.$$
  echo "Server will be logging locally to $server_logfile"

  # Find a TCP listen socket that is not in use
  ssh ${FLAGS_upgrade_server} "netstat -lnt" | awk '{ print $4 }' > $portlist
  server_port=8081
  while grep -q ":${server_port}$" $portlist; do
    server_port=$[server_port + 1]
  done
  rm -f $portlist

  ssh ${FLAGS_upgrade_server} "cd ${FLAGS_dest_path}/src/scripts && env PYTHONPATH=${remote_root}${FLAGS_dest_path}/python CHROMEOS_BUILD_ROOT=${archive_dir} ./start_devserver --archive_dir ${archive_dir} $server_port" > $server_logfile 2>&1 &
  server_pid=$!

  trap server_cleanup 2

  # Wait for server to startup
  while sleep 1; do
    if fgrep -q 'Serving images from' $server_logfile; then
      echo "Server is ready"
      break
    elif kill -0 ${server_pid}; then
      continue
    else
      echo "Server failed to startup"
      exit 1
    fi
  done
}

server_cleanup () {
  trap '' 2
  stop_server
  exit 0
}

# If destination path wasn't set on command line, create one from scratch
if [ -z "${FLAGS_dest_path}" -a ${FLAGS_stop_server} -eq ${FLAGS_FALSE} ] ; then
  require_latest_image
  hostname=$(uname -n)
  hostname=${hostname%%.*}
  image_name=${latest_image##*/}
  create_devserver ${hostname}_${image_name}
  FLAGS_start_server=${FLAGS_TRUE}
else
  validate_devserver_path
fi

if [ ${FLAGS_stop_server} -eq ${FLAGS_FALSE} -a \
     ${FLAGS_no_copy_archive} -eq ${FLAGS_FALSE} ] ; then
  create_archive_dir "${FLAGS_dest_path}/archive"
  FLAGS_start_server=${FLAGS_TRUE}
else
  archive_dir="${FLAGS_dest_path}/archive"
fi

if [ "${FLAGS_stop_server}" -eq ${FLAGS_TRUE} ] ; then
  stop_server
  exit 0
fi

# Make sure old devserver is dead, then restart it
if [ "${FLAGS_start_server}" -eq ${FLAGS_TRUE} ] ; then
  stop_server
  start_server

  tail -f ${server_logfile} &

  # Now tell the client to load from the server
  if [ -z "${FLAGS_server_address}" ] ; then
    FLAGS_server_address=${FLAGS_upgrade_server}
  fi
  live_args="--update_url=http://${FLAGS_server_address}:${server_port}/update \
        --remote=${FLAGS_client_address}"
  if [ -n "${FLAGS_client_address}" ] ; then
   echo "Running ${SCRIPTS_DIR}/image_to_live.sh $live_args"
    ${SCRIPTS_DIR}/image_to_live.sh $live_args &
  else
    echo "Start client upgrade using:"
    echo "    ${SCRIPTS_DIR}/image_to_live.sh ${live_args}<client_ip_address>"
  fi

  wait ${server_pid}
fi

