#!/bin/bash

source /tmp/chroot-functions.sh

# Build cross toolchains
# crossdev only does full bootstraps so if all of the packages are already
# installed (i.e. we are updating an existing stage4) then use emerge
for cross_chost in x86_64-cros-linux-gnu; do
    echo "Installing toolchain for ${cross_chost}"
    cross_pkgs=( cross-${cross_chost}/{binutils,gcc,gdb,glibc,linux-headers} )
    cross_bootstrap=0
    for pkg in "${cross_pkgs[@]}"; do
        if ! portageq match / "$pkg" | grep .; then
            cross_bootstrap=1
            break
        fi
    done

    if [[ "${cross_bootstrap}" -eq 1 ]]; then
        crossdev --ov-output "/usr/local/portage/crossdev" \
            --portage "${clst_myemergeopts}" \
            --env 'FEATURES=splitdebug' \
            --stable --ex-gdb --stage4 \
            --target "${cross_chost}" || exit 1
    else
        # Still run --init-target to ensure config is correct
        crossdev --ov-output "/usr/local/portage/crossdev" \
            --env 'FEATURES=splitdebug' \
            --stable --ex-gdb --init-target \
            --target "${cross_chost}" || exit 1
        run_merge -u "${cross_pkgs[@]}"
    fi
done

echo "Double checking everything is fresh and happy."
run_merge -uDN --with-bdeps=y world
