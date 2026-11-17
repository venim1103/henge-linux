#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Non-interactive builder that creates pre-configured HengeLinux guest artifacts:
#   - code.fd (64 MiB EDK2 AArch64 UEFI firmware code)
#   - vars.fd (64 MiB EDK2 AArch64 UEFI NVRAM template)
#   - archlinux.hvsparse (16 GiB virtual GPT+ESP+ext4 Arch Linux ARM64 rootfs
#     with console=tty0 console=ttyAMA0,115200 and guest/setup-arch-bridge.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK_DIR="${WORK_DIR:-$REPO_ROOT/work/prebuilt}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/prebuilt}"
DISK_SIZE_MIB="${DISK_SIZE_MIB:-16384}"
ESP_SIZE_MIB="${ESP_SIZE_MIB:-512}"
ROOT_UUID="${ROOT_UUID:-60417316-399c-4918-b592-19e253118b72}"
ESP_PARTUUID="${ESP_PARTUUID:-c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
ROOT_PARTUUID="${ROOT_PARTUUID:-b921b045-1df0-41c3-af44-4c6f280d3fae}"
DRY_RUN=0

ALARM_MIRRORS=(
    "${ALARM_TARBALL_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"
    "https://eu.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
    "https://de.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
)

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

find_edk2_vars_template() {
    local candidates=(
        "/opt/homebrew/share/qemu/edk2-arm-vars.fd"
        "/usr/local/share/qemu/edk2-arm-vars.fd"
        "/usr/share/edk2/aarch64/vars-template-pflash.raw"
        "/usr/share/AAVMF/AAVMF_VARS.fd"
        "/usr/share/qemu-efi-aarch64/QEMU_VARS.fd"
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
EDK2_VARS="$(find_edk2_vars_template || true)"
ROOT_SIZE_MIB=$((DISK_SIZE_MIB - ESP_SIZE_MIB - 2))

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[prebuilt] Dry-run configuration verified:"
    echo "  WORK_DIR      = $WORK_DIR"
    echo "  OUT_DIR       = $OUT_DIR"
    echo "  DISK_SIZE_MIB = $DISK_SIZE_MIB (${ESP_SIZE_MIB} MiB ESP + ${ROOT_SIZE_MIB} MiB ext4 root)"
    echo "  ROOT_UUID     = $ROOT_UUID"
    echo "  PRIMARY_URL   = ${ALARM_MIRRORS[0]}"
    echo "  EDK2_CODE     = ${EDK2_CODE:-<not installed on host>}"
    echo "  EDK2_VARS     = ${EDK2_VARS:-<not installed on host; will zero-init>}"
    exit 0
fi

if [ "$(uname -s)" != "Linux" ]; then
    echo "[prebuilt] Non-interactive loop/ext4 rootfs assembly requires Linux (or GitHub Actions ubuntu-24.04-arm)." >&2
    exit 1
fi

if [ -z "$EDK2_CODE" ]; then
    echo "[prebuilt] Missing EDK2 AArch64 firmware (install qemu-efi-aarch64)." >&2
    exit 1
fi

for tool in curl dd mkfs.vfat mkfs.ext4 mount sfdisk tar truncate umount; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[prebuilt] Missing required host tool: $tool" >&2
        exit 1
    fi
done

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "[prebuilt] Root or sudo privileges are required to mount loop filesystems." >&2
        exit 1
    fi
fi

make -C "$REPO_ROOT" hvsparse
HVSPARSE_BIN="$REPO_ROOT/build/hvsparse"

mkdir -p "$WORK_DIR" "$OUT_DIR"
MNT_DIR="$WORK_DIR/mnt"
ESP_IMG="$WORK_DIR/esp.img"
ROOT_IMG="$WORK_DIR/root.img"
DISK_IMG="$WORK_DIR/archlinux.img"
TARBALL="$WORK_DIR/ArchLinuxARM-aarch64-latest.tar.gz"

cleanup() {
    set +e
    if mountpoint -q "$MNT_DIR/boot" 2>/dev/null; then
        $SUDO umount -lf "$MNT_DIR/boot"
    fi
    if mountpoint -q "$MNT_DIR" 2>/dev/null; then
        $SUDO umount -lf "$MNT_DIR"
    fi
    rm -f "$ESP_IMG" "$ROOT_IMG"
}
trap cleanup EXIT

echo "[prebuilt] Preparing 64 MiB EDK2 UEFI firmware images (code.fd & vars.fd)"
cp "$EDK2_CODE" "$OUT_DIR/code.fd"
truncate -s 64M "$OUT_DIR/code.fd"

if [ -n "$EDK2_VARS" ]; then
    cp "$EDK2_VARS" "$OUT_DIR/vars.fd"
    truncate -s 64M "$OUT_DIR/vars.fd"
else
    rm -f "$OUT_DIR/vars.fd"
    truncate -s 64M "$OUT_DIR/vars.fd"
fi

if [ ! -s "$TARBALL" ]; then
    DOWNLOADED=0
    for url in "${ALARM_MIRRORS[@]}"; do
        echo "[prebuilt] Downloading Arch Linux ARM64 rootfs from $url"
        if curl -fL --retry 4 --retry-delay 3 --connect-timeout 20 "$url" -o "$TARBALL.part"; then
            mv "$TARBALL.part" "$TARBALL"
            DOWNLOADED=1
            break
        fi
        rm -f "$TARBALL.part"
    done
    if [ "$DOWNLOADED" -ne 1 ]; then
        echo "[prebuilt] Failed to download Arch Linux ARM64 rootfs from all mirrors." >&2
        exit 1
    fi
fi

echo "[prebuilt] Formatting ${ESP_SIZE_MIB} MiB FAT32 ESP and ${ROOT_SIZE_MIB} MiB ext4 root partition images"
rm -f "$ESP_IMG" "$ROOT_IMG" "$DISK_IMG"
truncate -s "${ESP_SIZE_MIB}M" "$ESP_IMG"
mkfs.vfat -F 32 -n "ARCH_EFI" "$ESP_IMG" >/dev/null

truncate -s "${ROOT_SIZE_MIB}M" "$ROOT_IMG"
mkfs.ext4 -F -q -L "arch_root" -U "$ROOT_UUID" "$ROOT_IMG"

mkdir -p "$MNT_DIR"
$SUDO mount -o loop "$ROOT_IMG" "$MNT_DIR"
$SUDO mkdir -p "$MNT_DIR/boot"
$SUDO mount -o loop "$ESP_IMG" "$MNT_DIR/boot"

echo "[prebuilt] Extracting Arch Linux ARM64 rootfs into mounted partitions"
if command -v bsdtar >/dev/null 2>&1; then
    $SUDO bsdtar -xpf "$TARBALL" -C "$MNT_DIR"
else
    $SUDO tar -xzpf "$TARBALL" -C "$MNT_DIR" --numeric-owner
fi

echo "[prebuilt] Configuring UEFI bootloader (BOOTAA64.EFI + systemd-boot + startup.nsh)"
$SUDO mkdir -p "$MNT_DIR/boot/EFI/BOOT" "$MNT_DIR/boot/EFI/systemd" "$MNT_DIR/boot/loader/entries"

if [ -f "$MNT_DIR/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" ]; then
    $SUDO cp "$MNT_DIR/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$MNT_DIR/boot/EFI/BOOT/BOOTAA64.EFI"
    $SUDO cp "$MNT_DIR/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$MNT_DIR/boot/EFI/systemd/systemd-bootaa64.efi"
elif [ -f "/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" ]; then
    $SUDO cp "/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$MNT_DIR/boot/EFI/BOOT/BOOTAA64.EFI"
    $SUDO cp "/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$MNT_DIR/boot/EFI/systemd/systemd-bootaa64.efi"
elif [ -f "$MNT_DIR/boot/Image" ]; then
    # Linux ARM64 Image is built with CONFIG_EFI_STUB=y and can execute directly as BOOTAA64.EFI
    $SUDO cp "$MNT_DIR/boot/Image" "$MNT_DIR/boot/EFI/BOOT/BOOTAA64.EFI"
fi

$SUDO tee "$MNT_DIR/boot/loader/loader.conf" >/dev/null <<'EOF'
default arch.conf
timeout 1
console-mode max
editor no
EOF

$SUDO tee "$MNT_DIR/boot/loader/entries/arch.conf" >/dev/null <<EOF
title   Arch Linux ARM64 (HengeLinux iOS)
linux   /Image
initrd  /initramfs-linux.img
options root=UUID=${ROOT_UUID} rw rootwait console=tty0 console=ttyAMA0,115200
EOF

$SUDO tee "$MNT_DIR/boot/startup.nsh" >/dev/null <<EOF
\Image initrd=\initramfs-linux.img root=UUID=${ROOT_UUID} rw rootwait console=tty0 console=ttyAMA0,115200
EOF

echo "[prebuilt] Configuring /etc/fstab, hostname, serial/GOP console, and henge-linux guest bridge"
$SUDO tee "$MNT_DIR/etc/fstab" >/dev/null <<EOF
# <file system>        <dir>         <type>    <options>          <dump> <pass>
UUID=${ROOT_UUID}      /             ext4      defaults,noatime   0      1
LABEL=ARCH_EFI         /boot         vfat      defaults,noatime   0      2
EOF

echo "hengelinux" | $SUDO tee "$MNT_DIR/etc/hostname" >/dev/null

# Install henge-xdg-open and setup-arch-bridge.sh inside the guest rootfs
$SUDO install -Dm755 "$REPO_ROOT/guest/henge-xdg-open" "$MNT_DIR/usr/local/bin/henge-xdg-open"
$SUDO install -Dm755 "$REPO_ROOT/guest/setup-arch-bridge.sh" "$MNT_DIR/usr/local/bin/setup-arch-bridge.sh"

if [ ! -e "$MNT_DIR/usr/bin/xdg-open" ] && [ ! -e "$MNT_DIR/usr/local/bin/xdg-open" ]; then
    $SUDO ln -sf /usr/local/bin/henge-xdg-open "$MNT_DIR/usr/local/bin/xdg-open"
fi

$SUDO install -d "$MNT_DIR/etc/profile.d"
$SUDO tee "$MNT_DIR/etc/profile.d/henge-safari-bridge.sh" >/dev/null <<'EOF'
# Route CLI OAuth helpers (gh, gcloud, git web--browse) to iOS SafariSheetView.
if [ -z "${BROWSER:-}" ]; then
    export BROWSER="/usr/local/bin/henge-xdg-open"
fi
EOF
$SUDO chmod 0644 "$MNT_DIR/etc/profile.d/henge-safari-bridge.sh"

$SUDO install -d "$MNT_DIR/etc/systemd/network"
$SUDO tee "$MNT_DIR/etc/systemd/network/20-henge-virtio.network" >/dev/null <<'EOF'
[Match]
Driver=virtio_net

[Network]
DHCP=yes
DNS=10.0.2.3
EOF

$SUDO rm -f "$MNT_DIR/etc/resolv.conf"
printf 'nameserver 10.0.2.3\n' | $SUDO tee "$MNT_DIR/etc/resolv.conf" >/dev/null

$SUDO install -d "$MNT_DIR/usr/local/share/applications" "$MNT_DIR/etc/xdg" "$MNT_DIR/mnt/ios-share"
$SUDO tee "$MNT_DIR/usr/local/share/applications/henge-safari-bridge.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=iOS Safari Bridge
Exec=/usr/local/bin/henge-xdg-open %u
Terminal=false
NoDisplay=true
MimeType=x-scheme-handler/http;x-scheme-handler/https;
EOF

$SUDO tee "$MNT_DIR/etc/xdg/mimeapps.list" >/dev/null <<'EOF'
[Default Applications]
x-scheme-handler/http=henge-safari-bridge.desktop
x-scheme-handler/https=henge-safari-bridge.desktop
EOF

# Ensure serial (ttyAMA0) and framebuffer (tty1) login prompts are enabled
$SUDO mkdir -p "$MNT_DIR/etc/systemd/system/getty.target.wants"
if [ -f "$MNT_DIR/usr/lib/systemd/system/serial-getty@.service" ]; then
    $SUDO ln -sf /usr/lib/systemd/system/serial-getty@.service \
        "$MNT_DIR/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"
fi

sync
$SUDO umount "$MNT_DIR/boot"
$SUDO umount "$MNT_DIR"

echo "[prebuilt] Assembling ${DISK_SIZE_MIB} MiB GPT disk image and writing ESP + root extents"
truncate -s "${DISK_SIZE_MIB}M" "$DISK_IMG"

ESP_SECTORS=$((ESP_SIZE_MIB * 2048))
ROOT_START_SECTOR=$((2048 + ESP_SECTORS))
ROOT_SECTORS=$((ROOT_SIZE_MIB * 2048))

sfdisk "$DISK_IMG" >/dev/null <<EOF
label: gpt
unit: sectors
first-lba: 2048

1 : start=2048, size=${ESP_SECTORS}, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=${ESP_PARTUUID}, name="EFI System"
2 : start=${ROOT_START_SECTOR}, size=${ROOT_SECTORS}, type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, uuid=${ROOT_PARTUUID}, name="Arch Linux Root"
EOF

dd if="$ESP_IMG" of="$DISK_IMG" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$ROOT_IMG" of="$DISK_IMG" bs=1M seek=$((1 + ESP_SIZE_MIB)) conv=notrunc,sparse status=none
rm -f "$ESP_IMG" "$ROOT_IMG"

echo "[prebuilt] Packing $DISK_IMG -> $OUT_DIR/archlinux.hvsparse"
"$HVSPARSE_BIN" pack "$DISK_IMG" "$OUT_DIR/archlinux.hvsparse"
rm -f "$DISK_IMG"

(
    cd "$OUT_DIR"
    sha256sum code.fd vars.fd archlinux.hvsparse > SHA256SUMS.txt
)

ls -lh "$OUT_DIR/code.fd" "$OUT_DIR/vars.fd" "$OUT_DIR/archlinux.hvsparse" "$OUT_DIR/SHA256SUMS.txt"
echo "[prebuilt] Pre-built Arch Linux ARM64 guest bundle ready in $OUT_DIR"
