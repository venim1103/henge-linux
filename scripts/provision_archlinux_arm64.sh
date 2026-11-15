#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Provision an Arch Linux AArch64 UEFI disk image using Archboot AArch64 and
# pack it into a zero-skipping archlinux.hvsparse container for henge-linux.

set -euo pipefail

WORK_DIR="${WORK_DIR:-work}"
DISK_SIZE_GB="${DISK_SIZE_GB:-24}"
RAM_MIB="${RAM_MIB:-3072}"
CPUS="${CPUS:-4}"
ARCHBOOT_BASE_URL="${ARCHBOOT_BASE_URL:-https://release.archboot.com/aarch64/latest/iso}"
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --dry-run|--check)
            DRY_RUN=1
            ;;
        *)
            echo "usage: $0 [--dry-run]" >&2
            exit 2
            ;;
    esac
done

find_edk2_firmware() {
    local candidates=(
        "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
        "/usr/local/share/qemu/edk2-aarch64-code.fd"
        "/usr/share/edk2/aarch64/QEMU_EFI.fd"
        "/usr/share/AAVMF/AAVMF_CODE.fd"
        "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
    )
    for path in "${candidates[@]}"; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

EDK2_CODE="$(find_edk2_firmware || true)"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[provision] Dry-run configuration verified:"
    echo "  WORK_DIR          = $WORK_DIR"
    echo "  DISK_SIZE_GB      = $DISK_SIZE_GB"
    echo "  RAM_MIB           = $RAM_MIB"
    echo "  CPUS              = $CPUS"
    echo "  ARCHBOOT_BASE_URL = $ARCHBOOT_BASE_URL"
    echo "  EDK2_CODE         = ${EDK2_CODE:-<not installed on host>}"
    exit 0
fi

if [ -z "$EDK2_CODE" ]; then
    echo "[provision] Missing EDK2 AArch64 firmware (install qemu via brew or apt/pacman)." >&2
    exit 1
fi

if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
    echo "[provision] Missing qemu-system-aarch64 in PATH." >&2
    exit 1
fi

mkdir -p "$WORK_DIR"

if [ ! -f "$WORK_DIR/code.fd" ]; then
    cp "$EDK2_CODE" "$WORK_DIR/code.fd"
    truncate -s 64M "$WORK_DIR/code.fd"
fi

if [ ! -f "$WORK_DIR/vars.fd" ]; then
    truncate -s 64M "$WORK_DIR/vars.fd"
fi

if [ ! -f "$WORK_DIR/archlinux.img" ]; then
    echo "[provision] Creating ${DISK_SIZE_GB} GiB raw NVMe image at $WORK_DIR/archlinux.img"
    truncate -s "${DISK_SIZE_GB}G" "$WORK_DIR/archlinux.img"
fi

ISO_PATH="$WORK_DIR/archboot-latest-aarch64.iso"
if [ ! -f "$ISO_PATH" ]; then
    echo "[provision] Resolving latest Archboot AArch64 ISO from $ARCHBOOT_BASE_URL/"
    ISO_NAME="$(curl -fsSL "$ARCHBOOT_BASE_URL/" | grep -oE 'archboot-[0-9.]+-[0-9.]+-[0-9.-]+-aarch64-ARCH-latest-aarch64\.iso' | head -n 1)"
    if [ -z "$ISO_NAME" ]; then
        ISO_NAME="$(curl -fsSL "$ARCHBOOT_BASE_URL/" | grep -oE 'archboot-[^"]+latest-aarch64\.iso' | head -n 1)"
    fi
    if [ -z "$ISO_NAME" ]; then
        echo "[provision] Could not resolve Archboot ISO filename at $ARCHBOOT_BASE_URL/" >&2
        exit 1
    fi
    echo "[provision] Downloading $ARCHBOOT_BASE_URL/$ISO_NAME -> $ISO_PATH"
    curl -fL "$ARCHBOOT_BASE_URL/$ISO_NAME" -o "$ISO_PATH"
fi

ACCEL_FLAG="-accel tcg"
if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
    ACCEL_FLAG="-accel hvf -cpu host"
elif [ -r /dev/kvm ] && [ "$(uname -m)" = "aarch64" ]; then
    ACCEL_FLAG="-accel kvm -cpu host"
else
    ACCEL_FLAG="-accel tcg -cpu cortex-a76"
fi

echo "[provision] Booting Archboot installer (run 'setup' inside guest to install to /dev/nvme0n1, then poweroff)..."
qemu-system-aarch64 \
    -M virt,gic-version=3,acpi=on \
    $ACCEL_FLAG \
    -smp "$CPUS" \
    -m "$RAM_MIB" \
    -drive if=pflash,format=raw,readonly=on,file="$WORK_DIR/code.fd" \
    -drive if=pflash,format=raw,file="$WORK_DIR/vars.fd" \
    -drive if=none,id=nvm,format=raw,file="$WORK_DIR/archlinux.img" \
    -device nvme,serial=HENGELNX01,drive=nvm \
    -drive if=none,id=cdrom,format=raw,readonly=on,file="$ISO_PATH" \
    -device virtio-scsi-pci \
    -device scsi-cd,drive=cdrom \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0 \
    -device qemu-xhci \
    -device usb-kbd \
    -device usb-tablet \
    -device ramfb \
    -nographic

if [ -x "./build/hvsparse" ]; then
    echo "[provision] Packing $WORK_DIR/archlinux.img -> $WORK_DIR/archlinux.hvsparse"
    ./build/hvsparse pack "$WORK_DIR/archlinux.img" "$WORK_DIR/archlinux.hvsparse"
else
    echo "[provision] Run 'make hvsparse && ./build/hvsparse pack $WORK_DIR/archlinux.img $WORK_DIR/archlinux.hvsparse' to pack."
fi
