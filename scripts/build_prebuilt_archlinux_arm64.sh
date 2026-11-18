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
VERIFY_BOOT="${VERIFY_BOOT:-0}"
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

echo "[prebuilt] Pruning static manpages/docs/locales/firmware to keep archlinux.hvsparse under GitHub's 2 GiB release cap"
$SUDO rm -rf \
    "$MNT_DIR/var/cache/pacman/pkg/"* \
    "$MNT_DIR/usr/share/doc/"* \
    "$MNT_DIR/usr/share/man/"* \
    "$MNT_DIR/usr/share/info/"* \
    "$MNT_DIR/usr/share/gtk-doc/"* \
    "$MNT_DIR/usr/share/help/"* \
    "$MNT_DIR/usr/share/i18n/"* \
    "$MNT_DIR/usr/lib/locale/locale-archive"
if [ -d "$MNT_DIR/usr/lib/firmware" ]; then
    $SUDO find "$MNT_DIR/usr/lib/firmware" -mindepth 1 -maxdepth 1 \
        ! -name 'regulatory.db*' \
        -exec rm -rf {} +
fi
if [ -d "$MNT_DIR/usr/share/locale" ]; then
    $SUDO find "$MNT_DIR/usr/share/locale" -mindepth 1 -maxdepth 1 \
        ! -name 'en' ! -name 'en_*' ! -name 'C.UTF-8' ! -name 'locale.alias' \
        -exec rm -rf {} +
fi
if [ -f "$MNT_DIR/etc/pacman.conf" ]; then
    $SUDO sed -i '/^#NoExtract/a NoExtract   = usr/share/man/* usr/share/doc/* usr/share/info/* usr/share/gtk-doc/* usr/share/help/* usr/share/i18n/* usr/lib/firmware/* !usr/lib/firmware/regulatory.db*' "$MNT_DIR/etc/pacman.conf"
fi

echo "[prebuilt] Populating FAT32 EFI System Partition (systemd-boot BOOTAA64.EFI + kernel + initramfs + startup.nsh)"
$SUDO mount -o loop "$ESP_IMG" "$ESP_MNT_DIR"
if [ -d "$MNT_DIR/boot" ]; then
    $SUDO cp -r --no-preserve=ownership,mode "$MNT_DIR/boot/." "$ESP_MNT_DIR/"
    $SUDO rm -rf "$MNT_DIR/boot"
fi
$SUDO mkdir -p "$MNT_DIR/boot" "$ESP_MNT_DIR/EFI/BOOT" "$ESP_MNT_DIR/loader/entries"

KERNEL_CMDLINE="root=UUID=${ROOT_UUID} rw rootwait earlycon=pl011,0x09000000 ignore_loglevel console=tty0 console=ttyAMA0,115200 usbcore.nousb rcupdate.rcu_cpu_stall_timeout=300"

if [ -f "$MNT_DIR/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" ]; then
    echo "[prebuilt] Installing Arch Linux ARM native systemd-bootaa64.efi as EFI/BOOT/BOOTAA64.EFI"
    $SUDO cp --no-preserve=ownership,mode \
        "$MNT_DIR/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" \
        "$ESP_MNT_DIR/EFI/BOOT/BOOTAA64.EFI"
elif [ -f "$ESP_MNT_DIR/Image" ]; then
    echo "[prebuilt] Falling back to direct CONFIG_EFI_STUB Linux Image as EFI/BOOT/BOOTAA64.EFI"
    $SUDO cp --no-preserve=ownership,mode "$ESP_MNT_DIR/Image" "$ESP_MNT_DIR/EFI/BOOT/BOOTAA64.EFI"
else
    echo "[prebuilt] ERROR: Missing /boot/Image in Arch Linux ARM64 rootfs." >&2
    exit 1
fi

$SUDO tee "$ESP_MNT_DIR/loader/loader.conf" >/dev/null <<'EOF'
default arch.conf
timeout 0
console-mode keep
editor no
EOF

$SUDO tee "$ESP_MNT_DIR/loader/entries/arch.conf" >/dev/null <<EOF
title   Arch Linux ARM64 (HengeLinux iOS)
linux   /Image
initrd  /initramfs-linux.img
options ${KERNEL_CMDLINE}
EOF

$SUDO tee "$ESP_MNT_DIR/startup.nsh" >/dev/null <<EOF
\Image initrd=\initramfs-linux.img ${KERNEL_CMDLINE}
EOF

echo "[prebuilt] Configuring /etc/fstab, hostname, serial/GOP console, and henge-linux guest bridge"
$SUDO tee "$MNT_DIR/etc/fstab" >/dev/null <<EOF
# <file system>        <dir>         <type>    <options>          <dump> <pass>
UUID=${ROOT_UUID}      /             ext4      defaults,noatime   0      1
LABEL=ARCH_EFI         /boot         vfat      defaults,noatime   0      2
EOF

echo "hengelinux" | $SUDO tee "$MNT_DIR/etc/hostname" >/dev/null
echo "LANG=C.UTF-8" | $SUDO tee "$MNT_DIR/etc/locale.conf" >/dev/null

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

# Pre-configure Xorg fbdev (/dev/fb0 efifb), SDDM autologin on VT2 (so VT1 serial console never collides),
# a serial-to-uinput HID bridge (so iOS touch/trackpad/keyboard work in X11 even with usbcore.nousb),
# and a one-command henge-install-desktop helper for LXQt + SDDM.
$SUDO install -d "$MNT_DIR/etc/X11/xorg.conf.d" "$MNT_DIR/etc/sddm.conf.d"
$SUDO tee "$MNT_DIR/etc/X11/xorg.conf.d/10-fbdev.conf" >/dev/null <<'EOF'
Section "Device"
    Identifier "EFIFB"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
EndSection
EOF

$SUDO tee "$MNT_DIR/etc/sddm.conf.d/hengelinux.conf" >/dev/null <<'EOF'
[Autologin]
User=arch
Session=lxqt

[General]
DisplayServer=x11

[X11]
MinimumVT=2
ServerArguments=-nolisten tcp vt2
EOF

$SUDO tee "$MNT_DIR/usr/local/bin/henge-uinput-bridge" >/dev/null <<'EOF'
#!/usr/bin/env python3
"""Inject iOS touch/trackpad pointer and HID keyboard events into Linux /dev/uinput
so X11/LXQt receives full mouse + keyboard input even when usbcore.nousb is active."""
import ctypes
import fcntl
import os
import select
import struct
import sys
import time

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_RELBIT = 0x40045566
UI_SET_ABSBIT = 0x40045567
UI_DEV_SETUP = 0x405C5503
UI_ABS_SETUP = 0x401C5504
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

EV_SYN = 0x00
EV_KEY = 0x01
EV_REL = 0x02
EV_ABS = 0x03
SYN_REPORT = 0x00

REL_WHEEL = 0x08
ABS_X = 0x00
ABS_Y = 0x01
BTN_LEFT = 0x110
BTN_RIGHT = 0x111
BTN_MIDDLE = 0x112
BTN_TOOL_FINGER = 0x145
BTN_TOUCH = 0x14A

HID_TO_EVDEV = {
    0x04: 30, 0x05: 48, 0x06: 46, 0x07: 32, 0x08: 18, 0x09: 33, 0x0A: 34, 0x0B: 35,
    0x0C: 23, 0x0D: 36, 0x0E: 37, 0x0F: 38, 0x10: 50, 0x11: 49, 0x12: 24, 0x13: 25,
    0x14: 16, 0x15: 19, 0x16: 31, 0x17: 20, 0x18: 22, 0x19: 47, 0x1A: 17, 0x1B: 45,
    0x1C: 21, 0x1D: 44,
    0x1E: 2, 0x1F: 3, 0x20: 4, 0x21: 5, 0x22: 6, 0x23: 7, 0x24: 8, 0x25: 9, 0x26: 10, 0x27: 11,
    0x28: 28, 0x29: 1, 0x2A: 14, 0x2B: 15, 0x2C: 57,
    0x2D: 12, 0x2E: 13, 0x2F: 26, 0x30: 27, 0x31: 43, 0x33: 39, 0x34: 40, 0x35: 41,
    0x36: 51, 0x37: 52, 0x38: 53, 0x39: 58,
    0x3A: 59, 0x3B: 60, 0x3C: 61, 0x3D: 62, 0x3E: 63, 0x3F: 64, 0x40: 65, 0x41: 66,
    0x42: 67, 0x43: 68, 0x44: 87, 0x45: 88,
    0x49: 110, 0x4A: 102, 0x4B: 104, 0x4C: 111, 0x4D: 107, 0x4E: 109,
    0x4F: 106, 0x50: 105, 0x51: 108, 0x52: 103,
    0x54: 98, 0x55: 55, 0x56: 74, 0x57: 78, 0x58: 96,
    0x59: 79, 0x5A: 80, 0x5B: 81, 0x5C: 75, 0x5D: 76, 0x5E: 77,
    0x5F: 71, 0x60: 72, 0x61: 73, 0x62: 82, 0x63: 83,
    0xE0: 29, 0xE1: 42, 0xE2: 56, 0xE3: 125, 0xE4: 97, 0xE5: 54, 0xE6: 100, 0xE7: 126,
}

def emit(fd, ev_type, code, value):
    now = time.time()
    sec = int(now)
    usec = int((now - sec) * 1_000_000)
    os.write(fd, struct.pack("@llHHi", sec, usec, ev_type, code, value))

def create_uinput():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    for ev in (EV_KEY, EV_ABS, EV_REL):
        fcntl.ioctl(fd, UI_SET_EVBIT, ev)
    for btn in (BTN_LEFT, BTN_RIGHT, BTN_MIDDLE, BTN_TOUCH, BTN_TOOL_FINGER):
        fcntl.ioctl(fd, UI_SET_KEYBIT, btn)
    for keycode in set(HID_TO_EVDEV.values()):
        fcntl.ioctl(fd, UI_SET_KEYBIT, keycode)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_WHEEL)
    for axis in (ABS_X, ABS_Y):
        fcntl.ioctl(fd, UI_SET_ABSBIT, axis)
        abs_setup = struct.pack("@Hiiiiii", axis, 0, 0, 32767, 0, 0, 0)
        fcntl.ioctl(fd, UI_ABS_SETUP, abs_setup)
    dev_setup = struct.pack("@HHHH80sI", 0x06, 0x1234, 0x5678, 1, b"HengeLinux Virtual HID", 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, dev_setup)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd

def main():
    fifo_path = "/run/henge-hid.fifo"
    if os.path.exists(fifo_path):
        os.unlink(fifo_path)
    os.mkfifo(fifo_path, 0o600)
    ufd = create_uinput()
    prev_buttons = 0
    rfd = os.open(fifo_path, os.O_RDWR | os.O_NONBLOCK)
    buf = b""
    try:
        while True:
            select.select([rfd], [], [])
            chunk = os.read(rfd, 4096)
            if not chunk:
                continue
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                parts = line.decode("ascii", "ignore").strip().split()
                if not parts:
                    continue
                if parts[0] == "P" and len(parts) == 5:
                    x = max(0, min(32767, int(parts[1])))
                    y = max(0, min(32767, int(parts[2])))
                    buttons = int(parts[3])
                    wheel = int(parts[4])
                    emit(ufd, EV_ABS, ABS_X, x)
                    emit(ufd, EV_ABS, ABS_Y, y)
                    for bit, btn in ((1, BTN_LEFT), (2, BTN_RIGHT), (4, BTN_MIDDLE)):
                        was = (prev_buttons & bit) != 0
                        now_b = (buttons & bit) != 0
                        if was != now_b:
                            emit(ufd, EV_KEY, btn, 1 if now_b else 0)
                    prev_buttons = buttons
                    if wheel != 0:
                        emit(ufd, EV_REL, REL_WHEEL, wheel)
                    emit(ufd, EV_SYN, SYN_REPORT, 0)
                elif parts[0] == "K" and len(parts) == 3:
                    usage = int(parts[1], 16)
                    pressed = 1 if int(parts[2]) != 0 else 0
                    code = HID_TO_EVDEV.get(usage)
                    if code is not None:
                        emit(ufd, EV_KEY, code, pressed)
                        emit(ufd, EV_SYN, SYN_REPORT, 0)
    finally:
        fcntl.ioctl(ufd, UI_DEV_DESTROY)
        os.close(ufd)
        os.close(rfd)

if __name__ == "__main__":
    main()
EOF
$SUDO chmod 0755 "$MNT_DIR/usr/local/bin/henge-uinput-bridge"

$SUDO tee "$MNT_DIR/etc/systemd/system/henge-uinput-bridge.service" >/dev/null <<'EOF'
[Unit]
Description=HengeLinux Virtual uinput Pointer & Keyboard Bridge
After=systemd-udevd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/henge-uinput-bridge
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
$SUDO ln -sf /etc/systemd/system/henge-uinput-bridge.service \
    "$MNT_DIR/etc/systemd/system/multi-user.target.wants/henge-uinput-bridge.service"

$SUDO tee "$MNT_DIR/usr/local/bin/henge-install-desktop" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "[henge-linux] Installing LXQt desktop, SDDM, and Xorg fbdev driver for /dev/fb0..."
pacman -Sy --needed --noconfirm lxqt sddm xorg-server xorg-xinit xf86-video-fbdev ttf-dejavu
if ! id -u arch >/dev/null 2>&1; then
    useradd -m -G wheel,video,input,audio -s /bin/bash arch
    echo "arch:arch" | chpasswd
    echo "[henge-linux] Created desktop user 'arch' (password: 'arch')."
else
    usermod -aG wheel,video,input,audio arch || true
fi
printf 'exec startlxqt\n' > /home/arch/.xinitrc
chown arch:arch /home/arch/.xinitrc
systemctl enable --now henge-uinput-bridge.service || true
systemctl set-default graphical.target
systemctl enable --now sddm
chvt 2 || true
echo "[henge-linux] SDDM autologin started on VT2 (user: arch)."
EOF
$SUDO chmod 0755 "$MNT_DIR/usr/local/bin/henge-install-desktop"

# Ensure serial (ttyAMA0) mirrors live onto tty1 (Metal display), networking, and DNS are enabled
$SUDO mkdir -p \
    "$MNT_DIR/etc/systemd/system/getty.target.wants" \
    "$MNT_DIR/etc/systemd/system/multi-user.target.wants" \
    "$MNT_DIR/etc/systemd/system/serial-getty@ttyAMA0.service.d"

$SUDO tee "$MNT_DIR/usr/local/bin/henge-dual-console" >/dev/null <<'EOF'
#!/usr/bin/env bash
# Mirror the PL011 serial TTY session (which receives all iPhone on-screen and
# Bluetooth keyboard events) onto /dev/tty1 with zero stdio buffering so every
# typed character renders immediately on the Metal display.
if command -v python3 >/dev/null 2>&1 && [ -e /dev/tty1 ]; then
    exec python3 - <<'PY'
import errno
import fcntl
import os
import pty
import select
import sys
import termios

tty1_fd = os.open("/dev/tty1", os.O_WRONLY | os.O_NOCTTY)
master_fd, slave_fd = pty.openpty()

try:
    winsz = fcntl.ioctl(tty1_fd, termios.TIOCGWINSZ, b"\x00" * 8)
    fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsz)
except OSError:
    pass

pid = os.fork()
if pid == 0:
    os.close(tty1_fd)
    os.close(master_fd)
    os.setsid()
    fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
    os.dup2(slave_fd, 0)
    os.dup2(slave_fd, 1)
    os.dup2(slave_fd, 2)
    if slave_fd > 2:
        os.close(slave_fd)
    os.execv("/sbin/agetty", [
        "agetty",
        "--noclear",
        "--autologin",
        "root",
        "-o",
        "-p -f -- \\u",
        "115200",
        "-",
        "linux",
    ])

os.close(slave_fd)
stdin_fd = sys.stdin.fileno()
stdout_fd = sys.stdout.fileno()
old_attrs = termios.tcgetattr(stdin_fd)

try:
    raw = list(old_attrs)
    raw[0] &= ~(termios.IGNBRK | termios.BRKINT | termios.PARMRK | termios.ISTRIP |
                termios.INLCR | termios.IGNCR | termios.ICRNL | termios.IXON)
    raw[1] &= ~termios.OPOST
    raw[2] &= ~(termios.CSIZE | termios.PARENB)
    raw[2] |= termios.CS8
    raw[3] &= ~(termios.ECHO | termios.ECHONL | termios.ICANON | termios.ISIG | termios.IEXTEN)
    raw[6][termios.VMIN] = 1
    raw[6][termios.VTIME] = 0
    termios.tcsetattr(stdin_fd, termios.TCSANOW, raw)

    def tty1_is_active() -> bool:
        try:
            with open("/sys/class/tty/tty0/active", "rb") as f:
                return f.read().strip() in (b"tty1", b"")
        except OSError:
            return True

    def forward_hid_escape_to_uinput(chunk: bytes) -> bytes:
        # Intercept OSC 9999 HID frames (\x1b]9999;...\x07) sent by HengeVMBridge
        # when VT2 (X11/LXQt) is active and write them to /run/henge-hid.fifo.
        out = bytearray()
        idx = 0
        marker = b"\x1b]9999;"
        while idx < len(chunk):
            pos = chunk.find(marker, idx)
            if pos == -1:
                out.extend(chunk[idx:])
                break
            out.extend(chunk[idx:pos])
            end = chunk.find(b"\x07", pos + len(marker))
            if end == -1:
                out.extend(chunk[pos:])
                break
            payload = chunk[pos + len(marker):end]
            try:
                fd = os.open("/run/henge-hid.fifo", os.O_WRONLY | os.O_NONBLOCK)
                try:
                    os.write(fd, payload + b"\n")
                finally:
                    os.close(fd)
            except OSError:
                pass
            idx = end + 1
        return bytes(out)

    while True:
        rlist, _, _ = select.select([stdin_fd, master_fd], [], [])
        if stdin_fd in rlist:
            data = os.read(stdin_fd, 1024)
            if not data:
                break
            data = forward_hid_escape_to_uinput(data)
            if data and tty1_is_active():
                os.write(master_fd, data)
        if master_fd in rlist:
            try:
                out = os.read(master_fd, 4096)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not out:
                break
            os.write(stdout_fd, out)
            if tty1_is_active():
                os.write(tty1_fd, out)
finally:
    termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_attrs)
    os.close(master_fd)
    os.close(tty1_fd)
    try:
        _, status = os.waitpid(pid, 0)
        sys.exit(os.waitstatus_to_exitcode(status))
    except ChildProcessError:
        sys.exit(0)
PY
elif command -v script >/dev/null 2>&1 && [ -e /dev/tty1 ]; then
    exec script -q -f -c "/sbin/agetty --noclear --autologin root -o '-p -f -- \\u' 115200 - linux" /dev/tty1
else
    exec /sbin/agetty --noclear --autologin root -o '-p -f -- \u' 115200 - linux
fi
EOF
$SUDO chmod 0755 "$MNT_DIR/usr/local/bin/henge-dual-console"

$SUDO tee "$MNT_DIR/etc/systemd/system/henge-pacman-keyring.service" >/dev/null <<'EOF'
[Unit]
Description=Initialize Arch Linux ARM Pacman GPG Keyring
ConditionPathExists=!/etc/pacman.d/gnupg/trustdb.gpg
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/pacman-key --init
ExecStart=/usr/bin/pacman-key --populate archlinuxarm
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
$SUDO ln -sf /etc/systemd/system/henge-pacman-keyring.service \
    "$MNT_DIR/etc/systemd/system/multi-user.target.wants/henge-pacman-keyring.service"

if [ -f "$MNT_DIR/usr/lib/systemd/system/serial-getty@.service" ]; then
    $SUDO ln -sf /usr/lib/systemd/system/serial-getty@.service \
        "$MNT_DIR/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"
fi
$SUDO tee "$MNT_DIR/etc/systemd/system/serial-getty@ttyAMA0.service.d/dual-console.conf" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/local/bin/henge-dual-console
EOF
# Prevent getty@tty1 from competing with henge-dual-console on /dev/tty1
$SUDO ln -sf /dev/null "$MNT_DIR/etc/systemd/system/getty@tty1.service"

for unit in systemd-networkd.service systemd-resolved.service; do
    if [ -f "$MNT_DIR/usr/lib/systemd/system/$unit" ]; then
        $SUDO ln -sf "/usr/lib/systemd/system/$unit" \
            "$MNT_DIR/etc/systemd/system/multi-user.target.wants/$unit"
    fi
done

sync
if command -v fstrim >/dev/null 2>&1; then
    $SUDO fstrim "$MNT_DIR" >/dev/null 2>&1 || true
fi
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

if [ "$VERIFY_BOOT" = "1" ] && command -v qemu-system-aarch64 >/dev/null 2>&1; then
    echo "[prebuilt] Running headless QEMU AArch64 UEFI -> Linux kernel boot smoke test..."
    VERIFY_DISK="$WORK_DIR/verify.img"
    VERIFY_VARS="$WORK_DIR/verify_vars.fd"
    VERIFY_LOG="$WORK_DIR/verify_serial.log"
    cp --reflink=auto "$DISK_IMG" "$VERIFY_DISK"
    cp "$OUT_DIR/vars.fd" "$VERIFY_VARS"
    rm -f "$VERIFY_LOG"

    ACCEL_OPT="-accel tcg"
    if [ -w /dev/kvm ] && [ "$(uname -m)" = "aarch64" ]; then
        ACCEL_OPT="-accel kvm"
    fi

    # Match HengeVM GPEX PCIe slots (slot 01:0 virtio-net, slot 02:0 nvme0) so
    # EDK2 writes the exact PCIe device path into Boot0000 inside vars.fd.
    timeout 45s qemu-system-aarch64 \
        -machine virt,gic-version=3,acpi=on $ACCEL_OPT \
        -cpu cortex-a76 \
        -smp 2 \
        -m 1024 \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0,bus=pcie.0,addr=0x1 \
        -display none \
        -no-reboot \
        -drive if=pflash,format=raw,readonly=on,file="$OUT_DIR/code.fd" \
        -drive if=pflash,format=raw,file="$VERIFY_VARS" \
        -drive if=none,id=nvme0,format=raw,file="$VERIFY_DISK" \
        -device nvme,drive=nvme0,serial=WIN11IOS01,bus=pcie.0,addr=0x2 \
        -serial file:"$VERIFY_LOG" || true

    echo "[prebuilt] Captured QEMU UEFI/kernel serial output:"
    tr -d '\r' < "$VERIFY_LOG" | head -n 120 || true
    if ! grep -Eq "Booting Linux on physical CPU|EFI stub:" "$VERIFY_LOG"; then
        echo "[prebuilt] ERROR: QEMU boot smoke test did not reach Linux kernel entry!" >&2
        rm -f "$VERIFY_DISK" "$VERIFY_VARS" "$VERIFY_LOG"
        exit 1
    fi
    cp "$VERIFY_VARS" "$OUT_DIR/vars.fd"
    rm -f "$VERIFY_DISK" "$VERIFY_VARS" "$VERIFY_LOG"
    echo "[prebuilt] Verified UEFI -> BOOTAA64.EFI -> Linux kernel serial boot and saved initialized vars.fd!"
fi

echo "[prebuilt] Packing $DISK_IMG -> $OUT_DIR/archlinux.hvsparse"
TMP_HVSPARSE="$OUT_DIR/archlinux.hvsparse.tmp"
rm -f "$TMP_HVSPARSE"
"$HVSPARSE_BIN" pack "$DISK_IMG" "$TMP_HVSPARSE"
rm -f "$DISK_IMG"

SPARSE_BYTES="$(wc -c < "$TMP_HVSPARSE" | tr -d '[:space:]')"
if [ "$SPARSE_BYTES" -ge "$MAX_HVSPARSE_BYTES" ]; then
    rm -f "$TMP_HVSPARSE"
    echo "[prebuilt] ERROR: archlinux.hvsparse is ${SPARSE_BYTES} bytes (exceeds ${MAX_HVSPARSE_BYTES}-byte limit for GitHub Releases)." >&2
    exit 1
fi
mv -f "$TMP_HVSPARSE" "$OUT_DIR/archlinux.hvsparse"

(
    cd "$OUT_DIR"
    sha256sum code.fd vars.fd archlinux.hvsparse > SHA256SUMS.txt
)

ls -lh "$OUT_DIR/code.fd" "$OUT_DIR/vars.fd" "$OUT_DIR/archlinux.hvsparse" "$OUT_DIR/SHA256SUMS.txt"
echo "[prebuilt] Pre-built Arch Linux ARM64 guest bundle ready in $OUT_DIR"
