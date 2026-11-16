# `henge-linux` Engineering Implementation Plan

**Repository:** `venim1103/henge-linux`
**License:** GNU General Public License v3.0 or later (`GPL-3.0-or-later`)
**Target Platforms:** Non-jailbroken iOS 26.0 – iOS 27+ (`arm64`, single-screen iPhones/iPads and foldable iPhone Duo) without `Hypervisor.framework`
**Target Guest:** Mainline `aarch64` Arch Linux (Archboot AArch64 / Collabora-Valve Holo Core AArch64)

---

## 1. Project Goals & Non-Goals

### Primary Goals
1. **Full-System ARM64 (`aarch64`) Kernel (`EL1`) Virtualization on Stock iOS:** Adapt the direct ARM64-to-ARM64 dynamic binary translation engine and Stage-1 software MMU of [`ammaarreshi/WindowsiOS`](https://github.com/ammaarreshi/WindowsiOS) and [`Leviidev/Henge`](https://github.com/Leviidev/Henge) (`HengeVM`) to boot mainline `aarch64` Arch Linux on non-jailbroken iOS 26/27 devices.
2. **16 KiB & 4 KiB Page-Granule Alignment:** Support standard 4 KiB Arch Linux kernels (`HV_TLB_PAGE_BITS=12`) out of the box while offering a compile-time `HV_TLB_PAGE_BITS=14` fast path for dedicated 16 KiB kernels (`CONFIG_ARM64_16K_PAGES=y`) that align 1:1 with Darwin's 16 KiB host page size.
3. **Zero-Driver-Injection Virtual Motherboard:** Boot Arch Linux on UEFI (EDK2 `ArmVirtQemu`) + ACPI 6.3 + PCIe GPEX using inbox Linux drivers for NVMe 1.4 (`hvsparse`), UEFI GOP (`simpledrm`/`efifb` -> Metal), VirtIO-Net (`libslirp`), USB 3.0 xHCI keyboard/touch, and Intel ICH6 duplex HD Audio (`CoreAudio`).
4. **TXM JIT & Jetsam Bypass Without Jailbreak:** Allocate a 384 MiB dual-mapped RX/RW JIT code cache below `0x7000000000` using the `brk #0xf00d` + byte-0 `0x69` page-blessing handshake, and map guest RAM with `LEDGER_NO_FOOTPRINT` scaled to device physical RAM (`2.5 GiB` on 8 GB iPhone 16 Pro; `4.5 GiB` on 12 GB+ iPhone Duo / Pro; `6.0 GiB` on 16 GB iPad Pro).
5. **Zero-Ceremony In-App Self-Debugging & Native iOS Bridge:** Eliminate tethered Mac/LLDB launch requirements via an embedded helper `NSExtension` (`com.apple.ar.viewer` pattern from `Playport`) and bridge guest `xdg-open` / dual-stack loopback OAuth callbacks (`127.0.0.1` / `[::1]`) and WebDAV file sharing through `http://10.0.2.4/.henge/`.
6. **Hardware-Accelerated 3D Wayland Desktop:** Upgrade the 2D UEFI GOP presenter to `virtio-gpu-gl-pci` backed by `virglrenderer` -> `ANGLE` -> `Metal` for hardware-accelerated `Hyprland`, `Wayfire`, and `Sway` compositing.

### Non-Goals
- Running `x86_64` guest kernels directly via full-system emulation (userspace `x86_64` binaries inside `aarch64` Arch Linux can optionally use `FEX-Emu` or `blink` later).
- Depending on macOS-only `ParavirtualizedGraphics.framework` (`Henge`'s `pvg_lite.c`), which has no mainline Linux kernel driver.
- Incorporating `Apache-2.0` code from UTM's UI/CocoaSpice layer into any `GPL-2.0-only` target (the repo uses `GPL-3.0-or-later` to preserve broad compatibility).

---

## 2. System Architecture & Module Map

```text
henge-linux/
├── host/                           # C11 & ARM64 assembly host substrate (compiled into libhengelinux.a & iOS app)
│   ├── henge_platform.{h,c}        # Darwin <104B sun_path formatter (iOS sandbox /tmp), TCR_EL1 decoder, RAM aligner, render mutex gate
│   ├── henge_txm_jit.{h,c}         # TXM [4GiB, 64GiB) VA validator, 0x69 blessing, P_TRACED vs CS_DEBUGGED, MAP_MEM_NAMED_CREATE RAM
│   ├── henge_brk.S                 # ARM64 brk #0xf00d traps with .cfi unwind & BTI landing pads
│   └── henge_virtio_gpu.{h,c}      # VirtIO-GPU PCI (0x1af4:0x1050) backend selector (2D GOP vs 3D VirGL/ANGLE)
├── tools/
│   └── hvsparse.c                  # Zero-skipping 64 KiB block sparse disk container packer/unpacker (64 KiB aligned data_offset)
├── ios/                            # XcodeGen iOS 26.0+ SwiftUI app + embedded JIT helper extension (links libhengelinux.a)
│   ├── project.yml                 # Generates HengeLinux.xcodeproj with Files sharing + nested JITExtension/Info.plist
│   ├── HengeLinux.entitlements     # com.apple.developer.kernel.increased-memory-limit
│   ├── Sources/
│   │   ├── HengeVMBridge.{h,mm}    # ObjC++/C++20 runtime bridge: HvWinVmConfig, CAMetalLayer, xHCI HID, 10.0.2.4/.henge/
│   │   ├── HengeLinuxApp.swift     # Launcher, dynamic physicalMemory RAM cap, async JIT boot, SafariSheetView polling
│   │   ├── SessionView.swift       # Metal framebuffer host, clamshell trackpad & HID modifier strip
│   │   ├── HingeSensorView.swift   # Runtime UIHingeInteraction detector + single-screen clamshell preview toggle
│   │   ├── MetalLifecycleGuard.swift # Synchronous NotificationCenter observer + C pthread_mutex render fence
│   │   ├── SelfDebugJITClient.swift  # P_TRACED / CS_DEBUGGED state machine + process-lifetime pool reuse
│   │   └── HengeLinux-Bridging-Header.h
│   └── JITExtension/
│       ├── Info.plist              # Nested NSExtension dictionary (com.apple.ar.viewer)
│       └── JITExtensionHandler.swift # NSExtension request handler for in-app TXM blessing
├── guest/                          # Scripts deployed inside the Arch Linux aarch64 guest
│   ├── henge-xdg-open              # Non-blocking double-fork dual-stack OAuth relay + EADDRINUSE + SafariSheet bridge
│   └── setup-arch-bridge.sh        # Installs xdg-open handler, systemd-networkd VirtIO DHCP, and /mnt/ios-share
├── scripts/
│   ├── sync_upstream.sh            # Initializes/fetches ammaarreshi/WindowsiOS and runs apply_upstream_patches.py
│   ├── apply_upstream_patches.py   # Idempotently patches share.c (<104B sun_path), fb_metal.m, audio_mac.c, jit_region.c
│   ├── build_ios_deps.sh           # Cross-compiles iOS static deps with /opt/homebrew vs /usr/local detection
│   └── provision_archlinux_arm64.sh # Boots Archboot AArch64 ISO in QEMU with EDK2 + NVMe and packs hvsparse
├── tests/
│   └── test_core.c                 # Unit tests for iOS sandbox sun_path, MMU granules, RAM, render lock, TXM JIT, VirtIO-GPU
├── docs/
│   └── RESEARCH.md                 # Deep technical review of WindowsiOS and 6 Linux-on-iOS architectures
└── .github/workflows/ci.yml        # Least-privilege Linux unit tests + Xcode 26 macOS unsigned .ipa build & upload
```

---

## 3. Technical Invariants & Hard Platform Constraints

Every code change in `henge-linux` must preserve these verified platform invariants:

1. **TXM Low Virtual Address Ceiling (`< 0x7000000000`):**
   - iOS 26/27 Trusted Execution Monitor hangs or rejects JIT pools mapped above `0x7000000000`, and StikJIT's 9-digit hex page addressing truncates at `64 GiB` (`0x1000000000`).
   - All RX/RW dual-mapped JIT pools must land inside `[0x0100000000, 0x1000000000)` (`[4 GiB, 64 GiB)`) and pass `henge_txm_is_valid_jit_range()`.
2. **TXM Byte-0 `0x69` Blessing Marker:**
   - Every 16 KiB (`16,384`-byte) page in the RX JIT region must carry `0x69` at byte offset `0` during the `x16=1; brk #0xf00d` (`0xa0013ed4`) debugger handshake before `mach_vm_remap` creates the RW alias and `x16=0; brk #0xf00d` detaches.
3. **iOS App-Switcher Metal Drawable Guard & Render Fence (`willResignActive`):**
   - iOS reclaims `CAMetalLayer` drawables immediately upon `UIApplication.willResignActiveNotification` *before* `didEnterBackground`. Submitting even a single Metal frame after `willResignActive` causes a fatal `gpus_ReturnNotPermittedKillClient` termination on resume.
   - `MetalLifecycleGuard` registers synchronous `NotificationCenter.default.addObserver(..., queue: .main)` observers in `init()` and serializes drawable acquisition/commit under `hengelinux_render_lock()` / `hengelinux_render_unlock()` so in-flight GPU work finishes before `willResignActive` returns.
4. **Darwin `AF_UNIX` `sun_path` 104-Byte Limit & iOS Seatbelt Sandbox:**
   - Deep iOS sandbox paths (`/private/var/mobile/Containers/Data/Application/<UUID>/Documents/...`) exceed Darwin's 104-byte `sockaddr_un.sun_path` limit, and iOS Seatbelt blocks `bind()` in global `/tmp`. `henge_format_unix_socket_path()` normalizes iOS container paths to `/var/mobile/Containers/Data/Application/<UUID>/tmp/<name>` (91 bytes `< 104`) and reserves `/tmp/hl-<64bit-hex>-<name>` for macOS/Linux hosts.
5. **iPhoneOS SDK Header Restrictions & `CS_DEBUGGED` Persistence:**
   - Apple's public `iPhoneOS.sdk` rejects `#include <mach/mach_vm.h>` with `#error mach_vm.h unsupported.` Use `<mach/mach.h>` instead.
   - `P_TRACED` clears immediately upon `henge_jit26_detach()`, while `CS_DEBUGGED` (`0x10000000` via `csops`) persists for the process lifetime. `henge_alloc_ledger_exempt_ram()` checks `henge_txm_is_cs_debugged()` and allocates via `mach_make_memory_entry_64(MAP_MEM_NAMED_CREATE)` + `mach_memory_entry_ownership(..., VM_LEDGER_TAG_DEFAULT, VM_LEDGER_FLAG_NO_FOOTPRINT)` + `vm_map()`.
6. **Guest RAM Budgeting by Device Class:**
   - `LEDGER_NO_FOOTPRINT` bypasses the ~3 GB per-process Mach ledger kill, but physical RAM exhaustion still triggers system-wide Jetsam kills. Presets enforce `2,560 MiB` on 8 GB devices (iPhone 16 Pro), `4,608 MiB` on 12 GB devices (iPhone Duo / Pro), and `6,144 MiB` on 16 GB iPad Pros, dynamically capped to ~60% of `ProcessInfo.processInfo.physicalMemory`.

---

## 4. Phased Implementation Roadmap

### Phase 1: Architecture Research & Licensing Baseline — **COMPLETED**
- [x] Deep technical review of `ammaarreshi/WindowsiOS`, `Leviidev/Henge`, `Leviidev/Husk`, `mxhm11cr/LinuxRunner`, `tctiSH`, `Playport`, `Madeira`, and Wasm/Waypipe approaches (`docs/RESEARCH.md`).
- [x] Selected `GPL-3.0-or-later` (`LICENSE`) to allow clean upstream `GPL-2.0-or-later` upgrades plus `MPL-2.0` (`StikJIT`), `MIT` (`idevice`), and `GPL-3.0` (`LinuxRunner`) integration.

### Phase 2: Cross-Platform Build System, Platform Guards & Adaptive iOS Shell — **COMPLETED**
- [x] Host-portable `Makefile` auto-detecting `/opt/homebrew` (Apple Silicon) and `/usr/local` (Intel `x86_64` MacBook), supporting `HV_TLB_PAGE_BITS=12` and `HV_TLB_PAGE_BITS=14`.
- [x] `host/henge_platform.{h,c}` + `tests/test_core.c` covering Darwin `<104`-byte `sun_path` formatting, `TCR_EL1` `TG0`/`TG1` decoding, 16 KiB RAM alignment, and thread-safe render pause state.
- [x] Adaptive iOS `26.0+` SwiftUI app (`HengeLinuxApp.swift`, `SessionView.swift`, `HingeSensorView.swift`, `MetalLifecycleGuard.swift`) supporting both foldable `UIHingeInteraction` devices and single-screen iPhones (iPhone 16 Pro) with a split-deck preview toggle and compact modifier bar.

### Phase 3: `hvsparse` Storage Container, Archboot Provisioning & Guest Bridge — **COMPLETED**
- [x] Zero-skipping 64 KiB block `tools/hvsparse.c` (`pack` and `unpack`) verified by byte-exact round-trip tests in CI.
- [x] `scripts/provision_archlinux_arm64.sh` automating EDK2 firmware setup, Archboot AArch64 ISO resolution, QEMU `virt` + NVMe installation, and `.hvsparse` packing.
- [x] `guest/henge-xdg-open` and `guest/setup-arch-bridge.sh` bridging IPv4/IPv6 loopback OAuth listeners (`127.0.0.1` / `[::1]` <-> `10.0.2.15`) to `http://10.0.2.4/.henge/expose-port`, `/open-url` (`SFSafariViewController`), and `/oauth-done`.

### Phase 4: TXM Self-Debug `NSExtension`, VirtIO-GPU Config & Pre-Phase-5 Hardening — **COMPLETED**
- [x] `host/henge_txm_jit.{h,c}` and `host/henge_brk.S` implementing low-VA bounds checking, `0x69` page-blessing marker helpers, `.cfi`/BTI `brk #0xf00d` assembly traps, `P_TRACED` vs `CS_DEBUGGED` detection, and `MAP_MEM_NAMED_CREATE` + `LEDGER_NO_FOOTPRINT` RAM allocation.
- [x] `ios/JITExtension/JITExtensionHandler.swift` + nested `ios/JITExtension/Info.plist` (`com.apple.ar.viewer` extension target in `ios/project.yml`), Files app sharing keys (`UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace`), single-source-of-truth `libhengelinux.a` linking, and synchronous `MetalLifecycleGuard` render fence.
- [x] `host/henge_virtio_gpu.{h,c}` defining `2D UEFI GOP` and `3D VirtIO-GPU VirGL (ANGLE Metal)` configuration descriptors, plus non-blocking double-fork `guest/henge-xdg-open` and 64 KiB aligned `tools/hvsparse.c`.

### Phase 5: Upstream Engine Integration, Live VM Runtime & 3D VirGL Bring-Up — **IN PROGRESS (5.1–5.3 Landed)**
- [x] **Milestone 5.1 — Upstream `HengeVM` / `WindowsiOS` Engine Linkage & Patcher:**
  - Implemented `scripts/apply_upstream_patches.py` (invoked by `scripts/sync_upstream.sh`) to patch `host/share.c` (`henge_format_unix_socket_path()`), `devices/fb_metal.m` (`hengelinux_render_lock()` + `hengelinux_is_render_paused()`), `host/audio_mac.c`, and `host/jit_region.c` (`henge_txm_is_valid_jit_range()`).
  - Updated `Makefile` (`ios-lib`) to compile upstream `core/*.c` (`-mgeneral-regs-only` on `mmu.c`), `host/*.c`/`enter.S`, and `devices/*.{c,m}` into `build/ios/libhengelinux.a` whenever `.upstream/WindowsiOS` + `ios/deps` (`libffi`, `glib`, `libslirp`) are present.
- [x] **Milestone 5.2 — Live VM Runner Bridge (`HengeVMBridge.{h,mm}`):**
  - Implemented `HengeVMBridge.{h,mm}` and wired `SessionView.swift` (`CAMetalLayer`, HID modifier & function keys, trackpad gestures) and `HengeLinuxApp.swift` (`SafariSheetView` polling on `10.0.2.4/.henge/open-url` + `/.henge/oauth-done`, `henge_alloc_ledger_exempt_ram()`).
- [x] **Milestone 5.3 — Cached iOS Static Deps (`libffi`, `glib`, `libslirp`), Live Engine Packaging & `CNTVCT_EL0` Suspend Offset:**
  - Wired cached iOS `arm64` static deps (`libffi`, `glib`, `libslirp`, `libintl`, `libpcre2-8`) in `scripts/build_ios_deps.sh`, `ios/project.yml`, and `.github/workflows/ci.yml` (`REQUIRE_UPSTREAM=1`) so `latest-ipa` embeds the full live `HengeVM` engine (`HENGE_HAS_UPSTREAM_ENGINE == 1`).
  - Implemented background-suspend `CNTVCT_EL0` / `CNTPCT_EL0` offset compensation in `host/henge_platform.{h,c}` and patched `core/sysreg.c` + `core/translate.c` in `scripts/apply_upstream_patches.py` to prevent Linux softlockup watchdogs after iOS background suspension.
  - Completed P0/P1/P2 audit hardening across `HengeVMBridge.{h,mm}` (`extern "C"` C headers, `NS_SWIFT_UI_ACTOR`, JIT-before-RAM order, `_vmCreated` RAM cleanup, `<container>/tmp` creation, `2,048 MiB` untethered Jetsam cap), `HengeLinuxApp.swift` (`http`/`https` `SFSafariViewController` guard, error alert, VM exit return-to-launcher, `changeCount`-guarded clipboard sync), `SessionView.swift` (`MetalDisplaySurfaceView` + `UIKeyInput`/`pressesBegan` HID keyboard + relative trackpad), `host/henge_brk.S` + `host/henge_txm_jit.{h,c}` + `ios/Resources/henge-jit.js` (64-bit LE GDB RSP hex, `mov x0, #0` before `brk #0x69`, thread-safe status copy), `host/henge_platform.c` (monotonic CAS `CNTVCT_EL0` clamp), `guest/henge-xdg-open` (non-HTTP fallback to `/usr/bin/xdg-open`, `0.5s` accept loop, dynamic NIC IP), `scripts/sync_upstream.sh` (pinned SHA `0071d697`), `scripts/provision_archlinux_arm64.sh` (ISO SHA-256 verification), `Makefile` (parallel `ios-lib`), `.github/workflows/ci.yml` (SHA-pinned actions + isolated `release-ipa` `contents: write`), and `tools/hvsparse.c` (sparse `unpack` + 8 TiB / file-size bounds checks). *(Remaining open items tracked in `HANDOVER.md` §4: end-user guest disk provisioning, physical iOS device boot benchmark, and Milestone 5.4).*
- [ ] **Milestone 5.4 — Embedded `StikJIT` XPC Handshake, 3D VirGL & Background Suspend:**
  - Link `StikJIT.xcframework` (`MPL-2.0`) and `idevice` (`MIT`) into `HengeLinuxJITExtension` (`JITExtensionHandler.swift`) to stream GDB RSP `brk #0xf00d` page blessing over `10.7.0.1` (`LocalDevVPN`) using `Documents/pairing.plist` (staying within the `com.apple.ar.viewer` ~50–120 MB extension memory limit).
  - Implement PCIe `virtio-gpu-gl-pci` (`0x1af4:0x1050`) backed by `virglrenderer` + `ANGLE (Metal)` for hardware-accelerated Wayland compositors (`Hyprland`, `Wayfire`, `Sway`), plus `tctiSH`-style background state serialization.

---

## 5. Build & Verification Matrix

| Environment | Commands | Output Artifacts |
| :--- | :--- | :--- |
| **Linux PC (Ubuntu / Arch)** | `make HV_TLB_PAGE_BITS=12 test-core hvsparse`<br>`make HV_TLB_PAGE_BITS=14 test-core hvsparse`<br>`bash scripts/provision_archlinux_arm64.sh` | `build/test_core`, `build/hvsparse`, `work/archlinux.hvsparse` |
| **Intel (`x86_64`) MacBook** *(macOS 26 / Xcode 26)* | `make test-core hvsparse ios-lib`<br>`xcodegen generate --spec ios/project.yml`<br>`xcodebuild -project ios/HengeLinux.xcodeproj -scheme HengeLinux -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build` | `build/ios/libhengelinux.a`, `HengeLinux.app` (sideload via SideStore / AltStore) |
| **Apple Silicon Mac** *(M1–M5, Xcode 26/27)* | Same as Intel MacBook + `xcrun devicectl device install app --device <UDID> ...` | Signed `HengeLinux.app` installed directly over USB/Wi-Fi |
| **GitHub Actions CI & Releases** *(No local Mac needed)* | Triggered automatically on push/PR to `main` (`.github/workflows/ci.yml`) | Direct download [`HengeLinux-unsigned.ipa`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/HengeLinux-unsigned.ipa) from `latest-ipa` Pre-Release and sign on-device with SideStore/AltStore |
