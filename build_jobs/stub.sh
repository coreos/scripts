#!/bin/bash
#
# This is the common job code to paste into Jenkins for everything except
# the manifest job. Update the exec line as appropriate.

set -ex

# build may not be started without a ref value
[[ -n "${MANIFEST_REF#refs/tags/}" ]]

# hack for catalyst jobs which may leave things chowned as root
#[[ -d .cache/sdks ]] && sudo chown -R $USER .cache/sdks

./bin/cork update --create --downgrade-replace --verify --verbose \
                  --manifest-url "${MANIFEST_URL}" \
                  --manifest-branch "${MANIFEST_REF}" \
                  --manifest-name "${MANIFEST_NAME}"
# add to packages job args which needs a full toolchain:
#                  -- --toolchain_boards=${BOARD}

exec ./src/scripts/build_jobs/00_job.sh
