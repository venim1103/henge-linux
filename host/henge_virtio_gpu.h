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
    HENGE_VIRTIO_GPU_CMD_SUBMIT_3D               = 0x0207U
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

/* Allocate and tear down a VirtIO-GPU 1.0 control-queue device instance. */
HengeVirtioGpuDevice *henge_virtio_gpu_create(const HengeVirtioGpuConfig *cfg);
void henge_virtio_gpu_destroy(HengeVirtioGpuDevice *dev);

/* Query negotiated VirtIO-GPU feature bits and live state counters. */
uint64_t henge_virtio_gpu_feature_bits(const HengeVirtioGpuDevice *dev);
uint32_t henge_virtio_gpu_scanout_resource(const HengeVirtioGpuDevice *dev, uint32_t scanout_id);
uint64_t henge_virtio_gpu_flush_count(const HengeVirtioGpuDevice *dev);
uint32_t henge_virtio_gpu_active_contexts(const HengeVirtioGpuDevice *dev);
uint32_t henge_virtio_gpu_active_resources(const HengeVirtioGpuDevice *dev);

/* Update host display geometry for primary (0) or USB-C external (1) scanout. */
int henge_virtio_gpu_set_display_mode(HengeVirtioGpuDevice *dev,
                                      uint32_t scanout_id,
                                      uint32_t width,
                                      uint32_t height,
                                      bool enabled);

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

#ifdef __cplusplus
}
#endif

#endif /* HENGE_VIRTIO_GPU_H */
