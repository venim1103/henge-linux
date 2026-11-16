# `henge-linux` Project Handover Document

**Last Updated:** 2026-11-16
**Repository:** `venim1103/henge-linux` (branch: `main`)
**License:** `GPL-3.0-or-later` (`LICENSE`)

This document captures the complete current state, architecture decisions, file inventory, CI pipeline details, and next steps so development can continue seamlessly in a new chat window.

---

## 1. Current Repository State & Commit History

All foundational documentation, cross-platform C/ASM host primitives, `hvsparse` disk tools, Archboot provisioning scripts, guest OAuth/WebDAV bridge scripts, the adaptive iOS `26.0+` SwiftUI shell, the embedded `HengeLinuxJITExtension` target, and GitHub Actions CI are committed on `main`:

| Commit | Summary |
| :--- | :--- |
| `11dd14a` | Initial commit (`LICENSE` — GNU General Public License v3.0) |
| `b85e4d2` | Added `README.md` and `docs/RESEARCH.md` (technical review of `WindowsiOS` and 6 Linux-on-iOS architectures) |
| `bab8dc7` | Refined `README.md` and `docs/RESEARCH.md` with `HV_TLB_PAGE_BITS=12|14` MMU details, `core/translate.c` register allocation (`x6/x7/x15/x18/x28`), `virtio-gpu-gl-pci` vs. `pvg_lite.c` analysis, and `<104`-byte `AF_UNIX` `sun_path` constraints |
| `b6a7bb3` | Scaffolded Phase 2: `Makefile`, `host/henge_platform.{h,c}`, `tests/test_core.c`, `ios/project.yml`, `ios/Sources/` (`HengeLinuxApp.swift`, `SessionView.swift`, `HingeSensorView.swift`, `MetalLifecycleGuard.swift`), `guest/henge-xdg-open`, `scripts/sync_upstream.sh`, `scripts/build_ios_deps.sh`, and `.github/workflows/ci.yml` |
| `aed31ce` | Added Phase 3: `tools/hvsparse.c` (zero-skipping 64 KiB block packer/unpacker), `scripts/provision_archlinux_arm64.sh`, `guest/setup-arch-bridge.sh`, `HengeLinux-Bridging-Header.h`, and `ios-lib` Makefile target |
| `e32016d` | Defined `_POSIX_C_SOURCE 200809L` and `_FILE_OFFSET_BITS 64` in `tools/hvsparse.c` for strict C11 `fseeko`/`ftello` |
| `4ab8429` | Invoked shell scripts via `bash` in `Makefile` and `.github/workflows/ci.yml` for `0644` checkout permissions |
| `50cf9b2` | Added Phase 4: `host/henge_txm_jit.{h,c}`, `host/henge_brk.S`, `host/henge_virtio_gpu.{h,c}`, `ios/JITExtension/JITExtensionHandler.swift`, `ios/Sources/SelfDebugJITClient.swift`, and `GENERATE_INFOPLIST_FILE: YES` |
| `dcb71e6` | Fixed Darwin BSD header/type compilation (`<sys/types.h>`, `mach_memory_entry_ownership` declaration) and added `.ipa` artifact packaging in `.github/workflows/ci.yml` |
| `0747102` | Removed `#include <mach/mach_vm.h>` from `host/henge_txm_jit.c` (unsupported by iPhoneOS 26.5 SDK) and linked `PLAN.md` + `HANDOVER.md` in `README.md` |
| `42c0669` | Added detailed engineering implementation plan (`PLAN.md`) |
| `3950a8f` | Added session handover document (`HANDOVER.md`) |
| `f7a4fba` | Applied P0/P1 C/ASM fixes: iOS sandbox `<container>/tmp/` socket paths, `P_TRACED` vs `CS_DEBUGGED` + `MAP_MEM_NAMED_CREATE` RAM, render mutex fence, `.cfi`/BTI traps, and 64 KiB aligned `hvsparse` |
| `55560f3` | Hardened `guest/henge-xdg-open` (double-fork daemonize, `EADDRINUSE` `expose-port`, direct `localhost` URLs), `Makefile` `ios-lib` `set -euo pipefail`, `sync_upstream.sh` SHA fetch, and `ci.yml` |
| `1a60781` | Wired `libhengelinux.a` into `ios/project.yml`, added Files app sharing + nested `JITExtension/Info.plist`, synchronous `MetalLifecycleGuard` observer, async JIT boot, and `physicalMemory` RAM cap |
| `1f6c6f4` | Added rolling `latest-ipa` GitHub Pre-Release publishing in `.github/workflows/ci.yml` and direct download links in `README.md` |
| `9ec1bf9` | Added `scripts/apply_upstream_patches.py`, updated `scripts/sync_upstream.sh`, and wired upstream `WindowsiOS` `core/host/devices` compilation into `Makefile` (`ios-lib`) |
| `ee0c18b` | Implemented `ios/Sources/HengeVMBridge.{h,mm}` and wired `SessionView.swift` + `HengeLinuxApp.swift` to `CAMetalLayer`, xHCI HID, and `10.0.2.4/.henge/` OAuth sheet polling |
| `c7c0374` | Fixed Swift `attachDisplayLayer` signature and `fb_metal.m` patch anchor |
| `7e765a0` | Milestone 5.3: wired cached `libffi`/`glib`/`libslirp` static deps in `scripts/build_ios_deps.sh`, `ios/project.yml`, and `.github/workflows/ci.yml`, and added `CNTVCT_EL0` background-suspend offset compensation |
| `e1c3e3f`–`65aec93` | First audit pass + TXM dual-mapped RX/RW pool acquisition (`henge_jit_acquire_pool` + `ios/Resources/henge-jit.js`) |
| `97da5b2`–*(HEAD)* | Second 35-file audit pass: wrapped `winvm.h`/`share.h` in `extern "C"` for ObjC++ linkage, fixed 64-bit LE hex + `P0=690000e000000000` in `henge-jit.js`, zeroed `x0` before `brk #0x69`, added full `UIKeyInput`/`pressesBegan` HID keyboard + relative trackpad in `SessionView.swift`, added CAS monotonic `CNTVCT_EL0` clamp, parallelized `Makefile` `ios-lib`, pinned CI action SHAs, and hardened `henge-xdg-open`/`hvsparse.c` |

---

## 2. File Inventory & Implementation Status

| File Path | Status | Responsibility |
| :--- | :--- | :--- |
| `LICENSE` | Complete | GNU General Public License v3.0 (`GPL-3.0-or-later`) |
| `README.md` | Complete | Project overview, target device memory table, build environment matrix, and doc links |
| `PLAN.md` | Complete | Full Phase 1–5 implementation roadmap, module map, and platform invariants |
| `HANDOVER.md` | Complete | Session handover guide, file status, CI troubleshooting notes, and next-step checklist |
| `docs/RESEARCH.md` | Complete | Deep technical analysis of `WindowsiOS`/`HengeVM` and all 6 Linux-on-iOS approaches |
| `Makefile` | Complete (Phase 2–5.3) | Builds `test_core`, `hvsparse`, and `build/ios/libhengelinux.a` (compiling upstream `WindowsiOS` `core/host/devices` alongside `host/henge_*.c`) |
| `host/henge_platform.{h,c}` | Complete (Phase 5.3) | iOS sandbox `<container>/tmp/` `<104`-byte `sun_path` formatter, `TCR_EL1` `TG0`/`TG1` decoder, 16 KiB RAM aligner, `pthread_mutex_t` render pause fence (`hengelinux_render_lock`), and `CNTVCT_EL0` background-suspend offset compensation (`hengelinux_compensated_counter`) |
| `host/henge_txm_jit.{h,c}` | Complete (P0 hardened) | TXM low-VA window `[4 GiB, 64 GiB)` (`< 0x7000000000`) validator, `0x69` page blessing, separated `P_TRACED` vs `CS_DEBUGGED`, and `MAP_MEM_NAMED_CREATE` + `LEDGER_NO_FOOTPRINT` RAM allocator |
| `host/henge_brk.S` | Complete (P1 polished) | ARM64 `brk #0xf00d` (`0xa0013ed4`) traps (`x16=1` prepare, `x16=0` detach) with `.cfi_startproc` unwind and `hint #34` (`bti c`) |
| `host/henge_virtio_gpu.{h,c}` | Complete (Config layer) | Configures PCI `0x1af4:0x1050` VirtIO-GPU in `2D GOP` or `3D VirGL` (`capset 1 & 2` + `ANGLE Metal`) mode |
| `tools/hvsparse.c` | Complete (P1 hardened) | Zero-skipping 64 KiB sparse disk container packer/unpacker (`HVSP` v1) with 64 KiB aligned `data_offset` and `block_count` bounds validation |
| `tests/test_core.c` | Complete | Unit tests for iOS sandbox `sun_path`, MMU granule decoding, RAM clamping/alignment, render lock/pause gate, TXM VA bounds & `0x69` blessing, and VirtIO-GPU capsets |
| `ios/project.yml` | Complete (Phase 5.3) | XcodeGen spec (`iOS 26.0`, `Swift 6.0`, `C++20`) linking `libhengelinux.a` + `libslirp`/`libglib-2.0`/`libintl`/`libpcre2-8`/`libffi`, enabling Files app sharing, audio background mode, and `HengeLinuxJITExtension` |
| `ios/JITExtension/Info.plist` | Complete | Explicit `Info.plist` with nested `NSExtension` dictionary (`com.apple.ar.viewer`) for PlugInKit / SideStore validation |
| `ios/HengeLinux.entitlements` | Complete | Requests `com.apple.developer.kernel.increased-memory-limit` |
| `ios/Sources/HengeVMBridge.{h,mm}` | Complete (Phase 5.3) | `NS_SWIFT_UI_ACTOR` ObjC++/C++20 bridge (`extern "C"` `winvm.h`/`share.h`), acquiring TXM RX/RW pool before RAM, cleaning up on VM exit, and detaching `CAMetalLayer` safely |
| `ios/Sources/HengeLinuxApp.swift` | Complete (Phase 5.3) | Launcher UI with `ProcessInfo.physicalMemory` RAM cap, async JIT boot, VM exit return-to-launcher polling, `changeCount`-guarded clipboard sync, and HTTP(S)-only `SafariSheetView` |
| `ios/Sources/SessionView.swift` | Complete (Phase 5.3) | Hosts `MetalDisplaySurfaceView` (`CAMetalLayer` + `UIKeyInput` on-screen keyboard + `pressesBegan` hardware HID keyboard + direct touch gestures), relative clamshell trackpad, and HID modifier/arrow/function bar |
| `ios/Sources/HingeSensorView.swift` | Complete | Runtime `NSClassFromString("UIHingeInteraction")` check so single-screen iPhones boot straight into full-screen canvas while offering a manual Split Deck toggle |
| `ios/Sources/MetalLifecycleGuard.swift` | Complete (P1 hardened) | Synchronous `NotificationCenter` `willResignActive`/`didBecomeActive` observers + `withRenderLock` serializing Metal drawables against UIKit suspension |
| `ios/Sources/SelfDebugJITClient.swift` | Complete (P1 hardened) | Async activation state machine checking `henge_txm_is_ptraced()` + `henge_txm_is_cs_debugged()` and preserving blessed pool across VM reboots |
| `ios/JITExtension/JITExtensionHandler.swift` | Scaffolded | `com.apple.ar.viewer` `NSExtensionRequestHandling` entry point; ready to link `StikJIT.xcframework` + `idevice` |
| `guest/henge-xdg-open` | Complete (P1 hardened) | Non-blocking double-fork guest URL opener & dual-stack OAuth relay with `EADDRINUSE` `expose-port`, direct `localhost` URLs, and 0.3s response flush delay |
| `guest/setup-arch-bridge.sh` | Complete | Installs `henge-xdg-open` as `xdg-open`, configures `systemd-networkd` DHCP on `virtio_net`, and creates `/mnt/ios-share` |
| `scripts/sync_upstream.sh` | Complete (Phase 5.1) | Initializes/fetches `ammaarreshi/WindowsiOS` and invokes `scripts/apply_upstream_patches.py` |
| `scripts/apply_upstream_patches.py` | Complete (Phase 5.3) | Idempotently patches upstream `share.c` (`<104B` `sun_path`), `fb_metal.m` & `audio_mac.c` (render pause fence), `jit_region.c` (TXM low-VA guard), and `core/sysreg.c` + `core/translate.c` (`CNTVCT_EL0` suspend offset) |
| `scripts/build_ios_deps.sh` | Complete (Phase 5.3) | Cross-compiles and validates cached iOS arm64 static libraries (`libffi`, `glib`, `libslirp`, `libintl`, `libpcre2-8`) across `/opt/homebrew` and `/usr/local` Macs |
| `scripts/provision_archlinux_arm64.sh` | Complete | Downloads latest Archboot AArch64 ISO, boots QEMU `virt` + EDK2 + NVMe, and packs `archlinux.hvsparse` |
| `.github/workflows/ci.yml` | Complete | Runs Linux C tests (`HV_TLB_PAGE_BITS=12` & `14`), `hvsparse` round-trip, script syntax checks, and macOS XcodeGen + unsigned `.ipa` packaging |

---

## 3. CI Pipeline & Build Notes

### GitHub Actions Workflow (`.github/workflows/ci.yml`)
- **Job 1 (`Core & Platform Unit Tests (Linux)` on `ubuntu-latest`):**
  - Compiles and runs `make HV_TLB_PAGE_BITS=12 test-core hvsparse` and `make HV_TLB_PAGE_BITS=14 test-core hvsparse` with `-Wall -Wextra -Werror`.
  - Runs a binary pack/unpack round-trip check (`cmp build/raw.bin build/unpacked.bin`).
  - Runs `python3 -m py_compile`, `bash -n`, and `bash scripts/provision_archlinux_arm64.sh --dry-run`.
- **Job 2 (`iOS Unsigned IPA Build (macOS)` on `macos-latest`):**
  - Selects Xcode 26 (`Xcode_26.6.app`), installs `xcodegen`, `meson`, `ninja`, and `pkg-config`, runs `bash scripts/sync_upstream.sh`, restores/caches `.upstream/WindowsiOS/ios/deps` (`libffi`, `glib`, `libslirp`, `libintl`, `libpcre2-8`), builds `make test-core hvsparse ios-lib` (`build/ios/libhengelinux.a` with full `HengeVM` engine linked), generates `ios/HengeLinux.xcodeproj`, runs `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO build`, packages `build/HengeLinux-unsigned.ipa` + `.sha256`, uploads the Actions artifact (`HengeLinux-unsigned-ipa`), and updates the rolling **`latest-ipa` GitHub Pre-Release** (`https://github.com/venim1103/henge-linux/releases/tag/latest-ipa`).
  - **Sideloading from Linux, Windows, or Intel Mac:** Download [`HengeLinux-unsigned.ipa`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/HengeLinux-unsigned.ipa) directly on your iPhone/iPad and sign/install it with **SideStore** or **AltStore**—no local Mac required.

### Resolved SDK / Toolchain Issues (Do Not Reintroduce)
1. **iPhoneOS SDK `<mach/mach_vm.h>`:** Public `iPhoneOS.sdk` headers fail compilation with `#error mach_vm.h unsupported.` Always use `<mach/mach.h>` instead.
2. **macOS `_POSIX_C_SOURCE`:** Defining `_POSIX_C_SOURCE` on `__APPLE__` hides BSD `u_int`/`u_char`/`u_short` types required by `<sys/sysctl.h>` and `MAP_ANON`. Gate `_POSIX_C_SOURCE` with `#if !defined(__APPLE__)`.
3. **XcodeGen `Info.plist` & Entitlements `properties:`:** Keep `GENERATE_INFOPLIST_FILE: YES` on `HengeLinux` and always define explicit `properties:` blocks under `info:` (`HengeLinuxJITExtension`) and `entitlements:` (`HengeLinux`) alongside `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `ios/project.yml`, otherwise `xcodegen generate` overwrites `Info.plist` without `NSExtension` (causing SideStore `IXErrorDomain Code=17`) and wipes `HengeLinux.entitlements`.
4. **`CAMetalLayer` Ownership & `fb_metal.m` Lock Order:** Host the guest display in `MetalDisplaySurfaceView` (`layerClass = CAMetalLayer.self`), never an unpaused `MTKView` (which steals drawables via its own 60 Hz `CADisplayLink`). In `fb_metal.m`, wrap `(void)tick` via method renaming to `_hengeUnlockedTick` so `hengelinux_render_lock()` is always acquired *outside* `os_unfair_lock` and released on every return path.
5. **SFSafariViewController & `xdg-open` URL Scheme Guard:** `SFSafariViewController(url:)` throws an uncatchable `NSInvalidArgumentException` for non-HTTP(S) schemes; enforce `http`/`https` + non-empty host in `HengeVMBridge.mm` / `HengeLinuxApp.swift` and delegate non-HTTP(S) URIs/files in `guest/henge-xdg-open` to `/usr/bin/xdg-open`.
6. **ObjC++ (`HengeVMBridge.mm`) C Header Linkage:** Upstream `winvm.h` and `share.h` omit `extern "C"`; always wrap them inside `extern "C" { ... }` when including from `.mm` files so linker symbols do not get C++-mangled.

---

## 4. Verified Upstream `WindowsiOS` Layout & Open Audit / Milestone 5.4 Tracker

We inspected `ammaarreshi/WindowsiOS` (`0071d6975287fd720b9046dfd3bd80b6f2aa765e`) and confirmed its exact module layout, Linux `arm64` MMU/ID-register compatibility, and patch coordinates:
- **Core DBT & MMU (`core/`):** `classify.c`, `operands.c`, `translate.c`, `dispatch.c`, `mmu.c` (compiled with `-mgeneral-regs-only`), `memop.c`, `exception.c`, `sysreg.c`, `machine.c`.
  - *Verified in `core/mmu.c:169-187`:* `current_asid()` and `hv_mmu_ukey()` already inspect `TCR_EL1.A1` (bit 22) and `TCR_EL1.AS` (bit 36) dynamically, so Linux `A1=0` (`TTBR0_EL1`) ASIDs and `ASID=0` KPTI transitions work without modification.
  - *Verified in `core/sysreg.c:18-25`:* `ID_AA64ISAR1` (`0x0000001100211001ull`) and `ID_AA64PFR0` (`0x1100000001110011ull`) already mask out PAuth (`APA`/`API`/`GPA`), SVE, and MTE, preventing `APIAKeyLo_EL1` MSR trap storms on Linux context switches.
  - *Verified in `devices/timer.c:14`:* `hv_timer_update()` reads `hv_counter()` from `core/sysreg.c`, which automatically inherits `hengelinux_compensated_counter(mach_absolute_time())` so virtual/physical timer deadlines stay synchronized across iOS background suspends.
  - *Verified in `host/hvsparse.c:90` & `THIRD_PARTY_NOTICES.md:3`:* Upstream `WindowsiOS` enforces chunk bounds (`rec[1] > CHUNK || rec[0] + rec[1] > size`) and licenses all `WindowsiOS`/`Henge`/`Husk` code as `GPL-2.0-or-later`, upgrading cleanly into `GPL-3.0-or-later`.
- **Host Primitives (`host/`):** `jit_region.c`, `enter.S`, `disk.c`, `winvm.c`, `net_slirp.c`, `share.c`, `audio_mac.c`, `hvsparse.c`.
- **Virtual Devices (`devices/`):** `fb_metal.m`, `nvme.c`, `pcie.c`, `gicv3.c`, `xhci.c`, `hda.c`, `virtio_net.c`, `acpi.c`, `fdt.c`, `fw_cfg.c`, `pflash.c`, `pl011.c`, `pl031.c`, `pl061.c`, `timer.c`, `virtio.c`, `virtio_blk.c`, `virtio_input.c`, `virtio_snd.c`, `winvirt.c`.

### Remaining Open Items (Tracked Until Resolved)
- **[OPEN / Milestone 5.3 Hardware Check] Guest Image Provisioning & `HV_TLB_PAGE_BITS=12` vs `14`:** Run `make hvsparse && bash scripts/provision_archlinux_arm64.sh` on a Mac or Linux host, install Arch Linux onto `/dev/nvme0n1` with `console=tty0 console=ttyAMA0,115200`, run `sudo bash /path/to/guest/setup-arch-bridge.sh`, and verify on physical iPhone/iPad (`Files -> On My iPhone -> HengeLinux -> Machines/ArchLinux/`).
- **[OPEN / Milestone 5.4] In-App `StikJIT` (`MPL-2.0`) + `idevice` (`MIT`) XPC Blessing:** `ios/JITExtension/JITExtensionHandler.swift` currently validates `pairing.plist` and returns `blessing_armed`; link `StikJIT.xcframework` + `idevice` (using App Group `com.apple.security.application-groups` file access rather than large `NSExtensionItem` plist payloads) to stream GDB RSP `brk #0xf00d` page blessing over `10.7.0.1` (`LocalDevVPN`) inside the `com.apple.ar.viewer` memory ceiling (~50–120 MB) without a tethered Mac.
- **[OPEN / Milestone 5.4] 3D VirtIO-GPU (`virtio-gpu-gl-pci`, `0x1af4:0x1050`):** Wire `virglrenderer` + `ANGLE (Metal)` behind `host/henge_virtio_gpu.{h,c}` for hardware-accelerated Wayland compositors (`Hyprland`, `Wayfire`, `Sway`) and `tctiSH`-style background VM state serialization.
- **[OPEN / Performance & UX Polish] Inline JIT `CNTVCT_EL0` Offset & Live `UIHingeInteraction` Angle Delegate:** Optimize `translate_counter` in `core/translate.c` to subtract a `HvCpu`-resident suspend offset inline in ARM64 JIT (eliminating `hv_sysreg_mrs` helper exits on VDSO `clock_gettime`), and bind live `UIHingeInteraction` angle updates on foldable hardware.

When continuing in a new chat window, **Milestone 5.3 engine, CI caching, and P0/P1 audit hardening are landed**. Start immediately with **Guest Provisioning & Milestone 5.4**:

1. **Provision & Boot Arch Linux AArch64 Image (Milestone 5.3 Hardware/Guest Validation):**
   - Run `make hvsparse && bash scripts/provision_archlinux_arm64.sh` on a Mac or Linux host, install Arch Linux via Archboot setup onto `/dev/nvme0n1`, run `sudo bash /path/to/guest/setup-arch-bridge.sh` inside the guest, and copy `archlinux.hvsparse`, `code.fd`, and `vars.fd` into **Files -> On My iPhone -> HengeLinux -> Machines/ArchLinux/**.
   - Compare `HV_TLB_PAGE_BITS=12` (stock 4 KiB Archboot kernel) vs. `HV_TLB_PAGE_BITS=14` (custom `CONFIG_ARM64_16K_PAGES=y` Arch kernel).
2. **Embed `StikJIT` (`MPL-2.0`) + `idevice` (`MIT`) & 3D VirGL (Milestone 5.4):**
   - Wire `SelfDebugJITClient.swift` to invoke `HengeLinuxJITExtension` over `NSExtensionContext` / XPC to perform live `brk #0xf00d` page blessing on-device without a tethered Mac.
   - Implement `virtio-gpu-gl-pci` (`0x1af4:0x1050`) backed by `virglrenderer` + `ANGLE (Metal)` for hardware-accelerated Wayland compositors (`Hyprland`, `Wayfire`, `Sway`).

---

## 5. Starter Prompt for a New Chat Window

Copy and paste the following into your next session to pick up immediately where this session left off:

> `@github-code-editor @GitHubCodeEditor Open venim1103/henge-linux and read HANDOVER.md and PLAN.md. Milestone 5.3 engine linkage and CNTVCT_EL0 suspend compensation are landed on main—let's execute Milestone 5.4: wire embedded StikJIT/idevice XPC page blessing in HengeLinuxJITExtension + SelfDebugJITClient.swift and implement virtio-gpu-gl-pci (virglrenderer + ANGLE Metal) in host/henge_virtio_gpu.{h,c}.`
