/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "henge_platform.h"

#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static atomic_bool g_render_paused = false;

static uint64_t fnv1a_64(const char *str) {
    uint64_t hash = 14695981039346656037ULL;
    const unsigned char *p = (const unsigned char *)str;
    while (*p != '\0') {
        hash ^= (uint64_t)(*p++);
        hash *= 1099511628211ULL;
    }
    return hash;
}

int henge_format_unix_socket_path(const char *container_dir,
                                  const char *socket_name,
                                  char *out_path,
                                  size_t out_cap) {
    if (container_dir == NULL || socket_name == NULL || out_path == NULL) {
        return -1;
    }
    if (out_cap == 0U || socket_name[0] == '\0') {
        return -1;
    }

    size_t effective_cap = out_cap;
    if (effective_cap > HENGE_DARWIN_SUN_PATH_MAX) {
        effective_cap = HENGE_DARWIN_SUN_PATH_MAX;
    }

    size_t dir_len = strlen(container_dir);
    while (dir_len > 1U && container_dir[dir_len - 1U] == '/') {
        dir_len--;
    }

    /* Direct path fits within Darwin's 104-byte sockaddr_un.sun_path limit. */
    int written = snprintf(out_path, effective_cap, "%.*s/%s",
                           (int)dir_len, container_dir, socket_name);
    if (written > 0 && (size_t)written < effective_cap) {
        return 0;
    }

    /* Fallback to /tmp with deterministic 64-bit container hash to stay < 104 B. */
    uint64_t digest = fnv1a_64(container_dir);
    written = snprintf(out_path, effective_cap, "/tmp/hl-%016llx-%s",
                       (unsigned long long)digest, socket_name);
    if (written > 0 && (size_t)written < effective_cap) {
        return 0;
    }

    out_path[0] = '\0';
    return -1;
}

uint32_t henge_decode_granule_bits(uint32_t tg_bits, int ttbr1) {
    uint32_t enc = tg_bits & 0x3U;
    if (ttbr1 != 0) {
        switch (enc) {
            case 0x2U: return 12U; /* 4 KiB */
            case 0x1U: return 14U; /* 16 KiB */
            case 0x3U: return 16U; /* 64 KiB */
            default:   return 0U;
        }
    } else {
        switch (enc) {
            case 0x0U: return 12U; /* 4 KiB */
            case 0x2U: return 14U; /* 16 KiB */
            case 0x1U: return 16U; /* 64 KiB */
            default:   return 0U;
        }
    }
}

uint64_t henge_align_guest_ram_bytes(uint32_t requested_mib, uint32_t device_cap_mib) {
    uint32_t upper = device_cap_mib;
    if (upper > HENGE_MAX_GUEST_RAM_MIB) {
        upper = HENGE_MAX_GUEST_RAM_MIB;
    }
    if (upper < HENGE_MIN_GUEST_RAM_MIB) {
        upper = HENGE_MIN_GUEST_RAM_MIB;
    }

    uint32_t clamped_mib = requested_mib;
    if (clamped_mib < HENGE_MIN_GUEST_RAM_MIB) {
        clamped_mib = HENGE_MIN_GUEST_RAM_MIB;
    }
    if (clamped_mib > upper) {
        clamped_mib = upper;
    }

    uint64_t raw_bytes = (uint64_t)clamped_mib * 1024ULL * 1024ULL;
    return raw_bytes & ~(HENGE_HOST_PAGE_SIZE - 1ULL);
}

void hengelinux_set_render_paused(bool paused) {
    atomic_store_explicit(&g_render_paused, paused, memory_order_release);
}

bool hengelinux_is_render_paused(void) {
    return atomic_load_explicit(&g_render_paused, memory_order_acquire);
}
