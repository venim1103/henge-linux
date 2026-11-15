#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fetch upstream ammaarreshi/WindowsiOS core/devices/host engine components
# into .upstream/WindowsiOS for local compilation without duplicating upstream trees.

set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/ammaarreshi/WindowsiOS.git}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"
DEST_DIR=".upstream/WindowsiOS"

mkdir -p .upstream

if [ ! -d "$DEST_DIR/.git" ]; then
    echo "[sync] Cloning $UPSTREAM_URL ($UPSTREAM_REF) -> $DEST_DIR"
    git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_URL" "$DEST_DIR"
else
    echo "[sync] Updating $DEST_DIR ($UPSTREAM_REF)"
    git -C "$DEST_DIR" fetch --depth 1 origin "$UPSTREAM_REF"
    git -C "$DEST_DIR" checkout -q FETCH_HEAD
fi

echo "[sync] Upstream engine ready at $DEST_DIR ($(git -C "$DEST_DIR" rev-parse --short HEAD))"
