#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Configure an installed Arch Linux AArch64 guest to integrate with henge-linux:
#   - Installs henge-xdg-open as default HTTP/HTTPS browser handler for Safari Passkeys/OAuth
#   - Configures systemd-networkd DHCP on VirtIO-Net (10.0.2.15 / gateway 10.0.2.4)
#   - Adds /mnt/ios-share helper for the 10.0.2.4 WebDAV host share

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "[guest-setup] Please run as root inside the Arch Linux guest (sudo $0)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -Dm755 "$SCRIPT_DIR/henge-xdg-open" /usr/local/bin/henge-xdg-open
ln -sf /usr/local/bin/henge-xdg-open /usr/local/bin/xdg-open

install -d /usr/local/share/applications
cat <<'EOF' > /usr/local/share/applications/henge-safari-bridge.desktop
[Desktop Entry]
Type=Application
Name=iOS Safari Bridge
Exec=/usr/local/bin/henge-xdg-open %u
Terminal=false
NoDisplay=true
MimeType=x-scheme-handler/http;x-scheme-handler/https;
EOF

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/local/share/applications || true
fi

install -d /etc/xdg
cat <<'EOF' > /etc/xdg/mimeapps.list
[Default Applications]
x-scheme-handler/http=henge-safari-bridge.desktop
x-scheme-handler/https=henge-safari-bridge.desktop
EOF

install -d /etc/systemd/network
cat <<'EOF' > /etc/systemd/network/20-henge-virtio.network
[Match]
Driver=virtio_net

[Network]
DHCP=yes
DNS=10.0.2.3
EOF

systemctl enable systemd-networkd systemd-resolved >/dev/null 2>&1 || true

install -d /mnt/ios-share
echo "[guest-setup] Installed henge-xdg-open, VirtIO-Net DHCP config, and /mnt/ios-share."
echo "[guest-setup] Mount iOS files anytime with: rclone mount :webdav: /mnt/ios-share --webdav-url http://10.0.2.4/ --daemon"
