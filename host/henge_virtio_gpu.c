/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "henge_virtio_gpu.h"

#include <stddef.h>

int henge_virtio_gpu_init_config(HengeGpuBackendMode mode,
                                 uint32_t vram_mib,
                                 HengeVirtioGpuConfig *out_cfg) {
    if (out_cfg == NULL) {
        return -1;
    }
    if (vram_mib < 64U || vram_mib > 2048U) {
        return -1;
    }

    out_cfg->mode = mode;
    out_cfg->pci_vendor_id = HENGE_VIRTIO_PCI_VENDOR_ID;
    out_cfg->pci_device_id = HENGE_VIRTIO_GPU_DEVICE_ID;
    out_cfg->max_scanouts = 2U; /* Primary display + USB-C external monitor */
    out_cfg->vram_mib = vram_mib;

    if (mode == HENGE_GPU_BACKEND_VIRGL_3D) {
        out_cfg->capset_mask = (1U << HENGE_VIRTIO_GPU_CAPSET_VIRGL) |
                               (1U << HENGE_VIRTIO_GPU_CAPSET_VIRGL2);
        out_cfg->angle_metal_enabled = true;
    } else {
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
    return (cfg->capset_mask & required) == required && cfg->angle_metal_enabled;
}
