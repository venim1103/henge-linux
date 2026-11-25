# HengeLinux (`v0.3.0`) Setup & Sideloading Guide

This guide walks through installing **`HengeLinux` `v0.3.0`** on a non-jailbroken iPhone or iPad (**iOS 18.0 – iOS 27+**), downloading or importing ARM64 Linux distributions, enabling JIT with **StikDebug** + **LocalDevVPN**, configuring **VirGL 3D Metal (ANGLE)** or **2D VirtIO-GPU KMS**, installing an **LXQt Wayland or X11** graphical desktop, and using **USB-C / HDMI External Displays**, hardware keyboards/mice, and the **Safari OAuth / WebDAV** guest bridge.

---

## Overview: What You Need

| File | Required | Where to Download | Purpose |
| :--- | :--- | :--- | :--- |
| **`HengeLinux-unsigned.ipa`** | **Yes** | [Releases (`v0.3.0`)](https://github.com/venim1103/henge-linux/releases) *(or [Nightly (`latest-ipa`)](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/HengeLinux-unsigned.ipa))* | iOS `18.0+` app (`HengeLinux.app`) + embedded JIT helper extension (`HengeLinuxJITExtension.appex`) + static `ANGLE` / `libepoxy` / `libvirglrenderer` 3D GPU stack |
| **`code.fd` & `vars.fd`** | **Yes** *(One-Time)* | In-app (**Machines → Download Distros & Firmware**) or [Releases](https://github.com/venim1103/henge-linux/releases) | 64 MiB TianoCore EDK2 AArch64 UEFI firmware + NVRAM template (automatically shared in `Documents/Firmware/` across all VMs) |
| **Linux Disk / Cloud / ISO Image** | **Yes** | In-app **Distro & Firmware Gallery**, [`archlinux.hvsparse`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/archlinux.hvsparse), or any official ARM64 `.qcow2` / `.img` / `.iso` | Pre-built Arch Linux image (~294 MiB) or any unmodified official ARM64 Linux cloud image or Live/Netinstall ISO |
| **`henge-jit.js`** | **Optional** *(iOS 26+ TXM)* | [`ios/Resources/henge-jit.js`](https://raw.githubusercontent.com/venim1103/henge-linux/main/ios/Resources/henge-jit.js) | Optional custom GDB RSP script for iOS 26/27+ TXM (stock StikDebug `universal.js` works out of the box; iOS 18 needs no script) |
| **`pairing.plist`** | **Optional** | Exported via `idevicepair` / `idevice_pair` | Lockdown pairing record for embedded `HengeLinuxJITExtension` XPC self-debugging |

---

## Step 1: Install `HengeLinux` via SideStore or AltStore

1. On your iPhone or iPad, download `HengeLinux-unsigned.ipa` from [Releases](https://github.com/venim1103/henge-linux/releases) (recommended) or the rolling [Nightly (`latest-ipa`)](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa) build.
2. Open **SideStore** (or **AltStore**), tap **`+`**, and select `HengeLinux-unsigned.ipa`.
3. Sign and install the app with your Apple ID.
   - *Free Apple ID note:* SideStore/AltStore strips `com.apple.developer.kernel.increased-memory-limit` and rewrites App Group prefixes on free Apple IDs. HengeLinux handles this automatically and displays live Jetsam headroom in the **Hardware** tab.
4. Launch **HengeLinux** once so it initializes `Documents/Machines/`, `Documents/Firmware/`, and `Documents/Shared/`.
   - *Tip:* Open the **Information** tab anytime to verify your installed version, release/nightly channel, short Git commit hash, build date, linked engine status, and **Boot & Serial Logs**.

---

## Step 2: Create a VM & Download or Import Linux Images

HengeLinux organizes the launcher into four dedicated tabs: **Machines**, **Hardware**, **Images & Disks**, and **Information**.

### Option A: In-App Distro & Firmware Gallery (Fastest)
1. Open the **Machines** tab and tap **Download Distros & Firmware**.
2. Tap **Download UEFI Firmware (~128 MiB)** once — `EDK2 Firmware` turns green (`Installed (Ready · Shared)`) and is shared across every VM.
3. Choose any supported ARM64 image (**Arch Linux**, **Debian 13**, **Ubuntu 24.04 / 26.04 LTS**, **Alpine 3.23**, **Fedora 43**, **openSUSE Tumbleweed**) or enter a custom `.qcow2` / `.hvsparse` / `.img` / `.iso` URL. Cloud images are automatically provisioned with an offline `CIDATA` seed.

### Option B: Import Local Disks, Cloud QCOW2s, or Live ISOs
1. In the **Machines** tab, select an existing VM or tap **New ARM64 Linux VM**.
2. Switch to the **Images & Disks** tab and tap **Import Disk, ISO, or Firmware**:
   - **Pre-Built Arch Linux (`.hvsparse`):** Imports and unpacks automatically into an APFS sparse disk on first boot.
   - **Official Cloud Images (`.qcow2` / `.img`):** Auto-detected by magic bytes (supporting both `zlib` and `zstd`-compressed QCOW2 v2/v3 clusters) and unpacked in the background. Tap **Generate Cloud-Init CIDATA Seed** to configure your hostname, username, and password.
   - **Standard ARM64 Live / Netinstall ISOs (`.iso`):** Create a **Blank Disk + ARM64 Live ISO** VM, import the `.iso` (attached as secondary read-only `virtio-blk` media with automatic `2048B` El Torito or `512B` isohybrid sector sizing), install Linux onto `/dev/nvme0n1`, and tap **Eject** on Secondary Media afterward.
3. **Storage & VM Management:**
   - **Expand Virtual Disk** (**Images & Disks** tab): Grows APFS sparse disks up to `128 GiB` instantly (`henge-grow-root` or `cloud-init` expands the partition & filesystem on next boot).
   - **Compact Sparse Disk** (**Images & Disks** tab): Reclaims zeroed blocks via APFS `F_PUNCHHOLE`.
   - **Duplicate / Delete VM** (**Machines** tab): **Press and hold** any machine to **Duplicate Machine (Clone)** via zero-copy APFS Copy-on-Write, or **swipe left** on custom machines to delete.
   - **Raw File Access:** Browse `Documents/Machines/`, `Documents/Firmware/`, and `Documents/Shared/` directly in the iOS **Files** app under **On My iPhone ▸ HengeLinux**.

---

## Step 3: Enable JIT (iOS 18.0 – iOS 27+) with StikDebug & LocalDevVPN

HengeLinux automatically detects your iOS version and picks the right JIT backend (overrideable under **Hardware → Virtual Devices & Engine → JIT Strategy**):

1. Turn on **LocalDevVPN** in iOS Settings or the LocalDevVPN app.
2. Open the **Machines** tab and tap **Enable JIT via StikDebug** (`stikdebug://enable-jit`).
   - **iOS 18:** Activates `Classic Dual-Map` JIT (`CS_DEBUGGED` + `vm_remap` + `vm_protect(RX)`) with no custom script required; survives VM stop/reboot without re-attaching.
   - **iOS 26/27+ (TXM):** Works out of the box with stock StikDebug `universal.js`. Optionally save [`ios/Resources/henge-jit.js`](https://raw.githubusercontent.com/venim1103/henge-linux/main/ios/Resources/henge-jit.js) into **Files ▸ On My iPhone ▸ StikDebug** and **long-press `HengeLinux` → Assign Script → `henge-jit.js`**.
   - **LiveContainer:** Detected automatically via `LC_HOME_PATH` and routed straight to StikDebug.
3. Once active, **JIT Status** turns green (`Blessed (384 MiB)`).
4. *(Optional)* Tap **Import Pairing File (.plist / .mobiledevicepairing)** in the **Machines** tab to store your lockdown pairing record (`Valid` status turns green) for `HengeLinuxJITExtension`:
   - **macOS:** `brew install libimobiledevice && idevicepair pair && cp "/var/db/lockdown/$(idevice_id -l | head -n1).plist" ~/Desktop/pairing.plist`
   - **Linux:** `sudo apt install libimobiledevice-utils && idevicepair pair && sudo cp "/var/lib/lockdown/$(idevice_id -l | head -n1).plist" ~/pairing.plist && sudo chown $USER ~/pairing.plist`
   - **Windows / GUI:** [`idevice_pair`](https://github.com/jkcoxson/idevice_pair).

---

## Step 4: Configure Hardware, VirGL 3D Metal & Boot Linux

Open the **Hardware** tab to tune the selected VM:

1. **Memory & CPU:**
   - Pick a device preset (**iPhone Pro**, **iPhone Duo / 12 GB**, **M-Series iPad Pro**) or adjust **Virtual CPUs** (`1`–`8`) and **Guest RAM** (`512`–`10,240 MiB` via slider, stepper, or `1G` / `1.6G` / `2G` / `2.5G` / `4G` pills — automatically selecting the **Custom** profile when customized).
   - Check the stacked **Jetsam Memory Breakdown Bar** (Guest RAM + JIT Pool + GPU Reserve + Free Margin against live `os_proc_available_memory()`).
2. **Display Adapter:**
   - **3D VirtIO-GPU VirGL (ANGLE Metal):** Hardware-accelerated OpenGL ES 3.0 / VirGL 3D on Apple Silicon Metal via zero-copy `IOSurfaceRef` + `MTLSharedEvent` swapchains, persistent `64 MiB` Metal shader cache, ES 3.0 sampler wrap sanitization, and automatic 5-frame crash recovery fallback.
   - **2D VirtIO-GPU KMS (EDID + Metal):** Native `/dev/dri/card0` KMS with alpha-blended Metal hardware cursor, dirty-rect partial uploads, and dynamic EDID 1.4 resolutions (`1024×768` portrait / widescreen landscape / up to `4K UHD` external) with minimal RAM overhead.
   - **2D UEFI GOP (Metal):** Universal `simpledrm`/`efifb` framebuffer — ideal for initial Ubuntu Cloud boots before `linux-modules-extra` (`virtio-gpu.ko`) is installed.
3. **GPU Budget, Refresh Rate & External Display:**
   - Set **VRAM Ceiling** (`Auto`, `256`, `512`, or `1,024 MiB`), **Target Refresh Rate** (`30 Hz`, `60 Hz`, or `120 Hz` ProMotion with automatic thermal step-down), **External Resolution** (`Auto`, `720p`, `900p`, `1080p`, `1440p`, `4K UHD`), **Dual Scanout (Extended Mode)**, **OLED Screen Saver Auto-Dim**, and **Clear Metal Shader Cache**.
4. **Virtual Devices:**
   - Defaults to **VirtIO Input = On** (native `/dev/input/event*` keyboard with `EV_REP` autorepeat + absolute tablet), **USB 3.0 xHCI = Off** (avoids legacy xHCI initrd stalls), and **ACPI SPCR Serial Console = On**.
5. Return to **Machines** and tap **Boot**:
   - Switch anytime between **Metal Display** and the native VT100/xterm-256color **`ttyAMA0` Serial Terminal** using the top-left segmented toggle.
   - Tap the **Gauge** icon in the top bar for the **Live Performance HUD Pill** (live FPS, active backend, GPU VRAM, and thermal/Hz state).
   - Tap the **Moon** icon for the pure `#000000` drifting **OLED Screen Saver** (pauses local Metal presentation when no external monitor is connected while keeping the VM and physical keyboard/mouse active).
   - Plug in a **USB-C / HDMI / AirPlay monitor** to render Linux directly on the external display while your iPhone serves as a trackpad/keyboard Control Deck.

---

## Step 5: Installing a Graphical Desktop (Wayland GLES2 or X11 LXQt)

1. **On Any Distro (Arch, Debian, Ubuntu, Fedora, openSUSE, Alpine):**
   ```sh
   (curl -fsSL http://10.0.2.4/.henge/guest-tools/install.sh || wget -qO- http://10.0.2.4/.henge/guest-tools/install.sh) | sudo sh
   sudo henge-install-desktop --wayland   # labwc + LXQt Wayland (GLES2 for VirGL 3D)
   # or:
   sudo henge-install-desktop --x11       # Openbox / Xorg + LXQt + SDDM
   sudo reboot
   ```
   - Automatically installs desktop packages via the distro's native package manager (`pacman`, `apt-get`, `dnf`, `zypper`, `apk`, `xbps`), installs `linux-modules-extra` on Ubuntu for VirtIO-GPU KMS/3D, and enables `henge-xorg-autodetect` so switching between 2D GOP, 2D KMS, and VirGL 3D works cleanly across reboots.
2. **Input in Desktop Mode:**
   - **Touch:** Tap to click, 1-finger press-and-hold/drag to select or move windows, 2-finger tap to right-click, 2-finger scroll, or open the 6×3 **Split Deck** trackpad (docks side-by-side in landscape).
   - **Hardware Keyboard & Mouse:** USB-C and Bluetooth keyboards/mice work immediately via `GCKeyboard`/`GCMouse` (even while the OLED Screen Saver is active).
   - **VT Switching:** Press **`Ctrl` + `Alt` + `F1`** (or `chvt 1`) for the `tty1` console and **`Ctrl` + `Alt` + `F2`** for the graphical session.

---

## Step 6: Networking, Offline Guest Agent & WebDAV Sharing

- **Networking (`libslirp` VirtIO-Net):** Guest IP `10.0.2.15` · Gateway `10.0.2.4` · DNS `10.0.2.3`.
- **Portable Offline Guest Agent:** Installed via `curl -fsSL http://10.0.2.4/.henge/guest-tools/install.sh | sudo sh` (bundles a static `aarch64-linux-musl` `henge-guest-agent` binary directly inside the `.ipa` so minimal guests without `gcc` install immediately).
- **Host ↔ Guest Shared Folder (`Documents/Shared/`):** Place files in **Files ▸ On My iPhone ▸ HengeLinux ▸ Shared/** and mount inside Linux at `http://10.0.2.4/`:
  ```sh
  rclone mount :webdav: /mnt/ios-share --webdav-url http://10.0.2.4/ --webdav-vendor other --daemon
  ```
- **Safari OAuth & Passkey Bridge (`henge-xdg-open`):** CLI OAuth flows (`gh auth login`, `gcloud auth login`, etc.) forward `127.0.0.1` / `[::1]` callbacks through `10.0.2.4/.henge/expose-port`, open an in-app `SFSafariViewController` sheet for Face ID / Passkeys, and auto-dismiss on completion.

---

## Step 7: Building Custom Disk Images (Optional)

### Automated Builder (Linux ARM64)
```bash
make prebuilt-guest-image
# Outputs: build/prebuilt/code.fd, build/prebuilt/vars.fd, build/prebuilt/archlinux.hvsparse
```

### Interactive Archboot QEMU Installer (macOS or Linux)
```bash
# macOS: brew install qemu
# Arch:  sudo pacman -S qemu-system-aarch64 edk2-aarch64
# Debian/Ubuntu: sudo apt install qemu-system-arm qemu-efi-aarch64
make hvsparse
./scripts/provision_archlinux_arm64.sh
```

---

## Troubleshooting

- **3D VirGL Auto-Recovery Banner appears after a crash:**
  - HengeLinux's 5-frame crash sentinel automatically falls the VM back to **2D VirtIO-GPU KMS** if a 3D boot terminates unexpectedly (usually from Jetsam RAM pressure on a free-account standard ledger). Open **Information → View Boot & Serial Logs → Saved Log** to inspect the exact crash tail, lower **Guest RAM** slightly (e.g., `1,664`–`1,792 MiB` on 8 GB iPhones with VirGL 3D), or tap **Clear Metal Shader Cache** in **Hardware**, then tap **Retry VirGL 3D**.
- **Black screen or missing `/dev/dri/card0` on Ubuntu Cloud with 2D KMS / VirGL 3D:**
  - Ubuntu Cloud omits `virtio-gpu.ko` by default. Boot once with **2D UEFI GOP**, run the Guest Tools `install.sh` + `sudo henge-install-desktop` (which installs `linux-modules-extra` and updates initramfs), then switch back to **2D KMS** or **VirGL 3D**.
- **JIT stuck on `Standby` or fails after 15 seconds:**
  - Ensure **LocalDevVPN** is connected, then tap **Enable JIT via StikDebug** in the **Machines** tab. On iOS 26+ TXM, confirm `universal.js` (or `henge-jit.js`) is assigned to `HengeLinux` in StikDebug.
- **Inspecting Engine, VirGL, or Serial Logs:**
  - Tap the **Log** icon during a running session or open **Information → View Boot & Serial Logs** before/after a session. Switch between **All**, **Engine** (ANGLE / VirGL / HengeVM lines), **Guest Serial**, and **Saved Log** (persistent on-disk boot log tail).
