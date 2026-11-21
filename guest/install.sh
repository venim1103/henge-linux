#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# HengeLinux Portable POSIX Guest Additions Installer
#
# Works on any ARM64 Linux distribution (Arch, Debian, Ubuntu, Fedora, Alpine,
# openSUSE, Void, NixOS, etc.) without bash or python3 dependencies.
#
# Offline installation inside any HengeLinux VM:
#   curl -fsSL http://10.0.2.4/.henge/guest-tools/install.sh | sudo sh

set -eu

GATEWAY="${HENGE_GATEWAY:-10.0.2.4}"
PREFIX="${HENGE_PREFIX:-/usr/local}"
DRY_RUN=0
SKIP_NETWORK=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run|--check)
            DRY_RUN=1
            ;;
        --no-network)
            SKIP_NETWORK=1
            ;;
        --gateway)
            shift
            GATEWAY="${1:-10.0.2.4}"
            ;;
        --prefix)
            shift
            PREFIX="${1:-/usr/local}"
            ;;
        -h|--help)
            printf 'Usage: %s [--dry-run] [--no-network] [--gateway IP] [--prefix DIR]\n' "$0"
            exit 0
            ;;
        *)
            printf '[henge-install] Unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

detect_init_system() {
    if [ -d /run/systemd/system ] || [ -d /usr/lib/systemd/system ] || [ -d /lib/systemd/system ]; then
        printf 'systemd'
    elif [ -x /sbin/openrc ] || [ -d /etc/runlevels ]; then
        printf 'openrc'
    elif [ -d /etc/sv ] || [ -d /etc/runit ]; then
        printf 'runit'
    else
        printf 'unknown'
    fi
}

has_existing_network_manager() {
    if command -v NetworkManager >/dev/null 2>&1 || [ -d /etc/NetworkManager/system-connections ]; then
        return 0
    fi
    if [ -d /etc/netplan ] && ls /etc/netplan/*.yaml >/dev/null 2>&1; then
        return 0
    fi
    if [ -f /etc/network/interfaces ] && grep -q 'iface ' /etc/network/interfaces 2>/dev/null; then
        return 0
    fi
    if [ -d /etc/systemd/network ] && ls /etc/systemd/network/*.network >/dev/null 2>&1; then
        return 0
    fi
    if command -v dhcpcd >/dev/null 2>&1 || command -v connmand >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

fetch_file() {
    url="$1"
    dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 5 "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 5 -O "$dest" "$url"
    else
        return 1
    fi
}

detect_distro() {
    if [ -r /etc/os-release ]; then
        awk -F= '/^ID=/{gsub(/"/, "", $2); print tolower($2); exit}' /etc/os-release 2>/dev/null || printf 'unknown'
    else
        printf 'unknown'
    fi
}

INIT_SYS="$(detect_init_system)"
DISTRO_ID="$(detect_distro)"
HAS_DRM=0
if [ -e /dev/dri/card0 ]; then
    HAS_DRM=1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[henge-install] Dry-run summary:\n'
    printf '  GATEWAY      = %s\n' "$GATEWAY"
    printf '  PREFIX       = %s\n' "$PREFIX"
    printf '  DISTRO       = %s\n' "$DISTRO_ID"
    printf '  INIT_SYSTEM  = %s\n' "$INIT_SYS"
    printf '  DRM_CARD0    = %s\n' "$HAS_DRM"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    printf '[henge-install] Please run as root (e.g. sudo sh).\n' >&2
    exit 1
fi

SCRIPT_DIR=""
if [ -f "$0" ]; then
    SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
fi

BIN_DIR="$PREFIX/bin"
mkdir -p "$BIN_DIR" /etc/profile.d "$PREFIX/share/applications" /mnt/ios-share

AGENT_DST="$BIN_DIR/henge-guest-agent"
INSTALLED_AGENT=0
TMP_DIR="$(mktemp -d /tmp/henge-install.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# 1. Install henge-guest-agent (prefer local/prebuilt binary, then compile C source, then script fallback)
if [ -n "$SCRIPT_DIR" ] && [ -x "$SCRIPT_DIR/henge-guest-agent" ]; then
    cp "$SCRIPT_DIR/henge-guest-agent" "$AGENT_DST"
    chmod 0755 "$AGENT_DST"
    INSTALLED_AGENT=1
elif fetch_file "http://${GATEWAY}/.henge/guest-tools/henge-guest-agent" "$TMP_DIR/henge-guest-agent" 2>/dev/null && [ -s "$TMP_DIR/henge-guest-agent" ]; then
    cp "$TMP_DIR/henge-guest-agent" "$AGENT_DST"
    chmod 0755 "$AGENT_DST"
    INSTALLED_AGENT=1
else
    SRC_C=""
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/henge_guest_agent.c" ]; then
        SRC_C="$SCRIPT_DIR/henge_guest_agent.c"
    elif fetch_file "http://${GATEWAY}/.henge/guest-tools/henge_guest_agent.c" "$TMP_DIR/henge_guest_agent.c" 2>/dev/null && [ -s "$TMP_DIR/henge_guest_agent.c" ]; then
        SRC_C="$TMP_DIR/henge_guest_agent.c"
    fi

    if [ -n "$SRC_C" ]; then
        CC_BIN=""
        if command -v cc >/dev/null 2>&1; then
            CC_BIN="cc"
        elif command -v gcc >/dev/null 2>&1; then
            CC_BIN="gcc"
        elif command -v clang >/dev/null 2>&1; then
            CC_BIN="clang"
        fi
        if [ -n "$CC_BIN" ] && "$CC_BIN" -O2 -Wall "$SRC_C" -o "$TMP_DIR/henge-guest-agent" 2>/dev/null; then
            cp "$TMP_DIR/henge-guest-agent" "$AGENT_DST"
            chmod 0755 "$AGENT_DST"
            INSTALLED_AGENT=1
        fi
    fi
fi

if [ "$INSTALLED_AGENT" -eq 1 ]; then
    ln -sf "$AGENT_DST" "$BIN_DIR/henge-xdg-open"
    ln -sf "$AGENT_DST" "$BIN_DIR/henge-dual-console"
    ln -sf "$AGENT_DST" "$BIN_DIR/henge-clipboard"
    printf '[henge-install] Installed unified henge-guest-agent at %s\n' "$AGENT_DST"
else
    # Fallback: install Python henge-xdg-open script if available
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/henge-xdg-open" ]; then
        cp "$SCRIPT_DIR/henge-xdg-open" "$BIN_DIR/henge-xdg-open"
        chmod 0755 "$BIN_DIR/henge-xdg-open"
    elif fetch_file "http://${GATEWAY}/.henge/guest-tools/henge-xdg-open" "$TMP_DIR/henge-xdg-open" 2>/dev/null; then
        cp "$TMP_DIR/henge-xdg-open" "$BIN_DIR/henge-xdg-open"
        chmod 0755 "$BIN_DIR/henge-xdg-open"
    else
        printf '[henge-install] Warning: could not install henge-guest-agent or henge-xdg-open.\n' >&2
    fi
fi

# 2. Provide xdg-open symlink ONLY when /usr/bin/xdg-open is absent (never shadow it)
if [ -L "$BIN_DIR/xdg-open" ] && [ -e /usr/bin/xdg-open ]; then
    rm -f "$BIN_DIR/xdg-open"
fi
if [ ! -e /usr/bin/xdg-open ] && [ ! -e "$BIN_DIR/xdg-open" ] && [ -x "$BIN_DIR/henge-xdg-open" ]; then
    ln -sf "$BIN_DIR/henge-xdg-open" "$BIN_DIR/xdg-open"
fi

# 3. Export $BROWSER and register XDG desktop entry for SafariSheet OAuth/Passkeys
cat <<EOF > /etc/profile.d/henge-safari-bridge.sh
# Route CLI OAuth helpers (gh, gcloud, git web--browse) to iOS SafariSheetView.
if [ -z "\${BROWSER:-}" ]; then
    export BROWSER="${BIN_DIR}/henge-xdg-open"
fi
EOF
chmod 0644 /etc/profile.d/henge-safari-bridge.sh

cat <<EOF > "$PREFIX/share/applications/henge-safari-bridge.desktop"
[Desktop Entry]
Type=Application
Name=iOS Safari Bridge
Exec=${BIN_DIR}/henge-xdg-open %u
Terminal=false
NoDisplay=true
MimeType=x-scheme-handler/http;x-scheme-handler/https;
EOF

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$PREFIX/share/applications" >/dev/null 2>&1 || true
fi

# 4. Preserve existing network managers; only add fallback DHCP config when none exists
if [ "$SKIP_NETWORK" -eq 0 ]; then
    if has_existing_network_manager; then
        printf '[henge-install] Existing network manager detected; preserving distro network config.\n'
    elif [ "$INIT_SYS" = "systemd" ]; then
        mkdir -p /etc/systemd/network
        cat <<'EOF' > /etc/systemd/network/20-henge-virtio.network
[Match]
Driver=virtio_net

[Network]
DHCP=yes
DNS=10.0.2.3
EOF
        systemctl enable systemd-networkd systemd-resolved >/dev/null 2>&1 || true
        printf '[henge-install] Configured fallback systemd-networkd DHCP on virtio_net.\n'
    elif [ "$INIT_SYS" = "openrc" ] && [ -d /etc/network ]; then
        cat <<'EOF' > /etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
        rc-update add networking boot >/dev/null 2>&1 || true
        printf '[henge-install] Configured fallback OpenRC DHCP on eth0.\n'
    elif [ "$INIT_SYS" = "runit" ] && [ -d /etc/sv/dhcpcd ]; then
        ln -sf /etc/sv/dhcpcd /var/service/dhcpcd 2>/dev/null || true
        printf '[henge-install] Enabled runit dhcpcd service.\n'
    fi
fi

# 5. Load uinput module on boot (for OSC 9999 fallback when virtio-input is disabled)
if [ -d /etc/modules-load.d ] || [ "$INIT_SYS" = "systemd" ]; then
    mkdir -p /etc/modules-load.d
    printf 'uinput\n' > /etc/modules-load.d/henge-uinput.conf
elif [ "$INIT_SYS" = "openrc" ] && [ -f /etc/modules ]; then
    grep -qx 'uinput' /etc/modules 2>/dev/null || printf 'uinput\n' >> /etc/modules
fi

# 6. Install idempotent henge-grow-root helper for automatic root partition/FS expansion
SBIN_DIR="$PREFIX/sbin"
mkdir -p "$SBIN_DIR"
cat <<'EOF' > "$SBIN_DIR/henge-grow-root"
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Automatically grow the root GPT partition and filesystem when the host
# expands the virtual NVMe/VirtIO disk image (idempotent; no-op if already grown).
set -eu

ROOT_DEV=""
if command -v findmnt >/dev/null 2>&1; then
    ROOT_DEV="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
fi
if [ -z "$ROOT_DEV" ]; then
    ROOT_DEV="$(awk '$2 == "/" && $1 ~ /^\/dev\// { print $1; exit }' /proc/mounts 2>/dev/null || true)"
fi
case "$ROOT_DEV" in
    /dev/*) ;;
    *) exit 0 ;;
esac

ROOT_REAL="$(readlink -f "$ROOT_DEV" 2>/dev/null || printf '%s' "$ROOT_DEV")"
PART_NAME="${ROOT_REAL#/dev/}"
DISK_NAME=""
PART_NUM=""
case "$PART_NAME" in
    nvme*p[0-9]*|mmcblk*p[0-9]*|loop*p[0-9]*)
        DISK_NAME="${PART_NAME%p*}"
        PART_NUM="${PART_NAME##*p}"
        ;;
    [a-z]*[0-9]*)
        DISK_NAME="$(printf '%s' "$PART_NAME" | sed 's/[0-9]*$//')"
        PART_NUM="$(printf '%s' "$PART_NAME" | sed 's/^[^0-9]*//')"
        ;;
    *)
        exit 0
        ;;
esac

[ -n "$DISK_NAME" ] && [ -n "$PART_NUM" ] || exit 0
DISK_DEV="/dev/$DISK_NAME"
SYS_DISK="/sys/class/block/$DISK_NAME"
SYS_PART="/sys/class/block/$PART_NAME"
[ -r "$SYS_DISK/size" ] && [ -r "$SYS_PART/start" ] && [ -r "$SYS_PART/size" ] || exit 0

DISK_SECTORS="$(cat "$SYS_DISK/size")"
PART_START="$(cat "$SYS_PART/start")"
PART_SIZE="$(cat "$SYS_PART/size")"
PART_END=$((PART_START + PART_SIZE))

if [ $((DISK_SECTORS - PART_END)) -le 32768 ]; then
    exit 0
fi

if command -v growpart >/dev/null 2>&1; then
    growpart "$DISK_DEV" "$PART_NUM" || true
elif command -v sfdisk >/dev/null 2>&1; then
    printf ', +\n' | sfdisk --no-reread -N "$PART_NUM" --force "$DISK_DEV" >/dev/null 2>&1 || true
    if command -v partx >/dev/null 2>&1; then
        partx -u "$DISK_DEV" 2>/dev/null || true
    elif command -v partprobe >/dev/null 2>&1; then
        partprobe "$DISK_DEV" 2>/dev/null || true
    fi
fi

FS_TYPE=""
if command -v blkid >/dev/null 2>&1; then
    FS_TYPE="$(blkid -o value -s TYPE "$ROOT_REAL" 2>/dev/null || true)"
fi
if [ -z "$FS_TYPE" ]; then
    FS_TYPE="$(awk '$2 == "/" { print $3; exit }' /proc/mounts 2>/dev/null || true)"
fi

case "$FS_TYPE" in
    ext2|ext3|ext4)
        command -v resize2fs >/dev/null 2>&1 && resize2fs "$ROOT_REAL"
        ;;
    xfs)
        command -v xfs_growfs >/dev/null 2>&1 && xfs_growfs /
        ;;
    btrfs)
        command -v btrfs >/dev/null 2>&1 && btrfs filesystem resize max /
        ;;
esac
EOF
chmod 0755 "$SBIN_DIR/henge-grow-root"
if [ "$INIT_SYS" = "systemd" ]; then
    mkdir -p /etc/systemd/system/multi-user.target.wants
    cat <<EOF > /etc/systemd/system/henge-grow-root.service
[Unit]
Description=HengeLinux Automatic Root Partition & Filesystem Expansion
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=${SBIN_DIR}/henge-grow-root
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/henge-grow-root.service /etc/systemd/system/multi-user.target.wants/henge-grow-root.service
    printf '[henge-install] Installed systemd henge-grow-root.service.\n'
elif [ "$INIT_SYS" = "openrc" ] && [ -d /etc/local.d ]; then
    cat <<EOF > /etc/local.d/henge-grow-root.start
#!/bin/sh
exec ${SBIN_DIR}/henge-grow-root
EOF
    chmod 0755 /etc/local.d/henge-grow-root.start
    rc-update add local default >/dev/null 2>&1 || true
    printf '[henge-install] Installed OpenRC henge-grow-root.start.\n'
fi

# 7. Upgrade invoking user's shell from dash/sh to /bin/bash when available (fixes arrow keys & history)
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ -x /bin/bash ]; then
    CURR_SHELL="$(awk -F: -v u="$SUDO_USER" '$1 == u { print $7; exit }' /etc/passwd 2>/dev/null || true)"
    case "$CURR_SHELL" in
        /bin/sh|/bin/dash|/usr/bin/dash|"")
            if command -v chsh >/dev/null 2>&1; then
                chsh -s /bin/bash "$SUDO_USER" >/dev/null 2>&1 || true
            elif command -v usermod >/dev/null 2>&1; then
                usermod -s /bin/bash "$SUDO_USER" >/dev/null 2>&1 || true
            fi
            printf '[henge-install] Switched login shell for %s to /bin/bash.\n' "$SUDO_USER"
            ;;
    esac
fi

# 8. Trim heavy Ubuntu cloud background daemons that compete for emulated CPU
if [ "$DISTRO_ID" = "ubuntu" ] && [ "$INIT_SYS" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now \
        snapd.service snapd.socket snapd.seeded.service \
        unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer \
        multipathd.service multipathd.socket ModemManager.service >/dev/null 2>&1 || true
    printf '[henge-install] Disabled heavy Ubuntu cloud background daemons.\n'
fi

# 9. Install distro-aware henge-install-desktop helper (one-command LXQt + SDDM setup)
cat <<'EOF' > "$BIN_DIR/henge-install-desktop"
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Install lightweight LXQt + Openbox + SDDM desktop across supported ARM64 distros.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run with sudo: sudo henge-install-desktop\n' >&2
    exit 1
fi

DISTRO="unknown"
if [ -r /etc/os-release ]; then
    DISTRO="$(awk -F= '/^ID=/{gsub(/"/, "", $2); print tolower($2); exit}' /etc/os-release 2>/dev/null || printf 'unknown')"
fi
printf '[henge-desktop] Detected distro: %s\n' "$DISTRO"

if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        lxqt-core openbox sddm xorg xserver-xorg-video-fbdev qterminal pcmanfm-qt \
        lxqt-themes breeze-icon-theme dbus-x11 scrot
    if [ "$DISTRO" = "ubuntu" ]; then
        apt-get install -y --no-install-recommends "linux-modules-extra-$(uname -r)" 2>/dev/null || true
    fi
    systemctl set-default graphical.target >/dev/null 2>&1 || true
    systemctl enable sddm >/dev/null 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y --setopt=install_weak_deps=False \
        lxqt-session lxqt-panel lxqt-runner lxqt-config lxqt-themes openbox \
        sddm qterminal pcmanfm-qt xorg-x11-server-Xorg xorg-x11-drv-fbdev dbus-x11
    systemctl set-default graphical.target >/dev/null 2>&1 || true
    systemctl enable sddm >/dev/null 2>&1 || true
elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install --no-recommends \
        lxqt-session lxqt-panel lxqt-config openbox sddm qterminal pcmanfm-qt \
        xorg-x11-server xf86-video-fbdev
    systemctl set-default graphical.target >/dev/null 2>&1 || true
    systemctl enable sddm >/dev/null 2>&1 || true
elif command -v apk >/dev/null 2>&1; then
    apk update
    apk add xorg-server xf86-video-fbdev xf86-input-libinput eudev mesa-dri-gallium \
        lxqt-desktop openbox qterminal pcmanfm-qt sddm dbus-x11 font-dejavu
    setup-devd udev >/dev/null 2>&1 || true
    rc-update add dbus default >/dev/null 2>&1 || true
    rc-update add sddm default >/dev/null 2>&1 || true
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed \
        xorg-server xf86-video-fbdev lxqt openbox sddm qterminal pcmanfm-qt breeze-icons
    systemctl set-default graphical.target >/dev/null 2>&1 || true
    systemctl enable sddm >/dev/null 2>&1 || true
elif command -v xbps-install >/dev/null 2>&1; then
    xbps-install -Sy xorg-minimal xf86-video-fbdev lxqt openbox sddm qterminal pcmanfm-qt dbus
    ln -sf /etc/sv/dbus /var/service/dbus 2>/dev/null || true
    ln -sf /etc/sv/sddm /var/service/sddm 2>/dev/null || true
else
    printf '[henge-desktop] Unsupported package manager on %s.\n' "$DISTRO" >&2
    exit 1
fi

if [ -e /dev/dri/card0 ]; then
    rm -f /etc/X11/xorg.conf.d/10-fbdev.conf
    printf '[henge-desktop] /dev/dri/card0 detected; using native KMS modesetting.\n'
else
    mkdir -p /etc/X11/xorg.conf.d
    cat <<'XEOF' > /etc/X11/xorg.conf.d/10-fbdev.conf
Section "Device"
    Identifier "EFIFB"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
EndSection
XEOF
    printf '[henge-desktop] Configured /etc/X11/xorg.conf.d/10-fbdev.conf for UEFI GOP.\n'
fi

printf '[henge-desktop] LXQt installed! Reboot now with: sudo reboot\n'
EOF
chmod 0755 "$BIN_DIR/henge-install-desktop"

# 10. Install boot-time Xorg GPU auto-selector so switching between 2D UEFI GOP
#     and VirtIO-GPU KMS never leaves a stale 10-fbdev.conf causing a black screen
cat <<'EOF' > "$SBIN_DIR/henge-xorg-autodetect"
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Keep /etc/X11/xorg.conf.d/10-fbdev.conf synchronized with /dev/dri/card0.
set -eu
[ -d /etc/X11 ] || exit 0
if [ -e /dev/dri/card0 ]; then
    rm -f /etc/X11/xorg.conf.d/10-fbdev.conf
elif [ -e /dev/fb0 ]; then
    mkdir -p /etc/X11/xorg.conf.d
    cat <<'XEOF' > /etc/X11/xorg.conf.d/10-fbdev.conf
Section "Device"
    Identifier "EFIFB"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
EndSection
XEOF
fi
EOF
chmod 0755 "$SBIN_DIR/henge-xorg-autodetect"
"$SBIN_DIR/henge-xorg-autodetect" || true

if [ "$INIT_SYS" = "systemd" ]; then
    mkdir -p /etc/systemd/system/multi-user.target.wants
    cat <<EOF > /etc/systemd/system/henge-xorg-autodetect.service
[Unit]
Description=HengeLinux Xorg GPU Backend Auto-Detector
After=systemd-udev-settle.service local-fs.target
Before=display-manager.service sddm.service lightdm.service gdm.service

[Service]
Type=oneshot
ExecStart=${SBIN_DIR}/henge-xorg-autodetect
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/henge-xorg-autodetect.service /etc/systemd/system/multi-user.target.wants/henge-xorg-autodetect.service
    printf '[henge-install] Installed systemd henge-xorg-autodetect.service.\n'
elif [ "$INIT_SYS" = "openrc" ] && [ -d /etc/local.d ]; then
    cat <<EOF > /etc/local.d/henge-xorg-autodetect.start
#!/bin/sh
exec ${SBIN_DIR}/henge-xorg-autodetect
EOF
    chmod 0755 /etc/local.d/henge-xorg-autodetect.start
    rc-update add local default >/dev/null 2>&1 || true
    printf '[henge-install] Installed OpenRC henge-xorg-autodetect.start.\n'
fi

printf '[henge-install] Done (distro=%s, init=%s). Install LXQt anytime with: sudo henge-install-desktop\n' "$DISTRO_ID" "$INIT_SYS"
printf '  Mount iOS Shared folder anytime with:\n'
printf '  rclone mount :webdav: /mnt/ios-share --webdav-url http://%s/ --webdav-vendor other --daemon\n' "$GATEWAY"
