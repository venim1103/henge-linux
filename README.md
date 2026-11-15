# henge-linux

**Full-system ARM64 (`aarch64`) Arch Linux virtualization on non-jailbroken iOS 26 / iOS 27 devices — without `Hypervisor.framework`.**

`henge-linux` adapts the direct ARM64-to-ARM64 dynamic binary translation architecture of [`ammaarreshi/WindowsiOS`](https://github.com/ammaarreshi/WindowsiOS) and [`Leviidev/Henge`](https://github.com/Leviidev/Henge) (`HengeVM`) to boot mainline `aarch64` Arch Linux on modern iPhones and iPads, combining full kernel (`EL1`) fidelity with 16 KiB page-granule alignment, TXM dual-mapped JIT, and ledger-exempt guest RAM.

> **Documentation:** See [`docs/RESEARCH.md`](docs/RESEARCH.md) for the complete technical review, comparison of all 6 Linux-on-iOS execution architectures, device adaptation notes, and unified implementation blueprint.

---

## Why `henge-linux`?

Stock iOS 16.4+ restricts `com.apple.developer.kernel.hypervisor` on non-jailbroken devices, forcing App Store emulators (such as UTM SE) onto QEMU's slow threaded interpreter (`TCI`) while subjecting sideloaded VMs to ~3 GB Jetsam terminations and iOS 26/27 Trusted Execution Monitor (`TXM`) `PROT_EXEC` blocks.

`henge-linux` targets a cleaner architecture for Linux on Apple Silicon iOS devices:

- **Same-Architecture ARM64-to-ARM64 Block Translation (`core/translate.c`):** Executes unprivileged user-mode ARM64 instructions directly on host silicon while rewriting privileged system register/exception instructions inline—avoiding QEMU's cross-architecture IR lifting overhead.
- **16 KiB + 4 KiB Stage-1 Software MMU (`core/mmu.c`):** Emulates VMSAv8-64 `EL1&0` translation with support for 4 KiB, 16 KiB, and 64 KiB granules, allowing a 16 KiB page-size Arch Linux kernel to match the Darwin host kernel 1:1.
- **Standard UEFI + ACPI 6.3 + PCIe GPEX Virtual Motherboard (`devices/`):** Boots mainline `aarch64` Arch Linux (via [Archboot AArch64](https://archboot.com/) or [Holo Core AArch64](https://www.collabora.com/news-and-blog/news-and-events/building-an-arch-linux-aarch64-port-for-holo-core.html)) using inbox Linux drivers for NVMe 1.4 (`hvsparse`), VirtIO-Net (`libslirp`), USB 3.0 xHCI touch/keyboard, and Intel ICH6 duplex HD Audio (`CoreAudio`)—with zero external driver injection.
- **iOS 26/27 TXM JIT & Jetsam Bypass (`winios_jit.c` / `LEDGER_NO_FOOTPRINT`):** Allocates a 384 MiB dual-mapped RX/RW JIT pool below `0x7000000000` via the `brk #0xf00d` / `0x69` page-blessing protocol and maps guest RAM with `LEDGER_NO_FOOTPRINT` so multi-process desktop workloads run without Jetsam kills.
- **Native iOS Integration (`10.0.2.4/.henge/`):** Bridges guest `xdg-open` URLs to `SFSafariViewController` (`SafariSheet`) for Face ID, Passkeys, and OAuth callbacks, alongside WebDAV file sharing.

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

1. **Phase 1 — Documentation & Architecture Baseline:** Complete technical specification and architectural trade-off analysis ([`docs/RESEARCH.md`](docs/RESEARCH.md)).
2. **Phase 2 — Core Engine & Single/Dual-Screen iOS Shell:** Port `HengeVM` / `WindowsiOS` `core/` and `devices/` C/Obj-C/Swift targets, guarding `UIHingeInteraction` so both foldable iPhone Duo and single-screen iPhones (e.g., iPhone 16 Pro) build cleanly with configurable RAM budgets.
3. **Phase 3 — Arch Linux AArch64 Guest & Native Bridge:** Provision a 16 KiB-page Arch Linux `hvsparse` image via Archboot AArch64 and wire `xdg-open` + local port forwarding to `http://10.0.2.4/.henge/`.
4. **Phase 4 — In-App Self-Debugging & 3D Metal Acceleration:** Integrate embedded `StikJIT` (`MPL-2.0`) XPC self-blessing (eliminating external Mac/LLDB launch steps) and evaluate `virglrenderer` → `ANGLE` → `Metal` 3D GPU acceleration.

---

## License

This repository is licensed under the **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** — see [`LICENSE`](LICENSE).

- Upstream `WindowsiOS` and `HengeVM` components (`GPL-2.0-or-later`) upgrade cleanly into `GPL-3.0-or-later`.
- `StikJIT` (`MPL-2.0`), `idevice` (`MIT`), and `LinuxRunner` (`GPL-3.0`) components are compatible with `GPL-3.0-or-later`.
- Avoid incorporating `Apache-2.0` code from UTM's UI/CocoaSpice layer into any `GPL-2.0-only` target; under `GPL-3.0-or-later`, `Apache-2.0` dependencies remain license-compatible.
