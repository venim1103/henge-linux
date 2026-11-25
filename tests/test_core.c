/* SPDX-License-Identifier: GPL-3.0-or-later */
#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "henge_platform.h"
#include "henge_txm_jit.h"
#include "henge_gpu_surface.h"
#include "henge_virtio_gpu.h"
#include "henge_virgl_worker.h"
#include "henge_qcow2.h"
#include "henge_cidata.h"

#include <zlib.h>
#if defined(HENGE_HAVE_ZSTD)
#include <zstd.h>
#endif

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

    /* Dual-mode JIT policy overrides and adaptive pool/RAM sizing checks. */
    HENGE_CHECK(henge_jit_get_policy() == HENGE_JIT_POLICY_AUTO);
    henge_jit_set_policy(HENGE_JIT_POLICY_FORCE_CLASSIC);
    HENGE_CHECK(henge_jit_detect_mode() == HENGE_JIT_MODE_CLASSIC);
    HENGE_CHECK(henge_jit_requires_txm_low_va() == false);
    henge_jit_set_policy(HENGE_JIT_POLICY_FORCE_TXM);
    HENGE_CHECK(henge_jit_detect_mode() == HENGE_JIT_MODE_TXM_BROKER);
    HENGE_CHECK(henge_jit_requires_txm_low_va() == true);
    henge_jit_set_policy(HENGE_JIT_POLICY_AUTO);
    HENGE_CHECK(henge_recommended_jit_pool_bytes() >= HENGE_MIN_JIT_POOL_BYTES);
    HENGE_CHECK(henge_recommended_guest_ram_mib(henge_recommended_jit_pool_bytes()) >= HENGE_MIN_GUEST_RAM_MIB);

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

    /* Milestone 6.5 (Phase E): verify 2D KMS backing, RGBA->BGRA dirty-rect transfer, and EDID 1.4. */
    HENGE_CHECK(henge_virtio_gpu_set_display_mode(gpu, 0U, 1280U, 800U, true) == 0);
    uint32_t disp_w = 0U, disp_h = 0U;
    bool disp_en = false;
    HENGE_CHECK(henge_virtio_gpu_get_display_info(gpu, 0U, &disp_w, &disp_h, &disp_en) == 0);
    HENGE_CHECK(disp_w == 1280U && disp_h == 800U && disp_en);

    uint8_t edid[128];
    HENGE_CHECK(henge_virtio_gpu_get_edid(gpu, 0U, edid) == 0);
    HENGE_CHECK(edid[0] == 0x00U && edid[1] == 0xFFU && edid[7] == 0x00U);
    HENGE_CHECK(edid[18] == 0x01U && edid[19] == 0x04U);
    uint8_t edid_sum = 0U;
    for (size_t i = 0U; i < 128U; i++) {
        edid_sum = (uint8_t)(edid_sum + edid[i]);
    }
    HENGE_CHECK(edid_sum == 0U);

    /* Create 4x4 2D RGBA resource, attach split 2-segment scatter-gather backing, and blit 2x2 rect. */
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_2D, 0U, 20U, 0U, 4U, 4U,
        HENGE_VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM, NULL, 0U) == HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    uint8_t seg0[32];
    uint8_t seg1[32];
    memset(seg0, 0, sizeof(seg0));
    memset(seg1, 0, sizeof(seg1));
    /* Pixel (1,1) in RGBA = (0x11, 0x22, 0x33, 0xFF) at byte offset 1*16 + 1*4 = 20 (in seg0) */
    seg0[20] = 0x11U; seg0[21] = 0x22U; seg0[22] = 0x33U; seg0[23] = 0xFFU;
    /* Pixel (2,2) in RGBA = (0xAA, 0xBB, 0xCC, 0xEE) at byte offset 2*16 + 2*4 = 40 (seg1 offset 8) */
    seg1[8] = 0xAAU; seg1[9] = 0xBBU; seg1[10] = 0xCCU; seg1[11] = 0xEEU;
    HengeGpuBackingEntry backing[2] = {
        { .host_ptr = seg0, .guest_addr = 0x40000000ULL, .length = sizeof(seg0), .reserved = 0U },
        { .host_ptr = seg1, .guest_addr = 0x40001000ULL, .length = sizeof(seg1), .reserved = 0U },
    };
    HENGE_CHECK(henge_virtio_gpu_attach_backing(gpu, 20U, backing, 2U) == 0);
    HENGE_CHECK(henge_virtio_gpu_transfer_to_host_2d(gpu, 20U, 1U, 1U, 2U, 2U, 20ULL) == 0);
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_SET_SCANOUT, 0U, 20U, 0U, 4U, 4U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    const uint8_t *scan_px = NULL;
    uint32_t scan_w = 0U, scan_h = 0U, scan_stride = 0U;
    HENGE_CHECK(henge_virtio_gpu_get_scanout_frame(gpu, 0U, &scan_px, &scan_w, &scan_h, &scan_stride) == 0);
    HENGE_CHECK(scan_px != NULL && scan_w == 4U && scan_h == 4U && scan_stride == 16U);
    /* Verify RGBA -> BGRA swizzle at (1,1) and (2,2) */
    HENGE_CHECK(scan_px[20] == 0x33U && scan_px[21] == 0x22U && scan_px[22] == 0x11U && scan_px[23] == 0xFFU);
    HENGE_CHECK(scan_px[40] == 0xCCU && scan_px[41] == 0xBBU && scan_px[42] == 0xAAU && scan_px[43] == 0xEEU);

    /* Sub-rect SET_SCANOUT (4x2 on 4x4 resource) must crop scanout frame without overwriting GET_DISPLAY_INFO. */
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_SET_SCANOUT, 0U, 20U, 0U, 4U, 2U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_get_display_info(gpu, 0U, &disp_w, &disp_h, &disp_en) == 0);
    HENGE_CHECK(disp_w == 1280U && disp_h == 800U && disp_en);
    HENGE_CHECK(henge_virtio_gpu_get_scanout_frame(gpu, 0U, &scan_px, &scan_w, &scan_h, &scan_stride) == 0);
    HENGE_CHECK(scan_px != NULL && scan_w == 4U && scan_h == 2U && scan_stride == 16U);
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_SET_SCANOUT, 0U, 20U, 0U, 4U, 4U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_get_scanout_frame(gpu, 0U, &scan_px, &scan_w, &scan_h, &scan_stride) == 0);
    HENGE_CHECK(scan_px != NULL && scan_w == 4U && scan_h == 4U && scan_stride == 16U);

    /* Verify dirty-rect accumulation, unioning, consume-and-clear, and SET_SCANOUT full-dirty flag. */
    HengeGpuDirtyRect dirty;
    HENGE_CHECK(henge_virtio_gpu_consume_scanout_dirty(gpu, 0U, &dirty) == 0);
    HENGE_CHECK(dirty.valid && dirty.full && dirty.x == 0U && dirty.y == 0U &&
                dirty.width == 4U && dirty.height == 4U);
    /* Second consume without new transfers reports clean (no upload needed). */
    HENGE_CHECK(henge_virtio_gpu_consume_scanout_dirty(gpu, 0U, &dirty) == 0);
    HENGE_CHECK(!dirty.valid && !dirty.full && dirty.width == 0U && dirty.height == 0U);
    /* Two disjoint TRANSFER_TO_HOST_2D calls union into minimal bounding box (0,0)-(3,3). */
    HENGE_CHECK(henge_virtio_gpu_transfer_to_host_2d(gpu, 20U, 0U, 0U, 1U, 1U, 0ULL) == 0);
    HENGE_CHECK(henge_virtio_gpu_transfer_to_host_2d(gpu, 20U, 2U, 2U, 1U, 1U, 40ULL) == 0);
    HENGE_CHECK(henge_virtio_gpu_consume_scanout_dirty(gpu, 0U, &dirty) == 0);
    HENGE_CHECK(dirty.valid && !dirty.full && dirty.x == 0U && dirty.y == 0U &&
                dirty.width == 3U && dirty.height == 3U);

    /* Verify Metal hardware cursor state export (zero CPU compositing into scanout pixels,
     * texture_gen increments only on UPDATE_CURSOR/transfer, position_gen increments on MOVE_CURSOR). */
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_2D, 0U, 21U, 0U, 2U, 2U,
        HENGE_VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM, NULL, 0U) == HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    uint8_t cur_px[16];
    memset(cur_px, 0, sizeof(cur_px));
    /* Cursor (0,0) = opaque white BGRA(FF,FF,FF,FF) */
    cur_px[0] = 0xFFU; cur_px[1] = 0xFFU; cur_px[2] = 0xFFU; cur_px[3] = 0xFFU;
    HengeGpuBackingEntry cur_backing = {
        .host_ptr = cur_px, .guest_addr = 0x40002000ULL, .length = sizeof(cur_px), .reserved = 0U
    };
    HENGE_CHECK(henge_virtio_gpu_attach_backing(gpu, 21U, &cur_backing, 1U) == 0);
    HENGE_CHECK(henge_virtio_gpu_transfer_to_host_2d(gpu, 21U, 0U, 0U, 2U, 2U, 0ULL) == 0);
    HENGE_CHECK(henge_virtio_gpu_update_cursor(gpu, 0U, 21U, 10U, 20U, 1U, 2U, false) == 0);
    HENGE_CHECK(henge_virtio_gpu_get_scanout_frame(gpu, 0U, &scan_px, &scan_w, &scan_h, &scan_stride) == 0);
    /* Scanout pixel (0,0) remains raw (0x00) because cursor compositing happens on Metal GPU. */
    HENGE_CHECK(scan_px[0] == 0x00U);
    HengeGpuCursorState cur_state;
    HENGE_CHECK(henge_virtio_gpu_get_cursor_state(gpu, 0U, &cur_state) == 0);
    HENGE_CHECK(cur_state.visible && cur_state.resource_id == 21U && cur_state.pixels != NULL);
    HENGE_CHECK(cur_state.width == 2U && cur_state.height == 2U && cur_state.stride == 8U);
    HENGE_CHECK(cur_state.x == 10 && cur_state.y == 20 && cur_state.hot_x == 1 && cur_state.hot_y == 2);
    HENGE_CHECK(cur_state.pixels[0] == 0xFFU && cur_state.pixels[3] == 0xFFU);
    uint64_t tex_gen_after_update = cur_state.texture_gen;
    uint64_t pos_gen_after_update = cur_state.position_gen;
    /* MOVE_CURSOR updates coordinates and position_gen without bumping texture_gen. */
    HENGE_CHECK(henge_virtio_gpu_update_cursor(gpu, 0U, 0U, 42U, 84U, 0U, 0U, true) == 0);
    HENGE_CHECK(henge_virtio_gpu_get_cursor_state(gpu, 0U, &cur_state) == 0);
    HENGE_CHECK(cur_state.visible && cur_state.resource_id == 21U);
    HENGE_CHECK(cur_state.x == 42 && cur_state.y == 84 && cur_state.hot_x == 1 && cur_state.hot_y == 2);
    HENGE_CHECK(cur_state.texture_gen == tex_gen_after_update);
    HENGE_CHECK(cur_state.position_gen == pos_gen_after_update + 1ULL);
    /* Hide cursor via UPDATE_CURSOR(resource_id = 0). */
    HENGE_CHECK(henge_virtio_gpu_update_cursor(gpu, 0U, 0U, 0U, 0U, 0U, 0U, false) == 0);
    HENGE_CHECK(henge_virtio_gpu_get_cursor_state(gpu, 0U, &cur_state) == 0);
    HENGE_CHECK(!cur_state.visible && cur_state.resource_id == 0U && cur_state.pixels == NULL);
    HENGE_CHECK(cur_state.texture_gen == tex_gen_after_update + 1ULL);

    /* Verify unified GPU config inspection and independent display presentation pause gate. */
    HengeVirtioGpuConfig live_cfg;
    HENGE_CHECK(henge_virtio_gpu_get_config(gpu, &live_cfg) == 0);
    HENGE_CHECK(live_cfg.mode == HENGE_GPU_BACKEND_VIRGL_3D && live_cfg.vram_mib == 512U);
    hengelinux_set_render_paused(false);
    hengelinux_set_display_presentation_paused(true);
    HENGE_CHECK(hengelinux_is_display_presentation_paused());
    HENGE_CHECK(!hengelinux_is_render_paused());
    hengelinux_set_display_presentation_paused(false);
    HENGE_CHECK(!hengelinux_is_display_presentation_paused());

    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_UNREF, 0U, 21U, 0U, 0U, 0U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_UNREF, 0U, 20U, 0U, 0U, 0U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_get_scanout_frame(gpu, 0U, &scan_px, &scan_w, &scan_h, &scan_stride) == -1);

    /* Simulate UEFI VirtioGpuDxe -> Linux virtio-gpu status=0 reset: resource ID 1 must be reusable
     * after henge_virtio_gpu_reset() while preserving configured scanout display dimensions. */
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_2D, 0U, 1U, 0U, 8U, 8U,
        HENGE_VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM, NULL, 0U) == HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_SET_SCANOUT, 0U, 1U, 0U, 8U, 8U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_set_display_mode(gpu, 0U, 1280U, 800U, true) == 0);
    henge_virtio_gpu_reset(gpu);
    HENGE_CHECK(henge_virtio_gpu_active_resources(gpu) == 0U);
    HENGE_CHECK(henge_virtio_gpu_scanout_resource(gpu, 0U) == 0U);
    HENGE_CHECK(henge_virtio_gpu_get_display_info(gpu, 0U, &disp_w, &disp_h, &disp_en) == 0);
    HENGE_CHECK(disp_w == 1280U && disp_h == 800U && disp_en);
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        gpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_2D, 0U, 1U, 0U, 16U, 16U,
        HENGE_VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM, NULL, 0U) == HENGE_VIRTIO_GPU_RESP_OK_NODATA);

    henge_virtio_gpu_destroy(gpu);
}

static void test_console_log_capture(void) {
    const char *log_path = "build/test_console.log";
    remove(log_path);
    HENGE_CHECK(hengelinux_start_console_capture(log_path) == 0);
    hengelinux_clear_console_log();

    hengelinux_console_append_line("[test] console marker line 1");
    fprintf(stderr, "=== AttributeGraph: cycle detected through attribute 1136664 ===\n");
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
    HENGE_CHECK(strstr(buf, "AttributeGraph") == NULL);

    hengelinux_reset_guest_hid_bridge_ready();
    HENGE_CHECK(!hengelinux_is_guest_hid_bridge_ready());
    HENGE_CHECK(!hengelinux_is_guest_hid_bridge_v2());
    hengelinux_console_append_line("\x1b]9998;HENGE_HID_READY\x07");
    HENGE_CHECK(hengelinux_is_guest_hid_bridge_ready());
    HENGE_CHECK(!hengelinux_is_guest_hid_bridge_v2());
    hengelinux_reset_guest_hid_bridge_ready();
    HENGE_CHECK(!hengelinux_is_guest_hid_bridge_ready());
    HENGE_CHECK(!hengelinux_is_guest_hid_bridge_v2());
    hengelinux_console_append_line("\x1b]9998;HENGE_HID_READY_V2\x07");
    HENGE_CHECK(hengelinux_is_guest_hid_bridge_ready());
    HENGE_CHECK(hengelinux_is_guest_hid_bridge_v2());
    hengelinux_reset_guest_hid_bridge_ready();
    HENGE_CHECK(!hengelinux_is_guest_hid_bridge_ready());
    HENGE_CHECK(!hengelinux_is_guest_hid_bridge_v2());

    hengelinux_clear_console_log();
    remove(log_path);

    /* Verify dedicated incremental pure guest serial ring (cursor, wraparound, clear). */
    hengelinux_serial_clear();
    HENGE_CHECK(hengelinux_serial_total_bytes() == 0ULL);
    const uint8_t s1[] = "\x1b[32mhello\r\n";
    hengelinux_serial_append_bytes(s1, sizeof(s1) - 1U);
    hengelinux_serial_append_byte((uint8_t)'!');
    HENGE_CHECK(hengelinux_serial_total_bytes() == (uint64_t)(sizeof(s1)));
    uint64_t cur = 0ULL;
    uint8_t out[64] = {0};
    size_t got = hengelinux_serial_copy_from(&cur, out, 5U);
    HENGE_CHECK(got == 5U && cur == 5ULL && memcmp(out, s1, 5U) == 0);
    got = hengelinux_serial_copy_from(&cur, out, sizeof(out));
    HENGE_CHECK(got == sizeof(s1) - 5U && cur == (uint64_t)sizeof(s1));
    HENGE_CHECK(out[got - 1U] == (uint8_t)'!');
    /* Second read at tail returns 0 bytes. */
    HENGE_CHECK(hengelinux_serial_copy_from(&cur, out, sizeof(out)) == 0U);
    /* Ring overflow past 128 KiB advances stale cursor to oldest retained bytes. */
    uint8_t chunk[4096];
    memset(chunk, 'A', sizeof(chunk));
    for (int i = 0; i < 40; ++i) {
        hengelinux_serial_append_bytes(chunk, sizeof(chunk));
    }
    uint8_t tail_mark[] = "TAIL";
    hengelinux_serial_append_bytes(tail_mark, 4U);
    uint64_t stale_cur = 0ULL;
    size_t total_drained = 0U;
    uint8_t last4[4] = {0};
    uint8_t drain[4096];
    for (;;) {
        size_t d = hengelinux_serial_copy_from(&stale_cur, drain, sizeof(drain));
        if (d == 0U) break;
        total_drained += d;
        if (d >= 4U) {
            memcpy(last4, drain + d - 4U, 4U);
        } else {
            memmove(last4, last4 + d, 4U - d);
            memcpy(last4 + (4U - d), drain, d);
        }
    }
    HENGE_CHECK(total_drained == 131072U);
    HENGE_CHECK(memcmp(last4, "TAIL", 4U) == 0);
    hengelinux_serial_clear();
    HENGE_CHECK(hengelinux_serial_total_bytes() == 0ULL);
}

static void write_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)((v >> 24) & 0xFFU);
    p[1] = (uint8_t)((v >> 16) & 0xFFU);
    p[2] = (uint8_t)((v >> 8) & 0xFFU);
    p[3] = (uint8_t)(v & 0xFFU);
}

static void write_be64(uint8_t *p, uint64_t v) {
    write_be32(p, (uint32_t)(v >> 32));
    write_be32(p + 4, (uint32_t)(v & 0xFFFFFFFFULL));
}

static void test_qcow2_and_storage_tools(void) {
    const char *qcow2_path = "build/test_v3.qcow2";
    const char *raw_path = "build/test_v3_out.raw";
    const char *clone_path = "build/test_v3_clone.raw";
    const char *iso_path = "build/test_dummy.iso";
    const char *ext_path = "build/test_extl2.qcow2";
    const char *ext_raw = "build/test_extl2.raw";
    const char *bad_path = "build/test_encrypted.qcow2";
    char err[256] = {0};

    /* 1. Synthesize a QCOW2 v3 image with 16 KiB clusters (cluster_bits=14),
     *    3 guest clusters (48 KiB virtual):
     *      cluster 0: uncompressed pattern
     *      cluster 1: unallocated (sparse zero hole)
     *      cluster 2: raw-deflate zlib-compressed pattern
     */
    const size_t cs = 16384U;
    uint8_t *c0 = (uint8_t *)calloc(1U, cs);
    uint8_t *c2 = (uint8_t *)calloc(1U, cs);
    HENGE_CHECK(c0 != NULL && c2 != NULL);
    for (size_t i = 0U; i < cs; i++) {
        c0[i] = (uint8_t)((i * 7U + 3U) & 0xFFU);
        c2[i] = (uint8_t)((i / 64U) ^ 0xA5U);
    }

    uint8_t comp_out[16384];
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    HENGE_CHECK(deflateInit2(&zs, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) == Z_OK);
    zs.next_in = c2;
    zs.avail_in = (uInt)cs;
    zs.next_out = comp_out;
    zs.avail_out = (uInt)sizeof(comp_out);
    HENGE_CHECK(deflate(&zs, Z_FINISH) == Z_STREAM_END);
    size_t comp_len = sizeof(comp_out) - (size_t)zs.avail_out;
    deflateEnd(&zs);
    HENGE_CHECK(comp_len > 0U && comp_len < cs);

    /* Layout:
     *   0x00000: header (1 cluster)
     *   0x04000: L1 table (1 cluster)
     *   0x08000: L2 table (1 cluster)
     *   0x0C000: cluster 0 uncompressed data (1 cluster)
     *   0x10000: cluster 2 compressed data (at sector-aligned offset 0x10000)
     */
    size_t total_img = cs * 4U + ((comp_len + 511U) & ~511U);
    uint8_t *qimg = (uint8_t *)calloc(1U, total_img);
    HENGE_CHECK(qimg != NULL);
    write_be32(qimg + 0, 0x514649FBU);
    write_be32(qimg + 4, 3U);            /* version 3 */
    write_be32(qimg + 20, 14U);          /* cluster_bits = 14 (16 KiB) */
    write_be64(qimg + 24, cs * 3ULL);    /* virtual_size = 48 KiB */
    write_be32(qimg + 36, 1U);           /* l1_size = 1 */
    write_be64(qimg + 40, cs * 1ULL);    /* l1_offset = 0x4000 */
    write_be64(qimg + 72, 0ULL);         /* incompat = 0 */
    write_be32(qimg + 100, 104U);        /* header_length = 104 */

    write_be64(qimg + cs * 1U, cs * 2ULL); /* L1[0] -> L2 at 0x8000 */
    write_be64(qimg + cs * 2U + 0U, cs * 3ULL); /* L2[0] -> uncompressed at 0xC000 */
    write_be64(qimg + cs * 2U + 8U, 0ULL);      /* L2[1] -> sparse hole */

    uint64_t coffset = cs * 4ULL;
    uint64_t nb_csectors = (comp_len + 511U) / 512U;
    uint32_t csize_shift = 62U - (14U - 8U); /* 56 */
    uint64_t comp_l2 = (1ULL << 62) | ((nb_csectors - 1ULL) << csize_shift) | coffset;
    write_be64(qimg + cs * 2U + 16U, comp_l2);

    memcpy(qimg + cs * 3U, c0, cs);
    memcpy(qimg + coffset, comp_out, comp_len);

    FILE *fp = fopen(qcow2_path, "wb");
    HENGE_CHECK(fp != NULL);
    HENGE_CHECK(fwrite(qimg, 1U, total_img, fp) == total_img);
    fclose(fp);

    HENGE_CHECK(henge_detect_image_format(qcow2_path) == HENGE_IMG_FORMAT_QCOW2);
    HengeQcow2Info qinfo;
    HENGE_CHECK(henge_qcow2_inspect(qcow2_path, &qinfo, err, sizeof(err)) == 0);
    HENGE_CHECK(qinfo.version == 3U && qinfo.cluster_bits == 14U && qinfo.virtual_size == cs * 3ULL);

    HENGE_CHECK(henge_qcow2_unpack_to_raw(qcow2_path, raw_path, 0ULL, err, sizeof(err)) == 0);
    HENGE_CHECK(henge_detect_image_format(raw_path) == HENGE_IMG_FORMAT_RAW);

    uint8_t *verify = (uint8_t *)malloc(cs * 3U);
    HENGE_CHECK(verify != NULL);
    fp = fopen(raw_path, "rb");
    HENGE_CHECK(fp != NULL);
    HENGE_CHECK(fread(verify, 1U, cs * 3U, fp) == cs * 3U);
    fclose(fp);
    HENGE_CHECK(memcmp(verify, c0, cs) == 0);
    for (size_t i = 0U; i < cs; i++) {
        HENGE_CHECK(verify[cs + i] == 0U);
    }
    HENGE_CHECK(memcmp(verify + cs * 2U, c2, cs) == 0);

    /* 2. Clone, compact & grow-only sparse disk expansion tests */
    HENGE_CHECK(henge_clone_file_apfs(raw_path, clone_path, err, sizeof(err)) == 0);
    uint64_t reclaimed = 0ULL;
    HENGE_CHECK(henge_compact_sparse_file(clone_path, &reclaimed, err, sizeof(err)) == 0);
    uint64_t final_sz = 0ULL;
    HENGE_CHECK(henge_expand_sparse_raw_disk(clone_path, cs * 5ULL, &final_sz, err, sizeof(err)) == 0);
    HENGE_CHECK(final_sz == cs * 5ULL);
    /* Grow-only invariant: smaller target size must not shrink the disk. */
    HENGE_CHECK(henge_expand_sparse_raw_disk(clone_path, cs * 2ULL, &final_sz, err, sizeof(err)) == 0);
    HENGE_CHECK(final_sz == cs * 5ULL);
    {
        uint8_t *expanded = (uint8_t *)malloc(cs * 5U);
        HENGE_CHECK(expanded != NULL);
        fp = fopen(clone_path, "rb");
        HENGE_CHECK(fp != NULL);
        HENGE_CHECK(fread(expanded, 1U, cs * 5U, fp) == cs * 5U);
        fclose(fp);
        HENGE_CHECK(memcmp(expanded, c0, cs) == 0);
        HENGE_CHECK(memcmp(expanded + cs * 2U, c2, cs) == 0);
        for (size_t i = cs * 3U; i < cs * 5U; i++) {
            HENGE_CHECK(expanded[i] == 0U);
        }
        free(expanded);
    }

    /* 3. Extended L2 subcluster test (incompat bit 4, 16-byte L2 entries) */
    uint8_t *eimg = (uint8_t *)calloc(1U, cs * 4U);
    HENGE_CHECK(eimg != NULL);
    write_be32(eimg + 0, 0x514649FBU);
    write_be32(eimg + 4, 3U);
    write_be32(eimg + 20, 14U);
    write_be64(eimg + 24, cs);
    write_be32(eimg + 36, 1U);
    write_be64(eimg + 40, cs * 1ULL);
    write_be64(eimg + 72, (1ULL << 4)); /* Extended L2 */
    write_be32(eimg + 100, 104U);
    write_be64(eimg + cs * 1U, cs * 2ULL);
    write_be64(eimg + cs * 2U + 0U, cs * 3ULL);
    /* Allocate subcluster 0 and subcluster 2; mark subcluster 2 zeroed -> only subcluster 0 copied */
    write_be64(eimg + cs * 2U + 8U, ((1ULL << 2) << 32) | (1ULL << 0) | (1ULL << 2));
    memset(eimg + cs * 3U, 0x5AU, 512U);
    memset(eimg + cs * 3U + 1024U, 0x7BU, 512U);
    fp = fopen(ext_path, "wb");
    HENGE_CHECK(fp != NULL);
    HENGE_CHECK(fwrite(eimg, 1U, cs * 4U, fp) == cs * 4U);
    fclose(fp);
    HENGE_CHECK(henge_qcow2_unpack_to_raw(ext_path, ext_raw, 0ULL, err, sizeof(err)) == 0);
    fp = fopen(ext_raw, "rb");
    HENGE_CHECK(fp != NULL);
    HENGE_CHECK(fread(verify, 1U, cs, fp) == cs);
    fclose(fp);
    HENGE_CHECK(verify[0] == 0x5AU && verify[511] == 0x5AU);
    HENGE_CHECK(verify[1024] == 0x00U && verify[1535] == 0x00U);

    /* 4. Fail-closed encrypted QCOW2 rejection */
    write_be32(qimg + 32, 1U); /* crypt_method = AES */
    fp = fopen(bad_path, "wb");
    HENGE_CHECK(fp != NULL);
    HENGE_CHECK(fwrite(qimg, 1U, total_img, fp) == total_img);
    fclose(fp);
    HENGE_CHECK(henge_qcow2_inspect(bad_path, &qinfo, err, sizeof(err)) == -1);
    HENGE_CHECK(henge_qcow2_unpack_to_raw(bad_path, raw_path, 0ULL, err, sizeof(err)) == -1);

    /* 5. ISO9660 magic detection ("CD001" at 0x8001) & preferred block size (512 vs 2048) */
    uint8_t *iso = (uint8_t *)calloc(1U, 0x9000U);
    HENGE_CHECK(iso != NULL);
    iso[0x8000U] = 0x01U;
    memcpy(iso + 0x8001U, "CD001", 5U);
    /* Pure El Torito ISO (no MBR/GPT) -> 2048-byte logical sectors */
    iso[0x8800U] = 0x00U;
    memcpy(iso + 0x8801U, "CD001", 5U);
    memcpy(iso + 0x8807U, "EL TORITO SPECIFICATION", 23U);
    fp = fopen(iso_path, "wb");
    HENGE_CHECK(fp != NULL);
    HENGE_CHECK(fwrite(iso, 1U, 0x9000U, fp) == 0x9000U);
    fclose(fp);
    HENGE_CHECK(henge_detect_image_format(iso_path) == HENGE_IMG_FORMAT_ISO9660);
    HENGE_CHECK(henge_iso_preferred_block_size(iso_path) == 2048U);

    /* Isohybrid GPT ISO ("EFI PART" at 0x200) -> 512-byte logical sectors */
    memcpy(iso + 0x200U, "EFI PART", 8U);
    fp = fopen(iso_path, "wb");
    HENGE_CHECK(fp != NULL);
    HENGE_CHECK(fwrite(iso, 1U, 0x9000U, fp) == 0x9000U);
    fclose(fp);
    HENGE_CHECK(henge_iso_preferred_block_size(iso_path) == 512U);

#if defined(HENGE_HAVE_ZSTD)
    /* 6. Zstd-compressed QCOW2 v3 (compression_type = 1) round-trip */
    HENGE_CHECK(henge_qcow2_has_zstd());
    {
        const char *zstd_qcow2 = "build/test_zstd.qcow2";
        const char *zstd_raw = "build/test_zstd.raw";
        uint8_t zcomp[16384];
        size_t zlen = ZSTD_compress(zcomp, sizeof(zcomp), c2, cs, 1);
        HENGE_CHECK(!ZSTD_isError(zlen) && zlen > 0U && zlen < cs);

        size_t ztotal = cs * 3U + ((zlen + 511U) & ~511U);
        uint8_t *zqimg = (uint8_t *)calloc(1U, ztotal);
        HENGE_CHECK(zqimg != NULL);
        write_be32(zqimg + 0, 0x514649FBU);
        write_be32(zqimg + 4, 3U);
        write_be32(zqimg + 20, 14U);           /* 16 KiB clusters */
        write_be64(zqimg + 24, cs);            /* 16 KiB virtual size */
        write_be32(zqimg + 36, 1U);            /* l1_size = 1 */
        write_be64(zqimg + 40, cs * 1ULL);     /* L1 at 0x4000 */
        write_be64(zqimg + 72, (1ULL << 3));   /* INCOMPAT_COMP_TYPE */
        write_be32(zqimg + 100, 105U);         /* header_length includes byte 104 */
        zqimg[104] = 1U;                       /* compression_type = zstd */
        write_be64(zqimg + cs * 1U, cs * 2ULL);
        uint64_t zcoff = cs * 3ULL;
        uint64_t zsectors = (zlen + 511U) / 512U;
        uint64_t zl2 = (1ULL << 62) | ((zsectors - 1ULL) << csize_shift) | zcoff;
        write_be64(zqimg + cs * 2U, zl2);
        memcpy(zqimg + zcoff, zcomp, zlen);

        fp = fopen(zstd_qcow2, "wb");
        HENGE_CHECK(fp != NULL);
        HENGE_CHECK(fwrite(zqimg, 1U, ztotal, fp) == ztotal);
        fclose(fp);

        HengeQcow2Info zinfo;
        HENGE_CHECK(henge_qcow2_inspect(zstd_qcow2, &zinfo, err, sizeof(err)) == 0);
        HENGE_CHECK(zinfo.compression_type == 1U);
        HENGE_CHECK(henge_qcow2_unpack_to_raw(zstd_qcow2, zstd_raw, 0ULL, err, sizeof(err)) == 0);
        fp = fopen(zstd_raw, "rb");
        HENGE_CHECK(fp != NULL);
        HENGE_CHECK(fread(verify, 1U, cs, fp) == cs);
        fclose(fp);
        HENGE_CHECK(memcmp(verify, c2, cs) == 0);

        free(zqimg);
        remove(zstd_qcow2);
        remove(zstd_raw);
    }
#endif

    free(iso);
    free(eimg);
    free(verify);
    free(qimg);
    free(c0);
    free(c2);
    remove(qcow2_path);
    remove(raw_path);
    remove(clone_path);
    remove(iso_path);
    remove(ext_path);
    remove(ext_raw);
    remove(bad_path);
}

static void test_cidata_fat16_generator(void) {
    const char *seed_path = "build/test_cidata.img";
    char err[256] = {0};
    HengeCidataConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.instance_id = "henge-test-01";
    cfg.hostname = "debian-ios";
    cfg.username = "dev";
    cfg.password = "secret123";
    cfg.ssh_authorized_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey dev@ios";

    HENGE_CHECK(henge_cidata_write_image(seed_path, &cfg, err, sizeof(err)) == 0);

    FILE *fp = fopen(seed_path, "rb");
    HENGE_CHECK(fp != NULL);
    HENGE_CHECK(fseek(fp, 0L, SEEK_END) == 0);
    long sz = ftell(fp);
    HENGE_CHECK(sz == 4224L * 512L);
    HENGE_CHECK(fseek(fp, 0L, SEEK_SET) == 0);

    uint8_t *img = (uint8_t *)malloc((size_t)sz);
    HENGE_CHECK(img != NULL);
    HENGE_CHECK(fread(img, 1U, (size_t)sz, fp) == (size_t)sz);
    fclose(fp);

    /* Verify FAT16 BPB, boot signature, CIDATA volume label, and FAT16 type */
    HENGE_CHECK(img[510] == 0x55U && img[511] == 0xAAU);
    HENGE_CHECK(memcmp(img + 43, "CIDATA     ", 11U) == 0);
    HENGE_CHECK(memcmp(img + 54, "FAT16   ", 8U) == 0);

    /* Root directory starts at sector 1 + 2*17 = 35; entry 0 is volume label */
    const uint8_t *root = img + 35U * 512U;
    HENGE_CHECK(memcmp(root, "CIDATA     ", 11U) == 0 && root[11] == 0x08U);

    /* Data region starts at sector 67; verify cloud-init payloads exist */
    const char *data_region = (const char *)(img + 67U * 512U);
    size_t data_bytes = (size_t)sz - 67U * 512U;
    bool found_meta = false, found_user = false, found_shell = false, found_net = false;
    for (size_t i = 0U; i + 16U < data_bytes; i++) {
        if (!found_meta && memcmp(data_region + i, "instance-id: henge-test-01", 26U) == 0) found_meta = true;
        if (!found_user && memcmp(data_region + i, "#cloud-config\nhostname: debian-ios", 34U) == 0) found_user = true;
        if (!found_shell && memcmp(data_region + i, "shell: /bin/sh\n", 15U) == 0) found_shell = true;
        if (!found_net && memcmp(data_region + i, "dhcp4: true", 11U) == 0) found_net = true;
    }
    HENGE_CHECK(found_meta && found_user && found_shell && found_net);

    free(img);
    remove(seed_path);

    /* Distro-aware CIDATA profiles: Ubuntu -> /bin/bash + NoCloud + snapd disable; Alpine -> /bin/sh */
    {
        const char *ubuntu_seed = "build/test_cidata_ubuntu.img";
        HengeCidataConfig ucfg;
        memset(&ucfg, 0, sizeof(ucfg));
        ucfg.instance_id = "henge-ubuntu-01";
        ucfg.hostname = "ubuntu-ios";
        ucfg.username = "linux";
        ucfg.password = "linux";
        ucfg.distro_tag = "ubuntu";
        HENGE_CHECK(henge_cidata_write_image(ubuntu_seed, &ucfg, err, sizeof(err)) == 0);

        FILE *ufp = fopen(ubuntu_seed, "rb");
        HENGE_CHECK(ufp != NULL);
        uint8_t *uimg = (uint8_t *)malloc(4224U * 512U);
        HENGE_CHECK(uimg != NULL);
        HENGE_CHECK(fread(uimg, 1U, 4224U * 512U, ufp) == 4224U * 512U);
        fclose(ufp);

        const char *udata = (const char *)(uimg + 67U * 512U);
        size_t ulen = (4224U - 67U) * 512U;
        bool has_bash = false, has_nocloud = false, has_snapd = false, has_growpart = false;
        for (size_t i = 0U; i + 32U < ulen; i++) {
            if (!has_bash && memcmp(udata + i, "shell: /bin/bash\n", 17U) == 0) has_bash = true;
            if (!has_nocloud && memcmp(udata + i, "datasource_list: [NoCloud, None]", 32U) == 0) has_nocloud = true;
            if (!has_snapd && memcmp(udata + i, "snapd.service", 13U) == 0) has_snapd = true;
            if (!has_growpart && memcmp(udata + i, "resize_rootfs: true", 19U) == 0) has_growpart = true;
        }
        HENGE_CHECK(has_bash && has_nocloud && has_snapd && has_growpart);
        free(uimg);
        remove(ubuntu_seed);
    }

    {
        const char *alpine_seed = "build/test_cidata_alpine.img";
        HengeCidataConfig acfg;
        memset(&acfg, 0, sizeof(acfg));
        acfg.instance_id = "henge-alpine-01";
        acfg.hostname = "alpine-ios";
        acfg.username = "linux";
        acfg.password = "linux";
        acfg.distro_tag = "alpine";
        HENGE_CHECK(henge_cidata_write_image(alpine_seed, &acfg, err, sizeof(err)) == 0);

        FILE *afp = fopen(alpine_seed, "rb");
        HENGE_CHECK(afp != NULL);
        uint8_t *aimg = (uint8_t *)malloc(4224U * 512U);
        HENGE_CHECK(aimg != NULL);
        HENGE_CHECK(fread(aimg, 1U, 4224U * 512U, afp) == 4224U * 512U);
        fclose(afp);

        const char *adata = (const char *)(aimg + 67U * 512U);
        size_t alen = (4224U - 67U) * 512U;
        bool has_sh = false, has_snapd = false;
        for (size_t i = 0U; i + 20U < alen; i++) {
            if (!has_sh && memcmp(adata + i, "shell: /bin/sh\n", 15U) == 0) has_sh = true;
            if (!has_snapd && memcmp(adata + i, "snapd.service", 13U) == 0) has_snapd = true;
        }
        HENGE_CHECK(has_sh && !has_snapd);
        free(aimg);
        remove(alpine_seed);
    }
}

static bool near_double(double a, double b, double eps) {
    double diff = a - b;
    if (diff < 0.0) diff = -diff;
    return diff <= eps;
}

static void test_touch_aspect_coordinate_mapping(void) {
    uint32_t w = 99U, h = 99U;
    hengelinux_set_presented_fb_size(1024U, 768U);
    hengelinux_get_presented_fb_size(&w, &h);
    HENGE_CHECK(w == 1024U && h == 768U);

    /* Portrait letterbox: 390x600 view showing 1024x768 (4:3) -> rendered height = 292.5, y in [153.75, 446.25]. */
    double nx = -1.0, ny = -1.0;
    henge_map_touch_to_guest_norm(0.0, 153.75, 390.0, 600.0, 1024U, 768U, &nx, &ny);
    HENGE_CHECK(near_double(nx, 0.0, 1e-4) && near_double(ny, 0.0, 1e-4));

    henge_map_touch_to_guest_norm(195.0, 300.0, 390.0, 600.0, 1024U, 768U, &nx, &ny);
    HENGE_CHECK(near_double(nx, 0.5, 1e-4) && near_double(ny, 0.5, 1e-4));

    henge_map_touch_to_guest_norm(390.0, 446.25, 390.0, 600.0, 1024U, 768U, &nx, &ny);
    HENGE_CHECK(near_double(nx, 1.0, 1e-4) && near_double(ny, 1.0, 1e-4));

    /* Taps inside top/bottom letterbox bars clamp cleanly to [0, 1]. */
    henge_map_touch_to_guest_norm(195.0, 10.0, 390.0, 600.0, 1024U, 768U, &nx, &ny);
    HENGE_CHECK(near_double(nx, 0.5, 1e-4) && near_double(ny, 0.0, 1e-4));
    henge_map_touch_to_guest_norm(195.0, 590.0, 390.0, 600.0, 1024U, 768U, &nx, &ny);
    HENGE_CHECK(near_double(nx, 0.5, 1e-4) && near_double(ny, 1.0, 1e-4));

    /* Landscape pillarbox: 800x300 view showing 1024x768 (4:3) -> rendered width = 400, x in [200, 600]. */
    henge_map_touch_to_guest_norm(200.0, 0.0, 800.0, 300.0, 1024U, 768U, &nx, &ny);
    HENGE_CHECK(near_double(nx, 0.0, 1e-4) && near_double(ny, 0.0, 1e-4));
    henge_map_touch_to_guest_norm(600.0, 300.0, 800.0, 300.0, 1024U, 768U, &nx, &ny);
    HENGE_CHECK(near_double(nx, 1.0, 1e-4) && near_double(ny, 1.0, 1e-4));
    henge_map_touch_to_guest_norm(50.0, 150.0, 800.0, 300.0, 1024U, 768U, &nx, &ny);
    HENGE_CHECK(near_double(nx, 0.0, 1e-4) && near_double(ny, 0.5, 1e-4));

    /* Unknown/zero framebuffer size falls back to linear full-view normalization. */
    hengelinux_set_presented_fb_size(0U, 0U);
    hengelinux_get_presented_fb_size(&w, &h);
    HENGE_CHECK(w == 0U && h == 0U);
    henge_map_touch_to_guest_norm(100.0, 75.0, 400.0, 300.0, 0U, 0U, &nx, &ny);
    HENGE_CHECK(near_double(nx, 0.25, 1e-4) && near_double(ny, 0.25, 1e-4));
}

typedef struct {
    pthread_mutex_t mu;
    pthread_t       caller_tid;
    uint32_t        completed_count;
    uint32_t        off_thread_count;
    uint32_t        display_events;
    uint32_t        cursor_events;
    uint32_t        last_resp_type;
    uint32_t        last_rflags;
    uint64_t        last_fence_id;
    uint32_t        last_capset_id;
    uint32_t        last_capset_max_ver;
    uint32_t        last_capset_max_size;
    size_t          last_resp_len;
} VirglWorkerTestSink;

static void test_virgl_on_complete(void *opaque,
                                   void *cmd_tag,
                                   uint64_t generation,
                                   const uint8_t *resp_bytes,
                                   size_t resp_len) {
    VirglWorkerTestSink *sink = (VirglWorkerTestSink *)opaque;
    (void)cmd_tag;
    (void)generation;
    pthread_mutex_lock(&sink->mu);
    if (!pthread_equal(pthread_self(), sink->caller_tid)) {
        sink->off_thread_count++;
    }
    sink->completed_count++;
    sink->last_resp_len = resp_len;
    if (resp_bytes != NULL && resp_len >= 24U) {
        memcpy(&sink->last_resp_type, resp_bytes + 0U, 4U);
        memcpy(&sink->last_rflags, resp_bytes + 4U, 4U);
        memcpy(&sink->last_fence_id, resp_bytes + 8U, 8U);
        if (sink->last_resp_type == HENGE_VIRTIO_GPU_RESP_OK_CAPSET_INFO && resp_len >= 40U) {
            memcpy(&sink->last_capset_id, resp_bytes + 24U, 4U);
            memcpy(&sink->last_capset_max_ver, resp_bytes + 28U, 4U);
            memcpy(&sink->last_capset_max_size, resp_bytes + 32U, 4U);
        }
    }
    pthread_mutex_unlock(&sink->mu);
}

static void test_virgl_on_display_event(void *opaque,
                                        uint32_t scanout_id,
                                        bool is_cursor,
                                        bool force_full) {
    VirglWorkerTestSink *sink = (VirglWorkerTestSink *)opaque;
    (void)scanout_id;
    (void)force_full;
    pthread_mutex_lock(&sink->mu);
    if (is_cursor) {
        sink->cursor_events++;
    } else {
        sink->display_events++;
    }
    pthread_mutex_unlock(&sink->mu);
}

static void test_virgl_async_worker(void) {
    HengeVirtioGpuConfig cfg;
    HENGE_CHECK(henge_virtio_gpu_init_config(HENGE_GPU_BACKEND_VIRGL_3D, 512U, &cfg) == 0);
    HengeVirtioGpuDevice *gpu = henge_virtio_gpu_create(&cfg);
    HENGE_CHECK(gpu != NULL);

    VirglWorkerTestSink sink;
    memset(&sink, 0, sizeof(sink));
    pthread_mutex_init(&sink.mu, NULL);
    sink.caller_tid = pthread_self();

    HengeVirglWorkerConfig wcfg;
    memset(&wcfg, 0, sizeof(wcfg));
    wcfg.gpu = gpu;
    wcfg.enable_virgl = true;
    wcfg.vram_mib = 512U;
    wcfg.callback_opaque = &sink;
    wcfg.on_complete = test_virgl_on_complete;
    wcfg.on_display_event = test_virgl_on_display_event;

    HengeVirglWorker *worker = henge_virgl_worker_create(&wcfg);
    HENGE_CHECK(worker != NULL);
    henge_virgl_register_active_worker(worker);

    /* 1. GET_CAPSET_INFO index 1 -> VIRGL2 */
    uint32_t cap_idx_req[2] = { 1U, 0U };
    HengeVirglCommand cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.queue_index = 0U;
    cmd.cmd_type = HENGE_VIRTIO_GPU_CMD_GET_CAPSET_INFO;
    cmd.flags = HENGE_VIRTIO_GPU_FLAG_FENCE;
    cmd.fence_id = 101ULL;
    cmd.generation = 1ULL;
    cmd.payload = (const uint8_t *)cap_idx_req;
    cmd.payload_len = sizeof(cap_idx_req);
    HENGE_CHECK(henge_virgl_worker_enqueue(worker, &cmd) == 0);
    HENGE_CHECK(henge_virgl_worker_drain(worker, 2000U) == 0);
    HENGE_CHECK(sink.last_resp_type == HENGE_VIRTIO_GPU_RESP_OK_CAPSET_INFO);
    HENGE_CHECK(sink.last_fence_id == 101ULL && sink.last_rflags == HENGE_VIRTIO_GPU_FLAG_FENCE);
    HENGE_CHECK(sink.last_capset_id == HENGE_VIRTIO_GPU_CAPSET_VIRGL2);
    HENGE_CHECK(sink.last_capset_max_ver >= 1U && sink.last_capset_max_size >= 64U);

    /* 2. GET_CAPSET for VIRGL2 */
    uint32_t get_cap_req[2] = { HENGE_VIRTIO_GPU_CAPSET_VIRGL2, sink.last_capset_max_ver };
    cmd.cmd_type = HENGE_VIRTIO_GPU_CMD_GET_CAPSET;
    cmd.fence_id = 102ULL;
    cmd.payload = (const uint8_t *)get_cap_req;
    cmd.payload_len = sizeof(get_cap_req);
    HENGE_CHECK(henge_virgl_worker_enqueue(worker, &cmd) == 0);
    HENGE_CHECK(henge_virgl_worker_drain(worker, 2000U) == 0);
    HENGE_CHECK(sink.last_resp_type == HENGE_VIRTIO_GPU_RESP_OK_CAPSET);
    HENGE_CHECK(sink.last_resp_len >= 24U + 64U);

    /* 3. CTX_CREATE -> RESOURCE_CREATE_3D -> ATTACH_BACKING -> CTX_ATTACH -> SUBMIT_3D (fenced) */
    uint8_t ctx_req[72];
    memset(ctx_req, 0, sizeof(ctx_req));
    uint32_t name_len = 5U;
    memcpy(ctx_req + 0U, &name_len, 4U);
    memcpy(ctx_req + 8U, "labwc", 5U);
    cmd.cmd_type = HENGE_VIRTIO_GPU_CMD_CTX_CREATE;
    cmd.ctx_id = 7U;
    cmd.fence_id = 103ULL;
    cmd.payload = ctx_req;
    cmd.payload_len = sizeof(ctx_req);
    HENGE_CHECK(henge_virgl_worker_enqueue(worker, &cmd) == 0);

    uint32_t res3d_req[12] = { 55U, 2U, HENGE_VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM, 2U, 64U, 64U, 1U, 1U, 0U, 0U, 0U, 0U };
    cmd.cmd_type = HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_3D;
    cmd.fence_id = 104ULL;
    cmd.payload = (const uint8_t *)res3d_req;
    cmd.payload_len = sizeof(res3d_req);
    HENGE_CHECK(henge_virgl_worker_enqueue(worker, &cmd) == 0);

    /* Large 1D PIPE_BUFFER (64 KiB, width > 7680, height == 1) must succeed for Mesa VBOs/UBOs. */
    uint32_t buf3d_req[12] = { 56U, 0U, 64U /* R8_UNORM */, 0x10U, 65536U, 1U, 1U, 1U, 0U, 0U, 0U, 0U };
    cmd.cmd_type = HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_3D;
    cmd.fence_id = 1041ULL;
    cmd.payload = (const uint8_t *)buf3d_req;
    cmd.payload_len = sizeof(buf3d_req);
    HENGE_CHECK(henge_virgl_worker_enqueue(worker, &cmd) == 0);

    uint32_t xfer3d_req[12] = { 0U, 0U, 0U, 64U, 1U, 1U, 0U, 0U, 56U, 0U, 0U, 0U };
    cmd.cmd_type = HENGE_VIRTIO_GPU_CMD_TRANSFER_FROM_HOST_3D;
    cmd.fence_id = 1042ULL;
    cmd.payload = (const uint8_t *)xfer3d_req;
    cmd.payload_len = sizeof(xfer3d_req);
    HENGE_CHECK(henge_virgl_worker_enqueue(worker, &cmd) == 0);

    uint8_t backing_mem[64];
    memset(backing_mem, 0x3CU, sizeof(backing_mem));
    HengeGpuBackingEntry bg = { .host_ptr = backing_mem, .guest_addr = 0x50000000ULL, .length = sizeof(backing_mem), .reserved = 0U };
    uint32_t attach_req[2] = { 55U, 1U };
    cmd.cmd_type = HENGE_VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING;
    cmd.fence_id = 105ULL;
    cmd.payload = (const uint8_t *)attach_req;
    cmd.payload_len = sizeof(attach_req);
    cmd.backing = &bg;
    cmd.backing_count = 1U;
    HENGE_CHECK(henge_virgl_worker_enqueue(worker, &cmd) == 0);
    cmd.backing = NULL;
    cmd.backing_count = 0U;

    uint32_t ctx_res_req[2] = { 55U, 0U };
    cmd.cmd_type = HENGE_VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE;
    cmd.fence_id = 106ULL;
    cmd.payload = (const uint8_t *)ctx_res_req;
    cmd.payload_len = sizeof(ctx_res_req);
    HENGE_CHECK(henge_virgl_worker_enqueue(worker, &cmd) == 0);

    uint32_t submit_req[3] = { 8U, 0x00000001U, 0xDEADBEEFU };
    cmd.cmd_type = HENGE_VIRTIO_GPU_CMD_SUBMIT_3D;
    cmd.fence_id = 107ULL;
    cmd.payload = (const uint8_t *)submit_req;
    cmd.payload_len = sizeof(submit_req);
    HENGE_CHECK(henge_virgl_worker_enqueue(worker, &cmd) == 0);

    /* 4. Drain via global active-worker hook (simulating MetalLifecycleGuard willResignActive). */
    henge_virgl_drain_active_worker(2000U);
    HENGE_CHECK(sink.last_resp_type == HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(sink.last_fence_id == 107ULL);
    HENGE_CHECK(sink.completed_count == 9U);
    HENGE_CHECK(sink.off_thread_count == 9U);
    HENGE_CHECK(henge_virtio_gpu_active_contexts(gpu) == 1U);
    HENGE_CHECK(henge_virtio_gpu_context_attached_resources(gpu, 7U) == 1U);

    /* 5. Reset barrier & stats check */
    HENGE_CHECK(henge_virgl_worker_enqueue_reset(worker, 2ULL) == 0);
    HENGE_CHECK(henge_virgl_worker_drain(worker, 2000U) == 0);
    HengeVirglWorkerStats stats;
    henge_virgl_worker_get_stats(worker, &stats);
    HENGE_CHECK(stats.cmds_enqueued == 9ULL && stats.cmds_completed == 9ULL);
    HENGE_CHECK(stats.fences_retired == 9ULL && stats.resets_processed == 1ULL);
    HENGE_CHECK(stats.pending_queue_depth == 0U && stats.pending_fence_count == 0U);

    /* 6. ES 3.0 VirGL sampler wrap sanitization (CLAMP_TO_BORDER / MIRROR_CLAMP -> CLAMP_TO_EDGE). */
    uint32_t sampler_stream[] = {
        0x0003000aU, 0x00000001U, 0x00000000U, 0x00000005U, /* SET_SAMPLER_VIEWS (skipped intact) */
        0x00090701U, 0x0000005eU, 0x0003101bU, 0x00000000U, /* CREATE_OBJECT SAMPLER_STATE: wrap_s=3 wrap_t=3 */
        0x00000000U, 0x447a0000U, 0x00000000U, 0x00000000U,
        0x00000000U, 0x00000000U,
        0x00090701U, 0x0000005fU, 0x000311b0U, 0x00000000U, /* wrap_s=0 wrap_t=6 (MIRROR_CLAMP_TO_EDGE) wrap_r=6 */
        0x00000000U, 0x447a0000U, 0x00000000U, 0x00000000U,
        0x00000000U, 0x00000000U
    };
    HENGE_CHECK(henge_virgl_sanitize_cmd_stream(sampler_stream, sizeof(sampler_stream) / 4U, true, true) == 0U);
    HENGE_CHECK(sampler_stream[6] == 0x0003101bU);
    HENGE_CHECK(henge_virgl_sanitize_cmd_stream(sampler_stream, sizeof(sampler_stream) / 4U, false, false) == 2U);
    HENGE_CHECK(sampler_stream[6] == 0x00031012U);
    HENGE_CHECK(sampler_stream[16] == 0x00031090U);
    HENGE_CHECK(sampler_stream[0] == 0x0003000aU && sampler_stream[3] == 0x00000005U);

    /* 7. ES 3.0 VirGL dual-source blend capset & blend state sanitization (Ubuntu 26.04 Xorg Glamor). */
    uint32_t capset_v1[77];
    memset(capset_v1, 0, sizeof(capset_v1));
    capset_v1[0] = 1U;
    capset_v1[66] = 300U;
    capset_v1[69] = 1U; /* max_dual_source_render_targets */
    capset_v1[70] = 8U; /* max_render_targets */
    HENGE_CHECK(henge_virgl_sanitize_caps(capset_v1, 64U) == false);
    HENGE_CHECK(henge_virgl_sanitize_caps(capset_v1, sizeof(capset_v1)) == true);
    HENGE_CHECK(capset_v1[69] == 0U && capset_v1[66] == 300U && capset_v1[70] == 8U);
    HENGE_CHECK(henge_virgl_sanitize_caps(capset_v1, sizeof(capset_v1)) == false);

    uint32_t blend_stream[] = {
        0x000b0101U, 0x00000029U, 0x00000004U, 0x00000000U, /* CREATE_OBJECT BLEND len=11 */
        0x7e423211U, 0x00000000U, 0x00000000U, 0x00000000U, /* S2[0]: ONE + INV_SRC1_COLOR */
        0x00000000U, 0x00000000U, 0x00000000U, 0x00000000U
    };
    HENGE_CHECK(henge_virgl_sanitize_blend_stream(blend_stream, sizeof(blend_stream) / 4U) == 1U);
    HENGE_CHECK(blend_stream[4] == 0x7c822411U);
    HENGE_CHECK(henge_virgl_sanitize_blend_stream(blend_stream, sizeof(blend_stream) / 4U) == 0U);

    henge_virgl_worker_destroy(worker);
    henge_virtio_gpu_destroy(gpu);
    pthread_mutex_destroy(&sink.mu);
}

static void test_phase030c_swapchain_jetsam_cache_telemetry(void) {
    /* 1. Double-buffered IOSurface swapchain RAII resize, 16-byte stride alignment, and flip. */
    HengeGpuSwapchain *sc = henge_gpu_swapchain_create();
    HENGE_CHECK(sc != NULL);
    HENGE_CHECK(henge_gpu_swapchain_slot_count(sc) == 0U);
    HENGE_CHECK(henge_gpu_swapchain_resize(sc, 1921U, 1080U, true) == 0);
    HENGE_CHECK(henge_gpu_swapchain_slot_count(sc) == HENGE_GPU_SWAPCHAIN_SLOTS);
    uint32_t slot0 = 99U, slot1 = 99U;
    HengeGpuSwapchainSlot info0, info1, front;
    HENGE_CHECK(henge_gpu_swapchain_acquire_back(sc, &slot0, &info0) == 0);
    HENGE_CHECK(slot0 == 0U && info0.iosurface != NULL && (info0.bytes_per_row & 63U) == 0U);
    HENGE_CHECK(info0.bytes_per_row >= 1921U * 4U && info0.is_srgb);
    HENGE_CHECK(henge_gpu_swapchain_publish(sc, slot0, NULL, 11ULL, true) == 0);
    HENGE_CHECK(henge_gpu_swapchain_get_front(sc, &front) == 0);
    HENGE_CHECK(front.signal_value == 11ULL && front.iosurface == info0.iosurface);
    HENGE_CHECK(henge_gpu_swapchain_acquire_back(sc, &slot1, &info1) == 0);
    HENGE_CHECK(slot1 == 1U && info1.iosurface != info0.iosurface);
    HENGE_CHECK(henge_gpu_swapchain_publish(sc, slot1, NULL, 12ULL, false) == 0);
    HENGE_CHECK(henge_gpu_swapchain_get_front(sc, &front) == 0);
    HENGE_CHECK(front.signal_value == 12ULL && !front.is_srgb);
    /* Resize tears down prior surfaces and resets front state cleanly. */
    HENGE_CHECK(henge_gpu_swapchain_resize(sc, 2560U, 1440U, false) == 0);
    HENGE_CHECK(henge_gpu_swapchain_get_front(sc, &front) == -1);
    henge_gpu_swapchain_destroy(sc);

    /* 2. Jetsam VRAM caps, 320 MiB emergency floor, GPU RAM reserves, and 3D OOM enforcement. */
    HENGE_CHECK(henge_gpu_default_vram_cap_mib(8ULL << 30, 3350ULL << 20) == HENGE_GPU_VRAM_CAP_STANDARD_MIB);
    HENGE_CHECK(henge_gpu_default_vram_cap_mib(8ULL << 30, 5120ULL << 20) == HENGE_GPU_VRAM_CAP_ENTITLED_MIB);
    HENGE_CHECK(henge_gpu_default_vram_cap_mib(12ULL << 30, 6144ULL << 20) == HENGE_GPU_VRAM_CAP_HIGHMEM_MIB);
    HENGE_CHECK(henge_gpu_ram_reserve_mib(1, 3350ULL << 20) == 448U);
    HENGE_CHECK(henge_gpu_ram_reserve_mib(1, 5120ULL << 20) == 768U);
    HENGE_CHECK(henge_gpu_ram_reserve_mib(2, 3350ULL << 20) == 32U);
    HENGE_CHECK(henge_gpu_check_vram_budget(16ULL << 20, 0ULL, 256ULL << 20, 1024ULL << 20));
    /* Exceeding VRAM cap fails cleanly. */
    HENGE_CHECK(!henge_gpu_check_vram_budget(64ULL << 20, 224ULL << 20, 256ULL << 20, 2048ULL << 20));
    /* Dropping below 320 MiB emergency floor fails cleanly. */
    HENGE_CHECK(!henge_gpu_check_vram_budget(64ULL << 20, 0ULL, 512ULL << 20, 350ULL << 20));

    HengeVirtioGpuConfig vcfg;
    HENGE_CHECK(henge_virtio_gpu_init_config(HENGE_GPU_BACKEND_VIRGL_3D, 64U, &vcfg) == 0);
    HengeVirtioGpuDevice *vgpu = henge_virtio_gpu_create(&vcfg);
    HENGE_CHECK(vgpu != NULL);
    /* 4096x2048x4 = 32 MiB -> first two succeed (64 MiB), third hits VRAM cap -> OUT_OF_MEMORY. */
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        vgpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_3D, 0U, 1U, 0U, 4096U, 2048U,
        HENGE_VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM, NULL, 0U) == HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        vgpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_3D, 0U, 2U, 0U, 4096U, 2048U,
        HENGE_VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM, NULL, 0U) == HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_vram_used_bytes(vgpu) == (64ULL << 20));
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        vgpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_3D, 0U, 3U, 0U, 4096U, 2048U,
        HENGE_VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM, NULL, 0U) == HENGE_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY);
    /* Unreferencing resource 1 reclaims VRAM so resource 3 now succeeds. */
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        vgpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_UNREF, 0U, 1U, 0U, 0U, 0U, 0U, NULL, 0U) ==
        HENGE_VIRTIO_GPU_RESP_OK_NODATA);
    HENGE_CHECK(henge_virtio_gpu_vram_used_bytes(vgpu) == (32ULL << 20));
    HENGE_CHECK(henge_virtio_gpu_process_ctrl(
        vgpu, HENGE_VIRTIO_GPU_CMD_RESOURCE_CREATE_3D, 0U, 3U, 0U, 4096U, 2048U,
        HENGE_VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM, NULL, 0U) == HENGE_VIRTIO_GPU_RESP_OK_NODATA);

    /* 3. EDID 60 Hz vs 120 Hz ProMotion Detailed Timing Descriptor pixel clock. */
    HENGE_CHECK(henge_virtio_gpu_set_display_mode(vgpu, 0U, 1280U, 720U, true) == 0);
    HENGE_CHECK(henge_virtio_gpu_set_refresh_hz(vgpu, 0U, 60U) == 0);
    uint8_t edid60[128], edid120[128];
    HENGE_CHECK(henge_virtio_gpu_get_edid(vgpu, 0U, edid60) == 0);
    HENGE_CHECK(henge_virtio_gpu_set_refresh_hz(vgpu, 0U, 120U) == 0);
    HENGE_CHECK(henge_virtio_gpu_get_edid(vgpu, 0U, edid120) == 0);
    uint16_t pclk60 = (uint16_t)(edid60[54] | ((uint16_t)edid60[55] << 8));
    uint16_t pclk120 = (uint16_t)(edid120[54] | ((uint16_t)edid120[55] << 8));
    HENGE_CHECK(pclk120 >= (uint16_t)(pclk60 * 2U - 2U) && pclk120 <= (uint16_t)(pclk60 * 2U + 2U));
    henge_virtio_gpu_destroy(vgpu);

    /* 4. Bounded LRU shader disk cache (put, size query, get, eviction, clear). */
    const char *cache_dir = "build/test_shader_cache";
    HENGE_CHECK(henge_shader_cache_init(cache_dir, "henge-test-v0.3.0", 2048U) == 0);
    HENGE_CHECK(henge_shader_cache_is_ready());
    HENGE_CHECK(henge_shader_cache_clear() == 0);
    uint8_t blobA[1024], blobB[1024], blobC[1024], outBuf[1024];
    memset(blobA, 0xA1, sizeof(blobA));
    memset(blobB, 0xB2, sizeof(blobB));
    memset(blobC, 0xC3, sizeof(blobC));
    HENGE_CHECK(henge_shader_cache_put("keyA", 4U, blobA, sizeof(blobA)) == 0);
    HENGE_CHECK(henge_shader_cache_put("keyB", 4U, blobB, sizeof(blobB)) == 0);
    HENGE_CHECK(henge_shader_cache_get("keyA", 4U, NULL, 0U) == sizeof(blobA));
    HENGE_CHECK(henge_shader_cache_get("keyA", 4U, outBuf, sizeof(outBuf)) == sizeof(blobA));
    HENGE_CHECK(memcmp(outBuf, blobA, sizeof(blobA)) == 0);
    /* Third 1 KiB blob exceeds 2 KiB cap and triggers LRU eviction down to <= 2048 B. */
    HENGE_CHECK(henge_shader_cache_put("keyC", 4U, blobC, sizeof(blobC)) == 0);
    HengeShaderCacheStats cstats;
    henge_shader_cache_get_stats(&cstats);
    HENGE_CHECK(cstats.ready && cstats.total_bytes <= 2048U && cstats.evictions >= 1ULL);
    HENGE_CHECK(henge_shader_cache_clear() == 0);
    henge_shader_cache_get_stats(&cstats);
    HENGE_CHECK(cstats.entry_count == 0U && cstats.total_bytes == 0ULL);

    /* 5. Thermal step-down pacing & lock-free FPS telemetry atomics. */
    henge_gpu_telemetry_reset();
    henge_gpu_telemetry_set_active_backend(1U);
    henge_gpu_telemetry_set_target_refresh_hz(120U);
    henge_gpu_telemetry_set_thermal_state(HENGE_THERMAL_NOMINAL);
    HENGE_CHECK(henge_gpu_telemetry_effective_refresh_hz() == 120U);
    henge_gpu_telemetry_set_thermal_state(HENGE_THERMAL_SERIOUS);
    HENGE_CHECK(henge_gpu_telemetry_effective_refresh_hz() == 40U);
    henge_gpu_telemetry_set_thermal_state(HENGE_THERMAL_CRITICAL);
    HENGE_CHECK(henge_gpu_telemetry_effective_refresh_hz() == 30U);
    henge_gpu_telemetry_set_thermal_state(HENGE_THERMAL_NOMINAL);
    henge_gpu_telemetry_set_target_refresh_hz(60U);
    for (uint64_t i = 0ULL; i <= 30ULL; i++) {
        henge_gpu_telemetry_record_frame(1000000000ULL + i * 16666667ULL);
    }
    HengeGpuTelemetrySnapshot tsnap;
    henge_gpu_telemetry_get_snapshot(&tsnap);
    HENGE_CHECK(tsnap.active_backend == 1U && tsnap.effective_refresh_hz == 60U);
    HENGE_CHECK(tsnap.total_frames_presented == 31ULL);
    HENGE_CHECK(tsnap.fps_tenths >= 550U && tsnap.fps_tenths <= 650U);
}

int main(void) {
    test_unix_socket_path_bounds();
    test_mmu_granule_decoding();
    test_guest_ram_alignment();
    test_render_pause_lifecycle_gate();
    test_multivcpu_counter_jump_atomicity();
    test_txm_jit_bounds_and_blessing();
    test_virtio_gpu_backends();
    test_virgl_async_worker();
    test_phase030c_swapchain_jetsam_cache_telemetry();
    test_console_log_capture();
    test_qcow2_and_storage_tools();
    test_cidata_fat16_generator();
    test_touch_aspect_coordinate_mapping();
    printf("[PASS] test_core: all platform, MMU, RAM, lifecycle, TXM JIT, VirtIO-GPU, QCOW2, CIDATA, touch, and console checks passed.\n");
    return 0;
}
