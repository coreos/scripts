#!/bin/bash

source /tmp/chroot-functions.sh

# Build cross toolchains
for cross_chost in x86_64-cros-linux-gnu; do
    echo "Installing toolchain for ${cross_chost}"
    cross_pkgs=( cross-${cross_chost}/{binutils,gcc,gdb,glibc,linux-headers} )
    crossdev --ov-output "/usr/local/portage/crossdev" \
        --env 'FEATURES=splitdebug' \
        --stable --ex-gdb --init-target \
        --target "${cross_chost}" || exit 1

    # If PKGCACHE is enabled check to see if binary packages are available
    # or (due to --noreplace) the packages are already installed. If so then
    # we don't need to perform a full bootstrap and just call emerge instead.
    if [[ -n "${clst_PKGCACHE}" ]] && \
        emerge ${clst_myemergeopts} --usepkgonly --binpkg-respect-use=y \
            --noreplace "${cross_pkgs[@]}" &>/dev/null
    then
        run_merge -u "${cross_pkgs[@]}"
    else
        crossdev --ov-output "/usr/local/portage/crossdev" \
            --portage "${clst_myemergeopts}" \
            --env 'FEATURES=splitdebug' \
            --stable --ex-gdb --stage4 \
            --target "${cross_chost}" || exit 1
    fi
done

echo "Double checking everything is fresh and happy."
run_merge -uDN --with-bdeps=y world
