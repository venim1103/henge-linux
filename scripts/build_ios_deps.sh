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
    echo "[deps] Delegating to .upstream/WindowsiOS/scripts/build_ios_deps.sh"
    (
        cd .upstream/WindowsiOS
        BREW_PREFIX="$BREW_PREFIX" ./scripts/build_ios_deps.sh
    )
else
    echo "[deps] Upstream not yet synced; run ./scripts/sync_upstream.sh first."
fi
