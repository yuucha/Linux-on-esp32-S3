#!/usr/bin/env bash
set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SD_APPS="$REPO/sd-apps"

find_n16_build() {
    local target

    for target in \
        "$REPO"/build-output/reproduce.*/refs/esp32-linux-build/build/build-buildroot-esp32s3_devkit_c1_16m/target \
        "$REPO"/build-output/sd-apps.*/refs/esp32-linux-build/build/build-buildroot-esp32s3_devkit_c1_16m/target
    do
        [ -d "$target" ] || continue
        printf '%s\n' "$target"
        return 0
    done

    return 1
}

CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/linux-on-esp32-s3"
SD_APPS_VERSION=$(git -C "$REPO" describe \
    --tags \
    --match '[0-9]*' \
    --abbrev=0)

echo "SD Apps build"
echo

if N16_TARGET=$(find_n16_build); then
    echo "N16 Buildroot userspace found:"
    echo "  $N16_TARGET"
    echo
    echo "Source: existing N16 build"
else
    echo "No reusable N16 Buildroot userspace found."
    echo
    echo "Checking build cache:"

    for name in toolchain ccache buildroot-dl; do
        path="$CACHE_ROOT/$name"

        if [ -d "$path" ]; then
            size=$(du -sh "$path" | awk '{print $1}')
            echo "  $name: available ($size)"
        else
            echo "  $name: not found"
        fi
    done

    echo
    echo "Source: N16 userspace build required"
fi

echo
echo "Preparing SD Apps build environment..."

mkdir -p "$REPO/build-output" "$SD_APPS/output"

WORK=$(mktemp -d "$REPO/build-output/sd-apps.XXXXXX")
mkdir -p "$WORK/Linux-on-esp32-S3" "$WORK/artifacts"

git -C "$REPO" archive HEAD | tar -x -C "$WORK/Linux-on-esp32-S3"

# sd-apps/ is not committed yet, so copy the current SD Apps scripts explicitly.
rm -rf "$WORK/Linux-on-esp32-S3/sd-apps"
mkdir -p "$WORK/Linux-on-esp32-S3/sd-apps"
cp "$SD_APPS/build.sh" "$WORK/Linux-on-esp32-S3/sd-apps/build.sh"
cp "$SD_APPS/container-build.sh" "$WORK/Linux-on-esp32-S3/sd-apps/container-build.sh"
cp "$SD_APPS/.gitignore" "$WORK/Linux-on-esp32-S3/sd-apps/.gitignore"

IMAGE="linux-esp32s3-sd-apps:local"

docker build \
    --network host \
    --build-arg BUILDER_UID="$(id -u)" \
    --build-arg BUILDER_GID="$(id -g)" \
    -f "$REPO/build/Dockerfile" \
    -t "$IMAGE" \
    "$REPO"

n16_mount=()

if [ -n "${N16_TARGET:-}" ]; then
    n16_mount+=(
        --mount "type=bind,source=$N16_TARGET,target=/n16-target,readonly"
    )
fi

cache_mounts=()

for name in buildroot-dl ccache toolchain; do
    path="$CACHE_ROOT/$name"

    if [ -d "$path" ]; then
        cache_mounts+=(
            --mount "type=bind,source=$path,target=/cache/$name"
        )
    fi
done

docker run \
    --network host \
    --rm \
    --mount "type=bind,source=$WORK,target=/work" \
    "${n16_mount[@]}" \
    "${cache_mounts[@]}" \
    --env JOBS="${JOBS:-8}" \
    --env SD_APPS_VERSION="$SD_APPS_VERSION" \
    --entrypoint bash \
    "$IMAGE" \
    /work/Linux-on-esp32-S3/sd-apps/container-build.sh

ARCHIVE="$WORK/artifacts/sd-apps-${SD_APPS_VERSION}.tar.gz"

test -s "$ARCHIVE"

cp "$ARCHIVE" "$SD_APPS/output/"

echo
echo "SD Apps output:"
ls -lh "$SD_APPS/output/sd-apps-${SD_APPS_VERSION}.tar.gz"

echo
echo "SD Apps build complete."
echo "Work directory: $WORK"
