#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fetch upstream ammaarreshi/WindowsiOS core/devices/host engine components
# into .upstream/WindowsiOS for local compilation without duplicating upstream trees.

set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/ammaarreshi/WindowsiOS.git}"
UPSTREAM_REF="${UPSTREAM_REF:-0071d6975287fd720b9046dfd3bd80b6f2aa765e}"
DEST_DIR=".upstream/WindowsiOS"

mkdir -p .upstream

if [ ! -d "$DEST_DIR/.git" ]; then
    echo "[sync] Initializing $DEST_DIR ($UPSTREAM_URL @ $UPSTREAM_REF)"
    git init "$DEST_DIR" >/dev/null
    git -C "$DEST_DIR" remote add origin "$UPSTREAM_URL"
else
    git -C "$DEST_DIR" remote set-url origin "$UPSTREAM_URL"
fi

echo "[sync] Fetching $UPSTREAM_URL ($UPSTREAM_REF)"
git -C "$DEST_DIR" fetch --depth 1 origin "$UPSTREAM_REF"
git -C "$DEST_DIR" checkout -f -q FETCH_HEAD

echo "[sync] Applying henge-linux iOS/Linux patches"
python3 ./scripts/apply_upstream_patches.py "$DEST_DIR"

echo "[sync] Upstream engine ready at $DEST_DIR ($(git -C "$DEST_DIR" rev-parse HEAD))"
