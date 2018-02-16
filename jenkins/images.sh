#!/bin/bash -ex

# Clear out old images.
sudo rm -rf chroot/build src/build torcx

enter() {
        local verify_key=
        trap 'sudo rm -f chroot/etc/portage/gangue.*' RETURN
        [ -s verify.asc ] &&
        sudo ln -f verify.asc chroot/etc/portage/gangue.asc &&
        verify_key=--verify-key=/etc/portage/gangue.asc
        sudo ln -f "${GS_DEVEL_CREDS}" chroot/etc/portage/gangue.json
        bin/cork enter --experimental -- env \
            COREOS_DEV_BUILDS="${DOWNLOAD_ROOT}" \
            {FETCH,RESUME}COMMAND_GS="/usr/bin/gangue get \
--json-key=/etc/portage/gangue.json $verify_key \
"'"${URI}" "${DISTDIR}/${FILE}"' \
            "$@"
}

script() {
        enter "/mnt/host/source/src/scripts/$@"
}

source .repo/manifests/version.txt
export COREOS_BUILD_ID

# Set up GPG for signing uploads.
gpg --import "${GPG_SECRET_KEY_FILE}"

script setup_board \
    --board="${BOARD}" \
    --getbinpkgver="${COREOS_VERSION}" \
    --regen_configs_only

if [ "x${COREOS_OFFICIAL}" == x1 ]
then
        script set_official --board="${BOARD}" --official
else
        script set_official --board="${BOARD}" --noofficial
fi

# Retrieve this version's torcx manifest
mkdir -p torcx/pkgs
enter gsutil cp -r \
    "${DOWNLOAD_ROOT}/torcx/manifests/${BOARD}/${COREOS_VERSION}/torcx_manifest.json"{,.sig} \
    /mnt/host/source/torcx/
gpg --verify torcx/torcx_manifest.json.sig

# Download all cas references from the manifest and verify their checksums
# TODO: technically we can skip ones that don't have a 'path' since they're not
# included in the image.
while read name digest hash
do
        mkdir -p "torcx/pkgs/${BOARD}/${name}/${digest}"
        enter gsutil cp -r "${TORCX_PKG_DOWNLOAD_ROOT}/pkgs/${BOARD}/${name}/${digest}" \
            "/mnt/host/source/torcx/pkgs/${BOARD}/${name}/"
        downloaded_hash=$(sha512sum "torcx/pkgs/${BOARD}/${name}/${digest}/"*.torcx.squashfs | awk '{print $1}')
        if [[ "sha512-${downloaded_hash}" != "${hash}" ]]
        then
                echo "Torcx package had wrong hash: ${downloaded_hash} instead of ${hash}"
                exit 1
        fi
done < <(jq -r '.value.packages[] | . as $p | .name as $n | $p.versions[] | [.casDigest, .hash] | join(" ") | [$n, .] | join(" ")' "torcx/torcx_manifest.json")

script build_image \
    --board="${BOARD}" \
    --group="${GROUP}" \
    --getbinpkg \
    --getbinpkgver="${COREOS_VERSION}" \
    --sign="${SIGNING_USER}" \
    --sign_digests="${SIGNING_USER}" \
    --torcx_manifest=/mnt/host/source/torcx/torcx_manifest.json \
    --torcx_root=/mnt/host/source/torcx/ \
    --upload_root="${UPLOAD_ROOT}" \
    --upload prod container
