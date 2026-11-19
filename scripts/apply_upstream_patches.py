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

    # 1. host/share.h & host/share.c: enforce <104-byte iOS sandbox AF_UNIX socket path
    #    and serve offline guest additions at http://10.0.2.4/.henge/guest-tools/
    share_h = upstream / "host/share.h"
    patch_file(
        share_h,
        "HENGE_SHARE_HAS_GUEST_TOOLS",
        "int hv_share_take_oauth_done(void);\n",
        """int hv_share_take_oauth_done(void);

#define HENGE_SHARE_HAS_GUEST_TOOLS 1
void hv_share_set_guest_tools_dir(const char *dir);
""",
    )

    share_c = upstream / "host/share.c"
    patch_file(
        share_c,
        "henge_format_unix_socket_path",
        '#include "share.h"\n',
        '#include "share.h"\n#include "henge_platform.h"\n',
    )
    patch_file(
        share_c,
        "guest_tools_dir",
        "static char agent_path[PATH_MAX];\n",
        """static char agent_path[PATH_MAX];
static char guest_tools_dir[PATH_MAX];

void hv_share_set_guest_tools_dir(const char *dir) {
    if (dir && dir[0]) {
        snprintf(guest_tools_dir, sizeof guest_tools_dir, "%s", dir);
    } else {
        guest_tools_dir[0] = 0;
    }
}
""",
    )
    patch_file(
        share_c,
        "serve_guest_tools",
        """static int serve_henge(Conn *c, Request *r) {
    const char *what = r->path + strlen("/.henge/");""",
        """static int serve_guest_tools(Conn *c, Request *r, const char *name) {
    if (body_discard(c, r) != 0) return -1;
    if (!name || !name[0]) {
        static const char listing[] =
            "install.sh\\n"
            "henge_guest_agent.c\\n"
            "henge-xdg-open\\n"
            "henge-guest-agent\\n";
        return respond(c, r, 200, "OK", "Content-Type: text/plain; charset=utf-8\\r\\n", listing, sizeof listing - 1);
    }
    int allowed = !strcmp(name, "install.sh") ||
                  !strcmp(name, "henge_guest_agent.c") ||
                  !strcmp(name, "henge-xdg-open") ||
                  !strcmp(name, "henge-guest-agent");
    if (!allowed || !guest_tools_dir[0]) {
        return respond_empty(c, r, 404, "Not Found");
    }
    char full_path[PATH_MAX];
    int n = snprintf(full_path, sizeof full_path, "%s/%s", guest_tools_dir, name);
    if (n <= 0 || (size_t)n >= sizeof full_path) {
        return respond_empty(c, r, 404, "Not Found");
    }
    int fd = open(full_path, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0 || st.st_size > SMALL_BODY_MAX) {
        if (fd >= 0) close(fd);
        return respond_empty(c, r, 404, "Not Found");
    }
    char *data = st.st_size > 0 ? malloc((size_t)st.st_size) : NULL;
    ssize_t got = st.st_size > 0 ? (data ? pread(fd, data, (size_t)st.st_size, 0) : -1) : 0;
    close(fd);
    if (got != st.st_size) {
        free(data);
        return respond_empty(c, r, 500, "Internal Server Error");
    }
    const char *ctype = !strcmp(name, "henge-guest-agent")
        ? "Content-Type: application/octet-stream\\r\\n"
        : "Content-Type: text/plain; charset=utf-8\\r\\n";
    int rc = respond(c, r, 200, "OK", ctype, data, (size_t)got);
    free(data);
    return rc;
}

static int serve_henge(Conn *c, Request *r) {
    const char *what = r->path + strlen("/.henge/");
    if (!strncmp(what, "guest-tools/", 12) && !strcmp(r->method, "GET")) {
        return serve_guest_tools(c, r, what + 12);
    }
    if (!strcmp(what, "guest-tools") && !strcmp(r->method, "GET")) {
        return serve_guest_tools(c, r, "");
    }""",
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
        "henge_jit_requires_txm_low_va",
        """int hv_jit_region_attach(HvJitRegion *region, void *rx, void *rw, size_t bytes) {""",
        """int hv_jit_region_attach(HvJitRegion *region, void *rx, void *rw, size_t bytes) {
    if (rw == NULL || rw == rx) {
        fprintf(stderr, "hengevm: jit: invalid RW alias %p for RX %p\\n", rw, rx);
        return -1;
    }
    if (henge_jit_requires_txm_low_va() && !henge_txm_is_valid_jit_range((uintptr_t)rx, bytes)) {
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

    # 6. Milestone 6.2 (Phase B3): virtio-input tablet (EV_ABS), dormant virtio-input/virtio-blk
    #    attachment on GPEX, toggleable xHCI & ACPI SPCR, and unified HID/tablet routing in winvm.
    virtio_input_h = upstream / "devices/virtio_input.h"
    patch_file(
        virtio_input_h,
        "HV_VINPUT_TABLET",
        """enum { HV_VINPUT_KEYBOARD, HV_VINPUT_MOUSE };

#define HV_EV_SYN 0
#define HV_EV_KEY 1
#define HV_EV_REL 2""",
        """enum { HV_VINPUT_KEYBOARD, HV_VINPUT_MOUSE, HV_VINPUT_TABLET };

#define HV_EV_SYN 0
#define HV_EV_KEY 1
#define HV_EV_REL 2
#define HV_EV_ABS 3
#define HV_ABS_X 0
#define HV_ABS_Y 1""",
    )

    virtio_input_c = upstream / "devices/virtio_input.c"
    patch_file(
        virtio_input_c,
        "CFG_ABS_INFO",
        """#define CFG_PROP_BITS 0x10
#define CFG_EV_BITS 0x11""",
        """#define CFG_PROP_BITS 0x10
#define CFG_EV_BITS 0x11
#define CFG_ABS_INFO 0x12""",
    )
    patch_file(
        virtio_input_c,
        "HengeVM Tablet",
        """    int kbd = d->kind == HV_VINPUT_KEYBOARD;
    switch (select) {
    case CFG_ID_NAME: {
        const char *name = kbd ? "HengeVM Keyboard" : "HengeVM Mouse";
        size = (uint32_t)strlen(name);
        memcpy(data, name, size);
        break;
    }
    case CFG_ID_SERIAL:
        data[0] = '0';
        size = 1;
        break;
    case CFG_ID_DEVIDS: { /* bustype BUS_VIRTUAL, vendor, product, version */
        /* AppleVirtIOInputKeyboard always says vendor Apple (0x5ac) and takes the
           product from here; HV_KBD_PRODUCT tries others (experiment). */
        uint16_t prod = (uint16_t)(kbd ? (getenv("HV_KBD_PRODUCT") ? atoi(getenv("HV_KBD_PRODUCT")) : 1) : 2);
        uint16_t ids[4] = {0x06, 0x0627, prod, 1};
        memcpy(data, ids, sizeof ids);
        size = sizeof ids;
        break;
    }
    case CFG_PROP_BITS:
        if (!kbd) {
            data[0] = 1; /* INPUT_PROP_POINTER */
            size = 1;
        }
        break;
    case CFG_EV_BITS:
        if (kbd && subsel == HV_EV_KEY) {
            for (unsigned k = 1; k < 0x100; k++) set_bit(data, k); /* every key, no buttons */
            size = 0x100 / 8;
        } else if (!kbd && subsel == HV_EV_KEY) {
            set_bit(data, HV_BTN_LEFT);
            set_bit(data, HV_BTN_RIGHT);
            set_bit(data, HV_BTN_MIDDLE);
            size = HV_BTN_MIDDLE / 8 + 1;
        } else if (!kbd && subsel == HV_EV_REL) {
            set_bit(data, HV_REL_X);
            set_bit(data, HV_REL_Y);
            set_bit(data, HV_REL_HWHEEL);
            set_bit(data, HV_REL_WHEEL);
            size = 2;
        }
        break;""",
        """    int kbd = d->kind == HV_VINPUT_KEYBOARD;
    int tab = d->kind == HV_VINPUT_TABLET;
    switch (select) {
    case CFG_ID_NAME: {
        const char *name = kbd ? "HengeVM Keyboard" : (tab ? "HengeVM Tablet" : "HengeVM Mouse");
        size = (uint32_t)strlen(name);
        memcpy(data, name, size);
        break;
    }
    case CFG_ID_SERIAL:
        data[0] = '0';
        size = 1;
        break;
    case CFG_ID_DEVIDS: { /* bustype BUS_VIRTUAL, vendor, product, version */
        uint16_t prod = (uint16_t)(kbd ? (getenv("HV_KBD_PRODUCT") ? atoi(getenv("HV_KBD_PRODUCT")) : 1) : (tab ? 3 : 2));
        uint16_t ids[4] = {0x06, 0x0627, prod, 1};
        memcpy(data, ids, sizeof ids);
        size = sizeof ids;
        break;
    }
    case CFG_PROP_BITS:
        if (tab) {
            data[0] = 2; /* INPUT_PROP_DIRECT */
            size = 1;
        } else if (!kbd) {
            data[0] = 1; /* INPUT_PROP_POINTER */
            size = 1;
        }
        break;
    case CFG_EV_BITS:
        if (kbd && subsel == HV_EV_KEY) {
            for (unsigned k = 1; k < 0x100; k++) set_bit(data, k); /* every key, no buttons */
            size = 0x100 / 8;
        } else if (!kbd && subsel == HV_EV_KEY) {
            set_bit(data, HV_BTN_LEFT);
            set_bit(data, HV_BTN_RIGHT);
            set_bit(data, HV_BTN_MIDDLE);
            size = HV_BTN_MIDDLE / 8 + 1;
        } else if (tab && subsel == HV_EV_ABS) {
            set_bit(data, HV_ABS_X);
            set_bit(data, HV_ABS_Y);
            size = 1;
        } else if (tab && subsel == HV_EV_REL) {
            set_bit(data, HV_REL_HWHEEL);
            set_bit(data, HV_REL_WHEEL);
            size = 2;
        } else if (!kbd && !tab && subsel == HV_EV_REL) {
            set_bit(data, HV_REL_X);
            set_bit(data, HV_REL_Y);
            set_bit(data, HV_REL_HWHEEL);
            set_bit(data, HV_REL_WHEEL);
            size = 2;
        }
        break;
    case CFG_ABS_INFO:
        if (tab && (subsel == HV_ABS_X || subsel == HV_ABS_Y)) {
            uint32_t absinfo[5] = {0u, 32767u, 0u, 0u, 0u};
            memcpy(data, absinfo, sizeof absinfo);
            size = sizeof absinfo;
        }
        break;""",
    )

    acpi_h = upstream / "devices/acpi.h"
    patch_file(
        acpi_h,
        "hv_acpi_set_enable_spcr",
        "void hv_acpi_build_and_register(HvFwCfg *fw, int ncpus, uint64_t ram_size, int spi_msi_base, int spi_msi_count);",
        """void hv_acpi_set_enable_spcr(int enable);
void hv_acpi_build_and_register(HvFwCfg *fw, int ncpus, uint64_t ram_size, int spi_msi_base, int spi_msi_count);""",
    )

    acpi_c = upstream / "devices/acpi.c"
    patch_file(
        acpi_c,
        "g_acpi_enable_spcr",
        """void hv_acpi_build_and_register(HvFwCfg *fw, int ncpus, uint64_t ram_size, int spi_msi_base, int spi_msi_count) {""",
        """static int g_acpi_enable_spcr = 1;

void hv_acpi_set_enable_spcr(int enable) {
    g_acpi_enable_spcr = enable ? 1 : 0;
}

void hv_acpi_build_and_register(HvFwCfg *fw, int ncpus, uint64_t ram_size, int spi_msi_base, int spi_msi_count) {""",
    )
    patch_file(
        acpi_c,
        "int ntbls = 5;",
        """    tbl_offs[5] = build_spcr(&tabs);
    tbl_lens[5] = (uint32_t)(tabs.len - tbl_offs[5]);

    tbl_offs[6] = build_dbg2_fixed(&tabs);
    tbl_lens[6] = (uint32_t)(tabs.len - tbl_offs[6]);

    tbl_offs[7] = build_iort(&tabs);
    tbl_lens[7] = (uint32_t)(tabs.len - tbl_offs[7]);

    for (int i = 1; i < 8; i++) {
        loader_add_cksum(&ldr, "etc/acpi/tables", (uint32_t)tbl_offs[i] + 9, (uint32_t)tbl_offs[i], tbl_lens[i]);
    }

    /* 3. XSDT */
    size_t xsdt_off = tabs.len;
    acpi_hdr(&tabs, "XSDT", 0, 1, "WINVIRT ");
    for (int i = 0; i < 8; i++) {""",
        """    int ntbls = 5;
    if (g_acpi_enable_spcr) {
        tbl_offs[ntbls] = build_spcr(&tabs);
        tbl_lens[ntbls] = (uint32_t)(tabs.len - tbl_offs[ntbls]);
        ntbls++;
    }

    tbl_offs[ntbls] = build_dbg2_fixed(&tabs);
    tbl_lens[ntbls] = (uint32_t)(tabs.len - tbl_offs[ntbls]);
    ntbls++;

    tbl_offs[ntbls] = build_iort(&tabs);
    tbl_lens[ntbls] = (uint32_t)(tabs.len - tbl_offs[ntbls]);
    ntbls++;

    for (int i = 1; i < ntbls; i++) {
        loader_add_cksum(&ldr, "etc/acpi/tables", (uint32_t)tbl_offs[i] + 9, (uint32_t)tbl_offs[i], tbl_lens[i]);
    }

    /* 3. XSDT */
    size_t xsdt_off = tabs.len;
    acpi_hdr(&tabs, "XSDT", 0, 1, "WINVIRT ");
    for (int i = 0; i < ntbls; i++) {""",
    )

    winvirt_h = upstream / "devices/winvirt.h"
    patch_file(
        winvirt_h,
        '#include "virtio_input.h"',
        '#include "virtio_net.h"\n',
        '#include "virtio_blk.h"\n#include "virtio_input.h"\n#include "virtio_net.h"\n',
    )
    patch_file(
        winvirt_h,
        "HvVirtioInput *vinput_kbd;",
        """    HvHda *hda;
    HvVirtioSnd *snd;""",
        """    HvHda *hda;
    HvVirtioSnd *snd;
    HvVirtioInput *vinput_kbd;
    HvVirtioInput *vinput_tab;
    HvVirtioBlk *vblk1;
    struct HvVirtioGpuPci *vgpu;""",
    )
    patch_file(
        winvirt_h,
        "hv_winvirt_set_virtio_gpu",
        "void hv_winvirt_power_button(HvWinVirt *b);",
        """void hv_winvirt_power_button(HvWinVirt *b);
void hv_winvirt_set_device_flags(int enable_xhci, int enable_virtio_input, int enable_acpi_spcr, int disk1_as_virtio_blk);
void hv_winvirt_set_virtio_gpu(int enable);""",
    )

    winvirt_c = upstream / "devices/winvirt.c"
    patch_file(
        winvirt_c,
        '#include "henge_virtio_gpu.h"',
        '#include "winvirt.h"\n',
        '#include "winvirt.h"\n#include "henge_platform.h"\n#include "henge_virtio_gpu.h"\n#include "virtio.h"\n',
    )
    patch_file(
        winvirt_c,
        "g_wv_enable_virtio_gpu",
        """static uint64_t tick_locked(HvMachine *m, HvCpu *cpu) {
    HvWinVirt *b = m->tick_opaque;
    uint64_t deadline = hv_timer_update(b->gic, cpu);
    if (cpu->index != 0) return deadline;
    hv_pl031_tick(b->rtc);
    if (b->poll) b->poll();
    hv_xhci_poll(b->usb);
    if (b->hda) hv_hda_poll(b->hda);
    if (b->snd) hv_virtio_snd_poll(b->snd);
    return deadline;
}""",
        """typedef struct HvVirtioGpuPci {
    HvVirtio vio;
    HengeVirtioGpuDevice *gpu;
    HvFbDisplay *fb;
} HvVirtioGpuPci;

static void vgpu_sync_scanout0(HvVirtioGpuPci *g) {
    if (!g || !g->fb || !g->gpu) return;
    const uint8_t *px = NULL;
    uint32_t w = 0, h = 0, stride = 0;
    hengelinux_render_lock();
    if (henge_virtio_gpu_get_scanout_frame(g->gpu, 0u, &px, &w, &h, &stride) == 0 && px != NULL) {
        hv_fb_display_set_host_buffer(g->fb, px, w, h, stride, 0x34325258u /* XR24 */);
    } else {
        hv_fb_display_set_host_buffer(g->fb, NULL, 0u, 0u, 0u, 0u);
    }
    hengelinux_render_unlock();
}

static void vgpu_config_write(HvVirtio *v, uint32_t off, uint64_t val, unsigned size) {
    if (off == 4u && size >= 4u) {
        uint32_t ev = 0;
        memcpy(&ev, v->config, 4);
        ev &= ~(uint32_t)val;
        memcpy(v->config, &ev, 4);
    }
}

static void vgpu_notify(HvVirtio *v, int q) {
    HvVirtioGpuPci *g = v->dev;
    if (!g || !g->gpu) return;
    HvVirtqElem e;
    int any = 0;
    while (hv_virtq_pop(v, q, &e) > 0) {
        uint8_t hdr[24];
        memset(hdr, 0, sizeof hdr);
        uint32_t type = 0, flags = 0, ctx_id = 0;
        uint64_t fence_id = 0;
        if (hv_virtq_read(v, &e, 0, hdr, 24) == 24) {
            memcpy(&type, hdr + 0, 4);
            memcpy(&flags, hdr + 4, 4);
            memcpy(&fence_id, hdr + 8, 8);
            memcpy(&ctx_id, hdr + 16, 4);
        }

        uint32_t resp_type = HENGE_VIRTIO_GPU_RESP_OK_NODATA;
        uint32_t written = 24;

        if (q == 1) {
            resp_type = HENGE_VIRTIO_GPU_RESP_OK_NODATA;
        } else if (type == HENGE_VIRTIO_GPU_CMD_GET_DISPLAY_INFO) {
            uint8_t resp[24 + 16 * 24];
            memset(resp, 0, sizeof resp);
            uint32_t w = 1280, h = 800;
            bool en = true;
            henge_virtio_gpu_get_display_info(g->gpu, 0u, &w, &h, &en);
            resp_type = HENGE_VIRTIO_GPU_RESP_OK_DISPLAY_INFO;
            memcpy(resp + 0, &resp_type, 4);
            uint32_t rflags = flags & 1u;
            memcpy(resp + 4, &rflags, 4);
            memcpy(resp + 8, &fence_id, 8);
            memcpy(resp + 24 + 8, &w, 4);
            memcpy(resp + 24 + 12, &h, 4);
            uint32_t enabled32 = en ? 1u : 0u;
            memcpy(resp + 24 + 16, &enabled32, 4);
            written = hv_virtq_write(v, &e, 0, resp, (uint32_t)sizeof resp);
            hv_virtq_push(v, q, &e, written);
            any = 1;
            continue;
        } else if (type == HENGE_VIRTIO_GPU_CMD_GET_EDID) {
            uint32_t scanout = 0;
            hv_virtq_read(v, &e, 24, &scanout, 4);
            uint8_t resp[24 + 8 + 1024];
            memset(resp, 0, sizeof resp);
            if (henge_virtio_gpu_get_edid(g->gpu, scanout, resp + 32) == 0) {
                resp_type = HENGE_VIRTIO_GPU_RESP_OK_EDID;
                uint32_t edid_sz = 128u;
                memcpy(resp + 24, &edid_sz, 4);
            } else {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT;
            }
            memcpy(resp + 0, &resp_type, 4);
            uint32_t rflags = flags & 1u;
            memcpy(resp + 4, &rflags, 4);
            memcpy(resp + 8, &fence_id, 8);
            written = hv_virtq_write(v, &e, 0, resp, (uint32_t)sizeof resp);
            hv_virtq_push(v, q, &e, written);
            any = 1;
            continue;
        } else if (type == HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_2D) {
            uint32_t args[4] = {0};
            hv_virtq_read(v, &e, 24, args, 16);
            resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                g->gpu, type, ctx_id, args[0], 0u, args[2], args[3], args[1], NULL, 0u);
        } else if (type == HENGE_VIRTIO_GPU_CMD_RESOURCE_UNREF) {
            uint32_t res_id = 0;
            hv_virtq_read(v, &e, 24, &res_id, 4);
            int was_scanout0 = (res_id != 0u && res_id == henge_virtio_gpu_scanout_resource(g->gpu, 0u));
            if (was_scanout0) {
                hengelinux_render_lock();
                hv_fb_display_set_host_buffer(g->fb, NULL, 0u, 0u, 0u, 0u);
            }
            resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                g->gpu, type, ctx_id, res_id, 0u, 0u, 0u, 0u, NULL, 0u);
            if (was_scanout0) {
                hengelinux_render_unlock();
            }
        } else if (type == HENGE_VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING) {
            uint32_t args[2] = {0};
            hv_virtq_read(v, &e, 24, args, 8);
            uint32_t res_id = args[0];
            uint32_t nr_entries = args[1];
            if (nr_entries > 4096u) {
                resp_type = HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
            } else {
                HengeGpuBackingEntry *entries = nr_entries ? calloc(nr_entries, sizeof(*entries)) : NULL;
                if (nr_entries && !entries) {
                    resp_type = HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
                } else {
                    for (uint32_t i = 0; i < nr_entries; i++) {
                        uint8_t mem_ent[16];
                        memset(mem_ent, 0, sizeof mem_ent);
                        hv_virtq_read(v, &e, 32u + i * 16u, mem_ent, 16u);
                        uint64_t addr = 0;
                        uint32_t len = 0;
                        memcpy(&addr, mem_ent + 0, 8);
                        memcpy(&len, mem_ent + 8, 4);
                        entries[i].guest_addr = addr;
                        entries[i].length = len;
                        entries[i].host_ptr = (len > 0u) ? (const uint8_t *)hv_phys_ptr(v->m, addr, len) : NULL;
                    }
                    resp_type = (henge_virtio_gpu_attach_backing(g->gpu, res_id, entries, nr_entries) == 0)
                        ? HENGE_VIRTIO_GPU_RESP_OK_NODATA
                        : HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE;
                    free(entries);
                }
            }
        } else if (type == HENGE_VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING) {
            uint32_t res_id = 0;
            hv_virtq_read(v, &e, 24, &res_id, 4);
            resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                g->gpu, type, ctx_id, res_id, 0u, 0u, 0u, 0u, NULL, 0u);
        } else if (type == HENGE_VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D) {
            uint8_t req[32];
            memset(req, 0, sizeof req);
            hv_virtq_read(v, &e, 24, req, sizeof req);
            uint32_t rx = 0, ry = 0, rw = 0, rh = 0, res_id = 0;
            uint64_t off = 0;
            memcpy(&rx, req + 0, 4);
            memcpy(&ry, req + 4, 4);
            memcpy(&rw, req + 8, 4);
            memcpy(&rh, req + 12, 4);
            memcpy(&off, req + 16, 8);
            memcpy(&res_id, req + 24, 4);
            resp_type = (henge_virtio_gpu_transfer_to_host_2d(g->gpu, res_id, rx, ry, rw, rh, off) == 0)
                ? HENGE_VIRTIO_GPU_RESP_OK_NODATA
                : HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE;
        } else if (type == HENGE_VIRTIO_GPU_CMD_SET_SCANOUT) {
            uint32_t req[6] = {0};
            hv_virtq_read(v, &e, 24, req, sizeof req);
            uint32_t rw = req[2], rh = req[3], scanout_id = req[4], res_id = req[5];
            resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                g->gpu, type, ctx_id, res_id, scanout_id, rw, rh, 0u, NULL, 0u);
            if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA && scanout_id == 0u) {
                vgpu_sync_scanout0(g);
            }
        } else if (type == HENGE_VIRTIO_GPU_CMD_RESOURCE_FLUSH) {
            uint32_t req[5] = {0};
            hv_virtq_read(v, &e, 24, req, sizeof req);
            uint32_t res_id = req[4];
            resp_type = (uint32_t)henge_virtio_gpu_process_ctrl(
                g->gpu, type, ctx_id, res_id, 0u, req[2], req[3], 0u, NULL, 0u);
            if (resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA &&
                res_id == henge_virtio_gpu_scanout_resource(g->gpu, 0u)) {
                vgpu_sync_scanout0(g);
            }
        } else {
            resp_type = HENGE_VIRTIO_GPU_RESP_ERR_UNSPEC;
        }

        uint8_t resp[24];
        memset(resp, 0, sizeof resp);
        memcpy(resp + 0, &resp_type, 4);
        uint32_t rflags = flags & 1u;
        memcpy(resp + 4, &rflags, 4);
        memcpy(resp + 8, &fence_id, 8);
        written = hv_virtq_write(v, &e, 0, resp, 24);
        hv_virtq_push(v, q, &e, written);
        any = 1;
    }
    if (any) hv_virtio_interrupt(v);
}

static HvVirtioGpuPci *henge_virtio_gpu_pci_create(HvMachine *m, HvPcie *bus, HvFbDisplay *fb) {
    HengeVirtioGpuConfig cfg;
    if (henge_virtio_gpu_init_config(HENGE_GPU_BACKEND_GOP_2D, 128u, &cfg) != 0) return NULL;
    HengeVirtioGpuDevice *gpu = henge_virtio_gpu_create(&cfg);
    if (!gpu) return NULL;
    henge_virtio_gpu_set_display_mode(gpu, 0u, 1280u, 800u, true);

    HvVirtioGpuPci *g = calloc(1, sizeof *g);
    if (!g) {
        henge_virtio_gpu_destroy(gpu);
        return NULL;
    }
    g->gpu = gpu;
    g->fb = fb;
    hv_virtio_init(&g->vio, m, 16, 0x038000, 2, HENGE_VIRTIO_GPU_F_EDID);
    g->vio.dev = g;
    g->vio.notify = vgpu_notify;
    g->vio.config_write = vgpu_config_write;
    g->vio.config_len = 16;
    uint32_t num_scanouts = 1u;
    memcpy(g->vio.config + 8, &num_scanouts, 4);
    hv_pcie_attach(bus, &g->vio.pci);
    fprintf(stderr, "winvm: virtio-gpu 2D KMS (0x1af4:0x1050, EDID 1280x800) attached on PCIe\\n");
    return g;
}

static int g_wv_enable_xhci = 1;
static int g_wv_enable_virtio_input = 1;
static int g_wv_enable_acpi_spcr = 1;
static int g_wv_disk1_virtio_blk = 0;
static int g_wv_enable_virtio_gpu = 0;

void hv_winvirt_set_device_flags(int enable_xhci, int enable_virtio_input, int enable_acpi_spcr, int disk1_as_virtio_blk) {
    g_wv_enable_xhci = enable_xhci ? 1 : 0;
    g_wv_enable_virtio_input = enable_virtio_input ? 1 : 0;
    g_wv_enable_acpi_spcr = enable_acpi_spcr ? 1 : 0;
    g_wv_disk1_virtio_blk = disk1_as_virtio_blk ? 1 : 0;
}

void hv_winvirt_set_virtio_gpu(int enable) {
    g_wv_enable_virtio_gpu = enable ? 1 : 0;
}

static uint64_t tick_locked(HvMachine *m, HvCpu *cpu) {
    HvWinVirt *b = m->tick_opaque;
    uint64_t deadline = hv_timer_update(b->gic, cpu);
    if (cpu->index != 0) return deadline;
    hv_pl031_tick(b->rtc);
    if (b->poll) b->poll();
    if (b->usb) hv_xhci_poll(b->usb);
    if (b->hda) hv_hda_poll(b->hda);
    if (b->snd) hv_virtio_snd_poll(b->snd);
    if (b->vinput_kbd) hv_virtio_input_poll(b->vinput_kbd);
    if (b->vinput_tab) hv_virtio_input_poll(b->vinput_tab);
    if (b->vblk1) hv_virtio_blk_poll(b->vblk1);
    return deadline;
}""",
    )
    patch_file(
        winvirt_c,
        "hv_acpi_set_enable_spcr(g_wv_enable_acpi_spcr);",
        "    hv_acpi_build_and_register(b->fw_cfg, b->ncpus, ram_size, 0, 0);",
        """    hv_acpi_set_enable_spcr(g_wv_enable_acpi_spcr);
    hv_acpi_build_and_register(b->fw_cfg, b->ncpus, ram_size, 0, 0);""",
    )
    patch_file(
        winvirt_c,
        "g_wv_enable_virtio_input",
        """    b->usb = hv_xhci_create(m, b->pcie);
    b->hda = hv_hda_create(m, b->pcie);
    if (disk1) b->nvme1 = hv_nvme_create(m, b->pcie, disk1, "WIN11INST");""",
        """    if (g_wv_enable_xhci) b->usb = hv_xhci_create(m, b->pcie);
    b->hda = hv_hda_create(m, b->pcie);
    if (g_wv_enable_virtio_input) {
        b->vinput_kbd = hv_virtio_input_create(m, b->pcie, HV_VINPUT_KEYBOARD);
        b->vinput_tab = hv_virtio_input_create(m, b->pcie, HV_VINPUT_TABLET);
    }
    if (disk1) {
        if (g_wv_disk1_virtio_blk) b->vblk1 = hv_virtio_blk_create(m, b->pcie, disk1, HV_VBLK_PLAIN);
        else b->nvme1 = hv_nvme_create(m, b->pcie, disk1, "WIN11INST");
    }
    if (g_wv_enable_virtio_gpu) {
        b->vgpu = henge_virtio_gpu_pci_create(m, b->pcie, b->fb);
    }""",
    )

    winvm_h = upstream / "host/winvm.h"
    patch_file(
        winvm_h,
        "HENGE_WINVM_HAS_V3_GPU",
        """    int log;
    int stats_interval;
} HvWinVmConfig;""",
        """    int log;
    int stats_interval;
    int disable_xhci;         /* 1 = omit xHCI USB 3 controller (avoids Linux 90s initrd stall) */
    int enable_virtio_input;  /* 1 = attach virtio-input keyboard + absolute tablet */
    int disable_acpi_spcr;    /* 1 = omit ACPI SPCR so Linux defaults /dev/console to tty0 */
    int disk1_virtio_blk;     /* 1 = expose disk1 as read-only virtio-blk instead of NVMe1 */
    int enable_virtio_gpu;    /* 1 = attach PCIe virtio-gpu 2D KMS (0x1af4:0x1050) */
} HvWinVmConfig;

#define HENGE_WINVM_HAS_V2_FLAGS 1
#define HENGE_WINVM_HAS_V3_GPU 1""",
    )

    winvm_c = upstream / "host/winvm.c"
    patch_file(
        winvm_c,
        "hv_winvirt_set_virtio_gpu(c->enable_virtio_gpu);",
        """    if (hv_winvirt_create(&board, &m, cpus, ncpus, ram_bytes, c->prealloc_ram, c->code_fd, c->vars_fd,
                          d0_ptr, d1_ptr, mac, c->enable_sound) != 0) {""",
        """    hv_winvirt_set_device_flags(!c->disable_xhci, c->enable_virtio_input, !c->disable_acpi_spcr, c->disk1_virtio_blk);
    hv_winvirt_set_virtio_gpu(c->enable_virtio_gpu);
    if (hv_winvirt_create(&board, &m, cpus, ncpus, ram_bytes, c->prealloc_ram, c->code_fd, c->vars_fd,
                          d0_ptr, d1_ptr, mac, c->enable_sound) != 0) {""",
    )
    patch_file(
        winvm_c,
        "henge_hid_usage_to_linux_key",
        """void hv_winvm_key_hid(uint8_t usage, int down) {
    if (board.usb) hv_xhci_key(board.usb, usage, down);
}

void hv_winvm_key_linux(uint16_t code, int down) {
    if (board.usb) hv_xhci_key_linux(board.usb, code, down);
}

void hv_winvm_tablet(double x_norm, double y_norm, uint8_t buttons, int8_t wheel) {
    if (!board.usb) return;
    if (x_norm < 0.0) x_norm = 0.0;
    if (x_norm > 1.0) x_norm = 1.0;
    if (y_norm < 0.0) y_norm = 0.0;
    if (y_norm > 1.0) y_norm = 1.0;
    int ax = (int)(x_norm * 32767.0 + 0.5);
    int ay = (int)(y_norm * 32767.0 + 0.5);
    hv_xhci_tablet(board.usb, ax, ay, buttons, wheel);
}

void hv_winvm_send_ctrl_alt_del(void) {
    if (!board.usb) return;
    /* Left Ctrl (0xe0), Left Alt (0xe2), Delete (0x4c) */
    hv_xhci_key(board.usb, 0xe0, 1);
    hv_xhci_key(board.usb, 0xe2, 1);
    hv_xhci_key(board.usb, 0x4c, 1);
    hv_xhci_key(board.usb, 0x4c, 0);
    hv_xhci_key(board.usb, 0xe2, 0);
    hv_xhci_key(board.usb, 0xe0, 0);
}""",
        """static uint16_t henge_hid_usage_to_linux_key(uint8_t usage) {
    static const uint16_t kMap[256] = {
        [0x04] = 30, [0x05] = 48, [0x06] = 46, [0x07] = 32, [0x08] = 18, [0x09] = 33,
        [0x0A] = 34, [0x0B] = 35, [0x0C] = 23, [0x0D] = 36, [0x0E] = 37, [0x0F] = 38,
        [0x10] = 50, [0x11] = 49, [0x12] = 24, [0x13] = 25, [0x14] = 16, [0x15] = 19,
        [0x16] = 31, [0x17] = 20, [0x18] = 22, [0x19] = 47, [0x1A] = 17, [0x1B] = 45,
        [0x1C] = 21, [0x1D] = 44,
        [0x1E] = 2, [0x1F] = 3, [0x20] = 4, [0x21] = 5, [0x22] = 6,
        [0x23] = 7, [0x24] = 8, [0x25] = 9, [0x26] = 10, [0x27] = 11,
        [0x28] = 28, [0x29] = 1, [0x2A] = 14, [0x2B] = 15, [0x2C] = 57,
        [0x2D] = 12, [0x2E] = 13, [0x2F] = 26, [0x30] = 27, [0x31] = 43,
        [0x33] = 39, [0x34] = 40, [0x35] = 41, [0x36] = 51, [0x37] = 52,
        [0x38] = 53, [0x39] = 58,
        [0x3A] = 59, [0x3B] = 60, [0x3C] = 61, [0x3D] = 62, [0x3E] = 63, [0x3F] = 64,
        [0x40] = 65, [0x41] = 66, [0x42] = 67, [0x43] = 68, [0x44] = 87, [0x45] = 88,
        [0x46] = 99, [0x47] = 70, [0x48] = 119, [0x49] = 110, [0x4A] = 102, [0x4B] = 104,
        [0x4C] = 111, [0x4D] = 107, [0x4E] = 109, [0x4F] = 106, [0x50] = 105, [0x51] = 108,
        [0x52] = 103, [0x53] = 69, [0x54] = 98, [0x55] = 55, [0x56] = 74, [0x57] = 78,
        [0x58] = 96, [0x59] = 79, [0x5A] = 80, [0x5B] = 81, [0x5C] = 75, [0x5D] = 76,
        [0x5E] = 77, [0x5F] = 71, [0x60] = 72, [0x61] = 73, [0x62] = 82, [0x63] = 83,
        [0x65] = 127,
        [0xE0] = 29, [0xE1] = 42, [0xE2] = 56, [0xE3] = 125,
        [0xE4] = 97, [0xE5] = 54, [0xE6] = 100, [0xE7] = 126,
    };
    return kMap[usage];
}

void hv_winvm_key_hid(uint8_t usage, int down) {
    if (board.usb) hv_xhci_key(board.usb, usage, down);
    if (board.vinput_kbd) {
        uint16_t code = henge_hid_usage_to_linux_key(usage);
        if (code != 0) {
            hv_virtio_input_send(board.vinput_kbd, HV_EV_KEY, code, down ? 1 : 0);
            hv_virtio_input_send(board.vinput_kbd, HV_EV_SYN, 0, 0);
        }
    }
}

void hv_winvm_key_linux(uint16_t code, int down) {
    if (board.usb) hv_xhci_key_linux(board.usb, code, down);
    if (board.vinput_kbd && code != 0) {
        hv_virtio_input_send(board.vinput_kbd, HV_EV_KEY, code, down ? 1 : 0);
        hv_virtio_input_send(board.vinput_kbd, HV_EV_SYN, 0, 0);
    }
}

void hv_winvm_tablet(double x_norm, double y_norm, uint8_t buttons, int8_t wheel) {
    if (!board.usb && !board.vinput_tab) return;
    if (x_norm < 0.0) x_norm = 0.0;
    if (x_norm > 1.0) x_norm = 1.0;
    if (y_norm < 0.0) y_norm = 0.0;
    if (y_norm > 1.0) y_norm = 1.0;
    int ax = (int)(x_norm * 32767.0 + 0.5);
    int ay = (int)(y_norm * 32767.0 + 0.5);
    if (board.usb) hv_xhci_tablet(board.usb, ax, ay, buttons, wheel);
    if (board.vinput_tab) {
        static _Atomic uint8_t prev_buttons = 0;
        uint8_t old_b = atomic_exchange_explicit(&prev_buttons, buttons, memory_order_acq_rel);
        hv_virtio_input_send(board.vinput_tab, HV_EV_ABS, HV_ABS_X, ax);
        hv_virtio_input_send(board.vinput_tab, HV_EV_ABS, HV_ABS_Y, ay);
        if ((buttons ^ old_b) & 1u)
            hv_virtio_input_send(board.vinput_tab, HV_EV_KEY, HV_BTN_LEFT, (buttons & 1u) ? 1 : 0);
        if ((buttons ^ old_b) & 2u)
            hv_virtio_input_send(board.vinput_tab, HV_EV_KEY, HV_BTN_RIGHT, (buttons & 2u) ? 1 : 0);
        if ((buttons ^ old_b) & 4u)
            hv_virtio_input_send(board.vinput_tab, HV_EV_KEY, HV_BTN_MIDDLE, (buttons & 4u) ? 1 : 0);
        if (wheel != 0)
            hv_virtio_input_send(board.vinput_tab, HV_EV_REL, HV_REL_WHEEL, (int32_t)wheel);
        hv_virtio_input_send(board.vinput_tab, HV_EV_SYN, 0, 0);
    }
}

void hv_winvm_send_ctrl_alt_del(void) {
    /* Left Ctrl (0xe0), Left Alt (0xe2), Delete (0x4c) */
    hv_winvm_key_hid(0xe0, 1);
    hv_winvm_key_hid(0xe2, 1);
    hv_winvm_key_hid(0x4c, 1);
    hv_winvm_key_hid(0x4c, 0);
    hv_winvm_key_hid(0xe2, 0);
    hv_winvm_key_hid(0xe0, 0);
}""",
    )

    # 8. Milestone 6.5 (Phase E): HvFbDisplay host-buffer hook + Linux xhci_hcd 1.1+ hardening
    fb_display_h = upstream / "devices/fb_display.h"
    patch_file(
        fb_display_h,
        "hv_fb_display_set_host_buffer",
        "int hv_fb_display_get_frame(HvFbDisplay *fb, const uint8_t **pixels, uint32_t *w, uint32_t *h, uint32_t *stride);",
        """int hv_fb_display_get_frame(HvFbDisplay *fb, const uint8_t **pixels, uint32_t *w, uint32_t *h, uint32_t *stride);
void hv_fb_display_set_host_buffer(HvFbDisplay *fb, const uint8_t *host_ptr, uint32_t width, uint32_t height, uint32_t stride, uint32_t fourcc);""",
    )

    fb_display_c = upstream / "devices/fb_display.c"
    patch_file(
        fb_display_c,
        "hv_fb_display_set_host_buffer",
        """    *pixels = fb->fb_host;
    *w = fb->width;
    *h = fb->height;
    *stride = fb->stride;
    pthread_mutex_unlock(&fb->mu);
    return 0;
}""",
        """    *pixels = fb->fb_host;
    *w = fb->width;
    *h = fb->height;
    *stride = fb->stride;
    pthread_mutex_unlock(&fb->mu);
    return 0;
}

void hv_fb_display_set_host_buffer(HvFbDisplay *fb, const uint8_t *host_ptr, uint32_t width, uint32_t height, uint32_t stride, uint32_t fourcc) {
    if (!fb) return;
    pthread_mutex_lock(&fb->mu);
    if (host_ptr && width > 0 && height > 0 && stride >= width * 4u) {
        fb->fb_pa = 0;
        fb->fb_host = host_ptr;
        fb->width = width;
        fb->height = height;
        fb->stride = stride;
        fb->fourcc = fourcc;
        fb->active = 1;
    } else {
        fb->fb_pa = 0;
        fb->fb_host = NULL;
        fb->width = 0;
        fb->height = 0;
        fb->stride = 0;
        fb->active = 0;
    }
    pthread_mutex_unlock(&fb->mu);
}""",
    )

    xhci_c = upstream / "devices/xhci.c"
    patch_file(
        xhci_c,
        "CC_CMD_RING_STOPPED",
        "enum { CC_SUCCESS = 1, CC_TRB_ERROR = 5, CC_STALL = 6, CC_SLOTS_FULL = 9, CC_SHORT_PACKET = 13, CC_CONTEXT_STATE = 19 };",
        "enum { CC_SUCCESS = 1, CC_TRB_ERROR = 5, CC_STALL = 6, CC_SLOTS_FULL = 9, CC_SHORT_PACKET = 13, CC_CONTEXT_STATE = 19, CC_CMD_RING_STOPPED = 24 };",
    )
    patch_file(
        xhci_c,
        "/* Deliver deferred MSI-X interrupts",
        """static void update_irq(HvXhci *x) {
    if (hv_pci_msix_enabled(&x->pci)) {
        hv_pci_set_intx(&x->pci, 0);
        return;
    }""",
        """static void update_irq(HvXhci *x) {
    if (hv_pci_msix_enabled(&x->pci)) {
        hv_pci_set_intx(&x->pci, 0);
        /* Deliver deferred MSI-X interrupts when USBCMD.INTE or IMAN.IE is enabled with IP=1. */
        if (x->usbcmd & 4) {
            for (int i = 0; i < HV_XHCI_INTRS; i++) {
                if ((x->intr[i].iman & 1) && (x->intr[i].iman & 2)) {
                    x->intr[i].iman &= ~1u;
                    hv_pci_msix_notify(&x->pci, (uint16_t)i);
                }
            }
        }
        return;
    }""",
    )
    patch_file(
        xhci_c,
        "CC_CMD_RING_STOPPED, 0);",
        """        case 0x18:
        case 0x1c: {
            if (r == 0x18 && size == 4) {
                x->cmd.dequeue = (x->cmd.dequeue & ~0xffffffffull) | ((uint32_t)v & ~0x3fu);
                x->cmd.ccs = (int)(v & 1);
            } else if (r == 0x1c) {
                x->cmd.dequeue = (x->cmd.dequeue & 0xffffffffull) | v << 32;
            } else {
                x->cmd.dequeue = v & ~0x3full;
                x->cmd.ccs = (int)(v & 1);
            }
            break;
        }""",
        """        case 0x18:
        case 0x1c: {
            if (r == 0x18 && (v & 6u)) {
                /* xHCI 5.4.5: CS (bit 1) / CA (bit 2) stops command ring without clobbering dequeue pointer. */
                x->cmd_running = 0;
                cmd_completion(x, x->cmd.dequeue, CC_CMD_RING_STOPPED, 0);
                break;
            }
            if (x->cmd_running) break;
            if (r == 0x18 && size == 4) {
                x->cmd.dequeue = (x->cmd.dequeue & ~0xffffffffull) | ((uint32_t)v & ~0x3fu);
                x->cmd.ccs = (int)(v & 1);
            } else if (r == 0x1c) {
                x->cmd.dequeue = (x->cmd.dequeue & 0xffffffffull) | v << 32;
            } else {
                x->cmd.dequeue = v & ~0x3full;
                x->cmd.ccs = (int)(v & 1);
            }
            break;
        }""",
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
