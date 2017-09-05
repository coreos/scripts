#!/usr/bin/env bash

set -eux

download() {
    local channel="$1"
    local version="$2"
    local board="$3"

    local gs="gs://builds.release.core-os.net/${channel}/boards/${board}/${version}"
    local dir="${BASEDIR}/${board}/${version}"
    mkdir -p "${dir}"
    pushd "${dir}" >/dev/null

    gsutil cp \
        "${gs}/coreos_production_image.vmlinuz" \
        "${gs}/coreos_production_image.vmlinuz.sig" \
        "${gs}/coreos_production_update.bin.bz2" \
        "${gs}/coreos_production_update.bin.bz2.sig" \
        "${gs}/coreos_production_update.zip" \
        "${gs}/coreos_production_update.zip.sig" ./

    gpg2 --verify "coreos_production_image.vmlinuz.sig"
    gpg2 --verify "coreos_production_update.bin.bz2.sig"
    gpg2 --verify "coreos_production_update.zip.sig"

    popd >/dev/null
}

usage() {
    echo "Usage: $0 <ARTIFACT-DIR> [{-a|-b|-s} <VERSION>]..." >&2
    exit 1
}

CMD=download

BASEDIR="${1:-}"
if [[ -z "${BASEDIR}" ]]; then
    usage
fi
shift

if [[ -d "${BASEDIR}" && ! -O "${BASEDIR}" ]]; then
    echo "Fixing ownership of ${BASEDIR}..."
    sudo chown -R "${USER}" "${BASEDIR}"
fi

# Walk argument pairs.
while [[ $# > 0 ]]; do
    c="$1"
    v="${2?Must provide a version (e.g. 1234.0.0)}"
    shift 2

    case "${c}" in
    -a)
        $CMD "alpha" "${v}" "amd64-usr"
        $CMD "alpha" "${v}" "arm64-usr"
        ;;
    -b)
        $CMD "beta" "${v}" "amd64-usr"
        $CMD "beta" "${v}" "arm64-usr"
        ;;
    -s)
        $CMD "stable" "${v}" "amd64-usr"
        ;;
    *)
        usage
        ;;
    esac
done
