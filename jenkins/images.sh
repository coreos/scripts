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
            PORTAGE_SSH_OPTS= \
            {FETCH,RESUME}COMMAND_GS="/usr/bin/gangue get \
--json-key=/etc/portage/gangue.json $verify_key \
"'"${URI}" "${DISTDIR}/${FILE}"' \
            "$@"
}

script() {
        enter "/mnt/host/source/src/scripts/$@"
}

sudo cp bin/gangue chroot/usr/bin/gangue  # XXX: until SDK mantle has it

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

# Try to find the version's torcx store, but don't require it.
torcx_store=
enter gsutil cp -r \
    "${DOWNLOAD_ROOT}/boards/${BOARD}/${COREOS_VERSION}/torcx" \
    /mnt/host/source/ &&
torcx_store=/mnt/host/source/torcx &&
for image in torcx/*.torcx.tgz
do
        gpg --verify "${image}.sig"
done

# Work around the lack of symlink support in GCS.
shopt -s nullglob
for default in torcx/*:com.coreos.cl.torcx.tgz
do
        for image in torcx/*.torcx.tgz
        do
                [ "x${default}" != "x${image}" ] &&
                cmp --silent -- "${default}" "${image}" &&
                ln -fns "${image##*/}" "${default}"
        done
done

script build_image \
    --board="${BOARD}" \
    --group="${GROUP}" \
    --getbinpkg \
    --getbinpkgver="${COREOS_VERSION}" \
    --sign="${SIGNING_USER}" \
    --sign_digests="${SIGNING_USER}" \
    ${torcx_store:+--torcx_store="${torcx_store}"} \
    --upload_root="${UPLOAD_ROOT}" \
    --upload prod container
