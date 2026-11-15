# Running Arch Linux on Modern iOS: Technical Review of WindowsiOS and Next-Generation Execution Architectures

## Executive Summary

The exact architecture that enabled **`WindowsiOS`** (`ammaarreshi/WindowsiOS`) to run unmodified retail Windows 11 24H2 ARM64 on Apple's foldable iPhone Duo (`iPhone19,4`, Apple A20 Pro, iOS 27) can be adapted to run **Arch Linux (`aarch64`)**, and its underlying design is in several ways a cleaner architectural fit for Linux than for Windows.

While standard UTM on non-jailbroken iOS 16.4 through iOS 27 is constrained by Apple's restriction of `Hypervisor.framework` (`com.apple.developer.kernel.hypervisor`), QEMU's cross-architecture Tiny Code Generator (TCG) translation overhead, and strict ~3 GB iOS Jetsam memory kills, `WindowsiOS` routes around all three barriers. Built on top of Leviidev's open-source **`Henge`** (`HengeVM`) macOS-on-iOS engine, `WindowsiOS` combines a direct **ARM64-to-ARM64 dynamic block translator** and **stage-1 software Memory Management Unit (MMU)** with a **384 MiB dual-mapped Trusted Execution Monitor (TXM) JIT pool** and **4.5 GB (4,608 MiB) of ledger-exempt guest RAM** (`LEDGER_NO_FOOTPRINT`).

Because `WindowsiOS` already emulates a complete UEFI + ACPI 6.3 + PCIe GPEX virtual motherboard with NVMe 1.4 storage, USB 3.0 xHCI touch and keyboard input, Intel ICH6 full-duplex HD Audio, and VirtIO-Net networking, a mainline `aarch64` Arch Linux system can boot on this virtual hardware using standard inbox Linux kernel drivers without binary patches or external driver injection. Furthermore, whereas Windows 11's `ntoskrnl.exe` forces `WindowsiOS` to translate 4 KiB virtual memory pages on top of iOS's 16 KiB host page size—and consumes 1.46 GB of RAM at idle even after an offline optimizer strips more than 35 background components—the `WindowsiOS` software MMU (`core/mmu.c`) natively supports **4 KiB, 16 KiB, and 64 KiB translation granules** (`TG0`/`TG1`), allowing an Arch Linux guest to run a 16 KiB page-size kernel that aligns 1:1 with the Darwin host while leaving over 3.5 GB of RAM free for user workloads.

Two caveats of `WindowsiOS` should be kept in mind:
1. No independent comparative benchmarks have been published alongside the repository to quantify its "near-native" speed claims.
2. Its display pipeline (`devices/fb_metal.m`) is currently a 2D BGRA8 software framebuffer presented via Metal at 60/120 Hz rather than a 3D hardware-accelerated GPU.

---

## 1. Deconstructing WindowsiOS: Bypassing Stock iOS 26/27 Barriers

Between iOS 16.4 and iOS 27, Apple introduced three system-level restrictions that limit traditional virtual machines on non-jailbroken devices:

1. **Hypervisor Entitlement Lockout (iOS 16.4+):** Apple restricted `com.apple.developer.kernel.hypervisor` on non-jailbroken devices, cutting off hardware EL2 virtualization (`Hypervisor.framework` / `UTM HV`) for sideloaded and App Store apps.
2. **Trusted Execution Monitor (TXM) & SPTM Enforcement (iOS 26/27):** On A18–A20 Pro chips running iOS 26 and iOS 27, TXM and the Secure Page Table Monitor (SPTM) enforce hardware page-table signing. Regular processes cannot call `mprotect` to mark anonymous memory executable (`PROT_EXEC`) or use standard `MAP_JIT` without an active debugger handshake.
3. **Jetsam Mach Ledger Kills (~3 GB Ceiling):** The XNU kernel's Jetsam daemon tracks per-process anonymous memory footprints via Mach ledgers and terminates standard apps without a dialog once resident memory exceeds roughly 3 GB.

App Store emulators such as **UTM SE** fall back to QEMU's Tiny Code Generator Threaded Interpreter (`TCI`), which is 5–10x slower than JIT, takes tens of minutes to reach a desktop, and struggles with multi-process Chromium/Electron workloads. Sideloaded **UTM** with QEMU TCG JIT still incurs cross-architecture IR lifting overhead and remains vulnerable to Jetsam kills if guest RAM plus QEMU overhead breaches the ~3 GB process ceiling.

### The Four-Layer Architecture of `WindowsiOS` and `HengeVM`

`WindowsiOS` (`GPL-2.0-or-later`) builds on **`Leviidev/Henge`** (`HengeVM`), an ARM64 dynamic binary translator created in November 2026 that boots unmodified macOS Sequoia through macOS 27.2 on an iPhone 17 Pro in ~15 seconds, alongside networking/JIT patterns from **`Leviidev/Husk`**, guest runtime concepts from **`mxhm11cr/LinuxRunner`**, and debugger scripts from **`StephenDev0/StikDebug`**.

#### 1.1 Same-Architecture ARM64-to-ARM64 Block Translation (`core/translate.c`)
Because both guest (Windows 11 ARM64 or Arch Linux AArch64) and host (Apple A14–A20 Pro / M1–M5) execute 64-bit ARM instructions, `HengeVM` avoids QEMU's multi-stage intermediate representation. Unprivileged user-mode computation instructions execute directly on host silicon, while privileged instructions (`MSR`/`MRS` system register accesses, exceptions, TLB operations) and guest memory accesses are rewritten inline against virtual CPU state (`core/cpu.h`, `core/sysreg.c`).

Targeted enhancements added in `WindowsiOS` (`core/translate.c`, `core/memop.c`) for multi-process Chromium (`msedge.dll`) and Electron (`Antigravity.exe`) apply directly to Linux guests:
- **Inline ARMv8.1 LSE Atomics:** Lowers 64-bit and 128-bit exclusive atomic operations into inline Apple Silicon `LDP` and `CASPAL` fast paths.
- **Zero-Register Exclusive Monitor Fix (`rt == 31`):** Resolves a deadlock/corruption bug triggered when Clang-compiled Chromium and Electron binaries emit `ldxr xzr, [rn]` to arm exclusive monitors.
- **Unaligned `FEAT_LRCPC2` Accesses (`LDAPUR`/`STLUR`):** `translate_mem_impl()` enforces an inline alignment mask (`host_align`): aligned RCpc accesses execute inline in a single instruction, while unaligned accesses branch out-of-line to software-fenced helpers.

#### 1.2 Stage-1 Software MMU and TLB Stash (`core/mmu.c`)
Without `Hypervisor.framework`, `core/mmu.c` implements a complete **VMSAv8-64 Stage-1 software MMU** in user space for `EL1&0` across 48-bit virtual and physical address spaces:
- Compiled with `-mgeneral-regs-only` so page-table walks never corrupt guest SIMD/NEON registers.
- Maintains 4-way per-privilege software TLB tables (`[EL0, EL1, EL1+PAN]` packed in 128-byte cache lines), 2 MiB and 1 GiB large-page Bloom filters (`large_2m_bloom`, `large_big_bloom`), and a 16-table, 2-way set-associative **Indirect Jump Cache (`IJC`)** (`hv_ijc_resolve`) that maps virtual branch targets directly to executable host blocks while verifying physical page-generation counters (`page_gen`) to detect self-modifying code.
- Includes an ASID-keyed `HvTlbStash` that preserves live user TLB entries across context switches when an OS transiently switches ASIDs.

#### 1.3 iOS 26/27 TXM Bypass via `brk #0xf00d` and `0x69` Page Blessing (`winios_jit.c`, `winios_brk.S`)
To obtain executable JIT memory under iOS 26/27 TXM without a jailbreak:
1. **Low-VA Reservation (`< 0x7000000000`):** JIT mappings above `0x7000000000` (or `>= 64 GiB`, where StikJIT's 9-digit hex addressing truncates) hang or fail on TXM devices. `winios_jit.c` reserves static zero-fill memory in `__DATA` below `0x180000000` at Mach-O load time and releases it right before allocating the JIT pool so it lands in `[4 GiB, 64 GiB)`.
2. **Breakpoint Trap (`x16 = 1; brk #0xf00d`):** After confirming `csops(CS_DEBUGGED)` and `sysctl(KERN_PROC_PID)` `P_TRACED`, `JIT26PrepareRegion(NULL, size)` places the requested pool size in `x1` and executes `mov x16, #1; brk #0xf00d; ret`.
3. **Byte-0 `0x69` Page Blessing:** The attached debugger (macOS `lldb` via `scripts/launch_on_duo.sh` or on-device `StikDebug` / `StikJIT` running `universal.js` / `henge-jit.js` over `LocalDevVPN`) verifies instruction `a0013ed4` (`brk #0xf00d`) at PC, allocates 16 KiB-aligned RX memory, and writes the blessing byte **`0x69` into byte 0 of every 16 KiB page** so TXM authorizes the region as executable code space.
4. **Dual-Mapped Aliasing (`mach_vm_remap`) & Detach (`x16 = 0; brk #0xf00d`):** The host maps a Read-Write (`RW`) alias over the same physical pages via `mach_vm_remap` and executes `JIT26Detach()` (`mov x16, #0; brk #0xf00d; ret`). Generated ARM64 code is written to the RW alias and executed from the RX alias with no debugger attached for the rest of the session.

#### 1.4 Jetsam Memory Bypass Architectures Compared

| Runtime / Project | Target Guest | Guest RAM / Swap Allocation | Jetsam Memory Bypass Mechanism | TXM Dual-Mapped JIT Pool |
| :--- | :--- | :--- | :--- | :--- |
| **`WindowsiOS`** (`ammaarreshi/WindowsiOS`) | Windows 11 24H2 ARM64 | **4.5 GB (4,608 MiB)** total; **1.46 GB (31.7%)** used at desktop idle | `hv_alloc_no_footprint`: `mach_make_memory_entry_64` + `mach_memory_entry_ownership(..., LEDGER_NO_FOOTPRINT)` while `CS_DEBUGGED` is active | **384 MiB** RX/RW dual-mapped pool (`< 0x7000000000` via `winios_jit.c`) |
| **`Henge`** (`Leviidev/Henge`) | macOS 13–27 ARM64 | **4 GB, 6 GB, or 8 GB** (configurable **1 GB–10 GB** on 12 GB+ devices) | Signed/built with `com.apple.developer.kernel.increased-memory-limit` entitlement | Uses `henge-jit.js` / `winios_jit.c` TXM dual-mapped substrate |
| **`Playport`** (`playportdev/playport`) | x86 / x86-64 / ARM64 Wine | **4 GiB** donor pool on 12 GB devices (**1 GiB** on 8 GB devices) | Allocates anonymous `SharedMemory` in helper `PlayportJIT.appex` and transfers Mach memory entry send rights over XPC | **896 MiB** (57,344 pages of 16 KiB blessed in **1.49 s**; **3.20 s** total XPC handshake) |
| **`Madeira`** | x86 / x86-64 Wine 11.4 (ARM64EC) | **1.5 GB** VRAM + up to **4.0 GB** `swap-mb` layer | Uses `increased-memory-limit` (`Memory+`) + file-backed guest swap (`swap-mb`) excluded from active Jetsam footprint | **640 MB** default RW/RX dual-mapped FEX JIT pool |
| **`LinuxRunner`** (`mxhm11cr/LinuxRunner`) | Arch Linux ARM, Debian, Fedora, Kali | Host userspace memory budget (**4 GB+ RAM** host; **8 GB+ RAM** for Hyprland) | Runs directly in host userspace without booting a guest kernel or VM | **120 MB** single RX/RW region via StikDebug `universal.js` `brk #0xf00d` (optional) |
| **Stock iOS App Baseline** | Standard iOS App / Unmodified VM | **~3.0 GB** resident memory ceiling | None — Jetsam terminates process past ~3 GB | **0 MiB** (`mprotect(PROT_EXEC)` blocked under iOS 27 TXM) |

---

## 2. Porting the WindowsiOS Engine to Arch Linux (`aarch64`)

### 2.1 Virtual Hardware Compatibility Matrix

No guest-specific Windows lock-in exists inside `devices/`, and every emulated peripheral uses an industry-standard interface supported by mainline Linux `arm64` inbox drivers:

| Subsystem / Layer | `WindowsiOS` Virtual Implementation (`core/` & `devices/`) | Windows 11 24H2 ARM64 Behavior | Arch Linux (`aarch64`) Behavior & Advantage |
| :--- | :--- | :--- | :--- |
| **Boot Firmware** | TianoCore EDK2 `ArmVirtQemu` (`QEMU_EFI.fd` in `pflash0` + persistent CFI01 `pflash1` NVRAM) | Boots Windows Boot Manager via BCD NVRAM provisioned by Python scripts | Boots `systemd-boot`, `GRUB`, `Limine`, `rEFInd`, or Unified Kernel Images (`UKI`) directly from ESP |
| **System Tables & IRQ** | ACPI 6.3 (`FADT` PSCI, `GTDT`, `MCFG`, `MADT`, `IORT`, `DSDT` GPEX+GED) + ARM GICv3 with LPI/ITS MSI-X | Required full ACPI 6.3 tables because Windows refuses Device-Tree boot | Mainline Linux `arm64` supports ACPI 6.3 + PSCI + GICv3 ITS natively |
| **Page Size & MMU** | `core/mmu.c` VMSAv8-64 Stage-1 MMU supporting **4 KiB, 16 KiB, and 64 KiB** granules (`TG0`/`TG1`) | Locked to **4 KiB pages** (`TG0=00, TG1=10`) with `TCR_EL1.A1=1` ASIDs in `TTBR1` | Supports **4 KiB** or **16 KiB** kernels, matching the 16 KiB Darwin host 1:1 and reducing page-table walks |
| **PCIe Host Bridge** | QEMU GPEX Host Bridge (`0x1b36:0x0008`) with ECAM & MSI-X routing (`devices/pcie.c`) | Uses inbox Windows PCI bus driver | Uses standard Linux generic ECAM PCIe host driver |
| **Block Storage** | PCIe NVMe 1.4 (`0x1b36:0x0010`) backed by zero-skipping `hvsparse` container | Uses inbox `StorNVMe` driver | Uses inbox Linux NVMe driver (`/dev/nvme0n1`) with GPT, `ext4`, `btrfs`, `xfs`, or `bcachefs` |
| **Input Devices** | USB 3.0 xHCI (`devices/xhci.c`) with Port 1 Boot Keyboard (`0627:0002`) & Port 2 Absolute Touch Tablet (`0627:0001`) | Uses `USBXHCI.SYS` (required custom `EDTLA` & `CC_STALL` recovery) | Uses standard Linux `xhci` and USB HID drivers for keyboard and absolute touch coordinates |
| **Audio Subsystem** | PCIe Intel ICH6 HD Audio (`0x8086:0x2668`, `devices/hda.c`) with 6-node duplex codec → `CoreAudio` | Binds inbox `hdaudbus.sys` + `HdAudio.sys` (48 kHz S16LE Stereo Out + Mic In) | Binds standard Linux Intel HD Audio driver automatically for 48 kHz / 44.1 kHz 16-bit PCM playback and capture |
| **Networking & Bridge** | VirtIO-Net (`0x1af4:0x1000`) over rootless `libslirp` NAT (`10.0.2.15`) + `http://10.0.2.4/.henge/` | Requires external WHQL Red Hat `NetKVM` driver injection via offline WinPE DISM | Uses inbox Linux VirtIO-Net driver (**zero driver injection needed**) + `xdg-open` wrapper to `10.0.2.4/.henge/` |
| **Display Output** | `devices/fb_metal.m` BGRA8 UEFI framebuffer on 120 Hz `CAMetalLayer` (60 FPS dirty-frame check) | Uses 2D software framebuffer rendering | Renders UEFI GOP framebuffer at 60/120 Hz; upgradeable with `Henge` vGPU or `virglrenderer` → `ANGLE` → `Metal` |
| **Memory Overhead** | 4,608 MiB (4.5 GB) `LEDGER_NO_FOOTPRINT` Guest RAM (or 2–3 GB on 8 GB iPhones) | **1.46 GB** idle *after* stripping 35+ services via offline WinPE hive surgery | Minimal base footprint (~673 MB live image), leaving >3.5 GB free RAM on 4.5 GB VMs |

### 2.2 Native Safari Passkey/OAuth & Port-Forwarding Bridge (`10.0.2.4/.henge/`)

`WindowsiOS` exposes a host control endpoint at `http://10.0.2.4/.henge/` over `libslirp`:
- `PUT http://10.0.2.4/.henge/expose-port` — forwards a host TCP port to the guest NIC (`10.0.2.15:<PORT>`).
- `PUT http://10.0.2.4/.henge/open-url` — opens a URL inside an in-app `SFSafariViewController` (`SafariSheet`) with native Face ID, Passkeys, and Safari session state.
- `PUT http://10.0.2.4/.henge/oauth-done` — automatically dismisses the Safari sheet once an OAuth callback hits the guest's local listener.

On Arch Linux, a lightweight shell script registered as the default `xdg-open` browser handler (`curl -s -X PUT -d "$1" http://10.0.2.4/.henge/open-url`) provides native iOS Safari Passkey/OAuth authentication without writing custom C Win32 shims.

### 2.3 Selecting an Arch Linux `aarch64` Distribution

Because official upstream Arch Linux (`archlinux.org`) compiles packages exclusively for `x86-64`, choose among four `aarch64` Arch ecosystems:
1. **[Archboot AArch64](https://archboot.com/) (*Recommended for UEFI VMs*):** Maintained by Tobias Powalowski (`tpowa`), Archboot ships modular AArch64 UEFI bootable ISOs and Unified Kernel Images (`archboot-local-aarch64.efi`) explicitly targeting Apple Silicon VMs, complete with `archboot-setup.sh` / `pacsetup` for GPT/NVMe partitioning and bootloader installation (`systemd-boot`, `GRUB`, `Limine`, `rEFInd`, `UKI`).
2. **[Collabora & Valve "Holo Core" AArch64](https://www.collabora.com/news-and-blog/news-and-events/building-an-arch-linux-aarch64-port-for-holo-core.html):** Pure `aarch64` port of Arch Linux powering Valve's ARM64 Steam Frame, offering early binary repositories (`holo-packages.steamos.cloud`), source trees, and repeatable CI tracking upstream Arch snapshots.
3. **Unofficial Arch `aarch64` Port (`ports.archlinux.page/aarch64/`):** Community port closely tracking upstream Arch packaging conventions (including OVMF packages).
4. **[Arch Linux ARM (ALARM)](https://archlinuxarm.org/):** Generic AArch64 rootfs tarball used in `LinuxRunner` and pairable with Archboot ISOs for UEFI installation.

---

## 3. Six Architectural Approaches to Running Arch Linux on iOS

| # | Approach & Representative Projects | Execution Model | Kernel (`EL1`)? | 3D Metal GPU? | Debugger / JIT Requirement | Best Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1** | **Direct ARM64 Block Translation**<br>(`WindowsiOS`, `Leviidev/Henge`) | Full-system ARM64-to-ARM64 JIT + Stage-1 Software MMU | **Yes** | 2D Metal (`WindowsiOS`); Metal vGPU (`Henge`) | Required (`lldb` or `StikDebug` `brk #0xf00d`) | Highest full-kernel CPU speed, 16 KiB page alignment, heavy multi-process apps |
| **2** | **Userspace Syscall Translation + VirGL**<br>(`mxhm11cr/LinuxRunner`, `rcarmo/ios-linuxkit`) | ARM64 threaded gadget interpreter / optional 120 MB JIT + Linux syscall shim (no guest kernel) | **No** | **Yes** (`Mesa/VirGL` → `virglrenderer` → `ANGLE` → `Metal`) | **Optional** (works out of the box without debugger) | Turnkey Arch Linux ARM (`pacman`) with Wayland compositors (`Hyprland`, `Wayfire`) & USB-C DeX Mode |
| **3** | **Hybrid Pseudo-JIT + Live StikJIT**<br>(`tctiSH/tctiSH`, `Leviidev/Husk`) | QEMU TCTI threaded interpreter with live hot-upgrade to native StikJIT + background state save | **Yes** | Via QEMU display | **Optional** (boots offline via TCTI; upgrades live on-device via iOS 27 pairing) | Offline full-kernel VMs that survive backgrounding without Jetsam kills |
| **4** | **Tuned Sideloaded UTM**<br>(`UTM` + `StikDebug` `legacy.js`) | QEMU TCG cross-arch JIT + `virtio-gpu-gl-pci` + `ANGLE (Metal)` | **Yes** | **Yes** (`virgl` OpenGL 3.x + experimental Venus Vulkan) | Required (`StikDebug` `legacy.js` + `LocalDevVPN`) | Standard GUI VM management with existing QEMU tooling |
| **5** | **In-App `NSExtension` Self-JIT + x86 Translation**<br>(`Playport`, `Madeira`, `FEX-Emu`, `Blink`) | Embedded `com.apple.ar.viewer` helper `.appex` self-blesses TXM JIT + XPC shared memory in ~3.2 s | Optional | Yes (DXVK / MoltenVK / ANGLE) | **Self-contained** (no Mac or external StikDebug app switch) | Zero-ceremony single-app UX + running `x86_64` Arch/Steam binaries inside `aarch64` |
| **6** | **Zero-Sideload Wasm & Remote Wayland**<br>(`copy/v86`, `WebVM`, `container2wasm`, `waypipe`) | Safari/`WKWebView` Wasm JIT (`< 4 GB`) or local `ios-linuxkit` + Tailscale + `waypipe` | Wasm: Yes<br>Remote: Host | WebGL / Native remote | **None** (uses WebKit's first-party Wasm JIT) | Zero-sideload browser Arch 32 (`v86`) or zero-overhead remote Wayland apps |

---

## 4. Device & Build Environment Adaptation Notes

### Adapting from Foldable iPhone Duo to Single-Screen iPhones (e.g., iPhone 16 Pro)
1. **Guard `UIHingeInteraction` (`ios/Sources/`):** Guard iOS 27's `UIHingeInteraction` (`HingeSensorView.swift`) at compile/runtime so non-foldable devices route directly into the full-screen `SessionView` canvas rather than `LaptopDeckView`, pairing with a Bluetooth/USB-C keyboard and trackpad or a toggleable on-screen input bar.
2. **Scale Guest RAM to Device Physical RAM:** On an 8 GB device such as the **iPhone 16 Pro** (A18 Pro), reduce guest RAM from `4,608 MiB` to **`2,048–3,072 MiB` (2–3 GB)** so iOS and the 384 MiB TXM JIT pool retain safe physical headroom without triggering system-wide Jetsam pressure.
3. **Deployment Target Compatibility:** Set `ios/project.yml` deployment target to **`26.0`** so the app compiles and runs across both iOS 26 and iOS 27 TXM devices.

### Building on x86 (Intel) MacBooks vs. Linux PCs
- **Intel (`x86_64`) MacBook:** Xcode cross-compiles C, ARM64 assembly (`winios_brk.S`), Objective-C (`fb_metal.m`), and Swift for `arm64-apple-ios` up to **macOS 26 (Tahoe) / Xcode 26** (the final Intel-supported releases). Replace `/opt/homebrew` paths with `/usr/local`, skip building/running the local macOS `winvm` host binary (which requires an Apple Silicon ARM64 CPU), and build `hvsparse` + the `.ipa` for SideStore/AltStore or `devicectl` installation.
- **Linux PC (Bare Metal):** Apple does not provide Xcode or iOS UIKit/Metal SDKs for Linux. Compile `hvsparse` and generate the Arch Linux `aarch64` disk image locally via `qemu-system-aarch64`, and build the unsigned `.ipa` using a **GitHub Actions `macos-latest` workflow** (`xcodegen` + `xcodebuild CODE_SIGNING_ALLOWED=NO`) for on-device signing via SideStore or AltStore.

---

## 5. Unified `henge-linux` Implementation Blueprint

To combine the strongest capabilities of these architectures under **`GPL-3.0-or-later`**:

1. **Core Virtualization Engine (`core/` + `devices/`):** Port `HengeVM` / `WindowsiOS`'s direct ARM64-to-ARM64 block translator, 16 KiB + 4 KiB stage-1 software MMU, `LEDGER_NO_FOOTPRINT` memory allocator, UEFI + ACPI 6.3 + PCIe GPEX bus, NVMe 1.4 (`hvsparse`), Intel ICH6 duplex CoreAudio bridge, and VirtIO-Net (`libslirp` + `10.0.2.4/.henge/`).
2. **Adaptive Single- & Dual-Screen SwiftUI Frontend (`ios/Sources/`):** Support both iPhone Duo (`UIHingeInteraction` clamshell + Open Studio) and standard iPhones/iPads (`SessionView` + configurable RAM presets).
3. **In-App Self-Debugging Extension (`PlayportJIT.appex` Pattern):** Bundle `StikJIT` (`MPL-2.0`) and `idevice` (`MIT`) inside an embedded helper `NSExtension` (`com.apple.ar.viewer`) to self-bless the 384 MiB TXM JIT pool on launch without a tethered Mac or external app switch.
4. **3D Metal Acceleration & Lifecycle Persistence:** Upgrade `devices/fb_metal.m` with `Henge`'s Metal command-replaying vGPU or `virglrenderer` → `ANGLE` → `Metal`, and integrate `tctiSH`-style background state suspension to protect against Jetsam kills when backgrounded.
