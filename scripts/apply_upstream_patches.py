#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""
Apply idempotent iOS/Arch Linux adaptation patches to synced upstream
ammaarreshi/WindowsiOS sources inside .upstream/WindowsiOS:
  1. host/share.c: format AF_UNIX sun_path via henge_format_unix_socket_path()
     so deep iOS app-container paths never truncate at Darwin's 104-byte limit.
  2. devices/fb_metal.m: serialize CAMetalLayer drawable acquisition/commit
     under hengelinux_render_lock() + hengelinux_is_render_paused() so
     UIApplication.willResignActiveNotification prevents GPU kill aborts.
  3. host/audio_mac.c: silence/re-prime CoreAudio callbacks when render-paused.
  4. host/jit_region.c: validate RX JIT mapping ranges against TXM's safe
     low-VA window [4 GiB, 64 GiB) via henge_txm_is_valid_jit_range().
"""

from pathlib import Path
import sys


def patch_file(path: Path, marker: str, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if marker in text:
        print(f"[patch] {path}: already applied")
        return
    if old not in text:
        raise RuntimeError(f"[patch] anchor not found in {path}")
    updated = text.replace(old, new, 1)
    path.write_text(updated, encoding="utf-8")
    print(f"[patch] {path}: applied")


def main() -> int:
    upstream = Path(sys.argv[1] if len(sys.argv) > 1 else ".upstream/WindowsiOS")
    if not upstream.is_dir():
        print(f"[patch] upstream directory not found: {upstream}", file=sys.stderr)
        return 1

    # 1. host/share.c: enforce <104-byte iOS sandbox AF_UNIX socket path
    share_c = upstream / "host/share.c"
    patch_file(
        share_c,
        "henge_format_unix_socket_path",
        '#include "share.h"\n',
        '#include "share.h"\n#include "henge_platform.h"\n',
    )
    patch_file(
        share_c,
        "bind_socket_path",
        """    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (strlen(socket_path) >= sizeof addr.sun_path) {
        fprintf(stderr, "hengevm: share: socket path too long: %s\\n", socket_path);
        return -1;
    }
    strcpy(addr.sun_path, socket_path);
    unlink(socket_path);
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0 || bind(server, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(server, 16) != 0) {
        fprintf(stderr, "hengevm: share: %s: %s\\n", socket_path, strerror(errno));
        if (server >= 0) close(server);
        return -1;
    }
    chmod(socket_path, 0600);""",
        """    char formatted_sock[HENGE_DARWIN_SUN_PATH_MAX];
    const char *bind_socket_path = socket_path;
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (strlen(socket_path) >= sizeof addr.sun_path) {
        if (henge_format_unix_socket_path(root, "share.sock", formatted_sock, sizeof formatted_sock) != 0) {
            fprintf(stderr, "hengevm: share: socket path too long: %s\\n", socket_path);
            return -1;
        }
        bind_socket_path = formatted_sock;
    }
    strcpy(addr.sun_path, bind_socket_path);
    unlink(bind_socket_path);
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0 || bind(server, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(server, 16) != 0) {
        fprintf(stderr, "hengevm: share: %s: %s\\n", bind_socket_path, strerror(errno));
        if (server >= 0) close(server);
        return -1;
    }
    chmod(bind_socket_path, 0600);""",
    )

    # 2. devices/fb_metal.m: serialize Metal drawable acquisition/commit on willResignActive
    fb_metal_m = upstream / "devices/fb_metal.m"
    patch_file(
        fb_metal_m,
        '#include "henge_platform.h"',
        '#include "fb_metal.h"\n',
        '#include "fb_metal.h"\n#include "henge_platform.h"\n',
    )
    patch_file(
        fb_metal_m,
        "hengelinux_render_lock()",
        """        id<CAMetalDrawable> drawable = [curLayer nextDrawable];
        if (!drawable) {
            os_unfair_lock_unlock(&lock);
            return;
        }""",
        """        hengelinux_render_lock();
        if (hengelinux_is_render_paused()) {
            hengelinux_render_unlock();
            os_unfair_lock_unlock(&lock);
            return;
        }

        id<CAMetalDrawable> drawable = [curLayer nextDrawable];
        if (!drawable) {
            hengelinux_render_unlock();
            os_unfair_lock_unlock(&lock);
            return;
        }""",
    )
    patch_file(
        fb_metal_m,
        "hengelinux_render_unlock();\n\n        lastHash = hval;",
        """        [cb presentDrawable:drawable];
        [cb commit];

        lastHash = hval;""",
        """        [cb presentDrawable:drawable];
        [cb commit];
        hengelinux_render_unlock();

        lastHash = hval;""",
    )

    # 3. host/audio_mac.c: pause audio playback/capture callbacks when backgrounded
    audio_mac_c = upstream / "host/audio_mac.c"
    patch_file(
        audio_mac_c,
        '#include "henge_platform.h"',
        '#include "audio_mac.h"\n',
        '#include "audio_mac.h"\n#include "henge_platform.h"\n',
    )
    patch_file(
        audio_mac_c,
        "if (hengelinux_is_render_paused()) {\n        for (UInt32 i = 0;",
        """    HvHda *hda = (HvHda *)ref;
    for (UInt32 i = 0; i < io->mNumberBuffers; i++)
        hv_hda_pull_playback(hda, io->mBuffers[i].mData, io->mBuffers[i].mDataByteSize);""",
        """    if (hengelinux_is_render_paused()) {
        for (UInt32 i = 0; i < io->mNumberBuffers; i++)
            memset(io->mBuffers[i].mData, 0, io->mBuffers[i].mDataByteSize);
        return noErr;
    }
    HvHda *hda = (HvHda *)ref;
    for (UInt32 i = 0; i < io->mNumberBuffers; i++)
        hv_hda_pull_playback(hda, io->mBuffers[i].mData, io->mBuffers[i].mDataByteSize);""",
    )

    # 4. host/jit_region.c: enforce TXM low-VA ceiling (< 64 GiB / 0x7000000000)
    jit_region_c = upstream / "host/jit_region.c"
    patch_file(
        jit_region_c,
        '#include "henge_txm_jit.h"',
        '#include "jit_region.h"\n',
        '#include "jit_region.h"\n#include "henge_txm_jit.h"\n',
    )
    patch_file(
        jit_region_c,
        "henge_txm_is_valid_jit_range",
        """int hv_jit_region_attach(HvJitRegion *region, void *rx, void *rw, size_t bytes) {""",
        """int hv_jit_region_attach(HvJitRegion *region, void *rx, void *rw, size_t bytes) {
    if (!henge_txm_is_valid_jit_range((uintptr_t)rx, bytes)) {
        fprintf(stderr, "hengevm: jit: rx range %p (+0x%zx) outside TXM low-VA bounds\\n", rx, bytes);
        return -1;
    }""",
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
