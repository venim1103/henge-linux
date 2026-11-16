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
| `97da5b2`–`a2a3619` | Second 35-file audit pass (`extern "C"` ObjC++ linkage, 64-bit LE hex in `henge-jit.js`, `UIKeyInput`/`pressesBegan` HID keyboard, CAS monotonic `CNTVCT_EL0` clamp, serialized macOS CI release builds) |
| `8a63cdd` | Replaced C preprocessor token-pasting macros in `host/henge_brk.S` with explicit `.globl _henge_jit26_*` labels under `#if defined(__APPLE__)` for Darwin Clang `.S` assembler |
| `469f5d9` | Documented 4-batch P0–P2 code audit findings and Run `#43925931666` `AudioToolbox.framework` linker order diagnosis in `HANDOVER.md`, `PLAN.md`, and `README.md` |
| `ca83def` | Applied P0/P1 fixes: `-framework AudioToolbox` link order in `ios/project.yml`, upstream `"HVSPARSE"` extent format in `tools/hvsparse.c` + first-boot `hv_sparse_unpack` in `HengeVMBridge.mm`, `CNTVCT_EL0` decoupling from `willResignActive` in `host/henge_platform.c`, `BRK` mask + `try/finally` `Detach` in `henge-jit.js`, `volatile sig_atomic_t` + signal fence + low-VA hold restore in `host/henge_txm_jit.c`, `Task.detached` JIT probe in `SelfDebugJITClient.swift`, and persistent C-strings in `HengeVMBridge.mm` |
| `9e52c66` | Applied P1/P2 fixes: passive `/proc/net/tcp{,6}` polling & `127.0.0.0/8` / `302` grace window in `guest/henge-xdg-open`, `rw != rx` guard in `scripts/apply_upstream_patches.py`, `.asciiCapable` + sticky modifier auto-release + real 2-finger tap/scroll in `SessionView.swift`, `NSNumber` XPC unboxing in `JITExtensionHandler.swift`, `-MMD -MP` deps in `Makefile`, and updated `tests/test_core.c` |
| `01f5747` | Passed `NULL` progress callbacks to 4-arg upstream `hv_sparse_unpack` in `HengeVMBridge.mm` (CI Run `#43965382351` green across Linux tests, macOS `.ipa` packaging, and `latest-ipa` release) |
| `0b1ec65` *(HEAD)* | Milestone 5.4 Track 1: wired `HengeJITExtensionBridge.{h,mm}`, `SelfDebugJITClient.swift` App Group `pairing.plist` sync + concurrent XPC/worker pool polling, and `JITExtensionHandler.swift` `10.7.0.1` GDB RSP `brk #0x69`/`#0xf00d` page blesser (CI Run `#43966740382` green) |

---

## 2. File Inventory & Implementation Status

| File Path | Status | Responsibility |
| :--- | :--- | :--- |
| `LICENSE` | Complete | GNU General Public License v3.0 (`GPL-3.0-or-later`) |
| `README.md` | Complete | Project overview, target device memory table, build environment matrix, and doc links |
| `PLAN.md` | Complete | Full Phase 1–5 implementation roadmap, module map, platform invariants, and P0–P2 audit backlog |
| `HANDOVER.md` | Complete | Session handover guide, file status, CI troubleshooting notes, and prioritized P0–P2 fix checklist |
| `docs/RESEARCH.md` | Complete | Deep technical analysis of `WindowsiOS`/`HengeVM` and all 6 Linux-on-iOS approaches |
| `Makefile` | Needs P2 Polish | Builds `test_core`, `hvsparse`, and `build/ios/libhengelinux.a` (needs `-MMD -MP` header dependency tracking + `HV_TLB_PAGE_BITS` stamp) |
| `host/henge_platform.{h,c}` | Needs P0/P1 Fix | Darwin `<104B` `sun_path`, `TCR_EL1` decoder, RAM aligner, render mutex, and `CNTVCT_EL0` compensation (**P0:** decouple `CNTVCT_EL0` freeze from `willResignActive`; **P1:** `pthread_once` on Intel `mach_timebase_info`, `pipe2` flag check, UUID validation) |
| `host/henge_txm_jit.{h,c}` | Needs P0/P1 Fix | TXM `[4 GiB, 64 GiB)` validator, `0x69` blessing, `P_TRACED` vs `CS_DEBUGGED`, and `LEDGER_NO_FOOTPRINT` RAM (**P0/P1:** `volatile sig_atomic_t` + signal fence, `henge_txm_is_ptraced()` probe gate, restore low-VA hold on all error paths, custom Mach-O section, `vm_allocate` Apple fallback) |
| `host/henge_brk.S` | Complete (P2 optional) | ARM64 `brk #0xf00d` / `brk #0x69` traps with `.cfi_startproc`, `hint #34` (`bti c`), and explicit Darwin `_henge_jit26_*` labels (optional: `.subsections_via_symbols` + `mov x16, #0` in probe) |
| `host/henge_virtio_gpu.{h,c}` | Complete (Phase 5.4) | VirtIO-GPU 1.0 PCI (`0x1af4:0x1050`) 2D/3D VirGL control-queue state machine (`num_capsets` + `capset_mask`, `CTX_CREATE`, `RESOURCE_CREATE_3D`, `SUBMIT_3D`, `SET_SCANOUT`, `RESOURCE_FLUSH`, `ANGLE Metal` probe) and atomic FNV-1a checksummed background VM state snapshots (`henge_vm_snapshot_write`/`read`) |
| `tools/hvsparse.c` | Needs P0 Fix | Sparse disk packer/unpacker (**P0 boot-blocker:** currently writes custom `"HVSP"` 64 KiB block table instead of upstream `WindowsiOS` `"HVSPARSE"` streaming `[offset, len]` extent archive) |
| `tests/test_core.c` | Needs P2 Polish | Unit tests for `sun_path`, MMU granules, RAM alignment, render fence, TXM VA bounds, and VirtIO-GPU capsets (update for `"HVSPARSE"` & clock-domain separation) |
| `ios/project.yml` | Needs P1 Fix | XcodeGen spec (`iOS 26.0`, `Swift 6.0`, `C++20`) (**P1 CI blocker:** add `-framework` / `AudioToolbox` after `-lhengelinux` in `OTHER_LDFLAGS`; optional pre-build script for `libhengelinux.a`) |
| `ios/JITExtension/Info.plist` | Complete | Explicit `Info.plist` with nested `NSExtension` dictionary (`com.apple.ar.viewer`) for PlugInKit / SideStore validation |
| `ios/JITExtension/JITExtensionHandler.swift` | Needs P2 Fix | `com.apple.ar.viewer` `NSExtensionRequestHandling` entry point (**P2:** unbox `targetPID` / `poolBytes` via `as? NSNumber` before Milestone 5.4 `StikJIT`/`idevice` XPC linkage) |
| `ios/Resources/henge-jit.js` | Needs P0 Fix | StikDebug / LLDB GDB RSP `brk #0xf00d` / `brk #0x69` script (**P0:** verify ARM64 `BRK` mask `((instrU32 & 0xFFE0001F) >>> 0) === 0xD4200000`, wrap loop in `try/finally` sending `D` so early `break` never freezes `P_TRACED`, add `p<reg>` fallback) |
| `ios/HengeLinux.entitlements` | Complete | Requests `com.apple.developer.kernel.increased-memory-limit` |
| `ios/Sources/HengeVMBridge.{h,mm}` | Needs P0/P1 Fix | ObjC++/C++20 VM bridge (**P0:** unpack `.hvsparse` into `archlinux.img` before `cfg.disk0`; **P1:** persist `HvWinVmConfig` C-strings in `std::string` ivars, guard redundant `attachDisplayLayer:`, lower untethered RAM cap to `1,536 MiB`) |
| `ios/Sources/HengeLinuxApp.swift` | Needs P1/P2 Fix | Launcher UI, RAM cap, JIT boot, `SafariSheetView` polling (**P1:** avoid double `henge_jit_acquire_pool` call; **P2:** make `UIPasteboard` sync opt-in) |
| `ios/Sources/SessionView.swift` | Needs P1/P2 Fix | Metal framebuffer host, keyboard & trackpad (**P1/P2:** `.asciiCapable` + `.smartInsertDeleteType = .no`, auto-release sticky modifiers, real 2-finger tap/scroll on clamshell trackpad, `dismantleUIView` guard) |
| `ios/Sources/HingeSensorView.swift` | Complete | Runtime `NSClassFromString("UIHingeInteraction")` check + manual Split Deck toggle |
| `ios/Sources/MetalLifecycleGuard.swift` | Complete | Synchronous `NotificationCenter` `willResignActive`/`didBecomeActive` observers + `withRenderLock` render fence |
| `ios/Sources/SelfDebugJITClient.swift` | Needs P1 Fix | TXM JIT activation state machine (**P1:** offload blocking `henge_jit_acquire_pool` from `@MainActor` via `Task.detached` to prevent UI freeze and Milestone 5.4 XPC `MainQueue` deadlock) |
| `guest/henge-xdg-open` | Needs P1 Fix | Non-blocking double-fork guest URL opener & OAuth relay (**P1:** replace active `connect_ex` probe with passive `/proc/net/tcp{,6}` `TCP_LISTEN` check, support `127.0.0.0/8` + extra redirect keys, avoid premature `oauth-done` on `302`/favicon, log gateway errors before daemonizing) |
| `guest/setup-arch-bridge.sh` | Needs P2 Fix | Installs `henge-xdg-open`, `systemd-networkd` DHCP, and `/mnt/ios-share` (**P2:** avoid `/usr/bin/xdg-open` wrapper recursion loop and handle `arch-chroot` `/etc/resolv.conf`) |
| `scripts/sync_upstream.sh` | Needs P2 Polish | Initializes/fetches `ammaarreshi/WindowsiOS` (`0071d697`) and invokes `apply_upstream_patches.py` |
| `scripts/apply_upstream_patches.py` | Needs P1 Fix | Idempotently patches upstream `share.c`, `fb_metal.m`, `audio_mac.c`, `jit_region.c`, `sysreg.c`, and `translate.c` (**P1:** check `rw != NULL && rw != rx` in `jit_region.c`, silence audio capture when paused) |
| `scripts/build_ios_deps.sh` | Needs P2 Polish | Cross-compiles and validates cached iOS arm64 static libraries (`libffi`, `glib`, `libslirp`, `libintl`, `libpcre2-8`) |
| `scripts/provision_archlinux_arm64.sh` | Needs P2 Polish | Downloads Archboot AArch64 ISO, boots QEMU `virt` + EDK2 + NVMe, and packs `archlinux.hvsparse` |
| `.github/workflows/ci.yml` | Needs P0/P2 Fix | Runs Linux C tests and macOS XcodeGen + unsigned `.ipa` build (**P0:** update `hvsparse` round-trip check for `"HVSPARSE"` format; **P2:** dynamic Xcode version cache key) |

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
7. **Darwin Clang `.S` Preprocessor & `AudioToolbox.framework` Linker Order:** Darwin's `.S` driver does not expand C preprocessor token-pasted `_##name` labels (keep explicit `.globl _henge_jit26_*` blocks in `host/henge_brk.S`), and `ld` resolves `.tbd` framework stubs in `HengeLinux-linker-args.resp` *before* `OTHER_LDFLAGS` (`-lhengelinux`), so `-framework` / `AudioToolbox` must appear *after* `-lhengelinux` in `ios/project.yml` `OTHER_LDFLAGS` to resolve `up_host_audio_mac.o` symbols.

---

## 4. Verified Upstream `WindowsiOS` Layout & Prioritized Audit Backlog (P0–P2)

We inspected `ammaarreshi/WindowsiOS` (`0071d6975287fd720b9046dfd3bd80b6f2aa765e`) alongside a 4-batch deep review across all 35 files in `venim1103/henge-linux`:
- **Core DBT & MMU (`core/`):** `classify.c`, `operands.c`, `translate.c`, `dispatch.c`, `mmu.c` (compiled with `-mgeneral-regs-only`), `memop.c`, `exception.c`, `sysreg.c`, `machine.c`.
  - *Verified in `core/mmu.c:169-187`:* `current_asid()` and `hv_mmu_ukey()` already inspect `TCR_EL1.A1` (bit 22) and `TCR_EL1.AS` (bit 36) dynamically, so Linux `A1=0` (`TTBR0_EL1`) ASIDs and `ASID=0` KPTI transitions work without modification.
  - *Verified in `core/sysreg.c:18-25`:* `ID_AA64ISAR1` (`0x0000001100211001ull`) and `ID_AA64PFR0` (`0x1100000001110011ull`) already mask out PAuth (`APA`/`API`/`GPA`), SVE, and MTE, preventing `APIAKeyLo_EL1` MSR trap storms on Linux context switches.
  - *Verified in `devices/timer.c:14`:* `hv_timer_update()` reads `hv_counter()` from `core/sysreg.c`, which inherits `hengelinux_compensated_counter(mach_absolute_time())`.
  - *Verified in `host/hvsparse.c` & `THIRD_PARTY_NOTICES.md:3`:* Upstream `WindowsiOS` uses a 16-byte `"HVSPARSE"` + `uint64_t size` header followed by streaming `[uint64_t offset, uint64_t len]` (`<= 8 MiB`) extents terminated by `{0, 0}`, unpacked once on-device via `hv_sparse_unpack(sparse_path, raw_img_path)` into an APFS sparse raw image (`ftruncate` holes cost 0 bytes on iOS APFS) before `host/disk.c` opens it as a raw NVMe image. All `WindowsiOS`/`Henge`/`Husk` code is `GPL-2.0-or-later` (upgrading cleanly into `GPL-3.0-or-later`).
- **Host Primitives (`host/`):** `jit_region.c`, `enter.S`, `disk.c`, `winvm.c`, `net_slirp.c`, `share.c`, `audio_mac.c`, `hvsparse.c`.
- **Virtual Devices (`devices/`):** `fb_metal.m`, `nvme.c`, `pcie.c`, `gicv3.c`, `xhci.c`, `hda.c`, `virtio_net.c`, `acpi.c`, `fdt.c`, `fw_cfg.c`, `pflash.c`, `pl011.c`, `pl031.c`, `pl061.c`, `timer.c`, `virtio.c`, `virtio_blk.c`, `virtio_input.c`, `virtio_snd.c`, `winvirt.c`.

### Priority 0 (P0) — Boot-Blockers & Critical Runtime / Debugger Traps (Fix First)
1. **`tools/hvsparse.c` + `.github/workflows/ci.yml` + `ios/Sources/HengeVMBridge.mm` (`"HVSPARSE"` Wire-Format Alignment):**
   - Replace the custom `"HVSP"` 64 KiB block-table format in `tools/hvsparse.c` with upstream `WindowsiOS`'s `"HVSPARSE"` streaming extent format (`"HVSPARSE"` 8B + `uint64_t size` 8B + `[uint64_t offset, uint64_t len]` `<= 8 MiB` extents using 64 KiB chunk granularity, terminated by `{0, 0}`, with overflow-safe bounds checks `rec[1] > CHUNK || rec[0] > size - rec[1]`).
   - Update `.github/workflows/ci.yml` round-trip validation to verify `"HVSPARSE"` headers/extents, and update `HengeVMBridge.mm` to unpack `archlinux.hvsparse` into `archlinux.img` on first boot (or whenever `.hvsparse` is newer) before passing `cfg.disk0` to `hv_winvm_create()`.
2. **`host/henge_platform.c` (`CNTVCT_EL0` Guest Timer Freeze on `willResignActive`):**
   - Decouple `g_render_paused` (which must remain exclusively for `fb_metal.m` / `audio_mac.c` when `willResignActive` fires) from `hengelinux_compensated_counter()`. Currently, opening `SafariSheetView` (Face ID / Passkey sheets), Notification Center, Control Center, or running in the background with `UIBackgroundModes: [audio]` sets `g_render_paused = true` and freezes `CNTVCT_EL0`/`CNTPCT_EL0` while vCPU threads still execute—stalling OAuth callbacks, TLS/HTTP timeouts, `nanosleep`/`epoll_wait`, and Linux RCU grace periods.
   - Compensate only for genuine XNU process suspension by detecting unscheduled wall-clock jumps (`raw_ticks - prev_raw > 12000000ULL`, i.e., `> 500 ms` without intermediate ticks) or gating on a separate `g_vm_clock_paused` flag tied strictly to vCPU suspension.
3. **`ios/Resources/henge-jit.js` (`BRK` Opcode Mask Verification & Frozen `P_TRACED` Prevention):**
   - Verify the ARM64 `BRK #imm16` opcode mask using unsigned 32-bit shift `((instrU32 & 0xFFE0001F) >>> 0) === 0xD4200000` (preventing signed JS int32 negative overflow on `0xD42...` and avoiding `PC`/`x0` corruption if stopped on non-`brk` signals/instructions whose bits `[20:5]` equal `0x0069` or `0xf00d`).
   - Wrap the `while (!detached)` loop in `try { ... } finally { if (!detached) { send_command('D'); detached = true; } }` so early `break` exits never leave `HengeLinux` permanently suspended under `P_TRACED`, forward benign signals instead of aborting, and add a `readReg()` fallback (`p<reg>;thread:<tid>;`) if an expedited `T` stop-reply omits GPRs.
4. **`host/henge_txm_jit.c` (Signal-Handler UB, Low-VA Hold Restoration & Symmetric Apple Allocator):**
   - Change `g_expecting_jit_trap` from `_Thread_local bool` to `_Thread_local volatile sig_atomic_t` with `atomic_signal_fence` around `henge_jit26_probe()` / `henge_jit26_prepare_region()` / `henge_jit26_detach()` to prevent Clang `-O2`/LTO dead-store elimination, and gate `henge_jit26_probe()` strictly on `henge_txm_is_ptraced()`.
   - Call `restore_low_va_hold(bytes)` on all `vm_remap` / `vm_protect` / `verify_rx_rw_selftest` failure paths, isolate `g_jit_low_hold` in a dedicated custom Mach-O section (e.g., `__DATA,__jit_hold`), and replace the Apple `mmap()` fallback in `henge_alloc_ledger_exempt_ram()` with `vm_allocate()` to match `vm_deallocate()` in `henge_free_ledger_exempt_ram()`.

### Priority 1 (P1) — CI Linker Fix, Thread Safety, Lifecycle & Guest OAuth Reliability
5. **`ios/project.yml` (Fix Run #43925931666 `AudioToolbox` Linker Failure):**
   - Add `"-framework"` and `"AudioToolbox"` after `"-lhengelinux"` in `OTHER_LDFLAGS` so `ld` resolves `_AudioComponentFindNext`, `_AudioQueueNewInput`, and `_AudioUnitInitialize` referenced by `libhengelinux.a(up_host_audio_mac.o)`.
6. **`ios/Sources/SelfDebugJITClient.swift` & `HengeLinuxApp.swift` (`@MainActor` Freeze / XPC Deadlock & Double Probe):**
   - Offload blocking `henge_jit_acquire_pool()` (`nanosleep` + `brk #0xf00d` page blessing) from `@MainActor` onto `Task.detached(priority: .userInitiated)` so SwiftUI renders `"Blessing Pages..."` immediately and Milestone 5.4 `NSExtension` XPC callbacks never deadlock `MainQueue`.
   - Avoid invoking `henge_jit_acquire_pool()` twice back-to-back on untethered boot taps between `prepareSession()` and `HengeVMBridge.startGuest()`.
7. **`ios/Sources/HengeVMBridge.mm` (Persistent `HvWinVmConfig` Strings, Layer Churn & Untethered RAM Cap):**
   - Store `code_fd`, `vars_fd`, `disk0`, `share_dir`, and `share_sock` in persistent `std::string` ivars on `HengeVMBridge` instead of transient `NSURL.path.UTF8String` pointers and stack-local `char shareSockPath[104]`.
   - Short-circuit `attachDisplayLayer:` when `_displayLayer == layer`, and lower the non-`CS_DEBUGGED` untethered RAM cap from `2,048 MiB` to `1,536 MiB` to prevent Jetsam kills alongside JIT + Metal overhead.
8. **`guest/henge-xdg-open` (Passive `/proc/net/tcp{,6}` Polling & OAuth Redirect Edge Cases):**
   - Replace active `connect_ex()` + immediate `close()` probes in `is_port_listening()` (which poison single-shot OAuth HTTP listeners like `HTTPServer.handle_request()` / `nc`) with passive `/proc/net/tcp` and `/proc/net/tcp6` `st == 0A` (`TCP_LISTEN`) inspection.
   - Support full `127.0.0.0/8` loopback extraction plus `return_to`/`next`/`continue`/`post_logout_redirect_uri` query keys, trigger `oauth-done` only on `2xx` or off-loopback `3xx` redirects (with a brief grace window so `/favicon.ico` or local redirect targets finish loading), and log `gateway_put` failures to `sys.stderr` before `daemonize_background()` detaches stdio.
9. **`host/henge_platform.c`, `host/henge_txm_jit.c` & `scripts/apply_upstream_patches.py` (Guards & Patch Symmetry):**
   - Guard Intel `x86_64` `mach_timebase_info(&tb)` initialization in `platform_raw_ticks_24mhz()` with `pthread_once`, reject invalid `pipe2()` flags with `EINVAL`, validate UUID container paths in `format_ios_sandbox_tmp_socket()`, and deprecate/remove unsynchronized `henge_jit_status_message()` in favor of `henge_jit_copy_status()`.
   - In `scripts/apply_upstream_patches.py`, verify `rw != NULL && rw != rx` in `host/jit_region.c` and silence CoreAudio input capture alongside playback in `host/audio_mac.c` when render-paused.

### Priority 2 (P2) — Input Ergonomics, Scripting, Build Hygiene & Licensing
10. **`ios/Sources/SessionView.swift` & `HengeLinuxApp.swift`:** Set `.keyboardType = .asciiCapable` and `.smartInsertDeleteType = .no`, auto-release sticky `Ctrl`/`Alt`/`Super` modifiers after key press, implement real 2-finger tap (right-click) and 2-finger pan (scroll) on the clamshell trackpad, guard `dismantleUIView` layer detach, and make `didBecomeActive` `UIPasteboard` sync opt-in.
11. **`ios/JITExtension/JITExtensionHandler.swift` & `host/henge_brk.S`:** Unbox `targetPID` / `poolBytes` via `(dict["..."] as? NSNumber)?.int32Value` / `uint64Value` instead of strict Swift casts; optionally append `.subsections_via_symbols` and `mov x16, #0` in `_henge_jit26_probe`.
12. **`Makefile`, `scripts/*.sh`, `.github/workflows/ci.yml` & `THIRD_PARTY_NOTICES.md`:** Add `-MMD -MP` header dependency generation (`-include $(DEPS)`) and `HV_TLB_PAGE_BITS` stamp tracking in `Makefile`; prevent `/usr/bin/xdg-open` wrapper recursion and handle `arch-chroot` `/etc/resolv.conf` in `guest/setup-arch-bridge.sh`; harden `scripts/provision_archlinux_arm64.sh`, `scripts/sync_upstream.sh`, `scripts/build_ios_deps.sh`, and `tests/test_core.c` clock domains; track Xcode version in CI cache keys; add `THIRD_PARTY_NOTICES.md` + GPLv3 §5a modification notices.

### Remaining Feature & Hardware Milestones
- **[OPEN / Milestone 5.3 Hardware Check] Guest Image Provisioning & `HV_TLB_PAGE_BITS=12` vs `14`:** Run `make hvsparse && bash scripts/provision_archlinux_arm64.sh`, install Arch Linux onto `/dev/nvme0n1` with `console=tty0 console=ttyAMA0,115200`, run `sudo bash /path/to/guest/setup-arch-bridge.sh`, and verify on physical iPhone/iPad (`Files -> On My iPhone -> HengeLinux -> Machines/ArchLinux/`).
- **[LANDED (Scaffold + GDB RSP + XPC Bridge) / Milestone 5.4 Track 1] In-App `StikJIT` (`MPL-2.0`) + `idevice` (`MIT`) XPC Blessing:** `HengeJITExtensionBridge.{h,mm}`, `SelfDebugJITClient.swift` (App Group `group.io.hengelinux.shared` sync + concurrent XPC/worker pool acquisition), and `JITExtensionHandler.swift` (`pairing.plist` validation, `#if canImport(StikJIT)` / `#if canImport(Idevice)` hooks, and pure-Swift `10.7.0.1` GDB RSP `brk #0x69` / `brk #0xf00d` page blesser) are wired; drop `StikJIT.xcframework` + `idevice.xcframework` into `ios/Frameworks/` to enable automatic RSD `debugproxy` tunnel creation without a manual `debugserverPort`.
- **[LANDED (Control Queue + Snapshot Runtime) / Milestone 5.4 Track 2] 3D VirtIO-GPU (`virtio-gpu-gl-pci`, `0x1af4:0x1050`) & Background State Snapshots:** `host/henge_virtio_gpu.{h,c}`, `HengeVMBridge.{h,mm}`, and `HengeLinuxApp.swift` implement the VirtIO-GPU 1.0 2D/3D VirGL control-queue command processor (`CTX_CREATE`, `RESOURCE_CREATE_3D`, `SUBMIT_3D`, `SET_SCANOUT`, `RESOURCE_FLUSH`, `num_capsets` accounting, `virglrenderer` + `ANGLE Metal` probe) and atomic FNV-1a checksummed background VM snapshot persistence (`suspend.state`) on `didEnterBackground`; next: link static `libvirglrenderer.a` + `ANGLE` (`libEGL.a`/`libGLESv2.a`) into `ios/deps/` when building Mesa Wayland compositors (`Hyprland`, `Wayfire`, `Sway`).

---

## 5. Starter Prompt for a New Chat Window

Copy and paste the following into your next session to start working through the P0/P1 fixes immediately:

> `@github-code-editor @GitHubCodeEditor Open venim1103/henge-linux and read HANDOVER.md and PLAN.md. Let's execute the Priority 0 and Priority 1 fixes from the 4-batch audit and Run #43925931666: (1) fix AudioToolbox.framework linker order in ios/project.yml, (2) align tools/hvsparse.c, ci.yml, and HengeVMBridge.mm with upstream WindowsiOS's "HVSPARSE" streaming extent format + first-boot raw image unpack, (3) decouple CNTVCT_EL0 suspend compensation in host/henge_platform.c from willResignActive g_render_paused, (4) harden ios/Resources/henge-jit.js (BRK mask check + try/finally Detach + p<reg> fallback) and host/henge_txm_jit.c (volatile sig_atomic_t + signal fence + low-VA hold restore), and (5) fix SelfDebugJITClient.swift @MainActor blocking, HengeVMBridge.mm persistent C-strings, and guest/henge-xdg-open passive /proc/net/tcp{,6} polling.`
