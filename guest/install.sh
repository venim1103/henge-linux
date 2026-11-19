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

INIT_SYS="$(detect_init_system)"
HAS_DRM=0
if [ -e /dev/dri/card0 ]; then
    HAS_DRM=1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[henge-install] Dry-run summary:\n'
    printf '  GATEWAY      = %s\n' "$GATEWAY"
    printf '  PREFIX       = %s\n' "$PREFIX"
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

# 6. Write Xorg 10-fbdev.conf ONLY when /dev/dri/card0 KMS is absent
if [ "$HAS_DRM" -eq 0 ] && [ -d /etc/X11 ]; then
    mkdir -p /etc/X11/xorg.conf.d
    if [ ! -f /etc/X11/xorg.conf.d/10-fbdev.conf ]; then
        cat <<'EOF' > /etc/X11/xorg.conf.d/10-fbdev.conf
Section "Device"
    Identifier "EFIFB"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
EndSection
EOF
        printf '[henge-install] Installed /etc/X11/xorg.conf.d/10-fbdev.conf (no /dev/dri/card0 present).\n'
    fi
else
    printf '[henge-install] Skipping 10-fbdev.conf (/dev/dri/card0 present or X11 absent).\n'
fi

printf '[henge-install] Done (init=%s). Mount iOS Shared folder anytime with:\n' "$INIT_SYS"
printf '  rclone mount :webdav: /mnt/ios-share --webdav-url http://%s/ --webdav-vendor other --daemon\n' "$GATEWAY"
