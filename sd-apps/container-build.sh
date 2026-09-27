#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(cd "$repo/.." && pwd)

test "$work" = /work

set -a
source "$repo/build/sources.lock"
set +a

export JOBS=${JOBS:-8}

mkdir -p "$work/refs" "$work/artifacts"

driver="$work/refs/esp32-linux-build"
base="$driver/build"

clone_locked() {
    local url=$1 revision=$2 target=$3

    if [[ ! -e "$target" ]]; then
        mkdir -p "$target"
        git -C "$target" init -q
        git -C "$target" remote add origin "$url"
    fi

    test "$(git -C "$target" remote get-url origin)" = "$url"

    if ! git -C "$target" rev-parse --verify HEAD >/dev/null 2>&1; then
        git -C "$target" fetch --depth 1 origin "$revision"
        git -C "$target" checkout --detach FETCH_HEAD
    fi

    test "$(git -C "$target" rev-parse HEAD)" = "$revision"
}

prepare_toolchain() {
    clone_locked \
        https://github.com/jcmvbkbc/esp32-linux-build \
        "$BUILD_DRIVER_REV" \
        "$driver"

    mkdir -p "$base"

    clone_locked \
        https://github.com/jcmvbkbc/xtensa-dynconfig \
        "$DYNCONFIG_REV" \
        "$base/xtensa-dynconfig"

    clone_locked \
        https://github.com/jcmvbkbc/config-esp32s3 \
        "$ESP32_CONFIG_REV" \
        "$base/esp32s3"

    make -C "$base/xtensa-dynconfig" \
        ORIG=1 CONF_DIR="$base" esp32s3.so

    clone_locked \
        https://github.com/jcmvbkbc/crosstool-NG \
        "$CTNG_REV" \
        "$base/crosstool-NG"

    cd "$base/crosstool-NG"

    ./bootstrap
    ./configure --enable-local
    make -j"$JOBS"
    ./ct-ng xtensa-esp32s3-linux-uclibcfdpic

    python3 "$repo/build/pin-toolchain.py" .config

    local toolchain_name
    local toolchain_path
    local toolchain_key
    local toolchain_cache

    toolchain_name=xtensa-esp32s3-linux-uclibcfdpic
    toolchain_path="$PWD/builds/$toolchain_name"

    toolchain_key=$(
        {
            printf '%s\n' \
                "$BUILD_DRIVER_REV" \
                "$DYNCONFIG_REV" \
                "$ESP32_CONFIG_REV" \
                "$CTNG_REV"
            grep -v '^CT_PARALLEL_JOBS=' .config
            cat "$repo/build/pin-toolchain.py"
        } | sha256sum | cut -d' ' -f1
    )

    echo
    echo "Toolchain key: $toolchain_key"

    if [ -d /cache/toolchain ]; then
        toolchain_cache="/cache/toolchain/$toolchain_key/toolchain.tar"

        if [ -f "$toolchain_cache" ]; then
            echo "Using cached Xtensa toolchain"
            echo "  $toolchain_cache"

            mkdir -p "$PWD/builds"
            tar -xf "$toolchain_cache" -C "$PWD/builds"
        else
            echo "Toolchain cache miss."
            echo "Building Xtensa toolchain..."

            CT_PREFIX="$PWD/builds" ./ct-ng build

            mkdir -p "$(dirname "$toolchain_cache")"

            local tmp
            tmp=$(mktemp "$(dirname "$toolchain_cache")/.toolchain.tar.tmp.XXXXXX")

            tar -cf "$tmp" -C "$PWD/builds" "$toolchain_name"

            if [ ! -e "$toolchain_cache" ]; then
                mv "$tmp" "$toolchain_cache"
                echo "Cached Xtensa toolchain:"
                echo "  $toolchain_cache"
            else
                rm -f "$tmp"
            fi
        fi
    else
        echo "Toolchain cache unavailable."
        echo "Building Xtensa toolchain..."

        CT_PREFIX="$PWD/builds" ./ct-ng build
    fi

    test -x "$toolchain_path/bin/$toolchain_name-gcc"

    export XTENSA_GNU_CONFIG="$base/xtensa-dynconfig/esp32s3.so"
    test -f "$XTENSA_GNU_CONFIG"

    echo
    echo "Xtensa toolchain ready:"
    "$toolchain_path/bin/$toolchain_name-gcc" --version | head -1
}

prepare_n16_userspace() {
    local n16_profile
    local br

    n16_profile=esp32s3_devkit_c1_16m
    br="$base/build-buildroot-$n16_profile"

    echo
    echo "Preparing N16 Buildroot userspace:"
    echo "  profile: $n16_profile"

    clone_locked \
        https://github.com/jcmvbkbc/buildroot \
        "$BUILDROOT_REV" \
        "$base/buildroot"

    install -m 755 \
        "$repo/new-files/toplevel/apply-local-changes.sh" \
        "$driver/apply-local-changes.sh"

    if [[ ! -L "$driver/local-changes" ]]; then
        ln -s "$repo" "$driver/local-changes"
    fi

    test "$(readlink "$driver/local-changes")" = "$repo"

    cd "$driver"
    ./apply-local-changes.sh buildroot

    make -C "$base/buildroot" \
        O="$br" \
        "${n16_profile}_defconfig"

    if [ -d /cache/ccache ]; then
        "$base/buildroot/utils/config" \
            --file "$br/.config" \
            --enable CCACHE
    fi

    "$base/buildroot/utils/config" \
        --file "$br/.config" \
        --set-str TOOLCHAIN_EXTERNAL_PATH \
        "$base/crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic"

    "$base/buildroot/utils/config" \
        --file "$br/.config" \
        --set-str TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX \
        '$(ARCH)-esp32s3-linux-uclibcfdpic'

    "$base/buildroot/utils/config" \
        --file "$br/.config" \
        --undefine PRIMARY_SITE \
        --set-str PRIMARY_SITE \
        'https://sources.buildroot.net'

    grep -qx \
        'BR2_PRIMARY_SITE="https://sources.buildroot.net"' \
        "$br/.config"

    "$base/buildroot/utils/config" \
        --file "$br/.config" \
        --set-str WGET \
        'wget -nd -t 3 --timeout=20'

    local build_args=()

    if [ -d /cache/buildroot-dl ]; then
        build_args+=(BR2_DL_DIR=/cache/buildroot-dl)
    fi

    if [ -d /cache/ccache ]; then
        build_args+=(BR2_CCACHE_DIR=/cache/ccache)
    fi

    echo
    echo "Building N16 userspace..."

    make -C "$base/buildroot" \
        O="$br" \
        BR2_JLEVEL="$JOBS" \
        "${build_args[@]}"

    test -s "$br/images/rootfs.cramfs"
    test -d "$br/target"

    echo
    echo "N16 userspace ready:"
    echo "  $br/target"

    echo
    echo "SD Apps candidates:"

    for file in \
        "$br/target/usr/bin/curl" \
        "$br/target/usr/sbin/dropbear"
    do
        if [ -e "$file" ]; then
            ls -lh "$file"
        fi
    done

    find "$br/target/usr/lib" \
        -maxdepth 1 \
        \( -name 'libcurl.so*' \
        -o -name 'libmbedtls.so*' \
        -o -name 'libmbedx509.so*' \
        -o -name 'libmbedcrypto.so*' \) \
        -print
}

package_sd_apps() {
    local br
    local target
    local stage
    local version
    local archive

    br="$base/build-buildroot-esp32s3_devkit_c1_16m"
    if [ -d /n16-target ]; then
        target=/n16-target
    else
        target="$br/target"
    fi
    stage=/work/sd-apps-package

    rm -rf "$stage"
    mkdir -p \
        "$stage/home/bin" \
        "$stage/home/sbin" \
        "$stage/home/lib"

    echo
    echo "Packaging SD Apps..."

    # curl
    cp -a "$target/usr/bin/curl" \
        "$stage/home/bin/"

    # Dropbear / SSH tools
    cp -a \
        "$target/usr/bin/ssh" \
        "$target/usr/bin/scp" \
        "$target/usr/bin/dbclient" \
        "$target/usr/bin/dropbearkey" \
        "$target/usr/bin/dropbearconvert" \
        "$stage/home/bin/"

    cp -a "$target/usr/sbin/dropbear" \
        "$stage/home/sbin/"

    # curl TLS libraries. Preserve Buildroot symlinks.
    cp -a "$target/usr/lib"/libcurl.so* \
        "$target/usr/lib"/libmbedtls.so* \
        "$target/usr/lib"/libmbedx509.so* \
        "$target/usr/lib"/libmbedcrypto.so* \
        "$stage/home/lib/"

    version="${SD_APPS_VERSION:?SD_APPS_VERSION is not set}"

    archive="/work/artifacts/sd-apps-${version}.tar.gz"

    rm -f "$archive"

    tar -C "$stage" \
        -czf "$archive" \
        home

    echo
    echo "SD Apps package:"
    ls -lh "$archive"

    echo
    echo "Contents:"
    tar -tzf "$archive"
}

if [ -d /n16-target ]; then
    echo
    echo "Using existing N16 Buildroot userspace:"
    echo "  /n16-target"
else
    prepare_toolchain
    prepare_n16_userspace
fi

package_sd_apps
