# henge-linux

**Full-system ARM64 (`aarch64`) Arch Linux virtualization on non-jailbroken iOS 26 / iOS 27 devices — without `Hypervisor.framework`.**

`henge-linux` adapts the direct ARM64-to-ARM64 dynamic binary translation architecture of [`ammaarreshi/WindowsiOS`](https://github.com/ammaarreshi/WindowsiOS) and [`Leviidev/Henge`](https://github.com/Leviidev/Henge) (`HengeVM`) to boot mainline `aarch64` Arch Linux on modern iPhones and iPads, combining full kernel (`EL1`) fidelity with 16 KiB page-granule alignment, TXM dual-mapped JIT, and ledger-exempt guest RAM.

> **Documentation & Builds:**
> - **Latest Unsigned `.ipa` (Direct Download):** [`HengeLinux-unsigned.ipa`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/HengeLinux-unsigned.ipa) · [All Releases](https://github.com/venim1103/henge-linux/releases) · [GitHub Actions CI](https://github.com/venim1103/henge-linux/actions)
> - [`PLAN.md`](PLAN.md) — Detailed engineering implementation plan, module architecture, technical invariants, and Phase 1–5 roadmap.
> - [`HANDOVER.md`](HANDOVER.md) — Current repository status, file inventory, CI build guide, and next-session handover checklist.
> - [`docs/RESEARCH.md`](docs/RESEARCH.md) — Complete technical review of `WindowsiOS`/`HengeVM` and all 6 Linux-on-iOS execution architectures.

---

## Quick Sideload (No Mac Required)

Every green push to `main` automatically packages and publishes an unsigned iOS 26.0+ `arm64` bundle (`HengeLinux.app` + embedded `HengeLinuxJITExtension.appex`):

1. **Download `.ipa` on iPhone / iPad:** Grab [`HengeLinux-unsigned.ipa`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/HengeLinux-unsigned.ipa) from the [`latest-ipa` Pre-Release](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa) (or from the `HengeLinux-unsigned-ipa` artifact on any [GitHub Actions run](https://github.com/venim1103/henge-linux/actions)).
2. **Sign & Install:** Open the `.ipa` in **SideStore** or **AltStore** to sign with your Apple ID and install on-device.
3. **Load Guest Files via iOS Files App:** Place `archlinux.hvsparse`, `code.fd`, and `vars.fd` (and optional `pairing.plist`) into **Files -> On My iPhone -> HengeLinux -> Machines/ArchLinux/** (`UIFileSharingEnabled` is pre-configured).

---

## Why `henge-linux`?

Stock iOS 16.4+ restricts `com.apple.developer.kernel.hypervisor` on non-jailbroken devices, forcing App Store emulators (such as UTM SE) onto QEMU's slow threaded interpreter (`TCI`) while subjecting sideloaded VMs to ~3 GB Jetsam terminations and iOS 26/27 Trusted Execution Monitor (`TXM`) `PROT_EXEC` blocks.

`henge-linux` targets a cleaner architecture for Linux on Apple Silicon iOS devices:

- **Same-Architecture ARM64-to-ARM64 Block Translation (`core/translate.c`):** Executes unprivileged user-mode ARM64 instructions directly on host silicon with hot/cold block splitting, inline ARMv8.1 LSE atomics, PAC stripping, and host scratch register allocation (`x6`, `x7`, `x15` free; guest `x6`, `x7`, `x15`, `x18`, `x28` stored in `HvCpu`).
- **Dual-Mode 16 KiB / 4 KiB Stage-1 Software MMU (`core/mmu.c`):** Emulates VMSAv8-64 `EL1&0` translation across 4 KiB, 16 KiB, and 64 KiB granules (`granule_bits()`), supporting both a `HV_TLB_PAGE_BITS=12` compatibility mode (for standard 4 KiB Archboot kernels) and a `HV_TLB_PAGE_BITS=14` fast-path mode (for 16 KiB `CONFIG_ARM64_16K_PAGES=y` kernels matching Darwin 1:1 with 4x TLB reach).
- **Standard UEFI + ACPI 6.3 + PCIe GPEX Virtual Motherboard (`devices/` & `host/`):** Boots mainline `aarch64` Arch Linux (via [Archboot AArch64](https://archboot.com/) or [Holo Core AArch64](https://www.collabora.com/news-and-blog/news-and-events/building-an-arch-linux-aarch64-port-for-holo-core.html)) using inbox Linux drivers for NVMe 1.4 (`hvsparse`), UEFI GOP framebuffer (`simpledrm`/`efifb` → `fb_metal.m`), VirtIO-Net (`libslirp`), USB 3.0 xHCI touch/keyboard, and Intel ICH6 duplex HD Audio (`host/audio_mac.c`)—with zero external driver injection.
- **iOS 26/27 TXM JIT & Jetsam Bypass (`winios_jit.c` / `LEDGER_NO_FOOTPRINT`):** Allocates a 384 MiB dual-mapped RX/RW JIT pool below `0x7000000000` via the `brk #0xf00d` / `0x69` page-blessing protocol and maps guest RAM with `LEDGER_NO_FOOTPRINT` so multi-process desktop workloads run without Jetsam kills.
- **Native iOS Integration (`host/share.c` → `10.0.2.4/.henge/`):** Bridges guest `henge-xdg-open` URLs and dual-stack (`127.0.0.1` / `[::1]`) OAuth loopback listeners to `SFSafariViewController` (`SafariSheet`) for Face ID and Passkeys, alongside internal `AF_UNIX`-backed WebDAV file sharing and clipboard sync.

---

## Target Devices & Memory Sizing

| Device Class | Example Hardware | Recommended Guest RAM | UI & Input Mode |
| :--- | :--- | :--- | :--- |
| **Foldable Dual-Screen iPhone** | iPhone Duo (`iPhone19,4`, A20 Pro, iOS 27) | **4,608 MiB** (4.5 GB) | `UIHingeInteraction` clamshell laptop deck + 7.6" Open Studio canvas |
| **Standard Single-Screen iPhone (8 GB+)** | iPhone 16 Pro (A18 Pro, 8 GB RAM, iOS 26/27) | **2,048–3,072 MiB** (2–3 GB) | Direct `SessionView` canvas + external Bluetooth/USB-C HID or on-screen input bar |
| **12 GB+ Pro iPhone / M-Series iPad** | iPhone 17 Pro / M-series iPad Pro | **4,096–6,144 MiB** (4–6 GB) | Full-screen canvas + USB-C external display output |

---

## Build Environments

| Task | Apple Silicon Mac | Intel (`x86_64`) MacBook | Linux PC (Bare Metal) |
| :--- | :--- | :--- | :--- |
| **Build iOS App (`.ipa`)** | **Yes** (Xcode 26 / 27) | **Yes** (up to macOS 26 / Xcode 26; use `/usr/local` Homebrew prefix) | **No natively** (use GitHub Actions `macos-latest` + SideStore/AltStore, or a macOS 26 KVM VM) |
| **Run Local macOS VM (`winvm`)** | **Yes** (ARM64-to-ARM64 host) | **No** (requires host ARM64 CPU) | **No** (requires macOS + ARM64 CPU) |
| **Build `hvsparse` & Arch Disk Image** | **Yes** | **Yes** | **Yes** (native C compiler + `qemu-system-aarch64`) |

---

## Roadmap

1. **Phase 1 — Documentation & Architecture Baseline:** Complete technical specification, gap analysis, and architectural trade-off review ([`docs/RESEARCH.md`](docs/RESEARCH.md)).
2. **Phase 2 — Core Engine, Host Layer & Single/Dual-Screen iOS Shell:** Port `HengeVM` / `WindowsiOS` `core/`, `devices/`, `host/`, `tests/`, and `ios/` targets—Verify instruction/block unit tests (`make test-core`), enforce `< 104`-byte `AF_UNIX` `sun_path` socket paths inside the iOS sandbox `<container>/tmp/` directory, serialize `CAMetalLayer` rendering under a `pthread_mutex_t` pause fence on `willResignActive`, and guard `UIHingeInteraction` for both foldable iPhone Duo and single-screen iPhones (e.g., iPhone 16 Pro).
3. **Phase 3 — Arch Linux AArch64 Guest & Dual-Stack Native Bridge:** Provision a 64 KiB-aligned Arch Linux `hvsparse` image via Archboot AArch64 (evaluating both 4 KiB default and 16 KiB `HV_TLB_PAGE_BITS=14` kernels), mount `http://10.0.2.4/` WebDAV, and ship non-blocking `henge-xdg-open` with dual-stack (`127.0.0.1` / `[::1]` ↔ `10.0.2.15`) OAuth port-forwarding and auto-dismiss (`/.henge/oauth-done`).
4. **Phase 4 — In-App Self-Debugging & VirtIO-GPU 3D Metal Acceleration:** Integrate embedded `StikJIT` (`MPL-2.0`) XPC self-blessing (`HengeLinuxJITExtension` with nested `Info.plist`) and add `virtio-gpu-gl-pci` (`virglrenderer` → `ANGLE` → `Metal`) for 3D Wayland compositors (`Hyprland`, `Wayfire`, `Sway`) alongside `tctiSH`-style background state persistence (since `Henge`'s `pvg_lite.c` targets macOS-only `ParavirtualizedGraphics.framework`).
5. **Phase 5 — Upstream `WindowsiOS` Engine Linkage & Live Arch Linux Runtime (*In Progress — 5.1 & 5.2 Landed*):** Upstream `WindowsiOS` patcher (`scripts/apply_upstream_patches.py`), `libhengelinux.a` engine build rules, and `HengeVMBridge.{h,mm}` (`CAMetalLayer`, xHCI HID, `10.0.2.4/.henge/` OAuth sheet bridge) are wired; next: iOS static deps (`libffi`/`glib`/`libslirp`) linking and Archboot guest boot validation.

---

## License

This repository is licensed under the **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** — see [`LICENSE`](LICENSE).

- Upstream `WindowsiOS` and `HengeVM` components (`GPL-2.0-or-later`) upgrade cleanly into `GPL-3.0-or-later`.
- `StikJIT` (`MPL-2.0`), `idevice` (`MIT`), and `LinuxRunner` (`GPL-3.0`) components are compatible with `GPL-3.0-or-later`.
- Avoid incorporating `Apache-2.0` code from UTM's UI/CocoaSpice layer into any `GPL-2.0-only` target; under `GPL-3.0-or-later`, `Apache-2.0` dependencies remain license-compatible.
