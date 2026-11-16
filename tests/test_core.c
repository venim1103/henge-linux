/* SPDX-License-Identifier: GPL-3.0-or-later */
#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "henge_platform.h"
#include "henge_txm_jit.h"
#include "henge_virtio_gpu.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define HENGE_CHECK(expr)                                                                 \
    do {                                                                                  \
        if (!(expr)) {                                                                    \
            fprintf(stderr, "[FAIL] %s:%d: %s\n", __FILE__, __LINE__, #expr);             \
            abort();                                                                      \
        }                                                                                 \
    } while (0)

static void test_unix_socket_path_bounds(void) {
    char out[HENGE_DARWIN_SUN_PATH_MAX];

    /* Root directory avoids double-slash prefix. */
    int rc = henge_format_unix_socket_path("/", "henge.sock", out, sizeof(out));
    HENGE_CHECK(rc == 0);
    HENGE_CHECK(strcmp(out, "/henge.sock") == 0);

    /* Short path fits directly within Darwin's 104-byte sockaddr_un.sun_path. */
    rc = henge_format_unix_socket_path("/var/tmp/henge", "share.sock", out, sizeof(out));
    HENGE_CHECK(rc == 0);
    HENGE_CHECK(strcmp(out, "/var/tmp/henge/share.sock") == 0);
    HENGE_CHECK(strlen(out) < HENGE_DARWIN_SUN_PATH_MAX);

    /* Deep iOS sandbox path (>104 bytes) normalizes /private/var -> /var/<UUID>/tmp/. */
    const char *deep_ios_sandbox =
        "/private/var/mobile/Containers/Data/Application/12345678-90AB-CDEF-1234-567890ABCDEF/Documents/Machines/ArchLinux";
    HENGE_CHECK(strlen(deep_ios_sandbox) >= HENGE_DARWIN_SUN_PATH_MAX);

    rc = henge_format_unix_socket_path(deep_ios_sandbox, "share.sock", out, sizeof(out));
    HENGE_CHECK(rc == 0);
    HENGE_CHECK(strlen(out) < HENGE_DARWIN_SUN_PATH_MAX);
    HENGE_CHECK(strcmp(out, "/var/mobile/Containers/Data/Application/12345678-90AB-CDEF-1234-567890ABCDEF/tmp/share.sock") == 0);

    /* Non-iOS deep host path falls back to deterministic /tmp/hl-<hash>-<name>. */
    const char *deep_host_path =
        "/Users/developer/workspace/nested/extremely/long/directory/hierarchy/for/virtual/machines/ArchLinux/instance-01";
    HENGE_CHECK(strlen(deep_host_path) >= HENGE_DARWIN_SUN_PATH_MAX);
    rc = henge_format_unix_socket_path(deep_host_path, "share.sock", out, sizeof(out));
    HENGE_CHECK(rc == 0);
    HENGE_CHECK(strlen(out) < HENGE_DARWIN_SUN_PATH_MAX);
    HENGE_CHECK(strncmp(out, "/tmp/hl-", 8) == 0);
}

static void test_mmu_granule_decoding(void) {
    /* TTBR0 encodings */
    HENGE_CHECK(henge_decode_granule_bits(0x0U, 0) == 12U); /* 4 KiB */
    HENGE_CHECK(henge_decode_granule_bits(0x2U, 0) == 14U); /* 16 KiB */
    HENGE_CHECK(henge_decode_granule_bits(0x1U, 0) == 16U); /* 64 KiB */
    HENGE_CHECK(henge_decode_granule_bits(0x3U, 0) == 0U);  /* Reserved */

    /* TTBR1 encodings */
    HENGE_CHECK(henge_decode_granule_bits(0x2U, 1) == 12U); /* 4 KiB */
    HENGE_CHECK(henge_decode_granule_bits(0x1U, 1) == 14U); /* 16 KiB */
    HENGE_CHECK(henge_decode_granule_bits(0x3U, 1) == 16U); /* 64 KiB */
    HENGE_CHECK(henge_decode_granule_bits(0x0U, 1) == 0U);  /* Reserved */
}

static void test_guest_ram_alignment(void) {
    /* iPhone 16 Pro (8 GB device cap -> 4096 MiB ceiling, 2560 MiB requested). */
    uint64_t bytes = henge_align_guest_ram_bytes(2560U, 4096U);
    HENGE_CHECK(bytes == (2560ULL * 1024ULL * 1024ULL));
    HENGE_CHECK((bytes & (HENGE_HOST_PAGE_SIZE - 1ULL)) == 0ULL);

    /* Clamping above device cap. */
    uint64_t clamped = henge_align_guest_ram_bytes(6144U, 3072U);
    HENGE_CHECK(clamped == (3072ULL * 1024ULL * 1024ULL));

    /* Clamping below minimum floor. */
    uint64_t floored = henge_align_guest_ram_bytes(128U, 4096U);
    HENGE_CHECK(floored == (512ULL * 1024ULL * 1024ULL));
}

static void test_render_pause_lifecycle_gate(void) {
    HENGE_CHECK(hengelinux_is_render_paused() == false);
    hengelinux_render_lock();
    HENGE_CHECK(hengelinux_is_render_paused() == false);
    hengelinux_render_unlock();

    hengelinux_set_render_paused(true);
    HENGE_CHECK(hengelinux_is_render_paused() == true);
    hengelinux_set_render_paused(false);
    HENGE_CHECK(hengelinux_is_render_paused() == false);

    /* Verify CNTVCT_EL0 suspend offset compensation across pause/resume cycles. */
    hengelinux_reset_suspend_counter();
    HENGE_CHECK(hengelinux_suspend_counter_offset() == 0ULL);
    HENGE_CHECK(hengelinux_compensated_counter(50000000ULL) == 50000000ULL);

    hengelinux_set_render_paused(true);
    uint64_t frozen = hengelinux_compensated_counter(80000000ULL);
    struct timespec pause_ts = {0, 2000000L};
    nanosleep(&pause_ts, NULL);
    uint64_t frozen_later = hengelinux_compensated_counter(120000000ULL);
    HENGE_CHECK(frozen == frozen_later);
    hengelinux_set_render_paused(false);

    uint64_t offset_after = hengelinux_suspend_counter_offset();
    HENGE_CHECK(offset_after > 0ULL);
    HENGE_CHECK(hengelinux_compensated_counter(offset_after + 12345ULL) == 12345ULL);
    HENGE_CHECK(hengelinux_compensated_counter(0ULL) == 0ULL);
    hengelinux_reset_suspend_counter();
    HENGE_CHECK(hengelinux_suspend_counter_offset() == 0ULL);
}

static void test_txm_jit_bounds_and_blessing(void) {
    /* Valid 384 MiB TXM range in [4 GiB, 64 GiB). */
    HENGE_CHECK(henge_txm_is_valid_jit_range(0x0180000000ULL, HENGE_DEFAULT_JIT_POOL_BYTES) == true);

    /* Reject addresses below 4 GiB, >= 64 GiB, >= 0x7000000000, or unaligned to 16 KiB. */
    HENGE_CHECK(henge_txm_is_valid_jit_range(0x0080000000ULL, HENGE_DEFAULT_JIT_POOL_BYTES) == false);
    HENGE_CHECK(henge_txm_is_valid_jit_range(0x1000000000ULL, HENGE_DEFAULT_JIT_POOL_BYTES) == false);
    HENGE_CHECK(henge_txm_is_valid_jit_range(0x7000000000ULL, HENGE_DEFAULT_JIT_POOL_BYTES) == false);
    HENGE_CHECK(henge_txm_is_valid_jit_range(0x0180001000ULL, HENGE_DEFAULT_JIT_POOL_BYTES) == false);

    /* Stamp and verify 0x69 byte-0 marker across 4 x 16 KiB pages. */
    size_t test_pool_size = 4U * (size_t)HENGE_HOST_PAGE_SIZE;
    uint8_t *buf = calloc(1U, test_pool_size);
    HENGE_CHECK(buf != NULL);
    HENGE_CHECK(henge_txm_verify_blessing_markers(buf, test_pool_size) == false);
    HENGE_CHECK(henge_txm_stamp_blessing_markers(buf, test_pool_size) == 0);
    HENGE_CHECK(henge_txm_verify_blessing_markers(buf, test_pool_size) == true);
    free(buf);

    /* Verify page-aligned guest RAM allocator/deallocator round-trip. */
    bool ledger_exempt = true;
    void *ram = henge_alloc_ledger_exempt_ram(test_pool_size, &ledger_exempt);
    HENGE_CHECK(ram != NULL);
    ((uint8_t *)ram)[0] = 0xAAU;
    ((uint8_t *)ram)[test_pool_size - 1U] = 0x55U;
    henge_free_ledger_exempt_ram(ram, test_pool_size);
    HENGE_CHECK(henge_jit_status_message() != NULL);
    HengeJitPool queried_pool;
    HENGE_CHECK(henge_jit_current_pool(&queried_pool) == false);
    HENGE_CHECK(henge_jit_acquire_pool(0U, true, &queried_pool) == false);
    (void)henge_txm_is_ptraced();
    (void)henge_txm_is_cs_debugged();
}

static void test_virtio_gpu_backends(void) {
    HengeVirtioGpuConfig cfg;
    HENGE_CHECK(henge_virtio_gpu_init_config(HENGE_GPU_BACKEND_GOP_2D, 128U, &cfg) == 0);
    HENGE_CHECK(henge_virtio_gpu_supports_virgl(&cfg) == false);

    HENGE_CHECK(henge_virtio_gpu_init_config(HENGE_GPU_BACKEND_VIRGL_3D, 512U, &cfg) == 0);
    HENGE_CHECK(cfg.pci_vendor_id == HENGE_VIRTIO_PCI_VENDOR_ID);
    HENGE_CHECK(cfg.pci_device_id == HENGE_VIRTIO_GPU_DEVICE_ID);
    HENGE_CHECK(henge_virtio_gpu_supports_virgl(&cfg) == true);
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
