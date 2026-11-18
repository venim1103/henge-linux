# `henge-linux` Setup & Sideloading Guide

This guide walks through installing **`HengeLinux`** on a non-jailbroken iPhone or iPad (iOS 26.0 – iOS 27+), importing the Arch Linux ARM64 guest image, configuring TXM JIT with **StikDebug** + **LocalDevVPN**, and using the native iOS Safari and WebDAV bridges.

---

## Overview: What You Need

To boot Arch Linux on iOS, you need the app bundle, three guest VM files, and the TXM JIT debugger script:

| File | Required | Where to Download | Purpose |
| :--- | :--- | :--- | :--- |
| **`HengeLinux-unsigned.ipa`** | **Yes** | [`latest-ipa` Pre-Release](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/HengeLinux-unsigned.ipa) | Main iOS app (`HengeLinux.app`) + embedded JIT helper extension (`HengeLinuxJITExtension.appex`) |
| **`archlinux.hvsparse`** | **Yes** | [`latest-ipa` Pre-Release](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/archlinux.hvsparse) | Pre-configured Arch Linux ARM64 sparse NVMe disk image (~294 MiB download; unpacks to 8 GiB sparse APFS image on first boot) |
| **`code.fd`** | **Yes** | [`latest-ipa` Pre-Release](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/code.fd) | 64 MiB TianoCore EDK2 AArch64 UEFI firmware code |
| **`vars.fd`** | **Yes** | [`latest-ipa` Pre-Release](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/vars.fd) | 64 MiB TianoCore EDK2 AArch64 UEFI NVRAM variable store |
| **`henge-jit.js`** | **Yes** *(for StikDebug)* | [`ios/Resources/henge-jit.js`](https://raw.githubusercontent.com/venim1103/henge-linux/main/ios/Resources/henge-jit.js) | Custom GDB RSP script that handles `brk #0x69` and `brk #0xf00d` (`0x69` byte-0 page blessing) for iOS 26/27 TXM |
| **`pairing.plist`** | **Optional** | Exported via `idevicepair` / `idevice_pair` | Lockdown pairing record for in-app `HengeLinuxJITExtension` XPC self-debugging |

---

## Step 1: Install `HengeLinux` via SideStore or AltStore

1. On your iPhone or iPad, download [`HengeLinux-unsigned.ipa`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/HengeLinux-unsigned.ipa) from the [`latest-ipa` Pre-Release](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa).
2. Open **SideStore** (or **AltStore**), tap **`+`**, and select `HengeLinux-unsigned.ipa` from **Downloads**.
3. Sign and install the app with your Apple ID.
   - *Tip:* If you previously installed an older build of `HengeLinux` before `UIFileSharingEnabled` / `CFBundleDocumentTypes` were added, delete the old app icon first before installing so iOS refreshes its `Files.app` container registration.
   - *Free Apple ID note:* SideStore/AltStore strips `com.apple.developer.kernel.increased-memory-limit` and rewrites the App Group prefix on free Apple IDs (`HengeLinux` handles this automatically via `CS_DEBUGGED` + `LEDGER_NO_FOOTPRINT` and dynamic bundle ID derivation).
4. Launch **HengeLinux** once so it initializes `Documents/Machines/ArchLinux/` and `Documents/Shared/`.

---

## Step 2: Download & Import the Guest VM Files

1. In Safari on your iPhone/iPad, open [`latest-ipa` Releases](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa) and download all three guest files into **Files ▸ On My iPhone ▸ Downloads**:
   - `archlinux.hvsparse`
   - `code.fd`
   - `vars.fd`
2. Open **HengeLinux**.
3. Under **Guest Image (`Documents/Machines/ArchLinux`)**, tap **Import Guest Files (hvsparse / code.fd / vars.fd)...**.
4. Select `archlinux.hvsparse`, `code.fd`, and `vars.fd` from **Downloads** and tap **Open**.
   - *Alternative:* You can also copy or AirDrop those three files directly into **Files ▸ On My iPhone ▸ HengeLinux ▸ Machines ▸ ArchLinux/**, or share them from the iOS Share Sheet into **HengeLinux**.
5. Confirm in the launcher UI that:
   - **Disk Container** reads `archlinux.hvsparse (Ready · ~294 MiB)`
   - **UEFI Firmware** reads `code.fd + vars.fd (Ready)`
   - **App Container Files (`Documents/`)** lists `archlinux.hvsparse`, `code.fd`, and `vars.fd`.

---

## Step 3: Set Up TXM JIT with StikDebug & LocalDevVPN

iOS 26/27 Trusted Execution Monitor (`TXM`) blocks anonymous executable memory (`PROT_EXEC`) unless a debugger performs the `brk #0xf00d` + byte-0 `0x69` page-blessing handshake, and `CS_DEBUGGED` unlocks `LEDGER_NO_FOOTPRINT` guest RAM (> 3 GB without Jetsam kills).

1. **Save `henge-jit.js` into StikDebug's folder:**
   - Open [`https://raw.githubusercontent.com/venim1103/henge-linux/main/ios/Resources/henge-jit.js`](https://raw.githubusercontent.com/venim1103/henge-linux/main/ios/Resources/henge-jit.js) in Safari and save it to **Downloads** (make sure the saved filename ends in `.js`, not `.js.txt`).
   - Open the iOS **Files** app, move `henge-jit.js` from **On My iPhone ▸ Downloads** into **On My iPhone ▸ StikDebug**.
2. **Assign `henge-jit.js` specifically to `HengeLinux` in StikDebug:**
   - Enable **LocalDevVPN** in iOS Settings or the LocalDevVPN app.
   - Open **StikDebug** and go to the **JIT** tab.
   - **Press and hold (`Long-Press`) `HengeLinux`** in the app list, tap **Assign Script**, and select **`henge-jit.js`**.
   - *Important:* Tapping the star (`★`) next to `henge-jit.js` in StikDebug's Scripts tab alone does **not** bind it to an app—you must long-press `HengeLinux` and use **Assign Script**.
3. *(Optional)* **Import `pairing.plist`:**
   - If you also want to store your lockdown pairing record in `HengeLinux`, tap **Import pairing.plist / .mobiledevicepairing...** and select your `pairing.plist` or `.mobiledevicepairing` file.
   - How to export `pairing.plist` on a computer over USB:
     - **macOS:** `brew install libimobiledevice && idevicepair pair && cp "/var/db/lockdown/$(idevice_id -l | head -n1).plist" ~/Desktop/pairing.plist`
     - **Linux:** `sudo apt install libimobiledevice-utils && idevicepair pair && sudo cp "/var/lib/lockdown/$(idevice_id -l | head -n1).plist" ~/pairing.plist && sudo chown $USER ~/pairing.plist`
     - **Windows / GUI:** Use [`idevice_pair`](https://github.com/jkcoxson/idevice_pair) to export `.mobiledevicepairing` / `pairing.plist`.

---

## Step 4: Boot Arch Linux on iOS

1. Open **StikDebug** (with **LocalDevVPN** active and `henge-jit.js` assigned to `HengeLinux`) and tap **HengeLinux** to launch it with the debugger attached.
2. In **HengeLinux**, pick your **Hardware Profile**:
   - **iPhone Pro (8 GB RAM):** `2,560 MiB` (2.5 GiB) · `4 vCPU` *(recommended for iPhone 16 Pro / 17 Pro 8 GB)*
   - **iPhone Duo / 12 GB Pro:** `4,608 MiB` (4.5 GiB) · `4 vCPU`
   - **M-Series iPad Pro (16 GB):** `6,144 MiB` (6.0 GiB) · `6 vCPU`
3. Leave **Display Adapter** set to **2D UEFI GOP (Metal)** for initial bring-up.
4. Tap **Boot Arch Linux**.
   - On first boot, `HengeLinux` unpacks `archlinux.hvsparse` into an APFS sparse `archlinux.img` on a background thread (`Unpacking Disk Image...`).
   - `henge-jit.js` blesses the `384 MiB` dual-mapped RX/RW JIT pool (`< 0x7000000000`) and detaches cleanly (`CS_DEBUGGED` remains active for the session).
5. **Allow 30–60 seconds on cold boot past TianoCore (`Start boot option`):**
   - `systemd-bootaa64.efi` (`timeout 0`, `console-mode keep`) launches `\Image` + `\initramfs-linux.img` automatically with zero keypresses required, and `HengeVMBridge` forwards on-screen / hardware keystrokes to both USB xHCI and the PL011 serial console (`ttyAMA0`).
   - On a cold boot, the ARM64 dynamic binary translator compiles the kernel decompression and `initramfs` unpack from scratch before Linux's framebuffer (`simpledrm`/`fbcon`) and serial console (`ttyAMA0`) display the login prompt (`root` / `root`).

---

## Step 5: Guest Networking, Safari OAuth & WebDAV File Sharing

The pre-built `archlinux.hvsparse` image comes pre-configured with `guest/setup-arch-bridge.sh`:

- **Networking (`libslirp` VirtIO-Net):**
  - Guest IP: `10.0.2.15` (via `systemd-networkd` DHCP on `virtio_net`)
  - Host Gateway: `10.0.2.4`
  - DNS: `10.0.2.3`
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

## Step 6: Building Your Own Custom Disk Image (Optional)

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
  - Make sure you have installed the latest **`HengeLinux-unsigned.ipa`** (`cf6f1f0` or newer, which fixes the Darwin `COMMPAGE_TIMEBASE_OFFSET` ARM timer clock-domain deadlock and forwards keys to PL011 UART `ttyAMA0`) **and** re-imported the latest `archlinux.hvsparse` and `vars.fd` from [`latest-ipa`](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa).
  - Wait 30–60 seconds on cold boot for initial DBT translation. If you want to inspect the UEFI menu manually, tap **Stop**, tap **Boot Arch Linux**, and press **`Esc`** or **`F2`** on the TianoCore logo to open **Boot Manager -> EFI Internal Shell** (`fs0:\startup.nsh`).
- **RAM clamped to `1536 MiB`:**
  - `CS_DEBUGGED` was not active when `Boot Arch Linux` was tapped, so the untethered Jetsam guard capped RAM at `1,536 MiB` to prevent a ~3 GB Mach ledger kill. Launch through StikDebug with `henge-jit.js` assigned to unlock full `2,560–6,144 MiB` `LEDGER_NO_FOOTPRINT` RAM. *(Note: On iOS 26+, telemetry may still report `standard ledger` once `P_TRACED` detaches; `2,560 MiB` fits safely within an 8 GB iPhone's Jetsam ceiling.)*
