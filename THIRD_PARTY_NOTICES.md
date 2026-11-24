# Third-Party Notices & License Attribution

`henge-linux` is licensed under the **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** — see [`LICENSE`](LICENSE).

In accordance with GPLv3 Section 5(a), modified files and adaptation patches carry prominent notices and SPDX headers (`SPDX-License-Identifier: GPL-3.0-or-later`). This project incorporates or links the following upstream and third-party components:

## 1. Upstream Virtualization Engine
- **`ammaarreshi/WindowsiOS`** (`0071d6975287fd720b9046dfd3bd80b6f2aa765e`) — Licensed under **`GPL-2.0-or-later`** (upgraded to `GPL-3.0-or-later` in `henge-linux`).
- **`Leviidev/Henge` (`HengeVM`) & `Leviidev/Husk`** — Licensed under **`GPL-2.0-or-later`** (upgraded to `GPL-3.0-or-later`).

## 2. iOS Static Dependencies (Linked via `scripts/build_ios_deps.sh`)

To satisfy GPLv3 §6(d) and LGPLv2.1 §4(d) Corresponding Source requirements for prebuilt `HengeLinux-unsigned.ipa` releases, all five `arm64` static archives (`libslirp.a`, `libglib-2.0.a`, `libffi.a`, `libpcre2-8.a`, `libintl.a`) are reproducibly built from the pinned source tarballs and patches specified in `ammaarreshi/WindowsiOS` (`0071d6975287fd720b9046dfd3bd80b6f2aa765e`, `scripts/build_ios_deps.sh`):

- **`libslirp`** — **BSD-3-Clause** (user-mode TCP/IP stack for VirtIO-Net; pinned in `WindowsiOS@0071d6975287`).
- **`GLib` (`libglib-2.0`)** — **LGPL-2.1-or-later** (event loop and utility primitives required by `libslirp`; pinned in `WindowsiOS@0071d6975287`).
- **`libffi`** — **MIT** (foreign function interface runtime; pinned in `WindowsiOS@0071d6975287`).
- **`PCRE2` (`libpcre2-8`)** — **BSD-3-Clause** (regular expression support for GLib; pinned in `WindowsiOS@0071d6975287`).
- **`GNU gettext / libintl`** — **LGPL-2.1-or-later** (internationalization support for GLib; pinned in `WindowsiOS@0071d6975287`).
- **`Zstandard` (`libzstd.a` `v1.5.7`, `https://github.com/facebook/zstd`)** — Dual-licensed **BSD-3-Clause / GPL-2.0** (QCOW2 `compression_type=1` Zstd cluster decompression; built from `v1.5.7` release tarball in `scripts/build_ios_deps.sh`).

## 3. Static 3D Graphics Stack (Linked via `scripts/build_ios_gpu_deps.sh`) & Self-Debugging Subsystems
- **`Google ANGLE` (`libEGL.a`, `libGLESv2.a`)** — **BSD-3-Clause** (Metal-only static OpenGL ES 3.0 / EGL 1.5 translation layer; built from pinned `https://github.com/godotengine/godot-angle-static` tag `chromium/7578`, commit `89bab1e` / upstream ANGLE `d39da9a`, with deterministic MSL `RescopeGlobalVariables.cpp` and `iOS 18.0` deployment patches in `scripts/patch_gpu_deps.py`).
- **`libepoxy` (`libepoxy.a` `v1.5.10`)** — **MIT** (OpenGL/EGL function pointer dispatch; built from `https://download.gnome.org/sources/libepoxy/1.5/libepoxy-1.5.10.tar.xz`, SHA256 `072cda4b59dd098bba8c2363a6247299db1fa89411dc221c8b81b8ee8192e623`, patched in `scripts/patch_gpu_deps.py` for direct static ANGLE dispatch on iOS).
- **`libvirglrenderer` (`libvirglrenderer.a` `v1.2.0`)** — **MIT** (VirtIO-GPU VirGL 3D Gallium command renderer; built from `https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/1.2.0/virglrenderer-1.2.0.tar.gz`, patched in `scripts/patch_gpu_deps.py` for ES 3.0 `MAX_SAMPLES=4` MSAA and `VIRGL_FORMAT_A8_UNORM`).
- **`StikJIT` / `StikDebug` (`https://github.com/StephenDev0/StikDebug`)** — **MPL-2.0** (compatible with `GPL-3.0-or-later` per MPL 2.0 §3.3; optional `StikJIT.xcframework` integration).
- **`idevice` (`https://github.com/jkcoxson/idevice`)** — **MIT** (Remote Service Discovery / lockdown `debugproxy` transport; optional `idevice.xcframework` integration).

## 4. Pre-Built Guest Image & UEFI Firmware Artifacts (`prebuilt-guest-image.yml`)
- **`Arch Linux ARM` (`http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz`)** — Distributed under upstream open-source licenses (`GPL-2.0-or-later`, `LGPL-2.1-or-later`, `MIT`, `BSD`); verified against upstream `.md5` digest during build in `scripts/build_prebuilt_archlinux_arm64.sh` and published with `SHA256SUMS.txt`.
- **`TianoCore EDK2` (`https://github.com/tianocore/edk2`, Ubuntu `qemu-efi-aarch64` `AAVMF_CODE.fd` & `AAVMF_VARS.fd`)** — **BSD-2-Clause-Patent** (64 MiB AArch64 UEFI firmware images packaged alongside `archlinux.hvsparse` with `SHA256SUMS.txt`).
