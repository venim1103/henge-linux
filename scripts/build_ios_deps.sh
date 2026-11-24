#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-compile or validate iOS arm64 static dependencies (libffi, glib, libslirp)
# on both Apple Silicon (/opt/homebrew) and Intel x86_64 (/usr/local) Macs.

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "[deps] Skipping iOS dependency cross-compile: Darwin/Xcode required."
    exit 0
fi

if [ -d "/opt/homebrew" ]; then
    BREW_PREFIX="/opt/homebrew"
elif [ -d "/usr/local/Homebrew" ] || [ -d "/usr/local/Cellar" ]; then
    BREW_PREFIX="/usr/local"
else
    echo "[deps] Homebrew not found in /opt/homebrew or /usr/local" >&2
    exit 1
fi

export PATH="$BREW_PREFIX/bin:$PATH"
IOS_MIN_VERSION="${IOS_MIN_VERSION:-18.0}"
export IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN_VERSION"
echo "[deps] Using Homebrew prefix: $BREW_PREFIX (IOS_MIN_VERSION=$IOS_MIN_VERSION)"

for tool in meson ninja pkg-config xcodegen; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[deps] Missing required host tool: $tool (install via: brew install $tool)" >&2
        exit 1
    fi
done

if [ -x ".upstream/WindowsiOS/scripts/build_ios_deps.sh" ]; then
    UPSTREAM_DEPS=".upstream/WindowsiOS/ios/deps"
    REQUIRED_LIBS=(libffi.a libglib-2.0.a libintl.a libpcre2-8.a libslirp.a)
    REQUIRED_HDRS=(
        "$UPSTREAM_DEPS/include/slirp/libslirp.h"
        "$UPSTREAM_DEPS/include/glib-2.0/glib.h"
        "$UPSTREAM_DEPS/lib/glib-2.0/include/glibconfig.h"
    )
    HAVE_ALL_CACHED=1
    for hdr in "${REQUIRED_HDRS[@]}"; do
        if [ ! -s "$hdr" ]; then
            HAVE_ALL_CACHED=0
        fi
    done
    for lib in "${REQUIRED_LIBS[@]}"; do
        if [ ! -s "$UPSTREAM_DEPS/lib/$lib" ]; then
            HAVE_ALL_CACHED=0
        fi
    done

    if [ "$HAVE_ALL_CACHED" -eq 1 ] && [ "${FORCE_REBUILD_DEPS:-0}" != "1" ]; then
        echo "[deps] Using cached upstream iOS static dependencies in $UPSTREAM_DEPS"
    else
        PYTHON3_BIN="$(command -v python3)"
        echo "[deps] Delegating to .upstream/WindowsiOS/scripts/build_ios_deps.sh (python3=$PYTHON3_BIN)"
        (
            cd .upstream/WindowsiOS
            PATCHED_SCRIPT="scripts/.build_ios_deps.patched.sh"
            trap 'rm -f "$PATCHED_SCRIPT"' EXIT
            python3 -c '
from pathlib import Path
import re
import sys
p = Path("scripts/build_ios_deps.sh")
txt = p.read_text(encoding="utf-8")
old_py = "/opt/homebrew/bin/python3"
old_path = "export PATH=\"/opt/homebrew/bin:"
assert old_py in txt, f"Expected {old_py} in upstream build_ios_deps.sh"
assert old_path in txt, f"Expected {old_path} in upstream build_ios_deps.sh"
txt = txt.replace(old_py, sys.argv[1])
txt = txt.replace(old_path, f"export PATH=\"{sys.argv[2]}:/opt/homebrew/bin:")
ios_min = sys.argv[4]
txt = re.sub(r"-m(?:iphoneos|ios)-version-min=[0-9]+\.[0-9]+", f"-miphoneos-version-min={ios_min}", txt)
txt = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET=[0-9]+\.[0-9]+", f"IPHONEOS_DEPLOYMENT_TARGET={ios_min}", txt)
Path(sys.argv[3]).write_text(txt, encoding="utf-8")
' "$PYTHON3_BIN" "$BREW_PREFIX/bin" "$PATCHED_SCRIPT" "$IOS_MIN_VERSION"
            chmod +x "$PATCHED_SCRIPT"
            IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN_VERSION" BREW_PREFIX="$BREW_PREFIX" "./$PATCHED_SCRIPT"

            # Ensure GLib headers (if built in sysroot) are staged alongside slirp headers
            if [ -d "work/ios_deps_build/sysroot/include/glib-2.0" ]; then
                rm -rf "ios/deps/include/glib-2.0"
                cp -R "work/ios_deps_build/sysroot/include/glib-2.0" "ios/deps/include/glib-2.0"
            fi
            if [ -d "work/ios_deps_build/sysroot/lib/glib-2.0/include" ]; then
                mkdir -p "ios/deps/lib/glib-2.0"
                rm -rf "ios/deps/lib/glib-2.0/include"
                cp -R "work/ios_deps_build/sysroot/lib/glib-2.0/include" "ios/deps/lib/glib-2.0/include"
            fi
        )
    fi

    # Cross-compile static libzstd.a (v1.5.7) for Zstd-compressed QCOW2 cluster support
    ZSTD_VER="1.5.7"
    ZSTD_URL="https://github.com/facebook/zstd/releases/download/v${ZSTD_VER}/zstd-${ZSTD_VER}.tar.gz"
    if [ ! -s "$UPSTREAM_DEPS/lib/libzstd.a" ] || [ ! -s "$UPSTREAM_DEPS/include/zstd.h" ] || [ ! -s "$UPSTREAM_DEPS/include/zstd_errors.h" ] || [ "${FORCE_REBUILD_DEPS:-0}" = "1" ]; then
        echo "[deps] Cross-compiling libzstd ${ZSTD_VER} for arm64-apple-ios${IOS_MIN_VERSION}"
        ZSTD_WORK=".upstream/WindowsiOS/work/zstd_ios_build"
        mkdir -p "$ZSTD_WORK" "$UPSTREAM_DEPS/lib" "$UPSTREAM_DEPS/include"
        ZSTD_TAR="$ZSTD_WORK/zstd-${ZSTD_VER}.tar.gz"
        if [ ! -s "$ZSTD_TAR" ]; then
            curl -fL --retry 3 -o "${ZSTD_TAR}.part" "$ZSTD_URL"
            mv "${ZSTD_TAR}.part" "$ZSTD_TAR"
        fi
        rm -rf "$ZSTD_WORK/zstd-${ZSTD_VER}"
        tar -xzf "$ZSTD_TAR" -C "$ZSTD_WORK"
        SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
        NCPU="$(sysctl -n hw.ncpu)"
        make -C "$ZSTD_WORK/zstd-${ZSTD_VER}/lib" -j"$NCPU" \
            CC="$(xcrun --sdk iphoneos --find clang)" \
            AR="$(xcrun --sdk iphoneos --find ar)" \
            CFLAGS="-O2 -arch arm64 -target arm64-apple-ios${IOS_MIN_VERSION} -miphoneos-version-min=${IOS_MIN_VERSION} -isysroot ${SDKROOT} -DZSTD_DISABLE_ASM" \
            ZSTD_LIB_COMPRESSION=0 \
            ZSTD_LIB_DICTBUILDER=0 \
            ZSTD_LIB_DEPRECATED=0 \
            ZSTD_LEGACY_SUPPORT=0 \
            libzstd.a
        cp "$ZSTD_WORK/zstd-${ZSTD_VER}/lib/libzstd.a" "$UPSTREAM_DEPS/lib/libzstd.a"
        cp "$ZSTD_WORK/zstd-${ZSTD_VER}/lib/zstd.h" "$UPSTREAM_DEPS/include/zstd.h"
        cp "$ZSTD_WORK/zstd-${ZSTD_VER}/lib/zstd_errors.h" "$UPSTREAM_DEPS/include/zstd_errors.h"
    else
        echo "[deps] Using cached libzstd.a in $UPSTREAM_DEPS/lib"
    fi

    REQUIRED_LIBS+=(libzstd.a)
    REQUIRED_HDRS+=("$UPSTREAM_DEPS/include/zstd.h" "$UPSTREAM_DEPS/include/zstd_errors.h")

    for lib in "${REQUIRED_LIBS[@]}"; do
        if [ ! -s "$UPSTREAM_DEPS/lib/$lib" ]; then
            echo "[deps] Missing expected static archive after build: $UPSTREAM_DEPS/lib/$lib" >&2
            exit 1
        fi
    done
    for hdr in "${REQUIRED_HDRS[@]}"; do
        if [ ! -s "$hdr" ]; then
            echo "[deps] Missing expected header after build: $hdr" >&2
            exit 1
        fi
    done
    ls -lh "$UPSTREAM_DEPS/lib"

    if [ "${BUILD_GPU_DEPS:-0}" = "1" ]; then
        bash "$(dirname "$0")/build_ios_gpu_deps.sh"
    fi
else
    echo "[deps] Upstream not yet synced; run ./scripts/sync_upstream.sh first."
    exit 1
fi
