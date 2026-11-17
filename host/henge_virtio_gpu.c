/* SPDX-License-Identifier: GPL-3.0-or-later */
#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "henge_virtio_gpu.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__has_include)
#if __has_include(<virglrenderer.h>)
#include <virglrenderer.h>
#define HENGE_HAS_VIRGLRENDERER 1
#endif
#endif

#ifndef HENGE_HAS_VIRGLRENDERER
#define HENGE_HAS_VIRGLRENDERER 0
#endif

typedef struct {
    bool     active;
    uint32_t ctx_id;
    uint32_t attached_resources;
} HengeGpuContextSlot;

typedef struct {
    bool     active;
    bool     is_3d;
    bool     has_backing;
    uint32_t resource_id;
    uint32_t attached_ctx_mask;
    uint32_t width;
    uint32_t height;
    uint32_t format;
} HengeGpuResourceSlot;

typedef struct {
    bool     enabled;
    uint32_t width;
    uint32_t height;
    uint32_t resource_id;
} HengeGpuScanoutState;

struct HengeVirtioGpuDevice {
    pthread_mutex_t      lock;
    HengeVirtioGpuConfig cfg;
    uint64_t             feature_bits;
    uint64_t             flush_count;
    uint64_t             cmd_count;
    bool                 virgl_backend_ready;
    HengeGpuScanoutState scanouts[HENGE_VIRTIO_GPU_MAX_SCANOUTS];
    HengeGpuContextSlot  contexts[HENGE_VIRTIO_GPU_MAX_CONTEXTS];
    HengeGpuResourceSlot resources[HENGE_VIRTIO_GPU_MAX_RESOURCES];
};

int henge_virtio_gpu_init_config(HengeGpuBackendMode mode,
                                 uint32_t vram_mib,
                                 HengeVirtioGpuConfig *out_cfg) {
    if (out_cfg == NULL) {
        return -1;
    }
    if (mode != HENGE_GPU_BACKEND_GOP_2D && mode != HENGE_GPU_BACKEND_VIRGL_3D) {
        return -1;
    }
    if (vram_mib < 64U || vram_mib > 2048U) {
        return -1;
    }

    out_cfg->mode = mode;
    out_cfg->max_scanouts = HENGE_VIRTIO_GPU_MAX_SCANOUTS; /* Primary display + USB-C external monitor */
    out_cfg->vram_mib = vram_mib;

    if (mode == HENGE_GPU_BACKEND_VIRGL_3D) {
        out_cfg->pci_vendor_id = HENGE_VIRTIO_PCI_VENDOR_ID;
        out_cfg->pci_device_id = HENGE_VIRTIO_GPU_DEVICE_ID;
        out_cfg->num_capsets = 2U;
        out_cfg->capset_mask = (1U << HENGE_VIRTIO_GPU_CAPSET_VIRGL) |
                               (1U << HENGE_VIRTIO_GPU_CAPSET_VIRGL2);
        out_cfg->angle_metal_enabled = true;
    } else {
        /* 2D UEFI GOP uses simpledrm/efifb platform framebuffer rather than VirtIO PCI. */
        out_cfg->pci_vendor_id = 0U;
        out_cfg->pci_device_id = 0U;
        out_cfg->num_capsets = 0U;
        out_cfg->capset_mask = 0U;
        out_cfg->angle_metal_enabled = false;
    }

    return 0;
}

bool henge_virtio_gpu_supports_virgl(const HengeVirtioGpuConfig *cfg) {
    if (cfg == NULL || cfg->mode != HENGE_GPU_BACKEND_VIRGL_3D) {
        return false;
    }
    uint32_t required = (1U << HENGE_VIRTIO_GPU_CAPSET_VIRGL) |
                        (1U << HENGE_VIRTIO_GPU_CAPSET_VIRGL2);
    return cfg->num_capsets >= 2U &&
           (cfg->capset_mask & required) == required &&
           cfg->angle_metal_enabled;
}

bool henge_virtio_gpu_has_virglrenderer(void) {
#if HENGE_HAS_VIRGLRENDERER
    return true;
#else
    return false;
#endif
}

static HengeGpuContextSlot *find_context_locked(HengeVirtioGpuDevice *dev,
                                                uint32_t ctx_id,
                                                size_t *out_slot_idx) {
    if (ctx_id == 0U) {
        return NULL;
    }
    for (size_t i = 0; i < HENGE_VIRTIO_GPU_MAX_CONTEXTS; i++) {
        if (dev->contexts[i].active && dev->contexts[i].ctx_id == ctx_id) {
            if (out_slot_idx != NULL) {
                *out_slot_idx = i;
            }
            return &dev->contexts[i];
        }
    }
    return NULL;
}

static HengeGpuResourceSlot *find_resource_locked(HengeVirtioGpuDevice *dev, uint32_t resource_id) {
    if (resource_id == 0U) {
        return NULL;
    }
    for (size_t i = 0; i < HENGE_VIRTIO_GPU_MAX_RESOURCES; i++) {
        if (dev->resources[i].active && dev->resources[i].resource_id == resource_id) {
            return &dev->resources[i];
        }
    }
    return NULL;
}

HengeVirtioGpuDevice *henge_virtio_gpu_create(const HengeVirtioGpuConfig *cfg) {
    if (cfg == NULL) {
        return NULL;
    }
    if (cfg->mode != HENGE_GPU_BACKEND_GOP_2D && cfg->mode != HENGE_GPU_BACKEND_VIRGL_3D) {
        return NULL;
    }

    HengeVirtioGpuDevice *dev = calloc(1U, sizeof(*dev));
    if (dev == NULL) {
        return NULL;
    }

    pthread_mutex_init(&dev->lock, NULL);
    dev->cfg = *cfg;
    dev->scanouts[0].enabled = true;
    dev->scanouts[0].width = 1920U;
    dev->scanouts[0].height = 1200U;
    dev->scanouts[1].enabled = false;
    dev->scanouts[1].width = 1920U;
    dev->scanouts[1].height = 1080U;

    if (cfg->mode == HENGE_GPU_BACKEND_VIRGL_3D) {
        dev->feature_bits = HENGE_VIRTIO_GPU_F_VIRGL |
                            HENGE_VIRTIO_GPU_F_EDID |
                            HENGE_VIRTIO_GPU_F_RESOURCE_UUID |
                            HENGE_VIRTIO_GPU_F_CONTEXT_INIT;
        dev->virgl_backend_ready = cfg->angle_metal_enabled;
    } else {
        dev->feature_bits = HENGE_VIRTIO_GPU_F_EDID;
        dev->virgl_backend_ready = false;
    }

    return dev;
}

bool henge_virtio_gpu_is_virgl_ready(const HengeVirtioGpuDevice *dev) {
    return dev != NULL && dev->virgl_backend_ready;
}

void henge_virtio_gpu_destroy(HengeVirtioGpuDevice *dev) {
    if (dev == NULL) {
        return;
    }
    pthread_mutex_destroy(&dev->lock);
    free(dev);
}

uint64_t henge_virtio_gpu_feature_bits(const HengeVirtioGpuDevice *dev) {
    return (dev != NULL) ? dev->feature_bits : 0ULL;
}

uint32_t henge_virtio_gpu_scanout_resource(const HengeVirtioGpuDevice *dev, uint32_t scanout_id) {
    if (dev == NULL || scanout_id >= HENGE_VIRTIO_GPU_MAX_SCANOUTS) {
        return 0U;
    }
    HengeVirtioGpuDevice *mut = (HengeVirtioGpuDevice *)dev;
    pthread_mutex_lock(&mut->lock);
    uint32_t res_id = dev->scanouts[scanout_id].resource_id;
    pthread_mutex_unlock(&mut->lock);
    return res_id;
}

uint64_t henge_virtio_gpu_flush_count(const HengeVirtioGpuDevice *dev) {
    if (dev == NULL) {
        return 0ULL;
    }
    HengeVirtioGpuDevice *mut = (HengeVirtioGpuDevice *)dev;
    pthread_mutex_lock(&mut->lock);
    uint64_t count = dev->flush_count;
    pthread_mutex_unlock(&mut->lock);
    return count;
}

uint32_t henge_virtio_gpu_active_contexts(const HengeVirtioGpuDevice *dev) {
    if (dev == NULL) {
        return 0U;
    }
    HengeVirtioGpuDevice *mut = (HengeVirtioGpuDevice *)dev;
    pthread_mutex_lock(&mut->lock);
    uint32_t active = 0U;
    for (size_t i = 0; i < HENGE_VIRTIO_GPU_MAX_CONTEXTS; i++) {
        if (dev->contexts[i].active) {
            active++;
        }
    }
    pthread_mutex_unlock(&mut->lock);
    return active;
}

uint32_t henge_virtio_gpu_active_resources(const HengeVirtioGpuDevice *dev) {
    if (dev == NULL) {
        return 0U;
    }
    HengeVirtioGpuDevice *mut = (HengeVirtioGpuDevice *)dev;
    pthread_mutex_lock(&mut->lock);
    uint32_t active = 0U;
    for (size_t i = 0; i < HENGE_VIRTIO_GPU_MAX_RESOURCES; i++) {
        if (dev->resources[i].active) {
            active++;
        }
    }
    pthread_mutex_unlock(&mut->lock);
    return active;
}

uint32_t henge_virtio_gpu_context_attached_resources(const HengeVirtioGpuDevice *dev, uint32_t ctx_id) {
    if (dev == NULL || ctx_id == 0U) {
        return 0U;
    }
    HengeVirtioGpuDevice *mut = (HengeVirtioGpuDevice *)dev;
    pthread_mutex_lock(&mut->lock);
    HengeGpuContextSlot *ctx = find_context_locked(mut, ctx_id, NULL);
    uint32_t count = (ctx != NULL) ? ctx->attached_resources : 0U;
    pthread_mutex_unlock(&mut->lock);
    return count;
}

int henge_virtio_gpu_set_display_mode(HengeVirtioGpuDevice *dev,
                                      uint32_t scanout_id,
                                      uint32_t width,
                                      uint32_t height,
                                      bool enabled) {
    if (dev == NULL || scanout_id >= HENGE_VIRTIO_GPU_MAX_SCANOUTS) {
        return -1;
    }
    if (enabled && (width == 0U || height == 0U || width > 7680U || height > 4320U)) {
        return -1;
    }
    pthread_mutex_lock(&dev->lock);
    dev->scanouts[scanout_id].enabled = enabled;
    if (enabled) {
        dev->scanouts[scanout_id].width = width;
        dev->scanouts[scanout_id].height = height;
    }
    pthread_mutex_unlock(&dev->lock);
    return 0;
}

HengeVirtioGpuRespType henge_virtio_gpu_process_ctrl(HengeVirtioGpuDevice *dev,
                                                     uint32_t cmd_type,
                                                     uint32_t ctx_id,
                                                     uint32_t resource_id,
                                                     uint32_t scanout_id,
                                                     uint32_t width,
                                                     uint32_t height,
                                                     uint32_t format,
                                                     const void *payload,
                                                     size_t payload_len) {
    if (dev == NULL) {
        return HENGE_VIRTIO_GPU_RESP_ERR_UNSPEC;
    }

    pthread_mutex_lock(&dev->lock);
    dev->cmd_count++;
    HengeVirtioGpuRespType resp = HENGE_VIRTIO_GPU_RESP_OK_NODATA;

    switch ((HengeVirtioGpuCmdType)cmd_type) {
        case HENGE_VIRTIO_GPU_CMD_GET_DISPLAY_INFO:
            resp = HENGE_VIRTIO_GPU_RESP_OK_DISPLAY_INFO;
            break;

        case HENGE_VIRTIO_GPU_CMD_GET_CAPSET_INFO:
        case HENGE_VIRTIO_GPU_CMD_GET_CAPSET:
            if (dev->cfg.mode != HENGE_GPU_BACKEND_VIRGL_3D) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
            } else {
                resp = (cmd_type == HENGE_VIRTIO_GPU_CMD_GET_CAPSET_INFO)
                    ? HENGE_VIRTIO_GPU_RESP_OK_CAPSET_INFO
                    : HENGE_VIRTIO_GPU_RESP_OK_CAPSET;
            }
            break;

        case HENGE_VIRTIO_GPU_CMD_GET_EDID:
            if (scanout_id >= HENGE_VIRTIO_GPU_MAX_SCANOUTS) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT;
            } else {
                resp = HENGE_VIRTIO_GPU_RESP_OK_EDID;
            }
            break;

        case HENGE_VIRTIO_GPU_CMD_CTX_CREATE: {
            if (dev->cfg.mode != HENGE_GPU_BACKEND_VIRGL_3D || ctx_id == 0U) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT;
                break;
            }
            if (find_context_locked(dev, ctx_id, NULL) != NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT;
                break;
            }
            HengeGpuContextSlot *free_slot = NULL;
            for (size_t i = 0; i < HENGE_VIRTIO_GPU_MAX_CONTEXTS; i++) {
                if (!dev->contexts[i].active) {
                    free_slot = &dev->contexts[i];
                    break;
                }
            }
            if (free_slot == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
                break;
            }
            free_slot->active = true;
            free_slot->ctx_id = ctx_id;
            free_slot->attached_resources = 0U;
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_CTX_DESTROY: {
            size_t slot_idx = 0U;
            HengeGpuContextSlot *ctx = find_context_locked(dev, ctx_id, &slot_idx);
            if (ctx == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT;
                break;
            }
            uint32_t ctx_bit = 1U << (uint32_t)slot_idx;
            for (size_t i = 0; i < HENGE_VIRTIO_GPU_MAX_RESOURCES; i++) {
                if (dev->resources[i].active) {
                    dev->resources[i].attached_ctx_mask &= ~ctx_bit;
                }
            }
            memset(ctx, 0, sizeof(*ctx));
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_2D:
        case HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_3D: {
            bool is_3d = (cmd_type == HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_3D);
            if (is_3d && dev->cfg.mode != HENGE_GPU_BACKEND_VIRGL_3D) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
                break;
            }
            if (resource_id == 0U || width == 0U || height == 0U || width > 7680U || height > 4320U) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
                break;
            }
            if (find_resource_locked(dev, resource_id) != NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE;
                break;
            }
            HengeGpuResourceSlot *free_res = NULL;
            for (size_t i = 0; i < HENGE_VIRTIO_GPU_MAX_RESOURCES; i++) {
                if (!dev->resources[i].active) {
                    free_res = &dev->resources[i];
                    break;
                }
            }
            if (free_res == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
                break;
            }
            free_res->active = true;
            free_res->is_3d = is_3d;
            free_res->has_backing = false;
            free_res->resource_id = resource_id;
            free_res->attached_ctx_mask = 0U;
            free_res->width = width;
            free_res->height = height;
            free_res->format = format;
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_RESOURCE_UNREF: {
            HengeGpuResourceSlot *res = find_resource_locked(dev, resource_id);
            if (res == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE;
                break;
            }
            for (size_t c = 0; c < HENGE_VIRTIO_GPU_MAX_CONTEXTS; c++) {
                if ((res->attached_ctx_mask & (1U << (uint32_t)c)) != 0U &&
                    dev->contexts[c].active &&
                    dev->contexts[c].attached_resources > 0U) {
                    dev->contexts[c].attached_resources--;
                }
            }
            for (size_t s = 0; s < HENGE_VIRTIO_GPU_MAX_SCANOUTS; s++) {
                if (dev->scanouts[s].resource_id == resource_id) {
                    dev->scanouts[s].resource_id = 0U;
                }
            }
            memset(res, 0, sizeof(*res));
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING: {
            HengeGpuResourceSlot *res = find_resource_locked(dev, resource_id);
            if (res == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE;
                break;
            }
            res->has_backing = true;
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING: {
            HengeGpuResourceSlot *res = find_resource_locked(dev, resource_id);
            if (res == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE;
                break;
            }
            res->has_backing = false;
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE: {
            size_t slot_idx = 0U;
            HengeGpuContextSlot *ctx = find_context_locked(dev, ctx_id, &slot_idx);
            if (ctx == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT;
                break;
            }
            HengeGpuResourceSlot *res = find_resource_locked(dev, resource_id);
            if (res == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE;
                break;
            }
            uint32_t ctx_bit = 1U << (uint32_t)slot_idx;
            if ((res->attached_ctx_mask & ctx_bit) == 0U) {
                res->attached_ctx_mask |= ctx_bit;
                ctx->attached_resources++;
            }
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_CTX_DETACH_RESOURCE: {
            size_t slot_idx = 0U;
            HengeGpuContextSlot *ctx = find_context_locked(dev, ctx_id, &slot_idx);
            if (ctx == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT;
                break;
            }
            HengeGpuResourceSlot *res = find_resource_locked(dev, resource_id);
            if (res == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE;
                break;
            }
            uint32_t ctx_bit = 1U << (uint32_t)slot_idx;
            if ((res->attached_ctx_mask & ctx_bit) != 0U) {
                res->attached_ctx_mask &= ~ctx_bit;
                if (ctx->attached_resources > 0U) {
                    ctx->attached_resources--;
                }
            }
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D:
        case HENGE_VIRTIO_GPU_CMD_TRANSFER_TO_HOST_3D:
        case HENGE_VIRTIO_GPU_CMD_TRANSFER_FROM_HOST_3D: {
            if (find_resource_locked(dev, resource_id) == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE;
            }
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_SUBMIT_3D: {
            if (dev->cfg.mode != HENGE_GPU_BACKEND_VIRGL_3D ||
                find_context_locked(dev, ctx_id, NULL) == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT;
                break;
            }
            if (payload_len > 0U && payload == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM;
                break;
            }
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_SET_SCANOUT: {
            if (scanout_id >= HENGE_VIRTIO_GPU_MAX_SCANOUTS) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT;
                break;
            }
            if (resource_id != 0U && find_resource_locked(dev, resource_id) == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE;
                break;
            }
            dev->scanouts[scanout_id].resource_id = resource_id;
            if (width > 0U && height > 0U) {
                dev->scanouts[scanout_id].width = width;
                dev->scanouts[scanout_id].height = height;
            }
            break;
        }

        case HENGE_VIRTIO_GPU_CMD_RESOURCE_FLUSH: {
            if (resource_id == 0U || find_resource_locked(dev, resource_id) == NULL) {
                resp = HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE;
                break;
            }
            dev->flush_count++;
            break;
        }

        default:
            resp = HENGE_VIRTIO_GPU_RESP_ERR_UNSPEC;
            break;
    }

    pthread_mutex_unlock(&dev->lock);
    return resp;
}

#define HENGE_SNAPSHOT_MAGIC "HENGESNP"
#define HENGE_SNAPSHOT_VERSION 1U
#define HENGE_SNAPSHOT_MAX_PAYLOAD (64ULL * 1024ULL * 1024ULL)

typedef struct __attribute__((packed)) {
    char     magic[8];
    uint32_t version;
    uint32_t ram_mib;
    uint32_t cpu_count;
    uint32_t gpu_mode;
    uint32_t scanout0_res_id;
    uint32_t reserved;
    uint64_t suspend_counter_offset;
    uint64_t gpu_flush_count;
    uint64_t payload_bytes;
    uint64_t payload_fnv1a64;
    uint64_t header_fnv1a64;
} HengeSnapshotDiskRecord;

static uint64_t snapshot_fnv1a64(const void *data, size_t len) {
    uint64_t h = 14695981039346656037ULL;
    const uint8_t *p = (const uint8_t *)data;
    for (size_t i = 0; i < len; i++) {
        h ^= (uint64_t)p[i];
        h *= 1099511628211ULL;
    }
    return h;
}

int henge_vm_snapshot_write(const char *path,
                            const HengeVmSnapshotInfo *info,
                            const void *payload,
                            size_t payload_len) {
    if (path == NULL || path[0] == '\0' || info == NULL) {
        return -1;
    }
    if ((payload_len > 0U && payload == NULL) || (uint64_t)payload_len > HENGE_SNAPSHOT_MAX_PAYLOAD) {
        return -1;
    }

#if defined(PATH_MAX) && (PATH_MAX > 1024)
    char tmp_path[PATH_MAX];
#else
    char tmp_path[1024];
#endif
    int n = snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", path);
    if (n <= 0 || (size_t)n >= sizeof(tmp_path)) {
        return -1;
    }

    HengeSnapshotDiskRecord rec;
    memset(&rec, 0, sizeof(rec));
    memcpy(rec.magic, HENGE_SNAPSHOT_MAGIC, 8U);
    rec.version = HENGE_SNAPSHOT_VERSION;
    rec.ram_mib = info->ram_mib;
    rec.cpu_count = info->cpu_count;
    rec.gpu_mode = info->gpu_mode;
    rec.scanout0_res_id = info->scanout0_res_id;
    rec.suspend_counter_offset = info->suspend_counter_offset;
    rec.gpu_flush_count = info->gpu_flush_count;
    rec.payload_bytes = (uint64_t)payload_len;
    rec.payload_fnv1a64 = (payload_len > 0U) ? snapshot_fnv1a64(payload, payload_len) : 0ULL;
    rec.header_fnv1a64 = snapshot_fnv1a64(&rec, offsetof(HengeSnapshotDiskRecord, header_fnv1a64));

    FILE *fp = fopen(tmp_path, "wb");
    if (fp == NULL) {
        return -1;
    }

    bool ok = (fwrite(&rec, sizeof(rec), 1U, fp) == 1U);
    if (ok && payload_len > 0U) {
        ok = (fwrite(payload, 1U, payload_len, fp) == payload_len);
    }
    if (ok && fflush(fp) != 0) {
        ok = false;
    }
    if (ok) {
        int fd = fileno(fp);
        if (fd < 0 || fsync(fd) != 0) {
            ok = false;
        }
#if defined(__APPLE__) && defined(F_FULLFSYNC)
        if (ok) {
            (void)fcntl(fd, F_FULLFSYNC);
        }
#endif
    }
    if (fclose(fp) != 0) {
        ok = false;
    }
    if (!ok) {
        unlink(tmp_path);
        return -1;
    }
    if (rename(tmp_path, path) != 0) {
        unlink(tmp_path);
        return -1;
    }
    return 0;
}

int henge_vm_snapshot_read(const char *path,
                           HengeVmSnapshotInfo *out_info,
                           void *payload_buf,
                           size_t payload_cap) {
    if (path == NULL || path[0] == '\0' || out_info == NULL) {
        return -1;
    }

    FILE *fp = fopen(path, "rb");
    if (fp == NULL) {
        return -1;
    }

    HengeSnapshotDiskRecord rec;
    if (fread(&rec, sizeof(rec), 1U, fp) != 1U) {
        fclose(fp);
        return -1;
    }

    if (memcmp(rec.magic, HENGE_SNAPSHOT_MAGIC, 8U) != 0 ||
        rec.version != HENGE_SNAPSHOT_VERSION ||
        rec.payload_bytes > HENGE_SNAPSHOT_MAX_PAYLOAD) {
        fclose(fp);
        return -1;
    }

    uint64_t expected_hdr = snapshot_fnv1a64(&rec, offsetof(HengeSnapshotDiskRecord, header_fnv1a64));
    if (rec.header_fnv1a64 != expected_hdr) {
        fclose(fp);
        return -1;
    }

    if (rec.payload_bytes > 0ULL) {
        if (payload_buf == NULL || payload_cap < (size_t)rec.payload_bytes) {
            fclose(fp);
            return -1;
        }
        size_t need = (size_t)rec.payload_bytes;
        if (fread(payload_buf, 1U, need, fp) != need) {
            fclose(fp);
            return -1;
        }
        if (snapshot_fnv1a64(payload_buf, need) != rec.payload_fnv1a64) {
            fclose(fp);
            return -1;
        }
    }

    fclose(fp);

    memset(out_info, 0, sizeof(*out_info));
    out_info->version = rec.version;
    out_info->ram_mib = rec.ram_mib;
    out_info->cpu_count = rec.cpu_count;
    out_info->gpu_mode = rec.gpu_mode;
    out_info->scanout0_res_id = rec.scanout0_res_id;
    out_info->suspend_counter_offset = rec.suspend_counter_offset;
    out_info->gpu_flush_count = rec.gpu_flush_count;
    out_info->payload_bytes = rec.payload_bytes;
    out_info->payload_fnv1a64 = rec.payload_fnv1a64;
    return 0;
}
