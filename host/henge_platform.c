/* SPDX-License-Identifier: GPL-3.0-or-later */
#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "henge_platform.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <mach/mach_time.h>

/* Provide pipe2 fallback if referenced by static libglib/libslirp on iOS. */
__attribute__((weak, visibility("default")))
int pipe2(int fds[2], int flags) {
    if (fds == NULL) {
        errno = EFAULT;
        return -1;
    }
    if ((flags & ~(O_CLOEXEC | O_NONBLOCK)) != 0) {
        errno = EINVAL;
        return -1;
    }
    if (pipe(fds) < 0) {
        return -1;
    }
    if ((flags & O_CLOEXEC) != 0) {
        if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0) {
            int saved = errno;
            close(fds[0]);
            close(fds[1]);
            errno = saved;
            return -1;
        }
    }
    if ((flags & O_NONBLOCK) != 0) {
        int f0 = fcntl(fds[0], F_GETFL);
        int f1 = fcntl(fds[1], F_GETFL);
        if (f0 < 0 || f1 < 0 ||
            fcntl(fds[0], F_SETFL, f0 | O_NONBLOCK) < 0 ||
            fcntl(fds[1], F_SETFL, f1 | O_NONBLOCK) < 0) {
            int saved = errno;
            close(fds[0]);
            close(fds[1]);
            errno = saved;
            return -1;
        }
    }
    return 0;
}
#endif

static atomic_bool g_render_paused = false;
static pthread_mutex_t g_render_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_clock_mutex = PTHREAD_MUTEX_INITIALIZER;
static atomic_uint_fast64_t g_clock_seq = 0ULL;
static atomic_bool g_vm_clock_paused = false;
static atomic_uint_fast64_t g_clock_pause_start_ticks = 0ULL;
static atomic_uint_fast64_t g_suspend_offset_ticks = 0ULL;
static atomic_uint_fast64_t g_neg_suspend_offset_ticks = 0ULL;
static atomic_uint_fast64_t g_last_raw_ticks = 0ULL;
static atomic_uint_fast64_t g_last_compensated_ticks = 0ULL;

/* Unscheduled XNU freezer jump threshold: 500 ms at 24 MHz (12,000,000 ticks). */
#define HENGE_SUSPEND_JUMP_THRESHOLD_TICKS 12000000ULL

#if defined(__APPLE__)
static mach_timebase_info_data_t g_darwin_timebase = {0, 0};
static pthread_once_t g_darwin_timebase_once = PTHREAD_ONCE_INIT;

static void init_darwin_timebase_once(void) {
    mach_timebase_info(&g_darwin_timebase);
}
#endif

static uint64_t platform_raw_ticks_24mhz(void) {
#if defined(__APPLE__)
    pthread_once(&g_darwin_timebase_once, init_darwin_timebase_once);
    uint64_t raw = mach_absolute_time();
    if (g_darwin_timebase.denom == 0U ||
        (g_darwin_timebase.numer == 125U && g_darwin_timebase.denom == 3U)) {
        return raw;
    }
    __uint128_t scaled = ((__uint128_t)raw * (uint64_t)g_darwin_timebase.numer * 24ULL) /
                         ((uint64_t)g_darwin_timebase.denom * 1000ULL);
    return (uint64_t)scaled;
#else
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0ULL;
    }
    return (uint64_t)ts.tv_sec * 24000000ULL + ((uint64_t)ts.tv_nsec * 24ULL) / 1000ULL;
#endif
}

#if !(defined(__APPLE__) && TARGET_OS_IPHONE)
static uint64_t fnv1a_64(const char *str) {
    uint64_t hash = 14695981039346656037ULL;
    const unsigned char *p = (const unsigned char *)str;
    while (*p != '\0') {
        hash ^= (uint64_t)(*p++);
        hash *= 1099511628211ULL;
    }
    return hash;
}
#endif

static bool is_valid_uuid36(const char *s, size_t len) {
    if (len != 36U) {
        return false;
    }
    for (size_t i = 0U; i < 36U; i++) {
        char c = s[i];
        if (i == 8U || i == 13U || i == 18U || i == 23U) {
            if (c != '-') {
                return false;
            }
        } else {
            bool is_hex = (c >= '0' && c <= '9') ||
                          (c >= 'a' && c <= 'f') ||
                          (c >= 'A' && c <= 'F');
            if (!is_hex) {
                return false;
            }
        }
    }
    return true;
}

/*
 * Extract an iOS app container root (up to the 36-char UUID directory) when
 * given a path inside /var/mobile/Containers/Data/Application/<UUID>/... or
 * /private/var/mobile/Containers/Data/Application/<UUID>/..., normalizing
 * /private/var/ to /var/ to save 8 bytes toward Darwin's 104-byte sun_path cap.
 */
static bool format_ios_sandbox_tmp_socket(const char *container_dir,
                                          const char *socket_name,
                                          char *out_path,
                                          size_t effective_cap) {
    const char *p = container_dir;
    if (strncmp(p, "/private/var/", 13) == 0) {
        p += 8; /* Points at "/var/..." */
    }

    const char *marker = "/Containers/Data/Application/";
    const char *app_dir = strstr(p, marker);
    if (app_dir != NULL) {
        const char *uuid_start = app_dir + strlen(marker);
        while (*uuid_start == '/') {
            uuid_start++;
        }
        const char *uuid_end = strchr(uuid_start, '/');
        size_t uuid_len = (uuid_end != NULL)
            ? (size_t)(uuid_end - uuid_start)
            : strlen(uuid_start);
        if (!is_valid_uuid36(uuid_start, uuid_len)) {
            return false;
        }
        size_t root_len = (uuid_end != NULL)
            ? (size_t)(uuid_end - p)
            : strlen(p);

        int written = snprintf(out_path, effective_cap, "%.*s/tmp/%s",
                               (int)root_len, p, socket_name);
        if (written > 0 && (size_t)written < effective_cap) {
            return true;
        }
        written = snprintf(out_path, effective_cap, "%.*s/tmp/hl.sock",
                           (int)root_len, p);
        if (written > 0 && (size_t)written < effective_cap) {
            return true;
        }
    }

#if defined(__APPLE__) && TARGET_OS_IPHONE
    const char *tmpdir = getenv("TMPDIR");
    if (tmpdir != NULL && tmpdir[0] != '\0') {
        const char *tp = tmpdir;
        if (strncmp(tp, "/private/var/", 13) == 0) {
            tp += 8;
        }
        size_t tlen = strlen(tp);
        while (tlen > 1U && tp[tlen - 1U] == '/') {
            tlen--;
        }
        int written = snprintf(out_path, effective_cap, "%.*s/%s",
                               (int)tlen, tp, socket_name);
        if (written > 0 && (size_t)written < effective_cap) {
            return true;
        }
        written = snprintf(out_path, effective_cap, "%.*s/hl.sock",
                           (int)tlen, tp);
        if (written > 0 && (size_t)written < effective_cap) {
            return true;
        }
    }
#endif

    return false;
}

int henge_format_unix_socket_path(const char *container_dir,
                                  const char *socket_name,
                                  char *out_path,
                                  size_t out_cap) {
    if (container_dir == NULL || socket_name == NULL || out_path == NULL) {
        return -1;
    }
    if (out_cap == 0U || socket_name[0] == '\0' || strchr(socket_name, '/') != NULL ||
        strcmp(socket_name, ".") == 0 || strcmp(socket_name, "..") == 0) {
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
    int written = (dir_len == 1U && container_dir[0] == '/')
        ? snprintf(out_path, effective_cap, "/%s", socket_name)
        : snprintf(out_path, effective_cap, "%.*s/%s",
                   (int)dir_len, container_dir, socket_name);
    if (written > 0 && (size_t)written < effective_cap) {
        return 0;
    }

    /* On iOS sandbox paths, bind inside <container>/tmp/ (Seatbelt blocks /tmp). */
    if (format_ios_sandbox_tmp_socket(container_dir, socket_name, out_path, effective_cap)) {
        return 0;
    }

#if !(defined(__APPLE__) && TARGET_OS_IPHONE)
    /* Fallback to /tmp with deterministic 64-bit container hash on macOS/Linux. */
    uint64_t digest = fnv1a_64(container_dir);
    written = snprintf(out_path, effective_cap, "/tmp/hl-%016llx-%s",
                       (unsigned long long)digest, socket_name);
    if (written > 0 && (size_t)written < effective_cap) {
        return 0;
    }
#endif

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
    pthread_mutex_lock(&g_render_mutex);
    atomic_store_explicit(&g_render_paused, paused, memory_order_release);
    pthread_mutex_unlock(&g_render_mutex);
}

bool hengelinux_is_render_paused(void) {
    return atomic_load_explicit(&g_render_paused, memory_order_acquire);
}

void hengelinux_render_lock(void) {
    pthread_mutex_lock(&g_render_mutex);
}

void hengelinux_render_unlock(void) {
    pthread_mutex_unlock(&g_render_mutex);
}

void hengelinux_set_vm_clock_paused(bool paused) {
    pthread_mutex_lock(&g_clock_mutex);
    bool was_paused = atomic_load_explicit(&g_vm_clock_paused, memory_order_relaxed);
    if (paused && !was_paused) {
        atomic_store_explicit(&g_clock_pause_start_ticks, platform_raw_ticks_24mhz(), memory_order_release);
        atomic_store_explicit(&g_vm_clock_paused, true, memory_order_release);
    } else if (!paused && was_paused) {
        uint64_t start = atomic_load_explicit(&g_clock_pause_start_ticks, memory_order_acquire);
        uint64_t now = platform_raw_ticks_24mhz();
        uint64_t seq = atomic_load_explicit(&g_clock_seq, memory_order_relaxed);
        atomic_store_explicit(&g_clock_seq, seq + 1ULL, memory_order_release);
        if (now > start && start > 0ULL) {
            uint64_t prev_off = atomic_fetch_add_explicit(&g_suspend_offset_ticks,
                                                          now - start,
                                                          memory_order_acq_rel);
            atomic_store_explicit(&g_neg_suspend_offset_ticks,
                                  0ULL - (prev_off + (now - start)),
                                  memory_order_release);
        }
        atomic_store_explicit(&g_last_raw_ticks, now, memory_order_release);
        atomic_store_explicit(&g_clock_seq, seq + 2ULL, memory_order_release);
        atomic_store_explicit(&g_clock_pause_start_ticks, 0ULL, memory_order_release);
        atomic_store_explicit(&g_vm_clock_paused, false, memory_order_release);
    }
    pthread_mutex_unlock(&g_clock_mutex);
}

uint64_t hengelinux_suspend_counter_offset(void) {
    uint64_t base_offset = atomic_load_explicit(&g_suspend_offset_ticks, memory_order_acquire);
    if (!atomic_load_explicit(&g_vm_clock_paused, memory_order_acquire)) {
        return base_offset;
    }
    uint64_t start = atomic_load_explicit(&g_clock_pause_start_ticks, memory_order_acquire);
    if (start == 0ULL) {
        return base_offset;
    }
    uint64_t now = platform_raw_ticks_24mhz();
    return (now > start) ? (base_offset + (now - start)) : base_offset;
}

const uint64_t *hengelinux_negative_counter_offset_ptr(void) {
    _Static_assert(sizeof(g_neg_suspend_offset_ticks) == sizeof(uint64_t),
                   "g_neg_suspend_offset_ticks must be 64-bit");
    return (const uint64_t *)&g_neg_suspend_offset_ticks;
}

static uint64_t clamp_monotonic_ticks(uint64_t candidate) {
    uint64_t prev = atomic_load_explicit(&g_last_compensated_ticks, memory_order_acquire);
    while (true) {
        if (candidate < prev) {
            return prev;
        }
        if (atomic_compare_exchange_weak_explicit(&g_last_compensated_ticks,
                                                    &prev,
                                                    candidate,
                                                    memory_order_acq_rel,
                                                    memory_order_acquire)) {
            return candidate;
        }
    }
}

static void read_clock_snapshot(uint64_t *out_prev_raw, uint64_t *out_base_offset) {
    while (true) {
        uint64_t seq1 = atomic_load_explicit(&g_clock_seq, memory_order_acquire);
        if ((seq1 & 1ULL) != 0ULL) {
            continue;
        }
        uint64_t raw = atomic_load_explicit(&g_last_raw_ticks, memory_order_acquire);
        uint64_t off = atomic_load_explicit(&g_suspend_offset_ticks, memory_order_acquire);
        uint64_t seq2 = atomic_load_explicit(&g_clock_seq, memory_order_acquire);
        if (seq1 == seq2) {
            *out_prev_raw = raw;
            *out_base_offset = off;
            return;
        }
    }
}

uint64_t hengelinux_compensated_counter(uint64_t raw_ticks) {
    if (atomic_load_explicit(&g_vm_clock_paused, memory_order_acquire)) {
        uint64_t prev_raw = 0ULL;
        uint64_t base_offset = 0ULL;
        read_clock_snapshot(&prev_raw, &base_offset);
        (void)prev_raw;
        uint64_t start = atomic_load_explicit(&g_clock_pause_start_ticks, memory_order_acquire);
        if (start > 0ULL) {
            uint64_t candidate = (start > base_offset) ? (start - base_offset) : 0ULL;
            return clamp_monotonic_ticks(candidate);
        }
    }

    uint64_t prev_raw = 0ULL;
    uint64_t base_offset = 0ULL;
    while (true) {
        read_clock_snapshot(&prev_raw, &base_offset);
        if (raw_ticks <= prev_raw) {
            break;
        }
        if ((raw_ticks - prev_raw) > HENGE_SUSPEND_JUMP_THRESHOLD_TICKS) {
            /* Serialize (>500 ms) XNU freezer jump updates via seqlock + mutex so no
             * concurrent vCPU can read updated g_last_raw_ticks with a stale offset. */
            pthread_mutex_lock(&g_clock_mutex);
            uint64_t cur_prev = atomic_load_explicit(&g_last_raw_ticks, memory_order_acquire);
            if (raw_ticks > cur_prev) {
                uint64_t seq = atomic_load_explicit(&g_clock_seq, memory_order_relaxed);
                atomic_store_explicit(&g_clock_seq, seq + 1ULL, memory_order_release);
                if (cur_prev > 0ULL && (raw_ticks - cur_prev) > HENGE_SUSPEND_JUMP_THRESHOLD_TICKS) {
                    uint64_t excess = (raw_ticks - cur_prev) - HENGE_SUSPEND_JUMP_THRESHOLD_TICKS;
                    uint64_t prev_off = atomic_fetch_add_explicit(&g_suspend_offset_ticks, excess, memory_order_acq_rel);
                    atomic_store_explicit(&g_neg_suspend_offset_ticks,
                                          0ULL - (prev_off + excess),
                                          memory_order_release);
                }
                atomic_store_explicit(&g_last_raw_ticks, raw_ticks, memory_order_release);
                atomic_store_explicit(&g_clock_seq, seq + 2ULL, memory_order_release);
            }
            pthread_mutex_unlock(&g_clock_mutex);
            read_clock_snapshot(&prev_raw, &base_offset);
            break;
        }
        if (atomic_compare_exchange_weak_explicit(&g_last_raw_ticks,
                                                    &prev_raw,
                                                    raw_ticks,
                                                    memory_order_acq_rel,
                                                    memory_order_acquire)) {
            break;
        }
    }

    uint64_t candidate = (raw_ticks > base_offset) ? (raw_ticks - base_offset) : 0ULL;
    return clamp_monotonic_ticks(candidate);
}

void hengelinux_reset_suspend_counter(void) {
    pthread_mutex_lock(&g_clock_mutex);
    uint64_t seq = atomic_load_explicit(&g_clock_seq, memory_order_relaxed);
    atomic_store_explicit(&g_clock_seq, seq + 1ULL, memory_order_release);
    atomic_store_explicit(&g_vm_clock_paused, false, memory_order_release);
    atomic_store_explicit(&g_clock_pause_start_ticks, 0ULL, memory_order_release);
    atomic_store_explicit(&g_suspend_offset_ticks, 0ULL, memory_order_release);
    atomic_store_explicit(&g_neg_suspend_offset_ticks, 0ULL, memory_order_release);
    atomic_store_explicit(&g_last_raw_ticks, 0ULL, memory_order_release);
    atomic_store_explicit(&g_last_compensated_ticks, 0ULL, memory_order_release);
    atomic_store_explicit(&g_clock_seq, seq + 2ULL, memory_order_release);
    pthread_mutex_unlock(&g_clock_mutex);

    pthread_mutex_lock(&g_render_mutex);
    atomic_store_explicit(&g_render_paused, false, memory_order_release);
    pthread_mutex_unlock(&g_render_mutex);
}

#define HENGE_CONSOLE_RING_BYTES 65536U

static pthread_mutex_t g_console_mutex = PTHREAD_MUTEX_INITIALIZER;
static char g_console_ring[HENGE_CONSOLE_RING_BYTES];
static size_t g_console_head = 0U;
static size_t g_console_len = 0U;
static atomic_uint_fast64_t g_console_total_bytes = 0ULL;
static FILE *g_console_log_fp = NULL;
static atomic_int g_console_pipe_read_fd = -1;
static int g_console_orig_stderr_fd = -1;
static bool g_console_capture_started = false;
static atomic_bool g_guest_hid_bridge_ready = false;
static atomic_bool g_guest_hid_bridge_v2 = false;
static size_t g_hid_ready_match_pos = 0U;
static size_t g_hid_v2_match_pos = 0U;

static void scan_guest_hid_ready_locked(const char *data, size_t len) {
    static const char kToken[] = "HENGE_HID_READY";
    static const char kTokenV2[] = "HENGE_HID_READY_V2";
    const size_t kTokenLen = sizeof(kToken) - 1U;
    const size_t kTokenV2Len = sizeof(kTokenV2) - 1U;
    bool ready = atomic_load_explicit(&g_guest_hid_bridge_ready, memory_order_relaxed);
    bool v2 = atomic_load_explicit(&g_guest_hid_bridge_v2, memory_order_relaxed);
    if (ready && v2) {
        return;
    }
    for (size_t i = 0U; i < len; ++i) {
        char ch = data[i];
        if (!ready) {
            if (ch == kToken[g_hid_ready_match_pos]) {
                g_hid_ready_match_pos++;
                if (g_hid_ready_match_pos == kTokenLen) {
                    atomic_store_explicit(&g_guest_hid_bridge_ready, true, memory_order_release);
                    g_hid_ready_match_pos = 0U;
                    ready = true;
                }
            } else {
                g_hid_ready_match_pos = (ch == kToken[0]) ? 1U : 0U;
            }
        }
        if (!v2) {
            if (ch == kTokenV2[g_hid_v2_match_pos]) {
                g_hid_v2_match_pos++;
                if (g_hid_v2_match_pos == kTokenV2Len) {
                    atomic_store_explicit(&g_guest_hid_bridge_ready, true, memory_order_release);
                    atomic_store_explicit(&g_guest_hid_bridge_v2, true, memory_order_release);
                    g_hid_v2_match_pos = 0U;
                    ready = true;
                    v2 = true;
                }
            } else {
                g_hid_v2_match_pos = (ch == kTokenV2[0]) ? 1U : 0U;
            }
        }
    }
}

static void console_ring_append_bytes_locked(const char *data, size_t len) {
    if (data == NULL || len == 0U) {
        return;
    }
    scan_guest_hid_ready_locked(data, len);
    const char *src = data;
    size_t remaining = len;
    if (remaining > HENGE_CONSOLE_RING_BYTES) {
        src += (remaining - HENGE_CONSOLE_RING_BYTES);
        remaining = HENGE_CONSOLE_RING_BYTES;
    }

    size_t first = HENGE_CONSOLE_RING_BYTES - g_console_head;
    if (first > remaining) {
        first = remaining;
    }
    memcpy(g_console_ring + g_console_head, src, first);
    if (remaining > first) {
        memcpy(g_console_ring, src + first, remaining - first);
    }

    g_console_head = (g_console_head + remaining) % HENGE_CONSOLE_RING_BYTES;
    if (g_console_len + remaining >= HENGE_CONSOLE_RING_BYTES) {
        g_console_len = HENGE_CONSOLE_RING_BYTES;
    } else {
        g_console_len += remaining;
    }

    if (g_console_log_fp != NULL) {
        size_t written = fwrite(data, 1U, len, g_console_log_fp);
        (void)written;
        fflush(g_console_log_fp);
    }
    atomic_fetch_add_explicit(&g_console_total_bytes, (uint64_t)len, memory_order_release);
}

static void *console_capture_reader_thread(void *opaque) {
    (void)opaque;
    static const char kAgPrefix[] = "=== AttributeGraph:";
    const size_t kAgPrefixLen = sizeof(kAgPrefix) - 1U;
    char buf[2048];
    char filtered[2068];
    char pending[sizeof(kAgPrefix)];
    size_t match_pos = 0U;
    bool dropping_line = false;

    while (true) {
        int fd = atomic_load_explicit(&g_console_pipe_read_fd, memory_order_acquire);
        if (fd < 0) {
            break;
        }
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (n == 0) {
            break;
        }
        if (g_console_orig_stderr_fd >= 0) {
            ssize_t ignored = write(g_console_orig_stderr_fd, buf, (size_t)n);
            (void)ignored;
        }

        /* Strip noisy host SwiftUI/UIKit AttributeGraph stderr cycles so they
         * never flood the guest ttyAMA0 ring buffer or trigger UI feedback loops. */
        size_t out_len = 0U;
        for (ssize_t i = 0; i < n; ++i) {
            char ch = buf[i];
            if (dropping_line) {
                if (ch == '\n') {
                    dropping_line = false;
                }
                continue;
            }
            if (ch == kAgPrefix[match_pos]) {
                pending[match_pos++] = ch;
                if (match_pos == kAgPrefixLen) {
                    match_pos = 0U;
                    dropping_line = true;
                }
                continue;
            }
            if (match_pos > 0U) {
                memcpy(filtered + out_len, pending, match_pos);
                out_len += match_pos;
                match_pos = 0U;
                if (ch == kAgPrefix[0]) {
                    pending[match_pos++] = ch;
                    continue;
                }
            }
            filtered[out_len++] = ch;
        }

        if (out_len > 0U) {
            pthread_mutex_lock(&g_console_mutex);
            console_ring_append_bytes_locked(filtered, out_len);
            pthread_mutex_unlock(&g_console_mutex);
        }
    }
    return NULL;
}

int hengelinux_start_console_capture(const char *log_file_path) {
    pthread_mutex_lock(&g_console_mutex);
    if (log_file_path != NULL && log_file_path[0] != '\0' && g_console_log_fp == NULL) {
        g_console_log_fp = fopen(log_file_path, "ab");
        if (g_console_log_fp != NULL) {
            setvbuf(g_console_log_fp, NULL, _IONBF, 0);
        }
    }
    if (g_console_capture_started) {
        pthread_mutex_unlock(&g_console_mutex);
        return 0;
    }

    int fds[2] = {-1, -1};
    if (pipe(fds) != 0) {
        pthread_mutex_unlock(&g_console_mutex);
        return -1;
    }

    int saved_err = dup(STDERR_FILENO);
    fflush(stdout);
    fflush(stderr);
    if (dup2(fds[1], STDOUT_FILENO) < 0 || dup2(fds[1], STDERR_FILENO) < 0) {
        if (saved_err >= 0) {
            close(saved_err);
        }
        close(fds[0]);
        close(fds[1]);
        pthread_mutex_unlock(&g_console_mutex);
        return -1;
    }
    close(fds[1]);

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    atomic_store_explicit(&g_console_pipe_read_fd, fds[0], memory_order_release);
    g_console_orig_stderr_fd = saved_err;

    pthread_t tid;
    if (pthread_create(&tid, NULL, console_capture_reader_thread, NULL) != 0) {
        atomic_store_explicit(&g_console_pipe_read_fd, -1, memory_order_release);
        if (saved_err >= 0) {
            close(saved_err);
            g_console_orig_stderr_fd = -1;
        }
        close(fds[0]);
        pthread_mutex_unlock(&g_console_mutex);
        return -1;
    }
    pthread_detach(tid);
    g_console_capture_started = true;
    pthread_mutex_unlock(&g_console_mutex);
    return 0;
}

void hengelinux_console_append_line(const char *line) {
    if (line == NULL) {
        return;
    }
    size_t len = strlen(line);
    pthread_mutex_lock(&g_console_mutex);
    if (len > 0U) {
        console_ring_append_bytes_locked(line, len);
    }
    if (len == 0U || line[len - 1U] != '\n') {
        console_ring_append_bytes_locked("\n", 1U);
    }
    pthread_mutex_unlock(&g_console_mutex);
}

uint64_t hengelinux_console_total_bytes(void) {
    return atomic_load_explicit(&g_console_total_bytes, memory_order_acquire);
}

bool hengelinux_is_guest_hid_bridge_ready(void) {
    return atomic_load_explicit(&g_guest_hid_bridge_ready, memory_order_acquire);
}

bool hengelinux_is_guest_hid_bridge_v2(void) {
    return atomic_load_explicit(&g_guest_hid_bridge_v2, memory_order_acquire);
}

void hengelinux_reset_guest_hid_bridge_ready(void) {
    pthread_mutex_lock(&g_console_mutex);
    g_hid_ready_match_pos = 0U;
    g_hid_v2_match_pos = 0U;
    atomic_store_explicit(&g_guest_hid_bridge_ready, false, memory_order_release);
    atomic_store_explicit(&g_guest_hid_bridge_v2, false, memory_order_release);
    pthread_mutex_unlock(&g_console_mutex);
}

size_t hengelinux_copy_console_log(char *out_buf, size_t out_cap) {
    if (out_buf == NULL || out_cap == 0U) {
        return 0U;
    }
    pthread_mutex_lock(&g_console_mutex);
    size_t avail = g_console_len;
    size_t to_copy = (avail < (out_cap - 1U)) ? avail : (out_cap - 1U);
    if (to_copy > 0U) {
        size_t start = (g_console_head + HENGE_CONSOLE_RING_BYTES - to_copy) % HENGE_CONSOLE_RING_BYTES;
        if (start + to_copy <= HENGE_CONSOLE_RING_BYTES) {
            memcpy(out_buf, g_console_ring + start, to_copy);
        } else {
            size_t first = HENGE_CONSOLE_RING_BYTES - start;
            memcpy(out_buf, g_console_ring + start, first);
            memcpy(out_buf + first, g_console_ring, to_copy - first);
        }
    }
    out_buf[to_copy] = '\0';
    pthread_mutex_unlock(&g_console_mutex);
    return to_copy;
}

void hengelinux_clear_console_log(void) {
    pthread_mutex_lock(&g_console_mutex);
    g_console_head = 0U;
    g_console_len = 0U;
    if (g_console_log_fp != NULL) {
        fflush(g_console_log_fp);
        int fd = fileno(g_console_log_fp);
        if (fd >= 0) {
            rewind(g_console_log_fp);
            int rc = ftruncate(fd, 0);
            (void)rc;
        }
    }
    /* Sentinel +1ULL bump wakes SwiftUI log observers polling hengelinux_console_total_bytes(). */
    atomic_fetch_add_explicit(&g_console_total_bytes, 1ULL, memory_order_release);
    pthread_mutex_unlock(&g_console_mutex);
}

#define HENGE_SERIAL_RING_BYTES 131072U

static pthread_mutex_t g_serial_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint8_t g_serial_ring[HENGE_SERIAL_RING_BYTES];
static uint64_t g_serial_total = 0ULL;
static atomic_uint_fast64_t g_serial_atomic_total = 0ULL;

void hengelinux_serial_append_byte(uint8_t byte) {
    pthread_mutex_lock(&g_serial_mutex);
    g_serial_ring[(size_t)(g_serial_total % (uint64_t)HENGE_SERIAL_RING_BYTES)] = byte;
    g_serial_total++;
    atomic_store_explicit(&g_serial_atomic_total, g_serial_total, memory_order_release);
    pthread_mutex_unlock(&g_serial_mutex);
}

void hengelinux_serial_append_bytes(const uint8_t *data, size_t len) {
    if (data == NULL || len == 0U) {
        return;
    }
    pthread_mutex_lock(&g_serial_mutex);
    const uint8_t *src = data;
    size_t remaining = len;
    if (remaining > HENGE_SERIAL_RING_BYTES) {
        src += (remaining - HENGE_SERIAL_RING_BYTES);
        g_serial_total += (uint64_t)(remaining - HENGE_SERIAL_RING_BYTES);
        remaining = HENGE_SERIAL_RING_BYTES;
    }
    size_t head = (size_t)(g_serial_total % (uint64_t)HENGE_SERIAL_RING_BYTES);
    size_t first = HENGE_SERIAL_RING_BYTES - head;
    if (first > remaining) {
        first = remaining;
    }
    memcpy(g_serial_ring + head, src, first);
    if (remaining > first) {
        memcpy(g_serial_ring, src + first, remaining - first);
    }
    g_serial_total += (uint64_t)remaining;
    atomic_store_explicit(&g_serial_atomic_total, g_serial_total, memory_order_release);
    pthread_mutex_unlock(&g_serial_mutex);
}

uint64_t hengelinux_serial_total_bytes(void) {
    return atomic_load_explicit(&g_serial_atomic_total, memory_order_acquire);
}

size_t hengelinux_serial_copy_from(uint64_t *cursor, uint8_t *out_buf, size_t out_cap) {
    if (cursor == NULL || out_buf == NULL || out_cap == 0U) {
        return 0U;
    }
    pthread_mutex_lock(&g_serial_mutex);
    uint64_t total = g_serial_total;
    uint64_t oldest = (total > (uint64_t)HENGE_SERIAL_RING_BYTES)
        ? (total - (uint64_t)HENGE_SERIAL_RING_BYTES)
        : 0ULL;
    uint64_t pos = *cursor;
    if (pos > total || pos < oldest) {
        pos = oldest;
    }
    uint64_t avail = total - pos;
    size_t to_copy = (avail < (uint64_t)out_cap) ? (size_t)avail : out_cap;
    if (to_copy > 0U) {
        size_t start = (size_t)(pos % (uint64_t)HENGE_SERIAL_RING_BYTES);
        size_t first = HENGE_SERIAL_RING_BYTES - start;
        if (first > to_copy) {
            first = to_copy;
        }
        memcpy(out_buf, g_serial_ring + start, first);
        if (to_copy > first) {
            memcpy(out_buf + first, g_serial_ring, to_copy - first);
        }
    }
    *cursor = pos + (uint64_t)to_copy;
    pthread_mutex_unlock(&g_serial_mutex);
    return to_copy;
}

void hengelinux_serial_clear(void) {
    pthread_mutex_lock(&g_serial_mutex);
    g_serial_total = 0ULL;
    atomic_store_explicit(&g_serial_atomic_total, 0ULL, memory_order_release);
    pthread_mutex_unlock(&g_serial_mutex);
}
