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

    # If PKGCACHE is enabled check to see if binary packages are available.
    # If so then don't perform a full bootstrap and just call emerge instead.
    if [[ -n "${clst_PKGCACHE}" ]] && \
        emerge ${clst_myemergeopts} --usepkgonly --binpkg-respect-use=y \
            --pretend "${cross_pkgs[@]}" &>/dev/null
    then
        run_merge -u "${cross_pkgs[@]}"
    else
        crossdev --ov-output "/usr/local/portage/crossdev" \
            --portage "${clst_myemergeopts}" \
            --env 'FEATURES=splitdebug' \
            --stable --ex-gdb --stage4 \
            --target "${cross_chost}" || exit 1
    fi

    # There is no point to including the built packages in the final tarball
    # because the packages will have to be downloaded anyway due to how the
    # cross toolchains are managed in board sysroots.
    crossdev --force -C "${cross_chost}"
done

echo "Double checking everything is fresh and happy."
run_merge -uDN --with-bdeps=y world
