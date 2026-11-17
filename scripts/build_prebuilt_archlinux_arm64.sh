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
DISK_SIZE_MIB="${DISK_SIZE_MIB:-8192}"
ESP_SIZE_MIB="${ESP_SIZE_MIB:-256}"
MAX_HVSPARSE_BYTES="${MAX_HVSPARSE_BYTES:-2097152000}"
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
ESP_MNT_DIR="$WORK_DIR/esp_mnt"
ESP_IMG="$WORK_DIR/esp.img"
ROOT_IMG="$WORK_DIR/root.img"
DISK_IMG="$WORK_DIR/archlinux.img"
TARBALL="$WORK_DIR/ArchLinuxARM-aarch64-latest.tar.gz"

cleanup() {
    set +e
    if mountpoint -q "$ESP_MNT_DIR" 2>/dev/null; then
        $SUDO umount -lf "$ESP_MNT_DIR"
    fi
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
            if curl -fsSL --connect-timeout 10 "${url}.md5" -o "$TARBALL.md5" 2>/dev/null; then
                EXPECTED_MD5="$(awk '{print $1; exit}' "$TARBALL.md5")"
                ACTUAL_MD5="$(md5sum "$TARBALL.part" | awk '{print $1}')"
                if [ -n "$EXPECTED_MD5" ] && [ "$ACTUAL_MD5" != "$EXPECTED_MD5" ]; then
                    echo "[prebuilt] MD5 mismatch from $url (expected $EXPECTED_MD5, got $ACTUAL_MD5)" >&2
                    rm -f "$TARBALL.part" "$TARBALL.md5"
                    continue
                fi
                echo "[prebuilt] Verified MD5 checksum ($ACTUAL_MD5)"
            fi
            rm -f "$TARBALL.md5"
            mv "$TARBALL.part" "$TARBALL"
            DOWNLOADED=1
            break
        fi
        rm -f "$TARBALL.part" "$TARBALL.md5"
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
mkfs.ext4 -F -q -L "arch_root" -U "$ROOT_UUID" -i 32768 -J size=16 -E lazy_itable_init=1,lazy_journal_init=1 "$ROOT_IMG"

mkdir -p "$MNT_DIR" "$ESP_MNT_DIR"
$SUDO mount -o loop "$ROOT_IMG" "$MNT_DIR"

echo "[prebuilt] Extracting Arch Linux ARM64 rootfs into ext4 root partition"
if command -v bsdtar >/dev/null 2>&1; then
    $SUDO bsdtar -xpf "$TARBALL" -C "$MNT_DIR"
else
    $SUDO tar -xzpf "$TARBALL" -C "$MNT_DIR" --numeric-owner
fi
rm -f "$TARBALL"

echo "[prebuilt] Pruning static manpages/docs/locales to keep archlinux.hvsparse under GitHub's 2 GiB release cap"
$SUDO rm -rf \
    "$MNT_DIR/var/cache/pacman/pkg/"* \
    "$MNT_DIR/usr/share/doc/"* \
    "$MNT_DIR/usr/share/man/"* \
    "$MNT_DIR/usr/share/info/"* \
    "$MNT_DIR/usr/share/gtk-doc/"*
if [ -d "$MNT_DIR/usr/share/locale" ]; then
    $SUDO find "$MNT_DIR/usr/share/locale" -mindepth 1 -maxdepth 1 \
        ! -name 'en' ! -name 'en_*' ! -name 'C.UTF-8' ! -name 'locale.alias' \
        -exec rm -rf {} +
fi

echo "[prebuilt] Populating FAT32 EFI System Partition (BOOTAA64.EFI + kernel + initramfs + startup.nsh)"
$SUDO mount -o loop "$ESP_IMG" "$ESP_MNT_DIR"
if [ -d "$MNT_DIR/boot" ]; then
    $SUDO cp -r --no-preserve=ownership,mode "$MNT_DIR/boot/." "$ESP_MNT_DIR/"
    $SUDO rm -rf "$MNT_DIR/boot"
fi
$SUDO mkdir -p "$MNT_DIR/boot" "$ESP_MNT_DIR/EFI/BOOT" "$ESP_MNT_DIR/EFI/systemd" "$ESP_MNT_DIR/loader/entries"

if [ -f "$MNT_DIR/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" ]; then
    $SUDO cp --no-preserve=ownership,mode "$MNT_DIR/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$ESP_MNT_DIR/EFI/BOOT/BOOTAA64.EFI"
    $SUDO cp --no-preserve=ownership,mode "$MNT_DIR/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$ESP_MNT_DIR/EFI/systemd/systemd-bootaa64.efi"
elif [ -f "/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" ]; then
    $SUDO cp --no-preserve=ownership,mode "/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$ESP_MNT_DIR/EFI/BOOT/BOOTAA64.EFI"
    $SUDO cp --no-preserve=ownership,mode "/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$ESP_MNT_DIR/EFI/systemd/systemd-bootaa64.efi"
elif [ -f "$ESP_MNT_DIR/Image" ]; then
    # Linux ARM64 Image is built with CONFIG_EFI_STUB=y and can execute directly as BOOTAA64.EFI
    $SUDO cp --no-preserve=ownership,mode "$ESP_MNT_DIR/Image" "$ESP_MNT_DIR/EFI/BOOT/BOOTAA64.EFI"
fi

$SUDO tee "$ESP_MNT_DIR/loader/loader.conf" >/dev/null <<'EOF'
default arch.conf
timeout 1
console-mode max
editor no
EOF

$SUDO tee "$ESP_MNT_DIR/loader/entries/arch.conf" >/dev/null <<EOF
title   Arch Linux ARM64 (HengeLinux iOS)
linux   /Image
initrd  /initramfs-linux.img
options root=UUID=${ROOT_UUID} rw rootwait console=tty0 console=ttyAMA0,115200
EOF

$SUDO tee "$ESP_MNT_DIR/startup.nsh" >/dev/null <<EOF
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

# Ensure serial (ttyAMA0), networking, and DNS services are enabled
$SUDO mkdir -p "$MNT_DIR/etc/systemd/system/getty.target.wants" "$MNT_DIR/etc/systemd/system/multi-user.target.wants"
if [ -f "$MNT_DIR/usr/lib/systemd/system/serial-getty@.service" ]; then
    $SUDO ln -sf /usr/lib/systemd/system/serial-getty@.service \
        "$MNT_DIR/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"
fi
for unit in systemd-networkd.service systemd-resolved.service; do
    if [ -f "$MNT_DIR/usr/lib/systemd/system/$unit" ]; then
        $SUDO ln -sf "/usr/lib/systemd/system/$unit" \
            "$MNT_DIR/etc/systemd/system/multi-user.target.wants/$unit"
    fi
done

sync
$SUDO umount "$ESP_MNT_DIR"
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

SPARSE_BYTES="$(wc -c < "$OUT_DIR/archlinux.hvsparse" | tr -d '[:space:]')"
if [ "$SPARSE_BYTES" -ge "$MAX_HVSPARSE_BYTES" ]; then
    echo "[prebuilt] ERROR: archlinux.hvsparse is ${SPARSE_BYTES} bytes (exceeds ${MAX_HVSPARSE_BYTES}-byte limit for GitHub Releases)." >&2
    exit 1
fi

(
    cd "$OUT_DIR"
    sha256sum code.fd vars.fd archlinux.hvsparse > SHA256SUMS.txt
)

ls -lh "$OUT_DIR/code.fd" "$OUT_DIR/vars.fd" "$OUT_DIR/archlinux.hvsparse" "$OUT_DIR/SHA256SUMS.txt"
echo "[prebuilt] Pre-built Arch Linux ARM64 guest bundle ready in $OUT_DIR"
