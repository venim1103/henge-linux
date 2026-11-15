/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HENGE_VIRTIO_GPU_H
#define HENGE_VIRTIO_GPU_H

#include <stdbool.h>
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

typedef enum {
    HENGE_GPU_BACKEND_GOP_2D   = 0, /* 2D UEFI GOP BGRA8 framebuffer -> CAMetalLayer */
    HENGE_GPU_BACKEND_VIRGL_3D = 1  /* 3D virtio-gpu-gl-pci -> virglrenderer -> ANGLE -> Metal */
} HengeGpuBackendMode;

typedef struct {
    HengeGpuBackendMode mode;
    uint16_t pci_vendor_id;
    uint16_t pci_device_id;
    uint32_t max_scanouts;
    uint32_t capset_mask;
    uint32_t vram_mib;
    bool     angle_metal_enabled;
} HengeVirtioGpuConfig;

/* Initialize and validate a VirtIO-GPU backend configuration for Arch Linux. */
int henge_virtio_gpu_init_config(HengeGpuBackendMode mode,
                                 uint32_t vram_mib,
                                 HengeVirtioGpuConfig *out_cfg);

/* Return true if the configured GPU exposes VirGL 3D capsets for Wayland compositors. */
bool henge_virtio_gpu_supports_virgl(const HengeVirtioGpuConfig *cfg);

#ifdef __cplusplus
}
#endif

#endif /* HENGE_VIRTIO_GPU_H */
