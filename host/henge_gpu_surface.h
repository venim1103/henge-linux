/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HENGE_GPU_SURFACE_H
#define HENGE_GPU_SURFACE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Jetsam & GPU VRAM governance defaults (MiB). */
#define HENGE_GPU_VRAM_CAP_STANDARD_MIB   256U
#define HENGE_GPU_VRAM_CAP_ENTITLED_MIB   512U
#define HENGE_GPU_VRAM_CAP_HIGHMEM_MIB    1024U
#define HENGE_GPU_JETSAM_FLOOR_BYTES      (320ULL * 1024ULL * 1024ULL)
#define HENGE_SHADER_CACHE_MAX_BYTES      (64ULL * 1024ULL * 1024ULL)

/* Thermal states matching NSProcessInfoThermalState. */
typedef enum {
    HENGE_THERMAL_NOMINAL  = 0,
    HENGE_THERMAL_FAIR     = 1,
    HENGE_THERMAL_SERIOUS  = 2,
    HENGE_THERMAL_CRITICAL = 3
} HengeThermalState;

/* Double-buffered zero-copy IOSurface swapchain slot state. */
#define HENGE_GPU_SWAPCHAIN_SLOTS 2U

typedef struct {
    void    *iosurface;        /* IOSurfaceRef on iPhoneOS, non-NULL opaque token in tests */
    void    *shared_event;     /* Optional bridged MTLSharedEvent pointer */
    uint64_t signal_value;     /* Monotonic MTLSharedEvent value to wait for */
    uint32_t width;
    uint32_t height;
    uint32_t bytes_per_row;
    bool     is_srgb;
    uint64_t generation;
} HengeGpuSwapchainSlot;

typedef struct HengeGpuSwapchain HengeGpuSwapchain;

/* Allocate, resize, publish, snapshot, and RAII-teardown a 2-slot IOSurface swapchain. */
HengeGpuSwapchain *henge_gpu_swapchain_create(void);
void henge_gpu_swapchain_destroy(HengeGpuSwapchain *sc);
int henge_gpu_swapchain_resize(HengeGpuSwapchain *sc,
                               uint32_t width,
                               uint32_t height,
                               bool is_srgb);
int henge_gpu_swapchain_acquire_back(HengeGpuSwapchain *sc,
                                     uint32_t *out_slot_idx,
                                     HengeGpuSwapchainSlot *out_slot);
int henge_gpu_swapchain_publish(HengeGpuSwapchain *sc,
                                uint32_t slot_idx,
                                void *shared_event,
                                uint64_t signal_value,
                                bool is_srgb);
int henge_gpu_swapchain_get_front(const HengeGpuSwapchain *sc,
                                  HengeGpuSwapchainSlot *out_slot);
uint32_t henge_gpu_swapchain_slot_count(const HengeGpuSwapchain *sc);

/*
 * Host VRAM governance & Jetsam guardrail:
 * Rejects allocations exceeding vram_cap_bytes OR dropping live process headroom
 * below HENGE_GPU_JETSAM_FLOOR_BYTES (320 MiB).
 */
uint32_t henge_gpu_default_vram_cap_mib(uint64_t total_physical_bytes,
                                        uint64_t avail_memory_bytes);
bool henge_gpu_check_vram_budget(uint64_t requested_bytes,
                                 uint64_t current_vram_bytes,
                                 uint64_t vram_cap_bytes,
                                 uint64_t avail_memory_bytes);

/*
 * Bounded 64 MiB LRU shader disk cache (for EGL_ANDROID_blob_cache).
 * Verifies directory writability before activation and evicts oldest entries by mtime.
 */
typedef struct {
    uint64_t total_bytes;
    uint32_t entry_count;
    uint64_t hits;
    uint64_t misses;
    uint64_t evictions;
    bool     ready;
} HengeShaderCacheStats;

int henge_shader_cache_init(const char *cache_dir,
                            const char *namespace_tag,
                            uint64_t max_bytes);
bool henge_shader_cache_is_ready(void);
int henge_shader_cache_put(const void *key,
                           size_t key_len,
                           const void *value,
                           size_t value_len);
size_t henge_shader_cache_get(const void *key,
                              size_t key_len,
                              void *out_value,
                              size_t out_cap);
int henge_shader_cache_clear(void);
void henge_shader_cache_get_stats(HengeShaderCacheStats *out_stats);

/*
 * Lock-free live GPU telemetry & thermal/ProMotion pacing atomics
 * consumed by fb_metal.m and the v0.3.0 SwiftUI Session HUD pill.
 */
typedef struct {
    uint32_t fps_tenths;              /* Rolling FPS * 10 (e.g. 600 = 60.0 FPS) */
    uint32_t active_backend;          /* 0 = 2D GOP, 1 = VirGL 3D, 2 = 2D KMS */
    uint32_t target_refresh_hz;       /* User-selected cap: 30, 60, or 120 */
    uint32_t effective_refresh_hz;    /* Thermal-adjusted presentation cap */
    uint32_t thermal_state;           /* HengeThermalState (0..3) */
    uint64_t metal_allocated_bytes;   /* MTLDevice.currentAllocatedSize */
    uint64_t vram_tracked_bytes;      /* VirtIO-GPU tracked resource bytes */
    uint64_t total_frames_presented;  /* Cumulative frames presented */
    uint64_t virgl_3d_flushes;        /* Cumulative 3D flushes for crash sentinel */
} HengeGpuTelemetrySnapshot;

void henge_gpu_telemetry_reset(void);
void henge_gpu_telemetry_record_frame(uint64_t now_ns);
void henge_gpu_telemetry_set_metal_allocated_bytes(uint64_t bytes);
void henge_gpu_telemetry_set_vram_tracked_bytes(uint64_t bytes);
void henge_gpu_telemetry_set_active_backend(uint32_t backend_id);
void henge_gpu_telemetry_set_target_refresh_hz(uint32_t hz);
void henge_gpu_telemetry_set_thermal_state(uint32_t state);
void henge_gpu_telemetry_inc_3d_flushes(void);
uint32_t henge_gpu_telemetry_effective_refresh_hz(void);
uint64_t henge_gpu_telemetry_min_frame_interval_ns(void);
void henge_gpu_telemetry_get_snapshot(HengeGpuTelemetrySnapshot *out_snap);

#ifdef __cplusplus
}
#endif

#endif /* HENGE_GPU_SURFACE_H */
