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
  5. core/sysreg.c & core/translate.c: apply background-suspend CNTVCT_EL0 /
     CNTPCT_EL0 offset compensation via hengelinux_compensated_counter() so
     Linux softlockup watchdogs do not fire after iOS background suspension.
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
    fb_text = fb_metal_m.read_text(encoding="utf-8")
    if '#include "henge_platform.h"' not in fb_text:
        if '#import "fb_metal.h"\n' in fb_text:
            patch_file(
                fb_metal_m,
                '#include "henge_platform.h"',
                '#import "fb_metal.h"\n',
                '#import "fb_metal.h"\n#include "henge_platform.h"\n',
            )
        elif '#include "fb_metal.h"\n' in fb_text:
            patch_file(
                fb_metal_m,
                '#include "henge_platform.h"',
                '#include "fb_metal.h"\n',
                '#include "fb_metal.h"\n#include "henge_platform.h"\n',
            )
        else:
            fb_metal_m.write_text('#include "henge_platform.h"\n' + fb_text, encoding="utf-8")
            print(f"[patch] {fb_metal_m}: prepended henge_platform.h")
    else:
        print(f"[patch] {fb_metal_m}: header already applied")
    patch_file(
        fb_metal_m,
        "uint32_t row_bytes = w * 4u;",
        """static uint64_t quick_frame_hash(const uint8_t *px, uint32_t w, uint32_t h, uint32_t stride) {
    uint64_t hash = ((uint64_t)w << 32) ^ h ^ stride;
    uint32_t step_y = h > 128 ? h / 128 : 1;
    for (uint32_t y = 0; y < h; y += step_y) {
        const uint64_t *row = (const uint64_t *)(px + (size_t)y * stride);
        uint32_t qwords = (w * 4) / 8;
        uint32_t step_x = qwords > 64 ? qwords / 64 : 1;
        for (uint32_t x = 0; x < qwords; x += step_x) {
            hash = (hash ^ row[x]) * 0x9e3779b97f4a7c15ull;
        }
    }
    return hash ? hash : 1;
}""",
        """static uint64_t quick_frame_hash(const uint8_t *px, uint32_t w, uint32_t h, uint32_t stride) {
    uint64_t hash = ((uint64_t)w << 32) ^ h ^ stride;
    uint32_t row_bytes = w * 4u;
    if ((((uintptr_t)px & 7u) == 0u) && ((stride & 7u) == 0u)) {
        uint32_t qwords = row_bytes >> 3;
        BOOL has_tail32 = (row_bytes & 4u) != 0u;
        for (uint32_t y = 0; y < h; y++) {
            const uint64_t *row = (const uint64_t *)(const void *)(px + (size_t)y * stride);
            for (uint32_t x = 0; x < qwords; x++) {
                hash = (hash ^ row[x]) * 0x9e3779b97f4a7c15ull;
            }
            if (has_tail32) {
                const uint32_t *tail = (const uint32_t *)(const void *)(row + qwords);
                hash = (hash ^ (uint64_t)(*tail)) * 0x9e3779b97f4a7c15ull;
            }
        }
    } else {
        for (uint32_t y = 0; y < h; y++) {
            const uint8_t *row = px + (size_t)y * stride;
            for (uint32_t x = 0; x < row_bytes; x++) {
                hash = (hash ^ (uint64_t)row[x]) * 0x9e3779b97f4a7c15ull;
            }
        }
    }
    return hash ? hash : 1;
}""",
    )
    patch_file(
        fb_metal_m,
        "_hengeUnlockedTick",
        """- (void)tick {
    @autoreleasepool {""",
        """- (void)tick {
    hengelinux_render_lock();
    if (!hengelinux_is_render_paused()) {
        [self _hengeUnlockedTick];
    }
    hengelinux_render_unlock();
}

- (void)_hengeUnlockedTick {
    @autoreleasepool {""",
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
    patch_file(
        audio_mac_c,
        "!hengelinux_is_render_paused() && hda",
        """    HvHda *hda = (HvHda *)opaque;
    if (hda && buf && buf->mAudioDataByteSize > 0)
        hv_hda_push_capture(hda, buf->mAudioData, buf->mAudioDataByteSize);""",
        """    HvHda *hda = (HvHda *)opaque;
    if (!hengelinux_is_render_paused() && hda && buf && buf->mAudioDataByteSize > 0)
        hv_hda_push_capture(hda, buf->mAudioData, buf->mAudioDataByteSize);""",
    )

    # 4. host/jit_region.c: enforce TXM low-VA ceiling (< 64 GiB / 0x7000000000)
    jit_region_c = upstream / "host/jit_region.c"
    patch_file(
        jit_region_c,
        '#include "henge_txm_jit.h"',
        '#include "jit_region.h"\n',
        '#include "jit_region.h"\n#include <stdio.h>\n#include "henge_txm_jit.h"\n',
    )
    patch_file(
        jit_region_c,
        "henge_txm_is_valid_jit_range",
        """int hv_jit_region_attach(HvJitRegion *region, void *rx, void *rw, size_t bytes) {""",
        """int hv_jit_region_attach(HvJitRegion *region, void *rx, void *rw, size_t bytes) {
    if (rw == NULL || rw == rx) {
        fprintf(stderr, "hengevm: jit: invalid RW alias %p for RX %p\\n", rw, rx);
        return -1;
    }
    if (!henge_txm_is_valid_jit_range((uintptr_t)rx, bytes)) {
        fprintf(stderr, "hengevm: jit: rx range %p (+0x%zx) outside TXM low-VA bounds\\n", rx, bytes);
        return -1;
    }""",
    )

    # 5. core/sysreg.c & core/translate.c: background-suspend CNTVCT_EL0 offset compensation
    sysreg_c = upstream / "core/sysreg.c"
    patch_file(
        sysreg_c,
        '#include "henge_platform.h"',
        '#include "sysreg.h"\n',
        '#include "sysreg.h"\n#include "henge_platform.h"\n',
    )
    patch_file(
        sysreg_c,
        "hengelinux_compensated_counter",
        """static uint64_t counter(void) {
    return mach_absolute_time(); /* 24 MHz on Apple silicon */
}""",
        """static uint64_t counter(void) {
    return hengelinux_compensated_counter(mach_absolute_time()); /* 24 MHz on Apple silicon, suspend-compensated */
}""",
    )

    translate_c = upstream / "core/translate.c"
    patch_file(
        translate_c,
        "hengelinux_negative_counter_offset_ptr",
        """static int translate_counter(Emit *e, uint32_t insn, uint64_t pc, int physical) {
    static int type = -1;
    if (type < 0) type = *(volatile uint8_t *)(uintptr_t)COMMPAGE_TIMEBASE_TYPE;
    if (type == 0) return 0; /* the kernel's own path: leave it to the helper */
    int rt = insn & 0x1f;
    if (rt == 31) return 1;
    if (!(e->flags & HV_BLOCK_EL1)) {
        put(e, 0xb9400000u | (HV_CPU_EL0_CNT / 4) << 10 | 28 << 5 | 6); /* ldr w6, [x28, #el0_cnt] */
        put(e, 0x36000000u | (physical ? 0u : 1u) << 19 | 6);         /* tbz w6, #enable, helper (patched) */
        put_ool(e, (Ool){.kind = OOL_MRS, .pc = pc, .insn = insn});
    }
    uint32_t slow = e->nool - 1;
    int el0 = !(e->flags & HV_BLOCK_EL1);
    int r = is_stolen(rt) ? 15 : rt;
    if (type == 1) put(e, 0xd5033fdfu);                                  /* isb; then CNTVCT_EL0 */
    put(e, (type == 1 ? 0xd53be040u : type == 2 ? 0xd53be0c0u : 0xd53cfac0u) | (uint32_t)r);
    put_lit(e, 6, COMMPAGE_TIMEBASE_OFFSET);
    put(e, LDR_X(6, 6, 0));
    put(e, ADD_LSL(r, r, 6, 0));
    if (r != rt) put(e, STR_X(r, 28, slot_of(rt)));
    if (el0) e->ool[slow].join = e->n;
    return 1;
}""",
        """#include "henge_platform.h"

static int translate_counter(Emit *e, uint32_t insn, uint64_t pc, int physical) {
    static int type = -1;
    if (type < 0) type = *(volatile uint8_t *)(uintptr_t)COMMPAGE_TIMEBASE_TYPE;
    if (type == 0) return 0; /* the kernel's own path: leave it to the helper */
    int rt = insn & 0x1f;
    if (rt == 31) return 1;
    if (!(e->flags & HV_BLOCK_EL1)) {
        put(e, 0xb9400000u | (HV_CPU_EL0_CNT / 4) << 10 | 28 << 5 | 6); /* ldr w6, [x28, #el0_cnt] */
        put(e, 0x36000000u | (physical ? 0u : 1u) << 19 | 6);         /* tbz w6, #enable, helper (patched) */
        put_ool(e, (Ool){.kind = OOL_MRS, .pc = pc, .insn = insn});
    }
    uint32_t slow = e->nool - 1;
    int el0 = !(e->flags & HV_BLOCK_EL1);
    int r = is_stolen(rt) ? 15 : rt;
    if (type == 1) put(e, 0xd5033fdfu);                                  /* isb; then CNTVCT_EL0 */
    put(e, (type == 1 ? 0xd53be040u : type == 2 ? 0xd53be0c0u : 0xd53cfac0u) | (uint32_t)r);
    put_lit(e, 6, COMMPAGE_TIMEBASE_OFFSET);
    put(e, LDR_X(6, 6, 0));
    put(e, ADD_LSL(r, r, 6, 0));
    put_lit(e, 6, (uint64_t)(uintptr_t)hengelinux_negative_counter_offset_ptr());
    put(e, LDR_X(6, 6, 0));
    put(e, ADD_LSL(r, r, 6, 0));
    if (r != rt) put(e, STR_X(r, 28, slot_of(rt)));
    if (el0) e->ool[slow].join = e->n;
    return 1;
}""",
    )

    dispatch_c = upstream / "core/dispatch.c"
    patch_file(
        dispatch_c,
        "cpu->timer_due && hv_counter() >= cpu->timer_due",
        "    if (cpu->timer_due && mach_absolute_time() >= cpu->timer_due) { if (m->stats_interval) m->stats.fr_fail[3]++; return NULL; }",
        "    if (cpu->timer_due && hv_counter() >= cpu->timer_due) { if (m->stats_interval) m->stats.fr_fail[3]++; return NULL; }",
    )
    patch_file(
        dispatch_c,
        "uint64_t now = hv_counter();",
        """    if (!m->tick) return -1; /* nothing could ever wake us */
    uint64_t now = mach_absolute_time();""",
        """    if (!m->tick) return -1; /* nothing could ever wake us */
    uint64_t now = hv_counter();""",
    )
    patch_file(
        dispatch_c,
        "next_due && hv_counter() >= next_due",
        "        if (m->tick && (kicked || (++since_tick >= 64 && (since_tick = 0, next_due && mach_absolute_time() >= next_due)))) {",
        "        if (m->tick && (kicked || (++since_tick >= 64 && (since_tick = 0, next_due && hv_counter() >= next_due)))) {",
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
