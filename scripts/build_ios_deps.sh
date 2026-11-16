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
echo "[deps] Using Homebrew prefix: $BREW_PREFIX"

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
        echo "[deps] Using cached iOS static dependencies in $UPSTREAM_DEPS"
        ls -lh "$UPSTREAM_DEPS/lib"
        exit 0
    fi

    PYTHON3_BIN="$(command -v python3)"
    echo "[deps] Delegating to .upstream/WindowsiOS/scripts/build_ios_deps.sh (python3=$PYTHON3_BIN)"
    (
        cd .upstream/WindowsiOS
        PATCHED_SCRIPT="scripts/.build_ios_deps.patched.sh"
        trap 'rm -f "$PATCHED_SCRIPT"' EXIT
        python3 -c '
from pathlib import Path
import sys
p = Path("scripts/build_ios_deps.sh")
txt = p.read_text(encoding="utf-8")
old_py = "/opt/homebrew/bin/python3"
old_path = "export PATH=\"/opt/homebrew/bin:"
assert old_py in txt, f"Expected {old_py} in upstream build_ios_deps.sh"
assert old_path in txt, f"Expected {old_path} in upstream build_ios_deps.sh"
txt = txt.replace(old_py, sys.argv[1])
txt = txt.replace(old_path, f"export PATH=\"{sys.argv[2]}:/opt/homebrew/bin:")
Path(sys.argv[3]).write_text(txt, encoding="utf-8")
' "$PYTHON3_BIN" "$BREW_PREFIX/bin" "$PATCHED_SCRIPT"
        chmod +x "$PATCHED_SCRIPT"
        BREW_PREFIX="$BREW_PREFIX" "./$PATCHED_SCRIPT"

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
else
    echo "[deps] Upstream not yet synced; run ./scripts/sync_upstream.sh first."
    exit 1
fi
