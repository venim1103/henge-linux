/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HENGE_VIRGL_WORKER_H
#define HENGE_VIRGL_WORKER_H

#include "henge_virtio_gpu.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* VirtIO-GPU header fence flag (VIRTIO_GPU_FLAG_FENCE). */
#define HENGE_VIRTIO_GPU_FLAG_FENCE (1U << 0)

/*
 * Completion callback invoked on virgl_thread (NEVER while holding worker->mu)
 * once a command finishes or its GPU fence retires.
 */
typedef void (*HengeVirglCompleteFn)(void *opaque,
                                     void *cmd_tag,
                                     uint64_t generation,
                                     const uint8_t *resp_bytes,
                                     size_t resp_len);

/*
 * Display/cursor notification callback invoked on virgl_thread after
 * SET_SCANOUT, RESOURCE_FLUSH, or cursorq updates complete.
 */
typedef void (*HengeVirglDisplayEventFn)(void *opaque,
                                         uint32_t scanout_id,
                                         bool is_cursor,
                                         bool force_full);

typedef struct {
    HengeVirtioGpuDevice    *gpu;
    bool                     enable_virgl;
    uint32_t                 vram_mib;
    void                    *callback_opaque;
    HengeVirglCompleteFn     on_complete;
    HengeVirglDisplayEventFn on_display_event;
} HengeVirglWorkerConfig;

typedef struct {
    uint32_t                    queue_index;  /* 0 = ctrlq, 1 = cursorq */
    uint32_t                    cmd_type;
    uint32_t                    flags;
    uint64_t                    fence_id;
    uint32_t                    ctx_id;
    uint8_t                     ring_idx;
    uint64_t                    generation;
    void                       *cmd_tag;      /* Opaque caller handle (e.g. HvVirtqElem*) */
    const uint8_t              *payload;      /* Request bytes AFTER 24-byte virtio_gpu_ctrl_hdr */
    size_t                      payload_len;
    const HengeGpuBackingEntry *backing;      /* Optional resolved scatter-gather entries */
    uint32_t                    backing_count;
} HengeVirglCommand;

typedef struct {
    uint64_t cmds_enqueued;
    uint64_t cmds_completed;
    uint64_t fences_retired;
    uint64_t resets_processed;
    uint32_t pending_queue_depth;
    uint32_t pending_fence_count;
    bool     virgl_initialized;
} HengeVirglWorkerStats;

typedef struct HengeVirglWorker HengeVirglWorker;

/*
 * Spawn the dedicated virgl_thread decoupled from guest vCPU MMIO traps.
 * Initializes virglrenderer (when compiled in and cfg->enable_virgl is true)
 * strictly on virgl_thread before returning.
 */
HengeVirglWorker *henge_virgl_worker_create(const HengeVirglWorkerConfig *cfg);

/* Stop virgl_thread, release pending commands, tear down virglrenderer, and free worker. */
void henge_virgl_worker_destroy(HengeVirglWorker *worker);

/* Returns true if libvirglrenderer initialized successfully on virgl_thread. */
bool henge_virgl_worker_is_virgl_active(const HengeVirglWorker *worker);

/* Returns advertised capset count (2 when VirGL is active, 0 otherwise). */
uint32_t henge_virgl_worker_num_capsets(const HengeVirglWorker *worker);

/*
 * Non-blocking enqueue from guest vCPU trap (vgpu_notify). Copies payload and
 * backing arrays so the vCPU can return immediately without stalling on GPU/shader work.
 * Returns 0 on success, -1 on error (caller retains ownership of cmd->cmd_tag on error).
 */
int henge_virgl_worker_enqueue(HengeVirglWorker *worker, const HengeVirglCommand *cmd);

/*
 * Non-blocking reset barrier enqueued from vgpu_reset() under hv_dev_lock().
 * Drops stale pending fences older than new_generation and resets virglrenderer state.
 */
int henge_virgl_worker_enqueue_reset(HengeVirglWorker *worker, uint64_t new_generation);

/*
 * Synchronously drain all queued commands and in-flight GPU work (up to timeout_ms).
 * Must NOT be called while holding hv_dev_lock() or hengelinux_render_lock().
 */
int henge_virgl_worker_drain(HengeVirglWorker *worker, uint32_t timeout_ms);

/* Query lock-protected worker telemetry counters. */
void henge_virgl_worker_get_stats(const HengeVirglWorker *worker,
                                  HengeVirglWorkerStats *out_stats);

/*
 * Process-wide active worker registration so MetalLifecycleGuard's willResignActive
 * observer can synchronously drain ANGLE/VirGL queues before iOS revokes GPU access.
 */
void henge_virgl_register_active_worker(HengeVirglWorker *worker);
void henge_virgl_unregister_active_worker(HengeVirglWorker *worker);
void henge_virgl_drain_active_worker(uint32_t timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* HENGE_VIRGL_WORKER_H */
