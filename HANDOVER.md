# `henge-linux` Project Handover Document

**Last Updated:** 2026-11-15
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
| *(HEAD)* | Added session handover document (`HANDOVER.md`) |

---

## 2. File Inventory & Implementation Status

| File Path | Status | Responsibility |
| :--- | :--- | :--- |
| `LICENSE` | Complete | GNU General Public License v3.0 (`GPL-3.0-or-later`) |
| `README.md` | Complete | Project overview, target device memory table, build environment matrix, and doc links |
| `PLAN.md` | Complete | Full Phase 1–5 implementation roadmap, module map, and platform invariants |
| `HANDOVER.md` | Complete | Session handover guide, file status, CI troubleshooting notes, and next-step checklist |
| `docs/RESEARCH.md` | Complete | Deep technical analysis of `WindowsiOS`/`HengeVM` and all 6 Linux-on-iOS approaches |
| `Makefile` | Complete (Phase 2–4) | Builds `test_core`, `hvsparse`, and Darwin `build/ios/libhengelinux.a`; auto-detects `/opt/homebrew` vs `/usr/local` |
| `host/henge_platform.{h,c}` | Complete | `<104`-byte Darwin `AF_UNIX` `sun_path` formatter (`henge_format_unix_socket_path`), `TCR_EL1` `TG0`/`TG1` granule decoder (`henge_decode_granule_bits`), 16 KiB RAM aligner (`henge_align_guest_ram_bytes`), and thread-safe render pause atomic (`hengelinux_set_render_paused`) |
| `host/henge_txm_jit.{h,c}` | Complete (C helpers) | Validates TXM low-VA window `[4 GiB, 64 GiB)` (`< 0x7000000000`), stamps/verifies byte-0 `0x69` page-blessing markers, checks `P_TRACED` debugger status, and allocates `LEDGER_NO_FOOTPRINT` guest RAM |
| `host/henge_brk.S` | Complete | ARM64 `brk #0xf00d` (`0xa0013ed4`) traps (`x16=1` prepare region, `x16=0` detach) |
| `host/henge_virtio_gpu.{h,c}` | Complete (Config layer) | Configures PCI `0x1af4:0x1050` VirtIO-GPU in `2D GOP` or `3D VirGL` (`capset 1 & 2` + `ANGLE Metal`) mode |
| `tools/hvsparse.c` | Complete | Zero-skipping 64 KiB sparse disk container packer/unpacker (`HVSP` v1 format) |
| `tests/test_core.c` | Complete | Unit tests for `sun_path` bounds, MMU granule decoding, RAM clamping/alignment, render pause gate, TXM VA bounds & `0x69` blessing, and VirtIO-GPU capsets |
| `ios/project.yml` | Complete | XcodeGen spec (`iOS 26.0`, `Swift 6.0`, `ARCHS: arm64`) building `HengeLinux` + embedded `HengeLinuxJITExtension` |
| `ios/HengeLinux.entitlements` | Complete | Requests `com.apple.developer.kernel.increased-memory-limit` |
| `ios/Sources/HengeLinuxApp.swift` | Complete (UI shell) | Launcher UI with device presets (`2,560 MiB`, `4,608 MiB`, `6,144 MiB`), GPU adapter picker, JIT status readout, `SafariSheetView`, and `willResignActive`/`didBecomeActive` lifecycle observers |
| `ios/Sources/SessionView.swift` | Complete (UI shell) | Hosts `MTKView` framebuffer, top status bar, clamshell split-deck mode, and compact modifier strip (`Esc`, `Tab`, `Ctrl`, `Alt`, `Super`, `F1/F2/F12`) |
| `ios/Sources/HingeSensorView.swift` | Complete | Runtime `NSClassFromString("UIHingeInteraction")` check so single-screen iPhones (iPhone 16 Pro) boot straight into full-screen canvas while offering a manual Split Deck toggle |
| `ios/Sources/MetalLifecycleGuard.swift` | Complete | Synchronously pauses `MTKView` and `CAMetalLayer.nextDrawable()` on `willResignActive` to prevent `gpus_ReturnNotPermittedKillClient` crashes |
| `ios/Sources/SelfDebugJITClient.swift` | Scaffolded | Checks `henge_txm_is_debugger_attached()` and `Documents/pairing.plist`; ready to wire XPC invocation of `HengeLinuxJITExtension` |
| `ios/JITExtension/JITExtensionHandler.swift` | Scaffolded | `com.apple.ar.viewer` `NSExtensionRequestHandling` entry point; ready to link `StikJIT.xcframework` + `idevice` |
| `guest/henge-xdg-open` | Complete | Python 3 guest URL opener & dual-stack (`127.0.0.1` / `[::1]` <-> `10.0.2.15`) OAuth callback relay talking to `http://10.0.2.4/.henge/` |
| `guest/setup-arch-bridge.sh` | Complete | Installs `henge-xdg-open` as `xdg-open`, configures `systemd-networkd` DHCP on `virtio_net`, and creates `/mnt/ios-share` |
| `scripts/sync_upstream.sh` | Complete | Clones/fetches `ammaarreshi/WindowsiOS` into `.upstream/WindowsiOS` |
| `scripts/build_ios_deps.sh` | Complete | Validates Homebrew (`/opt/homebrew` or `/usr/local`) and delegates iOS static library cross-compilation (`libffi`, `glib`, `libslirp`) |
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
  - Installs `xcodegen`, builds `make test-core hvsparse ios-lib` (`build/ios/libhengelinux.a`), generates `ios/HengeLinux.xcodeproj`, runs `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO build`, packages `build/HengeLinux-unsigned.ipa`, and uploads it as a GitHub Actions artifact (`HengeLinux-unsigned-ipa`).
  - **Sideloading from Linux or Intel Mac:** Download `HengeLinux-unsigned-ipa` from the latest green GitHub Actions run on your iPhone and sign/install it with **SideStore** or **AltStore**—no local Mac required.

### Resolved SDK / Toolchain Issues (Do Not Reintroduce)
1. **iPhoneOS SDK `<mach/mach_vm.h>`:** Public `iPhoneOS.sdk` headers fail compilation with `#error mach_vm.h unsupported.` Always use `<mach/mach.h>` instead.
2. **macOS `_POSIX_C_SOURCE`:** Defining `_POSIX_C_SOURCE` on `__APPLE__` hides BSD `u_int`/`u_char`/`u_short` types required by `<sys/sysctl.h>` and `MAP_ANON`. Gate `_POSIX_C_SOURCE` with `#if !defined(__APPLE__)`.
3. **XcodeGen `Info.plist`:** Always keep `GENERATE_INFOPLIST_FILE: YES` in `ios/project.yml` so `HengeLinux.app` and `HengeLinuxJITExtension.appex` emit valid `Info.plist` files.

---

## 4. Exact Next Steps (Phase 5 Bring-Up)

When continuing in a new chat window, start with **Phase 5.1 & 5.2** (wiring the actual `HengeVM` / `WindowsiOS` engine into `henge-linux`):

1. **Inspect & Link Upstream `WindowsiOS` Engine (`scripts/sync_upstream.sh` + `Makefile` + `ios/project.yml`):**
   - Run `sync_upstream.sh` in CI/build to pull `ammaarreshi/WindowsiOS` into `.upstream/WindowsiOS`.
   - Add compilation rules in `Makefile` (`ios-lib`) to build upstream `core/*.c` (`translate.c`, `memop.c`, `mmu.c`, `sysreg.c`, `cpu.c`, `jit.c`) and `devices/*.c` (`pcie.c`, `nvme.c`, `xhci.c`, `hda.c`, `virtio_net.c`, `fb_metal.m`, `audio_mac.c`, `share.c`) alongside `host/henge_*.c` into `build/ios/libhengelinux.a`.
   - Patch upstream `host/share.c` to call `henge_format_unix_socket_path()` (preventing >104-byte iOS sandbox `AF_UNIX` truncation) and patch `devices/fb_metal.m` + `host/audio_mac.c` to honor `hengelinux_is_render_paused()`.
2. **Wire SwiftUI Frontend to `HengeVM` Runtime (`ios/Sources/HengeVMBridge.{h,mm}`):**
   - Connect `SessionView.swift`'s `MTKView` drawable texture to `fb_metal.m`, forward touch/keyboard events to `devices/xhci.c`, and route `10.0.2.4/.henge/open-url` notifications to `HengeLinuxApp.safariURL` (`SafariSheetView`).
   - Load guest disk `Documents/Machines/ArchLinux/archlinux.hvsparse` and UEFI firmware `code.fd` / `vars.fd` with `selectedProfile.ramMiB` allocated via `henge_alloc_ledger_exempt_ram()`.
3. **Provision & Boot Arch Linux AArch64 Image:**
   - Run `make hvsparse && bash scripts/provision_archlinux_arm64.sh` on a Mac or Linux host, install Arch Linux via Archboot setup onto `/dev/nvme0n1`, run `sudo bash /path/to/guest/setup-arch-bridge.sh` inside the guest, and copy `archlinux.hvsparse`, `code.fd`, and `vars.fd` to the iPhone app's `Documents/Machines/ArchLinux/` folder.
4. **Embed `StikJIT` (`MPL-2.0`) + `idevice` (`MIT`) & 3D VirGL:**
   - Wire `SelfDebugJITClient.swift` to invoke `HengeLinuxJITExtension` over `NSExtensionContext` / XPC to perform live `brk #0xf00d` page blessing on-device without a tethered Mac.
   - Implement `virtio-gpu-gl-pci` (`0x1af4:0x1050`) backed by `virglrenderer` + `ANGLE (Metal)` for hardware-accelerated Wayland compositors (`Hyprland`, `Wayfire`, `Sway`).

---

## 5. Starter Prompt for a New Chat Window

Copy and paste the following into your next session to pick up immediately where this session left off:

> `@github-code-editor @GitHubCodeEditor Open venim1103/henge-linux and read HANDOVER.md and PLAN.md. Let's execute Phase 5.1: inspect upstream ammaarreshi/WindowsiOS core/ and devices/ layout via sync_upstream.sh, wire the core VM engine and devices into Makefile (libhengelinux.a) and ios/project.yml, and apply our iOS lifecycle pause and <104-byte AF_UNIX socket path patches.`
