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

## 3. Optional Self-Debugging & 3D Graphics Subsystems
- **`StikJIT` / `StikDebug` (`StephenDev0/StikDebug`)** — **MPL-2.0** (compatible with `GPL-3.0-or-later` per MPL 2.0 §3.3).
- **`idevice` (`jkcoxson/idevice`)** — **MIT** (Remote Service Discovery / lockdown debugproxy transport).
- **`virglrenderer` & `ANGLE`** — **MIT** / **BSD-3-Clause** (OpenGL ES / Metal translation layers for `virtio-gpu-gl-pci`).

## 4. Pre-Built Guest Image & UEFI Firmware Artifacts (`prebuilt-guest-image.yml`)
- **`Arch Linux ARM` (`ArchLinuxARM-aarch64-latest.tar.gz`)** — Distributed under upstream open-source licenses (`GPL-2.0-or-later`, `LGPL-2.1-or-later`, `MIT`, `BSD`) and provisioned non-interactively via `scripts/build_prebuilt_archlinux_arm64.sh`.
- **`TianoCore EDK2` (`ArmVirtQemu` / `AAVMF_CODE.fd` & `AAVMF_VARS.fd`)** — **BSD-2-Clause-Patent** (64 MiB AArch64 UEFI firmware images packaged alongside `archlinux.hvsparse`).
