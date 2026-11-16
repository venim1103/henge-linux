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
# Provide /usr/local/bin/xdg-open ONLY when /usr/bin/xdg-open is absent so we never
# shadow /usr/bin/xdg-open in $PATH (which would cause an infinite execv loop).
if [ -L /usr/local/bin/xdg-open ] && [ "$(readlink -f /usr/local/bin/xdg-open)" = "/usr/local/bin/henge-xdg-open" ] && [ -e /usr/bin/xdg-open ]; then
    rm -f /usr/local/bin/xdg-open
fi
if [ ! -e /usr/bin/xdg-open ] && [ ! -e /usr/local/bin/xdg-open ]; then
    ln -sf /usr/local/bin/henge-xdg-open /usr/local/bin/xdg-open
fi

install -d /etc/profile.d
cat <<'EOF' > /etc/profile.d/henge-safari-bridge.sh
# Route CLI OAuth helpers (gh, gcloud, git web--browse) to iOS SafariSheetView.
if [ -z "${BROWSER:-}" ]; then
    export BROWSER="/usr/local/bin/henge-xdg-open"
fi
EOF
chmod 0644 /etc/profile.d/henge-safari-bridge.sh

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
python3 - <<'PY'
from configparser import RawConfigParser
from pathlib import Path

path = Path("/etc/xdg/mimeapps.list")
cfg = RawConfigParser()
cfg.optionxform = str
if path.exists():
    cfg.read(path, encoding="utf-8")
if not cfg.has_section("Default Applications"):
    cfg.add_section("Default Applications")
cfg.set("Default Applications", "x-scheme-handler/http", "henge-safari-bridge.desktop")
cfg.set("Default Applications", "x-scheme-handler/https", "henge-safari-bridge.desktop")
with path.open("w", encoding="utf-8") as fh:
    cfg.write(fh, space_around_delimiters=False)
PY

install -d /etc/systemd/network
cat <<'EOF' > /etc/systemd/network/20-henge-virtio.network
[Match]
Driver=virtio_net

[Network]
DHCP=yes
DNS=10.0.2.3
EOF

systemctl enable systemd-networkd systemd-resolved >/dev/null 2>&1 || true
if [ -e /run/systemd/resolve/stub-resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi

install -d /mnt/ios-share
echo "[guest-setup] Installed henge-xdg-open, VirtIO-Net DHCP config, and /mnt/ios-share."
echo "[guest-setup] Mount iOS files anytime with: rclone mount :webdav: /mnt/ios-share --webdav-url http://10.0.2.4/ --daemon"
