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
