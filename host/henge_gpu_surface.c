/* SPDX-License-Identifier: GPL-3.0-or-later */
#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "henge_gpu_surface.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#endif
#endif

/* ===================== Double-Buffered IOSurface Swapchain ===================== */

struct HengeGpuSwapchain {
    pthread_mutex_t       mu;
    HengeGpuSwapchainSlot slots[HENGE_GPU_SWAPCHAIN_SLOTS];
    uint32_t              front_idx;
    bool                  has_front;
    uint32_t              width;
    uint32_t              height;
    uint64_t              next_gen;
};

static uint32_t align_stride_16(uint32_t width) {
    uint32_t raw = width * 4U;
    return (raw + 15U) & ~15U;
}

static void release_surface_handle(void **surface_ptr) {
    if (surface_ptr == NULL || *surface_ptr == NULL) {
        return;
    }
#if defined(__APPLE__) && TARGET_OS_IPHONE
    CFRelease((CFTypeRef)(*surface_ptr));
#else
    free(*surface_ptr);
#endif
    *surface_ptr = NULL;
}

static void *allocate_surface_handle(uint32_t width, uint32_t height, uint32_t *out_stride) {
    uint32_t stride = align_stride_16(width);
    if (out_stride != NULL) {
        *out_stride = stride;
    }
#if defined(__APPLE__) && TARGET_OS_IPHONE
    int32_t w32 = (int32_t)width;
    int32_t h32 = (int32_t)height;
    int32_t bpe = 4;
    int32_t bpr = (int32_t)stride;
    int32_t pixfmt = (int32_t)'BGRA';

    CFNumberRef cfW = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &w32);
    CFNumberRef cfH = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &h32);
    CFNumberRef cfBpe = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bpe);
    CFNumberRef cfBpr = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bpr);
    CFNumberRef cfFmt = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixfmt);

    const void *keys[5] = {
        kIOSurfaceWidth,
        kIOSurfaceHeight,
        kIOSurfaceBytesPerElement,
        kIOSurfaceBytesPerRow,
        kIOSurfacePixelFormat
    };
    const void *vals[5] = { cfW, cfH, cfBpe, cfBpr, cfFmt };

    IOSurfaceRef surf = NULL;
    if (cfW && cfH && cfBpe && cfBpr && cfFmt) {
        CFDictionaryRef props = CFDictionaryCreate(
            kCFAllocatorDefault, keys, vals, 5,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        if (props != NULL) {
            surf = IOSurfaceCreate(props);
            CFRelease(props);
        }
    }
    if (cfW) CFRelease(cfW);
    if (cfH) CFRelease(cfH);
    if (cfBpe) CFRelease(cfBpe);
    if (cfBpr) CFRelease(cfBpr);
    if (cfFmt) CFRelease(cfFmt);
    return (void *)surf;
#else
    /* Lightweight sentinel token for host/Linux/macOS unit tests (avoids multi-MB allocations). */
    uint32_t *token = calloc(2U, sizeof(uint32_t));
    if (token != NULL) {
        token[0] = width;
        token[1] = height;
    }
    return (void *)token;
#endif
}

static void release_shared_event_handle(void **ev_ptr) {
    if (ev_ptr == NULL || *ev_ptr == NULL) {
        return;
    }
#if defined(__APPLE__) && TARGET_OS_IPHONE
    CFRelease((CFTypeRef)(*ev_ptr));
#endif
    *ev_ptr = NULL;
}

static void teardown_slots_locked(HengeGpuSwapchain *sc) {
    for (uint32_t i = 0U; i < HENGE_GPU_SWAPCHAIN_SLOTS; i++) {
        release_shared_event_handle(&sc->slots[i].shared_event);
        release_surface_handle(&sc->slots[i].iosurface);
        memset(&sc->slots[i], 0, sizeof(sc->slots[i]));
    }
    sc->width = 0U;
    sc->height = 0U;
    sc->front_idx = 0U;
    sc->has_front = false;
}

HengeGpuSwapchain *henge_gpu_swapchain_create(void) {
    HengeGpuSwapchain *sc = calloc(1U, sizeof(*sc));
    if (sc == NULL) {
        return NULL;
    }
    pthread_mutex_init(&sc->mu, NULL);
    sc->next_gen = 1ULL;
    return sc;
}

void henge_gpu_swapchain_destroy(HengeGpuSwapchain *sc) {
    if (sc == NULL) {
        return;
    }
    pthread_mutex_lock(&sc->mu);
    teardown_slots_locked(sc);
    pthread_mutex_unlock(&sc->mu);
    pthread_mutex_destroy(&sc->mu);
    free(sc);
}

int henge_gpu_swapchain_resize(HengeGpuSwapchain *sc,
                               uint32_t width,
                               uint32_t height,
                               bool is_srgb) {
    if (sc == NULL || width == 0U || height == 0U || width > 7680U || height > 4320U) {
        return -1;
    }
    pthread_mutex_lock(&sc->mu);
    if (sc->width == width && sc->height == height &&
        sc->slots[0].iosurface != NULL && sc->slots[1].iosurface != NULL) {
        for (uint32_t i = 0U; i < HENGE_GPU_SWAPCHAIN_SLOTS; i++) {
            sc->slots[i].is_srgb = is_srgb;
        }
        pthread_mutex_unlock(&sc->mu);
        return 0;
    }

    /* Strict RAII teardown of prior IOSurface pair before allocating replacements. */
    teardown_slots_locked(sc);

    uint64_t gen = sc->next_gen++;
    for (uint32_t i = 0U; i < HENGE_GPU_SWAPCHAIN_SLOTS; i++) {
        uint32_t stride = 0U;
        void *handle = allocate_surface_handle(width, height, &stride);
        if (handle == NULL) {
            teardown_slots_locked(sc);
            pthread_mutex_unlock(&sc->mu);
            return -1;
        }
        sc->slots[i].iosurface = handle;
        sc->slots[i].width = width;
        sc->slots[i].height = height;
        sc->slots[i].bytes_per_row = stride;
        sc->slots[i].is_srgb = is_srgb;
        sc->slots[i].generation = gen;
    }
    sc->width = width;
    sc->height = height;
    sc->front_idx = 0U;
    sc->has_front = false;
    pthread_mutex_unlock(&sc->mu);
    return 0;
}

int henge_gpu_swapchain_acquire_back(HengeGpuSwapchain *sc,
                                     uint32_t *out_slot_idx,
                                     HengeGpuSwapchainSlot *out_slot) {
    if (sc == NULL || out_slot_idx == NULL || out_slot == NULL) {
        return -1;
    }
    pthread_mutex_lock(&sc->mu);
    if (sc->width == 0U || sc->height == 0U) {
        pthread_mutex_unlock(&sc->mu);
        return -1;
    }
    uint32_t back = sc->has_front ? ((sc->front_idx + 1U) % HENGE_GPU_SWAPCHAIN_SLOTS) : 0U;
    if (sc->slots[back].iosurface == NULL) {
        pthread_mutex_unlock(&sc->mu);
        return -1;
    }
    *out_slot_idx = back;
    *out_slot = sc->slots[back];
    pthread_mutex_unlock(&sc->mu);
    return 0;
}

int henge_gpu_swapchain_publish(HengeGpuSwapchain *sc,
                                uint32_t slot_idx,
                                void *shared_event,
                                uint64_t signal_value,
                                bool is_srgb) {
    if (sc == NULL || slot_idx >= HENGE_GPU_SWAPCHAIN_SLOTS) {
        return -1;
    }
    pthread_mutex_lock(&sc->mu);
    if (sc->slots[slot_idx].iosurface == NULL) {
        pthread_mutex_unlock(&sc->mu);
        return -1;
    }
    if (sc->slots[slot_idx].shared_event != shared_event) {
        release_shared_event_handle(&sc->slots[slot_idx].shared_event);
    }
    sc->slots[slot_idx].shared_event = shared_event;
    sc->slots[slot_idx].signal_value = signal_value;
    sc->slots[slot_idx].is_srgb = is_srgb;
    sc->slots[slot_idx].generation = sc->next_gen++;
    sc->front_idx = slot_idx;
    sc->has_front = true;
    pthread_mutex_unlock(&sc->mu);
    return 0;
}

int henge_gpu_swapchain_get_front(const HengeGpuSwapchain *sc,
                                  HengeGpuSwapchainSlot *out_slot) {
    if (sc == NULL || out_slot == NULL) {
        return -1;
    }
    memset(out_slot, 0, sizeof(*out_slot));
    HengeGpuSwapchain *mut = (HengeGpuSwapchain *)sc;
    pthread_mutex_lock(&mut->mu);
    if (!sc->has_front || sc->slots[sc->front_idx].iosurface == NULL) {
        pthread_mutex_unlock(&mut->mu);
        return -1;
    }
    *out_slot = sc->slots[sc->front_idx];
    pthread_mutex_unlock(&mut->mu);
    return 0;
}

uint32_t henge_gpu_swapchain_slot_count(const HengeGpuSwapchain *sc) {
    if (sc == NULL) {
        return 0U;
    }
    HengeGpuSwapchain *mut = (HengeGpuSwapchain *)sc;
    pthread_mutex_lock(&mut->mu);
    uint32_t count = 0U;
    for (uint32_t i = 0U; i < HENGE_GPU_SWAPCHAIN_SLOTS; i++) {
        if (sc->slots[i].iosurface != NULL) {
            count++;
        }
    }
    pthread_mutex_unlock(&mut->mu);
    return count;
}

/* ===================== Jetsam VRAM Governance ===================== */

uint32_t henge_gpu_default_vram_cap_mib(uint64_t total_physical_bytes,
                                        uint64_t avail_memory_bytes) {
    /* 12-16 GB devices with high headroom -> 1024 MiB VRAM cap */
    if (total_physical_bytes >= (11ULL << 30) &&
        (avail_memory_bytes == 0ULL || avail_memory_bytes >= (4800ULL << 20))) {
        return HENGE_GPU_VRAM_CAP_HIGHMEM_MIB;
    }
    /* Entitled 8 GB device (increased-memory-limit active, >4.0 GiB headroom) -> 512 MiB */
    if (avail_memory_bytes >= (4096ULL << 20)) {
        return HENGE_GPU_VRAM_CAP_ENTITLED_MIB;
    }
    /* Standard free SideStore ledger (~3.35 GiB ceiling on 8 GB phone) -> 256 MiB */
    return HENGE_GPU_VRAM_CAP_STANDARD_MIB;
}

bool henge_gpu_check_vram_budget(uint64_t requested_bytes,
                                 uint64_t current_vram_bytes,
                                 uint64_t vram_cap_bytes,
                                 uint64_t avail_memory_bytes) {
    if (requested_bytes == 0ULL) {
        return true;
    }
    if (current_vram_bytes > UINT64_MAX - requested_bytes) {
        return false;
    }
    if (vram_cap_bytes > 0ULL && (current_vram_bytes + requested_bytes) > vram_cap_bytes) {
        return false;
    }
    /* If live os_proc_available_memory() is known (>0), enforce 320 MiB emergency floor. */
    if (avail_memory_bytes > 0ULL) {
        if (avail_memory_bytes <= HENGE_GPU_JETSAM_FLOOR_BYTES) {
            return false;
        }
        if (requested_bytes > (avail_memory_bytes - HENGE_GPU_JETSAM_FLOOR_BYTES)) {
            return false;
        }
    }
    return true;
}

/* ===================== Bounded 64 MiB LRU Shader Disk Cache ===================== */

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

static pthread_mutex_t g_shader_cache_mu = PTHREAD_MUTEX_INITIALIZER;
static char g_shader_cache_dir[PATH_MAX] = {0};
static char g_shader_cache_ns[96] = {0};
static uint64_t g_shader_cache_max_bytes = HENGE_SHADER_CACHE_MAX_BYTES;
static bool g_shader_cache_ready = false;
static uint64_t g_shader_cache_hits = 0ULL;
static uint64_t g_shader_cache_misses = 0ULL;
static uint64_t g_shader_cache_evictions = 0ULL;

static uint64_t fnv1a64_seeded(uint64_t seed, const void *data, size_t len) {
    uint64_t h = seed;
    const uint8_t *p = (const uint8_t *)data;
    for (size_t i = 0U; i < len; i++) {
        h ^= (uint64_t)p[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static int ensure_dir_recursive(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return -1;
    }
    char tmp[PATH_MAX];
    int n = snprintf(tmp, sizeof(tmp), "%s", path);
    if (n <= 0 || (size_t)n >= sizeof(tmp)) {
        return -1;
    }
    for (char *p = tmp + 1; *p != '\0'; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0700) != 0 && errno != EEXIST) {
                return -1;
            }
            *p = '/';
        }
    }
    if (mkdir(tmp, 0700) != 0 && errno != EEXIST) {
        return -1;
    }
    return 0;
}

static int format_cache_entry_path_locked(const void *key,
                                          size_t key_len,
                                          char *out_path,
                                          size_t out_cap) {
    uint64_t h1 = fnv1a64_seeded(14695981039346656037ULL, g_shader_cache_ns, strlen(g_shader_cache_ns));
    h1 = fnv1a64_seeded(h1, key, key_len);
    uint64_t h2 = fnv1a64_seeded(0x9E3779B97F4A7C15ULL, key, key_len);
    h2 = fnv1a64_seeded(h2, g_shader_cache_ns, strlen(g_shader_cache_ns));
    int n = snprintf(out_path, out_cap, "%s/%016llx%016llx.bin",
                     g_shader_cache_dir,
                     (unsigned long long)h1,
                     (unsigned long long)h2);
    return (n > 0 && (size_t)n < out_cap) ? 0 : -1;
}

typedef struct {
    char     name[64];
    uint64_t size;
    time_t   mtime;
} ShaderCacheFileEnt;

static int cmp_shader_ent_oldest(const void *a, const void *b) {
    const ShaderCacheFileEnt *ea = (const ShaderCacheFileEnt *)a;
    const ShaderCacheFileEnt *eb = (const ShaderCacheFileEnt *)b;
    if (ea->mtime < eb->mtime) return -1;
    if (ea->mtime > eb->mtime) return 1;
    return strcmp(ea->name, eb->name);
}

static void enforce_shader_cache_budget_locked(void) {
    DIR *dir = opendir(g_shader_cache_dir);
    if (dir == NULL) {
        return;
    }
    size_t cap = 64U;
    size_t count = 0U;
    uint64_t total = 0ULL;
    ShaderCacheFileEnt *list = calloc(cap, sizeof(*list));
    if (list == NULL) {
        closedir(dir);
        return;
    }

    struct dirent *ent = NULL;
    while ((ent = readdir(dir)) != NULL) {
        if (ent->d_name[0] == '.') {
            continue;
        }
        size_t nlen = strlen(ent->d_name);
        if (nlen < 5U || strcmp(ent->d_name + nlen - 4U, ".bin") != 0) {
            continue;
        }
        char full[PATH_MAX];
        int fn = snprintf(full, sizeof(full), "%s/%s", g_shader_cache_dir, ent->d_name);
        if (fn <= 0 || (size_t)fn >= sizeof(full)) {
            continue;
        }
        struct stat st;
        if (stat(full, &st) != 0 || !S_ISREG(st.st_mode)) {
            continue;
        }
        if (count == cap) {
            size_t next_cap = cap * 2U;
            ShaderCacheFileEnt *grown = realloc(list, next_cap * sizeof(*list));
            if (grown == NULL) {
                break;
            }
            list = grown;
            cap = next_cap;
        }
        snprintf(list[count].name, sizeof(list[count].name), "%s", ent->d_name);
        list[count].size = (st.st_size > 0) ? (uint64_t)st.st_size : 0ULL;
        list[count].mtime = st.st_mtime;
        total += list[count].size;
        count++;
    }
    closedir(dir);

    if (total > g_shader_cache_max_bytes && count > 0U) {
        qsort(list, count, sizeof(*list), cmp_shader_ent_oldest);
        for (size_t i = 0U; i < count && total > g_shader_cache_max_bytes; i++) {
            char full[PATH_MAX];
            int fn = snprintf(full, sizeof(full), "%s/%s", g_shader_cache_dir, list[i].name);
            if (fn > 0 && (size_t)fn < sizeof(full) && unlink(full) == 0) {
                total = (total >= list[i].size) ? (total - list[i].size) : 0ULL;
                g_shader_cache_evictions++;
            }
        }
    }
    free(list);
}

int henge_shader_cache_init(const char *cache_dir,
                            const char *namespace_tag,
                            uint64_t max_bytes) {
    if (cache_dir == NULL || cache_dir[0] == '\0') {
        return -1;
    }
    pthread_mutex_lock(&g_shader_cache_mu);
    if (ensure_dir_recursive(cache_dir) != 0) {
        g_shader_cache_ready = false;
        pthread_mutex_unlock(&g_shader_cache_mu);
        return -1;
    }

    /* Verify directory writability prior to ANGLE init (Pitfall #6 mitigation). */
    char probe_path[PATH_MAX];
    int pn = snprintf(probe_path, sizeof(probe_path), "%s/.write_probe", cache_dir);
    if (pn <= 0 || (size_t)pn >= sizeof(probe_path)) {
        g_shader_cache_ready = false;
        pthread_mutex_unlock(&g_shader_cache_mu);
        return -1;
    }
    int pfd = open(probe_path, O_CREAT | O_WRONLY | O_TRUNC, 0600);
    if (pfd < 0) {
        g_shader_cache_ready = false;
        pthread_mutex_unlock(&g_shader_cache_mu);
        return -1;
    }
    close(pfd);
    unlink(probe_path);

    snprintf(g_shader_cache_dir, sizeof(g_shader_cache_dir), "%s", cache_dir);
    snprintf(g_shader_cache_ns, sizeof(g_shader_cache_ns), "%s",
             (namespace_tag != NULL && namespace_tag[0] != '\0') ? namespace_tag : "henge-v0.3.0");
    g_shader_cache_max_bytes = (max_bytes > 0ULL) ? max_bytes : HENGE_SHADER_CACHE_MAX_BYTES;
    g_shader_cache_ready = true;
    enforce_shader_cache_budget_locked();
    pthread_mutex_unlock(&g_shader_cache_mu);
    return 0;
}

bool henge_shader_cache_is_ready(void) {
    pthread_mutex_lock(&g_shader_cache_mu);
    bool ready = g_shader_cache_ready;
    pthread_mutex_unlock(&g_shader_cache_mu);
    return ready;
}

int henge_shader_cache_put(const void *key,
                           size_t key_len,
                           const void *value,
                           size_t value_len) {
    if (key == NULL || key_len == 0U || value == NULL || value_len == 0U) {
        return -1;
    }
    pthread_mutex_lock(&g_shader_cache_mu);
    if (!g_shader_cache_ready || (uint64_t)value_len > g_shader_cache_max_bytes) {
        pthread_mutex_unlock(&g_shader_cache_mu);
        return -1;
    }
    char path[PATH_MAX];
    char tmp_path[PATH_MAX];
    if (format_cache_entry_path_locked(key, key_len, path, sizeof(path)) != 0) {
        pthread_mutex_unlock(&g_shader_cache_mu);
        return -1;
    }
    int tn = snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", path);
    if (tn <= 0 || (size_t)tn >= sizeof(tmp_path)) {
        pthread_mutex_unlock(&g_shader_cache_mu);
        return -1;
    }

    int fd = open(tmp_path, O_CREAT | O_WRONLY | O_TRUNC, 0600);
    if (fd < 0) {
        pthread_mutex_unlock(&g_shader_cache_mu);
        return -1;
    }
    const uint8_t *p = (const uint8_t *)value;
    size_t written = 0U;
    while (written < value_len) {
        ssize_t w = write(fd, p + written, value_len - written);
        if (w <= 0) {
            close(fd);
            unlink(tmp_path);
            pthread_mutex_unlock(&g_shader_cache_mu);
            return -1;
        }
        written += (size_t)w;
    }
    close(fd);
    if (rename(tmp_path, path) != 0) {
        unlink(tmp_path);
        pthread_mutex_unlock(&g_shader_cache_mu);
        return -1;
    }
    enforce_shader_cache_budget_locked();
    pthread_mutex_unlock(&g_shader_cache_mu);
    return 0;
}

size_t henge_shader_cache_get(const void *key,
                              size_t key_len,
                              void *out_value,
                              size_t out_cap) {
    if (key == NULL || key_len == 0U) {
        return 0U;
    }
    pthread_mutex_lock(&g_shader_cache_mu);
    if (!g_shader_cache_ready) {
        pthread_mutex_unlock(&g_shader_cache_mu);
        return 0U;
    }
    char path[PATH_MAX];
    if (format_cache_entry_path_locked(key, key_len, path, sizeof(path)) != 0) {
        g_shader_cache_misses++;
        pthread_mutex_unlock(&g_shader_cache_mu);
        return 0U;
    }
    struct stat st;
    if (stat(path, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0) {
        g_shader_cache_misses++;
        pthread_mutex_unlock(&g_shader_cache_mu);
        return 0U;
    }
    size_t sz = (size_t)st.st_size;
    if (out_value == NULL || out_cap < sz) {
        /* EGL_ANDROID_blob_cache convention: return full blob size when querying size. */
        pthread_mutex_unlock(&g_shader_cache_mu);
        return sz;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        g_shader_cache_misses++;
        pthread_mutex_unlock(&g_shader_cache_mu);
        return 0U;
    }
    uint8_t *dst = (uint8_t *)out_value;
    size_t got = 0U;
    while (got < sz) {
        ssize_t r = read(fd, dst + got, sz - got);
        if (r <= 0) {
            close(fd);
            g_shader_cache_misses++;
            pthread_mutex_unlock(&g_shader_cache_mu);
            return 0U;
        }
        got += (size_t)r;
    }
    close(fd);
    g_shader_cache_hits++;
    pthread_mutex_unlock(&g_shader_cache_mu);
    return got;
}

int henge_shader_cache_clear(void) {
    pthread_mutex_lock(&g_shader_cache_mu);
    if (!g_shader_cache_ready || g_shader_cache_dir[0] == '\0') {
        pthread_mutex_unlock(&g_shader_cache_mu);
        return 0;
    }
    DIR *dir = opendir(g_shader_cache_dir);
    if (dir != NULL) {
        struct dirent *ent = NULL;
        while ((ent = readdir(dir)) != NULL) {
            if (ent->d_name[0] == '.') {
                continue;
            }
            char full[PATH_MAX];
            int fn = snprintf(full, sizeof(full), "%s/%s", g_shader_cache_dir, ent->d_name);
            if (fn > 0 && (size_t)fn < sizeof(full)) {
                unlink(full);
            }
        }
        closedir(dir);
    }
    pthread_mutex_unlock(&g_shader_cache_mu);
    return 0;
}

void henge_shader_cache_get_stats(HengeShaderCacheStats *out_stats) {
    if (out_stats == NULL) {
        return;
    }
    memset(out_stats, 0, sizeof(*out_stats));
    pthread_mutex_lock(&g_shader_cache_mu);
    out_stats->ready = g_shader_cache_ready;
    out_stats->hits = g_shader_cache_hits;
    out_stats->misses = g_shader_cache_misses;
    out_stats->evictions = g_shader_cache_evictions;
    if (g_shader_cache_ready && g_shader_cache_dir[0] != '\0') {
        DIR *dir = opendir(g_shader_cache_dir);
        if (dir != NULL) {
            struct dirent *ent = NULL;
            while ((ent = readdir(dir)) != NULL) {
                size_t nlen = strlen(ent->d_name);
                if (nlen < 5U || strcmp(ent->d_name + nlen - 4U, ".bin") != 0) {
                    continue;
                }
                char full[PATH_MAX];
                int fn = snprintf(full, sizeof(full), "%s/%s", g_shader_cache_dir, ent->d_name);
                if (fn > 0 && (size_t)fn < sizeof(full)) {
                    struct stat st;
                    if (stat(full, &st) == 0 && S_ISREG(st.st_mode)) {
                        out_stats->entry_count++;
                        out_stats->total_bytes += (st.st_size > 0) ? (uint64_t)st.st_size : 0ULL;
                    }
                }
            }
            closedir(dir);
        }
    }
    pthread_mutex_unlock(&g_shader_cache_mu);
}

/* ===================== Lock-Free GPU Telemetry & Thermal Pacing ===================== */

static atomic_uint_fast32_t g_tel_fps_tenths = 0U;
static atomic_uint_fast32_t g_tel_backend = 0U;
static atomic_uint_fast32_t g_tel_target_hz = 60U;
static atomic_uint_fast32_t g_tel_thermal = HENGE_THERMAL_NOMINAL;
static atomic_uint_fast64_t g_tel_metal_bytes = 0ULL;
static atomic_uint_fast64_t g_tel_vram_bytes = 0ULL;
static atomic_uint_fast64_t g_tel_total_frames = 0ULL;
static atomic_uint_fast64_t g_tel_3d_flushes = 0ULL;
static atomic_uint_fast64_t g_tel_window_start_ns = 0ULL;
static atomic_uint_fast32_t g_tel_window_frames = 0U;

void henge_gpu_telemetry_reset(void) {
    atomic_store_explicit(&g_tel_fps_tenths, 0U, memory_order_release);
    atomic_store_explicit(&g_tel_metal_bytes, 0ULL, memory_order_release);
    atomic_store_explicit(&g_tel_vram_bytes, 0ULL, memory_order_release);
    atomic_store_explicit(&g_tel_total_frames, 0ULL, memory_order_release);
    atomic_store_explicit(&g_tel_3d_flushes, 0ULL, memory_order_release);
    atomic_store_explicit(&g_tel_window_start_ns, 0ULL, memory_order_release);
    atomic_store_explicit(&g_tel_window_frames, 0U, memory_order_release);
}

void henge_gpu_telemetry_record_frame(uint64_t now_ns) {
    atomic_fetch_add_explicit(&g_tel_total_frames, 1ULL, memory_order_relaxed);
    uint64_t start = atomic_load_explicit(&g_tel_window_start_ns, memory_order_acquire);
    if (start == 0ULL || now_ns < start) {
        atomic_store_explicit(&g_tel_window_start_ns, now_ns, memory_order_release);
        atomic_store_explicit(&g_tel_window_frames, 1U, memory_order_release);
        return;
    }
    uint32_t count = atomic_fetch_add_explicit(&g_tel_window_frames, 1U, memory_order_acq_rel) + 1U;
    uint64_t elapsed = now_ns - start;
    if (elapsed >= 500000000ULL) { /* 500 ms rolling window */
        if (atomic_compare_exchange_strong_explicit(
                &g_tel_window_start_ns, &start, now_ns,
                memory_order_acq_rel, memory_order_relaxed)) {
            atomic_store_explicit(&g_tel_window_frames, 0U, memory_order_release);
            uint64_t fps10 = ((uint64_t)count * 10000000000ULL) / elapsed;
            if (fps10 > 2400ULL) {
                fps10 = 2400ULL;
            }
            atomic_store_explicit(&g_tel_fps_tenths, (uint32_t)fps10, memory_order_release);
        }
    }
}

void henge_gpu_telemetry_set_metal_allocated_bytes(uint64_t bytes) {
    atomic_store_explicit(&g_tel_metal_bytes, bytes, memory_order_release);
}

void henge_gpu_telemetry_set_vram_tracked_bytes(uint64_t bytes) {
    atomic_store_explicit(&g_tel_vram_bytes, bytes, memory_order_release);
}

void henge_gpu_telemetry_set_active_backend(uint32_t backend_id) {
    atomic_store_explicit(&g_tel_backend, backend_id, memory_order_release);
}

void henge_gpu_telemetry_set_target_refresh_hz(uint32_t hz) {
    uint32_t clamped = 60U;
    if (hz <= 30U) {
        clamped = 30U;
    } else if (hz >= 120U) {
        clamped = 120U;
    }
    atomic_store_explicit(&g_tel_target_hz, clamped, memory_order_release);
}

void henge_gpu_telemetry_set_thermal_state(uint32_t state) {
    if (state > (uint32_t)HENGE_THERMAL_CRITICAL) {
        state = (uint32_t)HENGE_THERMAL_CRITICAL;
    }
    atomic_store_explicit(&g_tel_thermal, state, memory_order_release);
}

void henge_gpu_telemetry_inc_3d_flushes(void) {
    atomic_fetch_add_explicit(&g_tel_3d_flushes, 1ULL, memory_order_relaxed);
}

uint32_t henge_gpu_telemetry_effective_refresh_hz(void) {
    uint32_t target = atomic_load_explicit(&g_tel_target_hz, memory_order_acquire);
    uint32_t thermal = atomic_load_explicit(&g_tel_thermal, memory_order_acquire);
    if (thermal >= (uint32_t)HENGE_THERMAL_CRITICAL) {
        return 30U;
    }
    if (thermal == (uint32_t)HENGE_THERMAL_SERIOUS) {
        return (target < 40U) ? target : 40U;
    }
    return (target > 0U) ? target : 60U;
}

uint64_t henge_gpu_telemetry_min_frame_interval_ns(void) {
    uint32_t hz = henge_gpu_telemetry_effective_refresh_hz();
    return (hz > 0U) ? (1000000000ULL / (uint64_t)hz) : 16666666ULL;
}

void henge_gpu_telemetry_get_snapshot(HengeGpuTelemetrySnapshot *out_snap) {
    if (out_snap == NULL) {
        return;
    }
    out_snap->fps_tenths = atomic_load_explicit(&g_tel_fps_tenths, memory_order_acquire);
    out_snap->active_backend = atomic_load_explicit(&g_tel_backend, memory_order_acquire);
    out_snap->target_refresh_hz = atomic_load_explicit(&g_tel_target_hz, memory_order_acquire);
    out_snap->effective_refresh_hz = henge_gpu_telemetry_effective_refresh_hz();
    out_snap->thermal_state = atomic_load_explicit(&g_tel_thermal, memory_order_acquire);
    out_snap->metal_allocated_bytes = atomic_load_explicit(&g_tel_metal_bytes, memory_order_acquire);
    out_snap->vram_tracked_bytes = atomic_load_explicit(&g_tel_vram_bytes, memory_order_acquire);
    out_snap->total_frames_presented = atomic_load_explicit(&g_tel_total_frames, memory_order_acquire);
    out_snap->virgl_3d_flushes = atomic_load_explicit(&g_tel_3d_flushes, memory_order_acquire);
}
