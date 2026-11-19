# HengeLinux (`henge-linux`) — Full-System ARM64 Linux Virtual Machine for iOS

[![CI](https://github.com/venim1103/henge-linux/actions/workflows/ci.yml/badge.svg)](https://github.com/venim1103/henge-linux/actions/workflows/ci.yml)
[![Releases](https://img.shields.io/github/v/release/venim1103/henge-linux?include_prereleases&label=Release)](https://github.com/venim1103/henge-linux/releases)
[![Nightly](https://img.shields.io/badge/Nightly-latest--ipa-blue)](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa)
[![Platform](https://img.shields.io/badge/iOS-18.0%20--%2027%2B%20(arm64)-black)](docs/SETUP.md)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/License-GPLv3-green.svg)](LICENSE)

**Run full-system ARM64 (`aarch64`) Linux virtual machines natively on non-jailbroken iPhone and iPad (iOS 18.0 – iOS 27+) — without `Hypervisor.framework` or QEMU TCG.**

**HengeLinux** is an open-source iOS Linux virtualization app powered by the direct ARM64-to-ARM64 dynamic binary translation (DBT) engine and Stage-1 software MMU of [`ammaarreshi/WindowsiOS`](https://github.com/ammaarreshi/WindowsiOS) and [`Leviidev/Henge`](https://github.com/Leviidev/Henge) (`HengeVM`). Boot **Arch Linux, Debian, Ubuntu, Fedora, Alpine Linux, openSUSE, Void Linux, or any ARM64 UEFI Live/Netinstall ISO** with full Linux kernel (`EL1`) fidelity, Metal display output, PCIe VirtIO devices, in-app QCOW2 unpacking, and Cloud-Init (`CIDATA`) provisioning—sideloadable via **SideStore** or **AltStore** with **StikDebug** JIT.

> **Downloads & Documentation:**
> - **Versioned Releases (Recommended):** [All Releases](https://github.com/venim1103/henge-linux/releases) (`v0.2.0`+)
> - **Nightly Builds (Bleeding-Edge `main`):** [Nightly (`latest-ipa`)](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa) (`HengeLinux-unsigned.ipa`, `archlinux.hvsparse`, `code.fd`, `vars.fd`) · [GitHub Actions CI](https://github.com/venim1103/henge-linux/actions)
> - [`docs/SETUP.md`](docs/SETUP.md) — Complete iPhone/iPad sideloading guide (SideStore/AltStore, StikDebug JIT on iOS 18 & iOS 26/27+, Multi-VM & QCOW2/`CIDATA` cloud images, 2D VirtIO-GPU KMS, LXQt desktop, and Safari OAuth / WebDAV bridges).
> - [`PLAN.md`](PLAN.md) — Engineering architecture, module map, platform invariants, and Phase 1–6 roadmap.
> - [`HANDOVER.md`](HANDOVER.md) — Repository state, file inventory, and CI build guide.
> - [`docs/RESEARCH.md`](docs/RESEARCH.md) — Technical comparison of `WindowsiOS`/`HengeVM` and Linux-on-iOS virtualization architectures.
> - [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) — GPLv3 §5a / §6(d) attribution and license provenance.

---

## Key Features

- **Direct ARM64-to-ARM64 JIT (No QEMU TCG Overhead):** Translates unprivileged `aarch64` instructions directly to Apple Silicon with hot/cold block splitting, inline ARMv8.1 LSE atomics, PAC stripping, and dual-mode 4 KiB / 16 KiB Stage-1 software MMU (`HV_TLB_PAGE_BITS=12|14`).
- **iOS 18.0 – iOS 27+ Dual-Mode JIT (`StikDebug` Ready):** Automatically uses **Classic Dual-Map JIT** on iOS 18 (`vm_remap` + `vm_protect(RX)`) and **TXM Broker JIT** on iOS 26/27+ (compatible with stock StikDebug `universal.js` and `henge-jit.js`), with one-tap `stikdebug://enable-jit` deep-linking, `UserDefaults` selftest crash auto-escalation, **LiveContainer** detection, and live `os_proc_available_memory()` Jetsam headroom advisories.
- **Multi-VM Manager & In-App QCOW2 (zlib + Zstd) / Cloud-Init (`CIDATA`):** Manage multiple isolated Linux VMs (`Documents/Machines/<ID>/vm.json`) with shared UEFI firmware (`Documents/Firmware/`), streaming C QCOW2 v2/v3 unpacking (`zlib` and `libzstd`, no PC required), 2 MiB FAT16 `CIDATA` seed generation, APFS `clonefile` instant cloning, and `F_PUNCHHOLE` disk compaction.
- **Standard UEFI + ACPI 6.3 + PCIe VirtIO Hardware:** Boots unmodified ARM64 Linux kernels using inbox drivers for NVMe 1.4, **2D UEFI GOP** or **2D VirtIO-GPU KMS + live viewport resize & EDID 1.4** (`0x1af4:0x1050` → Metal), **VirtIO Input** (keyboard with `EV_REP` + absolute tablet), secondary read-only **VirtIO Block** (`512B` `CIDATA`/isohybrid & `2048B` pure El Torito ISOs), **VirtIO-Net** (`libslirp` NAT), toggleable **USB 3.0 xHCI**, and **Intel ICH6 HD Audio** (`CoreAudio`).
- **Interactive `ttyAMA0` Serial Terminal, Repeat-Capable Special Keys & Native iOS Bridges:** Switch anytime between the Metal display and an interactive `ttyAMA0` serial terminal tab, use Bluetooth keyboards or the hold-to-repeat on-screen special-key strip (`Esc`, `Ctrl`, `Alt`, `Super`, arrows, `F1`–`F12`), inspect the installed version/commit hash in the **About** tab, and install the bundled static `aarch64-linux-musl` guest agent offline (`http://10.0.2.4/.henge/guest-tools/install.sh`) for Safari Face ID/Passkey OAuth (`xdg-open`), clipboard sync, and WebDAV file sharing.

---

## Supported ARM64 Linux Distributions

| Track | Distributions | How to Boot on iPhone / iPad |
| :--- | :--- | :--- |
| **Pre-Built `.hvsparse` Images** | **Arch Linux ARM64** *(with one-command `henge-install-desktop` LXQt + SDDM)* | Download `archlinux.hvsparse`, `code.fd`, and `vars.fd` from [Releases](https://github.com/venim1103/henge-linux/releases) or [Nightly (`latest-ipa`)](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa) and import in-app. |
| **Official ARM64 Cloud Images (`.qcow2` / `.img`)** | **Debian 13**, **Ubuntu 24.04 / 26.04 LTS**, **Fedora Cloud Base**, **Alpine Linux**, **openSUSE** | Download the official ARM64 UEFI `.qcow2`/`.img` on your iPhone, import it directly into a new VM, and tap **Generate Cloud-Init Seed (`CIDATA`)...**. |
| **Standard ARM64 Live / Netinstall ISOs** | **NixOS**, **Gentoo**, **Kali**, **Rocky / AlmaLinux**, **Void**, **Archboot** | Create a **Blank Disk + ARM64 Live ISO** VM, attach any ARM64 `.iso` as secondary media, install onto `/dev/nvme0n1`, and eject. |

---

## Quick Sideload & Setup (No Mac Required)

Download a tagged [Release](https://github.com/venim1103/henge-linux/releases) (recommended) or the rolling [Nightly (`latest-ipa`)](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa) build (see [`docs/SETUP.md`](docs/SETUP.md) for the full walkthrough):

1. **Install `HengeLinux-unsigned.ipa` with SideStore or AltStore:**
   - Download `HengeLinux-unsigned.ipa` on your iPhone or iPad (iOS 18.0 – iOS 27+), sign/install with **SideStore** or **AltStore**, and launch it once.
2. **Import Shared UEFI Firmware & a Linux Image:**
   - Download `code.fd` and `vars.fd` from [Releases](https://github.com/venim1103/henge-linux/releases) (or [Nightly](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa)), plus either `archlinux.hvsparse` or any official ARM64 `.qcow2` / `.iso`.
   - Inside **HengeLinux**, select a VM (or tap **New ARM64 Linux VM...**), tap **Import Guest Files...**, and for cloud images tap **Generate Cloud-Init Seed (`CIDATA`)...**.
3. **Enable JIT with StikDebug + LocalDevVPN:**
   - Turn on **LocalDevVPN** and tap **Enable JIT via StikDebug** inside HengeLinux (`stikdebug://enable-jit`).
   - **iOS 18:** Activates `Classic Dual-Map` JIT directly (no script needed).
   - **iOS 26/27+ (TXM):** Works with stock StikDebug `universal.js` out of the box, or assign [`ios/Resources/henge-jit.js`](https://raw.githubusercontent.com/venim1103/henge-linux/main/ios/Resources/henge-jit.js) via **Long-Press `HengeLinux` → Assign Script**.
4. **Boot Linux:**
   - Adjust **Guest RAM (MiB)** (`512`–`10,240 MiB` with live Jetsam advisories), pick **2D UEFI GOP (Metal)** or **2D VirtIO-GPU KMS (EDID + Metal)**, and tap **Boot**.
   - Switch between the **Metal Display** and **Serial Terminal (`ttyAMA0`)** tabs anytime, or install optional offline guest integrations (`xdg-open`, clipboard, WebDAV) with:
     ```sh
     curl -fsSL http://10.0.2.4/.henge/guest-tools/install.sh | sudo sh
     ```

---

## Why `henge-linux`?

Stock iOS 16.4+ restricts `com.apple.developer.kernel.hypervisor` on non-jailbroken devices, forcing App Store emulators (such as UTM SE) onto QEMU's slow threaded interpreter (`TCI`) while subjecting sideloaded VMs to ~3 GB Jetsam terminations and iOS 26/27 Trusted Execution Monitor (`TXM`) `PROT_EXEC` blocks.

`henge-linux` avoids cross-architecture IR translation entirely:

- **Same-Architecture ARM64-to-ARM64 Block Translation (`core/translate.c`):** Executes unprivileged user-mode ARM64 instructions directly on host silicon with hot/cold block splitting, inline ARMv8.1 LSE atomics, PAC stripping, and host scratch register allocation (`x6`, `x7`, `x15` free; guest `x6`, `x7`, `x15`, `x18`, `x28` stored in `HvCpu`).
- **Dual-Mode 16 KiB / 4 KiB Stage-1 Software MMU (`core/mmu.c`):** Emulates VMSAv8-64 `EL1&0` translation across 4 KiB, 16 KiB, and 64 KiB granules (`granule_bits()`), supporting both `HV_TLB_PAGE_BITS=12` (universal compatibility for 4 KiB and 64 KiB Linux kernels) and `HV_TLB_PAGE_BITS=14` (4x TLB reach for `CONFIG_ARM64_16K_PAGES=y` kernels).
- **Zero-Driver-Injection Virtual Motherboard (`devices/` & `host/`):** UEFI (EDK2 `ArmVirtQemu`) + ACPI 6.3 + PCIe GPEX with NVMe 1.4, `virtio-gpu` 2D KMS + EDID 1.4, `virtio-input` keyboard/tablet, `virtio-blk`, `virtio-net` (`libslirp`), toggleable `xhci`, and ICH6 HD Audio (`CoreAudio`).
- **Unified iOS 18.0 – iOS 27+ JIT & Live Jetsam Budgeting (`host/henge_txm_jit.c`):** Automatically selects `CLASSIC` dual-map JIT (iOS 18) or `TXM_BROKER` (iOS 26/27+), scales the JIT pool (`192`/`256`/`384 MiB`), and computes live available memory via `os_proc_available_memory()`.

---

## Target Devices & Memory Sizing

| Device Class | Example Hardware | Recommended Guest RAM | UI & Input Mode |
| :--- | :--- | :--- | :--- |
| **iPhone (4–6 GB RAM, iOS 18+)** | iPhone 13 / 14 / 15 (4–6 GB RAM, iOS 18.0+) | **1,024–1,536 MiB** *(192–256 MiB JIT pool)* | Direct `SessionView` canvas + interactive `ttyAMA0` terminal + Split Deck |
| **Standard Single-Screen iPhone (8 GB+)** | iPhone 16 Pro (A18 Pro, 8 GB RAM, iOS 18–27) | **1,664–2,560 MiB** *(editable 512–10,240 MiB)* | Direct `SessionView` canvas + Split Deck trackpad + full special-key strip / Bluetooth HID |
| **Foldable Dual-Screen iPhone** | iPhone Duo (`iPhone19,4`, A20 Pro, iOS 27) | **1,664 MiB** *(standard ledger)* / **4,608 MiB** *(ledger-exempt)* | `UIHingeInteraction` clamshell laptop deck + 7.6" Open Studio canvas |
| **12 GB+ Pro iPhone / M-Series iPad** | iPhone 17 Pro / M-series iPad Pro | **1,664–2,048 MiB** *(standard ledger)* / **4,096–6,144 MiB** *(ledger-exempt)* | Full-screen canvas + USB-C external display output |

---

## Build Environments

| Task | Apple Silicon Mac | Intel (`x86_64`) MacBook | Linux PC (Bare Metal) |
| :--- | :--- | :--- | :--- |
| **Build iOS App (`.ipa`)** | **Yes** (Xcode 26 / 27) | **Yes** (up to macOS 26 / Xcode 26; use `/usr/local` Homebrew prefix) | **No natively** (use GitHub Actions `macos-latest` + SideStore/AltStore, or a macOS 26 KVM VM) |
| **Run Local macOS VM (`winvm`)** | **Yes** (ARM64-to-ARM64 host) | **No** (requires host ARM64 CPU) | **No** (requires macOS + ARM64 CPU) |
| **Build `hvsparse` & Guest Disk Images** | **Yes** (`provision_archlinux_arm64.sh`) | **Yes** (`provision_archlinux_arm64.sh`) | **Yes** (`make prebuilt-guest-image` or `scripts/build_guest_image.sh`) |

---

## Roadmap

1. **Phase 1 — Documentation & Architecture Baseline:** Complete technical specification, gap analysis, and architectural trade-off review ([`docs/RESEARCH.md`](docs/RESEARCH.md)).
2. **Phase 2 — Core Engine, Host Layer & Single/Dual-Screen iOS Shell:** Port `HengeVM` / `WindowsiOS` `core/`, `devices/`, `host/`, `tests/`, and `ios/` targets—unit tests (`make test-core`), `< 104`-byte `AF_UNIX` `sun_path` enforcement, `willResignActive` Metal render fence, and `UIHingeInteraction` support.
3. **Phase 3 — Arch Linux AArch64 Guest & Dual-Stack Native Bridge:** `"HVSPARSE"` streaming-extent disk tools, Archboot provisioning, `http://10.0.2.4/` WebDAV sharing, and dual-stack `henge-xdg-open` OAuth bridge.
4. **Phase 4 — In-App Self-Debugging & VirtIO-GPU 3D Foundation:** Embedded `HengeLinuxJITExtension` (`com.apple.ar.viewer`), VirtIO-GPU 1.0 control-queue state machine, and atomic FNV-1a background VM state snapshots.
5. **Phase 5 — Upstream Engine Linkage, Live Arch Linux & LXQt Desktop (*`v0.1.0`*):** Upstream `WindowsiOS` patcher (`scripts/apply_upstream_patches.py`), cached `libffi`/`glib`/`libslirp` static deps, editable Guest RAM, native `/dev/uinput` HID bridge, full special-key strip, and automated Arch Linux ARM64 + LXQt guest image CI.
6. **Phase 6 — Multi-Distro ARM64 Linux & iOS 18.0–27+ Generalization (*`v0.2.0`–`v0.2.2`*):** iOS `18.0` deployment floor with unified `CLASSIC`/`TXM_BROKER` JIT, `stikdebug://enable-jit` deep-linking, selftest crash sentinel, Darwin commpage timebase sanity check, `LC_HOME_PATH` LiveContainer detection, and `os_proc_available_memory()` Jetsam sizing; Multi-VM `VMStore` (`vm.json` + shared `Documents/Firmware/`), PCIe `virtio-input` (`EV_REP`) + secondary `virtio-blk` (`512B`/`2048B` El Torito ISO) + toggleable `xhci`/`SPCR`, interactive `ttyAMA0` terminal, hold-to-repeat special keys & **About** build-info tab, streaming C QCOW2 unpacker (`zlib` + `libzstd` in `host/henge_qcow2.c`), FAT16 `CIDATA` cloud-init seeder (`host/henge_cidata.c`), APFS `clonefile` / `F_PUNCHHOLE` storage tools, bundled static `aarch64-linux-musl` guest agent (`guest/henge_guest_agent.c` + `guest/install.sh`), multi-distro CI profiles (`scripts/build_guest_image.sh`), 2D VirtIO-GPU KMS + live viewport resize & EDID 1.4 (`0x1af4:0x1050`), and Linux `xhci_hcd` hardening.

---

## License

This repository is licensed under the **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** — see [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

- Upstream `WindowsiOS` and `HengeVM` components (`GPL-2.0-or-later`) upgrade cleanly into `GPL-3.0-or-later`.
- `StikJIT` (`MPL-2.0`), `idevice` (`MIT`), and `LinuxRunner` (`GPL-3.0`) components are compatible with `GPL-3.0-or-later`.
- Under `GPL-3.0-or-later`, `Apache-2.0` dependencies remain license-compatible.
