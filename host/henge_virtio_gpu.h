/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HENGE_VIRTIO_GPU_H
#define HENGE_VIRTIO_GPU_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* VirtIO-GPU PCI device identifiers (QEMU / mainline Linux virtio_gpu). */
#define HENGE_VIRTIO_PCI_VENDOR_ID 0x1AF4U
#define HENGE_VIRTIO_GPU_DEVICE_ID 0x1050U

/* VirGL capset identifiers negotiated with Mesa gallium-virgl. */
#define HENGE_VIRTIO_GPU_CAPSET_VIRGL  1U
#define HENGE_VIRTIO_GPU_CAPSET_VIRGL2 2U

/* VirtIO-GPU 1.0 device feature bits (virtio_gpu.h). */
#define HENGE_VIRTIO_GPU_F_VIRGL         (1ULL << 0)
#define HENGE_VIRTIO_GPU_F_EDID          (1ULL << 1)
#define HENGE_VIRTIO_GPU_F_RESOURCE_UUID (1ULL << 2)
#define HENGE_VIRTIO_GPU_F_RESOURCE_BLOB (1ULL << 3)
#define HENGE_VIRTIO_GPU_F_CONTEXT_INIT  (1ULL << 4)

#define HENGE_VIRTIO_GPU_MAX_SCANOUTS  2U
#define HENGE_VIRTIO_GPU_MAX_CONTEXTS  32U
#define HENGE_VIRTIO_GPU_MAX_RESOURCES 256U

/* VirtIO-GPU 2D pixel formats (virtio_gpu_formats). */
#define HENGE_VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM 1U
#define HENGE_VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM 2U
#define HENGE_VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM 3U
#define HENGE_VIRTIO_GPU_FORMAT_X8R8G8B8_UNORM 4U
#define HENGE_VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM 67U
#define HENGE_VIRTIO_GPU_FORMAT_X8B8G8R8_UNORM 68U
#define HENGE_VIRTIO_GPU_FORMAT_A8B8G8R8_UNORM 121U
#define HENGE_VIRTIO_GPU_FORMAT_R8G8B8X8_UNORM 134U

/* Scatter-gather guest backing segment for 2D/3D VirtIO-GPU resources. */
typedef struct {
    const uint8_t *host_ptr;
    uint64_t       guest_addr;
    uint32_t       length;
    uint32_t       reserved;
} HengeGpuBackingEntry;

/* VirtIO-GPU control queue command types. */
typedef enum {
    HENGE_VIRTIO_GPU_CMD_GET_DISPLAY_INFO        = 0x0100U,
    HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_2D      = 0x0101U,
    HENGE_VIRTIO_GPU_CMD_RESOURCE_UNREF          = 0x0102U,
    HENGE_VIRTIO_GPU_CMD_SET_SCANOUT             = 0x0103U,
    HENGE_VIRTIO_GPU_CMD_RESOURCE_FLUSH          = 0x0104U,
    HENGE_VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D     = 0x0105U,
    HENGE_VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING = 0x0106U,
    HENGE_VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING = 0x0107U,
    HENGE_VIRTIO_GPU_CMD_GET_CAPSET_INFO         = 0x0108U,
    HENGE_VIRTIO_GPU_CMD_GET_CAPSET              = 0x0109U,
    HENGE_VIRTIO_GPU_CMD_GET_EDID                = 0x010AU,
    HENGE_VIRTIO_GPU_CMD_CTX_CREATE              = 0x0200U,
    HENGE_VIRTIO_GPU_CMD_CTX_DESTROY             = 0x0201U,
    HENGE_VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE     = 0x0202U,
    HENGE_VIRTIO_GPU_CMD_CTX_DETACH_RESOURCE     = 0x0203U,
    HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_3D      = 0x0204U,
    HENGE_VIRTIO_GPU_CMD_TRANSFER_TO_HOST_3D     = 0x0205U,
    HENGE_VIRTIO_GPU_CMD_TRANSFER_FROM_HOST_3D   = 0x0206U,
    HENGE_VIRTIO_GPU_CMD_SUBMIT_3D               = 0x0207U,
    HENGE_VIRTIO_GPU_CMD_UPDATE_CURSOR           = 0x0300U,
    HENGE_VIRTIO_GPU_CMD_MOVE_CURSOR             = 0x0301U
} HengeVirtioGpuCmdType;

/* VirtIO-GPU control queue response status codes. */
typedef enum {
    HENGE_VIRTIO_GPU_RESP_OK_NODATA            = 0x1100U,
    HENGE_VIRTIO_GPU_RESP_OK_DISPLAY_INFO      = 0x1101U,
    HENGE_VIRTIO_GPU_RESP_OK_CAPSET_INFO       = 0x1102U,
    HENGE_VIRTIO_GPU_RESP_OK_CAPSET            = 0x1103U,
    HENGE_VIRTIO_GPU_RESP_OK_EDID              = 0x1104U,
    HENGE_VIRTIO_GPU_RESP_ERR_UNSPEC           = 0x1200U,
    HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY    = 0x1201U,
    HENGE_VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT  = 0x1202U,
    HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE = 0x1203U,
    HENGE_VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT  = 0x1204U,
    HENGE_VIRTIO_GPU_RESP_ERR_INVALID_PARAM    = 0x1205U
} HengeVirtioGpuRespType;

typedef enum {
    HENGE_GPU_BACKEND_GOP_2D   = 0, /* 2D UEFI GOP BGRA8 framebuffer -> CAMetalLayer */
    HENGE_GPU_BACKEND_VIRGL_3D = 1  /* 3D virtio-gpu-gl-pci -> virglrenderer -> ANGLE -> Metal */
} HengeGpuBackendMode;

typedef struct {
    HengeGpuBackendMode mode;
    uint16_t pci_vendor_id;
    uint16_t pci_device_id;
    uint32_t max_scanouts;
    uint32_t num_capsets;
    uint32_t capset_mask;
    uint32_t vram_mib;
    bool     angle_metal_enabled;
} HengeVirtioGpuConfig;

typedef struct HengeVirtioGpuDevice HengeVirtioGpuDevice;

/* Initialize and validate a VirtIO-GPU backend configuration for Arch Linux. */
int henge_virtio_gpu_init_config(HengeGpuBackendMode mode,
                                 uint32_t vram_mib,
                                 HengeVirtioGpuConfig *out_cfg);

/* Return true if the configured GPU exposes VirGL 3D capsets for Wayland compositors. */
bool henge_virtio_gpu_supports_virgl(const HengeVirtioGpuConfig *cfg);

/* Return true if native libvirglrenderer headers/runtime are linked into this build. */
bool henge_virtio_gpu_has_virglrenderer(void);

/* Allocate, reset, and tear down a VirtIO-GPU 1.0 control-queue device instance. */
HengeVirtioGpuDevice *henge_virtio_gpu_create(const HengeVirtioGpuConfig *cfg);
void henge_virtio_gpu_reset(HengeVirtioGpuDevice *dev);
void henge_virtio_gpu_destroy(HengeVirtioGpuDevice *dev);

/* Query negotiated VirtIO-GPU feature bits and live state counters. */
int henge_virtio_gpu_get_config(const HengeVirtioGpuDevice *dev, HengeVirtioGpuConfig *out_cfg);
uint64_t henge_virtio_gpu_feature_bits(const HengeVirtioGpuDevice *dev);
uint32_t henge_virtio_gpu_scanout_resource(const HengeVirtioGpuDevice *dev, uint32_t scanout_id);
uint64_t henge_virtio_gpu_flush_count(const HengeVirtioGpuDevice *dev);
uint32_t henge_virtio_gpu_active_contexts(const HengeVirtioGpuDevice *dev);
uint32_t henge_virtio_gpu_active_resources(const HengeVirtioGpuDevice *dev);
uint32_t henge_virtio_gpu_context_attached_resources(const HengeVirtioGpuDevice *dev, uint32_t ctx_id);

/* Accumulated dirty rectangle for event-driven Metal partial texture uploads. */
typedef struct {
    bool     valid;
    bool     full;
    uint32_t x;
    uint32_t y;
    uint32_t width;
    uint32_t height;
} HengeGpuDirtyRect;

/* Hardware cursor overlay state exported directly to the Metal presenter (zero CPU compositing). */
typedef struct {
    bool           visible;
    uint32_t       resource_id;
    const uint8_t *pixels;
    uint32_t       width;
    uint32_t       height;
    uint32_t       stride;
    int32_t        x;
    int32_t        y;
    int32_t        hot_x;
    int32_t        hot_y;
    uint64_t       texture_gen;
    uint64_t       position_gen;
} HengeGpuCursorState;

/* Update host display geometry for primary (0) or USB-C external (1) scanout. */
int henge_virtio_gpu_set_display_mode(HengeVirtioGpuDevice *dev,
                                      uint32_t scanout_id,
                                      uint32_t width,
                                      uint32_t height,
                                      bool enabled);

/* Query current display geometry for a scanout. */
int henge_virtio_gpu_get_display_info(const HengeVirtioGpuDevice *dev,
                                      uint32_t scanout_id,
                                      uint32_t *out_width,
                                      uint32_t *out_height,
                                      bool *out_enabled);

/* Synthesize a valid 128-byte VESA EDID 1.4 block for a scanout. */
int henge_virtio_gpu_get_edid(const HengeVirtioGpuDevice *dev,
                              uint32_t scanout_id,
                              uint8_t out_edid[128]);

/* Attach a guest scatter-gather backing table to a 2D/3D resource. */
int henge_virtio_gpu_attach_backing(HengeVirtioGpuDevice *dev,
                                    uint32_t resource_id,
                                    const HengeGpuBackingEntry *entries,
                                    uint32_t entry_count);

/* Blit a dirty rectangle from guest backing pages into the host BGRA8/BGRX8 resource buffer. */
int henge_virtio_gpu_transfer_to_host_2d(HengeVirtioGpuDevice *dev,
                                         uint32_t resource_id,
                                         uint32_t x,
                                         uint32_t y,
                                         uint32_t width,
                                         uint32_t height,
                                         uint64_t offset);

/* Update or move the 2D hardware cursor overlay for a scanout (cursorq). */
int henge_virtio_gpu_update_cursor(HengeVirtioGpuDevice *dev,
                                   uint32_t scanout_id,
                                   uint32_t resource_id,
                                   uint32_t x,
                                   uint32_t y,
                                   uint32_t hot_x,
                                   uint32_t hot_y,
                                   bool move_only);

/* Snapshot the active scanout's raw host BGRA8 pixel buffer pointer and geometry. */
int henge_virtio_gpu_get_scanout_frame(const HengeVirtioGpuDevice *dev,
                                       uint32_t scanout_id,
                                       const uint8_t **out_pixels,
                                       uint32_t *out_width,
                                       uint32_t *out_height,
                                       uint32_t *out_stride);

/* Atomically consume and clear accumulated dirty bounds for a scanout's active resource. */
int henge_virtio_gpu_consume_scanout_dirty(HengeVirtioGpuDevice *dev,
                                           uint32_t scanout_id,
                                           HengeGpuDirtyRect *out_dirty);

/* Snapshot hardware cursor overlay state for native Metal quad compositing. */
int henge_virtio_gpu_get_cursor_state(const HengeVirtioGpuDevice *dev,
                                      uint32_t scanout_id,
                                      HengeGpuCursorState *out_cursor);

/* Dispatch a VirtIO-GPU 2D/3D control queue command and return its response code. */
HengeVirtioGpuRespType henge_virtio_gpu_process_ctrl(HengeVirtioGpuDevice *dev,
                                                     uint32_t cmd_type,
                                                     uint32_t ctx_id,
                                                     uint32_t resource_id,
                                                     uint32_t scanout_id,
                                                     uint32_t width,
                                                     uint32_t height,
                                                     uint32_t format,
                                                     const void *payload,
                                                     size_t payload_len);

/*
 * Background VM state serialization (tctiSH-inspired Jetsam-safe snapshot):
 * atomically writes and verifies a checksummed state header + payload so iOS
 * background transitions can persist VM configuration and display/timer metadata.
 */
typedef struct {
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
} HengeVmSnapshotInfo;

int henge_vm_snapshot_write(const char *path,
                            const HengeVmSnapshotInfo *info,
                            const void *payload,
                            size_t payload_len);

int henge_vm_snapshot_read(const char *path,
                           HengeVmSnapshotInfo *out_info,
                           void *payload_buf,
                           size_t payload_cap);

bool henge_virtio_gpu_is_virgl_ready(const HengeVirtioGpuDevice *dev);

#ifdef __cplusplus
}
#endif

#endif /* HENGE_VIRTIO_GPU_H */
