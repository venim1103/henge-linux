#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# HengeLinux Multi-Distro ARM64 Guest Image Profile Builder
#
# Declarative wrapper around prebuilt ARM64 Linux image profiles:
#   --profile arch    : Pre-configured Arch Linux ARM64 (delegates to build_prebuilt_archlinux_arm64.sh)
#   --profile debian  : Official Debian 13 (Trixie) generic ARM64 cloud image -> debian.hvsparse
#   --profile alpine  : Official Alpine Linux ARM64 UEFI nocloud image -> alpine.hvsparse
#   --profile void    : Void Linux ARM64 UEFI rootfs -> void.hvsparse
#
# Usage:
#   bash scripts/build_guest_image.sh --profile arch [--dry-run]
#   bash scripts/build_guest_image.sh --profile debian --out-dir build/prebuilt/debian

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${PROFILE:-arch}"
OUT_DIR="${OUT_DIR:-}"
DRY_RUN=0
VERIFY_BOOT="${VERIFY_BOOT:-0}"
HVSPARSE_BIN="${HVSPARSE_BIN:-$REPO_ROOT/build/hvsparse}"
MAX_HVSPARSE_BYTES="${MAX_HVSPARSE_BYTES:-1900000000}"

# Pinned upstream cloud/rootfs URLs (overridable via environment)
DEBIAN_QCOW2_URL="${DEBIAN_QCOW2_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.qcow2}"
ALPINE_QCOW2_URL="${ALPINE_QCOW2_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/cloud/nocloud_alpine-3.21.3-aarch64-uefi-cloudinit-r0.qcow2}"
VOID_ROOTFS_URL="${VOID_ROOTFS_URL:-https://repo-default.voidlinux.org/live/current/void-aarch64-ROOTFS-20250202.tar.xz}"

usage() {
    cat <<EOF
Usage: $0 --profile <arch|debian|alpine|void> [--out-dir DIR] [--dry-run]

Environment overrides:
  OUT_DIR, VERIFY_BOOT=1, HVSPARSE_BIN, DEBIAN_QCOW2_URL, ALPINE_QCOW2_URL, VOID_ROOTFS_URL
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile)
            shift
            PROFILE="${1:-}"
            ;;
        --out-dir)
            shift
            OUT_DIR="${1:-}"
            ;;
        --dry-run|--check)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[guest-image] ERROR: Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

case "$PROFILE" in
    arch)
        DEFAULT_OUT="$REPO_ROOT/build/prebuilt"
        IMAGE_NAME="archlinux.hvsparse"
        SOURCE_DESC="ArchLinuxARM-aarch64-latest.tar.gz (via build_prebuilt_archlinux_arm64.sh)"
        ;;
    debian)
        DEFAULT_OUT="$REPO_ROOT/build/prebuilt/debian"
        IMAGE_NAME="debian.hvsparse"
        SOURCE_DESC="$DEBIAN_QCOW2_URL"
        ;;
    alpine)
        DEFAULT_OUT="$REPO_ROOT/build/prebuilt/alpine"
        IMAGE_NAME="alpine.hvsparse"
        SOURCE_DESC="$ALPINE_QCOW2_URL"
        ;;
    void)
        DEFAULT_OUT="$REPO_ROOT/build/prebuilt/void"
        IMAGE_NAME="void.hvsparse"
        SOURCE_DESC="$VOID_ROOTFS_URL"
        ;;
    *)
        echo "[guest-image] ERROR: Unsupported profile '$PROFILE' (expected: arch, debian, alpine, void)" >&2
        exit 2
        ;;
esac

OUT_DIR="${OUT_DIR:-$DEFAULT_OUT}"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[guest-image] Dry-run profile summary:"
    echo "  PROFILE      = $PROFILE"
    echo "  OUT_DIR      = $OUT_DIR"
    echo "  IMAGE_NAME   = $IMAGE_NAME"
    echo "  SOURCE       = $SOURCE_DESC"
    echo "  VERIFY_BOOT  = $VERIFY_BOOT"
    if [ "$PROFILE" = "arch" ]; then
        OUT_DIR="$OUT_DIR" bash "$REPO_ROOT/scripts/build_prebuilt_archlinux_arm64.sh" --dry-run
    fi
    exit 0
fi

if [ "$PROFILE" = "arch" ]; then
    exec env OUT_DIR="$OUT_DIR" VERIFY_BOOT="$VERIFY_BOOT" HVSPARSE_BIN="$HVSPARSE_BIN" \
        bash "$REPO_ROOT/scripts/build_prebuilt_archlinux_arm64.sh"
fi

mkdir -p "$OUT_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/henge-profile-${PROFILE}.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

if [ ! -x "$HVSPARSE_BIN" ]; then
    make -C "$REPO_ROOT" hvsparse
fi

find_uefi_code() {
    for p in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/edk2/aarch64/QEMU_EFI.fd; do
        if [ -f "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

find_uefi_vars() {
    for p in /usr/share/AAVMF/AAVMF_VARS.fd /usr/share/edk2/aarch64/QEMU_VARS.fd; do
        if [ -f "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

prepare_firmware() {
    local code_src vars_src
    code_src="$(find_uefi_code)" || { echo "[guest-image] ERROR: EDK2 AArch64 firmware not found." >&2; exit 1; }
    cp "$code_src" "$OUT_DIR/code.fd"
    truncate -s 67108864 "$OUT_DIR/code.fd"
    if vars_src="$(find_uefi_vars)"; then
        cp "$vars_src" "$OUT_DIR/vars.fd"
        truncate -s 67108864 "$OUT_DIR/vars.fd"
    else
        truncate -s 67108864 "$OUT_DIR/vars.fd"
    fi
}

pack_and_hash() {
    local raw_img="$1"
    local out_sparse="$OUT_DIR/$IMAGE_NAME"
    local tmp_sparse="${out_sparse}.tmp"
    echo "[guest-image] Packing $raw_img -> $out_sparse"
    "$HVSPARSE_BIN" pack "$raw_img" "$tmp_sparse"
    mv -f "$tmp_sparse" "$out_sparse"
    local bytes
    bytes="$(wc -c < "$out_sparse" | tr -d '[:space:]')"
    if [ "$bytes" -ge "$MAX_HVSPARSE_BYTES" ]; then
        echo "[guest-image] ERROR: $IMAGE_NAME is ${bytes} bytes (exceeds ${MAX_HVSPARSE_BYTES})." >&2
        exit 1
    fi
    (
        cd "$OUT_DIR"
        sha256sum code.fd vars.fd "$IMAGE_NAME" > SHA256SUMS.txt
    )
    ls -lh "$OUT_DIR/code.fd" "$OUT_DIR/vars.fd" "$out_sparse" "$OUT_DIR/SHA256SUMS.txt"
}

prepare_firmware

case "$PROFILE" in
    debian|alpine)
        command -v qemu-img >/dev/null 2>&1 || { echo "[guest-image] ERROR: qemu-img (qemu-utils) is required." >&2; exit 1; }
        SRC_URL="$DEBIAN_QCOW2_URL"
        [ "$PROFILE" = "alpine" ] && SRC_URL="$ALPINE_QCOW2_URL"
        QCOW2_FILE="$WORK_DIR/${PROFILE}.qcow2"
        RAW_FILE="$WORK_DIR/${PROFILE}.raw"
        echo "[guest-image] Downloading $SRC_URL"
        curl -fL --retry 3 --retry-delay 2 "$SRC_URL" -o "$QCOW2_FILE"
        echo "[guest-image] Converting QCOW2 -> sparse raw"
        qemu-img convert -f qcow2 -O raw "$QCOW2_FILE" "$RAW_FILE"
        # Ensure at least 8 GiB virtual size for cloud-init / growpart
        cur_sz="$(stat -c%s "$RAW_FILE")"
        min_sz=$((8 * 1024 * 1024 * 1024))
        if [ "$cur_sz" -lt "$min_sz" ]; then
            truncate -s "$min_sz" "$RAW_FILE"
        fi
        pack_and_hash "$RAW_FILE"
        ;;
    void)
        echo "[guest-image] Void Linux rootfs profile requires root loop-mount provisioning."
        echo "[guest-image] Downloading $VOID_ROOTFS_URL -> $WORK_DIR/void-rootfs.tar.xz"
        curl -fL --retry 3 --retry-delay 2 "$VOID_ROOTFS_URL" -o "$WORK_DIR/void-rootfs.tar.xz"
        echo "[guest-image] ERROR: Automated unattended Void kernel+ESP packaging is not yet enabled; use Void Live ARM64 ISO via VMStore Quick Create." >&2
        exit 1
        ;;
esac

echo "[guest-image] Profile '$PROFILE' ready in $OUT_DIR"
