# Third-Party Notices & License Attribution

`henge-linux` is licensed under the **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** — see [`LICENSE`](LICENSE).

In accordance with GPLv3 Section 5(a), modified files and adaptation patches carry prominent notices and SPDX headers (`SPDX-License-Identifier: GPL-3.0-or-later`). This project incorporates or links the following upstream and third-party components:

## 1. Upstream Virtualization Engine
- **`ammaarreshi/WindowsiOS`** (`0071d6975287fd720b9046dfd3bd80b6f2aa765e`) — Licensed under **`GPL-2.0-or-later`** (upgraded to `GPL-3.0-or-later` in `henge-linux`).
- **`Leviidev/Henge` (`HengeVM`) & `Leviidev/Husk`** — Licensed under **`GPL-2.0-or-later`** (upgraded to `GPL-3.0-or-later`).

## 2. iOS Static Dependencies (Linked via `scripts/build_ios_deps.sh`)
- **`libslirp`** — **BSD-3-Clause** (user-mode TCP/IP stack for VirtIO-Net).
- **`GLib` (`libglib-2.0`)** — **LGPL-2.1-or-later** (event loop and utility primitives required by `libslirp`).
- **`libffi`** — **MIT** (foreign function interface runtime).
- **`PCRE2` (`libpcre2-8`)** — **BSD-3-Clause** (regular expression support for GLib).
- **`GNU gettext / libintl`** — **LGPL-2.1-or-later** (internationalization support for GLib).

## 3. Optional Self-Debugging & 3D Graphics Subsystems
- **`StikJIT` / `StikDebug` (`StephenDev0/StikDebug`)** — **MPL-2.0** (compatible with `GPL-3.0-or-later` per MPL 2.0 §3.3).
- **`idevice` (`jkcoxson/idevice`)** — **MIT** (Remote Service Discovery / lockdown debugproxy transport).
- **`virglrenderer` & `ANGLE`** — **MIT** / **BSD-3-Clause** (OpenGL ES / Metal translation layers for `virtio-gpu-gl-pci`).
