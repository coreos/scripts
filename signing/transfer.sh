#!/usr/bin/env bash

set -eux

APPID=e96281a6-d1af-4bde-9a0a-97b76e56dc57
BOARD=amd64-usr

declare -A RELEASE_CHANNEL
RELEASE_CHANNEL[alpha]=Alpha
RELEASE_CHANNEL[beta]=Beta
RELEASE_CHANNEL[stable]=Stable

download() {
    local channel="$1"
    local version="$2"

    local gs="gs://builds.release.core-os.net/${channel}/boards/${BOARD}/${version}"
    local dir="${BASEDIR}/${BOARD}/${version}"
    mkdir -p "${dir}"
    pushd "${dir}" >/dev/null

    gsutil -m cp \
        "${gs}/coreos_production_image.vmlinuz" \
        "${gs}/coreos_production_image.vmlinuz.sig" \
        "${gs}/coreos_production_update.bin.bz2" \
        "${gs}/coreos_production_update.bin.bz2.sig" \
        "${gs}/coreos_production_update.zip" \
        "${gs}/coreos_production_update.zip.sig" ./

    # torcx manifest: try embargoed release bucket first
    local torcx_base="gs://builds.release.core-os.net/embargoed/devfiles/torcx/manifests/${BOARD}/${version}"
    if ! gsutil -q stat "${torcx_base}/torcx_manifest.json"; then
        # Non-embargoed release
        local torcx_base="gs://builds.developer.core-os.net/torcx/manifests/${BOARD}/${version}"
    fi
    gsutil -m cp \
        "${torcx_base}/torcx_manifest.json" \
        "${torcx_base}/torcx_manifest.json.sig" \
        ./

    gpg2 --verify "coreos_production_image.vmlinuz.sig"
    gpg2 --verify "coreos_production_update.bin.bz2.sig"
    gpg2 --verify "coreos_production_update.zip.sig"
    gpg2 --verify "torcx_manifest.json.sig"

    popd >/dev/null
}

upload() {
    local channel="$1"
    local version="$2"

    local dir="${BASEDIR}/${BOARD}/${version}"
    local payload="${dir}/coreos_production_update.gz"
    local torcx_manifest="${dir}/torcx_manifest.json"
    local torcx_manifest_sig="${dir}/torcx_manifest.json.asc"
    local path
    for path in "${payload}" "${torcx_manifest}" "${torcx_manifest_sig}"; do
        if [[ ! -e "${path}" ]]; then
            echo "No such file: ${path}" >&2
            exit 1
        fi
    done

    "$(dirname $0)/../core_roller_upload" \
        --user="${ROLLER_USERNAME}" \
        --api_key="${ROLLER_API_KEY}" \
        --app_id="${APPID}" \
        --board="${BOARD}" \
        --version="${version}" \
        --payload="${payload}"

    # Upload torcx manifests
    gsutil cp \
        "${torcx_manifest}" \
        "${torcx_manifest_sig}" \
        "gs://coreos-tectonic-torcx/manifests/${BOARD}/${version}/"

    # Update version in a canary channel if one is defined.
    local -n canary_channel="ROLLER_CANARY_CHANNEL_${channel^^}"
    if [[ -n "${canary_channel}" ]]; then
        updateservicectl \
            --server="https://public.update.core-os.net" \
            --user="${ROLLER_USERNAME}" \
            --key="${ROLLER_API_KEY}" \
            channel update \
            --app-id="${APPID}" \
            --channel="${canary_channel}" \
            --version="${version}"
    fi
}

ready() {
    local channel="$1"
    local version="$2"

    # setting the percent will deactivate (not delete) any existing rollouts for
    # this specific group.
    echo "Rollout set to 0%"
    updateservicectl \
        --server="https://public.update.core-os.net" \
        --user="${ROLLER_USERNAME}" \
        --key="${ROLLER_API_KEY}" \
        group percent \
        --app-id="${APPID}" \
        --group-id="${channel}" \
        --update-percent=0

    # FIXME(bgilbert): We set --publish=true because there's no way to
    # say --publish=unchanged
    updateservicectl \
        --server="https://public.update.core-os.net" \
        --user="${ROLLER_USERNAME}" \
        --key="${ROLLER_API_KEY}" \
        channel update \
        --app-id="${APPID}" \
        --channel="${RELEASE_CHANNEL[${channel}]}" \
        --publish=true \
        --version="${version}"
}

roll() {
    local channel="$1"
    local hours="$2"

    local seconds=$((${hours} * 3600))

    # creating a new rollout deletes any existing rollout for this group and
    # automatically activates the new one.
    echo "Creating linear rollout that will get to 100% in ${hours}h"
    updateservicectl \
        --server="https://public.update.core-os.net" \
        --user="${ROLLER_USERNAME}" \
        --key="${ROLLER_API_KEY}" \
        rollout create linear \
        --app-id="${APPID}" \
        --group-id="${channel}" \
        --duration="${seconds}" \
        --frame-size="60"
}

usage() {
    echo "Usage: $0 {download|upload} <ARTIFACT-DIR> [{-a|-b|-s} <VERSION>]..." >&2
    echo "Usage: $0 ready [{-a|-b|-s} <VERSION>]..." >&2
    echo "Usage: $0 roll [{-a|-b|-s} <HOURS-TO-100-PERCENT>]..." >&2
    exit 1
}

# Parse subcommand.
CMD="${1:-}"
shift ||:
case "${CMD}" in
    download)
        ;;
    upload|ready|roll)
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

# Parse basedir if necessary.
case "${CMD}" in
    download|upload)
        BASEDIR="${1:-}"
        shift ||:
        if [[ -z "${BASEDIR}" ]]; then
            usage
        fi

        if [[ -d "${BASEDIR}" && ! -O "${BASEDIR}" ]]; then
            echo "Fixing ownership of ${BASEDIR}..."
            sudo chown -R "${USER}" "${BASEDIR}"
        fi
        ;;
esac

# Walk argument pairs.
while [[ $# > 0 ]]; do
    c="$1"
    v="${2?Must provide an argument for each channel (see usage)}"
    shift 2

    case "${c}" in
    -a)
        $CMD "alpha" "${v}"
        ;;
    -b)
        $CMD "beta" "${v}"
        ;;
    -s)
        $CMD "stable" "${v}"
        ;;
    *)
        usage
        ;;
    esac
done
