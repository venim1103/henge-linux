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
├── LICENSE                         # GNU General Public License v3.0 (GPL-3.0-or-later)
├── THIRD_PARTY_NOTICES.md          # GPLv3 §5a / §6(d) attribution & pinned source provenance
├── host/                           # C11 & ARM64 assembly host substrate (compiled into libhengelinux.a & iOS app)
│   ├── henge_platform.{h,c}        # Darwin <104B sun_path formatter (iOS sandbox /tmp), TCR_EL1 decoder, RAM aligner, render & CNTVCT_EL0 guards
│   ├── henge_txm_jit.{h,c}         # TXM [4GiB, 64GiB) VA validator, 0x69 blessing, P_TRACED vs CS_DEBUGGED, MAP_MEM_NAMED_CREATE RAM
│   ├── henge_brk.S                 # ARM64 brk #0x69 & brk #0xf00d traps with .cfi unwind & BTI landing pads
│   └── henge_virtio_gpu.{h,c}      # VirtIO-GPU 1.0 PCI (0x1af4:0x1050) 2D/3D VirGL control-queue & atomic FNV-1a suspend.state snapshots
├── tools/
│   └── hvsparse.c                  # Upstream-compatible "HVSPARSE" streaming [offset, len] extent packer/unpacker
├── ios/                            # XcodeGen iOS 26.0+ SwiftUI app + embedded JIT helper extension (links libhengelinux.a)
│   ├── project.yml                 # Generates HengeLinux.xcodeproj with CFBundleDocumentTypes/UTIs, Files sharing, App Group, & nested JITExtension/Info.plist
│   ├── HengeLinux.entitlements     # com.apple.developer.kernel.increased-memory-limit & group.io.hengelinux.shared
│   ├── Resources/
│   │   └── henge-jit.js            # StikDebug / LLDB GDB RSP brk #0x69 / #0xf00d TXM page-blessing script
│   ├── Sources/
│   │   ├── HengeJITExtensionBridge.{h,mm} # ObjC++ NSExtension (com.apple.ar.viewer) XPC bridge with timeout/cancellation guards
│   │   ├── HengeVMBridge.{h,mm}    # ObjC++/C++20 runtime bridge: HvWinVmConfig, async hv_sparse_unpack, CAMetalLayer, xHCI + PL011 + OSC 9999 HID, 10.0.2.4/.henge/
│   │   ├── HengeLinuxApp.swift     # Launcher, editable Guest RAM (512-10240 MiB), fileImporter, Share Sheet .onOpenURL, container file list, async JIT boot, SafariSheetView
│   │   ├── SessionView.swift       # Metal framebuffer host, serialized HID keyboard, clamshell trackpad & complete special-key strip (F1-F12, Shift/Ctrl/Alt/Super, Caps, etc.)
│   │   ├── HingeSensorView.swift   # Runtime UIHingeInteraction detector + live angle observer + single-screen clamshell preview toggle
│   │   ├── MetalLifecycleGuard.swift # Synchronous NotificationCenter observer + C pthread_mutex render fence
│   │   ├── SelfDebugJITClient.swift  # P_TRACED / CS_DEBUGGED state machine, SideStore bundle ID resolver, pairing.plist sync, & container scanner
│   │   └── HengeLinux-Bridging-Header.h
│   └── JITExtension/
│       ├── Info.plist              # Nested NSExtension dictionary (com.apple.ar.viewer)
│       ├── HengeLinuxJITExtension.entitlements # Shared App Group entitlement
│       └── JITExtensionHandler.swift # NSExtension request handler + pipelined 10.7.0.1 GDB RSP TXM blesser
├── guest/                          # Native binary & scripts deployed inside the Arch Linux aarch64 guest
│   ├── henge_dual_console.c        # Static C PL011->tty1 mirror, stateful OSC 9999 parser, HENGE_HID_READY handshake, & /dev/uinput Virtual Keyboard/Tablet bridge
│   ├── henge-xdg-open              # Non-blocking double-fork dual-stack OAuth relay + EADDRINUSE + SafariSheet bridge
│   └── setup-arch-bridge.sh        # Installs xdg-open handler, $BROWSER export, systemd-networkd VirtIO DHCP, and /mnt/ios-share
├── scripts/
│   ├── sync_upstream.sh            # Initializes/fetches ammaarreshi/WindowsiOS and runs apply_upstream_patches.py
│   ├── apply_upstream_patches.py   # Idempotently patches share.c (<104B sun_path), fb_metal.m, audio_mac.c, jit_region.c, sysreg.c, translate.c, dispatch.c
│   ├── build_ios_deps.sh           # Cross-compiles iOS static deps with /opt/homebrew vs /usr/local detection
│   ├── build_prebuilt_archlinux_arm64.sh # Headless GPT+FAT32 ESP+ext4 Arch Linux ARM64 rootfs & hvsparse image builder (< 2 GiB)
│   └── provision_archlinux_arm64.sh # Interactive QEMU virt + EDK2 + NVMe Archboot AArch64 installer and hvsparse packer
├── tests/
│   └── test_core.c                 # Unit tests for iOS sandbox sun_path, MMU granules, RAM, render lock, TXM JIT, VirtIO-GPU, & snapshots
├── docs/
│   ├── RESEARCH.md                 # Deep technical review of WindowsiOS and 6 Linux-on-iOS architectures
│   └── SETUP.md                    # Step-by-step SideStore/AltStore, StikDebug Assign Script, & guest artifact setup guide
└── .github/workflows/
    ├── ci.yml                      # Least-privilege Linux unit tests + Xcode 26 macOS unsigned .ipa build & latest-ipa release
    └── prebuilt-guest-image.yml    # Automated ubuntu-24.04-arm builder publishing code.fd, vars.fd, & archlinux.hvsparse to latest-ipa
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

### Phase 5: Upstream Engine Integration, Live VM Runtime & 3D VirGL Bring-Up — **MILESTONES 5.1–5.8 LANDED (Ready for On-Device SideStore Boot & PCIe VirGL Bus Wiring)**
- [x] **Milestone 5.1 — Upstream `HengeVM` / `WindowsiOS` Engine Linkage & Patcher:**
  - Implemented `scripts/apply_upstream_patches.py` (invoked by `scripts/sync_upstream.sh`) to patch `host/share.c` (`henge_format_unix_socket_path()`), `devices/fb_metal.m` (`hengelinux_render_lock()` + `hengelinux_is_render_paused()`), `host/audio_mac.c`, and `host/jit_region.c` (`henge_txm_is_valid_jit_range()`).
  - Updated `Makefile` (`ios-lib`) to compile upstream `core/*.c` (`-mgeneral-regs-only` on `mmu.c`), `host/*.c`/`enter.S`, and `devices/*.{c,m}` into `build/ios/libhengelinux.a` whenever `.upstream/WindowsiOS` + `ios/deps` (`libffi`, `glib`, `libslirp`) are present.
- [x] **Milestone 5.2 — Live VM Runner Bridge (`HengeVMBridge.{h,mm}`):**
  - Implemented `HengeVMBridge.{h,mm}` and wired `SessionView.swift` (`CAMetalLayer`, HID modifier & function keys, trackpad gestures) and `HengeLinuxApp.swift` (`SafariSheetView` polling on `10.0.2.4/.henge/open-url` + `/.henge/oauth-done`, `henge_alloc_ledger_exempt_ram()`).
- [x] **Milestone 5.3 — Cached iOS Static Deps (`libffi`, `glib`, `libslirp`), Live Engine Packaging & `CNTVCT_EL0` Suspend Offset:**
  - Wired cached iOS `arm64` static deps (`libffi`, `glib`, `libslirp`, `libintl`, `libpcre2-8`) in `scripts/build_ios_deps.sh`, `ios/project.yml`, and `.github/workflows/ci.yml` (`REQUIRE_UPSTREAM=1`) so `latest-ipa` embeds the full live `HengeVM` engine (`HENGE_HAS_UPSTREAM_ENGINE == 1`).
  - Implemented initial `CNTVCT_EL0` / `CNTPCT_EL0` offset compensation in `host/henge_platform.{h,c}` + `scripts/apply_upstream_patches.py`, and fixed Darwin Clang `.S` symbol labels in `host/henge_brk.S` (`8a63cdd`).
- [x] **Pre-Boot P0/P1 Hardening Pass (`ca83def`, `9e52c66`):**
  - **P0 Boot-Blockers & Runtime Traps:** Aligned `tools/hvsparse.c`, `.github/workflows/ci.yml`, and `HengeVMBridge.mm` with upstream `WindowsiOS`'s `"HVSPARSE"` streaming extent archive + first-boot sparse raw image unpack (`hv_sparse_unpack`); decoupled `CNTVCT_EL0` suspend compensation in `host/henge_platform.c` from `willResignActive` `g_render_paused`; added ARM64 `BRK` mask verification `((instrU32 & 0xFFE0001F) >>> 0) === 0xD4200000`, `try/finally` `Detach`, and `p<reg>` fallback in `ios/Resources/henge-jit.js`; hardened `host/henge_txm_jit.c` (`volatile sig_atomic_t` + signal fence, `henge_txm_is_ptraced()` probe gate, low-VA hold restoration on all error paths, custom `__DATA,__jit_hold` Mach-O section, `vm_allocate` Apple fallback).
  - **P1/P2 Linker, Lifecycle, Input & OAuth Reliability:** Linked `-framework AudioToolbox` after `-lhengelinux` in `ios/project.yml` `OTHER_LDFLAGS`; offloaded `SelfDebugJITClient.prepareSession()` `henge_jit_acquire_pool()` from `@MainActor` via `Task.detached` and eliminated redundant double probes; persisted `HvWinVmConfig` C-strings in `HengeVMBridge.mm` `std::string` ivars, guarded redundant `attachDisplayLayer:`, and lowered untethered RAM cap to `1,536 MiB`; replaced active TCP probes in `guest/henge-xdg-open` with passive `/proc/net/tcp{,6}` `TCP_LISTEN` inspection and fixed `127.0.0.0/8` / `302` / favicon redirect races; added `.asciiCapable`, sticky modifier auto-release, and real 2-finger tap/scroll in `SessionView.swift`, `NSNumber` XPC unboxing in `JITExtensionHandler.swift`, and `-MMD -MP` header dependency generation in `Makefile`.
- [x] **Milestone 5.4 (Track 1) — Embedded `HengeLinuxJITExtension` XPC Handshake & TXM GDB RSP Blesser:**
  - Wired `HengeJITExtensionBridge.{h,mm}` (`NSExtension` `com.apple.ar.viewer` lifecycle + one-shot timeout/cancellation guards) and `SelfDebugJITClient.swift` (App Group `group.io.hengelinux.shared` `pairing.plist` sync + concurrent XPC & `Task.detached` `henge_jit_acquire_pool` loop).
  - Implemented `pairing.plist` lockdown validation, `#if canImport(StikJIT)` / `#if canImport(Idevice)` hooks, and a pure-Swift `10.7.0.1` GDB RSP `vAttach` / `brk #0x69` / `brk #0xf00d` (`_M...,rx` + byte-0 `0x69` 16 KiB page blessing) engine in `ios/JITExtension/JITExtensionHandler.swift` (drop `StikJIT.xcframework` + `idevice.xcframework` into `ios/Frameworks/` for automatic RSD `debugproxy` tunnel creation).
- [x] **Milestone 5.4 (Track 2) — 3D VirtIO-GPU VirGL (`ANGLE Metal`) & Background Suspend:**
  - Implemented VirtIO-GPU 1.0 (`0x1af4:0x1050`) 2D/3D VirGL control-queue command processing (`CTX_CREATE`, `RESOURCE_CREATE_3D`, `CTX_ATTACH_RESOURCE`, `SUBMIT_3D`, `SET_SCANOUT`, `RESOURCE_FLUSH`, `num_capsets` vs `capset_mask`, `virglrenderer` + `ANGLE Metal` probe) in `host/henge_virtio_gpu.{h,c}` and wired `HengeVirtioGpuDevice` lifecycle into `HengeVMBridge.{h,mm}`.
  - Implemented atomic FNV-1a checksummed background VM snapshot serialization (`henge_vm_snapshot_write`/`read` -> `Documents/Machines/ArchLinux/suspend.state`) triggered on `UIApplication.didEnterBackgroundNotification` in `HengeLinuxApp.swift` and verified via `tests/test_core.c`.
- [x] **Milestone 5.5 — Post-5.4 39-File Audit Remediation (`P0`–`P3`) & Physical SideStore Boot Prep:**
  - **P0 Physical-Device Blockers:** Derive `SelfDebugJITClient.extensionIdentifier` dynamically from `Bundle.main.bundleIdentifier` for SideStore/AltStore bundle-ID rewrites; enable `TCP_NODELAY` and batch-pipeline `M<addr>,1:69` writes in `JITExtensionHandler.swift` (`24,576` pages `< 1 s`); preserve byte-0 `0x69` markers in `verify_rx_rw_selftest()` (`off + 4U`) and validate `rw != rx` on `VM_FLAGS_ANYWHERE` in `host/henge_txm_jit.c`; serialize `insertText` HID keystrokes with dwell spacing in `SessionView.swift`; fix the `/usr/local/bin/xdg-open` <-> `/usr/bin/xdg-open` recursion loop and configure `$BROWSER` + network-first ordering in `guest/setup-arch-bridge.sh` + `guest/henge-xdg-open`.
  - **P1 Concurrency, Watchdog & State-Machine Fixes:** Eliminate the multi-vCPU `CNTVCT_EL0` `> 500 ms` jump torn read in `host/henge_platform.c`; replace scalar `owner_ctx_id` with a 32-bit `attached_ctx_mask` bitmask in `host/henge_virtio_gpu.c`; offload first-boot `hv_sparse_unpack()` off `@MainActor` in `HengeVMBridge.mm`; wrap `didEnterBackground` snapshot flush in `UIApplication.beginBackgroundTask`; surface honest staged VirGL UI status until PCIe `0x1af4:0x1050` MMIO/virtqueue routing + `libvirglrenderer.a`/`ANGLE` are linked; dispatch `focusKeyboard` binding updates asynchronously and guard `dismantleUIView` layer detach in `SessionView.swift`; forward non-`SIGTRAP` signals (`C<sigHex>`) in `JITExtensionHandler.swift` + `henge-jit.js`; silence CoreAudio input capture on render pause in `scripts/apply_upstream_patches.py`; and add a `HV_TLB_PAGE_BITS` stamp prerequisite in `Makefile`.
  - **P2/P3 Durability, Performance & Tooling Polish:** Harden `guest/henge-xdg-open` (`127.0.0.0/8` + IPv4-mapped `ipaddress` check, double-unquote + portless `localhost` redirect parsing, `8192`-byte header inspection, `EADDRINUSE` `saw_listener` guard) and `arch-chroot` `/etc/resolv.conf` fallback; verify trap PCs in `henge_jit_trap_handler()` and add `.subsections_via_symbols` in `host/henge_brk.S`; validate 36-char UUIDs in `format_ios_sandbox_tmp_socket()`; call `fsync()`/`F_FULLFSYNC` before `rename()` in `henge_vm_snapshot_write()`; expand GDB RSP `*` RLE in `JITExtensionHandler.swift`; make `didBecomeActive` `UIPasteboard` sync opt-in; restore inline `CNTVCT_EL0` JIT emission in `scripts/apply_upstream_patches.py`; fail closed on truncated `.hvsparse` archives in `tools/hvsparse.c`; use `AAVMF_VARS.fd` templates in `scripts/provision_archlinux_arm64.sh`; hash `.xcode-version` and serialize `release-ipa` in `.github/workflows/ci.yml`; and expand `tests/test_core.c` coverage.
  - **UI File Importer Feature:** Added native `fileImporter` sheet in `HengeLinuxApp.swift` allowing users to import `pairing.plist`, `code.fd`, `vars.fd`, or `archlinux.hvsparse` directly via the iOS document browser into app documents and machine directories, ensuring immediate Files app visibility and zero setup friction.
- [x] **Milestone 5.6 — Automated Pre-Built Arch Linux AArch64 Guest Image & EDK2 Firmware CI (`ubuntu-24.04-arm`) & iOS Container UI:**
  - Added headless non-interactive rootfs builder script (`scripts/build_prebuilt_archlinux_arm64.sh`) that provisions a compact 8 GiB GPT + 256 MiB FAT32 EFI System Partition + ext4 rootfs image, bootstraps Arch Linux ARM (`aarch64`) userland + kernel (`console=tty0 console=ttyAMA0,115200`), prunes unused firmware/docs/locales (`LANG=C.UTF-8` + `fstrim`), installs `guest/setup-arch-bridge.sh`, and packs `archlinux.hvsparse` (~294 MiB, well under GitHub Releases' 2 GiB cap) + 64 MiB `code.fd` + 64 MiB `vars.fd`.
  - Added `.github/workflows/prebuilt-guest-image.yml` on `ubuntu-24.04-arm` (verified green in Run `#44062300353`) publishing `code.fd`, `vars.fd`, `archlinux.hvsparse`, and `SHA256SUMS.txt` directly to the rolling `latest-ipa` Pre-Release.
  - Registered `CFBundleDocumentTypes` + `UTImportedTypeDeclarations` in `ios/project.yml`, seeded `Documents/` folders on launch, added Share Sheet `.onOpenURL` import, and added an interactive **App Container Files (`Documents/`)** list with swipe-to-delete in `SelfDebugJITClient.swift` & `HengeLinuxApp.swift`.
- [x] **Milestone 5.7 — Post-5.6 42-File Audit Remediation (`P1`–`P3`) & Native `systemd-bootaa64.efi` ACPI Boot:**
  - All 28 `P1`–`P3` items documented in [`HANDOVER.md` §5](HANDOVER.md#5-full-repository-42-file-deep-audit--physical-device-boot-log-findings-post-milestone-56--commit-7628e20) landed (`904f7cc` + `0b9287e`, verified via QEMU ACPI boot smoke test in `CI Run #44138237110`): native `systemd-bootaa64.efi` + `startup.nsh` fallback, `-machine virt,gic-version=3,acpi=on` CI check, stale `archlinux.img` deletion on `.hvsparse` re-import, safe trap PC & `SA_RESETHAND` signal chaining, `handleEngineExitReason:` guard, `latest-ipa` release retries, `henge-jit.js` 64 GiB VA bound check, GDB RSP error logging & preamble discard, `atomic_int` console pipe FD, `henge_virtio_gpu_is_virgl_ready()`, FNV-1a corruption & empty-`hvsparse` round-trip tests, cached console regexes, and `UIHingeInteraction` live posture observer.
- [x] **Milestone 5.8 — ARM Generic Timer Clock-Domain Alignment, PL011 UART Input Forwarding & PCIe-Aligned NVRAM (`3d6a8fe`, `40f19cb`, `cf6f1f0`):**
  - Fixed the `CNTVCT_EL0` / `CNTPCT_EL0` clock-domain deadlock in `scripts/apply_upstream_patches.py` by preserving Darwin's `COMMPAGE_TIMEBASE_OFFSET` (`0xfffffc088ull`) alongside `*hengelinux_negative_counter_offset_ptr()` in `core/translate.c` (`translate_counter()`) and aligning `core/dispatch.c` timer deadlines (`timer_due`, `next_due`, `wait_for_interrupt`) to `hv_counter()` (`CI Run #44243183836` green), ensuring EDK2's 10 ms `ArmTimerDxe` interrupt fires immediately on iPhones with non-zero sleep offsets.
  - Wired `henge_forward_hid_to_pl011()` in `ios/Sources/HengeVMBridge.mm` so on-screen and hardware HID key presses are forwarded as ASCII / VT100 escape sequences into `hv_pl011_receive(hv_winvm_board()->uart, ...)` alongside `hv_winvm_key_hid()`.
  - Updated `scripts/build_prebuilt_archlinux_arm64.sh` to configure `systemd-bootaa64.efi` with `timeout 0` and `console-mode keep`, match `HengeVM`'s GPEX PCIe slot layout (`00:01.0` `virtio-net-pci`, `00:02.0` `nvme` `WIN11IOS01`) in `VERIFY_BOOT=1`, and persist QEMU-initialized `verify_vars.fd` into `vars.fd`.
- [x] **Milestone 5.9–5.10 — Interactive Console Polish, Full-Frame Metal Hash & Pre-Configured LXQt Desktop (`5ce42f2`–`dd45fa9`):**
  - Kept `MetalDisplaySurfaceView` permanently first responder with `inputView` suppression for immediate Bluetooth keyboard input, added `usbcore.nousb` + `rcupdate.rcu_cpu_stall_timeout=300` to eliminate initrd xHCI stalls, patched `quick_frame_hash()` in `devices/fb_metal.m` to hash every scanline/qword for instant single-glyph rendering, added `henge-pacman-keyring.service` + `pacman.conf` `NoExtract`, and pre-configured `/etc/X11/xorg.conf.d/10-fbdev.conf`, `/etc/sddm.conf.d/hengelinux.conf` (`vt2` autologin), and `/usr/local/bin/henge-install-desktop`.
- [x] **Milestone 5.11 — Native Static C `/dev/uinput` HID Bridge, Editable Guest RAM & Full Special-Key Strip (`4809648`–`7319ac4`):**
  - Added user-editable **Guest RAM (MiB)** controls (`512`–`10,240 MiB` numeric field, stepper, slider, quick-pick chips) in `HengeLinuxApp.swift` and removed hardcoded silent `1,664 MiB` clamping in `HengeVMBridge.mm`.
  - Replaced Python guest scripts with a zero-dependency static ARM64 C binary (`guest/henge_dual_console.c`) that launches a direct interactive root login shell (`/bin/bash`), runs a stateful OSC `9999` parser, announces `HENGE_HID_READY` (gated in `host/henge_platform.{h,c}` + `HengeVMBridge.mm` so UEFI and older images never receive OSC bytes), and creates separate `/dev/uinput` `HengeLinux Virtual Keyboard` and `HengeLinux Virtual Tablet` devices for full X11/LXQt mouse, touch, scroll, and keyboard input even with `usbcore.nousb`.
  - Expanded `SessionView.swift`'s modifier strip to include all special keys (`Esc`, `Tab`, `Bck`, `Del`, `Shift`, `Ctrl`, `Alt`, `Super`, `Caps`, arrows, `Home`, `End`, `PgUp`, `PgDn`, `Ins`, `Prnt`, `ScrLk`, `Pause`, `Menu`, `F1`–`F12`, `Paste`, `CAD`) plus full `F1`–`F12` / `Insert` PL011 escape sequences in `HengeVMBridge.mm`.

---

## 5. Build & Verification Matrix

| Environment | Commands | Output Artifacts |
| :--- | :--- | :--- |
| **Linux PC (Ubuntu / Arch)** | `make HV_TLB_PAGE_BITS=12 test-core hvsparse`<br>`make HV_TLB_PAGE_BITS=14 test-core hvsparse`<br>`make prebuilt-guest-image` *(or `bash scripts/provision_archlinux_arm64.sh`)* | `build/test_core`, `build/hvsparse`, `build/prebuilt/archlinux.hvsparse` (or `work/archlinux.hvsparse`) |
| **Intel (`x86_64`) MacBook** *(macOS 26 / Xcode 26)* | `make test-core hvsparse ios-lib`<br>`xcodegen generate --spec ios/project.yml`<br>`xcodebuild -project ios/HengeLinux.xcodeproj -scheme HengeLinux -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build` | `build/ios/libhengelinux.a`, `HengeLinux.app` (sideload via SideStore / AltStore) |
| **Apple Silicon Mac** *(M1–M5, Xcode 26/27)* | Same as Intel MacBook + `xcrun devicectl device install app --device <UDID> ...` | Signed `HengeLinux.app` installed directly over USB/Wi-Fi |
| **GitHub Actions CI & Releases** *(No local Mac needed)* | `.github/workflows/ci.yml` + `.github/workflows/prebuilt-guest-image.yml` | Direct download [`HengeLinux-unsigned.ipa`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/HengeLinux-unsigned.ipa), [`archlinux.hvsparse`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/archlinux.hvsparse), [`code.fd`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/code.fd), and [`vars.fd`](https://github.com/venim1103/henge-linux/releases/download/latest-ipa/vars.fd) from `latest-ipa` |

---

## 6. Guest Artifact, StikDebug JIT & `pairing.plist` Provisioning Guide

*(See [`docs/SETUP.md`](docs/SETUP.md) for the complete end-user walkthrough.)*

Four files are used to boot Arch Linux in `HengeLinux` on iOS: `code.fd`, `vars.fd`, `archlinux.hvsparse`, and `henge-jit.js` (for StikDebug TXM JIT), plus optional `pairing.plist`.

### 6.1 Where Each File Comes From

| File | Required | Where to Get It |
| :--- | :--- | :--- |
| `code.fd` & `vars.fd` | **Yes** | Download directly from [`latest-ipa` Pre-Release](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa) (built by `.github/workflows/prebuilt-guest-image.yml`), or generate locally via `make prebuilt-guest-image` / `scripts/provision_archlinux_arm64.sh`. |
| `archlinux.hvsparse` | **Yes** | Download directly from [`latest-ipa` Pre-Release](https://github.com/venim1103/henge-linux/releases/tag/latest-ipa) (~294 MiB pre-configured Arch Linux ARM64 image), or build locally via `make prebuilt-guest-image` / `scripts/provision_archlinux_arm64.sh`. |
| `henge-jit.js` | **Yes** *(StikDebug)* | Download [`ios/Resources/henge-jit.js`](https://raw.githubusercontent.com/venim1103/henge-linux/main/ios/Resources/henge-jit.js) into **Files ▸ On My iPhone ▸ StikDebug**, then **long-press `HengeLinux` -> Assign Script -> `henge-jit.js`** in StikDebug. |
| `pairing.plist` | **Optional** *(In-App JIT)* | Exported from your iPhone over USB using `libimobiledevice` (`idevicepair pair` / `idevicepair validate`) or [`idevice_pair`](https://github.com/jkcoxson/idevice_pair), or reused from your existing SideStore / StikDebug pairing file. |

### 6.2 Step-by-Step: Local Build of `code.fd`, `vars.fd`, and `archlinux.hvsparse`

1. **Install prerequisites & build the `hvsparse` packer:**
   - **macOS:**
     ```bash
     brew install qemu
     make hvsparse
     ```
   - **Arch Linux / Debian / Ubuntu:**
     ```bash
     # Arch: sudo pacman -S qemu-system-aarch64 edk2-aarch64
     # Debian/Ubuntu: sudo apt install qemu-system-arm qemu-efi-aarch64
     make hvsparse
     ```
2. **Run the Arch Linux provisioner:**
   ```bash
   ./scripts/provision_archlinux_arm64.sh
   ```
   - Automatically downloads `archboot-...-aarch64-ARCH-latest-aarch64.iso`, verifies its SHA-256 checksum, creates 64 MiB `work/code.fd` and `work/vars.fd`, and boots the Archboot installer over your terminal console.
3. **Complete the Archboot installation inside QEMU:**
   - Run `setup` at the Archboot prompt and install Arch Linux onto `/dev/nvme0n1` with a GPT EFI System Partition (`/boot` or `/boot/efi`).
   - Include `console=tty0 console=ttyAMA0,115200` on the bootloader kernel command line so output renders on both the iOS Metal display (`tty0`) and serial debug logs (`ttyAMA0`).
   - Copy `guest/setup-arch-bridge.sh` and `guest/henge-xdg-open` into the guest and run `sudo ./setup-arch-bridge.sh` to configure VirtIO-Net DHCP (`10.0.2.15`), `$BROWSER`, and Safari OAuth/Passkey redirects.
   - Run `poweroff` inside the guest; `provision_archlinux_arm64.sh` then runs `./build/hvsparse pack work/archlinux.img work/archlinux.hvsparse`.
4. **Import onto iPhone / iPad:**
   - Transfer `work/code.fd`, `work/vars.fd`, and `work/archlinux.hvsparse` to your iOS device (via AirDrop, iCloud Drive, or USB Finder) and tap **Import Guest Files (hvsparse / code.fd / vars.fd)...** inside `HengeLinux`.

### 6.3 Exporting `pairing.plist` for In-App TXM JIT

- **macOS:** `brew install libimobiledevice && idevicepair pair && cp "/var/db/lockdown/$(idevice_id -l | head -n1).plist" ~/Desktop/pairing.plist`
- **Linux:** `sudo apt install libimobiledevice-utils && idevicepair pair && sudo cp "/var/lib/lockdown/$(idevice_id -l | head -n1).plist" ~/pairing.plist && sudo chown $USER ~/pairing.plist`
- **Windows / Cross-Platform GUI:** Use [`idevice_pair`](https://github.com/jkcoxson/idevice_pair) (the official SideStore / StikDebug pairing generator) to export `pairing.plist` or `.mobiledevicepairing`, then import it in `HengeLinux` via **Import pairing.plist / .mobiledevicepairing...**.

### 6.4 Automated Pre-Built Guest Image via GitHub Actions (Milestone 5.6–5.11 Architecture)

To eliminate manual QEMU provisioning on a desktop computer, Milestones 5.6–5.11 provide an automated `ubuntu-24.04-arm` GitHub Actions pipeline:
1. **Firmware Packaging & NVRAM Initialization:** Extracts `/usr/share/AAVMF/AAVMF_CODE.fd` -> `code.fd` (64 MiB) and `/usr/share/AAVMF/AAVMF_VARS.fd` -> `vars.fd` (64 MiB), then persists the QEMU-initialized `Boot0000` NVRAM written during the `VERIFY_BOOT=1` smoke test back into `vars.fd`.
2. **Non-Interactive Rootfs & ESP Provisioning (`scripts/build_prebuilt_archlinux_arm64.sh`):**
   - Allocates a sparse raw disk image (`archlinux.img`), partitions GPT (`256 MiB` `EFI System` FAT32 + `ext4` rootfs), formats filesystems, and extracts the official Arch Linux ARM (`ArchLinuxARM-aarch64-latest.tar.gz`) rootfs.
   - Installs Arch Linux ARM's native `systemd-bootaa64.efi` as `EFI/BOOT/BOOTAA64.EFI`, compiles the zero-dependency static ARM64 `guest/henge_dual_console.c` binary into `/usr/local/bin/henge-dual-console`, configures `/etc/fstab`, `/boot/loader/loader.conf` (`timeout 0`, `console-mode keep`), `/boot/loader/entries/arch.conf`, `/boot/startup.nsh`, `/etc/modules-load.d/uinput.conf`, `/etc/X11/xorg.conf.d/10-fbdev.conf`, `/etc/sddm.conf.d/hengelinux.conf`, `/usr/local/bin/henge-install-desktop`, and executes `guest/setup-arch-bridge.sh` inside the rootfs.
   - Runs a headless QEMU AArch64 ACPI 6.3 boot smoke test (`-machine virt,gic-version=3,acpi=on` with `00:01.0` `virtio-net-pci` and `00:02.0` `nvme` `WIN11IOS01` matching `HengeVM`) to verify UEFI -> `BOOTAA64.EFI` -> Linux kernel serial entry before packing `archlinux.img` into `archlinux.hvsparse`.
3. **Release Publishing:** Uploads `code.fd`, `vars.fd`, and `archlinux.hvsparse` (plus `SHA256SUMS.txt`) to the rolling `latest-ipa` GitHub Pre-Release alongside `HengeLinux-unsigned.ipa`.
