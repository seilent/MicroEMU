set shell := ["bash", "-euo", "pipefail", "-c"]

device := env("MICROEMU_DEVICE", "armada@pm2")
platform := "linux/arm64"
builder := "localhost/microemu-builder"

default:
    @just --list

base:
    build/device-state {{device}} > build/base.env
    cat build/base.env

builder:
    . build/base.env && podman build --platform {{platform}} --build-arg BASE_IMAGE="$BASE_IMAGE" -t {{builder}} -f build/Containerfile .

dist: builder
    podman run --rm --platform {{platform}} -v "$PWD":/work:Z -e MICROEMU_VERSION="$(git describe --always --dirty 2>/dev/null || echo unknown)" {{builder}} build/build.sh

build: builder
    podman run --rm --platform {{platform}} -v "$PWD":/work:Z -e MICROEMU_VERSION="$(git describe --always --dirty 2>/dev/null || echo unknown)" -e MICROEMU_IMAGE=1 {{builder}} build/build.sh

dev:
    build/dev-loop {{device}}

off:
    rsync -a build/device-off {{device}}:/var/tmp/microemu-off
    ssh -t {{device}} sudo bash /var/tmp/microemu-off

test:
    bash tests/build-test.sh
    bash tests/device-apply-test.sh
    bash tests/device-off-test.sh
    bash tests/esde-test.sh
    bash tests/session-test.sh
    bash tests/systems-test.sh
    bash tests/client-test.sh
    bash tests/leave-test.sh
    bash tests/stop-test.sh
    bash tests/pad-test.sh
    bash tests/hotkeyd-test.sh
    bash tests/retroarch-test.sh
    bash tests/game-free-test.sh
    bash tests/retroarch-build-test.sh
    bash tests/shaders-test.sh
    bash tests/theme-test.sh
    bash tests/play-unit-test.sh
    bash tests/apk-test.sh
    bash tests/sideload-test.sh
    bash tests/android-hook-test.sh
    bash tests/reset-test.sh
    bash tests/pad-fuzz-test.sh
    bash tests/stub-test.sh
    bash tests/gapps-install-test.sh
    bash tests/play-update-test.sh
    bash tests/sync-test.sh
    bash tests/guard-test.sh
    bash tests/paths-test.sh

test-paths:
    MICROEMU_OTHER_DIST="${MICRODAP_DIST:-../MicroDAP/dist}" bash tests/paths-test.sh
