# `henge-linux` Setup & Sideloading Guide

This guide walks through installing **`HengeLinux`** (`v0.2.1`) on a non-jailbroken iPhone or iPad (**iOS 18.0 – iOS 27+**), importing pre-built Arch Linux or unmodified ARM64 cloud/ISO Linux images, enabling JIT with **StikDebug** + **LocalDevVPN**, and using **2D VirtIO-GPU KMS**, the interactive **`ttyAMA0` terminal**, and the offline **Safari OAuth / WebDAV** guest agent.

---

## Overview: What You Need

To boot ARM64 Linux on iOS, you need the app bundle, shared EDK2 UEFI firmware, and any ARM64 Linux disk image (`.hvsparse`, `.qcow2`, `.img`/`.raw`, or `.iso`):

| File | Required | Where to Download | Purpose |
| :--- | :--- | :--- | :--- |
| **`HengeLinux-unsigned.ipa`** | **Yes** | [Releases](https://github.com/venim1103/henge-linux/releases) *(or [Nightly (`latest-ipa`)](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/HengeLinux-unsigned.ipa))* | Main iOS 18.0+ app (`HengeLinux.app`) + embedded JIT helper extension (`HengeLinuxJITExtension.appex`) |
| **`code.fd` & `vars.fd`** | **Yes** | [Releases](https://github.com/venim1103/henge-linux/releases) *(or [Nightly (`latest-ipa`)](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa))* | 64 MiB TianoCore EDK2 AArch64 UEFI firmware + NVRAM template (automatically shared in `Documents/Firmware/` across all VMs) |
| **Linux Disk / Cloud / ISO Image** | **Yes** | [`archlinux.hvsparse`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/archlinux.hvsparse) or official Debian / Ubuntu / Fedora / Alpine / openSUSE `.qcow2`/`.img`/`.iso` | Pre-built Arch Linux image (~294 MiB) or any unmodified official ARM64 Linux cloud image or Live/Netinstall ISO |
| **`henge-jit.js`** | **Optional** *(iOS 26+ TXM)* | [`ios/Resources/henge-jit.js`](https://raw.githubusercontent.com/venim1103/henge-linux/main/ios/Resources/henge-jit.js) | Optional custom GDB RSP script for iOS 26/27+ TXM (stock StikDebug `universal.js` also works out of the box in `v0.2.0`; iOS 18 needs no script) |
| **`pairing.plist`** | **Optional** | Exported via `idevicepair` / `idevice_pair` | Lockdown pairing record for in-app `HengeLinuxJITExtension` XPC self-debugging |

---

## Step 1: Install `HengeLinux` via SideStore or AltStore

1. On your iPhone or iPad, download `HengeLinux-unsigned.ipa` from [Releases](https://github.com/venim1103/henge-linux/releases) (recommended) or the rolling [Nightly (`latest-ipa`)](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa) build.
2. Open **SideStore** (or **AltStore**), tap **`+`**, and select `HengeLinux-unsigned.ipa` from **Downloads**.
3. Sign and install the app with your Apple ID.
   - *Tip:* If you previously installed an older build of `HengeLinux` before `UIFileSharingEnabled` / `CFBundleDocumentTypes` were added, delete the old app icon first before installing so iOS refreshes its `Files.app` container registration.
   - *Free Apple ID note:* SideStore/AltStore strips `com.apple.developer.kernel.increased-memory-limit` and rewrites the App Group prefix on free Apple IDs (`HengeLinux` handles this automatically via `CS_DEBUGGED` + `LEDGER_NO_FOOTPRINT` and dynamic bundle ID derivation).
4. Launch **HengeLinux** once so it initializes `Documents/Machines/ArchLinux/` and `Documents/Shared/`.

---

## Step 2: Create a VM & Import Guest Files (Arch, Cloud QCOW2, or Live ISO)

HengeLinux `v0.2.0` supports multiple isolated VMs in `Documents/Machines/<ID>/vm.json` with shared firmware in `Documents/Firmware/` (existing `v0.1.0` `Documents/Machines/ArchLinux/` installs migrate automatically with zero data loss).

1. **Import Shared UEFI Firmware:**
   - Download `code.fd` and `vars.fd` from [Releases](https://github.com/venim1103/henge-linux/releases) (or [Nightly (`latest-ipa`)](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa)) and import them via **Import Guest Files...** (stored in `Documents/Firmware/` and cloned per VM so NVRAM stays isolated).
2. **Choose One of Three Guest Tracks:**
   - **Track A — Pre-Built Arch Linux:** Download `archlinux.hvsparse` from [Releases](https://github.com/venim1103/henge-linux/releases) (or [Nightly (`latest-ipa`)](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa)) and import it into the default **Arch Linux** VM.
   - **Track B — Official ARM64 Cloud Images (Debian 13 `generic`, Ubuntu 24.04/26.04 `server-cloudimg`, Fedora Cloud Base, Alpine `nocloud`, openSUSE):**
     - Tap **New ARM64 Linux VM...**, pick your distro preset, and import the official `.qcow2` or `.img` file (detected automatically by magic bytes and unpacked in the background into an APFS sparse disk on first boot).
     - Tap **Generate Cloud-Init Seed (`CIDATA`)...** to create a 2 MiB FAT16 `seed.img` with your hostname, username, password, and SSH key attached as secondary read-only `virtio-blk` media (`disk1`).
   - **Track C — Standard ARM64 Live / Netinstall ISO:**
     - Create a **Blank Disk + ARM64 Live ISO** VM (allocates an empty APFS sparse `disk0.img`), import any ARM64 `.iso` (attached to `disk1`), install Linux onto `/dev/nvme0n1`, and tap **Eject** on Secondary Media after installation.
3. **Storage Management:**
   - Use **Clone VM (APFS)** for instant copy-on-write snapshots and **Compact Disk** (`F_PUNCHHOLE`) to reclaim zeroed blocks.

---

## Step 3: Enable JIT (iOS 18.0 – iOS 27+) with StikDebug & LocalDevVPN

HengeLinux automatically detects your iOS version and selects the right JIT backend (configurable via **JIT Strategy**: `Auto / Classic Dual-Map (iOS 18) / TXM Broker (iOS 26+)`):

1. **One-Tap Activation (Recommended):**
   - Enable **LocalDevVPN** in iOS Settings or the LocalDevVPN app.
   - Open **HengeLinux** and tap **Enable JIT via StikDebug** (`stikdebug://enable-jit`).
   - **On iOS 18:** Activates `Classic Dual-Map` JIT (`CS_DEBUGGED` + `vm_remap` + `vm_protect(RX)`) with no custom script needed; survives VM stop/reboot without re-attaching.
   - **On iOS 26/27+ (TXM):** Automatically requests stock `universal.js`. If you prefer our custom script, save [`ios/Resources/henge-jit.js`](https://raw.githubusercontent.com/venim1103/henge-linux/main/ios/Resources/henge-jit.js) into **Files ▸ On My iPhone ▸ StikDebug** and **long-press `HengeLinux` -> Assign Script -> `henge-jit.js`**.
   - **LiveContainer:** Detected automatically via `LC_HOME_PATH` (skips the embedded `.appex` and routes directly to StikDebug).
2. *(Optional)* **Import `pairing.plist`:**
   - Tap **Import pairing.plist / .mobiledevicepairing...** to store your lockdown pairing record for `HengeLinuxJITExtension`.
   - Export over USB:
     - **macOS:** `brew install libimobiledevice && idevicepair pair && cp "/var/db/lockdown/$(idevice_id -l | head -n1).plist" ~/Desktop/pairing.plist`
     - **Linux:** `sudo apt install libimobiledevice-utils && idevicepair pair && sudo cp "/var/lib/lockdown/$(idevice_id -l | head -n1).plist" ~/pairing.plist && sudo chown $USER ~/pairing.plist`
     - **Windows / GUI:** Use [`idevice_pair`](https://github.com/jkcoxson/idevice_pair).

---

## Step 4: Boot Linux, Display Modes & Interactive Serial Terminal

1. Pick your **Hardware Profile** (`4` or `6` vCPU) and adjust **Guest RAM (MiB)** (`512`–`10,240 MiB`). The launcher displays live `os_proc_available_memory()` Jetsam headroom and adaptive JIT pool sizing (`192` / `256` / `384 MiB`).
2. Select a **Display Adapter**:
   - **2D UEFI GOP (Metal):** Universal UEFI framebuffer (`simpledrm`/`efifb`) — best default for initial boot and Arch Linux LXQt (`fbdev`).
   - **2D VirtIO-GPU KMS (EDID + Metal):** Attaches PCIe `virtio-gpu` (`0x1af4:0x1050`) with VESA EDID 1.4 (`1280×800`) for native `/dev/dri/card0` KMS (`modesetting` / software Wayland) on stock Linux distros.
3. Per-VM device toggles (**VirtIO Input**, **USB 3.0 xHCI**, **ACPI SPCR**) default to **VirtIO Input = On** and **xHCI = Off** for Linux guests so unmodified distros receive native `/dev/input/event*` keyboard + tablet input without the legacy xHCI stall.
4. Tap **Boot**:
   - Use the top segmented switcher in `SessionView` to toggle between the **Metal Display** and the interactive **`ttyAMA0` Serial Terminal** tab at any time (with direct PL011 typing, Paste, and `Ctrl+C` / `Esc` / `Tab`).
   - On the pre-built Arch Linux image, `systemd-bootaa64.efi` boots automatically into `[root@hengelinux ~]#`.

---

## Step 5: Installing the LXQt Graphical Desktop (Optional)

The pre-built `archlinux.hvsparse` image comes pre-configured with `/etc/X11/xorg.conf.d/10-fbdev.conf` (`/dev/fb0`), `/etc/sddm.conf.d/hengelinux.conf` (autologin on `vt2`), `/etc/modules-load.d/uinput.conf`, and the native `henge-dual-console` `/dev/uinput` Virtual Keyboard + Virtual Tablet bridge:

1. At the `[root@hengelinux ~]#` prompt, run:
   ```bash
   henge-install-desktop
   ```
   - This installs `lxqt`, `sddm`, `xorg-server`, `xorg-xinit`, `xf86-video-fbdev`, `xf86-input-libinput`, and `ttf-dejavu`, creates desktop user `arch` (password: `arch`), enables `sddm`, and switches the display to `vt2`.
2. **Using Touch, Trackpad & Keyboard in LXQt:**
   - Tap directly on the LXQt canvas to click, drag to move/drag, two-finger tap to right-click, or toggle **Split Deck** for a dedicated multi-touch trackpad + Left/Right Click buttons.
   - All touch, trackpad, and keyboard events are injected into Linux `/dev/uinput` by `henge-dual-console` whenever `vt2` is active—even with `usbcore.nousb` enabled.
3. **Switching Between LXQt (`vt2`) and the Root Console (`vt1`):**
   - Press **`Ctrl` + `Alt` + `F1`** (via the special-key strip or a Bluetooth keyboard) to return to the `tty1` root console, or **`Ctrl` + `Alt` + `F2`** to return to LXQt. From the root console, you can also run `chvt 2` / `chvt 1`.

---

## Step 6: Guest Networking, Offline Guest Agent & WebDAV File Sharing

- **Networking (`libslirp` VirtIO-Net):**
  - Guest IP: `10.0.2.15` · Host Gateway: `10.0.2.4` · DNS: `10.0.2.3`
- **Install Portable Guest Additions on Any Distro (`systemd` / `OpenRC` / `runit`):**
  - Unmodified cloud/ISO images work without guest software, or install Safari OAuth (`xdg-open`), clipboard sync, and WebDAV helpers offline from the host gateway:
    ```sh
    curl -fsSL http://10.0.2.4/.henge/guest-tools/install.sh | sudo sh
    ```
- **Host ↔ Guest Shared Folder (`Documents/Shared/`):**
  - Any files you place in **Files ▸ On My iPhone ▸ HengeLinux ▸ Shared/** are served inside the guest at `http://10.0.2.4/`.
  - Mount inside Arch Linux anytime with:
    ```bash
    rclone mount :webdav: /mnt/ios-share --webdav-url http://10.0.2.4/ --webdav-vendor other --daemon
    ```
- **Safari OAuth & Passkey Bridge (`henge-xdg-open`):**
  - `$BROWSER` and `xdg-open` inside Arch Linux point to `/usr/local/bin/henge-xdg-open`.
  - Running CLI login flows (`gh auth login`, `gcloud auth login`, etc.) automatically forwards the guest's `127.0.0.1` / `[::1]` OAuth callback port to `10.0.2.4/.henge/expose-port`, opens an in-app `SFSafariViewController` sheet on iOS for Face ID / Passkey authentication, and dismisses the sheet automatically when the OAuth redirect completes.

---

## Step 7: Building Your Own Custom Disk Image (Optional)

If you prefer to customize packages, disk size, or kernel options instead of downloading the pre-built image:

### Option A: Automated Non-Interactive Builder (Linux ARM64)
```bash
make prebuilt-guest-image
# Outputs: build/prebuilt/code.fd, build/prebuilt/vars.fd, build/prebuilt/archlinux.hvsparse
```

### Option B: Interactive Archboot QEMU Installer (macOS or Linux)
```bash
# macOS: brew install qemu
# Arch:  sudo pacman -S qemu-system-aarch64 edk2-aarch64
# Debian/Ubuntu: sudo apt install qemu-system-arm qemu-efi-aarch64
make hvsparse
./scripts/provision_archlinux_arm64.sh
```
Inside the Archboot QEMU console:
1. Run `setup` and install Arch Linux onto `/dev/nvme0n1` with a GPT EFI System Partition (`/boot`).
2. Add `console=tty0 console=ttyAMA0,115200` to your kernel boot parameters.
3. Copy `guest/setup-arch-bridge.sh` and `guest/henge-xdg-open` into the guest and run `sudo ./setup-arch-bridge.sh`.
4. Run `poweroff`; `provision_archlinux_arm64.sh` automatically packs `work/archlinux.img` into `work/archlinux.hvsparse`.

---

## Troubleshooting

- **`Unable to Start VM · pairing.plist validated (...); link StikJIT.xcframework...` after 15 seconds:**
  - `HengeLinux` was launched without `henge-jit.js` bound in StikDebug. Force-quit `HengeLinux`, open **StikDebug**, **long-press `HengeLinux` -> Assign Script -> `henge-jit.js`**, ensure **LocalDevVPN** is on, and relaunch `HengeLinux` from StikDebug.
- **`HengeLinux` folder does not appear in `Files ▸ On My iPhone`:**
  - Use the in-app **Import Guest Files...** and **Import pairing.plist...** buttons (they read directly from `Downloads` / `iCloud Drive` via iOS security-scoped URLs and verify files in **App Container Files (`Documents/`)**). If you upgraded from an older `.ipa`, delete and reinstall `HengeLinux` once via SideStore so iOS registers `CFBundleDocumentTypes`.
- **Stuck on TianoCore `Start boot option` or keys not responding in UEFI:**
  - Make sure you have installed the latest **`HengeLinux-unsigned.ipa`** (`cf6f1f0` or newer, which fixes the Darwin `COMMPAGE_TIMEBASE_OFFSET` ARM timer clock-domain deadlock and forwards keys to PL011 UART `ttyAMA0`) **and** re-imported the latest `archlinux.hvsparse` and `vars.fd` from [Releases](https://github.com/venim1103/henge-linux/releases) or [Nightly (`latest-ipa`)](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa).
  - Wait 30–60 seconds on cold boot for initial DBT translation. If you want to inspect the UEFI menu manually, tap **Stop**, tap **Boot Arch Linux**, and press **`Esc`** or **`F2`** on the TianoCore logo to open **Boot Manager -> EFI Internal Shell** (`fs0:\startup.nsh`).
- **Guest RAM & iOS Jetsam Ceiling (`~3 GiB` standard ledger):**
  - You can edit **Guest RAM (MiB)** freely (`512`–`10,240 MiB`) before tapping **Boot Arch Linux**. When `CS_DEBUGGED` is active via StikDebug (`ptraced=0`) without `VM_LEDGER_FLAG_NO_FOOTPRINT`, iOS enforces a ~3 GiB total process footprint ceiling under the standard Mach ledger—so keeping RAM around `1,664`–`2,048 MiB` (`+ 384 MiB` JIT pool) avoids Jetsam kills during heavy `pacman` installs.
- **Getting the LXQt + SDDM Graphical Desktop (`vt2`) & Mouse/Keyboard Input:**
  - Re-import the latest `archlinux.hvsparse` and `HengeLinux-unsigned.ipa` from [Releases](https://github.com/venim1103/henge-linux/releases) (or [Nightly (`latest-ipa`)](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa)), then run `henge-install-desktop` in the guest console. This installs `lxqt`, `sddm`, `xorg-server`, `xf86-video-fbdev`, `xf86-input-libinput`, and `ttf-dejavu`, configures SDDM autologin on `vt2` for user `arch` (password `arch`), and uses the built-in native `/dev/uinput` Virtual Keyboard + Virtual Tablet bridge inside `henge-dual-console` so touch taps, Split Deck trackpad gestures, and keyboard events work in X11 even with `usbcore.nousb` enabled.
