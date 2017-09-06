#!/usr/bin/env bash

set -eux

declare -A APPID
APPID[amd64-usr]=e96281a6-d1af-4bde-9a0a-97b76e56dc57
APPID[arm64-usr]=103867da-e3a2-4c92-b0b3-7fbd7f7d8b71

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

upload() {
    local channel="$1"
    local version="$2"
    local board="$3"

    local payload="${BASEDIR}/${board}/${version}/coreos_production_update.gz"
    if [[ ! -e "${payload}" ]]; then
        echo "No such file: ${payload}" >&2
        exit 1
    fi

    "$(dirname $0)/../core_roller_upload" \
        --user="${ROLLER_USERNAME}" \
        --api_key="${ROLLER_API_KEY}" \
        --app_id="${APPID[${board}]}" \
        --board="${board}" \
        --version="${version}" \
        --payload="${payload}"

    # Update version in a canary channel if one is defined.
    local -n canary_channel="ROLLER_CANARY_CHANNEL_${channel^^}"
    if [[ -n "${canary_channel}" ]]; then
        updateservicectl \
            --server="https://public.update.core-os.net" \
            --user="${ROLLER_USERNAME}" \
            --key="${ROLLER_API_KEY}" \
            channel update \
            --app-id="${APPID[${board}]}" \
            --channel="${canary_channel}" \
            --version="${version}"
    fi
}

usage() {
    echo "Usage: $0 {download|upload} <ARTIFACT-DIR> [{-a|-b|-s} <VERSION>]..." >&2
    exit 1
}

# Parse base arguments.
CMD="${1:-}"
BASEDIR="${2:-}"
shift 2 ||:

case "${CMD}" in
    download)
        ;;
    upload)
        if [[ -e "${HOME}/.config/roller.conf" ]]; then
            . "${HOME}/.config/roller.conf"
        fi
        if [[ -z "${ROLLER_USERNAME:-}" || -z "${ROLLER_API_KEY:-}" ]]; then
            echo 'Missing $ROLLER_USERNAME or $ROLLER_API_KEY.' >&2
            echo "Consider adding shell assignments to ~/.config/roller.conf." >&2
            exit 1
        fi
        ;;
    *)
        usage
        ;;
esac

if [[ -z "${BASEDIR}" ]]; then
    usage
fi

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
