/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "henge_platform.h"
#include "henge_txm_jit.h"
#include "henge_virtio_gpu.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void test_unix_socket_path_bounds(void) {
    char out[HENGE_DARWIN_SUN_PATH_MAX];

    /* Root directory avoids double-slash prefix. */
    int rc = henge_format_unix_socket_path("/", "henge.sock", out, sizeof(out));
    assert(rc == 0);
    assert(strcmp(out, "/henge.sock") == 0);

    /* Short path fits directly within Darwin's 104-byte sockaddr_un.sun_path. */
    rc = henge_format_unix_socket_path("/var/tmp/henge", "share.sock", out, sizeof(out));
    assert(rc == 0);
    assert(strcmp(out, "/var/tmp/henge/share.sock") == 0);
    assert(strlen(out) < HENGE_DARWIN_SUN_PATH_MAX);

    /* Deep iOS sandbox path (>104 bytes) normalizes /private/var -> /var/<UUID>/tmp/. */
    const char *deep_ios_sandbox =
        "/private/var/mobile/Containers/Data/Application/12345678-90AB-CDEF-1234-567890ABCDEF/Documents/Machines/ArchLinux";
    assert(strlen(deep_ios_sandbox) >= HENGE_DARWIN_SUN_PATH_MAX);

    rc = henge_format_unix_socket_path(deep_ios_sandbox, "share.sock", out, sizeof(out));
    assert(rc == 0);
    assert(strlen(out) < HENGE_DARWIN_SUN_PATH_MAX);
    assert(strcmp(out, "/var/mobile/Containers/Data/Application/12345678-90AB-CDEF-1234-567890ABCDEF/tmp/share.sock") == 0);

    /* Non-iOS deep host path falls back to deterministic /tmp/hl-<hash>-<name>. */
    const char *deep_host_path =
        "/Users/developer/workspace/nested/extremely/long/directory/hierarchy/for/virtual/machines/ArchLinux/instance-01";
    assert(strlen(deep_host_path) >= HENGE_DARWIN_SUN_PATH_MAX);
    rc = henge_format_unix_socket_path(deep_host_path, "share.sock", out, sizeof(out));
    assert(rc == 0);
    assert(strlen(out) < HENGE_DARWIN_SUN_PATH_MAX);
    assert(strncmp(out, "/tmp/hl-", 8) == 0);
}

static void test_mmu_granule_decoding(void) {
    /* TTBR0 encodings */
    assert(henge_decode_granule_bits(0x0U, 0) == 12U); /* 4 KiB */
    assert(henge_decode_granule_bits(0x2U, 0) == 14U); /* 16 KiB */
    assert(henge_decode_granule_bits(0x1U, 0) == 16U); /* 64 KiB */
    assert(henge_decode_granule_bits(0x3U, 0) == 0U);  /* Reserved */

    /* TTBR1 encodings */
    assert(henge_decode_granule_bits(0x2U, 1) == 12U); /* 4 KiB */
    assert(henge_decode_granule_bits(0x1U, 1) == 14U); /* 16 KiB */
    assert(henge_decode_granule_bits(0x3U, 1) == 16U); /* 64 KiB */
    assert(henge_decode_granule_bits(0x0U, 1) == 0U);  /* Reserved */
}

static void test_guest_ram_alignment(void) {
    /* iPhone 16 Pro (8 GB device cap -> 4096 MiB ceiling, 2560 MiB requested). */
    uint64_t bytes = henge_align_guest_ram_bytes(2560U, 4096U);
    assert(bytes == (2560ULL * 1024ULL * 1024ULL));
    assert((bytes & (HENGE_HOST_PAGE_SIZE - 1ULL)) == 0ULL);

    /* Clamping above device cap. */
    uint64_t clamped = henge_align_guest_ram_bytes(6144U, 3072U);
    assert(clamped == (3072ULL * 1024ULL * 1024ULL));

    /* Clamping below minimum floor. */
    uint64_t floored = henge_align_guest_ram_bytes(128U, 4096U);
    assert(floored == (512ULL * 1024ULL * 1024ULL));
}

static void test_render_pause_lifecycle_gate(void) {
    assert(hengelinux_is_render_paused() == false);
    hengelinux_render_lock();
    assert(hengelinux_is_render_paused() == false);
    hengelinux_render_unlock();

    hengelinux_set_render_paused(true);
    assert(hengelinux_is_render_paused() == true);
    hengelinux_set_render_paused(false);
    assert(hengelinux_is_render_paused() == false);
}

static void test_txm_jit_bounds_and_blessing(void) {
    /* Valid 384 MiB TXM range in [4 GiB, 64 GiB). */
    assert(henge_txm_is_valid_jit_range(0x0180000000ULL, HENGE_DEFAULT_JIT_POOL_BYTES) == true);

    /* Reject addresses below 4 GiB, >= 64 GiB, >= 0x7000000000, or unaligned to 16 KiB. */
    assert(henge_txm_is_valid_jit_range(0x0080000000ULL, HENGE_DEFAULT_JIT_POOL_BYTES) == false);
    assert(henge_txm_is_valid_jit_range(0x1000000000ULL, HENGE_DEFAULT_JIT_POOL_BYTES) == false);
    assert(henge_txm_is_valid_jit_range(0x7000000000ULL, HENGE_DEFAULT_JIT_POOL_BYTES) == false);
    assert(henge_txm_is_valid_jit_range(0x0180001000ULL, HENGE_DEFAULT_JIT_POOL_BYTES) == false);

    /* Stamp and verify 0x69 byte-0 marker across 4 x 16 KiB pages. */
    size_t test_pool_size = 4U * (size_t)HENGE_HOST_PAGE_SIZE;
    uint8_t *buf = calloc(1U, test_pool_size);
    assert(buf != NULL);
    assert(henge_txm_verify_blessing_markers(buf, test_pool_size) == false);
    assert(henge_txm_stamp_blessing_markers(buf, test_pool_size) == 0);
    assert(henge_txm_verify_blessing_markers(buf, test_pool_size) == true);
    free(buf);

    /* Verify page-aligned guest RAM allocator/deallocator round-trip. */
    bool ledger_exempt = true;
    void *ram = henge_alloc_ledger_exempt_ram(test_pool_size, &ledger_exempt);
    assert(ram != NULL);
    ((uint8_t *)ram)[0] = 0xAAU;
    ((uint8_t *)ram)[test_pool_size - 1U] = 0x55U;
    henge_free_ledger_exempt_ram(ram, test_pool_size);
    (void)henge_txm_is_ptraced();
    (void)henge_txm_is_cs_debugged();
}

static void test_virtio_gpu_backends(void) {
    HengeVirtioGpuConfig cfg;
    assert(henge_virtio_gpu_init_config(HENGE_GPU_BACKEND_GOP_2D, 128U, &cfg) == 0);
    assert(henge_virtio_gpu_supports_virgl(&cfg) == false);

    assert(henge_virtio_gpu_init_config(HENGE_GPU_BACKEND_VIRGL_3D, 512U, &cfg) == 0);
    assert(cfg.pci_vendor_id == HENGE_VIRTIO_PCI_VENDOR_ID);
    assert(cfg.pci_device_id == HENGE_VIRTIO_GPU_DEVICE_ID);
    assert(henge_virtio_gpu_supports_virgl(&cfg) == true);
}

int main(void) {
    test_unix_socket_path_bounds();
    test_mmu_granule_decoding();
    test_guest_ram_alignment();
    test_render_pause_lifecycle_gate();
    test_txm_jit_bounds_and_blessing();
    test_virtio_gpu_backends();
    printf("[PASS] test_core: all platform, MMU, RAM, lifecycle, TXM JIT, and VirtIO-GPU checks passed.\n");
    return 0;
}
