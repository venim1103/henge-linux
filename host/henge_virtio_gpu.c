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
    bool                  active;
    bool                  is_3d;
    bool                  has_backing;
    uint32_t              resource_id;
    uint32_t              attached_ctx_mask;
    uint32_t              width;
    uint32_t              height;
    uint32_t              stride;
    uint32_t              format;
    uint8_t              *pixels;
    HengeGpuBackingEntry *backing;
    uint32_t              backing_count;
} HengeGpuResourceSlot;

#define HENGE_VIRTIO_GPU_MAX_2D_BYTES (64ULL * 1024ULL * 1024ULL)

static void free_resource_buffers_locked(HengeGpuResourceSlot *res) {
    if (res == NULL) {
        return;
    }
    free(res->pixels);
    res->pixels = NULL;
    free(res->backing);
    res->backing = NULL;
    res->backing_count = 0U;
    res->has_backing = false;
}

static size_t read_from_backing_locked(const HengeGpuResourceSlot *res,
                                       uint64_t src_off,
                                       uint8_t *dst,
                                       size_t len) {
    if (res == NULL || res->backing == NULL || res->backing_count == 0U || dst == NULL || len == 0U) {
        return 0U;
    }
    size_t copied = 0U;
    uint64_t cursor = 0U;
    for (uint32_t i = 0U; i < res->backing_count && copied < len; i++) {
        uint64_t seg_len = res->backing[i].length;
        if (src_off >= cursor + seg_len) {
            cursor += seg_len;
            continue;
        }
        uint64_t seg_off = (src_off > cursor) ? (src_off - cursor) : 0ULL;
        uint64_t avail = seg_len - seg_off;
        size_t chunk = (avail < (uint64_t)(len - copied)) ? (size_t)avail : (len - copied);
        if (res->backing[i].host_ptr != NULL) {
            memcpy(dst + copied, res->backing[i].host_ptr + seg_off, chunk);
        } else {
            memset(dst + copied, 0, chunk);
        }
        copied += chunk;
        src_off += chunk;
        cursor += seg_len;
    }
    return copied;
}

static void convert_row_to_bgra8(uint32_t format, uint8_t *row, uint32_t pixel_count) {
    switch (format) {
        case HENGE_VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM:
        case HENGE_VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM:
            /* Native BGRA8/BGRX8 layout expected by HvFbDisplay / Metal. */
            break;
        case HENGE_VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM:
        case HENGE_VIRTIO_GPU_FORMAT_R8G8B8X8_UNORM:
            for (uint32_t i = 0U; i < pixel_count; i++) {
                uint8_t *p = row + (size_t)i * 4U;
                uint8_t r = p[0];
                p[0] = p[2];
                p[2] = r;
            }
            break;
        case HENGE_VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM:
        case HENGE_VIRTIO_GPU_FORMAT_X8R8G8B8_UNORM:
            for (uint32_t i = 0U; i < pixel_count; i++) {
                uint8_t *p = row + (size_t)i * 4U;
                uint8_t a = p[0];
                uint8_t r = p[1];
                uint8_t g = p[2];
                uint8_t b = p[3];
                p[0] = b;
                p[1] = g;
                p[2] = r;
                p[3] = a;
            }
            break;
        case HENGE_VIRTIO_GPU_FORMAT_A8B8G8R8_UNORM:
        case HENGE_VIRTIO_GPU_FORMAT_X8B8G8R8_UNORM:
            for (uint32_t i = 0U; i < pixel_count; i++) {
                uint8_t *p = row + (size_t)i * 4U;
                uint8_t a = p[0];
                uint8_t b = p[1];
                uint8_t g = p[2];
                uint8_t r = p[3];
                p[0] = b;
                p[1] = g;
                p[2] = r;
                p[3] = a;
            }
            break;
        default:
            break;
    }
}

typedef struct {
    bool     enabled;
    uint32_t width;
    uint32_t height;
    uint32_t resource_id;
    uint32_t cursor_resource_id;
    uint32_t cursor_x;
    uint32_t cursor_y;
    uint32_t cursor_hot_x;
    uint32_t cursor_hot_y;
    bool     composite_dirty;
    uint8_t *composited_pixels;
    size_t   composited_bytes;
    uint32_t composited_w;
    uint32_t composited_h;
    uint32_t composited_stride;
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

void henge_virtio_gpu_reset(HengeVirtioGpuDevice *dev) {
    if (dev == NULL) {
        return;
    }
    pthread_mutex_lock(&dev->lock);
    for (size_t i = 0U; i < HENGE_VIRTIO_GPU_MAX_RESOURCES; i++) {
        free_resource_buffers_locked(&dev->resources[i]);
    }
    memset(dev->resources, 0, sizeof(dev->resources));
    memset(dev->contexts, 0, sizeof(dev->contexts));
    for (size_t s = 0U; s < HENGE_VIRTIO_GPU_MAX_SCANOUTS; s++) {
        dev->scanouts[s].resource_id = 0U;
        dev->scanouts[s].cursor_resource_id = 0U;
        dev->scanouts[s].cursor_x = 0U;
        dev->scanouts[s].cursor_y = 0U;
        dev->scanouts[s].cursor_hot_x = 0U;
        dev->scanouts[s].cursor_hot_y = 0U;
        dev->scanouts[s].composite_dirty = false;
        free(dev->scanouts[s].composited_pixels);
        dev->scanouts[s].composited_pixels = NULL;
        dev->scanouts[s].composited_bytes = 0U;
        dev->scanouts[s].composited_w = 0U;
        dev->scanouts[s].composited_h = 0U;
        dev->scanouts[s].composited_stride = 0U;
    }
    dev->flush_count = 0ULL;
    dev->cmd_count = 0ULL;
    pthread_mutex_unlock(&dev->lock);
}

void henge_virtio_gpu_destroy(HengeVirtioGpuDevice *dev) {
    if (dev == NULL) {
        return;
    }
    pthread_mutex_lock(&dev->lock);
    for (size_t i = 0; i < HENGE_VIRTIO_GPU_MAX_RESOURCES; i++) {
        free_resource_buffers_locked(&dev->resources[i]);
    }
    for (size_t s = 0U; s < HENGE_VIRTIO_GPU_MAX_SCANOUTS; s++) {
        free(dev->scanouts[s].composited_pixels);
        dev->scanouts[s].composited_pixels = NULL;
    }
    pthread_mutex_unlock(&dev->lock);
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

int henge_virtio_gpu_get_display_info(const HengeVirtioGpuDevice *dev,
                                      uint32_t scanout_id,
                                      uint32_t *out_width,
                                      uint32_t *out_height,
                                      bool *out_enabled) {
    if (dev == NULL || scanout_id >= HENGE_VIRTIO_GPU_MAX_SCANOUTS) {
        return -1;
    }
    HengeVirtioGpuDevice *mut = (HengeVirtioGpuDevice *)dev;
    pthread_mutex_lock(&mut->lock);
    if (out_width != NULL) {
        *out_width = dev->scanouts[scanout_id].width;
    }
    if (out_height != NULL) {
        *out_height = dev->scanouts[scanout_id].height;
    }
    if (out_enabled != NULL) {
        *out_enabled = dev->scanouts[scanout_id].enabled;
    }
    pthread_mutex_unlock(&mut->lock);
    return 0;
}

int henge_virtio_gpu_get_edid(const HengeVirtioGpuDevice *dev,
                              uint32_t scanout_id,
                              uint8_t out_edid[128]) {
    if (dev == NULL || out_edid == NULL || scanout_id >= HENGE_VIRTIO_GPU_MAX_SCANOUTS) {
        return -1;
    }
    uint32_t width = 1920U;
    uint32_t height = 1200U;
    HengeVirtioGpuDevice *mut = (HengeVirtioGpuDevice *)dev;
    pthread_mutex_lock(&mut->lock);
    if (dev->scanouts[scanout_id].width > 0U && dev->scanouts[scanout_id].height > 0U) {
        width = dev->scanouts[scanout_id].width;
        height = dev->scanouts[scanout_id].height;
    }
    pthread_mutex_unlock(&mut->lock);

    if (width > 4095U) {
        width = 4095U;
    }
    if (height > 4095U) {
        height = 4095U;
    }

    memset(out_edid, 0, 128U);
    /* EDID 1.4 header */
    out_edid[0] = 0x00U;
    out_edid[1] = 0xFFU;
    out_edid[2] = 0xFFU;
    out_edid[3] = 0xFFU;
    out_edid[4] = 0xFFU;
    out_edid[5] = 0xFFU;
    out_edid[6] = 0xFFU;
    out_edid[7] = 0x00U;

    /* Manufacturer ID "HNG" (H=8, N=14, G=7) -> 0x21C7 big-endian */
    out_edid[8] = 0x21U;
    out_edid[9] = 0xC7U;
    /* Product code 0x0001, serial 1, week 1, year 2026 (1990 + 36) */
    out_edid[10] = 0x01U;
    out_edid[11] = 0x00U;
    out_edid[12] = 0x01U;
    out_edid[16] = 0x01U;
    out_edid[17] = 36U;
    /* EDID version 1.4 */
    out_edid[18] = 0x01U;
    out_edid[19] = 0x04U;
    /* Digital input, 8-bit color depth, DisplayPort interface */
    out_edid[20] = 0xA5U;
    /* Physical size in cm (~96 DPI nominal) */
    uint32_t width_cm = (width * 254U + 4800U) / 9600U;
    uint32_t height_cm = (height * 254U + 4800U) / 9600U;
    if (width_cm == 0U) width_cm = 16U;
    if (height_cm == 0U) height_cm = 10U;
    if (width_cm > 255U) width_cm = 255U;
    if (height_cm > 255U) height_cm = 255U;
    out_edid[21] = (uint8_t)width_cm;
    out_edid[22] = (uint8_t)height_cm;
    out_edid[23] = 120U; /* Gamma 2.20 */
    out_edid[24] = 0x06U; /* RGB 4:4:4, preferred timing mode in DTD #1 */

    /* Chromaticity (standard sRGB) */
    out_edid[25] = 0xEEU;
    out_edid[26] = 0x91U;
    out_edid[27] = 0xA3U;
    out_edid[28] = 0x54U;
    out_edid[29] = 0x4CU;
    out_edid[30] = 0x99U;
    out_edid[31] = 0x26U;
    out_edid[32] = 0x0FU;
    out_edid[33] = 0x50U;
    out_edid[34] = 0x54U;

    /* Established timings: 640x480@60, 800x600@60, 1024x768@60 */
    out_edid[35] = 0x21U;
    out_edid[36] = 0x08U;
    out_edid[37] = 0x00U;
    /* Unused standard timing slots filled with 0x01, 0x01 */
    for (size_t i = 38U; i < 54U; i++) {
        out_edid[i] = 0x01U;
    }

    /* Detailed Timing Descriptor #1 (bytes 54..71): width x height @ 60 Hz */
    uint32_t hblank = 160U;
    uint32_t vblank = 35U;
    uint32_t hfp = 48U;
    uint32_t hsync = 32U;
    uint32_t vfp = 3U;
    uint32_t vsync = 6U;
    uint64_t pclk_10khz = ((uint64_t)(width + hblank) * (uint64_t)(height + vblank) * 60ULL) / 10000ULL;
    if (pclk_10khz == 0ULL) pclk_10khz = 1ULL;
    if (pclk_10khz > 65535ULL) pclk_10khz = 65535ULL;

    uint8_t *dtd = out_edid + 54;
    dtd[0] = (uint8_t)(pclk_10khz & 0xFFU);
    dtd[1] = (uint8_t)((pclk_10khz >> 8) & 0xFFU);
    dtd[2] = (uint8_t)(width & 0xFFU);
    dtd[3] = (uint8_t)(hblank & 0xFFU);
    dtd[4] = (uint8_t)(((width >> 4) & 0xF0U) | ((hblank >> 8) & 0x0FU));
    dtd[5] = (uint8_t)(height & 0xFFU);
    dtd[6] = (uint8_t)(vblank & 0xFFU);
    dtd[7] = (uint8_t)(((height >> 4) & 0xF0U) | ((vblank >> 8) & 0x0FU));
    dtd[8] = (uint8_t)(hfp & 0xFFU);
    dtd[9] = (uint8_t)(hsync & 0xFFU);
    dtd[10] = (uint8_t)(((vfp & 0x0FU) << 4) | (vsync & 0x0FU));
    dtd[11] = (uint8_t)((((hfp >> 8) & 0x03U) << 6) |
                        (((hsync >> 8) & 0x03U) << 4) |
                        (((vfp >> 4) & 0x03U) << 2) |
                        ((vsync >> 4) & 0x03U));
    uint32_t width_mm = width_cm * 10U;
    uint32_t height_mm = height_cm * 10U;
    dtd[12] = (uint8_t)(width_mm & 0xFFU);
    dtd[13] = (uint8_t)(height_mm & 0xFFU);
    dtd[14] = (uint8_t)(((width_mm >> 4) & 0xF0U) | ((height_mm >> 8) & 0x0FU));
    dtd[15] = 0U;
    dtd[16] = 0U;
    dtd[17] = 0x1EU; /* Digital separate sync, +H +V */

    /* Descriptor #2 (bytes 72..89): Monitor Name "HengeLinux" */
    uint8_t *name_desc = out_edid + 72;
    name_desc[3] = 0xFCU;
    static const char kMonName[] = "HengeLinux\n  ";
    memcpy(name_desc + 5, kMonName, 13U);

    /* Descriptor #3 & #4: Dummy descriptors (0x10) */
    out_edid[90 + 3] = 0x10U;
    out_edid[108 + 3] = 0x10U;

    /* Checksum byte 127 so sum(out_edid[0..127]) == 0 mod 256 */
    uint8_t sum = 0U;
    for (size_t i = 0U; i < 127U; i++) {
        sum = (uint8_t)(sum + out_edid[i]);
    }
    out_edid[127] = (uint8_t)(0U - sum);
    return 0;
}

int henge_virtio_gpu_attach_backing(HengeVirtioGpuDevice *dev,
                                    uint32_t resource_id,
                                    const HengeGpuBackingEntry *entries,
                                    uint32_t entry_count) {
    if (dev == NULL || resource_id == 0U || (entry_count > 0U && entries == NULL)) {
        return -1;
    }
    if (entry_count > 4096U) {
        return -1;
    }
    pthread_mutex_lock(&dev->lock);
    HengeGpuResourceSlot *res = find_resource_locked(dev, resource_id);
    if (res == NULL) {
        pthread_mutex_unlock(&dev->lock);
        return -1;
    }
    HengeGpuBackingEntry *copy = NULL;
    if (entry_count > 0U) {
        copy = calloc((size_t)entry_count, sizeof(*copy));
        if (copy == NULL) {
            pthread_mutex_unlock(&dev->lock);
            return -1;
        }
        memcpy(copy, entries, (size_t)entry_count * sizeof(*copy));
    }
    free(res->backing);
    res->backing = copy;
    res->backing_count = entry_count;
    res->has_backing = (entry_count > 0U);
    pthread_mutex_unlock(&dev->lock);
    return 0;
}

int henge_virtio_gpu_transfer_to_host_2d(HengeVirtioGpuDevice *dev,
                                         uint32_t resource_id,
                                         uint32_t x,
                                         uint32_t y,
                                         uint32_t width,
                                         uint32_t height,
                                         uint64_t offset) {
    if (dev == NULL || resource_id == 0U) {
        return -1;
    }
    pthread_mutex_lock(&dev->lock);
    HengeGpuResourceSlot *res = find_resource_locked(dev, resource_id);
    if (res == NULL || res->pixels == NULL || res->backing == NULL || res->backing_count == 0U) {
        pthread_mutex_unlock(&dev->lock);
        return -1;
    }
    if (width == 0U || height == 0U) {
        pthread_mutex_unlock(&dev->lock);
        return 0;
    }
    if (x >= res->width || y >= res->height) {
        pthread_mutex_unlock(&dev->lock);
        return -1;
    }
    if (width > res->width - x) {
        width = res->width - x;
    }
    if (height > res->height - y) {
        height = res->height - y;
    }

    const uint32_t stride = res->stride;
    const size_t row_bytes = (size_t)width * 4U;
    for (uint32_t row = 0U; row < height; row++) {
        uint64_t src_off = offset + (uint64_t)row * (uint64_t)stride;
        uint8_t *dst_row = res->pixels + (size_t)(y + row) * (size_t)stride + (size_t)x * 4U;
        if (read_from_backing_locked(res, src_off, dst_row, row_bytes) == 0U) {
            break;
        }
        convert_row_to_bgra8(res->format, dst_row, width);
    }

    for (size_t s = 0U; s < HENGE_VIRTIO_GPU_MAX_SCANOUTS; s++) {
        if (dev->scanouts[s].resource_id == resource_id ||
            dev->scanouts[s].cursor_resource_id == resource_id) {
            dev->scanouts[s].composite_dirty = true;
        }
    }

    pthread_mutex_unlock(&dev->lock);
    return 0;
}

static void refresh_scanout_composite_locked(HengeVirtioGpuDevice *dev,
                                             uint32_t scanout_id,
                                             const HengeGpuResourceSlot *res) {
    HengeGpuScanoutState *sc = &dev->scanouts[scanout_id];
    if (sc->cursor_resource_id == 0U || res == NULL || res->pixels == NULL) {
        sc->composite_dirty = false;
        return;
    }
    const HengeGpuResourceSlot *cur = find_resource_locked(dev, sc->cursor_resource_id);
    if (cur == NULL || cur->pixels == NULL || cur->width == 0U || cur->height == 0U) {
        sc->composite_dirty = false;
        return;
    }
    size_t needed = (size_t)res->stride * (size_t)res->height;
    if (needed == 0U || needed > HENGE_VIRTIO_GPU_MAX_2D_BYTES) {
        sc->composite_dirty = false;
        return;
    }
    if (sc->composited_pixels == NULL || sc->composited_bytes != needed) {
        uint8_t *buf = malloc(needed);
        if (buf == NULL) {
            sc->composite_dirty = false;
            return;
        }
        free(sc->composited_pixels);
        sc->composited_pixels = buf;
        sc->composited_bytes = needed;
    }
    memcpy(sc->composited_pixels, res->pixels, needed);
    sc->composited_w = res->width;
    sc->composited_h = res->height;
    sc->composited_stride = res->stride;

    int32_t base_x = (int32_t)sc->cursor_x - (int32_t)sc->cursor_hot_x;
    int32_t base_y = (int32_t)sc->cursor_y - (int32_t)sc->cursor_hot_y;
    for (uint32_t cy = 0U; cy < cur->height; cy++) {
        int32_t dy = base_y + (int32_t)cy;
        if (dy < 0 || (uint32_t)dy >= res->height) continue;
        const uint8_t *src_row = cur->pixels + (size_t)cy * (size_t)cur->stride;
        uint8_t *dst_row = sc->composited_pixels + (size_t)dy * (size_t)res->stride;
        for (uint32_t cx = 0U; cx < cur->width; cx++) {
            int32_t dx = base_x + (int32_t)cx;
            if (dx < 0 || (uint32_t)dx >= res->width) continue;
            const uint8_t *sp = src_row + (size_t)cx * 4U;
            uint8_t a = sp[3];
            if (a == 0U) continue;
            uint8_t *dp = dst_row + (size_t)dx * 4U;
            if (a == 255U) {
                dp[0] = sp[0];
                dp[1] = sp[1];
                dp[2] = sp[2];
                dp[3] = 255U;
            } else {
                uint32_t inv_a = 255U - (uint32_t)a;
                /* Support both premultiplied ARGB (Xorg/DRM) and straight alpha. */
                bool premul = (sp[0] <= a && sp[1] <= a && sp[2] <= a);
                for (int ch = 0; ch < 3; ch++) {
                    uint32_t v = premul
                        ? ((uint32_t)sp[ch] + ((uint32_t)dp[ch] * inv_a + 127U) / 255U)
                        : (((uint32_t)sp[ch] * (uint32_t)a + (uint32_t)dp[ch] * inv_a + 127U) / 255U);
                    dp[ch] = (uint8_t)(v > 255U ? 255U : v);
                }
                dp[3] = 255U;
            }
        }
    }
    sc->composite_dirty = false;
}

int henge_virtio_gpu_update_cursor(HengeVirtioGpuDevice *dev,
                                   uint32_t scanout_id,
                                   uint32_t resource_id,
                                   uint32_t x,
                                   uint32_t y,
                                   uint32_t hot_x,
                                   uint32_t hot_y,
                                   bool move_only) {
    if (dev == NULL || scanout_id >= HENGE_VIRTIO_GPU_MAX_SCANOUTS) {
        return -1;
    }
    pthread_mutex_lock(&dev->lock);
    HengeGpuScanoutState *sc = &dev->scanouts[scanout_id];
    sc->cursor_x = x;
    sc->cursor_y = y;
    if (!move_only) {
        sc->cursor_resource_id = resource_id;
        sc->cursor_hot_x = hot_x;
        sc->cursor_hot_y = hot_y;
    }
    sc->composite_dirty = true;
    pthread_mutex_unlock(&dev->lock);
    return 0;
}

int henge_virtio_gpu_get_scanout_frame(const HengeVirtioGpuDevice *dev,
                                       uint32_t scanout_id,
                                       const uint8_t **out_pixels,
                                       uint32_t *out_width,
                                       uint32_t *out_height,
                                       uint32_t *out_stride) {
    if (dev == NULL || scanout_id >= HENGE_VIRTIO_GPU_MAX_SCANOUTS) {
        return -1;
    }
    HengeVirtioGpuDevice *mut = (HengeVirtioGpuDevice *)dev;
    pthread_mutex_lock(&mut->lock);
    HengeGpuScanoutState *sc = &mut->scanouts[scanout_id];
    uint32_t res_id = sc->resource_id;
    HengeGpuResourceSlot *res = find_resource_locked(mut, res_id);
    if (res == NULL || res->pixels == NULL || res->width == 0U || res->height == 0U) {
        pthread_mutex_unlock(&mut->lock);
        return -1;
    }
    const uint8_t *frame_ptr = res->pixels;
    if (sc->cursor_resource_id != 0U) {
        if (sc->composite_dirty || sc->composited_pixels == NULL ||
            sc->composited_w != res->width || sc->composited_h != res->height) {
            refresh_scanout_composite_locked(mut, scanout_id, res);
        }
        if (sc->composited_pixels != NULL &&
            sc->composited_w == res->width && sc->composited_h == res->height) {
            frame_ptr = sc->composited_pixels;
        }
    }
    if (out_pixels != NULL) {
        *out_pixels = frame_ptr;
    }
    if (out_width != NULL) {
        *out_width = res->width;
    }
    if (out_height != NULL) {
        *out_height = res->height;
    }
    if (out_stride != NULL) {
        *out_stride = res->stride;
    }
    pthread_mutex_unlock(&mut->lock);
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
            uint8_t *pixels = NULL;
            uint32_t stride = 0U;
            if (!is_3d) {
                uint64_t total_bytes = (uint64_t)width * (uint64_t)height * 4ULL;
                if (total_bytes == 0ULL || total_bytes > HENGE_VIRTIO_GPU_MAX_2D_BYTES) {
                    resp = HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
                    break;
                }
                pixels = calloc(1U, (size_t)total_bytes);
                if (pixels == NULL) {
                    resp = HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
                    break;
                }
                stride = width * 4U;
            }
            free_res->active = true;
            free_res->is_3d = is_3d;
            free_res->has_backing = false;
            free_res->resource_id = resource_id;
            free_res->attached_ctx_mask = 0U;
            free_res->width = width;
            free_res->height = height;
            free_res->stride = stride;
            free_res->format = format;
            free_res->pixels = pixels;
            free_res->backing = NULL;
            free_res->backing_count = 0U;
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
                    dev->scanouts[s].composite_dirty = true;
                }
                if (dev->scanouts[s].cursor_resource_id == resource_id) {
                    dev->scanouts[s].cursor_resource_id = 0U;
                    dev->scanouts[s].composite_dirty = true;
                }
            }
            free_resource_buffers_locked(res);
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
            free(res->backing);
            res->backing = NULL;
            res->backing_count = 0U;
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
            dev->scanouts[scanout_id].composite_dirty = true;
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
