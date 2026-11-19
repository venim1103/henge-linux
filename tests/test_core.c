/* SPDX-License-Identifier: GPL-3.0-or-later */
#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "henge_platform.h"
#include "henge_txm_jit.h"
#include "henge_virtio_gpu.h"

#include <pthread.h>
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

    /* Reject malformed non-UUID container segments under /Containers/Data/Application/. */
    const char *malformed_ios_sandbox =
        "/private/var/mobile/Containers/Data/Application/not-a-valid-uuid/Documents/Machines/ArchLinux";
    HENGE_CHECK(henge_format_unix_socket_path(malformed_ios_sandbox, "share.sock", out, sizeof(out)) == 0);
    HENGE_CHECK(strncmp(out, "/tmp/hl-", 8) == 0);

    /* Reject path separators and traversal components in socket_name. */
    HENGE_CHECK(henge_format_unix_socket_path("/var/tmp/henge", "../evil.sock", out, sizeof(out)) == -1);
    HENGE_CHECK(henge_format_unix_socket_path("/var/tmp/henge", "..", out, sizeof(out)) == -1);
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

    /* Verify CNTVCT_EL0 decoupling from render pause and strict monotonicity across VM clock pause/resume. */
    hengelinux_reset_suspend_counter();
    HENGE_CHECK(hengelinux_suspend_counter_offset() == 0ULL);
    uint64_t t0 = hengelinux_compensated_counter(50000000ULL);
    HENGE_CHECK(t0 == 50000000ULL);

    /* GPU render pause (willResignActive / SafariSheetView) must NOT freeze guest CNTVCT_EL0. */
    hengelinux_set_render_paused(true);
    uint64_t during_ui_overlay = hengelinux_compensated_counter(52000000ULL);
    HENGE_CHECK(during_ui_overlay == 52000000ULL);
    hengelinux_set_render_paused(false);

    /* Explicit VM vCPU clock pause freezes CNTVCT_EL0 and records suspend offset on resume. */
    hengelinux_set_vm_clock_paused(true);
    uint64_t frozen = hengelinux_compensated_counter(80000000ULL);
    struct timespec pause_ts = {0, 2000000L};
    nanosleep(&pause_ts, NULL);
    uint64_t frozen_later = hengelinux_compensated_counter(120000000ULL);
    HENGE_CHECK(frozen == frozen_later);
    HENGE_CHECK(frozen >= during_ui_overlay);
    hengelinux_set_vm_clock_paused(false);

    uint64_t offset_after = hengelinux_suspend_counter_offset();
    HENGE_CHECK(offset_after > 0ULL);
    /* Counter never steps backward even if raw ticks lag behind frozen checkpoint. */
    uint64_t after_resume_clamped = hengelinux_compensated_counter(offset_after + 12345ULL);
    HENGE_CHECK(after_resume_clamped >= frozen);
    uint64_t after_resume_forward = hengelinux_compensated_counter(frozen + offset_after + 50000ULL);
    HENGE_CHECK(after_resume_forward == frozen + 50000ULL);

    /* Unscheduled XNU freezer wall-clock jump (> 500 ms = 12,000,000 ticks) is automatically trimmed. */
    uint64_t jump_raw = frozen + offset_after + 50000ULL + 36000000ULL; /* +1.5s jump */
    uint64_t after_jump = hengelinux_compensated_counter(jump_raw);
    HENGE_CHECK(after_jump == frozen + 50000ULL + 12000000ULL);

    hengelinux_reset_suspend_counter();
    HENGE_CHECK(hengelinux_suspend_counter_offset() == 0ULL);
}

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t  cond;
    size_t          arrived;
    size_t          target;
} PortableBarrier;

typedef struct {
    PortableBarrier *barrier;
    uint64_t         raw_ticks;
    uint64_t         observed_ticks;
} CounterRaceWorkerArg;

static void portable_barrier_wait(PortableBarrier *b) {
    pthread_mutex_lock(&b->lock);
    b->arrived++;
    if (b->arrived >= b->target) {
        pthread_cond_broadcast(&b->cond);
    } else {
        while (b->arrived < b->target) {
            pthread_cond_wait(&b->cond, &b->lock);
        }
    }
    pthread_mutex_unlock(&b->lock);
}

static void *counter_race_worker(void *opaque) {
    CounterRaceWorkerArg *arg = (CounterRaceWorkerArg *)opaque;
    portable_barrier_wait(arg->barrier);
    arg->observed_ticks = hengelinux_compensated_counter(arg->raw_ticks);
    return NULL;
}

static void test_multivcpu_counter_jump_atomicity(void) {
    hengelinux_reset_suspend_counter();
    uint64_t base_raw = 100000000ULL;
    HENGE_CHECK(hengelinux_compensated_counter(base_raw) == base_raw);

    /* Four vCPU threads wake concurrently across a +2.0 s (48,000,000 tick) XNU freeze jump. */
    uint64_t jump_raw = base_raw + 48000000ULL;
    PortableBarrier barrier = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .cond = PTHREAD_COND_INITIALIZER,
        .arrived = 0U,
        .target = 4U,
    };

    pthread_t threads[4];
    CounterRaceWorkerArg args[4];
    for (size_t i = 0; i < 4; i++) {
        args[i].barrier = &barrier;
        args[i].raw_ticks = jump_raw + (uint64_t)i;
        args[i].observed_ticks = 0ULL;
        HENGE_CHECK(pthread_create(&threads[i], NULL, counter_race_worker, &args[i]) == 0);
    }
    for (size_t i = 0; i < 4; i++) {
        HENGE_CHECK(pthread_join(threads[i], NULL) == 0);
        uint64_t expected_min = base_raw + 12000000ULL;
        uint64_t expected_max = base_raw + 12000000ULL + 3ULL;
        HENGE_CHECK(args[i].observed_ticks >= expected_min);
        HENGE_CHECK(args[i].observed_ticks <= expected_max);
    }
    pthread_mutex_destroy(&barrier.lock);
    pthread_cond_destroy(&barrier.cond);
    hengelinux_reset_suspend_counter();
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
    char status_buf[128] = {0};
    henge_jit_copy_status(status_buf, sizeof(status_buf));
    HENGE_CHECK(status_buf[0] != '\0');
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
#endif
    HENGE_CHECK(henge_jit_status_message() != NULL);
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic pop
#endif
    HengeJitPool queried_pool;
    HENGE_CHECK(henge_jit_current_pool(&queried_pool) == false);
    HENGE_CHECK(henge_jit_acquire_pool(0U, true, &queried_pool) == false);
    (void)henge_txm_is_ptraced();
    (void)henge_txm_is_cs_debugged();
}

static void test_virtio_gpu_backends(void) {
    HengeVirtioGpuConfig cfg;
    HENGE_CHECK(henge_virtio_gpu_init_config((HengeGpuBackendMode)99, 128U, &cfg) == -1);
    HENGE_CHECK(henge_virtio_gpu_init_config(HENGE_GPU_BACKEND_GOP_2D, 128U, &cfg) == 0);
    HENGE_CHECK(cfg.pci_vendor_id == 0U);
    HENGE_CHECK(cfg.num_capsets == 0U);
    HENGE_CHECK(henge_virtio_gpu_supports_virgl(&cfg) == false);

    HENGE_CHECK(henge_virtio_gpu_init_config(HENGE_GPU_BACKEND_VIRGL_3D, 512U, &cfg) == 0);
    HENGE_CHECK(cfg.pci_vendor_id == HENGE_VIRTIO_PCI_VENDOR_ID);
    HENGE_CHECK(cfg.pci_device_id == HENGE_VIRTIO_GPU_DEVICE_ID);
    HENGE_CHECK(cfg.num_capsets == 2U);
    HENGE_CHECK(henge_virtio_gpu_supports_virgl(&cfg) == true);
    (void)henge_virtio_gpu_has_virglrenderer();

    HengeVirtioGpuDevice *gpu = henge_virtio_gpu_create(&cfg);
    HENGE_CHECK(gpu != NULL);
    HENGE_CHECK((henge_virtio_gpu_feature_bits(gpu) & HENGE_VIRTIO_GPU_F_VIRGL) != 0ULL);
    HENGE_CHECK(henge_virtio_gpu_set_display_mode(gpu, 0U, 2556U, 1179U, true) == 0);

    /* Reject 3D commands referencing nonexistent context or resource IDs. */
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_SUBMIT_3D, 99U, 0U, 0U, 0U, 0U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT);
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_FLUSH, 0U, 77U, 0U, 0U, 0U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE);

    /* Exercise full VirGL 3D context -> 3D resource -> attach -> submit -> scanout -> flush lifecycle. */
    uint32_t virgl_cmd_stream[4] = {0x00010001U, 0x00000000U, 1920U, 1080U};
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_CTX_CREATE, 1U, 0U, 0U, 0U, 0U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_active_contexts(gpu) == 1U);

    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_3D, 1U, 10U, 0U, 1920U, 1080U, 1U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_active_resources(gpu) == 1U);

    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE, 1U, 10U, 0U, 0U, 0U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_context_attached_resources(gpu, 1U) == 1U);

    /* Duplicate attach on same context is idempotent; attaching a second Wayland context tracks both. */
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE, 1U, 10U, 0U, 0U, 0U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_context_attached_resources(gpu, 1U) == 1U);

    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_CTX_CREATE, 2U, 0U, 0U, 0U, 0U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE, 2U, 10U, 0U, 0U, 0U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_context_attached_resources(gpu, 2U) == 1U);

    /* Detaching context 2 leaves context 1 attached; unref clears remaining context counts. */
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_CTX_DETACH_RESOURCE, 2U, 10U, 0U, 0U, 0U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_context_attached_resources(gpu, 2U) == 0U);
    HENGE_CHECK(henge_virtio_gpu_context_attached_resources(gpu, 1U) == 1U);
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_SUBMIT_3D, 1U, 10U, 0U, 0U, 0U, 0U,
        virgl_cmd_stream, sizeof(virgl_cmd_stream)) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_SET_SCANOUT, 1U, 10U, 0U, 1920U, 1080U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_scanout_resource(gpu, 0U) == 10U);
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_FLUSH, 1U, 10U, 0U, 1920U, 1080U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_flush_count(gpu) == 1ULL);

    /* Verify checksummed background VM snapshot persistence and corruption rejection. */
    const char *snap_path = "build/test_suspend.state";
    const char payload[] = "ARCHLINUX_VIRGL_WAYLAND_STATE";
    HengeVmSnapshotInfo snap_in = {
        .version = 1U,
        .ram_mib = 2560U,
        .cpu_count = 4U,
        .gpu_mode = (uint32_t)HENGE_GPU_BACKEND_VIRGL_3D,
        .scanout0_res_id = 10U,
        .suspend_counter_offset = 48000000ULL,
        .gpu_flush_count = henge_virtio_gpu_flush_count(gpu),
    };
    HENGE_CHECK(henge_vm_snapshot_write(snap_path, &snap_in, payload, sizeof(payload)) == 0);

    HengeVmSnapshotInfo snap_out;
    char read_payload[64] = {0};
    HENGE_CHECK(henge_vm_snapshot_read(snap_path, &snap_out, read_payload, sizeof(read_payload)) == 0);
    HENGE_CHECK(snap_out.ram_mib == 2560U);
    HENGE_CHECK(snap_out.gpu_mode == (uint32_t)HENGE_GPU_BACKEND_VIRGL_3D);
    HENGE_CHECK(snap_out.scanout0_res_id == 10U);
    HENGE_CHECK(snap_out.gpu_flush_count == 1ULL);
    HENGE_CHECK(strcmp(read_payload, payload) == 0);

    /* Bit-flip corruption check: FNV-1a checksum validation must reject tampered snapshots. */
    FILE *corrupt_fp = fopen(snap_path, "r+b");
    HENGE_CHECK(corrupt_fp != NULL);
    HENGE_CHECK(fseek(corrupt_fp, 16L, SEEK_SET) == 0);
    int orig_byte = fgetc(corrupt_fp);
    HENGE_CHECK(orig_byte != EOF);
    HENGE_CHECK(fseek(corrupt_fp, 16L, SEEK_SET) == 0);
    HENGE_CHECK(fputc(orig_byte ^ 0x5A, corrupt_fp) != EOF);
    HENGE_CHECK(fclose(corrupt_fp) == 0);
    HENGE_CHECK(henge_vm_snapshot_read(snap_path, &snap_out, read_payload, sizeof(read_payload)) == -1);
    remove(snap_path);

    HENGE_CHECK(henge_virtio_gpu_is_virgl_ready(gpu));

    /* Unreferencing resource 10 decrements context 1's attached_resources counter to 0. */
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_UNREF, 0U, 10U, 0U, 0U, 0U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_context_attached_resources(gpu, 1U) == 0U);
    HENGE_CHECK(henge_virtio_gpu_scanout_resource(gpu, 0U) == 0U);

    henge_virtio_gpu_destroy(gpu);
}

static void test_console_log_capture(void) {
    const char *log_path = "build/test_console.log";
    remove(log_path);
    HENGE_CHECK(hengelinux_start_console_capture(log_path) == 0);
    hengelinux_clear_console_log();

    hengelinux_console_append_line("[test] console marker line 1");
    fprintf(stderr, "[test] stderr serial line 2\n");
    fflush(stderr);

    struct timespec ts = {0, 20000000L}; /* 20 ms for reader thread */
    nanosleep(&ts, NULL);

    HENGE_CHECK(hengelinux_console_total_bytes() > 0ULL);
    char buf[1024] = {0};
    size_t n = hengelinux_copy_console_log(buf, sizeof(buf));
    HENGE_CHECK(n > 0U);
    HENGE_CHECK(strstr(buf, "[test] console marker line 1") != NULL);
    HENGE_CHECK(strstr(buf, "[test] stderr serial line 2") != NULL);

    hengelinux_reset_guest_hid_bridge_ready();
    HENGE_CHECK(!hengelinux_is_guest_hid_bridge_ready());
    hengelinux_console_append_line("\x1b]9998;HENGE_HID_READY\x07");
    HENGE_CHECK(hengelinux_is_guest_hid_bridge_ready());
    hengelinux_reset_guest_hid_bridge_ready();
    HENGE_CHECK(!hengelinux_is_guest_hid_bridge_ready());

    hengelinux_clear_console_log();
    remove(log_path);
}

int main(void) {
    test_unix_socket_path_bounds();
    test_mmu_granule_decoding();
    test_guest_ram_alignment();
    test_render_pause_lifecycle_gate();
    test_multivcpu_counter_jump_atomicity();
    test_txm_jit_bounds_and_blessing();
    test_virtio_gpu_backends();
    test_console_log_capture();
    printf("[PASS] test_core: all platform, MMU, RAM, lifecycle, TXM JIT, VirtIO-GPU, and console checks passed.\n");
    return 0;
}
