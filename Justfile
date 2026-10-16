set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

install destdir="dist":
    rm -rf {{destdir}}
    MICROEMU_VERSION="$(git describe --always --dirty 2>/dev/null || echo unknown)" build/install.sh {{destdir}}

test:
    bash tests/install-test.sh
    bash tests/session-test.sh
    bash tests/systems-test.sh
    bash tests/client-test.sh
    bash tests/reconcile-test.sh
    bash tests/layout-test.sh
    bash tests/leak-test.sh
    bash tests/lc-test.sh
    bash tests/stop-test.sh
    bash tests/pad-test.sh
    bash tests/osd-test.sh
    bash tests/osd-build-test.sh
    bash tests/retroarch-test.sh
    bash tests/retroarch-run-test.sh
    bash tests/game-free-test.sh
    bash tests/shaders-test.sh
    bash tests/theme-test.sh

test-android:
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
