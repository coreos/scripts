#!/bin/bash

source /tmp/chroot-functions.sh

echo "Double checking everything is fresh and happy."
run_merge -uDN --with-bdeps=y world
