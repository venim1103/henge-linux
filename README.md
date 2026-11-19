# henge-linux

**Full-system ARM64 (`aarch64`) Linux virtualization on non-jailbroken iOS 18.0 – iOS 27+ devices — without `Hypervisor.framework`.**

`henge-linux` adapts the direct ARM64-to-ARM64 dynamic binary translation architecture of [`ammaarreshi/WindowsiOS`](https://github.com/ammaarreshi/WindowsiOS) and [`Leviidev/Henge`](https://github.com/Leviidev/Henge) (`HengeVM`) to boot mainline `aarch64` Linux distributions (Arch Linux, Debian, Ubuntu, Fedora, Alpine, openSUSE, Void, and standard ARM64 Live/Netinstall ISOs) on modern iPhones and iPads, combining full kernel (`EL1`) fidelity with 16 KiB page-granule alignment, dual-mode iOS 18/26+ JIT, PCIe VirtIO devices, and live Jetsam-aware guest RAM sizing.

> **Documentation & Builds:**
> - **Latest Unsigned `.ipa` & Pre-Built Guest Image:** [`latest-ipa` Pre-Release](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa) (`HengeLinux-unsigned.ipa`, `archlinux.hvsparse`, `code.fd`, `vars.fd`) · [All Releases](https://github.com/venim1103/henge-linux/releases) · [GitHub Actions CI](https://github.com/venim1103/henge-linux/actions)
> - [`docs/SETUP.md`](docs/SETUP.md) — Step-by-step setup guide for SideStore/AltStore sideloading (iOS 18.0–27+), Multi-VM & QCOW2/`CIDATA` cloud-image onboarding, **StikDebug** JIT, 2D **VirtIO-GPU KMS**, **LXQt** desktop, and Safari OAuth / WebDAV bridges.
> - [`PLAN.md`](PLAN.md) — Detailed engineering implementation plan, module architecture, technical invariants, and Phase 1–6 roadmap.
> - [`HANDOVER.md`](HANDOVER.md) — Current repository status, file inventory, CI build guide, and session handover notes.
> - [`docs/RESEARCH.md`](docs/RESEARCH.md) — Complete technical review of `WindowsiOS`/`HengeVM` and all 6 Linux-on-iOS execution architectures.
> - [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) — GPLv3 §5a / §6(d) attribution and license provenance for all upstream and linked dependencies.

---

## Quick Sideload & Setup (No Mac Required)

Every green push to `main` automatically builds and publishes the unsigned iOS 18.0+ `arm64` bundle and pre-built Arch Linux ARM64 guest artifacts on the [`latest-ipa` Pre-Release](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa) (see [`docs/SETUP.md`](docs/SETUP.md) for full details and troubleshooting):

1. **Install `HengeLinux-unsigned.ipa` with SideStore / AltStore:**
   - Download [`HengeLinux-unsigned.ipa`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/HengeLinux-unsigned.ipa) on your iPhone/iPad (iOS 18.0 – iOS 27+), import it into **SideStore** or **AltStore**, sign with your Apple ID, and launch it once.
2. **Import Firmware & a Guest Image (Pre-Built Arch, Cloud QCOW2, or Live ISO):**
   - Download [`code.fd`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/code.fd) and [`vars.fd`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/vars.fd) (shared automatically in `Documents/Firmware/`), plus either [`archlinux.hvsparse`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/archlinux.hvsparse) or any official ARM64 cloud `.qcow2`/`.img` or Live `.iso`.
   - Inside **HengeLinux**, select a VM (or tap **New ARM64 Linux VM...**), tap **Import Guest Files...**, and select your files. For cloud images (Debian 13, Ubuntu, Fedora, Alpine, openSUSE), tap **Generate Cloud-Init Seed (`CIDATA`)...** to set credentials offline.
3. **Enable JIT in StikDebug + LocalDevVPN:**
   - Enable **LocalDevVPN** and tap **Enable JIT via StikDebug** directly inside HengeLinux (`stikdebug://enable-jit`).
   - **iOS 18:** Activates `Classic Dual-Map` JIT directly (no custom script required).
   - **iOS 26/27+ (TXM):** Works with stock StikDebug `universal.js` out of the box, or assign [`ios/Resources/henge-jit.js`](https://raw.githubusercontent.com/venim1103/henge-linux/main/ios/Resources/henge-jit.js) via **Long-Press `HengeLinux` -> Assign Script**.
4. **Boot Linux (Metal Display + Interactive `ttyAMA0` Terminal):**
   - Customize **Guest RAM (MiB)** (`512`–`10,240 MiB` with live `os_proc_available_memory()` Jetsam headroom advisories) and choose **2D UEFI GOP (Metal)** or **2D VirtIO-GPU KMS (EDID + Metal)**, then tap **Boot**.
   - Switch anytime between the **Metal Display** and the interactive **`ttyAMA0` Serial Terminal** tab in `SessionView`, or run `henge-install-desktop` on Arch Linux for LXQt + SDDM.
   - On unmodified distributions, optionally install Safari OAuth, clipboard sync, and WebDAV helpers offline via `curl -fsSL http://10.0.2.4/.henge/guest-tools/install.sh | sudo sh`.

---

## Why `henge-linux`?

Stock iOS 16.4+ restricts `com.apple.developer.kernel.hypervisor` on non-jailbroken devices, forcing App Store emulators (such as UTM SE) onto QEMU's slow threaded interpreter (`TCI`) while subjecting sideloaded VMs to ~3 GB Jetsam terminations and iOS 26/27 Trusted Execution Monitor (`TXM`) `PROT_EXEC` blocks.

`henge-linux` targets a cleaner architecture for Linux on Apple Silicon iOS devices:

- **Same-Architecture ARM64-to-ARM64 Block Translation (`core/translate.c`):** Executes unprivileged user-mode ARM64 instructions directly on host silicon with hot/cold block splitting, inline ARMv8.1 LSE atomics, PAC stripping, and host scratch register allocation (`x6`, `x7`, `x15` free; guest `x6`, `x7`, `x15`, `x18`, `x28` stored in `HvCpu`).
- **Dual-Mode 16 KiB / 4 KiB Stage-1 Software MMU (`core/mmu.c`):** Emulates VMSAv8-64 `EL1&0` translation across 4 KiB, 16 KiB, and 64 KiB granules (`granule_bits()`), supporting both a `HV_TLB_PAGE_BITS=12` compatibility mode (for standard 4 KiB Archboot kernels) and a `HV_TLB_PAGE_BITS=14` fast-path mode (for 16 KiB `CONFIG_ARM64_16K_PAGES=y` kernels matching Darwin 1:1 with 4x TLB reach).
- **Standard UEFI + ACPI 6.3 + PCIe GPEX Virtual Motherboard (`devices/` & `host/`):** Boots mainline `aarch64` Linux distributions using inbox Linux drivers for NVMe 1.4 (`hvsparse` / streaming QCOW2), 2D UEFI GOP or PCIe `virtio-gpu` 2D KMS + EDID 1.4 (`0x1af4:0x1050` → `fb_metal.m`), PCIe `virtio-input` keyboard + absolute tablet, secondary read-only `virtio-blk` (`CIDATA` / ISO), VirtIO-Net (`libslirp`), toggleable USB 3.0 xHCI, and Intel ICH6 duplex HD Audio (`host/audio_mac.c`)—with zero external driver injection.
- **Unified iOS 18.0 – iOS 27+ Dual-Mode JIT & Jetsam Sizing (`host/henge_txm_jit.c` + patched `host/jit_region.c`):** Automatically selects `CLASSIC` dual-map JIT on iOS 18 (`vm_remap` + `vm_protect(RX)`) or `TXM_BROKER` on iOS 26/27+ (compatible with stock StikDebug `universal.js` and `henge-jit.js`), scales the JIT cache (`192`/`256`/`384 MiB`), and computes live Jetsam headroom via `os_proc_available_memory()`.
- **Multi-VM Storage & Native iOS Integration (`VMStore.swift`, `host/henge_qcow2.c`, `host/henge_cidata.c`, `host/share.c`):** Manages isolated per-VM manifests (`Documents/Machines/<ID>/vm.json`), streaming QCOW2 unpacking, APFS `clonefile` cloning, `F_PUNCHHOLE` compaction, FAT16 `CIDATA` cloud-init seeds, interactive `ttyAMA0` serial terminal, offline `http://10.0.2.4/.henge/guest-tools/` `musl` guest agent, Safari OAuth/Passkeys (`SFSafariViewController`), WebDAV file sharing, and clipboard sync.

---

## Target Devices & Memory Sizing

| Device Class | Example Hardware | Recommended Guest RAM | UI & Input Mode |
| :--- | :--- | :--- | :--- |
| **Foldable Dual-Screen iPhone** | iPhone Duo (`iPhone19,4`, A20 Pro, iOS 27) | **1,664 MiB** *(standard ledger)* / **4,608 MiB** *(ledger-exempt)* | `UIHingeInteraction` clamshell laptop deck + 7.6" Open Studio canvas |
| **iPhone (4–6 GB RAM, iOS 18+)** | iPhone 13 / 14 / 15 (4–6 GB RAM, iOS 18.0+) | **1,024–1,536 MiB** *(192–256 MiB JIT pool)* | Direct `SessionView` canvas + interactive `ttyAMA0` terminal + Split Deck |
| **Standard Single-Screen iPhone (8 GB+)** | iPhone 16 Pro (A18 Pro, 8 GB RAM, iOS 18–27) | **1,664–2,560 MiB** *(editable 512–10,240 MiB)* | Direct `SessionView` canvas + Split Deck trackpad + full special-key strip / Bluetooth HID |
| **12 GB+ Pro iPhone / M-Series iPad** | iPhone 17 Pro / M-series iPad Pro | **1,664–2,048 MiB** *(standard ledger)* / **4,096–6,144 MiB** *(ledger-exempt)* | Full-screen canvas + USB-C external display output |

---

## Build Environments

| Task | Apple Silicon Mac | Intel (`x86_64`) MacBook | Linux PC (Bare Metal) |
| :--- | :--- | :--- | :--- |
| **Build iOS App (`.ipa`)** | **Yes** (Xcode 26 / 27) | **Yes** (up to macOS 26 / Xcode 26; use `/usr/local` Homebrew prefix) | **No natively** (use GitHub Actions `macos-latest` + SideStore/AltStore, or a macOS 26 KVM VM) |
| **Run Local macOS VM (`winvm`)** | **Yes** (ARM64-to-ARM64 host) | **No** (requires host ARM64 CPU) | **No** (requires macOS + ARM64 CPU) |
| **Build `hvsparse` & Arch Disk Image** | **Yes** (`provision_archlinux_arm64.sh`) | **Yes** (`provision_archlinux_arm64.sh`) | **Yes** (`make prebuilt-guest-image` or `provision_archlinux_arm64.sh`) |

---

## Roadmap

1. **Phase 1 — Documentation & Architecture Baseline:** Complete technical specification, gap analysis, and architectural trade-off review ([`docs/RESEARCH.md`](docs/RESEARCH.md)).
2. **Phase 2 — Core Engine, Host Layer & Single/Dual-Screen iOS Shell:** Port `HengeVM` / `WindowsiOS` `core/`, `devices/`, `host/`, `tests/`, and `ios/` targets—Verify instruction/block unit tests (`make test-core`), enforce `< 104`-byte `AF_UNIX` `sun_path` socket paths inside the iOS sandbox `<container>/tmp/` directory, serialize `CAMetalLayer` rendering under a `pthread_mutex_t` pause fence on `willResignActive`, and guard `UIHingeInteraction` for both foldable iPhone Duo and single-screen iPhones (e.g., iPhone 16 Pro).
3. **Phase 3 — Arch Linux AArch64 Guest & Dual-Stack Native Bridge:** Provision an upstream-compatible `"HVSPARSE"` streaming-extent Arch Linux image via Archboot AArch64 (evaluating both 4 KiB default and 16 KiB `HV_TLB_PAGE_BITS=14` kernels), mount `http://10.0.2.4/` WebDAV, and ship non-blocking `henge-xdg-open` with dual-stack (`127.0.0.1` / `[::1]` ↔ `10.0.2.15`) OAuth port-forwarding and auto-dismiss (`/.henge/oauth-done`).
4. **Phase 4 — In-App Self-Debugging & VirtIO-GPU 3D Metal Acceleration:** Integrate embedded `StikJIT` (`MPL-2.0`) XPC self-blessing (`HengeLinuxJITExtension` with nested `Info.plist`) and add `virtio-gpu-gl-pci` (`virglrenderer` → `ANGLE` → `Metal`) for 3D Wayland compositors (`Hyprland`, `Wayfire`, `Sway`) alongside `tctiSH`-style background state persistence (since `Henge`'s `pvg_lite.c` targets macOS-only `ParavirtualizedGraphics.framework`).
5. **Phase 5 — Upstream `WindowsiOS` Engine Linkage, Live Arch Linux & LXQt Desktop (*Milestones 5.1–5.11 Landed; `v0.1.0`*):** Upstream `WindowsiOS` patcher (`scripts/apply_upstream_patches.py`), cached `libffi`/`glib`/`libslirp` static deps, `"HVSPARSE"` unpacking, editable Guest RAM, native `/dev/uinput` HID bridge (`guest/henge_dual_console.c`), full special-key strip, `HengeLinuxJITExtension`, and automated Arch Linux ARM64 + LXQt guest image CI.
6. **Phase 6 — Multi-Distro ARM64 Linux & iOS 18.0–27+ Generalization (*Milestones 6.1–6.5 Landed; `v0.2.0` Ready*):** Lowered deployment floor to iOS `18.0` with unified `CLASSIC`/`TXM_BROKER` JIT, `stikdebug://enable-jit` deep-linking, `LC_HOME_PATH` LiveContainer detection, and `os_proc_available_memory()` Jetsam sizing; added multi-VM `VMStore` (`vm.json` + shared `Documents/Firmware/` + legacy migration), PCIe `virtio-input` + secondary `virtio-blk` + toggleable `xhci`/`SPCR`, interactive `ttyAMA0` terminal, streaming C QCOW2 unpacker (`host/henge_qcow2.c`), FAT16 `CIDATA` cloud-init seeder (`host/henge_cidata.c`), APFS `clonefile` / `F_PUNCHHOLE` storage tools, single-binary `musl` guest agent (`guest/henge_guest_agent.c` + `guest/install.sh` at `http://10.0.2.4/.henge/guest-tools/`), multi-distro CI profiles (`scripts/build_guest_image.sh`), 2D VirtIO-GPU KMS + EDID 1.4 (`0x1af4:0x1050`), and Linux `xhci_hcd` hardening; see [`docs/SETUP.md`](docs/SETUP.md), [`PLAN.md`](PLAN.md), and [`HANDOVER.md`](HANDOVER.md).

---

## License

This repository is licensed under the **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** — see [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

- Upstream `WindowsiOS` and `HengeVM` components (`GPL-2.0-or-later`) upgrade cleanly into `GPL-3.0-or-later`.
- `StikJIT` (`MPL-2.0`), `idevice` (`MIT`), and `LinuxRunner` (`GPL-3.0`) components are compatible with `GPL-3.0-or-later`.
- Avoid incorporating `Apache-2.0` code from UTM's UI/CocoaSpice layer into any `GPL-2.0-only` target; under `GPL-3.0-or-later`, `Apache-2.0` dependencies remain license-compatible.
