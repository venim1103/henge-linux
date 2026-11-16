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

create_sparse_raw_file() {
    local dst="$1"
    local size_spec="$2"
    if command -v qemu-img >/dev/null 2>&1; then
        qemu-img create -f raw "$dst" "$size_spec" >/dev/null
    elif command -v truncate >/dev/null 2>&1; then
        truncate -s "$size_spec" "$dst"
    else
        echo "[provision] Neither qemu-img nor truncate found to create $dst" >&2
        exit 1
    fi
}

mkdir -p "$WORK_DIR"

if [ ! -f "$WORK_DIR/code.fd" ]; then
    cp "$EDK2_CODE" "$WORK_DIR/code.fd"
    if command -v qemu-img >/dev/null 2>&1; then
        qemu-img resize -f raw "$WORK_DIR/code.fd" 64M >/dev/null
    else
        truncate -s 64M "$WORK_DIR/code.fd"
    fi
fi

if [ ! -f "$WORK_DIR/vars.fd" ]; then
    create_sparse_raw_file "$WORK_DIR/vars.fd" 64M
fi

if [ ! -f "$WORK_DIR/archlinux.img" ]; then
    echo "[provision] Creating ${DISK_SIZE_GB} GiB raw NVMe image at $WORK_DIR/archlinux.img"
    create_sparse_raw_file "$WORK_DIR/archlinux.img" "${DISK_SIZE_GB}G"
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
    curl -fL "$ARCHBOOT_BASE_URL/$ISO_NAME" -o "$ISO_PATH.part"
    if curl -fsSL "$ARCHBOOT_BASE_URL/sha256sums.txt" -o "$WORK_DIR/sha256sums.txt"; then
        EXPECTED_SHA="$(awk -v name="$ISO_NAME" '$2 == name || $2 == ("*" name) { print $1; exit }' "$WORK_DIR/sha256sums.txt")"
        if [ -n "$EXPECTED_SHA" ]; then
            if command -v sha256sum >/dev/null 2>&1; then
                ACTUAL_SHA="$(sha256sum "$ISO_PATH.part" | awk '{print $1}')"
            else
                ACTUAL_SHA="$(shasum -a 256 "$ISO_PATH.part" | awk '{print $1}')"
            fi
            if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
                echo "[provision] SHA-256 mismatch for $ISO_NAME (expected $EXPECTED_SHA, got $ACTUAL_SHA)" >&2
                rm -f "$ISO_PATH.part"
                exit 1
            fi
            echo "[provision] Verified SHA-256 for $ISO_NAME"
        fi
    fi
    mv "$ISO_PATH.part" "$ISO_PATH"
fi

ACCEL_ARGS=(-accel tcg -cpu cortex-a76)
if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
    ACCEL_ARGS=(-accel hvf -cpu host)
elif [ -r /dev/kvm ] && [ "$(uname -m)" = "aarch64" ]; then
    ACCEL_ARGS=(-accel kvm -cpu host)
fi

echo "[provision] Booting Archboot installer over serial console (run 'setup' inside guest to install to /dev/nvme0n1, ensure kernel cmdline includes 'console=tty0 console=ttyAMA0,115200', then poweroff)..."
qemu-system-aarch64 \
    -M virt,gic-version=3,acpi=on \
    "${ACCEL_ARGS[@]}" \
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
    -nographic

if [ -x "./build/hvsparse" ]; then
    echo "[provision] Packing $WORK_DIR/archlinux.img -> $WORK_DIR/archlinux.hvsparse"
    ./build/hvsparse pack "$WORK_DIR/archlinux.img" "$WORK_DIR/archlinux.hvsparse"
else
    echo "[provision] Run 'make hvsparse && ./build/hvsparse pack $WORK_DIR/archlinux.img $WORK_DIR/archlinux.hvsparse' to pack."
fi
